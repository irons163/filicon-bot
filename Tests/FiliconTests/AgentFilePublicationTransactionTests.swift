import CustomDump
import Foundation
import Testing
import FiliconAppServices
import FiliconDomain

private actor FilePublicationProbe {
    var events: [String] = []
    var active = true
    func record(_ event: String) { events.append(event) }
    func revoke() { active = false }
    func check() throws { if !active { throw CancellationError() } }
}

private actor FilePublicationGate {
    var reached = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        reached = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
    func waitUntilReached() async throws {
        for _ in 0..<600 {
            if reached { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }
}

@Suite("File publication approval and durable receipt", .timeLimit(.minutes(1)))
struct AgentFilePublicationTransactionTests {
    @Test(arguments: ["success", "deny", "revoke-read", "revoke-review", "prepare-failure", "save-failure",
        "wrong-conversation", "wrong-sender", "wrong-reply", "wrong-digest", "wrong-size", "wrong-name"])
    func orderedSnapshotTransaction(mode: String) async throws {
        let origin = UUID(), sender = UUID(), reply = UUID(), message = UUID(), probe = FilePublicationProbe()
        let file = try PreparedAgentPublicationFile(bytes: Data("artifact".utf8), filename: "report.txt")
        let transaction = AgentFilePublicationTransaction(conversationID: origin, senderID: sender,
            validateScope: { try await probe.check() }, prepare: { url, _, _ in
                expectNoDifference(url, "file:///authorized/report.txt")
                await probe.record("prepare")
                if mode == "prepare-failure" { throw AgentFilePublicationError.unavailable }
                if mode == "revoke-read" { await probe.revoke() }
                return file
            }, authorize: { review, _, _ in
                await probe.record("review")
                expectNoDifference(review.file, file)
                expectNoDifference(review.conversationID, origin)
                expectNoDifference(review.senderID, sender)
                expectNoDifference(review.replyTo, reply)
                if mode == "deny" { throw CancellationError() }
                if mode == "revoke-review" { await probe.revoke() }
            }, commit: { review, _, _ in
                await probe.record("commit")
                expectNoDifference(review.file, file)
                if mode == "save-failure" { throw AgentFilePublicationError.unavailable }
                return .init(messageID: message, conversationID: mode == "wrong-conversation" ? UUID() : origin,
                    senderID: mode == "wrong-sender" ? UUID() : sender,
                    replyTo: mode == "wrong-reply" ? nil : reply,
                    digest: mode == "wrong-digest" ? "incorrect" : file.digest,
                    filename: mode == "wrong-name" ? "different.txt" : file.filename,
                    byteCount: mode == "wrong-size" ? 0 : file.bytes.count)
            })
        let context = ToolContext(conversationID: origin)
        let call = try NormalizedToolCall(id: "publish", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        if mode == "success" {
            let first = try await transaction.publish(url: "file:///authorized/report.txt", replyTo: reply, call: call, context: context)
            await transaction.close()
            let replay = try await transaction.publish(url: "file:///authorized/report.txt", replyTo: reply, call: call, context: context)
            expectNoDifference(replay, first)
            expectNoDifference(first.messageID, message)
            await #expect(throws: AgentFilePublicationError.duplicateCall) {
                _ = try await transaction.publish(url: "file:///different", replyTo: reply, call: call, context: context)
            }
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await transaction.publish(url: "file:///authorized/report.txt", replyTo: reply, call: call, context: context)
            }
            if mode.hasPrefix("wrong-") || mode == "save-failure" {
                await #expect(throws: AgentFilePublicationError.uncertainCommit) {
                    _ = try await transaction.publish(url: "file:///authorized/report.txt", replyTo: reply, call: call, context: context)
                }
            }
        }
        let events = await probe.events
        let expected = ["prepare-failure", "revoke-read"].contains(mode) ? ["prepare"]
            : ["deny", "revoke-review"].contains(mode) ? ["prepare", "review"] : ["prepare", "review", "commit"]
        expectNoDifference(events, expected)
    }

    @Test func rejectsWrongContextAndClosedWithoutReading() async throws {
        let origin = UUID(), probe = FilePublicationProbe()
        let transaction = AgentFilePublicationTransaction(conversationID: origin, senderID: UUID(), validateScope: {},
            prepare: { _, _, _ in await probe.record("unexpected read"); throw CancellationError() },
            authorize: { _, _, _ in await probe.record("unexpected review") },
            commit: { _, _, _ in await probe.record("unexpected save"); throw CancellationError() })
        let call = try NormalizedToolCall(id: "publish", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        await #expect(throws: AgentFilePublicationError.unavailable) {
            _ = try await transaction.publish(url: "file:///a", replyTo: nil, call: call, context: .init(conversationID: UUID()))
        }
        await transaction.close()
        await #expect(throws: AgentFilePublicationError.unavailable) {
            _ = try await transaction.publish(url: "file:///a", replyTo: nil, call: call, context: .init(conversationID: origin))
        }
        let events = await probe.events
        expectNoDifference(events, [])
    }

    @Test(arguments: ["", ".", "..", "a/b", "a\\b", "a\u{0}b", "a\nb", String(repeating: "a", count: 256)])
    func rejectsUnsafeSnapshotFilename(name: String) {
        #expect(throws: AttachmentStoreError.invalidFilename) {
            _ = try PreparedAgentPublicationFile(bytes: Data(), filename: name)
        }
    }

    @Test(arguments: ["review", "commit"])
    func stopDuringAwaitPreventsSaveOrRetainsDurableReceipt(phase: String) async throws {
        let origin = UUID(), sender = UUID(), message = UUID(), gate = FilePublicationGate(), probe = FilePublicationProbe()
        let file = try PreparedAgentPublicationFile(bytes: Data([1, 2, 3]), filename: "result.bin")
        let transaction = AgentFilePublicationTransaction(conversationID: origin, senderID: sender,
            validateScope: {}, prepare: { _, _, _ in file }, authorize: { _, _, _ in
                if phase == "review" { await gate.pause() }
            }, commit: { review, _, _ in
                await probe.record("commit")
                if phase == "commit" { await gate.pause() }
                return .init(messageID: message, conversationID: origin, senderID: sender, replyTo: nil,
                    digest: review.file.digest, filename: review.file.filename, byteCount: review.file.bytes.count)
            })
        let context = ToolContext(conversationID: origin)
        let call = try NormalizedToolCall(id: "publish", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        let work = Task { try await transaction.publish(url: "file:///result.bin", replyTo: nil, call: call, context: context) }
        try await gate.waitUntilReached()
        await #expect(throws: AgentFilePublicationError.busy) {
            _ = try await transaction.publish(url: "file:///result.bin", replyTo: nil,
                call: .init(id: "second", name: "SendMessage", argumentsJSON: Data("{}".utf8)), context: context)
        }
        await transaction.close()
        work.cancel()
        await gate.resume()
        if phase == "review" {
            await #expect(throws: CancellationError.self) { _ = try await work.value }
        } else {
            let receipt = try await work.value
            expectNoDifference(receipt.messageID, message)
            let replay = try await transaction.publish(url: "file:///result.bin", replyTo: nil, call: call, context: context)
            expectNoDifference(replay, receipt)
        }
        let events = await probe.events
        expectNoDifference(events, phase == "review" ? [] : ["commit"])
    }
}
