import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum VNCBridgeMethod: String, Codable, Sendable { case readClipboard, writeClipboard, reportUserPresence }
public enum VNCClipboardTrigger: String, Codable, Sendable { case explicitGesture, focus, visiblePoll }

public struct VNCBridgeSession: Sendable, Equatable {
    public let identifier: UUID
    public let exactFrameURL: URL
    public let origin: String
    public let sessionToken: String
    public let generation: UInt64

    init(identifier: UUID, exactFrameURL: URL, origin: String, sessionToken: String, generation: UInt64) {
        self.identifier = identifier; self.exactFrameURL = exactFrameURL; self.origin = origin
        self.sessionToken = sessionToken; self.generation = generation
    }
}

public struct VNCBridgeEnvelope: Sendable, Equatable {
    public let requestID: UUID
    public let sessionIdentifier: UUID
    public let frameURL: URL
    public let origin: String
    public let sessionToken: String
    public let generation: UInt64
    public let method: VNCBridgeMethod
    public let visible: Bool
    public let clipboardTrigger: VNCClipboardTrigger?

    public init(requestID: UUID, sessionIdentifier: UUID, frameURL: URL, origin: String, sessionToken: String, generation: UInt64, method: VNCBridgeMethod, visible: Bool, clipboardTrigger: VNCClipboardTrigger? = nil) {
        self.requestID = requestID; self.sessionIdentifier = sessionIdentifier; self.frameURL = frameURL
        self.origin = origin; self.sessionToken = sessionToken; self.generation = generation
        self.method = method; self.visible = visible; self.clipboardTrigger = clipboardTrigger
    }
}

public enum VNCBridgeError: Error, Equatable, Sendable {
    case untrustedSession, frameMismatch, originMismatch, tokenMismatch, staleGeneration, replay
    case hiddenClipboardAccess, invalidTrigger, throttled, clipboardTooLarge(limitBytes: Int), invalidClipboardText
}

public struct VNCClipboardPort: Sendable {
    public var readText: @Sendable () async throws -> String
    public var writeText: @Sendable (String) async throws -> Void

    public init(readText: @escaping @Sendable () async throws -> String, writeText: @escaping @Sendable (String) async throws -> Void) {
        self.readText = readText; self.writeText = writeText
    }
}

#if canImport(AppKit)
public extension VNCClipboardPort {
    static func macOS() -> Self {
        .init(
            readText: { await MainActor.run { NSPasteboard.general.string(forType: .string) ?? "" } },
            writeText: { text in
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    _ = NSPasteboard.general.setString(text, forType: .string)
                }
            }
        )
    }
}
#endif

/// Process-owned bridge authority. Every call revalidates the immutable frame,
/// origin, token and generation and consumes a unique request id.
public actor VNCTrustedBridge {
    public static let maximumClipboardBytes = 1 * 1_024 * 1_024
    public static let clipboardThrottleMilliseconds: Int64 = 500

    private let clipboard: VNCClipboardPort
    private let now: @Sendable () -> Int64
    private let onUserPresence: @Sendable (Bool) async -> Void
    private var session: VNCBridgeSession?
    private var consumed: Set<UUID> = []
    private var consumedOrder: [UUID] = []
    private var lastClipboardAccess: Int64?
    private var highestInstalledGeneration: UInt64 = 0

    public init(clipboard: VNCClipboardPort, now: @escaping @Sendable () -> Int64, onUserPresence: @escaping @Sendable (Bool) async -> Void = { _ in }) {
        self.clipboard = clipboard; self.now = now; self.onUserPresence = onUserPresence
    }

    func install(session: VNCBridgeSession) {
        self.session = session
        consumed.removeAll(); consumedOrder.removeAll(); lastClipboardAccess = nil
    }

    /// Preferred app integration edge: a bridge session can only be minted
    /// from the existing URL trust policy's exact successful decision.
    @discardableResult
    public func install(frameURL: URL, trustPolicy: VNCTrustPolicy, identifier: UUID = UUID(), generation: UInt64) throws -> VNCBridgeSession {
        guard generation > highestInstalledGeneration, case .allowed(let origin, let token) = trustPolicy.evaluate(frameURL) else {
            throw VNCBridgeError.untrustedSession
        }
        let verified = VNCBridgeSession(identifier: identifier, exactFrameURL: frameURL, origin: origin, sessionToken: token, generation: generation)
        install(session: verified)
        highestInstalledGeneration = generation
        return verified
    }

    public func invalidate(generation: UInt64) {
        guard session?.generation == generation else { return }
        session = nil; consumed.removeAll(); consumedOrder.removeAll(); lastClipboardAccess = nil
    }

    public func readClipboard(_ envelope: VNCBridgeEnvelope) async throws -> String {
        try authorize(envelope, method: .readClipboard)
        try authorizeClipboard(envelope)
        let text = try await clipboard.readText()
        try validateClipboard(text)
        return text
    }

    public func writeClipboard(_ text: String, envelope: VNCBridgeEnvelope) async throws {
        try authorize(envelope, method: .writeClipboard)
        try authorizeClipboard(envelope)
        try validateClipboard(text)
        try await clipboard.writeText(text)
    }

    public func reportUserPresence(_ present: Bool, envelope: VNCBridgeEnvelope) async throws {
        try authorize(envelope, method: .reportUserPresence)
        await onUserPresence(present)
    }

    private func authorize(_ envelope: VNCBridgeEnvelope, method: VNCBridgeMethod) throws {
        guard let session, envelope.sessionIdentifier == session.identifier else { throw VNCBridgeError.untrustedSession }
        guard envelope.method == method else { throw VNCBridgeError.untrustedSession }
        guard envelope.frameURL.absoluteString == session.exactFrameURL.absoluteString else { throw VNCBridgeError.frameMismatch }
        guard envelope.origin == session.origin else { throw VNCBridgeError.originMismatch }
        guard Self.constantTimeEqual(envelope.sessionToken, session.sessionToken) else { throw VNCBridgeError.tokenMismatch }
        guard envelope.generation == session.generation else { throw VNCBridgeError.staleGeneration }
        guard consumed.insert(envelope.requestID).inserted else { throw VNCBridgeError.replay }
        consumedOrder.append(envelope.requestID)
        if consumedOrder.count > 4_096, let removed = consumedOrder.first {
            consumedOrder.removeFirst(); consumed.remove(removed)
        }
    }

    private func authorizeClipboard(_ envelope: VNCBridgeEnvelope) throws {
        guard envelope.visible else { throw VNCBridgeError.hiddenClipboardAccess }
        guard envelope.clipboardTrigger != nil else { throw VNCBridgeError.invalidTrigger }
        let instant = now()
        if let lastClipboardAccess, instant - lastClipboardAccess < Self.clipboardThrottleMilliseconds { throw VNCBridgeError.throttled }
        lastClipboardAccess = instant
    }

    private func validateClipboard(_ text: String) throws {
        guard text.utf8.count <= Self.maximumClipboardBytes else { throw VNCBridgeError.clipboardTooLarge(limitBytes: Self.maximumClipboardBytes) }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw VNCBridgeError.invalidClipboardText }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        for index in 0..<max(left.count, right.count) { difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0) }
        return difference == 0
    }
}

public enum VNCHostShortcutRouter {
    /// Host shortcuts are consumed by the host and must never be forwarded to
    /// the guest. Normal input returns false and may be delivered to VNC.
    public static func shouldRouteToHost(key: String, command: Bool, option: Bool = false, control: Bool = false) -> Bool {
        guard command || control else { return false }
        let normalized = key.lowercased()
        return ["q", "w", ",", "`", "tab"].contains(normalized) || (option && ["arrowleft", "arrowright"].contains(normalized))
    }
}
