import Foundation

public protocol AutoReviewClassifier: Sendable {
    func classify(
        action: AutoReviewAction,
        instructions: AutoReviewInstructions
    ) async throws -> AutoReviewClassification
}

/// A local, auditable classifier. Rules are normalized natural-language phrases
/// and are matched conservatively as complete phrases in the action description.
public struct DeterministicAutoReviewClassifier: AutoReviewClassifier {
    public init() {}

    public func classify(
        action: AutoReviewAction,
        instructions: AutoReviewInstructions
    ) async throws -> AutoReviewClassification {
        let text = normalize(action.searchableText)
        if let rule = instructions.askRules.first(where: { matches($0, text: text) }) {
            return .init(decision: .ask, reason: "Matched ask rule: \(rule)", isTrusted: true)
        }
        if let rule = instructions.allowRules.first(where: { matches($0, text: text) }) {
            return .init(decision: .allow, reason: "Matched allow rule: \(rule)", isTrusted: true)
        }
        return .init(decision: .ask, reason: "No allow rule matched.", isTrusted: true)
    }

    private func matches(_ rule: String, text: String) -> Bool {
        let phrase = normalize(rule)
        guard phrase.count >= 3 else { return false }
        return literalPhraseMatches(phrase, in: text)
    }

    private func normalize(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public struct AutoReviewer: Sendable {
    private let classifier: any AutoReviewClassifier

    public init(classifier: any AutoReviewClassifier = DeterministicAutoReviewClassifier()) {
        self.classifier = classifier
    }

    public func evaluate(
        _ action: AutoReviewAction,
        instructions: AutoReviewInstructions
    ) async -> AutoReviewEvaluation {
        guard instructions.isEnabled else {
            return .init(decision: .ask, reason: "Auto-review is disabled.")
        }
        let prohibited: Set<AutoReviewRisk> = [.destructive, .sensitive, .irreversible]
        guard action.risks.isDisjoint(with: prohibited) else {
            return .init(decision: .ask, reason: "Built-in safety requires approval for destructive, sensitive, or irreversible actions.")
        }
        // The core independently enforces literal ask rules before consulting
        // any pluggable classifier, so a permissive provider cannot reverse a
        // direct block/ask instruction.
        let normalizedText = normalize(action.searchableText)
        if let rule = instructions.askRules.first(where: {
            let phrase = normalize($0)
            return phrase.count >= 3 && literalPhraseMatches(phrase, in: normalizedText)
        }) {
            return .init(decision: .ask, reason: "Matched ask rule: \(rule)")
        }
        do {
            let classification = try await classifier.classify(action: action, instructions: instructions)
            guard classification.isTrusted else {
                return .init(decision: .ask, reason: "No trusted classifier was available.")
            }
            return .init(decision: classification.decision, reason: classification.reason)
        } catch {
            return .init(decision: .ask, reason: "Classifier failed closed: \(error.localizedDescription)")
        }
    }

    private func normalize(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Literal matching with Unicode letter/number boundaries. This preserves
/// punctuation-bearing rules such as hostnames while preventing a short rule
/// such as "read" from auto-allowing an unrelated word such as "thread".
private func literalPhraseMatches(_ phrase: String, in text: String) -> Bool {
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let range = text.range(of: phrase, options: [.literal], range: searchStart..<text.endIndex) {
        let startsWithWord = phrase.first.map(isWordCharacter) == true
        let endsWithWord = phrase.last.map(isWordCharacter) == true
        let beforeIsWord = range.lowerBound > text.startIndex
            && isWordCharacter(text[text.index(before: range.lowerBound)])
        let afterIsWord = range.upperBound < text.endIndex
            && isWordCharacter(text[range.upperBound])
        if (!startsWithWord || !beforeIsWord) && (!endsWithWord || !afterIsWord) {
            return true
        }
        searchStart = range.upperBound
    }
    return false
}

private func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
}
