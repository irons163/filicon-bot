import SwiftUI
import FiliconAgents
import FiliconDomain

typealias RemoteRedirectReview = @MainActor @Sendable (RemoteAttachmentReference, RemoteAttachmentReference) async throws -> Bool
typealias RemotePreviewAction = (@escaping RemoteRedirectReview) async throws -> Void

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
    var onThumbnail: ((RemoteAttachmentReference, @escaping RemoteRedirectReview) async throws -> Data)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(gallery.images, id: \.url) { reference in
                RemoteAttachmentCard(reference: reference,
                    onPreview: onPreview.map { action in { review in try await action(reference, review) } }, isImage: true,
                    onThumbnail: onThumbnail.map { action in { review in try await action(reference, review) } })
                    .accessibilityIdentifier("remote-gallery-image-\(gallery.images.firstIndex(of: reference) ?? 0)")
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
    var onThumbnail: ((RemoteAttachmentReference, @escaping RemoteRedirectReview) async throws -> Data)?

    var body: some View {
        Group {
            if let layout, layout.matches(attachments: images, remoteGallery: remoteGallery) {
                OrderedImageGalleryLayout(items: layout.items) { item in
                    switch item {
                    case let .attachment(id):
                        if let image = images.first(where: { $0.id == id }) {
                            AgentMessageImagePreviews(images: [image], compact: true,
                                expandsSingleImage: layout.items.count == 1, viewingGallery: images)
                        }
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
    @ViewBuilder var content: (ImageGalleryLayout.Item) -> Content

    var body: some View {
        if items.count == 1, let item = items.first {
            content(item).frame(maxWidth: 560, alignment: .leading)
        } else if !items.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    content(item).frame(maxWidth: .infinity, alignment: .leading)
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
    var onThumbnail: ((@escaping RemoteRedirectReview) async throws -> Data)?
    @StateObject private var redirectReview = RemoteRedirectReviewModel()
    @Environment(\.openURL) private var openURL
    @State private var previewTask: Task<Void, Never>?
    @State private var previewFailed = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        if let thumbnail {
            RemoteGalleryThumbnailView(image: thumbnail, alt: reference.alt)
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
                if previewFailed {
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
        thumbnail = nil
    }

    private func previewButtonTapped() {
        previewFailed = false
        previewTask = Task { @MainActor in
            defer { if !Task.isCancelled { previewTask = nil } }
            do {
                if let onThumbnail {
                    let data = try await onThumbnail { source, destination in try await redirectReview.review(source, destination) }
                    try Task.checkCancellation()
                    guard let image = NSImage(data: data) else { throw CancellationError() }
                    thumbnail = image
                } else if let onPreview {
                    try await onPreview { source, destination in try await redirectReview.review(source, destination) }
                }
            }
            catch is CancellationError {}
            catch { if !Task.isCancelled { previewFailed = true } }
        }
    }

    private func openReference() {
        guard let url = URL(string: reference.url) else { return }
        openURL(url)
    }
}
