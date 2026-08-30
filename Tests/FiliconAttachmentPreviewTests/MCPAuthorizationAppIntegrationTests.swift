import Foundation
import Testing
@testable import Filicon
import FiliconDomain
import FiliconMCP

private actor AppApprovalConnection: MCPConnection {
    private(set) var calls: [(String, MCPJSONValue)] = []
    let tool: MCPToolDescriptor
    init(tool: MCPToolDescriptor) { self.tool = tool }
    func connect() async throws {}
    func listTools() async throws -> [MCPToolDescriptor] { [tool] }
    func callTool(name: String, arguments: MCPJSONValue) async throws -> MCPToolResult {
        calls.append((name, arguments))
        return .init(content: [.init(type: "text", text: "authorized")])
    }
    func listResources() async throws -> [MCPResourceDescriptor] { [] }
    func readResource(uri: String) async throws -> MCPResourceResult { .init(contents: []) }
    func close() async {}
    func count() -> Int { calls.count }
}

private struct AppApprovalFactory: MCPConnectionFactory {
    let connection: AppApprovalConnection
    func connection(for config: MCPServerConfig) async throws -> any MCPConnection { connection }
}

private actor ApprovalPresentationBox {
    private var values: [MCPApprovalPresentation] = []
    func set(_ value: [MCPApprovalPresentation]) { values = value }
    func first() -> MCPApprovalPresentation? { values.first }
}

private func waitForApproval(_ box: ApprovalPresentationBox, excluding: UUID? = nil) async throws -> MCPApprovalPresentation {
    for _ in 0..<500 {
        if let value = await box.first(), value.id != excluding { return value }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw MCPAuthorizationError.unknownRequest
}

private func appExecutor(
    annotations: MCPToolAnnotations,
    policy: MCPDispatchPolicy = .init(),
    box: ApprovalPresentationBox
) async throws -> (AuthorizedMCPToolExecutor, AppApprovalConnection, AppMCPApprovalBroker, MCPAuthorizationCoordinator) {
    let tool = MCPToolDescriptor(
        serverIdentifier: "mail-work", name: "send", description: "Send mail",
        inputSchema: .object([:]), annotations: annotations
    )
    let connection = AppApprovalConnection(tool: tool)
    let service = MCPService(factory: AppApprovalFactory(connection: connection))
    try await service.replaceConfigs([try MCPServerConfig(
        identifier: "mail-work", displayName: "Mail",
        transport: .stdio(executable: "/usr/bin/false", arguments: [], environmentReferences: [:], workingDirectory: nil)
    )])
    let authorization = MCPAuthorizationCoordinator()
    let broker = AppMCPApprovalBroker { values in Task { await box.set(values) } }
    return (
        AuthorizedMCPToolExecutor(
            dispatcher: MCPAuthorizedDispatcher(service: service, authorization: authorization),
            authorization: authorization, approvals: broker, tool: tool,
            accountIdentifier: "work", serverName: "Mail", accountName: "Work",
            policy: policy
        ),
        connection, broker, authorization
    )
}

@Suite("MCP authorization app integration")
struct MCPAuthorizationAppIntegrationTests {
    @Test func allowDenyAndAlwaysExactStayBoundToOriginalContinuation() async throws {
        let box = ApprovalPresentationBox()
        let (executor, connection, broker, _) = try await appExecutor(
            annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: true), box: box
        )
        let context = ToolContext(conversationID: UUID())
        let first = try NormalizedToolCall(id: "deny", name: executor.descriptor.name, argumentsJSON: Data(#"{"to":"a","token":"secret"}"#.utf8))
        let denied = Task { try await executor.execute(first, context: context) }
        let deniedApproval = try await waitForApproval(box)
        #expect(deniedApproval.serverName == "Mail")
        #expect(deniedApproval.accountName == "Work")
        #expect(deniedApproval.request.risk.risk == .mutation)
        #expect(deniedApproval.argumentsSummary.contains("<redacted>"))
        #expect(await broker.resolveIfMatches(deniedApproval, resolution: .deny))
        await #expect(throws: MCPAuthorizationError.denied) { _ = try await denied.value }
        #expect(await connection.count() == 0)

        let approved = Task { try await executor.execute(first, context: context) }
        let once = try await waitForApproval(box, excluding: deniedApproval.id)
        #expect(await broker.resolveIfMatches(once, resolution: .allowAlways(scope: .exactArguments)))
        #expect(try await approved.value.wireText == "authorized")
        #expect(await connection.count() == 1)

        // Same exact arguments use the scoped grant; changed arguments must ask again.
        _ = try await executor.execute(first, context: context)
        #expect(await connection.count() == 2)
        let changed = try NormalizedToolCall(id: "changed", name: executor.descriptor.name, argumentsJSON: Data(#"{"to":"b"}"#.utf8))
        let pending = Task { try await executor.execute(changed, context: context) }
        let changedApproval = try await waitForApproval(box, excluding: once.id)
        let targets = await broker.cancel(conversationID: context.conversationID)
        #expect(targets.contains(changedApproval.request.target))
        await #expect(throws: MCPAuthorizationError.requestCancelled) { _ = try await pending.value }
    }

    @Test func unknownAnnotationsProjectReasonsAndManagedCeilingDisablesPersistentChoices() async throws {
        let box = ApprovalPresentationBox()
        let unknown = MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: true, openWorldHint: false,
            hasUnknownFields: true
        )
        let (executor, _, broker, _) = try await appExecutor(
            annotations: unknown, policy: .init(userMode: .always, managedCeiling: .ask), box: box
        )
        let call = try NormalizedToolCall(id: "unknown", name: executor.descriptor.name, argumentsJSON: Data("{}".utf8))
        let task = Task { try await executor.execute(call, context: .init(conversationID: UUID())) }
        let approval = try await waitForApproval(box)
        #expect(approval.request.risk.risk == .unknown)
        #expect(!approval.request.risk.reasons.isEmpty)
        #expect(!approval.canPersist)
        #expect(!approval.canPersistTool)
        #expect(await broker.resolveIfMatches(approval, resolution: .allowOnce))
        _ = try await task.value
    }

    @Test func expiryAndGenerationCancellationNeverDispatch() async throws {
        let box = ApprovalPresentationBox()
        let (executor, connection, broker, authorization) = try await appExecutor(
            annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: true), box: box
        )
        let conversation = UUID()
        let call = try NormalizedToolCall(id: "cancel", name: executor.descriptor.name, argumentsJSON: Data("{}".utf8))
        let task = Task { try await executor.execute(call, context: .init(conversationID: conversation)) }
        let approval = try await waitForApproval(box)
        let targets = await broker.cancelAll()
        for target in targets {
            await authorization.advanceGeneration(
                serverIdentifier: target.serverIdentifier, accountIdentifier: target.accountIdentifier,
                conversationIdentifier: target.conversationIdentifier
            )
        }
        await #expect(throws: MCPAuthorizationError.requestCancelled) { _ = try await task.value }
        #expect(await connection.count() == 0)
        #expect(targets.contains(approval.request.target))

        let expiredAuthorization = MCPAuthorizationCoordinator(now: { Date(timeIntervalSince1970: 0) })
        let expiredTarget = await expiredAuthorization.makeTarget(
            serverIdentifier: "mail-work", accountIdentifier: "work",
            conversationIdentifier: conversation.uuidString, toolName: "send", arguments: .object([:])
        )
        let expiredDescriptor = MCPToolDescriptor(
            serverIdentifier: "mail-work", name: "send", description: nil,
            inputSchema: .object([:]), annotations: .init()
        )
        guard case .approvalRequired(let expiredRequest) = await expiredAuthorization.prepare(
            target: expiredTarget, descriptor: expiredDescriptor, policy: .init()
        ) else { Issue.record("Expected an expiring approval"); return }
        let expiryBroker = AppMCPApprovalBroker()
        await expiryBroker.register(expiredRequest.target)
        let expiredDecision = await expiryBroker.request(.init(
            request: expiredRequest, serverName: "Mail", accountName: "Work",
            argumentsSummary: "{}", policy: .init()
        ))
        guard case .expired = expiredDecision else { Issue.record("Expired requests must not remain actionable"); return }

        // The app expiry cleanup cancels before resolving, so it removes the request without
        // ever minting an unused allow-once receipt—even if called before wall-clock expiry.
        let drainAuthorization = MCPAuthorizationCoordinator()
        let drainTarget = await drainAuthorization.makeTarget(
            serverIdentifier: "mail-work", accountIdentifier: "work",
            conversationIdentifier: "c-drain", toolName: "send", arguments: .object([:])
        )
        guard case .approvalRequired(let drainRequest) = await drainAuthorization.prepare(
            target: drainTarget, descriptor: expiredDescriptor, policy: .init()
        ) else { Issue.record("Expected a drainable request"); return }
        try await AuthorizedMCPToolExecutor.discardExpiredRequest(
            drainRequest.id, authorization: drainAuthorization, policy: .init()
        )
        await #expect(throws: MCPAuthorizationError.unknownRequest) {
            _ = try await drainAuthorization.resolve(
                requestID: drainRequest.id, resolution: .allowOnce, policy: .init()
            )
        }
    }

    @Test func userPolicyPersistenceContainsOnlyModeAndRawBypassIsAbsent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "policy.json")
        let store = MCPUserPolicyStore(url: url)
        try await store.set(.never, serverIdentifier: "work")
        #expect(await store.mode(serverIdentifier: "work") == .never)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("work"))
        #expect(!text.localizedCaseInsensitiveContains("token"))
        #expect(!text.localizedCaseInsensitiveContains("managed"))

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Filicon/AppModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("private struct MCPToolExecutor"))
        #expect(!source.contains("service.callTool(server:"))
        #expect(source.contains("AuthorizedMCPToolExecutor"))
    }

    @Test func accountLogoutAndConfigFencesCancelOnlyMatchingContinuations() async throws {
        let broker = AppMCPApprovalBroker()
        func presentation(server: String, account: String, conversation: String) async throws -> MCPApprovalPresentation {
            let authorization = MCPAuthorizationCoordinator()
            let target = await authorization.makeTarget(
                serverIdentifier: server, accountIdentifier: account,
                conversationIdentifier: conversation, toolName: "send", arguments: .object([:])
            )
            let descriptor = MCPToolDescriptor(
                serverIdentifier: server, name: "send", description: nil,
                inputSchema: .object([:]), annotations: .init()
            )
            guard case .approvalRequired(let request) = await authorization.prepare(
                target: target, descriptor: descriptor, policy: .init()
            ) else { throw MCPAuthorizationError.denied }
            return .init(request: request, serverName: server, accountName: account,
                         argumentsSummary: "{}", policy: .init())
        }
        let work = try await presentation(server: "mail-work", account: "work", conversation: "c1")
        let personal = try await presentation(server: "mail-personal", account: "personal", conversation: "c1")
        await broker.register(work.request.target)
        await broker.register(personal.request.target)
        let workTask = Task { await broker.request(work) }
        let personalTask = Task { await broker.request(personal) }
        for _ in 0..<100 { await Task.yield() }

        let loggedOutTargets = await broker.cancel(serverIdentifier: "mail-work", accountIdentifier: "work")
        #expect(loggedOutTargets == [work.request.target])
        guard case .cancelled = await workTask.value else { Issue.record("Logout must cancel its exact account"); return }
        #expect(await broker.resolveIfMatches(personal, resolution: .allowOnce))
        guard case .resolution(.allowOnce) = await personalTask.value else { Issue.record("Other accounts must remain independently actionable"); return }

        await broker.register(work.request.target)
        let configTask = Task { await broker.request(work) }
        for _ in 0..<100 { await Task.yield() }
        #expect(await broker.cancelAll().contains(work.request.target))
        guard case .cancelled = await configTask.value else { Issue.record("Config replacement must cancel all generations"); return }

        // A target invalidated after prepare but before UI registration cannot reappear.
        await broker.register(personal.request.target)
        _ = await broker.cancelAll()
        guard case .cancelled = await broker.request(personal) else {
            Issue.record("A prepare-to-pending config race must fail closed"); return
        }
    }
}
