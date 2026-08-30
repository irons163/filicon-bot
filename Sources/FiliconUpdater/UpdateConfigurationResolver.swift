import Foundation

/// Resolves the signed update feed without requiring each app user to configure it.
/// Explicit user overrides win; packaged Info.plist values are the production default.
public enum UpdateConfigurationResolver {
    public static let feedURLInfoKey = "FiliconUpdateFeedURL"
    public static let publicKeyInfoKey = "FiliconUpdatePublicKeyBase64"
    public static let feedURLEnvironmentKey = "FILICON_UPDATE_FEED_URL"
    public static let publicKeyEnvironmentKey = "FILICON_UPDATE_PUBLIC_KEY_BASE64"

    public static func resolve(
        channel: UpdateChannel = .stable,
        automaticallyChecks: Bool = true,
        automaticallyDownloads: Bool = false,
        persistedFeedURL: String? = nil,
        persistedPublicKeyBase64: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) throws -> UpdateConfiguration? {
        let persisted = pair(feed: persistedFeedURL, key: persistedPublicKeyBase64)
        let environmentPair = pair(
            feed: environment[feedURLEnvironmentKey],
            key: environment[publicKeyEnvironmentKey]
        )
        let packaged = pair(
            feed: infoDictionary[feedURLInfoKey] as? String,
            key: infoDictionary[publicKeyInfoKey] as? String
        )

        guard let selected = persisted ?? environmentPair ?? packaged else { return nil }
        guard let url = URL(string: selected.feed),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw UpdateError.insecureURL
        }
        guard let key = Data(base64Encoded: selected.key), key.count == 32 else {
            throw UpdateError.invalidPublicKey
        }
        return try UpdateConfiguration(
            channel: channel,
            feedURL: url,
            automaticallyChecks: automaticallyChecks,
            automaticallyDownloads: automaticallyDownloads,
            requiresSignature: true,
            trustedEd25519PublicKey: key
        )
    }

    private static func pair(feed: String?, key: String?) -> (feed: String, key: String)? {
        let feed = feed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feed.isEmpty || !key.isEmpty else { return nil }
        return (feed, key)
    }
}
