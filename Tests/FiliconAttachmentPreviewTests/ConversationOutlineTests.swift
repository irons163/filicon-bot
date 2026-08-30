import Foundation
import Testing
import FiliconDomain
@testable import Filicon

@Suite("Conversation outline")
struct ConversationOutlineTests {
    @Test func projectsMessagesReasoningToolsAndCardsInOrder() throws {
        let user = ChatMessage(role: .user, text: "Please inspect this")
        var assistant = ChatMessage(role: .assistant, text: "I found an issue")
        assistant.reasoningText = "Checking the implementation"
        assistant.toolActivities = [
            ToolActivity(id: "call-1", name: "read_file", argumentsJSON: #"{"path":"a.swift"}"#, status: .succeeded, result: "contents")
        ]
        assistant.transcriptCards = [
            TranscriptCard(lifecycle: .waiting, payload: .notice(.init(title: "Attention", message: "Review this")))
        ]

        let items = ConversationOutlineProjection.make(messages: [user, assistant])
        #expect(items.map(\.kind) == [.user, .assistantText, .thinking, .toolCall, .card])
        #expect(items[0].messageID == user.id)
        #expect(items[3].label == "Read File")
        #expect(items[3].detail.contains("a.swift"))
        #expect(items[4].status == "waiting")
    }

    @Test func boundsPreviewAndDetail() {
        let longLine = String(repeating: "x", count: 25_000)
        let item = ConversationOutlineProjection.make(messages: [.init(role: .assistant, text: longLine)])[0]
        #expect(item.preview.count == 240)
        #expect(item.detail.count == 20_000)
    }
}
