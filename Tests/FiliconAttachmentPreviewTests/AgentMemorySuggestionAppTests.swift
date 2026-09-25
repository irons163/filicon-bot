import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor MemorySuggestionAppProbe {
    private(set) var requests: [InferenceRequest] = []
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    func record(_ request: InferenceRequest) { requests.append(request) }
    func hold() async {
        entered.continuation.yield(())
        for await _ in release.stream { break }
    }
    func wait() async { for await _ in entered.stream { break } }
    func resume() { release.continuation.finish() }
}

private struct MemorySuggestionAppProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "memory-app-fixture", displayName: "Memory", requiresAPIKey: false)
    let probe: MemorySuggestionAppProbe
    var gated = false
    var malformed = false
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.record(request)
                let extraction = request.messages.first?.text == AgentMemorySuggestionExtractor.instructions
                if !extraction {
                    if request.toolExchanges.isEmpty {
                        do {
                            let call = try NormalizedToolCall(id: "report", name: "SendMessage",
                                argumentsJSON: JSONEncoder().encode(["text": "Understood. I will review the layout."]))
                            continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                            continuation.yield(.toolCallCompleted(call))
                            continuation.yield(.completed(.toolUse))
                        } catch { continuation.finish(throwing: error); return }
                    } else { continuation.yield(.completed(.stop)) }
                    continuation.finish(); return
                }
                if extraction && gated { await probe.hold() }
                let text = extraction
                    ? (malformed ? "Not a valid suggestion response" : #"{"suggestions":[{"fact":"Prefers accessible layouts","evidence":"accessible layouts","tier":"profile"}]}"#)
                    : "Understood. I will review the layout."
                continuation.yield(.textDelta(text)); continuation.yield(.completed(.stop)); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Memory suggestion app integration", .timeLimit(.minutes(1)))
@MainActor struct AgentMemorySuggestionAppTests {
    private struct Fixture {
        let root: URL
        let model: AppModel
        let owner: AgentProfile
        let peer: AgentProfile
        let group: AgentGroup
        let probe = MemorySuggestionAppProbe()
        func enable() async throws {
            let initial = try await model.memorySuggestionSnapshot(agentID: owner.id)
            try await model.setMemorySuggestionsEnabled(true, expected: initial.settings)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "memory-suggestion-app-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let owner = try #require(await model.createAgent(name: "Owner", summary: "", instructions: "", providerID: "memory-app-fixture", modelID: "test"))
        let peer = try #require(await model.createAgent(name: "Peer", summary: "", instructions: "", providerID: "memory-app-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Team", summary: "", memberIDs: [owner.id, peer.id]))
        return .init(root: root, model: model, owner: owner, peer: peer, group: try #require(model.groups.first))
    }

    @Test(arguments: [false, true])
    func groupCompletionProducesOnlyOptedInPrivateReviewCandidates(enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if enabled { try await f.enable() }
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe))
        await f.model.sendGroupMessage(groupID: f.group.id, text: "@Owner I prefer accessible layouts")
        #expect(f.model.errorMessage == nil && f.model.runningGroups.isEmpty && f.model.reviewingMemoryGroups.isEmpty)
        let requests = await f.probe.requests
        let extra = requests.filter { $0.messages.first?.text == AgentMemorySuggestionExtractor.instructions }
        expectNoDifference(extra.count, enabled ? 1 : 0)
        #expect(extra.allSatisfy { $0.tools.isEmpty && $0.toolExchanges.isEmpty && $0.attachmentsByMessageID.isEmpty })
        let history = f.model.groupMessages[f.group.id, default: []]
        expectNoDifference(history.filter { $0.senderID != nil && !$0.text.isEmpty }.map(\.senderID), [f.owner.id])
        #expect(!history.contains { $0.text.contains("suggestions") })
        let snapshot = try await f.model.memorySuggestionSnapshot(agentID: f.owner.id)
        expectNoDifference(snapshot.suggestions.map(\.fact), enabled ? ["Prefers accessible layouts"] : [])
        let facts = try await f.model.savedAgentMemories(agentID: f.owner.id)
        expectNoDifference(facts, [])
        let other = try await f.model.memorySuggestionSnapshot(agentID: f.peer.id)
        #expect(!other.settings.enabled && other.suggestions.isEmpty)
        if enabled {
            let candidate = try #require(snapshot.suggestions.first)
            try await f.model.reviewMemorySuggestion(candidate, accept: true)
            let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
            await restored.reloadWorkspaceData()
            let saved = try await restored.savedAgentMemories(agentID: f.owner.id)
            expectNoDifference(saved.map(\.fact), [candidate.fact]); expectNoDifference(saved.map(\.scope), [.agent])
            let pending = try await restored.memorySuggestionSnapshot(agentID: f.owner.id)
            #expect(pending.settings.enabled && pending.suggestions.isEmpty)
            let shared = try await restored.savedAgentMemories(agentID: f.owner.id, scope: .user)
            expectNoDifference(shared, [])
        }
    }

    @Test(arguments: ["stop", "account", "members", "disable"])
    func lifecycleChangesDiscardLateMaintenanceWithoutRemovingPublishedReply(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.enable()
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe, gated: true))
        let sending = Task { await f.model.sendGroupMessage(groupID: f.group.id, text: "@Owner I prefer accessible layouts") }
        defer { sending.cancel() }
        await f.probe.wait()
        #expect(f.model.runningGroups.contains(f.group.id) && f.model.reviewingMemoryGroups.contains(f.group.id))
        #expect(f.model.groupMessages[f.group.id, default: []].contains { $0.senderID == f.owner.id && !$0.text.isEmpty })
        switch mode {
        case "account": await f.model.cancelAutoReviewApprovals(nextAccountID: "other")
        case "members": await f.model.updateGroupMembers(groupID: f.group.id, memberIDs: [])
        case "disable":
            let current = try await f.model.memorySuggestionSnapshot(agentID: f.owner.id)
            try await f.model.setMemorySuggestionsEnabled(false, expected: current.settings)
        default: await f.model.stopGroup(id: f.group.id)
        }
        await f.probe.resume(); await sending.value
        let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        let current = try await restored.memorySuggestionSnapshot(agentID: f.owner.id)
        expectNoDifference(current.suggestions, [])
        let saved = try await restored.savedAgentMemories(agentID: f.owner.id)
        expectNoDifference(saved, [])
        #expect(f.model.runningGroups.isEmpty && f.model.reviewingMemoryGroups.isEmpty)
        #expect(restored.groupMessages[f.group.id, default: []].contains { $0.senderID == f.owner.id && !$0.text.isEmpty })
    }

    @Test func malformedExtractionDoesNotFailOrRepeatCompletedGroupTurn() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.enable()
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe, malformed: true))
        await f.model.sendGroupMessage(groupID: f.group.id, text: "@Owner I prefer accessible layouts")
        #expect(f.model.errorMessage == nil && f.model.runningGroups.isEmpty && f.model.reviewingMemoryGroups.isEmpty)
        let current = try await f.model.memorySuggestionSnapshot(agentID: f.owner.id)
        expectNoDifference(current.suggestions, [])
        let requests = await f.probe.requests
        expectNoDifference(requests.filter { $0.messages.first?.text == AgentMemorySuggestionExtractor.instructions }.count, 1)
        expectNoDifference(f.model.groupMessages[f.group.id, default: []].filter { $0.senderID != nil && !$0.text.isEmpty }.count, 1)
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func reviewCardAndDisclosureRenderInSevenLanguages(language: String) async throws {
        let candidate = AgentMemorySuggestion(accountID: "local", agentID: UUID(), exchangeID: UUID(),
            fact: "Prefers accessible layouts with clear focus indicators and consistent spacing.",
            evidence: "accessible layouts with clear focus indicators and consistent spacing", tier: .profile)
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                if language != "en" {
                    for key in ["Memory suggestions", "Save as private memory…", "Dismiss suggestion", "Reviewing memory suggestions…", AgentMemorySuggestionsNotice.disclosure] {
                        #expect(FiliconLocalization.string(key) != key)
                    }
                }
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
                    Text(l10n("Memory suggestions")).font(.headline)
                    AgentMemorySuggestionsNotice()
                    AgentMemorySuggestionCard(suggestion: candidate, onSave: {}, onDismiss: {})
                    AgentMemoryReviewProgress()
                }.padding(16).frame(width: 380).background(FiliconTheme.canvas)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                expectNoDifference(size.width, 380)
                #expect(size.height > 250 && size.height < 700)
                host.frame = .init(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "memory-suggestion-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
