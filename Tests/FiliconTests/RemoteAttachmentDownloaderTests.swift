import Foundation
import Testing
import CustomDump
import FiliconDomain
@testable import FiliconAppServices

private final class RemoteDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let mode = url.lastPathComponent
        if mode == "cancelled" { Issue.record("Cancelled download must not start a request") }
        let status = mode == "status" ? 403 : mode == "redirect" ? 302 : 200
        var headers = ["Content-Type": "image/png"]
        if mode == "declared-large" { headers["Content-Length"] = "9999999999" }
        if mode == "redirect" { headers["Location"] = "https://other.example/private" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode != "empty" { client?.urlProtocol(self, didLoad: Data(repeating: 7, count: mode == "stream-large" ? 33 : 32)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Bounded remote attachment download")
struct RemoteAttachmentDownloaderTests {
    @Test func cancelledDownloadDoesNotStartNetworkWork() async throws {
        let reference = try RemoteAttachmentReference(url: "https://example.com/cancelled")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RemoteDownloadProtocol.self]
            do {
                _ = try await RemoteAttachmentDownloader().download(reference, maximumBytes: 32, configuration: configuration)
                Issue.record("Cancelled download unexpectedly succeeded")
            } catch is CancellationError {
                // Expected before URLSession construction.
            }
        }
        try await task.value
    }

    @Test(arguments: ["valid", "status", "redirect", "declared-large", "stream-large", "empty", "limit"])
    func offlineTransportHonorsBounds(mode: String) async throws {
        let reference = try RemoteAttachmentReference(url: "https://example.com/\(mode)", alt: "Untrusted media")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteDownloadProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "must-not-leak", "Cookie": "must-not-leak"]
        do {
            let result = try await RemoteAttachmentDownloader().download(reference, maximumBytes: mode == "limit" ? 0 : 32,
                                                                         configuration: configuration)
            expectNoDifference(mode, "valid")
            expectNoDifference(result.reference, reference)
            expectNoDifference(result.data, Data(repeating: 7, count: 32))
            expectNoDifference(result.declaredMIMEType, "image/png")
        } catch let error as RemoteAttachmentDownloadError {
            let expected: RemoteAttachmentDownloadError = switch mode {
            case "status": .httpStatus(403)
            case "redirect": .redirect("https://other.example/private")
            case "declared-large", "stream-large": .tooLarge
            case "empty": .empty
            case "limit": .invalidLimit
            default: .invalidResponse
            }
            #expect(mode != "valid")
            expectNoDifference(error, expected)
        }
    }
}
