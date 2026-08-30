import Foundation

public enum UpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case nightly
    case dogfood
}

public enum UpdateArtifactFormat: String, Codable, Sendable {
    case appZip = "app-zip"
    case dmg
}

public struct UpdateFeed: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var channel: UpdateChannel
    public var releases: [UpdateRelease]

    public init(schemaVersion: Int = 1, channel: UpdateChannel, releases: [UpdateRelease]) {
        self.schemaVersion = schemaVersion
        self.channel = channel
        self.releases = releases
    }
}

public struct UpdateRelease: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int
    public var publishedAt: Date
    public var minimumSystemVersion: String
    public var notesURL: URL?
    public var artifact: UpdateArtifact

    public init(
        version: String,
        build: Int,
        publishedAt: Date,
        minimumSystemVersion: String,
        notesURL: URL? = nil,
        artifact: UpdateArtifact
    ) {
        self.version = version
        self.build = build
        self.publishedAt = publishedAt
        self.minimumSystemVersion = minimumSystemVersion
        self.notesURL = notesURL
        self.artifact = artifact
    }
}

public struct UpdateArtifact: Codable, Equatable, Sendable {
    public var url: URL
    public var format: UpdateArtifactFormat
    public var sha256: String
    public var size: Int64
    /// Base64-encoded Ed25519 signature over the artifact bytes.
    public var ed25519Signature: String?

    public init(url: URL, format: UpdateArtifactFormat, sha256: String, size: Int64, ed25519Signature: String? = nil) {
        self.url = url
        self.format = format
        self.sha256 = sha256
        self.size = size
        self.ed25519Signature = ed25519Signature
    }
}

public struct InstalledVersion: Equatable, Sendable {
    public var version: String
    public var build: Int

    public init(version: String, build: Int) {
        self.version = version
        self.build = build
    }
}

public struct UpdateCheckSchedule: Equatable, Sendable {
    public var initialDelay: Duration
    public var periodicInterval: Duration
    public var maximumJitter: Duration

    public init(
        initialDelay: Duration = .seconds(30),
        periodicInterval: Duration = .seconds(60 * 60),
        maximumJitter: Duration = .seconds(5 * 60)
    ) {
        self.initialDelay = max(.zero, initialDelay)
        self.periodicInterval = max(.seconds(15 * 60), periodicInterval)
        self.maximumJitter = max(.zero, maximumJitter)
    }

    public func nextPeriodicDelay(randomUnit: Double) -> Duration {
        let bounded = min(1, max(0, randomUnit))
        let intervalSeconds = periodicInterval.components.seconds
        let jitterSeconds = maximumJitter.components.seconds
        return .seconds(intervalSeconds + Int64((Double(jitterSeconds) * bounded).rounded(.down)))
    }
}

public struct UpdateIdleSnapshot: Equatable, Sendable {
    public var hasActiveWork: Bool
    public var sessionActive: Bool
    public var screenLocked: Bool
    public var screensaverActive: Bool
    public var systemIdleSeconds: TimeInterval
    public var lowPowerModeEnabled: Bool

    public init(
        hasActiveWork: Bool,
        sessionActive: Bool,
        screenLocked: Bool,
        screensaverActive: Bool,
        systemIdleSeconds: TimeInterval,
        lowPowerModeEnabled: Bool
    ) {
        self.hasActiveWork = hasActiveWork
        self.sessionActive = sessionActive
        self.screenLocked = screenLocked
        self.screensaverActive = screensaverActive
        self.systemIdleSeconds = systemIdleSeconds
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }
}

public enum UpdateIdleInstallPolicy {
    public static let defaultIdleThreshold: TimeInterval = 5 * 60

    public static func permitsInstall(
        snapshot: UpdateIdleSnapshot,
        optedIn: Bool,
        updateStaged: Bool,
        idleThreshold: TimeInterval = defaultIdleThreshold
    ) -> Bool {
        guard optedIn, updateStaged, !snapshot.hasActiveWork,
              !snapshot.lowPowerModeEnabled,
              snapshot.systemIdleSeconds >= max(1, idleThreshold) else { return false }
        return snapshot.screenLocked || snapshot.screensaverActive || !snapshot.sessionActive
    }
}

public enum UpdateRequirementEvaluator {
    public static func isBelowMinimum(installedVersion: String, minimumRequiredVersion: String?) -> Bool {
        guard let minimumRequiredVersion,
              let installed = try? ReleaseVersion(installedVersion),
              let minimum = try? ReleaseVersion(minimumRequiredVersion) else { return false }
        return installed < minimum
    }
}

public struct StagedUpdate: Codable, Equatable, Sendable {
    public var release: UpdateRelease
    public var artifactPath: String
    public var stagedAt: Date

    public init(release: UpdateRelease, artifactPath: String, stagedAt: Date) {
        self.release = release
        self.artifactPath = artifactPath
        self.stagedAt = stagedAt
    }
}

public enum UpdateError: Error, Equatable, LocalizedError {
    case insecureURL
    case invalidHTTPStatus(Int)
    case invalidFeedSchema(Int)
    case channelMismatch
    case invalidVersion(String)
    case invalidDigest
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case missingSignature
    case unexpectedSignature
    case invalidPublicKey
    case invalidBackendRequirementScope
    case invalidSignature
    case invalidArtifactName
    case responseNotHTTP
    case unsupportedArtifactFormat(UpdateArtifactFormat)
    case extractionFailed(String)
    case invalidApplicationBundle(String)
    case codeSignatureInvalid(Int32)
    case installFailed(String)
    case helperUnavailable

    public var errorDescription: String? {
        switch self {
        case .insecureURL: "Update URLs must use HTTPS"
        case let .invalidHTTPStatus(status): "Update server returned HTTP \(status)"
        case let .invalidFeedSchema(version): "Unsupported update feed schema \(version)"
        case .channelMismatch: "The update feed channel does not match the requested channel"
        case let .invalidVersion(value): "Invalid version: \(value)"
        case .invalidDigest: "The release SHA-256 digest is invalid"
        case let .sizeMismatch(expected, actual): "Artifact size mismatch (expected \(expected), got \(actual))"
        case .checksumMismatch: "Artifact SHA-256 verification failed"
        case .missingSignature: "The update is missing a required Ed25519 signature"
        case .unexpectedSignature: "A signed update was supplied without a trusted public key"
        case .invalidPublicKey: "The trusted Ed25519 public key is invalid"
        case .invalidBackendRequirementScope: "The backend update requirement scope is invalid"
        case .invalidSignature: "Artifact Ed25519 signature verification failed"
        case .invalidArtifactName: "The artifact URL has no safe file name"
        case .responseNotHTTP: "The update server response was not HTTP"
        case let .unsupportedArtifactFormat(format): "Unsupported update artifact format: \(format.rawValue)"
        case let .extractionFailed(message): "Update extraction failed: \(message)"
        case let .invalidApplicationBundle(message): "Invalid update application bundle: \(message)"
        case let .codeSignatureInvalid(status): "The update code signature is invalid (\(status))"
        case let .installFailed(message): "Update installation failed: \(message)"
        case .helperUnavailable: "The update installer helper is unavailable"
        }
    }
}
