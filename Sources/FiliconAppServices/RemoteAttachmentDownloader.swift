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
    case tooManyRedirects
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

extension RemoteAttachmentDownloading {
    /// Each new destination requires an explicit caller decision. No approval is cached.
    /// The returned bytes remain bound to the original saved attachment identity.
    public func downloadFollowingReviewedRedirects(
        _ reference: RemoteAttachmentReference, maximumBytes: Int,
        approveRedirect: @Sendable (RemoteAttachmentReference, RemoteAttachmentReference) async throws -> Bool
    ) async throws -> RemoteAttachmentDownload {
        var current = reference
        var visited: Set<String> = [reference.url]
        var redirects = 0
        while true {
            try Task.checkCancellation()
            do {
                let result = try await download(current, maximumBytes: maximumBytes)
                try Task.checkCancellation()
                guard result.reference == current else { throw RemoteAttachmentDownloadError.invalidResponse }
                return RemoteAttachmentDownload(reference: reference, data: result.data,
                    declaredMIMEType: result.declaredMIMEType)
            } catch RemoteAttachmentDownloadError.redirect(let location) {
                guard redirects < 5 else { throw RemoteAttachmentDownloadError.tooManyRedirects }
                guard let location, !location.isEmpty, location.utf8.count <= 16_384,
                      let decoded = location.removingPercentEncoding,
                      !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      !location.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                          || CharacterSet.controlCharacters.contains($0) }),
                      !location.contains("\\"),
                      let base = URL(string: current.url),
                      let destination = URL(string: location, relativeTo: base)?.absoluteURL else {
                    throw RemoteAttachmentDownloadError.invalidResponse
                }
                let next = try RemoteAttachmentReference(url: destination.absoluteString, alt: reference.alt)
                guard visited.insert(next.url).inserted else { throw RemoteAttachmentDownloadError.tooManyRedirects }
                try Task.checkCancellation()
                guard try await approveRedirect(current, next) else { throw CancellationError() }
                try Task.checkCancellation()
                current = next
                redirects += 1
            }
        }
    }
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
