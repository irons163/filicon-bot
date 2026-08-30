import Foundation
#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit
#endif

public struct TeachWindowDescriptor: Codable, Hashable, Sendable {
    public let windowID: UInt32
    public let ownerName: String?
    public let ownerBundleIdentifier: String?
    public let title: String?
    public let isOnScreen: Bool
    public let secureTextKnown: Bool?

    public init(windowID: UInt32, ownerName: String?, ownerBundleIdentifier: String?, title: String?, isOnScreen: Bool, secureTextKnown: Bool?) {
        self.windowID = windowID; self.ownerName = ownerName; self.ownerBundleIdentifier = ownerBundleIdentifier
        self.title = title; self.isOnScreen = isOnScreen; self.secureTextKnown = secureTextKnown
    }
}
public enum SensitiveWindowDisposition: String, Codable, Sendable { case safe, sensitive, unknown }
public protocol SensitiveWindowClassifier: Sendable { func classify(_ window: TeachWindowDescriptor) -> SensitiveWindowDisposition }

public struct DefaultSensitiveWindowClassifier: SensitiveWindowClassifier {
    private let ownBundleIdentifier: String
    public init(ownBundleIdentifier: String = "com.filicon.app") { self.ownBundleIdentifier = ownBundleIdentifier.lowercased() }
    public func classify(_ window: TeachWindowDescriptor) -> SensitiveWindowDisposition {
        guard window.isOnScreen, window.windowID > 0 else { return .safe }
        if window.secureTextKnown == true { return .sensitive }
        guard let owner = window.ownerBundleIdentifier?.lowercased(), !owner.isEmpty else { return .unknown }
        if owner == ownBundleIdentifier || owner.hasPrefix(ownBundleIdentifier + ".") { return .sensitive }
        let title = window.title?.lowercased() ?? ""
        let name = window.ownerName?.lowercased() ?? ""
        let signature = "\(owner) \(name) \(title)"
        let sensitiveTerms = ["authenticationservices", "securityagent", "system settings", "password", "1password", "bitwarden", "keychain", "consent", "authorization", "sign in"]
        if sensitiveTerms.contains(where: signature.contains) { return .sensitive }
        if window.secureTextKnown == false { return .safe }
        return .unknown
    }
}

public protocol TeachWindowInventory: Sendable { func windows() async throws -> [TeachWindowDescriptor] }
public protocol TeachSensitiveFilterUpdater: Sendable { func updateExcludedWindowIDs(_ ids: Set<UInt32>) async throws }
public protocol TeachCaptureBlackout: Sendable { func setBlackout(_ enabled: Bool) async }

public struct TeachMaskingPolicyMetadata: Codable, Equatable, Sendable {
    public let version: Int
    public let failClosed: Bool
    public let classifier: String
    public let dynamicallyUpdated: Bool
    public init(version: Int = 1, failClosed: Bool = true, classifier: String, dynamicallyUpdated: Bool = true) {
        self.version = version; self.failClosed = failClosed; self.classifier = classifier; self.dynamicallyUpdated = dynamicallyUpdated
    }
}
public struct TeachMaskingStatus: Codable, Equatable, Sendable {
    public let maskedCount: Int
    public let pausedCount: Int
    public let isPaused: Bool
    public let excludedWindowIDs: Set<UInt32>
    public let policy: TeachMaskingPolicyMetadata
}
public enum TeachSensitiveMaskingError: Error, Equatable, Sendable { case inventoryUnavailable, filterUpdateFailed }

/// Refresh this whenever the shareable-window inventory changes. Unknown
/// windows cause blackout before any filter update can expose a frame.
public actor TeachSensitiveMaskingController {
    private let inventory: any TeachWindowInventory
    private let classifier: any SensitiveWindowClassifier
    private let updater: any TeachSensitiveFilterUpdater
    private let blackout: any TeachCaptureBlackout
    private let metadata: TeachMaskingPolicyMetadata
    private var status: TeachMaskingStatus

    public init(inventory: any TeachWindowInventory, classifier: any SensitiveWindowClassifier, updater: any TeachSensitiveFilterUpdater, blackout: any TeachCaptureBlackout, classifierName: String = "default-sensitive-window-v1") {
        self.inventory = inventory; self.classifier = classifier; self.updater = updater; self.blackout = blackout
        metadata = .init(classifier: classifierName)
        status = .init(maskedCount: 0, pausedCount: 1, isPaused: true, excludedWindowIDs: [], policy: metadata)
    }

    public func currentStatus() -> TeachMaskingStatus { status }

    @discardableResult
    public func refresh() async throws -> TeachMaskingStatus {
        let windows: [TeachWindowDescriptor]
        do { windows = try await inventory.windows() }
        catch {
            await blackout.setBlackout(true)
            status = .init(maskedCount: status.maskedCount, pausedCount: status.pausedCount + 1, isPaused: true, excludedWindowIDs: status.excludedWindowIDs, policy: metadata)
            throw TeachSensitiveMaskingError.inventoryUnavailable
        }
        var sensitive: Set<UInt32> = []
        var unknown = 0
        for window in windows {
            switch classifier.classify(window) {
            case .safe: break
            case .sensitive: sensitive.insert(window.windowID)
            case .unknown: sensitive.insert(window.windowID); unknown += 1
            }
        }
        if unknown > 0 { await blackout.setBlackout(true) }
        do { try await updater.updateExcludedWindowIDs(sensitive) }
        catch {
            await blackout.setBlackout(true)
            status = .init(maskedCount: sensitive.count, pausedCount: unknown + 1, isPaused: true, excludedWindowIDs: sensitive, policy: metadata)
            throw TeachSensitiveMaskingError.filterUpdateFailed
        }
        await blackout.setBlackout(unknown > 0)
        status = .init(maskedCount: sensitive.count, pausedCount: unknown, isPaused: unknown > 0, excludedWindowIDs: sensitive, policy: metadata)
        return status
    }
}

#if canImport(ScreenCaptureKit)
@available(macOS 14.0, *)
public extension TeachSensitiveMaskingController {
    static func screenCaptureKit(
        backend: ScreenCaptureKitBackend,
        classifier: any SensitiveWindowClassifier = DefaultSensitiveWindowClassifier()
    ) -> TeachSensitiveMaskingController {
        .init(inventory: ScreenCaptureKitWindowInventory(), classifier: classifier, updater: backend, blackout: backend)
    }
}

@available(macOS 14.0, *)
public struct ScreenCaptureKitWindowInventory: TeachWindowInventory {
    public init() {}
    public func windows() async throws -> [TeachWindowDescriptor] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.map { window in
            .init(windowID: window.windowID, ownerName: window.owningApplication?.applicationName,
                  ownerBundleIdentifier: window.owningApplication?.bundleIdentifier, title: window.title,
                  isOnScreen: window.isOnScreen, secureTextKnown: nil)
        }
    }
}
#endif
