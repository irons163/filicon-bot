import Foundation

public typealias FeedLoader = @Sendable (URL) async throws -> (Data, URLResponse)
public typealias ArtifactDownloader = @Sendable (URL) async throws -> (URL, URLResponse)

public actor UpdateService {
    private let feedLoader: FeedLoader
    private let artifactDownloader: ArtifactDownloader
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        feedLoader: @escaping FeedLoader = UpdateService.liveFeedLoader,
        artifactDownloader: @escaping ArtifactDownloader = UpdateService.liveArtifactDownloader,
        fileManager: FileManager = .default
    ) {
        self.feedLoader = feedLoader
        self.artifactDownloader = artifactDownloader
        self.fileManager = fileManager
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func fetchFeed(from url: URL, channel: UpdateChannel) async throws -> UpdateFeed {
        try Self.requireHTTPS(url)
        let (data, response) = try await feedLoader(url)
        try Self.validate(response: response)
        guard response.url?.scheme?.lowercased() == "https" else { throw UpdateError.insecureURL }
        let feed = try decoder.decode(UpdateFeed.self, from: data)
        guard feed.schemaVersion == 1 else { throw UpdateError.invalidFeedSchema(feed.schemaVersion) }
        guard feed.channel == channel else { throw UpdateError.channelMismatch }
        for release in feed.releases { try Self.requireHTTPS(release.artifact.url) }
        return feed
    }

    public func downloadAndStage(
        _ release: UpdateRelease,
        in stagingRoot: URL,
        signaturePolicy: SignaturePolicy = .disabled,
        now: Date = Date()
    ) async throws -> StagedUpdate {
        try Self.requireHTTPS(release.artifact.url)
        let (temporaryDownload, response) = try await artifactDownloader(release.artifact.url)
        try Self.validate(response: response)
        guard response.url?.scheme?.lowercased() == "https" else { throw UpdateError.insecureURL }

        let name = release.artifact.url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw UpdateError.invalidArtifactName
        }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let releaseDirectory = stagingRoot.appendingPathComponent("\(release.version)-\(release.build)", isDirectory: true)
        let pendingDirectory = stagingRoot.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: pendingDirectory) } }

        let artifactURL = pendingDirectory.appendingPathComponent(name)
        try fileManager.copyItem(at: temporaryDownload, to: artifactURL)
        try ArtifactVerifier.verify(file: artifactURL, artifact: release.artifact, signaturePolicy: signaturePolicy)
        let staged = StagedUpdate(release: release, artifactPath: name, stagedAt: now)
        let metadata = try encoder.encode(staged)
        let metadataURL = pendingDirectory.appendingPathComponent("staged-update.json")
        try metadata.write(to: metadataURL, options: .atomic)

        if fileManager.fileExists(atPath: releaseDirectory.path) { try fileManager.removeItem(at: releaseDirectory) }
        try fileManager.moveItem(at: pendingDirectory, to: releaseDirectory)
        committed = true
        return staged
    }

    nonisolated public static func liveFeedLoader(_ url: URL) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(from: url)
    }

    nonisolated public static func liveArtifactDownloader(_ url: URL) async throws -> (URL, URLResponse) {
        try await URLSession.shared.download(from: url)
    }

    private static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil else { throw UpdateError.insecureURL }
    }

    private static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw UpdateError.responseNotHTTP }
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.invalidHTTPStatus(http.statusCode) }
    }
}

public struct UpdateInstallPlan: Codable, Equatable, Sendable {
    public var stagedArtifact: URL
    public var expectedBundleIdentifier: String
    public var targetApplication: URL
    public var relaunchAfterInstall: Bool

    public init(stagedArtifact: URL, expectedBundleIdentifier: String, targetApplication: URL, relaunchAfterInstall: Bool = true) throws {
        guard stagedArtifact.isFileURL, targetApplication.isFileURL,
              targetApplication.pathExtension == "app", !expectedBundleIdentifier.isEmpty else {
            throw UpdateError.invalidArtifactName
        }
        self.stagedArtifact = stagedArtifact
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.targetApplication = targetApplication
        self.relaunchAfterInstall = relaunchAfterInstall
    }
}
