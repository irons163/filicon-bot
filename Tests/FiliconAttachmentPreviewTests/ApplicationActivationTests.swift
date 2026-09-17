import AppKit
import Testing
@testable import Filicon

@Suite("Foreground application launch")
@MainActor
struct ApplicationActivationTests {
    @Test func launchMakesUnbundledExecutableARegularAppBeforeActivating() throws {
        let application = ActivationProbe()
        let delegate = FiliconApplicationDelegate(application: application)

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        #expect(application.requestedRegularPolicy)
        #expect(!application.wasActivated)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(application.wasActivated)
        #expect(application.activationFollowedRegularPolicy)
        #expect(application.activationRequestedForeground)
        #expect(application.receivedExactlyOneActivation)
    }

    @Test func alreadyRegularPackagedAppStillGetsForegroundActivation() {
        let application = ActivationProbe(alreadyRegular: true)
        let delegate = FiliconApplicationDelegate(application: application)
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(application.requestedRegularPolicy)
        #expect(application.activationFollowedRegularPolicy)
        #expect(application.receivedExactlyOneActivation)
    }

    /// The probe keeps tests from changing the test runner's Dock/focus state.
    private final class ActivationProbe: FiliconApplicationActivating {
        private var regular: Bool
        private var activationCount = 0
        private(set) var requestedRegularPolicy = false
        private(set) var activationFollowedRegularPolicy = false
        private(set) var activationRequestedForeground = false
        var wasActivated: Bool { activationCount > 0 }
        var receivedExactlyOneActivation: Bool { activationCount == 1 }

        init(alreadyRegular: Bool = false) { regular = alreadyRegular }

        func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
            requestedRegularPolicy = activationPolicy == .regular
            regular = requestedRegularPolicy
            return true
        }

        func activate(ignoringOtherApps flag: Bool) {
            activationFollowedRegularPolicy = regular
            activationRequestedForeground = flag
            activationCount += 1
        }
    }
}
