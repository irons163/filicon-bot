import Foundation

public enum SafeLinkError: Error, Sendable, Equatable {
    case invalidURL, invalidPolicy, forbiddenHost, resolutionFailed, addressPinningUnavailable, connectedAddressMismatch
    case redirectMissingLocation, redirectLimit, redirectDowngrade, responseTooLarge, unsupportedContentType
    case transportFailure, timeout, cancelled, malformedResponse
}

public struct ResolvedAddress: Sendable, Hashable {
    public enum Family: Sendable, Hashable { case ipv4, ipv6 }
    public let family: Family
    public let bytes: [UInt8]
    public init(family: Family, bytes: [UInt8]) { self.family = family; self.bytes = bytes }
}

public protocol SafeLinkResolving: Sendable {
    func resolve(host: String) async throws -> [ResolvedAddress]
}

public struct SafeLinkRequest: Sendable, Equatable {
    public let url: URL
    /// The transport must connect to one of these addresses while preserving the URL host for Host/SNI.
    public let approvedAddresses: [ResolvedAddress]
    public let maximumBodyBytes: Int
    public init(url: URL, approvedAddresses: [ResolvedAddress], maximumBodyBytes: Int) {
        self.url = url; self.approvedAddresses = approvedAddresses; self.maximumBodyBytes = maximumBodyBytes
    }
}

public struct SafeLinkResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    /// The actual peer address used for the request, reported by a pinning transport.
    public let connectedAddress: ResolvedAddress
    public init(statusCode: Int, headers: [String: String], body: Data, connectedAddress: ResolvedAddress) {
        self.statusCode = statusCode; self.headers = headers; self.body = body; self.connectedAddress = connectedAddress
    }
}

public protocol SafeLinkTransporting: Sendable {
    /// Must be false for ordinary URLSession implementations that cannot bind DNS resolution to the connection.
    var supportsAddressPinning: Bool { get }
    func send(_ request: SafeLinkRequest) async throws -> SafeLinkResponse
}

public struct SafeLinkMetadata: Sendable, Equatable {
    public let url: URL
    public let title: String
    public let summary: String?
    public let imageURL: URL?
    public init(url: URL, title: String, summary: String? = nil, imageURL: URL? = nil) {
        self.url = url; self.title = title; self.summary = summary; self.imageURL = imageURL
    }
}

public struct SafeLinkPolicy: Sendable, Equatable {
    public var maximumRedirects = 4
    public var maximumBodyBytes = 512 * 1024
    public var maximumImageURLBytes = 2_048
    public var maximumTitleCharacters = 300
    public var maximumSummaryCharacters = 1_000
    public var cacheLifetime: TimeInterval = 300
    public var retryCount = 1
    public init() {}
}

public actor SafeLinkMetadataClient {
    private struct Entry: Sendable { let value: SafeLinkMetadata; let expires: Date }
    private let resolver: any SafeLinkResolving
    private let transport: any SafeLinkTransporting
    private let policy: SafeLinkPolicy
    private let now: @Sendable () -> Date
    private var cache: [String: Entry] = [:]
    private var generations: [String: UInt64] = [:]

    public init(resolver: any SafeLinkResolving, transport: any SafeLinkTransporting, policy: SafeLinkPolicy = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.resolver = resolver; self.transport = transport; self.policy = policy; self.now = now
    }

    public func metadata(for input: URL, forceRefresh: Bool = false) async throws -> SafeLinkMetadata {
        guard policy.maximumRedirects >= 0, policy.maximumBodyBytes > 0, policy.maximumImageURLBytes > 0,
              policy.maximumTitleCharacters > 0, policy.maximumSummaryCharacters >= 0,
              policy.cacheLifetime >= 0, policy.retryCount >= 0 else { throw SafeLinkError.invalidPolicy }
        let initial = try Self.validatedURL(input)
        let key = Self.cacheKey(initial)
        if !forceRefresh, let entry = cache[key], entry.expires > now() { return entry.value }
        let generation = (generations[key] ?? 0) &+ 1; generations[key] = generation
        let value = try await fetch(initial)
        // An older, slower fetch may return to the actor after a forced refresh. It never overwrites it.
        if generations[key] == generation { cache[key] = Entry(value: value, expires: now().addingTimeInterval(policy.cacheLifetime)) }
        return value
    }

    public func invalidate(_ url: URL) {
        guard let validated = try? Self.validatedURL(url) else { return }
        let key = Self.cacheKey(validated); cache[key] = nil; generations[key] = (generations[key] ?? 0) &+ 1
    }

    private func fetch(_ initial: URL) async throws -> SafeLinkMetadata {
        guard transport.supportsAddressPinning else { throw SafeLinkError.addressPinningUnavailable }
        var current = initial
        for redirect in 0...policy.maximumRedirects {
            let addresses = try await approvedAddresses(for: current)
            var response: SafeLinkResponse?
            for attempt in 0...policy.retryCount {
                do { response = try await transport.send(.init(url: current, approvedAddresses: addresses, maximumBodyBytes: policy.maximumBodyBytes)); break }
                catch is CancellationError { throw SafeLinkError.cancelled }
                catch let error as SafeLinkError {
                    if error != .transportFailure && error != .timeout { throw error }
                    if attempt == policy.retryCount { throw error }
                }
                catch { if attempt == policy.retryCount { throw SafeLinkError.transportFailure } }
            }
            guard let response else { throw SafeLinkError.transportFailure }
            guard addresses.contains(response.connectedAddress) else { throw SafeLinkError.connectedAddressMismatch }
            if let declared = header("content-length", response.headers)?.trimmingCharacters(in: .whitespaces),
               let length = Int(declared), length > policy.maximumBodyBytes { throw SafeLinkError.responseTooLarge }
            guard response.body.count <= policy.maximumBodyBytes else { throw SafeLinkError.responseTooLarge }
            if (300..<400).contains(response.statusCode) {
                guard redirect < policy.maximumRedirects else { throw SafeLinkError.redirectLimit }
                guard let location = header("location", response.headers), let target = URL(string: location, relativeTo: current)?.absoluteURL else { throw SafeLinkError.redirectMissingLocation }
                if current.scheme?.lowercased() == "https", target.scheme?.lowercased() != "https" { throw SafeLinkError.redirectDowngrade }
                let next = try Self.validatedURL(target)
                current = next; continue
            }
            guard (200..<300).contains(response.statusCode) else { throw SafeLinkError.malformedResponse }
            let contentType = header("content-type", response.headers)?.lowercased() ?? ""
            guard contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "text/html" else { throw SafeLinkError.unsupportedContentType }
            guard let html = String(data: response.body, encoding: .utf8) else { throw SafeLinkError.malformedResponse }
            return try await parse(html: html, pageURL: current)
        }
        throw SafeLinkError.redirectLimit
    }

    private func parse(html: String, pageURL: URL) async throws -> SafeLinkMetadata {
        func content(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return Self.sanitizeHTMLText(String(html[range]))
        }
        let title = content(#"<meta\s+[^>]*(?:property|name)\s*=\s*["'](?:og:title|twitter:title)["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*>"#)
            ?? content(#"<meta\s+[^>]*content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["'](?:og:title|twitter:title)["'][^>]*>"#)
            ?? content(#"<title[^>]*>(.*?)</title>"#) ?? pageURL.host ?? pageURL.absoluteString
        let summary = content(#"<meta\s+[^>]*(?:property|name)\s*=\s*["'](?:og:description|twitter:description|description)["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*>"#)
            ?? content(#"<meta\s+[^>]*content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["'](?:og:description|twitter:description|description)["'][^>]*>"#)
        var imageURL: URL?
        if let image = content(#"<meta\s+[^>]*(?:property|name)\s*=\s*["'](?:og:image|twitter:image)["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*>"#)
            ?? content(#"<meta\s+[^>]*content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["'](?:og:image|twitter:image)["'][^>]*>"#),
           image.utf8.count <= policy.maximumImageURLBytes,
           let candidate = URL(string: image, relativeTo: pageURL)?.absoluteURL,
           let validated = try? Self.validatedURL(candidate), (try? await approvedAddresses(for: validated).isEmpty) == false { imageURL = validated }
        return SafeLinkMetadata(url: pageURL, title: String(title.prefix(policy.maximumTitleCharacters)), summary: summary.map { String($0.prefix(policy.maximumSummaryCharacters)) }, imageURL: imageURL)
    }

    private func approvedAddresses(for url: URL) async throws -> [ResolvedAddress] {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { throw SafeLinkError.invalidURL }
        let canonicalHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let forbiddenSuffixes = [".localhost", ".local", ".internal", ".lan", ".home", ".corp", ".cluster", ".svc", ".arpa", ".onion"]
        if canonicalHost == "localhost" || forbiddenSuffixes.contains(where: { canonicalHost == String($0.dropFirst()) || canonicalHost.hasSuffix($0) }) {
            throw SafeLinkError.forbiddenHost
        }
        let resolved: [ResolvedAddress]
        if let literal = Self.parseIPAddress(canonicalHost) { resolved = [literal] }
        else if canonicalHost.contains(".") {
            do { resolved = try await resolver.resolve(host: canonicalHost) }
            catch is CancellationError { throw SafeLinkError.cancelled }
            catch let error as SafeLinkError where error == .timeout || error == .cancelled { throw error }
            catch { throw SafeLinkError.resolutionFailed }
        } else { throw SafeLinkError.forbiddenHost }
        guard !resolved.isEmpty, resolved.allSatisfy(Self.isPublic) else { throw SafeLinkError.forbiddenHost }
        var seen = Set<ResolvedAddress>()
        return resolved.filter { seen.insert($0).inserted }
    }

    private static func validatedURL(_ url: URL) throws -> URL {
        guard url.absoluteString.utf8.count <= 2_048,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased(),
              scheme == "https", components.host?.isEmpty == false, components.user == nil, components.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true,
              !url.absoluteString.contains("\\"), !url.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw SafeLinkError.invalidURL }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil // Fragments are client-side state and must never reach the transport.
        guard let normalized = components.url else { throw SafeLinkError.invalidURL }
        return normalized
    }

    private static func cacheKey(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!; c.fragment = nil; c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased()
        return c.string ?? url.absoluteString
    }

    private func header(_ name: String, _ headers: [String: String]) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }

    private static func sanitizeHTMLText(_ value: String) -> String {
        let entities = value.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        let withoutTags = entities.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        return withoutTags.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func parseIPAddress(_ host: String) -> ResolvedAddress? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return .init(family: .ipv4, bytes: withUnsafeBytes(of: v4.s_addr) { Array($0) }) }
        let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if inet_pton(AF_INET6, unbracketed, &v6) == 1 { return .init(family: .ipv6, bytes: withUnsafeBytes(of: v6) { Array($0) }) }
        return nil
    }

    public static func isPublic(_ address: ResolvedAddress) -> Bool {
        let b = address.bytes
        switch address.family {
        case .ipv4:
            guard b.count == 4 else { return false }
            if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return false }
            if b[0] == 100 && (64...127).contains(b[1]) { return false }
            if b[0] == 169 && b[1] == 254 { return false }
            if b[0] == 172 && (16...31).contains(b[1]) { return false }
            if b[0] == 192 && b[1] == 168 { return false }
            if b[0] == 192 && b[1] == 0 { return false }
            if b[0] == 192 && b[1] == 88 && b[2] == 99 { return false }
            if b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100) { return false }
            if b[0] == 203 && b[1] == 0 && b[2] == 113 { return false }
            return true
        case .ipv6:
            guard b.count == 16 else { return false }
            if b.allSatisfy({ $0 == 0 }) || b.dropLast().allSatisfy({ $0 == 0 }) && b.last == 1 { return false }
            if b[0] == 0xff || b[0] & 0xfe == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0 == 0x80 || b[1] & 0xc0 == 0xc0)) { return false }
            if Array(b.prefix(12)) == Array(repeating: 0, count: 10) + [0xff, 0xff] { return isPublic(.init(family: .ipv4, bytes: Array(b.suffix(4)))) }
            // IPv4-compatible, NAT64 and 6to4 addresses can otherwise tunnel to a private IPv4 peer.
            if b.prefix(12).allSatisfy({ $0 == 0 }) { return false }
            if Array(b.prefix(12)) == [0x00,0x64,0xff,0x9b,0,0,0,0,0,0,0,0] || Array(b.prefix(6)) == [0x00,0x64,0xff,0x9b,0x00,0x01] { return false }
            if b[0] == 0x20 && b[1] == 0x02 { return false }
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false }
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0 && b[3] & 0xe0 == 0x20 { return false } // ORCHID/ORCHIDv2
            if b[0] == 0x3f && b[1] == 0xff && b[2] & 0xf0 == 0 { return false } // documentation 3fff::/20
            if b[0] == 0x01 && b.dropFirst().prefix(7).allSatisfy({ $0 == 0 }) { return false } // 100::/64 discard-only
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x02 { return false }
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00 { return false } // Teredo and IETF protocol assignments
            return true
        }
    }
}
