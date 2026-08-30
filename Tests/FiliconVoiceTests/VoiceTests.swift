import Foundation
import Testing
@testable import FiliconVoice

@MainActor
struct VoiceComposerTests {
    @Test func enforcesMinimumDurationAndAllowsRetry() async throws {
        let recorder = FixtureRecorder(duration: 0.49)
        let transcriber = FixtureTranscriber(text: "hello")
        let subject = VoiceComposerController(recorder: recorder, transcriber: transcriber, tickNanoseconds: 10_000_000_000)

        subject.startRecording()
        await eventually { subject.isRecording }
        subject.stopAndTranscribe()

        #expect(subject.phase == .tooShort(minimum: 0.5))
        #expect(transcriber.calls == 0)
        subject.retry()
        await eventually { subject.isRecording }
        #expect(recorder.startCount == 2)
        subject.cancel()
    }

    @Test func maximumDurationAutomaticallyStopsAndTranscribes() async throws {
        let recorder = FixtureRecorder(duration: 300)
        let transcriber = FixtureTranscriber(text: "system transcript")
        let subject = VoiceComposerController(recorder: recorder, transcriber: transcriber, tickNanoseconds: 10_000_000_000)

        subject.startRecording()
        await eventually { subject.isRecording }
        subject.sample(elapsed: 300, level: 0.75)
        await eventually { subject.phase == .ready }

        #expect(recorder.stopCount == 1)
        #expect(subject.waveformSamples == [0.75])
        #expect(subject.result?.transcript == "system transcript")
        let result = subject.takeResult()
        #expect(result?.recording.duration == 300)
        #expect(subject.phase == .idle)
        try? FileManager.default.removeItem(at: result?.recording.fileURL ?? URL(fileURLWithPath: "/missing"))
    }

    @Test func cancellationStopsRecordingAndClearsSamples() async {
        let recorder = FixtureRecorder(duration: 2)
        let subject = VoiceComposerController(recorder: recorder, transcriber: FixtureTranscriber(text: "unused"), tickNanoseconds: 10_000_000_000)
        subject.startRecording()
        await eventually { subject.isRecording }
        subject.sample(elapsed: 1, level: 0.4)
        subject.cancel()

        #expect(recorder.cancelCount == 1)
        #expect(subject.phase == .idle)
        #expect(subject.waveformSamples.isEmpty)
    }

    @Test func cancellingTranscriptionRemovesTemporaryRecording() async {
        let recorder = FixtureRecorder(duration: 2)
        let transcriber = FixtureTranscriber(text: "unused", waitsForCancellation: true)
        let subject = VoiceComposerController(recorder: recorder, transcriber: transcriber, tickNanoseconds: 10_000_000_000)
        subject.startRecording()
        await eventually { subject.isRecording }
        subject.stopAndTranscribe()
        await eventually { subject.phase == .transcribing && transcriber.calls == 1 }
        let url = recorder.url

        subject.cancel()
        await eventually { subject.phase == .idle }
        #expect(transcriber.cancelled)
        #expect(url.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func deniedMicrophonePermissionHasExplicitState() async {
        let recorder = FixtureRecorder(duration: 1, permission: false)
        let subject = VoiceComposerController(recorder: recorder, transcriber: FixtureTranscriber(text: "unused"))
        subject.startRecording()
        await eventually { subject.phase == .permissionDenied }
        #expect(recorder.startCount == 0)
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

struct ComposerDraftStoreTests {
    @Test func draftsAreIsolatedAndSurviveReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "drafts.json")
        let firstID = UUID(), secondID = UUID()
        let store = ComposerDraftStore(url: url)
        try await store.save("first draft", for: firstID)
        try await store.save("second draft", for: secondID)

        let reopened = ComposerDraftStore(url: url)
        #expect(try await reopened.draft(for: firstID) == "first draft")
        #expect(try await reopened.draft(for: secondID) == "second draft")
        try await reopened.remove(for: firstID)
        #expect(try await reopened.draft(for: firstID).isEmpty)
        #expect(try await reopened.draft(for: secondID) == "second draft")
    }
}

@MainActor
private final class FixtureRecorder: VoiceRecordingDriver {
    var duration: TimeInterval
    let permission: Bool
    var startCount = 0
    var stopCount = 0
    var cancelCount = 0
    private(set) var url: URL?

    init(duration: TimeInterval, permission: Bool = true) {
        self.duration = duration
        self.permission = permission
    }

    func requestPermission() async -> Bool { permission }
    func start(maximumDuration: TimeInterval) throws {
        startCount += 1
        let url = FileManager.default.temporaryDirectory.appending(path: "fixture-(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data("audio".utf8))
        self.url = url
    }
    func currentDuration() -> TimeInterval { duration }
    func currentLevel() -> Float { 0.25 }
    func stop() throws -> VoiceRecording {
        stopCount += 1
        return VoiceRecording(fileURL: url!, duration: duration)
    }
    func cancel() {
        cancelCount += 1
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }
}

@MainActor
private final class FixtureTranscriber: VoiceTranscribing {
    let text: String
    let waitsForCancellation: Bool
    var calls = 0
    var cancelled = false
    init(text: String, waitsForCancellation: Bool = false) {
        self.text = text
        self.waitsForCancellation = waitsForCancellation
    }
    func requestPermission() async -> Bool { true }
    func transcribe(fileURL: URL) async throws -> String {
        calls += 1
        while waitsForCancellation && !cancelled {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if cancelled { throw CancellationError() }
        return text
    }
    func cancel() { cancelled = true }
}
