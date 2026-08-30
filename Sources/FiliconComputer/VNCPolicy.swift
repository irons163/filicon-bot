import Foundation

public enum VNCTrustDecision: Sendable, Equatable {
    case allowed(origin: String, sessionToken: String)
    case denied(VNCTrustDenial)
}
public enum VNCTrustDenial: String, Sendable, Equatable {
    case malformedURL
    case unsupportedScheme
    case invalidEntryPage
    case untrustedOrigin
    case missingSessionToken
    case invalidSessionToken
}

public struct VNCTrustPolicy: Sendable {
    public static let sessionTokenQueryName = "session_token"

    private let trustedHTTPSOrigins: Set<String>
    private let sessionToken: String

    public init(trustedHTTPSOrigins: Set<String>, sessionToken: String) {
        self.trustedHTTPSOrigins = Set(trustedHTTPSOrigins.compactMap(Self.canonicalHTTPSOrigin))
        self.sessionToken = sessionToken
    }

    public func evaluate(_ url: URL) -> VNCTrustDecision {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .denied(.unsupportedScheme)
        }
        guard url.path.hasSuffix("/vnc.html") else { return .denied(.invalidEntryPage) }
        guard let host = url.host?.lowercased() else { return .denied(.malformedURL) }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if !loopback {
            guard scheme == "https", let origin = Self.origin(of: url), trustedHTTPSOrigins.contains(origin) else {
                return .denied(.untrustedOrigin)
            }
        }
        guard !sessionToken.isEmpty else { return .denied(.missingSessionToken) }
        guard let supplied = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == Self.sessionTokenQueryName })?.value,
              !supplied.isEmpty else {
            return .denied(.missingSessionToken)
        }
        guard Self.constantTimeEqual(supplied, sessionToken) else { return .denied(.invalidSessionToken) }
        return .allowed(origin: Self.origin(of: url) ?? "\(scheme)://\(host)", sessionToken: supplied)
    }

    public func authorizationHeaders(for url: URL) -> [String: String]? {
        guard case .allowed(_, let token) = evaluate(url) else { return nil }
        return ["X-Filicon-VNC-Session": token]
    }

    private static func canonicalHTTPSOrigin(_ raw: String) -> String? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return origin(of: url)
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let defaultPort = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        return "\(scheme)://\(host)\(url.port == nil || defaultPort ? "" : ":\(url.port!)")"
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }
}

public struct VNCLivenessCounters: Sendable, Equatable {
    public var keys: Int
    public var clicks: Int
    public var moves: Int
    public var drawOperations: Int
    public var inboundBytes: Int

    public init(keys: Int, clicks: Int, moves: Int, drawOperations: Int, inboundBytes: Int) {
        self.keys = keys
        self.clicks = clicks
        self.moves = moves
        self.drawOperations = drawOperations
        self.inboundBytes = inboundBytes
    }
}

public struct VNCLivenessReport: Sendable, Equatable {
    public var stallMilliseconds: Int64
    public var keys: Int
    public var clicks: Int
    public var moves: Int
    public var inboundBytes: Int
}

public struct VNCLivenessDetector: Sendable {
    public static let windowMilliseconds: Int64 = 10_000
    public static let minimumImpactfulInputs = 3

    private struct Delta: Sendable {
        let at: Int64
        let counters: VNCLivenessCounters
    }

    private var baseline: VNCLivenessCounters?
    private var coveredSince: Int64?
    private var deltas: [Delta] = []
    private var episodeReported = false

    public init() {}

    public mutating func reset() {
        baseline = nil
        coveredSince = nil
        deltas.removeAll()
        episodeReported = false
    }

    public mutating func sample(at now: Int64, counters: VNCLivenessCounters) -> VNCLivenessReport? {
        guard let previous = baseline else {
            baseline = counters
            coveredSince = now
            return nil
        }
        let delta = VNCLivenessCounters(
            keys: counters.keys - previous.keys,
            clicks: counters.clicks - previous.clicks,
            moves: counters.moves - previous.moves,
            drawOperations: counters.drawOperations - previous.drawOperations,
            inboundBytes: counters.inboundBytes - previous.inboundBytes
        )
        guard [delta.keys, delta.clicks, delta.moves, delta.drawOperations, delta.inboundBytes].allSatisfy({ $0 >= 0 }) else {
            reset()
            baseline = counters
            coveredSince = now
            return nil
        }
        baseline = counters
        deltas.append(Delta(at: now, counters: delta))
        deltas.removeAll { $0.at <= now - Self.windowMilliseconds }
        if delta.drawOperations > 0 || delta.inboundBytes > 0 { episodeReported = false }
        guard !episodeReported,
              let coveredSince,
              now - coveredSince >= Self.windowMilliseconds else { return nil }
        let total = deltas.reduce(into: VNCLivenessCounters(keys: 0, clicks: 0, moves: 0, drawOperations: 0, inboundBytes: 0)) {
            $0.keys += $1.counters.keys
            $0.clicks += $1.counters.clicks
            $0.moves += $1.counters.moves
            $0.drawOperations += $1.counters.drawOperations
            $0.inboundBytes += $1.counters.inboundBytes
        }
        guard total.keys + total.clicks >= Self.minimumImpactfulInputs,
              total.drawOperations == 0,
              total.inboundBytes == 0 else { return nil }
        episodeReported = true
        let oldest = deltas.first { $0.counters.keys + $0.counters.clicks > 0 }?.at ?? now
        return VNCLivenessReport(
            stallMilliseconds: max(0, now - oldest),
            keys: total.keys,
            clicks: total.clicks,
            moves: total.moves,
            inboundBytes: total.inboundBytes
        )
    }
}

public struct VNCInputThrottle: Sendable {
    public static let clipboardMilliseconds: Int64 = 500
    public static let gestureMilliseconds: Int64 = 200
    public static let telemetryMilliseconds: Int64 = 1_000

    public enum Channel: Sendable, Hashable { case clipboard, gesture, telemetry }
    private var lastEmitted: [Channel: Int64] = [:]

    public init() {}

    public mutating func shouldEmit(_ channel: Channel, at now: Int64) -> Bool {
        let interval: Int64 = switch channel {
        case .clipboard: Self.clipboardMilliseconds
        case .gesture: Self.gestureMilliseconds
        case .telemetry: Self.telemetryMilliseconds
        }
        if let last = lastEmitted[channel], now - last < interval { return false }
        lastEmitted[channel] = now
        return true
    }
}
