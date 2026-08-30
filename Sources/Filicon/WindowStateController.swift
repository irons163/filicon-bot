import AppKit
import SwiftUI
import FiliconSettings

@MainActor
final class AppWindowStateController {
    static let shared = AppWindowStateController()

    private var attachedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var saveTask: Task<Void, Never>?
    private var lastNormalBounds: WindowBounds?

    private init() {}

    func attach(_ window: NSWindow) {
        guard attachedWindow !== window else { return }
        detach()
        attachedWindow = window
        let workAreas = NSScreen.screens.map { screen -> WindowBounds in
            let frame = screen.visibleFrame
            return WindowBounds(
                x: Int(frame.origin.x.rounded()),
                y: Int(frame.origin.y.rounded()),
                width: Int(frame.width.rounded()),
                height: Int(frame.height.rounded())
            )
        }
        let store = makeStore(workAreas: workAreas)
        Task { [weak self, weak window] in
            let placement = await store.launchPlacement()
            guard let self, let window, self.attachedWindow === window else { return }
            let frame = NSRect(
                x: placement.bounds.x,
                y: placement.bounds.y,
                width: placement.bounds.width,
                height: placement.bounds.height
            )
            window.setFrame(frame, display: true)
            self.lastNormalBounds = placement.bounds
            if placement.shouldMaximize && !window.isZoomed { window.zoom(nil) }
            self.installObservers(for: window, store: store)
        }
    }

    private func installObservers(for window: NSWindow, store: WindowStateStore) {
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.scheduleRecord(window: window, store: store)
                }
            })
        }
    }

    private func scheduleRecord(window: NSWindow, store: WindowStateStore) {
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if !window.isZoomed && !isFullScreen { lastNormalBounds = Self.bounds(window.frame) }
        let normal = lastNormalBounds ?? Self.bounds(window.frame)
        let snapshot = WindowSnapshot(
            currentBounds: Self.bounds(window.frame),
            normalBounds: normal,
            isMaximized: window.isZoomed,
            isFullScreen: isFullScreen
        )
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                try await store.record(snapshot)
            } catch is CancellationError {
            } catch {
                // Geometry persistence is best effort and must never make the app unusable.
            }
        }
    }

    private func detach() {
        saveTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        attachedWindow = nil
    }

    private func makeStore(workAreas: [WindowBounds]) -> WindowStateStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Filicon", directoryHint: .isDirectory)
        return WindowStateStore(fileURL: root.appending(path: "window-state.json"), screenGeometry: { workAreas })
    }

    private static func bounds(_ frame: NSRect) -> WindowBounds {
        WindowBounds(
            x: Int(frame.origin.x.rounded()),
            y: Int(frame.origin.y.rounded()),
            width: Int(frame.width.rounded()),
            height: Int(frame.height.rounded())
        )
    }
}

struct AppWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { AppWindowStateController.shared.attach(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { AppWindowStateController.shared.attach(window) }
        }
    }
}
