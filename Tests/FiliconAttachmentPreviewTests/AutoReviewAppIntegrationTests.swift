import Foundation
import Testing
@testable import Filicon
import FiliconAutoReview
import FiliconDomain

@Suite("Auto-review app integration")
struct AutoReviewAppIntegrationTests {
    @Test("Ask suspends execution and approve grants exactly one execution")
    func approveExecutesExactlyOnce() async throws {
        let broker = PendingApprovalBroker()
        let counter = AppExecutionCounter()
        let fence = appFence()
        await broker.activate(fence)
        let executor = appReviewingExecutor(counter: counter, broker: broker, fence: fence)
        let call = try appCall()
        let task = Task {
            try await executor.execute(call, context: .init(conversationID: fenceConversation, runID: fence.runID))
        }
        let pending = try await appPending(broker)
        #expect(await counter.count == 0)
        try await broker.resolve(reviewID: pending.id, resolution: .approve, fence: pending.fence)
        _ = try await task.value
        #expect(await counter.count == 1)
        do {
            try await broker.resolve(reviewID: pending.id, resolution: .approve, fence: pending.fence)
            Issue.record("Replay unexpectedly acquired authority")
        } catch let error as PendingApprovalError {
            #expect(error == .replay(pending.id))
        }
        #expect(await counter.count == 1)
    }

    @Test("Deny never reaches the app tool executor")
    func denyDoesNotExecute() async throws {
        let broker = PendingApprovalBroker()
        let counter = AppExecutionCounter()
        let fence = appFence()
        await broker.activate(fence)
        let executor = appReviewingExecutor(counter: counter, broker: broker, fence: fence)
        let task = Task {
            try await executor.execute(try appCall(), context: .init(conversationID: fenceConversation, runID: fence.runID))
        }
        let pending = try await appPending(broker)
        try await broker.resolve(reviewID: pending.id, resolution: .deny, fence: pending.fence)
        do { _ = try await task.value; Issue.record("Denied operation executed") }
        catch let error as PendingApprovalError { #expect(error == .denied(pending.id)) }
        #expect(await counter.count == 0)
    }

    @Test("Auto-review card accepts only its exact stored review action")
    func cardActionMappingIsExact() async throws {
        let reviewID = "review-exact"
        let card = TranscriptCard(
            lifecycle: .waiting,
            payload: .autoReview(.init(reviewID: reviewID, title: "Approval required")),
            actions: [
                .init(id: "approve", label: "Approve", intent: .approveReview(reviewID: reviewID)),
                .init(id: "reject", label: "Reject", intent: .rejectReview(reviewID: reviewID)),
            ]
        )
        _ = try await TranscriptCardActionRouter().begin(card: card, intent: .approveReview(reviewID: reviewID))
        do {
            _ = try await TranscriptCardActionRouter().begin(card: card, intent: .approveReview(reviewID: "forged"))
            Issue.record("Forged review ID was accepted")
        } catch let error as TranscriptCardActionRoutingError {
            #expect(error == .unauthorizedAction)
        }
    }

    @Test("Atomic settings survive an app-style restart and enforce bounds")
    func settingsSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "filicon-auto-review-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "auto-review-instructions.json")
        try AtomicAutoReviewInstructionsStore(fileURL: url).save(.init(
            isEnabled: true,
            allowRules: Array(repeating: String(repeating: "r", count: 1_100), count: 24),
            askRules: ["network access"]
        ))
        let restarted = try AtomicAutoReviewInstructionsStore(fileURL: url).load()
        #expect(restarted.isEnabled)
        #expect(restarted.allowRules.count == 20)
        #expect(restarted.allowRules.allSatisfy { $0.count == 1_000 })
        #expect(restarted.askRules == ["network access"])
    }
}

private let fenceConversation = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

private actor AppExecutionCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct AppCountingExecutor: ToolExecutor {
    let counter: AppExecutionCounter
    let descriptor = ToolDescriptor(name: "local__read_file")
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        await counter.increment()
        return .init(callID: call.id, content: [.text("ok")])
    }
}

private func appFence() -> ApprovalFence {
    .init(accountID: "account", agentID: fenceConversation.uuidString.lowercased(), runID: UUID(), generation: 1)
}

private func appCall() throws -> NormalizedToolCall {
    try .init(id: "call", name: "local__read_file", argumentsJSON: Data("{\"path\":\"/tmp/a\"}".utf8))
}

private func appReviewingExecutor(
    counter: AppExecutionCounter, broker: PendingApprovalBroker, fence: ApprovalFence
) -> ReviewingToolExecutor {
    ReviewingToolExecutor(
        wrapping: AppCountingExecutor(counter: counter),
        broker: broker,
        instructions: { .init(isEnabled: false) },
        action: { call, _, context in
            .init(
                summary: "Read a file",
                target: .file(path: "/tmp/a"),
                risks: [.readOnly],
                context: .init(
                    fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue
                )
            )
        }
    )
}

private func appPending(_ broker: PendingApprovalBroker) async throws -> PendingApproval {
    for _ in 0..<100 {
        if let value = await broker.pendingApprovals.first { return value }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AppIntegrationTestError.pendingNotRegistered
}

private enum AppIntegrationTestError: Error { case pendingNotRegistered }
