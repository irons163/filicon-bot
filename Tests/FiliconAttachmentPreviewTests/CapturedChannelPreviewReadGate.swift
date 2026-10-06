import Foundation
import Testing
import FiliconAppServices
import FiliconDomain

/// Intentionally non-cooperative: host authority, not a friendly downloader,
/// must reject a CAS result that arrives after navigation or owner revocation.
actor CapturedChannelPreviewReadGate {
    private var release: CheckedContinuation<Void, Never>?
    private(set) var requests: [AttachmentMetadata] = []
    private(set) var completed = false

    func read(_ metadata: AttachmentMetadata, store: AttachmentStore) async throws -> Data {
        requests.append(metadata)
        await withCheckedContinuation { release = $0 }
        let bytes = try await store.channelPublicationData(for: metadata)
        completed = true
        return bytes
    }

    func waitUntilRequested() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!requests.isEmpty)
    }

    func open() { release?.resume(); release = nil }

    func waitUntilCompleted() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !completed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(completed)
    }
}
