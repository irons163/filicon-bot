import Foundation
import Testing
import CustomDump
import AppKit
import SwiftUI
import Vision
@testable import Filicon
import FiliconDomain
import FiliconLocalTools
import FiliconAppServices
import FiliconAgents

private actor WorkspaceOperationProbe: ToolExecutor {
    nonisolated let descriptor = ToolDescriptor(name: "local__write_file")
    private(set) var calls: [NormalizedToolCall] = []
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        calls.append(call)
        return .init(callID: call.id, content: [.text("executed")])
    }
}

@MainActor
private final class FolderRequests {
    var requests: [WorkspaceFolderRequest] = []
    func first() async throws -> WorkspaceFolderRequest {
        for _ in 0..<600 {
            if let request = requests.first { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }
}

@Suite("In-chat workspace access", .timeLimit(.minutes(1)))
@MainActor
struct WorkspaceFolderAccessTests {
    private let context = ToolContext(conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                      runID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private func fixture() throws -> (URL, WorkspaceAuthorizationStore, WorkspaceFolderCoordinator, FolderRequests) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-folder-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceAuthorizationStore(fileURL: root.appending(path: "bookmarks.json"))
        let state = FolderRequests()
        let folders = WorkspaceFolderCoordinator(store: store, onChange: { state.requests = $0 })
        return (root, store, folders, state)
    }

    @Test func changingTheRootNeverRedirectsTheOriginalWrite() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = WorkspaceOperationProbe()
        let executor = WorkspaceScopedToolExecutor(wrapped: operation, store: store, folders: folders, policy: .init())
        let call = try NormalizedToolCall(id: "write", name: "local__write_file", argumentsJSON: Data(#"{"root":"/wrong-guessed-root","path":"index.html","content":"test"}"#.utf8))
        let task = Task { try await executor.execute(call, context: context) }
        let request = try await state.first()
        #expect(await operation.calls.isEmpty)
        try await folders.resolve(request, selectedURL: root)
        let result = try await task.value
        #expect(result.isError)
        #expect(result.wireText.contains(root.lastPathComponent))
        #expect(await operation.calls.isEmpty)
        let roots = await store.authorizations().map(\.path)
        expectNoDifference(roots, [root.path])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "index.html").path))
    }

    @Test func authorizedRootSkipsThePromptButKeepsTheWrappedPermissionGate() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.authorize(root)
        let operation = WorkspaceOperationProbe()
        let executor = WorkspaceScopedToolExecutor(wrapped: operation, store: store, folders: folders, policy: .init())
        let call = try NormalizedToolCall(id: "write", name: "local__write_file", argumentsJSON: JSONEncoder().encode(["root": root.path, "path": "index.html"]))
        let result = try await executor.execute(call, context: context)
        #expect(!result.isError)
        let calls = await operation.calls
        expectNoDifference(calls, [call])
        #expect(state.requests.isEmpty)
    }

    @Test func neverPolicyDoesNotAskForFolderOrReachTheOperation() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = WorkspaceOperationProbe()
        let executor = WorkspaceScopedToolExecutor(wrapped: operation, store: store, folders: folders,
                                                  policy: .init(adminCeilings: [.writeFile: .never]))
        let call = try NormalizedToolCall(id: "write", name: "local__write_file", argumentsJSON: JSONEncoder().encode(["root": root.path, "path": "index.html"]))
        let result = try await executor.execute(call, context: context)
        #expect(result.isError)
        #expect(state.requests.isEmpty)
        #expect(await operation.calls.isEmpty)
    }

    @Test func discoveryWaitsForUserAndThenReturnsExactRootsWithoutAnotherPrompt() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = WorkspaceFoldersToolExecutor(store: store, folders: folders, policy: ToolPermissionPolicy())
        let call = try NormalizedToolCall(id: "folders", name: executor.descriptor.name, argumentsJSON: Data("{}".utf8))
        let task = Task { try await executor.execute(call, context: context) }
        let request = try await state.first()
        #expect(request.requestedRoot == nil)
        #expect(await store.authorizations().isEmpty)
        try await folders.resolve(request, selectedURL: root)
        let result = try await task.value
        let metadata = try JSONDecoder().decode(WorkspaceFolderDiscovery.self, from: Data(result.wireText.utf8))
        expectNoDifference(metadata, .init(authorizedRoots: [root.path], selectedRoots: [root.path], hostToolPermissions: defaultHostPermissions))
        let again = try await executor.execute(call, context: context)
        #expect(!again.isError)
        #expect(state.requests.isEmpty)
    }

    @Test func runtimeContextReportsEffectivePolicyWithoutPromptingOrGranting() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = ToolPermissionPolicy(choices: [.runCommand: .always, .writeFile: .always],
                                          adminCeilings: [.runCommand: .never, .writeFile: .ask])
        let executor = WorkspaceFoldersToolExecutor(store: store, folders: folders, policy: policy)
        let text = try await executor.runtimeContext(for: context)
        let json = try #require(text.split(separator: "\n").first { $0.hasPrefix("{") })
        let permissions = try JSONDecoder().decode([String: LocalToolPermission].self, from: Data(json.utf8))
        var expected = defaultHostPermissions
        expected["local__run_process"] = .never
        expectNoDifference(permissions, expected)
        #expect(text.contains("NOT the CLI's native sandbox"))
        #expect(text.contains("not an execution grant"))
        #expect(state.requests.isEmpty)
        #expect(await store.authorizations().isEmpty)
        let decision = await policy.evaluate(action: .writeFile, conversationID: context.conversationID,
                                             toolCallID: "still-needs-approval", title: "test", reason: "test")
        guard case .requiresApproval = decision else { Issue.record("Reporting ask must not grant a write"); return }
    }

    @Test func discoveryRefreshesPermissionsAfterFolderSelectionAndDoesNotReadProjectFiles() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = ToolPermissionPolicy()
        let executor = WorkspaceFoldersToolExecutor(store: store, folders: folders, policy: policy)
        let call = try NormalizedToolCall(id: "folders", name: executor.descriptor.name, argumentsJSON: Data("{}".utf8))
        let task = Task { try await executor.execute(call, context: context) }
        let request = try await state.first()
        try await policy.setChoice(.never, for: .writeFile)
        try await folders.resolve(request, selectedURL: root)
        let result = try await task.value
        let metadata = try JSONDecoder().decode(WorkspaceFolderDiscovery.self, from: Data(result.wireText.utf8))
        var expected = defaultHostPermissions
        expected["local__write_file"] = .never
        expectNoDifference(metadata, .init(authorizedRoots: [root.path], selectedRoots: [root.path], hostToolPermissions: expected))
        // Only the bookmark store was written; discovery performs no project file operation.
        expectNoDifference(try FileManager.default.contentsOfDirectory(atPath: root.path), ["bookmarks.json"])
    }

    @Test func declineSuppressesRepeatedRequestsInTheSameTurn() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await folders.request(context: context, callID: "first", root: nil) }
        let request = try await state.first()
        await expectDifference(state.requests) { folders.decline(request) } changes: { $0.removeAll() }
        #expect(try await task.value == nil)
        #expect(try await folders.request(context: context, callID: "again", root: nil) == nil)
        let secondMember = ToolContext(conversationID: context.conversationID, runID: UUID())
        #expect(try await folders.request(context: secondMember, callID: "second-member", root: nil) == nil)
        #expect(state.requests.isEmpty)
        #expect(await store.authorizations().isEmpty)
        folders.beginTurn(conversationID: context.conversationID)
        let next = Task { try await folders.request(context: secondMember, callID: "new-user-turn", root: nil) }
        let nextRequest = try await state.first()
        #expect(nextRequest.id != request.id)
        folders.decline(nextRequest)
        #expect(try await next.value == nil)
    }

    @Test func expiredRequestUnblocksTheToolWithoutGrantingAccessOrPromptingAgain() async throws {
        let (root, store, _, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = WorkspaceFolderCoordinator(store: store, requestLifetime: .zero,
                                                  onChange: { state.requests = $0 })
        let result = try await folders.request(context: context, callID: "expired", root: nil)
        #expect(result == nil)
        #expect(state.requests.isEmpty)
        #expect(await store.authorizations().isEmpty)
        let otherMember = ToolContext(conversationID: context.conversationID, runID: UUID())
        #expect(try await folders.request(context: otherMember, callID: "other-member", root: nil) == nil)
        #expect(state.requests.isEmpty)
    }

    @Test func crossConversationOrReplayedSelectionCannotGrantAccess() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await folders.request(context: context, callID: "folder", root: nil) }
        let request = try await state.first()
        let forged = WorkspaceFolderRequest(id: request.id, conversationID: UUID(), runID: request.runID,
                                            toolCallID: request.toolCallID, requestedRoot: request.requestedRoot)
        try await folders.resolve(forged, selectedURL: root)
        #expect(await store.authorizations().isEmpty)
        expectNoDifference(state.requests, [request])
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await folders.resolve(request, selectedURL: root)
        #expect(await store.authorizations().isEmpty)
        #expect(state.requests.isEmpty)
    }

    @Test func savedFolderCanBeSelectedButRemovedFolderCannotBeReauthorizedImplicitly() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let authorization = try await store.authorize(root)
        let task = Task { try await folders.request(context: context, callID: "folder", root: "/wrong") }
        let request = try await state.first()
        try await store.remove(id: authorization.id)
        await #expect(throws: LocalToolError.permissionMismatch) {
            try await folders.resolve(request, selectedURL: root, alreadyAuthorized: true)
        }
        expectNoDifference(state.requests, [request])
        #expect(await store.authorizations().isEmpty)
        _ = try await store.authorize(root)
        try await folders.resolve(request, selectedURL: root, alreadyAuthorized: true)
        let selected = try await task.value
        expectNoDifference(selected, root.path)
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func folderCardIsLocalized(language: String) {
        for key in ["Choose a workspace folder", "Choose a folder to continue this task. File changes and commands still require permission.", "Choose Folder…", "Requested folder: {0}", "Reauthorize workspace folder", "The saved folder authorization is no longer valid. Choose the folder again to continue. Your files and chats have not been changed.", "Waiting for folder selection"] {
            let translated = FiliconLocalization.string(key, language: language)
            #expect(!translated.isEmpty)
            if language != "en" { #expect(translated != key) }
        }
    }

    @Test func invalidPersistedGrantIsNotReportedAsAuthorizedOrSilentlyReplaced() async throws {
        let (root, store, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await store.registerBookmarkData(Data([4, 2]), url: root)
        let file = root.appending(path: "bookmarks.json")
        let before = try Data(contentsOf: file)
        let reloaded = WorkspaceAuthorizationStore(fileURL: file)
        let access = try await reloaded.accessState(forExactRoot: root.path)
        let grants = await reloaded.authorizations()
        expectNoDifference(access, .needsRenewal)
        expectNoDifference(grants, [saved])
        expectNoDifference(try Data(contentsOf: file), before)
        let parentAccess = try await reloaded.accessState(forExactRoot: root.deletingLastPathComponent().path)
        expectNoDifference(parentAccess, .missing)
    }

    @Test func mismatchedBookmarkCannotAuthorizeSavedPath() async throws {
        let (root, store, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await store.authorize(root)
        let other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try await store.registerBookmarkData(saved.bookmarkData, url: other)
        let otherAccess = try await store.accessState(forExactRoot: other.path)
        let rootAccess = try await store.accessState(forExactRoot: root.path)
        expectNoDifference(otherAccess, .needsRenewal)
        expectNoDifference(rootAccess, .ready)
    }

    @Test func invalidGrantPausesBeforeOperationAndExplicitReselectionRepairsIt() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await store.registerBookmarkData(Data([4, 2]), url: root)
        let operation = WorkspaceOperationProbe()
        let executor = WorkspaceScopedToolExecutor(wrapped: operation, store: store, folders: folders, policy: .init())
        let call = try NormalizedToolCall(id: "write", name: "local__write_file", argumentsJSON: JSONEncoder().encode(["root": root.path, "path": "index.html"]))
        let task = Task { try await executor.execute(call, context: context) }
        let request = try await state.first()
        #expect(request.requiresReauthorization)
        expectNoDifference(request.requestedRoot, root.path)
        #expect(await operation.calls.isEmpty)
        await #expect(throws: LocalToolError.workspaceAuthorizationNeedsRenewal) {
            try await folders.resolve(request, selectedURL: root, alreadyAuthorized: true)
        }
        let grants = await store.authorizations()
        expectNoDifference(grants, [saved])
        expectNoDifference(state.requests, [request])
        #expect(await operation.calls.isEmpty)
        try await folders.resolve(request, selectedURL: root)
        #expect(try await !task.value.isError)
        let calls = await operation.calls
        let access = try await store.accessState(forExactRoot: root.path)
        expectNoDifference(calls, [call])
        expectNoDifference(access, .ready)
        let reloaded = WorkspaceAuthorizationStore(fileURL: root.appending(path: "bookmarks.json"))
        let reloadedAccess = try await reloaded.accessState(forExactRoot: root.path)
        expectNoDifference(reloadedAccess, .ready)
    }

    @Test func invalidOnlyDiscoveryPromptsAndCancellationPreservesTheSavedGrant() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await store.registerBookmarkData(Data([4, 2]), url: root)
        let executor = WorkspaceFoldersToolExecutor(store: store, folders: folders, policy: ToolPermissionPolicy())
        let call = try NormalizedToolCall(id: "folders", name: executor.descriptor.name, argumentsJSON: Data("{}".utf8))
        let task = Task { try await executor.execute(call, context: context) }
        let request = try await state.first()
        #expect(request.requiresReauthorization)
        expectNoDifference(request.requestedRoot, root.path)
        folders.decline(request)
        #expect(try await task.value.isError)
        let grants = await store.authorizations()
        expectNoDifference(grants, [saved])
        let again = try await executor.execute(call, context: context)
        #expect(again.isError)
        #expect(state.requests.isEmpty)
    }

    @Test func discoverySeparatesInvalidSavedRootsFromValidatedGrants() async throws {
        let (root, store, folders, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.authorize(root)
        let invalid = root.appending(path: "invalid")
        _ = try await store.registerBookmarkData(Data([4, 2]), url: invalid)
        let executor = WorkspaceFoldersToolExecutor(store: store, folders: folders, policy: ToolPermissionPolicy())
        let call = try NormalizedToolCall(id: "folders", name: executor.descriptor.name, argumentsJSON: Data("{}".utf8))
        let result = try await executor.execute(call, context: context)
        let metadata = try JSONDecoder().decode(WorkspaceFolderDiscovery.self, from: Data(result.wireText.utf8))
        expectNoDifference(metadata, .init(authorizedRoots: [root.path], reauthorizationRequiredRoots: [invalid.path], hostToolPermissions: defaultHostPermissions))
        #expect(state.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func folderCardRendersAtChatWidths(requiresReauthorization: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-folder-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        model.pendingWorkspaceFolders = [.init(id: UUID(), conversationID: context.conversationID,
                                               runID: context.runID, toolCallID: "fixture", requestedRoot: requiresReauthorization ? "/Projects/example" : nil,
                                               requiresReauthorization: requiresReauthorization)]
        for (language, scheme, width) in [("zh-Hant", ColorScheme.dark, 520.0), ("zh-Hant", .light, 520.0), ("fr", .light, 360.0)] {
            try await withUIRenderTurn(language: language) {
                let content = WorkspaceFolderAccessPanel(conversationID: context.conversationID)
                    .environmentObject(model).environment(\.locale, Locale(identifier: language))
                    .foregroundStyle(FiliconTheme.textPrimary).padding(20)
                    .frame(width: width).background(FiliconTheme.canvas).environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == Int(width * 2))
                #expect(image.height >= 220 && image.height < 800)
                if let directory = ProcessInfo.processInfo.environment["FILICON_FOLDER_CARD_ARTIFACT_DIRECTORY"] {
                    let url = URL(fileURLWithPath: directory).appending(path: "folder-card-\(language)-\(scheme == .dark ? "dark" : "light")-\(requiresReauthorization ? "renewal" : "new").png")
                    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try png.write(to: url)
                }
            }
        }
    }

    @Test(arguments: [980.0, 620.0], [false, true])
    func folderRequestAppearsInAnAlreadyMountedLongGroupConversation(width: Double, dark: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-mounted-folder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let agent = AgentProfile(name: "Engineer")
        let group = AgentGroup(id: context.conversationID, name: "Folder test", memberIDs: [agent.id])
        model.agents = [agent]
        model.groups = [group]
        model.selectedGroupID = group.id
        model.runningGroups.insert(group.id)
        model.thinkingGroupMembers[group.id] = agent.id
        model.groupMessages[group.id] = (0..<40).map { index in
            RoomMessage(groupID: group.id, senderID: agent.id,
                        text: (index == 0 ? "Beginning of history. " : "History message \(index). ") + String(repeating: "Test content. ", count: 20))
        }
        let height = width < 700 ? 420.0 : 650.0
        let host = NSHostingView(rootView: GroupConversationView(group: group, draft: .constant(""), images: .constant([]))
            .environmentObject(model).environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width, height: height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        model.pendingWorkspaceFolders = [.init(id: UUID(), conversationID: group.id, runID: context.runID,
                                               toolCallID: "folders", requestedRoot: "/Projects/example",
                                               requiresReauthorization: true)]
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        // Scrolling history must not hide the action the running turn requires.
        for scroll in descendants(of: host).compactMap({ $0 as? NSScrollView }) {
            guard let document = scroll.documentView, document.bounds.height > host.bounds.height else { continue }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? 0 : document.bounds.height - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try renderedBitmap(of: host)
        // SwiftUI's in-process AX tree can be empty in an unshown test window.
        // Check actual rendered controls, not just the pending model state.
        let visibleText = try recognizedText(in: bitmap)
        let chooseLabel = normalizedText(FiliconLocalization.string("Choose Folder…"))
        #expect(visibleText.contains(chooseLabel), "Folder action must remain visible above the composer: \(visibleText)")
        #expect(visibleText.contains(normalizedText(FiliconLocalization.string("Cancel"))))
        #expect(visibleText.contains("Beginningofhistory"), "The fixture must be scrolled away from the latest tool call")
        #expect(!visibleText.contains(normalizedText(FiliconLocalization.string("Thinking"))))
        if let directory = ProcessInfo.processInfo.environment["FILICON_FOLDER_CARD_ARTIFACT_DIRECTORY"] {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appending(path: "mounted-group-folder-\(Int(width))-\(dark ? "dark" : "light").png"))
        }
        model.pendingWorkspaceFolders = []
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let afterDismissal = try recognizedText(in: renderedBitmap(of: host))
        #expect(!afterDismissal.contains(chooseLabel))
    }

    @Test func folderWaitingStatusAppearsInToolAndSidebarInsteadOfGenericPending() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-folder-status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let agent = AgentProfile(name: "Engineer")
        let message = RoomMessage(groupID: context.conversationID, senderID: agent.id, text: "",
                                  toolActivities: [.init(id: "folders", name: "local__workspace_folders")])
        let content = VStack(spacing: 20) {
            GroupMessageBubble(message: message, agent: agent, waitingForFolderCallIDs: ["folders"], onReaction: {})
            ChatListRow(title: "Folder test", subtitle: "", isWorking: true, needsFolderSelection: true) {
                Image(systemName: "folder")
            }
        }
        .environmentObject(model)
        .padding(20).frame(width: 520).background(FiliconTheme.canvas)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let text = try recognizedText(in: NSBitmapImageRep(cgImage: image))
        let status = normalizedText(FiliconLocalization.string("Waiting for folder selection"))
        #expect(text.components(separatedBy: status).count == 3, "Both the tool and sidebar must show why execution paused: \(text)")
        #expect(!text.contains(normalizedText(FiliconLocalization.string("Awaiting approval or result"))))
    }

    private func renderedBitmap(of host: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func recognizedText(in bitmap: NSBitmapImageRep) throws -> String {
        let image = try #require(bitmap.cgImage)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        let label = FiliconLocalization.string("Choose Folder…")
        let languages = [("en", "en-US"), ("zh-Hant", "zh-Hant"), ("zh-Hans", "zh-Hans"),
                         ("fr", "fr-FR"), ("es", "es-ES"), ("ja", "ja-JP"), ("ko", "ko-KR")]
        let language = languages.first { FiliconLocalization.string("Choose Folder…", language: $0.0) == label }?.1 ?? "en-US"
        recognition.recognitionLanguages = language == "en-US" ? [language] : [language, "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([recognition])
        let visibleText = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return normalizedText(visibleText)
    }

    private func normalizedText(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !"….⋯".contains($0) }
    }

    private var defaultHostPermissions: [String: LocalToolPermission] {
        ["local__read_file": .ask, "local__list_directory": .ask, "local__write_file": .ask, "local__run_process": .ask]
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

}
