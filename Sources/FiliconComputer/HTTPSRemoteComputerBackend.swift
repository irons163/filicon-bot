import Foundation

public protocol RemoteHTTPTransport: Sendable {
    func data(for request: URLRequest, exactOrigin: String, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}

private final class ExactOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: String
    init(origin: String) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Authentication headers must never follow redirects. Same-origin redirects are
        // deliberately rejected too: API endpoints are exact and redirects often mean login.
        completionHandler(nil)
    }
}

public struct URLSessionRemoteHTTPTransport: RemoteHTTPTransport {
    public init() {}
    public func data(for request: URLRequest, exactOrigin: String, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let delegate = ExactOriginRedirectDelegate(origin: exactOrigin)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteComputerError.invalidResponse }
        guard let finalURL = http.url, HTTPSRemoteComputerBackend.origin(of: finalURL) == exactOrigin else {
            throw RemoteComputerError.crossOriginRedirect
        }
        guard data.count <= maximumBytes else { throw RemoteComputerError.responseTooLarge(limit: maximumBytes) }
        if (300..<400).contains(http.statusCode) {
            if http.value(forHTTPHeaderField: "Location")?.lowercased().contains("login") == true { throw RemoteComputerError.authenticationRedirect }
            throw RemoteComputerError.crossOriginRedirect
        }
        return (data, http)
    }
}

public struct HTTPSRemoteComputerBackend: RemoteComputerBackend, RemoteTerminalBackend, RemoteFileBackend {
    public static let isolationDeclarationHeader = "X-Filicon-Isolation-Declaration"
    public static let maximumJSONBytes = 1 << 20
    public static let maximumFileBytes = RemoteFileTransfer.defaultMaximumBytes
    public static let maximumEncodedFileEnvelopeBytes = 90 * 1024 * 1024
    public let profile: RemoteComputerProfile
    private let credentials: (any RemoteComputerCredentialResolver)?
    private let transport: any RemoteHTTPTransport
    private let isolationVerifier: RemoteIsolationVerifier
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(profile: RemoteComputerProfile, credentials: (any RemoteComputerCredentialResolver)? = nil, transport: any RemoteHTTPTransport = URLSessionRemoteHTTPTransport(), isolationVerifier: RemoteIsolationVerifier? = nil) {
        self.profile = profile; self.credentials = credentials; self.transport = transport
        self.isolationVerifier = isolationVerifier ?? RemoteIsolationVerifier(policy: profile.isolationPolicy)
    }

    public func securitySnapshot(agentID: String) async -> RemoteSecuritySnapshot {
        await isolationVerifier.snapshot(agentID: agentID)
    }

    public func status(agentID: String) async throws -> RemoteComputerStatus {
        try profile.require(.lifecycle); return try await send("agents/\(try component(agentID))/status", method: "GET")
    }
    public func ensure(agentID: String) async throws -> RemoteComputerStatus {
        try profile.require(.lifecycle); return try await send("agents/\(try component(agentID))/ensure", method: "POST")
    }
    public func recreate(agentID: String, request: RemoteRecreateRequest) async throws -> RemoteOperation {
        try profile.require(request.preserveData ? .update : .recreate)
        return try await send("agents/\(try component(agentID))/recreate", method: "POST", body: request)
    }
    public func operation(agentID: String, operationID: String) async throws -> RemoteOperation {
        try await send("agents/\(try component(agentID))/operations/\(try component(operationID))", method: "GET")
    }
    public func cancel(agentID: String, operationID: String) async throws {
        let _: EmptyResponse = try await send("agents/\(try component(agentID))/operations/\(try component(operationID))/cancel", method: "POST")
    }

    public func start(agentID: String, ownerID: String, request start: RemoteTerminalStart) async throws -> RemoteTerminalSession {
        try profile.require(.terminal)
        return try await send("agents/\(try component(agentID))/terminals", method: "POST", body: TerminalStartEnvelope(ownerID: ownerID, request: start))
    }
    public func input(agentID: String, sessionID: String, data: Data) async throws {
        try profile.require(.terminal)
        guard data.count <= RemoteTerminalController.maximumInputBytes else { throw RemoteComputerError.requestTooLarge(limit: RemoteTerminalController.maximumInputBytes) }
        let _: EmptyResponse = try await send("agents/\(try component(agentID))/terminals/\(try component(sessionID))/input", method: "POST", body: TerminalInputEnvelope(data: data))
    }
    public func resize(agentID: String, sessionID: String, columns: Int, rows: Int) async throws {
        try profile.require(.terminal)
        let _: EmptyResponse = try await send("agents/\(try component(agentID))/terminals/\(try component(sessionID))/resize", method: "POST", body: TerminalResizeEnvelope(columns: columns, rows: rows))
    }
    public func output(agentID: String, sessionID: String, cursor: UInt64, limit: Int) async throws -> RemoteTerminalOutput {
        try profile.require(.terminal)
        guard limit > 0, limit <= RemoteTerminalController.maximumOutputBytes else { throw RemoteComputerError.responseTooLarge(limit: RemoteTerminalController.maximumOutputBytes) }
        return try await send("agents/\(try component(agentID))/terminals/\(try component(sessionID))/output?cursor=\(cursor)&limit=\(limit)", method: "GET")
    }
    public func cancel(agentID: String, sessionID: String) async throws {
        try profile.require(.terminal)
        let _: EmptyResponse = try await send("agents/\(try component(agentID))/terminals/\(try component(sessionID))/cancel", method: "POST")
    }

    public func upload(agentID: String, path: String, data: Data, descriptor: RemoteFileDescriptor) async throws {
        try profile.require(.fileTransfer); try RemoteFileTransfer.validate(path: path)
        guard data.count <= Self.maximumFileBytes,
              descriptor.size == data.count,
              descriptor.sha256.lowercased() == RemoteFileTransfer.sha256(data) else {
            throw RemoteComputerError.integrityMismatch
        }
        let encoded = try encoder.encode(FileUploadEnvelope(path: path, data: data, descriptor: descriptor))
        guard encoded.count <= Self.maximumEncodedFileEnvelopeBytes else {
            throw RemoteComputerError.requestTooLarge(limit: Self.maximumEncodedFileEnvelopeBytes)
        }
        let _: EmptyResponse = try await request(
            "agents/\(try component(agentID))/files/upload", method: "POST", body: encoded
        )
    }
    public func download(agentID: String, path: String, maximumBytes: Int) async throws -> (Data, RemoteFileDescriptor) {
        try profile.require(.fileTransfer); try RemoteFileTransfer.validate(path: path)
        guard maximumBytes > 0, maximumBytes <= Self.maximumFileBytes else {
            throw RemoteComputerError.responseTooLarge(limit: Self.maximumFileBytes)
        }
        let encoded = try encoder.encode(FileDownloadRequest(path: path, maximumBytes: maximumBytes))
        let responseLimit = min(Self.maximumEncodedFileEnvelopeBytes, maximumBytes * 2 + 16_384)
        let envelope: FileDownloadEnvelope = try await request(
            "agents/\(try component(agentID))/files/download", method: "POST", body: encoded,
            maximumResponseBytes: responseLimit
        )
        guard envelope.data.count <= maximumBytes else { throw RemoteComputerError.responseTooLarge(limit: maximumBytes) }
        return (envelope.data, envelope.descriptor)
    }

    public func request<Response: Decodable & Sendable>(_ path: String, method: String, body: Data? = nil, maximumResponseBytes: Int = maximumJSONBytes, contentType: String = "application/json") async throws -> Response {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("#"),
              path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw RemoteComputerError.invalidEndpoint
        }
        guard let url = URL(string: path, relativeTo: profile.endpoint)?.absoluteURL,
              Self.origin(of: url) == Self.origin(of: profile.endpoint) else { throw RemoteComputerError.invalidEndpoint }
        guard let agentID = isolationAgentID(from: path) else { throw RemoteComputerError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let pinned = try await isolationVerifier.expectedBinding(agentID: agentID) {
            request.setValue(pinned.identity, forHTTPHeaderField: "X-Filicon-Expected-Isolation-Identity")
            request.setValue(String(pinned.sessionGeneration), forHTTPHeaderField: "X-Filicon-Expected-Session-Generation")
        }
        if let reference = profile.credentialReference {
            guard let credentials else { throw RemoteComputerError.credentialUnavailable }
            let credential = try await credentials.resolve(reference: reference)
            guard !credential.headerName.isEmpty, credential.headerName.utf8.count <= 128,
                  credential.headerName.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45
                  }), credential.value.utf8.count <= 16_384,
                  credential.value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
                throw RemoteComputerError.credentialUnavailable
            }
            request.setValue(credential.value, forHTTPHeaderField: credential.headerName)
        }
        let (data, response) = try await transport.data(for: request, exactOrigin: Self.origin(of: profile.endpoint)!, maximumBytes: maximumResponseBytes)
        guard response.url.map(Self.origin(of:)) == Self.origin(of: profile.endpoint) else {
            throw RemoteComputerError.crossOriginRedirect
        }
        let declaration = Self.isolationDeclaration(from: response)
        try await isolationVerifier.validate(declaration, agentID: agentID)
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? decoder.decode(ErrorEnvelope.self, from: data))?.message
            throw RemoteComputerError.operationFailed(status: response.statusCode, message: message)
        }
        if Response.self == EmptyResponse.self, data.isEmpty { return EmptyResponse() as! Response }
        do { return try decoder.decode(Response.self, from: data) } catch { throw RemoteComputerError.invalidResponse }
    }

    private func send<Response: Decodable & Sendable, Body: Encodable>(_ path: String, method: String, body: Body) async throws -> Response {
        let data = try encoder.encode(body)
        guard data.count <= Self.maximumJSONBytes else { throw RemoteComputerError.requestTooLarge(limit: Self.maximumJSONBytes) }
        return try await request(path, method: method, body: data)
    }
    private func send<Response: Decodable & Sendable>(_ path: String, method: String) async throws -> Response {
        try await request(path, method: method)
    }
    private func component(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 256,
              let escaped = value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { throw RemoteComputerError.invalidIdentifier }
        return escaped
    }
    private func isolationAgentID(from path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "agents", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }
    private static func isolationDeclaration(from response: HTTPURLResponse) -> RemoteIsolationDeclaration? {
        guard let encoded = response.value(forHTTPHeaderField: isolationDeclarationHeader), encoded.utf8.count <= 16_384,
              let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(RemoteIsolationDeclaration.self, from: data)
    }
    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        return "\(scheme)://\(host)\(url.port == nil || url.port == defaultPort ? "" : ":\(url.port!)")"
    }
}

public struct EmptyResponse: Codable, Sendable { public init() {} }
private struct ErrorEnvelope: Decodable { var message: String? }
private struct TerminalStartEnvelope: Codable { var ownerID: String; var request: RemoteTerminalStart }
private struct TerminalInputEnvelope: Codable { var data: Data }
private struct TerminalResizeEnvelope: Codable { var columns: Int; var rows: Int }
private struct FileUploadEnvelope: Codable { var path: String; var data: Data; var descriptor: RemoteFileDescriptor }
private struct FileDownloadRequest: Codable { var path: String; var maximumBytes: Int }
private struct FileDownloadEnvelope: Codable { var data: Data; var descriptor: RemoteFileDescriptor }
