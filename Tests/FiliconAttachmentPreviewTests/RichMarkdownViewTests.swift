import Foundation
import AppKit
import SwiftUI
import Testing
import CustomDump
import Vision
import FiliconAgents
import FiliconDomain
@testable import Filicon
import FiliconRichContent

@Suite("Rich Markdown view projection")
struct RichMarkdownViewTests {
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["direct", "group"], ["flowchart", "sequence", "state", "fallback"])
    @MainActor func diagramExpansionIsReachableInBothActualTranscriptRoutes(route: String, kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-mermaid-route-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let date = Date(timeIntervalSince1970: 1_000)
        let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000051")!
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000052")!
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000053")!
        let agent = AgentProfile(id: agentID, name: "Fixture author", createdAt: date, avatar: .pet(.codex))
        let body: String
        switch kind {
        case "flowchart": body = "flowchart LR\nA[Design] --> B[Build]"
        case "sequence": body = "sequenceDiagram\nDesign->>Build: Review\nBuild-->>Design: Ready"
        case "state": body = "stateDiagram-v2\nDraft --> Ready"
        default: body = "flowchart LR\nclick A https://example.com"
        }
        let source = "```mermaid\n\(body)\n```"
        let direct = ChatMessage(id: messageID, role: .assistant, text: source, createdAt: date)
        let conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000054")!, messages: [direct], updatedAt: date)
        let group = RoomMessage(id: messageID, groupID: groupID, senderID: agentID, text: source, createdAt: date)
        try await withUIRenderTurn(language: "en") {
            let content = Group {
                if route == "direct" {
                    TranscriptMessageView(message: direct, conversation: conversation, onJumpToMessage: { _ in
                        Issue.record("A diagram must not navigate a transcript")
                    })
                } else {
                    GroupMessageBubble(message: group, agent: agent, onReaction: {
                        Issue.record("A diagram must not change reactions")
                    })
                }
            }.padding(16).frame(width: 420).environmentObject(model)
            let host = NSHostingView(rootView: content)
            host.frame = .init(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let buttons = descendants(in: host).compactMap { $0 as? MermaidExpandNativeButton }
            expectNoDifference(buttons.count, kind == "fallback" ? 0 : 1)
            #expect(buttons.allSatisfy { $0.isEnabled && $0.keyEquivalent.isEmpty })
            expectNoDifference(buttons.map(\.title), kind == "fallback" ? [] : ["Open diagram full screen"])
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
            let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            expectNoDifference(text.contains("Open diagram full screen"), kind != "fallback")
        }
        expectNoDifference(direct.text, source)
        expectNoDifference(group.text, source)
    }

    @Test(arguments: ["\n", "\r\n"])
    func taskListStatusPreservesListStructureAndInlineAttributes(newline: String) throws {
        let source = [
            "3. [ ] Plan **layout**",
            "4. [x] Check `code`",
            "   - [X] Verify [reference](https://example.com)",
            "   - ordinary item",
            "",
            "     [x] A continuation is not a new task.",
            "",
            "> - [ ] 任務 👩🏽‍💻",
        ].joined(separator: newline)
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters),
            "3. ☐ Plan layout\n4. ☑ Check code\n  • ☑ Verify reference\n  • ordinary item\n\n    [x] A continuation is not a new task.\n\n› • ☐ 任務 👩🏽‍💻")
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && String(value[$0.range].characters) == "layout" })
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && String(value[$0.range].characters) == "code" })
        expectNoDifference(value.runs.filter { $0.link != nil }.map { String(value[$0.range].characters) }, ["reference"])
        #expect(value.runs.filter { String(value[$0.range].characters).contains("☑") || String(value[$0.range].characters).contains("☐") }
            .allSatisfy { $0.link == nil && $0.inlinePresentationIntent == nil })
    }

    @Test func escapedCodeAndNonListTaskLookalikesAreNotCheckboxes() throws {
        let source = #"""
        [x] Not a list.

        - \[x] Escaped marker
        - `[x]` Code marker
        - **[x]** Emphasized marker
        - [x](https://example.com) Link label
        - [y] Unknown marker
        - [x]No separator
        - [x]
        - [ ] A real task
        """#
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters),
            "[x] Not a list.\n\n• [x] Escaped marker\n• [x] Code marker\n• [x] Emphasized marker\n• x Link label\n• [y] Unknown marker\n• [x]No separator\n• [x]\n• ☐ A real task")
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && String(value[$0.range].characters) == "[x]" })
        expectNoDifference(value.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com"])
    }

    @Test func taskSourcePositionsRemainCorrectAfterUnicodeAndAcrossWhitespace() throws {
        let source = "前言 👩🏽‍💻\n\n- [x]\t**完了** 한국어\n- [ ]  Check  spacing\n- ordinary\n\n  [X] Continuation\n\n> - [X] Café é\n"
        let paragraphs = try #require(RichMarkdownProseLayout.paragraphs(source))
        expectNoDifference(paragraphs.map(\.isTaskChecked), [nil, true, false, nil, nil, true])
        expectNoDifference(paragraphs.map { String($0.content.characters) },
            ["前言 👩🏽‍💻", "完了 한국어", "Check  spacing", "ordinary", "[X] Continuation", "Café é"])
        #expect(paragraphs[1].content.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        expectNoDifference(paragraphs.map(\.prefix), ["", "• ", "• ", "• ", "  ", "› • "])
    }

    @Test func tableCellsFormatInlineContentWithoutParsingBlocksOrExecutingHTML() {
        let value = RichMarkdownTableCellLayout.make("**Bold** *italic* ~~old~~ `code` [Web](https://example.com) https://example.org")
        expectNoDifference(String(value.characters), "Bold italic old code Web https://example.org")
        for (label, intent) in [("Bold", InlinePresentationIntent.stronglyEmphasized), ("italic", .emphasized), ("old", .strikethrough), ("code", .code)] {
            #expect(value.runs.contains { String(value[$0.range].characters) == label && $0.inlinePresentationIntent?.contains(intent) == true })
        }
        expectNoDifference(value.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com", "https://example.org"])
        let literal = "# Not a heading\n\n- Not a list <script>window.open('https://example.com')</script>"
        let inline = RichMarkdownTableCellLayout.make(literal)
        expectNoDifference(String(inline.characters), literal)
        #expect(inline.runs.allSatisfy { $0.presentationIntent == nil && $0.font == nil })
    }

    @Test func tableCellLinksKeepLabelsButRejectNonHTTPAndCredentialURLs() {
        let source = "[file](file:///tmp/private) [script](javascript:alert(1)) [message](sand-msg:t0u) [mail](mailto:a@example.com) [relative](../private) [credential](https://user:secret@example.com) [web](https://example.com/a)"
        let value = RichMarkdownTableCellLayout.make(source)
        expectNoDifference(String(value.characters), "file script message mail relative credential web")
        expectNoDifference(value.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com/a"])
        expectNoDifference(String(RichMarkdownTableCellLayout.make("`[code](https://example.com)`").characters), "[code](https://example.com)")
        #expect(RichMarkdownTableCellLayout.make("`[code](https://example.com)`").runs.allSatisfy { $0.link == nil })
    }

    @Test @MainActor func tableLinkClicksRecheckPolicyBeforeCallingInjectedOpener() throws {
        var opened: [URL] = []
        let view = RichMarkdownTableView(table: .init(headers: ["A"], rows: []), openLink: { opened.append($0); return true })
        for candidate in ["file:///tmp/private", "javascript:alert(1)", "sand-msg:t0u", "mailto:a@example.com", "../private", "https://user:secret@example.com"] {
            #expect(!view.open(try #require(URL(string: candidate))))
        }
        expectNoDifference(opened, [])
        let https = try #require(URL(string: "https://example.com/a"))
        let http = try #require(URL(string: "http://example.org"))
        #expect(view.open(https))
        #expect(view.open(http))
        expectNoDifference(opened, [https, http])
        let rejected = RichMarkdownTableView(table: .init(headers: ["A"], rows: []), openLink: { _ in false })
        #expect(!rejected.open(https))
    }

    @Test func tableLinksAndImagesNeverBecomeAutomaticMetadataRequests() {
        let table = "| Link | Image |\n| --- | --- |\n| [Web](https://example.com) | ![alt](https://example.org/image.png) |"
        expectNoDifference(RichMarkdownProjection.make(source: table).safeHTTPLinks(maximum: 3), [])
        expectNoDifference(RichMarkdownProjection.make(source: table).blocks.count, 1)
    }

    @Test @MainActor func taskStatusLabelsAreLocalizedWithoutChangingMessageContent() {
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            FiliconLocalization.$languageOverride.withValue(language) {
                for key in ["Task status", "Completed", "Not completed", "Status from the message; this checkbox cannot be changed."] {
                    expectNoDifference(FiliconLocalization.string(key) == key, language == "en")
                }
                expectNoDifference(RichMarkdownTaskStatus(isChecked: true).statusLabel, l10n("Completed"))
                expectNoDifference(RichMarkdownTaskStatus(isChecked: false).statusLabel, l10n("Not completed"))
                let message = "- [x] 原作者 👩🏽‍💻"
                expectNoDifference(String(RichMarkdownProseLayout.make(message)!.characters), "• ☑ 原作者 👩🏽‍💻")
            }
        }
        expectNoDifference(FiliconLocalization.string("Not completed", language: "ja"), "未完了")
        expectNoDifference(FiliconLocalization.string("Not completed", language: "ko"), "미완료")
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    @MainActor func tasksAndTablesRenderInBothActualTranscriptRoutes(language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-markdown-task-table-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let date = Date(timeIntervalSince1970: 1_000)
        let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let agent = AgentProfile(id: agentID, name: "Fixture author", createdAt: date, avatar: .pet(.codex))
        let source = """
        # Review

        - [ ] Plan **layout**
        - [x] Check `code`
          - [X] Verify contrast

        | **Area** | **State** |
        | --- | --- |
        | *Design* | ~~Draft~~ Ready |
        | `build` | 完了 測試 👩🏽‍💻 |
        """
        let direct = ChatMessage(id: messageID, role: .assistant, text: source, createdAt: date)
        let conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000044")!, messages: [direct], updatedAt: date)
        let group = RoomMessage(id: messageID, groupID: groupID, senderID: agentID, text: source, createdAt: date)
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for dark in [false, true] {
            for route in ["direct", "group"] {
                try await withUIRenderTurn(language: language) {
                    let content = Group {
                        if route == "direct" {
                            TranscriptMessageView(message: direct, conversation: conversation, onJumpToMessage: { _ in
                                Issue.record("Rendering must not navigate a transcript")
                            })
                        } else {
                            GroupMessageBubble(message: group, agent: agent, onReaction: {
                                Issue.record("Rendering must not change a reaction")
                            })
                        }
                    }
                    .padding(16).frame(width: 420, alignment: .leading).background(FiliconTheme.canvas)
                    .environmentObject(model).environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: content)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = host.fittingSize
                    expectNoDifference(size.width, 420)
                    #expect(size.height > 200 && size.height < 600)
                    host.frame = .init(origin: .zero, size: size)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    defer { window.contentView = nil }
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(!png.isEmpty)
                    // Offscreen NSHostingView exposes an empty accessibility tree.
                    // Inspect its real disabled native controls; localized status copy
                    // is tested separately. This is not a live VoiceOver assertion.
                    let checkboxes = descendants(in: host).compactMap { $0 as? NSButton }.filter { !$0.isEnabled }
                    expectNoDifference(checkboxes.count, 3)
                    expectNoDifference(checkboxes.map(\.state), [.off, .on, .on])
                    for checkbox in checkboxes { checkbox.performClick(nil) }
                    expectNoDifference(checkboxes.map(\.state), [.off, .on, .on])
                    if language == "en" {
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        recognition.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
                        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        for expected in ["Review", "Plan", "layout", "Check", "code", "Verify", "contrast", "Area", "State", "Design", "Ready", "build"] {
                            #expect(text.contains(expected), "Both transcripts must show inline content: \(text)")
                        }
                        for marker in ["[x]", "[X]", "[ ]", "**", "~~", "`"] {
                            #expect(!text.contains(marker), "Markdown delimiters must not leak into the rendered table or task: \(text)")
                        }
                    }
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "markdown-task-table-\(route)-\(language)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
        expectNoDifference(direct.text, source)
        expectNoDifference(group.text, source)
    }

    @MainActor private func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    @Test func paragraphBoundariesDoNotSplitInlineAttributesOrExtendLinks() throws {
        let source = "First **bold** and *emphasis* with `code`.\n\n[Second paragraph](https://example.com)\n\nThird paragraph."
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters), "First bold and emphasis with code.\n\nSecond paragraph\n\nThird paragraph.")
        let links = value.runs.compactMap { run -> String? in
            guard run.link != nil else { return nil }; return String(value[run.range].characters)
        }
        expectNoDifference(links, ["Second paragraph"])
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && String(value[$0.range].characters) == "bold" })
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true && String(value[$0.range].characters) == "emphasis" })
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && String(value[$0.range].characters) == "code" })
        #expect(value.runs.filter { String(value[$0.range].characters).contains("\n\n") }.allSatisfy { $0.link == nil && $0.inlinePresentationIntent == nil })
    }

    @Test(arguments: ["\n", "\r\n"])
    func preservesHardBreaksAndMarkdownSoftWrapping(newline: String) throws {
        let source = ["soft", "wrap  ", "hard\\", "next", "", "Another paragraph"].joined(separator: newline)
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters), "soft wrap\nhard\nnext\n\nAnother paragraph")
        expectNoDifference(String(try #require(RichMarkdownProseLayout.make(" \n\n ")).characters), "")
    }

    @Test func orderedNestedListsAndContinuationParagraphsKeepTheirStructure() throws {
        let source = """
        3. First **item**
        4. Second item
           - Nested item
           - Another nested item

             A second paragraph in the same nested item.

        After the list.
        """
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters), "3. First item\n4. Second item\n  • Nested item\n  • Another nested item\n\n    A second paragraph in the same nested item.\n\nAfter the list.")
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && String(value[$0.range].characters) == "item" })
    }

    @Test func listMarkersNeverInheritLinksAndSeparateListsDoNotMerge() throws {
        let source = "- [One](sand-msg:t0u)\n- [Two](https://example.com)\n\nParagraph.\n\n- New list"
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters), "• One\n• Two\n\nParagraph.\n\n• New list")
        expectNoDifference(value.runs.filter { $0.link != nil }.map { String(value[$0.range].characters) }, ["One", "Two"])
    }

    @Test func headingsQuotesAndThematicBreaksRemainDistinct() throws {
        let value = try #require(RichMarkdownProseLayout.make("# Heading\n\nBody\n\n> Quote\n>\n> More quote\n>> Nested quote\n\n---\n\nEnd"))
        expectNoDifference(String(value.characters), "Heading\n\nBody\n\n› Quote\n\n› More quote\n\n› › Nested quote\n\n⸻\n\nEnd")
        #expect(value.runs.first?.font != nil)
        #expect(value.runs.contains { String(value[$0.range].characters) == "Body" && $0.font == nil })
    }

    @Test @MainActor func referenceDefinitionsAndCodeSurviveParagraphLayout() throws {
        let original = URL(string: "sand-msg:t0u")!
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let source = "[原始需求 👩🏽‍💻][original]\n\n**Follow-up** [missing](sand-msg:t9u).\n\n`[literal](sand-msg:t0u)`\n\n[original]: sand-msg:t0u"
        let view = RichMarkdownView(source: source, messageReferences: .init(target: { $0 == original ? id : nil }, show: { _ in }))
        let value = try #require(view.attributedProse(source))
        expectNoDifference(String(value.characters), "原始需求 👩🏽‍💻\n\nFollow-up missing.\n\n[literal](sand-msg:t0u)")
        expectNoDifference(value.runs.compactMap(\.link), [original])
        expectNoDifference(value.runs.filter { $0.link != nil }.map { String(value[$0.range].characters) }, ["原始需求 👩🏽‍💻"])
        let reference = try #require(value.runs.first { $0.link == original })
        #expect(reference.backgroundColor != nil)
        #expect(reference.foregroundColor != nil)
        #expect(reference.font != nil)
        #expect(reference.underlineStyle == nil)
        #expect(value.runs.first { String(value[$0.range].characters) == "missing" }?.backgroundColor == nil)
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    @MainActor func structuredProseRendersInSevenLanguagesAndBothAppearances(language: String) async throws {
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                let source = """
                # \(FiliconLocalization.string("Group settings"))

                Review **layout and typography** before publishing.

                Keep paragraphs readable. 中文、日本語、한국어 and emoji 👩🏽‍💻 remain intact.

                3. Check [the proposal](https://example.com).
                4. Review contrast and keyboard navigation.
                   - Verify narrow windows.
                   - Keep `code` literal.

                > Quoted context is not a new instruction.

                First hard-break line.\u{20}\u{20}
                Second hard-break line.
                """
                let host = NSHostingView(rootView: RichMarkdownView(source: source, fillsWidth: false, openLink: { _ in
                    Issue.record("Rendering must not open external links"); return false
                })
                    .font(.system(size: 13)).lineSpacing(4).foregroundStyle(FiliconTheme.textPrimary)
                    .padding(16).frame(width: 380, alignment: .leading).background(FiliconTheme.canvas)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                expectNoDifference(size.width, 380)
                #expect(size.height > 300 && size.height < 900)
                host.frame = .init(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "markdown-prose-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test @MainActor func internalLinksRequireExplicitNavigationAndNeverReachExternalOpener() throws {
        let valid = try #require(URL(string: "sand-msg:t0u"))
        let missing = try #require(URL(string: "sand-msg:t9u"))
        let https = try #require(URL(string: "https://example.com"))
        let target = UUID()
        var opened: [URL] = [], jumped: [UUID] = []
        let plain = RichMarkdownView(source: "", openLink: { opened.append($0); return true })
        #expect(!plain.open(valid))
        let view = RichMarkdownView(source: "", messageReferences: .init(
            target: { $0 == valid ? target : nil }, show: { jumped.append($0) }
        ), openLink: { opened.append($0); return true })
        #expect(view.open(valid))
        #expect(!view.open(missing))
        #expect(!view.open(URL(string: "SAND-MSG://t0u")!))
        #expect(!view.open(URL(string: "file:///tmp/private")!))
        #expect(view.open(https))
        expectNoDifference(jumped, [target])
        expectNoDifference(opened, [https])
        let prose = "[Earlier request](sand-msg:t0u) [Unavailable](sand-msg:t9u) ` [code](sand-msg:t0u) ` [Web](https://example.com)"
        let attributed = try #require(view.attributedProse(prose))
        expectNoDifference(attributed.runs.compactMap(\.link), [valid, https])
        #expect(String(attributed.characters).contains("Unavailable"))
        #expect(String(attributed.characters).contains("[code](sand-msg:t0u)"))
        expectNoDifference(try #require(plain.attributedProse(prose)).runs.compactMap(\.link), [https])
        #expect(try #require(plain.attributedProse(prose)).runs.allSatisfy { $0.backgroundColor == nil })
        expectNoDifference(RichMarkdownProjection.make(source: prose).safeHTTPLinks(maximum: 3), [https])
    }

    @Test @MainActor func internalReferencesDoNotActivateInCodeMathOrTableBlocks() throws {
        let source = """
        [Original](sand-msg:t0u)

        ```text
        [Code](sand-msg:t0u)
        ```
        | Title | Link |
        | --- | --- |
        | Table | [label](sand-msg:t0u) |

        \\([math](sand-msg:t0u)\\)
        """
        let blocks = RichMarkdownProjection.make(source: source).blocks
        let prose = blocks.compactMap { block -> String? in
            if case .prose(let text) = block { return text }; return nil
        }
        let view = RichMarkdownView(source: source, messageReferences: .init(target: { _ in UUID() }, show: { _ in }))
        let links = prose.compactMap(view.attributedProse).flatMap { $0.runs.compactMap(\.link) }
        expectNoDifference(links.map(\.absoluteString), ["sand-msg:t0u"])
    }

    @Test func projectsEveryRichBlockWithoutExecutingContent() {
        let source = """
        Hello **world**

        ```swift
        let value = 1
        ```
        | A | B |
        | --- | --- |
        | 1 | 2 |
        \\(x_1\\)
        ```mermaid
        flowchart LR
        A[Start] --> B[Done]
        ```
        """
        let projection = RichMarkdownProjection.make(source: source)
        #expect(projection.blocks.contains { if case .prose = $0 { true } else { false } })
        #expect(projection.blocks.contains { if case .code(language: "swift", source: "let value = 1", isTerminated: true) = $0 { true } else { false } })
        #expect(projection.blocks.contains { if case .table(let value) = $0 { value.headers == ["A", "B"] } else { false } })
        #expect(projection.blocks.contains { if case .math(source: "x_1", mode: .inline, presentation: .rendered) = $0 { true } else { false } })
        #expect(projection.blocks.contains { if case .mermaid(_, .diagram(let value)) = $0 { value.kind == .flowchart } else { false } })
    }

    @Test func mathAndMermaidFailuresProjectExplicitFallbacks() {
        let projection = RichMarkdownProjection.make(source: "\\(\\href{x}{y}\\)\n```mermaid\nflowchart LR\nclick A https://evil.example\n```")
        #expect(projection.blocks.contains { if case .math(_, _, .fallback(original: #"\href{x}{y}"#)) = $0 { true } else { false } })
        #expect(projection.blocks.contains { if case .mermaid(let source, .fallback(let original, _)) = $0 { source == original } else { false } })
    }

    @Test func safeLinkProjectionIsDeduplicatedFilteredAndBounded() {
        let source = "[one](https://example.com/a) [again](https://example.com/a) [two](http://openai.com) [mail](mailto:a@example.com) [bad](file:///tmp/x)"
        let links = RichMarkdownProjection.make(source: source).safeHTTPLinks(maximum: 2)
        #expect(links.map(\.absoluteString) == ["https://example.com/a", "http://openai.com"])
        #expect(RichMarkdownProjection.make(source: source).safeHTTPLinks(maximum: 0).isEmpty)
    }

    @Test @MainActor func metadataCardsAreOptInAndHardCapped() {
        let defaultView = RichMarkdownView(source: "[x](https://example.com)")
        #expect(defaultView.metadataController == nil)
        #expect(defaultView.maximumMetadataCards == 0)
        let controller = RichLinkMetadataController { url in .init(url: url, title: "title") }
        #expect(RichMarkdownView(source: "x", metadataController: controller, maximumMetadataCards: 99).maximumMetadataCards == 3)
        #expect(RichMarkdownView(source: "x", metadataController: controller, maximumMetadataCards: -1).maximumMetadataCards == 0)
    }

    @Test func controllerForwardsToInjectedAsyncLoader() async throws {
        let expected = URL(string: "https://example.com")!
        let controller = RichLinkMetadataController { url in .init(url: url, title: "Injected") }
        #expect(try await controller.load(expected) == .init(url: expected, title: "Injected"))
    }

    @Test func offlineMathDocumentIsSelfContainedAndLockedDown() {
        guard case .rendered(let markup) = OfflineMathPresenter().presentation(for: "x", mode: .display)
        else { Issue.record("missing offline engine"); return }
        let document = OfflineMathWebPolicy.document(markup: markup, display: true)
        #expect(document.contains(markup.html))
        #expect(document.contains("default-src 'none'"))
        #expect(document.contains("script-src 'none'"))
        #expect(document.contains("font-src data:"))
        #expect(document.contains("data:font/woff2;base64,"))
        #expect(!document.localizedCaseInsensitiveContains("<script"))
        #expect(!document.localizedCaseInsensitiveContains(" src="))
    }

    @Test func offlineMathNavigationOnlyAllowsBlankInMemoryDocument() {
        #expect(OfflineMathWebPolicy.allowsNavigation(to: nil))
        #expect(OfflineMathWebPolicy.allowsNavigation(to: URL(string: "about:blank")))
        for value in ["https://example.com", "http://example.com", "data:text/html,x", "file:///tmp/x", "about:srcdoc"] {
            #expect(!OfflineMathWebPolicy.allowsNavigation(to: URL(string: value)))
        }
    }
}

@Suite("Native Mermaid layout projection")
struct MermaidNativeLayoutTests {
    @Test func flowchartLayoutRetainsEdgesAndLabels() {
        let diagram = MermaidDiagram(kind: .flowchart, nodes: [.init(id: "A", label: "Start"), .init(id: "B", label: "Done")], edges: [.init(from: "A", to: "B", label: "go")])
        let layout = MermaidNativeLayout.project(diagram)
        #expect(layout.kind == .flowchart)
        #expect(layout.nodes.map(\.label) == ["Start", "Done"])
        #expect(layout.edges.count == 1)
        #expect(layout.edges.first?.label == "go")
    }

    @Test func sequenceMessagesUseOrderedRowsAndParticipantColumns() {
        let diagram = MermaidDiagram(kind: .sequence, nodes: [.init(id: "A", label: "Alice"), .init(id: "B", label: "Bob")], edges: [.init(from: "A", to: "B", label: "hello"), .init(from: "B", to: "A", label: "reply")])
        let layout = MermaidNativeLayout.project(diagram)
        #expect(layout.nodes[0].position.x < layout.nodes[1].position.x)
        #expect(layout.edges[0].from.y < layout.edges[1].from.y)
        #expect(layout.edges.map(\.label) == ["hello", "reply"])
    }

    @Test func stateBoundaryGetsNativeAccessibleGlyph() {
        let diagram = MermaidDiagram(kind: .state, nodes: [.init(id: "__state_boundary", label: "__state_boundary"), .init(id: "Idle", label: "Idle")], edges: [.init(from: "__state_boundary", to: "Idle")])
        let layout = MermaidNativeLayout.project(diagram)
        #expect(layout.nodes.first?.label == "●")
        #expect(layout.edges.count == 1)
    }
}
