import Darwin
import Foundation

public enum EgressPolicyError: Error, Sendable, Equatable {
    case invalidURL
    case schemeDenied
    case hostDenied
    case addressDenied
    case dnsResolutionFailed
    case methodDenied
    case headerDenied(String)
    case bodyTooLarge(limit: Int)
}

public protocol EgressDNSResolver: Sendable {
    func addresses(for host: String) async throws -> [String]
}

public struct SystemEgressDNSResolver: EgressDNSResolver {
    public init() {}
    public func addresses(for host: String) async throws -> [String] {
        try await Task.detached {
            var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0 else { throw EgressPolicyError.dnsResolutionFailed }
            defer { if let result { freeaddrinfo(result) } }
            var values: [String] = []; var node = result
            while let current = node {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
                    values.append(String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self))
                }
                node = current.pointee.ai_next
            }
            return Array(Set(values))
        }.value
    }
}

public struct EgressRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data
    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data = Data()) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}

public struct EgressPolicy: Sendable {
    public static let defaultMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    public static let forbiddenHeaders: Set<String> = ["host", "connection", "proxy-authorization", "proxy-authenticate", "transfer-encoding", "upgrade", "te", "trailer"]
    public var allowedHosts: Set<String>
    public var allowedMethods: Set<String>
    public var maximumHeaderBytes: Int
    public var maximumBodyBytes: Int
    public var allowPrivateAddresses: Bool
    private let resolver: any EgressDNSResolver

    public init(allowedHosts: Set<String>, allowedMethods: Set<String> = defaultMethods, maximumHeaderBytes: Int = 64 * 1024, maximumBodyBytes: Int = 16 * 1024 * 1024, allowPrivateAddresses: Bool = false, resolver: any EgressDNSResolver = SystemEgressDNSResolver()) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() }); self.allowedMethods = Set(allowedMethods.map { $0.uppercased() })
        self.maximumHeaderBytes = maximumHeaderBytes; self.maximumBodyBytes = maximumBodyBytes
        self.allowPrivateAddresses = allowPrivateAddresses; self.resolver = resolver
    }

    public func validate(_ request: EgressRequest) async throws -> [String] {
        guard request.url.scheme?.lowercased() == "https", let host = request.url.host?.lowercased(), request.url.user == nil, request.url.password == nil else { throw EgressPolicyError.invalidURL }
        guard hostAllowed(host) else { throw EgressPolicyError.hostDenied }
        guard allowedMethods.contains(request.method.uppercased()) else { throw EgressPolicyError.methodDenied }
        let headerBytes = request.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 }
        guard headerBytes <= maximumHeaderBytes else { throw EgressPolicyError.headerDenied("headers too large") }
        for (name, value) in request.headers {
            let lowered = name.lowercased()
            guard !Self.forbiddenHeaders.contains(lowered), !name.contains("\n"), !name.contains(":"), !value.contains("\n") else { throw EgressPolicyError.headerDenied(name) }
        }
        guard request.body.count <= maximumBodyBytes else { throw EgressPolicyError.bodyTooLarge(limit: maximumBodyBytes) }
        let addresses: [String]
        if Self.isIPAddress(host) { addresses = [host] } else { addresses = try await resolver.addresses(for: host) }
        guard !addresses.isEmpty else { throw EgressPolicyError.dnsResolutionFailed }
        guard allowPrivateAddresses || addresses.allSatisfy({ !Self.isBlockedAddress($0) }) else { throw EgressPolicyError.addressDenied }
        return addresses
    }

    public func headersForRedirect(_ headers: [String: String], from: URL, to: URL) -> [String: String] {
        guard HTTPSRemoteComputerBackend.origin(of: from) != HTTPSRemoteComputerBackend.origin(of: to) else { return headers }
        return headers.filter { !["authorization", "proxy-authorization", "cookie"].contains($0.key.lowercased()) }
    }

    private func hostAllowed(_ host: String) -> Bool {
        allowedHosts.contains(host) || allowedHosts.contains { pattern in
            pattern.hasPrefix("*.") && host.hasSuffix(String(pattern.dropFirst())) && host.count > pattern.count - 1
        }
    }

    public static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    public static func isBlockedAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let n = UInt32(bigEndian: v4.s_addr), a = UInt8(n >> 24), b = UInt8((n >> 16) & 255), c = UInt8((n >> 8) & 255)
            return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) || (a == 192 && b == 0 && c == 2) || (a == 198 && (b == 18 || b == 19)) || (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113) || a >= 224
        }
        var v6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
            if bytes.allSatisfy({ $0 == 0 }) || bytes[0] == 0xff || (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) || (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) { return true }
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return isBlockedAddress(bytes[12..<16].map(String.init).joined(separator: "."))
            }
            return false
        }
        return true
    }
}
