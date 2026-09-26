import Foundation

/// Separate from consent: recording a review never invalidates settings.
struct AgentMemoryTemporalReview: Codable, Equatable, Sendable {
    let settings: AgentMemorySynthesisSettings
    let nextReviewAt: Date
}
