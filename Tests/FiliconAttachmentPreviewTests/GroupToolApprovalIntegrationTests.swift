import Foundation
import Testing
import CustomDump
@testable import Filicon
import FiliconDomain
import FiliconProviderKit
import FiliconAutoReview
import FiliconLocalTools
import FiliconAgents

private struct CollaborationFileProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "group-approval-test", displayName: "Collaboration fixture", requiresAPIKey: false)
    let root: URL
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let metadataText = try #require(request.messages.first { $0.text.hasPrefix("Room metadata") }?.text)
                    let metadata = try #require(JSONSerialization.jsonObject(with: Data(metadataText.split(separator: "\n", maxSplits: 1)[1].utf8)) as? [String: Any])
                    let round = try #require(metadata["round"] as? Int)
                    let isDesigner = request.messages[0].text.contains("Your name is Designer")
                    let transcript = try #require(request.messages.first { $0.text.hasPrefix("Group conversation context") }?.text)
                    let suffix = "\(round)-\(isDesigner ? "designer" : "engineer")"
                    let discovery = try await executeTool(.init(id: ToolCallID(rawValue: "roots-\(suffix)"), name: "local__workspace_folders", argumentsJSON: Data("{}".utf8)))
                    #expect(!discovery.isError)
                    let text: String
                    if isDesigner {
                        #expect(transcript.contains("Implementation ready") || transcript.contains("Contrast corrected"))
                        let arguments = try JSONEncoder().encode(["root": root.path, "path": "collaboration.html"])
                        let result = try await executeTool(.init(id: ToolCallID(rawValue: "read-\(suffix)"), name: "local__read_file", argumentsJSON: arguments))
                        #expect(!result.isError)
                        #expect(result.wireText.contains(round == 1 ? "low-contrast" : "accessible-contrast"))
                        text = round == 1 ? "Design review: change low-contrast to accessible-contrast." : "Design review passed after inspecting the corrected file."
                    } else {
                        if round > 1 { #expect(transcript.contains("Design review: change low-contrast")) }
                        let arguments = try JSONSerialization.data(withJSONObject: [
                            "root": root.path, "path": "collaboration.html",
                            "content": round == 1 ? "<button>low-contrast</button>" : "<button>accessible-contrast</button>",
                            "replace": round > 1
                        ])
                        let result = try await executeTool(.init(id: ToolCallID(rawValue: "write-\(suffix)"), name: "local__write_file", argumentsJSON: arguments))
                        #expect(!result.isError)
                        text = round == 1 ? "Implementation ready for design review." : "Contrast corrected based on the designer's feedback."
                    }
                    continuation.yield(.textDelta(text))
                    continuation.yield(.completed(.stop))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct GroupWriteProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "group-approval-test", displayName: "Group write test", requiresAPIKey: false)
    let root: URL
    let expectedPermission: LocalToolPermission
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let discovery = try await executeTool(.init(id: "discover", name: "local__workspace_folders", argumentsJSON: Data("{}".utf8)))
                    let metadata = try JSONDecoder().decode(WorkspaceFolderDiscovery.self, from: Data(discovery.wireText.utf8))
                    expectNoDifference(metadata.authorizedRoots, [root.path])
                    expectNoDifference(metadata.hostToolPermissions["local__write_file"], expectedPermission)
                    // Even a model ignoring `never` must be blocked by the real executor.
                    let arguments = try JSONEncoder().encode(["root": root.path, "path": "created.txt", "content": "approved fixture write"])
                    let result = try await executeTool(.init(id: "write", name: "local__write_file", argumentsJSON: arguments))
                    continuation.yield(.textDelta(result.isError ? "No file written." : "Fixture written successfully."))
                    continuation.yield(.completed(.stop))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Opt-in real-model regression. Only the isolated fixture destination can
/// reach the host, regardless of which calls the model attempts.
private struct ResumeLiveProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "group-approval-test", displayName: "Resume regression", requiresAPIKey: false)
    let root: URL
    var live = false
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream {
            $0.yield(.textDelta("Folder authorization is confirmed, but this workspace is read-only. No project files were read or written."))
            $0.yield(.completed(.stop))
            $0.finish()
        }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        guard live else { return stream(request) }
        let bounded = InferenceRequest(conversationID: request.conversationID, modelID: "gpt-5.6-sol",
            messages: request.messages,
            tools: request.tools.filter { ["local__workspace_folders", "local__write_file"].contains($0.name.rawValue) },
            toolExchanges: request.toolExchanges)
        return CodexCLIProvider().stream(bounded) { call in
            let arguments = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any]
            let discovery = call.name.rawValue == "local__workspace_folders" && arguments?["choose"] as? Bool != true
            let fixtureWrite = call.name.rawValue == "local__write_file"
                && arguments?["root"] as? String == root.path
                && arguments?["path"] as? String == "created.txt"
                && arguments?["content"] as? String == "approved fixture write"
                && arguments?["replace"] as? Bool != true
            guard discovery || fixtureWrite else {
                Issue.record("Live regression attempted an operation outside its isolated fixture")
                return .init(callID: call.id, content: [.text("Outside this test's permitted operation. No action ran.")], isError: true)
            }
            return try await executeTool(call)
        }
    }
}

private struct GroupApprovalProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "group-approval-test", displayName: "Group approval test", requiresAPIKey: false)
    let root: URL
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            do {
                #expect(request.messages.contains { $0.role == .system && $0.text.contains("Current Filicon host-tool permissions") })
                if request.toolExchanges.isEmpty {
                    let arguments = try JSONEncoder().encode(["root": root.path, "path": "fixture.txt"])
                    let call = try NormalizedToolCall(id: "group-local-read", name: "local__read_file", argumentsJSON: arguments)
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    let result = request.toolExchanges[0].results[0]
                    if !result.isError { #expect(result.wireText.contains("fixture-only")) }
                    continuation.yield(.textDelta(result.isError ? "No file read." : "Fixture read successfully."))
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

private struct InteractiveGroupApprovalProvider: InteractiveToolProvider {
    let wrapped: GroupApprovalProvider
    var descriptor: ProviderDescriptor { wrapped.descriptor }
    func models() async throws -> [AIModel] { try await wrapped.models() }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { wrapped.stream(request) }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #expect(request.messages.contains { $0.role == .system && $0.text.contains("Current Filicon host-tool permissions") })
                    let arguments = try JSONEncoder().encode(["root": wrapped.root.path, "path": "fixture.txt"])
                    let call = try NormalizedToolCall(id: "group-local-read", name: "local__read_file", argumentsJSON: arguments)
                    let result = try await executeTool(call)
                    if !result.isError { #expect(result.wireText.contains("fixture-only")) }
                    continuation.yield(.textDelta(result.isError ? "No file read." : "Fixture read successfully."))
                    continuation.yield(.completed(.stop))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Group tool approval integration", .timeLimit(.minutes(1)))
@MainActor
struct GroupToolApprovalIntegrationTests {
    @Test func engineerAndDesignerPerformApprovedFileHandoffsInTheExistingGroup() async throws {
        let (root, model, groupID) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let engineer = try #require(model.agents.first)
        let designer = try #require(await model.createAgent(name: "Designer", summary: "Inspect usability and contrast", instructions: "", providerID: "group-approval-test", modelID: "test"))
        await model.updateGroupMembers(groupID: groupID, memberIDs: [engineer.id, designer.id])
        try await model.localToolPermissionPolicy.setChoice(.ask, for: .writeFile)
        try await model.localToolPermissionPolicy.setChoice(.ask, for: .readFile)
        await model.registry.register(CollaborationFileProvider(root: root))
        var finished = false
        let run = Task {
            await model.sendGroupMessage(groupID: groupID, text: "Implement the fixture, have the designer review it, then correct the contrast and review the fix.")
            finished = true
        }
        defer { run.cancel() }
        var approvals: [LocalToolAction] = []
        var handledApprovalIDs: Set<UUID> = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !finished && ContinuousClock.now < deadline {
            if let review = model.pendingAutoReviewApprovals.first {
                await model.resolveGroupApproval(review, groupID: groupID, approve: true)
            }
            // Resolution and the published UI snapshot are asynchronous. The
            // same card can still be visible on the next poll; count decisions,
            // not renders. A second request with a new ID must still be counted.
            if let approval = model.pendingToolApprovals.first(where: { !handledApprovalIDs.contains($0.id) }) {
                let allowed = approval.action == .readFile || approval.action == .writeFile
                #expect(allowed)
                handledApprovalIDs.insert(approval.id)
                approvals.append(approval.action)
                model.resolveLocalToolApproval(id: approval.id, allowed: allowed)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if !finished {
            await model.stopGroup(id: groupID)
            Issue.record("Collaboration fixture did not finish")
        }
        await run.value
        expectNoDifference(try String(contentsOf: root.appending(path: "collaboration.html"), encoding: .utf8), "<button>accessible-contrast</button>")
        expectNoDifference(approvals, [.writeFile, .readFile, .writeFile, .readFile])
        let replies = (model.groupMessages[groupID] ?? []).filter { $0.senderID != nil && !$0.text.isEmpty }
        expectNoDifference(replies.map(\.senderID), [engineer.id, designer.id, engineer.id, designer.id])
        expectNoDifference(replies.map { $0.toolActivities.last?.name }, ["local__write_file", "local__read_file", "local__write_file", "local__read_file"])
        #expect(replies.allSatisfy { $0.toolActivities.allSatisfy { $0.status == .succeeded } })
        expectNoDifference(replies.last?.text, "Design review passed after inspecting the corrected file.")
        #expect(!model.runningGroups.contains(groupID))
        #expect(model.errorMessage == nil)
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.pendingToolApprovals.isEmpty)
    }

    private func fixture(interactive: Bool = false, authorized: Bool = true, writePermission: LocalToolPermission? = nil) async throws -> (URL, AppModel, UUID) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-approval-\(UUID())")
        // SwiftPM test executables do not embed the app's XPC service. Use its
        // concrete host in-process, retaining permission-receipt verification.
        let generation = UUID(), key = LocalToolRuntime.randomSessionKey()
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let host = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true, authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: WorkspaceAuthorizationStore(fileURL: root.appending(path: "bookmarks.json")), generation: generation, sessionKey: key, helper: host)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime)
        let provider = GroupApprovalProvider(root: root)
        if let writePermission {
            try await model.localToolPermissionPolicy.setChoice(writePermission, for: .writeFile)
            await model.registry.register(GroupWriteProvider(root: root, expectedPermission: writePermission))
        }
        else if interactive { await model.registry.register(InteractiveGroupApprovalProvider(wrapped: provider)) }
        else { await model.registry.register(provider) }
        let agent = try #require(await model.createAgent(name: "Tester", summary: "", instructions: "", providerID: "group-approval-test", modelID: "test"))
        #expect(await model.createGroup(name: "Approval fixture", summary: "", memberIDs: [agent.id]))
        await model.reloadWorkspaceData() // Installs the real reviewed local/MCP executors.
        try "fixture-only".write(to: root.appending(path: "fixture.txt"), atomically: true, encoding: .utf8)
        if authorized { _ = try await model.localToolRuntime.workspaceStore.authorize(root) }
        await model.setAutoReviewEnabled(true)
        let groupID = try #require(model.groups.first?.id)
        return (root, model, groupID)
    }

    private func pending(_ model: AppModel) async throws -> PendingApproval {
        for _ in 0..<600 {
            if let request = model.pendingAutoReviewApprovals.first { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("No group approval appeared")
    }

    private func folderRequest(_ model: AppModel) async throws -> WorkspaceFolderRequest {
        for _ in 0..<600 {
            if let request = model.pendingWorkspaceFolders.first { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("No folder selection appeared")
    }

    @Test(arguments: [false, true])
    func discoveredAskPermissionRequiresBothApprovalsBeforeWriting(allow: Bool) async throws {
        let (root, model, groupID) = try await fixture(writePermission: .ask)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "created.txt")
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Create the requested fixture file.") }
        let review = try await pending(model)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(model.pendingToolApprovals.isEmpty)
        await model.resolveGroupApproval(review, groupID: groupID, approve: true)
        for _ in 0..<600 {
            if !model.pendingToolApprovals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let local = try #require(model.pendingToolApprovals.first)
        expectNoDifference(local.action, .writeFile)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        model.resolveLocalToolApproval(id: local.id, allowed: allow)
        await run.value
        if allow {
            expectNoDifference(try String(contentsOf: destination, encoding: .utf8), "approved fixture write")
        } else {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        expectNoDifference(model.groupMessages[groupID]?.last?.text, allow ? "Fixture written successfully." : "No file written.")
        expectNoDifference(model.groupMessages[groupID]?.last?.toolActivities.last?.status, allow ? .succeeded : .failed)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.pendingToolApprovals.isEmpty)
    }

    @Test func discoveredNeverPermissionCannotBeBypassedByCallingTheWriteTool() async throws {
        let (root, model, groupID) = try await fixture(writePermission: .never)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.sendGroupMessage(groupID: groupID, text: "Create the requested fixture file.")
        expectNoDifference(model.groupMessages[groupID]?.last?.text, "No file written.")
        expectNoDifference(model.groupMessages[groupID]?.last?.toolActivities.last?.status, .failed)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "created.txt").path))
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.pendingToolApprovals.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILICON_CODEX_LIVE_TEST"] == "1"), .timeLimit(.minutes(2)))
    func installedCodexResumesAfterStaleReadOnlyReplyAndRequestsWriteApproval() async throws {
        let (root, model, groupID) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ResumeLiveProvider(root: root))
        await model.sendGroupMessage(groupID: groupID, text: "For this diagnostic only, check folder authorization. Do not read or write project files.")
        #expect(model.groupMessages[groupID]?.last?.text.contains("read-only") == true)
        await model.registry.register(ResumeLiveProvider(root: root, live: true))
        let destination = root.appending(path: "created.txt")
        var finished = false
        let run = Task {
            await model.sendGroupMessage(groupID: groupID, text: "The diagnostic is finished. Continue with my task now: create created.txt in the authorized workspace, containing exactly approved fixture write (no newline). Ask for the required operation approval and wait for it. Do not just give instructions; actually create the file after approval.")
            finished = true
        }
        defer { run.cancel() }
        var sawReview = false, sawPermission = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !finished && ContinuousClock.now < deadline {
            if let review = model.pendingAutoReviewApprovals.first {
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                sawReview = true
                await model.resolveGroupApproval(review, groupID: groupID, approve: true)
            }
            if let permission = model.pendingToolApprovals.first {
                expectNoDifference(permission.action, .writeFile)
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                sawPermission = true
                model.resolveLocalToolApproval(id: permission.id, allowed: permission.action == .writeFile)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        if !finished {
            await model.stopGroup(id: groupID)
            Issue.record("Installed Codex did not finish the isolated regression within 90 seconds")
        }
        await run.value
        #expect(sawReview)
        #expect(sawPermission)
        expectNoDifference(try String(contentsOf: destination, encoding: .utf8), "approved fixture write")
        #expect(model.groupMessages[groupID]?.last?.toolActivities.contains { $0.name == "local__write_file" && $0.status == .succeeded } == true)
        #expect(model.errorMessage == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func firstUseOrInvalidGrantSelectsFolderInChatThenResumesOriginalOperation(interactive: Bool, invalidSavedGrant: Bool) async throws {
        let (root, model, groupID) = try await fixture(interactive: interactive, authorized: false)
        defer { try? FileManager.default.removeItem(at: root) }
        if invalidSavedGrant {
            _ = try await model.localToolRuntime.workspaceStore.registerBookmarkData(Data([4, 2]), url: root)
        }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let folder = try await folderRequest(model)
        expectNoDifference(folder.conversationID, groupID)
        expectNoDifference(folder.requestedRoot, root.path)
        expectNoDifference(folder.requiresReauthorization, invalidSavedGrant)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.pendingToolApprovals.isEmpty)
        // This simulates the URL returned by NSOpenPanel, not a model-supplied path.
        try await model.workspaceFolders.resolve(folder, selectedURL: root)
        let review = try await pending(model)
        await model.resolveGroupApproval(review, groupID: groupID, approve: true)
        for _ in 0..<600 {
            if !model.pendingToolApprovals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let local = try #require(model.pendingToolApprovals.first)
        expectNoDifference(local.toolCallID, folder.toolCallID.rawValue)
        model.resolveLocalToolApproval(id: local.id, allowed: true)
        await run.value
        expectNoDifference(model.groupMessages[groupID]?.last?.text, "Fixture read successfully.")
        expectNoDifference(model.groupMessages[groupID]?.last?.toolActivities.first?.status, .succeeded)
        #expect(model.pendingWorkspaceFolders.isEmpty)
        let roots = await model.localToolRuntime.workspaceStore.authorizations().map(\.path)
        expectNoDifference(roots, [root.path])
    }

    @Test(arguments: [false, true]) func cancelledFolderSelectionDoesNotGrantOrExecute(interactive: Bool) async throws {
        let (root, model, groupID) = try await fixture(interactive: interactive, authorized: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let folder = try await folderRequest(model)
        model.workspaceFolders.decline(folder)
        await run.value
        #expect(model.pendingWorkspaceFolders.isEmpty)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.pendingToolApprovals.isEmpty)
        #expect(await model.localToolRuntime.workspaceStore.authorizations().isEmpty)
        expectNoDifference(model.groupMessages[groupID]?.last?.text, "No file read.")
        expectNoDifference(model.groupMessages[groupID]?.last?.toolActivities.first?.status, .failed)
    }

    @Test(arguments: [false, true]) func stoppingFolderSelectionRejectsLateSelection(interactive: Bool) async throws {
        let (root, model, groupID) = try await fixture(interactive: interactive, authorized: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let folder = try await folderRequest(model)
        await model.stopGroup(id: groupID)
        await run.value
        try await model.workspaceFolders.resolve(folder, selectedURL: root)
        #expect(model.pendingWorkspaceFolders.isEmpty)
        #expect(await model.localToolRuntime.workspaceStore.authorizations().isEmpty)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.pendingToolApprovals.isEmpty)
        expectNoDifference(model.groupMessages[groupID]?.last?.toolActivities.first?.status, .cancelled)
    }

    @Test(arguments: [false, true]) func approveGroupReviewThenLocalPermissionRunsRealTool(interactive: Bool) async throws {
        let (root, model, groupID) = try await fixture(interactive: interactive)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let approval = try await pending(model)
        #expect(approval.action.context.conversationID == groupID)
        #expect(model.runningGroups.contains(groupID))
        #expect(!model.conversations.contains { $0.id == groupID })
        #expect(model.pendingToolApprovals.isEmpty)
        // Cross-group/replayed UI actions cannot grant authority.
        await model.resolveGroupApproval(approval, groupID: UUID(), approve: true)
        #expect(model.pendingAutoReviewApprovals.count == 1)
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        for _ in 0..<600 {
            if !model.pendingToolApprovals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let local = try #require(model.pendingToolApprovals.first)
        #expect(local.conversationID == groupID)
        model.resolveLocalToolApproval(id: local.id, allowed: true)
        await run.value
        #expect(model.errorMessage == nil)
        #expect(model.groupMessages[groupID]?.last?.text == "Fixture read successfully.")
        #expect(model.groupMessages[groupID]?.last?.toolActivities.first?.status == .succeeded)
        #expect(!model.runningGroups.contains(groupID))
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test(arguments: [false, true]) func denyingApprovalNeverReachesLocalPermissionOrExecutor(interactive: Bool) async throws {
        let (root, model, groupID) = try await fixture(interactive: interactive)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let approval = try await pending(model)
        await model.resolveGroupApproval(approval, groupID: groupID, approve: false)
        await run.value
        #expect(model.pendingToolApprovals.isEmpty)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.groupMessages[groupID]?.last?.toolActivities.first?.status == .failed)
    }

    @Test(arguments: [false, true]) func stoppingPendingGroupApprovalCancelsItAndRejectsLateApproval(interactive: Bool) async throws {
        let (root, model, groupID) = try await fixture(interactive: interactive)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let approval = try await pending(model)
        await model.stopGroup(id: groupID)
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.pendingToolApprovals.isEmpty)
        #expect(model.groupMessages[groupID]?.last?.toolActivities.first?.status == .cancelled)
        #expect(!model.runningGroups.contains(groupID))
        #expect(model.errorMessage == nil)
    }

    @Test(arguments: [false, true]) func stoppingLocalPermissionAndConcurrentSendAreFenced(interactive: Bool) async throws {
        let (root, model, groupID) = try await fixture(interactive: interactive)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let review = try await pending(model)
        await model.sendGroupMessage(groupID: groupID, text: "must not send twice")
        #expect(model.groupMessages[groupID]?.filter { $0.senderID == nil }.count == 1)
        await model.resolveGroupApproval(review, groupID: groupID, approve: true)
        for _ in 0..<600 {
            if !model.pendingToolApprovals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let local = try #require(model.pendingToolApprovals.first)
        await model.stopGroup(id: groupID)
        await run.value
        model.resolveLocalToolApproval(id: local.id, allowed: true)
        #expect(model.groupMessages[groupID]?.last?.toolActivities.first?.status == .cancelled)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        // A subsequent user turn may start normally, but needs a new approval.
        let next = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture again") }
        let nextReview = try await pending(model)
        #expect(nextReview.id != review.id)
        await model.stopGroup(id: groupID)
        await next.value
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func controlsAreLocalized(language: String) {
        for key in ["Tools & connections", "Awaiting approval or result", "Text reply · no tools used", "Text-only providers cannot use Filicon tools.", "Integrations are managed in MCP Servers and Plugins. Gmail installation cards are not supported in chat.", "No group member matches @{0}. Add the member or choose an existing name."] {
            let translated = FiliconLocalization.string(key, language: language)
            #expect(!translated.isEmpty)
            if language != "en" { #expect(translated != key) }
        }
    }
}
