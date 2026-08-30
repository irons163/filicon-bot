import Foundation

public enum AgentWorkflowLimits {
    public static let maximumWorkflows = 100
    public static let maximumNameCharacters = 80
    public static let maximumDescriptionCharacters = 1_536
    public static let maximumBodyBytes = 100_000
    public static let maximumSteps = 64
    public static let maximumActionNameCharacters = 128
    public static let maximumActionPayloadBytes = 32_768
    public static let maximumReferences = 16
    public static let maximumReferenceDepth = 8
    public static let maximumURLBytes = 100_000
    public static let maximumRuns = 200
    public static let maximumRunFailureBytes = 8_192
}

public enum AgentWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case malformed(String), unsupportedSchema(Int), invalidIdentifier, invalidName
    case boundsExceeded(String), duplicateIdentifier, notFound, disabled
    case triggerMismatch, referenceNotFound(String), referenceCycle, insecureURL
    case deadlineExceeded, cancelled, staleGeneration, replayRejected
    case persistenceUnsafe, actionDenied(String), unsupportedAction(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let value): "Malformed workflow: \(value)"
        case .unsupportedSchema(let value): "Unsupported workflow schema version \(value)."
        case .invalidIdentifier: "The workflow identifier is invalid."
        case .invalidName: "The workflow name is empty or invalid."
        case .boundsExceeded(let value): "Workflow limit exceeded: \(value)."
        case .duplicateIdentifier: "A workflow with that identifier already exists."
        case .notFound: "The workflow was not found."
        case .disabled: "The workflow is disabled."
        case .triggerMismatch: "The workflow does not accept this trigger."
        case .referenceNotFound(let id): "Referenced workflow '\(id)' was not found."
        case .referenceCycle: "Workflow references contain a cycle."
        case .insecureURL: "Workflow imports require a public HTTPS URL."
        case .deadlineExceeded: "The workflow exceeded its deadline."
        case .cancelled: "The workflow was cancelled."
        case .staleGeneration: "A stale workflow generation attempted to commit state."
        case .replayRejected: "The workflow run cannot be replayed."
        case .persistenceUnsafe: "Workflow persistence refused a symbolic link or unsafe path."
        case .actionDenied(let name): "Workflow action '\(name)' was not authorized."
        case .unsupportedAction(let name): "Workflow action '\(name)' is not in the allowlist."
        }
    }
}

public enum AgentWorkflowTrigger: Hashable, Sendable {
    case manual
    case event(String)
    case schedule(String)
}

extension AgentWorkflowTrigger: Codable {
    private enum Keys: String, CodingKey { case type, event, schedule }
    private enum Kind: String, Codable { case manual, event, schedule }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let unknown = Set(values.allKeys.map(\.stringValue)).subtracting(["type", "event", "schedule"])
        guard unknown.isEmpty else { throw AgentWorkflowError.malformed("unknown trigger authority fields") }
        switch try values.decode(Kind.self, forKey: .type) {
        case .manual: self = .manual
        case .event:
            let event = try values.decode(String.self, forKey: .event).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !event.isEmpty, event.count <= 128 else { throw AgentWorkflowError.boundsExceeded("trigger event") }
            self = .event(event)
        case .schedule:
            let schedule = try values.decode(String.self, forKey: .schedule).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !schedule.isEmpty, schedule.count <= 256 else { throw AgentWorkflowError.boundsExceeded("trigger schedule") }
            self = .schedule(schedule.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        switch self {
        case .manual: try values.encode(Kind.manual, forKey: .type)
        case .event(let event): try values.encode(Kind.event, forKey: .type); try values.encode(event, forKey: .event)
        case .schedule(let schedule): try values.encode(Kind.schedule, forKey: .type); try values.encode(schedule, forKey: .schedule)
        }
    }
}

public enum AgentWorkflowStep: Hashable, Sendable {
    case prompt(String)
    case action(name: String, payload: String)
}

extension AgentWorkflowStep: Codable {
    private enum Keys: String, CodingKey { case type, text, name, payload }
    private enum Kind: String, Codable { case prompt, action }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let keys = Set(values.allKeys.map(\.stringValue))
        switch try values.decode(Kind.self, forKey: .type) {
        case .prompt:
            guard keys.subtracting(["type", "text"]).isEmpty else { throw AgentWorkflowError.malformed("unknown prompt authority fields") }
            self = .prompt(try values.decode(String.self, forKey: .text))
        case .action:
            guard keys.subtracting(["type", "name", "payload"]).isEmpty else { throw AgentWorkflowError.malformed("unknown action authority fields") }
            self = .action(name: try values.decode(String.self, forKey: .name), payload: try values.decodeIfPresent(String.self, forKey: .payload) ?? "")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        switch self {
        case .prompt(let text): try values.encode(Kind.prompt, forKey: .type); try values.encode(text, forKey: .text)
        case .action(let name, let payload):
            try values.encode(Kind.action, forKey: .type); try values.encode(name, forKey: .name); try values.encode(payload, forKey: .payload)
        }
    }
}

public struct AgentWorkflow: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var agentID: UUID?
    public var name: String
    public var description: String
    public var isEnabled: Bool
    public var trigger: AgentWorkflowTrigger
    public var steps: [AgentWorkflowStep]
    public var sourceReference: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, agentID: UUID? = nil, name: String, description: String = "", isEnabled: Bool = true,
                trigger: AgentWorkflowTrigger = .manual, steps: [AgentWorkflowStep],
                sourceReference: String? = nil, createdAt: Date = .now, updatedAt: Date? = nil) {
        self.id = id; self.agentID = agentID; self.name = name; self.description = description; self.isEnabled = isEnabled
        self.trigger = trigger; self.steps = steps; self.sourceReference = sourceReference
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    public func validated() throws -> Self {
        guard Self.isSafeIdentifier(id) else { throw AgentWorkflowError.invalidIdentifier }
        let cleanName = Self.line(name)
        guard !cleanName.isEmpty, cleanName.count <= AgentWorkflowLimits.maximumNameCharacters else { throw AgentWorkflowError.invalidName }
        let cleanDescription = Self.line(description)
        guard cleanDescription.count <= AgentWorkflowLimits.maximumDescriptionCharacters else { throw AgentWorkflowError.boundsExceeded("description") }
        switch trigger {
        case .manual: break
        case .event(let value): guard !Self.line(value).isEmpty, value.count <= 128 else { throw AgentWorkflowError.boundsExceeded("trigger event") }
        case .schedule(let value): guard !Self.line(value).isEmpty, value.count <= 256 else { throw AgentWorkflowError.boundsExceeded("trigger schedule") }
        }
        guard !steps.isEmpty, steps.count <= AgentWorkflowLimits.maximumSteps else { throw AgentWorkflowError.boundsExceeded("steps") }
        var cleanSteps: [AgentWorkflowStep] = []
        for step in steps {
            switch step {
            case .prompt(let text):
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.utf8.count <= AgentWorkflowLimits.maximumBodyBytes else { throw AgentWorkflowError.boundsExceeded("prompt") }
                cleanSteps.append(.prompt(clean))
            case .action(let name, let payload):
                let clean = Self.line(name)
                guard !clean.isEmpty, clean.count <= AgentWorkflowLimits.maximumActionNameCharacters else { throw AgentWorkflowError.boundsExceeded("action name") }
                guard payload.utf8.count <= AgentWorkflowLimits.maximumActionPayloadBytes else { throw AgentWorkflowError.boundsExceeded("action payload") }
                cleanSteps.append(.action(name: clean, payload: payload))
            }
        }
        if let sourceReference, sourceReference.utf8.count > 2_048 { throw AgentWorkflowError.boundsExceeded("source reference") }
        var result = self; result.name = cleanName; result.description = cleanDescription; result.steps = cleanSteps
        if case .event(let value) = trigger { result.trigger = .event(Self.line(value)) }
        if case .schedule(let value) = trigger { result.trigger = .schedule(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)) }
        result.sourceReference = sourceReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    public static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        let pieces = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character(String($0).lowercased()) : "-" }
        let result = String(pieces).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        return String((result.isEmpty ? "workflow" : result).prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }
    static func line(_ value: String) -> String { value.replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct AgentWorkflowDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var workflows: [AgentWorkflow]
    public init(schemaVersion: Int = currentSchemaVersion, workflows: [AgentWorkflow] = []) { self.schemaVersion = schemaVersion; self.workflows = workflows }
}

public enum AgentWorkflowCodec {
    public static func serialize(_ document: AgentWorkflowDocument) throws -> Data {
        guard document.schemaVersion == AgentWorkflowDocument.currentSchemaVersion else { throw AgentWorkflowError.unsupportedSchema(document.schemaVersion) }
        let workflows = try canonicalized(document.workflows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = try encoder.encode(AgentWorkflowDocument(workflows: workflows)); data.append(0x0A); return data
    }

    public static func parse(_ data: Data) throws -> AgentWorkflowDocument {
        guard data.count <= AgentWorkflowLimits.maximumWorkflows * (AgentWorkflowLimits.maximumBodyBytes + AgentWorkflowLimits.maximumActionPayloadBytes) else { throw AgentWorkflowError.boundsExceeded("document") }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw AgentWorkflowError.malformed("root must be an object") }
        try validateAuthorityShape(root)
        let version = root["schemaVersion"] as? Int ?? 1
        guard version <= AgentWorkflowDocument.currentSchemaVersion else { throw AgentWorkflowError.unsupportedSchema(version) }
        let normalized: Data
        if version == 1 {
            var migrated = root; migrated["schemaVersion"] = AgentWorkflowDocument.currentSchemaVersion
            if var workflows = migrated["workflows"] as? [[String: Any]] {
                for index in workflows.indices {
                    workflows[index]["isEnabled"] = workflows[index]["isEnabled"] ?? true
                    workflows[index]["trigger"] = workflows[index]["trigger"] ?? ["type": "manual"]
                    if workflows[index]["steps"] == nil, let body = workflows[index].removeValue(forKey: "body") as? String { workflows[index]["steps"] = [["type": "prompt", "text": body]] }
                }
                migrated["workflows"] = workflows
            }
            normalized = try JSONSerialization.data(withJSONObject: migrated)
        } else { normalized = data }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let document = try decoder.decode(AgentWorkflowDocument.self, from: normalized)
        return .init(workflows: try canonicalized(document.workflows))
    }

    private static func canonicalized(_ workflows: [AgentWorkflow]) throws -> [AgentWorkflow] {
        guard workflows.count <= AgentWorkflowLimits.maximumWorkflows else { throw AgentWorkflowError.boundsExceeded("workflow count") }
        var ids = Set<String>(), result: [AgentWorkflow] = []
        for workflow in workflows {
            let clean = try workflow.validated()
            guard ids.insert(clean.id).inserted else { throw AgentWorkflowError.duplicateIdentifier }
            result.append(clean)
        }
        return result
    }

    /// Codable intentionally tolerates future descriptive fields. Trigger and step objects grant
    /// execution authority, so their schema is inspected before decoding and unknown keys are denied.
    private static func validateAuthorityShape(_ root: [String: Any]) throws {
        guard let workflows = root["workflows"] else { return }
        guard let records = workflows as? [[String: Any]] else { throw AgentWorkflowError.malformed("workflows must be an array") }
        for record in records {
            if let rawTrigger = record["trigger"] {
                guard let trigger = rawTrigger as? [String: Any] else { throw AgentWorkflowError.malformed("trigger must be an object") }
                guard Set(trigger.keys).isSubset(of: ["type", "event", "schedule"]) else { throw AgentWorkflowError.malformed("unknown trigger authority fields") }
            }
            if let rawSteps = record["steps"] {
                guard let steps = rawSteps as? [[String: Any]] else { throw AgentWorkflowError.malformed("steps must be an array") }
                for step in steps {
                    let allowed: Set<String>
                    switch step["type"] as? String {
                    case "prompt": allowed = ["type", "text"]
                    case "action": allowed = ["type", "name", "payload"]
                    default: throw AgentWorkflowError.malformed("unknown step type")
                    }
                    guard Set(step.keys).isSubset(of: allowed) else { throw AgentWorkflowError.malformed("unknown step authority fields") }
                }
            }
        }
    }
}
