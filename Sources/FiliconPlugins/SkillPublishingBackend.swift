@preconcurrency import Foundation

public let skillArchiveMaximumFiles = 512
public let skillArchiveMaximumBytes: Int64 = 10 * 1_024 * 1_024
public let skillPublishingResponseMaximumBytes = 1 * 1_024 * 1_024

public enum SkillPublishingBackendError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidCredential
    case unsafeSkill(String)
    case archiveTooLarge
    case tooManyFiles
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Publishing requires a credential-free HTTPS endpoint."
        case .invalidCredential: "The publishing bearer token is missing or invalid."
        case .unsafeSkill(let reason): "The skill cannot be safely published: \(reason)"
        case .archiveTooLarge: "The skill archive is too large to publish."
        case .tooManyFiles: "The skill contains too many files to publish."
        case .invalidResponse: "The publishing service returned an invalid response."
        case .responseTooLarge: "The publishing service response was too large."
        case .httpStatus(let status, let message): message.map { "Publishing service error \(status): \($0)" } ?? "Publishing service error \(status)."
        }
    }
}

/// Produces a deterministic POSIX tar stream. Only bounded, regular,
/// non-symlink files below the supplied root are included.
public struct DeterministicSkillArchive: Sendable {
    public var maximumFiles: Int
    public var maximumBytes: Int64

    public init(maximumFiles: Int = skillArchiveMaximumFiles, maximumBytes: Int64 = skillArchiveMaximumBytes) {
        self.maximumFiles = maximumFiles
        self.maximumBytes = maximumBytes
    }

    public func encode(directory: URL) throws -> Data {
        let root = directory.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw SkillPublishingBackendError.unsafeSkill("the root is not a regular directory")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw SkillPublishingBackendError.unsafeSkill("the directory could not be read") }

        var files: [(path: String, url: URL, size: Int64)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw SkillPublishingBackendError.unsafeSkill("symbolic links are not allowed") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw SkillPublishingBackendError.unsafeSkill("only regular files are allowed") }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty,
                  !relative.hasPrefix("/"),
                  !relative.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
                  !relative.contains("\\"),
                  relative.utf8.count <= 100 else {
                throw SkillPublishingBackendError.unsafeSkill("a file path is unsafe or too long")
            }
            let size = Int64(values.fileSize ?? 0)
            guard size >= 0, size <= maximumBytes else { throw SkillPublishingBackendError.archiveTooLarge }
            files.append((relative, url, size))
            if files.count > maximumFiles { throw SkillPublishingBackendError.tooManyFiles }
        }
        files.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        guard files.contains(where: { $0.path == "SKILL.md" }) else { throw SkillPublishingBackendError.unsafeSkill("SKILL.md is required") }

        var output = Data()
        for file in files {
            let contents = try Data(contentsOf: file.url, options: [.mappedIfSafe])
            guard Int64(contents.count) == file.size else { throw SkillPublishingBackendError.unsafeSkill("a file changed while it was being archived") }
            let padded = ((contents.count + 511) / 512) * 512
            guard Int64(output.count) + 512 + Int64(padded) + 1_024 <= maximumBytes else { throw SkillPublishingBackendError.archiveTooLarge }
            output.append(try header(path: file.path, size: contents.count))
            output.append(contents)
            if padded > contents.count { output.append(Data(repeating: 0, count: padded - contents.count)) }
        }
        output.append(Data(repeating: 0, count: 1_024))
        return output
    }

    private func header(path: String, size: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)
        func put(_ string: String, at offset: Int, length: Int) {
            let source = Array(string.utf8.prefix(length))
            bytes.replaceSubrange(offset..<(offset + source.count), with: source)
        }
        func octal(_ value: Int, at offset: Int, length: Int) {
            let value = String(value, radix: 8)
            put(String(repeating: "0", count: max(0, length - value.count - 1)) + value, at: offset, length: length - 1)
        }
        put(path, at: 0, length: 100)
        octal(0o644, at: 100, length: 8)
        octal(0, at: 108, length: 8); octal(0, at: 116, length: 8)
        octal(size, at: 124, length: 12); octal(0, at: 136, length: 12)
        for index in 148..<156 { bytes[index] = 0x20 }
        bytes[156] = 0x30
        put("ustar\0", at: 257, length: 6); put("00", at: 263, length: 2)
        put("root", at: 265, length: 32); put("root", at: 297, length: 32)
        let checksum = bytes.reduce(0) { $0 + Int($1) }
        let checksumText = String(repeating: "0", count: max(0, 6 - String(checksum, radix: 8).count)) + String(checksum, radix: 8)
        put(checksumText, at: 148, length: 6); bytes[154] = 0; bytes[155] = 0x20
        return Data(bytes)
    }
}

public protocol SkillPublishingHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse)
}

public enum SkillPublishingURLPolicy {
    public static func isValidEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    public static func permitsRedirect(from original: URL, to destination: URL) -> Bool {
        destination.scheme?.lowercased() == "https" && destination.user == nil && destination.password == nil &&
        original.scheme?.lowercased() == destination.scheme?.lowercased() &&
        original.host?.lowercased() == destination.host?.lowercased() &&
        (original.port ?? 443) == (destination.port ?? 443)
    }
}

public struct URLSessionSkillPublishingTransport: SkillPublishingHTTPTransport {
    public init() {}
    public func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let delegate = BoundedSessionDelegate(origin: request.url, maximumBytes: maximumResponseBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await delegate.perform(request, in: session)
    }
}

private final class BoundedSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL?
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    init(origin: URL?, maximumBytes: Int) { self.origin = origin; self.maximumBytes = maximumBytes }

    func perform(_ request: URLRequest, in session: URLSession) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = origin, let destination = request.url,
              SkillPublishingURLPolicy.permitsRedirect(from: original, to: destination) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        if http.expectedContentLength > Int64(maximumBytes) { finish(.failure(SkillPublishingBackendError.responseTooLarge)); completionHandler(.cancel); return }
        lock.lock(); self.response = http; lock.unlock(); completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive newData: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        if data.count + newData.count > maximumBytes {
            lock.unlock(); dataTask.cancel(); finish(.failure(SkillPublishingBackendError.responseTooLarge)); return
        }
        data.append(newData); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let response = self.response; let data = self.data; lock.unlock()
        guard let response else { finish(.failure(SkillPublishingBackendError.invalidResponse)); return }
        finish(.success((data, response)))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
}

public actor HTTPSSkillPublishingBackend: SkillPublishingBackend {
    public nonisolated var requiresLocalInstallationConfirmation: Bool { false }
    public let endpoint: URL
    private let bearerToken: String
    private let transport: any SkillPublishingHTTPTransport
    private let archive: DeterministicSkillArchive
    private let timeout: TimeInterval

    public init(endpoint: URL, bearerToken: String, timeout: TimeInterval = 60, transport: any SkillPublishingHTTPTransport = URLSessionSkillPublishingTransport(), archive: DeterministicSkillArchive = .init()) throws {
        guard SkillPublishingURLPolicy.isValidEndpoint(endpoint) else { throw SkillPublishingBackendError.invalidEndpoint }
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 8_192,
              !token.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw SkillPublishingBackendError.invalidCredential
        }
        self.endpoint = endpoint; self.bearerToken = token; self.timeout = min(max(timeout, 1), 120)
        self.transport = transport; self.archive = archive
    }

    public func listTargets() async throws -> [SkillPublishTarget] {
        let response: TargetsResponse = try await request(path: "targets", method: "GET", body: Optional<String>.none)
        var seen = Set<String>()
        for target in response.targets {
            guard Self.validOpaqueID(target.id), !target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  target.name.count <= 256, seen.insert(target.id).inserted else { throw SkillPublishingBackendError.invalidResponse }
        }
        return response.targets
    }

    public func publish(skillDirectory: URL, name: String, description: String, targetID: String, existingPluginID: String?) async throws -> PublishedSkillReceipt {
        let payload = PublishRequest(targetID: targetID, existingPluginID: existingPluginID, name: name, description: description, archiveFormat: "tar", archiveBase64: try archive.encode(directory: skillDirectory).base64EncodedString())
        let receipt: PublishedSkillReceipt = try await request(path: "skills/publish", method: "POST", body: payload)
        guard Self.validOpaqueID(receipt.pluginID), Self.validOpaqueID(receipt.version) else { throw SkillPublishingBackendError.invalidResponse }
        return receipt
    }

    public func unpublish(pluginID: String, targetID: String) async throws {
        let _: EmptyResponse = try await request(path: "skills/unpublish", method: "POST", body: UnpublishRequest(pluginID: pluginID, targetID: targetID))
    }

    private func request<Body: Encodable, Response: Decodable>(path: String, method: String, body: Body?) async throws -> Response {
        let url = endpoint.appending(path: path)
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == endpoint.host?.lowercased(), (url.port ?? 443) == (endpoint.port ?? 443) else {
            throw SkillPublishingBackendError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport.send(request, maximumResponseBytes: skillPublishingResponseMaximumBytes)
        guard response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == endpoint.host?.lowercased(),
              (response.url?.port ?? 443) == (endpoint.port ?? 443) else { throw SkillPublishingBackendError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            throw SkillPublishingBackendError.httpStatus(response.statusCode, message.map { String($0.prefix(1_000)) })
        }
        if Response.self == EmptyResponse.self, data.isEmpty { return EmptyResponse() as! Response }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw SkillPublishingBackendError.invalidResponse }
    }

    private struct TargetsResponse: Codable { var targets: [SkillPublishTarget] }
    private struct PublishRequest: Codable { var targetID: String; var existingPluginID: String?; var name: String; var description: String; var archiveFormat: String; var archiveBase64: String }
    private struct UnpublishRequest: Codable { var pluginID: String; var targetID: String }
    private struct EmptyResponse: Codable {}
    private struct ErrorResponse: Codable { var error: String }

    private static func validOpaqueID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
