import Foundation
import SwiftUI
import AppKit
import FiliconDomain
import FiliconProviderKit
import FiliconAppServices
import FiliconAgents
import FiliconChannels
import FiliconAutomations
import FiliconMCP
import FiliconVoice
import FiliconLocalTools
import FiliconSettings
import FiliconComputer
import FiliconPlugins
import FiliconUpdater
import FiliconSharedRooms
import FiliconAccount
import FiliconAutoReview
import FiliconSecurityKey
import FiliconPersistence

enum WorkspaceRoute: Hashable {
    case conversation(UUID)
    case search
    case agents
    case groups
    case automations
    case channels
    case mcp
    case computer
    case plugins
    case hiddenChats
    case sharedRooms
    case account
}

enum GlobalSearchTab: String, CaseIterable, Identifiable {
    case conversations = "Conversations"
    case messages = "Messages"
    case files = "Files"

    var id: Self { self }
}

enum GlobalSearchState: Equatable {
    case idle
    case loading
    case results
    case empty
    case failed(String)
    case unavailable(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selection: UUID?
    @Published var descriptors: [ProviderDescriptor] = []
    @Published var availableModels: [AIModel] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelCatalogSource: ProviderCatalogSource?
    @Published private(set) var isModelCatalogStale = false
    @Published private(set) var modelCatalogError: String?
    @Published private(set) var modelCatalogLastUpdated: Date?
    @Published private(set) var modelCatalogProviderID: ProviderID?
    @Published private(set) var modelCatalogConversationID: UUID?
    @Published var draft = "" {
        didSet { scheduleDraftPersistence() }
    }
    @Published var errorMessage: String? {
        didSet {
            guard let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty, message != oldValue else { return }
            Task { [weak self] in await self?.publishNotificationError(message) }
        }
    }
    @Published private(set) var startupSettlement: StartupDataRootSettlement
    @Published private(set) var startupBanner: String?
    @Published private(set) var persistenceRecoveryReport: PersistenceRecoveryReport?
    @Published private(set) var rootConnection = WorkspaceRootConnection()
    @Published private(set) var quotaUsage: StorageQuotaUsage?
    @Published var running: Set<UUID> = []
    @Published var route: WorkspaceRoute? = .search
    @Published private(set) var navigationHistory = WorkspaceNavigationHistory()
    @Published var searchQuery = "" {
        didSet { scheduleGlobalSearch() }
    }
    @Published var searchResults: [Conversation] = []
    @Published var globalSearchTab: GlobalSearchTab = .conversations {
        didSet { scheduleGlobalSearch() }
    }
    @Published private(set) var globalMessageSearchResults: [GlobalMessageSearchHit] = []
    @Published private(set) var globalMediaSearchResults: [GlobalMediaSearchHit] = []
    @Published private(set) var globalSearchState: GlobalSearchState = .idle
    @Published private(set) var globalSearchFocusRequestID = UUID()
    @Published private(set) var requestedMessageJumpID: UUID?
    @Published var agents: [AgentProfile] = []
    @Published var requestedAgentInspectionID: UUID?
    @Published var pinnedAgentIDs: Set<UUID> = []
    @Published var agentAsyncTasks: [AgentAsyncTask] = []
    @Published private(set) var agentMessages: [AgentMessage] = []
    @Published private(set) var agentMessageUnreadCounts: [UUID: Int] = [:]
    @Published private(set) var notificationTrays: [InAppNotificationTray] = []
    @Published var groups: [AgentGroup] = []
    @Published var selectedGroupID: UUID?
    @Published var groupMessages: [UUID: [RoomMessage]] = [:]
    @Published var runningGroups: Set<UUID> = []
    private var stoppingGroups: Set<UUID> = []
    private var cancelledGroupRuns: Set<UUID> = []
    @Published var thinkingGroupMembers: [UUID: UUID] = [:]
    @Published var reviewingMemoryGroups: Set<UUID> = []
    @Published var automations: [Automation] = []
    @Published var automationHistory: [UUID: [AutomationRun]] = [:]
    @Published var automationWakes: [AutomationWake] = []
    @Published var automationSpendGuard = AutomationSpendGuardState()
    @Published var automationIngressRoutes: [AutomationIngressRoute] = []
    @Published var automationIngressAudit: [AutomationIngressAuditEntry] = []
    @Published var automationIngressStatus = AutomationIngressStatus()
    @Published var workflows: [AgentWorkflow] = []
    @Published var workflowRuns: [AgentWorkflowRun] = []
    @Published var workflowIsLoading = false
    @Published var workflowError: String?
    @Published var channelConnections: [ChannelConnection] = []
    @Published var channelDescriptors: [ChannelConnectorDescriptor] = []
    @Published var channelInboundEvents: [ChannelEnvelope] = []
    @Published var channelDeliveries: [ChannelDelivery] = []
    @Published var channelFailureWakes: [ChannelFailureWake] = []
    @Published var channelOAuthInProgress = false
    @Published var mcpConfigs: [MCPServerConfig] = []
    @Published var mcpCatalog = MCPCatalogSnapshot(revision: 0, tools: [], statuses: [:])
    @Published var mcpAccountDefinitions: [MCPServerDefinition] = []
    @Published private(set) var mcpOAuthInProgressSlotIDs: Set<UUID> = []
    @Published var pendingMCPApprovals: [MCPApprovalPresentation] = []
    @Published var mcpPermissionModes: [String: MCPPermissionMode] = [:]
    @Published var pendingAttachments: [AttachmentMetadata] = []
    @Published var isImportingAttachments = false
    @Published private(set) var attachmentPreview: AttachmentPreviewItem?
    @Published var replyingToMessageID: UUID?
    @Published var localToolPermissions: [LocalToolAction: LocalToolPermission] = [:]
    @Published var workspaceAuthorizations: [WorkspaceAuthorization] = []
    @Published var pendingToolApprovals: [ToolApprovalRequest] = []
    @Published var pendingWorkspaceFolders: [WorkspaceFolderRequest] = []
    @Published var settings = FiliconSettings()
    @Published private(set) var autoReviewInstructions = AutoReviewInstructions()
    @Published private(set) var pendingAutoReviewApprovals: [PendingApproval] = []
    @Published var computerSnapshot = ComputerSessionSnapshot()
    @Published var teachStatus = TeachRecordingStatus()
    @Published private(set) var vncControlSnapshot: VNCControlSnapshot?
    @Published var activeVNCURL: URL?
    @Published var activeVNCToken: String?
    @Published private(set) var activeVNCAccountID: String?
    @Published private(set) var activeVNCComputerID: String?
    @Published var pluginCatalogEntries: [PluginCatalogEntry] = []
    @Published var requestedPluginID: String?
    @Published var installedPlugins: [InstalledPlugin] = []
    @Published var indexedPluginSkills: [IndexedPluginSkill] = []
    @Published var privateSkills: [PrivateSkillRecord] = []
    @Published var skillPublishTargets: [SkillPublishTarget] = []
    @Published var skillPublicationStates: [SkillPublicationState] = []
    @Published var skillPublishingEndpoint = UserDefaults.standard.string(forKey: "FiliconSkillPublishingEndpoint") ?? ""
    @Published var isRefreshingSkillPublishing = false
    @Published var pluginCatalogURLString = UserDefaults.standard.string(forKey: "FiliconPluginCatalogURL") ?? ""
    @Published var isRefreshingPlugins = false
    @Published var cloudAgentEndpoint = UserDefaults.standard.string(forKey: "FiliconCloudAgentEndpoint") ?? ""
    @Published var cloudAgentCredentialReference = UserDefaults.standard.string(forKey: "FiliconCloudAgentCredentialReference") ?? "default"
    @Published var cloudAgentCatalog: [CloudAgentDescriptor] = []
    @Published var isRefreshingCloudAgents = false
    @Published var updateState: UpdateState = .idle
    @Published var updateFeedURLString = UserDefaults.standard.string(forKey: "FiliconUpdateFeedURL") ?? ""
    @Published var updatePublicKeyBase64 = UserDefaults.standard.string(forKey: "FiliconUpdatePublicKeyBase64") ?? ""
    @Published private(set) var minimumRequiredVersion = UserDefaults.standard.string(forKey: "FiliconMinimumRequiredVersion")
    @Published private(set) var isBootstrapped = false
    @Published private(set) var hasMoreConversations = false
    @Published private(set) var isLoadingMoreConversations = false
    @Published private(set) var loadingMessageHistory: Set<UUID> = []
    @Published var sharedRoomsEnabled = UserDefaults.standard.object(forKey: "FiliconSharedRoomsEnabled") as? Bool ?? false
    @Published var sharedRoomIdentity = SharedRoomIdentity(
        id: UUID(uuidString: UserDefaults.standard.string(forKey: "FiliconSharedRoomIdentityID") ?? "") ?? UUID(),
        displayName: UserDefaults.standard.string(forKey: "FiliconSharedRoomDisplayName") ?? NSFullUserName(),
        accountGeneration: UInt64(UserDefaults.standard.integer(forKey: "FiliconSharedRoomAccountGeneration")).clampedAtLeastOne
    )
    @Published var sharedRoomTransportMode = UserDefaults.standard.string(forKey: "FiliconSharedRoomTransportMode") ?? "local"
    @Published var sharedRoomServerURL = UserDefaults.standard.string(forKey: "FiliconSharedRoomServerURL") ?? ""
    @Published var sharedRoomCredentialReference = UserDefaults.standard.string(forKey: "FiliconSharedRoomCredentialReference") ?? "default"
    @Published var sharedRooms: [SharedRoomSnapshot] = []
    @Published var selectedSharedRoomID: UUID?
    @Published var lastSharedRoomInvite: SharedRoomInvite?
    @Published var remoteComputerEndpoint = UserDefaults.standard.string(forKey: "FiliconRemoteComputerEndpoint") ?? ""
    @Published var remoteComputerCredentialReference = UserDefaults.standard.string(forKey: "FiliconRemoteComputerCredentialReference") ?? "default"
    @Published var remoteComputerCredentialHeader = UserDefaults.standard.string(forKey: "FiliconRemoteComputerCredentialHeader") ?? "Authorization"
    @Published var remoteComputerCredentialScheme = UserDefaults.standard.string(forKey: "FiliconRemoteComputerCredentialScheme") ?? "Bearer"
    @Published var remoteComputerCapabilities = RemoteComputerCapabilities(
        rawValue: UInt16(truncatingIfNeeded: max(0, UserDefaults.standard.object(forKey: "FiliconRemoteComputerCapabilities") as? Int ?? 63))
    )
    @Published var remoteIsolationRequiredIdentity = UserDefaults.standard.string(forKey: "FiliconRemoteIsolationIdentity") ?? ""
    @Published var remoteIsolationMinimumGeneration: UInt64 = max(
        1, (UserDefaults.standard.object(forKey: "FiliconRemoteIsolationGeneration") as? NSNumber)?.uint64Value ?? 1
    )
    @Published private(set) var remoteSecuritySnapshot = RemoteSecuritySnapshot(state: .unverified)
    @Published var remoteComputerStatus: RemoteComputerStatus?
    @Published var remoteComputerOperation: RemoteOperation?
    @Published var remoteTerminalSessionID: String?
    @Published var remoteTerminalOutput = ""
    @Published var remoteTerminalExitCode: Int32?
    @Published var remoteFileTransferStatus: String?
    @Published var securityKeyEnabled = UserDefaults.standard.bool(forKey: "FiliconSecurityKeyEnabled")
    @Published var securityKeyStatus: SecurityKeyStatus = .disabled
    @Published var accountState: AccountState = .loggedOut(retainedButRevoked: false)
    @Published var accountEntitlement: Entitlement?
    @Published var accountUsage: UsageProjection?
    @Published var accountConnection = ConnectionSnapshot()
    @Published var onboardingProgress = OnboardingProgress()
    @Published var showingOnboarding = false
    @Published var showingFeedback = false
    @Published var accountAuthorizationURL = UserDefaults.standard.string(forKey: "FiliconAccountAuthorizationURL") ?? ""
    @Published var accountTokenURL = UserDefaults.standard.string(forKey: "FiliconAccountTokenURL") ?? ""
    @Published var accountProfileURL = UserDefaults.standard.string(forKey: "FiliconAccountProfileURL") ?? ""
    @Published var accountEntitlementURL = UserDefaults.standard.string(forKey: "FiliconAccountEntitlementURL") ?? ""
    @Published var accountUsageURL = UserDefaults.standard.string(forKey: "FiliconAccountUsageURL") ?? ""
    @Published var accountFeedbackURL = UserDefaults.standard.string(forKey: "FiliconAccountFeedbackURL") ?? ""
    @Published var accountClientID = UserDefaults.standard.string(forKey: "FiliconAccountClientID") ?? ""

    let credentials = KeychainCredentialStore()
    let systemNotifications = SystemNotificationService()
    let inAppNotifications = InAppNotificationCenter()
    let registry = ProviderRegistry()
    let toolCatalog = ToolCatalog()
    let voiceComposer = VoiceComposerController()
    let localToolRuntime: LocalToolRuntime
    let localToolPermissionPolicy: ToolPermissionPolicy
    let computerController: ComputerSessionController
    let teachController: TeachRecordingController
    let teachMaskingController: TeachSensitiveMaskingController
    let pluginStore: PluginStore
    let pluginSetupStore: PluginSetupStore
    let pluginInstaller: PluginInstaller
    let pluginSkillIndex: PluginSkillIndexService
    let privateSkillLibrary: PrivateSkillLibrary
    let skillPublicationStore: SkillPublicationStore
    let updateManager: UpdateManager
    private let backendUpdatePolicyStore: BackendUpdatePolicyStore
    private lazy var backendUpdateRequirementCoordinator = BackendUpdateRequirementCoordinator(
        store: backendUpdatePolicyStore,
        installedVersion: installedVersion.version
    ) { [weak self] minimumVersion, _ in
        await self?.applyBackendUpdateRequirement(minimumVersion)
    }
    let updateInstallCoordinator = UpdateInstallCoordinator()
    private var updateIdleMonitor: NativeUpdateIdleMonitor!
    let securityKeyConsentPresenter = AppSecurityKeyConsentPresenter()
    let dataRoot: URL
    private let store: ConversationStore
    private let attachmentStore: AttachmentStore
    private let channelAttachmentStore: AttachmentStore
    private let agentImageStore: AgentImageStore
    private let attachmentLifecycle: AttachmentLifecycle?
    private let attachmentPreviewMaterializer = AttachmentPreviewMaterializer()
    private let draftStore: ComposerDraftStore
    private let quotaLedger: StorageQuotaLedger?
    private let quotaWriter: AppQuotaWriter?
    private let rootResilience = WorkspaceRootResilience()
    private let agentService: AgentService?
    private let agentMessenger: AgentMessenger?
    private let agentConversations: AgentConversationStore?
    private var agentMessagingSessions: [UUID: AgentMessagingSession] = [:]
    private var delegatedGroupOrigins: [UUID: UUID] = [:]
    private var delegatedGroupPosts: [UUID: AgentGroupDispatch] = [:]
    @Published private(set) var runningAgentMessageScopes: Set<UUID> = []
    private var agentMessageTasks: [UUID: Task<Void, Never>] = [:]
    private var agentMessagingAccountTransition = false
    private var agentMemoryUILifetime = AgentMemoryChangeLifetime()
    private var agentMemorySuggestionUILifetime = AgentMemorySuggestionLifetime()
    private let subagentService: SubagentService?
    private let agentAvatarStore: AgentAvatarStore
    private let groupService: GroupService?
    private var groupQuestionLifetimes: [UUID: AgentPublicationLifetime] = [:]
    private let automationService: AutomationService?
    private var routineEditSessions: [UUID: RoutineEditSession] = [:]
    var workflowService: WorkflowService? = nil
    private var automationScheduler: AutomationScheduler?
    private var automationTriggerHub: AutomationTriggerHub?
    private var automationIngress: AutomationIngressController?
    private let channelService: ChannelService?
    private let channelOAuthCoordinator = ChannelOAuthCoordinator()
    private let mcpConfigStore: MCPConfigurationStore
    private let mcpAccountLibrary: MCPAccountLibrary
    private let mcpPolicyStore: MCPUserPolicyStore
    private let mcpOAuthCoordinator: MCPOAuthPendingCoordinator
    private let mcpOAuthFlowCoordinator: MCPOAuthFlowCoordinator
    private let mcpOAuthBrowserOpener: @MainActor @Sendable (URL) -> Bool
    private var mcpOAuthAttemptIDs: [UUID: UUID] = [:]
    private var mcpOAuthListeners: [UUID: ChannelOAuthLoopbackServer] = [:]
    private let settingsStore: SettingsStore
    private let navigationStore: WorkspaceNavigationStore
    private let autoReviewInstructionsStore: AtomicAutoReviewInstructionsStore
    private let autoReviewBroker = PendingApprovalBroker()
    private var skillPublishService: SkillPublishService?
    private var pendingAutoReviewByID: [String: PendingApproval] = [:]
    private var autoReviewAccountGeneration: UInt64 = 1
    private lazy var mcpService = MCPService(factory: DefaultMCPConnectionFactory { [credentials] reference in
        try await credentials.value(for: CredentialRef(providerID: ProviderID(rawValue: "mcp.\(reference)")))
    })
    private let mcpAuthorization = MCPAuthorizationCoordinator()
    private lazy var mcpDispatcher = MCPAuthorizedDispatcher(service: mcpService, authorization: mcpAuthorization)
    private lazy var mcpApprovalBroker = AppMCPApprovalBroker { [weak self] requests in
        Task { @MainActor in self?.pendingMCPApprovals = requests }
    }
    let agentExecutionScheduler = AgentExecutionScheduler()
    private lazy var coordinator = TurnCoordinator(registry: registry, toolCatalog: toolCatalog, agentScheduler: agentExecutionScheduler)
    private var modelRefreshGuard = ModelRefreshGuard()
    private var turnTasks: [UUID: Task<Void, Never>] = [:]
    private var draftSaveTask: Task<Void, Never>?
    private var navigationSaveTask: Task<Void, Never>?
    private var draftLoadGeneration = 0
    private var globalSearchGeneration = 0
    private var globalSearchTask: Task<Void, Never>?
    private var attachmentPreviewGeneration = 0
    private var stagedAttachments: [String: StagedAttachment] = [:]
    private var isRestoringDraft = false
    private var draftCache: [UUID: String] = [:]
    private var pendingTurnUsage: [UUID: Usage] = [:]
    private var computerStatusTask: Task<Void, Never>?
    private var inAppNotificationTask: Task<Void, Never>?
    private var agentStateObservationTask: Task<Void, Never>?
    private var teachStatusTask: Task<Void, Never>?
    private var teachMaskingRefreshTask: Task<Void, Never>?
    private var vncLeaseHeartbeatTask: Task<Void, Never>?
    private var agentNotificationBaselineSeeded = false
    private var automationRefreshTask: Task<Void, Never>?
    var workflowScheduleTask: Task<Void, Never>?
    var workflowNextRuns: [String: Date] = [:]
    private var pluginCatalogCache: PluginCatalogCache?
    private var channelFlushTask: Task<Void, Never>?
    private var conversationContinuation: ConversationMetadataContinuation?
    private var messageContinuations: [UUID: MessageHistoryContinuation] = [:]
    private var loadedMessageIDs: [UUID: Set<UUID>] = [:]
    private var completeMessageHistories: Set<UUID> = []
    private var conversationLoadFence = ConversationLoadFence()
    private var messageLoadGenerationByID: [UUID: Int] = [:]
    private var deletedConversationIDs: Set<UUID> = []
    private let transcriptCardActionRouter = TranscriptCardActionRouter()
    private var sharedRoomClient: SharedRoomClient?
    private var sharedRoomLocalStateURL: URL!
    private var remoteComputerBackend: HTTPSRemoteComputerBackend?
    private var remoteComputerLifecycle: RemoteComputerLifecycle?
    private var remoteTerminalController: RemoteTerminalController?
    private var remoteFileTransfer: RemoteFileTransfer?
    private var securityKeyProxy: RemoteSecurityKeyProxy?
    private var securityKeyProxyGeneration: UInt64 = 0
    private var remoteOperationTask: Task<Void, Never>?
    private var remoteTerminalPollingTask: Task<Void, Never>?
    private let remoteTerminalOwnerID = UUID().uuidString.lowercased()
    private let vncControllerID = UUID().uuidString.lowercased()
    private lazy var vncTakeoverController = VNCTakeoverController(
        now: Self.nowMilliseconds,
        handback: { [weak self] _, _ in
            await self?.performVNCHandback()
        }
    )
    private var deepLinkCoordinator = DeepLinkCoordinator()
    private var accountController: AccountController?
    private var accountConnectionMachine = ConnectionStateMachine()
    private let onboardingController: OnboardingController
    private lazy var localToolApprovalBroker = ToolApprovalBroker { [weak self] requests in
        Task { @MainActor in self?.pendingToolApprovals = requests }
    }
    lazy var workspaceFolders: WorkspaceFolderCoordinator = WorkspaceFolderCoordinator(store: localToolRuntime.workspaceStore, onChange: { [weak self] requests in
        self?.pendingWorkspaceFolders = requests
    })

    convenience init(
        applicationSupportRoot: URL,
        bootstrapImmediately: Bool = true,
        localToolRuntime: LocalToolRuntime? = nil,
        mcpOAuthTransport: any MCPOAuthTokenTransport = URLSessionMCPOAuthTokenTransport(),
        mcpOAuthBrowserOpener: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        let context: AppStartupContext = (try? .isolated(root: applicationSupportRoot, reason: .isolatedUserData))
            ?? .init(root: applicationSupportRoot, settlement: .init(route: .unchanged, reason: .isolatedUserData, root: applicationSupportRoot), warning: "The isolated data root could not be fully verified.")
        self.init(
            startupContext: context,
            bootstrapImmediately: bootstrapImmediately,
            localToolRuntime: localToolRuntime,
            mcpOAuthTransport: mcpOAuthTransport,
            mcpOAuthBrowserOpener: mcpOAuthBrowserOpener
        )
    }

    init(
        startupContext: AppStartupContext,
        bootstrapImmediately: Bool = true,
        localToolRuntime: LocalToolRuntime? = nil,
        mcpOAuthTransport: any MCPOAuthTokenTransport = URLSessionMCPOAuthTokenTransport(),
        mcpOAuthBrowserOpener: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        let root = startupContext.root
        dataRoot = root
        startupSettlement = startupContext.settlement
        startupBanner = startupContext.warning
        store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        draftStore = ComposerDraftStore(url: root.appending(path: "composer-drafts.json"))
        let liveQuota = try? StorageQuotaLedger.live(dataRoot: root)
        quotaLedger = liveQuota
        quotaWriter = liveQuota.map(AppQuotaWriter.init)
        attachmentStore = AttachmentStore(rootURL: root.appending(path: "attachments", directoryHint: .isDirectory))
        channelAttachmentStore = AttachmentStore(rootURL: root.appending(path: "channel-attachments", directoryHint: .isDirectory))
        agentImageStore = AgentImageStore(rootURL: root.appending(path: "agent-message-images", directoryHint: .isDirectory))
        attachmentLifecycle = try? AttachmentLifecycle.live(
            applicationSupportDirectory: root,
            configuration: .init(quotaCheck: { usage, requested in
                try AppModel.checkAttachmentQuota(usage: usage, requested: requested)
            })
        )
        let workspaceStore = WorkspaceAuthorizationStore(fileURL: root.appending(path: "workspace-bookmarks.json"))
        self.localToolRuntime = localToolRuntime ?? LocalToolRuntime(workspaceStore: workspaceStore)
        localToolPermissionPolicy = ToolPermissionPolicy(persistenceURL: root.appending(path: "local-tool-permissions.json"))
        computerController = ComputerSessionController(backend: LocalMacComputerBackend())
        let teachBackend = ScreenCaptureKitBackend()
        teachController = TeachRecordingController(
            backend: teachBackend,
            sessionsDirectory: root.appending(path: "teach-recordings", directoryHint: .isDirectory)
        )
        teachMaskingController = .screenCaptureKit(backend: teachBackend)
        pluginStore = PluginStore(fileURL: root.appending(path: "plugins-installed.json"))
        pluginSetupStore = PluginSetupStore(
            fileURL: root.appending(path: "plugin-setup.json"),
            secrets: AppPluginSecretStore(credentials: credentials)
        )
        pluginInstaller = PluginInstaller(
            pluginsRoot: root.appending(path: "plugins", directoryHint: .isDirectory),
            store: pluginStore,
            setupStore: pluginSetupStore
        )
        pluginSkillIndex = PluginSkillIndexService(
            pluginStore: pluginStore,
            cacheURL: root.appending(path: "plugin-skills-cache.json")
        )
        privateSkillLibrary = PrivateSkillLibrary(root: root.appending(path: "private-skills", directoryHint: .isDirectory))
        skillPublicationStore = SkillPublicationStore(fileURL: root.appending(path: "skill-publications.json"))
        updateManager = UpdateManager(service: UpdateService(), stagingRoot: root.appending(path: "updates", directoryHint: .isDirectory))
        backendUpdatePolicyStore = BackendUpdatePolicyStore(
            fileURL: root.appending(path: "updates/backend-requirements.json")
        )
        agentAvatarStore = AgentAvatarStore(rootURL: root.appending(path: "agent-avatars", directoryHint: .isDirectory))
        agentService = try? AgentService(storeURL: root.appending(path: "agents.json"))
        agentConversations = try? AgentConversationStore(url: root.appending(path: "agent-conversations.json"))
        if let agentService {
            agentMessenger = try? AgentMessenger(service: agentService, storeURL: root.appending(path: "agent-messages.json"))
            subagentService = SubagentService(agents: agentService, scheduler: agentExecutionScheduler)
            groupService = try? GroupService(agents: agentService, storeURL: root.appending(path: "groups.json"))
        } else {
            agentMessenger = nil
            subagentService = nil
            groupService = nil
        }
        pinnedAgentIDs = Set((UserDefaults.standard.stringArray(forKey: "FiliconPinnedAgentIDs") ?? []).compactMap(UUID.init(uuidString:)))
        automationService = try? AutomationService(storeURL: root.appending(path: "automations.json"))
        channelService = try? ChannelService(storeURL: root.appending(path: "channels.json"))
        mcpConfigStore = MCPConfigurationStore(url: root.appending(path: "mcp-servers.json"))
        let mcpOAuthCoordinator = MCPOAuthPendingCoordinator()
        self.mcpOAuthCoordinator = mcpOAuthCoordinator
        mcpOAuthFlowCoordinator = MCPOAuthFlowCoordinator(
            pendingCoordinator: mcpOAuthCoordinator,
            transport: mcpOAuthTransport
        )
        self.mcpOAuthBrowserOpener = mcpOAuthBrowserOpener
        mcpAccountLibrary = MCPAccountLibrary(
            fileURL: root.appending(path: "mcp-accounts.json"),
            tokenStore: MCPKeychainTokenReferenceStore(credentials: credentials)
        )
        mcpPolicyStore = MCPUserPolicyStore(url: root.appending(path: "mcp-approval-policies.json"))
        settingsStore = SettingsStore(fileURL: root.appending(path: "settings.json"))
        navigationStore = WorkspaceNavigationStore(fileURL: root.appending(path: "workspace-navigation.json"))
        autoReviewInstructionsStore = AtomicAutoReviewInstructionsStore(
            fileURL: root.appending(path: "auto-review-instructions.json")
        )
        onboardingController = OnboardingController(store: FileOnboardingStore(fileURL: root.appending(path: "onboarding.json")))
        sharedRoomLocalStateURL = root.appending(path: "shared-rooms/state.json")
        persistSharedRoomIdentity()
        if let agentService {
            workflowService = try? WorkflowService.persistent(
                workflowsURL: root.appending(path: "workflows.json"),
                runHistoryURL: root.appending(path: "runs.json"),
                promptExecutor: AppWorkflowPromptExecutor(registry: registry, agents: agentService, scheduler: agentExecutionScheduler),
                actionHandler: AppWorkflowNoAuthorityActionHandler()
            )
        }
        if let automationService, let agentService {
            let executor = AppAutomationExecutor(registry: registry, agents: agentService, scheduler: agentExecutionScheduler)
            automationScheduler = AutomationScheduler(service: automationService, executor: executor)
            let hub = AutomationTriggerHub(service: automationService, executor: executor)
            automationTriggerHub = hub
            let ingressSecrets = ClosureAutomationIngressSecretProvider { [credentials] reference in
                let value = try await credentials.value(for: CredentialRef(providerID: ProviderID(rawValue: "automation.ingress.\(reference)")))
                return Data(value.utf8)
            }
            automationIngress = try? AutomationIngressController(
                stateURL: root.appending(path: "automation-ingress.json"),
                auditURL: root.appending(path: "automation-ingress-audit.json"),
                secrets: ingressSecrets
            ) { event in await hub.ingest(event) }
        }
        if let url = URL(string: pluginCatalogURLString), url.scheme?.lowercased() == "https" {
            pluginCatalogCache = PluginCatalogCache(client: URLPluginCatalogClient(url: url))
        }
        rebuildRemoteComputerClient()
        rebuildSecurityKeyProxy()
        rebuildAccountController()
        updateIdleMonitor = NativeUpdateIdleMonitor { [weak self] in
            Task { await self?.attemptIdleUpdateInstallIfSafe() }
        }
        observeInAppNotifications()
        if bootstrapImmediately { Task { await bootstrap() } }
    }

    var selectedConversation: Conversation? { conversations.first { $0.id == selection } }
    var selectedModel: AIModel? {
        guard let conversation = selectedConversation,
              modelCatalogProviderID == conversation.providerID,
              modelCatalogConversationID == conversation.id else { return nil }
        let modelID = conversation.modelID
        return availableModels.first { $0.id == modelID }
    }
    var selectedModelSupportsAttachments: Bool {
        guard let model = selectedModel else { return true }
        return !model.capabilities.inputModalities.isDisjoint(with: [.image, .audio, .video, .document])
    }
    var selectedModelSupportsAudio: Bool {
        guard let model = selectedModel else { return true }
        return model.capabilities.inputModalities.contains(.audio)
    }
    var selectedModelAttachmentError: String? {
        guard let model = selectedModel, !selectedModelSupportsAttachments else { return nil }
        return "\(model.displayName) does not accept attachments. Choose a model with image, audio, video, or document input."
    }
    var selectedModelAudioError: String? {
        guard let model = selectedModel, !selectedModelSupportsAudio else { return nil }
        return "\(model.displayName) does not accept audio. Choose a model with audio input to use voice messages."
    }
    var supportedReasoningEfforts: [ReasoningEffort] {
        ProviderCatalogPresentation.reasoningEfforts(for: selectedModel)
    }
    var modelCatalogStatusLabel: String {
        ProviderCatalogPresentation.statusLabel(
            source: modelCatalogSource,
            isStale: isModelCatalogStale,
            error: modelCatalogError
        )
    }
    var selectedConversationConfigurationError: String? {
        guard let conversation = selectedConversation else { return "No conversation is selected." }
        return ProviderCatalogPresentation.validationError(
            conversation: conversation,
            models: availableModels,
            catalogProviderID: modelCatalogProviderID,
            catalogConversationID: modelCatalogConversationID,
            loading: isLoadingModels
        )
    }
    var visibleConversations: [Conversation] { conversations.filter { $0.hiddenAt == nil } }
    var hiddenConversations: [Conversation] { conversations.filter { $0.hiddenAt != nil } }
    var selectedConversationHasOlderMessages: Bool {
        selection.map { messageContinuations[$0] != nil } ?? false
    }
    var isUpdateRequired: Bool {
        UpdateRequirementEvaluator.isBelowMinimum(
            installedVersion: installedVersion.version,
            minimumRequiredVersion: minimumRequiredVersion
        )
    }
    var startupStorePaths: [URL] {
        [
            "conversations.json", "composer-drafts.json", "attachments", "channel-attachments", "attachment-index.sqlite",
            "workspace-bookmarks.json", "local-tool-permissions.json", "teach-recordings", "plugins-installed.json",
            "plugin-setup.json", "plugins", "plugin-skills-cache.json", "private-skills", "skill-publications.json", "updates",
            "agent-avatars", "agents.json", "agent-messages.json", "groups.json", "automations.json", "workflows.json", "runs.json", "channels.json", "mcp-servers.json",
            "mcp-accounts.json", "mcp-approval-policies.json", "settings.json", "workspace-navigation.json", "auto-review-instructions.json", "onboarding.json",
            "shared-rooms/state.json", "automation-ingress.json", "automation-ingress-audit.json", "quota",
        ].map { dataRoot.appending(path: $0) }
    }

    func bootstrap() async {
        let rootTicket = rootResilience.begin(accountGeneration: sharedRoomIdentity.accountGeneration)
        rootConnection = rootResilience.connection
        await reconcileQuota()
        do { settings = try await settingsStore.load() }
        catch { errorMessage = error.localizedDescription }
        do { autoReviewInstructions = try autoReviewInstructionsStore.load() }
        catch { errorMessage = error.localizedDescription }
        let credentials = self.credentials
        await registry.register(FakeProvider())
        await registry.register(OpenAIProvider { try await credentials.value(for: CredentialRef(providerID: "openai")) })
        await registry.register(OpenRouterProvider { try await credentials.value(for: CredentialRef(providerID: "openrouter")) })
        await registry.register(AnthropicProvider { try await credentials.value(for: CredentialRef(providerID: "anthropic")) })
        await registry.register(GeminiProvider { try await credentials.value(for: CredentialRef(providerID: "gemini")) })
        await registry.register(OllamaProvider())
        await registry.register(CodexCLIProvider())
        await registry.register(ClaudeCodeCLIProvider())
        await registerChannelConnectors()
        descriptors = await registry.descriptors()
        if let attachmentLifecycle {
            do {
                // Adopt references from transcripts created before the lifecycle index existed,
                // before reconciliation can quarantine otherwise-unindexed CAS files.
                for conversation in try await store.load() {
                    for message in conversation.messages where !message.attachments.isEmpty {
                        let owner = AttachmentReferenceOwner(conversationID: conversation.id, messageID: message.id)
                        for metadata in message.attachments {
                            do { try await attachmentLifecycle.addReference(metadata, owner: owner) }
                            catch AttachmentStoreError.missing { /* reconcile removes stale records */ }
                        }
                    }
                }
                _ = try await attachmentLifecycle.reconcile()
                _ = try await attachmentLifecycle.collectGarbage()
            } catch { errorMessage = error.localizedDescription }
        }
        await refreshPersistenceRecoveryStatus()
        do {
            let page = try await store.conversationPage()
            conversations = page.items
            conversationContinuation = page.continuation
            hasMoreConversations = page.continuation != nil
        } catch {
            rootResilience.fail(error, ticket: rootTicket)
            rootConnection = rootResilience.connection
            startupBanner = "Conversation storage is unavailable. Your data was not replaced."
            errorMessage = error.localizedDescription
        }
        if conversations.isEmpty {
            addConversationUnchecked()
            await persist(conversationID: selection)
        } else {
            selection = conversations.first(where: { $0.hiddenAt == nil })?.id
            route = selection.map(WorkspaceRoute.conversation)
            if selection == nil { route = .search }
        }
        await restoreWorkspaceNavigation()
        if let selection {
            await loadLatestMessages(for: selection)
            await restoreDraft(for: selection)
        }
        isBootstrapped = true
        await refreshModels()
        await reloadWorkspaceData()
        observeInAppNotifications()
        observeAgentState()
        await resumePersistedCloudRuns()
        await startEnabledChannelConnections()
        observeChannelDeliveries()
        await reloadLocalToolSettings()
        await automationScheduler?.start()
        if let automationIngress {
            try? await automationIngress.restoreIfNeeded(localNetworkOptIn: UserDefaults.standard.bool(forKey: "FiliconAutomationIngressLANOptIn"))
        }
        await reloadAutomationDetails(markViewed: false)
        observeAutomationState()
        await reloadWorkflows()
        startWorkflowScheduleCoordinator()
        observeComputerServices()
        _ = await computerController.ensure(agentID: selectedComputerAgentID)
        _ = try? await teachController.recover()
        await reloadPlugins(forceCatalogRefresh: false)
        await restoreSkillPublishing()
        await restoreBackendUpdateRequirementPolicy()
        await refreshUpdateSchedule()
        await rebuildSharedRoomClient()
        await refreshSharedRooms()
        await restoreAccountAndOnboarding()
        for link in deepLinkCoordinator.markReady() { dispatchDeepLink(link) }
        if rootConnection.phase != .unreachable {
            let queued = rootResilience.succeed(ticket: rootTicket)
            rootConnection = rootResilience.connection
            if queued { await reloadRootWorkspace() }
        }
    }

    func addConversation() {
        guard isBootstrapped else { return }
        addConversationUnchecked()
        Task { await persist(conversationID: selection) }
    }

    private func addConversationUnchecked() {
        persistCurrentDraftImmediately()
        let conversation: Conversation
        if let preferred = settings.defaultModel {
            conversation = Conversation(providerID: ProviderID(rawValue: preferred.providerID), modelID: ModelID(rawValue: preferred.modelID))
        } else {
            conversation = Conversation()
        }
        conversations.insert(conversation, at: 0)
        deletedConversationIDs.remove(conversation.id)
        loadedMessageIDs[conversation.id] = []
        completeMessageHistories.insert(conversation.id)
        messageContinuations[conversation.id] = nil
        selection = conversation.id
        setRoute(.conversation(conversation.id), recordingHistory: true)
        isRestoringDraft = true
        draft = ""
        isRestoringDraft = false
        draftCache[conversation.id] = ""
    }

    func selectRoute(_ value: WorkspaceRoute?) {
        setRoute(value, recordingHistory: true)
        if value == .agents { Task { await markAgentsViewed() } }
        if value == .sharedRooms { Task { await refreshSharedRooms() } }
        if value == .automations { Task { await reloadAutomationDetails(markViewed: true) } }
        if case .some(.conversation(let id)) = value, id != selection {
            persistCurrentDraftImmediately()
            selection = id
            Task {
                await loadLatestMessages(for: id)
                guard selection == id else { return }
                await restoreDraft(for: id)
                await refreshModels()
            }
        } else if case .some(.conversation) = value {
            Task { await refreshModels() }
        }
    }

    func selectGroup(id: UUID) {
        selectedGroupID = id
        selectRoute(.groups)
    }

    var canGoBack: Bool { navigationHistory.canGoBack }
    var canGoForward: Bool { navigationHistory.canGoForward }

    func goBack() {
        guard let destination = navigationHistory.goBack() else { return }
        scheduleNavigationPersistence()
        selectHistoricalRoute(WorkspaceRoute(destination))
    }

    func goForward() {
        guard let destination = navigationHistory.goForward() else { return }
        scheduleNavigationPersistence()
        selectHistoricalRoute(WorkspaceRoute(destination))
    }

    private func restoreWorkspaceNavigation() async {
        navigationHistory = await navigationStore.load()
        let canonical = (try? await store.load()) ?? conversations
        let validIDs = Set(canonical.map(\.id))
        navigationHistory.reconcile(validConversationIDs: validIDs)
        if case .conversation(let id) = navigationHistory.current,
           !conversations.contains(where: { $0.id == id }),
           var conversation = canonical.first(where: { $0.id == id }) {
            conversation.messages = []
            conversations.append(conversation)
        }
        selectHistoricalRoute(WorkspaceRoute(navigationHistory.current))
        scheduleNavigationPersistence()
    }

    private func setRoute(_ value: WorkspaceRoute?, recordingHistory: Bool) {
        route = value
        guard recordingHistory, let value else { return }
        navigationHistory.navigate(to: value.navigationDestination)
        scheduleNavigationPersistence()
    }

    private func selectHistoricalRoute(_ value: WorkspaceRoute) {
        setRoute(value, recordingHistory: false)
        if case .conversation(let id) = value, id != selection {
            persistCurrentDraftImmediately()
            selection = id
            Task {
                await loadLatestMessages(for: id)
                guard selection == id else { return }
                await restoreDraft(for: id)
                await refreshModels()
            }
        }
        if value == .agents { Task { await markAgentsViewed() } }
        if value == .sharedRooms { Task { await refreshSharedRooms() } }
        if value == .automations { Task { await reloadAutomationDetails(markViewed: true) } }
    }

    private func scheduleNavigationPersistence() {
        let snapshot = navigationHistory
        let previous = navigationSaveTask
        navigationSaveTask = Task { [navigationStore] in
            await previous?.value
            try? await navigationStore.save(snapshot)
        }
    }

    func updateRoute(providerID: ProviderID, modelID: ModelID? = nil) {
        guard isBootstrapped else { return }
        guard let selection, let index = conversations.firstIndex(where: { $0.id == selection }) else { return }
        conversations[index].providerID = providerID
        if let modelID {
            conversations[index].modelID = modelID
            if modelCatalogProviderID == providerID,
               let selectedModel = availableModels.first(where: { $0.id == modelID }),
               !selectedModel.capabilities.supports(conversations[index].reasoningEffort) {
                conversations[index].reasoningEffort = .disabled
                errorMessage = l10n("Reasoning was reset to disabled because \(selectedModel.displayName) does not support the previous effort.")
            }
        }
        Task { await refreshModels(); await persist(conversationID: selection) }
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        guard isBootstrapped,
              let selection,
              let index = conversations.firstIndex(where: { $0.id == selection }),
              let model = availableModels.first(where: { $0.id == conversations[index].modelID }),
              model.capabilities.supports(effort) else {
            errorMessage = l10n("The selected model does not support that reasoning effort.")
            return
        }
        conversations[index].reasoningEffort = effort
        conversations[index].updatedAt = .now
        Task { await persist(conversationID: selection) }
    }

    func renameConversation(id: UUID, title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        conversations[index].title = String(value.prefix(120))
        conversations[index].updatedAt = .now
        Task { await persist(conversationID: id) }
    }

    func setConversationHidden(id: UUID, hidden: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].hiddenAt = hidden ? .now : nil
        conversations[index].updatedAt = .now
        if hidden, selection == id {
            selection = conversations.first(where: { $0.hiddenAt == nil && $0.id != id })?.id
            setRoute(selection.map(WorkspaceRoute.conversation) ?? .search, recordingHistory: true)
            if let selection {
                Task {
                    await loadLatestMessages(for: selection)
                    guard self.selection == selection else { return }
                    await restoreDraft(for: selection)
                    await refreshModels()
                }
            }
        }
        Task { await persist(conversationID: id) }
    }

    func deleteConversation(id: UUID) {
        if running.contains(id) {
            turnTasks[id]?.cancel()
            Task { await coordinator.cancel(conversationID: id) }
        }
        Task { await cancelAutoReviewApprovals(conversationID: id, lifecycle: .cancelled) }
        Task { await invalidateMCPAuthorization(conversationID: id) }
        conversations.removeAll { $0.id == id }
        deletedConversationIDs.insert(id)
        loadedMessageIDs.removeValue(forKey: id)
        messageContinuations.removeValue(forKey: id)
        completeMessageHistories.remove(id)
        draftCache.removeValue(forKey: id)
        Task { try? await draftStore.remove(for: id) }
        if selection == id {
            selection = conversations.first(where: { $0.hiddenAt == nil })?.id
            setRoute(selection.map(WorkspaceRoute.conversation) ?? .search, recordingHistory: true)
        }
        let remainingHistoryIDs = Set(navigationHistory.entries.compactMap { destination -> UUID? in
            guard case .conversation(let candidate) = destination, candidate != id else { return nil }
            return candidate
        })
        navigationHistory.reconcile(validConversationIDs: remainingHistoryIDs)
        scheduleNavigationPersistence()
        if conversations.isEmpty { addConversationUnchecked() }
        Task {
            do {
                try await store.delete(id: id)
                try await attachmentLifecycle?.removeReferences(conversationID: id)
            }
            catch { errorMessage = error.localizedDescription }
            if let selection {
                await loadLatestMessages(for: selection)
                guard self.selection == selection else { return }
                await restoreDraft(for: selection)
                await refreshModels()
            }
        }
    }

    func loadMoreConversations() async {
        guard !isLoadingMoreConversations, let continuation = conversationContinuation else { return }
        isLoadingMoreConversations = true
        defer { isLoadingMoreConversations = false }
        do {
            let page = try await store.conversationPage(after: continuation)
            let existingIDs = Set(conversations.map(\.id))
            conversations.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
            conversationContinuation = page.continuation
            hasMoreConversations = page.continuation != nil
        } catch { errorMessage = error.localizedDescription }
    }

    func loadLatestMessages(for conversationID: UUID) async {
        // A loaded window may contain unsaved streaming/local mutations. Reusing
        // it on navigation avoids replacing those values with an older DB page.
        guard loadedMessageIDs[conversationID] == nil else { return }
        let ticket = conversationLoadFence.begin(conversationID: conversationID)
        messageLoadGenerationByID[conversationID] = ticket.generation
        loadingMessageHistory.insert(conversationID)
        defer {
            if messageLoadGenerationByID[conversationID] == ticket.generation {
                loadingMessageHistory.remove(conversationID)
            }
        }
        do {
            let page = try await store.messagePage(conversationID: conversationID)
            guard conversationLoadFence.accepts(ticket, selectedConversationID: selection),
                  let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            let messages = ConversationPageMerge.latest(page.items)
            conversations[index].messages = messages
            loadedMessageIDs[conversationID] = Set(messages.map(\.id))
            messageContinuations[conversationID] = page.continuation
            if page.continuation == nil { completeMessageHistories.insert(conversationID) }
            else { completeMessageHistories.remove(conversationID) }
        } catch {
            guard conversationLoadFence.accepts(ticket, selectedConversationID: selection) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadOlderMessages() async {
        guard let conversationID = selection,
              !loadingMessageHistory.contains(conversationID),
              let continuation = messageContinuations[conversationID] else { return }
        let ticket = ConversationLoadTicket(conversationID: conversationID, generation: conversationLoadFence.generation)
        messageLoadGenerationByID[conversationID] = ticket.generation
        loadingMessageHistory.insert(conversationID)
        defer {
            if messageLoadGenerationByID[conversationID] == ticket.generation {
                loadingMessageHistory.remove(conversationID)
            }
        }
        do {
            let page = try await store.messagePage(conversationID: conversationID, before: continuation)
            guard conversationLoadFence.accepts(ticket, selectedConversationID: selection),
                  let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            conversations[index].messages = ConversationPageMerge.older(page.items, into: conversations[index].messages)
            loadedMessageIDs[conversationID, default: []].formUnion(page.items.map(\.id))
            messageContinuations[conversationID] = page.continuation
            if page.continuation == nil { completeMessageHistories.insert(conversationID) }
        } catch {
            guard conversationLoadFence.accepts(ticket, selectedConversationID: selection) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Explicitly used by operations whose semantics require the whole thread
    /// (provider context, resend before an old turn, and find-in-chat).
    func loadAllMessages(for conversationID: UUID) async throws {
        if completeMessageHistories.contains(conversationID) { return }
        let ticket: ConversationLoadTicket? = if selection == conversationID {
            conversationLoadFence.begin(conversationID: conversationID)
        } else { nil }
        if let ticket {
            messageLoadGenerationByID[conversationID] = ticket.generation
            loadingMessageHistory.insert(conversationID)
        }
        defer {
            if let ticket, messageLoadGenerationByID[conversationID] == ticket.generation {
                loadingMessageHistory.remove(conversationID)
            }
        }
        guard let canonical = try await store.conversation(id: conversationID),
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let loaded = loadedMessageIDs[conversationID] ?? []
        let locallyCurrent = conversations[index].messages
        let unseen = canonical.messages.filter { !loaded.contains($0.id) }
        conversations[index].messages = ConversationPageMerge.older(unseen, into: locallyCurrent)
        loadedMessageIDs[conversationID] = Set(conversations[index].messages.map(\.id))
        messageContinuations[conversationID] = nil
        completeMessageHistories.insert(conversationID)
    }

    func refreshModels(forceRefresh: Bool = false) async {
        guard let conversation = selectedConversation else {
            availableModels = []
            modelCatalogProviderID = nil
            modelCatalogConversationID = nil
            return
        }
        let accountGeneration = autoReviewAccountGeneration
        let ticket = modelRefreshGuard.begin(
            accountGeneration: accountGeneration,
            conversationID: conversation.id,
            providerID: conversation.providerID
        )
        isLoadingModels = true
        modelCatalogError = nil
        guard let snapshot = await registry.modelCatalog(
            providerID: conversation.providerID,
            forceRefresh: forceRefresh
        ) else {
            guard modelRefreshGuard.accepts(
                ticket,
                accountGeneration: autoReviewAccountGeneration,
                selectedConversationID: selection,
                selectedProviderID: selectedConversation?.providerID
            ) else { return }
            isLoadingModels = false
            availableModels = []
            modelCatalogSource = nil
            isModelCatalogStale = false
            modelCatalogError = "The selected provider is unavailable."
            modelCatalogLastUpdated = nil
            modelCatalogProviderID = ticket.providerID
            modelCatalogConversationID = ticket.conversationID
            errorMessage = modelCatalogError
            return
        }
        guard modelRefreshGuard.accepts(
            ticket,
            accountGeneration: autoReviewAccountGeneration,
            selectedConversationID: selection,
            selectedProviderID: selectedConversation?.providerID
        ) else { return }
        isLoadingModels = false
        availableModels = snapshot.models
        modelCatalogSource = snapshot.source
        isModelCatalogStale = snapshot.isStale
        modelCatalogError = snapshot.errorDescription
        modelCatalogLastUpdated = snapshot.fetchedAt
        modelCatalogProviderID = ticket.providerID
        modelCatalogConversationID = ticket.conversationID
        if let index = conversations.firstIndex(where: {
            $0.id == ticket.conversationID && $0.providerID == ticket.providerID
        }), let currentModel = snapshot.models.first(where: { $0.id == conversations[index].modelID }),
           !currentModel.capabilities.supports(conversations[index].reasoningEffort) {
            conversations[index].reasoningEffort = .disabled
            errorMessage = l10n("Reasoning was reset to disabled because \(currentModel.displayName) does not support the previous effort.")
            await persist(conversationID: ticket.conversationID)
        } else if let catalogError = snapshot.errorDescription {
            errorMessage = catalogError
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBootstrapped, (!text.isEmpty || !pendingAttachments.isEmpty), let id = selection, !running.contains(id), conversations.contains(where: { $0.id == id }) else { return }
        guard let conversation = selectedConversation else { return }
        if !pendingAttachments.isEmpty, let attachmentError = selectedModelAttachmentError {
            errorMessage = attachmentError
            return
        }
        if let validationError = ProviderCatalogPresentation.validationError(
            conversation: conversation,
            models: availableModels,
            catalogProviderID: modelCatalogProviderID,
            catalogConversationID: modelCatalogConversationID,
            loading: isLoadingModels
        ) {
            errorMessage = validationError
            return
        }
        let attachments = pendingAttachments
        let replyToMessageID = replyingToMessageID
        let originalDraft = draft
        draft = ""
        pendingAttachments = []
        replyingToMessageID = nil
        running.insert(id)
        Task {
            do {
                try await loadAllMessages(for: id)
                guard let hydratedIndex = conversations.firstIndex(where: { $0.id == id }) else {
                    throw CancellationError()
                }
                let userMessage = ChatMessage(role: .user, text: text, attachments: attachments, replyToMessageID: replyToMessageID)
                conversations[hydratedIndex].messages.append(userMessage)
                let assistantMessage = ChatMessage(role: .assistant, text: "", deliveryStatus: .queued)
                conversations[hydratedIndex].messages.append(assistantMessage)
                loadedMessageIDs[id, default: []].formUnion([userMessage.id, assistantMessage.id])
                if conversations[hydratedIndex].title == "New conversation" { conversations[hydratedIndex].title = String(text.prefix(40)) }
                // The transcript must be durable before its CAS reachability records are added.
                try await persistOrThrow(conversationID: id)
                if let attachmentLifecycle {
                    var committed: [AttachmentMetadata] = []
                    do {
                        for metadata in attachments {
                        let owner = AttachmentReferenceOwner(conversationID: id, messageID: userMessage.id)
                            if let staged = stagedAttachments[metadata.id] {
                                committed.append(try await attachmentLifecycle.commit(staged, to: owner))
                                stagedAttachments.removeValue(forKey: metadata.id)
                            } else {
                                try await attachmentLifecycle.addReference(metadata, owner: owner)
                                committed.append(metadata)
                            }
                        }
                    } catch {
                        let commitError = error
                        // First remove the durable transcript references. Until that succeeds,
                        // retain every CAS reachability/upload record so a crash cannot dangle it.
                        conversations[hydratedIndex].messages.removeAll { $0.id == userMessage.id || $0.id == assistantMessage.id }
                        loadedMessageIDs[id]?.subtract([userMessage.id, assistantMessage.id])
                        try await persistOrThrow(conversationID: id)
                        for metadata in committed {
                            try? await attachmentLifecycle.removeReference(
                                blobID: metadata.id,
                                owner: .init(conversationID: id, messageID: userMessage.id)
                            )
                        }
                        for metadata in attachments {
                            if let staged = stagedAttachments.removeValue(forKey: metadata.id) {
                                try? await attachmentLifecycle.abort(staged)
                            }
                        }
                        throw commitError
                    }
                }
                let requestMessages = Array(conversations[hydratedIndex].messages.dropLast())
                startTurn(
                    conversationID: id,
                    assistantID: assistantMessage.id,
                    requestMessages: requestMessages,
                    modelID: conversations[hydratedIndex].modelID,
                    providerID: conversations[hydratedIndex].providerID,
                    reasoningEffort: conversations[hydratedIndex].reasoningEffort
                )
            } catch {
                running.remove(id)
                if selection == id {
                    draft = originalDraft
                    pendingAttachments = attachments
                    replyingToMessageID = replyToMessageID
                }
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func acceptVoiceResult() {
        guard let result = voiceComposer.result else { return }
        guard selectedModelAudioError == nil else {
            errorMessage = selectedModelAudioError
            return
        }
        isImportingAttachments = true
        Task {
            defer { isImportingAttachments = false }
            do {
                let staged = try await stageAttachment(
                    fileURL: result.recording.fileURL,
                    declaredMIMEType: "audio/mp4"
                )
                let metadata = staged.metadata
                if !pendingAttachments.contains(where: { $0.id == metadata.id }) {
                    stagedAttachments[metadata.id] = staged
                    pendingAttachments.append(metadata)
                } else { try? await attachmentLifecycle?.abort(staged) }
                let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcript.isEmpty {
                    draft = draft.isEmpty ? transcript : "\(draft)\n\(transcript)"
                }
                _ = voiceComposer.takeResult()
                try? FileManager.default.removeItem(at: result.recording.fileURL)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func pasteAttachments() {
        guard selectedModelAttachmentError == nil else {
            errorMessage = selectedModelAttachmentError
            return
        }
        let values = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] ?? []
        if !values.isEmpty {
            importAttachments(values)
            return
        }
        let pasteboard = NSPasteboard.general
        let image: (Data, String, String)? = {
            if let data = pasteboard.data(forType: .png) { return (data, "png", "image/png") }
            if let data = pasteboard.data(forType: .tiff) { return (data, "tiff", "image/tiff") }
            return nil
        }()
        guard let (data, extensionName, mimeType) = image else {
            errorMessage = l10n("The clipboard does not contain a file or image.")
            return
        }
        isImportingAttachments = true
        Task {
            defer { isImportingAttachments = false }
            let temporary = FileManager.default.temporaryDirectory
                .appending(path: "FiliconClipboard", directoryHint: .isDirectory)
                .appending(path: "pasted-\(UUID().uuidString).\(extensionName)")
            do {
                try FileManager.default.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: temporary, options: .atomic)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let attachmentLifecycle else { throw AttachmentStoreError.missing("lifecycle") }
                let staged = try await attachmentLifecycle.stage(
                    data: data, filename: temporary.lastPathComponent, declaredMIMEType: mimeType
                )
                let metadata = staged.metadata
                if !pendingAttachments.contains(where: { $0.id == metadata.id }) {
                    stagedAttachments[metadata.id] = staged
                    pendingAttachments.append(metadata)
                } else { try? await attachmentLifecycle.abort(staged) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func resend(messageID: UUID) {
        guard isBootstrapped,
              let conversationID = selection,
              !running.contains(conversationID),
              conversations.first(where: { $0.id == conversationID })?.messages.contains(where: {
                  $0.id == messageID && $0.role == .assistant && [.failed, .cancelled].contains($0.deliveryStatus)
              }) == true else { return }
        guard let conversation = selectedConversation else { return }
        if let validationError = ProviderCatalogPresentation.validationError(
            conversation: conversation,
            models: availableModels,
            catalogProviderID: modelCatalogProviderID,
            catalogConversationID: modelCatalogConversationID,
            loading: isLoadingModels
        ) {
            errorMessage = validationError
            return
        }
        running.insert(conversationID)
        Task {
            do {
                try await loadAllMessages(for: conversationID)
                guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
                      let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) else {
                    throw CancellationError()
                }
                conversations[conversationIndex].messages[messageIndex].prepareForResend()
                let requestMessages = Array(conversations[conversationIndex].messages[..<messageIndex])
                startTurn(
                    conversationID: conversationID,
                    assistantID: messageID,
                    requestMessages: requestMessages,
                    modelID: conversations[conversationIndex].modelID,
                    providerID: conversations[conversationIndex].providerID,
                    reasoningEffort: conversations[conversationIndex].reasoningEffort
                )
            } catch {
                running.remove(conversationID)
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func deleteMessage(id messageID: UUID) {
        guard let conversationID = selection,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if running.contains(conversationID),
           conversations[index].messages.contains(where: { $0.id == messageID && [.queued, .streaming].contains($0.deliveryStatus) }) {
            cancel()
        }
        let removed = conversations[index].messages.first(where: { $0.id == messageID })
        _ = conversations[index].deleteMessage(id: messageID)
        if replyingToMessageID == messageID { replyingToMessageID = nil }
        Task {
            do {
                try await persistOrThrow(conversationID: conversationID)
                if removed != nil {
                try? await attachmentLifecycle?.removeReferences(
                    owner: .init(conversationID: conversationID, messageID: messageID)
                )
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func toggleReaction(messageID: UUID, emoji: String, actorID: String = "local-user") {
        guard let conversationID = selection,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        _ = conversations[index].toggleReaction(messageID: messageID, emoji: emoji, actorID: actorID)
        conversations[index].updatedAt = Date()
        Task { await persist(conversationID: conversationID) }
    }

    func beginReply(to messageID: UUID) { replyingToMessageID = messageID }

    func handleTranscriptCardIntent(_ intent: TranscriptCardActionIntent) {
        guard let context = transcriptCardContext(for: intent) else {
            errorMessage = l10n("This card action is stale or ambiguous. No operation was performed.")
            return
        }
        Task { await executeTranscriptCardIntent(intent, context: context) }
    }

    private struct TranscriptCardContext {
        let conversationID: UUID
        let messageID: UUID
        let card: TranscriptCard
    }

    private func transcriptCardContext(for intent: TranscriptCardActionIntent) -> TranscriptCardContext? {
        guard let conversationID = selection,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        let matches = conversation.messages.flatMap { message in
            message.transcriptCards.compactMap { card -> TranscriptCardContext? in
                guard card.actions.contains(where: { $0.intent == intent }) else { return nil }
                return .init(conversationID: conversationID, messageID: message.id, card: card)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func executeTranscriptCardIntent(_ intent: TranscriptCardActionIntent, context: TranscriptCardContext) async {
        let ticket: TranscriptCardActionTicket
        do { ticket = try await transcriptCardActionRouter.begin(card: context.card, intent: intent) }
        catch { errorMessage = error.localizedDescription; return }

        var suppliedSecret: String?
        if case .provideSecret = intent {
            suppliedSecret = requestSecret(for: context.card)
            guard suppliedSecret != nil else {
                await transcriptCardActionRouter.abandon(ticket)
                return
            }
        }

        let startedAt = Date()
        guard updateTranscriptCard(
            context: context, expectedUpdatedAt: ticket.expectedUpdatedAt,
            lifecycle: intent == .dismiss(cardID: context.card.id) ? .retired : .running,
            updatedAt: startedAt
        ) else {
            await transcriptCardActionRouter.abandon(ticket)
            errorMessage = TranscriptCardActionRoutingError.staleCard.localizedDescription
            return
        }
        do {
            try await persistTranscriptCardConversation(context.conversationID)
        } catch {
            // No external action has run yet. Restore the provider-authored
            // lifecycle rather than leaving a phantom running operation.
            _ = updateTranscriptCard(
                context: context, expectedUpdatedAt: startedAt,
                lifecycle: context.card.lifecycle
            )
            await transcriptCardActionRouter.abandon(ticket)
            errorMessage = error.localizedDescription
            return
        }

        do {
            try await performTranscriptCardIntent(intent, card: context.card, conversationID: context.conversationID, secret: suppliedSecret)
            guard await transcriptCardActionRouter.finish(ticket),
                  updateTranscriptCard(context: context, expectedUpdatedAt: startedAt, lifecycle: ticket.successLifecycle) else {
                throw TranscriptCardActionRoutingError.staleCard
            }
            try await persistTranscriptCardConversation(context.conversationID)
        } catch {
            await transcriptCardActionRouter.abandon(ticket)
            let actionError = error
            if updateTranscriptCard(context: context, expectedUpdatedAt: startedAt, lifecycle: .failed) {
                do {
                    try await persistTranscriptCardConversation(context.conversationID)
                    errorMessage = actionError.localizedDescription
                } catch {
                    errorMessage = l10n("\(actionError.localizedDescription) Card failure state could not be persisted: \(error.localizedDescription)")
                }
            } else {
                // A successful external action may already have advanced the
                // card before its final persistence attempt failed. Never
                // overwrite that confirmed state with a misleading failure.
                errorMessage = actionError.localizedDescription
            }
        }
    }

    private func updateTranscriptCard(
        context: TranscriptCardContext, expectedUpdatedAt: Date,
        lifecycle: TranscriptCardLifecycle, updatedAt: Date = Date()
    ) -> Bool {
        guard let ci = conversations.firstIndex(where: { $0.id == context.conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == context.messageID }),
              let cardIndex = conversations[ci].messages[mi].transcriptCards.firstIndex(where: { $0.id == context.card.id }),
              conversations[ci].messages[mi].transcriptCards[cardIndex].updatedAt == expectedUpdatedAt else { return false }
        conversations[ci].messages[mi].transcriptCards[cardIndex].lifecycle = lifecycle
        conversations[ci].messages[mi].transcriptCards[cardIndex].updatedAt = updatedAt
        conversations[ci].updatedAt = updatedAt
        return true
    }

    /// Card actions cross external authority boundaries, so persistence errors
    /// cannot be swallowed like a cosmetic metadata update. A bounded retry
    /// covers transient SQLite busy/I/O failures; failure is surfaced to the
    /// user and never reported as a successfully persisted lifecycle.
    private func persistTranscriptCardConversation(_ conversationID: UUID) async throws {
        guard !deletedConversationIDs.contains(conversationID),
              let conversation = conversations.first(where: { $0.id == conversationID }) else {
            throw TranscriptCardActionRoutingError.staleCard
        }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await store.upsert(
                    conversation,
                    replacingLoadedMessageIDs: loadedMessageIDs[conversation.id] ?? [],
                    historyComplete: completeMessageHistories.contains(conversation.id)
                )
                return
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(50)) }
            }
        }
        throw lastError ?? TranscriptCardActionRoutingError.operationNotConfirmed("Card lifecycle persistence")
    }

    private func performTranscriptCardIntent(
        _ intent: TranscriptCardActionIntent, card: TranscriptCard,
        conversationID: UUID, secret: String?
    ) async throws {
        switch (intent, card.payload) {
        case (.approveReview(let reviewID), .autoReview(let reviewCard)),
             (.rejectReview(let reviewID), .autoReview(let reviewCard)):
            guard reviewID == reviewCard.reviewID,
                  let pending = pendingAutoReviewByID[reviewID],
                  pending.action.context.conversationID == conversationID else {
                throw TranscriptCardActionRoutingError.staleCard
            }
            let resolution: ApprovalResolution
            if case .approveReview = intent { resolution = .approve } else { resolution = .deny }
            do {
                try await autoReviewBroker.resolve(
                    reviewID: reviewID, resolution: resolution, fence: pending.fence
                )
            } catch {
                throw TranscriptCardActionRoutingError.staleCard
            }
            pendingAutoReviewByID.removeValue(forKey: reviewID)
            pendingAutoReviewApprovals = pendingAutoReviewByID.values.sorted { $0.createdAt < $1.createdAt }
        case (.retry, _), (.dismiss, _):
            return
        case (.sendDraft, .draft(let draft)):
            guard let channelService, let connectionID = draft.connectionID,
                  let channelID = draft.channelID?.trimmingCharacters(in: .whitespacesAndNewlines), !channelID.isEmpty,
                  let connection = await channelService.connections().first(where: { $0.id == connectionID }),
                  connection.enabled, connection.connectorID == draft.channel else {
                throw TranscriptCardActionRoutingError.mismatchedTarget
            }
            let text = [draft.subject.map { "\($0)\n" }, draft.body].compactMap { $0 }.joined()
            let delivery = try await channelService.enqueue(
                .init(text: text),
                to: .init(platform: connection.connectorID, channelID: channelID, threadID: draft.threadID),
                connectionID: connectionID, idempotencyKey: card.id
            )
            await channelService.flush()
            await reloadChannelState()
            guard await channelService.delivery(id: delivery.id)?.status == .delivered else {
                throw TranscriptCardActionRoutingError.operationNotConfirmed("Draft delivery")
            }
        case (.connectListener(let listenerID), .listener(let listenerCard)):
            guard let automationService, let id = UUID(uuidString: listenerID),
                  let automation = await automationService.list().first(where: { $0.id == id }),
                  Self.listenerCard(listenerCard, matches: automation.trigger) else {
                throw TranscriptCardActionRoutingError.mismatchedTarget
            }
            try await automationService.setEnabled(id: id, enabled: true)
            await reloadAutomationDetails(markViewed: false)
        case (.provideSecret, .secretRequest(let request)):
            guard let secret, !secret.isEmpty,
                  Self.isSafeCredentialComponent(request.service),
                  request.account.map(Self.isSafeCredentialComponent) ?? true else {
                throw TranscriptCardActionRoutingError.mismatchedTarget
            }
            try await credentials.set(secret, for: .init(
                providerID: ProviderID(rawValue: "secret.\(request.service)"),
                account: request.account ?? "default"
            ))
        case (.connectorAction(let connectorID, let actionID), .connector(let connector)):
            guard connector.allowedActionIDs.contains(actionID),
                  let destination = Self.registeredConnectorRoutes[connectorID]?[actionID] else {
                throw TranscriptCardActionRoutingError.unauthorizedAction
            }
            selectRoute(destination)
        case (.decideLocalToolPermission(let requestID, let decision), .localToolPermission(let cardRequest)):
            guard let id = UUID(uuidString: requestID),
                  let action = LocalToolAction(rawValue: cardRequest.toolName) else {
                throw TranscriptCardActionRoutingError.staleCard
            }
            if decision == .alwaysAllow {
                let previousPermission = await localToolPermissionPolicy.configuredChoices()[action] ?? .ask
                guard await localToolApprovalBroker.claimIfMatches(
                    id: id, conversationID: conversationID, action: action,
                    title: cardRequest.scope
                ) else { throw TranscriptCardActionRoutingError.staleCard }
                do {
                    try await localToolPermissionPolicy.setChoice(.always, for: action)
                    guard await localToolApprovalBroker.completeClaim(id: id, allowed: true) else {
                        try? await localToolPermissionPolicy.setChoice(previousPermission, for: action)
                        throw TranscriptCardActionRoutingError.staleCard
                    }
                } catch {
                    await localToolApprovalBroker.abandonClaim(id: id)
                    throw error
                }
            } else {
                guard await localToolApprovalBroker.resolveIfMatches(
                    id: id, conversationID: conversationID, action: action,
                    title: cardRequest.scope, allowed: decision != .deny
                ) else { throw TranscriptCardActionRoutingError.staleCard }
            }
            await reloadLocalToolSettings()
        case (.openCloudAgent(let agentID, let threadID), .cloudAgent):
            guard let id = UUID(uuidString: agentID), agents.contains(where: { $0.id == id && $0.archivedAt == nil }) else {
                throw TranscriptCardActionRoutingError.mismatchedTarget
            }
            if let threadID, let conversationID = UUID(uuidString: threadID),
               conversations.contains(where: { $0.id == conversationID }) {
                selectRoute(.conversation(conversationID))
            } else if threadID == nil { selectRoute(.agents) }
            else { throw TranscriptCardActionRoutingError.mismatchedTarget }
        case (.revealFileDiff, .fileOperation(let operation)):
            try await presentValidatedFileOperation(operation, conversationID: conversationID, cardID: card.id)
        case (.cancelShell(let operationID), .shell):
            guard let runID = UUID(uuidString: operationID) else { throw TranscriptCardActionRoutingError.mismatchedTarget }
            guard await localToolRuntime.cancel(runID: runID, conversationID: conversationID) else {
                throw TranscriptCardActionRoutingError.operationNotConfirmed("Shell cancellation")
            }
        default:
            throw TranscriptCardActionRoutingError.mismatchedTarget
        }
    }

    private static let registeredConnectorRoutes: [String: [String: WorkspaceRoute]] = [
        "filicon": ["open_channels": .channels, "open_automations": .automations, "open_plugins": .plugins, "open_mcp": .mcp],
        "slack": ["open_channels": .channels],
        "discord": ["open_channels": .channels],
        "automation": ["open_automations": .automations],
        "mcp": ["open_mcp": .mcp],
    ]

    private static func listenerCard(_ card: ListenerTranscriptCard, matches trigger: AutomationTrigger) -> Bool {
        let connector = card.connector.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = card.event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !connector.isEmpty, !event.isEmpty else { return false }
        switch trigger {
        case .event(let value):
            return connector.caseInsensitiveCompare(value.connectorID.uuidString) == .orderedSame
                && event == value.kind
        case .platform(let value):
            return connector.caseInsensitiveCompare(value.platform) == .orderedSame
        case .anyOf(let values):
            return values.contains { listenerCard(card, matches: $0) }
        case .cron, .unknown:
            return false
        }
    }

    private static func isSafeCredentialComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }
    }

    private func requestSecret(for card: TranscriptCard) -> String? {
        guard case .secretRequest(let request) = card.payload else { return nil }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        let alert = NSAlert()
        alert.messageText = request.prompt
        alert.informativeText = "Store a credential for \(request.service) in macOS Keychain. It will not be added to this conversation."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save to Keychain")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func presentValidatedFileOperation(
        _ operation: FileOperationTranscriptCard, conversationID: UUID, cardID: UUID
    ) async throws {
        guard let root = operation.workspaceRoot,
              await localToolRuntime.workspaceStore.authorization(forExactRoot: root) != nil,
              !operation.path.hasPrefix("/"), !operation.path.split(separator: "/").contains("..") else {
            throw TranscriptCardActionRoutingError.mismatchedTarget
        }
        let runID = UUID()
        let result = try await localToolRuntime.perform(
            operation: .readFile(root: root, relativePath: operation.path),
            conversationID: conversationID, agentID: conversationID, runID: runID,
            toolCallID: "transcript-file-preview:\(cardID.uuidString.lowercased())"
        )
        guard case .file(let data) = result else { throw TranscriptCardActionRoutingError.mismatchedTarget }
        let current = String(decoding: data.prefix(100_000), as: UTF8.self)
        let displayed = [operation.diff.map { "Recorded diff:\n\($0)" }, "Current read-only file:\n\(current)"].compactMap { $0 }.joined(separator: "\n\n")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        text.isEditable = false; text.isSelectable = true; text.string = displayed
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let alert = NSAlert(); alert.messageText = operation.path; alert.informativeText = "Validated read-only workspace preview"; alert.accessoryView = scroll; alert.addButton(withTitle: "Close")
        alert.runModal()
    }
    func cancelReply() { replyingToMessageID = nil }

    private func startTurn(
        conversationID id: UUID,
        assistantID: UUID,
        requestMessages: [ChatMessage],
        modelID requestModelID: ModelID,
        providerID: ProviderID,
        reasoningEffort: ReasoningEffort
    ) {
        running.insert(id)
        workspaceFolders.beginTurn(conversationID: id)
        let turnTask = Task {
            var succeeded = false
            do {
                await persist(conversationID: id)
                var attachmentsByMessageID: [UUID: [InferenceAttachment]] = [:]
                for message in requestMessages where !message.attachments.isEmpty {
                    var values: [InferenceAttachment] = []
                    for metadata in message.attachments {
                        let owner = AttachmentReferenceOwner(conversationID: id, messageID: message.id)
                        let data: Data
                        if let attachmentLifecycle {
                            do { data = try await attachmentLifecycle.data(for: metadata, owner: owner) }
                            catch AttachmentStoreError.missing { data = try await attachmentStore.data(for: metadata) }
                        } else { data = try await attachmentStore.data(for: metadata) }
                        values.append(.init(metadata: metadata, data: data))
                    }
                    attachmentsByMessageID[message.id] = values
                }
                let request = InferenceRequest(
                    conversationID: id,
                    modelID: requestModelID,
                    messages: WorkflowComposerReferences.injectingReferencedWorkflows(
                        into: requestMessages,
                        workflows: workflows
                    ),
                    attachmentsByMessageID: attachmentsByMessageID,
                    reasoningEffort: reasoningEffort
                )
                try await coordinator.send(request: request, providerID: providerID) { [weak self] event in
                    await self?.consume(event, conversationID: id, assistantID: assistantID)
                }
                succeeded = true
            } catch is CancellationError {
                setDeliveryStatus(.cancelled, conversationID: id, assistantID: assistantID)
            } catch {
                errorMessage = error.localizedDescription
                setDeliveryStatus(.failed, error: error.localizedDescription, conversationID: id, assistantID: assistantID)
            }
            finishTurn(conversationID: id, assistantID: assistantID, succeeded: succeeded)
            do {
                try await persistOrThrow(conversationID: id)
            } catch {
                errorMessage = l10n("The completed response could not be saved: \(error.localizedDescription)")
                running.remove(id)
                turnTasks.removeValue(forKey: id)
                return
            }
            if succeeded {
                do {
                    _ = try await store.recordFinalAssistantTurn(
                        conversationID: id,
                        assistantMessageID: assistantID
                    )
                } catch {
                    // The assistant turn is already canonical and durable. A
                    // replica-memory failure remains visible and is never
                    // represented as a successful memory record.
                    errorMessage = l10n("The response was saved, but turn memory could not be updated: \(error.localizedDescription)")
                }
            }
            running.remove(id)
            turnTasks.removeValue(forKey: id)
            if succeeded,
               let conversation = conversations.first(where: { $0.id == id }),
               let preview = conversation.messages.first(where: { $0.id == assistantID })?.text,
               !preview.isEmpty {
                await systemNotifications.deliverCompletion(conversationID: id, title: conversation.title, preview: preview)
            }
        }
        turnTasks[id] = turnTask
    }

    func cancel() {
        guard isBootstrapped, let selection else { return }
        turnTasks[selection]?.cancel()
        workspaceFolders.cancel(conversationID: selection)
        Task {
            await cancelAutoReviewApprovals(conversationID: selection, lifecycle: .cancelled)
            await localToolApprovalBroker.cancel(conversationID: selection)
            await localToolPermissionPolicy.revokePendingGrants(conversationID: selection)
            await localToolRuntime.cancel(conversationID: selection)
            await invalidateMCPAuthorization(conversationID: selection)
            await coordinator.cancel(conversationID: selection)
        }
    }

    private func consume(_ event: InferenceEvent, conversationID: UUID, assistantID: UUID) async {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }), let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantID }) else { return }
        if case .usage(let usage) = event {
            var accumulated = pendingTurnUsage[assistantID] ?? Usage()
            accumulated.mergeCumulative(usage)
            pendingTurnUsage[assistantID] = accumulated
        }
        conversations[ci].messages[mi].consume(event)
    }

    private func finishTurn(conversationID: UUID, assistantID: UUID, succeeded: Bool) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if succeeded, let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantID }) {
            conversations[ci].messages[mi].deliveryStatus = .succeeded
            conversations[ci].messages[mi].deliveryError = nil
        }
        if let usage = pendingTurnUsage.removeValue(forKey: assistantID) {
            let provider = conversations[ci].providerID.rawValue
            Task { await recordUsage(providerID: provider, usage: usage) }
        }
        conversations[ci].updatedAt = Date()
    }

    private func setDeliveryStatus(_ status: MessageDeliveryStatus, error: String? = nil, conversationID: UUID, assistantID: UUID) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantID }) else { return }
        conversations[ci].messages[mi].deliveryStatus = status
        conversations[ci].messages[mi].deliveryError = error
        if status == .failed || status == .cancelled {
            for activityIndex in conversations[ci].messages[mi].toolActivities.indices
            where conversations[ci].messages[mi].toolActivities[activityIndex].status == .running {
                conversations[ci].messages[mi].toolActivities[activityIndex].status = .failed
                if conversations[ci].messages[mi].toolActivities[activityIndex].result == nil {
                    conversations[ci].messages[mi].toolActivities[activityIndex].result = error ?? "Cancelled"
                }
            }
        }
    }

    private func persist(conversationID: UUID?) async {
        do { try await persistOrThrow(conversationID: conversationID) }
        catch { errorMessage = error.localizedDescription }
    }

    private func persistOrThrow(conversationID: UUID?) async throws {
        guard let conversationID,
              !deletedConversationIDs.contains(conversationID),
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let loadedIDs = loadedMessageIDs[conversation.id] ?? []
        let historyComplete = completeMessageHistories.contains(conversation.id)
        let operation: @Sendable () async throws -> Void = { [store, conversation, loadedIDs, historyComplete] in
            try await store.upsert(conversation, replacingLoadedMessageIDs: loadedIDs, historyComplete: historyComplete)
        }
        if let quotaWriter {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
            _ = try await quotaWriter.perform(scope: "conversation", key: conversation.id.uuidString, data: encoder.encode(conversation), operation: operation)
            if let quotaLedger { quotaUsage = await quotaLedger.usage() }
        } else {
            try await operation()
        }
    }

    private func scheduleDraftPersistence() {
        guard !isRestoringDraft, let conversationID = selection else { return }
        let value = draft
        draftCache[conversationID] = value
        let previous = draftSaveTask
        draftSaveTask = Task { [draftStore] in
            await previous?.value
            try? await draftStore.save(value, for: conversationID)
        }
    }

    private func persistCurrentDraftImmediately() {
        guard let conversationID = selection else { return }
        let value = draft
        draftCache[conversationID] = value
        let previous = draftSaveTask
        draftSaveTask = Task { [draftStore] in
            await previous?.value
            try? await draftStore.save(value, for: conversationID)
        }
    }

    private func restoreDraft(for conversationID: UUID) async {
        draftLoadGeneration += 1
        let generation = draftLoadGeneration
        do {
            let value: String
            if let cached = draftCache[conversationID] { value = cached }
            else {
                value = try await draftStore.draft(for: conversationID)
                draftCache[conversationID] = value
            }
            guard selection == conversationID, draftLoadGeneration == generation else { return }
            isRestoringDraft = true
            draft = value
            isRestoringDraft = false
        } catch { errorMessage = error.localizedDescription }
    }

    func importAttachments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard selectedModelAttachmentError == nil else {
            errorMessage = selectedModelAttachmentError
            return
        }
        isImportingAttachments = true
        Task {
            defer { isImportingAttachments = false }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let staged = try await stageAttachment(fileURL: url)
                    if !pendingAttachments.contains(where: { $0.id == staged.metadata.id }) {
                        stagedAttachments[staged.metadata.id] = staged
                        pendingAttachments.append(staged.metadata)
                    } else { try? await attachmentLifecycle?.abort(staged) }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func removePendingAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
        if let staged = stagedAttachments.removeValue(forKey: id) {
            Task { try? await attachmentLifecycle?.abort(staged) }
        }
    }

    private func stageAttachment(fileURL: URL, declaredMIMEType: String? = nil) async throws -> StagedAttachment {
        guard let attachmentLifecycle else { throw AttachmentStoreError.missing("lifecycle") }
        return try await attachmentLifecycle.stage(fileURL: fileURL, declaredMIMEType: declaredMIMEType)
    }

    func openAttachment(_ metadata: AttachmentMetadata) {
        let galleryMetadata = selectedConversation?.messages
            .first(where: { message in message.attachments.contains(where: { $0.id == metadata.id }) })?
            .attachments ?? [metadata]
        openAttachmentGallery(metadata, gallery: galleryMetadata) { candidate in
            try await self.attachmentStore.data(for: candidate)
        }
    }

    func openAgentMessageImage(_ metadata: AttachmentMetadata, gallery: [AttachmentMetadata]) {
        guard !agentMessagingAccountTransition, gallery.count <= 4, gallery.contains(metadata) else { return }
        let accountGeneration = autoReviewAccountGeneration
        openAttachmentGallery(metadata, gallery: gallery) { candidate in
            guard accountGeneration == self.autoReviewAccountGeneration else { throw CancellationError() }
            return try await self.agentMessageImageData(candidate)
        }
    }

    private func openAttachmentGallery(_ metadata: AttachmentMetadata, gallery: [AttachmentMetadata],
                                       load: @escaping @MainActor (AttachmentMetadata) async throws -> Data) {
        attachmentPreviewGeneration += 1
        let generation = attachmentPreviewGeneration
        Task {
            do {
                var files: [AttachmentPreviewFile] = []
                var selectedFileID: UUID?
                do {
                    for candidate in gallery.prefix(50) {
                        do {
                            let data = try await load(candidate)
                            let materialized = try attachmentPreviewMaterializer.materialize(data: data, metadata: candidate)
                            guard let file = materialized.files.first else { continue }
                            files.append(file)
                            if candidate.id == metadata.id { selectedFileID = file.id }
                        } catch {
                            // A stale sibling must not prevent the selected, CAS-verified
                            // attachment from opening. The selected file still fails closed.
                            if candidate.id == metadata.id { throw error }
                        }
                    }
                } catch {
                    if !files.isEmpty {
                        let partial = AttachmentPreviewItem(files: files, initialFileID: files[0].id)
                        attachmentPreviewMaterializer.remove(partial)
                    }
                    throw error
                }
                guard let selectedFileID, !files.isEmpty else {
                    throw AttachmentPreviewError.previewFileUnavailable
                }
                let item = AttachmentPreviewItem(files: files, initialFileID: selectedFileID)
                guard attachmentPreviewGeneration == generation else {
                    attachmentPreviewMaterializer.remove(item)
                    return
                }
                if let previous = attachmentPreview {
                    attachmentPreviewMaterializer.remove(previous)
                }
                attachmentPreview = item
            } catch {
                guard attachmentPreviewGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func dismissAttachmentPreview() {
        attachmentPreviewGeneration += 1
        guard let item = attachmentPreview else { return }
        attachmentPreview = nil
        attachmentPreviewMaterializer.remove(item)
    }

    func dismissAttachmentPreview(id: UUID) {
        guard attachmentPreview?.id == id else { return }
        dismissAttachmentPreview()
    }

    private func scheduleGlobalSearch() {
        globalSearchGeneration += 1
        let generation = globalSearchGeneration
        globalSearchTask?.cancel()
        globalSearchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.runGlobalSearch(generation: generation)
        }
    }

    /// Runs the current search immediately. The generation fence prevents an
    /// older index read from replacing results for a newer query or tab.
    func search() {
        globalSearchGeneration += 1
        let generation = globalSearchGeneration
        globalSearchTask?.cancel()
        globalSearchTask = Task { [weak self] in
            await self?.runGlobalSearch(generation: generation)
        }
    }

    func performGlobalSearch() async {
        globalSearchGeneration += 1
        let generation = globalSearchGeneration
        globalSearchTask?.cancel()
        await runGlobalSearch(generation: generation)
    }

    private func runGlobalSearch(generation: Int) async {
        guard generation == globalSearchGeneration else { return }
        if rootConnection.phase == .unreachable {
            globalSearchState = .unavailable("Conversation storage is unavailable.")
            return
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if globalSearchTab != .files, query.isEmpty {
            searchResults = []
            globalMessageSearchResults = []
            globalSearchState = .idle
            return
        }
        globalSearchState = .loading
        do {
            switch globalSearchTab {
            case .conversations:
                let results = try await store.search(query).filter { $0.hiddenAt == nil }
                guard generation == globalSearchGeneration, !Task.isCancelled else { return }
                searchResults = results
                globalSearchState = results.isEmpty ? .empty : .results
            case .messages:
                let liveInputs = conversations.flatMap { conversation in
                    conversation.messages.map { message in
                        LiveMessageSearchInput(
                            conversationID: conversation.id,
                            messageID: message.id,
                            role: message.role,
                            timestamp: message.createdAt,
                            body: message.text,
                            isHidden: conversation.hiddenAt != nil
                        )
                    }
                }
                let results = try await store.searchGlobalMessages(
                    query,
                    includeHidden: false,
                    latestLiveInputs: liveInputs
                )
                guard generation == globalSearchGeneration, !Task.isCancelled else { return }
                globalMessageSearchResults = results
                globalSearchState = results.isEmpty ? .empty : .results
            case .files:
                let results = try await store.searchGlobalMedia(query, includeHidden: false)
                guard generation == globalSearchGeneration, !Task.isCancelled else { return }
                globalMediaSearchResults = results
                globalSearchState = results.isEmpty ? .empty : .results
            }
        } catch {
            guard generation == globalSearchGeneration, !Task.isCancelled else { return }
            globalSearchState = .failed(error.localizedDescription)
        }
    }

    func focusGlobalSearch() {
        selectRoute(.search)
        globalSearchFocusRequestID = UUID()
    }

    func conversationTitle(for id: UUID) -> String {
        conversations.first(where: { $0.id == id })?.title ?? "Conversation"
    }

    func openSearchResult(_ result: Conversation) {
        if !conversations.contains(where: { $0.id == result.id }) {
            var metadata = result
            metadata.messages = []
            conversations.append(metadata)
        }
        selectRoute(.conversation(result.id))
    }

    func openGlobalMessageSearchHit(_ hit: GlobalMessageSearchHit) async {
        do {
            try await prepareGlobalSearchDestination(conversationID: hit.conversationID)
            requestedMessageJumpID = hit.messageID
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func consumeRequestedMessageJump(_ id: UUID) {
        if requestedMessageJumpID == id { requestedMessageJumpID = nil }
    }

    func openGlobalMediaSearchHit(_ hit: GlobalMediaSearchHit) async {
        do {
            try await prepareGlobalSearchDestination(conversationID: hit.conversationID)
            guard let metadata = selectedConversation?.messages
                .first(where: { $0.id == hit.messageID })?
                .attachments.first(where: { $0.id == hit.attachmentID }) else {
                throw AttachmentPreviewError.previewFileUnavailable
            }
            requestedMessageJumpID = hit.messageID
            openAttachment(metadata)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareGlobalSearchDestination(conversationID: UUID) async throws {
        if !conversations.contains(where: { $0.id == conversationID }),
           var conversation = try await store.conversation(id: conversationID) {
            conversation.messages = []
            conversations.append(conversation)
        }
        guard conversations.contains(where: { $0.id == conversationID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        selectRoute(.conversation(conversationID))
        await loadLatestMessages(for: conversationID)
        try await loadAllMessages(for: conversationID)
    }

    func publishNotificationError(
        _ message: String,
        title: String = "Filicon",
        agentID: String? = nil,
        requestID: String? = nil,
        actions: [NotificationTrayAction] = []
    ) async {
        let detail = Self.boundedNotificationText(message, maximumBytes: 16 * 1_024)
        let key = Self.boundedNotificationText(
            "app-error:\(agentID ?? "global"):\(message)",
            maximumBytes: 512
        )
        do {
            try await inAppNotifications.pushError(.init(
                agentID: agentID,
                title: title,
                detail: detail,
                requestID: requestID,
                errorKind: "app.error",
                rawDetail: detail,
                actions: actions,
                dedupeKey: key
            ))
        } catch {
            // Never replace the primary error with a tray presentation error.
        }
    }

    func dismissNotification(id: UUID) async {
        _ = await inAppNotifications.dismiss(id: id)
    }

    func clearNotifications() async {
        await inAppNotifications.clearAll()
    }

    func performNotificationAction(_ action: NotificationTrayAction) async -> NotificationTrayActionResult {
        do {
            let validated = try NotificationTrayAction.validated(action)
            switch validated {
            case .openURL(_, let url):
                guard NSWorkspace.shared.open(url) else {
                    return .init(succeeded: false, message: "The link could not be opened.")
                }
                return .init(succeeded: true, message: "Opened")
            case .dashboard(_, let action, let arguments, let successMessage):
                guard performExactDashboardAction(action, arguments: arguments) else {
                    return .init(succeeded: false, message: "This dashboard action is not allowed.")
                }
                return .init(succeeded: true, message: successMessage)
            }
        } catch {
            return .init(succeeded: false, message: error.localizedDescription)
        }
    }

    private func observeInAppNotifications() {
        guard inAppNotificationTask == nil else { return }
        inAppNotificationTask = Task { [weak self, inAppNotifications] in
            let events = await inAppNotifications.events()
            self?.notificationTrays = await inAppNotifications.list()
            for await _ in events {
                guard !Task.isCancelled else { return }
                self?.notificationTrays = await inAppNotifications.list()
            }
        }
    }

    private func observeAgentState() {
        guard agentStateObservationTask == nil, let agentService else { return }
        agentStateObservationTask = Task { [weak self, agentService] in
            let snapshots = await agentService.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.agents = snapshot.agents.sorted { $0.createdAt < $1.createdAt }
                self.agentAsyncTasks = snapshot.subagents
                    .sorted { $0.startedAt < $1.startedAt }
                    .map(AgentAsyncTask.init(record:))
                self.pinnedAgentIDs.formIntersection(Set(self.agents.map(\.id)))
                self.persistPinnedAgents()
                await self.projectAgentNotifications()
            }
        }
    }

    private func performExactDashboardAction(
        _ action: String,
        arguments: [String: NotificationArgumentValue]
    ) -> Bool {
        switch action {
        case "dashboard.search" where arguments.isEmpty:
            selectRoute(.search)
        case "dashboard.agents" where arguments.isEmpty:
            selectRoute(.agents)
        case "dashboard.automations" where arguments.isEmpty:
            selectRoute(.automations)
        case "dashboard.computer" where arguments.isEmpty:
            selectRoute(.computer)
        case "dashboard.agent":
            guard arguments.count == 1,
                  case .string(let rawID)? = arguments["agentID"],
                  let id = UUID(uuidString: rawID),
                  agents.contains(where: { $0.id == id && $0.archivedAt == nil }) else { return false }
            requestedAgentInspectionID = id
            selectRoute(.agents)
        case "dashboard.conversation":
            guard arguments.count == 1,
                  case .string(let rawID)? = arguments["conversationID"],
                  let id = UUID(uuidString: rawID),
                  conversations.contains(where: { $0.id == id }) else { return false }
            selectRoute(.conversation(id))
        default:
            return false
        }
        return true
    }

    private static func boundedNotificationText(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var end = value.utf8.index(value.utf8.startIndex, offsetBy: maximumBytes)
        while end > value.utf8.startIndex,
              end < value.utf8.endIndex,
              value.utf8[end] & 0b1100_0000 == 0b1000_0000 {
            end = value.utf8.index(before: end)
        }
        return String(decoding: value.utf8[..<end], as: UTF8.self)
    }

    func reloadWorkspaceData() async {
        if let agentService {
            agents = await agentService.list(includeArchived: true)
            agentAsyncTasks = await agentService.subagents().map(AgentAsyncTask.init(record:))
            pinnedAgentIDs.formIntersection(Set(agents.map(\.id)))
            persistPinnedAgents()
            await projectAgentNotifications()
        }
        await reloadAgentMessages()
        if let groupService {
            groups = await groupService.list()
            if selectedGroupID == nil || !groups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = groups.first?.id
            }
            var values: [UUID: [RoomMessage]] = [:]
            for group in groups { values[group.id] = await groupService.messages(groupID: group.id) }
            groupMessages = values
        }
        if let automationService { automations = await automationService.list() }
        if let channelService {
            channelConnections = await channelService.connections()
            channelDescriptors = await channelService.connectorDescriptors()
            channelInboundEvents = await channelService.inboundEvents()
            channelDeliveries = await channelService.deliveries()
            channelFailureWakes = await channelService.failureWakes()
        }
        do {
            var storedConfigs = try await mcpConfigStore.load()
            var definitions = try await mcpAccountLibrary.reconcile(existingConfigs: storedConfigs)
            // OAuth listeners are intentionally memory-only. A persisted
            // pending marker therefore cannot survive an app restart.
            for definition in definitions where !definition.managedReadOnly {
                for slot in definition.accounts where slot.authStatus == .pending {
                    _ = try await mcpAccountLibrary.setAuthentication(
                        serverID: definition.id,
                        accountKey: slot.accountKey,
                        status: .failed,
                        tokenReference: nil
                    )
                    if var config = storedConfigs.first(where: { $0.identifier == slot.serverIdentifier }) {
                        config.transport = Self.mcpTransport(config.transport, authorizationReference: nil)
                        storedConfigs = try await mcpConfigStore.upsert(config)
                    }
                }
            }
            definitions = try await mcpAccountLibrary.list()
            mcpAccountDefinitions = definitions
            mcpConfigs = try await mcpAccountLibrary.materializeRuntimeConfigs(existingConfigs: storedConfigs)
            var modes: [String: MCPPermissionMode] = [:]
            for config in mcpConfigs { modes[config.identifier] = await mcpPolicyStore.mode(serverIdentifier: config.identifier) }
            mcpPermissionModes = modes
            try await saveMCPConfigsWithQuota(mcpConfigs)
            try await mcpService.replaceConfigs(mcpConfigs)
            mcpCatalog = await mcpService.catalog()
            await installMCPTools()
        } catch { errorMessage = error.localizedDescription }
    }

    func retryRootConnection() {
        rootResilience.retry { [weak self] ticket in await self?.performRootRetry(ticket: ticket) }
        rootConnection = rootResilience.connection
    }

    func dismissStartupBanner() {
        startupBanner = nil
    }

    func reloadRootWorkspace() async {
        guard rootConnection.phase == .connected else {
            rootResilience.queueReload()
            retryRootConnection()
            return
        }
        let ticket = rootResilience.begin(accountGeneration: sharedRoomIdentity.accountGeneration)
        rootConnection = rootResilience.connection
        await performRootRetry(ticket: ticket)
    }

    func rebuildConversationSearchIndex() async {
        do {
            persistenceRecoveryReport = try await store.rebuildSearchIndex()
            startupBanner = persistenceRecoveryReport?.summary
        } catch {
            startupBanner = "Search index rebuild failed without replacing conversation data."
            errorMessage = error.localizedDescription
        }
    }

    func refreshPersistenceRecoveryStatus() async {
        do {
            persistenceRecoveryReport = try await store.recoveryReport()
            if let report = persistenceRecoveryReport { startupBanner = report.summary }
        } catch { startupBanner = "Recovery status could not be read: \(String(error.localizedDescription.prefix(500)))" }
    }

    func openRecoveryQuarantine() {
        guard let path = persistenceRecoveryReport?.quarantineDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    func copyRootDiagnostics() {
        let value = rootDiagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func rootDiagnostics(limit: Int = 4_096) -> String {
        let report = persistenceRecoveryReport
        let lines = [
            "root=\(dataRoot.path)",
            "route=\(startupSettlement.route.rawValue)",
            "reason=\(startupSettlement.reason.rawValue)",
            "connection=\(rootConnection.phase.rawValue)",
            "failures=\(rootConnection.failureCount)",
            "recovery=\(report?.kind.rawValue ?? "none")",
            "generation=\(report?.generation.uuidString ?? "none")",
            "recoveredConversations=\(report?.recoveredConversations ?? 0)",
            "recoveredMessages=\(report?.recoveredMessages ?? 0)",
            "rejectedRows=\(report?.rejectedRows.count ?? 0)",
        ]
        return String(lines.joined(separator: "\n").prefix(max(0, min(limit, 4_096))))
    }

    private func performRootRetry(ticket: WorkspaceRootTicket) async {
        do {
            let page = try await store.conversationPage()
            guard ticket.rootGeneration == rootResilience.generation,
                  ticket.accountGeneration == rootResilience.accountGeneration else { return }
            conversations = page.items
            conversationContinuation = page.continuation
            hasMoreConversations = page.continuation != nil
            persistenceRecoveryReport = try await store.recoveryReport()
            await reloadWorkspaceData()
            let queued = rootResilience.succeed(ticket: ticket)
            rootConnection = rootResilience.connection
            if queued { await reloadRootWorkspace() }
        } catch {
            rootResilience.fail(error, ticket: ticket)
            rootConnection = rootResilience.connection
        }
    }

    private func reconcileQuota() async {
        guard let quotaWriter else { return }
        let filenames = [
            "composer-drafts.json", "agents.json", "agent-messages.json", "groups.json", "automations.json",
            "channels.json", "mcp-servers.json", "mcp-accounts.json", "mcp-approval-policies.json", "settings.json",
            "auto-review-instructions.json", "workspace-bookmarks.json", "local-tool-permissions.json", "plugins-installed.json",
            "plugin-setup.json", "plugin-skills-cache.json", "skill-publications.json", "automation-ingress.json",
        ]
        var records: [StorageQuotaRecord] = filenames.compactMap { name in
            let url = dataRoot.appending(path: name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return .init(scope: "state", key: name, byteCount: Int64(size), generation: 1)
        }
        // The SQLite file is an aggregate container, not one logical record. Count
        // conversations independently so the per-record ceiling remains meaningful.
        if let conversations = try? await store.load() {
            let encoder = JSONEncoder()
            records += conversations.compactMap { conversation in
                guard let data = try? encoder.encode(conversation) else { return nil }
                return .init(
                    scope: "conversation",
                    key: conversation.id.uuidString.lowercased(),
                    byteCount: Int64(data.count),
                    generation: 1
                )
            }
        }
        do { quotaUsage = try await quotaWriter.reconcile(records) }
        catch {
            startupBanner = Self.quotaMessage(error)
            errorMessage = startupBanner
        }
    }

    private static func quotaMessage(_ error: Error) -> String {
        switch error {
        case StorageQuotaError.recordTooLarge(let limit, let requested): "A state record needs \(requested.formatted()) bytes, above the \(limit.formatted()) byte safety limit."
        case StorageQuotaError.totalExceeded(let limit, let projected): "Storage would use \(projected.formatted()) bytes, above the \(limit.formatted()) byte app limit."
        case is StorageQuotaError: "The storage quota ledger needs attention; the write was not committed."
        default: error.localizedDescription
        }
    }

    nonisolated static func checkAttachmentQuota(usage: AttachmentStorageUsage, requested: Int64) throws {
        let recordLimit: Int64 = 8 * 1_024 * 1_024
        let totalLimit: Int64 = 256 * 1_024 * 1_024
        guard requested <= recordLimit else { throw StorageQuotaError.recordTooLarge(limit: recordLimit, requested: requested) }
        let projected = usage.activeBytes + usage.quarantinedBytes + usage.stagedBytes + max(0, requested)
        guard projected <= totalLimit else { throw StorageQuotaError.totalExceeded(limit: totalLimit, projected: projected) }
    }

    private func quotaWrite<T: Sendable>(scope: String, key: String, data: Data, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let quotaWriter else { return try await operation() }
        let result = try await quotaWriter.perform(scope: scope, key: key, data: data, operation: operation)
        if let quotaLedger { quotaUsage = await quotaLedger.usage() }
        return result
    }

    @discardableResult
    func createAgent(name: String, title: String = "", summary: String, instructions: String, providerID: ProviderID, modelID: ModelID, avatar: AgentAvatar? = nil, notifyOnAgentUpdates: Bool = true) async -> AgentProfile? {
        guard let agentService else { errorMessage = l10n("Agent storage is unavailable."); return nil }
        do {
            let payload = try JSONEncoder().encode(["name": name, "title": title, "summary": summary, "instructions": instructions, "provider": providerID.rawValue, "model": modelID.rawValue])
            let profile = try await quotaWrite(scope: "workflow", key: "agent-\(name)", data: payload) { [agentService, name, summary, instructions, providerID, modelID, title, avatar] in
                try await agentService.create(name: name, summary: summary, instructions: instructions, providerID: providerID, modelID: modelID, title: title, avatar: avatar, notifyOnAgentUpdates: notifyOnAgentUpdates)
            }
            agents = await agentService.list(includeArchived: true)
            return profile
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @discardableResult
    func updateAgent(_ profile: AgentProfile) async -> Bool {
        guard let agentService else { errorMessage = l10n("Agent storage is unavailable."); return false }
        do {
            try await agentService.update(profile)
            agents = await agentService.list(includeArchived: true)
            await projectAgentNotifications()
            return true
        } catch { errorMessage = FiliconLocalization.string(error.localizedDescription); return false }
    }

    func archiveAgent(id: UUID) async {
        guard let agentService else { return }
        for session in routineEditSessions.values.filter({ $0.automation.agentID == id }) {
            endAutomationEdit(session)
        }
        do { try await agentService.archive(id: id); agents = await agentService.list(includeArchived: true) }
        catch { errorMessage = error.localizedDescription }
    }

    func restoreAgent(id: UUID) async {
        guard let agentService else { return }
        do { try await agentService.restore(id: id); agents = await agentService.list(includeArchived: true) }
        catch { errorMessage = error.localizedDescription }
    }

    func toggleAgentPinned(id: UUID) {
        if pinnedAgentIDs.contains(id) { pinnedAgentIDs.remove(id) } else { pinnedAgentIDs.insert(id) }
        persistPinnedAgents()
    }

    func markAgentRead(id: UUID) async {
        guard let agentService else { return }
        do {
            try await agentService.setUnreadCount(id: id, count: 0)
            agents = await agentService.list(includeArchived: true)
        } catch { errorMessage = error.localizedDescription }
    }

    private static let maximumVisibleAgentMessages = 500

    func agentInbox(for agentID: UUID) -> [AgentMessage] {
        Array(agentMessages.lazy.filter { $0.recipientID == agentID }.suffix(Self.maximumVisibleAgentMessages))
    }

    func agentOutbox(for agentID: UUID) -> [AgentMessage] {
        Array(agentMessages.lazy.filter { $0.senderID == agentID }.suffix(Self.maximumVisibleAgentMessages))
    }

    func agentThread(between firstID: UUID, and secondID: UUID) -> [AgentMessage] {
        Array(agentMessages.lazy.filter {
            ($0.senderID == firstID && $0.recipientID == secondID)
                || ($0.senderID == secondID && $0.recipientID == firstID)
        }.suffix(Self.maximumVisibleAgentMessages))
    }

    @discardableResult
    func sendAgentMessage(
        senderID: UUID,
        recipientID: UUID,
        text: String,
        priority: AgentMessagePriority = .normal,
        images: [AttachmentMetadata] = []
    ) async -> Bool {
        let generation = autoReviewAccountGeneration
        let accountID = settings.accountScope ?? "local"
        guard !agentMessagingAccountTransition else { return false }
        guard let agentService, agentMessenger != nil, let agentConversations else {
            errorMessage = l10n("Agent messaging storage is unavailable. Your message was not sent.")
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = l10n("Enter a message before sending.")
            return false
        }
        guard trimmed.count <= 8_000 else {
            errorMessage = AgentServiceError.messageTooLong.localizedDescription
            return false
        }
        guard senderID != recipientID else {
            errorMessage = AgentServiceError.selfMessage.localizedDescription
            return false
        }
        guard let sender = await agentService.profile(id: senderID), sender.archivedAt == nil else {
            errorMessage = l10n("The selected sender is unavailable. Your message was not sent.")
            return false
        }
        guard let recipient = await agentService.profile(id: recipientID), recipient.archivedAt == nil else {
            errorMessage = l10n("The selected recipient is unavailable. Your message was not sent.")
            return false
        }
        do {
            let scopeID = try await agentConversations.mailboxScope(accountID: accountID, senderID: sender.id, recipientID: recipient.id)
            guard generation == autoReviewAccountGeneration,
                  accountID == (settings.accountScope ?? "local"), !Task.isCancelled,
                  !runningAgentMessageScopes.contains(scopeID),
                  let session = makeAgentMessagingSession(originID: scopeID, supportsMailboxQuestions: true) else { return false }
            // Reserve before enqueue's first suspension. One conversation owns
            // its context and approval cards until its entire reply chain ends.
            runningAgentMessageScopes.insert(scopeID)
            agentMessagingSessions[scopeID] = session
            workspaceFolders.beginTurn(conversationID: scopeID)
            do {
                try await session.enqueueUserMessage(senderID: sender.id, recipientID: recipient.id, text: trimmed, priority: priority, images: images)
                guard generation == autoReviewAccountGeneration, !Task.isCancelled,
                      runningAgentMessageScopes.contains(scopeID) else { throw CancellationError() }
            } catch {
                try? await session.close()
                agentMessagingSessions[scopeID] = nil
                runningAgentMessageScopes.remove(scopeID)
                throw error
            }
            agentMessageTasks[scopeID] = Task { [weak self] in
                guard let self else { return }
                await self.runAgentMessages(scopeID: scopeID, session: session)
            }
            return true
        } catch {
            errorMessage = l10n("Message not sent: \(error.localizedDescription)")
            await reloadAgentMessages()
            return false
        }
    }

    func canAnswerMailboxQuestion(_ incoming: AgentMessage, publication: RoomMessage) -> Bool {
        guard !agentMessagingAccountTransition,
              let current = agentMessages.first(where: { $0.id == incoming.id }),
              current.delivery?.publications?.first(where: { $0.id == publication.id }) == publication,
              let delivery = incoming.delivery, delivery.state == .completed,
              !runningAgentMessageScopes.contains(delivery.originConversationID),
              let question = publication.question, question.isPending,
              question.accountID == (settings.accountScope ?? "local"),
              agents.contains(where: { $0.id == incoming.senderID && $0.archivedAt == nil }),
              agents.contains(where: { $0.id == incoming.recipientID && $0.archivedAt == nil }) else { return false }
        return true
    }

    func answerMailboxQuestion(incomingID: UUID, publicationID: UUID, answer: AgentQuestionAnswer) async {
        guard let incoming = agentMessages.first(where: { $0.id == incomingID }),
              let publication = incoming.delivery?.publications?.first(where: { $0.id == publicationID }),
              canAnswerMailboxQuestion(incoming, publication: publication),
              let scopeID = incoming.delivery?.originConversationID,
              let session = makeAgentMessagingSession(originID: scopeID, supportsMailboxQuestions: true) else { return }
        let generation = autoReviewAccountGeneration
        runningAgentMessageScopes.insert(scopeID)
        agentMessagingSessions[scopeID] = session
        workspaceFolders.beginTurn(conversationID: scopeID)
        do {
            try await session.enqueueQuestionAnswer(incomingID: incomingID, publicationID: publicationID, answer: answer)
            guard generation == autoReviewAccountGeneration, !Task.isCancelled,
                  runningAgentMessageScopes.contains(scopeID) else { throw CancellationError() }
            agentMessageTasks[scopeID] = Task { [weak self] in
                await self?.runAgentMessages(scopeID: scopeID, session: session)
            }
        } catch {
            try? await session.close()
            await cancelAgentMessageTools(scopeID: scopeID)
            agentMessagingSessions[scopeID] = nil
            runningAgentMessageScopes.remove(scopeID)
            if !(error is CancellationError) { errorMessage = FiliconLocalization.string(error.localizedDescription) }
            await reloadAgentMessages()
        }
    }

    private func runAgentMessages(scopeID: UUID, session: AgentMessagingSession) async {
        do { try await session.drain() }
        catch is CancellationError {}
        catch { errorMessage = error.localizedDescription }
        do { try await session.close() }
        catch { errorMessage = error.localizedDescription }
        await cancelAgentMessageTools(scopeID: scopeID)
        await reloadAgentMessages()
        agentMessagingSessions[scopeID] = nil
        agentMessageTasks[scopeID] = nil
        runningAgentMessageScopes.remove(scopeID)
    }

    func importAgentMessageImages(_ urls: [URL]) async throws -> [AttachmentMetadata] {
        let generation = autoReviewAccountGeneration
        guard !agentMessagingAccountTransition, urls.count <= 4 else { throw AgentImageError.limit }
        var images: [AttachmentMetadata] = []
        for url in urls {
            let image = try await agentImageStore.importImage(fileURL: url)
            if !images.contains(where: { $0.id == image.id }) { images.append(image) }
        }
        _ = try await agentImageStore.load(images)
        guard generation == autoReviewAccountGeneration, !agentMessagingAccountTransition else { throw CancellationError() }
        return images
    }

    func agentMessageImageData(_ image: AttachmentMetadata) async throws -> Data {
        let generation = autoReviewAccountGeneration
        let loaded = try await agentImageStore.load([image])
        guard generation == autoReviewAccountGeneration, !agentMessagingAccountTransition,
              let bytes = loaded.first?.data else { throw CancellationError() }
        return bytes
    }

    func stopAgentMessages(scopeID: UUID) async {
        guard runningAgentMessageScopes.contains(scopeID) else { return }
        agentMessagingSessions[scopeID]?.revokeProfileChanges()
        agentMessageTasks[scopeID]?.cancel()
        do { try await agentMessagingSessions[scopeID]?.close() }
        catch { errorMessage = error.localizedDescription }
        await cancelAgentMessageTools(scopeID: scopeID)
        // Keep the scope reserved until drain has unwound; a new request must
        // not share an old turn's pending grants or stale completion callbacks.
    }

    private func cancelAgentMessageTools(scopeID: UUID) async {
        workspaceFolders.cancel(conversationID: scopeID)
        await cancelAutoReviewApprovals(conversationID: scopeID, lifecycle: .cancelled)
        await localToolApprovalBroker.cancel(conversationID: scopeID)
        await localToolPermissionPolicy.revokePendingGrants(conversationID: scopeID)
        await localToolRuntime.cancel(conversationID: scopeID)
        await invalidateMCPAuthorization(conversationID: scopeID)
    }

    private func makeAgentMessagingSession(originID: UUID, supportsMailboxQuestions: Bool = false) -> AgentMessagingSession? {
        guard let agentService, let agentMessenger, let agentConversations else { return nil }
        let generation = autoReviewAccountGeneration
        let management = AgentManagementSession(originID: originID, agents: agentService,
            authorize: { [weak self] sender, change, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentProfileChange(sender: sender, change: change, call: call, context: context)
            }, commit: { [weak self] change, lifetime in
                guard let self else { throw CancellationError() }
                return try await self.commitAgentProfileChange(change, lifetime: lifetime, originID: originID, generation: generation)
            }, accountID: settings.accountScope ?? "local",
            authorizeMemory: { [weak self] sender, change, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentMemoryChange(sender: sender, change: change, call: call, context: context)
            }, commitMemory: { [weak self] change, lifetime in
                guard let self else { throw CancellationError() }
                try await self.commitAgentMemoryChange(change, lifetime: lifetime, originID: originID, generation: generation)
            }, authorizeAvatar: { [weak self] sender, change, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentAvatarChange(sender: sender, change: change, call: call, context: context)
            }, commitAvatar: { [weak self] change, lifetime in
                guard let self else { throw CancellationError() }
                return try await self.commitAgentAvatarChange(change, lifetime: lifetime, originID: originID, generation: generation)
            }, automations: automationService, authorizeRoutine: { [weak self] sender, change, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentRoutineChange(sender: sender, change: change, call: call, context: context)
            }, commitRoutine: { [weak self] change, lifetime in
                guard let self else { throw CancellationError() }
                return try await self.commitAgentRoutineChange(change, lifetime: lifetime, originID: originID, generation: generation)
            }, routineTimeZoneIdentifier: settings.timeZoneIdentifier ?? TimeZone.current.identifier,
            workflows: workflowService, authorizeWorkflow: { [weak self] sender, change, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentWorkflowWrite(sender: sender, change: change, call: call, context: context)
            }, commitWorkflow: { [weak self] change, lifetime in
                guard let self else { throw CancellationError() }
                return try await self.commitAgentWorkflowWrite(change, lifetime: lifetime, originID: originID, generation: generation)
            }, authorizeWorkflowDeletion: { [weak self] sender, change, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentWorkflowChange(sender: sender, previous: change.workflow, proposed: nil, call: call, context: context)
            }, commitWorkflowDeletion: { [weak self] change, lifetime in
                guard let self else { throw CancellationError() }
                try await self.commitAgentWorkflowDeletion(change, lifetime: lifetime, originID: originID, generation: generation)
            }, authorizeSettings: { [weak self] sender, change, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentSettingsChange(sender: sender, change: change, call: call, context: context)
            }, commitSettings: { [weak self] change, lifetime in
                guard let self else { throw CancellationError() }
                return try await self.commitAgentSettingsChange(change, lifetime: lifetime, originID: originID, generation: generation)
            }, channels: channelService, authorizeChannel: { [weak self] sender, change, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentChannelDisconnection(sender: sender, change: change, call: call, context: context)
            }, commitChannel: { [weak self] change, lifetime in
                guard let self else { throw CancellationError() }
                try await self.commitAgentChannelDisconnection(change, lifetime: lifetime, originID: originID, generation: generation)
            }, authorizeProject: { [weak self] sender, change, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentProjectChange(sender: sender, change: change, call: call, context: context)
            }, commitProject: { [weak self] change, lifetime in
                guard let self else { throw CancellationError() }
                try await self.commitAgentProjectChange(change, lifetime: lifetime, originID: originID, generation: generation)
            })
        return AgentMessagingSession(
            originConversationID: originID, agents: agentService, messenger: agentMessenger,
            registry: registry, coordinator: coordinator, conversations: agentConversations,
            accountID: settings.accountScope ?? "local", management: management,
            memoryExtractor: AgentMemorySuggestionExtractor(agents: agentService, registry: registry, scheduler: agentExecutionScheduler,
                record: { [weak self] suggestions, settings, exchangeID, lifetime in
                    guard let self else { throw CancellationError() }
                    try await self.recordMemorySuggestions(suggestions, settings: settings, exchangeID: exchangeID,
                        lifetime: lifetime, originID: originID, generation: generation)
                }),
            supportsMailboxQuestions: supportsMailboxQuestions,
            groups: groupService,
            authorizeGroup: { [weak self] sender, audience, text, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeGroupDelegation(sender: sender, audience: audience, text: text, call: call, context: context)
            }, postGroup: { [weak self] dispatch, lifetime in
                guard let self else { throw CancellationError() }
                try await self.postGroupDelegation(dispatch, lifetime: lifetime, originID: originID, generation: generation)
            }, runGroup: { [weak self] dispatch, session in
                guard let self else { throw CancellationError() }
                try await self.runGroupDelegation(dispatch, session: session, originID: originID, generation: generation)
            }, finishGroup: { [weak self] groupID, failed in
                await self?.finishGroupDelegation(groupID: groupID, originID: originID, failed: failed)
            },
            imageStore: agentImageStore,
            authorizeImages: { [weak self] sender, recipient, text, images, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentDelegation(sender: sender, recipient: recipient, text: text, call: call, context: context, images: images)
            },
            authorizePublication: { [weak self] sender, text, images, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentImagePublication(sender: sender, text: text, images: images, call: call, context: context)
            },
            authorize: { [weak self] sender, recipient, text, call, context in
                guard let self else { throw CancellationError() }
                try await self.authorizeAgentDelegation(sender: sender, recipient: recipient, text: text, call: call, context: context)
            }, onChange: { [weak self] in await self?.reloadAgentMessages() }
        )
    }

    func groupApprovalScope(_ groupID: UUID) -> UUID { delegatedGroupOrigins[groupID] ?? groupID }

    private func authorizeGroupDelegation(sender: AgentProfile, audience: AgentGroupAudience, text: String,
                                          call: NormalizedToolCall, context: ToolContext) async throws {
        guard isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
        guard !runningGroups.contains(audience.id) else { throw AgentGroupPostError.busy }
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: settings.accountScope ?? "local", agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        let names = audience.members.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: "\n")
        let action = AutoReviewAction(summary: "\(sender.name) → \(audience.name)",
            target: .resource(kind: "group", identifier: audience.id.uuidString), risks: [.sensitive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue,
                metadata: ["tool": "SendToAgent", "agentMessage": text, "agentGroupName": audience.name, "agentGroupMembers": names]))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] in await self?.registerAutoReviewApproval($0) }
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
    }

    private func postGroupDelegation(_ dispatch: AgentGroupDispatch, lifetime: AgentGroupPostLifetime,
                                     originID: UUID, generation: UInt64) async throws {
        let groupID = dispatch.audience.id
        guard let groupService, generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(originID) else { throw CancellationError() }
        guard !runningGroups.contains(groupID), !stoppingGroups.contains(groupID) else { throw AgentGroupPostError.busy }
        // Reserve before hopping to persistence; foreground sends cannot race
        // an approved shared-room wake or replace its conversation scope.
        runningGroups.insert(groupID); delegatedGroupOrigins[groupID] = originID
        delegatedGroupPosts[groupID] = dispatch
        do { try await groupService.postAgentMessage(dispatch.message, audience: dispatch.audience, lifetime: lifetime) }
        catch {
            runningGroups.remove(groupID); delegatedGroupOrigins[groupID] = nil; delegatedGroupPosts[groupID] = nil
            throw error
        }
        groupMessages[groupID] = await groupService.messages(groupID: groupID)
    }

    private func runGroupDelegation(_ dispatch: AgentGroupDispatch, session: AgentMessagingSession,
                                    originID: UUID, generation: UInt64) async throws {
        let groupID = dispatch.audience.id
        guard let groupService, delegatedGroupOrigins[groupID] == originID,
              generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(originID) else { throw CancellationError() }
        _ = try await groupService.run(groupID: groupID,
            responder: GroupConversationResponder(groupID: groupID, registry: registry, coordinator: coordinator,
                messaging: session, delegatedMessage: dispatch.message, toolScopeID: originID),
            delegatedAudience: dispatch.audience, delegatedSenderID: dispatch.message.senderID,
            onAgentChange: { [weak self] agentID in
                await MainActor.run { self?.thinkingGroupMembers[groupID] = agentID }
            }, onMessage: { [weak self] message in
                await MainActor.run {
                    guard let self, self.delegatedGroupOrigins[groupID] == originID,
                          self.autoReviewAccountGeneration == generation else { return }
                    if let index = self.groupMessages[groupID, default: []].firstIndex(where: { $0.id == message.id }) {
                        self.groupMessages[groupID]?[index] = message
                    } else { self.groupMessages[groupID, default: []].append(message) }
                }
            })
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(originID) else { throw CancellationError() }
    }

    private func finishGroupDelegation(groupID: UUID, originID: UUID, failed: Bool) async {
        guard delegatedGroupOrigins[groupID] == originID else { return }
        if failed, let dispatch = delegatedGroupPosts[groupID], let groupService {
            let notice = RoomMessage(groupID: groupID, senderID: dispatch.message.senderID,
                text: l10n("Group reply stopped or failed. The posted message was kept."), memberOutcome: .failed)
            do { try await groupService.recordDelegatedMessage(notice) }
            catch { errorMessage = error.localizedDescription }
        }
        if let groupService { groupMessages[groupID] = await groupService.messages(groupID: groupID) }
        delegatedGroupOrigins[groupID] = nil; delegatedGroupPosts[groupID] = nil
        runningGroups.remove(groupID); thinkingGroupMembers[groupID] = nil
    }

    private func commitAgentProfileChange(_ change: AgentProfileChange, lifetime: AgentProfileChangeLifetime,
                                          originID: UUID, generation: UInt64) async throws -> AgentProfile {
        guard let agentService, isAgentMessagingScopeActive(originID), generation == autoReviewAccountGeneration else {
            throw CancellationError()
        }
        var proposed = await agentService.profile(id: change.targetID) ?? AgentProfile(
            id: change.targetID, name: change.name, instructions: change.description,
            providerID: change.providerID, modelID: change.modelID)
        proposed.name = change.name; proposed.summary = change.description
        let payload = try JSONEncoder().encode(proposed)
        let profile: AgentProfile
        do {
            profile = try await quotaWrite(scope: "workflow", key: "agent-\(change.targetID)", data: payload) {
                try await agentService.applyProfileChange(change, lifetime: lifetime)
            }
        } catch {
            guard let saved = lifetime.committedProfile(for: change) else { throw error }
            errorMessage = Self.quotaMessage(error)
            profile = saved
        }
        agents = await agentService.list(includeArchived: true)
        return profile
    }

    /// User-facing editor: shared scope includes every writer, unlike model-side forget.
    func savedAgentMemories(agentID: UUID, scope: AgentMemory.Scope = .agent) async throws -> [AgentMemory] {
        let generation = autoReviewAccountGeneration
        guard let agentService, !agentMessagingAccountTransition else { throw CancellationError() }
        let values: [AgentMemory]
        if scope == .user { values = await agentService.sharedUserMemories(accountID: settings.accountScope ?? "local") }
        else if scope == .project { values = await agentService.projectMemoriesForEditor(accountID: settings.accountScope ?? "local") }
        else { values = await agentService.memories(accountID: settings.accountScope ?? "local", agentID: agentID) }
        guard generation == autoReviewAccountGeneration else { throw CancellationError() }
        return values
    }

    func memorySuggestionSnapshot(agentID: UUID) async throws -> AgentMemorySuggestionSnapshot {
        let generation = autoReviewAccountGeneration
        guard let agentService, !agentMessagingAccountTransition else { throw CancellationError() }
        let value = try await agentService.memorySuggestions(accountID: settings.accountScope ?? "local", agentID: agentID)
        guard generation == autoReviewAccountGeneration else { throw CancellationError() }
        return value
    }

    func setMemorySuggestionsEnabled(_ enabled: Bool, expected: AgentMemorySuggestionSettings) async throws {
        guard let agentService, !agentMessagingAccountTransition,
              expected.accountID == (settings.accountScope ?? "local") else { throw CancellationError() }
        let lifetime = agentMemorySuggestionUILifetime
        try await quotaWrite(scope: "workflow", key: "memory-suggestions-\(expected.agentID)", data: try JSONEncoder().encode(expected)) {
            try await agentService.setMemorySuggestionsEnabled(enabled, expected: expected, lifetime: lifetime)
        }
    }

    func reviewMemorySuggestion(_ suggestion: AgentMemorySuggestion, accept: Bool) async throws {
        guard let agentService, !agentMessagingAccountTransition,
              suggestion.accountID == (settings.accountScope ?? "local") else { throw CancellationError() }
        let lifetime = agentMemorySuggestionUILifetime
        try await quotaWrite(scope: "workflow", key: "memory-suggestion-\(suggestion.id)", data: accept ? try JSONEncoder().encode(suggestion) : Data()) {
            try await agentService.reviewMemorySuggestion(suggestion, accept: accept, lifetime: lifetime)
        }
    }

    private func recordMemorySuggestions(_ suggestions: [AgentMemorySuggestion], settings: AgentMemorySuggestionSettings,
                                        exchangeID: UUID, lifetime: AgentMemorySuggestionLifetime,
                                        originID: UUID, generation: UInt64) async throws {
        guard let agentService, generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(originID),
              settings.accountID == (self.settings.accountScope ?? "local") else { throw CancellationError() }
        try await quotaWrite(scope: "workflow", key: "memory-suggestions-\(settings.agentID)", data: try JSONEncoder().encode(suggestions)) {
            try await agentService.recordMemorySuggestions(suggestions, settings: settings, exchangeID: exchangeID, lifetime: lifetime)
        }
    }

    func forgetAgentMemory(_ memory: AgentMemory) async throws {
        guard memory.accountID == settings.accountScope ?? "local", !agentMessagingAccountTransition else { throw CancellationError() }
        guard let agentService else { throw CancellationError() }
        let lifetime = agentMemoryUILifetime
        do {
            try await quotaWrite(scope: "workflow", key: "agent-memory-\(memory.id)", data: Data()) {
                try await agentService.forgetMemoryFromEditor(memory, lifetime: lifetime)
            }
        } catch {
            guard lifetime.committed(.init(operation: .forget, memory: memory)) else { throw error }
            errorMessage = Self.quotaMessage(error)
        }
    }

    private func commitAgentMemoryChange(_ change: AgentMemoryChange, lifetime: AgentMemoryChangeLifetime,
                                          originID: UUID, generation: UInt64) async throws {
        guard isAgentMessagingScopeActive(originID), generation == autoReviewAccountGeneration else { throw CancellationError() }
        try await commitAgentMemoryChange(change, lifetime: lifetime)
    }

    private func commitAgentMemoryChange(_ change: AgentMemoryChange, lifetime: AgentMemoryChangeLifetime) async throws {
        guard let agentService, change.memory.accountID == settings.accountScope ?? "local", !agentMessagingAccountTransition else { throw CancellationError() }
        let payload = change.operation == .write ? try JSONEncoder().encode(change.memory) : Data()
        do {
            try await quotaWrite(scope: "workflow", key: "agent-memory-\(change.memory.id)", data: payload) {
                try await agentService.applyMemoryChange(change, lifetime: lifetime)
            }
        } catch {
            guard lifetime.committed(change) else { throw error }
            errorMessage = Self.quotaMessage(error)
        }
    }

    private func authorizeAgentMemoryChange(sender: AgentProfile, change: AgentMemoryChange,
                                            call: NormalizedToolCall, context: ToolContext) async throws {
        guard isAgentMessagingScopeActive(context.conversationID), change.memory.accountID == settings.accountScope ?? "local" else { throw CancellationError() }
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: change.memory.accountID, agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        let shared = change.memory.scope == .user
        let project = change.project
        let title: LocalizedText = project != nil ? (change.operation == .write ? "Save project memory" : "Forget project memory")
            : shared ? (change.operation == .write ? "Save shared user memory" : "Forget shared user memory")
            : (change.operation == .write ? "Save agent memory" : "Forget agent memory")
        let action = AutoReviewAction(summary: "\(sender.name) → \(l10n(title))",
            target: project != nil ? .resource(kind: "project-memory", identifier: change.memory.project ?? "")
                : shared ? .resource(kind: "shared-user-memory", identifier: change.memory.accountID)
                : .resource(kind: "agent", identifier: sender.id.uuidString), risks: [.sensitive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue,
                metadata: ["tool": "update_state", "agentStateTarget": "memory", "agentMemoryAction": change.operation.rawValue,
                           "agentMemoryFact": change.memory.fact, "agentMemoryTier": change.memory.tier.rawValue,
                           "agentMemoryOwner": sender.name, "agentMemoryScope": change.memory.scope.rawValue,
                           "agentMemoryProject": project?.slug ?? "", "agentMemoryProjectName": project?.name ?? "",
                           "agentMemoryProjectMembers": String(project?.memberIDs.count ?? 0)]))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] in await self?.registerAutoReviewApproval($0) }
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
    }

    private func commitAgentAvatarChange(_ change: AgentAvatarChange, lifetime: AgentAvatarChangeLifetime,
                                         originID: UUID, generation: UInt64) async throws -> AgentProfile {
        guard let agentService, isAgentMessagingScopeActive(originID), generation == autoReviewAccountGeneration,
              var proposed = await agentService.profile(id: change.agentID) else { throw CancellationError() }
        proposed.avatar = change.avatar
        let payload = try JSONEncoder().encode(proposed)
        let profile: AgentProfile
        do {
            profile = try await quotaWrite(scope: "workflow", key: "agent-\(change.agentID)", data: payload) {
                try await agentService.applyAvatarChange(change, lifetime: lifetime)
            }
        } catch {
            guard let saved = lifetime.committedProfile(for: change) else { throw error }
            errorMessage = Self.quotaMessage(error)
            profile = saved
        }
        let current = await agentService.list(includeArchived: true)
        guard generation == autoReviewAccountGeneration else { return profile }
        agents = current
        return profile
    }

    private func commitAgentRoutineChange(_ change: AutomationStateChange, lifetime: AutomationStateChangeLifetime,
                                          originID: UUID, generation: UInt64) async throws -> Automation {
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(originID),
              let automationService, let agentService,
              let owner = await agentService.profile(id: change.automation.agentID), owner.archivedAt == nil else { throw CancellationError() }
        let result: Automation
        if change.isDefinitionWrite {
            do {
                let payload = try JSONEncoder().encode(change.automation)
                result = try await quotaWrite(scope: "automation", key: change.automation.id.uuidString, data: payload) {
                    try await automationService.applyStateChange(change, lifetime: lifetime)
                }
            } catch {
                guard let saved = lifetime.committed(for: change) else { throw error }
                errorMessage = Self.quotaMessage(error)
                result = saved
            }
        } else { result = try await automationService.applyStateChange(change, lifetime: lifetime) }
        // Do not rebind UI to an old account after awaiting storage. The model's
        // existing scheduler observes the same service; no runNow is invoked.
        let definitions = await automationService.list()
        if generation == autoReviewAccountGeneration { automations = definitions }
        return result
    }

    private func authorizeAgentRoutineChange(sender: AgentProfile, change: AutomationStateChange,
                                             call: NormalizedToolCall, context: ToolContext) async throws {
        guard isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: settings.accountScope ?? "local", agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        var metadata = ["tool": "update_state", "agentStateTarget": "routine", "agentRoutineAction": change.operation.rawValue,
                        "agentName": sender.name, "agentRoutineName": change.automation.name,
                        "agentRoutineID": change.automation.id.uuidString,
                        "agentRoutineEnabled": String(change.enabled),
                        "agentRoutinePrompt": change.automation.prompt, "agentRoutineTrigger": try change.triggerJSON]
        if [.create, .update, .resume].contains(change.operation), change.automation.trigger.platformSources.contains("github") {
            metadata["agentRoutineGitHubTrigger"] = "true"
        }
        if [.create, .update, .resume].contains(change.operation), change.automation.trigger.platformSources.contains("slack") {
            metadata["agentRoutineSlackTrigger"] = "true"
        }
        if [.create, .update, .resume].contains(change.operation), change.automation.trigger.platformSources.contains("linear") {
            metadata["agentRoutineLinearTrigger"] = "true"
        }
        if [.create, .update, .resume].contains(change.operation), change.automation.trigger.platformSources.contains("sentry") {
            metadata["agentRoutineSentryTrigger"] = "true"
        }
        if [.create, .update, .resume].contains(change.operation), change.automation.trigger.platformSources.contains("pagerduty") {
            metadata["agentRoutinePagerDutyTrigger"] = "true"
        }
        if [.create, .update].contains(change.operation), change.automation.trigger.platformSources.contains("microsoftTeams") {
            metadata["agentRoutineTeamsTrigger"] = "true"
        }
        if [.create, .update, .resume].contains(change.operation), case .anyOf = change.automation.trigger {
            metadata["agentRoutineAnyOfTrigger"] = "true"
            if change.automation.trigger.containsTimeTrigger {
                metadata["agentRoutineTimeGroupTrigger"] = "true"
            }
        }
        if let previous = change.previous {
            metadata["previousAgentRoutineName"] = previous.name
            metadata["previousAgentRoutinePrompt"] = previous.prompt
            metadata["previousAgentRoutineTrigger"] = try AutomationStateChange(operation: .pause, automation: previous).triggerJSON
            metadata["previousAgentRoutineEnabled"] = String(previous.enabled)
        }
        let action = AutoReviewAction(summary: "\(sender.name) → \(change.operation.rawValue): \(change.automation.name)",
            target: .resource(kind: "automation", identifier: change.automation.id.uuidString),
            risks: change.operation == .delete ? [.sensitive, .destructive] : [.sensitive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue, metadata: metadata))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] in await self?.registerAutoReviewApproval($0) }
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
    }

    private func commitAgentWorkflowWrite(_ change: AgentWorkflowWrite, lifetime: AgentWorkflowWriteLifetime,
                                          originID: UUID, generation: UInt64) async throws -> AgentWorkflow {
        guard let workflowService, generation == autoReviewAccountGeneration,
              isAgentMessagingScopeActive(originID) else { throw CancellationError() }
        let saved: AgentWorkflow
        do {
            saved = try await quotaWrite(scope: "workflow", key: change.proposed.id, data: JSONEncoder().encode(change.proposed)) {
                try await workflowService.applyAgentWrite(change, lifetime: lifetime)
            }
        } catch {
            guard let receipt = lifetime.committed(for: change) else { throw error }
            errorMessage = Self.quotaMessage(error); saved = receipt
        }
        let current = await workflowService.workflows()
        if generation == autoReviewAccountGeneration { workflows = current }
        return saved
    }

    private func authorizeAgentWorkflowWrite(sender: AgentProfile, change: AgentWorkflowWrite,
                                             call: NormalizedToolCall, context: ToolContext) async throws {
        try await authorizeAgentWorkflowChange(sender: sender, previous: change.previous, proposed: change.proposed, call: call, context: context)
    }

    private func commitAgentWorkflowDeletion(_ change: AgentWorkflowDeletion, lifetime: AgentWorkflowDeletionLifetime,
                                             originID: UUID, generation: UInt64) async throws {
        guard let workflowService, let agentService, generation == autoReviewAccountGeneration,
              isAgentMessagingScopeActive(originID),
              let owner = await agentService.profile(id: change.requesterID), owner.archivedAt == nil else { throw CancellationError() }
        // Removing a definition does not require new quota or touch any runtime.
        try await workflowService.applyAgentDeletion(change, lifetime: lifetime)
        let current = await workflowService.workflows()
        if generation == autoReviewAccountGeneration { workflows = current }
    }

    private func authorizeAgentWorkflowChange(sender: AgentProfile, previous: AgentWorkflow?, proposed: AgentWorkflow?,
                                              call: NormalizedToolCall, context: ToolContext) async throws {
        guard let workflowService, let subject = proposed ?? previous,
              isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
        let operation = proposed == nil ? "delete" : previous == nil ? "create" : "update"
        let title = operation == "delete" ? "Delete reusable workflow" : operation == "create" ? "Save reusable workflow" : "Rewrite reusable workflow"
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: settings.accountScope ?? "local", agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        let library = await workflowService.workflows()
        let routines = await automationService?.list() ?? []
        // Reference names/IDs are shown only to the user, never returned to the
        // requesting model. This snapshot is advisory, not a frozen audience.
        let aliases = [previous, proposed].compactMap { $0 }
        var references = library.filter { value in
            value.id != subject.id && !AgentWorkflowReferenceResolver.mentionedIDs(in: value, library: aliases).isEmpty
        }.map { "\($0.name) (sand-workflow:\($0.id))" }
        references += routines.filter { routine in
            let carrier = AgentWorkflow(id: "reference-check", name: "Reference check", steps: [.prompt(routine.prompt)])
            return !AgentWorkflowReferenceResolver.mentionedIDs(in: carrier, library: aliases).isEmpty
        }.map { "\($0.name) (routine:\($0.id.uuidString))" }
        var metadata = ["tool": "update_state", "agentStateTarget": "workflow", "agentName": sender.name,
                        "agentWorkflowAction": operation,
                        "agentWorkflowID": subject.id,
                        "agentWorkflowReferences": references.sorted().prefix(100).joined(separator: "\n"),
                        "agentWorkflowReferenceCount": String(references.count)]
        func append(_ value: AgentWorkflow, prefix: String) {
            metadata[prefix + "Name"] = value.name
            metadata[prefix + "Description"] = value.description
            metadata[prefix + "Enabled"] = String(value.isEnabled)
            if case .prompt(let body) = value.steps.first { metadata[prefix + "Body"] = body }
        }
        if let proposed { append(proposed, prefix: "agentWorkflow") }
        if let previous { append(previous, prefix: "previousAgentWorkflow") }
        let action = AutoReviewAction(summary: "\(sender.name) → \(FiliconLocalization.string(title)): \(subject.name)",
            target: .resource(kind: "workflow", identifier: subject.id), risks: operation == "delete" ? [.sensitive, .destructive] : [.sensitive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue, metadata: metadata))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] in await self?.registerAutoReviewApproval($0) }
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
    }

    private func authorizeAgentChannelDisconnection(sender: AgentProfile, change: ChannelDisconnection,
                                                    call: NormalizedToolCall, context: ToolContext) async throws {
        guard isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: settings.accountScope ?? "local", agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        let metadata = ["tool": "update_state", "agentStateTarget": "channel", "agentName": sender.name,
            "channelID": change.connectionID.uuidString, "channelPlatform": change.platform,
            "channelName": change.displayName, "channelAccountLabel": change.accountLabel,
            "channelEnabled": String(change.enabled), "channelInboundCount": String(change.inboundCount),
            "channelDeliveryCount": String(change.deliveryCount), "channelPendingCount": String(change.pendingDeliveryCount),
            "channelFailureCount": String(change.failureCount)]
        let action = AutoReviewAction(summary: sender.name + " → " + l10n("Disconnect agent channel"),
            target: .resource(kind: "channel", identifier: change.connectionID.uuidString), risks: [.sensitive, .destructive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue, metadata: metadata))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        // Destructive channel changes never inherit generic tool allow rules.
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] in await self?.registerAutoReviewApproval($0) }
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
    }

    private func commitAgentChannelDisconnection(_ change: ChannelDisconnection, lifetime: ChannelDisconnectionLifetime,
                                                  originID: UUID, generation: UInt64) async throws {
        guard let channelService, let agentService, generation == autoReviewAccountGeneration,
              isAgentMessagingScopeActive(originID),
              let owner = await agentService.profile(id: change.agentID), owner.archivedAt == nil else { throw CancellationError() }
        try lifetime.check()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(originID) else { throw CancellationError() }
        try await channelService.applyDisconnection(change, lifetime: lifetime)
        // Credentials can be shared with other connections. Retain them, as
        // disclosed before approval; local deletion is not remote revocation.
        if generation == autoReviewAccountGeneration { await reloadChannelState() }
    }

    private func authorizeAgentProjectChange(sender: AgentProfile, change: AgentProjectChange,
                                             call: NormalizedToolCall, context: ToolContext) async throws {
        guard isAgentMessagingScopeActive(context.conversationID), change.proposed.accountID == (settings.accountScope ?? "local") else {
            throw CancellationError()
        }
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: change.proposed.accountID, agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        let metadata = ["tool": "update_state", "agentStateTarget": "project", "agentName": sender.name,
            "projectSlug": change.proposed.slug, "projectName": change.proposed.name, "projectDescription": change.proposed.summary,
            "projectCreates": String(change.createsProject), "projectAction": change.action.rawValue,
            "projectBeforeJoined": String(change.previous?.memberIDs.contains(change.agentID) ?? false),
            "projectAfterJoined": String(change.proposed.memberIDs.contains(change.agentID)),
            "projectBeforeCount": String(change.previous?.memberIDs.count ?? 0), "projectAfterCount": String(change.proposed.memberIDs.count)]
        let action = AutoReviewAction(summary: sender.name + " → " + l10n("Collaboration project membership"),
            target: .resource(kind: "agent-project", identifier: change.proposed.slug), risks: [.sensitive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue, metadata: metadata))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] in await self?.registerAutoReviewApproval($0) }
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
    }

    static func projectQuotaKey(accountID: String, slug: String) -> String {
        // The quota ledger is app-wide, whereas slugs are unique only per account.
        // Base64 has no colon separator and bounds a 256-byte account ID below
        // the ledger's 512-byte key limit, even with a maximum-length slug.
        "agent-project-" + Data(accountID.utf8).base64EncodedString() + ":" + slug
    }

    private func commitAgentProjectChange(_ change: AgentProjectChange, lifetime: AgentProjectChangeLifetime,
                                          originID: UUID, generation: UInt64) async throws {
        guard let agentService, isAgentMessagingScopeActive(originID), generation == autoReviewAccountGeneration,
              change.proposed.accountID == (settings.accountScope ?? "local") else { throw CancellationError() }
        let payload = try JSONEncoder().encode(change.proposed)
        do {
            try await quotaWrite(scope: "workflow", key: Self.projectQuotaKey(accountID: change.proposed.accountID, slug: change.proposed.slug), data: payload) {
                try await agentService.applyProjectChange(change, lifetime: lifetime)
            }
        } catch {
            guard lifetime.committed(change) else { throw error }
            errorMessage = Self.quotaMessage(error)
        }
    }

    private func authorizeAgentSettingsChange(sender: AgentProfile, change: AgentSettingsChange,
                                              call: NormalizedToolCall, context: ToolContext) async throws {
        guard isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: settings.accountScope ?? "local", agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        let metadata = ["tool": "update_state", "agentStateTarget": "settings", "agentName": sender.name,
                        "agentNotifyOnUpdates": String(change.notifyOnUpdates), "previousAgentNotifyOnUpdates": String(change.previousValue)]
        let action = AutoReviewAction(summary: sender.name + " → " + l10n("Agent update notifications"),
            target: .resource(kind: "agent", identifier: change.agentID.uuidString), risks: [.sensitive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue, metadata: metadata))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        // Muting must never inherit a general update_state allow rule.
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] in await self?.registerAutoReviewApproval($0) }
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
    }

    private func commitAgentSettingsChange(_ change: AgentSettingsChange, lifetime: AgentSettingsChangeLifetime,
                                           originID: UUID, generation: UInt64) async throws -> AgentProfile {
        guard let agentService, isAgentMessagingScopeActive(originID), generation == autoReviewAccountGeneration,
              var proposed = await agentService.profile(id: change.agentID) else { throw CancellationError() }
        proposed.notifyOnAgentUpdates = change.notifyOnUpdates
        let payload = try JSONEncoder().encode(proposed)
        let profile: AgentProfile
        do {
            profile = try await quotaWrite(scope: "workflow", key: "agent-\(change.agentID)", data: payload) {
                try await agentService.applySettingsChange(change, lifetime: lifetime)
            }
        } catch {
            guard let saved = lifetime.committedProfile(for: change) else { throw error }
            errorMessage = Self.quotaMessage(error)
            profile = saved
        }
        let current = await agentService.list(includeArchived: true)
        guard generation == autoReviewAccountGeneration else { return profile }
        agents = current
        await projectAgentNotifications()
        return profile
    }

    private func authorizeAgentAvatarChange(sender: AgentProfile, change: AgentAvatarChange,
                                            call: NormalizedToolCall, context: ToolContext) async throws {
        guard isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: settings.accountScope ?? "local", agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        let pet = change.pet ?? .codex
        let metadata = ["tool": "update_state", "agentStateTarget": "avatar", "agentAvatarAction": change.operation.rawValue,
                        "agentName": sender.name, "agentAvatarPet": pet.rawValue,
                        "previousAgentAvatarPet": sender.avatar?.kind == .pet ? sender.avatar?.petID ?? "" : ""]
        let action = AutoReviewAction(summary: "\(sender.name) → \(pet.name)",
            target: .resource(kind: "agent", identifier: change.agentID.uuidString), risks: [.sensitive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue, metadata: metadata))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] in await self?.registerAutoReviewApproval($0) }
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
    }

    private func authorizeAgentProfileChange(sender: AgentProfile, change: AgentProfileChange,
                                             call: NormalizedToolCall, context: ToolContext) async throws {
        guard isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: settings.accountScope ?? "local", agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        var metadata = ["tool": change.operation.rawValue, "agentName": change.name, "agentDescription": change.description,
                        "agentProvider": change.providerID.rawValue, "agentModel": change.modelID.rawValue]
        metadata["previousAgentName"] = change.previousName
        metadata["previousAgentDescription"] = change.previousDescription
        let action = AutoReviewAction(summary: "\(sender.name) → \(change.operation.rawValue): \(change.name)",
            target: .resource(kind: "agent", identifier: change.targetID.uuidString), risks: [.sensitive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue, metadata: metadata))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        // Profile writes always ask, even when a general auto-review rule allows
        // the tool name. Approval of a message is not profile-write permission.
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] pending in
            await self?.registerAutoReviewApproval(pending)
        }
        try Task.checkCancellation()
        guard isAgentMessagingScopeActive(context.conversationID), generation == autoReviewAccountGeneration else {
            throw CancellationError()
        }
    }

    private func isAgentMessagingScopeActive(_ scopeID: UUID) -> Bool {
        !agentMessagingAccountTransition && (
            (runningGroups.contains(scopeID) && !cancelledGroupRuns.contains(scopeID))
                || (runningAgentMessageScopes.contains(scopeID) && agentMessageTasks[scopeID]?.isCancelled == false)
        )
    }

    func markAgentMessagesRead(recipientID: UUID) async {
        guard let agentMessenger else {
            errorMessage = l10n("Agent messaging storage is unavailable.")
            return
        }
        do {
            while try await agentMessenger.dequeue(recipientID: recipientID) != nil {}
            await reloadAgentMessages()
        } catch {
            errorMessage = l10n("Messages could not be marked read: \(error.localizedDescription)")
            await reloadAgentMessages()
        }
    }

    func reloadAgentMessages() async {
        guard let agentMessenger else {
            agentMessages = []
            agentMessageUnreadCounts = [:]
            return
        }
        let stored = await agentMessenger.allMessages().sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        agentMessages = Array(stored.suffix(Self.maximumVisibleAgentMessages))
        agentMessageUnreadCounts = Dictionary(grouping: stored.lazy.filter { $0.deliveredAt == nil }, by: \.recipientID)
            .mapValues(\.count)
    }

    func retryAgent(id: UUID) async {
        guard let agentService else { return }
        do {
            try await agentService.setPresence(id: id, status: .idle)
            agents = await agentService.list(includeArchived: true)
        } catch { errorMessage = error.localizedDescription }
    }

    func importAgentAvatar(from url: URL, crop: AgentAvatarCrop, shape: AgentAvatarShape) -> AgentAvatar? {
        do { return try agentAvatarStore.importImage(at: url, crop: crop, shape: shape) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func agentAvatarURL(for avatar: AgentAvatar?) -> URL? {
        avatar.flatMap(agentAvatarStore.imageURL(for:))
    }

    func cancelAgentTask(id: UUID) async {
        guard let subagentService else { return }
        await subagentService.cancel(id)
        try? await Task.sleep(for: .milliseconds(20))
        await reloadAgentTasks()
    }

    func launchAgentTask(kind: AgentTaskKind, agentID: UUID, title: String, prompt: String) async {
        guard !agentMessagingAccountTransition else { return }
        let generation = autoReviewAccountGeneration
        guard let subagentService, let agentService,
              let profile = await agentService.profile(id: agentID), profile.archivedAt == nil else {
            errorMessage = l10n("The selected agent is unavailable."); return
        }
        guard !agentMessagingAccountTransition, generation == autoReviewAccountGeneration else { return }
        let runtime: any AgentAsyncTaskRuntime
        switch kind {
        case .shell:
            runtime = AppShellTaskRuntime()
        case .subagent:
            runtime = AppProviderTaskRuntime(kind: kind, registry: registry, profile: profile)
        case .cloud:
            let endpoint = try? CloudAgentEndpoint(URL(string: cloudAgentEndpoint) ?? URL(fileURLWithPath: "/"))
            let reference = CloudAgentBearerReference(rawValue: cloudAgentCredentialReference)
            let configuration = endpoint.map { CloudAgentBackendConfiguration(endpoint: $0, bearerReference: reference) }
            let backend = CloudAgentBackend(configuration: configuration, bearerProvider: AppCloudBearerProvider(credentials: credentials))
            let coordinator = CloudAgentRunCoordinator(backend: backend, agentID: profile.id.uuidString.lowercased())
            runtime = AppCloudTaskRuntime(
                runtime: CloudAgentRuntime(
                    coordinator: coordinator,
                    resumeRemoteRunID: Self.persistedCloudRunID(agentID: profile.id)
                ),
                agentID: profile.id
            )
        }
        do {
            _ = try await subagentService.launch(
                .init(agentID: agentID, title: title, prompt: prompt, parentToolCallID: "workspace-\(UUID().uuidString)",
                      depth: 0, parentAgentID: nil, taskKind: kind),
                parentRunID: UUID(), parentScope: .init(), runtime: runtime
            )
            await reloadAgentTasks()
            Task { [weak self] in
                await subagentService.drain()
                await self?.reloadAgentTasks()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func reloadAgentTasks() async {
        guard let agentService else { return }
        agentAsyncTasks = await agentService.subagents().map(AgentAsyncTask.init(record:))
        agents = await agentService.list(includeArchived: true)
        await projectAgentNotifications()
    }

    private func projectAgentNotifications() async {
        guard systemNotifications.notificationTransportIsActive else {
            agentNotificationBaselineSeeded = false
            systemNotifications.updateAgentDockBadge([])
            return
        }
        let notifications = AgentNotificationProjection.notificationSnapshots(
            profiles: agents,
            tasks: agentAsyncTasks
        )
        let dock = AgentNotificationProjection.dockSnapshots(
            profiles: agents,
            tasks: agentAsyncTasks
        )
        if agentNotificationBaselineSeeded {
            await systemNotifications.handleAgentRoster(notifications)
        } else {
            systemNotifications.seedAgentNotificationBaseline(notifications)
            agentNotificationBaselineSeeded = true
        }
        systemNotifications.updateAgentDockBadge(dock)
    }

    private func synchronizeNotificationTransport() async {
        let desiredScope: String? = if accountController == nil {
            "local"
        } else if case .signedIn = accountState,
                  accountConnection.phase == .connected {
            accountState.session?.profile.id
        } else {
            nil
        }

        if let desiredScope {
            guard systemNotifications.activateNotificationTransport(scopeID: desiredScope) else { return }
            await inAppNotifications.clearAll()
            agentNotificationBaselineSeeded = false
            await reloadAgentTasks()
        } else {
            let changed = systemNotifications.deactivateNotificationTransport()
            guard changed || agentNotificationBaselineSeeded || !notificationTrays.isEmpty else { return }
            agentNotificationBaselineSeeded = false
            await inAppNotifications.clearAll()
            notificationTrays = []
        }
    }

    private func markAgentsViewed() async {
        guard let agentService else { return }
        for profile in agents where profile.unreadCount > 0 {
            try? await agentService.setUnreadCount(id: profile.id, count: 0)
        }
        agents = await agentService.list(includeArchived: true)
        systemNotifications.updateAgentDockBadge(
            AgentNotificationProjection.dockSnapshots(profiles: agents, tasks: agentAsyncTasks)
        )
    }

    func configureCloudAgents(endpoint: String, credentialReference: String, bearer: String) async {
        let endpointValue = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceValue = credentialReference.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try CloudAgentEndpoint(URL(string: endpointValue) ?? URL(fileURLWithPath: "/"))
            guard let reference = CloudAgentBearerReference(rawValue: referenceValue) else { throw CloudAgentError.invalidCredential }
            if !bearer.isEmpty {
                try await credentials.set(bearer, for: Self.cloudCredentialRef(reference.rawValue))
            }
            cloudAgentEndpoint = endpointValue
            cloudAgentCredentialReference = reference.rawValue
            UserDefaults.standard.set(endpointValue, forKey: "FiliconCloudAgentEndpoint")
            UserDefaults.standard.set(reference.rawValue, forKey: "FiliconCloudAgentCredentialReference")
            await refreshCloudAgents()
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshCloudAgents() async {
        isRefreshingCloudAgents = true
        defer { isRefreshingCloudAgents = false }
        do { cloudAgentCatalog = try await cloudAgentBackend().list() }
        catch { cloudAgentCatalog = []; errorMessage = error.localizedDescription }
    }

    func cloudAgent(id: String) async -> CloudAgentDescriptor? {
        do { return try await cloudAgentBackend().get(agentID: id) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    private func cloudAgentBackend() throws -> CloudAgentBackend {
        guard let url = URL(string: cloudAgentEndpoint) else { throw CloudAgentError.unconfigured }
        let endpoint = try CloudAgentEndpoint(url)
        let reference = CloudAgentBearerReference(rawValue: cloudAgentCredentialReference)
        return CloudAgentBackend(
            configuration: .init(endpoint: endpoint, bearerReference: reference),
            bearerProvider: AppCloudBearerProvider(credentials: credentials)
        )
    }

    fileprivate static func cloudCredentialRef(_ reference: String) -> CredentialRef {
        .init(providerID: ProviderID(rawValue: "cloud-agent"), account: reference)
    }

    private static func persistedCloudRunID(agentID: UUID) -> String? {
        UserDefaults.standard.string(forKey: "FiliconCloudAgentRun.\(agentID.uuidString.lowercased())")
    }

    private func resumePersistedCloudRuns() async {
        guard !cloudAgentEndpoint.isEmpty, let agentService else { return }
        for profile in agents where Self.persistedCloudRunID(agentID: profile.id) != nil {
            for record in await agentService.subagents()
            where record.agentID == profile.id && record.taskKind == .cloud
                && [.queued, .running, .awaitingInput].contains(record.status) {
                try? await agentService.updateSubagent(
                    id: record.id, status: .cancelled,
                    result: "Reattached after app restart in a replacement task record."
                )
            }
            await launchAgentTask(
                kind: .cloud, agentID: profile.id,
                title: "Resume \(profile.name)", prompt: "Resume the persisted remote run."
            )
        }
    }

    func cloneAgent(id: UUID) async {
        guard let agentService else { return }
        do { _ = try await agentService.clone(id: id); agents = await agentService.list(includeArchived: true) }
        catch { errorMessage = error.localizedDescription }
    }

    private func persistPinnedAgents() {
        UserDefaults.standard.set(pinnedAgentIDs.map(\.uuidString).sorted(), forKey: "FiliconPinnedAgentIDs")
    }

    @discardableResult
    func createGroup(name: String, summary: String, memberIDs: [UUID]) async -> Bool {
        guard let groupService else { errorMessage = l10n("Group storage is unavailable."); return false }
        do {
            let group = try await groupService.create(name: name, summary: summary, memberIDs: memberIDs)
            groups = await groupService.list(); groupMessages[group.id] = []; selectedGroupID = group.id
            selectGroup(id: group.id)
            return true
        }
        catch { errorMessage = error.localizedDescription; return false }
    }

    func saveGroupSettings(groupID: UUID, name: String, summary: String, memberIDs: [UUID]) async -> Bool {
        guard let groupService else { errorMessage = l10n("Group storage is unavailable."); return false }
        do {
            if runningGroups.contains(groupID) { await stopGroup(id: groupID) }
            try await groupService.update(groupID: groupID, name: name, summary: summary, memberIDs: memberIDs)
            groups = await groupService.list()
            groupMessages[groupID] = await groupService.messages(groupID: groupID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateGroupMembers(groupID: UUID, memberIDs: [UUID]) async {
        guard let groupService else { return }
        if runningGroups.contains(groupID) { await stopGroup(id: groupID) }
        do {
            try await groupService.updateMembers(groupID: groupID, memberIDs: memberIDs)
            groups = await groupService.list()
            groupMessages[groupID] = await groupService.messages(groupID: groupID)
        }
        catch { errorMessage = error.localizedDescription }
    }

    func sendGroupMessage(groupID: UUID, text: String, images: [AttachmentMetadata] = [],
                          replyToMessageID: UUID? = nil,
                          questionReply: (UUID, AgentQuestionAnswer)? = nil,
                          onPosted: @MainActor () -> Void = {}) async {
        guard let groupService, !agentMessagingAccountTransition,
              !runningGroups.contains(groupID), !stoppingGroups.contains(groupID) else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty || questionReply != nil,
              let group = groups.first(where: { $0.id == groupID }), !group.memberIDs.isEmpty else { return }
        guard questionReply == nil || (images.isEmpty && replyToMessageID == nil) else { return }
        let generation = autoReviewAccountGeneration
        let questionLifetime = AgentPublicationLifetime()
        groupQuestionLifetimes[groupID] = questionLifetime
        // Reserve before the first suspension so two sends cannot race.
        runningGroups.insert(groupID)
        workspaceFolders.beginTurn(conversationID: groupID)
        let messaging = makeAgentMessagingSession(originID: groupID)
        agentMessagingSessions[groupID] = messaging
        var imageRecipientName: String?
        var imageRecipientIDs: Set<UUID> = []
        defer {
            questionLifetime.close()
            groupQuestionLifetimes[groupID] = nil
            agentMessagingSessions[groupID] = nil
            runningGroups.remove(groupID)
            cancelledGroupRuns.remove(groupID)
            thinkingGroupMembers[groupID] = nil
            reviewingMemoryGroups.remove(groupID)
        }
        do {
            guard text.count <= 8_000 else { throw AgentServiceError.messageTooLong }
            let loadedImages = try await agentImageStore.load(images)
            if !images.isEmpty {
                let members = agents.filter { group.memberIDs.contains($0.id) && $0.archivedAt == nil }
                if let unknown = GroupService.unknownMentions(in: text, members: members).first {
                    throw AgentServiceError.unknownGroupMention(unknown)
                }
                let mentions = GroupService.parseMentions(in: text, members: members)
                let recipients = members.filter { mentions.everyone || mentions.memberIDs.isEmpty || mentions.memberIDs.contains($0.id) }
                guard !recipients.isEmpty else { throw AgentImageError.unsupported }
                for recipient in recipients {
                    imageRecipientName = recipient.name
                    try await GroupConversationResponder.validateImageInput(agent: recipient, registry: registry)
                }
                imageRecipientName = nil
                imageRecipientIDs = Set(recipients.map(\.id))
            }
            guard generation == autoReviewAccountGeneration, !agentMessagingAccountTransition,
                  !cancelledGroupRuns.contains(groupID) else { throw CancellationError() }
            try Task.checkCancellation()
            let posted: RoomMessage
            if let (messageID, answer) = questionReply {
                posted = try await groupService.answerQuestion(groupID: groupID, messageID: messageID, answer: answer,
                    accountID: settings.accountScope ?? "local", lifetime: questionLifetime)
            } else {
                posted = try await groupService.postUserMessage(text, groupID: groupID, images: images,
                    expectedMemberIDs: group.memberIDs, replyToMessageID: replyToMessageID)
            }
            guard generation == autoReviewAccountGeneration, !agentMessagingAccountTransition else { throw CancellationError() }
            onPosted()
            groupMessages[groupID] = await groupService.messages(groupID: groupID)
            guard generation == autoReviewAccountGeneration, !agentMessagingAccountTransition,
                  !cancelledGroupRuns.contains(groupID) else { throw CancellationError() }
            let produced = try await groupService.run(
                groupID: groupID,
                responder: GroupConversationResponder(groupID: groupID, registry: registry, coordinator: coordinator, messaging: messaging,
                    userMessageID: posted.id, userImages: loadedImages, imageRecipientIDs: imageRecipientIDs,
                    questionAccountID: settings.accountScope ?? "local", questionLifetime: questionLifetime),
                onAgentChange: { [weak self] agentID in
                    await MainActor.run { self?.thinkingGroupMembers[groupID] = agentID }
                }
            ) { [weak self] message in
                await MainActor.run {
                    guard let self, self.autoReviewAccountGeneration == generation else { return }
                    if let index = self.groupMessages[groupID, default: []].firstIndex(where: { $0.id == message.id }) {
                        self.groupMessages[groupID]?[index] = message
                    } else { self.groupMessages[groupID, default: []].append(message) }
                }
            }
            if !cancelledGroupRuns.contains(groupID), !produced.contains(where: { $0.question != nil }) {
                try await messaging?.drain(onAgentChange: { [weak self] agentID in
                    await MainActor.run { self?.thinkingGroupMembers[groupID] = agentID }
                }, onUpdate: { [weak self] message in
                    guard let self else { throw CancellationError() }
                    try await self.recordDelegatedGroupMessage(message)
                })
            }
            groupMessages[groupID] = await groupService.messages(groupID: groupID)
            if !cancelledGroupRuns.contains(groupID), !produced.contains(where: { $0.question != nil }) {
                if await messaging?.hasMemorySuggestionsToProcess == true { reviewingMemoryGroups.insert(groupID) }
                await messaging?.suggestMemories()
                reviewingMemoryGroups.remove(groupID)
            }
        } catch is CancellationError {
            let messages = await groupService.messages(groupID: groupID)
            if generation == autoReviewAccountGeneration { groupMessages[groupID] = messages }
        } catch {
            let messages = await groupService.messages(groupID: groupID)
            if generation == autoReviewAccountGeneration { groupMessages[groupID] = messages }
            if !stoppingGroups.contains(groupID), !cancelledGroupRuns.contains(groupID), generation == autoReviewAccountGeneration {
                let detail = FiliconLocalization.string(error.localizedDescription)
                errorMessage = imageRecipientName.map { "\($0): \(detail)" } ?? detail
            }
        }
        do { try await messaging?.close() }
        catch { errorMessage = error.localizedDescription }
        await cancelAutoReviewApprovals(conversationID: groupID, lifecycle: .cancelled)
    }

    func stopGroup(id: UUID) async {
        if let originID = delegatedGroupOrigins[id] {
            if runningAgentMessageScopes.contains(originID) { await stopAgentMessages(scopeID: originID) }
            else { await stopGroup(id: originID) }
            return
        }
        guard runningGroups.contains(id), stoppingGroups.insert(id).inserted else { return }
        groupQuestionLifetimes[id]?.close()
        agentMessagingSessions[id]?.revokeProfileChanges()
        cancelledGroupRuns.insert(id)
        workspaceFolders.cancel(conversationID: id)
        defer { stoppingGroups.remove(id) }
        do { try await agentMessagingSessions[id]?.close() }
        catch { errorMessage = error.localizedDescription }
        await groupService?.stop(groupID: id)
        await coordinator.cancel(conversationID: id)
        await cancelAutoReviewApprovals(conversationID: id, lifecycle: .cancelled)
        await localToolApprovalBroker.cancel(conversationID: id)
        await localToolPermissionPolicy.revokePendingGrants(conversationID: id)
        await localToolRuntime.cancel(conversationID: id)
        await invalidateMCPAuthorization(conversationID: id)
        thinkingGroupMembers[id] = nil
    }

    func canAnswerGroupQuestion(_ message: RoomMessage) -> Bool {
        guard !agentMessagingAccountTransition, !runningGroups.contains(message.groupID), !stoppingGroups.contains(message.groupID),
              groupMessages[message.groupID]?.contains(message) == true,
              let card = message.question, card.isPending, card.accountID == (settings.accountScope ?? "local"),
              groups.first(where: { $0.id == message.groupID })?.memberIDs == card.memberIDs,
              agents.contains(where: { $0.id == message.senderID && $0.archivedAt == nil }) else { return false }
        return true
    }

    func groupQuestionAnswered(_ message: RoomMessage, answer: AgentQuestionAnswer) async {
        guard canAnswerGroupQuestion(message) else { return }
        await sendGroupMessage(groupID: message.groupID, text: "", questionReply: (message.id, answer))
    }

    private func recordDelegatedGroupMessage(_ message: RoomMessage) async throws {
        guard let groupService, runningGroups.contains(message.groupID), !cancelledGroupRuns.contains(message.groupID) else {
            throw CancellationError()
        }
        try await groupService.recordDelegatedMessage(message)
        groupMessages[message.groupID] = await groupService.messages(groupID: message.groupID)
    }

    private func authorizeAgentDelegation(sender: AgentProfile, recipient: AgentProfile, text: String,
                                           call: NormalizedToolCall, context: ToolContext, images: [AttachmentMetadata] = []) async throws {
        guard isAgentMessagingScopeActive(context.conversationID) else {
            throw CancellationError()
        }
        let fence = ApprovalFence(accountID: settings.accountScope ?? "local", agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: autoReviewAccountGeneration)
        await autoReviewBroker.activate(fence)
        struct Options: Decodable { let priority: Bool? }
        let priority = try JSONDecoder().decode(Options.self, from: call.argumentsJSON).priority == true
        var metadata = ["tool": "SendToAgent", "agentMessage": text, "agentMessagePriority": priority ? "priority" : "normal"]
        if !images.isEmpty { metadata["agentImages"] = String(decoding: try JSONEncoder().encode(images), as: UTF8.self) }
        let action = AutoReviewAction(
            summary: "\(sender.name) → \(recipient.name)", target: .recipient(identifier: recipient.id.uuidString),
            risks: [.sensitive], context: .init(fence: fence, conversationID: context.conversationID,
                                             toolCallID: call.id.rawValue, metadata: metadata)
        )
        // Always show the exact recipient and payload. General auto-review allow
        // rules never authorize expanding the participating agent set implicitly.
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] pending in
            await self?.registerAutoReviewApproval(pending)
        }
        try Task.checkCancellation()
        guard isAgentMessagingScopeActive(context.conversationID) else {
            throw CancellationError()
        }
    }

    private func authorizeAgentImagePublication(sender: AgentProfile, text: String, images: [AttachmentMetadata],
                                                 call: NormalizedToolCall, context: ToolContext) async throws {
        guard isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
        let generation = autoReviewAccountGeneration
        let fence = ApprovalFence(accountID: settings.accountScope ?? "local", agentID: context.conversationID.uuidString.lowercased(),
                                  runID: context.runID, generation: generation)
        await autoReviewBroker.activate(fence)
        var metadata = ["tool": "SendMessage", "agentMessage": text, "agentImagePublication": "true",
                        "agentImages": String(decoding: try JSONEncoder().encode(images), as: UTF8.self)]
        let group = groups.first { $0.id == context.conversationID }
        if let group {
            metadata["agentGroupName"] = group.name
            metadata["agentGroupMembers"] = group.memberIDs.map { id in
                "\(agents.first(where: { $0.id == id })?.name ?? id.uuidString) (\(id.uuidString))"
            }.joined(separator: "\n")
        }
        let action = AutoReviewAction(summary: "\(sender.name) → \(group?.name ?? l10n("User in this conversation"))",
            target: .resource(kind: "conversation", identifier: context.conversationID.uuidString), risks: [.sensitive],
            context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue,
                metadata: metadata))
        let pending = PendingApproval(action: action, reason: "Approval required", expiresAt: Date().addingTimeInterval(300))
        try await autoReviewBroker.waitForApprovalToExecute(pending) { [weak self] in await self?.registerAutoReviewApproval($0) }
        try Task.checkCancellation()
        guard generation == autoReviewAccountGeneration, isAgentMessagingScopeActive(context.conversationID) else { throw CancellationError() }
    }

    func toggleGroupReaction(groupID: UUID, messageID: UUID, emoji: String) async {
        guard let groupService, let actor = groups.first(where: { $0.id == groupID })?.memberIDs.first else { return }
        do { _ = try await groupService.toggleReaction(messageID: messageID, actorID: actor, emoji: emoji) }
        catch { errorMessage = error.localizedDescription }
    }

    func createChannelConnection(connectorID: String, displayName: String, channelIDs: String, token: String, agentID: UUID?) async {
        guard let channelService else { errorMessage = l10n("Channel storage is unavailable."); return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { errorMessage = l10n("Enter the bot token."); return }
        let id = UUID()
        let reference = "keychain://channels/\(id.uuidString.lowercased())"
        do {
            try await credentials.set(token, for: Self.channelCredentialReference(reference))
            let connection = ChannelConnection(
                id: id,
                connectorID: connectorID,
                displayName: displayName,
                accountLabel: channelIDs,
                secretReference: reference,
                agentID: agentID,
                authKind: .botToken
            )
            _ = try await channelService.saveConnection(connection)
            _ = try? await channelService.refreshProfile(connectionID: id)
            try await startChannelConnection(id: id)
            await reloadChannelState()
        } catch {
            try? await credentials.remove(Self.channelCredentialReference(reference))
            errorMessage = error.localizedDescription
        }
    }

    func connectChannelOAuth(connectorID: String, clientID: String, displayName: String, channelIDs: String, agentID: UUID?) async {
        guard !channelOAuthInProgress, let channelService else { return }
        let cleanClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanClientID.isEmpty else { errorMessage = l10n("Enter the OAuth client ID."); return }
        channelOAuthInProgress = true
        let listener = ChannelOAuthLoopbackServer()
        defer {
            listener.cancel()
            channelOAuthInProgress = false
        }
        do {
            let callback = try await listener.start()
            let configuration: ChannelOAuthConfiguration
            switch connectorID {
            case "slack": configuration = try .slack(clientID: cleanClientID)
            case "discord": configuration = try .discord(clientID: cleanClientID)
            default: throw ChannelOAuthError.unsupportedProvider
            }
            let request = try await channelOAuthCoordinator.begin(configuration: configuration, redirectURI: callback)
            guard NSWorkspace.shared.open(request.authorizationURL) else {
                await channelOAuthCoordinator.cancel(state: request.state)
                throw ChannelOAuthBrowserError.couldNotOpenBrowser
            }
            let callbackURL = try await listener.waitForCallback(timeout: .seconds(600))
            let token = try await channelOAuthCoordinator.complete(callbackURL: callbackURL)

            let id = UUID()
            let reference = "keychain://channels/\(id.uuidString.lowercased())"
            do {
                try await credentials.set(token.accessToken, for: Self.channelCredentialReference(reference))
                if let refreshToken = token.refreshToken, !refreshToken.isEmpty {
                    try await credentials.set(refreshToken, for: Self.channelCredentialReference(reference + ".refresh"))
                }
                let connection = ChannelConnection(
                    id: id, connectorID: connectorID, displayName: displayName,
                    accountLabel: channelIDs, secretReference: reference,
                    agentID: agentID, authKind: .oauth
                )
                _ = try await channelService.saveConnection(connection)
                _ = try await channelService.refreshProfile(connectionID: id)
                try await startChannelConnection(id: id)
                await reloadChannelState()
            } catch {
                try? await credentials.remove(Self.channelCredentialReference(reference))
                try? await credentials.remove(Self.channelCredentialReference(reference + ".refresh"))
                throw error
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setChannelConnectionEnabled(id: UUID, enabled: Bool) async {
        guard let channelService else { return }
        do {
            try await channelService.setConnectionEnabled(id: id, enabled: enabled)
            if enabled { try await startChannelConnection(id: id) }
            await reloadChannelState()
        } catch { errorMessage = error.localizedDescription }
    }

    func removeChannelConnection(id: UUID) async {
        guard let channelService else { return }
        do {
            let connection = try await channelService.removeConnection(id: id)
            try? await credentials.remove(Self.channelCredentialReference(connection.secretReference))
            if connection.authKind == .oauth {
                try? await credentials.remove(Self.channelCredentialReference(connection.secretReference + ".refresh"))
            }
            await reloadChannelState()
        } catch { errorMessage = error.localizedDescription }
    }

    func sendChannelMessage(connectionID: UUID, channelID: String, threadID: String? = nil, text: String, attachmentURLs: [URL] = []) async {
        guard let channelService,
              let connection = channelConnections.first(where: { $0.id == connectionID }) else { return }
        do {
            var attachments: [ChannelAttachment] = []
            for url in attachmentURLs {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let byteCount = values.fileSize, Int64(byteCount) <= AttachmentLimits.regularBytes else {
                    throw AttachmentStoreError.tooLarge(filename: url.lastPathComponent, limitBytes: AttachmentLimits.regularBytes)
                }
                let metadata = try await channelAttachmentStore.ingest(fileURL: url)
                attachments.append(.init(blobID: metadata.id, filename: metadata.filename, mimeType: metadata.mimeType, byteCount: metadata.byteCount))
            }
            let cleanThread = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await channelService.enqueue(
                .init(text: text, attachments: attachments),
                to: .init(platform: connection.connectorID, channelID: channelID, threadID: cleanThread?.isEmpty == false ? cleanThread : nil),
                connectionID: connectionID
            )
            await channelService.flush()
            await reloadChannelState()
        } catch { errorMessage = error.localizedDescription }
    }

    func setChannelReaction(event: ChannelEnvelope, emoji: String, removing: Bool) async {
        guard let channelService else { return }
        do {
            try await channelService.setReaction(
                emoji, eventID: event.externalEventID, address: event.address,
                connectionID: event.connectionID, removing: removing
            )
            await reloadChannelState()
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshChannelProfile(id: UUID) async {
        do { _ = try await channelService?.refreshProfile(connectionID: id); await reloadChannelState() }
        catch { errorMessage = error.localizedDescription }
    }

    func acknowledgeChannelFailure(id: UUID) async {
        guard let channelService else { return }
        do { try await channelService.acknowledgeFailureWake(id: id); await reloadChannelState() }
        catch { errorMessage = error.localizedDescription }
    }

    private func registerChannelConnectors() async {
        guard let channelService else { return }
        let resolver: ChannelSecretResolver = { [credentials] reference in
            try await credentials.value(for: Self.channelCredentialReference(reference))
        }
        let readBlob: ChannelBlobReader = { [channelAttachmentStore] attachment in
            try await channelAttachmentStore.data(for: .init(
                id: attachment.blobID, filename: attachment.filename, mimeType: attachment.mimeType,
                byteCount: attachment.byteCount, kind: Self.attachmentKind(for: attachment.mimeType)
            ))
        }
        let ingestBlob: ChannelBlobIngestor = { [channelAttachmentStore] data, filename, mimeType in
            let metadata = try await channelAttachmentStore.ingest(data: data, filename: filename, declaredMIMEType: mimeType)
            return .init(blobID: metadata.id, filename: metadata.filename, mimeType: metadata.mimeType, byteCount: metadata.byteCount)
        }
        await channelService.register(SlackChannelConnector(resolveSecret: resolver, readBlob: readBlob, ingestBlob: ingestBlob))
        await channelService.register(DiscordChannelConnector(resolveSecret: resolver, readBlob: readBlob, ingestBlob: ingestBlob))
        channelDescriptors = await channelService.connectorDescriptors()
    }

    private static func attachmentKind(for mimeType: String) -> AttachmentKind {
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        if mimeType.hasPrefix("text/") || mimeType == "application/pdf" { return .document }
        return .other
    }

    private func startEnabledChannelConnections() async {
        for connection in channelConnections where connection.enabled {
            do { try await startChannelConnection(id: connection.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func startChannelConnection(id: UUID) async throws {
        guard let channelService else { return }
        try await channelService.start(connectionID: id) { [weak self] envelope in
            await self?.handleInboundChannel(envelope)
        }
    }

    private func handleInboundChannel(_ envelope: ChannelEnvelope) async {
        await reloadChannelState()
        let payload: [String: Any] = [
            "channel": envelope.address.channelID,
            "sender": envelope.senderID,
            "text": envelope.text,
            "platform": envelope.address.platform,
            "authenticated": true,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            await ingestAutomationEvent(.init(
                connectorID: envelope.connectionID,
                kind: envelope.address.platform,
                externalEventID: envelope.externalEventID,
                payloadJSON: data,
                occurredAt: envelope.timestamp
            ))
        }
        await respondToInboundChannel(envelope)
    }

    private func respondToInboundChannel(_ envelope: ChannelEnvelope) async {
        guard !agentMessagingAccountTransition,
              let connection = channelConnections.first(where: { $0.id == envelope.connectionID && $0.enabled }),
              let agentID = connection.agentID else { return }
        let generation = autoReviewAccountGeneration
        do {
            try await agentExecutionScheduler.withExclusiveAccess(agentID: agentID) {
                try await self.respondToScheduledChannel(envelope, agentID: agentID, generation: generation)
            }
        } catch is CancellationError { /* Stopped or superseded while waiting for this agent. */
        } catch { errorMessage = error.localizedDescription }
    }

    private func respondToScheduledChannel(_ envelope: ChannelEnvelope, agentID: UUID, generation: UInt64) async throws {
        guard let channelService, let agentService else { return }
        // Revalidate after waiting: a queued reply must not revive a disabled
        // connection or run a profile captured before an account transition.
        let connections = await channelService.connections()
        guard connections.contains(where: { $0.id == envelope.connectionID && $0.enabled && $0.agentID == agentID }),
              let profile = await agentService.profile(id: agentID), profile.archivedAt == nil,
              let provider = await registry.provider(id: profile.providerID),
              !agentMessagingAccountTransition, generation == autoReviewAccountGeneration else { return }
        try Task.checkCancellation()
        let request = InferenceRequest(conversationID: UUID(), modelID: profile.modelID, messages: [
            .init(role: .system, text: profile.instructions),
            .init(role: .user, text: "\(envelope.senderDisplayName): \(envelope.text)"),
        ])
        var response = ""
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            if case .textDelta(let value) = event { response += value }
        }
        let currentConnections = await channelService.connections()
        try Task.checkCancellation()
        guard !agentMessagingAccountTransition, generation == autoReviewAccountGeneration,
              currentConnections.contains(where: { $0.id == envelope.connectionID && $0.enabled && $0.agentID == agentID }) else { return }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try await channelService.enqueue(.init(text: trimmed), to: envelope.address, connectionID: envelope.connectionID)
        await channelService.flush()
        await reloadChannelState()
    }

    private func observeChannelDeliveries() {
        guard channelFlushTask == nil else { return }
        channelFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, let channelService = self.channelService else { return }
                await channelService.flush()
                await self.reloadChannelState()
            }
        }
    }

    private func reloadChannelState() async {
        guard let channelService else { return }
        channelConnections = await channelService.connections()
        channelInboundEvents = await channelService.inboundEvents()
        channelDeliveries = await channelService.deliveries()
        channelFailureWakes = await channelService.failureWakes()
    }

    private static func channelCredentialReference(_ secretReference: String) -> CredentialRef {
        let prefix = "keychain://channels/"
        let identifier = secretReference.hasPrefix(prefix) ? String(secretReference.dropFirst(prefix.count)) : secretReference
        return CredentialRef(providerID: ProviderID(rawValue: "channel.\(identifier)"))
    }

    func createAutomation(agentID: UUID, name: String, prompt: String, schedule: String) async {
        let timeZoneIdentifier = settings.timeZoneIdentifier ?? TimeZone.current.identifier
        await createAutomation(agentID: agentID, name: name, prompt: prompt, trigger: .cron(expression: schedule, timeZoneIdentifier: timeZoneIdentifier))
    }

    func createAutomation(agentID: UUID, name: String, prompt: String, trigger: AutomationTrigger) async {
        guard let automationService else { errorMessage = l10n("Automation storage is unavailable."); return }
        do {
            let proposed = Automation(agentID: agentID, name: name, prompt: prompt, trigger: trigger)
            let data = try JSONEncoder().encode(proposed)
            _ = try await quotaWrite(scope: "automation", key: proposed.id.uuidString, data: data) { [automationService, proposed] in
                try await automationService.save(proposed)
            }
            await reloadAutomationDetails(markViewed: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func beginAutomationEdit(_ automation: Automation) -> RoutineEditSession? {
        guard !agentMessagingAccountTransition, automationService != nil else { return nil }
        let session = RoutineEditSession(automation: automation)
        routineEditSessions[session.id] = session
        return session
    }

    func endAutomationEdit(_ session: RoutineEditSession) {
        session.lifetime.close()
        routineEditSessions.removeValue(forKey: session.id)
    }

    func saveAutomationEdit(_ session: RoutineEditSession, draft: RoutineEditDraft) async throws {
        guard routineEditSessions[session.id]?.lifetime === session.lifetime,
              !agentMessagingAccountTransition, let automationService, let agentService,
              draft.original == session.automation else { throw AutomationEditError.unavailable }
        let generation = autoReviewAccountGeneration
        guard let owner = await agentService.profile(id: session.automation.agentID), owner.archivedAt == nil else {
            throw AutomationEditError.unavailable
        }
        try session.lifetime.check()
        let change = try draft.change
        do {
            let payload = try JSONEncoder().encode(change.automation)
            _ = try await quotaWrite(scope: "automation", key: change.automation.id.uuidString, data: payload) {
                try await automationService.updateManualDefinition(change, lifetime: session.lifetime)
            }
        } catch {
            // A post-commit quota bookkeeping failure must not masquerade as a
            // failed definition write, inviting a stale duplicate retry.
            guard session.lifetime.committed(for: change) != nil else { throw error }
            if generation == autoReviewAccountGeneration { errorMessage = Self.quotaMessage(error) }
        }
        let definitions = await automationService.list()
        if generation == autoReviewAccountGeneration { automations = definitions }
    }

    func setAutomationEnabled(id: UUID, enabled: Bool) async {
        guard let automationService else { return }
        do { try await automationService.setEnabled(id: id, enabled: enabled); await reloadAutomationDetails(markViewed: false) }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteAutomation(id: UUID) async {
        guard let automationService else { return }
        do { try await automationService.delete(id: id); await reloadAutomationDetails(markViewed: false) }
        catch { errorMessage = error.localizedDescription }
    }

    func runAutomationNow(id: UUID) async {
        guard let automationService, let agentService else { return }
        do {
            _ = try await automationService.runNow(id: id, executor: AppAutomationExecutor(registry: registry, agents: agentService, scheduler: agentExecutionScheduler, lane: .user))
            await reloadAutomationDetails(markViewed: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func acknowledgeAutomationWake(id: UUID) async {
        guard let automationService else { return }
        do { try await automationService.acknowledgeWake(id: id); await reloadAutomationDetails(markViewed: false) }
        catch { errorMessage = error.localizedDescription }
    }

    func answerAutomationSpendGuard(_ answer: SpendGuardAnswer) async {
        guard let automationService else { return }
        do { try await automationService.answerSpendGuard(answer); await reloadAutomationDetails(markViewed: true) }
        catch { errorMessage = error.localizedDescription }
    }

    func ingestAutomationEvent(_ event: AutomationEvent) async {
        _ = await automationTriggerHub?.ingest(event)
        await dispatchWorkflowAuthenticatedEvent(event)
    }

    func setAutomationRuntimeActive(_ active: Bool) async {
        if active { await automationScheduler?.resume() }
        else { await automationScheduler?.suspend() }
    }

    func reloadAutomationDetails(markViewed: Bool) async {
        guard let automationService else { return }
        if markViewed { try? await automationService.recordViewed() }
        let definitions = await automationService.list()
        var histories: [UUID: [AutomationRun]] = [:]
        for automation in definitions { histories[automation.id] = await automationService.history(automationID: automation.id) }
        automations = definitions
        automationHistory = histories
        automationWakes = await automationService.pendingWakes()
        automationSpendGuard = await automationService.spendGuardState()
        if let automationIngress {
            automationIngressRoutes = await automationIngress.routes()
            automationIngressAudit = await automationIngress.audits(limit: 100)
            automationIngressStatus = await automationIngress.status()
        }
    }

    func saveAutomationIngressRoute(name: String, provider: AutomationIngressProvider, secret: String) async {
        guard let automationIngress else { errorMessage = l10n("Automation webhook ingress is unavailable."); return }
        let id = UUID(), reference = "route.\(id.uuidString.lowercased()).secret"
        do {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AutomationIngressError.missingSecret }
            try await credentials.set(trimmed, for: CredentialRef(providerID: ProviderID(rawValue: "automation.ingress.\(reference)")))
            _ = try await automationIngress.saveRoute(.init(id: id, name: name, provider: provider, secretReference: reference))
            await reloadAutomationDetails(markViewed: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func removeAutomationIngressRoute(id: UUID) async {
        guard let automationIngress, let route = automationIngressRoutes.first(where: { $0.id == id }) else { return }
        do {
            try await automationIngress.removeRoute(id: id)
            try? await credentials.remove(CredentialRef(providerID: ProviderID(rawValue: "automation.ingress.\(route.secretReference)")))
            await reloadAutomationDetails(markViewed: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func startAutomationIngress(bindMode: AutomationIngressBindMode, port: UInt16, lanOptIn: Bool) async {
        guard let automationIngress else { return }
        do {
            UserDefaults.standard.set(lanOptIn, forKey: "FiliconAutomationIngressLANOptIn")
            try await automationIngress.start(bindMode: bindMode, port: port, localNetworkOptIn: lanOptIn)
            try? await Task.sleep(for: .milliseconds(150))
            await reloadAutomationDetails(markViewed: false)
        } catch { errorMessage = error.localizedDescription; await reloadAutomationDetails(markViewed: false) }
    }

    func stopAutomationIngress() async {
        do { try await automationIngress?.stop(); await reloadAutomationDetails(markViewed: false) }
        catch { errorMessage = error.localizedDescription }
    }

    func automationIngressEndpoint(routeID: UUID) async -> URL? {
        await automationIngress?.endpointURL(for: routeID)
    }

    private func observeAutomationState() {
        guard automationRefreshTask == nil else { return }
        automationRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guard let self else { return }
                if self.route == .automations { await self.reloadAutomationDetails(markViewed: false) }
            }
        }
    }

    func addMCPHTTPServer(identifier: String, displayName: String, endpoint: String) async {
        await invalidateAllMCPAuthorization()
        do {
            guard let url = URL(string: endpoint) else { throw MCPError.invalidConfiguration("Invalid endpoint URL.") }
            let config = try MCPServerConfig(identifier: identifier, displayName: displayName, transport: .streamableHTTP(url: url, headerReferences: [:]))
            mcpConfigs = try await mcpConfigStore.upsert(config)
            mcpAccountDefinitions = try await mcpAccountLibrary.reconcile(existingConfigs: mcpConfigs)
            await applyMCPConfigs()
        } catch { errorMessage = error.localizedDescription }
    }

    func addMCPStdioServer(identifier: String, displayName: String, executable: String, arguments: [String]) async {
        await invalidateAllMCPAuthorization()
        do {
            let config = try MCPServerConfig(
                identifier: identifier,
                displayName: displayName,
                transport: .stdio(
                    executable: executable,
                    arguments: arguments,
                    environmentReferences: [:],
                    workingDirectory: nil
                )
            )
            mcpConfigs = try await mcpConfigStore.upsert(config)
            mcpAccountDefinitions = try await mcpAccountLibrary.reconcile(existingConfigs: mcpConfigs)
            await applyMCPConfigs()
        } catch { errorMessage = error.localizedDescription }
    }

    func addMCPAccount(
        serverID: String, sourceServerIdentifier: String,
        accountKey: String, displayName: String
    ) async {
        await invalidateAllMCPAuthorization()
        do {
            guard let definition = mcpAccountDefinitions.first(where: { $0.id == serverID }) else {
                throw MCPAccountLifecycleError.serverNotFound
            }
            guard !definition.managedReadOnly else { throw MCPAccountLifecycleError.managedDefinition }
            guard let source = mcpConfigs.first(where: { $0.identifier == sourceServerIdentifier }) else {
                throw MCPAccountLifecycleError.accountNotFound
            }
            let normalizedKey = try MCPAccountSlot.normalizeAccountKey(accountKey)
            let identifier = try Self.uniqueMCPAccountIdentifier(
                serverID: serverID, accountKey: normalizedKey,
                existing: Set(mcpConfigs.map(\.identifier))
            )
            var transport = source.transport
            transport = Self.mcpTransport(transport, authorizationReference: nil)
            let config = try MCPServerConfig(
                identifier: identifier,
                displayName: displayName,
                transport: transport,
                enabledTools: source.enabledTools,
                disabledTools: source.disabledTools,
                customInstructions: source.customInstructions,
                enabled: source.enabled
            )
            let slot = try MCPAccountSlot(
                accountKey: normalizedKey, displayName: displayName,
                serverIdentifier: identifier,
                enabledTools: config.enabledTools,
                disabledTools: config.disabledTools,
                customInstructions: config.customInstructions
            )
            mcpConfigs = try await mcpConfigStore.upsert(config)
            do { _ = try await mcpAccountLibrary.addAccount(serverID: serverID, slot: slot) }
            catch {
                mcpConfigs = try await mcpConfigStore.remove(id: config.id)
                throw error
            }
            try await reloadMCPAccountRuntime()
        } catch { errorMessage = error.localizedDescription }
    }

    func authenticateMCPAccount(serverID: String, accountKey: String, bearerToken: String) async {
        await invalidateAllMCPAuthorization()
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { errorMessage = l10n("Enter a bearer token."); return }
        let authorizationValue = token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)"
        do {
            let slot = try Self.mcpAccountSlot(
                definitions: mcpAccountDefinitions, serverID: serverID, accountKey: accountKey
            )
            cancelMCPAccountOAuth(slotID: slot.id)
            await mcpOAuthCoordinator.cancel(serverID: serverID, accountKey: accountKey)
            guard var config = mcpConfigs.first(where: { $0.identifier == slot.serverIdentifier }) else {
                throw MCPAccountLifecycleError.accountNotFound
            }
            if case .stdio = config.transport {
                throw MCPError.invalidConfiguration("Bearer authentication applies only to HTTP MCP accounts.")
            }
            let reference = Self.mcpAccountAuthorizationReference(slotID: slot.id)
            try await credentials.set(authorizationValue, for: Self.mcpCredentialRef(reference: reference))
            config.transport = Self.mcpTransport(config.transport, authorizationReference: reference)
            do {
                mcpConfigs = try await mcpConfigStore.upsert(config)
                _ = try await mcpAccountLibrary.setAuthentication(
                    serverID: serverID, accountKey: accountKey,
                    status: .authenticated, tokenReference: reference
                )
            } catch {
                try? await credentials.remove(Self.mcpCredentialRef(reference: reference))
                throw error
            }
            try await reloadMCPAccountRuntime()
        } catch { errorMessage = error.localizedDescription }
    }

    func authenticateMCPAccountOAuth(
        serverID: String,
        accountKey: String,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        clientID: String,
        scopes: String,
        audience: String
    ) async {
        await invalidateAllMCPAuthorization()
        errorMessage = nil
        var startedSlot: MCPAccountSlot?
        var attemptID: UUID?
        do {
            let slot = try Self.mcpAccountSlot(
                definitions: mcpAccountDefinitions, serverID: serverID, accountKey: accountKey
            )
            guard var config = mcpConfigs.first(where: { $0.identifier == slot.serverIdentifier }) else {
                throw MCPAccountLifecycleError.accountNotFound
            }
            guard !Self.mcpTransportIsStdio(config.transport) else {
                throw MCPError.invalidConfiguration("OAuth applies only to HTTP MCP accounts.")
            }
            let cleanAuthorizationEndpoint = authorizationEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTokenEndpoint = tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let authorizationURL = URL(string: cleanAuthorizationEndpoint),
                  let tokenURL = URL(string: cleanTokenEndpoint) else {
                throw MCPOAuthFlowError.invalidConfiguration("endpoint URL")
            }
            let scopeValues = scopes
                .split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .map(String.init)
            let oauthConfiguration = try MCPOAuthConfiguration(
                clientID: clientID,
                authorizationEndpoint: authorizationURL,
                tokenEndpoint: tokenURL,
                scopes: scopeValues,
                audience: audience
            )

            cancelMCPAccountOAuth(slotID: slot.id)
            await mcpOAuthCoordinator.cancel(serverID: serverID, accountKey: accountKey)
            let newAttemptID = UUID()
            attemptID = newAttemptID
            startedSlot = slot
            mcpOAuthAttemptIDs[slot.id] = newAttemptID
            mcpOAuthInProgressSlotIDs.insert(slot.id)

            // Starting a new flow intentionally revokes the old credential and
            // makes the durable account state accurately reflect the pending UI.
            _ = try await mcpAccountLibrary.setAuthentication(
                serverID: serverID, accountKey: accountKey,
                status: .pending, tokenReference: nil
            )
            config.transport = Self.mcpTransport(config.transport, authorizationReference: nil)
            mcpConfigs = try await mcpConfigStore.upsert(config)
            try await reloadMCPAccountRuntime()
            try requireCurrentMCPAttempt(newAttemptID, slot: slot, serverID: serverID, accountKey: accountKey)

            let listener = ChannelOAuthLoopbackServer()
            mcpOAuthListeners[slot.id] = listener
            let callbackURL = try await listener.start()
            try requireCurrentMCPAttempt(newAttemptID, slot: slot, serverID: serverID, accountKey: accountKey)
            let request = try await mcpOAuthFlowCoordinator.begin(
                serverID: serverID,
                accountKey: accountKey,
                configuration: oauthConfiguration,
                callbackURL: callbackURL
            )
            guard mcpOAuthBrowserOpener(request.authorizationURL) else {
                await mcpOAuthCoordinator.cancel(serverID: serverID, accountKey: accountKey)
                throw ChannelOAuthBrowserError.couldNotOpenBrowser
            }
            let callback = try await listener.waitForCallback(timeout: .seconds(600))
            try requireCurrentMCPAttempt(newAttemptID, slot: slot, serverID: serverID, accountKey: accountKey)
            let token = try await mcpOAuthFlowCoordinator.complete(
                callbackURL: callback,
                request: request,
                configuration: oauthConfiguration
            )
            try requireCurrentMCPAttempt(newAttemptID, slot: slot, serverID: serverID, accountKey: accountKey)

            let reference = Self.mcpAccountAuthorizationReference(slotID: slot.id)
            try await credentials.set(
                token.authorizationHeaderValue,
                for: Self.mcpCredentialRef(reference: reference)
            )
            do {
                try requireCurrentMCPAttempt(newAttemptID, slot: slot, serverID: serverID, accountKey: accountKey)
                guard var exactConfig = mcpConfigs.first(where: { $0.identifier == slot.serverIdentifier }) else {
                    throw MCPAccountLifecycleError.accountNotFound
                }
                exactConfig.transport = Self.mcpTransport(exactConfig.transport, authorizationReference: reference)
                mcpConfigs = try await mcpConfigStore.upsert(exactConfig)
                try requireCurrentMCPAttempt(newAttemptID, slot: slot, serverID: serverID, accountKey: accountKey)
                _ = try await mcpAccountLibrary.setAuthentication(
                    serverID: serverID, accountKey: accountKey,
                    status: .authenticated, tokenReference: reference
                )
            } catch {
                try? await credentials.remove(Self.mcpCredentialRef(reference: reference))
                throw error
            }
            // Refresh tokens are deliberately not persisted until refresh is
            // implemented. They remain transient and never enter JSON or logs.
            _ = token.refreshToken
            finishMCPAccountOAuth(slotID: slot.id, attemptID: newAttemptID)
            try await reloadMCPAccountRuntime()
        } catch {
            if let slot = startedSlot, let attemptID,
               mcpOAuthAttemptIDs[slot.id] == attemptID {
                finishMCPAccountOAuth(slotID: slot.id, attemptID: attemptID)
                await mcpOAuthCoordinator.cancel(serverID: serverID, accountKey: accountKey)
                do {
                    _ = try await mcpAccountLibrary.setAuthentication(
                        serverID: serverID, accountKey: accountKey,
                        status: .failed, tokenReference: nil
                    )
                    if var config = mcpConfigs.first(where: { $0.identifier == slot.serverIdentifier }) {
                        config.transport = Self.mcpTransport(config.transport, authorizationReference: nil)
                        mcpConfigs = try await mcpConfigStore.upsert(config)
                    }
                    try await reloadMCPAccountRuntime()
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
            errorMessage = error.localizedDescription
        }
    }

    func renameMCPAccount(
        serverID: String, accountKey: String, newAccountKey: String, displayName: String
    ) async {
        await invalidateAllMCPAuthorization()
        do {
            let slot = try Self.mcpAccountSlot(
                definitions: mcpAccountDefinitions, serverID: serverID, accountKey: accountKey
            )
            cancelMCPAccountOAuth(slotID: slot.id)
            await mcpOAuthCoordinator.accountRenamed(
                serverID: serverID, oldAccountKey: accountKey, newAccountKey: newAccountKey
            )
            if slot.authStatus == .pending {
                _ = try await mcpAccountLibrary.setAuthentication(
                    serverID: serverID, accountKey: accountKey,
                    status: .failed, tokenReference: nil
                )
                mcpAccountDefinitions = try await mcpAccountLibrary.list()
            }
            _ = try await mcpAccountLibrary.renameAccount(
                serverID: serverID, accountKey: accountKey,
                newAccountKey: newAccountKey, displayName: displayName
            )
            try await reloadMCPAccountRuntime()
        } catch { errorMessage = error.localizedDescription }
    }

    func logoutMCPAccount(serverID: String, accountKey: String) async {
        await invalidateAllMCPAuthorization()
        do {
            let slot = try Self.mcpAccountSlot(
                definitions: mcpAccountDefinitions, serverID: serverID, accountKey: accountKey
            )
            cancelMCPAccountOAuth(slotID: slot.id)
            await mcpOAuthCoordinator.cancel(serverID: serverID, accountKey: accountKey)
            try await mcpAccountLibrary.logout(serverID: serverID, accountKey: accountKey)
            if var config = mcpConfigs.first(where: { $0.identifier == slot.serverIdentifier }) {
                config.transport = Self.mcpTransport(config.transport, authorizationReference: nil)
                mcpConfigs = try await mcpConfigStore.upsert(config)
            }
            try await reloadMCPAccountRuntime()
        } catch { errorMessage = error.localizedDescription }
    }

    func removeMCPAccount(serverID: String, accountKey: String) async {
        await invalidateAllMCPAuthorization()
        do {
            let slot = try Self.mcpAccountSlot(
                definitions: mcpAccountDefinitions, serverID: serverID, accountKey: accountKey
            )
            cancelMCPAccountOAuth(slotID: slot.id)
            await mcpOAuthCoordinator.cancel(serverID: serverID, accountKey: accountKey)
            try await mcpAccountLibrary.removeAccount(serverID: serverID, accountKey: accountKey)
            if let config = mcpConfigs.first(where: { $0.identifier == slot.serverIdentifier }) {
                mcpConfigs = try await mcpConfigStore.remove(id: config.id)
            }
            try await reloadMCPAccountRuntime()
        } catch { errorMessage = error.localizedDescription }
    }

    func saveMCPAccountPreferences(
        serverID: String, accountKey: String,
        disabledTools: Set<String>, customInstructions: String
    ) async {
        await invalidateAllMCPAuthorization()
        do {
            _ = try await mcpAccountLibrary.setPreferences(
                serverID: serverID, accountKey: accountKey,
                enabledTools: nil, disabledTools: disabledTools,
                customInstructions: customInstructions
            )
            try await reloadMCPAccountRuntime()
        } catch { errorMessage = error.localizedDescription }
    }

    private func reloadMCPAccountRuntime() async throws {
        await invalidateAllMCPAuthorization()
        mcpAccountDefinitions = try await mcpAccountLibrary.list()
        mcpConfigs = try await mcpAccountLibrary.materializeRuntimeConfigs(existingConfigs: mcpConfigs)
        try await saveMCPConfigsWithQuota(mcpConfigs)
        try await mcpService.replaceConfigs(mcpConfigs)
        mcpCatalog = await mcpService.catalog()
        await installMCPTools()
    }

    private func saveMCPConfigsWithQuota(_ configs: [MCPServerConfig]) async throws {
        let data = try JSONEncoder().encode(configs)
        _ = try await quotaWrite(scope: "config", key: "mcp-servers", data: data) { [mcpConfigStore, configs] in
            try await mcpConfigStore.save(configs)
        }
    }

    func renameMCPServer(id: UUID, displayName: String) async {
        await invalidateAllMCPAuthorization()
        guard var config = mcpConfigs.first(where: { $0.id == id }) else { return }
        if let definition = mcpAccountDefinitions.first(where: { definition in
            definition.accounts.contains { $0.serverIdentifier == config.identifier }
        }), let slot = definition.accounts.first(where: { $0.serverIdentifier == config.identifier }) {
            await renameMCPAccount(
                serverID: definition.id, accountKey: slot.accountKey,
                newAccountKey: slot.accountKey, displayName: displayName
            )
            return
        }
        do {
            config.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            try config.validate()
            mcpConfigs = try await mcpConfigStore.upsert(config)
            await applyMCPConfigs()
        } catch { errorMessage = error.localizedDescription }
    }

    func setMCPServerEnabled(id: UUID, enabled: Bool) async {
        await invalidateAllMCPAuthorization()
        guard var config = mcpConfigs.first(where: { $0.id == id }) else { return }
        do {
            config.enabled = enabled
            mcpConfigs = try await mcpConfigStore.upsert(config)
            await applyMCPConfigs()
        } catch { errorMessage = error.localizedDescription }
    }

    func setMCPToolEnabled(serverIdentifier: String, toolName: String, enabled: Bool) async {
        await invalidateAllMCPAuthorization()
        guard var config = mcpConfigs.first(where: { $0.identifier == serverIdentifier }) else { return }
        if let definition = mcpAccountDefinitions.first(where: { definition in
            definition.accounts.contains { $0.serverIdentifier == serverIdentifier }
        }), let slot = definition.accounts.first(where: { $0.serverIdentifier == serverIdentifier }) {
            var disabled = slot.disabledTools
            if enabled { disabled.remove(toolName) } else { disabled.insert(toolName) }
            await saveMCPAccountPreferences(
                serverID: definition.id, accountKey: slot.accountKey,
                disabledTools: disabled, customInstructions: slot.customInstructions
            )
            return
        }
        do {
            if enabled {
                config.disabledTools.remove(toolName)
                config.enabledTools?.insert(toolName)
            } else {
                config.disabledTools.insert(toolName)
                config.enabledTools?.remove(toolName)
            }
            mcpConfigs = try await mcpConfigStore.upsert(config)
            await applyMCPConfigs()
        } catch { errorMessage = error.localizedDescription }
    }

    func saveMCPAuthorization(id: UUID, token: String) async {
        await invalidateAllMCPAuthorization()
        guard var config = mcpConfigs.first(where: { $0.id == id }) else { return }
        if let definition = mcpAccountDefinitions.first(where: { definition in
            definition.accounts.contains { $0.serverIdentifier == config.identifier }
        }), let slot = definition.accounts.first(where: { $0.serverIdentifier == config.identifier }) {
            await authenticateMCPAccount(
                serverID: definition.id, accountKey: slot.accountKey, bearerToken: token
            )
            return
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let reference = Self.mcpAuthorizationReference(for: id)
            try await credentials.set(trimmed, for: CredentialRef(providerID: ProviderID(rawValue: "mcp.\(reference)")))
            switch config.transport {
            case .streamableHTTP(let url, var references):
                references["Authorization"] = reference
                config.transport = .streamableHTTP(url: url, headerReferences: references)
            case .legacySSE(let url, var references):
                references["Authorization"] = reference
                config.transport = .legacySSE(url: url, headerReferences: references)
            case .stdio:
                throw MCPError.invalidConfiguration("Authorization headers apply only to HTTP MCP servers.")
            }
            mcpConfigs = try await mcpConfigStore.upsert(config)
            await applyMCPConfigs()
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteMCPServer(id: UUID) async {
        await invalidateAllMCPAuthorization()
        if let config = mcpConfigs.first(where: { $0.id == id }),
           let definition = mcpAccountDefinitions.first(where: { definition in
               definition.accounts.contains { $0.serverIdentifier == config.identifier }
           }), let slot = definition.accounts.first(where: { $0.serverIdentifier == config.identifier }) {
            await removeMCPAccount(serverID: definition.id, accountKey: slot.accountKey)
            return
        }
        do {
            mcpConfigs = try await mcpConfigStore.remove(id: id)
            try? await credentials.remove(CredentialRef(providerID: ProviderID(rawValue: "mcp.\(Self.mcpAuthorizationReference(for: id))")))
            await applyMCPConfigs()
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshMCP() async {
        await invalidateAllMCPAuthorization()
        await mcpService.refresh()
        mcpCatalog = await mcpService.catalog()
        await installMCPTools()
    }

    private func applyMCPConfigs() async {
        do {
            await invalidateAllMCPAuthorization()
            try await mcpService.replaceConfigs(mcpConfigs)
            mcpCatalog = await mcpService.catalog()
            await installMCPTools()
        } catch { errorMessage = error.localizedDescription }
    }

    private static func mcpAuthorizationReference(for id: UUID) -> String {
        "keychain:server.\(id.uuidString.lowercased()).authorization"
    }

    private static func mcpAccountAuthorizationReference(slotID: UUID) -> String {
        "keychain:account.\(slotID.uuidString.lowercased()).authorization"
    }

    private static func mcpCredentialRef(reference: String) -> CredentialRef {
        CredentialRef(providerID: ProviderID(rawValue: "mcp.\(reference)"))
    }

    private func requireCurrentMCPAttempt(
        _ attemptID: UUID,
        slot: MCPAccountSlot,
        serverID: String,
        accountKey: String
    ) throws {
        guard mcpOAuthAttemptIDs[slot.id] == attemptID,
              let current = mcpAccountDefinitions
                .first(where: { $0.id == serverID })?
                .accounts.first(where: { $0.id == slot.id }),
              current.accountKey == accountKey,
              current.serverIdentifier == slot.serverIdentifier,
              current.authStatus == .pending else {
            throw MCPOAuthError.superseded
        }
    }

    private func cancelMCPAccountOAuth(slotID: UUID) {
        mcpOAuthAttemptIDs.removeValue(forKey: slotID)
        mcpOAuthInProgressSlotIDs.remove(slotID)
        mcpOAuthListeners.removeValue(forKey: slotID)?.cancel()
    }

    private func finishMCPAccountOAuth(slotID: UUID, attemptID: UUID) {
        guard mcpOAuthAttemptIDs[slotID] == attemptID else { return }
        mcpOAuthAttemptIDs.removeValue(forKey: slotID)
        mcpOAuthInProgressSlotIDs.remove(slotID)
        mcpOAuthListeners.removeValue(forKey: slotID)?.cancel()
    }

    private static func mcpTransportIsStdio(_ transport: MCPTransportConfiguration) -> Bool {
        if case .stdio = transport { return true }
        return false
    }

    private static func mcpTransport(
        _ transport: MCPTransportConfiguration, authorizationReference: String?
    ) -> MCPTransportConfiguration {
        switch transport {
        case .streamableHTTP(let url, var references):
            references = references.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
            if let authorizationReference { references["Authorization"] = authorizationReference }
            return .streamableHTTP(url: url, headerReferences: references)
        case .legacySSE(let url, var references):
            references = references.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
            if let authorizationReference { references["Authorization"] = authorizationReference }
            return .legacySSE(url: url, headerReferences: references)
        case .stdio:
            return transport
        }
    }

    private static func mcpAccountSlot(
        definitions: [MCPServerDefinition], serverID: String, accountKey: String
    ) throws -> MCPAccountSlot {
        guard let definition = definitions.first(where: { $0.id == serverID }) else {
            throw MCPAccountLifecycleError.serverNotFound
        }
        guard let slot = definition.accounts.first(where: { $0.accountKey == accountKey }) else {
            throw MCPAccountLifecycleError.accountNotFound
        }
        return slot
    }

    private static func uniqueMCPAccountIdentifier(
        serverID: String, accountKey: String, existing: Set<String>
    ) throws -> String {
        let raw = "\(serverID)-\(accountKey)".lowercased()
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
            return allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        var base = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if base.isEmpty || base.first?.isNumber == false && base.first?.isLetter == false { base = "mcp-\(base)" }
        base = String(base.prefix(64))
        if !existing.contains(base) { return try MCPServerConfig.normalizeIdentifier(base) }
        for index in 2...9_999 {
            let suffix = "-\(index)"
            let candidate = String(base.prefix(64 - suffix.count)) + suffix
            if !existing.contains(candidate) { return try MCPServerConfig.normalizeIdentifier(candidate) }
        }
        throw MCPError.invalidConfiguration("Unable to allocate an MCP account runtime identifier.")
    }

    private func installMCPTools() async {
        let approvals = mcpApprovalBroker
        let dispatcher = mcpDispatcher
        let authorization = mcpAuthorization
        var executors: [any ToolExecutor] = mcpCatalog.tools.map { tool in
            let identity = mcpExecutionIdentity(serverIdentifier: tool.serverIdentifier)
            return AuthorizedMCPToolExecutor(
                dispatcher: dispatcher, authorization: authorization, approvals: approvals,
                tool: tool, accountIdentifier: identity.accountIdentifier,
                serverName: identity.serverName, accountName: identity.accountName,
                policy: mcpDispatchPolicy(serverIdentifier: tool.serverIdentifier)
            )
        }
        executors.append(contentsOf: LocalAppToolExecutor.all(
            runtime: localToolRuntime,
            policy: localToolPermissionPolicy,
            approvals: localToolApprovalBroker
        ))
        var reviewed: [any ToolExecutor] = executors.map { executor in
            let checked = ReviewingToolExecutor(
                wrapping: executor,
                broker: autoReviewBroker,
                instructions: { [autoReviewInstructionsStore] in
                    try autoReviewInstructionsStore.load()
                },
                action: { [weak self] call, descriptor, context in
                    guard let self else { throw CancellationError() }
                    return await self.makeAutoReviewAction(call: call, descriptor: descriptor, context: context)
                },
                onPending: { [weak self] pending in
                    await self?.registerAutoReviewApproval(pending)
                }
            )
            if WorkspaceScopedToolExecutor.scopedNames.contains(executor.descriptor.name.rawValue) {
                return WorkspaceScopedToolExecutor(wrapped: checked, store: localToolRuntime.workspaceStore, folders: workspaceFolders, policy: localToolPermissionPolicy)
            }
            return checked
        }
        reviewed.append(WorkspaceFoldersToolExecutor(store: localToolRuntime.workspaceStore, folders: workspaceFolders, policy: localToolPermissionPolicy))
        await toolCatalog.replace(with: reviewed)
    }

    func resolveMCPApproval(_ approval: MCPApprovalPresentation, resolution: MCPApprovalResolution) {
        Task {
            guard await mcpApprovalBroker.resolveIfMatches(approval, resolution: resolution) else {
                errorMessage = l10n("This MCP approval is stale or has already been handled.")
                return
            }
        }
    }

    func mcpPermissionMode(serverIdentifier: String) -> MCPPermissionMode {
        mcpPermissionModes[serverIdentifier] ?? .ask
    }

    func setMCPPermissionMode(_ mode: MCPPermissionMode, serverIdentifier: String) async {
        do {
            try await mcpPolicyStore.set(mode, serverIdentifier: serverIdentifier)
            mcpPermissionModes[serverIdentifier] = mode
            await invalidateAllMCPAuthorization()
            await installMCPTools()
        } catch { errorMessage = error.localizedDescription }
    }

    private func mcpDispatchPolicy(serverIdentifier: String) -> MCPDispatchPolicy {
        .init(userMode: mcpPermissionMode(serverIdentifier: serverIdentifier),
              managedCeiling: mcpManagedCeiling(serverIdentifier: serverIdentifier),
              permitsAutomaticLocalReads: true)
    }

    private func mcpManagedCeiling(serverIdentifier: String) -> MCPPermissionMode {
        if let values = UserDefaults.standard.dictionary(forKey: "FiliconManagedMCPPermissionCeilings"),
           let raw = values[serverIdentifier] as? Int, let value = MCPPermissionMode(rawValue: raw) { return value }
        let managed = mcpAccountDefinitions.contains { definition in
            definition.managedReadOnly && definition.accounts.contains { $0.serverIdentifier == serverIdentifier }
        }
        return managed ? .ask : .always
    }

    private func mcpExecutionIdentity(serverIdentifier: String) -> (accountIdentifier: String, serverName: String, accountName: String) {
        for definition in mcpAccountDefinitions {
            if let account = definition.accounts.first(where: { $0.serverIdentifier == serverIdentifier }) {
                return (account.accountKey, definition.displayName, account.displayName)
            }
        }
        let display = mcpConfigs.first(where: { $0.identifier == serverIdentifier })?.displayName ?? serverIdentifier
        return ("default", display, "Default")
    }

    private func invalidateMCPAuthorization(conversationID: UUID) async {
        for target in await mcpApprovalBroker.cancel(conversationID: conversationID) {
            await mcpAuthorization.advanceGeneration(serverIdentifier: target.serverIdentifier,
                                                     accountIdentifier: target.accountIdentifier,
                                                     conversationIdentifier: target.conversationIdentifier)
        }
    }

    private func invalidateAllMCPAuthorization() async {
        for target in await mcpApprovalBroker.cancelAll() {
            await mcpAuthorization.advanceGeneration(serverIdentifier: target.serverIdentifier,
                                                     accountIdentifier: target.accountIdentifier,
                                                     conversationIdentifier: target.conversationIdentifier)
        }
    }

    private func makeAutoReviewAction(
        call: NormalizedToolCall, descriptor: ToolDescriptor, context: ToolContext
    ) async -> AutoReviewAction {
        let fence = ApprovalFence(
            accountID: settings.accountScope ?? "local",
            agentID: context.conversationID.uuidString.lowercased(),
            runID: context.runID,
            generation: autoReviewAccountGeneration
        )
        await autoReviewBroker.activate(fence)
        return AutoReviewAction(
            summary: Self.autoReviewSummary(descriptor: descriptor, arguments: call.argumentsJSON),
            target: Self.autoReviewTarget(descriptor: descriptor, arguments: call.argumentsJSON),
            risks: Self.autoReviewRisks(descriptor: descriptor, arguments: call.argumentsJSON),
            context: AutoReviewActionContext(
                fence: fence,
                conversationID: context.conversationID,
                toolCallID: call.id.rawValue,
                metadata: ["tool": descriptor.name.rawValue]
            )
        )
    }

    private func registerAutoReviewApproval(_ pending: PendingApproval) async {
        let conversationID = pending.action.context.conversationID
        if groups.contains(where: { $0.id == conversationID }) || runningAgentMessageScopes.contains(conversationID) {
            guard isAgentMessagingScopeActive(conversationID),
                  pendingAutoReviewByID[pending.id] == nil else {
                await autoReviewBroker.cancel(reviewID: pending.id, fence: pending.fence)
                return
            }
            pendingAutoReviewByID[pending.id] = pending
            pendingAutoReviewApprovals = pendingAutoReviewByID.values.sorted { $0.createdAt < $1.createdAt }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, pending.expiresAt.timeIntervalSinceNow)))
                await self?.expireAutoReviewApproval(reviewID: pending.id, fence: pending.fence)
            }
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              pendingAutoReviewByID[pending.id] == nil else {
            await autoReviewBroker.cancel(reviewID: pending.id, fence: pending.fence)
            return
        }
        pendingAutoReviewByID[pending.id] = pending
        pendingAutoReviewApprovals = pendingAutoReviewByID.values.sorted { $0.createdAt < $1.createdAt }
        let card = TranscriptCard(
            lifecycle: .waiting,
            payload: .autoReview(.init(
                reviewID: pending.id,
                title: "Approval required",
                summary: pending.action.summary,
                findings: [pending.reason, "Target: \(pending.action.target.searchableText)"]
            )),
            actions: [
                .init(id: "approve", label: "Approve", intent: .approveReview(reviewID: pending.id)),
                .init(id: "reject", label: "Reject", role: "destructive", intent: .rejectReview(reviewID: pending.id)),
            ]
        )
        let message = ChatMessage(role: .assistant, text: "", transcriptCards: [card])
        conversations[index].messages.append(message)
        conversations[index].updatedAt = card.updatedAt
        loadedMessageIDs[conversationID, default: []].insert(message.id)
        do {
            try await persistTranscriptCardConversation(conversationID)
            let delay = max(0, pending.expiresAt.timeIntervalSinceNow)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                await self?.expireAutoReviewApproval(reviewID: pending.id, fence: pending.fence)
            }
        } catch {
            pendingAutoReviewByID.removeValue(forKey: pending.id)
            pendingAutoReviewApprovals = pendingAutoReviewByID.values.sorted { $0.createdAt < $1.createdAt }
            await autoReviewBroker.cancel(reviewID: pending.id, fence: pending.fence)
            errorMessage = error.localizedDescription
        }
    }

    func resolveGroupApproval(_ pending: PendingApproval, groupID: UUID, approve: Bool) async {
        guard pending.action.context.conversationID == groupID,
              pendingAutoReviewByID[pending.id] == pending,
              isAgentMessagingScopeActive(groupID) else { return }
        do {
            try await autoReviewBroker.resolve(reviewID: pending.id, resolution: approve ? .approve : .deny, fence: pending.fence)
        } catch { errorMessage = error.localizedDescription }
        pendingAutoReviewByID.removeValue(forKey: pending.id)
        pendingAutoReviewApprovals = pendingAutoReviewByID.values.sorted { $0.createdAt < $1.createdAt }
    }

    func setAutoReviewEnabled(_ enabled: Bool) async {
        var updated = autoReviewInstructions
        updated.isEnabled = enabled
        await saveAutoReviewInstructions(updated)
    }

    func setAutoReviewRules(allow: [String], ask: [String]) async {
        var updated = autoReviewInstructions
        updated.setAllowRules(allow)
        updated.setAskRules(ask)
        await saveAutoReviewInstructions(updated)
    }

    private func saveAutoReviewInstructions(_ updated: AutoReviewInstructions) async {
        do {
            try autoReviewInstructionsStore.save(updated)
            autoReviewInstructions = updated
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelAutoReviewApprovals(nextAccountID: String) async {
        // Queued peer work is scoped to the account that approved the exchange.
        agentMessagingAccountTransition = true
        dismissAttachmentPreview()
        for lifetime in groupQuestionLifetimes.values { lifetime.close() }
        for session in routineEditSessions.values { session.lifetime.close() }
        routineEditSessions.removeAll()
        agentMemoryUILifetime.close()
        agentMemoryUILifetime = AgentMemoryChangeLifetime()
        agentMemorySuggestionUILifetime.close()
        agentMemorySuggestionUILifetime = AgentMemorySuggestionLifetime()
        for session in agentMessagingSessions.values { session.revokeProfileChanges() }
        autoReviewAccountGeneration &+= 1
        defer { agentMessagingAccountTransition = false }
        await agentExecutionScheduler.cancelAll()
        await subagentService?.cancelAll()
        for scopeID in Array(agentMessagingSessions.keys) {
            if runningAgentMessageScopes.contains(scopeID) { await stopAgentMessages(scopeID: scopeID) }
            else { await stopGroup(id: scopeID) }
        }
        let agentIDs = Set(pendingAutoReviewByID.values.map(\.fence.agentID))
        for agentID in agentIDs { await autoReviewBroker.cancelAll(agentID: agentID) }
        pendingAutoReviewByID.removeAll()
        pendingAutoReviewApprovals = []
        await autoReviewBroker.transitionAccount(to: nextAccountID)
    }

    private func cancelAutoReviewApprovals(
        conversationID: UUID, lifecycle: TranscriptCardLifecycle
    ) async {
        let requests = pendingAutoReviewByID.values.filter {
            $0.action.context.conversationID == conversationID
        }
        await autoReviewBroker.cancelAll(agentID: conversationID.uuidString.lowercased())
        for request in requests {
            pendingAutoReviewByID.removeValue(forKey: request.id)
            setAutoReviewCardLifecycle(reviewID: request.id, conversationID: conversationID, lifecycle: lifecycle)
        }
        pendingAutoReviewApprovals = pendingAutoReviewByID.values.sorted { $0.createdAt < $1.createdAt }
        if conversations.contains(where: { $0.id == conversationID }) {
            try? await persistTranscriptCardConversation(conversationID)
        }
    }

    private func expireAutoReviewApproval(reviewID: String, fence: ApprovalFence) async {
        guard let pending = pendingAutoReviewByID[reviewID], pending.fence == fence,
              pending.expiresAt <= Date() else { return }
        await autoReviewBroker.expire()
        pendingAutoReviewByID.removeValue(forKey: reviewID)
        pendingAutoReviewApprovals = pendingAutoReviewByID.values.sorted { $0.createdAt < $1.createdAt }
        let conversationID = pending.action.context.conversationID
        setAutoReviewCardLifecycle(reviewID: reviewID, conversationID: conversationID, lifecycle: .failed)
        if conversations.contains(where: { $0.id == conversationID }) {
            try? await persistTranscriptCardConversation(conversationID)
        }
    }

    private func setAutoReviewCardLifecycle(
        reviewID: String, conversationID: UUID, lifecycle: TranscriptCardLifecycle
    ) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        for messageIndex in conversations[conversationIndex].messages.indices {
            guard let cardIndex = conversations[conversationIndex].messages[messageIndex].transcriptCards.firstIndex(where: {
                guard case .autoReview(let value) = $0.payload else { return false }
                return value.reviewID == reviewID
            }) else { continue }
            conversations[conversationIndex].messages[messageIndex].transcriptCards[cardIndex].lifecycle = lifecycle
            conversations[conversationIndex].messages[messageIndex].transcriptCards[cardIndex].updatedAt = .now
            conversations[conversationIndex].updatedAt = .now
            return
        }
    }

    private static func autoReviewSummary(descriptor: ToolDescriptor, arguments: Data) -> String {
        let text = String(data: arguments, encoding: .utf8) ?? "{}"
        return "Run \(descriptor.name.rawValue) with \(String(text.prefix(1_500)))"
    }

    private static func autoReviewTarget(descriptor: ToolDescriptor, arguments: Data) -> AutoReviewTarget {
        let values = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        for key in ["path", "file", "workingDirectory"] {
            if let value = values[key] as? String { return .file(path: value) }
        }
        for key in ["command", "executable"] {
            if let value = values[key] as? String { return .command(executable: value) }
        }
        for key in ["url", "endpoint", "host"] {
            if let value = values[key] as? String {
                return .network(host: URL(string: value)?.host ?? value)
            }
        }
        if descriptor.name.rawValue.hasPrefix("mcp__") {
            let server = descriptor.name.rawValue.split(separator: "__").dropFirst().first.map(String.init) ?? "mcp"
            return .network(host: server)
        }
        return .resource(kind: "tool", identifier: descriptor.name.rawValue)
    }

    private static func autoReviewRisks(descriptor: ToolDescriptor, arguments: Data) -> Set<AutoReviewRisk> {
        let name = descriptor.name.rawValue.lowercased()
        if ["local__read_file", "local__list_directory", "local__read_process"].contains(name) {
            return [.readOnly]
        }
        if name.hasPrefix("mcp__") { return [.externalSideEffect, .sensitive] }
        if name == "local__write_file" { return [.externalSideEffect, .destructive] }
        if ["local__run_process", "local__send_input", "local__terminate_process"].contains(name) {
            return [.externalSideEffect, .sensitive]
        }
        let json = String(data: arguments, encoding: .utf8)?.lowercased() ?? ""
        if ["password", "secret", "token", "authorization", "api_key", "delete", "remove", "destroy"].contains(where: json.contains) {
            return [.externalSideEffect, .sensitive]
        }
        return [.externalSideEffect, .sensitive]
    }

    func reloadLocalToolSettings() async {
        localToolPermissions = await localToolPermissionPolicy.configuredChoices()
        workspaceAuthorizations = await localToolRuntime.workspaceStore.authorizations()
    }

    func setLocalToolPermission(_ permission: LocalToolPermission, for action: LocalToolAction) async {
        do {
            try await localToolPermissionPolicy.setChoice(permission, for: action)
            localToolPermissions = await localToolPermissionPolicy.configuredChoices()
        } catch { errorMessage = error.localizedDescription }
    }

    func authorizeWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.title = l10n("Authorize a workspace folder")
        panel.message = l10n("Local AI tools will be restricted to this exact folder.")
        panel.prompt = l10n("Authorize Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await localToolRuntime.workspaceStore.authorize(url)
                workspaceAuthorizations = await localToolRuntime.workspaceStore.authorizations()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeWorkspaceAuthorization(id: UUID) async {
        do {
            try await localToolRuntime.workspaceStore.remove(id: id)
            workspaceAuthorizations = await localToolRuntime.workspaceStore.authorizations()
        } catch { errorMessage = error.localizedDescription }
    }

    func resolveLocalToolApproval(id: UUID, allowed: Bool) {
        Task { await localToolApprovalBroker.resolve(id: id, allowed: allowed) }
    }

    func persistLocalToolApproval(_ request: ToolApprovalRequest, permission: LocalToolPermission) {
        Task {
            let constrained = permission.constrained(by: settings.localToolPermissionCeiling)
            guard constrained == permission,
                  permission == .always || permission == .never else {
                errorMessage = l10n("Managed policy does not permit that persistent local-tool choice.")
                return
            }
            let previous = await localToolPermissionPolicy.configuredChoices()[request.action] ?? .ask
            guard await localToolApprovalBroker.claimIfMatches(
                id: request.id,
                conversationID: request.conversationID,
                action: request.action,
                title: request.title
            ) else { return }
            do {
                try await localToolPermissionPolicy.setChoice(permission, for: request.action)
                guard await localToolApprovalBroker.completeClaim(
                    id: request.id,
                    allowed: permission == .always
                ) else {
                    try? await localToolPermissionPolicy.setChoice(previous, for: request.action)
                    return
                }
                localToolPermissions = await localToolPermissionPolicy.configuredChoices()
            } catch {
                await localToolApprovalBroker.abandonClaim(id: request.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    func canPersistAlwaysLocalToolApproval() -> Bool {
        LocalToolPermission.always.constrained(by: settings.localToolPermissionCeiling) == .always
    }

    func saveAPIKey(_ key: String, providerID: ProviderID) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await credentials.set(trimmed, for: CredentialRef(providerID: providerID))
    }

    func setTheme(_ theme: ThemePreference) async {
        await updateSettings { $0.theme = theme }
    }

    func setTimeZone(_ identifier: String?) async {
        await updateSettings { try $0.setTimeZoneIdentifier(identifier) }
    }

    func setDefaultModel(providerID: ProviderID, modelID: ModelID) async {
        await updateSettings {
            $0.defaultModel = ProviderModelDefault(providerID: providerID.rawValue, modelID: modelID.rawValue)
        }
    }

    func clearDefaultModel() async {
        await updateSettings { $0.defaultModel = nil }
    }

    func setUnavailableModelFallback(_ policy: UnavailableModelFallbackPolicy) async {
        await updateSettings { $0.unavailableModelFallback = policy }
    }

    func setGlobalLocalToolPermission(_ permission: LocalToolPermission) async {
        let constrained = permission.constrained(by: settings.localToolPermissionCeiling)
        await updateSettings { $0.localToolPermission = constrained }
        do {
            for action in LocalToolAction.allCases {
                try await localToolPermissionPolicy.setChoice(constrained, for: action)
            }
            localToolPermissions = await localToolPermissionPolicy.configuredChoices()
        } catch { errorMessage = error.localizedDescription }
    }

    func setUpdateTrack(_ track: UpdateTrack) async {
        await updateSettings { $0.updatePolicy.userOverride = $0.updatePolicy.coerce(track) }
        await refreshUpdateSchedule()
    }

    func setInstallUpdatesWhenIdle(_ enabled: Bool) async {
        await updateSettings { $0.updatePolicy.installWhenIdle = enabled }
        await refreshUpdateSchedule()
        if enabled { await attemptIdleUpdateInstallIfSafe() }
    }

    func resetUsage() async {
        await updateSettings { $0.resetAllUsage() }
    }

    func connectVNC(endpoint: String, sessionToken: String) async {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), let host = components.host else {
            errorMessage = l10n("Enter a valid VNC URL and session token.")
            return
        }
        if components.path.isEmpty || components.path == "/" { components.path = "/vnc.html" }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == VNCTrustPolicy.sessionTokenQueryName }
        items.append(URLQueryItem(name: VNCTrustPolicy.sessionTokenQueryName, value: token))
        components.queryItems = items
        guard let url = components.url else { errorMessage = l10n("The VNC URL is invalid."); return }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        let port = components.port.map { ":\($0)" } ?? ""
        let origins: Set<String> = !loopback && scheme == "https" ? ["https://\(host.lowercased())\(port)"] : []
        let policy = VNCTrustPolicy(trustedHTTPSOrigins: origins, sessionToken: token)
        guard case .allowed = policy.evaluate(url) else {
            errorMessage = l10n("VNC allows only loopback HTTP or the exact HTTPS origin you entered, with a matching session token.")
            return
        }
        activeVNCURL = url
        activeVNCToken = token
        // Freeze the authority identity with the connection. Roster or account
        // changes must not silently retarget an already trusted web session.
        activeVNCAccountID = vncAccountID
        activeVNCComputerID = vncComputerID
        vncControlSnapshot = await vncTakeoverController.snapshot()
        await computerController.ingest(.running(vncURL: url))
    }

    func disconnectVNC() async {
        await giveBackVNCControl()
        activeVNCURL = nil
        activeVNCToken = nil
        activeVNCAccountID = nil
        activeVNCComputerID = nil
        await computerController.ingest(.running(vncURL: nil))
    }

    var vncAccountID: String { accountState.session?.profile.id ?? settings.accountScope ?? "local" }
    var vncComputerID: String { selectedComputerAgentID }

    func takeVNCControl() async {
        let deadline = Self.nowMilliseconds() + 25_000
        do {
            let lease = try await vncTakeoverController.requestTakeover(
                controllerID: vncControllerID,
                deadlineMilliseconds: deadline,
                requestID: UUID()
            )
            vncControlSnapshot = await vncTakeoverController.snapshot()
            armVNCLeaseHeartbeat(lease)
        } catch {
            await failClosedVNCControl(error)
        }
    }

    func giveBackVNCControl() async {
        vncLeaseHeartbeatTask?.cancel()
        vncLeaseHeartbeatTask = nil
        let snapshot = await vncTakeoverController.snapshot()
        if let lease = snapshot.lease {
            do {
                try await vncTakeoverController.cancel(
                    controllerID: lease.controllerID,
                    generation: lease.generation,
                    requestID: UUID()
                )
            } catch {
                await performVNCHandback()
            }
        } else {
            await performVNCHandback()
        }
        vncControlSnapshot = await vncTakeoverController.snapshot()
    }

    func reportVNCUserPresence(_ present: Bool) async {
        if present {
            vncLeaseHeartbeatTask?.cancel()
            vncLeaseHeartbeatTask = nil
        }
        await vncTakeoverController.reportUserPresence(present)
        vncControlSnapshot = await vncTakeoverController.snapshot()
    }

    func configureRemoteComputer(
        endpoint: String, credentialReference: String, credentialHeader: String,
        credentialScheme: String, token: String, capabilities: RemoteComputerCapabilities,
        isolationIdentity: String = "", minimumIsolationGeneration: UInt64 = 1
    ) async {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = credentialReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = credentialHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = credentialScheme.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let isolationIdentity = isolationIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard minimumIsolationGeneration > 0 else {
                throw RemoteComputerError.invalidIsolationDeclaration
            }
            let isolationPolicy = RemoteIsolationPolicy(
                requiredIdentity: isolationIdentity.isEmpty ? nil : isolationIdentity,
                requiredFilesystemRoot: "/workspace",
                minimumSessionGeneration: minimumIsolationGeneration,
                maximumResourceCaps: RemoteIsolationPolicy.conservative.maximumResourceCaps
            )
            let profile = try RemoteComputerProfile(
                endpoint: URL(string: endpoint) ?? URL(fileURLWithPath: ""),
                credentialReference: reference.isEmpty ? nil : reference,
                capabilities: capabilities,
                isolationPolicy: isolationPolicy
            )
            guard header.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil,
                  !scheme.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue.map({ $0 < 0x20 || $0 == 0x7f }) == true }) else {
                throw RemoteComputerError.credentialUnavailable
            }
            if !token.isEmpty {
                guard !reference.isEmpty else { throw RemoteComputerError.credentialUnavailable }
                try await credentials.set(token, for: Self.remoteComputerCredentialReference(reference))
            }
            remoteComputerEndpoint = profile.endpoint.absoluteString
            remoteComputerCredentialReference = reference
            remoteComputerCredentialHeader = header
            remoteComputerCredentialScheme = scheme
            remoteComputerCapabilities = capabilities
            remoteIsolationRequiredIdentity = isolationIdentity
            remoteIsolationMinimumGeneration = minimumIsolationGeneration
            remoteSecuritySnapshot = .init(state: .unverified)
            let defaults = UserDefaults.standard
            defaults.set(remoteComputerEndpoint, forKey: "FiliconRemoteComputerEndpoint")
            defaults.set(reference, forKey: "FiliconRemoteComputerCredentialReference")
            defaults.set(header, forKey: "FiliconRemoteComputerCredentialHeader")
            defaults.set(scheme, forKey: "FiliconRemoteComputerCredentialScheme")
            defaults.set(Int(capabilities.rawValue), forKey: "FiliconRemoteComputerCapabilities")
            if isolationIdentity.isEmpty { defaults.removeObject(forKey: "FiliconRemoteIsolationIdentity") }
            else { defaults.set(isolationIdentity, forKey: "FiliconRemoteIsolationIdentity") }
            defaults.set(NSNumber(value: remoteIsolationMinimumGeneration), forKey: "FiliconRemoteIsolationGeneration")
            rebuildRemoteComputerClient()
            rebuildSecurityKeyProxy()
            await refreshRemoteComputer()
        } catch { errorMessage = error.localizedDescription }
    }

    func clearRemoteComputer(removeCredential: Bool) async {
        remoteOperationTask?.cancel(); remoteOperationTask = nil
        remoteTerminalPollingTask?.cancel(); remoteTerminalPollingTask = nil
        if removeCredential, !remoteComputerCredentialReference.isEmpty {
            try? await credentials.remove(Self.remoteComputerCredentialReference(remoteComputerCredentialReference))
        }
        remoteComputerEndpoint = ""; remoteComputerStatus = nil; remoteComputerOperation = nil
        remoteIsolationRequiredIdentity = ""; remoteIsolationMinimumGeneration = 1
        remoteSecuritySnapshot = .init(state: .unverified)
        remoteComputerBackend = nil; remoteComputerLifecycle = nil; remoteTerminalController = nil; remoteFileTransfer = nil
        rebuildSecurityKeyProxy()
        UserDefaults.standard.removeObject(forKey: "FiliconRemoteComputerEndpoint")
        UserDefaults.standard.removeObject(forKey: "FiliconRemoteIsolationIdentity")
        UserDefaults.standard.removeObject(forKey: "FiliconRemoteIsolationGeneration")
    }

    var securityKeySupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    func setSecurityKeyEnabled(_ enabled: Bool) async {
        guard !enabled || securityKeySupported else {
            securityKeyEnabled = false
            securityKeyStatus = .failed(SecurityKeyError.unsupported.localizedDescription)
            return
        }
        securityKeyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "FiliconSecurityKeyEnabled")
        rebuildSecurityKeyProxy()
    }

    func refreshRemoteComputer() async {
        guard let lifecycle = remoteComputerLifecycle else { return }
        do { await applyRemoteComputerStatus(try await lifecycle.status(agentID: selectedComputerAgentID)) }
        catch { await refreshRemoteSecuritySnapshot(); errorMessage = error.localizedDescription }
    }

    func ensureRemoteComputer() async {
        guard let lifecycle = remoteComputerLifecycle else { return }
        do { await applyRemoteComputerStatus(try await lifecycle.ensure(agentID: selectedComputerAgentID)) }
        catch { await refreshRemoteSecuritySnapshot(); errorMessage = error.localizedDescription }
    }

    func resetRemoteIsolationTrust() async {
        remoteIsolationRequiredIdentity = ""
        remoteIsolationMinimumGeneration = 1
        remoteSecuritySnapshot = .init(state: .unverified)
        UserDefaults.standard.removeObject(forKey: "FiliconRemoteIsolationIdentity")
        UserDefaults.standard.removeObject(forKey: "FiliconRemoteIsolationGeneration")
        rebuildRemoteComputerClient()
        rebuildSecurityKeyProxy()
    }

    func refreshRemoteSecuritySnapshot() async {
        guard let remoteComputerBackend else {
            remoteSecuritySnapshot = .init(state: .unverified)
            return
        }
        let snapshot = await remoteComputerBackend.securitySnapshot(agentID: selectedComputerAgentID)
        remoteSecuritySnapshot = snapshot
        guard snapshot.state == .trusted, let declaration = snapshot.declaration else { return }
        if remoteIsolationRequiredIdentity.isEmpty {
            remoteIsolationRequiredIdentity = declaration.identity
            UserDefaults.standard.set(declaration.identity, forKey: "FiliconRemoteIsolationIdentity")
        }
        if declaration.sessionGeneration > remoteIsolationMinimumGeneration {
            remoteIsolationMinimumGeneration = declaration.sessionGeneration
            UserDefaults.standard.set(NSNumber(value: declaration.sessionGeneration), forKey: "FiliconRemoteIsolationGeneration")
        }
    }

    func recreateRemoteComputer(preserveData: Bool, force: Bool) async {
        guard let lifecycle = remoteComputerLifecycle else { return }
        do {
            let operation = try await lifecycle.recreate(agentID: selectedComputerAgentID, preserveData: preserveData, force: force)
            remoteComputerOperation = operation
            guard operation.state == .queued || operation.state == .running else { await refreshRemoteComputer(); return }
            remoteOperationTask?.cancel()
            remoteOperationTask = Task { [weak self, lifecycle] in
                guard let self else { return }
                do {
                    let settled = try await lifecycle.poll(agentID: self.selectedComputerAgentID, operationID: operation.id)
                    guard !Task.isCancelled else { return }
                    self.remoteComputerOperation = settled
                    await self.refreshRemoteComputer()
                } catch is CancellationError { return }
                catch { self.errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelRemoteComputerOperation() async {
        remoteOperationTask?.cancel(); remoteOperationTask = nil
        do { try await remoteComputerLifecycle?.cancel(agentID: selectedComputerAgentID) }
        catch { errorMessage = error.localizedDescription }
        await refreshRemoteComputer()
    }

    func connectRemoteComputerVNC() async {
        guard let url = remoteComputerStatus?.vncURL,
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == VNCTrustPolicy.sessionTokenQueryName })?.value,
              !token.isEmpty else {
            errorMessage = l10n("The remote computer did not provide a VNC session token.")
            return
        }
        await connectVNC(endpoint: url.absoluteString, sessionToken: token)
    }

    func startRemoteTerminal(commandJSON: String) async {
        guard let controller = remoteTerminalController,
              let data = commandJSON.data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String], !command.isEmpty else {
            errorMessage = l10n("Enter the terminal command as a JSON argv array, for example [\"/usr/bin/env\",\"pwd\"].")
            return
        }
        remoteTerminalPollingTask?.cancel()
        do {
            let session = try await controller.start(
                agentID: selectedComputerAgentID, ownerID: remoteTerminalOwnerID,
                request: .init(command: command)
            )
            remoteTerminalSessionID = session.id; remoteTerminalOutput = ""; remoteTerminalExitCode = nil
            remoteTerminalPollingTask = Task { [weak self, controller] in
                guard let self else { return }
                while !Task.isCancelled, self.remoteTerminalSessionID == session.id {
                    do {
                        let chunk = try await controller.output(
                            agentID: self.selectedComputerAgentID, sessionID: session.id,
                            ownerID: self.remoteTerminalOwnerID, limit: 256 * 1024
                        )
                        guard !Task.isCancelled else { return }
                        if let value = String(data: chunk.data, encoding: .utf8), !value.isEmpty {
                            self.remoteTerminalOutput = String((self.remoteTerminalOutput + value).suffix(2 * 1024 * 1024))
                        }
                        if let code = chunk.exitCode {
                            self.remoteTerminalExitCode = code; self.remoteTerminalSessionID = nil; return
                        }
                        try await Task.sleep(for: .milliseconds(500))
                    } catch is CancellationError { return }
                    catch { self.errorMessage = error.localizedDescription; self.remoteTerminalSessionID = nil; return }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func sendRemoteTerminalInput(_ text: String) async {
        guard let sessionID = remoteTerminalSessionID, let controller = remoteTerminalController else { return }
        do { try await controller.input(agentID: selectedComputerAgentID, sessionID: sessionID, ownerID: remoteTerminalOwnerID, text: text) }
        catch { errorMessage = error.localizedDescription }
    }

    func cancelRemoteTerminal() async {
        remoteTerminalPollingTask?.cancel(); remoteTerminalPollingTask = nil
        guard let sessionID = remoteTerminalSessionID, let controller = remoteTerminalController else { return }
        do { try await controller.cancel(agentID: selectedComputerAgentID, sessionID: sessionID, ownerID: remoteTerminalOwnerID) }
        catch { errorMessage = error.localizedDescription; return }
        remoteTerminalSessionID = nil
    }

    func uploadRemoteFile(localURL: URL, remotePath: String) async {
        guard let transfer = remoteFileTransfer else { return }
        do {
            let values = try localURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= RemoteFileTransfer.defaultMaximumBytes else {
                throw RemoteComputerError.requestTooLarge(limit: RemoteFileTransfer.defaultMaximumBytes)
            }
            let descriptor = try await transfer.upload(
                agentID: selectedComputerAgentID, path: remotePath,
                data: Data(contentsOf: localURL, options: [.mappedIfSafe])
            )
            remoteFileTransferStatus = "Uploaded \(descriptor.size) bytes · \(descriptor.sha256.prefix(12))…"
        } catch { errorMessage = error.localizedDescription }
    }

    func downloadRemoteFile(remotePath: String, localURL: URL) async {
        guard let transfer = remoteFileTransfer else { return }
        do {
            let data = try await transfer.download(agentID: selectedComputerAgentID, path: remotePath)
            try data.write(to: localURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            remoteFileTransferStatus = "Downloaded \(data.count) bytes."
        } catch { errorMessage = error.localizedDescription }
    }

    func noteVNCRendererCrash() async {
        await computerController.noteRendererCrash()
    }

    func recoverVNCRenderer() async {
        await computerController.viewerBecameVisible()
    }

    func startTeachRecording() async {
        teachMaskingRefreshTask?.cancel()
        teachMaskingRefreshTask = nil
        do {
            let masking = try await teachMaskingController.refresh()
            await teachController.reportMaskingStatus(masking)
            _ = try await teachController.start(
                agentID: selectedComputerAgentID,
                entryPoint: "computer-workspace",
                monitor: .privateFork(index: 1),
                maskingPolicy: masking.policy
            )
            armTeachMaskingRefresh()
        } catch {
            teachMaskingRefreshTask?.cancel()
            teachMaskingRefreshTask = nil
            let masking = await teachMaskingController.currentStatus()
            await teachController.reportMaskingStatus(masking)
            errorMessage = error.localizedDescription
        }
    }

    func stopTeachRecording(save: Bool) async {
        teachMaskingRefreshTask?.cancel()
        teachMaskingRefreshTask = nil
        let agentID = selectedComputerAgentID
        do {
            let result = try await teachController.stop(agentID: agentID, save: save)
            if save, let videoURL = result.savedVideoURL {
                try await dispatchTeachLearningTurn(agentID: agentID, videoURL: videoURL)
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func dispatchTeachLearningTurn(agentID: String, videoURL: URL) async throws {
        guard let workflowService, let agentService,
              let profileID = UUID(uuidString: agentID),
              let profile = await agentService.profile(id: profileID),
              profile.archivedAt == nil else {
            throw AgentWorkflowError.malformed("Teach agent is unavailable")
        }
        _ = try await workflowService.ensureLearningWorkflow(agentID: profileID)
        await reloadWorkflows()

        let conversation = Conversation(
            title: "Learn from demonstration · \(profile.name)",
            providerID: profile.providerID,
            modelID: profile.modelID,
            messages: profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [.init(role: .system, text: profile.instructions)]
        )
        conversations.insert(conversation, at: 0)
        deletedConversationIDs.remove(conversation.id)
        loadedMessageIDs[conversation.id] = Set(conversation.messages.map(\.id))
        completeMessageHistories.insert(conversation.id)
        messageContinuations[conversation.id] = nil
        selection = conversation.id
        setRoute(.conversation(conversation.id), recordingHistory: true)

        let staged = try await stageAttachment(fileURL: videoURL, declaredMIMEType: "video/mp4")
        stagedAttachments[staged.metadata.id] = staged
        pendingAttachments = [staged.metadata]
        isRestoringDraft = true
        draft = "The recording is finished. Learn the task from it. \(WorkflowComposerReferences.learningReference(agentID: agentID))"
        isRestoringDraft = false
        draftCache[conversation.id] = draft
        send()
    }

    /// Ends capabilities that must not survive the Computer workspace/app.
    func shutdownComputerIntegration() async {
        await giveBackVNCControl()
        if teachStatus.phase == .recording || teachStatus.phase == .starting {
            await stopTeachRecording(save: false)
        } else {
            teachMaskingRefreshTask?.cancel()
            teachMaskingRefreshTask = nil
        }
    }

    func attachTeachRecording() async {
        guard let url = teachStatus.savedVideoURL else { return }
        do {
            let staged = try await stageAttachment(fileURL: url, declaredMIMEType: "video/mp4")
            let metadata = staged.metadata
            if !pendingAttachments.contains(where: { $0.id == metadata.id }) {
                stagedAttachments[metadata.id] = staged
                pendingAttachments.append(metadata)
            } else { try? await attachmentLifecycle?.abort(staged) }
            if let selection { selectRoute(.conversation(selection)) }
        } catch { errorMessage = error.localizedDescription }
    }

    func configurePluginCatalog(_ rawURL: String) async {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            pluginCatalogURLString = ""
            pluginCatalogCache = nil
            pluginCatalogEntries = []
            UserDefaults.standard.removeObject(forKey: "FiliconPluginCatalogURL")
            return
        }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else {
            errorMessage = l10n("Plugin catalogs must use an HTTPS URL.")
            return
        }
        pluginCatalogURLString = value
        UserDefaults.standard.set(value, forKey: "FiliconPluginCatalogURL")
        pluginCatalogCache = PluginCatalogCache(client: URLPluginCatalogClient(url: url))
        await reloadPlugins(forceCatalogRefresh: true)
    }

    func reloadPlugins(forceCatalogRefresh: Bool) async {
        isRefreshingPlugins = true
        defer { isRefreshingPlugins = false }
        do {
            installedPlugins = try await pluginStore.list()
            indexedPluginSkills = try await pluginSkillIndex.sync().skills
            privateSkills = try await privateSkillLibrary.list()
            if let pluginCatalogCache {
                pluginCatalogEntries = try await pluginCatalogCache.snapshot(forceRefresh: forceCatalogRefresh).entries
            } else {
                pluginCatalogEntries = []
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func importPlugin(from url: URL, setupValues: [String: String] = [:]) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let source: PluginInstallSource
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            source = values.isDirectory == true ? .directory(url) : .archive(url)
            let manifest = try await pluginInstaller.inspect(source)
            let entry = PluginCatalogEntry(manifest: manifest, ownership: .user, policy: .allowed)
            _ = try await pluginInstaller.install(entry: entry, from: source, setupValues: setupValues)
            await reloadPlugins(forceCatalogRefresh: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func installPlugin(_ entry: PluginCatalogEntry, setupValues: [String: String]) async {
        guard let url = entry.downloadURL else { errorMessage = l10n("This catalog entry has no downloadable artifact."); return }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https" else { throw PluginError.malformedCatalog }
            let size = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size <= pluginArchiveMaximumBytes else { throw PluginError.archiveTooLarge }
            let named = temporary.deletingLastPathComponent().appending(path: url.lastPathComponent)
            try? FileManager.default.removeItem(at: named)
            try FileManager.default.moveItem(at: temporary, to: named)
            defer { try? FileManager.default.removeItem(at: named) }
            _ = try await pluginInstaller.install(entry: entry, from: .archive(named), setupValues: setupValues)
            await reloadPlugins(forceCatalogRefresh: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func uninstallPlugin(id: String) async {
        do {
            _ = try await pluginInstaller.uninstall(pluginID: id)
            await reloadPlugins(forceCatalogRefresh: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func setPluginToolDisabled(pluginID: String, toolName: String, disabled: Bool) async {
        do {
            _ = try await pluginStore.setToolDisabled(pluginID: pluginID, toolName: toolName, disabled: disabled)
            installedPlugins = try await pluginStore.list()
        } catch { errorMessage = error.localizedDescription }
    }

    func privateSkillDocument(id: String) async -> PrivateSkillDocument? {
        do { return try await privateSkillLibrary.read(id: id) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func savePrivateSkill(id: String, name: String, description: String, body: String, replacing: Bool) async -> Bool {
        do {
            let payload = try JSONEncoder().encode(["id": id, "name": name, "description": description, "body": body])
            _ = try await quotaWrite(scope: "skill", key: id, data: payload) { [privateSkillLibrary, id, name, description, body] in
                if replacing { return try await privateSkillLibrary.update(id: id, name: name, description: description, body: body) }
                return try await privateSkillLibrary.create(id: id, name: name, description: description, body: body)
            }
            privateSkills = try await privateSkillLibrary.list()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func removePrivateSkill(id: String) async {
        do {
            if try await skillPublicationStore.state(skillID: id)?.pluginID != nil {
                throw PluginError.invalidManifest("unpublish this team-managed skill before deleting its local source")
            }
            try await privateSkillLibrary.remove(id: id); privateSkills = try await privateSkillLibrary.list()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func importPrivateSkill(from url: URL, id: String) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let source: PrivateSkillImportSource = values.isDirectory == true ? .directory(url) : .archive(url)
            _ = try await privateSkillLibrary.importSkill(id: id, from: source)
            privateSkills = try await privateSkillLibrary.list()
        } catch { errorMessage = error.localizedDescription }
    }

    func exportPrivateSkill(id: String, to parent: URL) async {
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        do { _ = try await privateSkillLibrary.exportSkill(id: id, to: parent) }
        catch { errorMessage = error.localizedDescription }
    }

    func configureSkillPublishing(endpoint rawEndpoint: String, bearerToken rawToken: String) async -> Bool {
        let endpoint = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.isEmpty {
            skillPublishingEndpoint = ""
            UserDefaults.standard.removeObject(forKey: "FiliconSkillPublishingEndpoint")
            try? await credentials.remove(Self.skillPublishingCredentialRef)
            skillPublishService = nil
            skillPublishTargets = []
            return true
        }
        guard let url = URL(string: endpoint), !token.isEmpty else {
            errorMessage = l10n("Publishing requires an HTTPS endpoint and bearer token.")
            return false
        }
        do {
            let backend = try HTTPSSkillPublishingBackend(endpoint: url, bearerToken: token)
            try await credentials.set(token, for: Self.skillPublishingCredentialRef)
            skillPublishingEndpoint = endpoint
            UserDefaults.standard.set(endpoint, forKey: "FiliconSkillPublishingEndpoint")
            skillPublishService = SkillPublishService(backend: backend, index: pluginSkillIndex, library: privateSkillLibrary, publicationStore: skillPublicationStore)
            await refreshSkillPublishing()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshSkillPublishing() async {
        isRefreshingSkillPublishing = true
        defer { isRefreshingSkillPublishing = false }
        do {
            skillPublicationStates = try await skillPublicationStore.list()
            guard let service = skillPublishService else { skillPublishTargets = []; return }
            skillPublishTargets = try await service.listTargets()
        } catch { errorMessage = error.localizedDescription }
    }

    func publishPrivateSkill(id: String, targetID: String) async {
        guard let service = skillPublishService else { errorMessage = l10n("Configure a publishing backend before changing a team marketplace."); return }
        do {
            let document = try await privateSkillLibrary.read(id: id)
            _ = try await service.publish(localSkillID: id, name: document.record.name, description: document.record.description, targetID: targetID)
            privateSkills = try await privateSkillLibrary.list()
            skillPublicationStates = try await skillPublicationStore.list()
        } catch { errorMessage = error.localizedDescription; skillPublicationStates = (try? await skillPublicationStore.list()) ?? [] }
    }

    func resyncPrivateSkill(id: String) async {
        guard let service = skillPublishService else { errorMessage = l10n("Configure a publishing backend before changing a team marketplace."); return }
        do {
            let document = try await privateSkillLibrary.read(id: id)
            _ = try await service.resyncPublication(localSkillID: id, name: document.record.name, description: document.record.description)
            skillPublicationStates = try await skillPublicationStore.list()
        } catch { errorMessage = error.localizedDescription; skillPublicationStates = (try? await skillPublicationStore.list()) ?? [] }
    }

    func unpublishPrivateSkill(id: String) async {
        guard let service = skillPublishService else { errorMessage = l10n("Configure a publishing backend before changing a team marketplace."); return }
        do {
            try await service.unpublishPublication(localSkillID: id)
            skillPublicationStates = try await skillPublicationStore.list()
        } catch { errorMessage = error.localizedDescription; skillPublicationStates = (try? await skillPublicationStore.list()) ?? [] }
    }

    func resyncPublishedPluginSkill(id: String) async {
        guard let service = skillPublishService else { errorMessage = l10n("Configure a publishing backend before changing a team marketplace."); return }
        do {
            _ = try await service.resync(skillID: id)
            indexedPluginSkills = try await pluginSkillIndex.snapshot()?.skills ?? []
            skillPublicationStates = try await skillPublicationStore.list()
        } catch { errorMessage = error.localizedDescription; skillPublicationStates = (try? await skillPublicationStore.list()) ?? [] }
    }

    func unpublishPublishedPluginSkill(id: String) async {
        guard let service = skillPublishService else { errorMessage = l10n("Configure a publishing backend before changing a team marketplace."); return }
        do {
            _ = try await service.unpublish(skillID: id)
            privateSkills = try await privateSkillLibrary.list()
            indexedPluginSkills = try await pluginSkillIndex.snapshot()?.skills ?? []
            skillPublicationStates = try await skillPublicationStore.list()
        } catch { errorMessage = error.localizedDescription; skillPublicationStates = (try? await skillPublicationStore.list()) ?? [] }
    }

    private func restoreSkillPublishing() async {
        skillPublicationStates = (try? await skillPublicationStore.list()) ?? []
        guard let url = URL(string: skillPublishingEndpoint),
              let token = try? await credentials.value(for: Self.skillPublishingCredentialRef),
              let backend = try? HTTPSSkillPublishingBackend(endpoint: url, bearerToken: token) else { return }
        let service = SkillPublishService(backend: backend, index: pluginSkillIndex, library: privateSkillLibrary, publicationStore: skillPublicationStore)
        skillPublishService = service
        _ = try? await service.recoverInterruptedOperations()
        await refreshSkillPublishing()
    }

    private static let skillPublishingCredentialRef = CredentialRef(providerID: ProviderID(rawValue: "skill-publishing"))

    func configureUpdates(feedURL: String, publicKeyBase64: String) async {
        let feed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        if feed.isEmpty && key.isEmpty {
            updateFeedURLString = ""; updatePublicKeyBase64 = ""
            UserDefaults.standard.removeObject(forKey: "FiliconUpdateFeedURL")
            UserDefaults.standard.removeObject(forKey: "FiliconUpdatePublicKeyBase64")
            await refreshUpdateSchedule()
            return
        }
        guard let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host != nil,
              let keyData = Data(base64Encoded: key), keyData.count == 32 else {
            errorMessage = l10n("Updates require an HTTPS feed and a 32-byte Ed25519 public key encoded as Base64.")
            return
        }
        do { _ = try makeUpdateConfiguration(feedURL: url, key: keyData) }
        catch { errorMessage = error.localizedDescription; return }
        updateFeedURLString = feed; updatePublicKeyBase64 = key
        UserDefaults.standard.set(feed, forKey: "FiliconUpdateFeedURL")
        UserDefaults.standard.set(key, forKey: "FiliconUpdatePublicKeyBase64")
        await refreshUpdateSchedule()
    }

    func checkForUpdates() async {
        await checkForUpdates(reportMissingConfiguration: true)
    }

    private func checkForUpdates(reportMissingConfiguration: Bool) async {
        guard let configuration = configuredUpdates(automaticallyDownloads: false) else {
            if reportMissingConfiguration {
                errorMessage = l10n("This build has no packaged update feed. Configure an HTTPS update feed and trusted signing key.")
            }
            return
        }
        updateState = await updateManager.check(
            configuration: configuration,
            installed: installedVersion,
            systemVersion: operatingSystemVersion,
            observer: { [weak self] value in await MainActor.run { self?.updateState = value } }
        )
    }

    func downloadAvailableUpdate() async {
        guard case .available(let release) = updateState,
              let configuration = configuredUpdates(automaticallyDownloads: false) else { return }
        updateState = await updateManager.stage(release, configuration: configuration) { [weak self] value in
            await MainActor.run { self?.updateState = value }
        }
    }

    func installStagedUpdate() async {
        guard case .staged(let staged, let directory) = updateState else { return }
        if hasUpdateBlockingWork {
            errorMessage = l10n("Filicon is busy. Stop active conversations, groups, and workflows before installing.")
            return
        }
        let application = Bundle.main.bundleURL
        guard application.pathExtension == "app", let bundleIdentifier = Bundle.main.bundleIdentifier else {
            errorMessage = l10n("Updates can be installed only from a packaged Filicon.app build.")
            return
        }
        do {
            updateState = .installing(staged)
            let plan = try await updateInstallCoordinator.prepare(
                staged: staged,
                stagingDirectory: directory,
                targetApplication: application,
                expectedBundleIdentifier: bundleIdentifier
            )
            guard !hasUpdateBlockingWork else {
                updateState = .staged(staged, directory: directory)
                errorMessage = l10n("Filicon became busy before installation. The verified update remains ready.")
                return
            }
            let helper = application.appending(path: "Contents/Helpers/FiliconUpdateHelper")
            try await updateInstallCoordinator.launchHelper(for: plan, helperURL: helper)
            NSApplication.shared.terminate(nil)
        } catch {
            updateState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func refreshUpdateSchedule() async {
        guard let configuration = configuredUpdates(automaticallyDownloads: settings.updatePolicy.installWhenIdle) else {
            await updateManager.stopPeriodicChecks(); return
        }
        await updateManager.startPeriodicChecks(
            configuration: configuration,
            installed: installedVersion,
            systemVersion: operatingSystemVersion,
            observer: { [weak self] value in await MainActor.run { self?.updateState = value } },
            afterCheck: { [weak self] in await self?.attemptIdleUpdateInstallIfSafe() }
        )
    }

    func setMinimumRequiredVersionForPolicy(_ version: String?) {
        let normalized = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        minimumRequiredVersion = normalized?.isEmpty == false ? normalized : nil
        if let minimumRequiredVersion {
            UserDefaults.standard.set(minimumRequiredVersion, forKey: "FiliconMinimumRequiredVersion")
        } else {
            UserDefaults.standard.removeObject(forKey: "FiliconMinimumRequiredVersion")
        }
    }

    /// Runtime entry point for a backend or gateway lifecycle/status response.
    /// Invalid or lower requirements are rejected by the scoped durable policy store.
    func ingestBackendUpdateRequirement(
        minimumVersion: String,
        scope: String = "gateway:production"
    ) async {
        do {
            _ = try await backendUpdateRequirementCoordinator.ingest(
                scope: scope,
                minimumVersion: minimumVersion
            )
        } catch {
            // A malformed remote policy must neither lower the gate nor disrupt backend status handling.
            errorMessage = error.localizedDescription
        }
    }

    private func applyBackendUpdateRequirement(_ minimumVersion: String) async {
        minimumRequiredVersion = minimumVersion
        await checkForUpdates(reportMissingConfiguration: false)
    }

    private func restoreBackendUpdateRequirementPolicy() async {
        guard let persisted = await backendUpdatePolicyStore.snapshot().highestMinimumVersion else { return }
        if let existing = minimumRequiredVersion,
           let existingVersion = try? ReleaseVersion(existing),
           let persistedVersion = try? ReleaseVersion(persisted),
           existingVersion >= persistedVersion {
            return
        }
        minimumRequiredVersion = persisted
    }

    private func attemptIdleUpdateInstallIfSafe() async {
        guard case .staged = updateState else { return }
        let snapshot = updateIdleMonitor.snapshot(
            hasActiveWork: hasUpdateBlockingWork
        )
        guard UpdateIdleInstallPolicy.permitsInstall(
            snapshot: snapshot,
            optedIn: settings.updatePolicy.installWhenIdle,
            updateStaged: true
        ) else { return }
        await installStagedUpdate()
    }

    private var hasUpdateBlockingWork: Bool {
        !running.isEmpty
            || !runningGroups.isEmpty
            || !runningAgentMessageScopes.isEmpty
            || workflowIsLoading
            || workflowRuns.contains(where: { $0.status == .running })
            || agentAsyncTasks.contains(where: { [.queued, .running, .awaitingInput].contains($0.status) })
            || remoteComputerOperation != nil
    }

    private func configuredUpdates(automaticallyDownloads: Bool) -> UpdateConfiguration? {
        try? UpdateConfigurationResolver.resolve(
            channel: FiliconUpdater.UpdateChannel(rawValue: settings.updatePolicy.effectiveTrack.rawValue) ?? .stable,
            automaticallyDownloads: automaticallyDownloads,
            persistedFeedURL: updateFeedURLString,
            persistedPublicKeyBase64: updatePublicKeyBase64
        )
    }

    private func makeUpdateConfiguration(feedURL: URL, key: Data, automaticallyDownloads: Bool = false) throws -> UpdateConfiguration {
        let channel = FiliconUpdater.UpdateChannel(rawValue: settings.updatePolicy.effectiveTrack.rawValue) ?? .stable
        return try UpdateConfiguration(
            channel: channel,
            feedURL: feedURL,
            automaticallyChecks: true,
            automaticallyDownloads: automaticallyDownloads,
            requiresSignature: true,
            trustedEd25519PublicKey: key
        )
    }

    private var installedVersion: InstalledVersion {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 1
        return InstalledVersion(version: version, build: build)
    }

    private var operatingSystemVersion: String {
        let value = ProcessInfo.processInfo.operatingSystemVersion
        return "\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)"
    }

    private var selectedComputerAgentID: String {
        agents.first(where: { $0.archivedAt == nil })?.id.uuidString ?? "local"
    }

    private func rebuildRemoteComputerClient() {
        remoteOperationTask?.cancel(); remoteOperationTask = nil
        remoteTerminalPollingTask?.cancel(); remoteTerminalPollingTask = nil
        guard let endpoint = URL(string: remoteComputerEndpoint),
              let profile = try? RemoteComputerProfile(
                  endpoint: endpoint,
                  credentialReference: remoteComputerCredentialReference.isEmpty ? nil : remoteComputerCredentialReference,
                  capabilities: remoteComputerCapabilities,
                  isolationPolicy: .init(
                      requiredIdentity: remoteIsolationRequiredIdentity.isEmpty ? nil : remoteIsolationRequiredIdentity,
                      requiredFilesystemRoot: "/workspace",
                      minimumSessionGeneration: max(1, remoteIsolationMinimumGeneration),
                      maximumResourceCaps: RemoteIsolationPolicy.conservative.maximumResourceCaps
                  )
              ) else {
            remoteComputerBackend = nil; remoteComputerLifecycle = nil
            remoteTerminalController = nil; remoteFileTransfer = nil
            return
        }
        let resolver = AppRemoteComputerCredentialResolver(
            credentials: credentials,
            headerName: remoteComputerCredentialHeader,
            scheme: remoteComputerCredentialScheme
        )
        let backend = HTTPSRemoteComputerBackend(profile: profile, credentials: resolver)
        remoteComputerBackend = backend
        remoteComputerLifecycle = RemoteComputerLifecycle(backend: backend)
        remoteTerminalController = RemoteTerminalController(backend: backend)
        remoteFileTransfer = RemoteFileTransfer(backend: backend)
        remoteSecuritySnapshot = .init(state: .unverified)
    }

    private func rebuildSecurityKeyProxy() {
        securityKeyProxyGeneration &+= 1
        let generation = securityKeyProxyGeneration
        let previous = securityKeyProxy
        securityKeyProxy = nil
        if let previous { Task { await previous.handback() } }
        guard securityKeyEnabled else { securityKeyStatus = .disabled; return }
        guard securityKeySupported,
              let endpoint = URL(string: remoteComputerEndpoint),
              !remoteComputerCredentialReference.isEmpty else {
            securityKeyStatus = .failed("Configure an HTTPS remote-computer endpoint and Keychain bearer credential first.")
            return
        }
        do {
            let credentials = self.credentials
            let reference = remoteComputerCredentialReference
            let backend = try HTTPSRemoteSecurityKeyBackend(baseURL: endpoint) {
                try await credentials.value(for: Self.remoteComputerCredentialReference(reference))
            }
            let coordinator = SecurityKeyCoordinator(
                enabled: true,
                provider: AuthenticationServicesHardwareSecurityKeyProvider(),
                consent: securityKeyConsentPresenter,
                status: { [weak self] value in await MainActor.run { self?.securityKeyStatus = value } }
            )
            let host = Host.current().localizedName
            let proxy = RemoteSecurityKeyProxy(
                enabled: true,
                backend: backend,
                coordinator: coordinator,
                computerID: host,
                label: "Filicon on \(host ?? "Mac")",
                status: { [weak self] value in await MainActor.run { self?.securityKeyStatus = value } }
            )
            securityKeyProxy = proxy
            securityKeyStatus = .disconnected
            Task { [weak self] in
                guard let self, self.securityKeyProxyGeneration == generation else { return }
                await proxy.start()
            }
        } catch {
            securityKeyStatus = .failed(error.localizedDescription)
        }
    }

    func applyRemoteComputerStatus(_ status: RemoteComputerStatus) async {
        if let minimumAppVersion = status.minimumAppVersion {
            await ingestBackendUpdateRequirement(
                minimumVersion: minimumAppVersion,
                scope: "remote-computer:lifecycle"
            )
        }
        remoteComputerStatus = status
        await refreshRemoteSecuritySnapshot()
        switch status.state {
        case .off:
            await computerController.ingest(.off)
        case .hibernated:
            await computerController.ingest(.hibernated)
        case .pulling:
            await computerController.ingest(.pulling(percent: status.pullPercent))
        case .running:
            await computerController.ingest(.running(vncURL: status.vncURL))
        case .failed:
            await computerController.ingest(.off)
        }
    }

    private static func remoteComputerCredentialReference(_ account: String) -> CredentialRef {
        CredentialRef(providerID: ProviderID(rawValue: "remote-computer"), account: account)
    }

    private func observeComputerServices() {
        guard computerStatusTask == nil, teachStatusTask == nil else { return }
        computerStatusTask = Task { [weak self, computerController] in
            let values = await computerController.statuses()
            for await value in values {
                guard !Task.isCancelled else { return }
                self?.computerSnapshot = value
            }
        }
        teachStatusTask = Task { [weak self, teachController] in
            let values = await teachController.statuses()
            for await value in values {
                guard !Task.isCancelled else { return }
                self?.teachStatus = value
                if value.phase != .recording && value.phase != .starting {
                    self?.teachMaskingRefreshTask?.cancel()
                    self?.teachMaskingRefreshTask = nil
                }
            }
        }
    }

    private func armVNCLeaseHeartbeat(_ initialLease: VNCTakeoverLease) {
        vncLeaseHeartbeatTask?.cancel()
        vncLeaseHeartbeatTask = Task { [weak self] in
            guard let self else { return }
            var lease = initialLease
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                    try Task.checkCancellation()
                    lease = try await self.vncTakeoverController.heartbeat(
                        controllerID: lease.controllerID,
                        generation: lease.generation,
                        deadlineMilliseconds: Self.nowMilliseconds() + 25_000,
                        requestID: UUID()
                    )
                    self.vncControlSnapshot = await self.vncTakeoverController.snapshot()
                } catch is CancellationError {
                    return
                } catch {
                    await self.failClosedVNCControl(error)
                    return
                }
            }
        }
    }

    private func failClosedVNCControl(_ error: Error) async {
        vncLeaseHeartbeatTask?.cancel()
        vncLeaseHeartbeatTask = nil
        let snapshot = await vncTakeoverController.snapshot()
        if let lease = snapshot.lease {
            try? await vncTakeoverController.cancel(
                controllerID: lease.controllerID,
                generation: lease.generation,
                requestID: UUID()
            )
        }
        await performVNCHandback()
        vncControlSnapshot = await vncTakeoverController.snapshot()
        errorMessage = error.localizedDescription
    }

    private func performVNCHandback() async {
        vncLeaseHeartbeatTask?.cancel()
        vncLeaseHeartbeatTask = nil
        remoteTerminalPollingTask?.cancel()
        remoteTerminalPollingTask = nil
        if let sessionID = remoteTerminalSessionID, let remoteTerminalController {
            try? await remoteTerminalController.cancel(
                agentID: selectedComputerAgentID,
                sessionID: sessionID,
                ownerID: remoteTerminalOwnerID
            )
        }
        remoteTerminalSessionID = nil
        await securityKeyProxy?.handback()
    }

    private func armTeachMaskingRefresh() {
        teachMaskingRefreshTask?.cancel()
        teachMaskingRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                    try Task.checkCancellation()
                    let masking = try await self.teachMaskingController.refresh()
                    await self.teachController.reportMaskingStatus(masking)
                } catch is CancellationError {
                    return
                } catch {
                    let masking = await self.teachMaskingController.currentStatus()
                    await self.teachController.reportMaskingStatus(masking)
                }
            }
        }
    }

    nonisolated private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private func recordUsage(providerID: String, usage: Usage) async {
        await updateSettings {
            $0.recordUsage(
                accountID: $0.accountScope ?? "local",
                providerID: providerID,
                increment: UsageCounters(
                    requests: 1,
                    inputTokens: Int64(max(0, usage.inputTokens)),
                    outputTokens: Int64(max(0, usage.outputTokens)),
                    cacheReadTokens: Int64(max(0, usage.cacheReadTokens)),
                    cacheWriteTokens: Int64(max(0, usage.cacheWriteTokens)),
                    costMicros: max(0, usage.costMicros)
                )
            )
        }
    }

    private func updateSettings(_ transform: @Sendable @escaping (inout FiliconSettings) throws -> Void) async {
        do { settings = try await settingsStore.update(transform) }
        catch { errorMessage = error.localizedDescription }
    }

    func handleDeepLink(_ url: URL) {
        if url.scheme?.lowercased() == "filicon", url.host?.lowercased() == "oauth", url.path == "/callback" {
            Task { await handleAccountCallback(url) }
            return
        }
        switch deepLinkCoordinator.handle(url) {
        case .dispatch(let link):
            dispatchDeepLink(link)
        case .queued, .duplicate:
            break
        case .queueFull:
            errorMessage = l10n("Filicon has too many pending links. Finish opening the app and try again.")
        case .rejected:
            errorMessage = l10n("Filicon could not open that link because it is unsupported or malformed.")
        }
    }

    var accountIsConfigured: Bool { accountController != nil }

    func configureAccount(
        authorizationURL: String, tokenURL: String, profileURL: String,
        entitlementURL: String, usageURL: String, feedbackURL: String, clientID: String
    ) async {
        let values = [authorizationURL, tokenURL, profileURL, entitlementURL, usageURL, clientID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if values.allSatisfy(\.isEmpty) {
            await cancelAutoReviewApprovals(nextAccountID: "local")
            accountAuthorizationURL = ""; accountTokenURL = ""; accountProfileURL = ""
            accountEntitlementURL = ""; accountUsageURL = ""; accountFeedbackURL = ""; accountClientID = ""
            for key in Self.accountConfigurationKeys { UserDefaults.standard.removeObject(forKey: key) }
            accountController = nil
            accountState = .loggedOut(retainedButRevoked: false)
            accountEntitlement = nil; accountUsage = nil; accountConnection = .init()
            await synchronizeNotificationTransport()
            await refreshModels(forceRefresh: true)
            return
        }
        let trimmedFeedbackURL = feedbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let replacement = makeAccountController(
            authorizationURL: values[0], tokenURL: values[1], profileURL: values[2],
            entitlementURL: values[3], usageURL: values[4], clientID: values[5]
        ) else {
            errorMessage = l10n("Account service requires HTTPS authorization, token, profile, entitlement, and usage endpoints plus a client ID.")
            return
        }
        if !trimmedFeedbackURL.isEmpty {
            guard let feedbackEndpoint = URL(string: trimmedFeedbackURL),
                  (try? HTTPSFeedbackTransport(endpoint: feedbackEndpoint)) != nil else {
                errorMessage = l10n("The feedback service requires a safe HTTPS endpoint.")
                return
            }
        }
        accountAuthorizationURL = values[0]; accountTokenURL = values[1]; accountProfileURL = values[2]
        accountEntitlementURL = values[3]; accountUsageURL = values[4]
        accountFeedbackURL = trimmedFeedbackURL
        accountClientID = values[5]
        let defaults = UserDefaults.standard
        zip(Self.accountConfigurationKeys, [accountAuthorizationURL, accountTokenURL, accountProfileURL, accountEntitlementURL, accountUsageURL, accountFeedbackURL, accountClientID]).forEach { defaults.set($0.1, forKey: $0.0) }
        accountController = replacement
        await restoreAccount()
        await refreshModels(forceRefresh: true)
    }

    func beginAccountSignIn() async {
        guard let accountController else { errorMessage = l10n("Configure an account service first."); return }
        do {
            let request = try await accountController.beginSignIn()
            accountState = await accountController.state
            await synchronizeNotificationTransport()
            guard NSWorkspace.shared.open(request.url) else { throw AccountProviderError.cancelled }
        } catch { errorMessage = accountErrorMessage(error) }
    }

    func handleAccountCallback(_ url: URL) async {
        guard let accountController else { errorMessage = l10n("No account sign-in is pending."); return }
        do {
            accountState = try await accountController.handleCallback(url)
            if let identifier = accountState.session?.profile.id {
                if activeVNCAccountID != nil, activeVNCAccountID != identifier {
                    await disconnectVNC()
                }
                await updateSettings { $0.scopeToAccount(identifier) }
                await cancelAutoReviewApprovals(nextAccountID: identifier)
            }
            await refreshAccountAccess()
            await refreshModels(forceRefresh: true)
        } catch {
            accountState = await accountController.state
            await synchronizeNotificationTransport()
            errorMessage = accountErrorMessage(error)
        }
    }

    func refreshAccount() async {
        guard let accountController else { return }
        do { accountState = try await accountController.refresh(); await refreshAccountAccess() }
        catch {
            accountState = await accountController.state
            accountConnection = accountConnectionMachine.send(.failed)
            await synchronizeNotificationTransport()
            errorMessage = accountErrorMessage(error)
        }
    }

    func logoutAccount() async {
        guard let accountController else { return }
        await giveBackVNCControl()
        await cancelAutoReviewApprovals(nextAccountID: "local")
        accountState = await accountController.logout()
        accountEntitlement = nil; accountUsage = nil
        accountConnectionMachine = ConnectionStateMachine()
        accountConnection = accountConnectionMachine.send(.hide)
        await synchronizeNotificationTransport()
        await updateSettings { $0.clearAccountScope() }
        await refreshModels(forceRefresh: true)
    }

    func retryAccountConnection() async {
        accountConnection = accountConnectionMachine.send(.retryStarted)
        await synchronizeNotificationTransport()
        await refreshAccountAccess()
    }

    func advanceOnboarding(to step: OnboardingStep) async {
        do {
            onboardingProgress = try await onboardingController.advance(to: step)
            if step == .handOff { showingOnboarding = false }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectOnboardingSuggestions(_ ids: [String]) async {
        do { onboardingProgress = try await onboardingController.selectSuggestions(ids) }
        catch { errorMessage = error.localizedDescription }
    }

    func submitFeedback(message: String, includeConversationID: Bool) async -> Bool {
        guard let endpoint = URL(string: accountFeedbackURL), !accountFeedbackURL.isEmpty else {
            errorMessage = l10n("Configure an HTTPS feedback endpoint in Account settings first.")
            return false
        }
        do {
            let controller = accountController
            let transport = try HTTPSFeedbackTransport(endpoint: endpoint, bearerToken: {
                guard let controller else { return nil }
                return try await controller.bearerTokenForAuthorizedRequest()
            })
            let submission = try FeedbackSubmission(message: message, conversationID: includeConversationID ? selection?.uuidString : nil)
            try await FeedbackClient(transport: transport).submit(submission)
            return true
        } catch { errorMessage = accountErrorMessage(error); return false }
    }

    private func restoreAccountAndOnboarding() async {
        do { onboardingProgress = try await onboardingController.restore() }
        catch { errorMessage = error.localizedDescription }
        showingOnboarding = onboardingProgress.current != .handOff
        await restoreAccount()
        await refreshModels(forceRefresh: true)
    }

    private func restoreAccount() async {
        guard let accountController else {
            await cancelAutoReviewApprovals(nextAccountID: "local")
            accountState = .loggedOut(retainedButRevoked: false)
            await synchronizeNotificationTransport()
            return
        }
        accountState = await accountController.restore()
        if case .signedIn = accountState, let identifier = accountState.session?.profile.id {
            await cancelAutoReviewApprovals(nextAccountID: identifier)
            await refreshAccountAccess()
        } else {
            await synchronizeNotificationTransport()
        }
    }

    private func refreshAccountAccess() async {
        guard let accountController, case .signedIn = accountState else {
            accountConnection = accountConnectionMachine.send(.hide)
            await synchronizeNotificationTransport()
            return
        }
        accountConnection = accountConnectionMachine.send(.show)
        await synchronizeNotificationTransport()
        do {
            let projection = try await accountController.accessProjection()
            accountEntitlement = projection.0; accountUsage = projection.1
            accountConnection = accountConnectionMachine.send(.succeeded)
            await synchronizeNotificationTransport()
        } catch {
            accountConnection = accountConnectionMachine.send(.failed)
            await synchronizeNotificationTransport()
            errorMessage = accountErrorMessage(error)
        }
    }

    private func rebuildAccountController() { accountController = makeAccountController() }

    private func makeAccountController() -> AccountController? {
        makeAccountController(
            authorizationURL: accountAuthorizationURL, tokenURL: accountTokenURL,
            profileURL: accountProfileURL, entitlementURL: accountEntitlementURL,
            usageURL: accountUsageURL, clientID: accountClientID
        )
    }

    private func makeAccountController(
        authorizationURL: String, tokenURL: String, profileURL: String,
        entitlementURL: String, usageURL: String, clientID: String
    ) -> AccountController? {
        guard let authorization = URL(string: authorizationURL), authorization.scheme?.lowercased() == "https",
              let token = URL(string: tokenURL), let profile = URL(string: profileURL),
              let entitlement = URL(string: entitlementURL), let usage = URL(string: usageURL),
              let configuration = try? HTTPSAccountProviderConfiguration(
                clientID: clientID, redirectURI: Self.accountCallbackURL,
                tokenEndpoint: token, profileEndpoint: profile, entitlementEndpoint: entitlement, usageEndpoint: usage
              ) else { return nil }
        return AccountController(
            provider: HTTPSAccountProvider(configuration: configuration),
            secrets: KeychainAccountSecretStore(service: "com.filicon.app.account"),
            authorizationEndpoint: authorization, clientID: clientID, callbackURL: Self.accountCallbackURL
        )
    }

    private func accountErrorMessage(_ error: Error) -> String {
        if let value = error as? LocalizedError, let message = value.errorDescription { return message }
        return switch error {
        case FeedbackError.invalid: "Feedback must contain 1–10,000 characters."
        case FeedbackError.deadlineExceeded: "Feedback submission timed out."
        case FeedbackError.badRequest: "The feedback service rejected the submission."
        case FeedbackError.authenticationRequired: "Sign in before sending feedback."
        case FeedbackError.paymentRequired: "This account is not entitled to send feedback."
        case FeedbackError.forbidden: "Feedback access was denied."
        case FeedbackError.rateLimited: "Too many feedback submissions. Try again later."
        case FeedbackError.server(let status): "Feedback service error (HTTP \(status))."
        case FeedbackError.transport: "The feedback service is unavailable."
        default: String(describing: error)
        }
    }

    private static let accountCallbackURL = URL(string: "filicon://oauth/callback")!
    private static let accountConfigurationKeys = [
        "FiliconAccountAuthorizationURL", "FiliconAccountTokenURL", "FiliconAccountProfileURL",
        "FiliconAccountEntitlementURL", "FiliconAccountUsageURL", "FiliconAccountFeedbackURL", "FiliconAccountClientID",
    ]

    private func dispatchDeepLink(_ link: FiliconDeepLink) {
        switch link {
        case .sharedRoomJoin(let token):
            selectRoute(.sharedRooms)
            Task { await requestSharedRoomJoin(invite: token) }
        case .pluginAdd(let id):
            requestedPluginID = id
            selectRoute(.plugins)
        case .open:
            NSApp.activate(ignoringOtherApps: true)
            if route == nil { selectRoute(.search) }
        case .infoDeepLinks:
            NSApp.activate(ignoringOtherApps: true)
            errorMessage = l10n("Supported links can open a conversation or agent, join a Shared Room, open a plugin for installation, or activate Filicon. Links are validated locally before any action runs.")
        case .agent(let id):
            NSApp.activate(ignoringOtherApps: true)
            guard agents.contains(where: { $0.id == id }) else {
                errorMessage = l10n("That agent is not available on this Mac.")
                return
            }
            requestedAgentInspectionID = id
            selectRoute(.agents)
        case .conversation(let id):
            if conversations.contains(where: { $0.id == id }) {
                selectRoute(.conversation(id))
                return
            }
            Task {
                do {
                    guard var metadata = try await store.conversation(id: id) else {
                        errorMessage = l10n("That conversation is not available on this Mac.")
                        return
                    }
                    metadata.messages = []
                    conversations.append(metadata)
                    selectRoute(.conversation(id))
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    var selectedSharedRoom: SharedRoomSnapshot? { sharedRooms.first { $0.id == selectedSharedRoomID } }

    func configureSharedRooms(enabled: Bool, displayName: String, transportMode: String, serverURL: String, credentialReference: String, token: String = "") async {
        let cleanName = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !cleanName.isEmpty else { errorMessage = SharedRoomError.invalidName.localizedDescription; return }
        let mode = transportMode == "https" ? "https" : "local"
        if mode == "https" {
            guard let url = URL(string: serverURL), url.scheme?.lowercased() == "https", url.host != nil else {
                errorMessage = SharedRoomError.insecureEndpoint.localizedDescription; return
            }
            guard !credentialReference.isEmpty else { errorMessage = l10n("Enter a Keychain credential reference."); return }
        }
        sharedRoomsEnabled = enabled
        sharedRoomIdentity.displayName = cleanName
        sharedRoomTransportMode = mode
        sharedRoomServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        sharedRoomCredentialReference = String(credentialReference.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: "FiliconSharedRoomsEnabled")
        defaults.set(mode, forKey: "FiliconSharedRoomTransportMode")
        defaults.set(sharedRoomServerURL, forKey: "FiliconSharedRoomServerURL")
        defaults.set(sharedRoomCredentialReference, forKey: "FiliconSharedRoomCredentialReference")
        persistSharedRoomIdentity()
        if !token.isEmpty {
            do { try await credentials.set(token, for: sharedRoomCredentialRef(sharedRoomCredentialReference)) }
            catch { errorMessage = error.localizedDescription; return }
        }
        await rebuildSharedRoomClient()
        await refreshSharedRooms()
    }

    func resetSharedRoomIdentity(displayName: String) async {
        sharedRoomIdentity = SharedRoomIdentity(
            id: UUID(), displayName: String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
            accountGeneration: sharedRoomIdentity.accountGeneration &+ 1
        )
        rootResilience.updateAccountGeneration(sharedRoomIdentity.accountGeneration)
        rootConnection = rootResilience.connection
        persistSharedRoomIdentity()
        sharedRooms = []; selectedSharedRoomID = nil; lastSharedRoomInvite = nil
        await rebuildSharedRoomClient(); await refreshSharedRooms()
    }

    func refreshSharedRooms() async {
        guard sharedRoomsEnabled, let sharedRoomClient else { sharedRooms = []; selectedSharedRoomID = nil; return }
        do {
            guard case .rooms(let values) = try await sharedRoomClient.perform(.listRooms) else { throw SharedRoomError.malformedReply }
            sharedRooms = values
            if let id = selectedSharedRoomID, !values.contains(where: { $0.id == id }) { selectedSharedRoomID = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    func createSharedRoom(name: String) async {
        guard let sharedRoomClient else { return }
        do {
            guard case .room(let room) = try await sharedRoomClient.perform(.createRoom(name: name)) else { throw SharedRoomError.malformedReply }
            selectedSharedRoomID = room.id; await refreshSharedRooms()
        } catch { errorMessage = error.localizedDescription }
    }

    func createSharedRoomInvite(roomID: UUID, lifetime: TimeInterval = 24 * 3600) async {
        guard let sharedRoomClient else { return }
        do {
            guard case .invite(let invite) = try await sharedRoomClient.perform(.createInvite(roomID: roomID, expiresAt: .now.addingTimeInterval(lifetime))) else { throw SharedRoomError.malformedReply }
            lastSharedRoomInvite = invite
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
        } catch { errorMessage = error.localizedDescription }
    }

    func requestSharedRoomJoin(invite: String) async {
        guard let sharedRoomClient else { errorMessage = l10n("Enable Shared Rooms first."); return }
        do {
            let response = try await sharedRoomClient.perform(.requestJoin(token: invite))
            if case .room(let room) = response { selectedSharedRoomID = room.id }
            selectRoute(.sharedRooms); await refreshSharedRooms()
        } catch { errorMessage = error.localizedDescription }
    }

    func decideSharedRoomJoin(roomID: UUID, requestID: UUID, approve: Bool) async {
        await updateSharedRoom(.decideJoin(roomID: roomID, requestID: requestID, decision: approve ? .approve : .deny))
    }

    func addAgentToSharedRoom(roomID: UUID, agent: AgentProfile) async {
        await updateSharedRoom(.addAgent(roomID: roomID, agent: .init(id: agent.id, displayName: agent.name)))
    }

    func removeSharedRoomMember(roomID: UUID, memberID: UUID) async { await updateSharedRoom(.removeMember(roomID: roomID, memberID: memberID)) }
    func leaveSharedRoom(roomID: UUID) async {
        guard let sharedRoomClient else { return }
        do { _ = try await sharedRoomClient.perform(.leave(roomID: roomID)); selectedSharedRoomID = nil; await refreshSharedRooms() }
        catch { errorMessage = error.localizedDescription }
    }
    func setSharedRoomTyping(roomID: UUID, isTyping: Bool) async { await updateSharedRoom(.setTyping(roomID: roomID, isTyping: isTyping)) }

    private func updateSharedRoom(_ operation: SharedRoomOperation) async {
        guard let sharedRoomClient else { return }
        do {
            guard case .room(let room) = try await sharedRoomClient.perform(operation) else { throw SharedRoomError.malformedReply }
            if let index = sharedRooms.firstIndex(where: { $0.id == room.id }) { sharedRooms[index] = room }
            else { sharedRooms.append(room) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func rebuildSharedRoomClient() async {
        guard sharedRoomsEnabled else { sharedRoomClient = nil; return }
        do {
            let transport: any SharedRoomTransport
            if sharedRoomTransportMode == "https" {
                guard let endpoint = URL(string: sharedRoomServerURL) else { throw SharedRoomError.insecureEndpoint }
                let credentials = self.credentials
                transport = try HTTPSSharedRoomTransport(
                    endpoint: endpoint, credentialReference: sharedRoomCredentialReference,
                    resolver: ClosureSharedRoomAuthTokenResolver { reference in
                        try await credentials.value(for: CredentialRef(providerID: ProviderID(rawValue: "shared-room.server"), account: reference))
                    }
                )
            } else {
                transport = FileSharedRoomTransport(stateURL: sharedRoomLocalStateURL)
            }
            sharedRoomClient = SharedRoomClient(identity: sharedRoomIdentity, transport: transport, enabled: true)
        } catch { sharedRoomClient = nil; errorMessage = error.localizedDescription }
    }

    private func sharedRoomCredentialRef(_ reference: String) -> CredentialRef {
        CredentialRef(providerID: ProviderID(rawValue: "shared-room.server"), account: reference)
    }

    private func persistSharedRoomIdentity() {
        let defaults = UserDefaults.standard
        defaults.set(sharedRoomIdentity.id.uuidString, forKey: "FiliconSharedRoomIdentityID")
        defaults.set(sharedRoomIdentity.displayName, forKey: "FiliconSharedRoomDisplayName")
        defaults.set(Int(sharedRoomIdentity.accountGeneration), forKey: "FiliconSharedRoomAccountGeneration")
    }

    private static func applicationSupportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Filicon", directoryHint: .isDirectory)
    }
}

private extension UInt64 {
    var clampedAtLeastOne: UInt64 { Swift.max(1, self) }
}

private struct LocalMacComputerBackend: ComputerSessionBackend {
    func status(for agentID: String) async throws -> ComputerBackendStatus { .running(vncURL: nil) }
    func ensure(for agentID: String) async throws -> ComputerBackendStatus { .running(vncURL: nil) }
}

private struct AppRemoteComputerCredentialResolver: RemoteComputerCredentialResolver {
    let credentials: KeychainCredentialStore
    let headerName: String
    let scheme: String

    func resolve(reference: String) async throws -> RemoteComputerCredential {
        let secret = try await credentials.value(for: CredentialRef(providerID: ProviderID(rawValue: "remote-computer"), account: reference))
        let value = scheme.isEmpty ? secret : "\(scheme) \(secret)"
        return .init(headerName: headerName, value: value)
    }
}

private struct AppCloudBearerProvider: CloudAgentBearerProvider {
    let credentials: KeychainCredentialStore

    func bearer(for reference: CloudAgentBearerReference) async throws -> String? {
        try? await credentials.value(for: AppModel.cloudCredentialRef(reference.rawValue))
    }
}

/// Persists only the opaque remote run identifier. Endpoint configuration contains a
/// Keychain reference, never bearer material, and a relaunched cloud task reattaches.
actor AppCloudTaskRuntime: AgentAsyncTaskRuntime {
    nonisolated let taskKind: AgentTaskKind = .cloud
    private let runtime: CloudAgentRuntime
    private let agentID: UUID

    init(runtime: CloudAgentRuntime, agentID: UUID) {
        self.runtime = runtime
        self.agentID = agentID
    }

    func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome {
        let observer = Task { [runtime, agentID] in
            while !Task.isCancelled {
                let state = await runtime.state()
                if let remoteRunID = state.remoteRunID {
                    UserDefaults.standard.set(remoteRunID, forKey: Self.runKey(agentID))
                }
                if state.status?.isTerminal == true { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { observer.cancel() }
        do {
            let outcome = try await runtime.run(prompt: prompt, scope: scope)
            UserDefaults.standard.removeObject(forKey: Self.runKey(agentID))
            return outcome
        } catch let error as CloudAgentError {
            if error == .remoteCancelled { UserDefaults.standard.removeObject(forKey: Self.runKey(agentID)) }
            throw error
        }
    }

    func interrupt(reason: String) async {
        await runtime.interrupt(reason: reason)
        UserDefaults.standard.removeObject(forKey: Self.runKey(agentID))
    }

    private static func runKey(_ agentID: UUID) -> String {
        "FiliconCloudAgentRun.\(agentID.uuidString.lowercased())"
    }
}

private actor AppProviderTaskRuntime: AgentAsyncTaskRuntime {
    nonisolated let taskKind: AgentTaskKind
    let registry: ProviderRegistry
    let profile: AgentProfile

    init(kind: AgentTaskKind, registry: ProviderRegistry, profile: AgentProfile) {
        taskKind = kind; self.registry = registry; self.profile = profile
    }

    func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome {
        guard let provider = await registry.provider(id: profile.providerID) else {
            throw ProviderError.transport("The agent provider is unavailable.")
        }
        let request = InferenceRequest(
            conversationID: UUID(), modelID: profile.modelID,
            messages: [.init(role: .system, text: profile.instructions), .init(role: .user, text: prompt)]
        )
        var text = "", usage = Usage()
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            if case .textDelta(let delta) = event { text += delta }
            if case .usage(let value) = event { usage = value }
        }
        return .completed(text: text, usage: usage)
    }

    func interrupt(reason: String) async {}
}

private actor AppShellTaskRuntime: AgentAsyncTaskRuntime {
    nonisolated let taskKind = AgentTaskKind.shell
    private var process: Process?

    func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome {
        let outputURL = FileManager.default.temporaryDirectory.appending(path: "filicon-agent-shell-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", prompt]
        process.standardOutput = output
        process.standardError = output
        self.process = process
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        self.process = nil
        try output.synchronize()
        let data = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        let clipped = String(decoding: data.prefix(1_000_000), as: UTF8.self)
        guard status == 0 else { throw ProviderError.transport("Shell exited with status \(status).\n\(clipped)") }
        return .completed(text: clipped, usage: .init())
    }

    func interrupt(reason: String) async {
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}

private struct AppPluginSecretStore: PluginSecretStore {
    let credentials: KeychainCredentialStore
    func set(_ value: String, pluginID: String, name: String) async throws {
        try await credentials.set(value, for: reference(pluginID: pluginID, name: name))
    }
    func value(pluginID: String, name: String) async throws -> String? {
        try? await credentials.value(for: reference(pluginID: pluginID, name: name))
    }
    func remove(pluginID: String, name: String) async throws {
        try await credentials.remove(reference(pluginID: pluginID, name: name))
    }
    private func reference(pluginID: String, name: String) -> CredentialRef {
        CredentialRef(providerID: ProviderID(rawValue: "plugin.\(pluginID).\(name)"))
    }
}

private struct AppAutomationExecutor: AutomationExecutor {
    let registry: ProviderRegistry
    let agents: AgentService
    let scheduler: AgentExecutionScheduler
    var lane: AgentExecutionLane = .background
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        try await scheduler.withExclusiveAccess(agentID: automation.agentID, lane: lane) {
            try await executeExclusive(automation: automation, prompt: prompt)
        }
    }
    private func executeExclusive(automation: Automation, prompt: String) async throws -> AutomationExecutionResult {
        guard let profile = await agents.profile(id: automation.agentID), profile.archivedAt == nil,
              let provider = await registry.provider(id: profile.providerID) else {
            throw ProviderError.transport("Automation agent or provider is unavailable.")
        }
        let system = ChatMessage(role: .system, text: profile.instructions)
        let request = InferenceRequest(conversationID: UUID(), modelID: profile.modelID, messages: [system, .init(role: .user, text: prompt)])
        var text = "", usage: Usage?
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            if case .textDelta(let delta) = event { text += delta }
            if case .usage(let value) = event { usage = value }
        }
        return .init(detail: text, inputTokens: usage?.inputTokens, outputTokens: usage?.outputTokens)
    }
}

private struct MCPKeychainTokenReferenceStore: MCPTokenReferenceStore {
    let credentials: KeychainCredentialStore

    func remove(reference: String) async throws {
        try await credentials.remove(CredentialRef(providerID: ProviderID(rawValue: "mcp.\(reference)")))
    }
}

struct LocalAppToolExecutor: ToolExecutor {
    enum Kind: String, CaseIterable, Sendable {
        case readFile = "local__read_file"
        case listDirectory = "local__list_directory"
        case writeFile = "local__write_file"
        case runProcess = "local__run_process"
        case readProcess = "local__read_process"
        case sendInput = "local__send_input"
        case terminateProcess = "local__terminate_process"
    }

    let kind: Kind
    let runtime: LocalToolRuntime
    let policy: ToolPermissionPolicy
    let approvals: ToolApprovalBroker

    static func all(
        runtime: LocalToolRuntime,
        policy: ToolPermissionPolicy,
        approvals: ToolApprovalBroker
    ) -> [any ToolExecutor] {
        Kind.allCases.map { Self(kind: $0, runtime: runtime, policy: policy, approvals: approvals) }
    }

    var descriptor: ToolDescriptor {
        .init(
            name: ToolName(rawValue: kind.rawValue),
            description: description,
            inputSchema: Data(schema.utf8),
            parallelSafe: false
        )
    }

    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        do {
            let arguments = try object(call.argumentsJSON)
            let operation = try makeOperation(arguments)
            let target = try await runtime.authorizationTarget(for: operation)
            let reason = (arguments["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let statedReason = reason?.isEmpty == false ? reason! : defaultReason
            let decision = await policy.evaluate(
                action: operation.permissionAction,
                conversationID: context.conversationID,
                toolCallID: call.id.rawValue,
                title: target,
                reason: statedReason
            )
            switch decision {
            case .denied:
                return errorResult(call, "Permission is set to Never for \(operation.permissionAction.rawValue).")
            case .requiresApproval(let request):
                guard await approvals.requestApproval(request) else {
                    try Task.checkCancellation()
                    return errorResult(call, "The user denied this local tool operation.")
                }
            case .allowed:
                break
            }
            let result = try await withTaskCancellationHandler {
                try await runtime.perform(
                    operation: operation,
                    conversationID: context.conversationID,
                    agentID: context.conversationID,
                    runID: context.runID,
                    toolCallID: call.id.rawValue
                )
            } onCancel: {
                Task { await runtime.cancel(runID: context.runID) }
            }
            // Collection failure is not a successful command result, even when
            // the leader exited with status 0. Keep partial bytes and diagnostics.
            let collectionFailed: Bool
            if case .process(let snapshot) = result { collectionFailed = snapshot.terminationError != nil }
            else { collectionFailed = false }
            return .init(callID: call.id, content: [.text(try render(result))], isError: collectionFailed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return errorResult(call, error.localizedDescription)
        }
    }

    private var description: String {
        switch kind {
        case .readFile: "Read one regular file under an exact user-authorized workspace root."
        case .listDirectory: "List a directory under an exact user-authorized workspace root."
        case .writeFile: "Write one regular file under an exact user-authorized workspace root."
        case .runProcess: "Start an executable with literal argv (never through a shell) in an authorized workspace."
        case .readProcess: "Read bounded output from a previously started local process."
        case .sendInput: "Send UTF-8 input to a previously started local process."
        case .terminateProcess: "Terminate a previously started local process and its process group."
        }
    }

    private var defaultReason: String {
        switch kind {
        case .readFile: "Read a workspace file requested by the current AI turn."
        case .listDirectory: "Inspect workspace directory contents requested by the current AI turn."
        case .writeFile: "Modify a workspace file requested by the current AI turn."
        case .runProcess: "Run a local command requested by the current AI turn."
        case .readProcess: "Read output from a local command started by the current AI turn."
        case .sendInput: "Provide input to a local command started by the current AI turn."
        case .terminateProcess: "Stop a local command started by the current AI turn."
        }
    }

    private var schema: String {
        switch kind {
        case .readFile, .listDirectory:
            #"{"type":"object","properties":{"root":{"type":"string"},"path":{"type":"string"},"reason":{"type":"string"}},"required":["root","path"],"additionalProperties":false}"#
        case .writeFile:
            #"{"type":"object","properties":{"root":{"type":"string"},"path":{"type":"string"},"content":{"type":"string"},"content_base64":{"type":"string"},"replace":{"type":"boolean"},"reason":{"type":"string"}},"required":["root","path"],"additionalProperties":false}"#
        case .runProcess:
            #"{"type":"object","properties":{"executable":{"type":"string"},"arguments":{"type":"array"},"root":{"type":"string"},"working_directory":{"type":"string"},"environment":{"type":"object"},"timeout_ms":{"type":"integer"},"reason":{"type":"string"}},"required":["executable","root"],"additionalProperties":false}"#
        case .readProcess:
            #"{"type":"object","properties":{"session_id":{"type":"string"},"offset":{"type":"integer"},"reason":{"type":"string"}},"required":["session_id"],"additionalProperties":false}"#
        case .sendInput:
            #"{"type":"object","properties":{"session_id":{"type":"string"},"data":{"type":"string"},"close_after_write":{"type":"boolean"},"reason":{"type":"string"}},"required":["session_id","data"],"additionalProperties":false}"#
        case .terminateProcess:
            #"{"type":"object","properties":{"session_id":{"type":"string"},"reason":{"type":"string"}},"required":["session_id"],"additionalProperties":false}"#
        }
    }

    private func makeOperation(_ arguments: [String: Any]) throws -> LocalOperation {
        switch kind {
        case .readFile:
            return .readFile(root: try string("root", arguments), relativePath: try string("path", arguments))
        case .listDirectory:
            return .listDirectory(root: try string("root", arguments), relativePath: try string("path", arguments))
        case .writeFile:
            let data: Data
            if let encoded = arguments["content_base64"] as? String, let decoded = Data(base64Encoded: encoded) {
                data = decoded
            } else if let content = arguments["content"] as? String {
                data = Data(content.utf8)
            } else {
                throw LocalToolError.invalidRequest("write_file requires content or valid content_base64")
            }
            return .writeFile(
                root: try string("root", arguments),
                relativePath: try string("path", arguments),
                data: data,
                replace: arguments["replace"] as? Bool ?? false
            )
        case .runProcess:
            let timeout = (arguments["timeout_ms"] as? NSNumber)?.uint64Value ?? 30_000
            let environment = arguments["environment"] as? [String: String] ?? [:]
            let argv = arguments["arguments"] as? [String] ?? []
            return .runCommand(.init(
                executable: try string("executable", arguments),
                arguments: argv,
                workingDirectoryRoot: try string("root", arguments),
                workingDirectory: arguments["working_directory"] as? String ?? ".",
                environment: environment,
                timeoutMilliseconds: timeout
            ))
        case .readProcess:
            return .readProcess(
                sessionID: try uuid("session_id", arguments),
                offset: (arguments["offset"] as? NSNumber)?.intValue ?? 0
            )
        case .sendInput:
            return .sendInput(
                sessionID: try uuid("session_id", arguments),
                data: Data(try string("data", arguments).utf8),
                closeAfterWrite: arguments["close_after_write"] as? Bool ?? false
            )
        case .terminateProcess:
            return .terminate(sessionID: try uuid("session_id", arguments))
        }
    }

    private func render(_ result: LocalOperationResult) throws -> String {
        switch result {
        case .acknowledged: return "OK"
        case .directory(let names):
            return String(decoding: try JSONEncoder().encode(names), as: UTF8.self)
        case .file(let data):
            if let text = String(data: data, encoding: .utf8) { return text }
            return "base64:\(data.base64EncodedString())"
        case .process(let snapshot):
            return String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalToolError.invalidRequest("arguments must be an object")
        }
        return value
    }

    private func string(_ key: String, _ values: [String: Any]) throws -> String {
        guard let value = values[key] as? String, !value.isEmpty else {
            throw LocalToolError.invalidRequest("missing \(key)")
        }
        return value
    }

    private func uuid(_ key: String, _ values: [String: Any]) throws -> UUID {
        guard let value = values[key] as? String, let id = UUID(uuidString: value) else {
            throw LocalToolError.invalidRequest("invalid \(key)")
        }
        return id
    }

    private func errorResult(_ call: NormalizedToolCall, _ message: String) -> NormalizedToolResult {
        .init(callID: call.id, content: [.text(message)], isError: true)
    }
}
