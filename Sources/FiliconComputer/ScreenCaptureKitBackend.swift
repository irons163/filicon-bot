@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public enum ScreenCaptureKitBackendError: Error, Sendable, Equatable {
    case recordingAlreadyActive
    case noDisplayAvailable
    case requestedDisplayUnavailable
    case cannotCreateWriterInput
    case recordingNotActive
}

private struct TeachSessionMetadata: Codable, Sendable {
    var request: TeachCaptureRequest
    var completed: Bool
    var saved: Bool
}

/// Production macOS capture adapter. The controller remains backend-agnostic;
/// this class owns ScreenCaptureKit, AVAssetWriter, and filesystem recovery.
public final class ScreenCaptureKitBackend: NSObject, TeachCaptureBackend, TeachSensitiveFilterUpdater, TeachCaptureBlackout, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let stateLock = NSLock()
    private let sampleQueue = DispatchQueue(label: "app.filicon.teach.screen-samples", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var activeRequest: TeachCaptureRequest?
    private var activeDisplayID: CGDirectDisplayID?
    private var capturePausedForMasking = false
    // Masking is staged before capture starts. Defaulting to blackout makes a
    // caller that forgets the preflight refresh fail closed instead of
    // recording an unfiltered frame.
    private var stagedExcludedWindowIDs: Set<UInt32> = []
    private var stagedBlackout = true

    public override init() { super.init() }

    public func start(_ request: TeachCaptureRequest) async throws {
        let alreadyActive = stateLock.withLock { activeRequest != nil }
        guard !alreadyActive else { throw ScreenCaptureKitBackendError.recordingAlreadyActive }

        let manager = FileManager.default
        let directory = request.outputURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeMetadata(TeachSessionMetadata(request: request, completed: false, saved: false), directory: directory)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display: SCDisplay
        if let requested = request.displayID {
            guard let match = content.displays.first(where: { $0.displayID == requested }) else {
                throw ScreenCaptureKitBackendError.requestedDisplayUnavailable
            }
            display = match
        } else {
            guard let first = content.displays.first else { throw ScreenCaptureKitBackendError.noDisplayAvailable }
            display = first
        }

        let writer = try AVAssetWriter(outputURL: request.outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: display.width,
            AVVideoHeightKey: display.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 75
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ScreenCaptureKitBackendError.cannotCreateWriterInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ScreenCaptureKitBackendError.cannotCreateWriterInput }
        writer.startSession(atSourceTime: .zero)

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let stagedMask = stateLock.withLock { (stagedExcludedWindowIDs, stagedBlackout) }
        let excludedWindows = content.windows.filter { stagedMask.0.contains($0.windowID) }
        guard excludedWindows.count == stagedMask.0.count else {
            writer.cancelWriting()
            try? manager.removeItem(at: directory)
            throw TeachSensitiveMaskingError.filterUpdateFailed
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        stateLock.withLock {
            self.stream = stream
            self.writer = writer
            self.writerInput = input
            self.activeRequest = request
            self.activeDisplayID = display.displayID
            self.capturePausedForMasking = stagedMask.1
        }
        do {
            if !stagedMask.1 { try await stream.startCapture() }
        } catch {
            clearCaptureState()
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    public func stop(_ request: TeachCaptureRequest, save: Bool) async throws -> URL? {
        let captured = captureState(for: request)
        guard let stream = captured.stream, let writer = captured.writer, let input = captured.input else {
            throw ScreenCaptureKitBackendError.recordingNotActive
        }
        let paused = stateLock.withLock { capturePausedForMasking }
        if !paused { try await stream.stopCapture() }
        input.markAsFinished()
        await writer.finishWriting()
        clearCaptureState()

        let directory = request.outputURL.deletingLastPathComponent()
        if save, writer.status == .completed {
            try writeMetadata(TeachSessionMetadata(request: request, completed: true, saved: true), directory: directory)
            return request.outputURL
        }
        try? FileManager.default.removeItem(at: directory)
        if let error = writer.error, save { throw error }
        return nil
    }

    public func discard(_ request: TeachCaptureRequest) async throws {
        let captured = captureState(for: request)
        let paused = stateLock.withLock { capturePausedForMasking }
        if let stream = captured.stream, !paused { try? await stream.stopCapture() }
        captured.input?.markAsFinished()
        captured.writer?.cancelWriting()
        clearCaptureState()
        let directory = request.outputURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func recoverArtifacts(in sessionsDirectory: URL) async throws -> [TeachRecoveryArtifact] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let urls = try manager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { directory in
            guard directory.lastPathComponent != "quarantine",
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let metadataURL = directory.appending(path: "session.json")
            let metadata = try? JSONDecoder().decode(TeachSessionMetadata.self, from: Data(contentsOf: metadataURL))
            let videoURL = directory.appending(path: "demo.mp4")
            let hasVideo = manager.fileExists(atPath: videoURL.path)
            return TeachRecoveryArtifact(
                sessionID: metadata?.request.sessionID,
                sessionDirectory: directory,
                videoURL: hasVideo ? videoURL : nil,
                isComplete: metadata?.completed == true && metadata?.saved == true && hasVideo
            )
        }
    }

    public func quarantine(_ artifact: TeachRecoveryArtifact, into quarantineDirectory: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        var destination = quarantineDirectory.appending(path: artifact.sessionDirectory.lastPathComponent, directoryHint: .isDirectory)
        if manager.fileExists(atPath: destination.path) {
            destination = quarantineDirectory.appending(path: "\(artifact.sessionDirectory.lastPathComponent)-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        try manager.moveItem(at: artifact.sessionDirectory, to: destination)
    }

    /// Dynamically reapplies ScreenCaptureKit's exclusion list. Resolution is
    /// by current shareable-window inventory so stale ids fail closed.
    public func updateExcludedWindowIDs(_ ids: Set<UInt32>) async throws {
        let captured = stateLock.withLock { (stream, activeDisplayID) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = content.windows.filter { ids.contains($0.windowID) }
        guard windows.count == ids.count else { throw TeachSensitiveMaskingError.filterUpdateFailed }
        stateLock.withLock { stagedExcludedWindowIDs = ids }
        // A pre-start refresh only stages the exact exclusion list. `start`
        // resolves it against a fresh inventory again before constructing the
        // stream, closing the inventory-change race.
        guard let stream = captured.0, let displayID = captured.1 else { return }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenCaptureKitBackendError.requestedDisplayUnavailable }
        try await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: windows))
    }

    /// Pauses the SCStream itself, ensuring unknown sensitive windows cannot
    /// leak a frame while inventory/filter state is unresolved.
    public func setBlackout(_ enabled: Bool) async {
        let transition = stateLock.withLock { () -> (SCStream?, Bool) in
            stagedBlackout = enabled
            guard let stream, capturePausedForMasking != enabled else { return (nil, false) }
            capturePausedForMasking = enabled
            return (stream, true)
        }
        guard transition.1, let stream = transition.0 else { return }
        do {
            if enabled { try await stream.stopCapture() } else { try await stream.startCapture() }
        } catch {
            stateLock.withLock { capturePausedForMasking = true }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let input = stateLock.withLock { writerInput }
        guard input?.isReadyForMoreMediaData == true else { return }
        _ = input?.append(sampleBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stateLock.withLock {
            writerInput?.markAsFinished()
            writer?.cancelWriting()
            self.stream = nil
            writer = nil
            writerInput = nil
            activeRequest = nil
            activeDisplayID = nil
            capturePausedForMasking = true
            stagedExcludedWindowIDs = []
            stagedBlackout = true
        }
    }

    private func captureState(for request: TeachCaptureRequest) -> (stream: SCStream?, writer: AVAssetWriter?, input: AVAssetWriterInput?) {
        stateLock.withLock {
            guard activeRequest == request else { return (nil, nil, nil) }
            return (stream, writer, writerInput)
        }
    }

    private func clearCaptureState() {
        stateLock.withLock {
            stream = nil
            writer = nil
            writerInput = nil
            activeRequest = nil
            activeDisplayID = nil
            capturePausedForMasking = true
            stagedExcludedWindowIDs = []
            stagedBlackout = true
        }
    }

    private func writeMetadata(_ metadata: TeachSessionMetadata, directory: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: directory.appending(path: "session.json"), options: .atomic)
    }
}
