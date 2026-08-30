import AVFoundation
import Foundation

@MainActor
public final class NativeVoiceRecorder: VoiceRecordingDriver {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    public init() {}

    public func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(maximumDuration: TimeInterval) throws {
        cancel()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "FiliconVoiceRecordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "voice-(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 96_000,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record(forDuration: maximumDuration) else {
            try? FileManager.default.removeItem(at: url)
            throw VoiceComposerError.recordingUnavailable
        }
        self.fileURL = url
        self.recorder = recorder
    }

    public func currentDuration() -> TimeInterval { recorder?.currentTime ?? 0 }

    public func currentLevel() -> Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, pow(10, decibels / 20)))
    }

    public func stop() throws -> VoiceRecording {
        guard let recorder, let fileURL else { throw VoiceComposerError.recordingUnavailable }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        return VoiceRecording(fileURL: fileURL, duration: duration)
    }

    public func cancel() {
        recorder?.stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        recorder = nil
        fileURL = nil
    }
}
