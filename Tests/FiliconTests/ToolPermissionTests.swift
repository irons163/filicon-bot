import Foundation
import Testing
import FiliconDomain
import FiliconAppServices

@Suite("Local tool permissions")
struct ToolPermissionTests {
    @Test func adminCeilingOnlyReducesAuthority() {
        #expect(LocalToolPermission.always.constrained(by: .ask) == .ask)
        #expect(LocalToolPermission.always.constrained(by: .never) == .never)
        #expect(LocalToolPermission.ask.constrained(by: .always) == .ask)
        #expect(LocalToolPermission.never.constrained(by: .always) == .never)
    }

    @Test func defaultsToAskAndGrantIsScopedAndSingleUse() async {
        let policy = ToolPermissionPolicy()
        let conversation = UUID()
        let first = await policy.evaluate(
            action: .readFile,
            conversationID: conversation,
            toolCallID: "call-1",
            title: "Read file",
            reason: "Summarize it"
        )
        guard case .requiresApproval(let request) = first else {
            Issue.record("default policy must require approval")
            return
        }
        await policy.approveOnce(request, expiresAt: Date().addingTimeInterval(60))

        #expect(await policy.evaluate(action: .readFile, conversationID: conversation, toolCallID: "call-1", title: "Read file", reason: "Summarize it") == .allowed)
        guard case .requiresApproval = await policy.evaluate(action: .readFile, conversationID: conversation, toolCallID: "call-1", title: "Read file", reason: "Replay") else {
            Issue.record("one-time grant must be consumed")
            return
        }
        guard case .requiresApproval = await policy.evaluate(action: .writeFile, conversationID: conversation, toolCallID: "call-1", title: "Write file", reason: "Different action") else {
            Issue.record("grant must be action-scoped")
            return
        }
    }

    @Test func neverAndExpiredGrantFailClosed() async {
        let policy = ToolPermissionPolicy(choices: [.runCommand: .always], adminCeilings: [.runCommand: .never])
        #expect(await policy.evaluate(action: .runCommand, conversationID: UUID(), toolCallID: "shell", title: "Run", reason: "test") == .denied)

        let conversation = UUID()
        let decision = await policy.evaluate(action: .readFile, conversationID: conversation, toolCallID: "expired", title: "Read", reason: "test")
        guard case .requiresApproval(let request) = decision else { return }
        await policy.approveOnce(request, expiresAt: Date().addingTimeInterval(-1))
        guard case .requiresApproval = await policy.evaluate(action: .readFile, conversationID: conversation, toolCallID: "expired", title: "Read", reason: "test") else {
            Issue.record("expired approval must not authorize")
            return
        }
    }

    @Test func choicesPersistAndBrokerCancellationLeavesNoContinuation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("filicon-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("permissions.json")
        let first = ToolPermissionPolicy(persistenceURL: url)
        try await first.setChoice(.always, for: .readFile)
        let restored = ToolPermissionPolicy(persistenceURL: url)
        #expect(await restored.effectivePermission(for: .readFile) == .always)

        let conversation = UUID()
        let request = ToolApprovalRequest(
            conversationID: conversation,
            toolCallID: "pending",
            action: .writeFile,
            title: "/tmp/target",
            reason: "test"
        )
        let broker = ToolApprovalBroker()
        let waiter = Task { await broker.requestApproval(request) }
        for _ in 0..<50 where await broker.requests().isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(await broker.requests().isEmpty)
    }
}

@Test func brokerResolvesOnlyTheExactTranscriptRequest() async {
    let broker = ToolApprovalBroker()
    let request = ToolApprovalRequest(
        conversationID: UUID(), toolCallID: "tool-call", action: .readFile,
        title: "/exact/root/file", reason: "read"
    )
    let waiting = Task { await broker.requestApproval(request) }
    while await broker.requests().isEmpty { await Task.yield() }

    #expect(await broker.resolveIfMatches(
        id: request.id, conversationID: UUID(), action: request.action,
        title: request.title, allowed: true
    ) == false)
    #expect(await broker.resolveIfMatches(
        id: request.id, conversationID: request.conversationID, action: .writeFile,
        title: request.title, allowed: true
    ) == false)
    #expect(await broker.resolveIfMatches(
        id: request.id, conversationID: request.conversationID, action: request.action,
        title: "/broader/root", allowed: true
    ) == false)
    #expect(await broker.requests().map(\.id) == [request.id])

    #expect(await broker.resolveIfMatches(
        id: request.id, conversationID: request.conversationID, action: request.action,
        title: request.title, allowed: true
    ))
    #expect(await waiting.value)
    #expect(await broker.resolveIfMatches(
        id: request.id, conversationID: request.conversationID, action: request.action,
        title: request.title, allowed: true
    ) == false)
}

@Test func brokerClaimCanCommitOrRestoreAnExactAlwaysAllowRequest() async {
    let broker = ToolApprovalBroker()
    let request = ToolApprovalRequest(
        conversationID: UUID(), toolCallID: "tool-call", action: .runCommand,
        title: "/usr/bin/swift [\"test\"]", reason: "test"
    )
    let waiting = Task { await broker.requestApproval(request) }
    while await broker.requests().isEmpty { await Task.yield() }

    #expect(await broker.claimIfMatches(
        id: request.id, conversationID: request.conversationID,
        action: request.action, title: request.title
    ))
    #expect(await broker.requests().isEmpty)
    await broker.abandonClaim(id: request.id)
    #expect(await broker.requests().map(\.id) == [request.id])

    #expect(await broker.claimIfMatches(
        id: request.id, conversationID: request.conversationID,
        action: request.action, title: request.title
    ))
    #expect(await broker.completeClaim(id: request.id, allowed: true))
    #expect(await waiting.value)
    #expect(await broker.completeClaim(id: request.id, allowed: true) == false)
}
