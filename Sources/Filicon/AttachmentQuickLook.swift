import AppKit
import CryptoKit
import Foundation
import QuickLookUI
import SwiftUI
import FiliconDomain

enum AttachmentPreviewError: LocalizedError, Equatable {
    case invalidFilename(String)
    case integrityMismatch
    case previewFileUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFilename:
            l10n("This attachment has an invalid filename and cannot be previewed.")
        case .integrityMismatch:
            l10n("The attachment bytes do not match their content-addressed identity.")
        case .previewFileUnavailable:
            l10n("The attachment preview file could not be created.")
        }
    }
}

struct AttachmentPreviewItem: Identifiable, Equatable {
    let id: UUID
    let files: [AttachmentPreviewFile]
    let initialFileID: UUID

    var filename: String { initialFile.filename }
    var fileURL: URL { initialFile.fileURL }
    var metadata: AttachmentMetadata? { initialFile.metadata }

    private var initialFile: AttachmentPreviewFile {
        files.first(where: { $0.id == initialFileID }) ?? files[0]
    }

    init(id: UUID = UUID(), filename: String, fileURL: URL, metadata: AttachmentMetadata? = nil) {
        self.id = id
        let file = AttachmentPreviewFile(filename: filename, fileURL: fileURL, metadata: metadata)
        self.files = [file]
        self.initialFileID = file.id
    }

    init(id: UUID = UUID(), files: [AttachmentPreviewFile], initialFileID: UUID) {
        precondition(!files.isEmpty)
        self.id = id
        self.files = files
        self.initialFileID = files.contains(where: { $0.id == initialFileID }) ? initialFileID : files[0].id
    }
}

struct AttachmentPreviewFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let fileURL: URL
    let metadata: AttachmentMetadata?
    /// Captured outbound documents never invoke an active HTML/script preview.
    var isCapturedChannelFile = false

    init(id: UUID = UUID(), filename: String, fileURL: URL, metadata: AttachmentMetadata? = nil) {
        self.id = id
        self.filename = filename
        self.fileURL = fileURL
        self.metadata = metadata
    }
}

/// Produces an isolated file with the original extension so Quick Look can
/// select the correct preview generator. Each materialization gets its own
/// directory, which also makes cleanup independent of other open requests.
struct AttachmentPreviewMaterializer {
    let rootURL: URL
    var fileManager: FileManager = .default

    init(
        rootURL: URL = FileManager.default.temporaryDirectory
            .appending(path: "FiliconPreviews", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func materialize(data: Data, metadata: AttachmentMetadata) throws -> AttachmentPreviewItem {
        let filename = metadata.filename
        guard isValidFilename(filename) else {
            throw AttachmentPreviewError.invalidFilename(filename)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == metadata.id, Int64(data.count) == metadata.byteCount else {
            throw AttachmentPreviewError.integrityMismatch
        }

        let directory = rootURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: filename, directoryHint: .notDirectory)
            try data.write(to: destination, options: [.atomic])
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                try? fileManager.removeItem(at: directory)
                throw AttachmentPreviewError.previewFileUnavailable
            }
            return AttachmentPreviewItem(filename: filename, fileURL: destination, metadata: metadata)
        } catch let error as AttachmentPreviewError {
            throw error
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func remove(_ item: AttachmentPreviewItem) {
        let root = rootURL.standardizedFileURL
        for file in item.files {
            let directory = file.fileURL.deletingLastPathComponent().standardizedFileURL
            guard directory.deletingLastPathComponent() == root else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func isValidFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.utf8.contains(0) else {
            return false
        }
        return URL(fileURLWithPath: filename).lastPathComponent == filename
            && !filename.contains("/")
    }
}

struct AttachmentQuickLookSheet: View {
    @Environment(\.locale) private var uiLocale
    let item: AttachmentPreviewItem
    let onClose: () -> Void

    var body: some View {
        let _ = uiLocale.identifier
        AttachmentMediaViewerSheet(item: item, onClose: onClose)
    }
}

/// Own a separate native window so the media viewer can enter macOS full screen.
/// The model remains the owner of preview files and receives identity-bound closes.
struct AttachmentPreviewWindowPresenter: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    let item: AttachmentPreviewItem?
    let onClose: (UUID) -> Void

    func makeCoordinator() -> AttachmentPreviewWindowCoordinator { AttachmentPreviewWindowCoordinator() }
    func makeNSView(context: Context) -> AttachmentPreviewAnchor {
        let view = AttachmentPreviewAnchor(frame: .zero)
        view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.observeParent($0) }
        return view
    }
    func updateNSView(_ view: AttachmentPreviewAnchor, context: Context) {
        context.coordinator.update(item: item, locale: locale, dark: colorScheme == .dark, onClose: onClose)
    }
    static func dismantleNSView(_ view: AttachmentPreviewAnchor, coordinator: AttachmentPreviewWindowCoordinator) {
        coordinator.observeParent(nil)
        coordinator.closeAndNotify()
    }
}

final class AttachmentPreviewAnchor: NSView {
    var windowChanged: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?(window) }
}

@MainActor final class AttachmentPreviewWindowCoordinator: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private(set) var itemID: UUID?
    private var onClose: ((UUID) -> Void)?
    private weak var parent: NSWindow?

    func observeParent(_ parent: NSWindow?) {
        if let old = self.parent { NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: old) }
        self.parent = parent
        if let parent {
            NotificationCenter.default.addObserver(self, selector: #selector(parentWillClose),
                name: NSWindow.willCloseNotification, object: parent)
        }
    }

    @objc private func parentWillClose(_ notification: Notification) { closeAndNotify() }

    func update(item: AttachmentPreviewItem?, locale: Locale, dark: Bool,
                show: Bool = true, onClose: @escaping (UUID) -> Void) {
        self.onClose = onClose
        guard let item else { dismiss(); return }
        if itemID == item.id, let window {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            (window.contentView as? NSHostingView<AnyView>)?.rootView = content(item: item, locale: locale, window: window)
            return
        }
        dismiss()
        itemID = item.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = item.filename
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.delegate = self
        window.contentView = NSHostingView(rootView: content(item: item, locale: locale, window: window))
        self.window = window
        window.center()
        if show { window.makeKeyAndOrderFront(nil) }
    }

    private func content(item: AttachmentPreviewItem, locale: Locale, window: NSWindow) -> AnyView {
        AnyView(AttachmentMediaViewerSheet(item: item,
            onClose: { [weak self] in self?.closeAndNotify() },
            onFullScreen: { [weak window] in window?.toggleFullScreen(nil) })
            .environment(\.locale, locale).id(item.id))
    }

    func dismiss(closeWindow: Bool = true) {
        let old = window
        window = nil
        itemID = nil
        old?.delegate = nil
        if closeWindow { old?.close() }
        old?.contentView = nil
    }

    func closeAndNotify(closeWindow: Bool = true) {
        let id = itemID, callback = onClose
        dismiss(closeWindow: closeWindow)
        // Dismantling may occur during a SwiftUI update. Identity checking in
        // the model prevents this deferred close from dismissing a newer item.
        if let id { Task { @MainActor in callback?(id) } }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closeAndNotify(closeWindow: false)
    }
}

struct AttachmentQuickLookView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)
        view?.autostarts = true
        view?.previewItem = fileURL as NSURL
        return view ?? QLPreviewView(frame: .zero, style: .normal)!
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != fileURL as NSURL {
            view.previewItem = fileURL as NSURL
            view.refreshPreviewItem()
        }
    }
}
