import AppKit
import CustomDump
import Foundation
import SwiftUI
import Testing
@testable import Filicon
import FiliconAgents
import FiliconAutoReview

@Suite("Immutable image avatar approval UI")
@MainActor
struct AgentAvatarImagePreviewTests {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private func image() throws -> PreparedAgentAvatar {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let cgImage = try #require(context.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        return try AgentAvatarStore(rootURL: URL(fileURLWithPath: "/unused-preview-store"))
            .prepareImage(data: data, shape: .hexagon)
    }
    private func metadata(_ image: PreparedAgentAvatar) -> [String: String] {
        ["agentStateTarget": "avatar", "agentAvatarAction": "set", "agentName": "Designer",
         "agentAvatarOwner": owner.uuidString, "agentAvatarImageHash": image.avatar.imageHash!]
    }

    @Test func fingerprintsOwnerAndPreviousImageMustMatch() throws {
        let prepared = try image()
        let preview = AgentAvatarApprovalPreview(agentID: owner, proposed: prepared,
            previous: prepared.avatar, previousPNG: prepared.pngData)
        let fields = metadata(prepared)
        #expect(preview.matches(fields))
        expectNoDifference(preview.previousPNG, prepared.pngData)
        for key in ["agentAvatarOwner", "agentAvatarImageHash", "agentAvatarAction", "agentStateTarget"] {
            var changed = fields; changed[key] = "wrong"
            #expect(!preview.matches(changed))
            changed.removeValue(forKey: key)
            #expect(!preview.matches(changed))
        }
        let corrupt = AgentAvatarApprovalPreview(agentID: owner, proposed: prepared,
            previous: prepared.avatar, previousPNG: Data("not an image".utf8))
        expectNoDifference(corrupt.previousPNG, nil)
        let absentHash = AgentAvatarApprovalPreview(agentID: owner, proposed: prepared,
            previous: .pet(.codex), previousPNG: prepared.pngData)
        expectNoDifference(absentHash.previousPNG, nil)
        #expect(!AgentAvatarApprovalPreview.validPNG(Data(count: 1_024 * 1_024), hash: prepared.avatar.imageHash))
        #expect(NSImage(data: prepared.pngData) != nil)
    }

    @Test func imageAndMissingPreviewRenderInSevenLanguages() async throws {
        let prepared = try image()
        let preview = AgentAvatarApprovalPreview(agentID: owner, proposed: prepared,
            previous: prepared.avatar, previousPNG: prepared.pngData)
        let fields = metadata(prepared)
        let keys = ["Image avatar", "Image preview unavailable. Reject this request and try again.",
                    "This exact image will be saved after approval. The source file is not changed."]
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for missing in [false, true] {
                for dark in [false, true] {
                    try await withUIRenderTurn(language: language) {
                        if language != "en" { for key in keys { #expect(FiliconLocalization.string(key) != key) } }
                        let host = NSHostingView(rootView: AgentManagementApprovalDetails(metadata: fields,
                            avatarPreview: missing ? nil : preview).padding(20).frame(width: 380)
                            .background(FiliconTheme.canvas).environment(\.locale, Locale(identifier: language))
                            .environment(\.colorScheme, dark ? .dark : .light))
                        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        host.frame = .init(x: 0, y: 0, width: 380, height: 430)
                        host.layoutSubtreeIfNeeded()
                        #expect(host.fittingSize.height <= 430)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        if let output {
                            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                            try data.write(to: output.appending(path: "image-avatar-\(language)-\(missing ? "missing" : "ready")-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
        }
    }

    @Test func missingInMemoryPreviewCannotBeApproved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-avatar-approval-gate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let prepared = try image()
        let conversationID = UUID()
        let fence = ApprovalFence(accountID: "local", agentID: conversationID.uuidString, runID: UUID(), generation: 0)
        let action = AutoReviewAction(summary: "Image avatar", target: .resource(kind: "agent", identifier: owner.uuidString),
            risks: [.sensitive], context: .init(fence: fence, conversationID: conversationID, toolCallID: "avatar", metadata: metadata(prepared)))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(30))
        #expect(!model.canApproveAvatarChange(pending))
        #expect(model.avatarApprovalPreview(for: pending) == nil)
    }
}
