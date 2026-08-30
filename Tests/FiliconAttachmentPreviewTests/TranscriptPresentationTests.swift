import Foundation
import Testing
import FiliconDomain
@testable import Filicon

@Suite("Transcript presentation")
struct TranscriptPresentationTests {
    @Test func conversationLoadFenceRejectsStaleAndSwitchedSelections() {
        let firstID = UUID(), secondID = UUID()
        var fence = ConversationLoadFence()
        let first = fence.begin(conversationID: firstID)
        #expect(fence.accepts(first, selectedConversationID: firstID))
        let newer = fence.begin(conversationID: firstID)
        #expect(!fence.accepts(first, selectedConversationID: firstID))
        #expect(fence.accepts(newer, selectedConversationID: firstID))
        #expect(!fence.accepts(newer, selectedConversationID: secondID))
    }

    @Test func olderDatabasePagesDeduplicateAndRemainChronological() {
        let m0 = ChatMessage(role: .user, text: "0")
        let m1 = ChatMessage(role: .assistant, text: "1")
        let m2 = ChatMessage(role: .user, text: "2")
        var locallyEditedM1 = m1
        locallyEditedM1.text = "locally edited"

        let merged = ConversationPageMerge.older([m0, m1], into: [locallyEditedM1, m2])
        #expect(merged.map(\.id) == [m0.id, m1.id, m2.id])
        #expect(merged.map(\.text) == ["0", "locally edited", "2"])
    }

    @Test func latestPageCollapsesDuplicateRowsWithoutReordering() {
        let first = ChatMessage(role: .user, text: "first")
        let second = ChatMessage(role: .assistant, text: "second")
        #expect(ConversationPageMerge.latest([first, second, first]).map(\.id) == [first.id, second.id])
    }

    @Test func rendersLatestPageAndLoadsOlderWithoutReordering() {
        let messages = (0..<250).map { ChatMessage(role: .user, text: "message \($0)") }
        var state = TranscriptPresentationState(messages: messages)

        #expect(state.visibleMessages(from: messages).map(\.text) == messages.suffix(100).map(\.text))
        state.loadOlder()
        #expect(state.visibleMessages(from: messages).map(\.text) == messages.suffix(200).map(\.text))
        state.loadOlder()
        #expect(state.visibleMessages(from: messages).map(\.id) == messages.map(\.id))
    }

    @Test func findNavigatesAndExposesMatchesOutsideInitialPage() throws {
        let messages = (0..<220).map { index in
            ChatMessage(role: .assistant, text: index == 5 || index == 210 ? "Needle \(index)" : "message \(index)")
        }
        var state = TranscriptPresentationState(messages: messages)

        state.setQuery("needle", messages: messages)
        #expect(state.matchIDs == [messages[5].id, messages[210].id])
        #expect(state.activeMatchID == messages[5].id)
        #expect(state.renderedCount == 215)
        #expect(state.matchPositionLabel == "1 of 2")

        #expect(state.selectNext(messages: messages) == messages[210].id)
        #expect(state.matchPositionLabel == "2 of 2")
        #expect(state.selectNext(messages: messages) == messages[5].id)
        #expect(state.selectPrevious(messages: messages) == messages[210].id)
    }

    @Test func appendingMessagesPreservesTheAlreadyRenderedWindow() {
        var messages = (0..<150).map { ChatMessage(role: .user, text: "message \($0)") }
        var state = TranscriptPresentationState(messages: messages)
        state.loadOlder()
        let previouslyVisible = state.visibleMessages(from: messages).map(\.id)

        messages.append(ChatMessage(role: .assistant, text: "new response"))
        state.synchronize(messages: messages)

        #expect(state.visibleMessages(from: messages).dropLast().map(\.id) == previouslyVisible)
        #expect(state.visibleMessages(from: messages).last?.text == "new response")
    }

    @Test func searchIncludesReasoningToolsAndAttachmentNames() {
        let attachment = AttachmentMetadata(
            id: String(repeating: "a", count: 64), filename: "quarterly-report.pdf",
            mimeType: "application/pdf", byteCount: 10, kind: .document
        )
        let tool = ToolActivity(id: "call-1", name: "lookup", argumentsJSON: "{\"city\":\"Taipei\"}", result: "sunny")
        let message = ChatMessage(role: .assistant, text: "answer", attachments: [attachment], reasoningText: "private plan", toolActivities: [tool])
        let messages = [message]
        var state = TranscriptPresentationState(messages: messages)

        for query in ["quarterly", "private", "Taipei", "sunny"] {
            state.setQuery(query, messages: messages)
            #expect(state.matchIDs == [message.id])
        }
    }

    @Test func replyJumpExposesTargetOutsideInitialPage() {
        let messages = (0..<250).map { ChatMessage(role: .user, text: "message \($0)") }
        var state = TranscriptPresentationState(messages: messages)

        #expect(!state.visibleMessages(from: messages).contains(where: { $0.id == messages[3].id }))
        let exposed = state.exposeMessage(id: messages[3].id, in: messages)
        #expect(exposed)
        #expect(state.visibleMessages(from: messages).contains(where: { $0.id == messages[3].id }))
        let missing = state.exposeMessage(id: UUID(), in: messages)
        #expect(!missing)
    }

    @Test func markdownSeparatesCopyableCodeFromProse() {
        let source = "Before\n```swift\nlet answer = 42\nprint(answer)\n```\nAfter"
        #expect(TranscriptMarkdownParser.blocks(in: source) == [
            .prose("Before"),
            .code(language: "swift", source: "let answer = 42\nprint(answer)"),
            .prose("After"),
        ])
        #expect(TranscriptMarkdownParser.blocks(in: "```\nunclosed") == [
            .code(language: nil, source: "unclosed"),
        ])
    }

    @Test func copyContentUsesVisibleMessageThenSafeFallbacks() {
        let normal = ChatMessage(role: .assistant, text: "copy **exact markdown**", reasoningText: "hidden")
        let reasoning = ChatMessage(role: .assistant, text: "", reasoningText: "reasoning")
        let tool = ToolActivity(id: "1", name: "lookup", result: "tool result")
        let richOnly = ChatMessage(role: .assistant, text: "", toolActivities: [tool])
        let cardOnly = ChatMessage(role: .assistant, text: "", transcriptCards: [
            .init(lifecycle: .pending, payload: .notice(.init(title: "Maintenance", message: "Tonight")))
        ])

        #expect(TranscriptClipboardContent.messageText(normal) == "copy **exact markdown**")
        #expect(TranscriptClipboardContent.messageText(reasoning) == "reasoning")
        #expect(TranscriptClipboardContent.messageText(richOnly) == "tool result")
        #expect(TranscriptClipboardContent.messageText(cardOnly).contains("Maintenance"))
    }

    @Test func linkPolicyAllowsOnlyExplicitSafeSchemes() throws {
        for value in ["https://example.com/report", "http://localhost:8080/status", "mailto:hello@example.com?subject=Hi"] {
            let url = try #require(URL(string: value))
            guard case .allowed(let allowed) = TranscriptLinkPolicy.decision(for: url) else {
                Issue.record("Expected allowed link: \(value)")
                continue
            }
            #expect(allowed == url)
        }
        for value in [
            "javascript:alert(1)", "file:///etc/passwd", "filicon://conversation/1",
            "https://user:password@example.com", "https://example.com/%0Aopen",
            "https://example.com\\@attacker.invalid", "mailto:not-an-address",
            "mailto:hello@example.com?bcc=attacker@example.com",
        ] {
            let url = try #require(URL(string: value))
            #expect(TranscriptLinkPolicy.decision(for: url) == .blocked)
        }
    }

    @Test func toolCardsClassifyProviderNeutralSemanticsAndRedactSecrets() {
        let fixtures: [(String, String, ToolCardKind)] = [
            ("slack.post_message", #"{"channel":"alerts","url":"https://example.com/thread"}"#, .connector),
            ("send_email", #"{"to":"team@example.com","subject":"Status"}"#, .email),
            ("request_permission", #"{"scope":"calendar.read","reason":"Schedule meeting"}"#, .permission),
            ("store_credential", #"{"service":"example","api_key":"should-not-render","nested":{"password":"also-hidden"}}"#, .secret),
            ("create_schedule", #"{"schedule":"0 9 * * 1","timezone":"Asia/Taipei"}"#, .automation),
            ("delegate_agent", #"{"agent":"researcher","task":"Summarize"}"#, .cloudAgent),
            ("lookup", #"{"query":"Taipei"}"#, .generic),
        ]

        for fixture in fixtures {
            let activity = ToolActivity(id: ToolCallID(rawValue: UUID().uuidString), name: ToolName(rawValue: fixture.0), argumentsJSON: fixture.1)
            let card = ToolCardClassifier.presentation(for: activity)
            #expect(card.kind == fixture.2)
        }

        let secret = ToolActivity(id: "secret", name: "store_secret", argumentsJSON: #"{"api_key":"literal-key","nested":{"access_token":"literal-token"}}"#)
        let card = ToolCardClassifier.presentation(for: secret)
        #expect(card.redactedArguments.contains("••••••••"))
        #expect(!card.redactedArguments.contains("literal-key"))
        #expect(!card.redactedArguments.contains("literal-token"))

        let nonstandardSecret = ToolActivity(
            id: "secret-value", name: "store_credential",
            argumentsJSON: #"{"service":"example","value":"unlabeled-sensitive-value"}"#,
            result: "the-secret-result"
        )
        let protectedCard = ToolCardClassifier.presentation(for: nonstandardSecret)
        #expect(!protectedCard.redactedArguments.contains("unlabeled-sensitive-value"))
        #expect(protectedCard.redactedResult == "Protected result hidden")

        let malformedSecret = ToolActivity(
            id: "malformed", name: "request_secret", argumentsJSON: "literal-secret-that-is-not-json"
        )
        #expect(ToolCardClassifier.presentation(for: malformedSecret).redactedArguments == "Protected content hidden")
    }

    @Test func authoritativeCardsHaveDistinctLifecyclePresentationsAndOnlyTypedActions() {
        let cards: [TranscriptCard] = [
            .init(lifecycle: .succeeded, payload: .widget(.init(title: "Widget"))),
            .init(lifecycle: .draft, payload: .draft(.init(draftID: "d", channel: "email", body: "Body"))),
            .init(lifecycle: .waiting, payload: .autoReview(.init(reviewID: "r", title: "Review"))),
            .init(lifecycle: .pending, payload: .listener(.init(listenerID: "l", connector: "Slack", event: "message"))),
            .init(lifecycle: .provided, payload: .secretRequest(.init(requestID: "s", service: "GitHub"))),
            .init(lifecycle: .connected, payload: .connector(.init(connectorID: "c", service: "Linear", title: "Connector"))),
            .init(lifecycle: .denied, payload: .localToolPermission(.init(requestID: "p", toolName: "read", scope: "workspace"))),
            .init(lifecycle: .retired, payload: .notice(.init(title: "Notice", message: "Old"))),
            .init(lifecycle: .running, payload: .timeline(.init(eventKind: "channel_joined", channel: "alerts"))),
            .init(lifecycle: .running, payload: .cloudAgent(.init(agentID: "a", bcID: "bc", threadID: "t", title: "Agent"))),
            .init(lifecycle: .succeeded, payload: .fileOperation(.init(operationID: "f", operation: "edit", path: "a.swift", diff: "+x"))),
            .init(lifecycle: .failed, payload: .shell(.init(operationID: "sh", commandSummary: "swift test", exitCode: 1))),
        ]
        let presentations = cards.map(TranscriptCardPresenter.presentation)
        #expect(Set(presentations.map(\.kind)).count == cards.count)
        #expect(presentations.map(\.subtitle).allSatisfy { !$0.isEmpty })
        #expect(presentations[4].detail == "Credential required")
        #expect(presentations[9].fields.contains(where: { $0.label == "BC ID" && $0.value == "bc" }))
        #expect(presentations[10].longText == "+x")

        let safe = TranscriptCardAction(id: "send", label: "Send", intent: .sendDraft(draftID: "d"))
        let unsafe = TranscriptCardAction(id: "future", label: "Run", intent: .unknown(type: "run_anything", payload: .object(["command": .string("unsafe")])) )
        #expect(safe.intent.isRendererSafe)
        #expect(!unsafe.intent.isRendererSafe)
    }

    @Test func toolCardsDoNotPromoteUntrustedSchemesOrInterpretMarkup() {
        let activity = ToolActivity(
            id: "untrusted", name: "connector_action",
            argumentsJSON: #"{"safe":"https://example.com/thread","unsafe":"javascript:alert(1)"}"#,
            status: .succeeded,
            result: "<script>never execute()</script>"
        )
        let card = ToolCardClassifier.presentation(for: activity)
        #expect(card.links.map(\.absoluteString) == ["https://example.com/thread"])
        #expect(card.redactedResult == "<script>never execute()</script>")
    }

    @Test func replyPreviewRepresentsTextAttachmentsReasoningToolsAndMissingTargets() {
        let attachment = AttachmentMetadata(
            id: String(repeating: "b", count: 64), filename: "diagram.png",
            mimeType: "image/png", byteCount: 4, kind: .image
        )
        let cases: [(ChatMessage?, ReplyPreviewKind, String)] = [
            (ChatMessage(role: .user, text: "First line\nSecond line"), .text, "First line Second line"),
            (ChatMessage(role: .assistant, text: "", attachments: [attachment]), .attachment, "diagram.png"),
            (ChatMessage(role: .assistant, text: "", reasoningText: "thinking"), .reasoning, "Reasoning"),
            (ChatMessage(role: .assistant, text: "", toolActivities: [ToolActivity(id: "tool", name: "send_email")]), .tool, "Email"),
            (nil, .unavailable, "Unavailable"),
        ]

        for (message, kind, detail) in cases {
            let preview = ReplyPreviewPresentation.make(for: message)
            #expect(preview.kind == kind)
            #expect(preview.detail == detail)
        }
    }
}
