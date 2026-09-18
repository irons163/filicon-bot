import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private struct AppImageProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "app-image", displayName: "Image fixture", requiresAPIKey: false)
    let run: @Sendable (InferenceRequest, @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) async throws -> String
    func models() async throws -> [AIModel] { [.init(id: "vision", capabilities: .init(inputModalities: [.text, .image]))] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.textDelta(try await run(request, executeTool)))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor AppImageProbe {
    var requests: [InferenceRequest] = []
    func record(_ value: InferenceRequest) -> Int { requests.append(value); return requests.count }
}

@Suite("Peer image app integration", .timeLimit(.minutes(1)))
@MainActor struct AgentImageAppIntegrationTests {
    private func imageData() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 120,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let blue = NSColor(deviceRed: 0.2, green: 0.45, blue: 0.85, alpha: 1)
        let yellow = NSColor(deviceRed: 0.95, green: 0.78, blue: 0.3, alpha: 1)
        let teal = NSColor(deviceRed: 0.2, green: 0.7, blue: 0.65, alpha: 1)
        for y in 0..<120 { for x in 0..<240 {
            bitmap.setColor(x < 80 ? blue : x < 160 ? yellow : teal, atX: x, y: y)
        } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate())
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "corrupt"])
    func importedImagesUseFreshPreviewApprovalAndRespectLifecycle(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-app-images-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let sender = try #require(await model.createAgent(name: "Sender", summary: "", instructions: "", providerID: "app-image", modelID: "vision"))
        let recipient = try #require(await model.createAgent(name: "Reviewer", summary: "", instructions: "", providerID: "app-image", modelID: "vision"))
        let file = root.appending(path: "review.png"), bytes = try imageData()
        try bytes.write(to: file)
        let images = try await model.importAgentMessageImages([file])
        let image = try #require(images.first), preview = try await model.agentMessageImageData(image)
        expectNoDifference(preview, bytes)
        let probe = AppImageProbe()
        await model.setAutoReviewEnabled(true)
        await model.setAutoReviewRules(allow: ["SendToAgent"], ask: [])
        await model.registry.register(AppImageProvider { request, execute in
            let count = await probe.record(request)
            let actual = request.attachmentsByMessageID.values.flatMap { $0 }.map(\.data)
            expectNoDifference(actual, [bytes])
            if count == 1 {
                struct Forward: Encodable { let recipientID: UUID; let images: [String]; let message = "Review the selected image" }
                let result = try await execute(.init(id: "image-forward", name: "SendToAgent",
                    argumentsJSON: JSONEncoder().encode(Forward(recipientID: sender.id, images: [image.id]))))
                if mode == "approve" { #expect(!result.isError) }
            }
            return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Review", images: images))
        try await waitUntil { !model.pendingAutoReviewApprovals.isEmpty }
        let approval = try #require(model.pendingAutoReviewApprovals.first)
        let scope = try #require(model.runningAgentMessageScopes.first)
        let encoded = try #require(approval.action.context.metadata["agentImages"])
        let proposed = try JSONDecoder().decode([AttachmentMetadata].self, from: Data(encoded.utf8))
        expectNoDifference(proposed.map(\.id), [image.id])
        expectNoDifference(approval.action.context.metadata["agentMessage"], "Review the selected image")
        #expect(approval.action.summary.contains("Reviewer → Sender"))
        expectNoDifference(model.agentMessages.count, 1)
        if mode == "stop" { await model.stopAgentMessages(scopeID: scope) }
        else if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "different-account") }
        else {
            if mode == "corrupt" {
                try Data(repeating: 0, count: Int(image.byteCount)).write(to: root.appending(path: "agent-message-images/\(image.id.prefix(2))/\(image.id)"))
            }
            await model.resolveGroupApproval(approval, groupID: scope, approve: mode != "deny")
        }
        try await waitUntil { model.runningAgentMessageScopes.isEmpty }
        let requests = await probe.requests
        expectNoDifference(requests.count, mode == "approve" ? 2 : 1)
        expectNoDifference(model.agentMessages.count, mode == "approve" ? 2 : 1)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        if mode == "approve" {
            let restarted = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
            await restarted.reloadWorkspaceData()
            expectNoDifference(restarted.agentMessages.map { $0.images?.map(\.id) }, [[image.id], [image.id]])
            let restored = try await restarted.agentMessageImageData(image)
            expectNoDifference(restored, bytes)
        }
    }

    @Test func actualImagePreviewAndDisclosureRenderInSevenLanguages() throws {
        let bytes = try imageData(), preview = try #require(NSImage(data: bytes))
        let image = AttachmentMetadata(id: String(repeating: "abcd", count: 16), filename: "review-layout.png", mimeType: "image/png", byteCount: Int64(bytes.count), kind: .image)
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let title = "Forward these images to the recipient model?"
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try FiliconLocalization.$languageOverride.withValue(language) {
                if language != "en" { #expect(FiliconLocalization.string(title) != title) }
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
                    Text(FiliconLocalization.string(title)).font(.headline)
                    Text("Reviewer → Designer").font(.callout)
                    Text(FiliconLocalization.string("Images will be sent to the selected recipient's configured model.")).font(.caption)
                    AgentMessageImagePreviewContent(image: image, preview: preview)
                    Text(FiliconLocalization.string("PNG/JPEG only · up to 4 images · 5 MB each · 12 MB total")).font(.caption)
                }.padding(20).frame(width: 360).background(FiliconTheme.canvas)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = .init(x: 0, y: 0, width: 360, height: 410)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height <= 410)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                if let output {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try data.write(to: output.appending(path: "peer-image-\(language).png"))
                }
            }
        }
    }
}
