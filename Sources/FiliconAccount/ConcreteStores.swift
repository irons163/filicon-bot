import Foundation

public actor FileOnboardingStore: OnboardingStore {
    public static let defaultMaximumByteCount = 1_048_576
    public let fileURL: URL
    public let maximumByteCount: Int

    public init(fileURL: URL, maximumByteCount: Int = defaultMaximumByteCount) {
        self.fileURL = fileURL
        self.maximumByteCount = max(1, maximumByteCount)
    }

    public func load() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= maximumByteCount else { throw FileOnboardingStoreError.invalidFile }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= maximumByteCount else { throw FileOnboardingStoreError.invalidFile }
        return data
    }

    public func save(_ data: Data) async throws {
        guard data.count <= maximumByteCount else { throw FileOnboardingStoreError.invalidFile }
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw FileOnboardingStoreError.invalidFile }
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public enum FileOnboardingStoreError: Error, Equatable, Sendable { case invalidFile }

public typealias FeedbackBearerTokenProvider = @Sendable () async throws -> String?

public struct HTTPSFeedbackTransport: FeedbackTransport {
    public let endpoint: URL
    public let maximumResponseByteCount: Int
    private let session: URLSession
    private let bearerToken: FeedbackBearerTokenProvider?

    public init(endpoint: URL, session: URLSession = .shared, maximumResponseByteCount: Int = 262_144, bearerToken: FeedbackBearerTokenProvider? = nil) throws {
        guard HTTPSRequestSafety.validEndpoint(endpoint), (1...1_048_576).contains(maximumResponseByteCount) else { throw FeedbackError.invalid }
        self.endpoint = endpoint; self.session = session; self.maximumResponseByteCount = maximumResponseByteCount; self.bearerToken = bearerToken
    }

    public func send(_ submission: FeedbackSubmission) async throws -> FeedbackHTTPResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = try await bearerToken?() {
            guard HTTPSRequestSafety.validBearer(token) else { throw FeedbackError.authenticationRequired }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(submission)
        do {
            let (data, response) = try await session.data(for: request, delegate: HTTPSNoRedirectDelegate.shared)
            guard data.count <= maximumResponseByteCount, let response = response as? HTTPURLResponse,
                  response.url == endpoint else { throw FeedbackError.transport }
            return FeedbackHTTPResponse(statusCode: response.statusCode, body: data)
        } catch let error as FeedbackError { throw error }
        catch { throw FeedbackError.transport }
    }
}
