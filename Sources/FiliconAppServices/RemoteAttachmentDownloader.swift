import Foundation
import FiliconDomain

public enum RemoteAttachmentDownloadError: Error, Equatable, Sendable {
    case invalidLimit
    case invalidResponse
    case httpStatus(Int)
    case tooLarge
    case empty
    /// The caller must review the new destination before making another request.
    case redirect(String?)
}

/// Untrusted bytes, not proof of media type or permission to execute the content.
public struct RemoteAttachmentDownload: Sendable {
    public let reference: RemoteAttachmentReference
    public let data: Data
    public let declaredMIMEType: String?
}

public protocol RemoteAttachmentDownloading: Sendable {
    /// Call only after the user requests this exact remote resource.
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload
}

public struct RemoteAttachmentDownloader: RemoteAttachmentDownloading {
    public init() {}

    public func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        try await download(reference, maximumBytes: maximumBytes, configuration: .ephemeral)
    }

    // Internal configuration seam for offline URLProtocol tests, never a shared session.
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int,
                  configuration: URLSessionConfiguration) async throws -> RemoteAttachmentDownload {
        guard maximumBytes > 0, maximumBytes <= 256 * 1_024 * 1_024 else {
            throw RemoteAttachmentDownloadError.invalidLimit
        }
        try Task.checkCancellation()
        guard let url = URL(string: reference.url) else { throw RemoteAttachmentDownloadError.invalidResponse }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = nil
        let session = URLSession(configuration: configuration, delegate: RemoteAttachmentSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url else {
            throw RemoteAttachmentDownloadError.invalidResponse
        }
        if (300..<400).contains(http.statusCode) {
            throw RemoteAttachmentDownloadError.redirect(http.value(forHTTPHeaderField: "Location"))
        }
        guard http.statusCode == 200 else { throw RemoteAttachmentDownloadError.httpStatus(http.statusCode) }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw RemoteAttachmentDownloadError.tooLarge }
        var data = Data()
        // Reserve only a small bounded buffer, never an attacker-provided Content-Length.
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw RemoteAttachmentDownloadError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard !data.isEmpty else { throw RemoteAttachmentDownloadError.empty }
        return RemoteAttachmentDownload(reference: reference, data: data, declaredMIMEType: http.mimeType)
    }
}

private final class RemoteAttachmentSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
