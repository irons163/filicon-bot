import Foundation

public enum OnboardingStep: String, Codable, CaseIterable, Sendable { case landing, meet, computerDemo, jobs, tools, create, handOff }

public struct OnboardingProgress: Codable, Equatable, Sendable {
    public var completed: Set<OnboardingStep>
    public var current: OnboardingStep
    public var selectedSuggestionIDs: [String]
    public var updatedAt: Date
    public init(completed: Set<OnboardingStep> = [], current: OnboardingStep = .landing, selectedSuggestionIDs: [String] = [], updatedAt: Date = .now) {
        self.completed = completed; self.current = current; self.selectedSuggestionIDs = Array(selectedSuggestionIDs.prefix(20)); self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey { case completed, current, selectedSuggestionIDs, updatedAt, seen }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completed = (try? c.decode(Set<OnboardingStep>.self, forKey: .completed)) ?? []
        var seenIDs = Set<String>()
        selectedSuggestionIDs = ((try? c.decode([String].self, forKey: .selectedSuggestionIDs)) ?? []).compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && id.count <= 128 && seenIDs.insert(id).inserted ? id : nil
        }.prefix(20).map { $0 }
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? .distantPast
        if (try? c.decode(Bool.self, forKey: .seen)) == true { current = .handOff; completed = Set(OnboardingStep.allCases) }
        else { current = (try? c.decode(OnboardingStep.self, forKey: .current)) ?? .landing }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(completed, forKey: .completed); try c.encode(current, forKey: .current)
        try c.encode(selectedSuggestionIDs, forKey: .selectedSuggestionIDs); try c.encode(updatedAt, forKey: .updatedAt)
    }
}

public protocol OnboardingStore: Sendable { func load() async throws -> Data?; func save(_ data: Data) async throws }

public actor OnboardingController {
    private let store: any OnboardingStore
    public private(set) var progress: OnboardingProgress
    public init(store: any OnboardingStore, initial: OnboardingProgress = .init()) { self.store = store; self.progress = initial }
    @discardableResult public func restore() async throws -> OnboardingProgress {
        if let data = try await store.load() {
            let restored = try JSONDecoder().decode(OnboardingProgress.self, from: data)
            progress = restored
        }
        return progress
    }
    @discardableResult public func advance(to step: OnboardingStep) async throws -> OnboardingProgress {
        if let old = OnboardingStep.allCases.firstIndex(of: progress.current), let new = OnboardingStep.allCases.firstIndex(of: step), new >= old {
            var candidate = progress
            candidate.completed.formUnion(OnboardingStep.allCases.prefix(new)); candidate.current = step; candidate.updatedAt = .now
            try await persist(candidate); progress = candidate
        }
        return progress
    }
    @discardableResult public func selectSuggestions(_ ids: [String]) async throws -> OnboardingProgress {
        var seen = Set<String>(), selected: [String] = []
        for raw in ids where selected.count < 20 {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, id.count <= 128, seen.insert(id).inserted { selected.append(id) }
        }
        var candidate = progress
        candidate.selectedSuggestionIDs = selected
        candidate.updatedAt = .now
        try await persist(candidate); progress = candidate; return progress
    }
    private func persist(_ candidate: OnboardingProgress) async throws { try await store.save(try JSONEncoder().encode(candidate)) }
}

public enum ReadinessState: String, Codable, Sendable { case hidden, checking, ready, waiting, unavailable }
public struct OnboardingReadiness: Codable, Equatable, Sendable {
    public var state: ReadinessState; public var progress: Double?; public var canContinue: Bool
    public init(accountSignedIn: Bool, serviceReachable: Bool?, resourceCount: Int?, progress: Double? = nil) {
        guard accountSignedIn else { state = .hidden; self.progress = nil; canContinue = false; return }
        self.progress = progress.map { min(max($0, 0), 1) }
        if serviceReachable == nil { state = .checking; canContinue = false }
        else if serviceReachable == false { state = .unavailable; canContinue = false }
        else if (resourceCount ?? 0) > 0 { state = .ready; canContinue = true }
        else { state = .waiting; canContinue = false }
    }
}

public struct OnboardingSuggestion: Codable, Equatable, Sendable {
    public var id: String; public var title: String; public var requiredCapability: String?; public var priority: Int
    public init(id: String, title: String, requiredCapability: String? = nil, priority: Int = 0) { self.id = id; self.title = title; self.requiredCapability = requiredCapability; self.priority = priority }
}
public func selectOnboardingSuggestions(_ catalog: [OnboardingSuggestion], capabilities: Set<String>, limit: Int = 10) -> [OnboardingSuggestion] {
    guard limit > 0 else { return [] }
    var seen = Set<String>()
    return catalog.filter {
        !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            ($0.requiredCapability == nil || capabilities.contains($0.requiredCapability!)) && seen.insert($0.id).inserted
    }.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority }.prefix(min(limit, 100)).map { $0 }
}
