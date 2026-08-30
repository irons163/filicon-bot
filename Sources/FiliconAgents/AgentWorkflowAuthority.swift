import Foundation

/// The complete action surface available to persisted workflows. Deliberately absent are
/// shell/process execution, URL fetching/opening, tool invocation, and permission changes.
public enum AgentWorkflowAllowedAction: String, CaseIterable, Codable, Hashable, Sendable {
    case notify
    case createDraft = "create_draft"
    case appendTranscriptNote = "append_transcript_note"
}

public struct AgentWorkflowPromptRequest: Hashable, Sendable {
    public var workflowID: String
    public var agentID: UUID?
    public var runID: UUID
    public var prompt: String
    public var referencedWorkflows: [AgentWorkflow]
    public var priorOutputs: [String]

    public init(workflowID: String, agentID: UUID? = nil, runID: UUID, prompt: String,
                referencedWorkflows: [AgentWorkflow], priorOutputs: [String]) {
        self.workflowID = workflowID
        self.agentID = agentID
        self.runID = runID
        self.prompt = prompt
        self.referencedWorkflows = referencedWorkflows
        self.priorOutputs = priorOutputs
    }
}

public protocol AgentWorkflowPromptExecuting: Sendable {
    func executePrompt(_ request: AgentWorkflowPromptRequest) async throws -> String
}

public struct AgentWorkflowActionRequest: Hashable, Sendable {
    public var workflowID: String
    public var runID: UUID
    public var action: AgentWorkflowAllowedAction
    public var payload: String
    public var priorOutputs: [String]

    public init(workflowID: String, runID: UUID, action: AgentWorkflowAllowedAction,
                payload: String, priorOutputs: [String]) {
        self.workflowID = workflowID
        self.runID = runID
        self.action = action
        self.payload = payload
        self.priorOutputs = priorOutputs
    }
}

/// Authorization is consulted for every action execution; there is no persisted workflow field
/// that can bypass or expand this authority.
public protocol AgentWorkflowActionAuthorizing: Sendable {
    func authorize(_ request: AgentWorkflowActionRequest) async -> Bool
}

public protocol AgentWorkflowActionHandling: Sendable {
    func perform(_ request: AgentWorkflowActionRequest) async throws -> String
}

public struct DenyAllAgentWorkflowActions: AgentWorkflowActionAuthorizing {
    public init() {}
    public func authorize(_ request: AgentWorkflowActionRequest) async -> Bool { false }
}

/// App-injectable executor that keeps prompts and low-authority actions behind separate interfaces.
/// Action names fail closed against ``AgentWorkflowAllowedAction`` before authorization is asked.
public struct AuthorizedAgentWorkflowExecutor: AgentWorkflowStepExecutor {
    private let promptExecutor: any AgentWorkflowPromptExecuting
    private let actionAuthorizer: any AgentWorkflowActionAuthorizing
    private let actionHandler: any AgentWorkflowActionHandling

    public init(promptExecutor: any AgentWorkflowPromptExecuting,
                actionAuthorizer: any AgentWorkflowActionAuthorizing = DenyAllAgentWorkflowActions(),
                actionHandler: any AgentWorkflowActionHandling) {
        self.promptExecutor = promptExecutor
        self.actionAuthorizer = actionAuthorizer
        self.actionHandler = actionHandler
    }

    public func execute(_ request: AgentWorkflowStepRequest) async throws -> String {
        switch request.step {
        case .prompt(let prompt):
            return try await promptExecutor.executePrompt(.init(
                workflowID: request.workflowID,
                agentID: request.agentID,
                runID: request.runID,
                prompt: prompt,
                referencedWorkflows: request.referencedWorkflows,
                priorOutputs: request.priorOutputs
            ))
        case .action(let name, let payload):
            guard let action = AgentWorkflowAllowedAction(rawValue: name) else {
                throw AgentWorkflowError.unsupportedAction(name)
            }
            let actionRequest = AgentWorkflowActionRequest(
                workflowID: request.workflowID,
                runID: request.runID,
                action: action,
                payload: payload,
                priorOutputs: request.priorOutputs
            )
            guard await actionAuthorizer.authorize(actionRequest) else {
                throw AgentWorkflowError.actionDenied(name)
            }
            return try await actionHandler.perform(actionRequest)
        }
    }
}
