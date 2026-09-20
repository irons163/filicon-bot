# Filicon / Grok Bot 0.18 功能 parity matrix（current implementation）

本矩陣保留固定的 48 個 parity ID，對照目前 macOS Swift 實作。`complete` 表示該列所述能力有歷史實作證據，不代表原版所有細項均已重新核驗；`partial` 表示仍有功能、接線或驗證缺口；`NA` 表示該列是來源 runtime 的實作細節，不是 macOS 產品行為。這不是「原版功能全部都有」的保證。

2026-09-20 再次核對後，為 43 筆 `complete`、4 筆 `partial`、1 筆 `NA`（`UPD-04`）。`AUTO-03` 因已確認平台事件語意缺口，維持 partial；Linear 已補事件分類、送達識別、防重播、受核准模型提案與新狀態篩選，Sentry 已補五種 issue case／issueAny、正確 project ID 篩選與 body digest 去重，已接上模型 create/update、平面混合 OR 與七語言完整核准；PagerDuty 已補四種 incident case／incidentAny、精確 service ID 篩選、僅 v1 簽章候選與 signed-body／event.id 去重，已接上自身模型 create/update、完整核准及混合 OR；先前已補原生 Cycle/update 的明確完成轉換、team/cycle UUID 篩選和完成身分去重；已接上 endOfCycle／cycleIds 自身模型提案、混合 OR、七語言完整核准與生命週期防護。本輪修正 Teams 傳出 webhook：不再以 HMAC 當使用者登入、分離 Graph/Bot 團隊 ID、拒絕非訊息活動、加入有範圍的訊息身分去重；缺少使用者／主文證據時保守不執行，不等於已還原 Teams 雲端功能。原生無專案關聯的週期提案拒絕非空 projectIds；平台專用編輯器及原版雲端等完整語意仍未還原。`AGENT-01` 已補受審批的模型 `CreateAgent`／`UpdateAgent`、own-profile `update_state(profile.set)` 及 own-agent `memory.write/forget`；先前已接上明確核准的 `scope:user` 共享事實與 note 分級、正規化去重及有預算的記憶召回，當時跨重啟與完整套件通過。仍限制在有 agent 身分的群組／mailbox，不改私人 persona，也未涵蓋 project 記憶及其他 update_state 路由，因此維持 partial。其他列的驗證欄保留歷史紀錄，不表示本次重新驗證；本輪非並行完整回歸通過（134 XCTest、822 Swift Testing）；上一批預設並行曾有 5 項既有測試失敗，單獨重跑通過，仍須處理時序穩定性。細項見 [協作核對紀錄](Agent-collaboration-parity.md)。

## Matrix

### 1. UI surface

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| UI-01 | `Sources/Filicon/FiliconApp.swift`、`AppModel.swift`、`WorkspaceNavigationBridge.swift` 提供 app root、sidebar、workspace route、commands 與 deep-link dispatch。 | complete | final gates passed |
| UI-02 | `FiliconApp.swift` 掛載 chats、search、agents、groups、automations、channels、shared rooms、MCP、computer、plugins、account 與 update surfaces。 | complete | final gates passed |
| UI-03 | `FiliconApp.swift` composer、`ComposerDraftStore.swift`、`AttachmentLifecycle.swift` 與 `FiliconVoice` 提供 draft、file/drop/paste staging、voice、send/queue/cancel。 | complete | final gates passed |
| UI-04 | `TranscriptPresentationState.swift`、`TranscriptRichPresentation.swift`、`TranscriptCardPresentation.swift`、`TranscriptCardActionRouter.swift` 與 `RichMarkdownView.swift` 提供 rich transcript、tool/thinking cards、reaction、reply、resend/delete 與 safe links。 | complete | final gates passed |

### 2. Conversation / transcript

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| CONV-01 | `AppModel.swift`、`ConversationStore.swift` 與 `ConversationRepository.swift` 提供 conversation CRUD、命名、隱藏/還原、選取與 transcript ownership。 | complete | final gates passed |
| CONV-02 | `TurnCoordinator.swift` 與 `AppModel.swift` 提供每 conversation queue、streaming lifecycle、cancellation、terminal cleanup，以及獨立 conversation concurrency。 | complete | final gates passed |
| CONV-03 | `FiliconDomain/Models.swift`、`TranscriptEventHub.swift` 與 transcript action router 持久化 rich messages、tool rows、reaction、reply、queued/failed resend/delete。 | complete | final gates passed |
| CONV-04 | `Pagination.swift`、`ConversationPaginationState.swift`、`GlobalSearchService.swift` 與 `AppModel.swift` 提供 cursor paging、request fencing、dedupe、find-in-chat 與 global search。 | complete | final gates passed |

### 3. Attachments / media

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| ATT-01 | `FiliconDomain/Attachments.swift`、`AttachmentStore.swift`、`AttachmentLifecycle.swift` 與 `AttachmentReferenceRepository.swift` 提供 SHA-256 content-addressed ingest、limits、metadata、staging、read/remove、reference lifecycle 與 quota。 | complete | final gates passed |
| ATT-02 | `AppModel.swift` composer staging 與 `FiliconApp.swift` file/drop/paste UI 將 attachment 連到 user message、turn 與 provider request，並支援取消/重試。 | complete | final gates passed |
| ATT-03 | `AttachmentMediaViewer.swift`、`AttachmentQuickLook.swift` 與 `AttachmentSpreadsheetPreview.swift` 提供 image/video/audio、PDF/Quick Look、CSV/TSV/XLSX safe preview、download/export 與 integrity/error states。 | complete | final gates passed |
| ATT-04 | `FiliconVoice/NativeVoiceRecorder.swift`、`VoiceComposerController.swift` 與 `SystemSpeechTranscriber.swift` 提供 microphone permission、bounded recording、cancel/retry、transcription 與 transcript attachment。 | complete | final gates passed |

### 4. Providers / models

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| PROV-01 | `FiliconProviderKit/HTTPProviders.swift`、`IncrementalParsers.swift`、`Provider.swift` 與 `TurnCoordinator.swift` 統一 SSE/NDJSON streaming、usage、error、abort、tool events 與 cancellation。 | complete | final gates passed |
| PROV-02 | `OpenRouterProvider` 已由 `AppModel.swift` registry 註冊，並以 provider-scoped `CredentialRef`、descriptor、endpoint wire contract 與 catalog integration 提供 OpenRouter routing。 | complete | final gates passed |
| PROV-03 | `FiliconProviderKit/CLIProviders.swift` 的 `CodexCLIProvider` 與 `ClaudeCodeCLIProvider` 使用各自官方 CLI 的 auth session、model/reasoning flags、stream parser、error mapping 與 no-credential state；不讀私有 app auth。 | complete | final gates passed |
| PROV-04 | `ProviderCatalog.swift`、`ProviderCatalogPresentation.swift`、`ModelRefreshGuard` 與 `AppModel.swift` 提供 dynamic/static catalog、provider/model snapshot、default fallback、reasoning capability、usage 與 unavailable/error state。 | complete | final gates passed |

### 5. MCP / plugins / tools / permissions

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| MCP-01 | `ToolModels.swift`、`ToolLoop.swift` 與 provider event normalization 提供 bounded eight-step tool loop、schema validation、parallel-safe execution、ordered results、duplicate/cancel errors。 | complete | final gates passed |
| MCP-02 | `FiliconMCP/Service.swift`、`ConfigurationStore.swift`、`MCPAccountsView.swift`、`FiliconPlugins` 與 `PrivateSkillsView.swift` 提供 server/plugin catalog、account/auth、tool toggles、install/remove/rename 與 private skills。 | complete | final gates passed |
| MCP-03 | `FiliconMCP/StdioTransport.swift`、`HTTPTransport.swift`、`MCPOAuthFlow.swift`、`MCPApprovalView.swift` 與 authorized dispatcher 提供 initialize/list/call、HTTPS/stdio boundaries、OAuth state、timeout、schema/policy dispatch。 | complete | final gates passed |
| MCP-04 | `ToolPermissionPolicy.swift`、`ToolApprovalBroker`、`FiliconLocalTools` 與 approval UI 提供 always/ask/never、allow-once scope、TTL/generation fencing、admin ceiling、deny 與 replay protection。 | complete | final gates passed |

### 6. Agents / groups / channels

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| AGENT-01 | `AgentService`、`Models`、`AgentsWorkspaceScreen`、`AgentAvatarStore` 提供 UI profile CRUD。`AgentManagementSession` 在群組／mailbox 接上 `CreateAgent`／`UpdateAgent`／own-profile `update_state(profile.set)`，完整欄位審批、停止撤銷、共用四次上限、重播防護與原子儲存。只改名稱／公開摘要；新增沿用發起者模型，不複製私人上下文或自動加入群組。own-agent `memory.write/forget` 已逐次審批、帳號＋代理人隔離、跨群組／mailbox 持久化。另有 `scope:user` 的帳號內共享事實，核准列明所有現有／未來代理人及其模型，舊記憶維持私人；UI 可檢視／忘記，模型只能刪自己的記錄。note 以較低重要性參與近期排序，私人／共享各有獨立召回預算與重複摺疊，省略不刪除原記錄。新增 own-avatar set/clear：逐次預覽核准，只能選內建 pet_id 或恢復 Codex，與 profile／memory 共用四次額度，不接受原版 host/box path 圖片來源。群組／mailbox 另接 own-routine create/update/pause/resume/delete：逐次完整 before/after 核准，建立／修改支援固定時區 cron／alias／@every、單一 GitHub／Slack trigger 或 1–8 個平面時間／事件 OR 條件，省略欄位與歷史保留，核准後開始且不補跑；delete 移除定義、歷史保留。不能越過費用防護；GitHub 需既有已驗證事件入口，CI 僅個別 push workflow 完成而非 checks 彙整；Slack 限對話 ID／*，不解析名稱或篩選自身身分；時間與事件可混合且逐項固定時區，揭露 OR／間隔共用基準；其他平台／generic event 的模型建立／修改仍缺。仍缺 project 記憶、自動擷取／檢索、其他入口／update_state 路由與完整原版 persona/runtime。 | partial | `AgentManagementSessionTests`、`AgentAvatarChangeTests`、`AgentMemoryTests`、`AgentManagementAppIntegrationTests`；本輪驗證狀態見協作核對紀錄 |
| AGENT-02 | `GroupService.swift`、`GroupConversationResponder.swift` 提供三輪接續、角色/增量上下文、去重、PASS/失敗、stop/cancel。`AgentUserMessageTool` 已接線 `SendMessage`：一般群組可發布本輪 host 綁定且使用者指定給自己的圖片；mailbox/peer wake 可發布本次 incoming 圖片，均需文字與獨立預覽核准。群組原子保存 room reply；canonical mailbox 先持久化發布紀錄，再鏡射來源 UI。Stop／失敗／重啟保留，每 turn 至多兩則，不重複 final text、不新增回覆成員。仍未還原完整圖片來源或原版 runtime。 | partial | `GroupCollaborationTests`、`GroupToolExecutionTests`、`AgentBackgroundExecutionTests`、`AgentUserMessageToolTests`、`AgentImageAppIntegrationTests` |
| AGENT-03 | `FiliconSharedRooms` 的 file/HTTPS transports、`SharedRoomsWorkspaceView.swift`、`FiliconChannels/ChannelService.swift` 與 REST connectors 提供 room invite/approval/member lifecycle、channel inbound/outbound、attachments、reactions、OAuth 與 delivery retry。 | complete | final gates passed |
| AGENT-04 | `AgentMessagingSession` 提供固定寄件身分、完整 payload approval、durable queue、recipient/reply wake、權限/停止/逾時/上限。手動訊息已接上背景推論與審批 UI。已補審批後貼入自己所屬其他群組的文字訊息與房間回覆；忙碌目標拒絕，兩群組／六委派上限。`AgentConversationStore` 持久化 account/origin/agent 隔離上下文。App 共用 `AgentExecutionScheduler` 將群組、mailbox、子任務、自動化、workflow、channel reply 依 agent 串行（一般工作 FIFO），取消等待不影響其他 owner，host 工具清理後才放行。已補明確核准的 peer/manual priority：來源 drain 後可中斷背景 peer/group/排程自動化，使用者回合受保護；工具清理後才交棒、不重播。群組 priority 不支援，也非 enqueue 當下立即中斷。仍非跨全部 DM/群組統一私人記憶或完整原版 runtime；手動訊息及一般群組可輸入有界 PNG/JPEG，當輪圖片 ID 可經審批後轉交單一 peer 或 SendMessage 發布。歷史圖片不自動重播；任意圖片來源、跨程序與重啟排程仍缺。參考的 postToGroup 也是文字入口，不能將跨群組圖片視為已確認原版缺項。 | partial | `AgentMessagingSessionTests`、`SendToAgentAppIntegrationTests`、`AgentGroupMessagingTests`、`AgentGroupMessagingAppTests`、`AgentBackgroundExecutionTests`、`AgentConversationStoreTests`、`AgentExecutionSchedulerTests`、`AgentImageMessagingTests`、`AgentImageAppIntegrationTests`、`GroupImageAppTests` |

### 7. Automations

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| AUTO-01 | `FiliconAutomations/CronSchedule.swift`、`AutomationService.swift` 與 `Scheduler.swift` 提供 cron/alias/`@every`、timezone/DST、next-run、durable claim、cancel/reconcile 與 restart recovery。內部平面 `.anyOf` 已補最早時間與事件／手動共用 last-run 基準、同時命中單次執行、舊資料不自動啟用、stale batch 與開始執行寫檔失敗回滾；模型混合條件入口與七語言完整核准已接上，單項 cron／alias／interval 可與 GitHub／Slack 任意平面混合。 | complete | 本輪 85 項聚焦回歸與原生建置通過；完整回歸待 Mac 解鎖，詳見協作核對紀錄 |
| AUTO-02 | `AutomationService.swift`、`Models.swift`、`WorkflowWorkspaceView.swift` 與 AppModel integration 提供 routine CRUD、enable/disable、Run Now、next/last run 與 bounded run history。群組／mailbox 可提出自身排程 create/update（固定時區的 cron／alias／@every、單一 GitHub／Slack／Linear／Sentry／PagerDuty trigger 或 1–8 個平面時間／事件 OR 條件）、pause/resume/delete；ID、完整 before/after 任務與觸發條件／enabled 核准後套用，防 stale／Stop／帳號切換／寫檔失敗；費用防護不由模型解除；修改保留現有歷史，delete 不取消已執行／已排隊工作，歷史留存但無還原入口。GitHub 可篩選 repo／事件／作者與操作人／CI 分支，須既有已驗證連線，不會自動安裝 webhook；CI 只看個別 push workflow 完成，Slack 支援普通訊息／App 提及／關鍵字／新增表情的明確 ID 或 * 篩選，不支援名稱解析或自身身分；已支援時間／事件混合 OR 的模型 create/update，每項時間皆固定時區並驗證 366 天內可執行，核准明示事件／手動執行重設間隔；Linear 支援 issueCreated／statusChanged／endOfCycle 與 teamIds／projectIds／新 statusIds／cycleIds 的明確 UUID 篩選；statusIds 僅用於狀態變更、cycleIds 僅用於週期完成，原生週期拒絕非空 projectIds；Sentry 已支援五種 issue case／issueAny 與精確十進位 projectIds 篩選、完整核准及生命週期防護；PagerDuty 支援四種 incident case／incidentAny 與精確、區分大小寫的 serviceIds 篩選、完整核准及混合 OR；尚缺 checks 彙整及其他 event/platform 的模型 create/update。 | complete | 非並行完整回歸 134 XCTest、812 Swift Testing 通過；並行測試穩定性限制詳見協作核對紀錄 |
| AUTO-03 | `PlatformTriggers.swift`、`AutomationIngress*`、`EventBatcher.swift` 與 connector integration 提供 matching／signature／去重及 audit 基礎。Linear 已補 issueCreated／statusChanged、team/project/new-status 篩選、送達識別、signed-body timestamp／digest 防重播、模型 create/update 與七語言核准；保留舊儲存，不自動遷移排程。Sentry 已補五種 issue case／issueAny、data.issue.project.id 精確篩選、body digest 作 nonce 及事件 ID、重開與 history 去重；Request-ID 僅供診斷，無簽章時間戳可證明新鮮度，也不是永久防重播；舊 raw-action 定義保留原有比對。已接上 Sentry 自身模型提案、完整核准、精確 projectIds 與平面混合 OR；PagerDuty 已補四種 incident case／incidentAny、V3 resource／type 驗證、精確 service_reference ID 篩選，body digest nonce 及已簽章 event.id history 去重；僅接受 v1 簽章候選，delivery ID 僅診斷，occurred_at 不當送達新鮮度證據；保留舊 raw-event 定義。已接上 PagerDuty 自身模型 create/update、完整核准與平面混合 OR，serviceIds 最多 50 個精確且區分大小寫的 ID，不作名稱查找或隱含連線。本輪補原生 Cycle/update 的 null→completedAt 轉換、team/cycle UUID 篩選與 cycle＋完成時間的 history 去重；不把單純日期到期當事件，原生無 project 歸屬時拒絕專案篩選。已接上 cycle 自身模型 create/update、完整核准及混合 OR，原始 cycleIds 清單最多 50 個 UUID，非空 projectIds 與不適用的 statusIds 直接拒絕；沒有自動遷移／啟用舊定義。Teams 原生入口已分離傳輸簽章與使用者登入，Graph UUID 用 aadGroupId、Bot ID 保留獨立比對；僅分類完整的頻道 message，非訊息／超限上下文不觸發，以 tenant/team/channel/conversation/activity 身分 hash 去重。保留 blockUnauthenticatedUsers 的條件一律不執行；未證明主文時須有明確文字篩選，既有權限不放寬。手動編輯器保留預設登入限制並明示不能執行，模型 Teams 提案仍未開放。尚缺平台專用編輯器及原版雲端等完整語意；GitHub 仍為個別 push workflow 而非 checks 彙整，Slack 仍無名稱／人類身分映射。不能將 generic matcher 或歷史 ingress 測試視為原版各事件完整還原。 | partial | `TeamsRoutineEventTests`、`PagerDutyRoutineEventTests`、`SentryRoutineEventTests`、`LinearRoutineEventTests`、`AgentRoutineChangeTests` 與 App fixtures；Teams 與既有 ingress／localization 聚焦、非並行完整回歸（134 XCTest、822 Swift Testing）、原生建置與嚴格簽章通過；非 live 平台驗收 |
| AUTO-04 | `AgentWorkflowModel.swift`、`AgentWorkflowStore.swift`、`AgentWorkflowRuntime.swift`、`WorkflowService.swift` 與 `WorkflowAppIntegration.swift` 提供 SKILL/workflow import/codec、trigger/action validation、run history/cancel/replay；Teach recording queue scope 與 attachment-backed scoped auto-dispatch 已接線。 | complete | final gates passed |

### 8. Computer / local execution

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| COMP-01 | `FiliconLocalTools`、`FiliconLocalToolHelper`、`FiliconLocalToolXPCService`、`ProcessSupervisor.swift` 與 `RequestGuard.swift` 提供 command/read/write/send-input、permission gate、generation/timeout/termination 與 XPC isolation。 | complete | final gates passed |
| COMP-02 | `HTTPSRemoteComputerBackend.swift`、`RemoteIsolation.swift`、`RemoteComputerControlsView.swift` 與 lifecycle coordinator 提供 HTTPS remote runtime status/start/update/recreate/recovery、resource caps、filesystem boundary、terminal/file transfer。 | complete | final gates passed |
| COMP-03 | `ScreenCaptureKitBackend.swift`、`VNCTrustedBridge.swift`、`VNCIsolationPolicy.swift`、`VNCTakeoverController.swift` 與 `VNCWebView.swift` 提供 trusted preview、takeover/handback、clipboard/input guard、session lease 與 reconnect。 | complete | final gates passed |
| COMP-04 | `TeachRecordingController.swift`、`TeachSensitiveMasking.swift`、`ScreenCaptureKitBackend.swift` 與 workflow integration 提供 private-monitor recording、600-second cap、mask/pause sensitive windows、save/discard、recovery/quarantine 與 update confirmation。 | complete | final gates passed |

### 9. Account / settings

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| ACCT-01 | `KeychainCredentialStore.swift` 與 `FiliconAccount/KeychainSecretStore.swift` 提供 provider/account-scoped secrets、missing/isolation handling；UI 僅顯示狀態。 | complete | final gates passed |
| ACCT-02 | `FiliconSettings/SettingsStore.swift`、`SettingsModels.swift`、`SettingsView` 與 `AppModel.swift` 提供 provider/router/model、theme/timezone、permission、usage、update、sidebar、validation、migration 與 atomic save。 | complete | final gates passed |
| ACCT-03 | `FiliconAccount/Authentication.swift`、`Connection.swift`、`HTTPSAccountProvider.swift`、`AccountExperienceView.swift` 提供 browser OAuth、restore/refresh/logout、profile、entitlement、usage、feedback 與 access/error state。 | complete | final gates passed |
| ACCT-04 | `FiliconSecurityKey`、`FiliconAutoReview`、settings integration 與 account UI 提供 WebAuthn/security-key consent、auto-review approval、notifications、local-tool settings 與 account-scoped persistence。 | complete | final gates passed |

### 10. Notifications / deep links / window

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| NOTIF-01 | `FiliconApp.swift`、`WindowStateController.swift` 與 `FiliconSettings/WindowStateStore.swift` 提供 single-window lifecycle、native commands、traffic-light window 與 restore state。 | complete | final gates passed |
| NOTIF-02 | `SystemNotifications.swift`、`AgentNotificationPolicy.swift`、`NotificationThrottle.swift`、`InAppNotificationCenter.swift` 與 Dock projection 提供 permission、needs-input/done/error notifications、focus action、throttle、tray、badge。 | complete | final gates passed |
| NOTIF-03 | `DeepLinks.swift`、`WorkspaceNavigationBridge.swift` 與 `FiliconApp.swift` `onOpenURL` 提供 strict allowlist parsing、cold-start queue、dedupe、bounded pending queue 與 route dispatch。 | complete | final gates passed |
| NOTIF-04 | `WindowStateController.swift`、`WindowStateStore.swift` 與 `WorkspaceNavigationState.swift` 持久化 bounds/maximized/navigation history，並提供 reload、error recovery 與 out-of-bounds handling。 | complete | final gates passed |

### 11. Persistence / search / recovery

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| PERS-01 | `ConversationRepository.swift`、`ConversationTranscriptService.swift`、`TranscriptEventHub.swift` 與 SQLite schema 提供 transactional transcript/session/event lifecycle、FTS、memory buffer 與 replica recovery。 | complete | final gates passed |
| PERS-02 | `AttachmentLifecycle.swift`、`AttachmentReferenceRepository.swift`、`AttachmentStore.swift` 與 message model references 提供 attachment bytes/metadata/index、dedupe、reference counts、GC 與 crash-safe commit。 | complete | final gates passed |
| PERS-03 | `StartupDataRoot.swift`、`ConversationRecovery.swift`、`StorageQuota.swift`、`SettingsStore.swift` 與 `ConversationStore.swift` 提供 canonical-root migration、corrupt quarantine、atomic settings/blob writes、quota 與 idempotent recovery。 | complete | final gates passed |
| PERS-04 | `GlobalSearch.swift`、`GlobalSearchService.swift`、`Pagination.swift`、`ConversationPaginationState.swift` 與 startup recovery 提供 message/media/roster search、paging、index fallback、rebuild、retry 與 visible recovery state。 | complete | final gates passed |

### 12. Updates / distribution

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| UPD-01 | `scripts/package-app.sh`、`scripts/verify-package.sh`、`Package.swift` 與 signed app bundle 提供 clean build/package、nested helper/XPC assembly、metadata、hardened runtime flags 與 strict verification。 | complete | final gates passed |
| UPD-02 | `FiliconUpdater/UpdateService.swift`、`UpdateManager.swift`、`UpdateConfigurationResolver.swift`、`BackendUpdateRequirement.swift`、`UpdatePresentation.swift` 與 `UpdateIdleMonitor.swift` 提供 channel/default/runtime checks、signed feed resolution、download/verify/stage/install、idle/required UI；runtime/default/backend requirement signal 已接線。 | complete | final gates passed |
| UPD-03 | `scripts/release-macos.sh`、`generate-update-feed.swift`、`generate-update-feed-key.swift`、`read-update-feed-key.swift`、`verify-release-artifacts.sh` 與 updater verifier/install pipeline 已完成；本機 signing key 已安全存入 Keychain，`filicon-notary` 已以 App Store Connect Team Key/issuer 驗證；`v0.18.0` 已發布 notarized/stapled ZIP、DMG 與 signed update feed 至 [GitHub Release](https://github.com/irons163/filicon-bot/releases/tag/v0.18.0)。 | complete | Apple notarization + Gatekeeper/stapler + remote checksum/feed signature passed |
| UPD-04 | Electron/ASAR/preload、Windows installer/overlay 與來源 daemon wiring 是來源 runtime 細節，不是 macOS 原生產品行為；Swift package 以原生 targets 取代它們。 | NA | final gates passed |

## Verification note

歷史 verifier 紀錄：553 tests（420 Swift Testing、133 XCTest）、WAE、release build，以及 `v0.18.0` release `0.18.0-184` 的簽署／發佈檢查曾通過。這些不是本輪重新驗證，也不能證明功能完整對等。舊版「沒有剩餘 parity gap」結論已撤回；目前至少有上述 AGENT-01/02/04 缺項，其他區域仍需逐項端到端核對。`UPD-04` 維持 NA。
