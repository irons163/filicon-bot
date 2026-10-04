import CustomDump
import Foundation
import Testing
@testable import Filicon

@Suite("UI render scheduling", .timeLimit(.minutes(1)))
@MainActor
struct UIRenderSchedulingTests {
    @Test func concurrentFixturesGiveMainQueueATurnBetweenImages() async throws {
        let events = RenderEvents()
        let tasks = (0..<8).map { index in
            Task { @MainActor in
                try await withUIRenderTurn {
                    events.values.append("render-\(index)")
                    DispatchQueue.main.async { events.values.append("queued-\(index)") }
                }
            }
        }
        defer { tasks.forEach { $0.cancel() } }
        for task in tasks { try await task.value }
        try await withUIRenderTurn {
            expectNoDifference(events.values.count, 16)
            try #require(events.values.count == 16)
            var rendered: [String] = []
            for index in stride(from: 0, to: 16, by: 2) {
                let fixture = String(events.values[index].dropFirst("render-".count))
                expectNoDifference(events.values[index + 1], "queued-\(fixture)")
                rendered.append(fixture)
            }
            expectNoDifference(rendered.sorted(), (0..<8).map(String.init))
        }
    }

    @Test func queuedMainThreadWorkRunsBetweenFixtures() async throws {
        let events = RenderEvents()
        for index in 0..<3 {
            try await withUIRenderTurn {
                events.values.append("render-\(index)")
                DispatchQueue.main.async { events.values.append("queued-\(index)") }
            }
        }
        try await withUIRenderTurn {
            expectNoDifference(events.values, ["render-0", "queued-0", "render-1", "queued-1", "render-2", "queued-2"])
        }
    }

    @Test func cancelledTaskNeverStartsAnotherFixture() async throws {
        let events = RenderEvents()
        let render = Task { @MainActor in
            try await withUIRenderTurn { events.values.append("unexpected render") }
        }
        render.cancel()
        await #expect(throws: CancellationError.self) { try await render.value }
        expectNoDifference(events.values, [])
    }

    @Test func mainQueueCancellationPreventsRendering() async throws {
        let events = RenderEvents()
        let render = Task { @MainActor in
            try await withUIRenderTurn { events.values.append("unexpected render") }
        }
        // This block is enqueued before the rendering helper's main-queue
        // checkpoint. It either cancels before entry or during that suspension.
        DispatchQueue.main.async { render.cancel() }
        await #expect(throws: CancellationError.self) { try await render.value }
        expectNoDifference(events.values, [])
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func languageIsTaskLocalAndRestoredAfterSuccessOrFailure(language: String) async throws {
        try await FiliconLocalization.$languageOverride.withValue("en") {
            try await withUIRenderTurn(language: language) {
                expectNoDifference(FiliconLocalization.languageOverride, language)
            }
            expectNoDifference(FiliconLocalization.languageOverride, "en")
            await #expect(throws: RenderFailure.fixture) {
                try await withUIRenderTurn(language: language) {
                    expectNoDifference(FiliconLocalization.languageOverride, language)
                    throw RenderFailure.fixture
                }
            }
            expectNoDifference(FiliconLocalization.languageOverride, "en")
            try await withUIRenderTurn {
                expectNoDifference(FiliconLocalization.languageOverride, "en")
            }
        }
    }

    @Test func synchronousAndAsynchronousFixturesUseTheSameExclusiveQueue() async throws {
        let events = RenderEvents()
        let tasks = (0..<8).map { index in
            Task { @MainActor in
                if index.isMultiple(of: 2) {
                    try await withUIAsyncRenderTurn {
                        events.values.append("start-\(index)")
                        await withCheckedContinuation { continuation in
                            DispatchQueue.main.async { continuation.resume() }
                        }
                        events.values.append("end-\(index)")
                    }
                } else {
                    try await withUIRenderTurn {
                        events.values.append("start-\(index)")
                        events.values.append("end-\(index)")
                    }
                }
            }
        }
        defer { tasks.forEach { $0.cancel() } }
        for task in tasks { try await task.value }
        expectNoDifference(events.values.count, 16)
        for index in stride(from: 0, to: events.values.count, by: 2) {
            let fixture = String(events.values[index].dropFirst("start-".count))
            expectNoDifference(events.values[index + 1], "end-\(fixture)")
        }
    }

    @Test func cancellationNeverStartsAnAsynchronousFixtureAndReleasesTheQueue() async throws {
        let events = RenderEvents()
        let task = Task { @MainActor in
            try await withUIAsyncRenderTurn { events.values.append("unexpected") }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await withUIRenderTurn { expectNoDifference(events.values, []) }
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func asynchronousLocaleIsRestoredAfterSuccessAndFailure(language: String) async throws {
        try await FiliconLocalization.$languageOverride.withValue("en") {
            try await withUIAsyncRenderTurn(language: language) {
                await Task.yield()
                expectNoDifference(FiliconLocalization.languageOverride, language)
            }
            expectNoDifference(FiliconLocalization.languageOverride, "en")
            await #expect(throws: RenderFailure.fixture) {
                try await withUIAsyncRenderTurn(language: language) {
                    await Task.yield()
                    expectNoDifference(FiliconLocalization.languageOverride, language)
                    throw RenderFailure.fixture
                }
            }
            try await withUIRenderTurn { expectNoDifference(FiliconLocalization.languageOverride, "en") }
        }
    }
}

@MainActor private final class RenderEvents {
    var values: [String] = []
}

private enum RenderFailure: Error, Equatable {
    case fixture
}
