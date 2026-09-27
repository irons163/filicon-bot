import Foundation
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconAutoReview
import FiliconDomain
import FiliconLocalTools
import FiliconPersistence
import FiliconProviderKit
@testable import Filicon

private final class GroupFileQuotaFault: @unchecked Sendable {
    private let lock = NSLock()
    private let groupsURL: URL
    private var mode: String?
    private var triggered = false
    private var directCheckpoints = 0
    init(groupsURL: URL) { self.groupsURL = groupsURL }
    func arm(_ mode: String) { lock.lock(); defer { lock.unlock() }; self.mode = mode }
    var didTrigger: Bool { lock.lock(); defer { lock.unlock() }; return triggered }
    func inject(_ point: StorageQuotaFaultPoint) throws {
        lock.lock(); defer { lock.unlock() }
        guard let mode else { return }
        if mode == "direct-message-reserve" || mode == "direct-message-late" {
            guard point == (mode == "direct-message-reserve" ? .afterReservationPersist : .afterCommitPersist) else { return }
            directCheckpoints += 1
            guard directCheckpoints == 2 else { return }
        } else if mode == "quota-reserve" {
            guard point == .afterReservationPersist else { return }
        } else {
            guard point == .afterCommitPersist else { return }
            if mode == "quota-message" {
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: groupsURL)) as? [String: Any]
                let messages = state?["roomMessages"] as? [[String: Any]] ?? []
                let mailbox = state?["messages"] as? [[String: Any]] ?? []
                let publications = mailbox.flatMap { (($0["delivery"] as? [String: Any])?["publications"] as? [[String: Any]]) ?? [] }
                guard (messages + publications).contains(where: { ($0["files"] as? [Any])?.isEmpty == false }) else { return }
            }
        }
        self.mode = nil
        triggered = true
        throw CocoaError(.fileWriteUnknown)
    }
}

private struct GroupFileAppProvider: AIProvider {
    let url: String
    var destinationID: UUID? = nil
    var peerRecipientID: UUID? = nil
    var expectedFileSuccess: Bool? = nil
    let descriptor = ProviderDescriptor(id: "group-file-app", displayName: "Files fixture", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                if request.toolExchanges.isEmpty {
                    let name: ToolName
                    let arguments: [String: String]
                    if let peerRecipientID, request.messages.first?.text.contains("You are Sender,") == true {
                        name = "SendToAgent"
                        arguments = ["recipientID": peerRecipientID.uuidString, "message": "Publish the reviewed report"]
                    } else if let destinationID, request.messages.first?.text.contains("Your name is Designer,") != true {
                        name = "SendToAgent"
                        arguments = ["recipientID": destinationID.uuidString, "message": "Publish the reviewed report"]
                    } else {
                        name = "SendMessage"
                        arguments = ["type": "attachment", "url": url]
                    }
                    let call = try NormalizedToolCall(id: "publish-report", name: name,
                        argumentsJSON: JSONSerialization.data(withJSONObject: arguments))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    if let expectedFileSuccess {
                        let result = try #require(request.toolExchanges.last?.results.first)
                        expectNoDifference(result.isError, !expectedFileSuccess)
                        expectNoDifference(result.wireText.contains("Saved message receipt:"), expectedFileSuccess)
                    }
                    continuation.yield(.textDelta("PASS"))
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@Suite("App group file publication", .timeLimit(.minutes(1)))
@MainActor struct GroupFilePublicationAppTests {
    @Test(arguments: ["approve", "deny", "stop", "account", "source-changed", "quota-reserve", "quota-blob", "direct-message-reserve", "direct-message-late"])
    func directMainPublishesReviewedFile(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-file-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appending(path: "report.txt"), bytes = Data("Reviewed direct artifact".utf8)
        try bytes.write(to: source)
        let grants = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
        try await grants.authorize(workspace)
        let generation = UUID(), key = Data(repeating: 13, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: grants, generation: generation, sessionKey: key, helper: helper)
        let fault = GroupFileQuotaFault(groupsURL: root.appending(path: "unused.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime,
            quotaFaultInjector: { try fault.inject($0) })
        await model.bootstrap()
        try await model.localToolPermissionPolicy.setChoice(.always, for: .readFile)
        await model.registry.register(GroupFileAppProvider(url: source.absoluteString,
            expectedFileSuccess: ["approve", "source-changed", "direct-message-late"].contains(mode)))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = "group-file-app"
        model.conversations[ci].modelID = "test"
        await model.refreshModels()
        model.draft = "Publish report"
        model.send()
        let approval = try await pending(model)
        expectNoDifference(approval.action.context.metadata["agentFilePublication"], "true")
        #expect(model.conversations[ci].messages.allSatisfy { $0.attachments.isEmpty })
        if mode == "source-changed" { try Data("Unreviewed replacement".utf8).write(to: source) }
        if mode.hasPrefix("quota-") || mode.hasPrefix("direct-message-") { fault.arm(mode) }
        if mode == "stop" { model.cancel() }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        model.handleTranscriptCardIntent(mode == "deny" ? .rejectReview(reviewID: approval.id) : .approveReview(reviewID: approval.id))
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let saved = try #require(try await store.conversation(id: id))
        let files = saved.messages.filter { !$0.attachments.isEmpty }
        expectNoDifference(files.count, ["approve", "source-changed", "direct-message-late"].contains(mode) ? 1 : 0)
        if files.isEmpty {
            let prepared = try PreparedAgentPublicationFile(bytes: bytes, filename: "report.txt")
            let index = try AttachmentReferenceRepository(databaseURL: root.appending(path: "attachment-index.sqlite"))
            let count = try await index.referenceCount(blobID: prepared.digest)
            expectNoDifference(count, 0)
        }
        if let message = files.first {
            let metadata = try #require(message.attachments.first)
            expectNoDifference(message.text, "")
            #expect(message.shortAddress != nil)
            let lifecycle = try AttachmentLifecycle.live(applicationSupportDirectory: root)
            let data = try await lifecycle.data(for: metadata, owner: .init(conversationID: id, messageID: message.id))
            expectNoDifference(data, bytes)
        }
        if mode.hasPrefix("quota-") || mode.hasPrefix("direct-message-") { #expect(fault.didTrigger) }
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "source-changed", "quota-reserve", "quota-blob", "quota-message", "message-write"], ["mailbox", "direct"])
    func mailboxPublishesReviewedFileWithDurableOwner(mode: String, route: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-mailbox-file-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appending(path: "report.txt"), bytes = Data("Reviewed mailbox artifact".utf8)
        try bytes.write(to: source)
        let grants = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
        try await grants.authorize(workspace)
        let generation = UUID(), key = Data(repeating: 13, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: grants, generation: generation, sessionKey: key, helper: helper)
        let mailboxURL = root.appending(path: "agent-messages.json"), backupURL = root.appending(path: "mailbox.backup")
        let fault = GroupFileQuotaFault(groupsURL: mailboxURL)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime,
            quotaFaultInjector: { try fault.inject($0) })
        await model.bootstrap()
        try await model.localToolPermissionPolicy.setChoice(.always, for: .readFile)
        await model.registry.register(GroupFileAppProvider(url: source.absoluteString))
        let senderValue = await model.createAgent(name: "Sender", summary: "", instructions: "", providerID: "group-file-app", modelID: "test")
        let recipientValue = await model.createAgent(name: "Recipient", summary: "", instructions: "", providerID: "group-file-app", modelID: "test")
        let sender = try #require(senderValue), recipient = try #require(recipientValue)
        var delegationID: String?
        if route == "direct" {
            _ = await model.addConversation(agentID: sender.id)
            await model.refreshModels()
            await model.registry.register(GroupFileAppProvider(url: source.absoluteString, peerRecipientID: recipient.id))
            model.draft = "Send report"
            model.send()
            let delegation = try await pending(model)
            delegationID = delegation.id
            expectNoDifference(delegation.action.context.metadata["tool"], "SendToAgent")
            model.handleTranscriptCardIntent(.approveReview(reviewID: delegation.id))
        } else {
            #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Send report"))
        }
        let approval = try await pending(model, excluding: delegationID)
        let originID = approval.action.context.conversationID
        expectNoDifference(approval.action.context.metadata["agentFilePublication"], "true")
        #expect(approval.action.context.metadata["mailboxIncomingID"] != nil)
        #expect(approval.action.context.metadata["agentMessage"]?.contains("report.txt") == true)
        if mode == "source-changed" { try Data("Changed source".utf8).write(to: source) }
        if mode == "stop" {
            if route == "direct" { model.cancel() }
            else { await model.stopAgentMessages(scopeID: originID) }
        }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode.hasPrefix("quota-") { fault.arm(mode) }
        if mode == "message-write" {
            try FileManager.default.moveItem(at: mailboxURL, to: backupURL)
            try FileManager.default.createDirectory(at: mailboxURL, withIntermediateDirectories: false)
        }
        await model.resolveGroupApproval(approval, groupID: originID, approve: mode != "deny")
        let deadline = ContinuousClock.now + .seconds(10)
        while model.runningAgentMessageScopes.contains(originID) || model.isConversationWorking(originID), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.runningAgentMessageScopes.contains(originID))
        #expect(!model.isConversationWorking(originID))
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        if mode.hasPrefix("quota-") { #expect(fault.didTrigger) }
        if mode == "message-write" {
            let prepared = try PreparedAgentPublicationFile(bytes: bytes, filename: "report.txt")
            let index = try AttachmentReferenceRepository(databaseURL: root.appending(path: "attachment-index.sqlite"))
            let count = try await index.referenceCount(blobID: prepared.digest)
            expectNoDifference(count, 0)
            let blob = try await index.blob(id: prepared.digest)
            expectNoDifference(blob?.state, .quarantined)
            try FileManager.default.removeItem(at: mailboxURL)
            try FileManager.default.moveItem(at: backupURL, to: mailboxURL)
        }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let messenger = try AgentMessenger(service: agents, storeURL: root.appending(path: "agent-messages.json"))
        let messages = await messenger.allMessages()
        let files = messages.flatMap { $0.delivery?.publications ?? [] }.filter { $0.files?.isEmpty == false }
        expectNoDifference(files.count, ["approve", "source-changed", "quota-message"].contains(mode) ? 1 : 0)
        if let message = files.first, let file = message.files?.first {
            expectNoDifference(messages.first?.delivery?.state, .completed)
            let lifecycle = try AttachmentLifecycle.live(applicationSupportDirectory: root)
            let data = try await lifecycle.data(for: file, owner: .init(conversationID: originID, messageID: message.id))
            expectNoDifference(data, bytes)
            if route == "direct" {
                let destination = try #require(model.conversations.first(where: { $0.agentBinding?.agentID == recipient.id }))
                let projected = try #require(destination.messages.first(where: { $0.id == message.id }))
                expectNoDifference(projected.attachments, [file])
                expectNoDifference(projected.agentMessageSource?.deliveryID, messages[0].id)
                #expect(model.conversations.first(where: { $0.id == originID })?.messages.allSatisfy { $0.id != message.id } == true)
                let mirroredBytes = try await lifecycle.data(for: file, owner: .init(conversationID: destination.id, messageID: message.id))
                expectNoDifference(mirroredBytes, bytes)
                #expect(await model.recoverDirectPeerMessages(conversationID: originID))
                #expect(await model.recoverDirectPeerMessages(conversationID: originID))
                let restored = try #require(model.conversations.first(where: { $0.id == destination.id }))
                expectNoDifference(restored.messages.filter { $0.id == message.id }.count, 1)
                let conversationStore = ConversationStore(fileURL: root.appending(path: "conversations.json"))
                var missingProjection = restored
                missingProjection.messages.removeAll { $0.id == message.id }
                try await conversationStore.upsert(missingProjection, replacingLoadedMessageIDs: [message.id], historyComplete: true)
                try await lifecycle.removeReferences(owner: .init(conversationID: destination.id, messageID: message.id))
                let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime)
                await reopened.bootstrap()
                #expect(await reopened.recoverDirectPeerMessages(conversationID: originID))
                let recovered = try #require(try await conversationStore.conversation(id: destination.id))
                expectNoDifference(recovered.messages.filter { $0.id == message.id }.map(\.attachments), [[file]])
                let recoveredBytes = try await lifecycle.data(for: file, owner: .init(conversationID: destination.id, messageID: message.id))
                expectNoDifference(recoveredBytes, bytes)
            }
            let directory = try await messenger.replyDirectory(replyingTo: messages[0].id)
            #expect(directory.contains(where: { $0.id == message.id && $0.shortAddress != nil }))
            // Click with the current UI's metadata, not a separately JSON-decoded
            // Date value whose floating-point precision can differ from the live actor.
            let previewFile = try #require(model.agentMessages.first(where: { $0.id == messages[0].id })?
                .delivery?.publications?.first(where: { $0.id == message.id })?.files?.first)
            expectNoDifference(previewFile.id, file.id)
            expectNoDifference(previewFile.filename, file.filename)
            model.openMailboxMessageFile(previewFile, messageID: UUID(), incomingID: messages[0].id)
            #expect(model.attachmentPreview == nil)
            model.openMailboxMessageFile(previewFile, messageID: message.id, incomingID: messages[0].id)
            let previewDeadline = ContinuousClock.now + .seconds(5)
            while model.attachmentPreview == nil && ContinuousClock.now < previewDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let preview = try #require(model.attachmentPreview)
            expectNoDifference(try Data(contentsOf: preview.fileURL), bytes)
            model.dismissAttachmentPreview()
        }
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func mailboxFileRowRenders(language: String) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let file = AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "產品報告-report.txt",
                mimeType: "text/plain", byteCount: 512, kind: .document)
            let publication = RoomMessage(groupID: UUID(), senderID: UUID(), text: "", files: [file])
            let host = NSHostingView(rootView: AgentPublishedResponses(publications: [publication],
                onOpenFile: { _, _ in Issue.record("Rendering must not open files") })
                .padding(16).frame(width: 420).environment(\.locale, Locale(identifier: language)))
            let size = host.fittingSize
            expectNoDifference(size.width, 420)
            #expect(size.height > 40 && size.height < 250)
            host.frame = .init(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
    }

    @Test(arguments: ["approve", "deny", "stop", "destination-stop", "account", "members", "source-changed", "quota-reserve", "quota-blob", "quota-message", "message-write"], ["foreground", "group", "direct", "mailbox"])
    func requiresApprovalAndKeepsReviewedBytes(mode: String, route: String) async throws {
        let background = route != "foreground"
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-file-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appending(path: "report.txt"), bytes = Data("Reviewed artifact".utf8)
        try bytes.write(to: source)
        let grants = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
        try await grants.authorize(workspace)
        let generation = UUID(), key = Data(repeating: 13, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: grants, generation: generation, sessionKey: key, helper: helper)
        let fault = GroupFileQuotaFault(groupsURL: root.appending(path: "groups.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime,
            quotaFaultInjector: { try fault.inject($0) })
        await model.bootstrap()
        try await model.localToolPermissionPolicy.setChoice(.always, for: .readFile)
        await model.registry.register(GroupFileAppProvider(url: source.absoluteString))
        let senderValue = await model.createAgent(name: "Sender", summary: "", instructions: "", providerID: "group-file-app", modelID: "test")
        let sender = try #require(senderValue)
        #expect(await model.createGroup(name: "Files", summary: "", memberIDs: [sender.id]))
        let group = try #require(model.groups.first)
        var destination = group
        if background {
            let designerValue = await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "group-file-app", modelID: "test")
            let designer = try #require(designerValue)
            #expect(await model.createGroup(name: "Destination", summary: "", memberIDs: [sender.id, designer.id]))
            destination = try #require(model.groups.first(where: { $0.name == "Destination" }))
            await model.registry.register(GroupFileAppProvider(url: source.absoluteString, destinationID: destination.id))
        }
        var originID: UUID
        if route == "direct" {
            let conversationID = await model.addConversation(agentID: sender.id)
            originID = try #require(conversationID)
            await model.refreshModels()
        } else { originID = group.id }
        var mailboxSenderID: UUID?
        if route == "mailbox" {
            let caller = await model.createAgent(name: "Caller", summary: "", instructions: "", providerID: "group-file-app", modelID: "test")
            mailboxSenderID = try #require(caller).id
        }
        let send = Task {
            if let mailboxSenderID {
                let sent = await model.sendAgentMessage(senderID: mailboxSenderID, recipientID: sender.id, text: "Send report")
                #expect(sent)
            } else if route == "direct" {
                model.draft = "Send report"
                model.send()
            } else { await model.sendGroupMessage(groupID: group.id, text: "Send report") }
        }
        defer { send.cancel() }
        var delegationID: String?
        if background {
            let delegation = try await pending(model)
            delegationID = delegation.id
            if route == "mailbox" { originID = delegation.action.context.conversationID }
            expectNoDifference(delegation.action.context.metadata["tool"], "SendToAgent")
            if route == "direct" {
                model.handleTranscriptCardIntent(.approveReview(reviewID: delegation.id))
            } else { await model.resolveGroupApproval(delegation, groupID: originID, approve: true) }
        }
        let approval = try await pending(model, excluding: delegationID)
        expectNoDifference(approval.action.context.metadata["agentFilePublication"], "true")
        expectNoDifference(approval.action.context.conversationID, originID)
        expectNoDifference(approval.action.context.metadata["agentGroupName"], destination.name)
        #expect(approval.action.context.metadata["agentMessage"]?.contains("report.txt") == true)
        #expect(model.groupMessages[group.id]?.allSatisfy { $0.files == nil } == true)
        if mode == "source-changed" { try Data("Changed source".utf8).write(to: source) }
        if mode == "stop" {
            if route == "direct" { model.cancel() }
            else if route == "mailbox" { await model.stopAgentMessages(scopeID: originID) }
            else { await model.stopGroup(id: originID) }
        }
        if mode == "destination-stop" { await model.stopGroup(id: destination.id) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "members" { await model.updateGroupMembers(groupID: destination.id, memberIDs: []) }
        if mode.hasPrefix("quota-") { fault.arm(mode) }
        let groupsURL = root.appending(path: "groups.json")
        let backupURL = root.appending(path: "groups-before-write.json")
        if mode == "message-write" {
            // Only this test's isolated store is replaced. Atomic writes cannot
            // replace a directory, so GroupService reaches a real save failure.
            try FileManager.default.moveItem(at: groupsURL, to: backupURL)
            try FileManager.default.createDirectory(at: groupsURL, withIntermediateDirectories: false)
        }
        await model.resolveGroupApproval(approval, groupID: originID, approve: mode != "deny")
        await send.value
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isConversationWorking(originID) || model.runningGroups.contains(destination.id) || model.runningAgentMessageScopes.contains(originID), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isConversationWorking(originID))
        #expect(!model.runningGroups.contains(destination.id))
        #expect(!model.runningAgentMessageScopes.contains(originID))
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        if mode.hasPrefix("quota-") { #expect(fault.didTrigger) }
        if mode == "message-write" {
            let inMemory = model.groupMessages[destination.id, default: []]
            #expect(inMemory.allSatisfy { $0.files?.isEmpty != false })
            let prepared = try PreparedAgentPublicationFile(bytes: bytes, filename: "report.txt")
            let index = try AttachmentReferenceRepository(databaseURL: root.appending(path: "attachment-index.sqlite"))
            let referenceCount = try await index.referenceCount(blobID: prepared.digest)
            expectNoDifference(referenceCount, 0)
            let storedBlob = try await index.blob(id: prepared.digest)
            let blob = try #require(storedBlob)
            expectNoDifference(blob.state, .quarantined)
            expectNoDifference(blob.byteCount, Int64(bytes.count))
            // Restore the untouched snapshot only after the run has unwound.
            try FileManager.default.removeItem(at: groupsURL)
            try FileManager.default.moveItem(at: backupURL, to: groupsURL)
        }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let messages = await groups.messages(groupID: destination.id)
        let publications = messages.filter { $0.files?.isEmpty == false }
        expectNoDifference(publications.count, ["approve", "source-changed", "quota-message"].contains(mode) ? 1 : 0)
        if let message = publications.first, let file = message.files?.first {
            let activity = try #require(messages.flatMap(\.toolActivities).first(where: { $0.name == "SendMessage" }))
            expectNoDifference(activity.status, .succeeded)
            let lifecycle = try AttachmentLifecycle.live(applicationSupportDirectory: root)
            let data = try await lifecycle.data(for: file, owner: .init(conversationID: destination.id, messageID: message.id))
            expectNoDifference(data, bytes)
            let priorBanner = model.startupBanner
            let priorError = model.errorMessage
            await model.reconcileQuota()
            expectNoDifference(model.startupBanner, priorBanner)
            expectNoDifference(model.errorMessage, priorError)
        }
        if background {
            let sourceMessages = await groups.messages(groupID: group.id)
            #expect(sourceMessages.allSatisfy { $0.files?.isEmpty != false })
        }
    }

    private func pending(_ model: AppModel, excluding priorID: String? = nil) async throws -> PendingApproval {
        let deadline = ContinuousClock.now + .seconds(10)
        while !model.pendingAutoReviewApprovals.contains(where: { $0.id != priorID }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(model.pendingAutoReviewApprovals.first(where: { $0.id != priorID }), "\(model.errorMessage ?? "No publication approval")")
    }
}
