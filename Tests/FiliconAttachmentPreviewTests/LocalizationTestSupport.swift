import Foundation
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

/// Render one fixture at a time, allowing pending MainActor work to run between
/// images. A synchronous multi-language batch can otherwise starve integration
/// tests (including their cancellation/approval handlers) until they time out.
/// Keep the host, bitmap and PNG inside this scope so AppKit's temporary objects
/// are drained after each fixture instead of accumulating across the whole suite.
@MainActor
func withUIRenderTurn(language: String? = nil, _ render: () throws -> Void) async throws {
    try Task.checkCancellation()
    await UIRenderQueue.shared.acquire()
    defer { UIRenderQueue.shared.release() }
    try Task.checkCancellation()
    try autoreleasepool {
        if let language {
            try FiliconLocalization.$languageOverride.withValue(language, operation: render)
        } else {
            try render()
        }
    }
}

/// AppKit drawing is already main-thread-only. Admit just one fixture per queue
/// turn instead of waking every rendering test into a burst of MainActor jobs.
/// Test bodies and all non-rendering integration work remain concurrent.
@MainActor
private final class UIRenderQueue {
    static let shared = UIRenderQueue()
    private var reserved = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            if reserved {
                waiting.append(continuation)
            } else {
                reserved = true
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func release() {
        guard !waiting.isEmpty else {
            reserved = false
            return
        }
        let next = waiting.removeFirst()
        DispatchQueue.main.async { next.resume() }
    }
}
