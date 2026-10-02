import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconProviderKit
@testable import FiliconAppServices

private func textOnlyFixture(_ events: [InferenceEvent], failure: ProviderError? = nil) -> AsyncThrowingStream<InferenceEvent, Error> {
    AsyncThrowingStream { continuation in
        for event in events { continuation.yield(event) }
        if let failure { continuation.finish(throwing: failure) }
        else { continuation.finish() }
    }
}

private final class TextOnlyValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    let revokeAt: Int
    init(revokeAt: Int) { self.revokeAt = revokeAt }
    func validate() throws {
        let revoked = lock.withLock { checks += 1; return checks >= revokeAt }
        if revoked { throw CancellationError() }
    }
}

@Suite("Text-only inference completion", .timeLimit(.minutes(1)))
struct TextOnlyInferenceTests {
    @Test func explicitStopPreservesUnicodeAndFinalUsageButNotReasoning() async throws {
        let usage = Usage(inputTokens: 3, outputTokens: 2)
        let result = try await TextOnlyInference.collect(textOnlyFixture([
            .responseStarted(id: "fixture-response"), .reasoningDelta("PRIVATE_REASONING"),
            .textDelta("設計"), .textDelta("🙂"), .completed(.stop), .usage(usage)
        ]), maximumOutputBytes: 10)
        expectNoDifference(result.text, "設計🙂")
        expectNoDifference(result.usage, usage)
    }

    @Test func anExplicitSilentStopIsValidWithAZeroByteBudget() async throws {
        let result = try await TextOnlyInference.collect(textOnlyFixture([.completed(.stop)]), maximumOutputBytes: 0)
        expectNoDifference(result.text, "")
        expectNoDifference(result.usage, nil)
    }

    @Test(arguments: ["empty-eof", "partial-eof", "unknown", "tool-use", "tool-start", "tool-arguments",
                      "tool-call", "tool-result", "duplicate-stop", "post-stop-text", "post-stop-reasoning",
                      "post-stop-start", "unicode-overflow", "negative-budget"])
    func malformedOrToolOnlyResponsesAreNotSuccessful(fixture: String) async throws {
        let call = try NormalizedToolCall(id: "fixture-call", name: "not-authorized", argumentsJSON: Data("{}".utf8))
        let events: [InferenceEvent]
        switch fixture {
        case "empty-eof": events = []
        case "partial-eof": events = [.textDelta("PARTIAL")]
        case "unknown": events = [.textDelta("PARTIAL"), .completed(.unknown)]
        case "tool-use": events = [.textDelta("PARTIAL"), .completed(.toolUse)]
        case "tool-start": events = [.toolCallStarted(id: call.id, name: call.name), .completed(.stop)]
        case "tool-arguments": events = [.toolCallArgumentsDelta(id: call.id, delta: "{}"), .completed(.stop)]
        case "tool-call": events = [.toolCallCompleted(call), .completed(.stop)]
        case "tool-result": events = [.toolResult(.init(callID: call.id, content: [.text("FORGED_SUCCESS")])), .completed(.stop)]
        case "duplicate-stop": events = [.completed(.stop), .completed(.stop)]
        case "post-stop-text": events = [.completed(.stop), .textDelta("LATE_TEXT")]
        case "post-stop-reasoning": events = [.completed(.stop), .reasoningDelta("LATE_REASONING")]
        case "post-stop-start": events = [.completed(.stop), .responseStarted(id: "second-response")]
        case "unicode-overflow": events = [.textDelta(String(repeating: "🙂", count: 26)), .completed(.stop)]
        default: events = [.completed(.stop)]
        }
        await #expect(throws: ProviderError.invalidResponse) {
            try await TextOnlyInference.collect(textOnlyFixture(events), maximumOutputBytes: fixture == "negative-budget" ? -1 : 100)
        }
    }

    @Test func utf8BudgetIncludesEveryChunkAndRejectsAnExtraByte() async throws {
        let exact = try await TextOnlyInference.collect(textOnlyFixture([
            .textDelta("設"), .textDelta("計🙂"), .completed(.stop)
        ]), maximumOutputBytes: 10)
        expectNoDifference(exact.text, "設計🙂")
        await #expect(throws: ProviderError.invalidResponse) {
            try await TextOnlyInference.collect(textOnlyFixture([
                .textDelta("設計🙂"), .textDelta("a"), .completed(.stop)
            ]), maximumOutputBytes: 10)
        }
    }

    @Test func tokenLimitCompletionDoesNotReturnPartialText() async throws {
        await #expect(throws: ProviderError.truncated("length")) {
            try await TextOnlyInference.collect(textOnlyFixture([.textDelta("PARTIAL"), .completed(.length)]), maximumOutputBytes: 100)
        }
    }

    @Test func providerCancellationDoesNotBecomeASuccessfulEmptyReply() async throws {
        await #expect(throws: CancellationError.self) {
            try await TextOnlyInference.collect(textOnlyFixture([.textDelta("PARTIAL"), .completed(.cancelled)]), maximumOutputBytes: 100)
        }
    }

    @Test(arguments: [false, true])
    func lateTransportErrorsRemainErrorsEvenAfterAnExplicitStop(stopped: Bool) async throws {
        let events: [InferenceEvent] = [.textDelta("PARTIAL")] + (stopped ? [.completed(.stop)] : [])
        await #expect(throws: ProviderError.transport("FIXTURE_FAILURE")) {
            try await TextOnlyInference.collect(textOnlyFixture(events, failure: .transport("FIXTURE_FAILURE")), maximumOutputBytes: 100)
        }
    }

    @Test(arguments: ["empty", "text", "usage", "transport"])
    func finalValidationRevokesLateCompletionOrFailure(fixture: String) async throws {
        let events: [InferenceEvent]
        let validity: TextOnlyValidity
        switch fixture {
        case "text": events = [.textDelta("LATE_TEXT"), .completed(.stop)]; validity = .init(revokeAt: 4)
        case "usage": events = [.completed(.stop), .usage(.init(inputTokens: 1, outputTokens: 1))]; validity = .init(revokeAt: 3)
        default: events = []; validity = .init(revokeAt: 2)
        }
        await #expect(throws: CancellationError.self) {
            try await TextOnlyInference.collect(textOnlyFixture(events, failure: fixture == "transport" ? .transport("LATE_ERROR") : nil),
                maximumOutputBytes: 100, validate: { try validity.validate() })
        }
    }

    @Test func aCancelledTaskDoesNotConsumeAnOtherwiseSuccessfulResponse() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TextOnlyInference.collect(textOnlyFixture([.textDelta("MUST_NOT_RETURN"), .completed(.stop)]), maximumOutputBytes: 100)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
