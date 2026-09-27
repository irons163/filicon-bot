import CustomDump
import Foundation
import Testing
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private actor RemotePublicationProbe {
    var events: [String] = []
    var active = true
    func record(_ value: String) { events.append(value) }
    func revoke() { active = false }
    func check() throws { if !active { throw CancellationError() } }
}

private actor RemotePublicationGate {
    var reached = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { reached = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
    func wait() async throws {
        for _ in 0..<600 {
            if reached { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }
}

@Suite("Remote locator publication transaction", .timeLimit(.minutes(1)))
struct AgentRemotePublicationTransactionTests {
    @Test(arguments: ["wrong-context", "wrong-tool", "closed"])
    func invalidScopeNeverReachesApproval(mode: String) async throws {
        let origin = UUID(), probe = RemotePublicationProbe()
        let reference = try RemoteAttachmentReference(url: "https://example.com/report")
        let transaction = AgentRemotePublicationTransaction(conversationID: origin, senderID: UUID(),
            validateScope: {}, authorize: { _, _, _ in await probe.record("approve") },
            commit: { review, _, _ in await probe.record("save"); return .init(messageID: UUID(), review: review) })
        if mode == "closed" { await transaction.close() }
        let call = try NormalizedToolCall(id: "remote", name: mode == "wrong-tool" ? "OtherTool" : "SendMessage", argumentsJSON: Data("{}".utf8))
        await #expect(throws: AgentRemotePublicationTransaction.Failure.unavailable) {
            try await transaction.publish(reference: reference, replyTo: nil, call: call,
                context: ToolContext(conversationID: mode == "wrong-context" ? UUID() : origin))
        }
        let events = await probe.events
        expectNoDifference(events, [])
    }

    @Test(arguments: ["success", "deny", "revoke", "save-failure", "wrong-receipt"])
    func approvalAndReplay(mode: String) async throws {
        let origin = UUID(), sender = UUID(), message = UUID(), probe = RemotePublicationProbe()
        let reference = try RemoteAttachmentReference(url: "https://example.com/report?sig=a%2Bb", alt: "Report")
        let context = ToolContext(conversationID: origin)
        let call = try NormalizedToolCall(id: "remote", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        let transaction = AgentRemotePublicationTransaction(conversationID: origin, senderID: sender,
            validateScope: { try await probe.check() }, authorize: { review, _, _ in
                expectNoDifference(review.reference, reference)
                await probe.record("approve")
                if mode == "deny" { throw CancellationError() }
                if mode == "revoke" { await probe.revoke() }
            }, commit: { review, _, _ in
                await probe.record("save")
                if mode == "save-failure" { throw CocoaError(.fileWriteUnknown) }
                if mode == "wrong-receipt" {
                    // Obtain a different host-bound review, without exposing a model constructor.
                    let other = AgentRemotePublicationTransaction(conversationID: UUID(), senderID: sender,
                        validateScope: {}, authorize: { _, _, _ in }, commit: { review, _, _ in .init(messageID: message, review: review) })
                    return try await other.publish(reference: reference, replyTo: nil, call: call,
                        context: ToolContext(conversationID: other.conversationID))
                }
                return .init(messageID: message, review: review)
            })
        if mode == "success" {
            let saved = try await transaction.publish(reference: reference, replyTo: nil, call: call, context: context)
            expectNoDifference(saved.messageID, message)
            await transaction.close()
            let replay = try await transaction.publish(reference: reference, replyTo: nil, call: call, context: context)
            expectNoDifference(replay, saved)
            let changed = try RemoteAttachmentReference(url: "https://example.com/other")
            await #expect(throws: AgentRemotePublicationTransaction.Failure.duplicateCall) {
                try await transaction.publish(reference: changed, replyTo: nil, call: call, context: context)
            }
        } else {
            await #expect(throws: (any Error).self) {
                try await transaction.publish(reference: reference, replyTo: nil, call: call, context: context)
            }
            if mode == "save-failure" || mode == "wrong-receipt" {
                await #expect(throws: AgentRemotePublicationTransaction.Failure.uncertainCommit) {
                    try await transaction.publish(reference: reference, replyTo: nil, call: call, context: context)
                }
            }
        }
        let events = await probe.events
        expectNoDifference(events, ["deny", "revoke"].contains(mode) ? ["approve"] : ["approve", "save"])
    }

    @Test(arguments: [false, true])
    func cancellationBeforeAndAfterCommit(duringCommit: Bool) async throws {
        let origin = UUID(), message = UUID(), gate = RemotePublicationGate(), probe = RemotePublicationProbe()
        let reference = try RemoteAttachmentReference(url: "https://example.com/video.mp4")
        let call = try NormalizedToolCall(id: "remote", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        let context = ToolContext(conversationID: origin)
        let transaction = AgentRemotePublicationTransaction(conversationID: origin, senderID: UUID(), validateScope: {},
            authorize: { _, _, _ in if !duringCommit { await gate.pause() } },
            commit: { review, _, _ in
                await probe.record("save")
                if duringCommit { await gate.pause() }
                return .init(messageID: message, review: review)
            })
        let task = Task { try await transaction.publish(reference: reference, replyTo: nil, call: call, context: context) }
        try await gate.wait()
        await #expect(throws: duringCommit ? AgentRemotePublicationTransaction.Failure.uncertainCommit : .busy) {
            try await transaction.publish(reference: reference, replyTo: nil, call: call, context: context)
        }
        let concurrentCall = try NormalizedToolCall(id: "concurrent", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        await #expect(throws: AgentRemotePublicationTransaction.Failure.busy) {
            try await transaction.publish(reference: reference, replyTo: nil, call: concurrentCall, context: context)
        }
        task.cancel()
        await transaction.close()
        await gate.resume()
        if duringCommit {
            let receipt = try await task.value
            expectNoDifference(receipt.messageID, message)
        } else {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        let events = await probe.events
        expectNoDifference(events, duringCommit ? ["save"] : [])
    }
}
