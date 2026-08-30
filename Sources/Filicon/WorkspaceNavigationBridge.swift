import FiliconSettings

extension WorkspaceRoute {
    init(_ destination: WorkspaceNavigationDestination) {
        self = switch destination {
        case .conversation(let id): .conversation(id)
        case .search: .search
        case .agents: .agents
        case .groups: .groups
        case .automations: .automations
        case .channels: .channels
        case .mcp: .mcp
        case .computer: .computer
        case .plugins: .plugins
        case .hiddenChats: .hiddenChats
        case .sharedRooms: .sharedRooms
        case .account: .account
        }
    }

    var navigationDestination: WorkspaceNavigationDestination {
        switch self {
        case .conversation(let id): .conversation(id)
        case .search: .search
        case .agents: .agents
        case .groups: .groups
        case .automations: .automations
        case .channels: .channels
        case .mcp: .mcp
        case .computer: .computer
        case .plugins: .plugins
        case .hiddenChats: .hiddenChats
        case .sharedRooms: .sharedRooms
        case .account: .account
        }
    }
}
