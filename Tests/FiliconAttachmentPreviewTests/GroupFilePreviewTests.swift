import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
@testable import Filicon

private struct PreviewFileResponder: GroupAgentResponder {
    let file: ReviewedGroupFile
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] { ["PASS"] }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        _ = try await onSavedPublication(.init(text: "", file: file))
        return ["PASS"]
    }
}

@Suite("Group file preview", .timeLimit(.minutes(1)))
@MainActor struct GroupFilePreviewTests {
    @Test(arguments: ["valid", "foreign-message", "foreign-group", "metadata", "missing", "switch-group"])
    func opensOnlyCanonicalStoredFiles(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-file-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", providerID: "fixture", modelID: "test")
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Files", memberIDs: [sender.id])
        let bytes = Data("Reviewed report".utf8)
        let store = AttachmentStore(rootURL: root.appending(path: "attachments"))
        let file = try await store.ingest(prepared: PreparedAgentPublicationFile(bytes: bytes, filename: "report.txt"),
                                          createdAt: Date(timeIntervalSince1970: 123))
        _ = try await groups.postUserMessage("Report", groupID: group.id)
        let reviewed = try ReviewedGroupFile(metadata: file, groupID: group.id, senderID: sender.id, lifetime: AgentPublicationLifetime())
        _ = try await groups.run(groupID: group.id, responder: PreviewFileResponder(file: reviewed))
        let history = await groups.messages(groupID: group.id)
        let message = try #require(history.first { $0.files?.isEmpty == false })
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        model.selectedGroupID = group.id
        var candidate = file
        if mode == "metadata" { candidate.altText = "Forged metadata" }
        if mode == "missing" {
            // Only the isolated fixture blob is removed, not user attachments.
            let blob = root.appending(path: "attachments/\(file.id.prefix(2))/\(file.id)")
            try FileManager.default.removeItem(at: blob)
        }
        model.openGroupMessageFile(candidate, messageID: mode == "foreign-message" ? UUID() : message.id,
                                   groupID: mode == "foreign-group" ? UUID() : group.id)
        if mode == "switch-group" { model.selectedGroupID = UUID() }
        if mode != "foreign-group" {
            let deadline = ContinuousClock.now + .seconds(5)
            while model.attachmentPreview == nil && model.errorMessage == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        expectNoDifference(model.attachmentPreview != nil, mode == "valid")
        if let preview = model.attachmentPreview {
            expectNoDifference(try Data(contentsOf: preview.fileURL), bytes)
            model.dismissAttachmentPreview()
        }
    }

    @Test func fileOnlyBubbleRendersInSevenLanguages() async throws {
        let file = AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "設計報告 — résumé — レポート.txt",
            mimeType: "text/plain", byteCount: 1024, kind: .document, createdAt: Date(timeIntervalSince1970: 123))
        let message = RoomMessage(groupID: UUID(), senderID: UUID(), text: "", files: [file])
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try await withUIRenderTurn(language: language) {
                let host = NSHostingView(rootView: GroupMessageBubble(message: message, agent: nil,
                    onOpenFile: { _ in }, onReaction: {}).padding(16).frame(width: 380, height: 220)
                    .environment(\.locale, Locale(identifier: language)))
                host.frame = .init(x: 0, y: 0, width: 380, height: 220)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height <= 220)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let output = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "group-file-\(language).png"))
                }
            }
        }
    }
}
