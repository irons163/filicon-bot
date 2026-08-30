import Foundation
import Speech

@MainActor
public final class SystemSpeechTranscriber: VoiceTranscribing {
    private let locale: Locale
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, any Error>?

    public init(locale: Locale = .current) { self.locale = locale }

    public func requestPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
    }

    public func transcribe(fileURL: URL) async throws -> String {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw VoiceComposerError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    guard let self, let continuation = self.continuation else { return }
                    if let error {
                        self.continuation = nil
                        self.task = nil
                        continuation.resume(throwing: error)
                    } else if let result, result.isFinal {
                        self.continuation = nil
                        self.task = nil
                        let text = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if text.isEmpty { continuation.resume(throwing: VoiceComposerError.emptyTranscript) }
                        else { continuation.resume(returning: text) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
