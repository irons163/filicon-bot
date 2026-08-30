import Foundation

public enum FiliconDeepLink: Equatable, Sendable {
    case conversation(UUID)
    case agent(UUID)
    case sharedRoomJoin(token: String)
    case pluginAdd(id: String)
    case open
    case infoDeepLinks

    public init?(url: URL) {
        let raw = url.absoluteString
        guard Self.isSafeEnvelope(raw),
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "filicon",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }

        let path = components.percentEncodedPath
        guard !path.contains("%"), !Self.hasTraversalComponent(path) else { return nil }

        switch (host, path) {
        case ("conversation", let value):
            guard components.percentEncodedQuery == nil,
                  value.first == "/",
                  value.dropFirst().allSatisfy({ $0 != "/" }),
                  let id = UUID(uuidString: String(value.dropFirst())) else { return nil }
            self = .conversation(id)

        case ("agent", let value):
            guard components.percentEncodedQuery == nil,
                  value.first == "/",
                  value.dropFirst().allSatisfy({ $0 != "/" }),
                  let id = UUID(uuidString: String(value.dropFirst())) else { return nil }
            self = .agent(id)

        case ("shared-room", "/join"):
            guard let query = Self.singleQuery(components.percentEncodedQuery, key: "token"),
                  query.count == 43,
                  query.utf8.allSatisfy(Self.isBase64URLByte) else { return nil }
            self = .sharedRoomJoin(token: query)

        case ("app", "/v1/plugin/add"):
            guard let id = Self.singleQuery(components.percentEncodedQuery, key: "id"),
                  (1...19).contains(id.utf8.count),
                  id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            self = .pluginAdd(id: id)

        case ("app", "/v1/open"):
            guard components.percentEncodedQuery == nil else { return nil }
            self = .open

        case ("app", "/v1/info"):
            guard Self.singleQuery(components.percentEncodedQuery, key: "topic") == "deep-links" else { return nil }
            self = .infoDeepLinks

        default:
            return nil
        }
    }

    public var url: URL {
        switch self {
        case .conversation(let id):
            URL(string: "filicon://conversation/\(id.uuidString)")!
        case .agent(let id):
            URL(string: "filicon://agent/\(id.uuidString)")!
        case .sharedRoomJoin(let token):
            URL(string: "filicon://shared-room/join?token=\(token)")!
        case .pluginAdd(let id):
            URL(string: "filicon://app/v1/plugin/add?id=\(id)")!
        case .open:
            URL(string: "filicon://app/v1/open")!
        case .infoDeepLinks:
            URL(string: "filicon://app/v1/info?topic=deep-links")!
        }
    }

    private static func isSafeEnvelope(_ raw: String) -> Bool {
        guard (1...2_048).contains(raw.utf8.count),
              raw.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }),
              !raw.contains("#"),
              !raw.contains("\\") else { return false }
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "%" {
                guard let first = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex), first < raw.endIndex,
                      let second = raw.index(first, offsetBy: 1, limitedBy: raw.endIndex), second < raw.endIndex,
                      raw[first].isHexDigit, raw[second].isHexDigit else { return false }
                index = raw.index(after: second)
            } else {
                index = raw.index(after: index)
            }
        }
        return true
    }

    private static func hasTraversalComponent(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }

    private static func singleQuery(_ encodedQuery: String?, key: String) -> String? {
        guard let encodedQuery, !encodedQuery.isEmpty, !encodedQuery.contains("%") else { return nil }
        let fields = encodedQuery.split(separator: "&", omittingEmptySubsequences: false)
        guard fields.count == 1 else { return nil }
        let pair = fields[0].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2, pair[0] == Substring(key), !pair[1].isEmpty else { return nil }
        return String(pair[1])
    }

    private static func isBase64URLByte(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) || value == 45 || value == 95
    }

}

public enum DeepLinkDisposition: Equatable, Sendable {
    case rejected
    case duplicate
    case queueFull
    case queued
    case dispatch(FiliconDeepLink)
}

public struct DeepLinkCoordinator: Sendable {
    public static let pendingLimit = 16
    public static let deduplicationWindow: TimeInterval = 2

    private var ready = false
    private var pending: [FiliconDeepLink] = []
    private var recentlyAccepted: [String: Date] = [:]

    public init() {}

    public mutating func handle(_ url: URL, at date: Date = .now) -> DeepLinkDisposition {
        guard let link = FiliconDeepLink(url: url) else { return .rejected }
        prune(at: date)
        let key = link.url.absoluteString
        guard recentlyAccepted[key] == nil, !pending.contains(link) else { return .duplicate }
        guard ready || pending.count < Self.pendingLimit else { return .queueFull }
        recentlyAccepted[key] = date
        if ready { return .dispatch(link) }
        pending.append(link)
        return .queued
    }

    public mutating func markReady() -> [FiliconDeepLink] {
        ready = true
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    public mutating func markNotReady() {
        ready = false
        let pendingKeys = Set(pending.map { $0.url.absoluteString })
        recentlyAccepted = recentlyAccepted.filter { pendingKeys.contains($0.key) }
    }

    private mutating func prune(at date: Date) {
        recentlyAccepted = recentlyAccepted.filter { date.timeIntervalSince($0.value) <= Self.deduplicationWindow }
    }
}
