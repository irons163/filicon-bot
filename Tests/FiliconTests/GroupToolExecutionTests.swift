import Foundation
import Testing
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

@Suite("Group tool execution", .timeLimit(.minutes(1)))
struct GroupToolExecutionTests {
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
            #expect(request.tools.map(\.name) == ["fixture_read"])
            #expect(request.messages.contains { $0.text.contains("no built-in Gmail connector") })
            if request.toolExchanges.isEmpty { return try groupCallEvents() }
            #expect(request.toolExchanges[0].results[0].wireText == "private fixture result")
            return [.textDelta("Read completed."), .completed(.stop)]
        })
        let executor = GroupTestExecutor { call, context in
            await probe.execute(context)
            return .init(callID: call.id, content: [.text("private fixture result")])
        }
        let responder = GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog([executor])))
        let produced = try await service.run(groupID: group.id, responder: responder, onMessage: { await probe.record($0) })
        #expect(await probe.contexts.map(\.conversationID) == [group.id])
        #expect(await probe.messages.map { $0.toolActivities.first?.status } == [.pending, .succeeded, .succeeded])
        #expect(produced.map(\.text) == ["Read completed."])
        let reopened = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let stored = await reopened.messages(groupID: group.id)
        #expect(stored.count == 2)
        #expect(stored.last?.toolActivities.first?.status == .succeeded)
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
            request.toolExchanges.isEmpty ? try groupCallEvents() : [.textDelta("Access denied."), .completed(.stop)]
        })
        let executor = GroupTestExecutor { call, _ in .init(callID: call.id, content: [.text("denied")], isError: true) }
        let result = try await service.run(groupID: group.id, responder: GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog([executor]))))
        #expect(result.last?.toolActivities.first?.status == .failed)
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
            return [.textDelta("@everyone hi"), .completed(.stop)]
        })
        let responder = GroupConversationResponder(groupID: group.id, registry: registry, coordinator: .init(registry: registry, toolCatalog: ToolCatalog()))
        let result = try await service.run(groupID: group.id, responder: responder)
        #expect(result.map(\.senderID) == [group.memberIDs[0]])
    }
}
