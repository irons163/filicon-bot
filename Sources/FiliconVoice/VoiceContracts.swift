import Foundation

public struct VoiceRecording: Equatable, Sendable {
    public var fileURL: URL
    public var duration: TimeInterval

    public init(fileURL: URL, duration: TimeInterval) {
        self.fileURL = fileURL
        self.duration = duration
    }
}

public struct VoiceComposerResult: Equatable, Sendable {
    public var recording: VoiceRecording
    public var transcript: String
    public var waveformSamples: [Float]

    public init(recording: VoiceRecording, transcript: String, waveformSamples: [Float]) {
        self.recording = recording
        self.transcript = transcript
        self.waveformSamples = waveformSamples
    }
}

public enum VoiceComposerPhase: Equatable, Sendable {
    case idle
    case requestingMicrophonePermission
    case recording(elapsed: TimeInterval)
    case transcribing
    case ready
    case permissionDenied
    case tooShort(minimum: TimeInterval)
    case failed(String)
}

public enum VoiceComposerError: LocalizedError, Equatable, Sendable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case recordingUnavailable
    case recognizerUnavailable
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "Microphone access is required to record a voice message."
        case .speechPermissionDenied: "Speech recognition access is required to transcribe this recording."
        case .recordingUnavailable: "The Mac audio input could not start recording."
        case .recognizerUnavailable: "Speech recognition is currently unavailable."
        case .emptyTranscript: "No speech could be recognized in this recording."
        }
    }
}

@MainActor
public protocol VoiceRecordingDriver: AnyObject {
    func requestPermission() async -> Bool
    func start(maximumDuration: TimeInterval) throws
    func currentDuration() -> TimeInterval
    func currentLevel() -> Float
    func stop() throws -> VoiceRecording
    func cancel()
}

@MainActor
public protocol VoiceTranscribing: AnyObject {
    func requestPermission() async -> Bool
    func transcribe(fileURL: URL) async throws -> String
    func cancel()
}
