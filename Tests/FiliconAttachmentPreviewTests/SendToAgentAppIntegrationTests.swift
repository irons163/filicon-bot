import Foundation
import AppKit
import CSQLite
import Testing
import CustomDump
@testable import Filicon
import FiliconAgents
import FiliconDomain
import FiliconProviderKit
import FiliconAutoReview
import FiliconAppServices

private actor AgentWakeProbe {
    var wakes: [UUID] = []
    var pausesAfterWake = false
    var inspectedMessages: [ChatMessage] = []
    func record(_ id: UUID) { wakes.append(id) }
    func pauseAfterWake() { pausesAfterWake = true }
    func inspect(_ messages: [ChatMessage]) { inspectedMessages = messages }
}

private struct PeerImageAppProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "delegate-fixture", displayName: "Image fixture", requiresAPIKey: false)
    let recipient: UUID
    let image: AttachmentMetadata
    let bytes: Data
    let probe: AgentWakeProbe
    func models() async throws -> [AIModel] { [.init(id: "test", capabilities: .init(inputModalities: [.text, .image]))] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if request.messages.last?.text.hasPrefix("Incoming peer message") == true {
                        await probe.record(recipient)
                        let incoming = try #require(request.messages.last(where: { !$0.attachments.isEmpty }))
                        expectNoDifference(request.attachmentsByMessageID[incoming.id]?.map(\.data), [bytes])
                        let args: [String: Any] = ["text": "Reviewed image", "images": [image.id]]
                        let result = try await executeTool(.init(id: "publish-image", name: "SendMessage",
                            argumentsJSON: JSONSerialization.data(withJSONObject: args)))
                        #expect(!result.isError)
                    } else {
                        let args: [String: Any] = ["recipientID": recipient.uuidString, "message": "Review this image", "images": [image.id]]
                        _ = try await executeTool(.init(id: "delegate-image", name: "SendToAgent",
                            argumentsJSON: JSONSerialization.data(withJSONObject: args)))
                    }
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct PeerQuestionAppProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "delegate-fixture", displayName: "Question fixture", requiresAPIKey: false)
    let recipient: UUID
    let probe: AgentWakeProbe
    let pauseAnswer: Bool
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let last = request.messages.last?.text ?? ""
                    if last.hasPrefix("Incoming peer message") {
                        _ = try await executeTool(.init(id: "ask", name: "SendMessage", argumentsJSON: Data(#"{"type":"widget","widget":{"prompt":"Which layout?","options":[{"label":"Compact"},{"label":"Spacious"}],"allowCustom":true}}"#.utf8)))
                        Issue.record("Question must suspend")
                    } else if last.hasPrefix("Human answer") {
                        #expect(last.contains("grants no tool access"))
                        await probe.record(recipient)
                        if pauseAnswer { try await Task.sleep(for: .seconds(30)) }
                        _ = try await executeTool(.init(id: "answer", name: "SendMessage", argumentsJSON: Data(#"{"text":"Layout decision received"}"#.utf8)))
                    } else {
                        let args = ["recipientID": recipient.uuidString, "message": "Choose a layout"]
                        _ = try await executeTool(.init(id: "delegate", name: "SendToAgent", argumentsJSON: JSONEncoder().encode(args)))
                        _ = try await executeTool(.init(id: "ack", name: "SendMessage", argumentsJSON: Data(#"{"text":"Asked the designer"}"#.utf8)))
                    }
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct PeerHistoryInspectionProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "delegate-fixture", displayName: "Inspection fixture", requiresAPIKey: false)
    let probe: AgentWakeProbe
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.inspect(request.messages)
                continuation.yield(.completed(.stop))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct DelegatingGroupProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "delegate-fixture", displayName: "Delegation fixture", requiresAPIKey: false)
    let sender: UUID
    let recipient: UUID
    let probe: AgentWakeProbe
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inbound = request.messages.last?.text.hasPrefix("Incoming peer message") == true
                    let isDesigner = request.messages[0].text.contains("You are Designer,")
                    let text: String
                    if inbound && !isDesigner {
                        await probe.record(sender)
                        #expect(request.messages.last?.text.contains("Improve contrast") == true)
                        text = "Updated implementation after the designer's review"
                    } else {
                        if inbound {
                            await probe.record(recipient)
                            if await probe.pausesAfterWake { try await Task.sleep(for: .seconds(30)) }
                        }
                        let args = ["recipientID": (inbound ? sender : recipient).uuidString,
                                    "message": inbound ? "Improve contrast" : "Review just the button contrast"]
                        let result = try await executeTool(.init(id: "delegate", name: "SendToAgent", argumentsJSON: JSONEncoder().encode(args)))
                        text = result.isError ? "Delegation was not sent" : (inbound ? "Design review sent" : "Queued design review")
                    }
                    let report = try await executeTool(.init(id: "report", name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": text])))
                    #expect(!report.isError)
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("SendToAgent app integration", .timeLimit(.minutes(1)))
@MainActor struct SendToAgentAppIntegrationTests {
    @Test(arguments: ["approve", "deny", "stop", "account", "recover"])
    func directPeerImagesAreApprovedPersistedAndRecoverable(mode: String) async throws {
        let (root, model, _, sender, recipient, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.bootstrap()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let storage = AttachmentStore(rootURL: root.appending(path: "attachments"))
        let image = try await storage.ingest(data: bytes, filename: "layout.png", declaredMIMEType: "image/png")
        await model.registry.register(PeerImageAppProvider(recipient: recipient, image: image, bytes: bytes, probe: probe))
        let origin = try #require(await model.addConversation(agentID: sender))
        await model.refreshModels()
        model.pendingAttachments = [image]
        model.draft = "Ask the designer to review this image"
        model.send()
        let approval = try await pending(model)
        #expect(approval.action.context.metadata["agentImages"]?.contains(image.id) == true)
        if mode == "stop" { model.cancel() }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        model.handleTranscriptCardIntent(mode == "deny" ? .rejectReview(reviewID: approval.id) : .approveReview(reviewID: approval.id))
        let succeeds = ["approve", "recover"].contains(mode)
        if succeeds {
            var next: PendingApproval?
            let limit = ContinuousClock.now + .seconds(10)
            while next == nil, ContinuousClock.now < limit {
                next = model.pendingAutoReviewApprovals.first { $0.id != approval.id }
                if next == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            let publication = try #require(next)
            expectNoDifference(publication.action.context.metadata["agentImagePublication"], "true")
            model.handleTranscriptCardIntent(.approveReview(reviewID: publication.id))
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isConversationWorking(origin), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isConversationWorking(origin))
        let wakes = await probe.wakes
        expectNoDifference(wakes, succeeds ? [recipient] : [])
        if succeeds {
            let peer = try #require(model.conversations.first { $0.agentBinding?.agentID == recipient })
            expectNoDifference(peer.messages.map(\.attachments), [[image], [image]])
            expectNoDifference(peer.messages.map(\.text), ["Review this image", "Reviewed image"])
            let saved = try #require(try await ConversationStore(fileURL: root.appending(path: "conversations.json")).conversation(id: peer.id))
            expectNoDifference(saved.messages.map(\.attachments), [[image], [image]])
            let restoredBytes = try await storage.data(for: image)
            expectNoDifference(restoredBytes, bytes)
            if mode == "recover" {
                try await removeQuestionProjections(model: model, root: root, peerID: peer.id)
                #expect(await model.recoverDirectPeerMessages(conversationID: origin))
                let restored = try #require(model.conversations.first { $0.id == peer.id })
                expectNoDifference(restored.messages.map(\.attachments), [[image], [image]])
                let after = await probe.wakes
                expectNoDifference(after, wakes)
            }
            await model.registry.register(PeerHistoryInspectionProvider(probe: probe))
            model.selectRoute(.conversation(peer.id))
            await model.loadLatestMessages(for: peer.id)
            await model.refreshModels()
            model.draft = "Continue without reattaching old images"
            model.send()
            #expect(model.isConversationWorking(peer.id), "\(model.errorMessage ?? "No turn started")")
            let limit = ContinuousClock.now + .seconds(10)
            while model.isConversationWorking(peer.id), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.isConversationWorking(peer.id))
            let inspected = await probe.inspectedMessages
            let peerContext = inspected.filter { $0.agentMessageSource != nil }
            expectNoDifference(peerContext.count, 2)
            #expect(peerContext.allSatisfy { $0.attachments.isEmpty })
        } else {
            #expect(model.agentMessages.isEmpty)
        }
    }

    @Test(arguments: ["option", "custom", "dismissed", "foreign", "delete", "stop", "restart", "recover-pending", "recover-answered"])
    func directPeerQuestionReturnsAnswerToOwnChat(mode: String) async throws {
        let (root, initialModel, _, sender, recipient, probe) = try await fixture()
        var model = initialModel
        defer { try? FileManager.default.removeItem(at: root) }
        await model.bootstrap()
        await model.registry.register(PeerQuestionAppProvider(recipient: recipient, probe: probe, pauseAnswer: mode == "stop"))
        let origin = try #require(await model.addConversation(agentID: sender))
        model.draft = "Ask the designer for a layout"
        model.send()
        let approval = try await pending(model)
        model.handleTranscriptCardIntent(.approveReview(reviewID: approval.id))
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isConversationWorking(origin), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isConversationWorking(origin))
        if mode == "restart" {
            model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
            await model.bootstrap()
            await model.registry.register(PeerQuestionAppProvider(recipient: recipient, probe: probe, pauseAnswer: false))
            let reopened = try #require(model.conversations.first(where: { $0.agentBinding?.agentID == recipient }))
            model.selection = reopened.id
            await model.loadLatestMessages(for: reopened.id)
        }
        let incoming = try #require(model.agentMessages.first)
        let publication = try #require(incoming.delivery?.publications?.first(where: { $0.question != nil }))
        let peer = try #require(model.conversations.first(where: { $0.agentBinding?.agentID == recipient }))
        if mode == "recover-pending" {
            try await removeQuestionProjections(model: model, root: root, peerID: peer.id)
            #expect(await model.recoverDirectPeerMessages(conversationID: origin))
            let wakes = await probe.wakes
            expectNoDifference(wakes, [])
        }
        if mode == "restart" {
            let projected = try #require(peer.messages.first(where: { $0.id == publication.id }))
            expectNoDifference(projected.text, publication.text)
            #expect(projected.agentMessageSource != nil)
            expectNoDifference(incoming.delivery?.directOriginBinding?.accountID, "local")
        }
        #expect(model.directPeerQuestion(conversationID: peer.id, messageID: publication.id) != nil)
        #expect(model.canAnswerMailboxQuestion(incoming, publication: publication))
        if mode == "foreign", let index = model.conversations.firstIndex(where: { $0.id == origin }) {
            model.conversations[index].agentBinding = .init(accountID: "other", agentID: sender)
        }
        if mode == "delete" { model.deleteConversation(id: peer.id) }
        let answer: AgentQuestionAnswer = mode == "custom" ? .custom("Spacious please") : mode == "dismissed" ? .dismissed : .option(0)
        await model.answerMailboxQuestion(incomingID: incoming.id, publicationID: publication.id, answer: answer)
        if mode == "stop" {
            while await probe.wakes.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            model.selection = peer.id
            model.cancel()
        }
        while model.isConversationWorking(origin), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isConversationWorking(origin) && !model.isConversationWorking(peer.id))
        let blocked = ["foreign", "delete"].contains(mode)
        expectNoDifference(model.agentMessages.count, blocked ? 1 : 2)
        if !blocked {
            expectNoDifference(model.agentMessages.last?.questionResponse?.answer, answer)
            expectNoDifference(model.agentMessages.last?.delivery?.state, mode == "stop" ? .cancelled : .completed)
            let output = model.conversations.first(where: { $0.id == peer.id })?.messages.filter { $0.text == "Layout decision received" } ?? []
            expectNoDifference(output.count, mode == "stop" ? 0 : 1)
            #expect(!model.conversations.first(where: { $0.id == origin })!.messages.contains { $0.text == "Layout decision received" })
            #expect(output.allSatisfy { $0.agentMessageSource?.authorAgentID == recipient })
            let count = model.agentMessages.count
            await model.answerMailboxQuestion(incomingID: incoming.id, publicationID: publication.id, answer: answer)
            expectNoDifference(model.agentMessages.count, count)
            if mode == "recover-answered" {
                let canonical = model.agentMessages
                let wakes = await probe.wakes
                try await removeQuestionProjections(model: model, root: root, peerID: peer.id)
                #expect(await model.recoverDirectPeerMessages(conversationID: origin))
                let recovered = try #require(model.conversations.first(where: { $0.id == peer.id }))
                expectNoDifference(recovered.messages.count, 3)
                let question = try #require(model.directPeerQuestion(conversationID: peer.id, messageID: publication.id))
                expectNoDifference(question.publication.question?.answer, answer)
                #expect(!model.canAnswerMailboxQuestion(question.incoming, publication: question.publication))
                let snapshot = model.conversations
                #expect(await model.recoverDirectPeerMessages(conversationID: origin))
                expectNoDifference(model.conversations, snapshot)
                expectNoDifference(model.agentMessages, canonical)
                let after = await probe.wakes
                expectNoDifference(after, wakes)
            }
        }
    }

    private func removeQuestionProjections(model: AppModel, root: URL, peerID: UUID) async throws {
        let index = try #require(model.conversations.firstIndex(where: { $0.id == peerID }))
        model.conversations[index].messages.removeAll { $0.agentMessageSource != nil }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.upsert(model.conversations[index], replacingLoadedMessageIDs: [], historyComplete: true)
    }

    @Test(arguments: ["missing-chat", "missing-message", "deleted", "foreign", "write-failure", "conflict", "restart", "restart-deleted"])
    func recoversCanonicalTextWithoutRerunningAgents(mode: String) async throws {
        let (root, initialModel, _, sender, recipient, probe) = try await fixture()
        var model = initialModel
        defer { try? FileManager.default.removeItem(at: root) }
        await model.bootstrap()
        let origin = try #require(await model.addConversation(agentID: sender))
        model.draft = "Ask the designer for a contrast review"
        model.send()
        let approval = try await pending(model)
        model.handleTranscriptCardIntent(.approveReview(reviewID: approval.id))
        let deadline = ContinuousClock.now + .seconds(10)
        while model.running.contains(origin), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.running.contains(origin))
        let peer = try #require(model.conversations.first { $0.agentBinding?.agentID == recipient })
        let canonical = model.agentMessages
        let wakes = await probe.wakes
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        for id in [origin, peer.id] {
            let index = try #require(model.conversations.firstIndex { $0.id == id })
            model.conversations[index].messages.removeAll { $0.agentMessageSource != nil }
            try await store.upsert(model.conversations[index], replacingLoadedMessageIDs: [], historyComplete: true)
        }
        if mode == "missing-chat" {
            // Remove only the canonical row to simulate missing projection data.
            // User deletion also removes the transcript journal and is a separate case.
            var fixtureDB: OpaquePointer?
            #expect(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &fixtureDB) == SQLITE_OK)
            defer { if let fixtureDB { sqlite3_close(fixtureDB) } }
            #expect(sqlite3_exec(fixtureDB, "DELETE FROM conversations WHERE id = '\(peer.id.uuidString)'", nil, nil, nil) == SQLITE_OK)
            model.conversations.removeAll { $0.id == peer.id }
        }
        let deleted = mode == "deleted" || mode == "restart-deleted"
        if deleted {
            model.deleteConversation(id: peer.id)
            while try await store.conversation(id: peer.id) != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        if mode == "foreign", let index = model.conversations.firstIndex(where: { $0.id == origin }) {
            model.conversations[index].agentBinding = .init(accountID: "other", agentID: sender)
        }
        if mode == "conflict", let index = model.conversations.firstIndex(where: { $0.id == peer.id }) {
            var conflicting = try #require(peer.messages.first)
            conflicting.text = "Keep this conflicting record"
            model.conversations[index].messages = [conflicting]
            try await store.upsert(model.conversations[index], replacingLoadedMessageIDs: [], historyComplete: true)
        }
        var database: OpaquePointer?
        defer { if let database { sqlite3_close(database) } }
        if mode == "write-failure" {
            #expect(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &database) == SQLITE_OK)
            #expect(sqlite3_exec(database, "CREATE TRIGGER reject_recovery BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'fixture recovery failure'); END", nil, nil, nil) == SQLITE_OK)
        }
        if mode.hasPrefix("restart") {
            // Recreate only the isolated fixture host, never the user's running app.
            model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
            await model.bootstrap()
            expectNoDifference(model.agentMessages.map(\.id), canonical.map(\.id))
        }
        let canonicalBeforeRecovery = model.agentMessages
        let success = await model.recoverDirectPeerMessages(conversationID: origin)
        if mode == "missing-chat" { #expect(success, Comment(rawValue: model.errorMessage ?? "Recovery failed")) }
        expectNoDifference(success, !["foreign", "write-failure", "conflict"].contains(mode))
        #expect(model.recoveringPeerConversations.isEmpty)
        let afterWakes = await probe.wakes
        expectNoDifference(afterWakes, wakes)
        expectNoDifference(model.agentMessages, canonicalBeforeRecovery)
        if mode == "write-failure" {
            #expect(sqlite3_exec(database, "DROP TRIGGER reject_recovery", nil, nil, nil) == SQLITE_OK)
            #expect(await model.recoverDirectPeerMessages(conversationID: origin))
            expectNoDifference(model.conversations.flatMap(\.messages).filter { $0.agentMessageSource != nil }.count, 4)
            let snapshot = model.conversations
            #expect(await model.recoverDirectPeerMessages(conversationID: origin))
            expectNoDifference(model.conversations, snapshot)
            expectNoDifference(model.agentMessages, canonicalBeforeRecovery)
            let retryWakes = await probe.wakes
            expectNoDifference(retryWakes, wakes)
        }
        if success {
            let count = model.conversations.flatMap(\.messages).filter { $0.agentMessageSource != nil }.count
            expectNoDifference(count, deleted ? 2 : 4)
            let snapshot = model.conversations
            #expect(await model.recoverDirectPeerMessages(conversationID: origin))
            expectNoDifference(model.conversations, snapshot)
            if deleted { #expect(!model.conversations.contains { $0.id == peer.id }) }
            else {
                let restored = try #require(try await store.conversation(id: peer.id))
                expectNoDifference(restored.messages.map(\.text), peer.messages.map(\.text))
                expectNoDifference(restored.messages.map(\.agentMessageSource), peer.messages.map(\.agentMessageSource))
            }
        }
    }

    private func fixture() async throws -> (URL, AppModel, UUID, UUID, UUID, AgentWakeProbe) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-delegating-app-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let sender = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "", providerID: "delegate-fixture", modelID: "test"))
        let recipient = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "delegate-fixture", modelID: "test"))
        // Deliberately NOT a group member: no implicit @everyone expansion.
        #expect(await model.createGroup(name: "Implementation", summary: "", memberIDs: [sender.id]))
        await model.reloadWorkspaceData()
        await model.setAutoReviewEnabled(true)
        await model.setAutoReviewRules(allow: ["SendToAgent"], ask: [])
        let probe = AgentWakeProbe()
        await model.registry.register(DelegatingGroupProvider(sender: sender.id, recipient: recipient.id, probe: probe))
        return (root, model, try #require(model.groups.first?.id), sender.id, recipient.id, probe)
    }

    private func pending(_ model: AppModel) async throws -> PendingApproval {
        for _ in 0..<600 {
            if let value = model.pendingAutoReviewApprovals.first { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("No delegation approval appeared")
    }

    @Test(arguments: [false, true]) func newPeerRequiresExactApprovalThenReplyWakesOriginal(approve: Bool) async throws {
        let (root, model, groupID, sender, recipient, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Ask the designer for a contrast review") }
        let request = try await pending(model)
        expectNoDifference(request.action.target, .recipient(identifier: recipient.uuidString))
        #expect(request.action.summary.contains("Engineer → Designer"))
        expectNoDifference(request.action.context.metadata["agentMessage"], "Review just the button contrast")
        expectNoDifference(model.agentMessages.count, 0)
        let before = await probe.wakes
        expectNoDifference(before, [])
        await model.resolveGroupApproval(request, groupID: groupID, approve: approve)
        await run.value
        let wakes = await probe.wakes
        expectNoDifference(wakes, approve ? [recipient, sender] : [])
        expectNoDifference(model.agentMessages.count, approve ? 2 : 0)
        #expect(model.agentMessages.allSatisfy { $0.delivery?.state == .completed })
        #expect(model.agentMessages.allSatisfy { $0.delivery?.directOriginBinding == nil })
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(!model.runningGroups.contains(groupID))
        #expect(model.thinkingGroupMembers[groupID] == nil)
        if approve {
            let messages = model.groupMessages[groupID] ?? []
            #expect(messages.contains { $0.senderID == recipient && $0.text == "Design review sent" })
            #expect(messages.contains { $0.senderID == sender && $0.text == "Updated implementation after the designer's review" })
            #expect(messages.flatMap(\.toolActivities).filter { $0.name == "SendToAgent" }.allSatisfy { $0.status == .succeeded })
        }
    }

    @Test func stopWhileApprovalPendingBlocksLateApprovalAndWake() async throws {
        let (root, model, groupID, _, _, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Delegate the review") }
        let approval = try await pending(model)
        await model.stopGroup(id: groupID)
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        await run.value
        let wakes = await probe.wakes
        expectNoDifference(wakes, [])
        expectNoDifference(model.agentMessages, [])
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(!model.runningGroups.contains(groupID))
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "delete", "archive", "unbound", "peer-stop", "peer-account", "peer-chat-stop", "peer-chat-delete"])
    func boundDirectChatDelegatesWithExactApproval(mode: String) async throws {
        let (root, model, _, sender, recipient, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.bootstrap()
        let id = try #require(await model.addConversation(agentID: sender))
        if mode.hasPrefix("peer-") { await probe.pauseAfterWake() }
        if mode == "unbound", let index = model.conversations.firstIndex(where: { $0.id == id }) {
            model.conversations[index].agentBinding = nil
        }
        model.draft = "Ask the designer for a contrast review"
        model.send()
        if mode != "unbound" {
            let approval = try await pending(model)
            expectNoDifference(approval.action.context.conversationID, id)
            expectNoDifference(approval.action.target, .recipient(identifier: recipient.uuidString))
            expectNoDifference(approval.action.context.metadata["agentMessage"], "Review just the button contrast")
            let card = try #require(model.conversations.first(where: { $0.id == id })?.messages
                .flatMap(\.transcriptCards).first(where: {
                    if case .autoReview(let value) = $0.payload { return value.reviewID == approval.id }
                    return false
                }))
            if case .autoReview(let value) = card.payload {
                #expect(value.findings.contains("Review just the button contrast"))
            }
            let before = await probe.wakes
            expectNoDifference(before, [])
            expectNoDifference(model.agentMessages.count, 0)
            if mode == "stop" { model.cancel() }
            if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
            if mode == "delete" { model.deleteConversation(id: id) }
            if mode == "archive" { await model.archiveAgent(id: sender) }
            model.handleTranscriptCardIntent(mode == "deny"
                ? .rejectReview(reviewID: approval.id) : .approveReview(reviewID: approval.id))
            if mode.hasPrefix("peer-") {
                let deadline = ContinuousClock.now + .seconds(10)
                while await probe.wakes.isEmpty, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let started = await probe.wakes
                expectNoDifference(started, [recipient])
                let peerChat = try #require(model.conversations.first(where: { $0.agentBinding?.agentID == recipient }))
                #expect(model.isConversationWorking(peerChat.id))
                #expect(model.isConversationWorking(id))
                #expect(!model.running.contains(peerChat.id))
                if mode == "peer-chat-stop" || mode == "peer-chat-delete" {
                    model.selectRoute(.conversation(peerChat.id))
                    let before = model.conversations.first(where: { $0.id == peerChat.id })?.messages
                    model.draft = "Do not start a competing turn"
                    model.send()
                    expectNoDifference(model.conversations.first(where: { $0.id == peerChat.id })?.messages, before)
                    #expect(await !model.syncAgentModel(conversationID: peerChat.id))
                    if mode == "peer-chat-delete" { model.deleteConversation(id: peerChat.id) }
                    else { model.cancel() }
                } else if mode == "peer-stop" { model.cancel() }
                else { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
            }
        }
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(10)
        while model.running.contains(id), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.running.contains(id))
        #expect(model.conversations.allSatisfy { !model.isConversationWorking($0.id) })
        let wakes = await probe.wakes
        expectNoDifference(wakes, mode == "approve" ? [recipient, sender] : mode.hasPrefix("peer-") ? [recipient] : [])
        expectNoDifference(model.agentMessages.count, mode == "approve" ? 2 : mode.hasPrefix("peer-") ? 1 : 0)
        #expect(model.agentMessages.allSatisfy { $0.delivery?.state == (mode.hasPrefix("peer-") ? .cancelled : .completed) })
        #expect(model.agentMessages.allSatisfy {
            $0.delivery?.directOriginBinding == DirectConversationAgentBinding(accountID: "local", agentID: sender)
        })
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.runningGroups.isEmpty)
        let projected = model.conversations.flatMap(\.messages).filter { $0.agentMessageSource != nil }
        if mode == "approve" {
            let rootChat = try #require(model.conversations.first(where: { $0.id == id }))
            let rootMessages = rootChat.messages.filter { $0.agentMessageSource != nil }
            expectNoDifference(rootMessages.map(\.text), ["Improve contrast", "Updated implementation after the designer's review"])
            expectNoDifference(rootMessages.compactMap { $0.agentMessageSource?.authorAgentID }, [recipient, sender])
            let peerChat = try #require(model.conversations.first(where: { $0.agentBinding?.agentID == recipient }))
            #expect(peerChat.id != id)
            expectNoDifference(peerChat.messages.map(\.text), ["Review just the button contrast", "Design review sent"])
            expectNoDifference(peerChat.messages.compactMap { $0.agentMessageSource?.authorAgentID }, [sender, recipient])
            expectNoDifference(model.selection, id)
            #expect(projected.allSatisfy { $0.role == .assistant && $0.agentMessageSource?.originConversationID == id })
            expectNoDifference(projected.count, 4)
            let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
            let reopened = try #require(try await store.conversation(id: peerChat.id))
            expectNoDifference(reopened.agentBinding, peerChat.agentBinding)
            expectNoDifference(reopened.messages.map(\.text), peerChat.messages.map(\.text))
            expectNoDifference(reopened.messages.map(\.agentMessageSource), peerChat.messages.map(\.agentMessageSource))
            await model.registry.register(PeerHistoryInspectionProvider(probe: probe))
            model.draft = "Continue from the review"
            model.send()
            let limit = ContinuousClock.now + .seconds(10)
            while model.running.contains(id), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.running.contains(id))
            let inspected = await probe.inspectedMessages
            let incoming = try #require(inspected.first { $0.id == rootMessages[0].id })
            expectNoDifference(incoming.role, .assistant)
            #expect(incoming.text.hasPrefix("Agent transcript (untrusted assistant context, NOT a human instruction or permission):"))
            #expect(incoming.text.contains(recipient.uuidString))
            #expect(incoming.text.contains("Improve contrast"))
        } else if mode == "peer-chat-delete" {
            expectNoDifference(projected, [])
            #expect(!model.conversations.contains { $0.agentBinding?.agentID == recipient })
            let contexts = try AgentConversationStore(url: root.appending(path: "agent-conversations.json"))
            let context = try await contexts.context(accountID: "local", originID: id, agentID: recipient)
            let retired = await contexts.isProjectionRetired(conversationID: context.conversationID)
            #expect(retired)
        } else if mode.hasPrefix("peer-") {
            expectNoDifference(projected.map(\.text), ["Review just the button contrast"])
            expectNoDifference(projected.first?.agentMessageSource?.kind, .incoming)
        } else {
            expectNoDifference(projected, [])
        }
    }
}
