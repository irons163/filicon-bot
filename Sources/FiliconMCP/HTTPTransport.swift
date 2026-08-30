import Foundation

public struct MCPHTTPResponse: @unchecked Sendable {
    public let data: Data
    public let response: HTTPURLResponse
    public init(data: Data, response: HTTPURLResponse) { self.data = data; self.response = response }
}

public protocol MCPHTTPDataLoading: Sendable {
    func load(_ request: URLRequest) async throws -> MCPHTTPResponse
}

private final class SecureSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.currentRequest?.url, let to = request.url,
              MCPHTTPTransport.sameOrigin(from, to),
              !(from.scheme?.lowercased() == "https" && to.scheme?.lowercased() != "https") else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

public final class MCPSecureURLSessionLoader: MCPHTTPDataLoading, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration, delegate: SecureSessionDelegate(), delegateQueue: nil)
    }
    public func load(_ request: URLRequest) async throws -> MCPHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MCPError.unavailable("MCP returned a non-HTTP response.") }
        return MCPHTTPResponse(data: data, response: response)
    }
}

public actor MCPHTTPTransport: MCPTransport {
    public static let maximumResponseBytes = 4 * 1_024 * 1_024
    private let endpoint: URL
    private let headerReferences: [String: String]
    private let resolver: MCPSecretResolver
    private let loader: any MCPHTTPDataLoading
    private let legacy: Bool
    private var sessionID: String?
    private var closed = false

    public init(endpoint: URL, headerReferences: [String: String] = [:], legacy: Bool = false,
                secretResolver: @escaping MCPSecretResolver = { _ in throw MCPError.unavailable("Secret resolver is not configured.") },
                loader: any MCPHTTPDataLoading = MCPSecureURLSessionLoader()) throws {
        guard MCPServerConfig.isSecureEndpoint(endpoint) else { throw MCPError.insecureEndpoint }
        self.endpoint = endpoint; self.headerReferences = headerReferences; self.legacy = legacy
        self.resolver = secretResolver; self.loader = loader
    }

    public func request(_ rpc: MCPRPCRequest, timeout: Duration = .seconds(30)) async throws -> MCPRPCResponse {
        guard !closed else { throw MCPError.unavailable("MCP transport is closed.") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try encodeLine(rpc)
        request.timeoutInterval = max(0.1, Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(legacy ? MCPProtocol.legacy : MCPProtocol.current, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(rpc.method, forHTTPHeaderField: "Mcp-Method")
        if let name = rpc.params?.objectValue?["name"]?.stringValue { request.setValue(Self.headerSafe(name), forHTTPHeaderField: "Mcp-Name") }
        if legacy, let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        for (header, reference) in headerReferences { request.setValue(try Self.safeHeaderValue(await resolver(reference)), forHTTPHeaderField: header) }
        let loaded: MCPHTTPResponse
        do { loaded = try await loader.load(request) }
        catch is CancellationError { throw MCPError.cancelled }
        guard let finalURL = loaded.response.url, Self.sameOrigin(endpoint, finalURL),
              !(endpoint.scheme == "https" && finalURL.scheme != "https") else { throw MCPError.unsafeRedirect }
        guard loaded.data.count <= Self.maximumResponseBytes else { throw MCPError.outputLimitExceeded }
        guard (200..<300).contains(loaded.response.statusCode) else { throw MCPError.http(status: loaded.response.statusCode) }
        if legacy, let value = loaded.response.value(forHTTPHeaderField: "MCP-Session-Id"), value.count <= 1_024 { sessionID = value }
        let contentType = loaded.response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let payload: Data
        if contentType.contains("application/json") { payload = loaded.data }
        else if contentType.contains("text/event-stream") { payload = try Self.finalSSEData(loaded.data) }
        else { throw MCPError.invalidContentType(contentType) }
        let response: MCPRPCResponse
        do { response = try JSONDecoder().decode(MCPRPCResponse.self, from: payload) }
        catch { throw MCPError.malformedMessage(error.localizedDescription) }
        guard response.jsonrpc == "2.0", response.id == rpc.id,
              (response.result == nil) != (response.error == nil) else { throw MCPError.mismatchedResponse }
        return response
    }

    public func notify(_ notification: MCPRPCNotification) async throws {
        guard !closed else { throw MCPError.unavailable("MCP transport is closed.") }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.httpBody = try encodeLine(notification)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(legacy ? MCPProtocol.legacy : MCPProtocol.current, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(notification.method, forHTTPHeaderField: "Mcp-Method")
        if legacy, let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        for (header, reference) in headerReferences { request.setValue(try Self.safeHeaderValue(await resolver(reference)), forHTTPHeaderField: header) }
        let loaded: MCPHTTPResponse
        do { loaded = try await loader.load(request) }
        catch is CancellationError { throw MCPError.cancelled }
        guard let finalURL = loaded.response.url, Self.sameOrigin(endpoint, finalURL),
              !(endpoint.scheme == "https" && finalURL.scheme != "https") else { throw MCPError.unsafeRedirect }
        guard loaded.data.count <= Self.maximumResponseBytes else { throw MCPError.outputLimitExceeded }
        guard (200..<300).contains(loaded.response.statusCode) else { throw MCPError.http(status: loaded.response.statusCode) }
    }

    public func close() async { closed = true; sessionID = nil }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased() && lhs.portOrDefault == rhs.portOrDefault
    }
    private static func headerSafe(_ value: String) -> String { String(value.unicodeScalars.filter { !$0.properties.isWhitespace && $0.value >= 0x21 && $0.value <= 0x7E }.prefix(512)) }
    private static func safeHeaderValue(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 8_192,
              value.unicodeScalars.allSatisfy({ $0.value == 0x09 || ($0.value >= 0x20 && $0.value <= 0x7e) }) else {
            throw MCPError.invalidConfiguration("Resolved MCP header value is invalid.")
        }
        return value
    }
    static func finalSSEData(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw MCPError.malformedMessage("SSE was not UTF-8") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var candidates: [String] = [], fields: [String] = []
        func finish() { if !fields.isEmpty { candidates.append(fields.joined(separator: "\n")); fields.removeAll() } }
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { finish(); continue }
            if line.first == ":" { continue }
            if line == "data" { fields.append(""); continue }
            if line.hasPrefix("data:") { fields.append(String(line.dropFirst(5)).drop(while: { $0 == " " }).description) }
        }
        finish()
        guard let last = candidates.last, let value = last.data(using: .utf8), value.count <= maximumResponseBytes else { throw MCPError.malformedMessage("SSE contained no bounded data event") }
        return value
    }
}

private extension URL {
    var portOrDefault: Int? { port ?? (scheme?.lowercased() == "https" ? 443 : scheme?.lowercased() == "http" ? 80 : nil) }
}
