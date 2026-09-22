import Foundation

public struct AgentQuestion: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable {
        public enum Style: String, Codable, Sendable { case `default`, primary, danger }
        public let label: String
        public let value: String?
        public let description: String?
        public let style: Style?
        public var reply: String { value ?? label }
    }

    public let prompt: String
    public let helpText: String?
    public let options: [Option]
    public let allowCustom: Bool?
    public let dismissOnMoveOn: Bool?

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 16_384,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["prompt", "helpText", "options", "allowCustom", "dismissOnMoveOn"]),
              let options = object["options"] as? [[String: Any]],
              options.allSatisfy({ Set($0.keys).isSubset(of: ["label", "value", "description", "style"]) }),
              !object.values.contains(where: { $0 is NSNull }),
              !options.contains(where: { $0.values.contains(where: { $0 is NSNull }) }) else {
            throw AgentQuestionError.invalid
        }
        let question = try JSONDecoder().decode(Self.self, from: data)
        try question.validate()
        return question
    }

    public func validate() throws {
        guard try JSONEncoder().encode(self).count <= 16_384 else { throw AgentQuestionError.invalid }
        guard Self.validText(prompt, maximum: 1_000),
              helpText.map({ Self.validText($0, maximum: 2_000) }) ?? true,
              (1...6).contains(options.count),
              options.allSatisfy({ Self.validText($0.label, maximum: 120)
                  && Self.validText($0.reply, maximum: 2_000)
                  && ($0.description.map { Self.validText($0, maximum: 500) } ?? true) }),
              Set(options.map(\.label)).count == options.count,
              Set(options.map(\.reply)).count == options.count else { throw AgentQuestionError.invalid }
    }

    public static func validText(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximum
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }

    public func reply(for answer: AgentQuestionAnswer) throws -> String {
        try validate()
        switch answer {
        case .option(let index):
            guard options.indices.contains(index) else { throw AgentQuestionError.invalid }
            return options[index].reply
        case .custom(let text):
            guard allowCustom == true, Self.validText(text, maximum: 2_000) else { throw AgentQuestionError.invalid }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .dismissed: return "Question dismissed without an answer."
        }
    }
}

public enum AgentQuestionAnswer: Codable, Hashable, Sendable {
    case option(Int), custom(String), dismissed
}

public struct GroupQuestion: Codable, Hashable, Sendable {
    public let question: AgentQuestion
    public let accountID: String
    public let memberIDs: [UUID]
    public var answer: AgentQuestionAnswer?
    public var responseMessageID: UUID?
    public var retired = false
    public var isPending: Bool { answer == nil && !retired }

    public init(question: AgentQuestion, accountID: String, memberIDs: [UUID]) {
        self.question = question; self.accountID = accountID; self.memberIDs = memberIDs
    }
}

public enum AgentQuestionError: LocalizedError, Equatable, Sendable {
    case invalid, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalid: "The question or answer is invalid. Nothing was sent."
        case .unavailable: "This question is no longer available in this account or group."
        }
    }
}
