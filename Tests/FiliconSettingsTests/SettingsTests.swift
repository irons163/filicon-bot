import Foundation
import Testing
import FiliconDomain
@testable import FiliconSettings

@Suite("Versioned settings")
struct SettingsStoreTests {
    @Test func defaultsAndAtomicRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appending(path: "settings.json")
            let store = SettingsStore(fileURL: url, fileManager: FileManager())
            #expect(try await store.load() == FiliconSettings())

            var expected = FiliconSettings(theme: .dark)
            try expected.setTimeZoneIdentifier("Asia/Taipei")
            expected.defaultModel = .init(providerID: "openai", modelID: "gpt-5.6")
            try await store.save(expected)

            #expect(try await store.load() == expected)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".tmp") })
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func malformedAndFutureSettingsAreQuarantinedWithInjectedClock() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appending(path: "settings.json")
            try Data("not json".utf8).write(to: url)
            let store = SettingsStore(
                fileURL: url,
                fileManager: FileManager(),
                clock: { Date(timeIntervalSince1970: 1234.567) }
            )
            #expect(try await store.load() == FiliconSettings())
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(FileManager.default.fileExists(atPath: url.path + ".corrupt-1234567"))

            try Data(#"{"version":99}"#.utf8).write(to: url)
            #expect(try await store.load() == FiliconSettings())
            #expect(FileManager.default.fileExists(atPath: url.path + ".corrupt-1234567-1"))
        }
    }

    @Test func legacyVersionMigratesAndPersistsCurrentSchema() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appending(path: "settings.json")
            try Data(#"""
            {
              "theme":"light", "timeZoneIdentifier":"America/New_York",
              "defaultProviderID":"anthropic", "defaultModelID":"claude-sonnet",
              "localToolPermission":"always", "localToolPermissionCeiling":"ask",
              "updateTrack":"nightly", "autoUpdateWhenIdleOptIn":true,
              "sidebarCollapsed":true, "sidebarWidth":900,
              "pinnedAgentIDs":["a","a"," ","b"]
            }
            """#.utf8).write(to: url)
            let store = SettingsStore(fileURL: url)
            let loaded = try await store.load()
            #expect(loaded.version == filiconSettingsSchemaVersion)
            #expect(loaded.theme == .light)
            #expect(loaded.timeZoneIdentifier == "America/New_York")
            #expect(loaded.defaultModel == .init(providerID: "anthropic", modelID: "claude-sonnet"))
            #expect(loaded.localToolPermission == .ask)
            #expect(loaded.updatePolicy.effectiveTrack == .stable)
            #expect(loaded.updatePolicy.installWhenIdle)
            #expect(loaded.sidebar.width == 600)
            #expect(loaded.sidebar.pinnedAgentIDs == ["a", "b"])
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(raw?["version"] as? Int == 1)
        }
    }

    @Test func semanticInvalidValuesAreNormalizedInsteadOfCrashing() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appending(path: "settings.json")
            try Data(#"""
            {
              "version":1,
              "timeZoneIdentifier":"GMT+99",
              "usageByAccount":{"acct":{"providers":{"openai":{
                "requests":-4,"inputTokens":-1,"outputTokens":2,
                "cacheReadTokens":-3,"cacheWriteTokens":4,"costMicros":-9
              }}}}
            }
            """#.utf8).write(to: url)
            let store = SettingsStore(fileURL: url)
            let loaded = try await store.load()
            #expect(loaded.timeZoneIdentifier == nil)
            #expect(loaded.usageByAccount["acct"]?.providers["openai"] == UsageCounters(outputTokens: 2, cacheWriteTokens: 4))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func currentSchemaToleratesMissingNestedFields() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appending(path: "settings.json")
            try Data(#"{"version":1,"updatePolicy":{"installWhenIdle":true},"sidebar":{"pinnedAgentIDs":["a"]},"usageByAccount":{"acct":{"providers":{"p":{"requests":2}}}}}"#.utf8).write(to: url)
            let loaded = try await SettingsStore(fileURL: url).load()
            #expect(loaded.updatePolicy.installWhenIdle)
            #expect(loaded.updatePolicy.enabledTracks == [.stable, .dogfood])
            #expect(loaded.sidebar.width == 280)
            #expect(loaded.sidebar.pinnedAgentIDs == ["a"])
            #expect(loaded.usageByAccount["acct"]?.providers["p"] == UsageCounters(requests: 2))
        }
    }

    @Test func updateReadsTransformsNormalizesAndWrites() async throws {
        try await withTemporaryDirectory { root in
            let store = SettingsStore(fileURL: root.appending(path: "settings.json"))
            let result = try await store.update {
                $0.sidebar = SidebarState(width: 50, pinnedAgentIDs: ["one", "one", "two"])
                $0.recordUsage(accountID: "account", providerID: "openai", increment: .init(requests: 1, costMicros: 25))
            }
            #expect(result.sidebar.width == 180)
            #expect(result.sidebar.pinnedAgentIDs == ["one", "two"])
            #expect(result.usageByAccount["account"]?.total.costMicros == 25)
        }
    }
}

@Suite("Settings policies")
struct SettingsPolicyTests {
    @Test func validatesIANAIdentifiersAndAllowsSystemDefault() throws {
        var settings = FiliconSettings()
        try settings.setTimeZoneIdentifier(" Europe/Paris ")
        #expect(settings.timeZoneIdentifier == "Europe/Paris")
        #expect(FiliconSettings.isValidIANATimeZone("Asia/Taipei"))
        #expect(!FiliconSettings.isValidIANATimeZone("PST"))
        #expect(throws: SettingsValidationError.invalidTimeZone("Mars/Olympus")) {
            try settings.setTimeZoneIdentifier("Mars/Olympus")
        }
        try settings.setTimeZoneIdentifier("  ")
        #expect(settings.timeZoneIdentifier == nil)
    }

    @Test func modelFallbackPolicyNeverSilentlyCrossesProviderUnlessRequested() {
        let catalog = [
            ProviderModelAvailability(providerID: "openai", modelIDs: ["gpt-5"], defaultModelID: "gpt-5"),
            ProviderModelAvailability(providerID: "anthropic", modelIDs: ["sonnet"], defaultModelID: "sonnet"),
        ]
        let unavailable = ProviderModelDefault(providerID: "openai", modelID: "retired")
        #expect(ModelSelectionResolver.resolve(preferred: unavailable, policy: .providerDefault, availability: catalog)
                == .fallback(.init(providerID: "openai", modelID: "gpt-5")))
        #expect(ModelSelectionResolver.resolve(preferred: .init(providerID: "missing", modelID: "x"), policy: .providerDefault, availability: catalog)
                == .unavailable)
        #expect(ModelSelectionResolver.resolve(preferred: unavailable, policy: .firstAvailable, availability: catalog)
                == .fallback(.init(providerID: "openai", modelID: "gpt-5")))
        #expect(ModelSelectionResolver.resolve(preferred: unavailable, policy: .none, availability: catalog) == .unavailable)
    }

    @Test func adminCeilingUsesExplicitPermissionRank() {
        #expect(LocalToolPermission.never.rank < LocalToolPermission.ask.rank)
        #expect(LocalToolPermission.ask.rank < LocalToolPermission.always.rank)
        let settings = FiliconSettings(localToolPermission: .always, localToolPermissionCeiling: .ask)
        #expect(settings.effectiveLocalToolPermission == .ask)
        #expect(settings.normalized().localToolPermission == .ask)
    }

    @Test func usageIsNonnegativeSaturatingAndAccountScoped() {
        var settings = FiliconSettings()
        settings.recordUsage(accountID: "a", providerID: "openai", increment: .init(requests: 2, inputTokens: 10, costMicros: 30))
        settings.recordUsage(accountID: "a", providerID: "openai", increment: .init(requests: .max, inputTokens: -5, costMicros: 5))
        settings.recordUsage(accountID: "b", providerID: "gemini", increment: .init(requests: 1, costMicros: 7))
        #expect(settings.usageByAccount["a"]?.total.requests == .max)
        #expect(settings.usageByAccount["a"]?.total.inputTokens == 10)
        #expect(settings.usageByAccount["a"]?.total.costMicros == 35)
        settings.resetUsage(accountID: "a")
        #expect(settings.usageByAccount["a"] == nil)
        #expect(settings.usageByAccount["b"]?.total.costMicros == 7)
        settings.resetAllUsage()
        #expect(settings.usageByAccount.isEmpty)
    }

    @Test func switchingAccountResetsOnlyAccountScopedChoices() {
        var settings = FiliconSettings(
            theme: .dark,
            defaultModel: .init(providerID: "openai", modelID: "gpt-5"),
            localToolPermission: .always,
            localToolPermissionCeiling: .always
        )
        settings.recordUsage(accountID: "a", providerID: "openai", increment: .init(requests: 1))
        settings.scopeToAccount("a")
        #expect(settings.defaultModel != nil) // first ownership association preserves the choice
        settings.scopeToAccount("b")
        #expect(settings.accountScope == "b")
        #expect(settings.defaultModel == nil)
        #expect(settings.localToolPermission == .ask)
        #expect(settings.localToolPermissionCeiling == nil)
        #expect(settings.theme == .dark)
        #expect(settings.usageByAccount["a"]?.total.requests == 1)
        settings.clearAccountScope()
        #expect(settings.accountScope == nil)
    }

    @Test func updateTrackCoercionAndIdleInstallAreExplicit() {
        let requestedPolicy = UpdateTrackPolicy(
            enabledTracks: [.stable],
            userOverride: .nightly,
            managedTrack: .dogfood,
            buildDefault: .nightly,
            installWhenIdle: true
        )
        let publicPolicy = FiliconSettings(updatePolicy: requestedPolicy).normalized().updatePolicy
        #expect(publicPolicy.effectiveTrack == .stable)
        #expect(publicPolicy.managedTrack == nil)
        #expect(publicPolicy.userOverride == .stable)
        #expect(publicPolicy.installWhenIdle)

        let internalPolicy = UpdateTrackPolicy(enabledTracks: [.stable, .dogfood], userOverride: .dogfood)
        #expect(internalPolicy.effectiveTrack == .dogfood)
        #expect(!internalPolicy.acceptsManagedTrack(.nightly))
    }
}

@Suite("macOS window state")
struct WindowStateTests {
    private let mainDisplay = WindowBounds(x: 0, y: 0, width: 1728, height: 1080)

    @Test func fallbackIs1040x760AndCenteredWhenNoState() {
        let placement = WindowGeometry.resolve(state: nil, workAreas: [mainDisplay])
        #expect(placement.bounds.width == 1040)
        #expect(placement.bounds.height == 760)
        #expect(placement.bounds.x == 344)
        #expect(placement.bounds.y == 160)
        #expect(!placement.shouldMaximize)
    }

    @Test func undersizedScreenCannotOverrideApplicationMinimum() {
        let tiny = WindowBounds(x: 0, y: 0, width: 400, height: 300)
        let placement = WindowGeometry.resolve(state: nil, workAreas: [tiny])
        #expect(placement.bounds == .init(x: 0, y: 0, width: 1040, height: 760))
    }

    @Test func restoredBoundsEnforceMinimumSizeAndStayOnDisplay() {
        let state = WindowState(normalBounds: .init(x: 1650, y: 1050, width: 200, height: 100), isMaximized: true)
        let placement = WindowGeometry.resolve(state: state, workAreas: [mainDisplay])
        #expect(placement.bounds == .init(x: 1216, y: 560, width: 512, height: 520))
        #expect(placement.shouldMaximize)
        #expect(!placement.usedPersistedBounds) // less than 100×40 was visible
    }

    @Test func removedDisplayClampsToAvailableDisplay() {
        let removedDisplayState = WindowState(normalBounds: .init(x: 2000, y: 100, width: 1200, height: 900), isMaximized: false)
        let placement = WindowGeometry.resolve(state: removedDisplayState, workAreas: [mainDisplay])
        #expect(placement.bounds == .init(x: 528, y: 100, width: 1200, height: 900))
        #expect(!placement.usedPersistedBounds)
    }

    @Test func thresholdOverlapSelectsMatchingDisplay() {
        let second = WindowBounds(x: 1728, y: 0, width: 1920, height: 1080)
        let state = WindowState(normalBounds: .init(x: 3500, y: 100, width: 800, height: 700), isMaximized: false)
        let placement = WindowGeometry.resolve(state: state, workAreas: [mainDisplay, second])
        #expect(placement.usedPersistedBounds)
        #expect(placement.bounds.x == 2848)
        #expect(placement.bounds.y == 100)
    }

    @Test func fullscreenDoesNotPolluteNormalOrMaximizedState() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appending(path: "window-state.json")
            let store = WindowStateStore(fileURL: url, screenGeometry: { [mainDisplay] })
            let normal = WindowBounds(x: 100, y: 120, width: 900, height: 700)
            try await store.record(.init(currentBounds: normal, normalBounds: normal, isMaximized: false, isFullScreen: false))
            try await store.record(.init(
                currentBounds: .init(x: 0, y: 0, width: 1728, height: 1080),
                normalBounds: normal,
                isMaximized: true,
                isFullScreen: true
            ))
            let reopened = WindowStateStore(fileURL: url, screenGeometry: { [mainDisplay] })
            #expect(await reopened.load() == WindowState(normalBounds: normal, isMaximized: false))

            try await reopened.record(.init(
                currentBounds: .init(x: 0, y: 0, width: 1728, height: 1080),
                normalBounds: normal,
                isMaximized: true,
                isFullScreen: false
            ))
            #expect(await reopened.load() == WindowState(normalBounds: normal, isMaximized: true))
        }
    }

    @Test func malformedWindowStateQuarantinesAndUsesInjectedScreens() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appending(path: "window-state.json")
            try Data(#"{"version":1,"normalBounds":{"x":0,"y":0,"width":0,"height":1},"isMaximized":false}"#.utf8).write(to: url)
            let store = WindowStateStore(
                fileURL: url,
                clock: { Date(timeIntervalSince1970: 42) },
                screenGeometry: { [mainDisplay] }
            )
            let placement = await store.launchPlacement()
            #expect(placement.bounds.width == 1040)
            #expect(FileManager.default.fileExists(atPath: url.path + ".corrupt-42000"))
        }
    }
}

@Suite("Workspace navigation state")
struct WorkspaceNavigationStateTests {
    @Test func boundedBackForwardAndBranchingAreDeterministic() {
        var history = WorkspaceNavigationHistory()
        history.navigate(to: .agents)
        history.navigate(to: .computer)
        #expect(history.goBack() == .agents)
        #expect(history.canGoForward)
        history.navigate(to: .plugins)
        #expect(!history.canGoForward)
        #expect(history.current == .plugins)
        for index in 0..<(WorkspaceNavigationHistory.maximumEntries + 10) {
            history.navigate(to: .conversation(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!))
        }
        #expect(history.entries.count == WorkspaceNavigationHistory.maximumEntries)
        #expect(history.index == history.entries.count - 1)
    }

    @Test func reconcileDropsDeletedConversationsWithoutStaleNavigation() {
        let kept = UUID(), deleted = UUID()
        var history = WorkspaceNavigationHistory(entries: [.search, .conversation(kept), .conversation(deleted)], index: 2)
        history.reconcile(validConversationIDs: [kept])
        #expect(history.entries == [.search, .conversation(kept), .search])
        #expect(history.current == .search)

        var middle = WorkspaceNavigationHistory(
            entries: [.agents, .conversation(deleted), .plugins, .search],
            index: 1
        )
        middle.reconcile(validConversationIDs: [])
        #expect(middle.entries == [.agents, .search, .plugins, .search])
        #expect(middle.index == 1)
        #expect(middle.current == .search)
    }

    @Test func storeRoundTripsAndQuarantinesMalformedState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "navigation-\(UUID().uuidString)")
        let url = directory.appending(path: "navigation.json")
        let store = WorkspaceNavigationStore(fileURL: url, clock: { Date(timeIntervalSince1970: 42) })
        var history = WorkspaceNavigationHistory()
        history.navigate(to: .automations)
        try await store.save(history)
        #expect(await WorkspaceNavigationStore(fileURL: url).load() == history)

        try Data("{bad".utf8).write(to: url, options: .atomic)
        #expect(await store.load().current == .search)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt-42000").path))
    }

    @Test func storeRejectsSymlinkDestinationWithoutTouchingTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "navigation-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "outside.json")
        let link = directory.appending(path: "navigation.json")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = WorkspaceNavigationStore(fileURL: link)
        await #expect(throws: WorkspaceNavigationError.unsafePersistencePath) {
            try await store.save(.init())
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }
}

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appending(path: "filicon-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}
