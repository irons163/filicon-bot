import Foundation

public enum TeachMonitorPolicy: Sendable, Equatable {
    case primary
    case sharedFork(index: Int)
    case privateFork(index: Int)

    public var isPrivateFork: Bool {
        if case .privateFork(let index) = self { return index > 0 }
        return false
    }
}

public struct TeachCaptureRequest: Sendable, Equatable, Codable {
    public let sessionID: UUID
    public let agentID: String
    public let entryPoint: String?
    public let outputURL: URL
    public let displayID: UInt32?
    public let startedAtMilliseconds: Int64
    public let maskingPolicy: TeachMaskingPolicyMetadata?

    public init(
        sessionID: UUID,
        agentID: String,
        entryPoint: String?,
        outputURL: URL,
        displayID: UInt32?,
        startedAtMilliseconds: Int64,
        maskingPolicy: TeachMaskingPolicyMetadata? = nil
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.entryPoint = entryPoint
        self.outputURL = outputURL
        self.displayID = displayID
        self.startedAtMilliseconds = startedAtMilliseconds
        self.maskingPolicy = maskingPolicy
    }
}

public struct TeachRecoveryArtifact: Sendable, Equatable {
    public let sessionID: UUID?
    public let sessionDirectory: URL
    public let videoURL: URL?
    public let isComplete: Bool

    public init(sessionID: UUID?, sessionDirectory: URL, videoURL: URL?, isComplete: Bool) {
        self.sessionID = sessionID
        self.sessionDirectory = sessionDirectory
        self.videoURL = videoURL
        self.isComplete = isComplete
    }
}

public protocol TeachCaptureBackend: Sendable {
    func start(_ request: TeachCaptureRequest) async throws
    func stop(_ request: TeachCaptureRequest, save: Bool) async throws -> URL?
    func discard(_ request: TeachCaptureRequest) async throws
    func recoverArtifacts(in sessionsDirectory: URL) async throws -> [TeachRecoveryArtifact]
    func quarantine(_ artifact: TeachRecoveryArtifact, into quarantineDirectory: URL) async throws
}

public enum TeachRecordingPhase: String, Codable, Sendable, Equatable {
    case idle
    case starting
    case recording
    case finalizing
    case recovering
    case failed
}

public struct TeachRecordingStatus: Sendable, Equatable {
    public var phase: TeachRecordingPhase
    public var agentID: String?
    public var sessionID: UUID?
    public var startedAtMilliseconds: Int64?
    public var maxDurationMilliseconds: Int64
    public var savedVideoURL: URL?
    public var quarantinedCount: Int
    public var maskedWindowCount: Int
    public var pausedSensitiveWindowCount: Int
    public var maskingPolicy: TeachMaskingPolicyMetadata?
    public var errorMessage: String?

    public init(
        phase: TeachRecordingPhase = .idle,
        agentID: String? = nil,
        sessionID: UUID? = nil,
        startedAtMilliseconds: Int64? = nil,
        maxDurationMilliseconds: Int64 = TeachRecordingController.maximumDurationMilliseconds,
        savedVideoURL: URL? = nil,
        quarantinedCount: Int = 0,
        maskedWindowCount: Int = 0,
        pausedSensitiveWindowCount: Int = 0,
        maskingPolicy: TeachMaskingPolicyMetadata? = nil,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.agentID = agentID
        self.sessionID = sessionID
        self.startedAtMilliseconds = startedAtMilliseconds
        self.maxDurationMilliseconds = maxDurationMilliseconds
        self.savedVideoURL = savedVideoURL
        self.quarantinedCount = quarantinedCount
        self.maskedWindowCount = maskedWindowCount
        self.pausedSensitiveWindowCount = pausedSensitiveWindowCount
        self.maskingPolicy = maskingPolicy
        self.errorMessage = errorMessage
    }
}

public enum TeachRecordingError: Error, Sendable, Equatable {
    case privateMonitorRequired
    case recordingBelongsToDifferentAgent
    case disposed
}

public actor TeachRecordingController {
    public static let maximumDurationMilliseconds: Int64 = 600_000

    private let backend: any TeachCaptureBackend
    private let clock: any ComputerClock
    private let sessionsDirectory: URL
    private let quarantineDirectory: URL
    private var status = TeachRecordingStatus()
    private var activeRequest: TeachCaptureRequest?
    private var startInFlight: Task<Void, Error>?
    private var startOperationID: UUID?
    private var stopInFlight: Task<URL?, Error>?
    private var stopOperationID: UUID?
    private var stopIntentSave = true
    private var capTask: Task<Void, Never>?
    private var disposed = false
    private var continuations: [UUID: AsyncStream<TeachRecordingStatus>.Continuation] = [:]

    public init(
        backend: any TeachCaptureBackend,
        sessionsDirectory: URL,
        quarantineDirectory: URL? = nil,
        clock: any ComputerClock = SystemComputerClock()
    ) {
        self.backend = backend
        self.sessionsDirectory = sessionsDirectory
        self.quarantineDirectory = quarantineDirectory ?? sessionsDirectory.appending(path: "quarantine", directoryHint: .isDirectory)
        self.clock = clock
    }

    public func currentStatus() -> TeachRecordingStatus { status }

    public func statuses() -> AsyncStream<TeachRecordingStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(status)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    @discardableResult
    public func start(
        agentID: String,
        entryPoint: String? = nil,
        monitor: TeachMonitorPolicy,
        displayID: UInt32? = nil,
        maskingPolicy: TeachMaskingPolicyMetadata? = nil
    ) async throws -> TeachRecordingStatus {
        guard !disposed else { throw TeachRecordingError.disposed }
        guard monitor.isPrivateFork else { throw TeachRecordingError.privateMonitorRequired }
        if let activeRequest {
            if let startInFlight { try await startInFlight.value }
            return statusForActive(activeRequest, phase: .recording)
        }
        if let startInFlight {
            try await startInFlight.value
            return status
        }

        let now = await clock.nowMilliseconds()
        let sessionID = UUID()
        let directory = sessionsDirectory.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        let request = TeachCaptureRequest(
            sessionID: sessionID,
            agentID: agentID,
            entryPoint: entryPoint,
            outputURL: directory.appending(path: "demo.mp4"),
            displayID: displayID,
            startedAtMilliseconds: now,
            maskingPolicy: maskingPolicy
        )
        activeRequest = request
        status = statusForActive(request, phase: .starting)
        publish()

        let backend = self.backend
        let operationID = UUID()
        let task = Task { try await backend.start(request) }
        startInFlight = task
        startOperationID = operationID
        do {
            try await task.value
            if startOperationID == operationID {
                startInFlight = nil
                startOperationID = nil
            }
            guard !disposed, activeRequest == request else {
                try? await backend.discard(request)
                return status
            }
            status = statusForActive(request, phase: .recording)
            publish()
            armDurationCap(for: request)
            return status
        } catch {
            if startOperationID == operationID {
                startInFlight = nil
                startOperationID = nil
            }
            if activeRequest == request { activeRequest = nil }
            status = TeachRecordingStatus(phase: .failed, errorMessage: String(describing: error))
            publish()
            throw error
        }
    }

    @discardableResult
    public func stop(agentID: String, save: Bool) async throws -> TeachRecordingStatus {
        guard !disposed else { throw TeachRecordingError.disposed }
        if let existing = stopInFlight {
            if !save { stopIntentSave = false }
            _ = try await existing.value
            return status
        }
        if let starting = startInFlight {
            _ = try await starting.value
        }
        guard let request = activeRequest else { return status }
        guard request.agentID == agentID else { throw TeachRecordingError.recordingBelongsToDifferentAgent }

        stopIntentSave = save
        capTask?.cancel()
        capTask = nil
        status = statusForActive(request, phase: .finalizing)
        publish()
        let backend = self.backend
        let operationID = UUID()
        let task = Task { try await backend.stop(request, save: save) }
        stopInFlight = task
        stopOperationID = operationID
        do {
            var savedURL = try await task.value
            if !stopIntentSave, save {
                try await backend.discard(request)
                savedURL = nil
            }
            if stopOperationID == operationID {
                stopInFlight = nil
                stopOperationID = nil
            }
            if activeRequest == request { activeRequest = nil }
            status = TeachRecordingStatus(savedVideoURL: stopIntentSave ? savedURL : nil)
            publish()
            return status
        } catch {
            if stopOperationID == operationID {
                stopInFlight = nil
                stopOperationID = nil
            }
            status = statusForActive(request, phase: .failed, error: String(describing: error))
            publish()
            throw error
        }
    }

    /// Returns completed recordings and quarantines incomplete or malformed
    /// sessions left by an earlier process crash.
    @discardableResult
    public func recover() async throws -> [TeachRecoveryArtifact] {
        guard !disposed else { throw TeachRecordingError.disposed }
        status = TeachRecordingStatus(phase: .recovering)
        publish()
        do {
            let artifacts = try await backend.recoverArtifacts(in: sessionsDirectory)
            var completed: [TeachRecoveryArtifact] = []
            var quarantined = 0
            for artifact in artifacts {
                if artifact.isComplete, artifact.videoURL != nil {
                    completed.append(artifact)
                } else {
                    try await backend.quarantine(artifact, into: quarantineDirectory)
                    quarantined += 1
                }
            }
            status = TeachRecordingStatus(quarantinedCount: quarantined)
            publish()
            return completed
        } catch {
            status = TeachRecordingStatus(phase: .failed, errorMessage: String(describing: error))
            publish()
            throw error
        }
    }

    public func dispose() async {
        guard !disposed else { return }
        disposed = true
        capTask?.cancel()
        capTask = nil
        startInFlight?.cancel()
        stopInFlight?.cancel()
        if let request = activeRequest { try? await backend.discard(request) }
        activeRequest = nil
        status = TeachRecordingStatus()
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    /// App integration hook for a dynamic masking controller. Status is
    /// surfaced without changing capture ownership or lifecycle.
    public func reportMaskingStatus(_ masking: TeachMaskingStatus) {
        status.maskedWindowCount = masking.maskedCount
        status.pausedSensitiveWindowCount = masking.pausedCount
        status.maskingPolicy = masking.policy
        publish()
    }

    private func armDurationCap(for request: TeachCaptureRequest) {
        let clock = self.clock
        capTask?.cancel()
        capTask = Task { [weak self] in
            do {
                try await clock.sleep(milliseconds: Self.maximumDurationMilliseconds)
                try Task.checkCancellation()
                try await self?.stopAtCap(request)
            } catch { }
        }
    }

    private func stopAtCap(_ request: TeachCaptureRequest) async throws {
        guard activeRequest == request else { return }
        _ = try await stop(agentID: request.agentID, save: true)
    }

    private func statusForActive(_ request: TeachCaptureRequest, phase: TeachRecordingPhase, error: String? = nil) -> TeachRecordingStatus {
        TeachRecordingStatus(
            phase: phase,
            agentID: request.agentID,
            sessionID: request.sessionID,
            startedAtMilliseconds: request.startedAtMilliseconds,
            maskingPolicy: request.maskingPolicy,
            errorMessage: error
        )
    }

    private func publish() {
        for continuation in continuations.values { continuation.yield(status) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
