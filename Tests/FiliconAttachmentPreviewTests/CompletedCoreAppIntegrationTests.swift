import Foundation
import Testing
@testable import Filicon
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconPersistence
import FiliconRichContent

private actor AppCloudTransportProbe: CloudAgentTransport {
    private(set) var requests: [CloudAgentHTTPRequest] = []
    private var polls = 0

    func send(
        _ request: CloudAgentHTTPRequest, timeout: TimeInterval, maximumResponseBytes: Int
    ) async throws -> CloudAgentHTTPResponse {
        requests.append(request)
        let path = request.url.path
        let run: CloudAgentRemoteRun
        if request.method == .post && path.hasSuffix("/cancel") {
            run = .init(id: "remote-1", agentID: "agent-1", status: .cancelled, revision: 2)
        } else if request.method == .get && path.hasSuffix("/runs/remote-1") {
            polls += 1
            run = .init(id: "remote-1", agentID: "agent-1", status: .running, revision: 1)
        } else {
            run = .init(id: "remote-1", agentID: "agent-1", status: .running, revision: 1)
        }
        return .init(statusCode: 200, body: try JSONEncoder().encode(run))
    }

    func captured() -> [CloudAgentHTTPRequest] { requests }
}

private struct FastCloudSleeper: CloudAgentSleeper {
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .milliseconds(10)) }
}

@Suite("Completed core app wiring")
struct CompletedCoreAppIntegrationTests {
    @Test @MainActor func cloudConfigurationPersistsOnlyKeychainReference() async throws {
        let defaults = UserDefaults.standard
        let oldEndpoint = defaults.object(forKey: "FiliconCloudAgentEndpoint")
        let oldReference = defaults.object(forKey: "FiliconCloudAgentCredentialReference")
        let reference = "integration-\(UUID().uuidString.lowercased())"
        let secret = "bearer-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-cloud-config-\(UUID().uuidString)")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let oldEndpoint { defaults.set(oldEndpoint, forKey: "FiliconCloudAgentEndpoint") }
            else { defaults.removeObject(forKey: "FiliconCloudAgentEndpoint") }
            if let oldReference { defaults.set(oldReference, forKey: "FiliconCloudAgentCredentialReference") }
            else { defaults.removeObject(forKey: "FiliconCloudAgentCredentialReference") }
        }
        await model.configureCloudAgents(
            endpoint: "https://127.0.0.1:9/v1", credentialReference: reference, bearer: secret
        )
        #expect(defaults.string(forKey: "FiliconCloudAgentEndpoint") == "https://127.0.0.1:9/v1")
        #expect(defaults.string(forKey: "FiliconCloudAgentCredentialReference") == reference)
        #expect(!defaults.dictionaryRepresentation().values.contains { ($0 as? String) == secret })
        let ref = CredentialRef(providerID: ProviderID(rawValue: "cloud-agent"), account: reference)
        #expect(try await model.credentials.value(for: ref) == secret)
        try await model.credentials.remove(ref)
    }

    @Test func cloudRuntimeFailsClosedAndNeverUsesProviderRuntime() async throws {
        let backend = CloudAgentBackend(configuration: nil, transport: AppCloudTransportProbe())
        let coordinator = CloudAgentRunCoordinator(backend: backend, agentID: "agent-1", sleeper: FastCloudSleeper())
        let runtime = AppCloudTaskRuntime(runtime: CloudAgentRuntime(coordinator: coordinator), agentID: UUID())
        #expect(runtime.taskKind == .cloud)
        await #expect(throws: CloudAgentError.unconfigured) {
            try await runtime.run(prompt: "remote only", scope: .init())
        }
    }

    @Test func persistedRemoteRunResumesAndCancellationReachesRemote() async throws {
        let agentID = UUID()
        let key = "FiliconCloudAgentRun.\(agentID.uuidString.lowercased())"
        UserDefaults.standard.set("remote-1", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let transport = AppCloudTransportProbe()
        let endpoint = try CloudAgentEndpoint(URL(string: "https://cloud.example.test/v1")!)
        let backend = CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: transport)
        let coordinator = CloudAgentRunCoordinator(
            backend: backend, agentID: "agent-1",
            policy: .init(deadline: 2, initialDelay: 0.01, maximumDelay: 0.01), sleeper: FastCloudSleeper()
        )
        let runtime = AppCloudTaskRuntime(
            runtime: CloudAgentRuntime(coordinator: coordinator, resumeRemoteRunID: "remote-1"), agentID: agentID
        )
        let task = Task { try await runtime.run(prompt: "ignored on resume", scope: SubagentExecutionScope()) }
        for _ in 0..<100 {
            if await transport.captured().contains(where: { $0.method == .get }) { break }
            await Task.yield()
        }
        await runtime.interrupt(reason: "test cancellation")
        _ = try? await task.value
        let requests = await transport.captured()
        #expect(requests.contains { $0.method == .get && $0.url.path.hasSuffix("/runs/remote-1") })
        #expect(requests.contains { $0.method == .post && $0.url.path.hasSuffix("/runs/remote-1/cancel") })
        #expect(UserDefaults.standard.string(forKey: key) == nil)
    }

    @Test func attachmentReferenceIsAddedOnlyAfterMessagePersistenceAndRemovedWithMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-app-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = try AttachmentLifecycle.live(applicationSupportDirectory: root)
        let references = try AttachmentReferenceRepository(databaseURL: root.appending(path: "attachment-index.sqlite"))
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let staged = try await lifecycle.stage(data: Data("bytes".utf8), filename: "note.txt", declaredMIMEType: "text/plain")
        var conversation = Conversation()
        let message = ChatMessage(role: .user, text: "attached", attachments: [staged.metadata])
        conversation.messages = [message]
        try await store.save([conversation])
        let owner = AttachmentReferenceOwner(conversationID: conversation.id, messageID: message.id)
        #expect(try await references.references(owner: owner).isEmpty)
        _ = try await lifecycle.commit(staged, to: owner)
        #expect(try await references.references(owner: owner).map(\.blobID) == [staged.metadata.id])
        conversation.messages = []
        try await store.save([conversation])
        try await lifecycle.removeReferences(owner: owner)
        #expect(try await references.references(owner: owner).isEmpty)
    }

    @Test @MainActor func transcriptUsesSharedProductionControllerAndBareLinksStayBounded() {
        let first = RichMarkdownView.transcript(source: "https://one.example https://two.example https://three.example https://four.example")
        let second = RichMarkdownView.transcript(source: "https://one.example")
        #expect(first.maximumMetadataCards == 3)
        #expect(first.metadataController != nil)
        #expect(second.metadataController != nil)
        #expect(RichMarkdownProjection.make(source: first.source).safeHTTPLinks(maximum: 3).count == 3)
        let excluded = RichMarkdownProjection.make(source: "```\nhttps://code.example\n```\n`https://inline-code.example`\n\\(https://math.example\\)")
        #expect(excluded.safeHTTPLinks(maximum: 3).isEmpty)
    }

    @Test func metadataControllerPropagatesRendererCancellation() async {
        let controller = RichLinkMetadataController { _ in
            try await Task.sleep(for: .seconds(30))
            return .init(url: URL(string: "https://never.example")!, title: "Never")
        }
        let task = Task { try await controller.load(URL(string: "https://cancel.example")!) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
