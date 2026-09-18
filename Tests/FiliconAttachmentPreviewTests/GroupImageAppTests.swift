import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor GroupImageGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        guard !released else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor GroupImageProbe {
    private(set) var requests: [InferenceRequest] = []
    func record(_ request: InferenceRequest) { requests.append(request) }
}

private struct GroupImageProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "group-image-fixture", displayName: "Group images", requiresAPIKey: false, supportsToolCalling: false)
    var gate: GroupImageGate?
    let probe: GroupImageProbe
    func models() async throws -> [AIModel] {
        await gate?.wait()
        return [.init(id: "vision", capabilities: .init(inputModalities: [.text, .image])), .init(id: "text")]
    }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.record(request)
                continuation.yield(.textDelta("PASS"))
                continuation.yield(.completed(.stop)); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Group image composer and delivery", .timeLimit(.minutes(1)))
@MainActor struct GroupImageAppTests {
    private struct Fixture {
        let root: URL
        let model: AppModel
        let group: AgentGroup
        let engineer: AgentProfile
        let designer: AgentProfile
        let images: [AttachmentMetadata]
        let bytes: Data
        let probe: GroupImageProbe
    }
    private func fixture(textOnlyDesigner: Bool = false, gate: GroupImageGate? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-image-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let engineer = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "", providerID: "group-image-fixture", modelID: "vision"))
        let designer = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "group-image-fixture", modelID: textOnlyDesigner ? "text" : "vision"))
        #expect(await model.createGroup(name: "Image review", summary: "", memberIDs: [engineer.id, designer.id]))
        let group = try #require(model.groups.first)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let blue = NSColor(deviceRed: 0.2, green: 0.45, blue: 0.85, alpha: 1)
        let yellow = NSColor(deviceRed: 0.95, green: 0.78, blue: 0.3, alpha: 1)
        for y in 0..<12 { for x in 0..<24 { bitmap.setColor(x < 12 ? blue : yellow, atX: x, y: y) } }
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let file = root.appending(path: "layout.png")
        try bytes.write(to: file)
        let images = try await model.importAgentMessageImages([file])
        let probe = GroupImageProbe()
        await model.registry.register(GroupImageProvider(gate: gate, probe: probe))
        return .init(root: root, model: model, group: group, engineer: engineer, designer: designer, images: images, bytes: bytes, probe: probe)
    }

    @Test(arguments: ["", "Review this layout", "@Engineer review", "@everyone review"])
    func sendsActualBytesToRequestedMembersAndPersists(text: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var posted = 0
        await f.model.sendGroupMessage(groupID: f.group.id, text: text, images: f.images) { posted += 1 }
        expectNoDifference(posted, 1)
        let user = try #require(f.model.groupMessages[f.group.id]?.first)
        expectNoDifference(user.images, f.images)
        expectNoDifference(user.text, text)
        let requests = await f.probe.requests
        expectNoDifference(requests.count, text.hasPrefix("@Engineer") ? 1 : 2)
        for request in requests {
            expectNoDifference(request.messages.last?.id, user.id)
            expectNoDifference(request.messages.last?.attachments, f.images)
            expectNoDifference(request.attachmentsByMessageID.keys.sorted(), [user.id])
            expectNoDifference(request.attachmentsByMessageID[user.id]?.map(\.data), [f.bytes])
            expectNoDifference(request.attachmentsByMessageID[user.id]?.map(\.metadata), f.images)
        }
        if text.hasPrefix("@Engineer") { #expect(requests.allSatisfy { $0.messages[0].text.contains(f.engineer.id.uuidString) }) }
        let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.groupMessages[f.group.id]?.first?.images?.map(\.id), f.images.map(\.id))
        let restoredBytes = try await restored.agentMessageImageData(f.images[0])
        expectNoDifference(restoredBytes, f.bytes)
        #expect(f.model.runningGroups.isEmpty)
    }

    @Test func followupDoesNotReloadHistoricalImages() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.sendGroupMessage(groupID: f.group.id, text: "@Engineer review", images: f.images)
        await f.model.sendGroupMessage(groupID: f.group.id, text: "@Designer summarize")
        let requests = await f.probe.requests
        expectNoDifference(requests.count, 2)
        #expect(requests[1].attachmentsByMessageID.isEmpty)
        #expect(requests[1].messages.allSatisfy { $0.attachments.isEmpty })
        #expect(requests[1].messages.contains { $0.text.contains("\"omittedImageCount\":1") })
    }

    @Test func unsupportedMemberFailsBeforePostingButUnaddressedMemberDoesNotBlock() async throws {
        let f = try await fixture(textOnlyDesigner: true); defer { try? FileManager.default.removeItem(at: f.root) }
        var posted = false
        await f.model.sendGroupMessage(groupID: f.group.id, text: "Review", images: f.images) { posted = true }
        #expect(!posted)
        #expect(f.model.errorMessage?.contains(f.designer.name) == true)
        expectNoDifference(f.model.groupMessages[f.group.id] ?? [], [])
        let rejectedCount = await f.probe.requests.count
        expectNoDifference(rejectedCount, 0)
        await f.model.sendGroupMessage(groupID: f.group.id, text: "@Engineer review", images: f.images) { posted = true }
        #expect(posted)
        let acceptedCount = await f.probe.requests.count
        expectNoDifference(acceptedCount, 1)
    }

    @Test(arguments: ["unknown", "duplicate", "missing", "corrupt", "long"])
    func invalidInputPreservesDraftAndDoesNotPost(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = f.images[0]
        let blob = f.root.appending(path: "agent-message-images/\(image.id.prefix(2))/\(image.id)")
        if mode == "missing" { try FileManager.default.removeItem(at: blob) }
        if mode == "corrupt" { try Data(repeating: 0, count: Int(image.byteCount)).write(to: blob) }
        var draft = "Review"
        let text = mode == "long" ? String(repeating: "x", count: 8_000) + " @Engineer" : mode == "unknown" ? "@Stranger review" : draft
        await f.model.sendGroupMessage(groupID: f.group.id, text: text,
            images: mode == "duplicate" ? f.images + f.images : f.images) { draft = "" }
        expectNoDifference(draft, "Review")
        expectNoDifference(f.model.groupMessages[f.group.id] ?? [], [])
        let count = await f.probe.requests.count
        expectNoDifference(count, 0)
        #expect(f.model.errorMessage != nil)
        #expect(f.model.runningGroups.isEmpty)
    }

    @Test func persistenceFailureRollsBackAndPreservesDraft() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let destination = f.root.appending(path: "groups.json")
        let backup = f.root.appending(path: "groups.backup")
        try FileManager.default.moveItem(at: destination, to: backup)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var posted = false
        await f.model.sendGroupMessage(groupID: f.group.id, text: "Review", images: f.images) { posted = true }
        #expect(!posted)
        expectNoDifference(f.model.groupMessages[f.group.id] ?? [], [])
        let count = await f.probe.requests.count
        expectNoDifference(count, 0)
        #expect(f.model.errorMessage != nil)
    }

    @Test(arguments: ["stop", "account", "members"])
    func invalidationDuringModelPreflightDoesNotPost(mode: String) async throws {
        let gate = GroupImageGate()
        let f = try await fixture(gate: gate); defer { try? FileManager.default.removeItem(at: f.root) }
        var posted = false
        let send = Task { await f.model.sendGroupMessage(groupID: f.group.id, text: "Review", images: f.images) { posted = true } }
        for _ in 0..<1_000 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await gate.entered
        if entered {
            if mode == "stop" { await f.model.stopGroup(id: f.group.id) }
            if mode == "account" { await f.model.cancelAutoReviewApprovals(nextAccountID: "other-account") }
            if mode == "members" { await f.model.updateGroupMembers(groupID: f.group.id, memberIDs: [f.engineer.id]) }
        }
        await gate.release()
        await send.value
        #expect(entered)
        #expect(!posted)
        expectNoDifference(f.model.groupMessages[f.group.id] ?? [], [])
        let count = await f.probe.requests.count
        expectNoDifference(count, 0)
        #expect(f.model.runningGroups.isEmpty)
    }

    @Test func reusedResponderAndPeerWakeCannotReplayImages() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let registry = f.model.registry
        let coordinator = TurnCoordinator(registry: registry, toolCatalog: ToolCatalog())
        let user = RoomMessage(groupID: f.group.id, senderID: nil, text: "Review", images: f.images)
        let attachment = InferenceAttachment(metadata: f.images[0], data: f.bytes)
        let responder = GroupConversationResponder(groupID: f.group.id, registry: registry, coordinator: coordinator,
            userMessageID: UUID(), userImages: [attachment])
        await #expect(throws: AgentImageError.unavailable) { try await responder.respond(agent: f.engineer, history: [user]) }
        let wrongRecipient = GroupConversationResponder(groupID: f.group.id, registry: registry, coordinator: coordinator,
            userMessageID: user.id, userImages: [attachment], imageRecipientIDs: [f.designer.id])
        await #expect(throws: AgentImageError.unavailable) { try await wrongRecipient.respond(agent: f.engineer, history: [user]) }
        let count = await f.probe.requests.count
        expectNoDifference(count, 0)
        let peer = RoomMessage(groupID: f.group.id, senderID: f.designer.id, text: "Review the summary only")
        let delegated = GroupConversationResponder(groupID: f.group.id, registry: registry, coordinator: coordinator,
            delegatedMessage: peer, userMessageID: user.id, userImages: [attachment])
        _ = try await delegated.respond(agent: f.engineer, history: [user, peer])
        let requests = await f.probe.requests
        expectNoDifference(requests.count, 1)
        #expect(requests[0].attachmentsByMessageID.isEmpty)
        #expect(requests[0].messages.allSatisfy { $0.attachments.isEmpty })
    }

    @Test func imageDraftsStayInTheirOwnGroup() {
        var drafts = GroupImageDrafts()
        let first = UUID(), second = UUID()
        let image = AttachmentMetadata(id: "fixture", filename: "layout.png", mimeType: "image/png", byteCount: 1, kind: .image)
        drafts[first] = [image]
        expectNoDifference(drafts[second], [])
        expectNoDifference(drafts[first], [image])
        drafts = GroupImageDrafts()
        expectNoDifference(drafts[first], [])
    }

    @Test func rememberedGroupContextDoesNotCarryImageHandlesIntoPeerWake() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let agents = try AgentService(storeURL: f.root.appending(path: "agents.json"))
        let messenger = try AgentMessenger(service: agents, storeURL: f.root.appending(path: "image-test-mailbox.json"))
        let session = AgentMessagingSession(originConversationID: f.group.id, agents: agents, messenger: messenger,
            registry: f.model.registry, coordinator: TurnCoordinator(registry: f.model.registry, toolCatalog: ToolCatalog()))
        await session.remember(agentID: f.designer.id, messages: [.init(role: .user, text: "Previous group request", attachments: f.images)], response: "Reviewed")
        try await session.enqueueUserMessage(senderID: f.engineer.id, recipientID: f.designer.id, text: "Review the text summary only")
        try await session.drain()
        try await session.close()
        let requests = await f.probe.requests
        expectNoDifference(requests.count, 1)
        #expect(requests[0].messages.contains { $0.text == "Previous group request" })
        #expect(requests[0].messages.allSatisfy { $0.attachments.isEmpty })
        #expect(requests[0].attachmentsByMessageID.isEmpty)
    }

    @Test func groupImageDisclosureRendersInSevenLanguages() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let preview = try #require(NSImage(data: f.bytes))
        let title = "Images are saved in this group and sent to the responding members' configured models. @mentions limit this turn's recipients."
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try FiliconLocalization.$languageOverride.withValue(language) {
                if language != "en" { #expect(FiliconLocalization.string(title) != title) }
                let host = NSHostingView(rootView: GroupImageDraftPreview(onRemove: {}) {
                    AgentMessageImagePreviewContent(image: f.images[0], preview: preview, compact: true)
                }
                    .padding(16).frame(width: 380, height: 280).background(FiliconTheme.canvas)
                    .environmentObject(f.model).environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = .init(x: 0, y: 0, width: 380, height: 280)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height <= 280)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let output {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "group-image-\(language).png"))
                }
            }
        }
    }
}
