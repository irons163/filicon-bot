import Foundation
import Testing
@testable import Filicon
import FiliconAppServices
import FiliconDomain
import FiliconMCP

private struct FixedMCPOAuthTransport: MCPOAuthTokenTransport {
    let body: Data

    func exchange(request: URLRequest, expectedEndpoint: URL) async throws -> MCPOAuthHTTPResponse {
        MCPOAuthHTTPResponse(statusCode: 200, finalURL: expectedEndpoint, body: body)
    }
}

private actor MCPAuthorizationURLCapture {
    private var value: URL?

    func set(_ url: URL) { value = url }
    func wait() async throws -> URL {
        for _ in 0..<200 {
            if let value { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ChannelOAuthBrowserError.timedOut
    }
}

@Suite("MCP multi-account app integration")
struct MCPAccountAppIntegrationTests {
    @Test @MainActor func oauthAuthenticatesOnlyTheExactSlotAndDoesNotPersistTokenBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-mcp-oauth-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let accessToken = "oauth-access-secret-\(UUID().uuidString)"
        let refreshToken = "oauth-refresh-secret-\(UUID().uuidString)"
        let response = try JSONSerialization.data(withJSONObject: [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "token_type": "Bearer",
        ])
        let model = AppModel(
            applicationSupportRoot: root,
            bootstrapImmediately: false,
            mcpOAuthTransport: FixedMCPOAuthTransport(body: response),
            mcpOAuthBrowserOpener: { authorizationURL in
                guard let callback = Self.oauthCallback(from: authorizationURL) else { return false }
                Task { _ = try? await URLSession.shared.data(from: callback) }
                return true
            }
        )
        await model.addMCPHTTPServer(identifier: "calendar", displayName: "Calendar", endpoint: "https://example.test/mcp")
        let original = try #require(model.mcpAccountDefinitions.first?.accounts.first)
        await model.addMCPAccount(
            serverID: "calendar", sourceServerIdentifier: original.serverIdentifier,
            accountKey: "work", displayName: "Work"
        )

        await model.authenticateMCPAccountOAuth(
            serverID: "calendar", accountKey: "work",
            authorizationEndpoint: "https://auth.example.test/authorize",
            tokenEndpoint: "https://auth.example.test/token",
            clientID: "public-desktop-client", scopes: "mcp.read mcp.write", audience: "https://example.test"
        )

        let definition = try #require(model.mcpAccountDefinitions.first(where: { $0.id == "calendar" }))
        let work = try #require(definition.accounts.first(where: { $0.accountKey == "work" }))
        let unchanged = try #require(definition.accounts.first(where: { $0.id == original.id }))
        let reference = try #require(work.tokenReference)
        #expect(work.authStatus == .authenticated)
        #expect(unchanged.authStatus == .signedOut)
        #expect(unchanged.tokenReference == nil)
        #expect(try await model.credentials.value(for: CredentialRef(providerID: ProviderID(rawValue: "mcp.\(reference)"))) == "Bearer \(accessToken)")

        for name in ["mcp-accounts.json", "mcp-servers.json"] {
            let bytes = try Data(contentsOf: root.appending(path: name))
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(!text.contains(accessToken))
            #expect(!text.contains(refreshToken))
        }
    }

    @Test @MainActor func oauthStateMismatchFailsAndLateCallbackAfterLogoutCannotCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-mcp-oauth-fence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = try JSONSerialization.data(withJSONObject: [
            "access_token": "must-not-commit", "token_type": "Bearer",
        ])
        let mismatchModel = AppModel(
            applicationSupportRoot: root.appending(path: "mismatch"),
            bootstrapImmediately: false,
            mcpOAuthTransport: FixedMCPOAuthTransport(body: response),
            mcpOAuthBrowserOpener: { authorizationURL in
                guard let callback = Self.oauthCallback(from: authorizationURL, state: "wrong-state") else { return false }
                Task { _ = try? await URLSession.shared.data(from: callback) }
                return true
            }
        )
        await mismatchModel.addMCPHTTPServer(identifier: "mail", displayName: "Mail", endpoint: "https://example.test/mcp")
        await mismatchModel.authenticateMCPAccountOAuth(
            serverID: "mail", accountKey: "default",
            authorizationEndpoint: "https://auth.example.test/authorize",
            tokenEndpoint: "https://auth.example.test/token",
            clientID: "public-client", scopes: "", audience: ""
        )
        #expect(mismatchModel.mcpAccountDefinitions.first?.accounts.first?.authStatus == .failed)
        #expect(mismatchModel.mcpAccountDefinitions.first?.accounts.first?.tokenReference == nil)

        let capture = MCPAuthorizationURLCapture()
        let lateModel = AppModel(
            applicationSupportRoot: root.appending(path: "late"),
            bootstrapImmediately: false,
            mcpOAuthTransport: FixedMCPOAuthTransport(body: response),
            mcpOAuthBrowserOpener: { url in Task { await capture.set(url) }; return true }
        )
        await lateModel.addMCPHTTPServer(identifier: "mail", displayName: "Mail", endpoint: "https://example.test/mcp")
        let authentication = Task { @MainActor in
            await lateModel.authenticateMCPAccountOAuth(
                serverID: "mail", accountKey: "default",
                authorizationEndpoint: "https://auth.example.test/authorize",
                tokenEndpoint: "https://auth.example.test/token",
                clientID: "public-client", scopes: "", audience: ""
            )
        }
        let authorizationURL = try await capture.wait()
        await lateModel.logoutMCPAccount(serverID: "mail", accountKey: "default")
        if let callback = Self.oauthCallback(from: authorizationURL) {
            _ = try? await URLSession.shared.data(from: callback)
        }
        await authentication.value
        let lateSlot = try #require(lateModel.mcpAccountDefinitions.first?.accounts.first)
        #expect(lateSlot.authStatus == .signedOut)
        #expect(lateSlot.tokenReference == nil)
    }

    @Test @MainActor func oauthRejectsInsecureOrInvalidInputWithoutEnteringPendingState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-mcp-oauth-invalid-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = try JSONSerialization.data(withJSONObject: ["access_token": "unused", "token_type": "Bearer"])
        let model = AppModel(
            applicationSupportRoot: root, bootstrapImmediately: false,
            mcpOAuthTransport: FixedMCPOAuthTransport(body: response),
            mcpOAuthBrowserOpener: { _ in false }
        )
        await model.addMCPHTTPServer(identifier: "docs", displayName: "Docs", endpoint: "https://example.test/mcp")
        await model.authenticateMCPAccountOAuth(
            serverID: "docs", accountKey: "default",
            authorizationEndpoint: "http://auth.example.test/authorize",
            tokenEndpoint: "not a URL", clientID: "", scopes: "bad scope", audience: ""
        )
        let slot = try #require(model.mcpAccountDefinitions.first?.accounts.first)
        #expect(slot.authStatus == .signedOut)
        #expect(slot.tokenReference == nil)
        #expect(model.mcpOAuthInProgressSlotIDs.isEmpty)
    }

    @Test @MainActor func appMethodsKeepAccountsRuntimesPreferencesAndTokensIsolated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-mcp-account-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)

        await model.addMCPHTTPServer(
            identifier: "calendar", displayName: "Calendar",
            endpoint: "https://127.0.0.1:9/mcp"
        )
        #expect(model.errorMessage == nil)
        let definition = try #require(model.mcpAccountDefinitions.first(where: { $0.id == "calendar" }))
        let defaultSlot = try #require(definition.accounts.first)

        await model.addMCPAccount(
            serverID: definition.id, sourceServerIdentifier: defaultSlot.serverIdentifier,
            accountKey: "personal", displayName: "Personal Calendar"
        )
        #expect(model.mcpConfigs.count == 2)
        #expect(Set(model.mcpConfigs.map(\.identifier)).count == 2)
        var personal = try #require(model.mcpAccountDefinitions.first(where: { $0.id == "calendar" })?.accounts.first(where: { $0.accountKey == "personal" }))

        await model.authenticateMCPAccount(
            serverID: "calendar", accountKey: "personal", bearerToken: "real-manual-token"
        )
        personal = try #require(model.mcpAccountDefinitions.first(where: { $0.id == "calendar" })?.accounts.first(where: { $0.accountKey == "personal" }))
        let reference = try #require(personal.tokenReference)
        #expect(personal.authStatus == .authenticated)
        #expect(await model.credentials.contains(CredentialRef(providerID: ProviderID(rawValue: "mcp.\(reference)"))))
        #expect(try await model.credentials.value(for: CredentialRef(providerID: ProviderID(rawValue: "mcp.\(reference)"))) == "Bearer real-manual-token")

        await model.saveMCPAccountPreferences(
            serverID: "calendar", accountKey: "personal",
            disabledTools: ["delete"], customInstructions: "Use personal data only."
        )
        let personalConfig = try #require(model.mcpConfigs.first(where: { $0.identifier == personal.serverIdentifier }))
        let defaultConfig = try #require(model.mcpConfigs.first(where: { $0.identifier == defaultSlot.serverIdentifier }))
        #expect(personalConfig.disabledTools == ["delete"])
        #expect(personalConfig.customInstructions == "Use personal data only.")
        #expect(defaultConfig.disabledTools.isEmpty)

        await model.renameMCPAccount(
            serverID: "calendar", accountKey: "personal",
            newAccountKey: "home", displayName: "Home Calendar"
        )
        let renamed = try #require(model.mcpAccountDefinitions.first(where: { $0.id == "calendar" })?.accounts.first(where: { $0.accountKey == "home" }))
        #expect(renamed.serverIdentifier == personal.serverIdentifier)

        await model.logoutMCPAccount(serverID: "calendar", accountKey: "home")
        let loggedOut = try #require(model.mcpAccountDefinitions.first(where: { $0.id == "calendar" })?.accounts.first(where: { $0.accountKey == "home" }))
        #expect(loggedOut.authStatus == .signedOut)
        #expect(loggedOut.tokenReference == nil)
        #expect(!(await model.credentials.contains(CredentialRef(providerID: ProviderID(rawValue: "mcp.\(reference)")))))

        await model.removeMCPAccount(serverID: "calendar", accountKey: "home")
        #expect(model.mcpAccountDefinitions.first(where: { $0.id == "calendar" })?.accounts.map(\.accountKey) == ["default"])
        #expect(model.mcpConfigs.map(\.identifier) == [defaultSlot.serverIdentifier])
    }

    @Test @MainActor func bootstrapReconcilesLegacyConfigWithoutDroppingIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-mcp-migration-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try MCPServerConfig(
            identifier: "legacy", displayName: "Legacy",
            transport: .streamableHTTP(url: URL(string: "https://127.0.0.1:9/mcp")!, headerReferences: [:]),
            enabled: false
        )
        try await MCPConfigurationStore(url: root.appending(path: "mcp-servers.json")).save([config])
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.reloadWorkspaceData()
        #expect(model.mcpConfigs.map(\.identifier) == ["legacy"])
        #expect(model.mcpAccountDefinitions.first(where: { $0.id == "legacy" })?.accounts.first?.serverIdentifier == "legacy")
    }

    private static func oauthCallback(from authorizationURL: URL, state override: String? = nil) -> URL? {
        guard let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems,
              let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
              let state = override ?? items.first(where: { $0.name == "state" })?.value,
              var components = URLComponents(string: redirect) else { return nil }
        components.queryItems = [URLQueryItem(name: "code", value: "integration-code"), URLQueryItem(name: "state", value: state)]
        return components.url
    }
}
