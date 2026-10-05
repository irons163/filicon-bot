import Foundation
import Testing
import CustomDump
import FiliconDomain
@testable import FiliconAppServices
@testable import Filicon

private actor ChannelSourceProbe {
    var events: [String] = []
    var active = true
    func record(_ event: String) { events.append(event) }
    func close() { active = false }
    func validate() throws { if !active { throw CancellationError() } }
}

private struct ChannelSourceDownloader: RemoteAttachmentDownloading {
    let probe: ChannelSourceProbe
    let data: Data
    var mode = "approve"
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        await probe.record("fetch:\(reference.url):\(maximumBytes)")
        if mode == "redirect", reference.url.contains("original") {
            throw RemoteAttachmentDownloadError.redirect("https://second.example/final.txt")
        }
        if mode == "after-fetch" { await probe.close() }
        let returned = mode == "substituted" ? try RemoteAttachmentReference(url: "https://other.example/private") : reference
        // A claimed server MIME must never promote these bytes into a renderer.
        return .init(reference: returned, data: data, declaredMIMEType: "text/html")
    }
}

@Suite("Channel attachment source consent", .timeLimit(.minutes(1)))
struct AgentChannelAttachmentSourceTests {
    private let call = try! NormalizedToolCall(id: "source-test", name: "SendMessage", argumentsJSON: Data("{}".utf8))
    private let context = ToolContext(conversationID: UUID(uuidString: "34000000-0000-0000-0000-000000000001")!,
        runID: UUID(uuidString: "34000000-0000-0000-0000-000000000002")!)

    @Test(arguments: LocalGalleryFormatFixture.publicationFormats, [false, true])
    func formatsUseVerifiedMetadataWithoutInstalling(type: String, isImage: Bool) async throws {
        let probe = ChannelSourceProbe(), bytes = try LocalGalleryFormatFixture.bytes(type: type)
        let filename = LocalGalleryFormatFixture.filename(type: type)
        let file = try PreparedAgentPublicationFile(bytes: bytes, filename: filename)
        let adapter = AgentChannelAttachmentSource(prepareLocal: { _, _, _ in file },
            downloader: ChannelSourceDownloader(probe: probe, data: Data()), validateScope: {},
            authorizeDownload: { _, _, _, _ in Issue.record("Local image must not download") })
        let input = try AgentMessageImageInput(entry: ["url": "file:///approved/\(filename)"])
        let result = try await adapter.prepare(input, isImage: isImage, call: call, context: context)
        expectNoDifference(result, try PreparedAgentChannelAttachment(file: file, mimeType: LocalGalleryFormatFixture.mimeType(type: type)))
        let events = await probe.events
        expectNoDifference(events, [])
    }

    @Test(arguments: ["approve", "deny", "after-fetch", "substituted", "empty", "oversize", "redirect", "redirect-denied", "review-retired"])
    func remoteReadRequiresExactConsentAndCapturedIdentity(mode: String) async throws {
        let probe = ChannelSourceProbe(), original = "https://example.com/original/report.txt?signature=a%2Bb"
        let data = mode == "empty" ? Data() : mode == "oversize" ? Data(count: AgentChannelAttachmentSource.maximumBytes + 1) : Data("Captured report".utf8)
        let transportMode = mode == "redirect-denied" ? "redirect" : mode
        let adapter = AgentChannelAttachmentSource(prepareLocal: { _, _, _ in
            Issue.record("A remote URL must not enter the local reader")
            throw AgentFilePublicationError.unavailable
        }, downloader: ChannelSourceDownloader(probe: probe, data: data, mode: transportMode),
            validateScope: { try await probe.validate() }, authorizeDownload: { reference, from, _, _ in
                await probe.record("review:\(from?.url ?? "initial"):\(reference.url)")
                if mode == "deny" || mode == "redirect-denied" && from != nil { throw CancellationError() }
                if mode == "review-retired" { await probe.close() }
            })
        let input = try AgentMessageImageInput(entry: ["url": original, "alt": "Report description"])
        do {
            let captured = try await adapter.prepare(input, isImage: false, call: call, context: context)
            #expect(["approve", "redirect"].contains(mode))
            expectNoDifference(captured, try PreparedAgentChannelAttachment(file: .init(bytes: data, filename: "report.txt"), mimeType: "text/plain"))
        } catch {
            #expect(!["approve", "redirect"].contains(mode))
            switch mode {
            case "substituted": expectNoDifference(error as? RemoteAttachmentDownloadError, .invalidResponse)
            case "empty": expectNoDifference(error as? RemoteAttachmentDownloadError, .empty)
            case "oversize": expectNoDifference(error as? RemoteAttachmentDownloadError, .tooLarge)
            default: #expect(error is CancellationError)
            }
        }
        var expected = ["review:initial:\(original)"]
        if !["deny", "review-retired"].contains(mode) { expected.append("fetch:\(original):\(AgentChannelAttachmentSource.maximumBytes)") }
        if ["redirect", "redirect-denied"].contains(mode) {
            expected.append("review:\(original):https://second.example/final.txt")
            if mode == "redirect" { expected.append("fetch:https://second.example/final.txt:\(AgentChannelAttachmentSource.maximumBytes)") }
        }
        let events = await probe.events
        expectNoDifference(events, expected)
    }

    @Test(arguments: ["approved", "read-denied", "read-retired", "too-large", "html", "image", "fake-image", "empty"])
    func localCaptureNeverDownloadsOrReopensAfterRead(mode: String) async throws {
        let probe = ChannelSourceProbe()
        let filename = mode == "html" ? "report.html" : mode.contains("image") ? "misleading.bin" : "report.txt"
        let bytes = mode == "image" ? try LocalGalleryFormatFixture.bytes(type: "png")
            : mode == "empty" ? Data() : mode == "too-large" ? Data(count: AgentChannelAttachmentSource.maximumBytes + 1) : Data("Captured local file".utf8)
        let adapter = AgentChannelAttachmentSource(prepareLocal: { url, _, _ in
            await probe.record("read:\(url)")
            if mode == "read-denied" { throw CancellationError() }
            if mode == "read-retired" { await probe.close() }
            return try .init(bytes: bytes, filename: filename)
        }, downloader: ChannelSourceDownloader(probe: probe, data: Data()),
            validateScope: { try await probe.validate() }, authorizeDownload: { _, _, _, _ in
                Issue.record("A local file must not request a download")
            })
        let input = try AgentMessageImageInput(entry: ["url": "file:///approved/\(filename)"])
        do {
            let captured = try await adapter.prepare(input, isImage: mode.contains("image"), call: call, context: context)
            #expect(["approved", "html", "image", "empty"].contains(mode))
            let mime = mode == "html" ? "application/octet-stream" : mode == "image" ? "image/png" : "text/plain"
            expectNoDifference(captured, try PreparedAgentChannelAttachment(file: .init(bytes: bytes, filename: filename), mimeType: mime))
        } catch {
            #expect(!["approved", "html", "image", "empty"].contains(mode))
            if mode == "fake-image" { expectNoDifference(error as? AgentImageError, .galleryInvalid) }
            else if mode == "too-large" { #expect(error is AttachmentStoreError) }
            else { #expect(error is CancellationError) }
        }
        let events = await probe.events
        expectNoDifference(events, ["read:file:///approved/\(filename)"])
    }

    @Test(arguments: ["host-id", "invalid-basename", "retired"])
    func unavailableOrInvalidSourceDoesNotAskOrRead(mode: String) async throws {
        let probe = ChannelSourceProbe()
        if mode == "retired" { await probe.close() }
        let adapter = AgentChannelAttachmentSource(prepareLocal: { _, _, _ in
            await probe.record("read")
            throw AgentFilePublicationError.unavailable
        }, downloader: ChannelSourceDownloader(probe: probe, data: Data("Private".utf8)),
            validateScope: { try await probe.validate() }, authorizeDownload: { _, _, _, _ in await probe.record("review") })
        let input = try AgentMessageImageInput(entry: mode == "host-id" ? ["image_id": "never-export-host-id"]
            : ["url": "https://example.com/" + String(repeating: "x", count: 256)])
        await #expect(throws: (any Error).self) { _ = try await adapter.prepare(input, isImage: false, call: call, context: context) }
        let events = await probe.events
        expectNoDifference(events, [])
    }
}
