import Foundation
import Testing
import CustomDump
@testable import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit

private struct GroupScriptProvider: AIProvider {
    let descriptor: ProviderDescriptor
    let script: @Sendable (InferenceRequest) throws -> [InferenceEvent]
    init(tools: Bool = true, script: @escaping @Sendable (InferenceRequest) throws -> [InferenceEvent]) {
        descriptor = .init(id: "group-test", displayName: "Group test", requiresAPIKey: false, supportsToolCalling: tools)
        self.script = script
    }
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            do { for event in try script(request) { continuation.yield(event) }; continuation.finish() }
            catch { continuation.finish(throwing: error) }
        }
    }
}

private struct GroupTestExecutor: ToolExecutor {
    let descriptor = ToolDescriptor(name: "fixture_read", inputSchema: Data("{\"type\":\"object\"}".utf8))
    let executeBody: @Sendable (NormalizedToolCall, ToolContext) async throws -> NormalizedToolResult
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        try await executeBody(call, context)
    }
}

private actor GroupToolProbe {
    var contexts: [ToolContext] = []
    var messages: [RoomMessage] = []
    var cancelled = false
    func execute(_ context: ToolContext) { contexts.append(context) }
    func record(_ message: RoomMessage) { messages.append(message) }
    func didCancel() { cancelled = true }
}

private func groupCallEvents(name: ToolName = "fixture_read") throws -> [InferenceEvent] {
    let call = try NormalizedToolCall(id: "test-call", name: name, argumentsJSON: Data("{}".utf8))
    return [.textDelta("I will read it."), .toolCallStarted(id: call.id, name: name), .toolCallCompleted(call), .completed(.toolUse)]
}

private func groupPublicationEvents(_ text: String) throws -> [InferenceEvent] {
    let call = try NormalizedToolCall(id: "publication", name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": text]))
    return [.toolCallStarted(id: call.id, name: call.name), .toolCallCompleted(call), .completed(.toolUse)]
}

private actor CollaborationResponder: GroupAgentResponder {
    struct Turn: Sendable {
        let agent: AgentProfile
        let history: [RoomMessage]
        let context: GroupTurnContext
    }
    struct Failure: Error {}
    private(set) var turns: [Turn] = []
    let scripts: [String: [[String]]]
    let failingNames: Set<String>
    init(_ scripts: [String: [[String]]], failingNames: Set<String> = []) {
        self.scripts = scripts; self.failingNames = failingNames
    }
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        Issue.record("GroupService must provide collaboration context")
        return []
    }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext, onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void) async throws -> [String] {
        let index = turns.filter { $0.agent.id == agent.id }.count
        turns.append(.init(agent: agent, history: history, context: context))
        if failingNames.contains(agent.name) { throw Failure() }
        let script = scripts[agent.name] ?? []
        return index < script.count ? script[index] : ["PASS"]
    }
}

@Suite("Group collaboration", .timeLimit(.minutes(1)))
struct GroupCollaborationTests {
    private func fixture() async throws -> (URL, AgentService, GroupService, AgentGroup) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-collaboration-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let engineer = try await agents.create(name: "Engineer", summary: "Implement and test", providerID: "group-test", modelID: "test")
        let designer = try await agents.create(name: "Designer", summary: "Review layout and usability", providerID: "group-test", modelID: "test")
        let service = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let group = try await service.create(name: "Product team", summary: "Build an accessible inventory website", memberIDs: [engineer.id, designer.id])
        _ = try await service.postUserMessage("Build the website together and review the result.", groupID: group.id)
        return (root, agents, service, group)
    }

    @Test func engineerDesignerHandoffContinuesAcrossRoundsWithNewContext() async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let responder = CollaborationResponder([
            "Engineer": [["Implemented the layout."], ["Fixed the contrast based on the review."]],
            "Designer": [["Reviewed the layout: improve button contrast."], ["Reviewed the fix: contrast is now correct."]]
        ])
        let result = try await service.run(groupID: group.id, responder: responder)
        let turns = await responder.turns
        expectNoDifference(turns.map { $0.agent.name }, ["Engineer", "Designer", "Engineer", "Designer"])
        expectNoDifference(turns.map { $0.context.round }, [0, 0, 1, 2])
        expectNoDifference(result.map(\.senderID), [group.memberIDs[0], group.memberIDs[1], group.memberIDs[0], group.memberIDs[1]])
        expectNoDifference(turns[2].context.group.summary, group.summary)
        expectNoDifference(turns[2].context.members.map(\.summary), ["Implement and test", "Review layout and usability"])
        expectNoDifference(turns[2].history.filter { turns[2].context.newMessageIDs.contains($0.id) }.map(\.text), [result[1].text])
        expectNoDifference(turns[3].history.filter { turns[3].context.newMessageIDs.contains($0.id) }.map(\.text), [result[2].text])
    }

    @Test func passIsVisibleAndCanBeFollowedByUsefulWork() async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let responder = CollaborationResponder([
            "Engineer": [["PASS"], ["Implemented the new design."]],
            "Designer": [["Here is the design specification."], ["Checked the implementation."]]
        ])
        let result = try await service.run(groupID: group.id, responder: responder)
        expectNoDifference(result.map(\.text), ["Here is the design specification.", "Implemented the new design.", "Checked the implementation."])
        let notices = await service.messages(groupID: group.id).filter { $0.memberOutcome != nil }
        expectNoDifference(notices.map(\.memberOutcome), [.passed])
        expectNoDifference(notices.map(\.senderID), [group.memberIDs[0]])
    }

    @Test func allPassStopsAndStartingMemberRotatesOnNextRequest() async throws {
        let (root, agents, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CollaborationResponder([:])
        let result = try await service.run(groupID: group.id, responder: first)
        let firstTurns = await first.turns
        expectNoDifference(result, [])
        expectNoDifference(firstTurns.map { $0.agent.name }, ["Engineer", "Designer"])
        let reopened = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let notices = await reopened.messages(groupID: group.id).compactMap(\.memberOutcome)
        expectNoDifference(notices, [.passed, .passed])
        _ = try await reopened.postUserMessage("Another task", groupID: group.id)
        let second = CollaborationResponder([:])
        _ = try await reopened.run(groupID: group.id, responder: second)
        let secondTurns = await second.turns
        expectNoDifference(secondTurns.map { $0.agent.name }, ["Designer", "Engineer"])
    }

    @Test func partialFailureIsPersistedAndPublishedWithoutRetryingFailedMember() async throws {
        let (root, agents, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let responder = CollaborationResponder(["Engineer": [["Implemented."]]], failingNames: ["Designer"])
        let probe = GroupToolProbe()
        let result = try await service.run(groupID: group.id, responder: responder, onMessage: { await probe.record($0) })
        expectNoDifference(result.map(\.text), ["Implemented."])
        let turns = await responder.turns
        expectNoDifference(turns.map { $0.agent.name }, ["Engineer", "Designer"])
        let failure = try #require(await probe.messages.last)
        expectNoDifference(failure.senderID, group.memberIDs[1])
        expectNoDifference(failure.memberOutcome, .failed)
        expectNoDifference(failure.text, "")
        let reopened = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let restored = try #require(await reopened.messages(groupID: group.id).last)
        expectNoDifference(restored.id, failure.id)
        expectNoDifference(restored.memberOutcome, .failed)
        expectNoDifference(restored.senderID, group.memberIDs[1])
    }

    @Test func duplicatesDoNotKeepConversationAlive() async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let responder = CollaborationResponder([
            "Engineer": [["Done."], ["  Done.  "]],
            "Designer": [["Reviewed."]]
        ])
        let result = try await service.run(groupID: group.id, responder: responder)
        expectNoDifference(result.map(\.text), ["Done.", "Reviewed."])
        let turns = await responder.turns
        expectNoDifference(turns.count, 3)
    }

    @Test func messageAndPerTurnCapsRemainBounded() async throws {
        let (root, agents, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = group.memberIDs
        for index in 2..<6 { ids.append(try await agents.create(name: "Member \(index)").id) }
        try await service.updateMembers(groupID: group.id, memberIDs: ids)
        let names = ["Engineer", "Designer"] + (2..<6).map { "Member \($0)" }
        let responder = CollaborationResponder(Dictionary(uniqueKeysWithValues: names.map { ($0, [["\($0) one", "\($0) two", "never published"]]) }))
        let result = try await service.run(groupID: group.id, responder: responder)
        expectNoDifference(result.count, 10)
        let turns = await responder.turns
        expectNoDifference(turns.count, 5)
        #expect(!result.contains { $0.text == "never published" })
    }

    @Test func roleMetadataAndNamedIncrementalHistoryReachProviderWithoutPrivateInstructions() async throws {
        let (root, agents, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var engineer = try #require(await agents.profile(id: group.memberIDs[0]))
        engineer.instructions = "PRIVATE-ENGINEER-INSTRUCTIONS"
        try await agents.update(engineer)
        let registry = ProviderRegistry()
        await registry.register(GroupScriptProvider { request in
            if !request.toolExchanges.isEmpty { return [.completed(.stop)] }
            let metadataText = try #require(request.messages.first { $0.text.hasPrefix("Room metadata") }?.text)
            let metadata = try #require(JSONSerialization.jsonObject(with: Data(metadataText.split(separator: "\n", maxSplits: 1)[1].utf8)) as? [String: Any])
            expectNoDifference(metadata["name"] as? String, group.name)
            expectNoDifference(metadata["goal"] as? String, group.summary)
            let members = try #require(metadata["members"] as? [[String: Any]])
            expectNoDifference(members.compactMap { $0["summary"] as? String }, ["Implement and test", "Review layout and usability"])
            #expect(members.allSatisfy { $0["instructions"] == nil })
            let isEngineer = request.messages[0].text.contains("Your name is Engineer")
            if !isEngineer {
                #expect(!request.messages.contains { $0.text.contains("PRIVATE-ENGINEER-INSTRUCTIONS") })
                let transcript = try #require(request.messages.first { $0.text.hasPrefix("Group conversation context") })
                #expect(transcript.text.contains("Engineer"))
                #expect(transcript.text.contains("isNewSinceYourLastTurn"))
            }
            expectNoDifference(request.messages.last?.text, "Build the website together and review the result.")
            let round = metadata["round"] as? Int
            return round == 1 ? try groupPublicationEvents(isEngineer ? "Implementation ready." : "Design reviewed.") : [.textDelta("PASS"), .completed(.stop)]
        })
        let responder = GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog()))
        let result = try await service.run(groupID: group.id, responder: responder)
        expectNoDifference(result.map(\.text), ["Implementation ready.", "Design reviewed."])
    }
}

@Suite("Group tool execution", .timeLimit(.minutes(1)))
struct GroupToolExecutionTests {
    @Test(arguments: [false, true], [false, true])
    func unpublishedFinalTextIsPrivateOnlyWhenPublicationToolIsAvailable(tools: Bool, catalog: Bool) async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry()
        await registry.register(GroupScriptProvider(tools: tools) { request in
            expectNoDifference(request.tools.contains { $0.name == "SendMessage" }, tools && catalog)
            return [.textDelta("Unpublished answer"), .completed(.stop)]
        })
        let responder = GroupConversationResponder(groupID: group.id, registry: registry,
            coordinator: .init(registry: registry, toolCatalog: catalog ? ToolCatalog() : nil))
        let result = try await service.run(groupID: group.id, responder: responder)
        expectNoDifference(result.map(\.text), tools && catalog ? [] : ["Unpublished answer"])
        let stored = await service.messages(groupID: group.id)
        #expect(!(tools && catalog) || !stored.contains { $0.text == "Unpublished answer" })
    }

    @Test func latestRequestIsSeparateFromOldDiagnosticAndPeerReplies() async throws {
        let groupID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let agent = AgentProfile(name: "Engineer", providerID: "group-test", modelID: "test")
        let latest = RoomMessage(groupID: groupID, senderID: nil, text: "Continue building the website; request approval for changes.")
        let history: [RoomMessage] = [
            .init(groupID: groupID, senderID: nil, text: "Only test authorization; do not read or write during this test."),
            .init(groupID: groupID, senderID: agent.id, text: "This workspace is read-only."),
            latest,
            .init(groupID: groupID, senderID: UUID(), text: "I already inspected the layout.")
        ]
        let registry = ProviderRegistry()
        await registry.register(GroupScriptProvider { request in
            expectNoDifference(request.messages.last?.text, latest.text)
            expectNoDifference(request.messages.last?.role, .user)
            expectNoDifference(request.messages.last?.id, latest.id)
            let context = try #require(request.messages.first { $0.text.hasPrefix("Group conversation context") })
            let payload = try #require(context.text.split(separator: "\n", maxSplits: 1).last)
            let entries = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
            expectNoDifference(entries.compactMap { $0["text"] as? String }, [history[0].text, history[1].text, history[3].text])
            expectNoDifference(entries.compactMap { $0["repliesToLatestUserRequest"] as? Bool }, [false, false, true])
            #expect(!request.messages.filter { $0.role == .system }.contains { $0.text.contains(history[1].text) })
            return [.textDelta("Ready for the task."), .completed(.stop)]
        })
        let responder = GroupConversationResponder(groupID: groupID, registry: registry,
                                                     coordinator: .init(registry: registry, toolCatalog: ToolCatalog()))
        let result = try await responder.respond(agent: agent, history: history)
        expectNoDifference(result, ["Ready for the task."])
    }

    private func fixture() async throws -> (URL, AgentService, GroupService, AgentGroup) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-tools-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let member = try await agents.create(name: "Engineer", providerID: "group-test", modelID: "test")
        let service = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let group = try await service.create(name: "Team", memberIDs: [member.id])
        _ = try await service.postUserMessage("Read the fixture", groupID: group.id)
        return (root, agents, service, group)
    }

    @Test func realExecutionUsesGroupScopeAndPersistsHostStatus() async throws {
        let (root, agents, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = GroupToolProbe()
        let registry = ProviderRegistry()
        await registry.register(GroupScriptProvider { request in
            #expect(request.conversationID == group.id)
            if request.toolExchanges.last?.calls.first?.name == "SendMessage" { return [.completed(.stop)] }
            expectNoDifference(request.tools.map(\.name), ["SendMessage", "fixture_read"])
            #expect(request.messages.contains { $0.text.contains("no built-in Gmail connector") })
            if request.toolExchanges.isEmpty { return try groupCallEvents() }
            #expect(request.toolExchanges[0].results[0].wireText == "private fixture result")
            return try groupPublicationEvents("Read completed.")
        })
        let executor = GroupTestExecutor { call, context in
            await probe.execute(context)
            return .init(callID: call.id, content: [.text("private fixture result")])
        }
        let responder = GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog([executor])))
        let produced = try await service.run(groupID: group.id, responder: responder, onMessage: { await probe.record($0) })
        #expect(await probe.contexts.map(\.conversationID) == [group.id])
        #expect(await probe.messages.first?.toolActivities.first?.status == .pending)
        #expect(await probe.messages.last?.toolActivities.first?.status == .succeeded)
        #expect(produced.map(\.text) == ["Read completed."])
        let reopened = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let stored = await reopened.messages(groupID: group.id)
        expectNoDifference(stored.count, 3) // user, host activity, explicit publication
        expectNoDifference(stored[1].toolActivities.map(\.status), [.succeeded, .succeeded])
        expectNoDifference(stored.last?.toolActivities, [])
        #expect(stored.last?.id == produced.first?.id)
        let json = try String(contentsOf: root.appending(path: "groups.json"), encoding: .utf8)
        #expect(!json.contains("private fixture result"))
        #expect(!json.contains("argumentsJSON"))
    }

    @Test func textOnlyCannotEmitExecutionCardsFromProse() async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = GroupToolProbe()
        await registry.register(GroupScriptProvider(tools: false) { request in
            #expect(request.tools.isEmpty)
            #expect(request.messages.contains { $0.text.contains("text-only response") })
            return [.textDelta("I created a Gmail installation card."), .completed(.stop)]
        })
        let executor = GroupTestExecutor { call, context in
            await probe.execute(context)
            return .init(callID: call.id, content: [])
        }
        let result = try await service.run(groupID: group.id, responder: GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog([executor]))))
        #expect(await probe.contexts.isEmpty)
        #expect(result.count == 1)
        #expect(result[0].toolActivities.isEmpty)
    }

    @Test func unknownInstallationToolFailsWithoutExecution() async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry()
        await registry.register(GroupScriptProvider { _ in try groupCallEvents(name: "request_plugin_install") })
        let responder = GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog()))
        await #expect(throws: ToolLoopError.unknownTool("request_plugin_install")) {
            _ = try await service.run(groupID: group.id, responder: responder)
        }
        #expect(await service.messages(groupID: group.id).last?.toolActivities.first?.status == .failed)
    }

    @Test func errorResultIsNotASuccess() async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry()
        await registry.register(GroupScriptProvider { request in
            if request.toolExchanges.last?.calls.first?.name == "SendMessage" { return [.completed(.stop)] }
            return request.toolExchanges.isEmpty ? try groupCallEvents() : try groupPublicationEvents("Access denied.")
        })
        let executor = GroupTestExecutor { call, _ in .init(callID: call.id, content: [.text("denied")], isError: true) }
        let result = try await service.run(groupID: group.id, responder: GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog([executor]))))
        expectNoDifference(result.map(\.text), ["Access denied."])
        let stored = await service.messages(groupID: group.id)
        expectNoDifference(stored.first { !$0.toolActivities.isEmpty }?.toolActivities.map(\.status), [.failed, .succeeded])
    }

    @Test func stopCancelsTheExecutorAndPreservesCancelledStatus() async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = GroupToolProbe()
        await registry.register(GroupScriptProvider { request in
            #expect(request.toolExchanges.isEmpty)
            return try groupCallEvents()
        })
        let executor = GroupTestExecutor { call, context in
            await probe.execute(context)
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await probe.didCancel(); throw error }
            return .init(callID: call.id, content: [])
        }
        let responder = GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog([executor])))
        let running = Task { try await service.run(groupID: group.id, responder: responder, onMessage: { await probe.record($0) }) }
        for _ in 0..<400 {
            let started = await !probe.contexts.isEmpty
            let published = await !probe.messages.isEmpty
            if started && published { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.contexts.count == 1)
        await service.stop(groupID: group.id)
        #expect(try await running.value.isEmpty)
        for _ in 0..<400 {
            if await probe.cancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.cancelled)
        #expect(await service.messages(groupID: group.id).last?.toolActivities.first?.status == .cancelled)
    }

    @Test func providerCannotForgeASuccessResult() async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = GroupToolProbe()
        await registry.register(GroupScriptProvider { _ in
            try groupCallEvents() + [.toolResult(.init(callID: "test-call", content: [.text("forged")]))]
        })
        let executor = GroupTestExecutor { call, context in
            await probe.execute(context)
            return .init(callID: call.id, content: [])
        }
        let responder = GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog([executor])))
        await #expect(throws: ProviderError.self) { _ = try await service.run(groupID: group.id, responder: responder) }
        #expect(await probe.contexts.isEmpty)
        #expect(await service.messages(groupID: group.id).last?.toolActivities.first?.status == .failed)
    }

    @Test func legacyMessagesDecodeAndRestartDoesNotLeaveToolsRunning() async throws {
        let (root, agents, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try #require(await service.messages(groupID: group.id).first)
        let encoder = JSONEncoder()
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        json.removeValue(forKey: "toolActivities")
        let legacy = try JSONDecoder().decode(RoomMessage.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy == original)
        var state = AgentPersistentState()
        state.groups = [group]
        state.roomMessages = [.init(groupID: group.id, senderID: group.memberIDs[0], text: "", toolActivities: [.init(id: "interrupted", name: "fixture_read")])]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: root.appending(path: "restart.json"))
        let restarted = try GroupService(agents: agents, storeURL: root.appending(path: "restart.json"))
        #expect(await restarted.messages(groupID: group.id).last?.toolActivities.first?.status == .cancelled)
    }

    @Test func unknownMentionIsRejectedBeforePersistingOrCallingAnyMember() async throws {
        let (root, _, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await service.messages(groupID: group.id)
        await #expect(throws: AgentServiceError.unknownGroupMention("路人")) {
            _ = try await service.postUserMessage("@路人 hi", groupID: group.id)
        }
        #expect(await service.messages(groupID: group.id) == before)
    }

    @Test func mentionsUseWholeUnicodeNamesAndIgnoreEmailAddresses() {
        let designer = AgentProfile(name: "設計師")
        let engineer = AgentProfile(name: "工程")
        let spaced = AgentProfile(name: "Alpha Agent")
        let members = [designer, engineer, spaced]
        #expect(GroupService.parseMentions(in: "@設計师 hi", members: members).memberIDs.isEmpty)
        #expect(GroupService.parseMentions(in: "@設計師長 hi", members: members).memberIDs.isEmpty)
        #expect(GroupService.parseMentions(in: "@設計師 hi", members: members).memberIDs == [designer.id])
        #expect(GroupService.unknownMentions(in: "@工程 @Alpha Agent @everyone @all", members: members).isEmpty)
        #expect(GroupService.unknownMentions(in: "email test@example.com / test+tag@example.com", members: members).isEmpty)
        #expect(GroupService.unknownMentions(in: "@路人 @工程師 @everyoneElse", members: members) == ["路人", "工程師", "everyoneelse"])
    }

    @Test func targetedMemberCannotEscalateRecipientsByEchoingEveryone() async throws {
        let (root, agents, service, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try await agents.create(name: "Other", providerID: "group-test", modelID: "test")
        try await service.updateMembers(groupID: group.id, memberIDs: group.memberIDs + [other.id])
        _ = try await service.postUserMessage("@Engineer hi", groupID: group.id)
        let registry = ProviderRegistry()
        await registry.register(GroupScriptProvider { request in
            #expect(request.messages[0].text.contains("Your name is Engineer"))
            return request.toolExchanges.isEmpty ? try groupPublicationEvents("@everyone hi") : [.completed(.stop)]
        })
        let responder = GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog()))
        let result = try await service.run(groupID: group.id, responder: responder)
        #expect(result.map(\.senderID) == [group.memberIDs[0]])
    }
}
