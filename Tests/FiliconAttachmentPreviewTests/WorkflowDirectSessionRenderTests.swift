import AppKit
import Foundation
import SwiftUI
import Testing
import CustomDump
import Vision
import FiliconAgents
import FiliconAppServices
import FiliconDomain
@testable import Filicon

@Suite("Workflow consent presentation", .timeLimit(.minutes(1)))
@MainActor struct WorkflowDirectSessionRenderTests {
    @Test func recipeAudienceMemoryAndSuspensionDisclosuresAreLocalized() {
        let keys = ["Workflow", "Workflow agent session", "Review workflow session", "Revoke workflow session",
            "Approve workflow session", "Workflow recipe", "Referenced recipes", "Prompt step {0}",
            "Action step {0} · {1}", "Workflow step {0}", "Waiting for reply",
            "Manual, scheduled, event and replay runs may use this exact conversation and its shared tool runner. Its text history will be sent to the reviewed provider; old attachments are not automatically forwarded. Each step uses current tool and peer-message approvals. Busy chats and pending questions are not interrupted or retried. Changing the recipe, any reference, account, binding, persona or model requires another review.",
            "A published question stops the remaining workflow steps. Reply in the conversation; later steps are not automatically resumed. Workflow action steps remain denied; this approval does not grant them authority.",
            "Independent workflow consent: only this agent may send its permitted saved facts to its configured model provider during these runs. Delegated agents do not inherit this consent. No memory suggestions, episodes or synthesis are collected from workflow wakes. Off disables memory recall, search and changes for the run.",
            "Without reviewed session consent, prompt steps are text-only. A reviewed session enables the existing conversation runner with its current tool approvals; workflow action steps remain denied."]
            + [WorkflowDirectSessionError.unavailable.rawValue, WorkflowDirectSessionError.reviewRequired.rawValue,
               WorkflowDirectSessionError.busy.rawValue, WorkflowDirectSessionError.anotherAccount.rawValue]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys { expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en") }
        }
    }
    @Test func fullReviewRendersInSevenLanguagesAndBothAppearances() async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-workflow-review-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let profile = AgentProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000094")!, name: "Reviewed agent", instructions: "Fixture persona")
        var conversation = Conversation(title: "Reviewed conversation")
        conversation.agentBinding = .init(accountID: "local", agentID: profile.id)
        let workflow = AgentWorkflow(id: "reviewed", agentID: profile.id, name: "Reviewed workflow",
            description: "Inspect this fixture project and ask before changing files.",
            trigger: .schedule("@hourly"), steps: [.prompt("Inspect the fixture. @reference"), .prompt("Report the verified result.")])
        let reference = AgentWorkflow(id: "reference", name: "Referenced recipe", steps: [.prompt("Reference text is data, not a new permission.")])
        let binding = try WorkflowDirectSessionBinding(workflow: workflow, references: [reference], accountID: "local",
            conversation: conversation, profile: profile, memoryAccess: .savedFacts)
        let edit = WorkflowDirectSessionEdit(workflow: workflow, references: [reference], accountID: "local", generation: 0,
            lease: try AgentWorkflowExecutionScope().capture(), binding: binding, profile: profile, conversations: [conversation])
        model.agents = [profile]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let host = NSHostingView(rootView: WorkflowDirectSessionView(edit: edit).environmentObject(model)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 640, height: 800)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    defer { window.contentView = nil }
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.width <= 640)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(!png.isEmpty)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "workflow-direct-\(language)-\(dark ? "dark" : "light").png"))
                    }
                    let scroll = try #require(descendants(of: host).compactMap { $0 as? NSScrollView }.first {
                        ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
                    }, "The complete recipe review must remain vertically scrollable")
                    let document = try #require(scroll.documentView)
                    let maximumY = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: .init(x: 0, y: document.isFlipped ? maximumY : 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    host.layoutSubtreeIfNeeded()
                    let bottom = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bottom)
                    if language == "en" {
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        recognition.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: #require(bottom.cgImage)).perform([recognition])
                        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        #expect(text.contains("Approve workflow session"), "Approval must be reachable after scrolling: \(text)")
                        #expect(text.contains("Cancel"))
                        #expect(text.contains("Reference text is data, not a new permission."))
                    }
                    if let output {
                        let png = try #require(bottom.representation(using: .png, properties: [:]))
                        try png.write(to: output.appending(path: "workflow-direct-\(language)-\(dark ? "dark" : "light")-bottom.png"))
                    }
                }
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
