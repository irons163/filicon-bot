import Foundation
import Testing
@testable import Filicon
import FiliconDomain
import FiliconAppServices
import FiliconPersistence
import FiliconProviderKit
import FiliconSettings
import CustomDump

private actor UsageAttributionGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { value in
            if isOpen { value.resume() } else { continuation = value }
        }
    }
    func release() { isOpen = true; continuation?.resume(); continuation = nil }
}

private struct UsageAttributionProvider: AIProvider {
    let gate: UsageAttributionGate
    let fails: Bool
    var descriptor: ProviderDescriptor {
        .init(id: "fake", displayName: "Usage fixture", requiresAPIKey: false, supportsToolCalling: false)
    }
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.usage(.init(inputTokens: 11, outputTokens: 4,
                    cacheReadTokens: 3, cacheWriteTokens: 2, costMicros: 250)))
                continuation.yield(.textDelta("USAGE_RECEIVED"))
                await gate.wait()
                if fails { continuation.finish(throwing: ProviderError.transport("Fixture failure after usage")) }
                else { continuation.yield(.completed(.stop)); continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor ProviderRequestProbe {
    private var requests: [InferenceRequest] = []
    func append(_ request: InferenceRequest) { requests.append(request) }
    func values() -> [InferenceRequest] { requests }
}

private actor AppCatalogProvider: AIProvider, DynamicModelCatalogProviding {
    nonisolated let descriptor: ProviderDescriptor
    private let snapshot: ProviderModelCatalogSnapshot
    nonisolated private let requestProbe: ProviderRequestProbe?
    private var forcedRefreshes = 0

    init(
        id: ProviderID,
        snapshot: ProviderModelCatalogSnapshot,
        requestProbe: ProviderRequestProbe? = nil
    ) {
        descriptor = .init(id: id, displayName: "Catalog test", requiresAPIKey: false)
        self.snapshot = snapshot
        self.requestProbe = requestProbe
    }

    func models() async throws -> [AIModel] { snapshot.models }

    func modelCatalog(forceRefresh: Bool) async -> ProviderModelCatalogSnapshot {
        if forceRefresh { forcedRefreshes += 1 }
        return snapshot
    }

    nonisolated func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        let probe = requestProbe
        return AsyncThrowingStream { continuation in
            Task {
                await probe?.append(request)
                continuation.yield(.responseStarted(id: "catalog-test"))
                continuation.finish(throwing: ProviderError.transport("intentional test failure"))
            }
        }
    }

    func forceRefreshCount() -> Int { forcedRefreshes }
}

@MainActor private func waitUntil(
    attempts: Int = 400,
    _ predicate: @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Suite("Provider catalog app integration", EnglishUITrait())
struct ProviderCatalogAppIntegrationTests {
    @Test func presentationMakesFallbackStalenessCapabilitiesAndErrorsExplicit() {
        let model = AIModel(
            id: "reasoner",
            displayName: "Reasoner",
            capabilities: .init(inputModalities: [.text, .image, .tools], reasoningEfforts: [.disabled, .high]),
            contextWindow: 128_000,
            maximumOutputTokens: 32_000,
            isDeprecated: true
        )
        let label = ProviderCatalogPresentation.modelLabel(model)
        #expect(label.contains("128K context"))
        #expect(label.contains("32K max output"))
        #expect(label.contains("image"))
        #expect(label.contains("tools"))
        #expect(label.contains("deprecated"))
        #expect(ProviderCatalogPresentation.statusLabel(
            source: .dynamic, isStale: false, error: nil
        ) == "Live provider catalog")
        #expect(ProviderCatalogPresentation.statusLabel(
            source: .builtInFallback, isStale: true, error: "offline"
        ) == "Built-in fallback — offline")
    }

    @Test @MainActor func selectedProviderUsageUsesExactAccountAndProviderScope() {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-provider-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let conversation = Conversation(providerID: "openai", modelID: "gpt")
        app.conversations = [conversation]
        app.selection = conversation.id
        app.settings.accountScope = "work"
        app.settings.recordUsage(
            accountID: "work", providerID: "openai",
            increment: .init(requests: 2, inputTokens: 10, outputTokens: 5)
        )
        app.settings.recordUsage(
            accountID: "other", providerID: "openai",
            increment: .init(requests: 99, inputTokens: 99, outputTokens: 99)
        )

        #expect(app.selectedProviderUsage?.requests == 2)
        #expect(app.selectedProviderUsage?.inputTokens == 10)
        #expect(app.selectedProviderUsage?.outputTokens == 5)
    }

    @Test(arguments: ["account", "provider", "both"], [false, true])
    @MainActor func lateTurnUsageKeepsTheRequestAccountAndProvider(change: String, fails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-usage-attribution-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(fileURL: root.appending(path: "settings.json"))
        try await store.save(FiliconSettings(accountScope: "original"))
        let conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000071")!,
            providerID: "fake", modelID: "fixture", updatedAt: Date(timeIntervalSince1970: 1_000))
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).save([conversation])
        let app = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await app.bootstrap()
        app.settings = try await store.update { $0.accountScope = "original" }
        app.conversations = [conversation]
        app.selection = conversation.id
        let gate = UsageAttributionGate()
        await app.registry.register(UsageAttributionProvider(gate: gate, fails: fails))
        let id = try #require(app.selection)
        let index = try #require(app.conversations.firstIndex(where: { $0.id == id }))
        app.conversations[index].providerID = "fake"
        app.conversations[index].modelID = "fixture"
        await app.refreshModels()
        app.draft = "Isolated usage fixture"
        app.send()
        let received = await waitUntil {
            app.conversations.first(where: { $0.id == id })?.messages.contains(where: {
                $0.role == .assistant && $0.text == "USAGE_RECEIVED"
            }) == true
        }
        guard received else {
            await gate.release()
            Issue.record("The fixture never delivered usage: \(app.errorMessage ?? "no error")")
            return
        }

        // The request has already incurred usage. A later UI/settings change
        // cannot change which account and provider owned that request.
        if change != "provider" {
            app.settings = try await store.update { $0.accountScope = "other" }
        }
        if change != "account" { app.conversations[index].providerID = "other-provider" }
        // This pending UI preference is independent of the usage writer.
        app.settings.theme = .dark
        await gate.release()
        #expect(await waitUntil { !app.running.contains(id) })
        #expect(await waitUntil { !app.settings.usageByAccount.isEmpty })
        let saved = try await store.load()
        let expected: [String: AccountUsageCounters] = ["original": .init(providers: ["fake": .init(
            requests: 1, inputTokens: 11, outputTokens: 4,
            cacheReadTokens: 3, cacheWriteTokens: 2, costMicros: 250)])]
        expectNoDifference(saved.usageByAccount, expected)
        expectNoDifference(app.settings.usageByAccount, expected)
        #expect(saved.accountScope == (change == "provider" ? "original" : "other"))
        #expect(app.settings.accountScope == saved.accountScope)
        #expect(app.settings.theme == .dark)
        #expect(saved.theme == .system)
        if change != "provider" { #expect(app.selectedProviderUsage == nil) }
    }

    @Test @MainActor func refreshUsesRegistrySnapshotForceRefreshAndNeverReplacesRemovedModel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-provider-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let provider = AppCatalogProvider(
            id: "catalog-test",
            snapshot: .init(
                models: [.init(id: "available", displayName: "Available")],
                source: .builtInFallback,
                isStale: true,
                errorDescription: "offline"
            )
        )
        await app.registry.register(provider)
        let conversation = Conversation(providerID: "catalog-test", modelID: "removed", reasoningEffort: .disabled)
        app.conversations = [conversation]
        app.selection = conversation.id

        await app.refreshModels(forceRefresh: true)

        #expect(app.availableModels.map(\.id) == ["available"])
        #expect(app.selectedConversation?.modelID == "removed")
        #expect(app.modelCatalogSource == .builtInFallback)
        #expect(app.isModelCatalogStale)
        #expect(app.modelCatalogError == "offline")
        #expect(app.modelCatalogLastUpdated != nil)
        #expect(app.modelCatalogProviderID == "catalog-test")
        #expect(app.modelCatalogConversationID == conversation.id)
        #expect(await provider.forceRefreshCount() == 1)
        #expect(app.selectedConversationConfigurationError?.contains("not available") == true)
    }

    @Test @MainActor func unsupportedEffortResetsDisabledAndPersistsAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-provider-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let provider = AppCatalogProvider(
            id: "catalog-test",
            snapshot: .init(models: [.init(id: "plain")], source: .dynamic)
        )
        await app.registry.register(provider)
        let conversation = Conversation(providerID: "catalog-test", modelID: "plain", reasoningEffort: .high)
        app.conversations = [conversation]
        app.selection = conversation.id

        await app.refreshModels()
        #expect(app.selectedConversation?.reasoningEffort == .disabled)

        let stored = try await ConversationStore(fileURL: root.appending(path: "conversations.json")).load()
        #expect(stored.first(where: { $0.id == conversation.id })?.reasoningEffort == .disabled)
    }

    @Test @MainActor func sendAndResendPropagateEffortAndUnsupportedConfigurationCannotSend() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-provider-send-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)

        await app.bootstrap()
        let unsupportedID = try #require(app.selection)
        let unsupportedIndex = try #require(app.conversations.firstIndex(where: { $0.id == unsupportedID }))
        app.conversations[unsupportedIndex].providerID = "missing"
        app.conversations[unsupportedIndex].modelID = "removed"
        app.conversations[unsupportedIndex].reasoningEffort = .high
        await app.refreshModels()
        app.draft = "must stay"
        app.send()
        #expect(app.draft == "must stay")
        #expect(app.conversations[unsupportedIndex].messages.isEmpty)
        #expect(app.errorMessage?.contains("not available") == true || app.errorMessage?.contains("unavailable") == true)

        let probe = ProviderRequestProbe()
        let provider = AppCatalogProvider(
            id: "fake",
            snapshot: .init(models: [
                .init(id: "reasoner", capabilities: .init(reasoningEfforts: [.disabled, .high]))
            ], source: .dynamic),
            requestProbe: probe
        )
        await app.registry.register(provider)
        let conversationID = try #require(app.selection)
        let index = try #require(app.conversations.firstIndex(where: { $0.id == conversationID }))
        app.conversations[index].providerID = "fake"
        app.conversations[index].modelID = "reasoner"
        app.conversations[index].reasoningEffort = .high
        await app.refreshModels()
        app.draft = "send"
        app.send()
        #expect(await waitUntil { await probe.values().count == 1 })
        #expect(await probe.values().first?.reasoningEffort == .high)

        #expect(await waitUntil { !app.running.contains(conversationID) })
        let failed = try #require(app.conversations[index].messages.last(where: {
            $0.role == .assistant && $0.deliveryStatus == .failed
        }))
        app.resend(messageID: failed.id)
        #expect(await waitUntil { await probe.values().count == 2 })
        #expect(await probe.values().last?.reasoningEffort == .high)
    }
}
