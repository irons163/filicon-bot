import Foundation
import XCTest
@testable import FiliconPlugins

final class PluginTests: XCTestCase {
    func testCatalogMetadataIsBackwardCompatibleAndTeamOwnershipIsExplicit() throws {
        let legacy = """
        {"id":"legacy","manifest":{"schemaVersion":1,"id":"legacy","name":"Legacy","displayName":"Legacy","version":"1","description":"","connectors":[],"skills":[],"variables":[]},"ownership":"publicMarketplace","policy":"allowed"}
        """
        let decoded = try JSONDecoder().decode(PluginCatalogEntry.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.popularity, 0)
        XCTAssertEqual(decoded.authorizationState, .notRequired)
        XCTAssertFalse(decoded.publishedByCurrentUser)

        let team = PluginCatalogEntry(
            manifest: .init(id: "team-plugin", name: "Team", version: "1"),
            ownership: .team,
            policy: .required,
            marketplaceID: "market-1",
            teamID: "team-1",
            popularity: 900,
            authorizationState: .required
        )
        XCTAssertTrue(team.isManagedReadOnly)
        XCTAssertTrue(team.requiresAuthentication)
    }

    func testSparseLegacyManifestAndInstalledArrayRemainReadable() async throws {
        let manifestJSON = #"{"id":"legacy","name":"Legacy","version":"1"}"#
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON.utf8))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.displayName, "Legacy")
        XCTAssertEqual(manifest.connectors, [])

        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installedJSON = #"[{"manifest":{"id":"legacy","name":"Legacy","version":"1"},"installPath":"/tmp/legacy","installedAt":1000}]"#
        let file = root.appending(path: "installed.json")
        try Data(installedJSON.utf8).write(to: file)
        let plugins = try await PluginStore(fileURL: file).list()
        XCTAssertEqual(plugins[0].ownership, .user)
        XCTAssertEqual(plugins[0].installedAt, Date(timeIntervalSince1970: 1000))
    }

    func testHiddenSymlinkAndAuthenticationRequiredInstallFailClosed() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appending(path: ".hidden-link"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try PluginSecurity.inspectDirectory(source))

        let manifest = PluginManifest(id: "auth-plugin", name: "Auth", version: "1")
        let installer = PluginInstaller(
            pluginsRoot: root.appending(path: "plugins"),
            store: PluginStore(fileURL: root.appending(path: "installed.json")),
            setupStore: PluginSetupStore(fileURL: root.appending(path: "setup.json"), secrets: InMemoryPluginSecretStore())
        )
        do {
            _ = try await installer.install(entry: .init(manifest: manifest, authorizationState: .required), from: .directory(source))
            XCTFail("Expected authentication requirement")
        } catch let error as PluginError {
            XCTAssertEqual(error, .authenticationRequired)
        }
    }

    func testManagedPolicyNeedsExplicitClientAndFailsClosed() async throws {
        let withoutClient = PluginManagedPolicyService()
        let emptyRules = try await withoutClient.rules()
        XCTAssertEqual(emptyRules, [])
        let client = TestPolicyClient(rules: [.init(pluginID: "required-plugin", teamID: "team-1", policy: .required)])
        let service = PluginManagedPolicyService(authorizedClient: client)
        let required = try await service.effectivePolicy(pluginID: "required-plugin", catalogPolicy: .allowed)
        let allowed = try await service.effectivePolicy(pluginID: "other", catalogPolicy: .allowed)
        XCTAssertEqual(required, .required)
        XCTAssertEqual(allowed, .allowed)
    }

    func testManifestAndPathsRejectTraversalAndDuplicateSkills() throws {
        XCTAssertThrowsError(try PluginSecurity.safeRelativePath("../secret"))
        XCTAssertThrowsError(try PluginSecurity.safeRelativePath("/absolute"))
        let duplicate = PluginManifest(
            id: "demo-plugin",
            name: "Demo",
            version: "1",
            skills: [
                .init(id: "review", name: "Review", relativePath: "skills/review/SKILL.md"),
                .init(id: "review", name: "Review 2", relativePath: "skills/review2/SKILL.md"),
            ]
        )
        XCTAssertThrowsError(try PluginSecurity.validate(duplicate))
    }

    func testContentLimitsEnforceAllSourceBounds() throws {
        XCTAssertThrowsError(try PluginSecurity.validateContentFacts(.init(fileCount: 50_001, expandedBytes: 1)))
        XCTAssertThrowsError(try PluginSecurity.validateContentFacts(.init(fileCount: 1, expandedBytes: 500 * 1_024 * 1_024 + 1)))
        XCTAssertThrowsError(try PluginSecurity.validateContentFacts(.init(fileCount: 1, expandedBytes: 101, compressedBytes: 1)))
        XCTAssertNoThrow(try PluginSecurity.validateContentFacts(.init(fileCount: 50_000, expandedBytes: 500 * 1_024 * 1_024, compressedBytes: 100 * 1_024 * 1_024)))
    }

    func testCatalogFilterAndThirtySecondCache() async throws {
        let clock = TestNow()
        let connector = PluginCatalogEntry(manifest: .init(id: "calendar", name: "Calendar", version: "1", connectors: [.init(name: "calendar")]))
        let skill = PluginCatalogEntry(manifest: .init(id: "review", name: "Review", version: "1", skills: [.init(id: "review", name: "Review", relativePath: "SKILL.md")]), ownership: .team)
        let client = TestCatalogClient(entries: [connector, skill])
        let cache = PluginCatalogCache(client: client, now: { clock.value })
        let first = try await cache.snapshot()
        XCTAssertEqual(first.entries.count, 2)
        _ = try await cache.snapshot()
        var calls = await client.count()
        XCTAssertEqual(calls, 1)
        clock.value = clock.value.addingTimeInterval(31)
        _ = try await cache.snapshot()
        calls = await client.count()
        XCTAssertEqual(calls, 2)
        let filtered = try await cache.filter(.init(type: .skills, ownership: .team, query: "review"), installedIDs: [])
        XCTAssertEqual(filtered.map(\.id), ["review"])
    }

    func testAtomicDirectoryInstallToolToggleAndRecoverableRemoval() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source.appending(path: "skills/review"), withIntermediateDirectories: true)
        let manifest = PluginManifest(
            id: "demo-plugin",
            name: "Demo",
            version: "1",
            connectors: [.init(name: "demo", configurationPath: "mcp.json")],
            skills: [.init(id: "review", name: "Review", relativePath: "skills/review/SKILL.md")]
        )
        try JSONEncoder().encode(manifest).write(to: source.appending(path: "plugin.json"))
        try Data("skill".utf8).write(to: source.appending(path: "skills/review/SKILL.md"))
        try Data("{}".utf8).write(to: source.appending(path: "mcp.json"))
        let store = PluginStore(fileURL: root.appending(path: "installed.json"))
        let setup = PluginSetupStore(fileURL: root.appending(path: "setup.json"), secrets: InMemoryPluginSecretStore())
        let installer = PluginInstaller(pluginsRoot: root.appending(path: "plugins"), store: store, setupStore: setup)
        let installed = try await installer.install(entry: .init(manifest: manifest), from: .directory(source))
        XCTAssertEqual(installed.id, "demo-plugin")
        _ = try await store.setToolDisabled(pluginID: installed.id, toolName: "delete", disabled: true)
        let stored = try await store.plugin(id: installed.id)
        XCTAssertEqual(stored?.disabledToolNames, Set(["delete"]))
        let configurations = try await installer.connectorConfigurations()
        XCTAssertEqual(configurations.first?.data, Data("{}".utf8))
        let recovery = try await installer.uninstall(pluginID: installed.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        let removed = try await store.plugin(id: installed.id)
        XCTAssertNil(removed)
    }

    func testRequiredAndUnknownTeamPoliciesCannotBeRemoved() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(fileURL: root.appending(path: "installed.json"))
        for policy in [PluginInstallPolicy.required, .unknown] {
            let manifest = PluginManifest(id: "policy-\(policy.rawValue)", name: "Policy", version: "1")
            _ = try await store.upsert(.init(manifest: manifest, installPath: root.appending(path: manifest.id).path, ownership: .team, policy: policy))
        }
        let installer = PluginInstaller(
            pluginsRoot: root,
            store: store,
            setupStore: PluginSetupStore(fileURL: root.appending(path: "setup.json"), secrets: InMemoryPluginSecretStore())
        )
        for id in ["policy-required", "policy-unknown"] {
            do { _ = try await installer.uninstall(pluginID: id); XCTFail("Expected policy denial") }
            catch let error as PluginError { XCTAssertEqual(error, .removalDenied) }
        }
    }

    func testSetupSecretsStayOutOfPlaintextStoreAndRequiredFieldsFailClosed() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemoryPluginSecretStore()
        let setup = PluginSetupStore(fileURL: root.appending(path: "setup.json"), secrets: secrets)
        let manifest = PluginManifest(
            id: "auth-plugin", name: "Auth", version: "1",
            variables: [.init(name: "region", required: true), .init(name: "token", kind: .secret, required: true)]
        )
        do { try await setup.save(values: ["region": "us"], for: manifest); XCTFail("Expected missing token") }
        catch let error as PluginError { XCTAssertEqual(error, .missingRequiredVariable("token")) }
        try await setup.save(values: ["region": "us", "token": "very-secret"], for: manifest)
        let disk = String(data: try Data(contentsOf: root.appending(path: "setup.json")), encoding: .utf8)!
        XCTAssertFalse(disk.contains("very-secret"))
        let resolved = try await setup.resolvedValues(for: manifest)
        XCTAssertEqual(resolved, ["region": "us", "token": "very-secret"])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "FiliconPluginsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

private final class TestNow: @unchecked Sendable {
    var value = Date(timeIntervalSince1970: 1_000)
}

private actor TestCatalogClient: PluginCatalogClient {
    let entries: [PluginCatalogEntry]
    private var calls = 0
    init(entries: [PluginCatalogEntry]) { self.entries = entries }
    func fetchCatalog() -> PluginCatalogSnapshot { calls += 1; return .init(entries: entries) }
    func count() -> Int { calls }
}

private struct TestPolicyClient: PluginTeamPolicyClient {
    let rules: [PluginTeamRule]
    func fetchAuthorizedRules() async throws -> [PluginTeamRule] { rules }
}
