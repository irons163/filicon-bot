import Testing
@testable import Filicon

/// Presentation snapshots assert English copy without modifying the user's
/// persisted language or racing other tests that exercise another locale.
struct EnglishUITrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await FiliconLocalization.$languageOverride.withValue("en") {
            try await function()
        }
    }
}
