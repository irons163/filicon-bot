import AppKit
import CoreGraphics
import Foundation
import FiliconUpdater

@MainActor
final class NativeUpdateIdleMonitor {
    private(set) var sessionActive = true
    private(set) var screenLocked = false
    private(set) var screensaverActive = false
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var processTokens: [NSObjectProtocol] = []
    private let onSignalChange: @MainActor () -> Void

    init(onSignalChange: @escaping @MainActor () -> Void) {
        self.onSignalChange = onSignalChange
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionActive = false; self?.onSignalChange() }
            },
            workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionActive = true; self?.onSignalChange() }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked = true; self?.onSignalChange() }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked = false; self?.onSignalChange() }
            },
        ]
        let distributed = DistributedNotificationCenter.default()
        distributedTokens = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked = true; self?.onSignalChange() }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked = false; self?.onSignalChange() }
            },
            distributed.addObserver(forName: .init("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensaverActive = true; self?.onSignalChange() }
            },
            distributed.addObserver(forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensaverActive = false; self?.onSignalChange() }
            },
        ]
        processTokens = [
            NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.onSignalChange() } },
        ]
    }

    func snapshot(hasActiveWork: Bool) -> UpdateIdleSnapshot {
        .init(
            hasActiveWork: hasActiveWork,
            sessionActive: sessionActive,
            screenLocked: screenLocked,
            screensaverActive: screensaverActive,
            systemIdleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}
