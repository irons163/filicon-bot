import Foundation

public protocol SharedRoomAuthTokenResolver: Sendable {
    func token(for reference: String) async throws -> String
}

public struct ClosureSharedRoomAuthTokenResolver: SharedRoomAuthTokenResolver {
    private let body: @Sendable (String) async throws -> String
    public init(_ body: @escaping @Sendable (String) async throws -> String) { self.body = body }
    public func token(for reference: String) async throws -> String { try await body(reference) }
}

private final class ExactOriginDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: String
    init(origin: String) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.exactOrigin == origin ? request : nil)
    }
}

/// Provider-neutral RPC client. A deployment must expose the same request/response
/// contract and enforce the file transport's host/member/generation rules server-side.
public actor HTTPSSharedRoomTransport: SharedRoomTransport {
    public let endpoint: URL
    public let credentialReference: String
    private let resolver: any SharedRoomAuthTokenResolver
    private let session: URLSession

    public init(endpoint: URL, credentialReference: String, resolver: any SharedRoomAuthTokenResolver, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil else { throw SharedRoomError.insecureEndpoint }
        self.endpoint = endpoint; self.credentialReference = credentialReference; self.resolver = resolver
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: ExactOriginDelegate(origin: endpoint.exactOrigin!), delegateQueue: nil)
    }

    public func perform(_ request: SharedRoomRequest) async throws -> SharedRoomResponse {
        let token: String
        do { token = try await resolver.token(for: credentialReference) }
        catch { throw SharedRoomError.authenticationRequired }
        guard !token.isEmpty,
              !token.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) })
        else { throw SharedRoomError.authenticationRequired }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"; urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder.sharedRoomHTTP.encode(request)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: urlRequest) }
        catch { throw SharedRoomError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, http.url?.exactOrigin == endpoint.exactOrigin else { throw SharedRoomError.originMismatch }
        if (300..<400).contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"),
           let redirect = URL(string: location, relativeTo: http.url)?.absoluteURL,
           redirect.exactOrigin != endpoint.exactOrigin {
            throw SharedRoomError.originMismatch
        }
        guard (200..<300).contains(http.statusCode), data.count <= 2 * 1_024 * 1_024 else { throw SharedRoomError.transport("Shared-room server returned HTTP \(http.statusCode).") }
        do { return try JSONDecoder.sharedRoomHTTP.decode(SharedRoomResponse.self, from: data) }
        catch { throw SharedRoomError.malformedReply }
    }
}

private extension URL {
    var exactOrigin: String? {
        guard let scheme = scheme?.lowercased(), let host = host?.lowercased() else { return nil }
        let effectivePort = port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(effectivePort)"
    }
}
private extension JSONEncoder {
    static var sharedRoomHTTP: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
}
private extension JSONDecoder {
    static var sharedRoomHTTP: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
