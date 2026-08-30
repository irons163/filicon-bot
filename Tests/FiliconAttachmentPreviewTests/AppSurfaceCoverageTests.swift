import AppKit
import Foundation
import Testing
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
import FiliconSettings
import FiliconUpdater
@testable import Filicon

@Suite("App surface projection coverage")
struct AppSurfaceCoverageTests {
    @Test func workspaceRoutesRoundTripEveryDestination() {
        let conversationID = UUID()
        let destinations: [WorkspaceNavigationDestination] = [
            .conversation(conversationID), .search, .agents, .groups,
            .automations, .channels, .mcp, .computer, .plugins,
            .hiddenChats, .sharedRooms, .account,
        ]

        for destination in destinations {
            let route = WorkspaceRoute(destination)
            #expect(route.navigationDestination == destination)
        }
    }

    @Test func globalSearchTabsExposeStableIdentities() {
        #expect(GlobalSearchTab.allCases.map(\.id) == GlobalSearchTab.allCases)
        #expect(GlobalSearchTab.conversations.id == .conversations)
        #expect(GlobalSearchTab.messages.id == .messages)
        #expect(GlobalSearchTab.files.id == .files)
    }

    @Test func providerCatalogPresentationCoversStatusesValidationAndCapabilities() {
        let conversationID = UUID()
        let conversation = Conversation(
            id: conversationID, providerID: "provider", modelID: "reasoner", reasoningEffort: .high
        )
        let model = AIModel(
            id: "reasoner", displayName: "Reasoner",
            capabilities: .init(inputModalities: [.text, .audio], reasoningEfforts: [.high]),
            contextWindow: 1_000_000, maximumOutputTokens: 2_000
        )

        #expect(ProviderCatalogPresentation.statusLabel(source: nil, isStale: false, error: nil) == "Catalog not loaded")
        #expect(ProviderCatalogPresentation.statusLabel(source: .builtIn, isStale: false, error: nil) == "Built-in catalog")
        #expect(ProviderCatalogPresentation.statusLabel(source: .builtInFallback, isStale: false, error: nil) == "Built-in fallback")
        #expect(ProviderCatalogPresentation.statusLabel(source: .dynamic, isStale: true, error: nil) == "Stale catalog")
        #expect(ProviderCatalogPresentation.statusLabel(source: .dynamic, isStale: false, error: "offline") == "Catalog error — offline")
        #expect(ProviderCatalogPresentation.statusLabel(source: .builtIn, isStale: true, error: "offline") == "Stale catalog — offline")

        #expect(ProviderCatalogPresentation.modelLabel(AIModel(id: "plain")) == "plain")
        let label = ProviderCatalogPresentation.modelLabel(model)
        #expect(label.contains("1M context"))
        #expect(label.contains("2K max output"))
        #expect(label.contains("audio"))
        #expect(ProviderCatalogPresentation.reasoningEfforts(for: nil) == [.disabled])
        #expect(ProviderCatalogPresentation.reasoningEfforts(for: model) == [.disabled, .high])

        #expect(ProviderCatalogPresentation.validationError(
            conversation: conversation, models: [model], catalogProviderID: "provider",
            catalogConversationID: conversationID, loading: false
        ) == nil)
        #expect(ProviderCatalogPresentation.validationError(
            conversation: conversation, models: [model], catalogProviderID: "provider",
            catalogConversationID: conversationID, loading: true
        )?.contains("finish loading") == true)
        #expect(ProviderCatalogPresentation.validationError(
            conversation: conversation, models: [model], catalogProviderID: "other",
            catalogConversationID: conversationID, loading: false
        )?.contains("Refresh") == true)
        #expect(ProviderCatalogPresentation.validationError(
            conversation: conversation, models: [], catalogProviderID: "provider",
            catalogConversationID: conversationID, loading: false
        )?.contains("not available") == true)
        let unsupported = AIModel(id: "reasoner", displayName: "Plain", capabilities: .safeTextOnly)
        #expect(ProviderCatalogPresentation.validationError(
            conversation: conversation, models: [unsupported], catalogProviderID: "provider",
            catalogConversationID: conversationID, loading: false
        )?.contains("does not support") == true)
    }

    @Test func updatePresentationsCoverEveryState() throws {
        let release = UpdateRelease(
            version: "2.0.0", build: 20, publishedAt: .now, minimumSystemVersion: "14.0",
            artifact: .init(
                url: URL(string: "https://updates.example/Filicon.zip")!, format: .appZip,
                sha256: String(repeating: "a", count: 64), size: 10
            )
        )
        let staged = StagedUpdate(release: release, artifactPath: "Filicon.zip", stagedAt: .now)
        let states: [UpdateState] = [
            .idle, .upToDate(checkedAt: .now), .checking, .available(release),
            .downloading(release), .staged(staged, directory: URL(fileURLWithPath: "/tmp/staged")),
            .installing(staged), .failed("offline"),
        ]

        #expect(UpdatePillPresentation.make(state: .idle) == nil)
        #expect(UpdatePillPresentation.make(state: .upToDate(checkedAt: .now)) == nil)
        let expectedPillActions: [UpdatePresentationAction?] = [nil, nil, nil, .download, nil, .install, nil, .check]
        for (state, expectedAction) in zip(states, expectedPillActions) {
            #expect(UpdatePillPresentation.make(state: state)?.action == expectedAction)
        }
        #expect(UpdatePillPresentation.make(state: .checking)?.label == "Checking for updates…")
        #expect(UpdatePillPresentation.make(state: .downloading(release))?.label == "Downloading update…")
        #expect(UpdatePillPresentation.make(state: .installing(staged))?.label == "Installing update…")
        #expect(UpdatePillPresentation.make(state: .failed("offline"))?.isError == true)

        for state in states {
            let presentation = RequiredUpdatePresentation.make(state: state)
            #expect(!presentation.status.isEmpty)
        }
        #expect(RequiredUpdatePresentation.make(state: .idle).action == .check)
        #expect(RequiredUpdatePresentation.make(state: .checking).action == nil)
        #expect(RequiredUpdatePresentation.make(state: .available(release)).action == .download)
        #expect(RequiredUpdatePresentation.make(state: .downloading(release)).action == nil)
        #expect(RequiredUpdatePresentation.make(state: .staged(staged, directory: URL(fileURLWithPath: "/tmp/staged"))).action == .install)
        #expect(RequiredUpdatePresentation.make(state: .installing(staged)).action == nil)
        #expect(RequiredUpdatePresentation.make(state: .failed("offline")).isError)
    }

    @Test @MainActor func emptyAppModelSurfaceFailsClosed() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-app-surface-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)

        #expect(model.selectedConversation == nil)
        #expect(model.selectedModel == nil)
        #expect(model.supportedReasoningEfforts == [.disabled])
        #expect(model.selectedConversationConfigurationError == "No conversation is selected.")
        #expect(model.modelCatalogStatusLabel == "Catalog not loaded")
        #expect(model.visibleConversations.isEmpty)
        #expect(model.hiddenConversations.isEmpty)
        #expect(!model.isUpdateRequired)
        #expect(model.startupStorePaths.contains(root.appending(path: "conversations.json")))
    }

    @Test @MainActor func notificationServiceScopesTransportAndDockProjection() {
        let service = SystemNotificationService()
        let agentID = UUID()

        #expect(!service.notificationTransportIsActive)
        #expect(service.activateNotificationTransport(scopeID: "  account-a  "))
        #expect(service.notificationTransportIsActive)
        #expect(!service.activateNotificationTransport(scopeID: "account-a"))

        service.updateAgentDockBadge([
            .init(id: agentID.uuidString.lowercased(), hasUnread: true, unreadCount: 2, epoch: "test", sequence: 1),
            .init(id: "hidden", hasUnread: true, unreadCount: 99, isHidden: true, epoch: "test", sequence: 2),
        ])
        #expect(NSApplication.shared.dockTile.badgeLabel == "2")
        service.forgetAgent(agentID)
        #expect(NSApplication.shared.dockTile.badgeLabel == nil)

        #expect(service.deactivateNotificationTransport())
        #expect(!service.notificationTransportIsActive)
        #expect(!service.deactivateNotificationTransport())
        service.markAllViewed()
    }

    @Test @MainActor func idleMonitorTracksWorkspaceSignalsAndSnapshots() async {
        var signalCount = 0
        let monitor = NativeUpdateIdleMonitor { signalCount += 1 }
        let workspace = NSWorkspace.shared.notificationCenter

        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        for _ in 0..<5 { await Task.yield() }

        #expect(!monitor.sessionActive)
        #expect(monitor.screenLocked)
        #expect(!monitor.screensaverActive)
        #expect(signalCount >= 2)
        let snapshot = monitor.snapshot(hasActiveWork: true)
        #expect(snapshot.hasActiveWork)
        #expect(!snapshot.sessionActive)
        #expect(snapshot.screenLocked)
        #expect(!snapshot.screensaverActive)
        #expect(snapshot.systemIdleSeconds.isFinite)

        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        for _ in 0..<5 { await Task.yield() }
        #expect(monitor.sessionActive)
        #expect(!monitor.screenLocked)
        #expect(!monitor.screensaverActive)
    }

    @Test func cardPresenterCoversOptionalFieldsAndUnknownCards() {
        let cards: [TranscriptCard] = [
            .init(lifecycle: .draft, payload: .draft(.init(
                draftID: "draft", channel: "chat", recipients: ["one@example.com"],
                subject: "Subject", body: "Body"
            ))),
            .init(lifecycle: .pending, payload: .listener(.init(
                listenerID: "listener", connector: "slack", event: "message", filterSummary: "mentions"
            ))),
            .init(lifecycle: .provided, payload: .secretRequest(.init(
                requestID: "secret", service: "github", account: "work", scope: "repo"
            ))),
            .init(lifecycle: .retired, payload: .localToolPermission(.init(
                requestID: "permission", toolName: "write_file", scope: "workspace", retiredNotice: "Expired"
            ))),
            .init(lifecycle: .failed, payload: .notice(.init(title: "Error", message: "Failed", severity: "error"))),
            .init(lifecycle: .failed, payload: .notice(.init(title: "Warning", message: "Careful", severity: "warning"))),
            .init(lifecycle: .succeeded, payload: .notice(.init(title: "Info", message: "Ready", severity: "information"))),
            .init(lifecycle: .running, payload: .timeline(.init(
                eventKind: "job-finished", name: "Nightly", channel: "ops", automation: "backup", detail: "Done"
            ))),
            .init(lifecycle: .running, payload: .cloudAgent(.init(
                agentID: "agent", title: "Remote", detail: "Running"
            ))),
            .init(lifecycle: .succeeded, payload: .fileOperation(.init(
                operationID: "file", operation: "write", path: "notes.txt", diff: "+line",
                isBackground: true, streamSummary: "written"
            ))),
            .init(lifecycle: .failed, payload: .shell(.init(
                operationID: "shell", commandSummary: "echo hi", workingDirectory: "/tmp",
                exitCode: 1, isBackground: true, streamSummary: "stderr"
            ))),
            .init(lifecycle: .pending, payload: .unknown(
                type: "future_card", payload: .object(["token": .string("redacted")])
            )),
        ]

        let values = cards.map(TranscriptCardPresenter.presentation)
        #expect(values[0].longTextTitle == "Message")
        #expect(values[0].fields.map { [$0.label, $0.value] } == [["Recipients", "one@example.com"]])
        #expect(values[1].fields.map { [$0.label, $0.value] } == [["Filter", "mentions"]])
        #expect(values[2].fields.map(\.label) == ["Service", "Account", "Scope"])
        #expect(values[3].title == "Retired Permission")
        #expect(values[4].symbolName == "xmark.octagon")
        #expect(values[5].symbolName == "exclamationmark.triangle")
        #expect(values[6].symbolName == "info.circle")
        #expect(values[7].fields.count == 3)
        #expect(values[8].fields.map { [$0.label, $0.value] } == [["Agent", "agent"]])
        #expect(values[9].symbolName == "doc.badge.plus")
        #expect(values[9].longText == "+line")
        #expect(values[10].fields.map(\.label) == ["Mode", "Directory", "Exit code"])
        #expect(values[11].kind == .unknown)
        #expect(values[11].title == "Unsupported Card")
    }

    @Test func toolCardProjectionHandlesNestedValuesAndMalformedFallbacks() {
        let nested = ToolActivity(
            id: "nested", name: "lookup",
            argumentsJSON: #"{"query":["one","two","three","four"],"path":7,"nested":[{"url":"https://example.com"}]}"#,
            status: .succeeded,
            result: #"{"secret":"hidden","value":42}"#
        )
        let card = ToolCardClassifier.presentation(for: nested)
        #expect(card.kind == ToolCardKind.generic)
        #expect(card.fields.contains { $0.label == "Query" && $0.value == "one, two, three" })
        #expect(card.fields.contains { $0.label == "Path" && $0.value == "7" })
        #expect(card.links.map { $0.absoluteString } == ["https://example.com"])
        #expect(card.redactedResult?.contains("••••••••") == true)
        #expect(card.redactedResult?.contains("42") == true)

        let malformed = ToolCardClassifier.presentation(
            for: .init(id: "plain", name: "lookup", argumentsJSON: "literal\u{0001}value")
        )
        #expect(malformed.redactedArguments == "literalvalue")
    }

    @Test func attachmentPreviewSelectionAndErrorsRemainExplicit() {
        let first = AttachmentPreviewFile(filename: "first.txt", fileURL: URL(fileURLWithPath: "/tmp/first"))
        let second = AttachmentPreviewFile(filename: "second.txt", fileURL: URL(fileURLWithPath: "/tmp/second"))
        let item = AttachmentPreviewItem(files: [first, second], initialFileID: UUID())
        #expect(item.initialFileID == first.id)
        #expect(item.filename == first.filename)
        #expect(item.fileURL == first.fileURL)
        #expect(AttachmentPreviewError.invalidFilename("../bad").errorDescription?.contains("invalid filename") == true)
        #expect(AttachmentPreviewError.integrityMismatch.errorDescription?.contains("content-addressed") == true)
        #expect(AttachmentPreviewError.previewFileUnavailable.errorDescription?.contains("could not be created") == true)
    }
}
