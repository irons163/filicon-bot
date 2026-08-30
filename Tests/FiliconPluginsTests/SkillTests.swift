import Foundation
import XCTest
@testable import FiliconPlugins

final class SkillTests: XCTestCase {
    func testDeterministicArchiveIsStableAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconArchive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "references"), withIntermediateDirectories: true)
        try Data("body".utf8).write(to: root.appending(path: "SKILL.md"))
        try Data("reference".utf8).write(to: root.appending(path: "references/a.txt"))
        let archiver = DeterministicSkillArchive()
        let first = try archiver.encode(directory: root)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: root.appending(path: "SKILL.md").path)
        XCTAssertEqual(first, try archiver.encode(directory: root))
        XCTAssertEqual(String(data: first.prefix(100).prefix { $0 != 0 }, encoding: .utf8), "SKILL.md")

        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "SKILL.md"))
        XCTAssertThrowsError(try archiver.encode(directory: root)) { error in
            guard case SkillPublishingBackendError.unsafeSkill = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testHTTPSBackendValidatesConfigurationAndUsesBoundedAuthenticatedRequests() async throws {
        XCTAssertThrowsError(try HTTPSSkillPublishingBackend(endpoint: URL(string: "http://example.com")!, bearerToken: "token"))
        XCTAssertThrowsError(try HTTPSSkillPublishingBackend(endpoint: URL(string: "https://user@example.com")!, bearerToken: "token"))
        XCTAssertTrue(SkillPublishingURLPolicy.permitsRedirect(from: URL(string: "https://market.example/api")!, to: URL(string: "https://market.example/v2")!))
        XCTAssertFalse(SkillPublishingURLPolicy.permitsRedirect(from: URL(string: "https://market.example/api")!, to: URL(string: "https://evil.example/v2")!))
        XCTAssertFalse(SkillPublishingURLPolicy.permitsRedirect(from: URL(string: "https://market.example/api")!, to: URL(string: "http://market.example/v2")!))
        let transport = RecordingPublishingTransport(responses: [
            (200, #"{"targets":[{"id":"team","name":"Team","kind":"team","authorizationState":"authorized"}]}"#),
            (200, #"{"pluginID":"plugin","version":"v1"}"#),
            (204, "")
        ])
        let backend = try HTTPSSkillPublishingBackend(endpoint: URL(string: "https://market.example/api")!, bearerToken: "secret", transport: transport)
        let targets = try await backend.listTargets()
        XCTAssertEqual(targets.map(\.id), ["team"])
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconBackend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: root.appending(path: "SKILL.md"))
        let receipt = try await backend.publish(skillDirectory: root, name: "Skill", description: "Description", targetID: "team", existingPluginID: nil)
        XCTAssertEqual(receipt, .init(pluginID: "plugin", version: "v1"))
        try await backend.unpublish(pluginID: "plugin", targetID: "team")
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/targets", "/api/skills/publish", "/api/skills/unpublish"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
        let maximums = await transport.maximums()
        XCTAssertTrue(maximums.allSatisfy { $0 == skillPublishingResponseMaximumBytes })
    }

    func testInterruptedPublicationRecoveryFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let publicationStore = SkillPublicationStore(fileURL: root.appending(path: "publication.json"))
        try await publicationStore.set(.init(skillID: "review", pluginID: "plugin", targetID: "team", phase: .unpublishing))
        let service = SkillPublishService(
            backend: TestSkillBackend(receipt: .init(pluginID: "plugin", version: "1")),
            index: PluginSkillIndexService(pluginStore: PluginStore(fileURL: root.appending(path: "plugins.json")), cacheURL: root.appending(path: "index.json")),
            library: PrivateSkillLibrary(root: root.appending(path: "private")),
            publicationStore: publicationStore
        )
        let recovered = try await service.recoverInterruptedOperations()
        XCTAssertEqual(recovered.first?.phase, .failed)
        XCTAssertTrue(recovered.first?.errorMessage?.contains("interrupted") == true)
    }

    func testPrivateSkillLibraryPublishingBridgeKeepsSourceForRemoteResyncAndUnpublish() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconPrivateBridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PrivateSkillLibrary(root: root.appending(path: "private"))
        _ = try await library.create(id: "review", name: "Review", description: "Reviews code", body: "Review")
        let publications = SkillPublicationStore(fileURL: root.appending(path: "publications.json"))
        let backend = RemoteSkillBackend()
        let service = SkillPublishService(
            backend: backend,
            index: PluginSkillIndexService(pluginStore: PluginStore(fileURL: root.appending(path: "plugins.json")), cacheURL: root.appending(path: "index.json")),
            library: library,
            publicationStore: publications
        )
        _ = try await service.publish(localSkillID: "review", name: "Review", description: "Reviews code", targetID: "team")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "private/review/SKILL.md").path))
        let publishedState = try await publications.state(skillID: "review")
        XCTAssertEqual(publishedState?.pluginID, "remote-plugin")
        _ = try await service.resyncPublication(localSkillID: "review", name: "Review", description: "Reviews code")
        let existingPluginIDs = await backend.existingPluginIDs()
        XCTAssertEqual(existingPluginIDs, [nil, "remote-plugin"])
        try await service.unpublishPublication(localSkillID: "review")
        let finalState = try await publications.state(skillID: "review")
        XCTAssertNil(finalState)
        let unpublishCalls = await backend.unpublishCalls()
        XCTAssertEqual(unpublishCalls, ["remote-plugin:team"])
    }
    func testPrivateSkillCRUDImportExportAndPathSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconPrivateSkills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PrivateSkillLibrary(root: root.appending(path: "library"))
        _ = try await library.create(id: "code-review", name: "Code Review", description: "Reviews", body: "Review carefully.")
        let document = try await library.read(id: "code-review")
        XCTAssertEqual(document.record.name, "Code Review")
        XCTAssertEqual(document.record.description, "Reviews")
        XCTAssertEqual(document.body, "Review carefully.")
        _ = try await library.update(id: "code-review", name: "Code Review", description: "Reviews safely", body: "Never expose secrets.")
        var listed = try await library.list().map(\.id)
        XCTAssertEqual(listed, ["code-review"])
        let exported = try await library.exportSkill(id: "code-review", to: root.appending(path: "exports"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appending(path: "SKILL.md").path))
        _ = try await library.importSkill(id: "imported-review", from: .directory(exported))
        listed = try await library.list().map(\.id)
        XCTAssertEqual(listed, ["code-review", "imported-review"])
        do { _ = try await library.importSkill(id: "../escape", from: .directory(exported)); XCTFail("Expected unsafe id rejection") }
        catch let error as PluginError { XCTAssertEqual(error, .invalidIdentifier("../escape")) }
        try await library.remove(id: "code-review")
        listed = try await library.list().map(\.id)
        XCTAssertEqual(listed, ["imported-review"])
    }

    func testPublishingRequiresKnownAuthorizedTargetAndPersistsFailureState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconPublishAuth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(fileURL: root.appending(path: "plugins.json"))
        let index = PluginSkillIndexService(pluginStore: store, cacheURL: root.appending(path: "index.json"))
        let library = LocalSkillLibrary(root: root.appending(path: "skills"))
        _ = try await library.create(id: "private-skill", name: "Private", description: "Private", body: "Body")
        let publicationStore = SkillPublicationStore(fileURL: root.appending(path: "publication.json"))
        let backend = TestSkillBackend(
            receipt: .init(pluginID: "never", version: "1"),
            targets: [.init(id: "team-1", name: "Team", authorizationState: .required)]
        )
        let service = SkillPublishService(backend: backend, index: index, library: library, publicationStore: publicationStore)
        do { _ = try await service.publish(localSkillID: "private-skill", name: "Private", description: "Private", targetID: "team-1"); XCTFail("Expected auth rejection") }
        catch let error as SkillPublishError { XCTAssertEqual(error, .authenticationRequired) }
        do { _ = try await service.publish(localSkillID: "private-skill", name: "Private", description: "Private", targetID: "unknown"); XCTFail("Expected target rejection") }
        catch let error as SkillPublishError { XCTAssertEqual(error, .invalidTarget) }
        let state = try await publicationStore.state(skillID: "private-skill")
        XCTAssertNil(state)
    }

    func testIndexPublishConfirmationAndUnpublishRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconSkillTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let install = root.appending(path: "plugins/demo")
        try FileManager.default.createDirectory(at: install.appending(path: "skills/published-review"), withIntermediateDirectories: true)
        try Data("---\nname: Review\ndescription: Reviews code\n---\n".utf8)
            .write(to: install.appending(path: "skills/published-review/SKILL.md"))
        let manifest = PluginManifest(
            id: "demo-plugin", name: "Demo", version: "commit-1",
            skills: [.init(id: "published-review", name: "Review", description: "Reviews code", relativePath: "skills/published-review/SKILL.md")]
        )
        let store = PluginStore(fileURL: root.appending(path: "installed.json"))
        _ = try await store.upsert(.init(manifest: manifest, installPath: install.path, ownership: .team, policy: .allowed))
        let index = PluginSkillIndexService(pluginStore: store, cacheURL: root.appending(path: "skill-index.json"))
        let library = LocalSkillLibrary(root: root.appending(path: "local-skills"))
        _ = try await library.create(id: "local-review", name: "Local Review", description: "Reviews code", body: "Review this.")
        let backend = TestSkillBackend(receipt: .init(pluginID: "demo-plugin", version: "commit-1"))
        let service = SkillPublishService(backend: backend, index: index, library: library)

        let targets = try await service.listTargets()
        XCTAssertEqual(targets, [.init(id: "team-1", name: "Team")])
        let receipt = try await service.publish(localSkillID: "local-review", name: "Local Review", description: "Reviews code", targetID: "team-1")
        XCTAssertEqual(receipt.pluginID, "demo-plugin")
        let publishedDirectories = await backend.publishedDirectories()
        XCTAssertEqual(publishedDirectories, [root.appending(path: "local-skills/local-review").path])
        let localAfterPublish = try await library.directory(id: "local-review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: localAfterPublish.path))

        let restoredID = try await service.unpublish(skillID: "published-review")
        XCTAssertEqual(restoredID, "published-review")
        let restored = try await library.directory(id: restoredID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appending(path: "SKILL.md").path))
        let calls = await backend.unpublishCalls()
        XCTAssertEqual(calls, ["demo-plugin:team-1"])
    }

    func testIndexAcceptsSkillDirectoryAndSkipsDirectoryWithoutSkillFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconSkillTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let install = root.appending(path: "plugins/demo")
        let validDirectory = install.appending(path: "skills/directory-skill")
        try FileManager.default.createDirectory(at: validDirectory, withIntermediateDirectories: true)
        try Data("---\nname: Directory\n---\nBody\n".utf8)
            .write(to: validDirectory.appending(path: "SKILL.md"))
        try FileManager.default.createDirectory(at: install.appending(path: "skills/not-a-skill"), withIntermediateDirectories: true)

        let manifest = PluginManifest(
            id: "demo-plugin", name: "Demo", version: "1",
            skills: [
                .init(id: "directory-skill", name: "Directory", relativePath: "skills/directory-skill"),
                .init(id: "not-a-skill", name: "Missing", relativePath: "skills/not-a-skill"),
                .init(id: "missing-file", name: "Missing file", relativePath: "skills/missing/SKILL.md")
            ]
        )
        let store = PluginStore(fileURL: root.appending(path: "installed.json"))
        _ = try await store.upsert(.init(manifest: manifest, installPath: install.path, ownership: .team, policy: .allowed))
        let index = PluginSkillIndexService(pluginStore: store, cacheURL: root.appending(path: "skill-index.json"))

        let snapshot = try await index.sync()
        XCTAssertEqual(snapshot.skills.map(\.id), ["directory-skill"])
        XCTAssertEqual(snapshot.skills[0].relativePath, "skills/directory-skill")
        XCTAssertEqual(snapshot.skills[0].filePath, validDirectory.appending(path: "SKILL.md").path)
    }

    func testResyncAndUnpublishResolveIndexedDirectoryPath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconSkillTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installDirectory = root.appending(path: "plugins/demo/skills/directory-skill")
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try Data("skill body\n".utf8).write(to: installDirectory.appending(path: "SKILL.md"))
        let store = PluginStore(fileURL: root.appending(path: "installed.json"))
        let backend = TestSkillBackend(receipt: .init(pluginID: "demo-plugin", version: "2"))
        let library = LocalSkillLibrary(root: root.appending(path: "local-skills"))
        let record = IndexedPluginSkill(
            id: "directory-skill", pluginID: "demo-plugin", pluginName: "Demo", pluginVersion: "1",
            name: "Directory", description: "A directory skill", filePath: installDirectory.path,
            installPath: root.appending(path: "plugins/demo").path, relativePath: "skills/directory-skill",
            publishedByCurrentUser: true, marketplaceTeamID: "team-1"
        )

        let resyncIndexURL = root.appending(path: "resync-index.json")
        try writeIndex(.init(skills: [record]), to: resyncIndexURL)
        let resyncIndex = PluginSkillIndexService(pluginStore: store, cacheURL: resyncIndexURL)
        let resyncService = SkillPublishService(backend: backend, index: resyncIndex, library: library)
        _ = try await resyncService.resync(skillID: record.id)
        let publishedDirectories = await backend.publishedDirectories()
        XCTAssertEqual(publishedDirectories, [installDirectory.path])

        let unpublishIndexURL = root.appending(path: "unpublish-index.json")
        try writeIndex(.init(skills: [record]), to: unpublishIndexURL)
        let unpublishIndex = PluginSkillIndexService(pluginStore: store, cacheURL: unpublishIndexURL)
        let unpublishService = SkillPublishService(backend: backend, index: unpublishIndex, library: library)
        let restoredID = try await unpublishService.unpublish(skillID: record.id)
        XCTAssertEqual(restoredID, record.id)
        let restored = try await library.directory(id: record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appending(path: "SKILL.md").path))
    }

    func testResyncRejectsSkillNotPublishedByCurrentUser() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconSkillTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let install = root.appending(path: "plugin")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: install.appending(path: "SKILL.md"))
        let manifest = PluginManifest(id: "foreign-plugin", name: "Foreign", version: "1", skills: [.init(id: "foreign-skill", name: "Foreign", relativePath: "SKILL.md")])
        let store = PluginStore(fileURL: root.appending(path: "installed.json"))
        _ = try await store.upsert(.init(manifest: manifest, installPath: install.path, ownership: .team, policy: .allowed))
        let index = PluginSkillIndexService(pluginStore: store, cacheURL: root.appending(path: "index.json"))
        _ = try await index.sync()
        let service = SkillPublishService(
            backend: TestSkillBackend(receipt: .init(pluginID: "foreign-plugin", version: "1")),
            index: index,
            library: LocalSkillLibrary(root: root.appending(path: "skills"))
        )
        do { _ = try await service.resync(skillID: "foreign-skill"); XCTFail("Expected ownership failure") }
        catch let error as SkillPublishError { XCTAssertEqual(error, .notOwnedByCurrentUser) }
    }

    func testUnpublishDoesNotDeleteCollidingPrivateSkill() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconCollision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let published = root.appending(path: "plugin/skills/review")
        try FileManager.default.createDirectory(at: published, withIntermediateDirectories: true)
        try Data("published".utf8).write(to: published.appending(path: "SKILL.md"))
        let library = LocalSkillLibrary(root: root.appending(path: "private"))
        _ = try await library.create(id: "review", name: "Private", description: "Local", body: "keep me")
        let store = PluginStore(fileURL: root.appending(path: "installed.json"))
        let cache = root.appending(path: "index.json")
        try writeIndex(.init(skills: [.init(
            id: "review", pluginID: "plugin", pluginName: "Plugin", pluginVersion: "1", name: "Review",
            description: "Review", filePath: published.appending(path: "SKILL.md").path,
            installPath: root.appending(path: "plugin").path, relativePath: "skills/review",
            publishedByCurrentUser: true, marketplaceTeamID: "team-1"
        )]), to: cache)
        let backend = TestSkillBackend(receipt: .init(pluginID: "plugin", version: "1"))
        let service = SkillPublishService(backend: backend, index: PluginSkillIndexService(pluginStore: store, cacheURL: cache), library: library)
        do { _ = try await service.unpublish(skillID: "review"); XCTFail("Expected collision") }
        catch { }
        let unpublishCalls = await backend.unpublishCalls()
        XCTAssertEqual(unpublishCalls, [])
        let contents = try String(contentsOf: root.appending(path: "private/review/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(contents.contains("keep me"))
    }
}

private actor RecordingPublishingTransport: SkillPublishingHTTPTransport {
    private var queued: [(Int, String)]
    private var recorded: [URLRequest] = []
    private var limits: [Int] = []
    init(responses: [(Int, String)]) { queued = responses }
    func send(_ request: URLRequest, maximumResponseBytes: Int) throws -> (Data, HTTPURLResponse) {
        recorded.append(request); limits.append(maximumResponseBytes)
        let next = queued.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(next.1.utf8), response)
    }
    func requests() -> [URLRequest] { recorded }
    func maximums() -> [Int] { limits }
}

private actor RemoteSkillBackend: SkillPublishingBackend {
    nonisolated var requiresLocalInstallationConfirmation: Bool { false }
    private var existing: [String?] = []
    private var unpublished: [String] = []
    func listTargets() -> [SkillPublishTarget] { [.init(id: "team", name: "Team")] }
    func publish(skillDirectory: URL, name: String, description: String, targetID: String, existingPluginID: String?) -> PublishedSkillReceipt {
        existing.append(existingPluginID)
        return .init(pluginID: "remote-plugin", version: "v\(existing.count)")
    }
    func unpublish(pluginID: String, targetID: String) { unpublished.append("\(pluginID):\(targetID)") }
    func existingPluginIDs() -> [String?] { existing }
    func unpublishCalls() -> [String] { unpublished }
}


private actor TestSkillBackend: SkillPublishingBackend {
    let receipt: PublishedSkillReceipt
    let targets: [SkillPublishTarget]
    private var published: [String] = []
    private var unpublished: [String] = []
    init(receipt: PublishedSkillReceipt, targets: [SkillPublishTarget] = [.init(id: "team-1", name: "Team")]) { self.receipt = receipt; self.targets = targets }
    func listTargets() -> [SkillPublishTarget] { targets }
    func publish(skillDirectory: URL, name: String, description: String, targetID: String, existingPluginID: String?) -> PublishedSkillReceipt {
        published.append(skillDirectory.path)
        return receipt
    }
    func unpublish(pluginID: String, targetID: String) { unpublished.append("\(pluginID):\(targetID)") }
    func publishedDirectories() -> [String] { published }
    func unpublishCalls() -> [String] { unpublished }
}

private func writeIndex(_ index: PluginSkillIndex, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(index).write(to: url, options: .atomic)
}
