import Foundation

private final class PluginCatalogSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.currentRequest?.url, let to = request.url,
              from.scheme?.lowercased() == to.scheme?.lowercased(),
              from.host?.lowercased() == to.host?.lowercased(),
              (from.port ?? 443) == (to.port ?? 443) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

public struct PluginCatalogSnapshot: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var entries: [PluginCatalogEntry]
    public var includesPrivateMarketplaces: Bool

    public init(fetchedAt: Date = .now, entries: [PluginCatalogEntry], includesPrivateMarketplaces: Bool = false) {
        self.fetchedAt = fetchedAt
        self.entries = entries
        self.includesPrivateMarketplaces = includesPrivateMarketplaces
    }

    private enum CodingKeys: String, CodingKey { case fetchedAt, entries, includesPrivateMarketplaces }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fetchedAt: try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast,
                  entries: try c.decode([PluginCatalogEntry].self, forKey: .entries),
                  includesPrivateMarketplaces: try c.decodeIfPresent(Bool.self, forKey: .includesPrivateMarketplaces) ?? false)
    }
}

public protocol PluginCatalogClient: Sendable {
    func fetchCatalog() async throws -> PluginCatalogSnapshot
}

public struct URLPluginCatalogClient: PluginCatalogClient {
    public let url: URL
    public let session: URLSession
    public let bearerToken: @Sendable () async throws -> String?

    public init(
        url: URL,
        session: URLSession? = nil,
        bearerToken: @escaping @Sendable () async throws -> String? = { nil }
    ) {
        self.url = url
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration, delegate: PluginCatalogSessionDelegate(), delegateQueue: nil)
        }
        self.bearerToken = bearerToken
    }

    public func fetchCatalog() async throws -> PluginCatalogSnapshot {
        guard url.scheme?.lowercased() == "https", url.host != nil else { throw PluginError.malformedCatalog }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = try await bearerToken(), !token.isEmpty {
            guard token.count <= 8_192, token.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else { throw PluginError.malformedCatalog }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url,
              Self.sameOrigin(url, finalURL),
              (200..<300).contains(http.statusCode), data.count <= 10 * 1_024 * 1_024 else {
            throw PluginError.malformedCatalog
        }
        var snapshot: PluginCatalogSnapshot
        do { snapshot = try JSONDecoder().decode(PluginCatalogSnapshot.self, from: data) }
        catch { throw PluginError.malformedCatalog }
        for entry in snapshot.entries {
            try PluginSecurity.validate(entry.manifest)
            guard entry.id == entry.manifest.id else { throw PluginError.malformedCatalog }
            guard entry.popularity >= 0 else { throw PluginError.malformedCatalog }
            if entry.ownership == .team {
                guard entry.teamID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw PluginError.malformedCatalog }
            } else if entry.teamID != nil {
                throw PluginError.malformedCatalog
            }
            if let downloadURL = entry.downloadURL {
                guard downloadURL.scheme?.lowercased() == "https", downloadURL.host != nil,
                      downloadURL.user == nil, downloadURL.password == nil, downloadURL.fragment == nil else { throw PluginError.malformedCatalog }
            }
            if let iconURL = entry.iconURL {
                guard iconURL.scheme?.lowercased() == "https", iconURL.host != nil,
                      iconURL.user == nil, iconURL.password == nil, iconURL.fragment == nil else { throw PluginError.malformedCatalog }
            }
        }
        snapshot.entries.sort { $0.manifest.displayName.localizedCaseInsensitiveCompare($1.manifest.displayName) == .orderedAscending }
        return snapshot
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }
}

public actor PluginCatalogCache {
    private let client: any PluginCatalogClient
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: PluginCatalogSnapshot?
    private var inFlight: Task<PluginCatalogSnapshot, Error>?

    public init(client: any PluginCatalogClient, ttl: TimeInterval = pluginCatalogTTL, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.ttl = max(0, ttl)
        self.now = now
    }

    public func snapshot(forceRefresh: Bool = false) async throws -> PluginCatalogSnapshot {
        let current = now()
        if !forceRefresh, let cached, current.timeIntervalSince(cached.fetchedAt) < ttl { return cached }
        if let inFlight { return try await inFlight.value }
        let client = self.client
        let task = Task { try await client.fetchCatalog() }
        inFlight = task
        defer { inFlight = nil }
        do {
            var value = try await task.value
            value.fetchedAt = current
            cached = value
            return value
        } catch {
            if let cached { return cached }
            throw error
        }
    }

    public func invalidate() { cached = nil }

    public func filter(_ filter: PluginCatalogFilter, installedIDs: Set<String>) async throws -> [PluginCatalogEntry] {
        try await snapshot().entries.filter { $0.matches(filter, installedIDs: installedIDs) }
    }
}
