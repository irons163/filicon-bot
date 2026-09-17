import AppKit
import Foundation
import SwiftUI
import FiliconDomain
import FiliconLocalTools
import FiliconAppServices

struct WorkspaceFolderRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    let runID: UUID
    let toolCallID: ToolCallID
    let requestedRoot: String?
    var requiresReauthorization = false
}

/// Folder selection is user authority, not an AI permission grant. A stopped
/// turn cannot revive its request or save a late file-panel selection.
@MainActor
final class WorkspaceFolderCoordinator {
    private struct Pending {
        let request: WorkspaceFolderRequest
        let continuation: CheckedContinuation<String?, Error>
        let expiry: Task<Void, Never>
        var resolving = false
    }
    private let store: WorkspaceAuthorizationStore
    private let onChange: ([WorkspaceFolderRequest]) -> Void
    private let makeID: () -> UUID
    private let requestLifetime: Duration
    private var pending: [UUID: Pending] = [:]
    private var panels: [UUID: NSOpenPanel] = [:]
    private var declinedConversations: [UUID] = []

    init(store: WorkspaceAuthorizationStore, makeID: @escaping () -> UUID = UUID.init,
         requestLifetime: Duration = .seconds(300),
         onChange: @escaping ([WorkspaceFolderRequest]) -> Void = { _ in }) {
        self.store = store; self.makeID = makeID; self.onChange = onChange
        self.requestLifetime = requestLifetime
    }

    func beginTurn(conversationID: UUID) {
        cancel(conversationID: conversationID)
        declinedConversations.removeAll { $0 == conversationID }
    }

    func request(context: ToolContext, callID: ToolCallID, root: String?, requiresReauthorization: Bool = false) async throws -> String? {
        try Task.checkCancellation()
        guard !declinedConversations.contains(context.conversationID) else { return nil }
        let request = WorkspaceFolderRequest(id: makeID(), conversationID: context.conversationID,
                                            runID: context.runID, toolCallID: callID, requestedRoot: root,
                                            requiresReauthorization: requiresReauthorization)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let expiry = Task { [weak self, requestLifetime] in
                    do { try await Task.sleep(for: requestLifetime) } catch { return }
                    self?.decline(request)
                }
                pending[request.id] = Pending(request: request, continuation: continuation, expiry: expiry)
                publish()
            }
        } onCancel: {
            Task { @MainActor in self.finish(request, result: .failure(CancellationError())) }
        }
    }

    func chooseFolder(_ request: WorkspaceFolderRequest) async throws {
        guard matches(request), panels[request.id] == nil else { return }
        let panel = NSOpenPanel()
        panel.title = l10n("Choose a workspace folder")
        panel.message = l10n("Choose a folder to continue this task. File changes and commands still require permission.")
        panel.prompt = l10n("Authorize Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Never preselect the model's proposed root: it may be fabricated or overly broad.
        panels[request.id] = panel
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        panels.removeValue(forKey: request.id)
        guard matches(request) else { return }
        try await resolve(request, selectedURL: response == .OK ? panel.url : nil)
    }

    func resolve(_ request: WorkspaceFolderRequest, selectedURL: URL?, alreadyAuthorized: Bool = false) async throws {
        guard matches(request), pending[request.id]?.resolving == false else { return }
        guard let selectedURL else { decline(request); return }
        pending[request.id]?.resolving = true
        do {
            let root: String
            if alreadyAuthorized {
                guard let authorization = await store.authorization(forExactRoot: selectedURL.path) else {
                    throw LocalToolError.permissionMismatch
                }
                _ = try await store.transportBookmark(forExactRoot: selectedURL.path)
                root = authorization.path
            } else {
                let scoped = selectedURL.startAccessingSecurityScopedResource()
                defer { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }
                root = try await store.authorize(selectedURL).path
            }
            finish(request, result: .success(root))
        } catch {
            pending[request.id]?.resolving = false
            throw error // Keep the card available for retry after a bookmark/storage failure.
        }
    }

    func decline(_ request: WorkspaceFolderRequest) {
        guard matches(request) else { return }
        // Group members have different provider runs but share one user turn.
        // A second member must not repeat a folder question the user declined.
        declinedConversations.append(request.conversationID)
        declinedConversations = Array(declinedConversations.suffix(256))
        finish(request, result: .success(nil))
    }

    func cancel(conversationID: UUID) {
        for request in pending.values.map(\.request) where request.conversationID == conversationID {
            finish(request, result: .failure(CancellationError()))
        }
    }

    private func matches(_ request: WorkspaceFolderRequest) -> Bool { pending[request.id]?.request == request }

    private func finish(_ request: WorkspaceFolderRequest, result: Result<String?, Error>) {
        guard matches(request), let value = pending.removeValue(forKey: request.id) else { return }
        value.expiry.cancel()
        panels.removeValue(forKey: request.id)?.cancel(nil)
        value.continuation.resume(with: result)
        publish()
    }

    private func publish() { onChange(pending.values.map(\.request).sorted { $0.id.uuidString < $1.id.uuidString }) }
}

/// Runs before the exact-operation review, so missing folder access is never
/// presented as an operation that will succeed merely by clicking Allow.
struct WorkspaceScopedToolExecutor: ToolExecutor {
    let wrapped: any ToolExecutor
    let store: WorkspaceAuthorizationStore
    let folders: WorkspaceFolderCoordinator
    let policy: ToolPermissionPolicy
    var descriptor: ToolDescriptor { wrapped.descriptor }

    static let scopedNames: Set<String> = ["local__read_file", "local__list_directory", "local__write_file", "local__run_process"]

    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        try Task.checkCancellation()
        guard let arguments = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
              let root = arguments["root"] as? String else { throw LocalToolError.invalidRequest("root is required") }
        let action: LocalToolAction
        switch descriptor.name.rawValue {
        case "local__read_file": action = .readFile
        case "local__list_directory": action = .listDirectory
        case "local__write_file": action = .writeFile
        case "local__run_process": action = .runCommand
        default: throw LocalToolError.invalidRequest("not a workspace-scoped tool")
        }
        guard await policy.effectivePermission(for: action) != .never else {
            return .init(callID: call.id, content: [.text("Permission is set to Never for \(action.rawValue). No operation ran.")], isError: true)
        }
        let access = try await store.accessState(forExactRoot: root)
        if access != .ready {
            guard let selected = try await folders.request(context: context, callID: call.id, root: root,
                                                          requiresReauthorization: access == .needsRenewal) else {
                return .init(callID: call.id, content: [.text("Folder selection was cancelled or expired. No operation ran. Do not ask again during this turn.")], isError: true)
            }
            try Task.checkCancellation()
            // Do not silently redirect a read/write/command to another location
            // using an approval or arguments that described the old location.
            if URL(fileURLWithPath: root).standardizedFileURL.path != selected {
                let encoded = String(decoding: try JSONEncoder().encode(["selected_root": selected]), as: UTF8.self)
                return .init(callID: call.id, content: [.text("The user selected a different workspace: \(encoded). No file or command operation ran. Continue the task with a new tool call using this exact root and a safe relative path; do not reuse an absolute path from the old root. Filicon will check that operation's permissions.")], isError: true)
            }
            // Keep the exact-operation review inside `wrapped`. Choosing a
            // folder repairs only the folder grant, not write/command consent.
            _ = try await store.transportBookmark(forExactRoot: root)
        }
        try Task.checkCancellation()
        return try await wrapped.execute(call, context: context)
    }
}

/// Metadata/selection only: cannot read files, run commands, or grant access
/// without a real user selection. Does not need an AI-generated approval.
struct WorkspaceFolderDiscovery: Codable, Equatable, Sendable {
    var authorizedRoots: [String] = []
    var reauthorizationRequiredRoots: [String]?
    var selectedRoots: [String]?
    var hostToolPermissions: [String: LocalToolPermission]

    enum CodingKeys: String, CodingKey {
        case authorizedRoots = "authorized_roots"
        case reauthorizationRequiredRoots = "reauthorization_required_roots"
        case selectedRoots = "selected_roots"
        case hostToolPermissions = "host_tool_permissions"
    }
}

struct WorkspaceFoldersToolExecutor: ToolExecutor, ToolRuntimeContextProviding {
    let store: WorkspaceAuthorizationStore
    let folders: WorkspaceFolderCoordinator
    let policy: ToolPermissionPolicy
    var descriptor: ToolDescriptor {
        .init(name: "local__workspace_folders",
              description: "Get validated exact workspace roots and current host_tool_permissions before local file/process work. ask means call the Filicon tool to request operation approval, not read-only; never means blocked. If no root is usable, pauses for folder selection in chat. reauthorization_required_roots are invalid grants, not authorized roots. Set choose=true to select another folder. Never guess paths or use the CLI sandbox cwd. Discovery is not a file read/write test, and selection does not approve file changes or commands.",
              inputSchema: Data(#"{"type":"object","properties":{"choose":{"type":"boolean"}},"additionalProperties":false}"#.utf8), parallelSafe: false)
    }
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        try Task.checkCancellation()
        let arguments = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any]
        var metadata = try await validatedRoots()
        var selected: String?
        if metadata.authorizedRoots.isEmpty || arguments?["choose"] as? Bool == true {
            let invalidRoot = arguments?["choose"] as? Bool == true ? nil : metadata.reauthorizationRequiredRoots?.first
            selected = try await folders.request(context: context, callID: call.id, root: invalidRoot,
                                                 requiresReauthorization: invalidRoot != nil)
            try Task.checkCancellation()
            guard selected != nil else {
                return .init(callID: call.id, content: [.text("Folder selection was cancelled or expired. No access was granted. Do not ask again during this turn.")], isError: true)
            }
            metadata = try await validatedRoots()
        }
        if let selected { metadata.selectedRoots = [selected] }
        return .init(callID: call.id, content: [.text(String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self))])
    }

    func runtimeContext(for context: ToolContext) async throws -> String {
        let permissions = try JSONEncoder().encode(await hostToolPermissions())
        return """
        Current Filicon host-tool permissions (host policy snapshot, not an execution grant):
        \(String(decoding: permissions, as: UTF8.self))
        These supplied local__ tools run in Filicon's host executor, NOT the CLI's native sandbox or working directory. A read-only CLI sandbox does not make the authorized Filicon workspace read-only. Do not change or bypass that sandbox.
        Policy meanings: ask = the operation may be requested through a structured tool call and must wait for host/user approval; never = blocked by host policy; always = the local permission preference permits the request, but operation review, folder authorization and runtime validation still apply. Policies can change and are checked again for every operation.
        For a user-requested file change, use the supplied local__write_file tool when its policy is ask or always; let Filicon present the required approval. Do not claim writing is unavailable merely because no approval has yet been requested. Do not call a never operation or use another tool to work around it.
        Discover exact roots with local__workspace_folders; its success confirms folder authorization only, NOT successful project I/O. Report file read/write success only from the corresponding tool result. This snapshot does not authorize actions the user has not requested.
        """
    }

    private func hostToolPermissions() async -> [String: LocalToolPermission] {
        let snapshot = await policy.effectivePermissions()
        let actions: [(String, LocalToolAction)] = [
            ("local__read_file", .readFile), ("local__list_directory", .listDirectory),
            ("local__write_file", .writeFile), ("local__run_process", .runCommand)
        ]
        return Dictionary(uniqueKeysWithValues: actions.map { ($0.0, snapshot[$0.1] ?? .ask) })
    }

    private func validatedRoots() async throws -> WorkspaceFolderDiscovery {
        var metadata = WorkspaceFolderDiscovery(hostToolPermissions: await hostToolPermissions())
        for folder in await store.authorizations() {
            switch try await store.accessState(forExactRoot: folder.path) {
            case .ready: metadata.authorizedRoots.append(folder.path)
            case .needsRenewal: metadata.reauthorizationRequiredRoots = (metadata.reauthorizationRequiredRoots ?? []) + [folder.path]
            case .missing: break
            }
        }
        return metadata
    }
}

struct WorkspaceFolderAccessPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var uiLocale
    let conversationID: UUID
    @State private var choosing = false

    var body: some View {
        let _ = uiLocale.identifier
        ForEach(model.pendingWorkspaceFolders.filter { $0.conversationID == conversationID }) { request in
            VStack(alignment: .leading, spacing: 10) {
                Label(request.requiresReauthorization ? l10n("Reauthorize workspace folder") : l10n("Choose a workspace folder"),
                      systemImage: "folder.badge.plus").font(.headline)
                Text(request.requiresReauthorization
                     ? l10n("The saved folder authorization is no longer valid. Choose the folder again to continue. Your files and chats have not been changed.")
                     : l10n("Choose a folder to continue this task. File changes and commands still require permission."))
                    .font(.callout).foregroundStyle(FiliconTheme.textSecondary)
                if let root = request.requestedRoot, !root.isEmpty {
                    Text(l10n("Requested folder: \(root)")).font(.caption).lineLimit(2).textSelection(.enabled)
                }
                if !model.workspaceAuthorizations.isEmpty && !request.requiresReauthorization {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.workspaceAuthorizations) { folder in
                                Button { Task { await model.useWorkspaceFolder(folder, for: request) } } label: {
                                    Label(folder.path, systemImage: "folder").font(.caption).lineLimit(2)
                                }
                            }
                        }
                    }.frame(maxHeight: 110)
                }
                HStack {
                    Button(l10n("Choose Folder…")) { Task { await chooseFolderButtonTapped(request) } }
                        .buttonStyle(FiliconPrimaryButtonStyle())
                        .accessibilityIdentifier("chat-choose-workspace-folder")
                    Button(l10n("Cancel")) { model.workspaceFolders.decline(request) }
                        .accessibilityIdentifier("chat-cancel-workspace-folder")
                }
                .disabled(choosing)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(FiliconTheme.input, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-workspace-folder-request")
        }
    }

    private func chooseFolderButtonTapped(_ request: WorkspaceFolderRequest) async {
        choosing = true
        defer { choosing = false }
        await model.chooseWorkspaceFolder(for: request)
    }
}

extension AppModel {
    func chooseWorkspaceFolder(for request: WorkspaceFolderRequest) async {
        do { try await workspaceFolders.chooseFolder(request) }
        catch { errorMessage = error.localizedDescription }
        await reloadLocalToolSettings()
    }

    func useWorkspaceFolder(_ folder: WorkspaceAuthorization, for request: WorkspaceFolderRequest) async {
        do { try await workspaceFolders.resolve(request, selectedURL: URL(fileURLWithPath: folder.path), alreadyAuthorized: true) }
        catch LocalToolError.workspaceAuthorizationNeedsRenewal {
            // Clicking a saved folder is not enough to resurrect an invalid
            // grant. The user must explicitly select it in the native picker.
            await chooseWorkspaceFolder(for: request)
        }
        catch { errorMessage = error.localizedDescription }
    }
}
