import Foundation
import SwiftUI
import FiliconDomain
import FiliconMCP

struct MCPApprovalPresentation: Identifiable, Sendable, Equatable {
    let request: MCPApprovalRequest
    let serverName: String
    let accountName: String
    let argumentsSummary: String
    let policy: MCPDispatchPolicy
    var id: UUID { request.id }
}

enum AppMCPApprovalDecision: Sendable {
    case resolution(MCPApprovalResolution)
    case expired
    case cancelled
}

actor AppMCPApprovalBroker {
    typealias ChangeHandler = @Sendable ([MCPApprovalPresentation]) -> Void
    private struct Pending {
        let presentation: MCPApprovalPresentation
        let continuation: CheckedContinuation<AppMCPApprovalDecision, Never>
        let expiry: Task<Void, Never>
    }

    private var pending: [UUID: Pending] = [:]
    private var knownTargets = Set<MCPCallTarget>()
    private let onChange: ChangeHandler

    init(onChange: @escaping ChangeHandler = { _ in }) { self.onChange = onChange }

    func register(_ target: MCPCallTarget) { knownTargets.insert(target) }

    func request(_ presentation: MCPApprovalPresentation) async -> AppMCPApprovalDecision {
        // Registration happens before authorization.prepare. If a config/account/conversation
        // fence advanced in between, invalidate() removed this target and the stale request must
        // never be republished to the UI.
        guard knownTargets.contains(presentation.request.target) else { return .cancelled }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .cancelled); return }
                let id = presentation.id
                let delay = max(0, presentation.request.expiresAt.timeIntervalSinceNow)
                let expiry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    await self?.expire(id: id)
                }
                pending[id] = .init(presentation: presentation, continuation: continuation, expiry: expiry)
                publish()
            }
        } onCancel: { Task { await self.cancel(id: presentation.id) } }
    }

    @discardableResult
    func resolveIfMatches(_ presentation: MCPApprovalPresentation, resolution: MCPApprovalResolution) -> Bool {
        guard let value = pending[presentation.id], value.presentation == presentation else { return false }
        finish(id: presentation.id, decision: .resolution(resolution))
        return true
    }

    func cancel(id: UUID) { finish(id: id, decision: .cancelled) }

    func cancel(conversationID: UUID) -> [MCPCallTarget] {
        invalidate { $0.conversationIdentifier == conversationID.uuidString }
    }

    func cancel(serverIdentifier: String, accountIdentifier: String? = nil) -> [MCPCallTarget] {
        invalidate {
            $0.serverIdentifier == serverIdentifier
                && (accountIdentifier == nil || $0.accountIdentifier == accountIdentifier)
        }
    }

    func cancelAll() -> [MCPCallTarget] { invalidate { _ in true } }

    private func expire(id: UUID) { finish(id: id, decision: .expired) }

    private func finish(id: UUID, decision: AppMCPApprovalDecision) {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.expiry.cancel()
        value.continuation.resume(returning: decision)
        publish()
    }

    private func invalidate(_ predicate: (MCPCallTarget) -> Bool) -> [MCPCallTarget] {
        let targets = knownTargets.filter(predicate)
        knownTargets.subtract(targets)
        let pendingIDs = pending.values.filter { predicate($0.presentation.request.target) }.map { $0.presentation.id }
        for id in pendingIDs { finish(id: id, decision: .cancelled) }
        return Array(targets)
    }

    private func publish() {
        onChange(pending.values.map(\.presentation).sorted { $0.request.createdAt < $1.request.createdAt })
    }
}

enum AppMCPDispatchError: LocalizedError {
    case denied(String)
    var errorDescription: String? { if case .denied(let reason) = self { reason } else { nil } }
}

struct AuthorizedMCPToolExecutor: ToolExecutor {
    let dispatcher: MCPAuthorizedDispatcher
    let authorization: MCPAuthorizationCoordinator
    let approvals: AppMCPApprovalBroker
    let tool: MCPToolDescriptor
    let accountIdentifier: String
    let serverName: String
    let accountName: String
    let policy: MCPDispatchPolicy

    var descriptor: ToolDescriptor {
        let schema = (try? JSONEncoder().encode(tool.inputSchema)) ?? Data("{\"type\":\"object\"}".utf8)
        return .init(
            name: ToolName(rawValue: "mcp__\(tool.serverIdentifier)__\(tool.name)"),
            description: tool.description, inputSchema: schema, parallelSafe: false
        )
    }

    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        let arguments = try JSONDecoder().decode(MCPJSONValue.self, from: call.argumentsJSON)
        let target = await authorization.makeTarget(
            serverIdentifier: tool.serverIdentifier,
            accountIdentifier: accountIdentifier,
            conversationIdentifier: context.conversationID.uuidString,
            toolName: tool.name,
            arguments: arguments
        )
        await approvals.register(target)
        let preparation = await authorization.prepare(
            target: target, descriptor: tool, policy: policy, autoReview: .ask
        )
        let receipt: MCPAuthorizationReceipt
        switch preparation {
        case .authorized(let value): receipt = value
        case .denied(let reason): throw AppMCPDispatchError.denied(reason)
        case .approvalRequired(let request):
            let presentation = MCPApprovalPresentation(
                request: request, serverName: serverName, accountName: accountName,
                argumentsSummary: MCPArgumentsSummary.make(arguments), policy: policy
            )
            let decision = await approvals.request(presentation)
            switch decision {
            case .resolution(let resolution):
                guard let value = try await authorization.resolve(
                    requestID: request.id, resolution: resolution, policy: policy
                ) else { throw MCPAuthorizationError.denied }
                receipt = value
            case .expired:
                // Cancel first, then drain the core request. This cannot issue a receipt even if
                // the UI expiry timer fires slightly before the coordinator's wall clock boundary.
                try await Self.discardExpiredRequest(request.id, authorization: authorization, policy: policy)
                throw MCPAuthorizationError.requestExpired
            case .cancelled:
                await authorization.cancel(requestID: request.id)
                do {
                    _ = try await authorization.resolve(requestID: request.id, resolution: .allowOnce, policy: policy)
                } catch MCPAuthorizationError.unknownRequest {
                    throw MCPAuthorizationError.requestCancelled
                } catch MCPAuthorizationError.staleGeneration {
                    throw MCPAuthorizationError.requestCancelled
                }
                throw MCPAuthorizationError.requestCancelled
            }
        }
        let result = try await dispatcher.dispatch(target: target, arguments: arguments, receipt: receipt, policy: policy)
        let content: [ToolResultContent] = result.content.map { item in
            if let uri = item.uri { return .resource(uri: uri, mimeType: item.mimeType) }
            if let text = item.text { return .text(text) }
            if let data = item.data { return .text("[\(item.mimeType ?? item.type)] \(data)") }
            return .text("[\(item.type)]")
        }
        return .init(callID: call.id, content: content, isError: result.isError)
    }

    static func discardExpiredRequest(
        _ requestID: UUID,
        authorization: MCPAuthorizationCoordinator,
        policy: MCPDispatchPolicy
    ) async throws {
        await authorization.cancel(requestID: requestID)
        do {
            if try await authorization.resolve(
                requestID: requestID, resolution: .allowOnce, policy: policy
            ) != nil {
                throw MCPAuthorizationError.invalidReceipt
            }
        } catch let error as MCPAuthorizationError {
            switch error {
            case .requestCancelled, .requestExpired, .unknownRequest, .staleGeneration:
                return
            default:
                throw error
            }
        }
    }
}

actor MCPUserPolicyStore {
    private struct Document: Codable { var modes: [String: MCPPermissionMode] = [:] }
    private let url: URL
    private var document: Document

    init(url: URL) {
        self.url = url
        document = (try? JSONDecoder().decode(Document.self, from: Data(contentsOf: url))) ?? .init()
    }

    func mode(serverIdentifier: String) -> MCPPermissionMode { document.modes[serverIdentifier] ?? .ask }

    func set(_ mode: MCPPermissionMode, serverIdentifier: String) throws {
        document.modes[serverIdentifier] = mode
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

struct MCPApprovalPanel: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    var conversationID: UUID? = nil

    var body: some View {
        let _ = uiLocale.identifier
        let approvals = model.pendingMCPApprovals.filter {
            $0.request.target.conversationIdentifier == (conversationID ?? model.selection)?.uuidString
        }
        if !approvals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(l10n("MCP tool approval"), systemImage: "checkmark.shield")
                    .font(.headline)
                ForEach(approvals) { approval in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(approval.serverName) · \(approval.accountName)").fontWeight(.medium)
                            Spacer()
                            Text(approval.request.risk.risk.label).foregroundStyle(approval.request.risk.risk.color)
                        }
                        Text(approval.request.target.toolName).font(.callout.monospaced())
                        if !approval.request.risk.reasons.isEmpty {
                            Text(approval.request.risk.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
                        }
                        Text(approval.argumentsSummary).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                        ViewThatFits(in: .horizontal) {
                            approvalButtons(approval, horizontal: true)
                            approvalButtons(approval, horizontal: false)
                        }
                        Text(l10n("Expires \(approval.request.expiresAt.formatted(date: .omitted, time: .shortened))"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
    }

    private func approvalButtons(_ approval: MCPApprovalPresentation, horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout()) : AnyLayout(VStackLayout(alignment: .leading))
        return layout {
            Button(l10n("Allow Once")) { model.resolveMCPApproval(approval, resolution: .allowOnce) }
            Button(l10n("Always Exact Arguments")) { model.resolveMCPApproval(approval, resolution: .allowAlways(scope: .exactArguments)) }
                .disabled(!approval.canPersist)
            Button(l10n("Always This Tool")) { model.resolveMCPApproval(approval, resolution: .allowAlways(scope: .tool)) }
                .disabled(!approval.canPersistTool)
            Button(l10n("Deny"), role: .destructive) { model.resolveMCPApproval(approval, resolution: .deny) }
        }
    }
}

extension MCPApprovalPresentation {
    var canPersist: Bool { policy.managedCeiling == .always && request.risk.risk != .unknown }
    var canPersistTool: Bool { canPersist }
}

private extension MCPToolRisk {
    var label: String {
        switch self {
        case .localRead: l10n("Local read")
        case .openWorldRead: l10n("Open-world read")
        case .mutation: l10n("Mutation")
        case .destructive: l10n("Destructive")
        case .unknown: l10n("Unknown — fail closed")
        }
    }
    var color: Color {
        switch self {
        case .localRead: .secondary
        case .openWorldRead: .blue
        case .mutation: .orange
        case .destructive, .unknown: .red
        }
    }
}

enum MCPArgumentsSummary {
    static func make(_ value: MCPJSONValue) -> String {
        String(render(value, key: nil).prefix(2_000))
    }

    private static func render(_ value: MCPJSONValue, key: String?) -> String {
        if let key, ["token", "secret", "password", "authorization", "credential", "api_key", "apikey"].contains(where: { key.lowercased().contains($0) }) {
            return "<redacted>"
        }
        return switch value {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value): String(value)
        case .string(let value): "\"\(String(value.prefix(300)))\""
        case .array(let values): "[" + values.prefix(20).map { render($0, key: nil) }.joined(separator: ", ") + "]"
        case .object(let values):
            "{" + values.keys.sorted().prefix(30).map { "\($0): \(render(values[$0]!, key: $0))" }.joined(separator: ", ") + "}"
        }
    }
}
