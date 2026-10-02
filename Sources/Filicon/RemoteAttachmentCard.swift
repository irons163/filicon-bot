import SwiftUI
import FiliconAgents
import FiliconDomain
import FiliconAppServices
import ImageIO
import Observation

typealias RemoteRedirectReview = @MainActor @Sendable (RemoteAttachmentReference, RemoteAttachmentReference) async throws -> Bool
typealias RemotePreviewAction = (@escaping RemoteRedirectReview) async throws -> Void
typealias RemoteGalleryPreview = RemoteAttachmentImagePreparation.InlinePreview
typealias RemoteThumbnailAction = (@escaping RemoteRedirectReview) async throws -> RemoteGalleryPreview

/// PNG frames were prepared off-main after validating every original frame.
/// Decode only those bounded thumbnails, never the downloaded original here.
struct RemoteGalleryDisplay {
    let preview: RemoteGalleryPreview
    let images: [CGImage]

    init(preview: RemoteGalleryPreview) throws {
        self.preview = preview
        images = try preview.frames.map { frame in
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(frame.data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == frame.width, image.height == frame.height else {
                throw AttachmentPreviewError.integrityMismatch
            }
            return image
        }
    }
}

struct RemoteGalleryFrameView: View {
    let display: RemoteGalleryDisplay
    let elapsed: TimeInterval
    var paused = false

    var body: some View {
        Image(decorative: display.images[paused ? 0 : display.preview.frameIndex(at: elapsed)], scale: 1)
            .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 240)
            .accessibilityLabel(display.preview.original.altText ?? l10n("Image"))
            .accessibilityIdentifier("remote-gallery-thumbnail")
    }
}

/// Avoid a permanent 60-Hz timer for slow, still or completed images. The lazy
/// sequence schedules only the next boundary, not all loops in advance.
struct RemoteGalleryTimeline: TimelineSchedule {
    let preview: RemoteGalleryPreview
    let startedAt: Date

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        AnySequence(sequence(first: startDate) { date in
            // Date has sub-microsecond representation error at a boundary.
            guard let next = preview.nextFrameTime(after: date.timeIntervalSince(startedAt) + 0.000_001) else { return nil }
            return startedAt.addingTimeInterval(next)
        })
    }
}

struct RemoteGalleryAnimationView: View {
    let display: RemoteGalleryDisplay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt: Date?

    var body: some View {
        RemoteGalleryPlaybackView(display: display, startedAt: startedAt, reduceMotion: reduceMotion,
            isActive: scenePhase == .active)
            .onAppear { startedAt = Date() }
            .onDisappear { startedAt = nil }
    }
}

struct RemoteGalleryPlaybackView: View {
    let display: RemoteGalleryDisplay
    let startedAt: Date?
    let reduceMotion: Bool
    let isActive: Bool

    var body: some View {
        Group {
            if display.preview.isAnimated, !reduceMotion, isActive, let startedAt {
                TimelineView(RemoteGalleryTimeline(preview: display.preview, startedAt: startedAt)) { context in
                    RemoteGalleryFrameView(display: display, elapsed: context.date.timeIntervalSince(startedAt) + 0.000_001)
                }
            } else {
                RemoteGalleryFrameView(display: display, elapsed: 0, paused: true)
            }
        }
    }
}

@MainActor @Observable final class RemoteGalleryCardModel {
    struct State: Equatable {
        var isLoading = false
        var previewFailed = false
        var preview: RemoteGalleryPreview?
    }

    private(set) var state = State()
    private(set) var display: RemoteGalleryDisplay?
    @ObservationIgnored private var generation: UInt64 = 0

    func previewButtonTapped(onThumbnail: RemoteThumbnailAction?, onPreview: RemotePreviewAction?,
                             approveRedirect: @escaping RemoteRedirectReview) async {
        generation &+= 1
        let expected = generation
        state = State(isLoading: true)
        display = nil
        defer { if generation == expected { state.isLoading = false } }
        do {
            if let onThumbnail {
                let preview = try await onThumbnail(approveRedirect)
                try Task.checkCancellation()
                guard generation == expected else { return }
                let prepared = try RemoteGalleryDisplay(preview: preview)
                state.preview = preview
                display = prepared
            } else if let onPreview {
                try await onPreview(approveRedirect)
            }
        } catch is CancellationError {
        } catch {
            if generation == expected, !Task.isCancelled { state.previewFailed = true }
        }
    }

    func cancelButtonTapped() {
        generation &+= 1
        state = State()
        display = nil
    }
}

struct RemoteGalleryThumbnailView: View {
    let image: NSImage
    let alt: String?

    var body: some View {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            Image(decorative: cgImage, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 240)
                .accessibilityLabel(alt ?? l10n("Image"))
                .accessibilityIdentifier("remote-gallery-thumbnail")
        }
    }
}

/// Ordered saved image locators. Rendering never starts a network request.
struct RemoteImageGalleryView: View {
    let gallery: RemoteImageGallery
    var onPreview: ((RemoteAttachmentReference, @escaping RemoteRedirectReview) async throws -> Void)?
    var onThumbnail: ((RemoteAttachmentReference, @escaping RemoteRedirectReview) async throws -> RemoteGalleryPreview)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(Array(gallery.images.enumerated()), id: \.offset) { index, reference in
                RemoteAttachmentCard(reference: reference,
                    onPreview: onPreview.map { action in { review in try await action(reference, review) } }, isImage: true,
                    onThumbnail: onThumbnail.map { action in { review in try await action(reference, review) } })
                    .accessibilityIdentifier("remote-gallery-image-\(index)")
            }
        }
        .accessibilityIdentifier("remote-image-gallery")
    }
}

/// Renders persisted local image blobs and remote locators in the exact order
/// that was approved. Legacy messages without layout keep their prior display.
struct OrderedImageGalleryView: View {
    let layout: ImageGalleryLayout?
    let images: [AttachmentMetadata]
    let remoteGallery: RemoteImageGallery?
    var onPreview: ((RemoteAttachmentReference, @escaping RemoteRedirectReview) async throws -> Void)?
    var onThumbnail: ((RemoteAttachmentReference, @escaping RemoteRedirectReview) async throws -> RemoteGalleryPreview)?

    var body: some View {
        Group {
            if let layout, let resolved = layout.resolvedItems(attachments: images, remoteGallery: remoteGallery) {
                OrderedImageGalleryLayout(items: layout.items) { index, _ in
                    let item = resolved[index]
                    switch item {
                    case let .attachment(image, localIndex):
                        AgentMessageImagePreviews(images: [image], compact: true,
                            expandsSingleImage: layout.items.count == 1, viewingGallery: images,
                            viewingGalleryIndex: localIndex)
                    case let .remote(reference):
                        RemoteAttachmentCard(reference: reference,
                            onPreview: onPreview.map { action in { review in try await action(reference, review) } },
                            isImage: true,
                            onThumbnail: onThumbnail.map { action in { review in try await action(reference, review) } })
                    }
                }
            } else {
                if let remoteGallery {
                    RemoteImageGalleryView(gallery: remoteGallery, onPreview: onPreview,
                        onThumbnail: onThumbnail)
                }
                if !images.isEmpty { AgentMessageImagePreviews(images: images) }
            }
        }
    }
}

/// A single image uses the bubble width; multiple images stay in a compact
/// row-major grid, including when local blobs and remote locators alternate.
struct OrderedImageGalleryLayout<Content: View>: View {
    let items: [ImageGalleryLayout.Item]
    @ViewBuilder var content: (Int, ImageGalleryLayout.Item) -> Content

    var body: some View {
        if items.count == 1, let item = items.first {
            content(0, item).frame(maxWidth: 560, alignment: .leading)
        } else if !items.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    content(index, item).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }
}

@MainActor final class RemoteRedirectReviewModel: ObservableObject {
    struct Request {
        let id: UUID
        let source: RemoteAttachmentReference
        let destination: RemoteAttachmentReference
    }
    @Published private(set) var request: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    func review(_ source: RemoteAttachmentReference, _ destination: RemoteAttachmentReference) async throws -> Bool {
        try Task.checkCancellation()
        resolve(approved: false)
        let id = UUID()
        return try await withTaskCancellationHandler {
            let approved = await withCheckedContinuation { continuation in
                self.continuation = continuation
                request = Request(id: id, source: source, destination: destination)
            }
            try Task.checkCancellation()
            return approved
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.request?.id == id else { return }
                self?.resolve(approved: false)
            }
        }
    }

    func resolve(approved: Bool) {
        let pending = continuation
        continuation = nil
        request = nil
        pending?.resume(returning: approved)
    }
}

/// A saved locator is not a downloaded or verified media file.
struct RemoteAttachmentCard: View {
    let reference: RemoteAttachmentReference
    var onPreview: RemotePreviewAction?
    var isImage = false
    var onThumbnail: RemoteThumbnailAction?
    @StateObject private var redirectReview = RemoteRedirectReviewModel()
    @Environment(\.openURL) private var openURL
    @State private var previewTask: Task<Void, Never>?
    @State private var previewModel = RemoteGalleryCardModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        if let thumbnail = previewModel.display {
            RemoteGalleryAnimationView(display: thumbnail)
        }
        Button { openReference() } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: isImage ? "photo" : "link").font(.title2)
                    Text(l10n(isImage ? "Image" : "Remote attachment")).font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                }
                if let alt = reference.alt {
                    Text(verbatim: alt).lineLimit(3)
                }
                Text(verbatim: reference.url).font(.caption.monospaced()).lineLimit(2)
                Text(l10n("Open external link. Content has not been downloaded or verified."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(reference.url)
        .accessibilityIdentifier("remote-attachment-reference")
            if onPreview != nil || onThumbnail != nil {
                HStack {
                    if previewTask != nil {
                        ProgressView().controlSize(.small)
                        Button(l10n("Cancel")) { cancelButtonTapped() }
                    } else {
                        Button(l10n("Download preview"), systemImage: "eye") { previewButtonTapped() }
                    }
                }
                if let request = redirectReview.request {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n("Confirm download redirect")).font(.headline)
                        Text(verbatim: request.source.url).font(.caption.monospaced()).textSelection(.enabled)
                        Image(systemName: "arrow.down")
                        Text(verbatim: request.destination.url).font(.caption.monospaced()).textSelection(.enabled)
                        Button(l10n("Download from this address")) { redirectReview.resolve(approved: true) }
                        Button(l10n("Cancel")) { cancelButtonTapped() }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                if previewModel.state.previewFailed {
                    Text(l10n("Preview unavailable. You can open the external link instead."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear { cancelButtonTapped() }
        .onChange(of: reference) { _, _ in cancelButtonTapped() }
    }

    private func cancelButtonTapped() {
        previewTask?.cancel()
        previewTask = nil
        redirectReview.resolve(approved: false)
        previewModel.cancelButtonTapped()
    }

    private func previewButtonTapped() {
        guard previewTask == nil else { return }
        previewTask = Task { @MainActor in
            defer { if !Task.isCancelled { previewTask = nil } }
            await previewModel.previewButtonTapped(onThumbnail: onThumbnail, onPreview: onPreview,
                approveRedirect: { source, destination in try await redirectReview.review(source, destination) })
        }
    }

    private func openReference() {
        guard let url = URL(string: reference.url) else { return }
        openURL(url)
    }
}
