import AVFoundation
import CoreVideo
import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices

@Suite("Remote video preview preparation", .timeLimit(.minutes(1)))
struct RemoteAttachmentVideoPreparationTests {
    @Test func imageContainersDoNotEnterTheVideoPath() {
        for brand in ["heic", "mif1", "avif"] {
            #expect(!RemoteAttachmentVideoPreparation.isCandidate(Data([0, 0, 0, 12]) + Data("ftyp\(brand)".utf8)))
        }
    }

    @Test(arguments: [false, true])
    func validatesSelfContainedVideo(quickTime: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "remote-video-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: quickTime ? "fixture.mov" : "fixture.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: quickTime ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var optionalBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &optionalBuffer) == kCVReturnSuccess)
        let buffer = try #require(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let deadline = ContinuousClock.now + .seconds(5)
        while !input.isReadyForMoreMediaData && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(input.isReadyForMoreMediaData)
        #expect(adaptor.append(buffer, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        expectNoDifference(writer.status, .completed)
        let data = try Data(contentsOf: url)
        #expect(RemoteAttachmentVideoPreparation.isCandidate(data))
        let reference = try RemoteAttachmentReference(url: "https://example.com/wrong.png", alt: "Movie")
        let metadata = try await RemoteAttachmentVideoPreparation.metadata(for: data, reference: reference)
        expectNoDifference(metadata.kind, .video)
        expectNoDifference(metadata.mimeType, quickTime ? "video/quicktime" : "video/mp4")
        expectNoDifference(metadata.byteCount, Int64(data.count))
        expectNoDifference(metadata.altText, "Movie")
    }

    @Test func rejectsPlaylistsAndFakeContainers() async throws {
        let reference = try RemoteAttachmentReference(url: "https://example.com/video.mp4")
        for data in [Data("#EXTM3U\nhttps://other.example/private".utf8), Data([0, 0, 0, 12]) + Data("ftypisom".utf8)] {
            do {
                _ = try await RemoteAttachmentVideoPreparation.metadata(for: data, reference: reference)
                Issue.record("Invalid media unexpectedly accepted")
            } catch {}
        }
    }
}
