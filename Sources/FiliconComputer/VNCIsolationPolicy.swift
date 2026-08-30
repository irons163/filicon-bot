import Foundation

public enum VNCWebCapability: String, Codable, CaseIterable, Sendable {
    case readClipboard, writeClipboard, reportUserPresence, telemetry
}
public enum VNCNavigationDisposition: Equatable, Sendable { case allow, deny }
public enum VNCProcessRecoveryDisposition: Equatable, Sendable { case reload(generation: UInt64), crashOut }
public enum VNCIsolationError: Error, Equatable, Sendable { case invalidConfiguration, untrustedOrigin, forbiddenMethod, malformedMessage, tokenOriginMismatch, replay, crashedOut }

public struct VNCIsolatedSession: Sendable, Equatable {
    public let identifier: UUID
    public let accountID: String
    public let computerID: String
    public let generation: UInt64
    public let contentWorld: String
    public let allowedOrigin: String
    public let allowedMethods: Set<VNCWebCapability>
}

public struct VNCContentMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let method: String
    public let requestID: UUID
    public let generation: UInt64
    public let payload: [String: String]

    public init(version: Int = 1, method: String, requestID: UUID, generation: UInt64, payload: [String: String] = [:]) {
        self.version = version; self.method = method; self.requestID = requestID; self.generation = generation; self.payload = payload
    }
}

/// Fail-closed capability surface for VNCWebView integration. Sessions are
/// memory-only and scoped to one account/computer pair.
public actor VNCIsolationPolicy {
    public static let contentWorldName = "FiliconVNCBridge"
    public static let crashLimit = 3
    public static let crashWindowMilliseconds: Int64 = 60_000
    public static let maximumMessageBytes = 64 * 1_024

    private let now: @Sendable () -> Int64
    private let allowedOrigin: String
    private let tokenOrigin: String
    private var session: VNCIsolatedSession
    private var crashes: [Int64] = []
    private var consumedRequestIDs: Set<UUID> = []

    public init(accountID: String, computerID: String, allowedOrigin: String, tokenOrigin: String, allowedMethods: Set<VNCWebCapability> = Set(VNCWebCapability.allCases), now: @escaping @Sendable () -> Int64) throws {
        guard !accountID.isEmpty, !computerID.isEmpty, let origin = Self.canonicalOrigin(allowedOrigin), origin == Self.canonicalOrigin(tokenOrigin), !allowedMethods.isEmpty else {
            throw VNCIsolationError.invalidConfiguration
        }
        self.now = now; self.allowedOrigin = origin; self.tokenOrigin = origin
        session = .init(identifier: UUID(), accountID: accountID, computerID: computerID, generation: 1, contentWorld: Self.contentWorldName, allowedOrigin: origin, allowedMethods: allowedMethods)
    }

    public func currentSession() -> VNCIsolatedSession { session }

    public func validateMessage(_ data: Data, frameURL: URL, contentWorld: String) throws -> VNCContentMessage {
        guard data.count <= Self.maximumMessageBytes, contentWorld == session.contentWorld,
              Self.canonicalOrigin(frameURL.absoluteString) == allowedOrigin else { throw VNCIsolationError.untrustedOrigin }
        guard let message = try? JSONDecoder().decode(VNCContentMessage.self, from: data), message.version == 1,
              message.generation == session.generation, let method = VNCWebCapability(rawValue: message.method) else {
            throw VNCIsolationError.malformedMessage
        }
        guard session.allowedMethods.contains(method) else { throw VNCIsolationError.forbiddenMethod }
        guard validatePayload(message.payload, method: method) else { throw VNCIsolationError.malformedMessage }
        guard consumedRequestIDs.insert(message.requestID).inserted else { throw VNCIsolationError.replay }
        if consumedRequestIDs.count > 4_096 { consumedRequestIDs.removeAll(keepingCapacity: true); consumedRequestIDs.insert(message.requestID) }
        return message
    }

    public func navigation(to url: URL, isMainFrame: Bool) -> VNCNavigationDisposition {
        guard isMainFrame, Self.canonicalOrigin(url.absoluteString) == allowedOrigin,
              url.path.hasSuffix("/vnc.html") else { return .deny }
        return .allow
    }

    public func allowNewWindow(_ url: URL) -> Bool { false }
    public func allowDownload(_ url: URL) -> Bool { false }
    public func requestHeaders(for url: URL, token: String) throws -> [String: String] {
        guard !token.isEmpty, Self.canonicalOrigin(url.absoluteString) == tokenOrigin else { throw VNCIsolationError.tokenOriginMismatch }
        return ["X-Filicon-VNC-Session": token]
    }

    public func processDidCrash() throws -> VNCProcessRecoveryDisposition {
        let instant = now()
        crashes.removeAll { recorded in
            guard instant >= recorded else { return false }
            let (elapsed, overflow) = instant.subtractingReportingOverflow(recorded)
            return overflow || elapsed >= Self.crashWindowMilliseconds
        }
        crashes.append(instant)
        guard crashes.count <= Self.crashLimit, session.generation < .max else { throw VNCIsolationError.crashedOut }
        session = .init(identifier: UUID(), accountID: session.accountID, computerID: session.computerID, generation: session.generation + 1, contentWorld: session.contentWorld, allowedOrigin: session.allowedOrigin, allowedMethods: session.allowedMethods)
        consumedRequestIDs.removeAll(keepingCapacity: true)
        return .reload(generation: session.generation)
    }

    public func recoverAfterExplicitVisibility() {
        crashes.removeAll()
        guard session.generation < .max else { return }
        session = .init(identifier: UUID(), accountID: session.accountID, computerID: session.computerID, generation: session.generation + 1, contentWorld: session.contentWorld, allowedOrigin: session.allowedOrigin, allowedMethods: session.allowedMethods)
        consumedRequestIDs.removeAll(keepingCapacity: true)
    }

    private func validatePayload(_ payload: [String: String], method: VNCWebCapability) -> Bool {
        let trustedClipboardTriggers = Set([VNCClipboardTrigger.explicitGesture.rawValue, VNCClipboardTrigger.focus.rawValue])
        switch method {
        case .readClipboard:
            return Set(payload.keys) == ["trigger"] && payload["trigger"].map(trustedClipboardTriggers.contains) == true
        case .writeClipboard:
            guard Set(payload.keys) == ["text", "trigger"], let text = payload["text"],
                  payload["trigger"].map(trustedClipboardTriggers.contains) == true else { return false }
            return text.utf8.count <= VNCTrustedBridge.maximumClipboardBytes && !text.unicodeScalars.contains(where: { $0.value == 0 })
        case .reportUserPresence: return Set(payload.keys) == ["isPresent"] && ["true", "false"].contains(payload["isPresent"])
        case .telemetry:
            let allowed: Set<String> = ["keys", "clicks", "moves", "drawOperations", "inboundBytes"]
            return !payload.isEmpty && Set(payload.keys).isSubset(of: allowed) && payload.values.allSatisfy { Int64($0).map { $0 >= 0 } == true }
        }
    }

    private static func canonicalOrigin(_ raw: String) -> String? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        let defaultPort = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        return "\(scheme)://\(host)\(url.port == nil || defaultPort ? "" : ":\(url.port!)")"
    }
}
