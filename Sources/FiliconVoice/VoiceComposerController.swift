import Combine
import Foundation

@MainActor
public final class VoiceComposerController: ObservableObject {
    public static let minimumDuration: TimeInterval = 0.5
    public static let maximumDuration: TimeInterval = 300

    @Published public private(set) var phase: VoiceComposerPhase = .idle
    @Published public private(set) var waveformSamples: [Float] = []
    @Published public private(set) var result: VoiceComposerResult?

    private let recorder: any VoiceRecordingDriver
    private let transcriber: any VoiceTranscribing
    private let minimum: TimeInterval
    private let maximum: TimeInterval
    private let tickNanoseconds: UInt64
    private var ticker: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var pendingRecording: VoiceRecording?

    public init(
        recorder: any VoiceRecordingDriver,
        transcriber: any VoiceTranscribing,
        minimum: TimeInterval = VoiceComposerController.minimumDuration,
        maximum: TimeInterval = VoiceComposerController.maximumDuration,
        tickNanoseconds: UInt64 = 100_000_000
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.minimum = minimum
        self.maximum = maximum
        self.tickNanoseconds = tickNanoseconds
    }

    public convenience init() {
        self.init(recorder: NativeVoiceRecorder(), transcriber: SystemSpeechTranscriber())
    }

    public var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    public func startRecording() {
        guard !isRecording, phase != .transcribing else { return }
        cancelOperations(removeResultFile: true)
        phase = .requestingMicrophonePermission
        operation = Task { [weak self] in
            guard let self else { return }
            guard await recorder.requestPermission() else {
                guard !Task.isCancelled else { return }
                phase = .permissionDenied
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try recorder.start(maximumDuration: maximum)
                waveformSamples = []
                phase = .recording(elapsed: 0)
                beginTicker()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    public func stopAndTranscribe() {
        guard isRecording else { return }
        ticker?.cancel()
        ticker = nil
        do {
            let recording = try recorder.stop()
            guard recording.duration >= minimum else {
                try? FileManager.default.removeItem(at: recording.fileURL)
                phase = .tooShort(minimum: minimum)
                return
            }
            pendingRecording = recording
            phase = .transcribing
            operation = Task { [weak self] in
                guard let self else { return }
                guard await transcriber.requestPermission() else {
                    guard !Task.isCancelled else { return }
                    try? FileManager.default.removeItem(at: recording.fileURL)
                    pendingRecording = nil
                    phase = .failed(VoiceComposerError.speechPermissionDenied.localizedDescription)
                    return
                }
                do {
                    let transcript = try await transcriber.transcribe(fileURL: recording.fileURL)
                    guard !Task.isCancelled else { return }
                    result = VoiceComposerResult(recording: recording, transcript: transcript, waveformSamples: waveformSamples)
                    pendingRecording = nil
                    phase = .ready
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: recording.fileURL)
                    pendingRecording = nil
                    if phase == .transcribing { phase = .idle }
                } catch {
                    try? FileManager.default.removeItem(at: recording.fileURL)
                    pendingRecording = nil
                    phase = .failed(error.localizedDescription)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Exposed for deterministic fixtures; the native ticker calls this every 100 ms.
    public func sample(elapsed: TimeInterval? = nil, level: Float? = nil) {
        guard isRecording else { return }
        let duration = elapsed ?? recorder.currentDuration()
        let sample = min(1, max(0, level ?? recorder.currentLevel()))
        waveformSamples.append(sample)
        if waveformSamples.count > 3_000 { waveformSamples.removeFirst(waveformSamples.count - 3_000) }
        phase = .recording(elapsed: min(duration, maximum))
        if duration >= maximum { stopAndTranscribe() }
    }

    public func cancel() {
        let wasRecording = isRecording
        cancelOperations(removeResultFile: true)
        if wasRecording { recorder.cancel() }
        transcriber.cancel()
        if let pendingRecording { try? FileManager.default.removeItem(at: pendingRecording.fileURL) }
        pendingRecording = nil
        phase = .idle
        waveformSamples = []
        result = nil
    }

    public func retry() { startRecording() }

    public func takeResult() -> VoiceComposerResult? {
        guard let result else { return nil }
        self.result = nil
        waveformSamples = []
        phase = .idle
        return result
    }

    private func beginTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, isRecording {
                try? await Task.sleep(nanoseconds: tickNanoseconds)
                guard !Task.isCancelled else { return }
                sample()
            }
        }
    }

    private func cancelOperations(removeResultFile: Bool) {
        ticker?.cancel()
        operation?.cancel()
        ticker = nil
        operation = nil
        if removeResultFile, let result {
            try? FileManager.default.removeItem(at: result.recording.fileURL)
            self.result = nil
        }
    }
}
