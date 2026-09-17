import AppKit
import Testing
import FiliconAgents
@testable import Filicon

@Suite("Group mention completion")
struct GroupMentionCompletionTests {
    private let engineer = AgentProfile(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, name: "工程師")
    private let designer = AgentProfile(id: UUID(uuidString: "22222222-2222-4333-8444-555555555555")!, name: "設計師")

    private func query(_ text: String, memberNames: [String] = []) throws -> GroupMentionCompletion.Query {
        try #require(GroupMentionCompletion.query(in: text, selection: NSRange(location: text.utf16.count, length: 0), memberNames: memberNames))
    }

    @Test func listsOnlyActiveMembersInGroupOrderAndEveryone() throws {
        let outsider = AgentProfile(name: "路人")
        let archived = AgentProfile(name: "封存成員", archivedAt: Date(timeIntervalSince1970: 0))
        let result = GroupMentionCompletion.candidates(for: try query("@"), memberIDs: [designer.id, archived.id, engineer.id], agents: [outsider, engineer, archived, designer])
        #expect(result.map(\.name) == ["設計師", "工程師", "everyone"])
        #expect(GroupMentionCompletion.candidates(for: try query("@"), memberIDs: [], agents: [outsider]).isEmpty)
    }

    @Test func filtersCJKAndUnknownMembers() throws {
        let members = [engineer, designer]
        #expect(GroupMentionCompletion.candidates(for: try query("請 @工"), memberIDs: members.map(\.id), agents: members).map(\.name) == ["工程師"])
        #expect(GroupMentionCompletion.candidates(for: try query("@路人"), memberIDs: members.map(\.id), agents: members).isEmpty)
    }

    @Test func supportsMultiwordNamesAndCaseInsensitiveHandles() throws {
        let agent = AgentProfile(name: "Sales Outbound")
        for fragment in ["@sales o", "@OUTBOUND", "@salesout"] {
            #expect(GroupMentionCompletion.candidates(for: try query(fragment, memberNames: [agent.name]), memberIDs: [agent.id], agents: [agent]).map(\.name) == [agent.name])
        }
    }

    @Test func ignoresEmailsCompletedTokensSelectionsAndInvalidCaret() {
        for text in ["me@example.com", "x.y@work", "user+tag@host", "a-b@host", "hi @工程師 ", "@工程師\nnext", "no mention"] {
            #expect(GroupMentionCompletion.query(in: text, selection: NSRange(location: text.utf16.count, length: 0)) == nil)
        }
        #expect(GroupMentionCompletion.query(in: "@工程師", selection: NSRange(location: 0, length: 4)) == nil)
        #expect(GroupMentionCompletion.query(in: "@", selection: NSRange(location: 99, length: 0)) == nil)
        #expect(GroupMentionCompletion.query(in: "@", selection: NSRange(location: NSNotFound, length: 0)) == nil)
    }

    @Test func unicodeCaretAndInsertionPreserveSurroundingText() throws {
        let text = "👩🏽‍💻 請 @工程 今天聊聊"
        let caret = "👩🏽‍💻 請 @工".utf16.count
        let query = try #require(GroupMentionCompletion.query(in: text, selection: NSRange(location: caret, length: 0)))
        let candidate = GroupMentionCompletion.Candidate(id: engineer.id.uuidString, name: engineer.name, agent: engineer)
        let insertion = try #require(GroupMentionCompletion.inserting(candidate, into: text, query: query))
        #expect(insertion.text == "👩🏽‍💻 請 @工程師 今天聊聊")
        #expect(insertion.selection.location == "👩🏽‍💻 請 @工程師 ".utf16.count)
        #expect(GroupMentionCompletion.query(in: insertion.text, selection: insertion.selection) == nil)
    }

    @Test func insertsFullNameWithOneSpaceAndRoutesToMember() throws {
        let agent = AgentProfile(name: "Sales Outbound")
        let candidate = GroupMentionCompletion.Candidate(id: agent.id.uuidString, name: agent.name, agent: agent)
        let result = try #require(GroupMentionCompletion.inserting(candidate, into: "@Sa", query: query("@Sa")))
        #expect(result.text == "@Sales Outbound ")
        #expect(result.selection.location == result.text.utf16.count)
        #expect(GroupService.parseMentions(in: result.text, members: [agent]).memberIDs == [agent.id])
        #expect(GroupService.unknownMentions(in: result.text, members: [agent]).isEmpty)
    }

    @Test func everyoneInsertsCanonicalUntranslatedHandle() throws {
        let result = try #require(GroupMentionCompletion.inserting(.everyone, into: "@eve", query: query("@eve")))
        #expect(result.text == "@everyone ")
        #expect(GroupService.parseMentions(in: result.text, members: [engineer]).everyone)
    }

    @Test func secondMentionAndNewlineRemainIntact() throws {
        let text = "@工程師\n@設"
        let candidate = GroupMentionCompletion.Candidate(id: designer.id.uuidString, name: designer.name, agent: designer)
        let result = try #require(GroupMentionCompletion.inserting(candidate, into: text, query: query(text)))
        #expect(result.text == "@工程師\n@設計師 ")
        #expect(GroupService.parseMentions(in: result.text, members: [engineer, designer]).memberIDs == [engineer.id, designer.id])
    }

    @Test func keyboardSelectionWrapsAndHandlesEmptyList() {
        #expect(GroupMentionCompletion.movedSelection(0, by: -1, count: 3) == 2)
        #expect(GroupMentionCompletion.movedSelection(2, by: 1, count: 3) == 0)
        #expect(GroupMentionCompletion.movedSelection(0, by: 1, count: 0) == 0)
    }

    @Test func ordinaryTextAfterCompletedMentionDoesNotReopenTheMenu() {
        for text in ["@工程師 hi", "@everyone 大家好", "@Sales Outbound please help", "@unknown is not here"] {
            #expect(GroupMentionCompletion.query(in: text, selection: NSRange(location: text.utf16.count, length: 0), memberNames: ["工程師", "Sales Outbound"]) == nil)
        }
    }

    @MainActor @Test func editorMapsOnlyUnmodifiedNavigationAndPreservesOptionReturn() throws {
        #expect(GroupComposerTextView.command(for: try key(125)) == .next)
        #expect(GroupComposerTextView.command(for: try key(126)) == .previous)
        #expect(GroupComposerTextView.command(for: try key(36)) == .submit)
        #expect(GroupComposerTextView.command(for: try key(36, modifiers: .option)) == nil)
        #expect(GroupComposerTextView.command(for: try key(125, modifiers: .shift)) == nil)
        #expect(GroupComposerTextView.command(for: try key(48)) == .accept)
        #expect(GroupComposerTextView.command(for: try key(53)) == .dismiss)
    }

    @MainActor @Test func handledReturnDoesNotInsertANewline() throws {
        let editor = GroupComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.string = "@工"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        var commands: [GroupComposerCommand] = []
        editor.onCommand = { command, text, selection in
            commands.append(command)
            #expect(text == "@工")
            #expect(selection.location == 2)
            return true
        }
        editor.keyDown(with: try key(36))
        #expect(commands == [.submit])
        #expect(editor.string == "@工")
    }

    @MainActor @Test func markedTextDoesNotTriggerCompletionOrSubmit() throws {
        let editor = GroupComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.setMarkedText("設", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        var invoked = false
        editor.onCommand = { _, _, _ in invoked = true; return true }
        editor.keyDown(with: try key(36))
        #expect(!invoked)
    }

    @MainActor private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: code == 36 ? "\r" : "", isARepeat: false, keyCode: code))
    }
}
