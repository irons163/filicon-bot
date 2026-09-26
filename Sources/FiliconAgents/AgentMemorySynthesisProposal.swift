import Foundation

/// Structural validation only. A proposal is not a verified fact, permission,
/// or persistent mutation. The host must still verify evidence semantics and
/// atomically revalidate the snapshot before applying any changes.
struct AgentMemorySynthesisProposal: Equatable, Sendable {
    enum Action: String, Sendable { case create, update, remove }
    struct Change: Equatable, Sendable {
        let action: Action
        let id: UUID?
        let content: String?
        let tier: AgentMemory.Tier?
        let evidenceIDs: [String]
    }
    enum Invalid: Error { case proposal }
    let changes: [Change]

    /// `mutableMemoryIDs` must come from host-owned provenance, never model
    /// output. Existing explicit/approved memories must not be included.
    /// Clock evidence is host-supplied and cannot justify creating a new fact.
    static func parse(_ text: String, evidenceIDs: Set<String>,
                      mutableMemoryIDs: Set<UUID>, clockEvidenceID: String? = nil) throws -> Self {
        guard text.utf8.count <= 262_144,
              evidenceIDs.count <= 12, evidenceIDs.allSatisfy(validID),
              clockEvidenceID.map({ validID($0) && !evidenceIDs.contains($0) }) ?? true,
              let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(root.keys) == ["changes"],
              let rows = root["changes"] as? [[String: Any]], rows.count <= 64 else {
            throw Invalid.proposal
        }
        var changes: [Change] = []
        var touched: Set<UUID> = []
        for row in rows {
            guard let rawAction = row["action"] as? String, let action = Action(rawValue: rawAction),
                  let sources = row["sourceEvidenceIds"] as? [String], !sources.isEmpty, sources.count <= 32,
                  Set(sources).count == sources.count,
                  sources.allSatisfy({ validID($0) && (evidenceIDs.contains($0) || $0 == clockEvidenceID) }) else {
                throw Invalid.proposal
            }
            let expected: Set<String>
            switch action {
            case .create: expected = ["action", "content", "kind", "sourceEvidenceIds"]
            case .update: expected = ["action", "id", "content", "kind", "sourceEvidenceIds"]
            case .remove: expected = ["action", "id", "sourceEvidenceIds"]
            }
            guard Set(row.keys) == expected else { throw Invalid.proposal }
            var id: UUID?
            if action != .create {
                guard let raw = row["id"] as? String, let target = UUID(uuidString: raw),
                      mutableMemoryIDs.contains(target), touched.insert(target).inserted else {
                    throw Invalid.proposal
                }
                id = target
            } else if !sources.contains(where: evidenceIDs.contains) {
                throw Invalid.proposal
            }
            var content: String?
            var tier: AgentMemory.Tier?
            if action != .remove {
                guard let raw = row["content"] as? String, raw.count <= 500, raw.utf8.count <= 2_000,
                      !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      let kind = row["kind"] as? String, ["profile", "log"].contains(kind) else {
                    throw Invalid.proposal
                }
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { throw Invalid.proposal }
                content = normalized
                tier = AgentMemory.Tier(rawValue: kind)
            }
            changes.append(.init(action: action, id: id, content: content, tier: tier, evidenceIDs: sources))
        }
        return .init(changes: changes)
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.utf8.count <= 256
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
