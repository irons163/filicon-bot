import AppKit
import AVKit
import CryptoKit
import Darwin
import Foundation
import FiliconAppServices
import FiliconDomain
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentViewerKind: Equatable {
    case image
    case audiovisual
    case pdf
    case spreadsheet
    case quickLook
    case plainText

    static func classify(_ file: AttachmentPreviewFile) -> Self {
        let kind = classify(filename: file.filename, mimeType: file.metadata?.mimeType)
        return file.isCapturedChannelFile && kind == .quickLook ? .plainText : kind
    }

    static func classify(filename: String, mimeType: String?) -> Self {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let mime = mimeType?.lowercased() ?? ""
        if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "avif", "ico", "svg"].contains(ext) {
            return .image
        }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") || ["mov", "mp4", "m4v", "mp3", "m4a", "aac", "wav", "aiff", "caf"].contains(ext) {
            return .audiovisual
        }
        if mime == "application/pdf" || ext == "pdf" { return .pdf }
        if ["csv", "tsv", "xlsx"].contains(ext) || [
            "text/csv", "text/tab-separated-values",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        ].contains(mime) { return .spreadsheet }
        return .quickLook
    }
}

enum AttachmentFileIntegrityError: LocalizedError, Equatable {
    case unsafeFile
    case changed

    var errorDescription: String? {
        switch self {
        case .unsafeFile: l10n("The preview copy is no longer a safe regular file.")
        case .changed: l10n("The preview copy no longer matches its verified attachment.")
        }
    }
}

struct AttachmentFileIntegrity {
    func verifiedData(for file: AttachmentPreviewFile) throws -> Data {
        guard file.fileURL.isFileURL else { throw AttachmentFileIntegrityError.unsafeFile }
        let descriptor = open(file.fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AttachmentFileIntegrityError.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= AttachmentLimits.videoBytes else {
            throw AttachmentFileIntegrityError.unsafeFile
        }
        if let metadata = file.metadata, info.st_size != metadata.byteCount {
            throw AttachmentFileIntegrityError.changed
        }
        let data = try handle.read(upToCount: Int(info.st_size) + 1) ?? Data()
        guard data.count == info.st_size else { throw AttachmentFileIntegrityError.changed }
        if let metadata = file.metadata {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == metadata.id, Int64(data.count) == metadata.byteCount else {
                throw AttachmentFileIntegrityError.changed
            }
        }
        return data
    }
}

enum AttachmentImagePreviewError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? { l10n("Image preview unavailable") }
}

struct AttachmentImageSnapshot: Sendable {
    let displayData: Data
    let original: AttachmentMetadata

    private init(displayData: Data, original: AttachmentMetadata) {
        self.displayData = displayData
        self.original = original
    }

    nonisolated static func prepare(_ data: Data, filename: String) throws -> Self {
        do {
            let original = try RemoteAttachmentImagePreparation.metadata(for: data, filename: filename,
                createdAt: Date(timeIntervalSince1970: 0))
            let displayData = original.mimeType == "image/svg+xml"
                ? try RemoteAttachmentImagePreparation.thumbnail(for: data, original: original,
                    maximumDimension: 1_024).data : data
            try Task.checkCancellation()
            return Self(displayData: displayData, original: original)
        } catch is RemoteAttachmentImageError { throw AttachmentImagePreviewError.unavailable }
    }

    nonisolated static func thumbnail(_ data: Data, filename: String) throws -> Data {
        do {
            let original = try RemoteAttachmentImagePreparation.metadata(for: data, filename: filename,
                createdAt: Date(timeIntervalSince1970: 0))
            return try RemoteAttachmentImagePreparation.thumbnail(for: data, original: original,
                maximumDimension: 256).data
        } catch is RemoteAttachmentImageError { throw AttachmentImagePreviewError.unavailable }
    }
}

struct AttachmentPreviewSnapshot: Sendable {
    let data: Data?
    let image: AttachmentImageSnapshot?

    nonisolated static func verified(for file: AttachmentPreviewFile) throws -> Self {
        try Task.checkCancellation()
        let data = try AttachmentFileIntegrity().verifiedData(for: file)
        let kind = AttachmentViewerKind.classify(file)
        let image = kind == .image ? try AttachmentImageSnapshot.prepare(data, filename: file.filename) : nil
        try Task.checkCancellation()
        return Self(data: [.image, .pdf, .spreadsheet, .plainText].contains(kind) ? data : nil, image: image)
    }
}

struct AttachmentMediaViewerSheet: View {
    @Environment(\.locale) private var uiLocale
    let item: AttachmentPreviewItem
    let onClose: () -> Void
    let onFullScreen: (() -> Void)?

    @State private var selectedFileID: UUID
    @State private var showsMetadata = false
    @State private var actionError: String?

    init(item: AttachmentPreviewItem, onClose: @escaping () -> Void, onFullScreen: (() -> Void)? = nil) {
        self.item = item
        self.onClose = onClose
        self.onFullScreen = onFullScreen
        _selectedFileID = State(initialValue: item.initialFileID)
    }

    private var selectedFile: AttachmentPreviewFile {
        item.files.first(where: { $0.id == selectedFileID }) ?? item.files[0]
    }

    private var selectedIndex: Int {
        item.files.firstIndex(where: { $0.id == selectedFileID }) ?? 0
    }

    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 0) {
            toolbar
            Divider()
            viewer(for: selectedFile)
                .id(selectedFile.id)
                .accessibilityLabel(selectedFile.metadata?.altText ?? selectedFile.filename)
            if let alt = selectedFile.metadata?.altText {
                Text(verbatim: alt).textSelection(.enabled).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.files.count > 1 {
                Divider()
                galleryStrip
            }
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 560, idealHeight: 720)
        .alert(l10n("Attachment"), isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) { Button(l10n("OK")) { actionError = nil } } message: { Text(FiliconLocalization.message(actionError ?? "")) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if item.files.count > 1 {
                Button { select(offset: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(selectedIndex == 0)
                Button { select(offset: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(selectedIndex == item.files.count - 1)
                Text(l10n("\(selectedIndex + 1) of \(item.files.count)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(selectedFile.filename).font(.headline).lineLimit(1)
            Spacer()
            if let onFullScreen {
                Button(action: onFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(l10n("Full Screen"))
                    .accessibilityLabel(l10n("Full Screen"))
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }
            Button { showsMetadata.toggle() } label: { Label(l10n("Info"), systemImage: "info.circle") }
                .popover(isPresented: $showsMetadata) { AttachmentMetadataView(file: selectedFile) }
            Button(l10n("Save a Copy…"), action: saveOriginal)
            Button(l10n("Open Externally"), action: openExternally)
            Button(l10n("Close"), action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    @ViewBuilder private func viewer(for file: AttachmentPreviewFile) -> some View {
        AttachmentIntegrityGate(file: file) { snapshot in
            switch AttachmentViewerKind.classify(file) {
            case .image: AttachmentImageView(snapshot: snapshot.image)
            case .audiovisual: AttachmentAVPlayerView(fileURL: file.fileURL)
            case .pdf: AttachmentPDFView(file: file, verifiedData: snapshot.data)
            case .spreadsheet: AttachmentSpreadsheetView(file: file, verifiedData: snapshot.data)
            case .quickLook: AttachmentQuickLookView(fileURL: file.fileURL)
            case .plainText: CapturedChannelTextPreview(data: snapshot.data)
            }
        }
    }

    private var galleryStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(item.files) { file in
                    Button { selectedFileID = file.id } label: {
                        VStack(spacing: 4) {
                            AttachmentThumbnail(file: file)
                                .frame(width: 72, height: 52)
                            Text(file.filename).font(.caption2).lineLimit(1).frame(width: 88)
                        }
                        .padding(5)
                        .background(file.id == selectedFileID ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(height: 92)
    }

    private func select(offset: Int) {
        let next = selectedIndex + offset
        guard item.files.indices.contains(next) else { return }
        selectedFileID = item.files[next].id
    }

    private func saveOriginal() {
        do {
            let data = try AttachmentFileIntegrity().verifiedData(for: selectedFile)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = selectedFile.filename
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try data.write(to: destination, options: [.atomic])
        } catch { actionError = error.localizedDescription }
    }

    private func openExternally() {
        do {
            _ = try AttachmentFileIntegrity().verifiedData(for: selectedFile)
            guard NSWorkspace.shared.open(selectedFile.fileURL) else {
                throw CocoaError(.fileNoSuchFile)
            }
        } catch { actionError = error.localizedDescription }
    }
}

struct CapturedChannelTextSnapshot: Equatable {
    static let byteLimit = 256 * 1_024
    let text: String
    let truncated: Bool

    init?(data: Data) {
        let sample = data.prefix(8 * 1_024)
        let controls = sample.filter { $0 < 32 && !(9...13).contains($0) }.count
        guard !sample.contains(0), sample.isEmpty || Double(controls) / Double(sample.count) <= 0.3 else { return nil }
        var prefix = Data(data.prefix(Self.byteLimit))
        var decoded = String(data: prefix, encoding: .utf8)
        if decoded == nil && data.count > Self.byteLimit {
            // A UTF-8 character may straddle the bounded preview boundary.
            for _ in 0..<3 where decoded == nil && !prefix.isEmpty {
                prefix.removeLast(); decoded = String(data: prefix, encoding: .utf8)
            }
        }
        guard let decoded else { return nil }
        text = decoded; truncated = data.count > prefix.count
    }
}

private struct CapturedChannelTextPreview: View {
    let data: Data?
    var body: some View {
        if let data, let snapshot = CapturedChannelTextSnapshot(data: data) {
            VStack(alignment: .leading, spacing: 8) {
                if snapshot.truncated {
                    Text(l10n("This preview shows only the first \(CapturedChannelTextSnapshot.byteLimit) bytes. Save a copy to view the full file."))
                        .font(.caption).padding(12)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: snapshot.text).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityIdentifier("captured-channel-text-preview")
        } else {
            Text(l10n("This attachment has no safe text preview. Save a copy to open it in another app."))
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// No native parser or Quick Look generator receives a materialized CAS file
/// until its digest and byte count have been checked again. This closes the
/// gap between the store check in `AppModel` and opening the preview sheet.
/// Image, PDF and table decoding consume the verified snapshot, not the original path.
/// Other native parsers still use their URL APIs after the initial check.
private struct AttachmentIntegrityGate<Content: View>: View {
    @Environment(\.locale) private var uiLocale
    let file: AttachmentPreviewFile
    @ViewBuilder let content: (AttachmentPreviewSnapshot) -> Content
    @State private var snapshot: AttachmentPreviewSnapshot?
    @State private var error: String?

    var body: some View {
        let _ = uiLocale.identifier
        Group {
            if let snapshot {
                content(snapshot)
            } else if let error {
                ContentUnavailableView(
                    l10n("Attachment unavailable"),
                    systemImage: "lock.trianglebadge.exclamationmark",
                    description: Text(FiliconLocalization.message(error))
                )
            } else {
                ProgressView("Verifying attachment…")
            }
        }
        .task(id: file.id) { await verifyAttachment() }
    }

    private func verifyAttachment() async {
        snapshot = nil
        error = nil
        do {
            let previewFile = file
            let worker = Task.detached(priority: .userInitiated) {
                try AttachmentPreviewSnapshot.verified(for: previewFile)
            }
            let verified = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            snapshot = verified
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct AttachmentMetadataView: View {
    @Environment(\.locale) private var uiLocale
    let file: AttachmentPreviewFile

    var body: some View {
        let _ = uiLocale.identifier
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            row(l10n("Name"), file.filename)
            row(l10n("Type"), file.metadata?.mimeType ?? "Unknown")
            row(l10n("Size"), file.metadata.map { ByteCountFormatter.string(fromByteCount: $0.byteCount, countStyle: .file) } ?? "Unknown")
            if let identifier = file.metadata?.id {
                row(l10n("SHA-256"), identifier)
                Button(l10n("Copy SHA-256")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(identifier, forType: .string)
                }
                .gridCellColumns(2)
            }
        }
        .textSelection(.enabled)
        .padding(16)
        .frame(width: 430)
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(3)
        }
    }
}

struct AttachmentThumbnail: View {
    @Environment(\.locale) private var uiLocale
    let file: AttachmentPreviewFile
    @State private var preview: NSImage?
    @State private var failed = false

    var body: some View {
        let _ = uiLocale.identifier
        Group {
            if let image = preview {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: failed ? "photo.badge.exclamationmark" : icon)
                    .resizable().scaledToFit().padding(12).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(failed ? l10n("Image preview unavailable") : file.metadata?.altText ?? file.filename)
        .help(file.metadata?.altText ?? file.filename)
        .task(id: file.id) { await loadThumbnail() }
    }

    nonisolated static func verifiedImageData(for file: AttachmentPreviewFile) throws -> Data? {
        try Task.checkCancellation()
        guard AttachmentViewerKind.classify(filename: file.filename, mimeType: file.metadata?.mimeType) == .image else { return nil }
        let data = try AttachmentFileIntegrity().verifiedData(for: file)
        return try AttachmentImageSnapshot.thumbnail(data, filename: file.filename)
    }

    private func loadThumbnail() async {
        preview = nil
        failed = false
        do {
            let snapshot = file
            let worker = Task.detached(priority: .utility) {
                try Self.verifiedImageData(for: snapshot)
            }
            let bytes = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            preview = bytes.flatMap { NSImage(data: $0) }
            failed = bytes != nil && preview == nil
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    private var icon: String {
        switch AttachmentViewerKind.classify(file) {
        case .image: "photo"
        case .audiovisual: "play.rectangle"
        case .pdf: "doc.richtext"
        case .spreadsheet: "tablecells"
        case .quickLook, .plainText: "doc"
        }
    }
}

struct AttachmentImageZoom: Equatable {
    var scale = 1.0

    func effectiveScale(gesture: Double) -> Double {
        let proposed = scale * gesture
        return proposed.isFinite ? min(8, max(0.1, proposed)) : scale
    }

    mutating func finishGesture(_ magnification: Double) {
        scale = effectiveScale(gesture: magnification)
    }

    func displaySize(image: CGSize, viewport: CGSize, gesture: Double = 1) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let fit = min(1, max(0, viewport.width - 48) / image.width,
                      max(0, viewport.height - 48) / image.height)
        let factor = fit * effectiveScale(gesture: gesture)
        return CGSize(width: image.width * factor, height: image.height * factor)
    }
}

struct AttachmentImageView: View {
    @Environment(\.locale) private var uiLocale
    let image: NSImage?
    @State private var zoom = AttachmentImageZoom()
    @GestureState private var gestureScale = 1.0

    init(snapshot: AttachmentImageSnapshot?) {
        image = snapshot.flatMap { NSImage(data: $0.displayData) }
    }

    var body: some View {
        let _ = uiLocale.identifier
        if let image {
            VStack(spacing: 0) {
                HStack {
                    Slider(value: $zoom.scale, in: 0.1...8) { Text(l10n("Zoom")) }
                        .frame(maxWidth: 280)
                    Text(zoom.effectiveScale(gesture: gestureScale), format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(minWidth: 48)
                    Button(l10n("Reset")) { zoom = AttachmentImageZoom() }
                    Spacer()
                }
                .padding(8)
                Divider()
                GeometryReader { geometry in
                    let size = zoom.displaySize(image: image.size, viewport: geometry.size, gesture: gestureScale)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                            .padding(24)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    .gesture(MagnifyGesture()
                        .updating($gestureScale) { value, state, _ in state = value.magnification }
                        .onEnded { zoom.finishGesture($0.magnification) })
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ContentUnavailableView(l10n("Image unavailable"), systemImage: "photo.badge.exclamationmark")
        }
    }
}

private struct AttachmentAVPlayerView: View {
    @Environment(\.locale) private var uiLocale
    let player: AVPlayer

    init(fileURL: URL) {
        let asset = AVURLAsset(url: fileURL,
            options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    var body: some View {
        let _ = uiLocale.identifier
        VideoPlayer(player: player)
            .background(.black)
            .onDisappear { player.pause() }
    }
}

struct AttachmentPDFView: View {
    @Environment(\.locale) private var uiLocale
    let file: AttachmentPreviewFile
    let document: PDFDocument?
    @State private var searchQuery = ""
    @State private var showsText = false
    @State private var documentText = ""
    @State private var pageCount = 0
    @State private var error: String?

    init(file: AttachmentPreviewFile, verifiedData: Data?) {
        self.file = file
        document = verifiedData.flatMap { PDFDocument(data: $0) }
    }

    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 0) {
            HStack {
                TextField(l10n("Search PDF"), text: $searchQuery).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Text(l10n("Pages: \(pageCount)")).foregroundStyle(.secondary)
                Spacer()
                Toggle(l10n("Text"), isOn: $showsText).toggleStyle(.button)
                Button(l10n("Export Text…"), action: exportText).disabled(documentText.isEmpty)
            }
            .padding(8)
            Divider()
            if let error {
                ContentUnavailableView(l10n("PDF unavailable"), systemImage: "doc.badge.ellipsis", description: Text(FiliconLocalization.message(error)))
            } else if showsText {
                ScrollView { Text(documentText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            } else {
                PDFNativeView(document: document, searchQuery: searchQuery)
            }
        }
        .task(id: file.id) { loadDocumentMetadata() }
    }

    private func loadDocumentMetadata() {
        guard let document else { error = "The PDF document is malformed."; return }
        pageCount = document.pageCount
        var parts: [String] = []
        var characters = 0
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string else { continue }
            characters += text.count
            if characters > SpreadsheetPreviewLimits.totalCharacters {
                parts.append("\n[Text preview truncated]")
                break
            }
            parts.append(text)
        }
        documentText = parts.joined(separator: "\n\n")
    }

    private func exportText() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: file.filename).deletingPathExtension().lastPathComponent + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Export is an attachment-derived save operation. Fail closed if
            // the isolated preview changed since its original CAS check.
            _ = try AttachmentFileIntegrity().verifiedData(for: file)
            try Data(documentText.utf8).write(to: url, options: [.atomic])
        }
        catch { self.error = error.localizedDescription }
    }
}

struct PDFNativeView: NSViewRepresentable {
    let document: PDFDocument?
    let searchQuery: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.update(view, document: document, searchQuery: searchQuery)
    }

    @MainActor final class Coordinator {
        private var lastQuery = ""

        func update(_ view: PDFView, document: PDFDocument?, searchQuery: String) {
            let changedDocument = view.document !== document
            if changedDocument { view.document = document }
            guard changedDocument || lastQuery != searchQuery else { return }
            lastQuery = searchQuery
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { view.highlightedSelections = []; return }
            let selections = document?.findString(query, withOptions: .caseInsensitive) ?? []
            view.highlightedSelections = Array(selections.prefix(1_000))
            if let first = selections.first { view.go(to: first) }
        }
    }
}

private struct AttachmentSpreadsheetView: View {
    @Environment(\.locale) private var uiLocale
    let file: AttachmentPreviewFile
    let verifiedData: Data?
    @State private var preview: SpreadsheetPreview?
    @State private var selectedSheetID: String?
    @State private var error: String?

    var body: some View {
        let _ = uiLocale.identifier
        Group {
            if let preview {
                VStack(spacing: 0) {
                    if preview.sheets.count > 1 {
                        Picker(l10n("Sheet"), selection: $selectedSheetID) {
                            ForEach(preview.sheets) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.segmented).padding(8)
                        Divider()
                    }
                    if let sheet = selectedSheet(in: preview) { SpreadsheetGrid(sheet: sheet) }
                    else { ContentUnavailableView(l10n("Empty workbook"), systemImage: "tablecells") }
                }
            } else if let error {
                VStack(spacing: 12) {
                    ContentUnavailableView(l10n("Table preview unavailable"), systemImage: "tablecells.badge.ellipsis", description: Text(FiliconLocalization.message(error)))
                    Text(l10n("Quick Look remains available for unsupported system spreadsheet formats."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Parsing table safely…")
            }
        }
        .task(id: file.id) { await load() }
    }

    private func selectedSheet(in preview: SpreadsheetPreview) -> SpreadsheetPreview.Sheet? {
        preview.sheets.first(where: { $0.id == selectedSheetID }) ?? preview.sheets.first
    }

    private func load() async {
        preview = nil
        selectedSheetID = nil
        error = nil
        let name = file.filename
        do {
            guard let data = verifiedData else { throw SpreadsheetPreviewError.malformedWorkbook }
            let result = try await Task.detached(priority: .userInitiated) {
                try AttachmentSpreadsheetSnapshotParser().parse(data: data, filename: name)
            }.value
            guard !Task.isCancelled else { return }
            preview = result
            selectedSheetID = result.sheets.first?.id
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct SpreadsheetGrid: View {
    @Environment(\.locale) private var uiLocale
    let sheet: SpreadsheetPreview.Sheet

    private var columnCount: Int { sheet.rows.map(\.count).max() ?? 0 }

    var body: some View {
        let _ = uiLocale.identifier
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sheet.rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        Text("\(rowIndex + 1)")
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing).padding(.trailing, 8)
                        ForEach(0..<columnCount, id: \.self) { column in
                            SpreadsheetCell(value: column < row.count ? row[column] : "", isHeader: rowIndex == 0)
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}

private struct SpreadsheetCell: View {
    @Environment(\.locale) private var uiLocale
    let value: String
    let isHeader: Bool

    var body: some View {
        let _ = uiLocale.identifier
        Text(value)
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .frame(width: 180, alignment: .leading)
                                .frame(minHeight: 28)
                                .padding(.horizontal, 6)
                                .background(isHeader ? Color.secondary.opacity(0.12) : .clear)
                                .overlay(Rectangle().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5))
    }
}
