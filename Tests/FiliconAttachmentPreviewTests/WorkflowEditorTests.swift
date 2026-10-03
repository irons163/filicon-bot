import Foundation
import AppKit
import SwiftUI
import Vision
import Testing
import CustomDump
import FiliconAgents
@testable import Filicon

@Suite("Lossless workflow editor", .timeLimit(.minutes(1)))
@MainActor struct WorkflowEditorTests {
    private let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000095")!
    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
    private let saveDate = Date(timeIntervalSince1970: 1_700_000_200)

    @Test(arguments: [AgentWorkflowTrigger.manual, .event("connector:fixture:changed"), .schedule("@hourly")], [true, false])
    func unchangedRecipeKeepsEveryStepEnabledStateSourceAndCreationDate(trigger: AgentWorkflowTrigger, enabled: Bool) throws {
        for source in [nil, "private-skill:fixture", "https://example.com/SKILL.md"] as [String?] {
            let original = recipe(trigger: trigger, enabled: enabled, source: source)
            let draft = WorkflowEditorDraft(workflow: original)
            #expect(draft.isValid)
            let proposal = try draft.workflow(at: saveDate)
            var expected = original; expected.updatedAt = saveDate
            expectNoDifference(proposal, expected)
            // The actual schema retains prompt/action boundaries and metadata; no UI-only snapshot proves this.
            let decoded = try AgentWorkflowCodec.parse(AgentWorkflowCodec.serialize(.init(workflows: [proposal])))
            expectNoDifference(decoded.workflows, [expected])
        }
    }

    @Test func changingOnePromptDoesNotFlattenOtherStepsOrActionPayloads() throws {
        let original = recipe(trigger: .manual, enabled: false, source: "private-skill:fixture")
        var draft = WorkflowEditorDraft(workflow: original)
        expectDifference(draft.steps) {
            draft.steps[0].prompt = "Revised inspection. @reference"
        } changes: {
            $0[0].prompt = "Revised inspection. @reference"
        }
        let proposed = try draft.workflow(at: saveDate)
        var expected = original
        expected.updatedAt = saveDate
        expected.steps[0] = .prompt("Revised inspection. @reference")
        expectNoDifference(proposed, expected)
    }

    @Test func actionOnlyRecipeRemainsEditableAndTyped() throws {
        var original = recipe(trigger: .manual, enabled: false, source: nil)
        original.steps = [.action(name: "notify", payload: "{\"message\":\"Fixture\"}")]
        var draft = WorkflowEditorDraft(workflow: original)
        #expect(draft.isValid)
        expectDifference(draft.steps) {
            draft.steps[0].actionPayload = "{\"message\":\"Edited fixture\"}"
        } changes: {
            $0[0].actionPayload = "{\"message\":\"Edited fixture\"}"
        }
        let proposed = try draft.workflow(at: saveDate)
        expectNoDifference(proposed.steps, [.action(name: "notify", payload: "{\"message\":\"Edited fixture\"}")])
        expectNoDifference(proposed.isEnabled, false)
        expectNoDifference(proposed.agentID, agentID)
    }

    @Test func reorderingAndRemovingHaveExactVisibleEffects() throws {
        var draft = WorkflowEditorDraft(workflow: recipe(trigger: .manual, enabled: true, source: nil))
        let first = draft.steps[0], middle = draft.steps[1], last = draft.steps[2]
        draft.moveStep(id: middle.id, offset: -1)
        expectNoDifference(draft.steps, [middle, first, last])
        draft.moveStep(id: middle.id, offset: 1)
        expectNoDifference(draft.steps, [first, middle, last])
        draft.moveStep(id: first.id, offset: -1)
        draft.moveStep(id: last.id, offset: 1)
        draft.moveStep(id: middle.id, offset: Int.min)
        draft.moveStep(id: "missing", offset: 1)
        expectNoDifference(draft.steps, [first, middle, last])
        expectDifference(draft.steps) {
            draft.removeStep(id: middle.id)
        } changes: {
            $0.remove(at: 1)
        }
        let proposed = try draft.workflow(at: saveDate)
        expectNoDifference(proposed.steps, [first.step, last.step])
        draft.removeStep(id: last.id)
        draft.removeStep(id: first.id)
        expectNoDifference(draft.steps, [first])
    }

    @Test func additionsAreBoundedDistinctAndMustBeFilledBeforeSaving() throws {
        var draft = WorkflowEditorDraft.new(defaultAgentID: agentID)
        draft.name = "Fixture flow"; draft.steps[0].prompt = "Inspect the fixture."
        #expect(draft.isValid)
        draft.addStep(.action, id: "new-action")
        #expect(!draft.isValid)
        draft.steps[1].actionName = "createDraft"; draft.steps[1].actionPayload = "{}"
        #expect(draft.isValid)
        draft.addStep(.prompt, id: "new-prompt")
        #expect(!draft.isValid)
        draft.steps[2].prompt = "Report the result."
        #expect(draft.isValid)
        let expected = draft.steps
        draft.addStep(.prompt, id: "new-prompt")
        expectNoDifference(draft.steps, expected)
        let proposal = try draft.workflow(at: saveDate)
        expectNoDifference(proposal.id, "fixture-flow")
        expectNoDifference(proposal.createdAt, saveDate)
        expectNoDifference(proposal.updatedAt, saveDate)
        expectNoDifference(proposal.steps, [.prompt("Inspect the fixture."), .action(name: "createDraft", payload: "{}"), .prompt("Report the result.")])
        for index in draft.steps.count..<AgentWorkflowLimits.maximumSteps {
            draft.addStep(.prompt, id: "extra-\(index)")
            draft.steps[index].prompt = "Bounded fixture step."
        }
        #expect(draft.isValid)
        let maximum = draft.steps
        draft.addStep(.action, id: "overflow")
        expectNoDifference(draft.steps, maximum)
    }

    @Test(arguments: ["name", "prompt", "action name", "action payload", "source", "step count", "agent", "trigger"])
    func invalidEditsCannotProduceAnAcceptedProposal(field: String) {
        var draft = WorkflowEditorDraft(workflow: recipe(trigger: .manual, enabled: true, source: nil))
        switch field {
        case "name": draft.name = String(repeating: "x", count: AgentWorkflowLimits.maximumNameCharacters + 1)
        case "prompt": draft.steps[0].prompt = String(repeating: "x", count: AgentWorkflowLimits.maximumBodyBytes + 1)
        case "action name": draft.steps[1].actionName = " "
        case "action payload": draft.steps[1].actionPayload = String(repeating: "x", count: AgentWorkflowLimits.maximumActionPayloadBytes + 1)
        case "source": draft.sourceReference = String(repeating: "x", count: 2_049)
        case "step count": draft.steps = []
        case "agent": draft.agentID = nil
        case "trigger": draft.trigger = .event; draft.triggerValue = " "
        default: Issue.record("Unknown fixture field")
        }
        #expect(!draft.isValid)
    }

    @Test func changingIdentityCannotReplaceADifferentWorkflow() throws {
        var draft = WorkflowEditorDraft(workflow: recipe(trigger: .manual, enabled: false, source: nil))
        draft.workflowID = "different-target"
        let proposal = try draft.workflow(at: saveDate)
        expectNoDifference(proposal.id, "fixture-workflow")
        expectNoDifference(draft.replacingID, "fixture-workflow")
    }

private func recipe(trigger: AgentWorkflowTrigger, enabled: Bool, source: String?) -> AgentWorkflow {
        AgentWorkflow(id: "fixture-workflow", agentID: agentID, name: "Fixture workflow", description: "Preserve all recipe data.",
            isEnabled: enabled, trigger: trigger,
            steps: [.prompt("Inspect the fixture. @reference"), .action(name: "createDraft", payload: "{\"body\":\"Fixture draft\",\"title\":\"Unchanged\"}"), .prompt("Report the verified result.")],
            sourceReference: source, createdAt: createdAt, updatedAt: updatedAt)
    }
}

@Suite("Workflow editor presentation", .timeLimit(.minutes(1)))
@MainActor struct WorkflowEditorRenderTests {
    @Test(arguments: ["ready", "invalid", "saving"])
    func persistentNativeFooterHonorsKeyboardAndSavingState(state: String) async throws {
        var saves = 0, cancellations = 0
        try await withUIRenderTurn(language: "en") {
            let host = NSHostingView(rootView: WorkflowEditorFooter(isSaving: state == "saving", canSave: state != "invalid",
                saveButtonTapped: { saves += 1 }, cancelButtonTapped: { cancellations += 1 }))
            host.frame = .init(x: 0, y: 0, width: 640, height: 56)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let buttons = descendants(of: host).compactMap { $0 as? NSButton }
            let save = try #require(buttons.first { $0.title == "Save" })
            let cancel = try #require(buttons.first { $0.title == "Cancel" })
            expectNoDifference(save.keyEquivalent, "\r")
            expectNoDifference(cancel.keyEquivalent, "\u{1b}")
            expectNoDifference(save.isEnabled, state == "ready")
            expectNoDifference(cancel.isEnabled, state != "saving")
            #expect(host.bounds.contains(host.convert(save.bounds, from: save)))
            #expect(host.bounds.contains(host.convert(cancel.bounds, from: cancel)))
            save.performClick(nil); cancel.performClick(nil)
            expectNoDifference(saves, state == "ready" ? 1 : 0)
            expectNoDifference(cancellations, state != "saving" ? 1 : 0)
        }
    }

    @Test func orderedStepControlsAreLocalized() {
        let keys = ["Action name", "Action payload", "Move step up", "Move step down", "Remove step",
            "Add prompt step", "Add action step", "Source reference",
            "Editing preserves the ordered steps, source and enabled state. Changing the recipe requires reviewing its session consent again."]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys { expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en") }
            #expect(FiliconLocalization.string("Cron or @every expression", language: language).contains("@every"))
        }
    }

    @Test func fullEditorScrollsAndKeepsSaveReachableInSevenLanguages() async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-workflow-editor-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let profile = AgentProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000095")!, name: "Fixture agent", instructions: "Fixture persona")
        model.agents = [profile]
        let workflow = AgentWorkflow(id: "editable-fixture", agentID: profile.id, name: "Editable fixture", description: "Fixture recipe with separate prompt and action steps.",
            isEnabled: false, trigger: .schedule("@hourly"), steps: [.prompt("Inspect the fixture. @reference"), .action(name: "createDraft", payload: "{\"body\":\"Fixture draft\"}"), .prompt("Report the verified result.")],
            sourceReference: "https://example.com/SKILL.md")
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let host = NSHostingView(rootView: WorkflowEditorView(draft: .init(workflow: workflow)).environmentObject(model)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 640, height: 800)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    defer { window.contentView = nil }
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    #expect(host.fittingSize.width <= 640)
                    let top = try capture(host)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        let png = try #require(top.representation(using: .png, properties: [:]))
                        try png.write(to: output.appending(path: "workflow-editor-\(language)-\(dark ? "dark" : "light").png"))
                    }
                    let scrolls = descendants(of: host).compactMap { $0 as? NSScrollView }.filter {
                        ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
                    }
                    let scroll = try #require(scrolls.max { lhs, rhs in
                        (lhs.documentView?.bounds.height ?? 0) < (rhs.documentView?.bounds.height ?? 0)
                    }, "All ordered steps must remain accessible by scrolling")
                    let document = try #require(scroll.documentView)
                    let maximumY = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: .init(x: 0, y: document.isFlipped ? maximumY : 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    let bottom = try capture(host)
                    if language == "en" {
                        for bitmap in [top, bottom] {
                            let recognition = VNRecognizeTextRequest()
                            recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
                            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
                            let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                            #expect(text.contains("Save") && text.contains("Cancel"), "Save and Cancel must stay reachable: \(text)")
                        }
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: #require(bottom.cgImage)).perform([recognition])
                        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        #expect(text.contains("Add prompt step") && text.contains("Add action step") && text.contains("Source reference"), "Editor controls: \(text)")
                    }
                    if let output {
                        let png = try #require(bottom.representation(using: .png, properties: [:]))
                        try png.write(to: output.appending(path: "workflow-editor-\(language)-\(dark ? "dark" : "light")-bottom.png"))
                    }
                }
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func capture(_ host: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}
