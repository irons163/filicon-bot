# Filicon / Grok Bot 0.18 功能 parity matrix（current implementation）

本矩陣保留固定的 48 個 parity ID，對照目前 macOS Swift 實作。`complete` 表示該列所述能力有歷史實作證據，不代表原版所有細項均已重新核驗；`partial` 表示仍有功能、接線或驗證缺口；`NA` 表示該列是來源 runtime 的實作細節，不是 macOS 產品行為。這不是「原版功能全部都有」的保證。

表格預覽安全修正（2026-09-24）：CSV／TSV 改為直接解析 gate 已驗證資料；XLSX 使用同份資料建立 mkdtemp 私有目錄中的暫存 archive，系統 ZIP 工具不再開啟原預覽路徑，結束後清理副本。保留檔案大小、展開量、路徑／XML／列欄及不執行公式的限制。取消後不呈現遲到結果。23 項附件聚焦測試通過；不宣稱防禦相同使用者惡意程序對所有暫存檔的攻擊，影音／Quick Look URL API 仍另列核對範圍，parity 計數不變。

PDF 預覽安全修正（2026-09-24）：PDF 畫面、頁數與文字擷取改用 gate 已驗證 Data 建立的同一份 PDFDocument，不再重新以 URL 讀檔。原檔替換／刪除後預覽仍是原快照；匯出文字前仍須重驗檔案。切換文件即使搜尋字詞相同亦重算高亮，避免舊搜尋結果殘留。22 項附件聚焦測試、原生 Debug build、deep strict 簽章與封裝通過；影音／Quick Look URL 載入仍需另行核對，未增加 complete 列。

圖片主檢視器安全修正（2026-09-24）：主圖不再於完整性 gate 通過後用 `NSImage(contentsOf:)` 重讀路徑，改以 gate 的已驗證 Data 快照解碼。圖片來源被替換／刪除不會讓解碼器讀到另一份內容；重新驗證竄改檔仍拒絕，空白／無效圖片維持錯誤狀態。非圖片不保留額外 Data，PDF／影音／Quick Look 的 URL API 仍有另外的核對範圍，不宣稱全部附件 parser 均無路徑競態。31 項聚焦測試、七語言圖片渲染測試、原生 Debug build 與 deep strict 封裝檢查通過；整體 parity 計數不變。

文字內圖片描述（2026-09-24）：`SendMessage.images` 現可混用舊版 ID 字串與 `{image_id,alt}`，每張描述沿用 500 字／2,000 UTF-8 bytes 與控制字元限制；整批圖片和描述經預覽核准，回條重播驗證全部描述，不能藉換描述重複發布。信箱重開保留描述，群組沿用已驗證的 annotation 保存路徑。完整非並行回歸 exit 0，原生 Debug 建置、deep strict 簽章與封裝通過。這取代下方歷史紀錄的「inline 逐張 alt 尚缺」；任意 URL／本機檔案、影片等附件語意仍未完成，矩陣計數不變。

解鎖後驗證（2026-09-24）：確認 macOS `IOConsoleLocked = No` 後，對 `fcc8354` 重跑完整非並行 `swift test`，exit 0。先前圖片、工作流程 EPERM 與共享聊天室 malformedState 未再出現，圖片描述增量的最終回歸阻礙已解除；下方失敗紀錄保留為前次鎖定時的結果。沒有降低檔案保護、重啟使用者 App／Xcode、push 或真實帳號操作。測試通過不代表其餘 parity 缺口完成，矩陣仍 43 complete／4 partial／1 NA。

圖片描述增量（2026-09-24）：目前單張 `SendMessage(type:attachment)` 接受可選 `alt`，最多 500 字／2,000 UTF-8 bytes，拒絕控制字元。描述顯示在核准預覽、懸停、圖片檢視與輔助閱讀，隨群組／信箱保存；圖片本體與來源 metadata 仍須完全相符，只有描述可變更，重送亦驗證描述。21 項 storage/delivery 與 19 項 App 測試曾分別通過；七語言渲染、原生 Debug 建置及 deep strict 封裝檢查通過。完整回歸未通過：工作流程暫存檔 EPERM、共享聊天室 malformedState 等失敗仍需追查；最後重跑圖片聚焦套件亦出現圖片暫存檔 EPERM 和連帶斷言失敗，尚無最後一次全綠結果。多張圖片逐張描述與其他附件類型尚未補齊，整體計數不變。

附件視窗增量（2026-09-23）：將附屬 sheet 換成可調整大小的獨立原生視窗，接上 macOS 全螢幕按鈕／Control–Command–F；七語言新增 Full Screen 字串。視窗關閉帶 preview ID，避免遲到回呼誤關新預覽；主視窗關閉與帳號撤銷會關閉附件並沿用暫存清理。21 項聚焦測試通過，包含隱藏 NSWindow 的全螢幕設定、同一預覽更新、替換、主視窗關閉及帳號清理；七語言各 1,661 keys、零缺漏。沒有啟動使用者 App，實際 macOS 全螢幕動畫未驗收；原版 lightbox 外觀與 alt caption 仍非完成，整體計數不變。

圖片呈現增量（2026-09-23）：群組／信箱及核准預覽共用單張放大、多張雙欄圖集；圖片寬高共同限制，避免窄欄溢出，草稿仍保留捲動區。18 項圖片 App 聚焦測試與七語言渲染通過，原生 Debug 建置成功。這批只補呈現，不包含來源 alt caption／全螢幕檢視、任意檔案／URL／影片。`AGENT-02` 仍 partial，整體計數不變。

接續圖片檢視增量：上述圖片已接上點擊開啟既有原生附件檢視器，包含縮放、圖集切換、另存副本。使用 agent image store 的帳號隔離及完整性檢查，不拿單聊附件 store 代讀；關閉／帳號切換會撤銷待處理開啟並移除預覽副本。App 測試模組 **368 項／49 suites** 非並行通過，含毀損拒絕及清理。這是原生 sheet，並非來源的全螢幕 lightbox，也尚未支援模型 alt caption。

圖片檢視修正（2026-09-23）：發現原有 `scaleEffect` 不會同步擴大可捲動範圍，且捏合每次重新從 1 倍開始。改為保持長寬比的實際 layout 尺寸、累積手勢比例（0.1–8 倍相對初始適配尺寸）、七語言既有「縮放／重設」控制列。18 項檢視器測試、七語言隔離渲染（法文抽查）、原生 Debug build 與嚴格簽章／封裝通過。未在使用者 App 做實際手勢驗收；不計為新增完整 parity 列，原版全螢幕 lightbox／alt 等缺口仍保留。

圖集安全補強（2026-09-23）：底部縮圖原先直接按路徑解碼，現在先在背景讀取並驗證 metadata 雜湊／長度，再只解碼同一份記憶體資料；取消後不套用結果。共用驗證讀取改用 `O_NOFOLLOW`／`O_NONBLOCK` 與 descriptor `fstat`，拒絕非一般檔案、超過現有附件上限及讀取長度改變。20 項聚焦測試（含同長度竄改、symlink、FIFO、圖片開啟清理）、原生 Debug build 與嚴格簽章／封裝通過。這批是縮圖安全修正，不代表其他原生媒體 parser 的路徑重開行為皆已消除，也沒有新增原版功能完成列。

再校正（2026-09-23）：`AGENT-02` 的 `SendMessage` 已可用 `{type:"attachment",image_id:"本輪ID"}` 發布**單張、無文字**的本輪輸入圖片，群組與代理人信箱均需即時圖片預覽核准；群組可取保存回條，信箱持久化於原 incoming delivery。拒絕、停止、過期圖片與非本輪 ID 不發布，圖片不被最後一段文字重複。下方較早快照的「均需文字／獨立附件全缺」以此段為準：任意檔案／URL、影片與來源原版完整附件語意仍缺。隔離聚焦、完整非並行回歸（exit 0）、原生 Debug 建置、deep strict codesign 與 package verifier 已通過；未做 live App 點擊或真實帳號／模型驗收。整體仍 **43 complete／4 partial／1 NA**。

最新校正（2026-09-23）：`AGENT-02` 的群組 `sand-msg` 連結早已有安全跳轉，本輪加上有效引用的 chip-like 行內底色／字重；原版圓角 chip 的精確樣式仍未還原。`ba6b915` 已補群組背景 peer wake 引用，`5b90593` 已補其選項問題，因此下方較早快照所列的「背景引用／提問」或把所有 chip 當成功能缺口，應按此段修正。mailbox／單獨聊天引用與提問仍缺。這批聚焦測試和原生 Debug 建置／簽章／封裝通過；完整回歸因 macOS 暫存檔 `EPERM` 未通過，不能當成全套驗證成功。矩陣仍為 **43 complete／4 partial／1 NA**；詳見[最新協作核對](Agent-collaboration-parity.md)。

後續同日驗收：修正背景群組問題卡工具提示的舊限制敘述，實際背景問答測試通過。macOS 暫存檔恢復可讀後，完整非並行回歸重新執行通過（exit 0），原生 Debug 建置／嚴格簽章／封裝檢查再次通過。前次 `EPERM` 失敗仍是紀錄中的環境事件；不等於 live 帳號、模型或 App 點擊驗收。

最新驗收（2026-09-23）：群組引用回覆已提交 `e5cad3c`。本輪接上可選的代理人記憶建議：只在完成的前景群組回合做額外無工具模型請求；候選事實逐筆審核，核准後才進入該帳號／代理人的私人記憶，預設關閉。停止、帳號／成員切換、封存或停用時拒收遲到候選；舊 store 可省略新欄位。完整預設並行 **135 XCTest、1,107 Swift Testing／125 suites**（App 363／49 suites，42.129 秒）通過；七語言各 **1,660 keys／零缺漏**，14 張審核卡預覽及繁中／法文抽查通過。原生 Debug 建置、deep strict codesign、package verifier 通過；兩項 opt-in live Codex 仍跳過，沒有真實 App 點擊、付費模型或 live 帳號驗收。原版自動記憶改寫／episode／archive、跨 session/fork、chip、背景引用／提問、外部 channel、獨立附件與安全憑證請求等仍缺，整體 **43 complete／4 partial／1 NA**。詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

接續驗收（2026-09-23）：`AGENT-02` 的**群組背景 peer-message wake** 現可在來源對話工具權限下，引用目標群組最近 40 筆可用訊息並取得保存後的 messageID／shortAddress 回條。不可引用來源其他群組，不能繼承人類串接目標或讀歷史圖片；接續增量亦已接上背景群組選項問題，回答時在新的人類群組回合僅續接原提問者。mailbox／單獨聊天引用及提問仍缺。本次完整非並行回歸 **135 XCTest、1,110 Swift Testing／125 suites** 通過；原生 Debug 建置、嚴格簽章與封裝檢查通過。前批一次並行聚焦跑法的既有圖片暫存檔 `EPERM` 與後續重開失敗另記，不當作通過。整體仍 **43 complete／4 partial／1 NA**。實作與測試範圍見 [協作核對紀錄](Agent-collaboration-parity.md)。

2026-09-21 再次核對後，為 43 筆 `complete`、4 筆 `partial`、1 筆 `NA`（`UPD-04`）。`AUTO-03` 因已確認平台事件語意缺口，維持 partial；Linear 已補事件分類、送達識別、防重播、受核准模型提案與新狀態篩選，Sentry 已補五種 issue case／issueAny、正確 project ID 篩選與 body digest 去重，已接上模型 create/update、平面混合 OR 與七語言完整核准；PagerDuty 已補四種 incident case／incidentAny、精確 service ID 篩選、僅 v1 簽章候選與 signed-body／event.id 去重，已接上自身模型 create/update、完整核准及混合 OR；先前已補原生 Cycle/update 的明確完成轉換、team/cycle UUID 篩選和完成身分去重；已接上 endOfCycle／cycleIds 自身模型提案、混合 OR、七語言完整核准與生命週期防護。上一輪修正 Teams 傳出 webhook：不再以 HMAC 當使用者登入、分離 Graph/Bot 團隊 ID、拒絕非訊息活動、加入有範圍的訊息身分去重；缺少使用者／主文證據時保守不執行，不等於已還原 Teams 雲端功能。原生無專案關聯的週期提案拒絕非空 projectIds；手動新增 Linear／Sentry／PagerDuty 已有事件選單與精確篩選；既有 cron／五平台／平面 OR 已可手動編輯；GitHub 改用 14 種事件勾選，Slack 使用對話 ID、獨立關鍵字／表情欄位，拒絕靜默丟棄事件／截斷篩選；不支援的格式仍僅名稱／任務可改、trigger 原樣保留。原生 generic connector 本輪補嚴格 JSON 篩選、型別／精度比對與既有條件編輯；損壞條件不再變成 match-all，舊定義原樣保留。這是 Filicon-native 安全補強，模型 generic create/update 仍拒絕；Teams 已補保留登入限制的 literal 條件手動編輯；原版雲端等完整語意仍未還原。`AGENT-01` 已補受審批的模型 `CreateAgent`／`UpdateAgent`、own-profile `update_state(profile.set)` 及 own-agent `memory.write/forget`；先前已接上明確核准的 `scope:user` 共享事實與 note 分級、正規化去重及有預算的記憶召回，當時跨重啟與完整套件通過。先前補依當前使用者／peer 訊息的有界關鍵字相關性召回，維持帳號／私人／共享隔離與原始預算。本輪接上只讀 `SearchMemory`，讓模型分頁搜尋已核准但未注入的原始事實；先隔離帳號／私人範圍，游標綁 owner／turn／session，資料改變即失效，不授予內部檔案存取。這是 reference Read/grep 舊記憶的 native 對應，非原版同名工具、自動抽取或語意搜尋。仍限制在有 agent 身分的群組／mailbox，不改私人 persona，現已補需成員資格的 project 記憶但仍未涵蓋其他 update_state 路由，因此維持 partial。其他列的驗證欄保留歷史紀錄，不表示本次重新驗證；先前解鎖後完整回歸通過（134 XCTest、861 Swift Testing／98 suites）；本輪驗證見最新協作核對紀錄。鎖定時曾有受保護檔案重開失敗及既有測試索引越界中止，未弱化檔案保護；解鎖重跑未再出現，不把此誤報為並行 flake。更早的並行時序穩定性問題仍保留。本輪另補共用 ingress 安全重試、等待金鑰期間的路由／listener 撤銷、pending nonce 保護及 connector-scoped 佇列去重；不是持久佇列或 exactly-once。細項見 [協作核對紀錄](Agent-collaboration-parity.md)。

## Matrix

上一輪完整重跑通過（134 XCTest、898 Swift Testing／102 suites），但首次執行的既有 stdin 輸出測試曾收到空結果。本輪已以受控時序重現並修正 `ProcessSupervisor` 的提前完成：等待雙管線輸出交付、限制收尾等待，且將 terminationError 正確映射為失敗工具結果。不是僅靠重跑通過。最終驗證及背景子孫程序等限制見最新協作核對紀錄；其他既有並行風險不宣稱一併根治。

### 1. UI surface

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| UI-01 | `Sources/Filicon/FiliconApp.swift`、`AppModel.swift`、`WorkspaceNavigationBridge.swift` 提供 app root、sidebar、workspace route、commands 與 deep-link dispatch。 | complete | final gates passed |
| UI-02 | `FiliconApp.swift` 掛載 chats、search、agents、groups、automations、channels、shared rooms、MCP、computer、plugins、account 與 update surfaces。 | complete | final gates passed |
| UI-03 | `FiliconApp.swift` composer、`ComposerDraftStore.swift`、`AttachmentLifecycle.swift` 與 `FiliconVoice` 提供 draft、file/drop/paste staging、voice、send/queue/cancel。 | complete | final gates passed |
| UI-04 | `TranscriptPresentationState.swift`、`TranscriptRichPresentation.swift`、`TranscriptCardPresentation.swift`、`TranscriptCardActionRouter.swift` 與 `RichMarkdownView.swift` 提供 rich transcript、tool/thinking cards、reaction、reply、resend/delete 與 safe links；原生 Markdown 依 block intent 保留段落、標題、清單／引用層級及 hard break，inline 屬性與連結限制不變，非完整 CommonMark/GFM 或原版 pixel-perfect 排版。 | complete | `RichMarkdownViewTests`／`GroupReplyAppTests`，本輪完整回歸與七語言畫面驗收見協作紀錄 |

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
| AGENT-01 | `AgentService`、`Models`、`AgentsWorkspaceScreen`、`AgentAvatarStore` 提供 UI profile CRUD。`AgentManagementSession` 在群組／mailbox 接上 `CreateAgent`／`UpdateAgent`／own-profile `update_state(profile.set)`，完整欄位審批、停止撤銷、共用四次上限、重播防護與原子儲存。只改名稱／公開摘要；新增沿用發起者模型，不複製私人上下文或自動加入群組。own-agent `memory.write/forget` 已逐次審批、帳號＋代理人隔離、跨群組／mailbox 持久化。另有 `scope:user` 的帳號內共享事實，核准列明所有現有／未來代理人及其模型，舊記憶維持私人；UI 可檢視／忘記，模型只能刪自己的記錄。note 以較低重要性參與近期排序，私人／共享各有獨立召回預算與重複摺疊，省略不刪除原記錄。已接上當前訊息的有界關鍵字召回（英／繁中／簡中／法／西／日／韓例句），群組與 peer/mailbox 使用獨立 query snapshot。本輪新增 `AgentMemorySearch`／`SearchMemory` 只讀搜尋已核准事實，最多八筆／8 KiB JSON，32 次獨立讀取額度；空查詢可瀏覽，字串子串比對不做 regex／語意搜尋，來源和 canForget 保留。cursor 綁 owner／run／session／selected store fingerprint，變更後拒絕 stale；不查原始記憶檔／舊對話／私人 peer／其他帳號，不增加自動儲存或分享。新增 own-avatar set/clear：逐次預覽核准，只能選內建 pet_id 或恢復 Codex，與 profile／memory 共用四次額度，不接受原版 host/box path 圖片來源。群組／mailbox 另接 own-routine create/update/pause/resume/delete：逐次完整 before/after 核准，建立／修改支援固定時區 cron／alias／@every、單一 GitHub／Slack／Linear／Sentry／PagerDuty trigger 或受限 Teams 定義 或 1–8 個平面時間／事件 OR 條件，省略欄位與歷史保留，核准後開始且不補跑；delete 移除定義、歷史保留。不能越過費用防護；GitHub 需既有已驗證事件入口，CI 僅個別 push workflow 完成而非 checks 彙整；Slack 限對話 ID／*，不解析名稱或篩選自身身分；時間與事件可混合且逐項固定時區，揭露 OR／間隔共用基準；已補 Teams 的精確 scope／literal 定義提案，保留登入限制、事件仍不執行；其他平台與 generic event 的模型建立／修改仍缺。本輪新增 own-workflow write：群組／mailbox 可提出自身本機手動單一 prompt 的建立／全文改寫，名稱／說明／body 必填且 body 最多 8,000 UTF-8 bytes；完整 before/after 核准明示本機流程庫共享與既有／未來引用影響，並展示已知直接引用。保留 owner／trigger／enabled／歷史，不立即執行；同 store revision／Stop／帳號切換、重播及共用四次修改額度防護，拒絕 peer／source-linked／managed／多步驟／action／scheduled 定義及權限欄位。另接自身 workflow delete：只接受 target/action/精確 ID，獨立 destructive 全文核准、同樣 owner/revision/lifetime 與四次額度防護；保留可依 ID 檢視的 run history 和已取得內容的執行，其他 workflow/routine/schedule/file/source/permission 不變，未來引用可能失敗或省略內容。流程庫不是帳號隔離記憶，也非跨程序版本鎖。新增 own-settings set：僅 JSON boolean notify_on_updates，獨立明確 before/after 核准與手動切換、專用持久化 revision 防 ABA／舊 editor 覆蓋；綁定 agent roster 系統通知，不改對話通知、核准卡、未讀／Dock、任務或權限。舊資料預設開啟；local profile 非 account 隔離。hidden_from_sidebar 明確拒絕。新增 own-channel disconnect：Slack／Discord 自身單一連線、歧義拒絕、完整計數核准、資料 revision／lifetime 與失敗回滾；移除本機連線及其紀錄，保留聊天／附件／鑰匙圈，不撤回遠端授權或已開始傳送。新增 own-project create/join/leave：固定帳號／自身身分，metadata 與完整成員資格核准；create existing 不覆蓋 metadata、leave 不刪專案；最多 50 個／帳號，完整快照與 revision 防 stale/ABA、Stop／帳號／封存／失敗回滾，共用四次額度。僅帳號隔離的成員資料，沒有新增檔案授權／群組／任務或私有記憶分享；不建立 reference 專案目錄。另補 `scope:project` 共享事實：同帳號已加入成員召回／搜尋、寫入／忘記逐次核准，模型只刪自己的記錄，人類可管理已離開作者的事實；成員快照／revision 防 stale/ABA，離開後停止讀取、不刪記憶，重新加入恢復；獨立有界召回與每專案跨作者共用儲存容量，私人記憶不自動分享。本輪補預設關閉、逐筆核准的前景群組記憶建議；候選不參加召回，僅核准後成為該帳號／代理人的私人事實。仍缺原版自動改寫／episode／任意 archive 檢索、其他入口／update_state 路由與完整 persona/runtime。 | partial | `AgentProjectMemoryTests`、`AgentProjectChangeTests`、`AgentChannelDisconnectionTests`、`AgentSettingsChangeTests`、`AgentNotificationProjectionTests`、`AgentManagementSessionTests`、`AgentAvatarChangeTests`、`AgentMemoryTests`、`AgentMemoryRecallTests`、`AgentMemorySearchTests`、`AgentMemorySuggestionTests`、`AgentMemorySuggestionAppTests`、`AgentManagementAppIntegrationTests`、`AgentWorkflowWriteTests`、`AgentWorkflowWriteAppTests`；本輪驗證狀態見協作核對紀錄 |
| AGENT-02 | `GroupService.swift`、`GroupConversationResponder.swift` 提供三輪接續、角色/增量上下文、去重、PASS/失敗、stop/cancel。`AgentUserMessageTool` 已接線 `SendMessage`：一般群組可發布本輪 host 綁定且使用者指定給自己的圖片；mailbox/peer wake 可發布本次 incoming 圖片，均需文字與獨立預覽核准。群組原子保存 room reply；canonical mailbox 先持久化發布紀錄，再鏡射來源 UI。Stop／失敗／重啟保留，每 turn 至多兩則，不重複 final text、不新增回覆成員。一般群組支援 1–6 選項提問、自訂文字、略過、保存／重啟後僅續接原作者；回答不等於工具核准，帳號／成員／封存失效及重複送出有防護。文字／核准圖片與 widget 可帶 reply_to，限 host 最近 40 筆同群組目錄的可用 UUID 或持久短位址；host 依完整歷史分配 t0u、t0s0 等，不因 prompt 截斷重新編號。先解析成 UUID 再防重播，格式錯誤／歧義／越界位址拒絕。固定作者、原子保存引用、舊資料相容；卡片顯示原文並可點回，原文缺失停用，不擴大收件者、不答覆問題、不載入歷史附件。引用問題保存後暫停，回答僅續接提問者而非原文作者，關係重啟保留。停止／帳號／成員撤銷、無效目標及保存失敗不回退普通訊息或問題。一般群組文字另支援 sand-msg 行內跳轉，沿用持久短位址，只定位同群組較早且唯一的原文；無效標籤不開外部 App、不讀附件或授權工具。新增保存後成功回條：固定作者／群組的 messageID 與有效 shortAddress 由 host 回傳，最多兩筆新訊息可加入同回合目錄，文字／核准圖片／提問可引用剛發布的內容；舊無回條 callback 不捏造位址，保存失敗不耗額度，儲存後取消仍記錄冪等結果；提問照常暫停。新增一般群組折疊討論串：完整歷史的一次掃描投影歸併有效巢狀引用，計數與暫存展開狀態、引用定位先展開；問題／工具 pending 時強制開啟。損壞／循環／前向／歧義／跨群組引用留主時間線，無資料遺失或權限變更。新增人類回覆 context menu／hover 入口及可取消預覽、群組獨立草稿與 account 清理；保存時拒絕壞 target、不回退普通發送。同回合模型 publication／final 自動引用最新人類回覆，明確目標可覆蓋；串內問題答案及續接保持串接，一般新訊息回主線。舊 target 附有界 quotation、不讀歷史圖片；文字／圖片輸入與三種撤銷已有 fixture 回歸。仍缺原版 chip、跨 session/fork、mailbox／背景引用及提問、外部 channel、獨立附件、安全遮罩憑證請求及供應商 cloud-agent 卡；不能以一般 UI 已有回覆／頻道視為已接線。仍非完整圖片來源或原版 runtime。 | partial | `GroupCollaborationTests`、`GroupToolExecutionTests`、`AgentBackgroundExecutionTests`、`AgentUserMessageToolTests`、`AgentPublicationReceiptTests`、`AgentImageAppIntegrationTests`、`AgentQuestionTests`、`GroupQuestionAppTests`、`AgentReplyTests`、`AgentQuestionReplyTests`、`GroupMessageAddressTests`、`GroupMessageReferenceTests`、`GroupThreadProjectionTests`、`GroupUserReplyTests`、`RichMarkdownViewTests`、`AgentImageMessagingTests`、`GroupReplyAppTests` 及工具迴圈暫停測試；本輪完整回歸與缺口核對見協作紀錄 |
| AGENT-03 | `FiliconSharedRooms` 的 file/HTTPS transports、`SharedRoomsWorkspaceView.swift`、`FiliconChannels/ChannelService.swift` 與 REST connectors 提供 room invite/approval/member lifecycle、channel inbound/outbound、attachments、reactions、OAuth 與 delivery retry。已修正 channel 保存回滾、斷線與暫停後 listener 生命週期、非同步 profile 的配置世代與最新請求防護、重疊 flush／傳送前持久化；新增模型 own-channel disconnect，僅自身唯一 Slack／Discord 連線，獨立核准與 revision／lifetime 防護，保留鑰匙圈與遠端授權；不宣稱 live 帳號驗收。 | complete | 歷史列能力保留；本輪頻道／管理聚焦 64 項、完整 135 XCTest＋965 Swift Testing、原生 build／嚴格簽章及七語言核准卡驗證通過；先前 Xcode 初始化阻擋已解決，見最新協作紀錄 |
| AGENT-04 | `AgentMessagingSession` 提供固定寄件身分、完整 payload approval、durable queue、recipient/reply wake、權限/停止/逾時/上限。手動訊息已接上背景推論與審批 UI。已補審批後貼入自己所屬其他群組的文字訊息與房間回覆；忙碌目標拒絕，兩群組／六委派上限。`AgentConversationStore` 持久化 account/origin/agent 隔離上下文。App 共用 `AgentExecutionScheduler` 將群組、mailbox、子任務、自動化、workflow、channel reply 依 agent 串行（一般工作 FIFO），取消等待不影響其他 owner，host 工具清理後才放行。已補明確核准的 peer/manual priority：來源 drain 後可中斷背景 peer/group/排程自動化，使用者回合受保護；工具清理後才交棒、不重播。群組 priority 不支援，也非 enqueue 當下立即中斷。仍非跨全部 DM/群組統一私人記憶或完整原版 runtime；手動訊息及一般群組可輸入有界 PNG/JPEG，當輪圖片 ID 可經審批後轉交單一 peer 或 SendMessage 發布。歷史圖片不自動重播；任意圖片來源、跨程序與重啟排程仍缺。參考的 postToGroup 也是文字入口，不能將跨群組圖片視為已確認原版缺項。 | partial | `AgentMessagingSessionTests`、`SendToAgentAppIntegrationTests`、`AgentGroupMessagingTests`、`AgentGroupMessagingAppTests`、`AgentBackgroundExecutionTests`、`AgentConversationStoreTests`、`AgentExecutionSchedulerTests`、`AgentImageMessagingTests`、`AgentImageAppIntegrationTests`、`GroupImageAppTests` |

### 7. Automations

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| AUTO-01 | `FiliconAutomations/CronSchedule.swift`、`AutomationService.swift` 與 `Scheduler.swift` 提供 cron/alias/`@every`、timezone/DST、next-run、durable claim、cancel/reconcile 與 restart recovery。內部平面 `.anyOf` 已補最早時間與事件／手動共用 last-run 基準、同時命中單次執行、舊資料不自動啟用、stale batch 與開始執行寫檔失敗回滾；模型混合條件入口與七語言完整核准已接上，單項 cron／alias／interval 可與 GitHub／Slack 任意平面混合。 | complete | 本輪 85 項聚焦回歸與原生建置通過；完整回歸待 Mac 解鎖，詳見協作核對紀錄 |
| AUTO-02 | `AutomationService.swift`、`Models.swift`、`WorkflowWorkspaceView.swift` 與 AppModel integration 提供 routine CRUD、enable/disable、Run Now、next/last run 與 bounded run history。群組／mailbox 可提出自身排程 create/update（固定時區的 cron／alias／@every、單一 GitHub／Slack／Linear／Sentry／PagerDuty trigger 或受限 Teams 定義 或 1–8 個平面時間／事件 OR 條件）、pause/resume/delete；ID、完整 before/after 任務與觸發條件／enabled 核准後套用，防 stale／Stop／帳號切換／寫檔失敗；費用防護不由模型解除；修改保留現有歷史，delete 不取消已執行／已排隊工作，歷史留存但無還原入口。GitHub 可篩選 repo／事件／作者與操作人／CI 分支，須既有已驗證連線，不會自動安裝 webhook；CI 只看個別 push workflow 完成，Slack 支援普通訊息／App 提及／關鍵字／新增表情的明確 ID 或 * 篩選，不支援名稱解析或自身身分；已支援時間／事件混合 OR 的模型 create/update，每項時間皆固定時區並驗證 366 天內可執行，核准明示事件／手動執行重設間隔；Linear 支援 issueCreated／statusChanged／endOfCycle 與 teamIds／projectIds／新 statusIds／cycleIds 的明確 UUID 篩選；statusIds 僅用於狀態變更、cycleIds 僅用於週期完成，原生週期拒絕非空 projectIds；Sentry 已支援五種 issue case／issueAny 與精確十進位 projectIds 篩選、完整核准及生命週期防護；PagerDuty 支援四種 incident case／incidentAny 與精確、區分大小寫的 serviceIds 篩選、完整核准及混合 OR；尚缺 checks 彙整及其他 event/platform 的模型 create/update。 | complete | 非並行完整回歸 134 XCTest、812 Swift Testing 通過；並行測試穩定性限制詳見協作核對紀錄 |
| AUTO-03 | `PlatformTriggers.swift`、`AutomationIngress*`、`EventBatcher.swift` 與 connector integration 提供 matching／signature／去重及 audit 基礎。Linear 已補 issueCreated／statusChanged、team/project/new-status 篩選、送達識別、signed-body timestamp／digest 防重播、模型 create/update 與七語言核准；保留舊儲存，不自動遷移排程。Sentry 已補五種 issue case／issueAny、data.issue.project.id 精確篩選、body digest 作 nonce 及事件 ID、重開與 history 去重；Request-ID 僅供診斷，無簽章時間戳可證明新鮮度，也不是永久防重播；舊 raw-action 定義保留原有比對。已接上 Sentry 自身模型提案、完整核准、精確 projectIds 與平面混合 OR；PagerDuty 已補四種 incident case／incidentAny、V3 resource／type 驗證、精確 service_reference ID 篩選，body digest nonce 及已簽章 event.id history 去重；僅接受 v1 簽章候選，delivery ID 僅診斷，occurred_at 不當送達新鮮度證據；保留舊 raw-event 定義。已接上 PagerDuty 自身模型 create/update、完整核准與平面混合 OR，serviceIds 最多 50 個精確且區分大小寫的 ID，不作名稱查找或隱含連線。本輪補原生 Cycle/update 的 null→completedAt 轉換、team/cycle UUID 篩選與 cycle＋完成時間的 history 去重；不把單純日期到期當事件，原生無 project 歸屬時拒絕專案篩選。已接上 cycle 自身模型 create/update、完整核准及混合 OR，原始 cycleIds 清單最多 50 個 UUID，非空 projectIds 與不適用的 statusIds 直接拒絕；沒有自動遷移／啟用舊定義。Teams 原生入口已分離傳輸簽章與使用者登入，Graph UUID 用 aadGroupId、Bot ID 保留獨立比對；僅分類完整的頻道 message，非訊息／超限上下文不觸發，以 tenant/team/channel/conversation/activity 身分 hash 去重。保留 blockUnauthenticatedUsers 的條件一律不執行；未證明主文時須有明確文字篩選，既有權限不放寬。手動編輯器保留預設登入限制並明示不能執行，模型 Teams create/update 已接上同樣受限定義與獨立核准，Teams 事件仍不執行。共用入口已補佇列拒收後安全釋放 nonce、儲存失敗時保守拒收、金鑰返回後重驗 route revision／listener generation／適用的簽章時間戳；pending nonce 不會提前到期，接受後不撤回。佇列採 connector＋external event ID，已入列副本與容量不足分開；仍無 crash-safe delivery／exactly-once。本輪已補手動新增 Linear／Sentry／PagerDuty 的事件選單、正確預設、case 專屬 ID 欄位與七語言說明；每欄最多 50 筆原始 ID、空逗號項及無效／不適用條件拒絕，切換事件保留篩選供使用者修正，不自動放大範圍。既有定義不遷移；已補既有 cron／GitHub／Slack／Linear／Sentry／PagerDuty／平面 OR 的手動編輯，原子儲存保留 runtime／history／費用防護，拒絕 stale／取消／帳號切換／owner 封存的未提交寫入；其他 trigger 僅可改名稱與任務、原定義唯讀保留。GitHub／Slack 新增與編輯共用嚴格驗證，GitHub 14 事件勾選、精確 CI 分支／登入名稱；Slack 對話 ID／獨立關鍵字與表情篩選，保留不適用條件供明確清除。拒絕默默丟棄未知事件、截斷過長字串或省略無效篩選。舊 Slack 名稱／bySelf、未知格式唯讀。generic 已補嚴格有界 JSON、精確型別／數字與 connector scope 比對、損壞分支不匹配及既有條件手動編輯；模型 generic 寫入仍拒絕。已補 Teams 的有界 literal 條件新增／編輯：保留登入限制、嚴格清單與 scope／text 驗證，regex／不同政策／空篩選等舊格式維持唯讀，保存再驗證；不啟用 Teams 事件執行；模型提案另經完整核准與提交時重驗。仍缺原版雲端完整語意；GitHub 仍為個別 push workflow 而非 checks 彙整，Slack 仍無名稱／人類身分映射。不能將 generic matcher 或歷史 ingress 測試視為原版各事件完整還原。 | partial | `TeamsRoutineEditorTests`、`ConnectorRoutineFilterTests`、`ConnectorRoutineEditorTests`、`GitHubSlackRoutineEditorTests`、`ManualRoutineEditTests`、`RoutineEditAppTests`、`RoutineListenerEditorTests`、`IngressAdmissionTests`、`TeamsRoutineEventTests`、`PagerDutyRoutineEventTests`、`SentryRoutineEventTests`、`LinearRoutineEventTests`、`AgentRoutineChangeTests` 與 App fixtures；上一批 59 項編輯／事件／語言聚焦、42 張 generic 欄位與 98 張完整 sheet 七語言明暗渲染、原生 clean build 與嚴格簽章通過；完整回歸見最新協作核對紀錄，非 live 平台驗收 |
| AUTO-04 | `AgentWorkflowModel.swift`、`AgentWorkflowStore.swift`、`AgentWorkflowRuntime.swift`、`WorkflowService.swift` 與 `WorkflowAppIntegration.swift` 提供 SKILL/workflow import/codec、trigger/action validation、run history/cancel/replay；Teach recording queue scope 與 attachment-backed scoped auto-dispatch 已接線。 | complete | final gates passed |

### 8. Computer / local execution

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| COMP-01 | `FiliconLocalTools`、`FiliconLocalToolHelper`、`FiliconLocalToolXPCService`、`ProcessSupervisor.swift` 與 `RequestGuard.swift` 提供 command/read/write/send-input、permission gate、generation/timeout/termination 與 XPC isolation。本輪 `ProcessOutputReader` 等 stdout/stderr 確認交付後才公布完成；64 KiB 單區塊交付、10 MiB 合併上限、子程序退出後一秒有界收尾。部分輸出／diagnostics 保留，App 依 terminationError 標示工具失敗；不擴大執行授權或宣稱任意背景子孫監督。 | complete | 歷史 final gates；本輪 `ProcessOutputTests`／`LocalToolsTests`／`ProcessResultPresentationTests` 與完整驗證見協作核對紀錄 |
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
| UPD-01 | `scripts/package-app.sh`、`scripts/verify-package.sh`、`scripts/verify-package-entitlements.py`、`Package.swift` 與 signed app bundle 提供 build/package、nested helper/XPC assembly、metadata、hardened runtime flags 與 strict verification。Xcode 資源變更已宣告簽章輸出依賴；Debug 例外只接受完整 bundle 路徑及經確認的系統別名，Release 禁止開發例外。 | complete | 歷史 final gates；本輪政策 fixtures 與 13 次原生 Debug build／內容／deep strict／完整 package verifier 通過；詳見協作核對紀錄，非公證驗收 |
| UPD-02 | `FiliconUpdater/UpdateService.swift`、`UpdateManager.swift`、`UpdateConfigurationResolver.swift`、`BackendUpdateRequirement.swift`、`UpdatePresentation.swift` 與 `UpdateIdleMonitor.swift` 提供 channel/default/runtime checks、signed feed resolution、download/verify/stage/install、idle/required UI；runtime/default/backend requirement signal 已接線。 | complete | final gates passed |
| UPD-03 | `scripts/release-macos.sh`、`generate-update-feed.swift`、`generate-update-feed-key.swift`、`read-update-feed-key.swift`、`verify-release-artifacts.sh` 與 updater verifier/install pipeline 已完成；本機 signing key 已安全存入 Keychain，`filicon-notary` 已以 App Store Connect Team Key/issuer 驗證；`v0.18.0` 已發布 notarized/stapled ZIP、DMG 與 signed update feed 至 [GitHub Release](https://github.com/irons163/filicon-bot/releases/tag/v0.18.0)。 | complete | Apple notarization + Gatekeeper/stapler + remote checksum/feed signature passed |
| UPD-04 | Electron/ASAR/preload、Windows installer/overlay 與來源 daemon wiring 是來源 runtime 細節，不是 macOS 原生產品行為；Swift package 以原生 targets 取代它們。 | NA | final gates passed |

## Verification note

歷史 verifier 紀錄：553 tests（420 Swift Testing、133 XCTest）、WAE、release build，以及 `v0.18.0` release `0.18.0-184` 的簽署／發佈檢查曾通過。這些不是本輪重新驗證，也不能證明功能完整對等。舊版「沒有剩餘 parity gap」結論已撤回；目前至少有上述 AGENT-01/02/04 缺項，其他區域仍需逐項端到端核對。`UPD-04` 維持 NA。
