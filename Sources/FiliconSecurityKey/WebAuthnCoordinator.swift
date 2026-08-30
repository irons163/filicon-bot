import Foundation

public enum RemoteSecurityKeyRequestFrame: Codable, Sendable, Equatable {
    case welcome(providerID: String)
    case ceremony(requestID: String, ceremony: SecurityKeyCeremony)
    case cancel(requestID: String)
}

private enum RequestFrameKeys: String, CodingKey { case kind, providerID = "providerId", requestID = "requestId", ceremony }

extension RemoteSecurityKeyRequestFrame {
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: RequestFrameKeys.self)
        switch try value.decode(String.self, forKey: .kind) {
        case "welcome": self = .welcome(providerID: try value.decode(String.self, forKey: .providerID))
        case "ceremony": self = .ceremony(
            requestID: try value.decode(String.self, forKey: .requestID),
            ceremony: try value.decode(SecurityKeyCeremony.self, forKey: .ceremony)
        )
        case "cancel": self = .cancel(requestID: try value.decode(String.self, forKey: .requestID))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: value, debugDescription: "Unknown WebAuthn request frame")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: RequestFrameKeys.self)
        switch self {
        case .welcome(let providerID):
            try value.encode("welcome", forKey: .kind); try value.encode(providerID, forKey: .providerID)
        case .ceremony(let requestID, let ceremony):
            try value.encode("ceremony", forKey: .kind); try value.encode(requestID, forKey: .requestID); try value.encode(ceremony, forKey: .ceremony)
        case .cancel(let requestID):
            try value.encode("cancel", forKey: .kind); try value.encode(requestID, forKey: .requestID)
        }
    }
}

public enum RemoteSecurityKeyResponseFrame: Codable, Sendable, Equatable {
    case hello(computerID: String?, label: String?)
    case ping
    case stage(requestID: String, stage: String, outcome: String)
    case result(requestID: String, credential: SecurityKeyCredentialResponse)
    case error(requestID: String, name: String, message: String, code: String?)
}

private enum ResponseFrameKeys: String, CodingKey {
    case kind, computerID = "computerId", label, requestID = "requestId", stage, outcome
    case credential = "credentialJson", name, message, code
}

extension RemoteSecurityKeyResponseFrame {
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: ResponseFrameKeys.self)
        switch try value.decode(String.self, forKey: .kind) {
        case "hello": self = .hello(computerID: try value.decodeIfPresent(String.self, forKey: .computerID), label: try value.decodeIfPresent(String.self, forKey: .label))
        case "ping": self = .ping
        case "stage": self = .stage(requestID: try value.decode(String.self, forKey: .requestID), stage: try value.decode(String.self, forKey: .stage), outcome: try value.decode(String.self, forKey: .outcome))
        case "result": self = .result(requestID: try value.decode(String.self, forKey: .requestID), credential: try value.decode(SecurityKeyCredentialResponse.self, forKey: .credential))
        case "error": self = .error(requestID: try value.decode(String.self, forKey: .requestID), name: try value.decode(String.self, forKey: .name), message: try value.decode(String.self, forKey: .message), code: try value.decodeIfPresent(String.self, forKey: .code))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: value, debugDescription: "Unknown WebAuthn response frame")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: ResponseFrameKeys.self)
        switch self {
        case .hello(let computerID, let label):
            try value.encode("hello", forKey: .kind); try value.encodeIfPresent(computerID, forKey: .computerID); try value.encodeIfPresent(label, forKey: .label)
        case .ping: try value.encode("ping", forKey: .kind)
        case .stage(let requestID, let stage, let outcome):
            try value.encode("stage", forKey: .kind); try value.encode(requestID, forKey: .requestID); try value.encode(stage, forKey: .stage); try value.encode(outcome, forKey: .outcome)
        case .result(let requestID, let credential):
            try value.encode("result", forKey: .kind); try value.encode(requestID, forKey: .requestID); try value.encode(credential, forKey: .credential)
        case .error(let requestID, let name, let message, let code):
            try value.encode("error", forKey: .kind); try value.encode(requestID, forKey: .requestID); try value.encode(name, forKey: .name); try value.encode(message, forKey: .message); try value.encodeIfPresent(code, forKey: .code)
        }
    }
}

public protocol SecurityKeyConsentProvider: Sendable {
    /// The implementation must show origin and rpID and require an explicit user action.
    func requestConsent(_ consent: SecurityKeyConsent) async -> Bool
    func dismissConsent(requestID: String) async
}

public protocol HardwareSecurityKeyProvider: Sendable {
    /// Must use a cross-platform hardware security-key provider. Platform passkeys are not an acceptable fallback.
    func perform(
        _ ceremony: SecurityKeyCeremony,
        status: @escaping @Sendable (SecurityKeyStatus) async -> Void
    ) async throws -> SecurityKeyCredentialResponse
    func cancel() async
}

public protocol SecurityKeyClock: Sendable {
    func sleep(milliseconds: Int64) async throws
}

public struct SystemSecurityKeyClock: SecurityKeyClock {
    public init() {}
    public func sleep(milliseconds: Int64) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

public actor SecurityKeyCoordinator {
    public static let ceremonyDeadlineMilliseconds: Int64 = 120_000

    private let provider: any HardwareSecurityKeyProvider
    private let consent: any SecurityKeyConsentProvider
    private let clock: any SecurityKeyClock
    private let deadlineMilliseconds: Int64
    private let statusSink: @Sendable (SecurityKeyStatus) async -> Void
    private var enabled: Bool
    private var generation: UInt64 = 1
    private var inFlight: Set<String> = []
    private var consumed: Set<String> = []
    private var consumedOrder: [String] = []

    public init(
        enabled: Bool,
        provider: any HardwareSecurityKeyProvider,
        consent: any SecurityKeyConsentProvider,
        clock: any SecurityKeyClock = SystemSecurityKeyClock(),
        deadlineMilliseconds: Int64 = ceremonyDeadlineMilliseconds,
        status: @escaping @Sendable (SecurityKeyStatus) async -> Void = { _ in }
    ) {
        self.enabled = enabled
        self.provider = provider
        self.consent = consent
        self.clock = clock
        self.deadlineMilliseconds = max(1, deadlineMilliseconds)
        self.statusSink = status
    }

    public func setEnabled(_ value: Bool) async {
        guard enabled != value else { return }
        enabled = value
        await invalidate(reason: value ? .disconnected : .disabled)
    }

    public func currentGeneration() -> UInt64 { generation }

    /// Called on stream close, reconnect, account handback, or remote-computer reconfiguration.
    public func invalidate(reason: SecurityKeyStatus = .disconnected) async {
        generation &+= 1
        inFlight.removeAll()
        await provider.cancel()
        await statusSink(reason)
    }

    public func cancel(requestID: String) async {
        guard inFlight.remove(requestID) != nil else { return }
        generation &+= 1
        await provider.cancel()
        await consent.dismissConsent(requestID: requestID)
        await statusSink(.disconnected)
    }

    public func run(requestID: String, ceremony: SecurityKeyCeremony, encodedBytes: Int? = nil) async -> [RemoteSecurityKeyResponseFrame] {
        guard enabled else { return failureFrames(requestID, .disabled) }
        guard validRequestID(requestID) else { return failureFrames(requestID, .invalidRequest) }
        guard !inFlight.contains(requestID), !consumed.contains(requestID) else { return failureFrames(requestID, .replay) }
        // AuthenticationServices exposes one controller for this provider instance. Serializing
        // ceremonies prevents a second request from cancelling or receiving the first request's UI.
        guard inFlight.isEmpty else { return failureFrames(requestID, .providerUnavailable) }
        do { try SecurityKeyValidation.validate(ceremony, encodedBytes: encodedBytes) }
        catch let error as SecurityKeyError { return failureFrames(requestID, error) }
        catch { return failureFrames(requestID, .invalidRequest) }

        let token = generation
        inFlight.insert(requestID)
        defer { inFlight.remove(requestID); rememberConsumed(requestID) }
        let grant = SecurityKeyConsent(requestID: requestID, origin: ceremony.origin, rpID: ceremony.rpID, generation: token)
        await statusSink(.awaitingConsent(origin: ceremony.origin, rpID: ceremony.rpID))
        guard await consent.requestConsent(grant) else {
            await consent.dismissConsent(requestID: requestID)
            await statusSink(.failed(SecurityKeyError.consentDeclined.localizedDescription))
            return [
                .stage(requestID: requestID, stage: "grant", outcome: "declined"),
                errorFrame(requestID, .consentDeclined)
            ]
        }
        guard generation == token, inFlight.contains(requestID) else {
            await consent.dismissConsent(requestID: requestID)
            return failureFrames(requestID, .staleGeneration)
        }

        var frames: [RemoteSecurityKeyResponseFrame] = [.stage(requestID: requestID, stage: "grant", outcome: "ok")]
        do {
            let credential = try await withThrowingTaskGroup(of: SecurityKeyCredentialResponse.self) { group in
                group.addTask { [provider, statusSink] in try await provider.perform(ceremony, status: statusSink) }
                group.addTask { [clock, deadlineMilliseconds] in
                    try await clock.sleep(milliseconds: deadlineMilliseconds)
                    throw SecurityKeyError.deadlineExceeded
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw SecurityKeyError.providerUnavailable }
                return first
            }
            guard generation == token, inFlight.contains(requestID) else { throw SecurityKeyError.staleGeneration }
            frames.append(.stage(requestID: requestID, stage: "sign", outcome: "ok"))
            frames.append(.result(requestID: requestID, credential: credential))
            await statusSink(.completed)
        } catch is CancellationError {
            await provider.cancel()
            frames.append(.stage(requestID: requestID, stage: "sign", outcome: "failed"))
            frames.append(errorFrame(requestID, .cancelled))
        } catch let error as SecurityKeyError {
            await provider.cancel()
            frames.append(.stage(requestID: requestID, stage: "sign", outcome: "failed"))
            frames.append(errorFrame(requestID, error))
            await statusSink(.failed(error.localizedDescription))
        } catch {
            await provider.cancel()
            frames.append(.stage(requestID: requestID, stage: "sign", outcome: "failed"))
            frames.append(.error(requestID: requestID, name: "NotAllowedError", message: error.localizedDescription, code: "provider_failed"))
            await statusSink(.failed(error.localizedDescription))
        }
        await consent.dismissConsent(requestID: requestID)
        return frames
    }

    private func failureFrames(_ requestID: String, _ error: SecurityKeyError) -> [RemoteSecurityKeyResponseFrame] {
        [.stage(requestID: requestID, stage: "grant", outcome: "failed"), errorFrame(requestID, error)]
    }

    private func errorFrame(_ requestID: String, _ error: SecurityKeyError) -> RemoteSecurityKeyResponseFrame {
        let code: String
        switch error {
        case .cancelled: code = "cancelled"
        case .deadlineExceeded: code = "timeout"
        case .replay: code = "replay"
        case .staleGeneration: code = "stale_generation"
        case .unsupported: code = "unsupported"
        case .disabled: code = "disabled"
        default: code = "invalid_or_unavailable"
        }
        return .error(requestID: requestID, name: "NotAllowedError", message: error.localizedDescription, code: code)
    }

    private func validRequestID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }

    private func rememberConsumed(_ requestID: String) {
        guard consumed.insert(requestID).inserted else { return }
        consumedOrder.append(requestID)
        if consumedOrder.count > 4_096 { consumed.remove(consumedOrder.removeFirst()) }
    }
}
