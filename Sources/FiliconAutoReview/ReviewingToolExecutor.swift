import Foundation
import FiliconDomain

public enum ReviewingToolExecutorError: LocalizedError, Equatable, Sendable {
    case actionContextMismatch

    public var errorDescription: String? {
        "The auto-review action does not match the active conversation, run, and tool call."
    }
}

/// A real execution gate: an `.ask` evaluation suspends the tool invocation;
/// approval resumes the wrapped executor exactly once, while denial, expiry,
/// cancellation, or a fence change prevents it from running.
public struct ReviewingToolExecutor: ToolExecutor {
    public typealias ActionFactory = @Sendable (
        _ call: NormalizedToolCall,
        _ descriptor: ToolDescriptor,
        _ context: ToolContext
    ) async throws -> AutoReviewAction
    public typealias InstructionsProvider = @Sendable () async throws -> AutoReviewInstructions
    public typealias PendingHandler = @Sendable (PendingApproval) async -> Void

    private let wrapped: any ToolExecutor
    private let reviewer: AutoReviewer
    private let broker: PendingApprovalBroker
    private let approvalLifetime: TimeInterval
    private let actionFactory: ActionFactory
    private let instructionsProvider: InstructionsProvider
    private let onPending: PendingHandler

    public var descriptor: ToolDescriptor { wrapped.descriptor }

    public init(
        wrapping wrapped: any ToolExecutor,
        reviewer: AutoReviewer = AutoReviewer(),
        broker: PendingApprovalBroker,
        approvalLifetime: TimeInterval = 300,
        instructions: @escaping InstructionsProvider,
        action: @escaping ActionFactory,
        onPending: @escaping PendingHandler = { _ in }
    ) {
        self.wrapped = wrapped
        self.reviewer = reviewer
        self.broker = broker
        self.approvalLifetime = max(1, approvalLifetime)
        self.instructionsProvider = instructions
        self.actionFactory = action
        self.onPending = onPending
    }

    public func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        let action = try await actionFactory(call, descriptor, context)
        guard action.context.conversationID == context.conversationID,
              action.context.fence.runID == context.runID,
              action.context.toolCallID == call.id.rawValue else {
            throw ReviewingToolExecutorError.actionContextMismatch
        }
        let instructions: AutoReviewInstructions
        do { instructions = try await instructionsProvider() }
        catch {
            return try await requestApproval(
                for: action,
                reason: "Instructions could not be loaded; approval is required.",
                call: call,
                context: context
            )
        }
        let evaluation = await reviewer.evaluate(action, instructions: instructions)
        switch evaluation.decision {
        case .allow:
            return try await wrapped.execute(call, context: context)
        case .ask:
            return try await requestApproval(for: action, reason: evaluation.reason, call: call, context: context)
        }
    }

    private func requestApproval(
        for action: AutoReviewAction,
        reason: String,
        call: NormalizedToolCall,
        context: ToolContext
    ) async throws -> NormalizedToolResult {
        let pending = PendingApproval(
            action: action,
            reason: reason,
            expiresAt: Date().addingTimeInterval(approvalLifetime)
        )
        try await broker.waitForApprovalToExecute(pending, onRegistered: onPending)
        try Task.checkCancellation()
        return try await wrapped.execute(call, context: context)
    }
}
