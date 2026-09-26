import Foundation

/// Bounded host diagnostics. Never include evidence, facts, provider errors,
/// prompts, credentials or account identifiers in this payload.
public struct AgentMemorySynthesisReport: Encodable, Equatable, Sendable {
    public enum Outcome: String, Codable, Hashable, Sendable {
        case committed, noWork, rejected, stale, invalidOutput, failed, cancelled, dropped
    }
    public let outcome: Outcome
    public let agentID: UUID
    public let evidenceCount: Int
    public let inputMemoryCount: Int
    public let changeCount: Int
    public let durationMilliseconds: Double

    public init(outcome: Outcome, agentID: UUID, evidenceCount: Int, inputMemoryCount: Int,
                changeCount: Int, durationMilliseconds: Double) {
        self.outcome = outcome; self.agentID = agentID
        self.evidenceCount = max(0, min(evidenceCount, 1_000_000))
        self.inputMemoryCount = max(0, min(inputMemoryCount, 1_000_000))
        self.changeCount = max(0, min(changeCount, 64))
        self.durationMilliseconds = durationMilliseconds.isFinite ? max(0, min(durationMilliseconds, 86_400_000)) : 0
    }
}

/// One App/account owns one journal. Replacing it on account transition also
/// isolates late callbacks still holding the old journal. Never persisted.
public final class AgentMemorySynthesisJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [AgentMemorySynthesisReport] = []
    public init() {}
    public func append(_ report: AgentMemorySynthesisReport) {
        lock.withLock {
            reports.append(report)
            if reports.count > 64 { reports.removeFirst(reports.count - 64) }
        }
    }
    public func snapshot() -> [AgentMemorySynthesisReport] { lock.withLock { reports } }
    public func summary() -> String {
        let values = snapshot()
        let counts = Dictionary(grouping: values, by: \.outcome).map { "\($0.key.rawValue)=\($0.value.count)" }.sorted()
        guard let last = values.last else { return "memorySynthesis=none" }
        return "memorySynthesis[recent=\(values.count)]=\(counts.joined(separator: ","))\n" +
            "memorySynthesisLast=\(last.outcome.rawValue);evidence=\(last.evidenceCount);memories=\(last.inputMemoryCount);changes=\(last.changeCount);ms=\(Int(last.durationMilliseconds))"
    }
}

final class AgentMemorySynthesisMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var memories = 0
    private var changes = 0
    func snapshotCount(_ value: Int) { lock.withLock { memories = value } }
    func proposalCount(_ value: Int) { lock.withLock { changes = value } }
    func counts() -> (Int, Int) { lock.withLock { (memories, changes) } }
}
