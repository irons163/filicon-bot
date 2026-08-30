import Foundation
import Testing
@testable import FiliconMCP

private actor ScriptedTransport: MCPTransport {
    var requests: [MCPRPCRequest] = []
    var notifications: [MCPRPCNotification] = []
    let modern: Bool

    init(modern: Bool) { self.modern = modern }

    func request(_ request: MCPRPCRequest, timeout: Duration) async throws -> MCPRPCResponse {
        requests.append(request)
        switch request.method {
        case "server/discover":
            if modern {
                return .init(id: request.id, result: .object(["supportedVersions": .array([.string(MCPProtocol.current)])]))
            }
            return .init(id: request.id, error: .init(code: -32601, message: "not found"))
        case "initialize":
            return .init(id: request.id, result: .object([
                "protocolVersion": .string(MCPProtocol.legacy),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("fixture"), "version": .string("1")]),
            ]))
        case "tools/list":
            let cursor = request.params?.objectValue?["cursor"]?.stringValue
            if cursor == nil {
                return .init(id: request.id, result: .object([
                    "tools": .array([.object([
                        "name": .string("echo"),
                        "description": .string("<b>echo</b>\nunsafe"),
                        "inputSchema": .object(["type": .string("object")]),
                        "annotations": .object([
                            "title": .string(String(repeating: "E", count: 300)),
                            "readOnlyHint": .bool(true),
                            "destructiveHint": .bool(false),
                            "idempotentHint": .bool(true),
                            "openWorldHint": .bool(false),
                        ]),
                    ])]),
                    "nextCursor": .string("2"),
                ]))
            }
            return .init(id: request.id, result: .object([
                "tools": .array([.object([
                    "name": .string("clock"),
                    "inputSchema": .object(["type": .string("object")]),
                ])]),
            ]))
        case "tools/call":
            return .init(id: request.id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("ok")])]),
                "isError": .bool(false),
            ]))
        case "resources/list":
            return .init(id: request.id, result: .object(["resources": .array([])]))
        default:
            return .init(id: request.id, error: .init(code: -32601, message: request.method))
        }
    }

    func notify(_ notification: MCPRPCNotification) async throws { notifications.append(notification) }
    func close() async {}
}

private actor FixtureConnection: MCPConnection {
    let identifier: String
    let tools: [MCPToolDescriptor]
    var closed = false
    var callCount = 0

    init(identifier: String, tools: [MCPToolDescriptor]) {
        self.identifier = identifier
        self.tools = tools
    }

    func connect() async throws {}
    func listTools() async throws -> [MCPToolDescriptor] { tools }
    func callTool(name: String, arguments: MCPJSONValue) async throws -> MCPToolResult {
        callCount += 1
        return .init(content: [.init(type: "text", text: name)])
    }
    func listResources() async throws -> [MCPResourceDescriptor] { [] }
    func readResource(uri: String) async throws -> MCPResourceResult { .init(contents: []) }
    func close() async { closed = true }
}

private actor FixtureFactory: MCPConnectionFactory {
    var connections: [String: FixtureConnection] = [:]
    func connection(for config: MCPServerConfig) async throws -> any MCPConnection {
        let connection = FixtureConnection(
            identifier: config.identifier,
            tools: [
                .init(serverIdentifier: config.identifier, name: "enabled", description: "hello", inputSchema: .object([:])),
                .init(serverIdentifier: config.identifier, name: "disabled", description: nil, inputSchema: .object([:])),
            ]
        )
        connections[config.identifier] = connection
        return connection
    }
}

private struct Loader: MCPHTTPDataLoading {
    let handler: @Sendable (URLRequest) throws -> MCPHTTPResponse
    func load(_ request: URLRequest) async throws -> MCPHTTPResponse { try handler(request) }
}

private actor TokenReferences: MCPTokenReferenceStore {
    private var removed: [String] = []
    func remove(reference: String) { removed.append(reference) }
    func values() -> [String] { removed }
}

private actor AuthorizedAccountClient: MCPAccountMutationClient {
    private var calls: [String] = []
    func renameAccount(serverID: String, accountKey: String, newAccountKey: String) { calls.append("rename:\(serverID):\(accountKey):\(newAccountKey)") }
    func removeAccount(serverID: String, accountKey: String) { calls.append("remove:\(serverID):\(accountKey)") }
    func logoutAccount(serverID: String, accountKey: String) { calls.append("logout:\(serverID):\(accountKey)") }
    func recorded() -> [String] { calls }
}

@Suite("MCP core")
struct MCPTests {
    @Test func legacyConfigReconciliationIsMergeOnlyAndMaterializesSlotPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = TokenReferences()
        let managedSlot = try MCPAccountSlot(
            accountKey: "team", displayName: "Managed Account", serverIdentifier: "managed-runtime"
        )
        let managed = try MCPServerDefinition(
            id: "managed", displayName: "Managed", ownership: .team, accounts: [managedSlot]
        )
        let library = MCPAccountLibrary(fileURL: root.appending(path: "accounts.json"), tokenStore: tokens)
        try await library.replace([managed])
        let legacy = try MCPServerConfig(
            identifier: "calendar", displayName: "Calendar Work",
            transport: .streamableHTTP(
                url: URL(string: "https://example.com/mcp")!,
                headerReferences: ["Authorization": "keychain:legacy.calendar"]
            ),
            disabledTools: ["delete"]
        )
        let definitions = try await library.reconcile(existingConfigs: [legacy])
        #expect(definitions.contains(managed))
        let migrated = try #require(definitions.first(where: { $0.id == "calendar" })?.accounts.first)
        #expect(migrated.serverIdentifier == "calendar")
        #expect(migrated.authStatus == .authenticated)
        #expect(migrated.tokenReference == "keychain:legacy.calendar")

        _ = try await library.setPreferences(
            serverID: "calendar", accountKey: "default", enabledTools: ["read"],
            disabledTools: ["delete", "write"], customInstructions: "Use the work calendar only."
        )
        let runtime = try await library.materializeRuntimeConfigs(existingConfigs: [legacy])
        #expect(runtime[0].enabledTools == ["read"])
        #expect(runtime[0].disabledTools == ["delete", "write"])
        #expect(runtime[0].customInstructions == "Use the work calendar only.")
    }

    @Test func twoAccountSlotsKeepDistinctRuntimeIdentifiersAndToolCatalogs() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-isolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MCPAccountLibrary(fileURL: root.appending(path: "accounts.json"), tokenStore: TokenReferences())
        let work = try MCPAccountSlot(accountKey: "work", displayName: "Work", serverIdentifier: "calendar-work", disabledTools: ["disabled"], customInstructions: "Work account")
        let personal = try MCPAccountSlot(accountKey: "personal", displayName: "Personal", serverIdentifier: "calendar-personal", disabledTools: [], customInstructions: "Personal account")
        try await library.replace([try MCPServerDefinition(id: "calendar", displayName: "Calendar", accounts: [work, personal])])
        let transport = MCPTransportConfiguration.streamableHTTP(url: URL(string: "https://example.com/mcp")!, headerReferences: [:])
        let configs = [
            try MCPServerConfig(identifier: "calendar-work", displayName: "base", transport: transport),
            try MCPServerConfig(identifier: "calendar-personal", displayName: "base", transport: transport),
        ]
        let runtime = try await library.materializeRuntimeConfigs(existingConfigs: configs)
        #expect(runtime.map(\.identifier) == ["calendar-personal", "calendar-work"])
        let factory = FixtureFactory()
        let service = MCPService(factory: factory)
        try await service.replaceConfigs(runtime)
        let catalog = await service.catalog()
        #expect(Set(catalog.tools.map(\.serverIdentifier)) == ["calendar-work", "calendar-personal"])
        #expect(!catalog.tools.contains { $0.serverIdentifier == "calendar-work" && $0.name == "disabled" })
        #expect(catalog.tools.contains { $0.serverIdentifier == "calendar-personal" && $0.name == "disabled" })
        #expect(catalog.tools.first { $0.serverIdentifier == "calendar-work" }?.description?.contains("Work account") == true)
    }

    @Test func managedPreferencesAndAuthenticationFailClosedWithoutRemoteAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-managed-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = try MCPAccountSlot(accountKey: "team", displayName: "Team", serverIdentifier: "team-runtime")
        let library = MCPAccountLibrary(fileURL: root.appending(path: "accounts.json"), tokenStore: TokenReferences())
        try await library.replace([try MCPServerDefinition(id: "managed", displayName: "Managed", ownership: .team, accounts: [slot])])
        await #expect(throws: MCPAccountLifecycleError.self) {
            _ = try await library.setPreferences(serverID: "managed", accountKey: "team", enabledTools: nil, disabledTools: [], customInstructions: "override")
        }
        await #expect(throws: MCPAccountLifecycleError.self) {
            _ = try await library.setAuthentication(serverID: "managed", accountKey: "team", status: .authenticated, tokenReference: "keychain:managed")
        }
    }

    @Test func perAccountLifecyclePersistsOnlyReferencesAndCleansTokens() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = TokenReferences()
        let library = MCPAccountLibrary(fileURL: root.appending(path: "accounts.json"), tokenStore: tokens)
        let slot = try MCPAccountSlot(
            accountKey: "work",
            displayName: "Work account",
            serverIdentifier: "calendar-work",
            authStatus: .authenticated,
            tokenReference: "keychain:mcp/calendar/work"
        )
        let definition = try MCPServerDefinition(id: "calendar", displayName: "Calendar", accounts: [slot])
        try await library.replace([definition])
        _ = try await library.setPreferences(serverID: "calendar", accountKey: "work", enabledTools: ["read"], disabledTools: ["delete"], customInstructions: "Use work events")
        _ = try await library.renameAccount(serverID: "calendar", accountKey: "work", newAccountKey: "office", displayName: "Office")
        try await library.logout(serverID: "calendar", accountKey: "office")
        let stored = try await library.list()[0].accounts[0]
        #expect(stored.displayName == "Office")
        #expect(stored.disabledTools == ["delete"])
        #expect(stored.customInstructions == "Use work events")
        #expect(stored.authStatus == .signedOut)
        #expect(stored.tokenReference == nil)
        #expect(await tokens.values() == ["keychain:mcp/calendar/work"])
        let disk = String(decoding: try Data(contentsOf: root.appending(path: "accounts.json")), as: UTF8.self)
        #expect(!disk.contains("access_token"))
    }

    @Test func teamDefinitionsAreReadOnlyWithoutExplicitAuthorizedClient() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-team-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = TokenReferences()
        let slot = try MCPAccountSlot(accountKey: "team", displayName: "Team", serverIdentifier: "managed-team")
        let definition = try MCPServerDefinition(id: "managed", displayName: "Managed", ownership: .team, popularity: 42, accounts: [slot])
        let readOnly = MCPAccountLibrary(fileURL: root.appending(path: "read-only.json"), tokenStore: tokens)
        try await readOnly.replace([definition])
        await #expect(throws: MCPAccountLifecycleError.self) {
            _ = try await readOnly.renameAccount(serverID: "managed", accountKey: "team", newAccountKey: "renamed")
        }

        let client = AuthorizedAccountClient()
        let authorized = MCPAccountLibrary(fileURL: root.appending(path: "authorized.json"), tokenStore: tokens, managedClient: client)
        try await authorized.replace([definition])
        _ = try await authorized.renameAccount(serverID: "managed", accountKey: "team", newAccountKey: "renamed")
        #expect(await client.recorded() == ["rename:managed:team:renamed"])
    }

    @Test func oauthPendingUsesStateCallbackAndPerAccountGenerationFences() async throws {
        let oauth = MCPOAuthPendingCoordinator()
        let callback = URL(string: "http://127.0.0.1:43123/oauth/callback")!
        let first = try await oauth.begin(serverID: "calendar", accountKey: "work", authorizationURL: URL(string: "https://auth.example/authorize")!, callbackURL: callback)
        _ = try await oauth.begin(serverID: "calendar", accountKey: "personal", authorizationURL: URL(string: "https://auth.example/authorize")!, callbackURL: callback)
        try await oauth.validateCompletion(serverID: "calendar", accountKey: "work", state: first.state, callbackURL: callback, generation: first.generation)

        let superseded = try await oauth.begin(serverID: "calendar", accountKey: "work", authorizationURL: URL(string: "https://auth.example/authorize")!, callbackURL: callback)
        await oauth.cancel(serverID: "calendar", accountKey: "work")
        await #expect(throws: MCPOAuthError.self) {
            try await oauth.validateCompletion(serverID: "calendar", accountKey: "work", state: superseded.state, callbackURL: callback, generation: superseded.generation)
        }
        await #expect(throws: MCPOAuthError.self) {
            _ = try await oauth.begin(serverID: "calendar", accountKey: "work", authorizationURL: URL(string: "http://evil.example/authorize")!, callbackURL: callback)
        }
        await #expect(throws: MCPOAuthError.self) {
            _ = try await oauth.begin(serverID: "calendar", accountKey: "work", authorizationURL: URL(string: "https://auth.example/authorize")!, callbackURL: URL(string: "http://evil.example/callback")!)
        }
    }

    @Test func accountAuthenticationReplacementCleansOldReferenceAndLegacyFieldsDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = TokenReferences()
        let file = root.appending(path: "accounts.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = """
        [{"id":"mail","displayName":"Mail","accounts":[{"accountKey":"work","serverIdentifier":"mail-work"}]}]
        """
        try Data(legacy.utf8).write(to: file)
        let library = MCPAccountLibrary(fileURL: file, tokenStore: tokens)
        let decoded = try await library.list()[0].accounts[0]
        #expect(decoded.displayName == "work")
        #expect(decoded.authStatus == .signedOut)
        _ = try await library.setAuthentication(serverID: "mail", accountKey: "work", status: .authenticated, tokenReference: "keychain:mcp/mail/old")
        _ = try await library.setAuthentication(serverID: "mail", accountKey: "work", status: .authenticated, tokenReference: "vault:mcp/mail/new")
        #expect(await tokens.values() == ["keychain:mcp/mail/old"])
        await #expect(throws: MCPError.self) {
            _ = try await library.setAuthentication(serverID: "mail", accountKey: "work", status: .authenticated, tokenReference: nil)
        }
    }

    @Test func renameInvalidatesOAuthWatchesUnderBothAccountKeys() async throws {
        let oauth = MCPOAuthPendingCoordinator()
        let callback = URL(string: "http://localhost:43123/callback")!
        let old = try await oauth.begin(serverID: "mail", accountKey: "old", authorizationURL: URL(string: "https://auth.example/start")!, callbackURL: callback)
        let new = try await oauth.begin(serverID: "mail", accountKey: "new", authorizationURL: URL(string: "https://auth.example/start")!, callbackURL: callback)
        await oauth.accountRenamed(serverID: "mail", oldAccountKey: "old", newAccountKey: "new")
        await #expect(throws: MCPOAuthError.self) {
            try await oauth.validateCompletion(serverID: "mail", accountKey: "old", state: old.state, callbackURL: callback, generation: old.generation)
        }
        await #expect(throws: MCPOAuthError.self) {
            try await oauth.validateCompletion(serverID: "mail", accountKey: "new", state: new.state, callbackURL: callback, generation: new.generation)
        }
    }

    @Test func configurationStoreUpsertRenameAndRemoveAreAtomic() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPConfigurationStore(url: root.appending(path: "servers.json"))
        var first = try MCPServerConfig(
            identifier: "first",
            displayName: "First",
            transport: .streamableHTTP(url: URL(string: "https://example.com/mcp")!, headerReferences: [:])
        )
        let second = try MCPServerConfig(
            identifier: "second",
            displayName: "Second",
            transport: .stdio(executable: "/usr/bin/false", arguments: [], environmentReferences: [:], workingDirectory: nil)
        )
        _ = try await store.upsert(second)
        _ = try await store.upsert(first)
        #expect(try await store.load().map(\.identifier) == ["first", "second"])

        first.displayName = "Renamed"
        first.disabledTools = ["unsafe"]
        _ = try await store.upsert(first)
        let renamed = try await store.load().first { $0.id == first.id }
        #expect(renamed?.displayName == "Renamed")
        #expect(renamed?.disabledTools == ["unsafe"])

        _ = try await store.remove(id: second.id)
        #expect(try await store.load().map(\.identifier) == ["first"])
    }

    @Test func modernAndLegacyLifecycleAndPagination() async throws {
        let modernTransport = ScriptedTransport(modern: true)
        let modern = MCPClient(serverIdentifier: "modern", transport: modernTransport)
        try await modern.connect()
        #expect(await modern.mode == .modern)
        let modernTools = try await modern.listTools()
        #expect(modernTools.map(\.name) == ["echo", "clock"])
        #expect(modernTools[0].annotations?.title?.count == 256)
        #expect(modernTools[0].readOnlyHint)
        #expect(!modernTools[0].destructiveHint)
        #expect(modernTools[0].idempotentHint)
        #expect(!modernTools[0].openWorldHint)

        let legacyTransport = ScriptedTransport(modern: false)
        let legacy = MCPClient(serverIdentifier: "legacy", transport: legacyTransport)
        try await legacy.connect()
        #expect(await legacy.mode == .legacy)
        #expect(await legacyTransport.notifications.contains(where: { $0.method == "notifications/initialized" }))
    }

    @Test func configContainsOnlySecretReferencesAndValidatesSecurity() throws {
        let config = try MCPServerConfig(
            identifier: "My Server",
            displayName: "Example",
            transport: .streamableHTTP(
                url: URL(string: "https://example.com/mcp")!,
                headerReferences: ["Authorization": "keychain:mcp/example"]
            )
        )
        let data = try JSONEncoder().encode(config)
        let encoded = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        #expect(config.identifier == "my-server")
        #expect(decoded == config)
        #expect(!encoded.contains("Bearer secret"))
        #expect(throws: MCPError.self) {
            _ = try MCPServerConfig(identifier: "bad", displayName: "Bad", transport: .streamableHTTP(url: URL(string: "http://example.com/mcp")!, headerReferences: [:]))
        }
        #expect(throws: MCPError.self) {
            _ = try MCPServerConfig(identifier: "credentials", displayName: "Bad", transport: .streamableHTTP(url: URL(string: "https://user@example.com/mcp")!, headerReferences: [:]))
        }
    }

    @Test func HTTPTransportSetsModernHeadersAndRejectsCrossOrigin() async throws {
        let endpoint = URL(string: "https://example.com/mcp")!
        let okLoader = Loader { request in
            #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == MCPProtocol.current)
            #expect(request.value(forHTTPHeaderField: "Mcp-Method") == "tools/list")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            let body = MCPRPCResponse(id: 7, result: .object(["tools": .array([])]))
            return MCPHTTPResponse(
                data: try JSONEncoder().encode(body),
                response: HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            )
        }
        let transport = try MCPHTTPTransport(
            endpoint: endpoint,
            headerReferences: ["Authorization": "ref"],
            secretResolver: { _ in "Bearer fixture" },
            loader: okLoader
        )
        _ = try await transport.request(.init(id: 7, method: "tools/list"), timeout: .seconds(1))

        let badLoader = Loader { _ in
            let body = MCPRPCResponse(id: 8, result: .object([:]))
            return MCPHTTPResponse(
                data: try JSONEncoder().encode(body),
                response: HTTPURLResponse(url: URL(string: "https://evil.example/mcp")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            )
        }
        let unsafe = try MCPHTTPTransport(endpoint: endpoint, loader: badLoader)
        await #expect(throws: MCPError.self) {
            _ = try await unsafe.request(.init(id: 8, method: "ping"), timeout: .seconds(1))
        }
        await #expect(throws: MCPError.self) {
            try await unsafe.notify(.init(method: "notifications/test"))
        }
    }

    @Test func serviceFiltersDisabledToolsAndReconnectsOnConfigChange() async throws {
        let factory = FixtureFactory()
        let service = MCPService(factory: factory)
        let first = try MCPServerConfig(
            identifier: "fixture",
            displayName: "Fixture",
            transport: .stdio(executable: "/usr/bin/false", arguments: [], environmentReferences: [:], workingDirectory: nil),
            disabledTools: ["disabled"]
        )
        try await service.replaceConfigs([first])
        let catalog = await service.catalog()
        #expect(catalog.tools.map(\.name) == ["enabled"])
        #expect(try await service.callTool(server: "fixture", name: "enabled", arguments: .object([:])).content.first?.text == "enabled")
        await #expect(throws: MCPError.self) {
            _ = try await service.callTool(server: "fixture", name: "disabled", arguments: .object([:]))
        }
        let second = try MCPServerConfig(
            identifier: "fixture",
            displayName: "Changed",
            transport: first.transport
        )
        try await service.replaceConfigs([second])
        #expect((await service.catalog()).tools.count == 2)
    }
}
