import Foundation
import Testing
import FiliconDomain
@testable import Filicon

@Suite("Workspace navigation app bridge")
struct WorkspaceNavigationBridgeTests {
    @Test func everyRouteRoundTripsWithoutChangingConversationIdentity() {
        let id = UUID()
        let routes: [WorkspaceRoute] = [
            .conversation(id), .search, .agents, .groups, .automations,
            .channels, .mcp, .computer, .plugins, .hiddenChats,
            .sharedRooms, .account,
        ]
        for route in routes {
            #expect(WorkspaceRoute(route.navigationDestination) == route)
        }
        #expect(WorkspaceRoute(.conversation(id)) == .conversation(id))
    }

    @Test @MainActor func appNavigationRecordsBranchesAndRestoresRoutesWithoutDuplicatingHistory() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-navigation-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)

        model.selectRoute(.agents)
        model.selectRoute(.plugins)
        #expect(model.canGoBack)
        model.goBack()
        #expect(model.route == .agents)
        #expect(model.canGoForward)

        model.selectRoute(.computer)
        #expect(model.route == .computer)
        #expect(!model.canGoForward)
        model.goBack()
        #expect(model.route == .agents)
        model.goForward()
        #expect(model.route == .computer)
    }

    @Test @MainActor func deletingConversationRemovesItsHistoricalDestination() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-navigation-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let conversation = Conversation(title: "Temporary")
        model.conversations = [conversation]
        model.selectRoute(.conversation(conversation.id))

        model.deleteConversation(id: conversation.id)

        #expect(!model.navigationHistory.entries.contains(.conversation(conversation.id)))
        #expect(model.route != .conversation(conversation.id))
    }
}
