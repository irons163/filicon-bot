import Foundation
import CryptoKit
import FiliconAgents
import FiliconDomain

struct WorkflowComposerSuggestion: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
}

enum WorkflowComposerReferences {
    static let maximumSuggestions = 100
    static let maximumReferences = 16
    static let maximumInjectedBodyBytes = 8_000

    struct Query: Equatable {
        let replacementRange: Range<String.Index>
        let value: String
    }

    struct ScopedReference: Equatable {
        let workflow: AgentWorkflow
        let teachQueueScope: String?
    }

    static func query(in draft: String) -> Query? {
        guard let slash = draft.lastIndex(of: "/") else { return nil }
        let prefix = draft[..<slash]
        guard prefix.last.map({ $0.isWhitespace }) ?? true else { return nil }
        let valueStart = draft.index(after: slash)
        let value = String(draft[valueStart...])
        guard !value.contains(where: { $0.isNewline }) else { return nil }
        return Query(replacementRange: slash..<draft.endIndex, value: value)
    }

    static func suggestions(in draft: String, workflows: [AgentWorkflow]) -> [WorkflowComposerSuggestion] {
        guard let query = query(in: draft) else { return [] }
        let needle = query.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return workflows.lazy
            .filter { workflow in
                guard workflow.isEnabled, case .manual = workflow.trigger else { return false }
                return needle.isEmpty
                    || workflow.name.lowercased().contains(needle)
                    || workflow.id.lowercased().contains(needle)
                    || workflow.description.lowercased().contains(needle)
            }
            .prefix(maximumSuggestions)
            .map { .init(id: $0.id, name: $0.name, description: $0.description) }
    }

    static func inserting(_ suggestion: WorkflowComposerSuggestion, into draft: String) -> String {
        guard let query = query(in: draft) else { return draft }
        let reference = "[\(suggestion.name)](sand-workflow:\(suggestion.id)) "
        return draft.replacingCharacters(in: query.replacementRange, with: reference)
    }

    static func referencedWorkflows(in prompt: String, workflows: [AgentWorkflow]) -> [AgentWorkflow] {
        scopedReferences(in: prompt, workflows: workflows).map(\.workflow)
    }

    static func scopedReferences(in prompt: String, workflows: [AgentWorkflow]) -> [ScopedReference] {
        guard !prompt.isEmpty else { return [] }
        let carrier = AgentWorkflow(id: "composer-reference", name: "Composer reference", steps: [.prompt(prompt)])
        let ids = Set(AgentWorkflowReferenceResolver.mentionedIDs(in: carrier, library: workflows).map { $0.lowercased() })
        let scopes = teachScopes(in: prompt)
        return workflows.filter { workflow in
            guard ids.contains(workflow.id.lowercased()), workflow.isEnabled else { return false }
            if case .manual = workflow.trigger { return true }
            return false
        }.prefix(maximumReferences).map { workflow in
            ScopedReference(
                workflow: workflow,
                teachQueueScope: workflow.id == "learn-from-demonstration" ? scopes[workflow.id] : nil
            )
        }
    }

    static func injectingReferencedWorkflows(
        into messages: [ChatMessage],
        workflows: [AgentWorkflow]
    ) -> [ChatMessage] {
        guard let userIndex = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        let referenced = scopedReferences(in: messages[userIndex].text, workflows: workflows)
        guard !referenced.isEmpty else { return messages }

        let rendered = referenced.map { reference in
            let workflow = reference.workflow
            let body = workflow.steps.compactMap { step -> String? in
                guard case .prompt(let text) = step else { return nil }
                return text
            }.joined(separator: "\n\n")
            let scope = reference.teachQueueScope.map { "\n\nTeach recording queue scope: \($0)" } ?? ""
            return "## \(workflow.name) (`\(workflow.id)`)\n\(boundedUTF8(body, maximumBytes: maximumInjectedBodyBytes))\(scope)"
        }.joined(separator: "\n\n")
        let system = ChatMessage(
            role: .system,
            text: "The user explicitly referenced the following shared workflows. Follow only these bounded workflow bodies for this turn.\n\n\(rendered)"
        )
        var result = messages
        result.insert(system, at: userIndex)
        return result
    }

    static func learningReference(agentID: String, label: String = "Learn from demonstration") -> String {
        let scope = SHA256.hash(data: Data(agentID.utf8)).map { String(format: "%02x", $0) }.joined()
        return l10n("[\(label)](sand-workflow:learn-from-demonstration?teachQueueScope=\(scope))")
    }

    private static func teachScopes(in prompt: String) -> [String: String] {
        let pattern = #"sand-workflow:(learn-from-demonstration)\?teachQueueScope=([a-f0-9]{64})(?![a-f0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [:] }
        var values: [String: String] = [:]
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        expression.enumerateMatches(in: prompt, range: range) { match, _, _ in
            guard let match,
                  let idRange = Range(match.range(at: 1), in: prompt),
                  let scopeRange = Range(match.range(at: 2), in: prompt) else { return }
            values[String(prompt[idRange]).lowercased()] = String(prompt[scopeRange]).lowercased()
        }
        return values
    }

    private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > maximumBytes else { return value }
        var end = maximumBytes
        while end > 0, bytes[end] & 0b1100_0000 == 0b1000_0000 { end -= 1 }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
