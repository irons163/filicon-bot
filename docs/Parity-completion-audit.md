# 完成驗收入口（2026-09-27）

## 真正單獨聊天委派的收件人成員外部送件

2026-10-06 接續 `af754a9`；reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。本批將明確的 mailbox channel factory 接入 App 的 bound direct `SendToAgent` → 真正收件人成員回合，亦涵蓋該成員以已接受的 `SendToAgent` 回覆原發起成員。不是讓 `drain` 借用來源前景或 saved-group publisher；沒有 host factory、durable recipient context、正確 account／chain／owner／destination／author／reply directory 的回合，不取得送件能力。group-origin／manual mailbox 和 inbound shared runner 仍未安裝此 grant。

原人類入口保留 `ToolContext`、每次核准卡、source consent 與 mailbox reply directory；真正收件人成員使用自己的唯一 connection，host 將正式 entry 固定至該成員自己的 canonical direct chat。回到原 bound owner 時正式目的地才是原聊天。原始訊息只在 scheduler 實際 admission 後投影成 recipient incoming row；publisher acquisition 不先建立聊天，也不拷貝原 owner／無關聊天的私人 history。其他聊天的 external receipt aliases 不匯入原目錄，跨 destination 的 local quote 仍先拒絕。

`SendToAgent`、本機讀檔／HTTPS source、final channel send 的核准分開；generic auto-review allow 不能代替新的外部送件核准。完整 ordered intent 與 captured bytes／digest／filename／MIME／caption 保留，不於送件前重讀改寫後的 source。只有實際 canonical save 產生明確的 saved external output；它是含原 delivery ID 的 queued-not-delivered 事實，不是假 local mailbox publication，不投影到來源群組或其他 direct chat，也不把 private provider draft 當完成報告。provider 在實際 save 後失敗仍保留已保存事實；只有 queue 成功但 canonical save 缺失／拋錯／偽造，不宣稱正式 entry 已保存。

來源與收件 chat 的 semantic binding／route、原 account／generation、鏈上相關 personas 及已捕捉的唯一 durable binding leases 一直保留至 queue／SQL commit。來源或目標 Stop、archive／delete、換帳號、persona／binding／route 修改後還原均不能恢復舊 grant；純導航、presence／unread／updatedAt 不改 persona。失效的 channel review 退休 exact broker waiter；本機 read 的 final runtime dispatch 另驗同步 captured scope，舊讀取核准不能呼叫 helper。未宣稱 persona 變更會主動退休所有 local read waiters，也不宣稱跨 process exactly-once、queue／chat／CAS 原子性或召回已 admitted 的 I/O。

新增 core 4 methods（23 parameter cases＋1 standalone failure case）及 actual App 3 methods／48 parameter cases。使用隔離真實 stores、原生核准入口、bookmark／receipt-aware in-process helper、假 provider／HTTPS downloader／connector，以及完整 CustomDump 狀態比較；不碰真實 credentials 或外部傳輸。覆蓋 owner→peer→owner、錯誤或缺少 acquisition、source 與 send 同意、reopen、provider failure after saved receipt、17 種 App lifecycle／connection／navigation 情境和 12 種 local／HTTPS consent 情境。queue 日期預期以該 store 的毫秒 codec 完整 round-trip 比較，不省略 payload 欄位，也不宣稱浮點日期無精度損失。

較早 App 聚焦失敗含 fixture API／存取控制／wire-field 編譯錯誤，首次模型目錄未載入，以及 queue 日期 codec 比對不一致；均修正 fixture／完整預期，沒有降低產品 catalog、MIME、工具協定或權限 guard。`v9` 僅首個 case 的 catalog readiness race 共 2 issues，provider requests 與 mailbox messages 皆未開始；fixture 現等待實際可用 catalog。最後 `mailbox-channel-app-focused-v10.log` exit 0：core 39 tests／3 suites＋App 29 tests／5 suites，合計 68 tests／8 suites，包含前景 direct／delegated group／原 group mailbox 回歸。

舊 `mailbox-channel-core-full-final-v1.log` 不是通過證據：135 XCTest 通過，但 App 與 Agents targets 有失敗，包含隔離的 `agents.json`／`workflows.json`／`runs.json` 出現 Cocoa 257／POSIX 1。保留原檔案保護設定，不繞過 macOS 保護。解鎖後，最後接線 source 的完整串行 `mailbox-channel-app-full-final-v2.log` exit 0：17 個 Swift Testing target summaries 合計 2,124 tests／255 suites，另 17 個 XCTest bundles 合計 135 tests／0 failures；App target 為 775 tests／102 suites。兩項 opt-in installed Codex live tests skipped，不算外部驗收；既有 CoreData NSXPCConnection 診斷仍存在，相關 tests 通過，不宣稱修復。

`mailbox-channel-app-native-final-v2.log` 的 `Filicon App`／arm64 Debug BUILD SUCCEEDED；`mailbox-channel-app-native-verify-final-v2.log` 與全新 standalone `MailboxChannelPackage/Filicon.app`／`mailbox-channel-app-package-final-v2.log` 均 exit 0，四個 executables、app／XPC entitlements 與 deep strict codesign 通過。`mailbox-channel-app-localization-final-v2.log` 七語各 1,815 keys／0 missing。standalone 等同一 `.build` 的完整測試結束後正常完成，沒有新增 UI layout／翻譯，不把文字鍵完整度當全翻譯語意或真人驗收。此為隔離 Debug／ad-hoc gate，不是 Developer ID release／公證；未執行列印的 launch smoke。`git diff --check` 通過，日誌／隔離產物留於忽略的 `.build/validation/`。

**仍未完成**：group-origin／manual mailbox 與 inbound shared runner 的 channel publication／canonical host 接線、其餘路徑的 delivery-failure model follow-up、安全 CAS preview／open，以及 live Slack／Discord／OAuth、真人／VoiceOver／最低 macOS、Developer ID release／公證。direct-peer mailbox 的 failure follow-up 尚待實際路徑驗證，不因共用 direct runner 就宣稱完成。AGENT-02／整體 partial、48 分類（42 個歷史 complete／5 partial／1 NA）不變。本節只取代下方歷史的 bound-direct peer mailbox publication 缺口；未 push、啟動或重啟使用者 App／Xcode，未改真實資料。

## 已核准委派到其他群組的外部送件

2026-10-06 接續 `fd2ee0f`，reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。`agent-to-agent-messaging.ts` 對 group target 使用 `postToGroup`，不是把背景 draft 貼回來源房間；本批在 App 的實際 `runGroupDelegation` → `GroupConversationResponder` → `savedBackgroundGroupPublisher` 安裝 host-bound channel factory。原 mailbox `drain`、inbound runner 不因共享 session 取得此能力。

源頭的 `ToolContext`／獨立核准卡／source consent 維持原群組或 bound direct conversation；connection 與 queue owner 使用真正回覆成員，不借用原發起者的 credentials。canonical destination／author 是 host 固定的目標 group／actual agent，不是模型可選參數。reply directory 必須與實際目標群組一致，才能保留該群組內有效 local quote；缺省的跨聊天拒絕仍保留，沒有把來源 quote 或另一聊天 receipt alias 自動匯入目錄。

`SendToAgent` 核准不代替 source read、每次 redirect 或 external send 核准；即使 generic auto-review allow 也要顯示新的完整送件核准。source 與 queue 使用 captured bytes／digest／filename／MIME／caption，不重讀已變更的 source。正式群組 entry 來自實際 queue ID、保留 actual author／quote／完整 intent，同回合 exact call replay 不重送；存檔後可重開，不將 private draft、外部 entry 或未分享的來源 history 寫入無關 direct chat。

App 同步 capture 原 account／dispatch／來源 binding、route 與來源／目標 group 的 semantic identity；相關 persona／membership／group metadata 修改後還原、Stop／account transition 會關閉原 lifetime，final durable queue save 仍持有既有同步 guard。presence／unread／updatedAt、speaker offset 和純粹導航不撤銷 persona。失效的 channel review 會取消 exact broker waiter，不須另按核准或等五分鐘 expiry；native direct review 先驗 scope 才可保存，不恢復 stale owner。已 queued 的訊息不宣稱可召回，queue／chat／CAS 不是跨 stores 原子交易。

新增本機 read 測試抓到有效產品缺口：`delegated-group-channel-local-red-v1.log` exit 1，group／direct 兩個 persona-ABA cases 共 4 issues，舊讀取核准雖最終沒有入列，仍已呼叫 helper。現將 channel lifetime 傳入 `AuthorizedAgentFileReader` 的 read checks 及 `LocalToolRuntime.perform` dispatch validator，在 workspace bookmark／permission await 後、helper dispatch 前拒絕，不降低原 bookmark／policy／receipt 防護或假裝撤回已 admitted 的讀取。

新增 5 test methods／38 parameter cases，以隔離 AppModel、durable stores、真實 security-scoped bookmark、receipt-aware in-process helper、假 provider／connector／HTTPS downloader 與完整 CustomDump 值比對驗證。包含 direct／group 來源、delegation 和 send 分開、actual recipient connection／目標 group quote／canonical reopen、原 history 不洩漏、12 種 scope／config changes、native stale card、8 種 HTTPS／redirect 情境和 12 種 local read／send／revocation 情境。附件核准後替換 source 的 bytes，必須仍安裝原 bytes；拒絕 read、unsupported connector、Stop 及 persona-ABA read 不 dispatch、不留下 channel CAS 或 queue。

較早 `focused-v1` 是 cache permission 編譯失敗，`v2` 是 fixture 存取控制編譯失敗；`v3`／`v4` 遇到受限 macOS type／ScopedBookmarksAgent／離屏渲染服務，不當作產品紅燈。相同既有測試在必要系統存取下的 `v5` 通過；該輪僅新 fixture 的 `.bin` 被 macOS 映射為 `application/macbinary` 而受既有 MIME allow-list 拒絕（4 timeout issues）。沒有放寬產品檔案類型或跳過測試；fixture 改用必須保持 inert 的 `.html`，獨立預期 `application/octet-stream`。最後完整聚焦 `delegated-group-channel-focused-v6.log` exit 0：74 tests／9 suites，包含所有前景／reviewed background direct／group channel source 和 App 卡片回歸。七語 `delegated-group-channel-localization-final-v2.log` 各 1,815 keys／0 missing；沒有新增 UI layout／文字，不當作全翻譯語意或真人驗收。

最後完整串行 `delegated-group-channel-full-final-v1.log` exit 0：17 個 Swift Testing target summaries 合計 2,117 tests／253 suites，另 17 個 XCTest bundles 合計 135 tests／0 failures；App target 為 772 tests／101 suites。兩項 opt-in installed Codex live tests skipped，不算 live 驗收；既有 CoreData NSXPCConnection 診斷仍存在，相關 tests 通過，不宣稱修復。

`delegated-group-channel-native-final-v1.log` 的 `Filicon App`／arm64 Debug BUILD SUCCEEDED；`delegated-group-channel-native-verify-final-v1.log` 與全新 `DelegatedGroupChannelPackage/Filicon.app`／`delegated-group-channel-package-final-v1.log` 均 exit 0：四個 executables、app／XPC entitlements、deep strict codesign、KaTeX 0.16.45／20 fonts、Mermaid 11.16.0／72 notices 通過。standalone 封裝等待同一 `.build` 的完整測試結束後正常完成，沒有另啟 App；此為隔離 Debug／ad-hoc gate，不是 Developer ID release／公證，未執行列印的 launch smoke。`git diff --check` 通過，日誌／隔離產物留於忽略的 `.build/validation/`。

**仍未完成**：mailbox／inbound shared runner 的 channel publication／canonical projection，以及 group 等其餘路徑的 delivery-failure model follow-up；安全 CAS preview／open；live Slack／Discord／OAuth、真人／VoiceOver／最低 macOS、Developer ID release／公證。AGENT-02／整體 partial 和 48 分類（42 個歷史 complete／5 partial／1 NA）不變。本節只取代下方歷史的 delegated-group publication 缺口，沒有新增 schema 或真實帳號／聊天權限；未 push、啟動或重啟使用者 App／Xcode，未改真實資料。

## 委派送件的核准來源與正式聊天目的地分離

2026-10-06 接續 `8eac57a`，reference HEAD 為 `a9f633e09d49a85829b8236331b9e21f7e612634`。main 核對 `agent-to-agent-messaging.ts` 的 `runAgentInboundWake`：收件 agent 使用自己的 background session，而 `turn-runtime.ts` 的 channel `send-message` 保存在實際 run session transcript。本批先補共用 transaction 的必要契約，不將委派來源群組／聊天誤當成收件人的正式聊天。

host 可明確提供 canonical destination／author；來源 `ToolContext`、人類核准卡、source consent 和實際 connection 的 account／agent ownership 不改投。destination 是 host 資料，不是權限、模型參數或恢復後的新 grant；caller 仍須重驗原 scope，並保留 final lifetime／binding guards。direct author 必須是該 canonical chat ID，group author 必須是實際 owner agent；跨 destination 的 local quote 在 source read／review 之前拒絕。

只有實際成功保存且完整匹配的 canonical publication 才回傳另一聊天的 receipt，並明示其 UUID／short alias 不能當作來源對話的 reply target；不加入原 reply directory、不複製其他聊天 history。queue 已提交而 canonical save 缺失／取消／造假時仍回報 durable queued-not-delivered 事實，沒有假 local receipt 或自動重送；exact call replay 不重新審核、讀 source、排入或保存。

新增 6 個 test methods／20 個 standalone／parameter cases，使用實際隔離 SQLite repository、binding lease 和 durable channel queue，connector／source 由假服務替代，商業時間／IDs 受控，CustomDump 比較完整狀態及最少預期 mutation。涵蓋原 approval scope、實際 recipient chat receipt／重開、來源上下文、foreign quote、錯 author／context、binding ABA／late revocation、模型偽造 destination，以及 canonical callback 失敗後 exact replay。source fixture 驗證獨立 callback 與順序，不冒充 App 原生核准卡或真正本機／HTTPS permission 驗收。`channel-destination-focused-v4.log` exit 0：36 tests／3 suites；七語 `channel-destination-localization-final-v1.log` 各 1,815 keys／0 missing。較早編譯與預期未包含既有訊息短位址／scopeMismatch 的 fixture 失敗保留，不當作有效產品 baseline 紅燈；本缺口由來源／call-site 核對確認。

最後完整串行 `channel-destination-full-final-v1.log` exit 0：17 個 Swift Testing target summaries 合計 2,112 tests／252 suites，另 17 個 XCTest bundles 合計 135 tests／0 failures；App target 為 767 tests／100 suites。兩項 opt-in installed Codex live tests skipped，不算 live 驗收；既有 CoreData NSXPCConnection 診斷仍存在，相關 tests 通過，不宣稱修復。

`channel-destination-native-final-v1.log` 的 `Filicon App`／arm64 Debug BUILD SUCCEEDED；`channel-destination-native-verify-final-v1.log` 與全新 `ChannelDestinationPackage/Filicon.app`／`channel-destination-package-final-v1.log` 均 exit 0：四個 executables、app／XPC entitlements、deep strict codesign、KaTeX 0.16.45／20 fonts、Mermaid 11.16.0／72 notices 通過。standalone 為隔離 Debug／ad-hoc gate，不是 Developer ID release／公證，未執行列印的 launch smoke。`git diff --check` 通過，日誌／隔離產物留於忽略的 `.build/validation/`；測試技能保留受控依賴與完整值驗證，文件技能保留來源與尚未接線的界線。

**App 委派送件入口尚未接線。** 本批沒有替 `AgentMessagingSession.drain` 安裝 mailbox channel publisher，也沒有替 App 建立 recipient canonical scope、原生核准生命週期或該路徑的 failure follow-up。mailbox／delegated group／inbound publication／projection 與相應 failure routing、安全 CAS preview／open、live／真人／VoiceOver／最低 macOS／Developer ID release／公證仍待完成；AGENT-02／整體 partial 和 48 分類（42 個歷史 complete／5 partial／1 NA）不變。沒有新增 UI、持久 schema、真實帳號／聊天權限，未 push、啟動或重啟使用者 App／Xcode、修改真實資料。

## 已審閱的背景單獨聊天：外部送件與流程結果

2026-10-06 接續 `ed2053c`，reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。main 核對 `source/host/extensions/transcript/turn-runtime.ts`：channel `SendMessage` 不限前景，background publication 也保存原 session 的 transcript。本批只補已有獨立 direct-session consent 的 routine／workflow，涵蓋 manual／scheduled 原生入口；不因目前選取另一聊天而改投。未審閱的 routine 不取得聊天 history／tools，activity acknowledgment／delivery-failure notice 不取得外部送件能力。

背景 task 的 channel proposal 仍須逐次人類核准；generic auto-review、背景 session consent 或 source read consent 都不等於送件同意。HTTPS source／每次 redirect／final send 分開審閱，queue 使用已捕捉 bytes／digest／filename／MIME／caption／目的地，不再次抓取核准後已變更的 source。history 只提供既有文字，不自動讀取或轉送舊附件；不支援附件的 connector 在讀取前拒絕。沿用原 bound agent／account 的唯一 connection，不借用 peer 或其他聊天。

account／dispatch scope、原 repository unique-binding lease 與 publication lifetime 的同步 guards 保留到最後 durable queue save，鎖定順序為 host scope／binding → parent／child publication，避免與 repository publication 顛倒。Stop、帳號／consent／definition／persona／binding／model／reasoning／hidden 的離開再返回、duplicate binding 及 connector／connection 更換，不能用舊核准復活；presence／unread／updatedAt 不當作 persona 變更。另一 repository 改綁的案例由 async canonical validator 拒絕，不把 per-instance lease 說成跨 process fence。已排入的真實 receipt 保留 queued-not-delivered 事實，不假裝取消已送件或自動重送。

失效的背景 source／send 核准卡會退休原 broker waiter，避免 canonical owner 已改綁而卡片保存失敗時一直等待；不為了存卡而復原另一 owner。成功保存的正式外部記錄才列入該 turn 的 explicit outputs，workflow 下一步取得這筆 canonical 結果與 history，不取得模型 private draft。每一步仍需新的核准；refresh／bootstrap repair 不重新發表 output 或送件。terminal queue failure 沿用原 bound member follow-up runner，在原聊天更正，不取得新的外部送件能力。

有效 baseline `background-channel-red-v2.log` 使用 `ed2053c` production，exit 1：4 個 manual／scheduled routine／workflow cases 沒有新核准、channel capability 為 false。`background-channel-expanded-v2.log` 另抓到已排入／已保存的 workflow 結果仍為空字串（4 issues），現改傳實際 saved receipt。前幾版編譯失敗屬 fixture，不當作產品紅燈；durable-rebind waiter 和 workflow output 的實際缺口未用放寬權限或斷言處理。

新增 8 個 test methods／60 個 standalone／parameter cases：核心同步 guards 2／4、真正 App background 6／56。包含原入口、15 類核准撤銷 × 2 種 task、逐次附件／redirect 核准、操作狀態更新、workflow 兩步與重開不重送，以及 actual queue failure 回原成員。採隔離 stores、假 provider／connector／downloader、受控商業時間與完整 CustomDump 值比較；原選取的另一聊天及未公開內容不被寫入或轉送。fixture 現等待下一張真實核准卡，而非把 workflow 兩步間的 idle 空檔當成完成。

`background-channel-integration-v1.log` 保留預設並行跑法的 28 issues，包括既有核准期限／routine 狀態與新 fixture 的步驟空檔；沒有略過失敗 methods 或放寬時間／權限。最後明確 `--no-parallel` 的 `background-channel-integration-v2.log` exit 0：96 tests／7 suites，所有上述 methods、原 foreground source／redirect 核准卡渲染、routine／workflow 舊入口及 failure follow-up 均通過。七語 `background-channel-localization-final-v1.log` 各 1,815 keys／0 missing；沒有新增 UI layout／文字，此 audit 不是全翻譯語意或真人可用性驗收。

最後完整串行 `background-channel-full-final-v1.log` exit 0：17 個 Swift Testing target summaries 合計 2,106 tests／251 suites，另 17 個 XCTest bundles 合計 135 tests／0 failures；App target 為 767 tests／100 suites。兩項 opt-in installed Codex live tests skipped，不算 live 驗收。既有 CoreData NSXPCConnection 診斷仍出現，相關 tests 通過，不宣稱已修好。

`background-channel-native-final-v1.log` 的 `Filicon App`／arm64 Debug BUILD SUCCEEDED，修正 source 實際編譯；`background-channel-native-verify-final-v1.log` 及新 `BackgroundChannelPackage/Filicon.app`／`background-channel-package-final-v1.log` 均 exit 0：四個 executables、app／XPC entitlements、deep strict codesign、KaTeX 0.16.45／20 fonts、Mermaid 11.16.0／72 notices 通過。standalone 是 Debug／ad-hoc gate，不是 Developer ID release／公證，未執行列印的 launch smoke。`git diff --check` 通過；日誌／隔離產物只留於忽略的 `.build/validation/`。Swift Testing／CustomDump／Dependencies 技能驗證受控原入口與完整值，文件技能保留來源、歷史失敗與尚未完成的邊界。

**仍未完成**：mailbox／delegated group／inbound shared runner 的 channel publication、canonical projection 與相應 failure routing；locators 的安全 CAS preview／open；真實 Slack／Discord／OAuth、真人／VoiceOver／最低 macOS、Developer ID release／公證。AGENT-02／整體 partial 和 48 分類（42 個歷史 complete／5 partial／1 NA）不變。本節只取代下方歷史的 reviewed routine／workflow background direct 缺口，不宣稱任意 background runner、跨 process exactly-once 或 queue／chat／CAS 跨 store 原子性。未 push、啟動或重啟使用者 App／Xcode，未改真實帳號／群組／聊天。

## 外部送件失敗後通知原代理人

2026-10-06 接續 `89e5a35`，reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。main 核對 `background-wakes.ts` 的 `runChannelFailureWake`、`session-runtime.ts` 的原 agent background session，以及 `channel-messaging.ts` 的失敗提醒：不是新的人類訊息或權限，須以沒有 channel target 的 `SendMessage` 在 App 更正先前送達說法，不默默重送。本批補原前景 bound direct 的 terminal delivery failure → 原 account／agent／canonical chat → shared direct runner；saved-group 仍保留原生失敗狀態，不因此啟動全群組回合。legacy nil-origin／listener failure 不猜測收件聊天。

host 從 authoritative dead-letter queue 與已保存的 exact canonical publication 建立有界提醒。只提供 delivery ID、平台／目的地 ID、attempts 及 allow-listed typed reason；raw connector／server error、token、outbound text、任意附件 URL／filename／alt／bytes 不加入提醒。一般 transport／legacy 無型別失敗只能說「未確認送達」，不能推論收件人什麼都沒收到。原 persona／聊天 history 維持，但提醒只在 request 中暫存，不保存假的 user row，也不將它當作記憶建議、episode 或 synthesis 的人類證據。

durable `ChannelFailureFollowUp` 在模型執行前保存一次 admission。completed／failed／cancelled 不重播；重開遇到 running 轉 interrupted，避免重複已可能發表的更正，不把舊 spinner 當成仍在執行。原聊天忙碌時先不 claim；不在側欄首頁時只載回 exact canonical owner，不跟隨目前選取或新增聊天。hidden／刪除／封存／歧義 binding／外帳號／無工具 provider 拒絕，不回退其他聊天。corrupt bookkeeping 在重寫前拒絕；claim／finish／acknowledgment 保存失敗回滾完整 state，非有限日期拒絕，完成時間不因倒退時鐘早於 admission。

原 repository binding lease、account generation／scope、provider／model／reasoning 及 persona identity 維持到最後 publication／review-card／SQL save。Stop、acknowledgment、帳號或 binding／hidden／provider／model／reasoning／persona 的離開再返回，以及同一 App 的實際側欄隱藏、成員編輯／封存操作，均同步退休原回合；遲到且忽略 cancellation 的 provider 不能追加文字或借用較寬 finalization lease。status／unread／updatedAt 等 operational changes 不當作 persona 變更。取消只清理原 run／review IDs，不覆寫另一 owner 的 history。這是本機 admission／lifetime fence，不是跨 process exactly-once 或 queue／chat 跨 store 原子交易。

有效 baseline `channel-failure-wake-red-v2.log` 使用 `89e5a35` production，exit 1：真正 App 的 terminal failure 沒有進入原 bound member runner（1 test／1 suite／1 issue，requests 為 0）。接線後的隔離 bootstrap 測試另抓到帳號 restoration 的既有 cancellation 會提前消耗新 claim；`channel-failure-wake-app-v8.log` 的暫時 stack 證明路徑為 restoreAccount → cancelAutoReviewApprovals → cancelConversationWork。現待帳號與 bootstrap 完成才 admission，最後來源已移除診斷輸出。另修正 acknowledgment optional state mutation 的 Swift exclusivity crash；沒有略過取消情境。

`channel-failure-wake-focused-v12.log` 的兩項失敗是 fixture 誤以為未支援的 `channel` 會回傳一般 executor error。真正 ToolLoop schema 在 executor 前拒絕 unknown property，既有 interactive bridge 讓該 protocol error 結束回合；沒有修改 ToolLoop／bridge 或宣稱模型一定能接續更正。最後 App fixture 要求 exact typed rejection、failed admission、零 local correction／新外部送件／核准。另一純 executor bypass 測試確認即使不經 schema，unsupported channel 仍不能發表或消耗兩筆本地 publication 額度。其餘編譯、fixture 日期精度和斷言修正日誌保留，不當作新的產品安全紅燈。

最後聚焦 `channel-failure-wake-focused-final-v15.log` exit 0：22 tests／3 suites，包含 80 個 standalone／parameter cases（notice 5 methods／15 cases、channel service 10／32、真正 App 7／33）。涵蓋原 runner 實際 `SendMessage` 更正、private draft／silence／provider failure、busy／unselected／off-page／重開、14 種遲到 publication 撤銷、實際開啟 memory suggestions＋episodes／synthesis 仍無寫入、typed reason privacy、corrupt／rollback／nonfinite clock 和 terminal no-replay。使用隔離 stores、假 connector／provider、受控商業時間與完整 CustomDump 值比較；另一聊天完整值及原一次 external send 不變，不使用真實帳號或模型。

最後完整串行 `channel-failure-wake-full-final-v1.log` exit 0：17 個 Swift Testing target summaries 合計 2,098 tests／250 suites，另 17 個 XCTest bundles 合計 135 tests／0 failures；App target 為 761 tests／99 suites。兩項 opt-in installed Codex live tests skipped，不算 live 驗收。`channel-failure-wake-localization-final-v1.log` 七語各 1,815 keys／0 missing；本批未新增 UI layout／文字，不新增真人／VoiceOver 驗收。

`channel-failure-wake-native-final-v1.log` 的 `Filicon App`／arm64 Debug BUILD SUCCEEDED，新 notice／record 實際編譯；`channel-failure-wake-native-verify-final-v1.log` 及新 `ChannelFailurePackage/Filicon.app`／`channel-failure-wake-package-final-v1.log` 均 exit 0，四個 executables、app／XPC entitlements、deep strict codesign、KaTeX 0.16.45／20 fonts、Mermaid 11.16.0／72 notices 通過。standalone 為 Debug／ad-hoc，不是 Developer ID release／公證，未執行印出的 launch smoke。`git diff --check` 通過；日誌／隔離產物只留於忽略的 `.build/validation/`。Swift Testing／CustomDump／Dependencies 技能用於受控原入口與完整值斷言；文件技能保留實際接線與驗收界線。

**後續範圍**：本批原列的 reviewed routine／workflow background direct 缺口由上節接續；mailbox／delegated group／inbound shared runner 的 channel publication、canonical projection 與相應 failure routing、locators 的安全 CAS preview／open，以及真實 Slack／Discord／OAuth、真人／VoiceOver／最低 macOS、Developer ID release／公證仍保留。AGENT-02／整體 partial 和 48 分類（42 個歷史 complete／5 partial／1 NA）不變。本節只取代下方歷史「前景 bound direct 沒有 delivery-failure model follow-up」的缺口；不保證模型遵循更正文案，也不擴大任何工具 grant。未 push、啟動或重啟使用者 App／Xcode，未改真實帳號／群組／聊天。

## 前景外部送件的正式聊天記錄與狀態恢復

2026-10-06 接續 `782f850`，reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。main 核對 `source/host/extensions/transcript/turn-runtime.ts` 的 channel canonical publication，以及 `send-message-shaping.ts` 的 source URL／file name／alt／thread。這批只補兩條已核准的前景 bound direct／saved-group：queue receipt 對應原聊天中一筆正式記錄；取得實際保存的 message ID／shortAddress 後才回傳 local saved receipt。原 local quote 與 platform thread 分開，完整 ordered URL／alt 和 first-image 契約未送出的圖片保留；實際 transport 仍只有已核准的 outbound。

`ExternalChannelTranscriptPublication` 是有界、唯顯示的 typed evidence，不是 source／帳號／重試／模型權限。文字、目的地、原作者／run／call、附件 digest／filename／MIME／byte count 和 queued timestamp 不可改名或改投；只有 authoritative outbox 的 queued／sending／retrying／delivered／dead-letter 狀態與 attempt／delivery timestamp 能前進，terminal 不被舊快照降級。direct 保留完整歷史、reactions、持久短位址和 read-state；group 沿用原保存／未讀／引用／討論串。附件沒有 alt 時仍是一筆可見 activity，不漏掉未讀、短位址或引用導航；status refresh 不重複計數。相同 caption 的兩筆不同目的地送件各自可取得 receipt，原每 turn 兩筆額度及 group budget 不放寬。

durable queue 先提交並快取真實 queued receipt。聊天保存失敗、Stop／cancel 或 callback shape 不符時，不捏造 saved receipt，也不以失敗為由重送；兩秒既有狀態 refresh／bootstrap 可用同一 delivery ID 補記或更新原記錄。repair 只讀 outbox，不執行 connector、source read／download、approval 或 member turn。當前 account／generation、active original agent、unique bound direct／非 hidden／未刪除、原 group member／完整 immutable owner 及最終同步 commit fence 都須有效；legacy nil-origin 不猜測聊天。original foreground lifetime 退休仍禁止該回合追加，但原已核准 outbox 的 display-only repair 可以在目前有效 owner 下完成。queue／chat／CAS 仍非跨 store 原子交易，沒有新增跨 process exactly-once 保證。

direct repository 在最終 actor write 保存舊 UI snapshot 尚未載入的新 external row，拒絕重標 publication 或帶動 delivery evidence；載入後的明確 native deletion 則由既有 activity receipt 區分，不被 repair 加回。group projector 也不呼叫 responder、不耗回覆 budget，兩條路由的 UI 只更新原 stable row，不整批取代正在串流或尚未載入的歷史。

direct／group 共用原生唯讀送件卡，七語顯示標題與五種狀態；queued 提示明確不是 delivered，first-image omissions 仍可見。exact URL／query、任意 filename／alt 原樣換行，只是 inert locators，不抓 remote bytes、不開啟來源、不新增 CAS preview／open。generic retry／dismiss 對帶 external evidence 的 widget 一律拒絕，即使修改 widget kind 亦不取得執行能力。修正 19 個既有相關狀態翻譯，新增一個七語 title key；獨立預期用語檢查避免翻譯自我比對，這不是全 catalog 語意驗收。

有效 baseline `channel-transcript-red-v1.log` 使用 `782f850` production 與新增原 App assertions，exit 1：2 methods／2 suites／6 issues 重現成功排隊卻無 canonical local row。完整 `channel-transcript-full-final-v1.log` 是 nested `#require` fixture macro 編譯失敗，不當產品紅燈；v2 執行後的 20 issues 是一處 fixture 使用未受控 wall-clock 的 sub-millisecond reopen 比對，以及 19 個舊 attachment success assertions 仍要求沒有 local saved receipt。已改成固定核心商業時鐘和更強的成功完整 row／重新開啟存檔比對，拒絕、Stop、account／membership／connection、queue／quota 故障情境仍須零新增 row／零送件，沒有跳過或降低拒絕邊界。

新增核心 13 methods／35 parameter cases、App recovery 一個方法／四種情境、畫面／inert actions 兩個方法；既有實際 App 文字／附件成功情境亦檢查 exact canonical evidence。SQLite 保存故障、回滾、terminal replay、stale full／paged snapshot、native deletion、owner／ID collisions、被撤銷的最終 commit、group 重開與 callback race，以及 queue 成功後 chat 保存失敗／cancel／forged receipt 均使用隔離 stores、受控 dependencies、fake connectors／downloader 和完整 CustomDump 值比對。App recovery fixture 重跑原 host 的 reconcile；core store 的 reopen 不冒充新 App bootstrap 或 live 平台驗收。

最後聚焦 `channel-transcript-focused-final-v7.log` exit 0：31 tests／5 suites（core 13／1、App 18／4），包含新增正式記錄、原 direct／group 文字與完整群組附件測試。原成功附件情境重新開啟自己的 group／agent 存檔，比對實際可見 row、完整來源與未送出圖片；失敗情境仍禁止 saved acknowledgment 和新增正式 row。較早 v6 的 43 tests 是不同聚焦集合，不取代最後 v7。

真正 unshown NSHostingView 產生七語 × 280／680 points × 明暗 × 五種 delivery status，共 140 張 PNG，存於 `channel-transcript-card-renders/`。每張檢查原生 fitting bounds 和全文末尾 marker；exact query、全部 URL／alt 與 inert actions 另用完整值 assertion。main 逐張檢視其中 17 張最後來源的代表畫面，涵蓋七語、兩種寬度、明暗與所有五種狀態：附件 metadata、完整 URL／首尾 alt、first-image omissions 與 queued 提示沒有截斷或重疊。沒有聲稱人工看過全部 140 張，也不當作完整 transcript viewport／真人 mouse、keyboard focus／VoiceOver 驗收。

`channel-transcript-full-final-v3.log` 因回合中斷停止，沒有完整結果或 exit，不當作 green。重新跑最後來源的完整串行 `channel-transcript-full-final-v4.log` exit 0：17 個 Swift Testing target summaries 合計 2,076 tests／247 suites，另 17 個 XCTest bundles 合計 135 tests／0 failures；App target 為 754 tests／98 suites。兩項 opt-in installed Codex live tests 依既有設定 skipped，不算 live 驗收。`channel-transcript-localization-final-v1.log` 七語各 1,815 keys／0 missing。

`channel-transcript-native-final-v1.log` 的 `Filicon App`／arm64 Debug BUILD SUCCEEDED，確認新 domain／projection 檔案實際編譯；`channel-transcript-native-verify-final-v1.log` 及新的 `ChannelTranscriptPackage/Filicon.app`／`channel-transcript-package-final-v1.log` 均 exit 0，檢查 version 0.1.0／build 1、四個 executables、app／XPC entitlements、deep strict codesign，以及 KaTeX 0.16.45／20 fonts 和 Mermaid 11.16.0／72 notices。standalone 為 Debug／ad-hoc，不是 Developer ID release／公證，未執行 script 印出的 launch smoke。既有 SDK／CoreData／macro 診斷不宣稱由本批修復。`git diff --check` 通過。日誌和隔離產物只留於忽略的 `.build/validation/`。Swift 測試／CustomDump／Dependencies 技能用於原 App 入口及完整值比較；SwiftUI 技能用於有界、唯讀原生卡和七語畫面；文件技能保留最新完成範圍與歷史紀錄。

**仍未完成**：delivery-failure model follow-up；background direct／mailbox／delegated group／inbound shared runner 的 channel publication 及其 canonical projection；locators 的安全 CAS preview／open；真實 Slack／Discord／OAuth、真人／VoiceOver／最低 macOS、Developer ID release／公證。AGENT-02／整體 partial 和 48 分類不變。未 push、啟動或重啟使用者 App／Xcode，未改真實帳號／群組／聊天。本節只取代下方歷史紀錄的前景 canonical transcript／recovery／UI 缺口，不取代其他待驗收項目。

## 外部送件的原始對話保存

2026-10-06 接續 `ffcbc67`，reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。前景 bound direct／saved-group 的已核准送件現在保存原 route、conversation、sender／name、run／call、local reply quote 及完整 parsed intent。intent 保留所有 ordered source URL／alt，包括 first-image 契約不送出的圖片；實際 transport 仍只收到原 outbound，不因此讀取其他 source。這是補回正式聊天紀錄所需的保存基礎，**本批尚未產生 canonical external-publication transcript 或模型失敗通知**。

來源與 queue row／authorization 在同一 channels envelope 保存，寫入失敗整筆回滾；不是 queue／chat／CAS 跨 stores 原子交易。cached、fresh lifetime 和重開後的相同 idempotency key 都要求完全相同來源，不允許改 conversation／sender／run／call／quote／intent 或移除來源。重試與 terminal failure 保留原 row／source；原 cached receipt 仍只是最初 queued 狀態，不是目前 delivered 證據。來源只有 consistency／size bounds，不能授權 source access、收件連線、聊天寫入或恢復模型。正式 projector 仍須獨立驗證當前 canonical owner／destination。

模型不能指定 host provenance；只有兩條既有前景入口加入它，background／mailbox／delegated group／inbound 不繼承。legacy human／scoped queue 保持 `origin == nil`，不猜測或自動遷移到聊天；含損壞來源的 envelope 在重寫或 sending recovery 前拒絕，保留原 bytes。既有外部核准、account／lifetime／configuration revision、附件 quota 和不可召回已排隊訊息的界線不放寬。

有效 baseline `channel-origin-red-v2.log` exit 1：保留新增 App assertions、使用原 `ffcbc67` production，2 methods／2 suites／36 parameter cases 中 6 issues 重現沒有來源欄位。`channel-origin-red-v1.log` 的 nested compiler sandbox 拒絕沒有執行測試，不當產品紅燈。`channel-origin-focused-v2.log` 的 62 App issues 發生在受限系統服務的本機 bookmark／離屏 render；相同最後來源在具備必要本機系統存取的 `channel-origin-focused-v3.log` exit 0，48 tests／5 suites，包含完整 direct／group 既有入口回歸，沒有降低產品 sandbox 或跳過失敗測試。

新增 8 個方法／47 parameter cases，另加 3 個 strict model-fields cases，共 50 個新增 cases；既有 6 個 App 核准成功 cases 另比對實際 host source。隔離 stores、固定核心 identity／商業時間、fake connectors／downloader 與完整 CustomDump 值比對涵蓋文字／附件／gallery、source bounds、保存故障、Stop／cancel、重開／重試／terminal failure、損壞來源和 legacy rows。保存完整 intent 不等於額外 source fetch、local publication 或 remote delivery。

最後來源的完整串行 `channel-origin-full-final-v1.log` exit 0：17 個 Swift Testing target summaries 合計 2,060 tests／245 suites，另 17 個 XCTest bundles 合計 135 tests／0 failures；App target 為 751 tests／97 suites。兩項 opt-in installed Codex live tests 依既有設定 skipped，不算 live 驗收。`channel-origin-localization-final-v1.log` 七語各 1,814 keys／0 missing。`channel-origin-native-final-v1.log` 的 `Filicon App`／arm64 Debug BUILD SUCCEEDED，並確認新來源檔案實際參與編譯；`channel-origin-native-verify-final-v1.log` 及新的 `ChannelOriginPackage/Filicon.app`／`channel-origin-package-final-v1.log` 均 exit 0，驗證 version 0.1.0／build 1、四個 executables、app／XPC entitlements、deep strict codesign 及離線 KaTeX／Mermaid。standalone 為 Debug／ad-hoc，不是 Developer ID release／公證；沒有執行 script 印出的 launch smoke，既有 SDK／CoreData／macro 診斷不宣稱由本批修復。`git diff --check` 通過。

Swift 測試／CustomDump／Dependencies 技能用於原 App tool loop、受控依賴與完整狀態比對；文件技能保留保存基礎與未接線流程的界線。日誌及隔離產物只留於忽略的 `.build/validation/`；本批沒有新增 UI 或截圖驗收。

**仍未接線**：canonical external-publication transcript／recovery／UI、delivery-failure model follow-up，以及 background direct／mailbox／delegated group／inbound shared runner 的 channel publication。live 帳號／服務、真人／VoiceOver／最低 macOS、release／公證仍待驗收，AGENT-02／整體 partial 和 48 分類不變。未 push、啟動或重啟使用者 App／Xcode，未改真實帳號／群組／聊天；下方歷史驗收紀錄保留。

## 已綁定成員的前景單獨聊天頻道送件

2026-10-06 接續 `048a710`，reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。已綁定有效 agent 的前景 direct chat 現在支援 `SendMessage channel` 的文字、本機附件及 HTTPS 附件，沿用下節群組的 source／send 分開核准、captured bytes、first-image caption 和 quota-backed CAS。收件連線屬於實際 bound agent，不是聊天 UUID、目前選取的聊天或另一位成員；tool receipt 的 sender 仍保留原 direct conversation identity。

沒有 binding、自身連線缺失／歧義、外帳號／peer 連線或不支援附件時，先拒絕而不讀檔、下載、排隊或回退本地 publication。只有這條前景入口取得 channel capability；reviewed background direct-session routine 不繼承。`conversations` 的 binding、provider／model、hidden 狀態或刪除會同步退休原 lifetime，即使改回相同值也不復活；Stop／account transition 在首次 await 前關閉，approval 註冊前後、broker activation 後及返回後重驗捕捉的 owner／generation。單純換到別的聊天或改標題不撤銷原送件；在別的聊天不能代替原核准。

本機 read、每個 HTTPS 原 URL／redirect 與精確 external send 各自要求同意，auto-review 開關不代替人類決定。核准卡保留完整 caption、目的地、檔名／MIME／大小／SHA-256／exact source URL、未送出的圖片與 queued-not-delivered／Stop 提示。核准後送捕捉的同一份 bytes，不重新開啟 pathname；安裝後連線撤銷可以留下孤立 CAS，由 quota inventory 計費，但不得入列。既有每附件 8 MiB／image 5 MiB、local helper transport bound、durable queue revision／retry 防護不放寬，也不宣稱跨 store 原子性或已排隊訊息可召回。

direct review card 現在也保存完整 `agentMessage`。renderer 只翻譯 host 固定的核准標題、finding／target wrapper 及 typed approve／reject actions；自訂標題、任意 payload、URL query、檔名和其他 action labels 原樣保留。新增 saved-card 語言切換與完整 presentation 比對；法／西／日／韓／繁中／簡中共修正 11 個既有相關翻譯，沒有新增 keys，也不把此局部修正當作全 catalog 語意驗收。

有效 App baseline `direct-channel-baseline-v1.log` exit 1：保留新 fixture、使用原 `048a710` AppModel，1 test／1 suite 重現沒有獨立 channel review／queue。最後聚焦 `direct-channel-focused-final-v3.log` exit 0：96 tests／10 suites，包含既有群組文字／附件、queue、local execution fence、auto-review、typed card action 及 reviewed background direct-session。新增 direct suite 為 7 個方法／94 parameter cases，使用隔離 stores、fake provider／connectors／downloader 和必要的隔離 LocalProcessHost／HMAC，覆蓋拒絕、Stop、account／binding／route ABA、連線撤銷、pathname 改變、redirect denial、first-image 與 corrupt-image。早期 fixture 編譯、等待錯誤 card ID 與 OCR 把網址 `2` 認成 `Z` 的失敗保留日誌，不當產品紅燈或 URL mutation 證據。

真正 pending-review 的 unshown NSHostingView 產生 source／send 七語 × 340／620 points × 明暗共 56 張 direct card PNG，位於 `direct-channel-cards-final-v3/`。main 逐張檢視其中 14 張，涵蓋全部七語的 source／send、兩種寬度與明暗；全文首尾、URL、附件 metadata、未送出的圖片、提示及核准／拒絕按鈕沒有截斷或重疊。OCR 檢 marker，exact query／full details 由另一路完整值 assertion 檢查。`direct-channel-localization-final-v1.log` 七語各 1,814 keys／0 missing。這些離屏畫面不是完整 transcript viewport 捲動、真人 mouse／keyboard focus、VoiceOver 或最低 macOS 驗收。

最後來源的完整串行 `direct-channel-full-final-v1.log` exit 0：17 個 Swift Testing target summaries 合計 2,052 tests／244 suites，另 17 個 XCTest bundles 合計 135 tests／0 failures；App target 為 751 tests／97 suites。兩項 opt-in installed Codex live tests 依既有設定 skipped，不算真實模型／服務驗收。`direct-channel-native-final-v1.log` 的 `Filicon App`／arm64 Debug BUILD SUCCEEDED；`direct-channel-native-verify-final-v1.log` 及新的 `DirectChannelPackage/Filicon.app`／`direct-channel-package-final-v1.log` 均 exit 0，檢查 version 0.1.0／build 1、四個 executables、app／XPC entitlements、deep strict codesign 和離線 KaTeX／Mermaid resources。原生建置沿用既有隔離 DerivedData 與限定的 `--xcode-debug` 規則；standalone 是 Debug／ad-hoc，不是 Developer ID release／公證。沒有執行 script 印出的 launch smoke；既有 SDK／CoreData／macro 診斷不宣稱由本批修復。`git diff --check` 通過。

Swift 測試／CustomDump／Dependencies 技能用於原 App tool loop、受控 dependencies、固定 identity、隔離故障與完整值比對；SwiftUI 技能限定翻譯 typed host UI 並驗證七語真實卡片。文件技能保留此入口與其他路由的界線。日誌、PNG 和隔離產物留在忽略的 `.build/validation/`。

**仍未接線**：background direct、mailbox、delegated group、inbound shared runner 的 channel publication，canonical external-publication transcript 與 delivery-failure model follow-up。原 inbound 一次純文字 reply 不變；live Slack／Discord／OAuth、真人／VoiceOver／最低 macOS、release／公證仍待驗收，AGENT-02／整體 partial 及 48 分類範圍不變。未 push、啟動或重啟使用者 App／Xcode，未改真實帳號／群組／聊天。本節只取代下節前景 bound direct 缺口，其餘歷史紀錄保留。

## 前景群組的 channel 附件與 HTTPS source 核准

2026-10-06 接續 `88aae1c`，reference HEAD 仍是 `a9f633e09d49a85829b8236331b9e21f7e612634`。main 再讀 `source/shared/channel-messaging.ts`，保留文字取第一個 image URL＋text caption，以及 standalone attachment URL／alt；本批只接上真正前景 saved-group 的附件能力，取代下節 text-only App 邊界，不當全 route 或 live 平台完成。

`AgentChannelAttachmentSource` 將 preparation、CAS install 和 queue 分開。本機沿用 exact authorized root 的 reader；HTTPS 原 URL 和每個 redirect 都需獨立、fresh 人類核准，目的地送件核准不能授權 source fetch，generic auto-review allow 也不代替它。選取自身唯一 enabled connection／registered connector 後，若介面不支援附件，先拒絕而不要求 file／download access。remote source filename 在問核准前驗證，不接受 host image IDs；下載結果重驗 original reference、非空／長度，不信 declared MIME。圖片由真正 decoder 驗證，metadata 用同一 pure projector，沒有 projection 階段 blob 寫入或 source pathname reopen。

下載沿用既有 ephemeral、無 cache／cookies／credentials 的 bounded HTTPS GET，原 downloader 的 timeout、reviewed redirect 上限／loop／TLS 規則不降低。每 attachment 的 host bound 為 8 MiB，image 5 MiB，local helper 10 MiB transport 不是額外 quota；connector 25 MiB 不允許繞過 host 每記錄／總儲存限額。這不是 DNS pinning、全面 private-IP 封鎖或真實網路驗收。

送件 review 保留完整 caption、own connection／platform:chat、filename、MIME、跟隨 App 語言的 size、SHA-256 和 exact source URL。first-image 模式另列出所有未送出的 URL／alt；排入 queue 不代表 delivered，Stop 不召回已入列訊息。核准後以 captured immutable bytes 做 quota reservation／CAS install，不重新開啟來源。channel inventory 納入 ledger，active 與 retained quarantine 相同 digest 的兩份實體 bytes 分開計費。install 成功而 queue 失敗仍可能留下 orphan CAS，reconciliation 會計入；不宣稱跨 stores 原子交易、exactly-once 或跨 process CAS。

有效 App baseline `channel-attachment-native-baseline-red-v3.log` exit 1：1 test／3 issues，在還原原 AppModel、保留新 fixture 的狀態，重現 attachment capability 未接線，沒有 local read review／結果／queue；之後恢復本批 forward diff。v1 fixture 編譯、v2 未等 Task 開始即讀 finished 狀態不是有效產品紅燈。早期 focused-v2 的 error enum 拼字、v4 quota fault fixture 未辨認 UUID-keyed Codable array、v5 dynamic localization overload、v6 OCR 將 Latin a 視為 Cyrillic confusable，亦保留日誌但不當產品證據；exact URL 仍由獨立 state assertion 檢查，不靠 OCR confusable 字元認定 equality。

完整串行 `channel-attachment-full-final-v1.log` exit 1：新增附件 routes 通過，但既有 `stoppingAnActivityConfirmationRetiresAnAdmittedReviewWhoseCompletionDidNotSave` 在 local approval 返回後仍寫入隔離的 `activity-created.txt`。沒有略過該測試或以聚焦單獨通過當成全套通過。root cause 是同步退休 host scope，並未跨 local approval await 保存到 executor／runtime，actor cancellation 可以晚於 approval。

工具現在 capture 原背景 run／account execution check，policy／local approval await 後及 runtime bookmark resolution 後、helper dispatch 前重驗；不重新 lookup／capture 新 generation。Stop 不放寬核准、不把正常 denial 改成 permission。`channel-attachment-stop-fence-red-v3.log` exit 1：2 tests／1 suite／5 issues，以新增 capture-hook scaffold 但未啟用檢查的 executor，確定性重現 late allow、late deny、fresh generation 的舊回合未退休；這是 scaffold red，不冒充未新增 hook 的 HEAD unit baseline。v1 nested compiler sandbox 拒絕及 v2 async CustomDump autoclosure 編譯失敗不是產品紅燈。原 full-v1 的實際 App 寫檔失敗為獨立 integration 證據。新 runtime checkpoint 測試檢查 pre-bookmark／post-bookmark／pre-helper 三處，並明示已 admitted helper work 不可召回，只丟棄其晚到結果；正常有效回合的 local approval 控制組仍成功。

最後 source `channel-attachment-focused-final-v9.log` exit 0：85 tests／10 suites（core 23／3、channels 14／1、App 48／6），包含完整 RoutineDirectSessionTests、ProcessResultPresentationTests 及新增 retirement suite。source adapter 的 22 format/image、9 HTTPS、8 local 及 3 unavailable cases；真正 App 的 local 26、11 actual formats、HTTPS 26，以及 active/quarantine reconciliation 均以隔離 stores、fake connectors／downloader 和必要的隔離 LocalProcessHost／HMAC 驗證，不冒充 shipping XPC service 驗收。quota reserve／commit failure、source mutation、Stop／account／membership／connection、redirect denial、corrupt image 和排隊結果有完整 state／bytes 比對。沒有讀真實 Keychain、HTTP、群組或聊天。

真正 pending-review 的 unshown NSHostingView 產生 source＋send 各七語 × 340／620 points × 明暗，共 56 張新附件 PNG；原文字回歸另 28 張，共 84 張，位於 `channel-attachment-cards-final/`。OCR 檢 caption 首尾／destination／digest／excluded image 等 markers，state 另檢 exact details。main 重新檢視 v8 的 14 張覆蓋七語；v9 的 80 張 SHA-256 與 v8 一致，四張 Korean send cards 因 Type 翻譯修正變動，四張均逐張重檢。韓文 Type／Size／bytes 舊翻譯與日文 Size 冒號一併修正，新 size formatter 使用所選 App locale。`channel-attachment-localization-final-v2.log` 七語各 1,814 keys／0 missing；這不是全 catalog 語意或真人 gesture／keyboard focus／完整 transcript viewport／VoiceOver 驗收。

最終 gates 均 exit 0：完整串行 `channel-attachment-full-final-v2.log` 為 17 個 Swift Testing target summaries 合計 2,045 tests／243 suites，另 17 個 XCTest bundles 合計 135 tests／0 failures。App target 為 744 tests／96 suites，原 Stop integration 在全套通過；兩項 opt-in installed Codex live tests 依既有設定 skipped，不能算 live 驗收。完整 Xcode 的 `Filicon App`／arm64 Debug 使用既有隔離 DerivedData，`channel-attachment-native-final-v1.log` 為 BUILD SUCCEEDED；`channel-attachment-native-verify-final-v1.log` 驗證 version 0.1.0／build 1、四個 executables、app／XPC entitlements、deep strict codesign 及離線資源。新的 `ChannelAttachmentPackage/Filicon.app` 與 `channel-attachment-package-final-v1.log` 完成 standalone Debug packaging 和相同 verify。只建置／檢查，沒有執行 script 印出的 launch smoke；ad-hoc Debug 不當 Developer ID release／公證證據。`git diff --check` 通過。

Swift 測試／CustomDump 技能用於固定 core 商業時間／IDs、受控 dependencies、原 App tool loop、故障注入及完整值比對；SwiftUI 技能驗證真正 card，SPM 技能移除前批兩個 test targets 的 redundant Channels dependency，仍沿用既有 targets／transitive module，不新增套件或降低最低 OS。文件技能保留失敗類別、原 reference 和未接線邊界。日誌、PNG 與隔離產物只留於忽略的 `.build/validation/`。

**仍未接線**：direct／mailbox／delegated group／inbound shared runner 的 channel publication、canonical external-publication transcript 及 delivery failure model follow-up；原 inbound 一次純文字回覆不變。live Slack／Discord／OAuth、真人／VoiceOver／最低 macOS、release／公證仍未驗收，AGENT-02／整體 partial 和 48 分類範圍不變。未 push、啟動或重啟使用者 App／Xcode，未改真實帳號／群組／聊天。

## SendMessage 的前景群組頻道文字核准

2026-10-05 接續 `86d9a3b`，reference 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。這批將 host queue API 接上 `AgentChannelPublicationTransaction`、bound SendMessage schema／adapter 及真正 AppModel 的前景 saved-group 文字 publication。下節 foundation 的「schema／UI 未接線」保留為該 commit 的歷史階段，由本節限定取代；不是全 route／附件／canonical transcript 或外部服務完成。

channel 只接受 `type:text + content` 或有 opt-in captured source capability 的 `type:attachment + url/alt`，strictly reject legacy text、widget、secret、cloud-agent、host image IDs、model account／agent／connection IDs 及 mixed fields。address 解析後由服務選 host account／agent 的唯一 enabled Slack／Discord 連線，未擁有／歧義／外帳號／disabled／未註冊拒絕，source approval 不能代替 destination authority。只有 exact conversation／sender 綁定可宣告 capability；native 前景入口只有 text，不廣告或悄悄讀取附件／HTTPS。conditional schema 的非 channel 分支完整保留原 schema；source opt-in 不擴張本地 gallery／attachment 權限，另以 sorted JSON 完整比對回歸。

core 的 source preparation 與 install closures 必須成對提供，HTTPS 另需 host opt-in；本批 fixtures 用 immutable captured bytes，不作真實 download。image 用真正 image decoder 驗證 MIME／bytes，installer 必須回 exact SHA-256／basename／MIME／length。文字 images 只選第一個 URL，文字為 caption，完整 intent 與 ignored occurrences 保留在 review；獨立附件 alt 為 caption。所有 source／publication／queue await 之間重驗 scope，關閉中途操作不觸及 queue；已裝入但 queue 失敗可能留下 unreferenced CAS blob，尚非跨 store 原子交易。

外部和本地 publications 共用兩筆額度及 call ID；同 ID 改 payload／kind 或失敗後自動重播不取得新送件權限。exact cached result 只證明 original durable enqueue，不證明目前 status 或 remote delivered；after-save 不再用 late cancellation 把成功寫成失敗。local `reply_to` 必須解析原 bounded directory，只供 review quotation，從不當 external thread；queue ID 不加入本地 reply directory。底層 persistent revision、credential write retirement、restart／retry validation 與原值 rollback 延用 foundation。

AppModel 逐次等待人類決定，完整 payload、connection display name、platform:chat 和 queued／Stop disclosure 保留在 `agentMessage`，不受 summary 的 2,000-character bound 截斷。自動審核開關不略過這步。session parent lifetime 在 Stop／account transition 的第一次 await 前關閉，child turn 關閉不退休 siblings；成員修改先停止原工作，connector 即使 descriptor 相同重新註冊也使舊 proposal 失效。為 native integration 注入 ChannelService／connectors，production defaults 不變；fixtures 完全取代 REST，普通 delivery observer 也不能碰真實 Keychain／HTTP。

有效 adapter baseline `channel-message-adapter-red-v1.log` exit 1：2 tests／1 suite／7 issues，在新 transaction 已存在但 adapter 尚未接線時重現未宣告 channel、文字／附件被拒、沒有 source／review／queue。這是 adapter runtime red，不冒充尚無 transaction 的 baseline。較早權限審核容量失敗沒有執行測試，原請求經重試獲准；focused-v1 的 nonescaping closure、v2 optional descriptor description、v3 Sendable fixture／API spelling、v4 missing constructor argument、v5 inaccessible private setter 編譯失敗，以及 v6 fixture credential reference 缺少必要 prefix、v7 subpixel width 使用不當 exact equality 的失敗，皆保留日誌，不當產品紅燈。

最後 source `channel-message-focused-final-v9.log` exit 0：59 tests／7 suites（core 29／4、channels 14／1、App 16／2）。core 測試涵蓋 identity／receipt／shared budget／mixed fields／first image／own route／保存失敗／parent-child／approval、source 和 install retirement；App 測試覆蓋真正 tool loop 的 fresh human review、Stop／account／members／connection／connector、unavailable routes／不回退。完整訊息核准與 lifecycle 共 14 cases，自動審核開／關都不能代替人類決定；五種 unavailable cases 不降級成本地 publication。

七語 × 340／620 points × 明暗，共 28 張真正 pending-review 的 unshown NSHostingView PNG，存於 `ChannelMessageCards/`；每張另以英文 payload 的 OCR 首尾 markers／destination 檢查完整內容。主線重新檢視最後 v9 的 14 張，覆蓋全部七語的明暗與兩種寬度：全文、目的地、queued／Stop disclosure、核准／拒絕按鈕沒有截斷或重疊。較早 v8 雖通過，視覺抽查另發現韓文 Channel 既有翻譯尾端冒號與新 label 重複，修正後重新產生 v9 全套；七語 `channel-message-localization-final-v3.log` 各 1,809 keys／0 missing。這不是 full transcript viewport 捲動、真人 button gesture／keyboard focus 或 VoiceOver 驗收，不冒充已測原生點擊；核准／拒絕行為由 App API integration 另驗證。

最後 source 完整串行 `channel-message-full-final-v1.log` exit 0：135 XCTest＋2,030 Swift Testing／240 suites，按 17 targets 的單數及複數摘要彙總，沒有失敗（核心 997／109、App 730／93、channels 43／3）。兩項 opt-in live Codex tests 略過，不當真實模型或外部服務驗收；既有 CoreData／colorspace 診斷仍出現，相關 tests 通過，不宣稱由本批修好。最後 authored diff whitespace check 通過。

`channel-message-native-final-v1.log` BUILD SUCCEEDED；`channel-message-native-verify-final-v1.log` 與 `channel-message-package-final-v1.log` 均 exit 0，驗證 offline KaTeX／Mermaid resources、四個 executables、app／XPC entitlements 與 deep strict 簽章。原生建置只按既有 `--xcode-debug` 規則允許 debugger exception；standalone 為 Debug／ad-hoc `.build/validation/ChannelMessagePackage/Filicon.app`，不是 release／公證。首次 native 請求因權限審查服務容量不足未執行；重試同一審核請求後獲准，沒有繞過 sandbox。未執行 script 列印的 launch smoke；日誌、PNG 與隔離產物只留在忽略的 `.build/validation/`。

Swift 測試／CustomDump 技能用於精確 identity 與完整快照，SwiftUI 技能檢查真實核准卡及七語布局，SPM 技能只補測試 target 的 explicit dependency，文件技能保留來源、有效紅燈與未接線邊界。

**仍未接線**：App channel 附件／HTTPS source services、direct／mailbox／delegated group／inbound shared runner、canonical external-publication message 與 delivery failure 的 model follow-up。原有一次 inbound 純文字回覆未改；tool activity 加 durable queue 不冒充原版本地 transcript 契約。live Slack／Discord／OAuth、真人 VoiceOver／最低 macOS、release／公證、exactly-once／cross-process CAS 亦未驗收。AGENT-02／整體仍 partial，48 分類不縮減；未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天。

## 外部頻道的核准送件佇列基礎

2026-10-05 接續 `703df89`，核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `source/host/runner/tools/send-message-schema.ts`、`source/shared/channel-messaging.ts` 及 `source/host/extensions/transcript/{turn-runtime,background-wakes,transcript-manager}.ts`。原版 `SendMessage` 有 optional `channel: platform:chat`，限文字／附件；文字帶圖片時 outbound helper 取第一張並以文字為 caption，standalone attachment 使用 URL／alt。turn runtime 呼叫頻道 delivery，也保存本地 transcript；失敗另建提醒及 hidden failure wake。recovered source 只有 `setChannelDelivery` 宣告，未找到 production 呼叫，預設 delivery 丟出未註冊錯誤；這是工具／路由契約，不是原版 live 平台可用的證明。

native 原有 REST transports／人工送件不等於模型 `SendMessage channel` 接線。這批新增 `ChannelPublication`、`ChannelDeliveryAuthorization` 及 `ChannelPublicationLifetime` 的 host API，**尚未接入模型 schema、App 核准卡、canonical transcript 或 inbound shared runner**。現有 `respondToScheduledChannel` 的一次純文字回覆亦未改成這條核准路徑；外部 channel 的 AGENT-02 缺口仍 partial，其他 48 分類及外部／release 邊界不縮減。

preparation 無網路／寫入，只能選該 account／agent 的唯一 enabled Slack／Discord 連線，不借用 peer、receive-only 或外帳號；歧義及未註冊介面拒絕。proposal 公開 JSON／debug mirror 不含 credential reference、profile 或內部 fences。host 日後必須取得涵蓋精確目的地、thread、內容及所有附件 metadata 的人類同意，再使用 scoped enqueue；proposal 本身不是同意，這批沒有自動核准。Stop／account／dispatch retirement 要由尚待接線的 host 關閉 lifetime。

提交前重驗 issuer、configuration／process／registered-connector generation 與完整 descriptor；即使 descriptor 相同，替換介面也退休未提交 proposal。metadata／owner／agent／enabled／profile／remove-recreate／ABA 修改均失效；inbound cursor／activity 不誤撤銷核准。scoped queue 保存無憑證的 owner／agent／persistent configuration revision，每次 transport attempt 重驗；重開後的修改、憑證寫入嘗試（含 no-op／失敗）及 ABA 不讓待送件跟隨另一身分。若有 scoped pending rows，revision 必須先落盤才可呼叫 credential writer；保存失敗不執行 writer。沒有 pending rows 時仍先退休 process-local proposals／profile requests。legacy 人工 rows 的 optional authorization 維持 absent，不憑空授權給 agent。

同一 idempotency key 只能對應完全相同的 connection、normalized address／payload／authorization；不同內容、目的地、thread、檔案或人工／scoped 身分衝突拒絕。queue 與首次 legacy revision 在同一 atomic envelope 保存；失敗不保留 receipt 或新 authority，legacy collision 不污染記憶體或下一次保存。8,000 characters、512-byte IDs、64 files、每檔 25 MiB／總計 100 MiB、basename／MIME／lowercase SHA-256 metadata 有界；queue 只檢 metadata，既有 REST transport 讀出 bytes 後仍驗長度／SHA-256，保留 pinned HTTPS origins／redirect policy，不授予模型 URL／path 讀取權。

queued receipt 只證明已落盤，不冒充 delivered。flush／retry 保留同一地址、內容及 key，final failure 保留 durable wake。lifetime 關閉不召回已入列訊息，也不能撤回已開始的 remote request；retry 不宣稱 exactly-once、cross-process CAS 或跨 transcript／queue 原子交易。真人 App／VoiceOver、live Slack／Discord／OAuth、release／公證仍未驗收。

有效 baseline `channel-publication-baseline-red-v3.log` exit 1：2 tests／19 issues，重現五種 idempotency 替換及七種 invalid metadata 被錯誤接受。v1 compiler cache 拒寫及 v2 async assertion 編譯錯誤不是產品紅燈，紀錄保留。最後 source 聚焦 `channel-publication-focused-final-v4.log` exit 0：81 tests／7 suites（core credential／disconnect 29／3、channels 43／3、既有 secure card 9／1）。新增 14 個方法／55 cases，使用固定商業時間／delivery IDs、隔離 stores、受控 writer／transport 及 CustomDump 完整值比較；包含保存 rollback、重開、credential failure／no-op、legacy decode／collision、proposal 異動、輸入上下界、介面能力及 retry，不操作真實 Keychain／remote send。

最後 source 完整串行 `channel-publication-full-final-v1.log` exit 0：135 XCTest＋2,012 Swift Testing／238 suites，17 targets 全部跑完且沒有失敗（核心 982／108、App 727／92、channels 43／3）；兩項 opt-in live Codex tests 略過，不作外部驗收。七語 `channel-publication-localization-final-v1.log` 各 1,806 keys／0 missing，authored diff whitespace check 通過。較早 focused-v2 的 immutable fixture assignment 編譯錯誤保留，v1／v3 的成功不代替最後 v4；沒有新增 UI／dependency／scheme 或降低最低 OS。

`channel-publication-native-final-v1.log` BUILD SUCCEEDED；`channel-publication-native-verify-final-v1.log` 及 `channel-publication-package-final-v1.log` 的 standalone Debug／ad-hoc 封裝，均通過 offline KaTeX／Mermaid resources、四個 executables、app／XPC entitlements 與 deep strict 簽章。standalone 只在 `.build/validation/ChannelPublicationPackage/Filicon.app`，未執行列印的 launch smoke，不是 release／公證；原生建置的 debugger exception 只按既有 `--xcode-debug` 規則驗證。既有 compiler／CoreData 診斷不宣稱由本批修復。

Swift 測試／CustomDump 技能用於隔離失效與完整快照，SPM 技能保留既有 package target，文件技能分清工具契約、queue foundation 與未接線項目。沒有刪除 cache、改產品權限或停用 compiler sandbox；未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天。完整工具 adapter／UI／shared channel runner 仍為下一步，不因這批 gate 通過而上調整體 partial。

## Mermaid 十二類圖表及濾鏡驗證

2026-10-05 接續 `1c21bf0` 的真正聊天與預覽接線，新增 journey、timeline、quadrant、requirement 四類 fixed public-engine fixtures，與原八類合計十二類。reference 仍是 `a9f633e09d49a85829b8236331b9e21f7e612634`，執行的是已驗證公開 11.16.0 engine；官方 rolling syntax docs 只供語法參照，不當作 pinned engine 的輸出 oracle。原 opaque bytes／精確 geometry、完整語法、真人／最低 macOS／external／release 等價仍未證明；`UI-04` 及整體維持 partial，48 分類不縮減。詳見 [Offline-mermaid.md](Offline-mermaid.md)。下節八類 UI 紀錄保留為前一批證據。

`mermaid-grammar-families-red-v1.log` exit 1，在真正 engine 的兩種 appearance 重現 journey／timeline 被 output gate 拒絕（1 test／4 issues）；`mermaid-grammar-svg-red-v1.log` exit 1，以獨立 SVG fixtures 重現 inert journey 標籤與五種正常 brightness 的誤拒（8 tests／6 issues）。journey 的 static `switch`／enumerated overflow 現在可通過，缺少 namespace 的 plain `foreignObject` label root 明確正規化為 XHTML。namespace override、HTML 在 label 外、active child／event／external resource 仍拒絕；序列化重驗保持 idempotent，不將 raw engine output 直接顯示。

timeline 的 brightness 限單一有限值 0–2 或 0–200%。新增此函式時，額外拒絕測試抓到既有 shadow prefix 可夾帶 brightness，及 URL prefix／SVG attribute 的檢查差異：`mermaid-grammar-filter-composite-red.log` exit 1（1 test／2 issues），`mermaid-grammar-filter-attribute-red.log` exit 1（9 tests／8 issues）。最後 SVG filter attribute 與 CSS 共用檢查；URL 開頭的 filter 必須是完整單一 local reference，brightness 不得藏在 shadow／URL 的組合值後。超量／非有限數字／resource cycle 仍拒絕，既有 source、output、node、depth、attribute、geometry、queue、cache 與 deadline bounds 不變，沒有新增 network、file、script 或 tool authority。

最後 source 聚焦 `mermaid-grammar-all-focused-final-v2.log` exit 0：60 tests／11 suites（backend 26／4、App 34／7），包含真正十二類明暗 engine、73 個 unsafe-output 拒絕案例、queue／cancel／resources、既有 native click／keyboard／lifecycle／七語 figure／viewer 回歸。真正 direct／group route 是 26 個 English fixture cases，每個測兩種 appearance，合計 48 個正常 diagram render 與 4 個 unsafe 原文 fallback；journey 另要求非空 HTML labels 全部具有正確 XHTML namespace。不是以空集合通過 namespace 斷言，也沒有把測試文字自動翻譯成 UI 語言。窗口皆 unshown，原 messages 不改寫。

新增四類的 380-point figure／540×420 viewer 共 16 張 native controls 加 actual WebKit snapshot 已檢視，另檢查八張 actual-route SVG crop，覆蓋四類的 direct light 與 group dark。最終 V2 相較 V1 有十二張 composite PNG 的 SHA-256 相同；四張 requirement PNG 不同，已逐張重新檢查 V2，沒有把差異當作 pixel-identical 保證。標籤及 fit bounds 正常、dark canvas 無白邊；DOM／OCR／native expand-button bounds 為獨立檢查，不以空白 host bitmap 冒充 render。這仍不是真人 VoiceOver、OS full-screen 或最低 macOS 驗收。

最後 source 完整串行 `mermaid-grammar-full-final-v1.log` exit 0：135 XCTest＋1,998 Swift Testing／237 suites，17 targets 全部跑完且沒有失敗（核心 982／108、App 727／92）；兩項 opt-in live Codex tests 略過，不作外部驗收。`mermaid-grammar-localization-final-v2.log` 七語各 1,806 keys／0 missing，`mermaid-grammar-resources-final-v1.log` 驗證 75 個 Mermaid resources，authored diff whitespace check 通過。較早 localization-v1 呼叫不存在的 script，屬命令錯誤而不是產品紅燈，失敗日誌保留。

`mermaid-grammar-native-final-v1.log` BUILD SUCCEEDED；native verify 及 `mermaid-grammar-package-final-v3.log` standalone Debug／ad-hoc 封裝均通過 offline KaTeX／Mermaid resources、四個 executables、app／XPC entitlements 與 deep strict 簽章。standalone 只在 `.build/validation/MermaidGrammarPackage/Filicon.app`，未執行列印的 launch smoke，不是 release／公證。package-v1 的 compiler cache 寫入拒絕、v2 的 nested `sandbox-exec` 拒絕保留；把 module cache 指向專案內目錄後，經建置權限審核的 v3 成功，沒有停用 compiler sandbox 或改產品權限。既有 compiler／CoreData 診斷不宣稱由本批修復。

低磁碟空間時，先按舊成功日誌與實際路徑確認，只移除五份自有隔離 DerivedData（`LocalGalleryFormatsNative`、`GalleryRepeatNative`、`GalleryCardinalityNative`、`MixedGalleryNative`、`GalleryAnimationNative`）各自的 `SDKExplicitPrecompiledModules` 及 `Index.noindex`，共十個可重建快取目錄；保留 Products、sources、logs、screenshots、repository metadata 與使用者資料。沒有刪除正在建置所用的 cache，或以其他目錄代替失敗的刪除目標。

本批沿用 Swift 測試／CustomDump 的隔離 fixtures 與完整值比較、SPM 技能的既有 targets／dependencies／最低 OS 邊界；文件技能將新增正常語法、安全紅燈與最後 gates 分開記錄。不新增 dependency、改 scheme 或降低安全 bounds。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天。

## 公開 Mermaid 圖表的聊天與預覽接線

2026-10-05 接續 `f662371` 的離線後端，真正 `TranscriptMessageView`／`GroupMessageBubble` 現在以 `OfflineMermaidView` 顯示 independently validated public-engine SVG，不再只顯示三種 native parser 的圖表。已核對的八類是 flowchart、sequence、state、pie、class、entity relationship、Gantt、mindmap；不將這些 fixtures 外推為完整語法、原版 opaque bytes／精確 geometry 或全功能完成。reference 仍是 `a9f633e09d49a85829b8236331b9e21f7e612634`，公開 11.16.0 的來源與 output gate 邊界不變，詳見 [Offline-mermaid.md](Offline-mermaid.md)。下節 backend-only 的「UI 尚未接線」保留為前一批歷史紀錄，由本節取代。

等待時有七語 progress label 與可選取原文；invalid／unsafe／unavailable 或 static display failure 都回退原始 source，不載入 raw engine SVG／error HTML。source／appearance／移除／取消按 exact request 及 revision 撤銷；同 source 消失後重現也有新的 lifetime，舊 click／failure／child close 不能開啟或關閉新 preview。whole-figure 與 native expand button 支援 click、focused Return／Space；重複開啟沿用同一 viewer／transform，parent 移除與關閉清理自己的 child window。

獨立 `MermaidSVGWebView` 只顯示已通過 native gate 的 static SVG，不載入 Mermaid engine。nonpersistent、page JavaScript disabled、CSP offline fonts only、navigation／downloads／popups／dialogs 拒絕；native isolated-world operation 只等待 fonts 後設定有界 viewport transform 與 appearance。geometry ticket 在 JavaScript 的 await 後再次檢查，native callback 另核對 document／view／revision，防止晚到 transform 改寫新畫面。十秒 display deadline 與 process failure 回退原文；仍不是 hard process termination 或 CPU／memory ceiling。native viewer 保留 pointer zoom／drag／fit／keyboard，20,000-point logical SVG 的 8× zoom 仍使用 viewport-sized surface。resize 按 reference 保留已選 scale，實際 F 鍵／fit 重新置中。canvas 明暗可在同 surface 更新，不 reload SVG 或丟失 transform。failure 時撤除 pan／zoom input overlay、停用無作用的縮放按鈕，原文選取與雙向捲動不再被攔截。

有效紅燈包括 actual-route advanced families 缺少 expand action（`mermaid-ui-advanced-route-red-v2.log`）、same-source lifetime 的舊 callback 改壞新 figure（`mermaid-ui-same-source-failure-red.log`）、七語 dark WebKit corner 實際仍白色（`mermaid-ui-dark-canvas-red-v1.log`）與 failed viewer 殘留 input overlay（`mermaid-ui-fallback-input-red-v1.log`）；修正 production 邏輯後均通過。較早 helper 編譯／簽章失敗不是產品 baseline；v5 重用 figure model 建立第二窗口、v7 預期 resize 自動 fit 都是 fixture 錯誤，已核對 reference 再修正 oracle，沒有放寬 SVG bounds。v6 host／WebKit composite 的 HiDPI 與 copy blending 錯誤已修正，不能把那批圖片當視覺驗收。

最後聚焦 `mermaid-ui-all-focused-final-v9.log` exit 0：33 tests／7 suites，含十八個真正 direct／group route cases（八類正常圖表及 unsafe output 原文 fallback）、native click／Return／Space、七語明暗、source/theme／cancel/removal／同源新 lifetime、display deadline／WebKit process／old document／geometry/font callback、page script 與外部 navigation 拒絕。所有窗口 unshown，使用隔離 App fixture；原 messages 未被改寫。實際 WebKit snapshots 與 native controls 合成的二十八張 380-point figure／540×420 viewer（v8）已逐張檢查，標籤沒有裁切、dark canvas 沒有白邊；v9 這二十八張 PNG 的 SHA-256 全部相同，並重新檢查繁中 light figure 與法文 dark viewer。八個不同 family 的 route SVG crop 另有人工檢查。OCR／actual fitted DOM bounds／dark corner pixels 為獨立斷言，沒有拿只有 host bitmap 的空白 surface 冒充 render。這仍不是真人 VoiceOver、OS full-screen 或最低 macOS 驗收。

最後 source 完整串行 `mermaid-ui-full-final-v2.log` exit 0：135 XCTest＋1,994 Swift Testing／237 suites，全部 17 targets 通過（核心 982／108、App 726／92）；兩項 opt-in live Codex tests 略過，不作外部驗收。較早 full-v1 同樣通過，但在 failure input overlay 修正之前，不能代替這份最終結果。七語各 1,806 keys／0 missing、authored diff whitespace check 與 75 個 Mermaid resources verification 通過。`mermaid-ui-native-final-v1.log` BUILD SUCCEEDED，native verify 與 `mermaid-ui-package-final-v1.log` 的 standalone Debug／ad-hoc 封裝均驗證 offline KaTeX／Mermaid resources、四個 executables、app／XPC entitlements 與 deep strict 簽章；standalone 產物只在 `.build/validation/MermaidUIIntegrationPackage/Filicon.app`。沒有執行列印的 launch smoke，不是 release／公證。既有 CoreData NSXPC 診斷與 compiler warnings 不宣稱由本批修復。

早期低磁碟空間的 build／codesign 失敗保留，沒有把環境失敗當產品紅燈或改寫日誌。按舊 log 確認後，只移除 `.build/validation/markdown-prose.SDrQnO` 下四個自有可重建 build/cache 子目錄：`spm/out`、`native/Build`、`native/Index.noindex`、`native/SDKExplicitPrecompiledModules`，保留 sources、checkouts、screenshots 與 logs；沒有刪使用者 App／資料或 repository metadata。不因空間回復而宣稱所有簽章錯誤只有單一原因。

本批用 SwiftUI／observable-models 技能將 async lifecycle 留在可測 model，testing／CustomDump 技能控制晚到 callbacks 與完整值，SPM／Xcode 技能只新增兩個 source 的八筆 project membership，不改最低 OS／dependencies／scheme。文件技能將實際 UI 證據與完整語法／opaque geometry／真人／最低 macOS／hard containment／external／release 邊界分開。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天；`UI-04` 及整體仍 partial，48 分類範圍不縮減。

## 公開 Mermaid 引擎的離線後端與 SVG 驗證

2026-10-05 接續公開資源批次，新增 `OfflineMermaidRenderer` 與獨立 `MermaidSVG` output gate。這是後端增量，尚未取代真正 transcript／viewer 的三種 native diagram；不能把八類引擎 fixtures 當成新增可見 UI 能力。reference 來源與公開 11.16.0 候選／opaque asset 的界線不變，詳見 [Offline-mermaid.md](Offline-mermaid.md)。

非持久離屏 WebKit 只在 native isolated content world 評估已驗證 engine，page JavaScript 關閉；source 以函式參數傳入，沒有 message handler／host tools／opener。CSP 禁止 script、網路、圖片、frame、worker、form；只有已驗證的 offline math fonts 可使用 data resources。每次重設 strict、明暗主題、deterministic IDs、65,536-byte source／1,000 lines／512 edges，secure config 不讓 frontmatter 覆寫；只 parse／render，不呼叫 `bindFunctions`。navigation／downloads／popups／dialogs 均拒絕。

strict 的實際 output 仍可能包含外部 `img`，因此所有輸出在交給 consumer 前另經 XML／SVG／XHTML／MathML／CSS 白名單、local fragment 與有限 geometry 檢查。scripts／events／images／links／frames／forms／editable elements／SVG animation elements／外部資源／CSS escapes 或 imports／entities 拒絕；2 MiB output、16,384 nodes、128 depth、65,536 bytes per attribute 及有限正 viewBox／numeric geometry／shadow bounds 保留。direct attribute／inline style 的 fragments 必須有 target，resource definition 不允許 recursive references；stylesheet 可有未使用的 local fragment，但不得 external。public engine 的 later duplicate IDs 去除、bare `undefined` inline CSS statements 移除，只保留 first-target semantics 與無效 no-op，不加入新 resource。output 重驗 idempotent；CSS keyframes 仍屬接受子集，不宣稱所有動畫已移除。

單一 FIFO active render、最多 32 requests、source/theme LRU 最多 64 entries／8 MiB（含 source）及 20-second soft client deadline。queued duplicate 可借用已完成快取；invalid／unsafe deterministic result 可 cache，timeout／cancel／transient failure 不 cache。active cancellation、deadline 或 process termination 退休自己的 surface，queued cancellation 不取消其他 request；request ID／surface identity／revision fence 拒絕晚到 callbacks，後續可重建 surface。沒有以 deprecated `WKProcessPool` 偽稱 separate process；public WebKit API 不提供 uncooperative process 的 hard kill 或 hard CPU／memory limit。

最後聚焦 `mermaid-engine-focused-final-v1.log` exit 0：23 tests／4 suites，含既有 resources 與新 SVG／queue／actual WebKit suites。八種 diagram families × 明暗共十六個 actual-engine outputs 均通過 geometry 與 idempotent gate；frontmatter／external image fixture 拒絕、isolated-world config 保留 strict／512 edges／empty theme CSS，獨立查 `.page` 沒有注入執行。實際 cancel／fresh-surface recovery 與 old process callback、FIFO／duplicate/theme isolation／count＋byte eviction／overflow／shutdown／stale deadline／unsafe output／budgets 另有測試。早期 access／async assertion compile failures 不當成產品 baseline；v2 的安全 gate 不接受正常 shadow／selector、fixture mindmap indentation，以及 v3 的 inert engine artifacts／inactive local stylesheet rules 造成的 failures 留存，按真實 output 修正並保留 active-resource 拒絕，沒有直接接受所有 raw SVG。

最後 source 完整串行 `mermaid-engine-full-final-v1.log` exit 0：135 XCTest＋1,976 Swift Testing／234 suites，全部 17 targets 通過（核心 982／108、App 708／89）；兩項 opt-in live Codex tests 略過，不當作外部服務驗收。Ruby 2.6 不支援 `filter_map` 的彙總命令失敗另行修正，沒有改寫原日誌或測試結果；統計含單數 `suite`。七語各 1,805 keys／0 missing、authored diff whitespace check 及 75 個 Mermaid resources verification 通過。`mermaid-engine-native-final-v1.log` BUILD SUCCEEDED；native verify 與 `mermaid-engine-package-final-v1.log` standalone Debug／ad-hoc 封裝均驗證 KaTeX／Mermaid resources、四個 executables、app／XPC entitlements 與 deep strict 簽章。standalone 產物只在 `.build/validation/MermaidEnginePackage/Filicon.app`，未執行列印的 launch smoke，不是 release／公證。既有 CoreData NSXPC 診斷仍保留，不宣稱由本批修復。

本批使用測試／CustomDump 技能檢查完整值、固定商業 IDs 與隔離 fixtures，文件技能區分後端證據和 UI 未完成。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天。async figure、原文 fallback、static SVG surface、viewer 及 actual UI lifecycle 尚未接線；完整語法／opaque geometry／真人／最低 macOS／hard runtime containment／外部／release 仍待驗收，`UI-04` 及整體 partial，48 分類範圍不縮減。下節是前一批 resource-only 的歷史紀錄。

## 公開 Mermaid 的離線資源與授權告示基礎

2026-10-05 再核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `mermaid.tsx`：它以 strict runtime 做 `initialize`／`parse`／`render`，但 opaque `mermaid.core-CYC_FcEu.js` 不在 recovered checkout。根 lockfile 沒有 Mermaid dependency tree；recovered contract 的 `^11.16.0` 只讓公開 11.16.0 成為替代候選，不證明原 shipped version／bytes／layout。

本批保留目前三種 native diagram parser／viewer，不新增 UI 語法能力。從 pinned public archive 匯入未修改的 IIFE engine／MIT notice；source map 顯示 59 個外層 package/version identities，pre-bundled parser 再包含 12 個。其 32 個 parser source entries 與公開 `@mermaid-js/parser` 1.2.0 archive 逐 byte 相符，連 parser 本身告示共 72 個 component notices。patched／peer suffix 保留原 source identity，沒有把它們冒充 registry code 等價；每個依賴 archive 只讀 original license document，不 install 或執行其程式。完整來源與限制見 [Offline-mermaid.md](Offline-mermaid.md)。

importer 在任何 vendor write 前驗證全部 archive SHA-512、locked entry bytes／SHA-256 和每層 destination，拒絕 missing／changed input、duplicate entry、symlink 和未知既存檔案。runtime／封裝 verifier 固定 manifest，再驗 engine／MIT／72 notices；runtime 有 manifest／per-file／total bounds，整個 bundle 缺失不呼叫 trapping `Bundle.module`，damaged preferred bundle 不借用另一安裝。取得 verified string 不等於執行 script，更不提供網路、導航或 host tools。

`mermaid-assets-focused-v1.log` exit 0：19 tests／3 suites；五個新方法涵蓋全部 75 個檔案的 modified／missing、五種 identical-byte symlink、root／兩層 notices directory、whole-bundle missing／damaged preferred。提供 pinned local inputs 的 `mermaid-resources-final-v2.log` 為 9 runs／420 assertions／0 failures／0 errors／0 skips，包含全部檔案重複 byte-preserving 再匯入及 late invalid input 不部分覆寫。新增 repository attributes 對兩個 offline vendor folders 關閉 text conversion／filters／ident expansion；獨立 Git index／export fixture 在 `core.autocrlf=true` 下仍逐一保留全部 Mermaid bytes，不 commit 或執行 user hooks。前一版 8／342 的日誌保留。既有 resource-signing 為 7／84；七語各 1,805 keys／0 missing。原生 `mermaid-assets-native-v1.log` BUILD SUCCEEDED，`mermaid-assets-native-verify-v1.log` 的 Mermaid／KaTeX resources、四個 executables、app／XPC entitlements 與 deep strict 簽章通過。

第一輪完整 `mermaid-assets-full-v1.log` exit 1，包含大量 protected-file Cocoa 257／POSIX 1 及其他 downstream issues，不能算通過，也不把每項語意失敗一律歸因鎖定。解鎖後獨立 protected-profile probe 通過；`mermaid-assets-full-unlocked-v2.log` 的 17 targets 跑完仍 exit 1，唯一 issue 是既有 memory-history fixture 的 Cocoa 640／POSIX 28（磁碟不足），App 的 708 tests／89 suites 通過。console-before 是 unlocked；沒有改測試或降低 file protection。以各自 build log 確認後，只移除五份舊隔離 DerivedData 的 `Intermediates.noIndex`／`ModuleCache.noindex` 可重建快取，保留 sources、logs、Products 與封裝。

最後 source 完整串行 `mermaid-assets-full-final-v3.log` exit 0：135 XCTest＋1,958 Swift Testing／231 suites（核心 982／108、App 708／89），全部 17 target summaries 通過；console-before／after 均 unlocked。兩項 opt-in live Codex tests 略過，不作外部服務或真人模型證據。`mermaid-assets-package-final-v1.log` 的 standalone Debug／ad-hoc 封裝亦通過 Mermaid／KaTeX resources、四個 executables、app／XPC entitlements 與 deep strict 簽章，產物只在 `.build/validation/MermaidAssetsPackage/Filicon.app`；沒有執行列印的 launch smoke，也不是 release／公證。既有 CoreData NSXPC 診斷和 compiler warnings 不因本批而宣稱修好。authored staged diff check 通過；原 engine 空白、Chevrotain-allstar notice 的 CRLF 及 DOMPurify notice 的末尾空行按 upstream 原 bytes 保留，不改寫授權文件來消除 whitespace 診斷。另直接比較 Git index，全部 75 resources 與 verified working bytes 相同。

獨立非持久離屏 WebKit probe 使用 verified engine、isolated native content world、page JavaScript disabled 與 CSP，沒有 user App launch、message handler 或 host tool。八種正常 graph 與一種 frontmatter injection fixture 均 parse／render 成功且 config 仍 strict；v3／v4 直接查 `.page` world，原 page script／event injection 均未執行。較早 v1 的 engine 最後回傳 JS object 不可 bridge、v2 查 isolated world 的錯誤安全 oracle 保留，不當成產品安全驗收。strict output 仍保留 frontmatter fixture 的外部 `img src`；這正是下一階段必須做 native SVG resource／active-content gate 的證據，不代表安全 UI 已接線。probe 輸出不是 full App screenshot、完整語法或真人事件驗收。

本批使用 SPM／Xcode 技能保留原 target／最低 OS／dependencies，測試與 CustomDump 技能驗證完整值及隔離檔案，文件技能記錄來源及未完成邊界。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天；inputs、logs、probe outputs 和隔離產品留在忽略的暫存／`.build/validation/`。完整 public-engine renderer、serialized／cancelled lifecycle、safe SVG、transcript／viewer integration 尚未完成，opaque bytes／精確 geometry、真人／最低 macOS／external／release 缺口不變；`UI-04` 與整體仍 partial，全部 48 分類不縮減。

## 段落與表格的行內公式

2026-10-05 再核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `transcript.tsx` 與 `math.tsx`：inline formula 是 paragraph／heading／list／quote／table cell 的子節點，不是獨立 transcript block；single-dollar math 不啟用。有效 baseline `inline-math-baseline-red.log` exit 1 重現原生將兩個 inline formula 拆成五個垂直 block，連帶破壞外層 Markdown。native 現只把 display formula 拆出，inline 保留完整段落；比 recovered 簡單 delimiter pattern 更廣的 TeX 指令支援不當作原 opaque asset 的等價證明。

`MarkdownInlineMath` 使用原文中不存在的 deterministic token，在 Foundation 解析整個 Markdown 前保護 TeX。`RichMarkdownInlineMath.swift` 從已解析的文字 attributes 產生 escaped host HTML，插入經驗證的 static KaTeX HTML／MathML；保留標題階層、粗斜體／code／刪除線、清單／quote prefix、唯讀 task 狀態及 host 明確解析的 message reference。公式表格使用同一個靜態 renderer；沒有公式的表格保留 native Grid。使用者原訊息不修改，數學或一般訊息文字不因 UI 語言翻譯。

escaped marker、inline code、Markdown destination、reference-definition 地址與 autolink／HTML tag attributes 不變成公式；TeX 不進 Markdown link／escape parser，也不觸發 metadata requests。inline preparation 受 262,144 bytes／128 formulas 限制，表格另有 2,048 cells／合計 262,144 source bytes，generated HTML 不超過 2 MiB。preparation 拒絕時保留整個 exact literal source；HTML 超量時走 native fallback，在 protected Markdown 解析後才恢復原 formula contents，不漏出 token 或重新啟用 TeX 內的連結。

nonpersistent WebKit 的 page JavaScript 與外部連線仍禁止，只有 verified offline fonts。所有 WebKit navigation／download 取消；只有 user activation 的 exact host-generated link 才交給原 host，HTTP(S) policy 或 deleted message target 在 host 再驗。table 沒有 message navigation 權限。舊 source／superseded width-query 的量測不回寫，新寬度會重新換行；dismantle 撤銷 links、height callback、resize、navigation 與 document references，不留舊 host authority。

追加的 `inline-math-reference-newline-red.log` exit 1 在 LF 通過、CRLF／CR 兩個 cases 漏掉 reference definition 下一行的公式；已改用 Character newline 判斷，三種換行均通過。相同 source 的 isolated scanner 計時另發現未閉合 `<` 的重複 suffix search：2,000／8,000 chars 原為約 0.032／0.482 秒。記住該 suffix 不存在 closer 後，相同 cases 為約 0.001／0.004 秒，200,000 chars 為約 0.113 秒；large inline／display／no-formula fixture 均保留正確結果。

`inline-math-marker-scan-baseline.log` 亦重現不同長度 code markers 與 formula token 名稱碰撞時的重複掃描。code runs 現一次建索引、以二分搜尋選最近且完整同長的 closer；salt 現一次盤點 canonical marker prefixes，不逐個 salt 重掃原文。相同 120／240 runs 的約 0.040／0.480 秒降至 0.0008／0.0019 秒；4,000 個碰撞名稱的約 6.005 秒降至 0.059 秒。新增 600 runs／8,000 名稱分別約 0.011／0.111 秒，均保留一個正確公式；escaped code boundaries、最近 closer、前導零／Unicode／overflow salts 與 TeX 內的碰撞另有功能回歸。計時見 `inline-math-marker-scan-after.log`，這些只是本機小型計時與回歸，不是跨平台 wall-clock deadline 或全面效能保證。

`inline-math-generated-token-red.log` exit 1：實際 KaTeX macro 可生成下一個 formula 的 token-looking text，舊替換順序重新掃描 generated HTML，破壞第一個公式（1 method／4 issues，prose／table 均重現）。現只定位 protected original run 的 tokens，不再掃描 engine output；新回歸檢查原公式 HTML 完整保留、恰有兩個 inline formula，兩個呈現路徑均通過。

`inline-math-focused-final-v8.log` exit 0：112 tests／12 suites（rich content 66／8、App 46／4）。涵蓋 rejected input、各層 source／formula／cell／HTML bounds、unsafe HTML／TeX URL／images、macro-generated marker collision、cross-mode delimiter、安全 fallback、原 host link／deleted target／download／dismantle、兩條真正 transcript route 的同一行 geometry、實際 fixture-window 460→290 縮窄與不裁切 auto-height。之前 table header 被誤當 baseline、過量內容誤設為必須拒絕、只縮 content view 被 AppKit 恢復原寬，以及缺少 test import 的編譯失敗均修正測試 oracle／設定；未以這些失敗當產品 baseline，也未手動觸發 production measurement 來取得綠燈。

七語 × direct／group × 明暗，各保存 prose、table、窄幅 prose 三張 WebKit crop，共 84 張 `InlineMathReviewFinal/inline-*.png`。主線重新人工檢視最後 source 的 18 張，覆蓋七語明暗、兩條 route、表格與縮窄排版；不是全 transcript screenshot、真人 link gesture／keyboard focus 或 VoiceOver 驗收。七語各 1,805 keys／0 missing；pinned local archive 的 resource Ruby tests 為 6 tests／127 assertions／0 skips，resource-signing 為 7／84，皆通過。`inline-math-native-final-v5.log` BUILD SUCCEEDED；`inline-math-native-verify-final-v5.log` 檢查 engine／fonts、四個 executables、app／XPC entitlements 與 deep strict 簽章通過。

最後 source 完整串行 `inline-math-full-final-v5.log` exit 0：135 XCTest＋1,953 Swift Testing／230 suites（核心 982／108、App 708／89），按全部 17 個 target 的單數及複數 summary 彙總。兩項 opt-in live Codex tests 略過，不當作真實模型或外部服務驗收；既有 CoreData NSXPC 診斷仍出現，相關 tests 通過，不宣稱已修好。`inline-math-package-final-v5.log` 的 standalone Debug／ad-hoc 封裝亦通過 engine／fonts、四個 executables、app／XPC entitlements 與 deep strict 簽章，隔離產物為 `.build/validation/InlineMathPackage/Filicon.app`，不是 release／公證。沒有執行列印的 launch smoke；日誌、PNG 及隔離封裝只留在忽略的 `.build/validation/`。

本批以 SwiftUI／SPM 技能分離 static presentation 與原 host actions，測試技能使用固定商業 IDs／日期、隔離 store 與 CustomDump value diff，文件技能保留來源、實際證據與剩餘邊界。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天。此節取代歷史 prose baseline／table inline math 缺口，不關閉 opaque asset bytes、精確 typography／diagram geometry、完整 strict Mermaid、真人／最低 macOS／外部／release 等驗收；`UI-04` 及整體仍 partial，48 項範圍不縮減。

## 離線 KaTeX 公式排版

2026-10-05 核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `math.tsx` 與 root lockfile：它使用 KaTeX `renderToString`、inline／display mode、tolerant parse-error retry 和 escaped fallback，公開依賴固定為 0.16.45。recovered `katex-DHMw6HUq.js` opaque asset 在此 checkout 不存在；本批從相同版本公開套件匯入，不宣稱原 shipped bytes 等價或所有外掛 extension 已對齊。原生先前只有手寫 TeX 小子集，四種矩陣／aligned／math alphabets／annotated root fixture 的有效 baseline 紅燈見 `katex-engine-red-permitted.log` exit 1。

`FiliconRichContent` 現包含 pinned engine／CSS／20 WOFF2 fonts／MIT notice。匯入前驗證 archive SHA-512；manifest 及每個檔案 bytes／SHA-256 在 runtime 與 package verifier 再核對。只使用白名單檔案、拒絕 symlink，沒有 install 或執行 package scripts。JavaScriptCore 只評估經驗證引擎，TeX 是普通函式參數；serialized VM 與每次新的 macros 字典隔離並行訊息／global definitions／錯誤重試。`trust` 回報曾要求權限時，整條公式保留原文，不產生 links、外部 images 或 HTML attributes。

真正 direct／group 的 `OfflineMathWebView` 使用 static KaTeX HTML＋MathML、nonpersistent WebKit、禁止 page JavaScript 的設定與 CSP；只有 verified fonts 的 data URL，沒有網路或新模型工具權限。native isolated-world measurement 等待字型完成，按實際高度調整；六行公式不再被舊 96-point frame 截掉。1,024-point viewport 以上維持捲動；source revision／dismantle fences 拒絕舊回報並清理 references。missing whole bundle 不觸發 generated `Bundle.module` trap；缺失、改動或不可用引擎回退原文。

輸入 16,384 UTF-8 bytes、128 brace depth、1,000 macro expansions、20 em size、1 MiB output，以及 128／8 MiB 成功或失敗 cache bounds 保留。這些是 deliberate resource limits，並非 unbounded 原版或硬 wall-clock timeout；未使用 private JSC timeout API。來源及安全設計詳見 [Offline-math.md](Offline-math.md) 與其中 primary KaTeX documentation。

`katex-render-v3.log` 曾驗證早期 source。最後 `katex-focused-final.log` 是新增測試 closure 的編譯錯誤，`katex-focused-final-v2.log` 的兩項 issue 是 CustomDump 對 unchanged cache 使用差異斷言，不是產品語意紅燈；全部保留。最後 source `katex-focused-final-v3.log` exit 0：62 tests／7 suites（core 19／3、App 43／4）。包括 real JSC engine、15 種 missing／modified／symlink resource cases、整個 bundle 缺失、並行 macros／cache eviction、static page-script rejection、兩條 actual transcript route、多行 auto-height／超高捲動、舊 measurement／dismantle 與同步／非同步 render queue 回歸。

七語 × 明暗 14 張公式 PNG，另有兩張 actual-route WebKit crop，存於 `KaTeXReview/`；人工檢視覆蓋全部七語明暗和兩條 route。數學內容保持原文，不因 UI 語言翻譯。這些是未顯示 NSHostingView／WebKit 的 fixture 與實際 route bounds 檢查，不是 full transcript screenshot、真人 keyboard／focus 或 VoiceOver 驗收。`katex-resources-final.log` 為已提供 pinned local archive 的 6 個 Ruby tests／127 assertions／0 skips，所有 bytes-preserving 再匯入、missing／tamper／symlink／preflight 拒絕通過；另有既有 resource-signing 7 tests／84 assertions 通過。

最後 source `katex-full-final.log` 的完整 `swift test --no-parallel` exit 0：135 XCTest＋1,930 Swift Testing／228 suites（核心 982／108、App 697／88）。本次重新彙總已納入原先漏算的單數 `suite` 摘要（11 tests／1 suite），不重寫日誌或當作新增測試。兩項 opt-in live Codex tests 略過，不作外部服務證據。既有 CoreData NSXPC 診斷仍出現，相關 tests 通過，不宣稱已修好。七語各 1,805 keys／0 missing 與 `git diff --check` 通過。`katex-native-final.log` BUILD SUCCEEDED，`katex-native-package-final.log` 與 `katex-package-final.log` 都通過引擎／字型完整性、四個 executables、app／XPC entitlements 和 deep strict 簽章；standalone 隔離產物是 `.build/validation/KaTeXPackage/Filicon.app`，不是 release／公證。未執行列印的 launch smoke。

本批以 SwiftUI、SPM／Xcode 與測試技能分離靜態 renderer、使用完整 value diff 與固定商業 IDs／日期，文件技能保留來源／驗證／剩餘差異。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天；日誌、圖片和封裝只在忽略的 `.build/validation/`。本節保留引擎批次的歷史驗收；後續 prose baseline／table inline math 已接線（見最上節），完整 strict Mermaid／精確幾何、真人／最低 macOS／external／release 或其餘分類仍保留。`UI-04` 及整體仍 partial，48 項範圍不縮減。

## 有界 Mermaid 圖表的原生放大檢視（2026-10-05）

重新核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `frontend/src/recovered/features/conversation/workspace/mermaid.tsx`：真正 figure／expand button 可用 click、Return／Space 開啟 portal viewer，支援 0.1…8 倍縮放、pointer-anchored wheel、4-point drag threshold、fit／double-click、鍵盤 +／−／F／0／Escape 及關閉清理。native 原本只有三種有界 diagram 呈現，沒有這個入口。

`MermaidDiagramViewer.swift` 現在由真正 `TranscriptMessageView`／`GroupMessageBubble` 的 `NativeMermaidView` 接上 figure click、具原生鍵盤焦點及可及性名稱的 expand button。獨立 `@Observable` model 保存 transform／drag／close state；0.1…8 倍限制、pointer anchor、精確／非精確 wheel、Control／Command 加速、magnify、拖曳、fit／double-click 和本視窗的鍵盤操作共用同一 bounded state。非法或非有限幾何／事件拒絕，關閉後的晚到事件不復活；沒有 global event monitor，也沒有修改聊天或模型執行權限。

原生 preview 是可調大小的獨立 NSWindow，初次使用所屬螢幕可見範圍，提供 full-screen control／`fullScreenPrimary`，不是 reference 的 DOM portal。再次開啟同一 figure 保留窗口與縮放；source 改變、anchor 移除或 parent 關閉時清理原 window／model。延後通知以 object identity 檢查，舊關閉不能關閉後來的新圖表。Canvas 始終以 viewport 大小繪製，對 logical diagram 做 context transform，不為放大後的巨大座標建立巨大 bitmap；256 nodes／512 edges 的 sequence 在 8 倍縮放仍有實際 viewport-sized render 測試。

保留既有三種有界 parser／native layout 與安全 fallback。unsupported／unsafe source 不新增 viewer／link／資源載入；圖表 labels 保留原文，不因 UI 語言翻譯。七個新控制／說明 keys 補齊七語。沒有 JavaScript、WebView、外部 runtime 或新 dependency；新 source 以最小四個 project references 納入 Xcode 原生 App target。

有效 baseline 紅燈 `mermaid-viewer-route-red-v2.log` exit 1：真正 direct／group × 三種 diagram 的六個 cases 都沒有 expand action，兩個 fallback cases 通過。`route-red`、`focused-final-v2` 是新增測試的 Swift macro 編譯問題，不算產品紅燈；`route-green-v1／v2` 是離屏 SwiftUI Button 沒有可查的 NSButton instrumentation，保留日誌，不冒充產品仍無入口。最終用真正原生 expand button 的 click／focused Return／Space 測試，另外從兩條 actual route 檢查 native control 與 OCR，不靠獨立 model 冒充接線。

最後 `mermaid-viewer-focused-final-v3.log` exit 0：101 tests／12 suites（rich content 37／5、App 64／7）；新增 15 個方法。包括 bounded state、原生 key／mouse／wheel、原 window lifecycle／stale callbacks、maximum sequence render、八個 actual transcript cases，以及既有 reply／reference／rich content 回歸。七語 × 三種 diagram × 明暗共 42 張 viewer PNG；英語六張另 OCR 驗證 header 與內容，人工檢視涵蓋全部七語明暗與三種 diagram。圖片為隔離 NSHostingView／未顯示 window，不是使用者 App 的真人操作或 VoiceOver 證據。

最後 source 完整 `swift test --no-parallel` 的 `mermaid-viewer-full-final.log` exit 0：135 XCTest＋1,904 Swift Testing／225 suites（App 688／87）。兩項 opt-in live Codex 測試略過，不當成真實模型／外部帳號驗收；既有 CoreData NSXPCConnection 診斷仍出現，相關 tests 通過，不宣稱已修好。`mermaid-viewer-localization-final.log` 七語各 1,805 keys／0 missing；`git diff --check` 通過。`mermaid-viewer-native-final.log` BUILD SUCCEEDED 並真正編譯新 viewer source；`mermaid-viewer-package-final.log` exit 0：四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/MermaidViewerPackage/Filicon.app` 為 Debug／ad-hoc gate，不是 release／公證；未執行列印的 launch smoke。完整回歸不替代真人／外部驗收。

本批使用 SwiftUI／observable-model 技能分離可驗證 state、Swift 測試／CustomDump 技能比對完整值與固定商業 ID／日期，以及 SPM／Xcode 整合技能保留現有 target／dependency。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天；日誌、PNG 及封裝只存於忽略的 `.build/validation/`。

本節取代下節歷史「尚無 diagram viewer」，但不取代 reference 的 shipped strict Mermaid runtime／完整語法、精確 layout／shape／direction／arrow geometry、KaTeX／table inline math、真人 focus／手勢／VoiceOver、OS full-screen transition 或最低 macOS runtime 驗收。`UI-04` 保持 partial，全部 48 項及其餘 namespace／舊資料歸屬、外部服務／release 缺口不變。

## 聊天待辦勾選狀態與表格行內格式（2026-10-05）

重新核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `frontend/src/recovered/features/conversation/workspace/transcript.tsx`：`assistantTextBlocks` 辨認 list item 開頭的 `[ ]`／`[x]`／`[X]`；`AssistantTextBlock` 呈現 `aria-checked`、`aria-disabled` 的唯讀狀態。表格 header／cell 同樣使用 `renderAssistantInlineText`，不是直接顯示 Markdown 字元；真正 assistant transcript 呼叫此元件。native 原本由 Foundation 保留 task marker 原文，表格亦是 `Text(value)`。

native 現以 Foundation block intent 及原文 source position 辨認真正清單首段的 literal task marker，狀態與文字 attributes 分開。保留 ordered ordinal、nested／quote prefix、續段、hard break、Unicode 與 inline formatting；跳脫、程式碼、強調、連結 label、一般段落或續段中的 `[x]` 不變成 task。呈現使用 constant binding、disabled 原生 checkbox，沒有任務 action／保存權限，不改訊息原文。狀態名稱／完成值與唯讀說明補齊七語。

表格只做 inline Markdown，支援粗體、斜體、刪除線、行內程式碼及 HTTP(S) 連結，保留原 Grid／橫向捲動。非 HTTP、custom／file／mail／relative scheme 與帶 credentials 的 URL 只保留文字；點擊另外重驗現有 `TranscriptLinkPolicy` 才呼叫 opener。table 不繼承 host 的 `sand-msg` navigation，也不新增 metadata、遠端圖片、HTML／JavaScript 或其他資源載入。完整 inline math 與其他 reference runtime 能力仍不是本批已完成範圍。

有效紅燈 `markdown-task-table-red.log` exit 1：兩個方法／三個 cases 直接重現 task 原文沒有狀態呈現（3 issues）。`focused-v1` 是測試把動態 String 傳給只收 literal 的 `l10n` 的編譯問題，不當作產品紅燈；離屏 AX probes 發現 `NSHostingView.accessibilityChildren()` 為空、native button role 為 `AXUnknown`，另一次 probe 編譯失敗亦保留。最後改檢查真正原生 disabled controls 的三個 off／on／on 值、嘗試 click 不改值；localized status 另以七語投影比對。沒有把這項離屏 native control 檢查稱為真人 VoiceOver 驗收。

`markdown-task-table-focused-final.log` exit 0：95 tests／10 suites（rich content 37／5、App 58／5），包括既有 prose、reference navigation、群組 reply、math／Mermaid fallback 與安全 metadata 邊界。新增九個測試方法，真正 `TranscriptMessageView` 與 `GroupMessageBubble` 產生七語 × light／dark × direct／group 共 28 張隔離圖片，三個狀態及 native read-only controls 每張檢查；英語四張另以 OCR 確認格式後的文字及未漏出 `[x]`、`**`、`~~`／backtick。人工抽查 14 張，覆蓋全部七語明暗與兩條 route；內容未因 UI 語言被翻譯或改寫。

最後 source 完整 `swift test --no-parallel` 的 `markdown-task-table-full-final.log` exit 0：135 XCTest＋1,889 Swift Testing／222 suites（App 673／84）。兩項 opt-in live Codex 測試略過，不當作真實模型或外部帳號驗收；既有 CoreData NSXPCConnection 診斷仍出現，相關 tests 通過，不宣稱診斷已修好。`markdown-task-table-localization-final.log` 七語各 1,798 keys／0 missing；`git diff --check` 通過。`markdown-task-table-native-final.log` BUILD SUCCEEDED；`markdown-task-table-package-final.log` exit 0：四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/MarkdownTaskTablePackage/Filicon.app` 是 Debug／ad-hoc gate，不是 release／公證；未執行列印的 launch smoke。完整回歸包含本批 actual-route renders，不替代真人 VoiceOver／focus 或最低 macOS runtime 驗收。

技能使用現代 SwiftUI 的唯讀 constant binding／分離 presentation 與 Swift 測試的固定商業日期／ID、隔離 AppModel／store、CustomDump 狀態及注入 link callback；沒有新 dependency。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天。日誌、PNG 與封裝只存於忽略的 `.build/validation/`。

同時修正歷史 `UI-04 complete` 標記為 partial，沒有縮小全部 48 項的驗收範圍。reference `math.tsx` 的 shipped KaTeX 與 `mermaid.tsx` 的 shipped strict runtime／full-screen viewer／zoom／drag／fit 是可達功能；此批完成當下 native 尚為有界 MathML 及三種 diagram parser，沒有該圖表 viewer（後續 viewer 增量見上節）。其餘完整 runtime、表格 inline math、真人 VoiceOver／焦點及精確排版差異均保留；帳號 namespace／舊資料歸屬選擇、外部服務與 release 等其餘差異不由本批關閉。

## 單獨聊天無變更查看不執行 read-state UPSERT（2026-10-05）

reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `agent-db.ts:207` 在保留 manual-unread、或非 manual 的 view time 不前進時直接回傳，不寫 unread KV。native domain 已正確回傳無變更，但 direct-chat SQLite 層忽略 Bool，仍寫入原 row。本批只在 `markViewed` 真正變更時執行 UPSERT；finite date、原 commit／binding lease、canonical owner／read row 檢查仍先執行，observation publication transaction 不移除。沒有無 I/O 或跨 process CAS 保證，沒有新增權限。

有效紅燈 `direct-unread-view-noop-red.log` exit 1：隔離 trigger 只拒絕 read-state UPDATE，三種 no-op × 已綁定／未綁定共六種真正 UPDATE 錯誤（1 test／6 cases／6 issues），console unlocked。最後 source `direct-unread-view-noop-focused.log` exit 0：93 tests／5 suites（核心 53／3，App 40／2），新增兩個方法。覆蓋原 manual flag／同時間／較舊時間不變、owner 與另一 owner 的 live observation／content 保留、changed view／explicit read／unread 的 SQL 失敗與重試／重開，以及 close／rebind-away-and-back／wrong binding／rejected host／missing／invalid／deleted／三種非有限日期拒絕；群組 UI 及 hidden confirmation Stop 回歸亦通過。Swift 測試技能以既有固定商業時間／ID、隔離 SQLite 和 CustomDump 保存完整 state 比對，沒有新 dependency 或略過測試。

最後 source 完整 `swift test --no-parallel` 的 `direct-unread-view-noop-full-final.log` exit 0：135 XCTest＋1,880 Swift Testing（222 suites；核心 982／108、App 664／84）。兩項 opt-in live Codex 測試略過，不當成真實模型或外部帳號驗收；既有 CoreData NSXPCConnection 診斷仍出現，相關 tests 通過，不宣稱診斷已修好。`direct-unread-view-noop-localization-final.log` 七語各 1,795 keys／0 missing，`git diff --check` 通過。`direct-unread-view-noop-native-final.log` BUILD SUCCEEDED；`direct-unread-view-noop-package-final.log` exit 0：四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/DirectUnreadViewNoopPackage/Filicon.app` 是 Debug／ad-hoc gate，不是 release／公證；未執行列印的 launch smoke。

沒有新增 UI layout／文字，完整套件既有 render 斷言通過，不新增真人 UI／VoiceOver 證據。legacy fallback、完整 core 帳號 namespace／遷移、雲端 session、live／release 與全 48 分類仍保留，整體 partial 不上調。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天資料；日誌和封裝只存於忽略的 `.build/validation/`。

## hidden activity confirmation 的原審核卡取消時序（2026-10-05）

解鎖後 `group-unread-ui-full-final-v2.log` 完整跑完但 exit 1：核心 980 tests／108 suites 通過，App 663／84 有一項既有 Stop/local assertion 失敗，durable review card 仍為 running 而不是 approved；console unlocked，不能歸因於鎖定或算整輪通過。追查發現 broker 核准與卡片最後 SQL 保存是不同非同步邊界，待審 UI 已移除時 native Stop 只收集 pending review IDs，會漏掉尚未保存完成的原卡。

有效紅燈 `activity-review-stop-red.log` exit 1：隔離 SQL trigger 只拒絕最後 approved-card 保存，真正 local confirmation 已出現，但停止後 canonical 卡仍 running、UI 卡卻 approved（1 test／2 issues）。現在 host 在原 acknowledgment/run 註冊審核時保留 exact IDs；停止只退休同 owner 的 unfinished waiting／running 卡，已完成或無關卡不變。native handler 同步捕捉原 execution，所有後續保存沿用同一 lease／binding，不在舊 execution 移除後退回無 fence 的 snapshot write；每個 await 邊界重新檢查撤銷，晚到 action 不改 UI。取消成功後僅投影 exact cancelled review cards，不把整份 canonical 聊天覆蓋新帳號 UI。

正常 provider 可以在 broker 核准／拒絕後先結束；final chat snapshot 現在等待已點擊的原 review action 完成保存，保持原 lease 到該動作結束。Stop／owner cycle 立即撤銷 scope 並解除等待，沒有延長工具 grant、重跑確認或自動同意 local write。既有 local Stop fixture 另明確等到 canonical approved 才檢查保留 completed approval；新增 SQL-save failure 與點擊後 Task 尚未開始即 Stop 的覆蓋，不將 running 接受為成功。

`activity-review-stop-focused-v1.log` 是修改時 Store facade 仍回傳 Void 的編譯錯誤，不當作產品紅燈；修正 facade 回傳原 canonical cleanup 結果後，v2 聚焦 46 tests／3 suites 通過。`group-unread-ui-focused-final-v2.log` 的混合聚焦另有兩個既有排程／question 方法失敗（3 issues）；`activity-review-stop-neighbor-recheck.log` 單獨重跑兩方法通過，沒有移除或跳過測試。最後 source 明確 `--no-parallel` 的 `activity-review-stop-focused-final.log` exit 0：65 tests／4 suites（核心 25／2，App 40／2），包含正常核准／拒絕的 canonical terminal 卡與非 streaming 回合、三種 Stop 邊界、SQL 故障、不執行取消寫入、原 owner SQL fence 及卡片 router。最後整套重跑亦通過，紀錄見下節；技能使用隔離資料／provider、既有固定商業時間及 CustomDump，不降低原存檔或權限檢查。

## 群組未讀側欄與 scoped 原生操作（2026-10-04）

本批接上下一節已驗證的 canonical group read store。真正 `FiliconSidebar` 的群組列顯示 durable unread count（超過 99 顯示 `99+`），並重用七語的可及性說明及「標示為已讀／未讀」選單；側欄點選是明確 human read。前景 arrival／window focus 則只在原群組仍可見、主視窗有焦點、沒有 onboarding／帳號／更新／工具核准／error 遮蓋、history 已載入且 message IDs 匹配原 canonical snapshot 時記 viewed，保留 manual-unread。不把 pending wakes、另一同名群組或載入失敗當作零未讀。

native handler 在建立 Task 前，從原 store／group／member／account lease 同步取得獨立可取消的 action；不在非同步執行時追隨最新選取或重獲權限。human choice 不被 focus 或 projection refresh 覆蓋；較新的 human choice 只撤銷原 pending choice。route／selection／失焦循環撤銷 automatic read，membership／移除恢復／account away-and-back 亦撤銷原 action。投影載入以 owner generation 及 epoch 拒絕晚到結果，真正 member saved callback 刷新 canonical count；保存失敗保留已知 count 及原始 bytes，不發布假的已讀。read action 不回答 question、重播工具或修改 history、排程、review／spend-guard cards。

有效紅燈 `group-unread-ui-red.log` exit 1：在 224-point 的真正群組側欄 OCR 能找到 room，但 canonical 123 arrivals 沒有 `99+`（1 test／1 issue），不是以獨立 badge 冒充接線。`group-unread-ui-focused-v1.log` 是新 fixture 的 callback member 路徑及 async assertion 編譯錯誤，修正測試後另重跑，不當作產品語意紅燈。`group-unread-ui-focused-final.log` exit 0：99 tests／5 suites（核心 18／1，App 81／4），包含新 10 個 App methods 及獨立 child lease 測試。隔離 fixtures 驗證原 human identity、六種 automatic 拒絕、四種 owner 循環、三種保存失敗、pending question 不被回答及真正 shared `SendMessage` saved callback。

reference `agent-db.ts` 的 `markViewed` 在保留 manual-unread 或相同／較舊查看時間時不寫入。native 原先仍保存整份群組 envelope；`group-unread-view-noop-red.log` exit 1 在隔離寫入故障重現三種無變更查看都拋保存錯誤（1 test／3 cases／3 issues），不是鎖定檔案的讀取拒絕。現在僅在 `markViewed` 真正改變 state 時保存，原 store／membership／host lease 及 original-record 檢查仍先執行，closed no-op 也拒絕；explicit read／unread 保存契約不變。`group-unread-view-noop-focused.log` exit 0：核心 19 tests／1 suite 與受保護檔案探針 1 test／1 suite 通過；沒有移除保護，探針通過時 console unlocked。

七語×明暗共 14 張真正 narrow sidebar render 斷言通過，另逐語檢視 selected row 的 `99+` 與 working spinner 無重疊；使用者 fixture 名稱／正文保留原文。最後 source 的 selected-render fixture 在完整測試中亦通過。UI 測試使用 offscreen `NSHostingView`，沒有啟動使用者 App 或操作真人視窗，不宣稱焦點、context-menu 點擊或 VoiceOver 已 live 驗收。七語各 1,795 keys／0 missing，沒有新增 UI keys。

完整 `group-unread-ui-full-final.log` 在途中再次鎖定 Mac，受保護 fixture 檔案出現 Cocoa 257／POSIX 1 拒絕；同時確認 `IOConsoleLocked=Yes`。核心 979 tests／108 suites 與本批 Group read UI suite 已通過，但其餘 App suites 未可靠完成，不能稱整輪綠燈。只停止 stdout／stderr 綁定該日誌的本任務 test helper 及其 swift-test parent，保留失敗日誌（exit 143）；沒有停止使用者 App／Xcode、略過測試或降低檔案保護。解鎖後 v2 的真實 Stop 失敗與修正見上一節。

最後 source 明確 `swift test --no-parallel` 的 `group-unread-ui-full-final-v3.log` exit 0：135 XCTest＋1,878 Swift Testing（222 suites；核心 980／108、App 664／84）。新 group UI suite、三種 Stop 邊界及先前混合聚焦失敗的兩個排程／question 方法均通過；兩項 opt-in live Codex 測試仍略過，不能當成外部模型／帳號驗收。`group-unread-ui-localization-final-v2.log` 七語各 1,795 keys／0 missing，`git diff --check` 通過。

群組 UI 的早期 `group-unread-ui-native-final.log` BUILD SUCCEEDED，`group-unread-ui-package-final.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過；這兩輪在後續 no-op／Stop 修正之前，不能冒充最後 source gate。最後 source 另以 `group-unread-ui-native-final-v2.log` BUILD SUCCEEDED 及 `group-unread-ui-package-final-v2.log` exit 0 驗證四個執行檔、deep strict 簽章與 app／XPC entitlements。最後隔離產物 `.build/validation/GroupUnreadUIFinalPackage/Filicon.app` 與保留的早期 `.build/validation/GroupUnreadUIPackage/Filicon.app` 均為 Debug／ad-hoc gate，不是 release／公證；未執行列印的 launch smoke。本批使用測試及現代 SwiftUI 技能，採隔離 store、controlled clock、同步捕捉 action identity 與 named handlers；日誌、PNG 及封裝只保留在忽略的 `.build/validation/`。

本節局部取代下一節歷史「群組側欄／manual／focused callback 尚未接線」，最後本機完整回歸已通過，但不取代真人 UI gate。legacy fallback、完整 core 帳號 namespace／遷移、雲端 session、live／release 及全 48 分類仍各自保留，整體 partial 不上調；atomic JSON 與原 lease 不是跨 instance／process CAS。未 push、重啟使用者 App／Xcode 或改真實帳號／群組／聊天資料。

## 群組聊天的 canonical 已讀／未讀儲存基礎（2026-10-04）

reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `agent-db.ts` 提供 `getUnreadState`／`markActivity`／`markViewed`／`markRead`／`markUnread`；`session-summaries.ts` 的 `buildSummary` 在 `isGroup` 分支亦使用同一 unread state。`group-chat-glue.ts` 在非前景的群組公開訊息保存後呼叫 `markSessionActivity`；`session-runtime.ts` 在前景 arrival／focus 保留 manual-unread。native 原本只在 direct-chat SQLite 保存這些標記，群組的 `groups.json` 沒有對應資料。本批先補真正群組 store，而不是拿 direct chat 或 pending wakes 當近似來源。

`groupReadBookkeeping` 使用獨立 schema 1，保留每個精確 group ID 的四個 read fields 及 durable activity message IDs；既有 envelope schema 2、群組／訊息 ID 和短地址不變。公開文字、附件／圖片及問題／secret 卡與真正人類回覆才計 arrival；tool-only 更新、空 PASS／failure notice 與 host 的非人類 routine seed 不計。第一次真正公開的同一訊息可取得 receipt，其後編輯、反應、metadata／成員保存及歷史重播不重算；同名群組不共享標記。訊息與 receipts／count 在同一 atomic JSON envelope 保存成功後才發布到記憶體，不因舊 clock 或 replay 重複增加。

只在舊 envelope 缺少整個欄位時 seed 歷史 IDs，不把全部舊訊息當新未讀，也不在開啟時重寫來源；沒有宣稱還原 reference mtime 的歷史 activity timestamp。current bookkeeping 的 null、缺失／重複／孤立 record、非法 state／receipt 或未知版本會拒絕，原始 bytes 不覆寫，不默認空值／已讀。原生 read action 重用四個 domain 欄位的 monotonic timestamps／manual flag；只更新 read record，不回答 pending question、重新排程或改群組 history／permission。

non-Codable host lease 保留原 GroupService instance、group ID、member IDs、可撤銷生命期及選配 inherited host／account scope，到最後同步保存。membership-away-and-back、手動 close、host scope cycle 與換 instance 不能復活舊 action；失敗的 membership 保存不改成員或撤銷已有效的 lease。automatic view 另要求原 activity receipts／read state，不能清除較新的 arrival 或手動未讀；explicit read 可涵蓋當前 canonical 訊息。這是本機 read bookkeeping，不是 account namespace、model tool 或執行 grant。

有效紅燈 `group-unread-foundation-red.log`：真正公開訊息保存後缺少 bookkeeping（1 test／1 issue）。`group-unread-foundation-rollback-red.log` 另重現保存失敗後 reaction／speaker offset 仍留在記憶體（1 test／7 cases／2 issues）；這些未提交內容可能被下一次 read 保存帶入。GroupService 現在統一回滾整個失敗 envelope，移除只回滾部分 message array 的分散處理；模型／工具尚未開始時的失敗不執行 responder。native read 保存亦只在成功後發布。

最後 source 聚焦 `group-unread-foundation-focused-final.log` exit 0：69 tests／9 suites（核心 54／8，App 群組排程 15／1）；新增 17 個測試方法。涵蓋真正 member publication／tool updates、background seed、human question 不被 read 回答、manual／focus、同名 rooms、membership／host cycles、八種 atomic-save failure、八種 corrupt-data、legacy seed／reopen／replay／receipt tombstone、monotonic divider 及非有限日期。測試技能使用隔離 stores、固定商業時間與 controlled clock；不使用真實模型、帳號或群組。

完整 `group-unread-foundation-full-final.log` 跑完但 exit 1，既有 direct-session Stop fixture 在 pending UI 已發布、SQL 尚未完成時取消，卻要求原本不存在的 durable review card；`group-unread-stop-race-recheck.log` 單獨重現同一 nil-card 斷言。fixture 現先讀取 canonical store，等待真正 waiting card 落盤才取消，保留原 streaming／cancelled-or-approved／沒有寫檔與 schedule bytes 不變的斷言；production cancellation fence 不變，不在撤銷後補造卡片。`group-unread-foundation-focused-final-v5.log` exit 0：74 tests／5 suites（核心 30／3，App direct／group 44／2），包含修正後兩個 Stop phases。較早 `focused-final-v3`／`v4` 均在執行測試前遇到 ad-hoc Code Signing internal error，當時磁碟剩約 239 MB；只清理有本輪 build logs 證明的三份 ignored DerivedData（可重建），保留日誌與封裝後，原簽章設定重跑通過。沒有降低 protection／簽章檢查。

最後 source 完整串行 `group-unread-foundation-full-final-v2.log` exit 0：135 XCTest＋1,865 Swift Testing（221 suites；核心 978／108，App 653／83）。兩項 opt-in live Codex 測試略過，不當作真實模型／外部服務驗收。七語各 1,795 keys／0 missing。`group-unread-foundation-native-final.log` 在 SDK 預編譯遇到明確 `No space left on device`，不是 compile 語意紅燈；又清理五份有本任務 build logs 證明的 ignored DerivedData，保留日誌／封裝並可重建，不碰真實資料。

最後 `group-unread-foundation-native-final-v2.log` BUILD SUCCEEDED；`group-unread-foundation-package-final.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/GroupUnreadFoundationPackage/Filicon.app` 為 Debug／ad-hoc gate，不是 release／公證；未執行列印的 launch smoke。最後 source 只修改儲存層與上述 fixture，不新增 UI 文字／佈局；沒有真人／VoiceOver gate。日誌與封裝留在忽略的 `.build/validation/`。

本節只取代下面歷史「群組沒有 canonical read 儲存」的基礎部分。群組側欄 count／manual actions／focused visible callback／projection refresh 與真人／VoiceOver 尚未接線或驗收；不是完整 group unread UI parity。legacy fallback、完整 core 帳號遷移、雲端 session、live／release 及全 48 分類仍各自保留，整體 partial 不上調。atomic JSON 是單 store 保存，不宣稱跨 store、獨立 instance／process 的 CAS 或完整群組帳號隔離；未 push、重啟使用者 App／Xcode 或改真實資料。

## 回答活動卡片後的原聊天確認回合（2026-10-04）

再次核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634`：`sand-automation-spend-guard.ts` 的 `renderSpendGuardAnswerAck` 要求一句短確認、不重編排程、不再次詢問；`widget-responses.ts` 在 host 已保存選擇後以 `appendUserMessage: false`／`awaitTurn: false` 將它交給原 agent，模型失敗不回滾已生效的選擇。

native 現在於真正 service outbox 回答及原聊天的 native system receipt 均落盤後，透過同一個 shared direct runner 排入一次 hidden acknowledgment。目標仍是原 account／agent／canonical chat，不跟隨畫面選取、不新增聊天；provider 不支援工具時拒絕，不降級 plain text。五種選擇只產生 ephemeral host reminder，要求短 `SendMessage` 確認；沒有假的持久 user row，也不重跑原任務或改排程。history 只來自原聊天，排除 host bookkeeping；attachments、saved facts、memory suggestions／episodes／synthesis 及 workflow library 不注入。原 persona 及 host 工具／peer 核准流程仍在，不增加任何 grant。

process-local FIFO 依實際 click order 而非可能倒退的回答時間；原聊天忙於回合／peer recovery／model sync，或正在等人類 question／secret 時保留排隊。待原工作結束才執行；最多 64 個 pending＋active confirmations，超出只略過模型確認，不回滾選擇或抹掉 native receipt。queue 不保存，重開／reload／重複 callback／receipt 補寫不 replay。每個確認另保留原 repository binding lease、account generation／scope 及原 provider／model／reasoning；重綁／隱藏／刪除／封存／帳號循環或 Stop 使其失效。最終訊息及 review-card SQL 保存仍用該原 lease，不能在 finalization 換成較寬的 account lease。

取消測試另外抓到 canonical streaming placeholder 未退休、Stop 顯示假儲存錯誤的問題。現以獨立 native cleanup 僅取消原 owner 的已知 run ID／pending review ID，不接收聊天 snapshot、不新增正文、復活模型 lease 或修改另一 owner；已完成行及無關訊息／卡片保留，SQL 失敗回滾。帳號切換亦可退休原 run 的未完成本機紀錄，這是取消收尾，不是舊帳號模型回合或 publication permission。晚到 provider 即使忽略 cancellation 仍不能發表；停止不永久留下等待卡片。

有效紅燈 `spend-guard-answer-ack-red-valid.log` 重現 Resume／Stay paused 保存後沒有模型確認（1 test／2 cases／4 issues）；`spend-guard-answer-ack-write-cancel-red-v2.log` 重現四種 active cancellation 留下 streaming row，Stop 另出現儲存錯誤（2 tests／5 issues，檔案核准測試已通過）。寫入測試較早使用了未選取原聊天的 UI intent、並誤以為 review denial 會返回普通 tool result；這些 fixture 失敗及 async assertion 編譯失敗各自保留，不當成產品核准 gate 缺失。`focused-final.log` 的一項失敗是 fixture 把原生 review 的 `approved` 誤寫成 `succeeded`；只修正既有契約的斷言。

最後 source 聚焦 `spend-guard-answer-ack-focused-final-v2.log` exit 0：172 tests／7 suites（核心 71／3，App／direct／group／router 101／4）。涵蓋五選項、真正 shared model／SendMessage、無假人類／私有 draft、FIFO、pending question 與真實 human reply、重開不 replay、保存／provider 故障、十五種最後 binding SQL fence、paged history 保留、八種 cancellation-only storage 邊界，以及真實雙重檔案核准／兩階段 Stop／晚到 provider 拒絕。

最後 source 完整串行 `spend-guard-answer-ack-full-final.log` exit 0：135 XCTest＋1,848 Swift Testing（220 suites；核心 961／107，App 653／83）。兩項 opt-in live Codex 測試略過，不當作真實模型或外部服務驗收。`spend-guard-answer-ack-native-final.log` BUILD SUCCEEDED；`spend-guard-answer-ack-package-final.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/SpendGuardAnswerAckPackage/Filicon.app` 為 Debug／ad-hoc 離線 gate，不是 release／公證；未執行列印的 launch smoke。七語各 1,795 keys／0 missing，`git diff --check` 通過；沒有新增 UI layout 或文字，不新增真人／VoiceOver 驗收。日誌及產物僅保留在忽略的 `.build/validation/`。

本節只取代下面歷史 canonical direct-chat branch 的「hidden model answer acknowledgment 尚未接線」。legacy unbound fallback、group read state、完整 core 帳號遷移、雲端 session、真人／VoiceOver、live／release 及全 48 分類仍各自保留，整體 partial 不上調。不宣稱模型一定遵循短句、跨 process lease 或跨 store 原子交易；失敗保留 native 已套用的確認，不 rollback／重送。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天資料。

## 同一次檢查保留原卡片的回答選項（2026-10-04）

再次核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634`：`automation-spend-guard-runtime.ts` 在 automatic pause 保留原 `cardEntryIds` 並新增 paused entry；`handleWidgetAnswer` 核對仍在 active set 的 host entry 與該 widget 的原選項，而不是要求每張卡都符合最新 stage。Keep／Never ask 可由未回答的原 nudge 恢復 guard-paused routines；Pause 保留檢查，Resume／Stay paused 只屬於 paused widget。檢查結束即退休其餘 sibling entries。

native 現在仍先核對當前 owner／cycle ID，再以原始 host outbox entry ID、immutable account／conversation、未回答狀態及該 entry 的選項決定是否接受。App 只由 service outbox 發出 retained nudge 的 live presentation，保留原 binding lease／account generation，不能以模型或匯入 metadata 取得權限。automatic stage change 可保留未回答 nudge 的原 lease；已回答、重綁／隱藏／帳號離開再回來及換 cycle 的回呼不復活。workspace／無 entry 的舊入口仍要求當前 stage，不把任意舊 prompt 當成 host entry。native system receipt／排程同筆保存和聊天 receipt 補寫的原契約保留，沒有 hidden model acknowledgment 或新模型回合。

同一 cycle 的新 stage 必須沿用第一張卡的原目的地；不能借 automatic pause 在另一帳號或聊天建立新的回答入口。schema 3 亦拒絕同一 owner／cycle 跨目的地的矛盾 outbox，保留原來源而不正規化重寫。沒有改 schema、修補真實資料或新增遷移權限。

有效紅燈 `spend-guard-retained-nudge-red.log`：core 的三種 nudge 選項在 auto-pause 後遭 staleCard 拒絕（1 test／5 cases／3 issues），實際 App 重開後原 nudge 沒有 live action（1 test／3 cases／3 issues）。`spend-guard-retained-destination-red.log` 重現新 stage 可被改投，以及矛盾目的地 outbox 未拒絕並改寫來源（2 tests／4 issues）。`spend-guard-retained-focused-final.log` 另是新增測試把 `#require` 巢狀放入另一 macro 的編譯錯誤，修正後另跑最終 gate，不當成產品語意紅燈。

最後 source 聚焦 `spend-guard-retained-focused-final-v2.log` exit 0：155 tests／6 suites（核心 64／2，App／direct／group／router 91／4）；含五種原選項、auto-pause／重開、原 callback／lease、錯選項／錯 stage／retired sibling、rebind／hidden／account cycles、假 entry、immutable destination 與 SQL receipt 故障復原。

最後 source 完整串行 `spend-guard-retained-full-final.log` exit 0：135 XCTest＋1,834 Swift Testing（220 suites；核心 957／107，App 643／83）。兩項 opt-in live Codex 測試略過，不當作真實模型或外部服務驗收。`spend-guard-retained-native-final.log` BUILD SUCCEEDED；`spend-guard-retained-package-final.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/SpendGuardRetainedPackage/Filicon.app` 為 Debug／ad-hoc 離線 gate，不是 release／公證；未執行列印的 launch smoke。七語各 1,795 keys／0 missing，`git diff --check` 通過。沒有新增 UI layout 或文字，不新增真人／VoiceOver 驗收；日誌及產物僅保留在忽略的 `.build/validation/`。

本節取代下面歷史「native 只接受當前 stage、retained 舊 nudge 是唯讀」的 canonical host-entry 部分；錯選項、已回答／退休的 entry、模型 metadata、無 canonical lease 與 ownership cycles 仍拒絕。legacy unbound fallback、hidden model answer acknowledgment、group read state、完整 core 帳號遷移、雲端 session、真人／VoiceOver、live／release 與全 48 分類仍各自保留，整體 partial 不上調。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天資料。

## 背景回合的一次性活動提醒（2026-10-04）

再次核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634`：`automation-spend-guard-runtime.ts` 的 nudge transition 保存 widget 後回傳 `renderSpendGuardNudgeReminder`；`automation-run-path.ts` 只為非群組的 background automation trigger 將提醒附於同一 wake。manual、group、awaiting-ack 與 pause 不重送，也不是額外的模型回合。

native 現以不可 Codable／無 public initializer 的 host nudge value 捕捉原 agent、card、canonical account／conversation、view time、unread／retained fires 和可撤銷來源。process-local pending transition 跨越 scheduler 的預先 evaluate，僅在一次成功 background admission 消耗；不保存 reminder queue、不在重開／後續 awaiting-ack／查看或回答後補發。host 必須先依原綁定 lease 將永久卡片保存到原聊天，才能讓模型說「App 已詢問」；沒有 canonical source 或 publication host 時不假稱已保存。排程 publication 失敗保留原 nudge 與尚未 claim 的到期任務可重試；不宣稱事件 ingress 可重送已去重的 event。

publication 的 await 後重新檢查 owner scope、當前 card／stage、definition revision／enabled、schedule snapshot、claim／busy 與 dispatch epoch，不能用舊候選覆蓋中途的新狀態。SQL publication 使用獨立的 tracked mutation lifetime，不在 repository publication lock 中取得來源 observation lock。直接對話的原 consent、工具／peer／saved-facts 權限不增加；未審核的 text-only branch 不取得 canonical history 或 tools。提醒僅進入既有 ephemeral wake，不變更任務正文／持久聊天，不偽造 user answer；期限在真正執行前讀目前時區，已審核 group 仍豁免。

有效紅燈分開保存：`spend-guard-reminder-red-valid.log` 在真實 App background fixture 重現缺少 hidden reminder 及 inference 前沒有永久卡片（1 test／3 issues）；`focused-final.log` 的 event fixture 重現 host value 被 native manual／group／peer request 重用（3 issues），request renderer 現也拒絕這些身分；`spend-guard-reminder-time-zone-red.log` 重現 scheduler 沿用啟動時時區（1 test／2 cases／1 issue）。早期測試 autoclosure／Equatable 編譯失敗另保留，不當作產品紅燈。

`spend-guard-reminder-focused-final-v3.log` 的核心 37 tests 通過，但 App 的受保護 `agents.json` 讀取遭 Cocoa 257／POSIX 1 拒絕，該輪不能算通過。其後 console unlocked 且 isolated protection probe 通過，沒有降低檔案保護。最後 source 聚焦 `spend-guard-reminder-focused-final-v4.log` exit 0：151 tests／6 suites（核心 63／2，App／direct／group／router 88／4）；含排程預先 evaluate、事件與去重、only-once、manual／group 排除、publication retry、answer／view／pause／scope／destination／closed source／queued edit／competing manual fences，以及真實 App 卡片-before-inference、未審核 plain history／tool 邊界和即時時區。

最後 source 完整串行 `spend-guard-reminder-full-final.log` exit 0：135 XCTest＋1,830 Swift Testing（220 suites；核心 956／107，App 640／83）。兩項 opt-in live Codex 測試略過，不當作真實模型或外部服務驗收。`spend-guard-reminder-native-final.log` BUILD SUCCEEDED；`spend-guard-reminder-package-final.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/SpendGuardReminderPackage/Filicon.app` 為 Debug／ad-hoc 離線 gate，不是 release／公證；未執行列印的 launch smoke。七語各 1,795 keys／0 missing，`git diff --check` 通過；沒有新增 UI layout 或文字，不新增真人／VoiceOver 驗收。日誌及產物僅保留在忽略的 `.build/validation/`。

這只取代較早「host nudge reminder 未接線」的 canonical direct-chat 分支，不是 hidden model answer acknowledgment turn，也未關閉 reference retained nudge entry 的多階段回答差異。無 canonical chat 的 legacy fallback、group read state、完整 core 帳號遷移、雲端 session、真人／VoiceOver、live／release 與全 48 分類驗收仍保留；整體 partial 不上調。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天資料。

## 活動提醒的永久聊天紀錄與回答確認（2026-10-04）

reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `automation-spend-guard-runtime.ts` 保存實際 `send-message` widget entries，nudge／paused 使用不同 entry ID；`handleWidgetAnswer` 核對 entry 與選項，`widget-responses.ts` 將回傳的 ack 作為 `modelPrompt` 呼叫 `sendPrompt`，設定 `appendUserMessage: false`／`awaitTurn: false`。本批補永久聊天 widget 與確定性的 native system 回答確認，不把 UI 投影或模型口頭宣稱當成已保存訊息，也不宣稱已接上原版 hidden model acknowledgment turn／host reminder。

automation schema 3 的 immutable outbox 保存原 account／agent／conversation、guard stage、prompt／ack ID 及回答日期；1／2 遷移為空 outbox，損壞／重複 entry 或錯階段回答拒絕且不重寫來源。nudge 與 paused 可共用 guard ID，但各有永久 entry／ack ID，舊階段不得回答。選擇與排程變更在 automation store 同筆保存；原始 generation／lifetime／binding lease 仍保留到最終同步提交。聊天另以完整 canonical history 保存 prompt 更新＋system ack，保留既有歷史、反應與短地址；ack 保存故障重開可按原目的地補寫，不再次套用排程選擇、不改投替代聊天／帳號。兩個 stores 並非原子交易，derived transcript reconciliation 也不是同筆 SQL。

新 host prompt 計一次 canonical arrival；更新、system ack 與 replay 不增加未讀。materialization 後更新 guard count，避免舊零值在另一 owner 的下一次 reload 才跳成一；已完成的 read receipt 在後續 prompt arrival 前結束，不因新卡片誤回報失敗，尚未提交的舊 read 仍撤銷。歷史／匯入卡沒有回答權限、generic retry／dismiss 或無限 spinner；模型輸入只排除 scoped host outbox 的非人類 ID，匯入 metadata 不可隱藏人類訊息。native summary／confirmation 與 in-chat search 使用七語 closed keys；global FTS 保存 canonical 英文摘要，不宣稱索引全部翻譯。

有效故障證據分開保留：owned test process 的 sample 證明持有 binding lease 時重新進入 public `save` 的 lease cleanup 死鎖，改用不能變動 owner／visibility 的 private storage commit，未改成遞迴鎖或放寬 fence。`spend-guard-transcript-fractional-red.log` 重現 4 種次毫秒日期中的 3 個 valid receipt 被拒，改以 millisecond 正規化後通過；`focused-v9` 重現上述 unread 投影／已完成 read 的 6 issues。`spend-guard-transcript-japanese-title-red.log` 實際 OCR 重現日文標題截斷（1 test／12 issues），共用 renderer 的 title／subtitle 現可換行。先前因受保護檔案拒絕、fixture readiness／零 intrinsic height 或測試 API 編譯錯誤造成的失敗另保留，不冒充產品語意紅燈。

解鎖後 `spend-guard-transcript-full-unlocked.log` 完整跑完但 exit 1：舊 direct-session fixture 把服務層的 Keep／Never ask 相容回答當成已 paused 原生卡片的選項，兩個 `nextRunAt` 斷言失敗；實際共用 UI 的 paused stage 只有 Resume／Stay paused。`spend-guard-transcript-full-final.log` 另重現 group-session fixture 的同一錯誤假設（2 issues）。兩條 fixture 現先證明錯階段回呼不改定義、審核或原始 outbox bytes，再以畫面真正提供的 Resume 驗證原審核與 shared runner 可繼續；原有 revision／nextRunAt／durable binding／實際 run ID 斷言保留。核心服務層原有三種 continuing 回答的相容測試保留且通過，不因本機 UI 契約移除。另以 `spend-guard-transcript-workspace-stage-red.log`（1 test／2 cases／6 issues）重現未綁定、無 outbox 的 native workspace 回呼仍接受錯階段回答；App 的共用入口現在先檢查當階段選項，與有 ledger 的聊天路徑一致，不放寬保存契約。修正後的最終完整回歸見下方，不用中間綠燈取代最後 source。

最後 source 聚焦 `spend-guard-transcript-focused-final-with-group.log` exit 0：144 tests／6 suites（核心 58／2，App／router／direct 與 group routine 86／4），包含五種回答、nudge→pause 雙 entry、原始身分失效、ack SQL rollback／重試／重開、不再次 reschedule、完整 history／FTS／reaction／unread 及日期 round trip。native 回呼有／無 outbox 均拒絕錯階段選項，真正 Resume 保留原審核並使用 shared runner；核心服務層的三種 continuing 相容回答仍保留。98 個 312-point 歷史卡 render 覆蓋 7 種卡片 × 七語 × 明暗，另有 28 個 live native、28 個 workspace、14 個未讀 badge 及實際永久 entry 的完整 `ChatDetailView` OCR／PNG；日文 14 個 variants 要求完整標題 OCR。人工檢視各語代表圖與修正後日文長標題，並非逐張人工檢視 98 張或 live／VoiceOver 驗收。七語各 1,795 keys／0 missing，`git diff --check` 通過。

最後 source 的 `spend-guard-transcript-native-final.log` BUILD SUCCEEDED；`spend-guard-transcript-package-final.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/SpendGuardTranscriptPackage/Filicon.app` 為 Debug／離線 gate，不是 release／公證；未執行列印的 launch smoke。日誌、PNG 及產物只留在忽略的 `.build/validation/`。

較早完整串行 `spend-guard-transcript-full.log` 途中 macOS 再次 `IOConsoleLocked=Yes`；核心 951 tests／107 suites 先通過，其後受保護 fixture 的 Cocoa 257／POSIX 1 及衍生失敗使該輪不能算完整通過。只停止有 log FD 證明的 owned swift-test／testing-helper（exit 143），保留日誌、未降低檔案保護。

最後 source 完整串行 `spend-guard-transcript-full-final-v2.log` exit 0：135 XCTest＋1,823 Swift Testing（220 suites；核心 951／107，App 638／83）。兩項 opt-in live Codex 測試略過，不當作真實模型／外部服務驗收；不拿前批 1,805 tests 或中間 fixture 失敗充作本批結果。最終 native／封裝使用上方 `-final` 日誌；之後只修正 group 測試契約及驗收紀錄，沒有再修改 production source。

本節局部取代下方歷史「只有 live projection、沒有永久 entries／回答確認」。reference 在 pause 後保留 nudge 與 paused 的 host entry IDs，仍可按各 widget 原選項回答；native 目前只接受當前 stage，舊 nudge 仍是唯讀紀錄，不能以本批雙 entry 保存宣稱完整多 entry 回答 parity。原版 hidden model acknowledgment／host reminder、group read state、legacy unbound fallback／完整 core 帳號遷移、雲端 session、真人 UI／VoiceOver、live／release 與全 48 分類仍各自保留，整體 partial 不上調。lease 僅 fence 同 repository，不宣稱 cross-process snapshot CAS 或跨 store 原子交易；未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天資料。

## 聊天內的原生活動提醒卡片（2026-10-03）

reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `automation-spend-guard-runtime.ts` 以 `issueGuardCard` 在 active／background session 保存 host-issued `send-message` widget，`handleWidgetAnswer` 驗證 entry ID 與 widget 選項並回傳 acknowledgment；這不是模型說已產生按鈕。Filicon 本批先補實際 bound direct chat 的 native 操作入口，重用工作區的已保存 card ID、五種回答及既有核准／pause／resume 保存邏輯，不另建一套回答權限。

presentation 由當前 account／generation、未封存 owner、唯一 canonical binding 與原始 repository lease 建立，不按聊天標題／名稱推斷。hidden／unpaged 的第二綁定同樣造成拒絕，舊 callback 在重綁、移除、隱藏、封存、帳號離開再回來或 card phase 改變後不復活。最終同步 guard-store 保存仍持有原 lease；不在延遲回答時尋找新的 lease。較新 reload 的 epoch 防止舊投影覆蓋或關閉被重用的有效 lease。單純導航不撤銷已捕捉的人類回答，但它只作用於原 owner，不能改投目前選取的聊天。

查看、read／unread 及重新開啟不回答或解除 pause；原本持久化 card ID 重開後仍可解析。錯階段選項與模型／匯入 widget 沒有 native authority。寫入失敗保留未回答卡片及定義，清除 UI answering 狀態後可重試，不部分恢復；已審核 group 豁免、人工停用、peer／tool／background-memory 同意不放寬。這批不把卡片保存成假真人或模型訊息，不增加聊天 arrival／未讀計數。

有效紅燈 `spend-guard-chat-card-red.log` 的實際 `ChatDetailView` OCR 重現缺少 Resume／Stay paused 按鈕（1 test／1 semantic issue）。`focused-v2`／`focused-v3` 的新 fixture 沒有預先載入 canonical metadata、`focused-v4` 的 Keep／Never ask fixture 錯誤期待已啟用任務重新排程，各日誌保留而不當成新的產品紅燈。修正 fixture 後最後 `spend-guard-chat-card-focused-final.log` exit 0：126 tests／6 suites（核心 48／2、Automations 9／1、App 69／3），包含五種回答、十一種身分失效、同名不同 owner、重開、失敗重試、最終 lease 撤銷與 phase fence。七語×明暗×兩階段共 28 個 280-point native 卡片 render 通過實際按鈕 bounds／無重疊斷言，逐張檢視換行與內容，另有 640×900 完整聊天 OCR／PNG；這不是 live 點擊或 VoiceOver 驗收。

最後完整串行 `spend-guard-chat-card-full.log` exit 0：135 XCTest＋1,805 Swift Testing（220 suites；核心 941／107、App 630／83）；兩項 opt-in live Codex 測試略過，不當作 live 驗收。七語各 1,789 keys／0 missing。`spend-guard-chat-card-native.log` BUILD SUCCEEDED；`spend-guard-chat-card-package.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過，隔離產物 `.build/validation/SpendChatCardPackage/Filicon.app` 為 Debug／離線 gate，不是 release／公證，沒有執行列印的 launch smoke。日誌及 PNG 僅保留在忽略的 `.build/validation/`。

本節只取代「只有自動化工作區入口」；這仍是 live native projection，不是永久 transcript widget entries、搜尋／歷史中的多 entry ID 或回答確認，host reminder 尚待接線。group read state、legacy unbound fallback／完整帳號遷移、雲端 session、真人 UI／VoiceOver、live／release 及全 48 分類仍各自保留，整體 partial 不上調。lease 只 fence 同 repository，不宣稱獨立 repository／process 的 live fence、跨聊天 DB／automation store 原子交易或 arbitrary snapshot CAS。未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天資料。

## 活動提醒改讀 canonical 單獨聊天狀態（2026-10-03）

再次核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634`：`automation-spend-guard-runtime.ts` 的 `evaluate` 直接讀 `session.db.getUnreadState()`，並以該 `lastViewedAt` 計算現存 definitions 的 retained runs；pause transition 亦重新評估。native 的 trusted host 現在為非 reviewed-group routine 解析目前 account／exact agent 的唯一 canonical bound direct chat，包含未載入側欄與 hidden histories。count 與 view time 不再由 pending wakes 或 routine 建立時間取代；有 canonical source 時不把 wakes 加進聊天 count。沒有 canonical bound chat 的明確 legacy／text-only host 才保留舊 fallback，歧義／缺失或損壞 read row 不 fallback、不按名稱或 prompt 猜 owner。

repository-owned live observation 跟隨同一 repository 的 content／read-state 成功提交更新，不把 reconcile 時的一次 snapshot 當成之後的真實 count。它以原 owner／conversation／hidden 狀態註冊，重綁、歧義、hide／delete 與 close 後不復活；同一 owner 重用 projection，weak registry 不因重新整理保留無用觀測。SQL transaction 先解析各 observation 下一值，COMMIT 成功後才發布；owner 不變的 activity／read 保存錯誤保留全部舊 projection。owner 變更的保存嘗試會保守先撤銷舊 observation，即使保存失敗也不復活。guard 同步決策與自己 store 的保存持有 read-publication fence；source 不是 Codable definition／model tool input，也不是新的檔案／工具／記憶 grant。原始 account generation／可撤銷 lifetime 仍限制批次；已審核 group 的豁免與人工停用不變。

activity 卡片的明確「標示為已讀」也會更新其 exact canonical chat，而非只改 automation timestamp；聊天 read／unread／view 不回答卡片、不自動恢復任務、不清除 pause ownership／snooze／opt-out。canonical reconcile 故障顯示錯誤並保留已有卡片，未發布猜測的新 activity。重啟後重新從 DB 解析 count／view，既有未回答 card ID 保留。

有效紅燈 `spend-guard-canonical-unread-red-valid.log` 重現 15 則 canonical 未讀但沒有 wakes 時，native count、view time 與 nudge 決策三項差異。`spend-guard-canonical-unread-red.log` 的 Array／Set 型別及 `spend-guard-canonical-unread-focused-v4.log` 的 fixture 修改唯讀 ID 編譯失敗保留，與產品語意紅燈分開。最後聚焦 `spend-guard-canonical-unread-focused-final.log` exit 0：172 tests／24 suites（核心 96／15、App 65／7、Automations 9／1、Agents 2／1）。新增 11 個測試方法，包括四種 queued batch、兩種 invalid source、兩種 owner lifetime、四種 observation revocation，以及 rollback、manual unread、重開、explicit activity read、15 wakes／20 runs 不能覆蓋 canonical read marker；固定日期、隔離 stores 與受控 gate 不用真實模型或服務。

最後 source 的完整串行 `spend-guard-canonical-unread-full.log` exit 0：135 XCTest＋1,795 Swift Testing（220 suites；核心 939／107、App 622／83），兩項 opt-in live Codex 測試略過，不冒充外部服務驗收。七語各 1,789 keys／0 missing；沒有新增 UI layout 或文字，完整套件的既有 render 斷言通過，不新增真人視覺／VoiceOver 驗收。

`spend-guard-canonical-unread-native.log` BUILD SUCCEEDED；`spend-guard-canonical-unread-package.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/SpendCanonicalUnreadPackage/Filicon.app` 為 Debug／離線 gate，不是 release／公證；未執行列印的 launch smoke。日誌及產物僅保留在忽略的 `.build/validation/`。

本節只取代下面歷史「guard canonical count 未接線」的 bound direct-chat 部分。group read state、聊天 widget／host reminder、legacy unbound fallback、真人 UI／VoiceOver、雲端 session、完整 core 帳號資料遷移、live／release 與全 48 分類仍各自保留，整體 partial 不上調。observation 僅 fence 同一 repository，不宣稱跨獨立 repository／process 的 live fence、跨聊天 DB／automation store 原子交易或任意 snapshot 的跨 process CAS；未 push、啟動或重啟使用者 App／Xcode、改真實帳號／群組／聊天資料。

## 單獨聊天的 canonical 未讀畫面接線（2026-10-03）

接續 `d1ced91` storage foundation：主工作區 focused／active／可見的當前單獨聊天會更新 canonical read state，不要求一定有 routine 或 agent binding；有 binding 時仍限當前帳號、未封存的 exact owner。manual unread 不因取得焦點或新訊息而清除，右鍵提供「標示為已讀／未讀」；人類明確點選側欄開啟聊天則走 read，對齊 reference `activateSession` 的 activation 與單純 focus 差別，不把任何程式呼叫 `selectRoute` 當成這份人工證據。側欄從 canonical count 顯示未讀數（大於 99 顯示 `99+`，可存取標籤仍保留完整數字）。七語提供動作與標籤；分頁載入、workspace reload 與訊息保存後重新查詢狀態，不按每個文字 delta 清除手動旗標。

原始 native action 在排入 Task 前同步捕捉 account／generation／exact binding／可撤銷 lifetime；換帳號再回來、換綁定再換回來、移除／封存、舊 action replay 與較新的 action 可使其失效。automatic view 另限原 window／route／selection／epoch／最新訊息 ID 及 delivery status；新訊息到達同步撤銷舊 bound activity receipt，不等待下一次 SwiftUI render。讀取 projection 在同筆 SQLite transaction 重驗 binding，refresh epoch 避免舊 reload 覆蓋新手動操作。失敗不發布假零值、不把缺失 state 當已讀；查看或手動 read／unread 不回答、清除或恢復 spend guard 卡片／任務／權限。已手動未讀的聊天不再因 focus 更新 automation 的 viewed time。

有效紅燈 `conversation-unread-ui-red.log` 重現 canonical count 未清除及 manual unread 誤更新 guard，共 3 issues；`conversation-unread-ui-arrival-race-red.log` 重現已解析的 bound receipt 在新訊息未 render 時仍清除未讀並更新 guard，共 3 issues；`conversation-unread-ui-human-action-race-red.log` 重現 focus 回呼撤銷排隊中的人類 read／unread，兩種情境共 7 issues。修正後 automatic view 不覆蓋待提交的人工動作。`conversation-unread-ui-focused-final-v2.log` 的單一失敗另屬 fixture 未註冊假 provider，造成不可用提示覆蓋聊天而正確拒絕 bound viewed time；只補 fixture 的離線模型目錄，不放寬 error-cover gate，不當成新的產品語意紅燈。

最後聚焦 `conversation-unread-ui-focused-final-v3.log` exit 0：173 tests／24 suites（核心 69／15、App 102／8、Agents 2／1），涵蓋無 routine／unbound、explicit activation、手動旗標持久化、原始帳號／binding／arrival witness、replay、較新 action 與保存失敗。最後完整串行 `conversation-unread-ui-full.log` exit 0：135 XCTest＋1,784 Swift Testing（220 suites；核心 935／107、App 615／83）；兩項 opt-in live Codex 測試略過，不當成 live 驗收。七語各 1,789 keys／0 missing；七語×明暗共 14 個 224-point 窄版 render 通過 bounds／OCR 斷言，並逐張檢視徽章、spinner 與長標題／預覽截斷，沒有重疊；這不是真人點擊或 VoiceOver 驗收。

`conversation-unread-ui-native.log` BUILD SUCCEEDED；`conversation-unread-ui-package.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/SpendUnreadUIPackage/Filicon.app` 為 Debug／離線 gate，不是 release／公證；未執行其 launch smoke。日誌與 PNG 僅保留於忽略的 `.build/validation/`。本批使用受控 AppModel 與離屏 render，不啟動或重啟使用者 App／Xcode、不改真實群組或聊天。

本節只取代下面歷史「manual／automatic direct-chat UI 尚未接線」的部分。guard canonical unread counter、group read state、聊天 widget／host reminder、真人 UI／VoiceOver、雲端 session、完整 core 帳號資料遷移、live／release 及全 48 分類仍保留。unbound chats 的舊 core 資料仍不宣稱完整帳號隔離；聊天與 automation viewed time 是兩個 store，不宣稱跨 store 原子交易或任意 snapshot 的跨 process CAS。整體 partial 不上調，未 push。

## 聊天資料庫未讀／手動未讀基礎（2026-10-03）

reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `source/host/extensions/session/agent-db.ts` 保存 `lastActivityAt`／`lastViewedAt`／`isManuallyUnread`／`unreadCount`，`source/host/extensions/transcript/session-runtime.ts` 對 message／send-message／user-attachment 記錄活動，排除 `fromAgent` 的 incoming peer；`automation-spend-guard-runtime.ts` 使用這份 DB 狀態而非結果 wake 數。本批先補 native canonical storage，並未完成後兩者的 UI／guard 接線。

SQLite schema 17 加入每單獨聊天的 read state 及 message-ID activity receipts，與訊息保存同筆交易。read state 不放進 `Conversation` JSON／舊畫面快照；串流成功只計一次，編輯／反應／刪除後還原不重算，receipts 只隨整個聊天刪除。純工具／系統／未完成／失敗／incoming peer 不計；native 綁定且屬於該聊天的空正文 secret-request 卡片算已發表活動，不存憑證值。較舊／相同活動時間不倒退或重計，批次新發表的多訊息可一次計數，溢位飽和。

自動 viewed 可保留 manual unread，explicit read 清除旗標且時間不倒退；讀寫需 exact canonical binding（包括明確 unbound），最後同步 host commit guard 可取消，SQLite transaction 內重驗 binding。重綁 account／agent 會重設狀態並 seed 舊 ID，不把舊 owner 的未讀帶給新 owner。兩個 repository 實例的 read time 只前進，舊 content save 不覆蓋 read marker；這不代表 arbitrary snapshot 的跨 process CAS、完整 core 帳號隔離或 UI 生命周期已驗收。寫入 API 回傳 SQLite 已落盤的日期精度值。

schema 16 遷移／受信任舊 JSON import seed 歷史已發表 ID，不把整批聊天算成新未讀；尚未發表的串流 draft 在匯入後完成仍可成為新 arrival。普通 content save／read action 遇到缺失或損壞 read row 明確失敗，不自行補零。recovery 保存原始資料庫／WAL 隔離證據與報告；valid 手動未讀及已刪除／被拒絕訊息的 receipts 可保留，無法恢復的 read state 保守標成需注意，不宣稱人類讀過。損壞 receipt 若連對應歷史訊息也不存在，不能捏造其已計數 ID。

有效紅燈：`conversation-unread-storage-red-valid.log` 的未接線計數／重綁／回滾共 10 issues；`conversation-unread-recovery-red.log` 的缺失 row／空正文 secret 卡片／匯入未完成 draft 共 7 issues；`conversation-unread-storage-focused-final-v2.log` 重現兩 repository 的回傳日期與 SQL 精度不一致一項差異。`conversation-unread-storage-red.log` 及 `conversation-unread-storage-focused-unlocked.log` 是 fixture 的 await autoclosure／可變值 async-let 編譯錯誤，不當成產品紅燈。第一次擴大聚焦 `conversation-unread-storage-focused-final.log` 的既有 agents／policy／workflow 讀取 EPERM 與一項 mailbox cancellation 保留；不把 cancellation 本身當成鎖定證明，也不降低 `.completeFileProtectionUnlessOpen`。解鎖後最後 `conversation-unread-storage-focused-final-v3.log` exit 0：88 tests／23 suites，18 個新增測試涵蓋持久化／恢復／部分歷史／exact owner／原子回滾／多實例，其中損壞 row 另有兩種參數情境。

最後完整串行 gate `conversation-unread-storage-full.log` exit 0：135 XCTest＋1,771 Swift Testing（220 suites；核心 935／107、App 602／83），兩項 opt-in live Codex 測試略過，不當成 live 服務驗收。`conversation-unread-storage-native.log` BUILD SUCCEEDED；`conversation-unread-storage-package.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過，七語各 1,787 keys／0 missing。隔離產物 `.build/validation/SpendUnreadStoragePackage/Filicon.app` 為 Debug／離線 gate，不是 release／公證；本批未改 UI layout，完整套件中的既有 render 斷言通過，沒有新增真人視覺／互動驗收。日誌與產物只保留於忽略的 `.build/validation/`。

本批是 storage foundation，不是聊天未讀整套完成。既有 visible-chat 路徑仍只接 automation 查看時間，manual read／unread UI、guard canonical unread counter、group chat read state、聊天 widget／host reminder 均尚未接；真人點擊／VoiceOver、雲端 session、完整 persisted account migration、live／release 與全 48 分類仍需各自驗收，整體 partial 不上調。沒有 push、啟動或重啟使用者 App／Xcode 或改真實帳號／群組／聊天。

## 綁定單獨聊天的可見活動時間（2026-10-03）

reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `source/host/extensions/transcript/session-runtime.ts` 將 focused active session 的活動、取得焦點與啟用聊天接到 `markSessionViewed`；`source/host/extensions/session/agent-db.ts` 的查看與回答 spend guard 是兩條不同流程。Filicon 本批接上主工作區的真實 active／key／visible／非最小化／occlusion 狀態，設定視窗取得焦點不當成聊天已讀。首次 window attach、選取聊天、最新訊息 ID／delivery status 變化及 account generation 均重新解析；不按每個串流文字 delta 更新。

只接受目前 route＋selection、已載入最新訊息、未被 onboarding／feedback／強制更新／entitlement／工具核准／error 覆蓋、當前帳號未封存 owner 且有排程的明確 binding。canonical lookup 涵蓋未分頁／hidden histories，歧義不猜名稱；await 前註冊原始 generation／lifetime，取得 lease 後再核對 canonical profile 與畫面身分。route、selection、失焦、切帳號、封存、移除畫面或 binding 變化撤銷工作；即使工作尚未開始，換綁定再換回來也不能復活舊 epoch。新 receipt 不被晚到舊 receipt 的清理取消。最終同步提交以 lifetime＋binding lease 保護，lease 只保護同一 repository 的 mutation，不宣稱跨 repository／process 原子 CAS。

viewedAt 在畫面事件時捕捉；service 只接受比既有時間新的值，較舊／相同 callback 不倒退或重新計入舊 fires。原子保存失敗或 host commit 被拒絕不發布記憶中狀態。只更新該 owner，不回答或清除未回答卡片、snooze／opt-out／pause ownership，不恢復排程、不修改 definition／revision／工具核准。這是查看時間接線，不是人類批准無人值守執行。

有效紅燈保留於 `spend-guard-chat-view-monotonic-red.log`（舊回呼使查看時間／執行計數倒退）及 `spend-guard-chat-view-queued-rebind-red.log`（排隊前換綁定與換回原 owner 共兩種舊工作誤接受）；最初 `spend-guard-chat-view-focused.log` 是兩處 fixture upsert 缺少參數的編譯錯誤，不當成產品缺陷證據。最後聚焦 `spend-guard-chat-view-focused-post-rebind.log` exit 0：43 tests／3 suites，包含 service 時間順序／提交拒絕及 App 的 owner 隔離、replay、八種晚到取消、七種 lookup／queued 拒絕、新 receipt 仍可完成與 durable 重開。UI 焦點由受控 AppModel fixture 驗證，沒有啟動或操作使用者 App。

排隊換綁定修正後重新跑最後 source：`spend-guard-chat-view-full-post-rebind.log` exit 0，135 XCTest＋1,753 Swift Testing（219 suites；核心 917／106、App 602／83，兩項 opt-in live Codex 測試略過）；先前 full／native 日誌亦保留，但不替代最後 gate。七語各 1,787 keys／0 missing；七語×明暗×nudge／paused 共 28 個窄版 render 斷言通過，逐語檢視既有卡片換行／無重疊，這批沒有新增卡片 layout 或文字。`spend-guard-chat-view-native-post-rebind.log` BUILD SUCCEEDED；`spend-guard-chat-view-package.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物 `.build/validation/SpendGuardChatViewPackage/Filicon.app` 為 Debug／離線 gate，不是 release／公證或 live 焦點驗收；日誌與 PNG 只保留在忽略的 `.build/validation/`。

真正 transcript unread／manual-unread 仍未完成：reference `automation-spend-guard-runtime.ts` 讀取聊天 DB 的 `getUnreadState()`；native 仍由 pending result wakes 與 retained runs 近似計數。沒有新增每聊天 unread DB、手動未讀旗標、聊天 widget／host reminder；未綁定聊天不靠名稱推斷 owner，仍保留明確已讀入口。真人焦點／VoiceOver、雲端 metadata／session、完整 persisted account migration、live／release 及全 48 分類仍待各自驗收，整體 partial 不上調。下方較早「對話查看未接線」由本節局部取代，其他歷史 gate 不作最後 source 的證明。未 push、未重啟使用者 App／Xcode、未改真實帳號／群組／聊天資料。

## 經審核群組排程的活動保護豁免（2026-10-03）

本批補上下一節仍保留的群組差異：reference `automation-run-path.ts` 只對 `!isGroup && backgroundTrigger` 套用 guard。Filicon 現在於定時／事件批次及 scheduler 檢查前，由 trusted executor 解析 canonical human group binding、account、完整任務 digest、群組／成員及 direct binding 衝突；只對仍有效的已審核 group session 豁免。分類不進入 Codable definition、匯入或模型工具參數，模型文字／事件 `group`／`spend_guard_exempt` 提示不能指定豁免，text-only executor 也不能冒充 session executor。

同一 owner 的單人排程仍保護，已審核群組排程不因其逾期提醒、owner pause epoch 或卡片回答而被停用；真正人工停用及 definition revision 檢查不放寬。批次捕捉 group binding ID 及 host lifetime，帳號切換、封存與 routine／consent 撤銷同步撤銷舊分類。executor 必須再次匹配原 binding ID；失去或換了 binding 不可轉投其他 group／direct／plain 路徑。舊版已被 guard 暫停的群組不自動重啟，仍由人類回覆恢復；不是重新授予工具或背景記憶權限。

group runs 不計入單人 fires／pending wakes。新結果保存 optional `automationID` 關聯，歷史裁至最近 20 次仍不把群組結果誤算成單人未讀；重啟中斷結果亦保留關聯。舊 wake 缺少關聯時只利用仍保留的真實 run 解析；若兩者都沒有且 owner 同時有單人排程，保留保守計數、不捏造來源。這仍不是 reference transcript DB unread，未知舊資料與聊天查看／widget 接線仍保留驗收差異。

有效紅燈 `spend-guard-group-exemption-red.log` exit 1：實際 App 已審核群組因過期提醒被停用、沒有 schedule run，共兩項語意失敗。修正後聚焦 `spend-guard-group-exemption-focused-final.log` exit 0：177 tests／12 suites；涵蓋同 owner 混合排程、40 個 group wakes／20 筆 retained history、舊事件分類撤銷、真人綁定的六種失效情境及真實 group runner／run UUID／grant 保持。最終 source 另加 text-only 分類拒絕及七語明示豁免說明，最後完整串行 `spend-guard-group-exemption-full.log` exit 0：135 XCTest＋1,747 Swift Testing（219 suites，核心 915／106、App 598／83，兩項 opt-in live Codex 測試略過）。既有 CoreData NSXPC 診斷不是測試失敗，也不冒充 live 服務驗收。

最後 source 的七語各 1,787 keys／0 missing；七語×明暗×nudge／paused 共 28 個窄版原生 render 通過並逐語檢視 group 豁免說明、長名稱及按鈕換行／無重疊。`spend-guard-group-exemption-native.log` BUILD SUCCEEDED；`spend-guard-group-exemption-package.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。隔離產物為 `.build/validation/SpendGuardGroupPackage/Filicon.app`；這是 Debug／離線 fixtures，不是 release／公證或啟動使用者 App。日誌與 PNG 只保留於忽略的 `.build/validation/`。

這只補本機已審核 group routine 分支，不宣稱雲端 group session／metadata、真實 transcript unread／對話查看、聊天 widget／host reminder、完整帳號資料遷移、真人 UI／VoiceOver、live 平台、release 或全 48 分類已驗收。既有 AGENT-01／02／04、AUTO-03 整體仍 partial；未 push、未重啟使用者 App／Xcode、未改真實帳號／群組／聊天資料。

## 擁有者隔離的自動化活動提醒與安全恢復（2026-10-03）

reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `source/host/extensions/transcript/automation-spend-guard-runtime.ts` 與 `sand-automation-spend-guard.ts` 已核對：狀態、提醒、暫停及 opt-out 限各 session／agent；閒置三天且未讀至少 15 或執行至少 20 次才提醒，三天未答才暫停。Keep／Resume 只恢復 guard 暫停的定義並延後下一次檢查 30 天；Never ask 亦恢復 guard 暫停項目，但只關閉此擁有者的活動檢查；不補跑錯過的定時或事件，不授予新工具權限。查看對話不是回答提醒，也不隱式解除暫停。此為活動保護，不是精確金額預算。

Filicon 舊全域狀態已改為 schema 2 的 per-agent 狀態，schema 1 遷移只將已存在的定義、保留的 started runs 及 pending wakes 歸回各擁有者；舊 pause IDs 取該擁有者交集、提醒重新發卡，後來新增的代理人不繼承舊 opt-out。不支援的 schema／損壞的新版必須拒絕且不覆寫原檔。活動 counters 依目前保留資料計算，刪除定義及讀取後不再計入；不把晚到完成當成新的 started run。定時、事件及 scheduler 均在 admission 前檢查已逾期提醒；手動執行豁免。提醒回答、查看、暫停及恢復先計算完整候選再原子寫入，計算／磁碟失敗不部分發布、關卡或啟用。

App 卡片綁定確切 owner／persisted card ID／account／generation；舊卡、錯 owner、重播、帳號離開再回到原帳號與封存拒絕。切帳號及封存同步取消 mutation lifetime，再由 service 最後同步提交 fence 核對；舊回呼不重新發布新帳號投影。打開共用「自動化」頁不再把所有代理人當成已讀；各排程內的「標示為已讀」限該 owner，仍保留未回答提醒與 pause ownership。

自動 guard 暫停／恢復是 admission 狀態，不是任務定義修改，現在保留 definition revision，不能使原本已審核的 direct／group grant 無故失效。owner dispatch epoch 另行封閉暫停前已擷取但未 admission 的事件／定時 batch；恢復後舊事件及 coalesced 後續批次不能補跑，其他 owner 不受影響，寫入失敗也不提前推進 epoch。已 admission 的執行不在本批中取消，也不回滾完成效果；真正人工定義修改仍須重新審核。

有效紅燈包含 `spend-guard-parity-red.log` 的 8 個語意問題、`spend-guard-account-cycle-red.log` 的 2 個 stale-generation 問題、`spend-guard-binding-red-valid.log` 的 24 個 direct／group 授權與 shared runner 問題，以及 `spend-guard-dispatch-red.log` 的 4 個舊事件重啟問題。編譯、未完成的 headless event harness 與不透明 render 修正日誌另保留，不當作產品缺陷的紅燈證據。最後聚焦 `spend-guard-focused-final-7.log` exit 0：156 tests／11 suites（核心 113／7、App 43／4），實際 App 驗證 Keep／Resume／Never ask 後兩種既有對話仍走經審核 runner、真實 run UUID 及 durable grant 不變。

七語各 1,787 keys／0 missing，七語×明暗×nudge／paused 共 28 個窄版原生 render 通過並逐語檢視；長名稱、原生按鈕實際 frame／無重疊及水平不足時垂直排列均有斷言。修正法／西／日／韓語原有 Keep／Pause／Never ask／Resume／Stay paused 語意誤譯，另有七語逐項文字斷言。沒有以 headless AX 空集合宣稱 VoiceOver 或真人點擊已驗收。

第一次 `spend-guard-full.log` 未明確指定 `--no-parallel` 並與重型原生建置重疊，出現既有期限／UI 核准等待失敗；保留日誌，不歸咎已解鎖的檔案保護，也不略過失敗測試。最後單獨串行 `spend-guard-full-final.log` exit 0：135 XCTest＋1,741 Swift Testing（219 suites；核心 911／106、App 596／83），包含先前失敗的期限與圖庫案例；兩項 opt-in live Codex 測試略過。最新 `spend-guard-native-final.log` BUILD SUCCEEDED；`spend-guard-package.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。這是隔離 Debug／離線 fixture gate，不是 release／公證或 live 驗收；日誌及 PNG 位於 `.build/validation/`，不提交產物。

尚未閉合的 reference 差異：`automation-run-path.ts` 明確以 `!isGroup && backgroundTrigger` 套用 guard，群組 session 豁免；本批 native per-agent 保守規則仍涵蓋經審核 group-bound routines。pending result wakes＋明確 owner 已讀不等同原版 transcript DB unread／lastViewedAt；本機卡片位於自動化工作區，未接原版聊天 widget／host reminder，單 card ID 也非原版多 widget entry ID。account generation fence 不代表已新增完整 persisted per-account core migration。上述均保留，不能以本批恢復測試、七語 render 或回歸綠燈關閉 AGENT-01／02／04、AUTO-03 或全 48 分類驗收。未 push、未重啟使用者 App／Xcode、未改真實帳號／群組／聊天資料。

## 回合用量歸屬與原版費用契約核對（2026-10-03）

本批修正一般直接對話收尾的實際競態：原先於收尾讀取目前 conversation provider，並於非同步 settings 保存時讀取目前 account；已接收的用量可能因此歸到後來選取的帳號／供應商。現在沿用推論 admission 捕捉的 account＋provider，只更新已持久化的 `usageByAccount` 投影，不把舊 settings snapshot 蓋回畫面偏好。成功與收到 usage 後 transport 失敗均保留原始歸屬；不代表刪除／所有取消分支或群組／peer 用量已完整彙整。

隔離測試走實際 App `send`／provider stream／收尾／SettingsStore 保存，使用受控 gate 確認先收到 usage，再變更 account、provider 或兩者，成功／失敗共六種情境。`usage-attribution-red-canonical.log` exit 1 有 16 個真實歸屬斷言失敗；先前 fixture 未準備好與 private setter 編譯失敗的日誌另保留，不當作缺陷重現證據。修正後最後 `usage-attribution-focused-final.log` exit 0：33 tests／3 suites，涵蓋 routine／workflow direct session 回歸及六種歸屬情境；並驗證獨立、尚未落盤的 theme 不被 usage 寫入覆蓋。

reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的來源界線：

- `source/host/automations/automation.ts` 的 `AutomationRun` 與 `source/host/extensions/transcript/automation-run-path.ts` 的 `finishAutomationRun` 只記 run 身分、時間、狀態及 detail／event，未見每次 routine 的 token／price／cost 欄位或全群組／peer 成本彙整。
- `source/host/runner/turn-usage.ts` 有獨立 turn token 契約；`source/host/extensions/transcript/run-lifecycle.ts/reportTurnUsage` 依真正 session ID、request IDs 與 source 向 telemetry 回報。這證明回合用量設計，不證明每次排程已產生完整帳單。
- `source/host/extensions/transcript/sand-automation-spend-guard.ts` 依閒置三天、未讀至少 15 或執行至少 20 次提醒，再依未回覆時間暫停；不是精確金額預算。`source/shared/usage.ts` 的 weekly／on-demand 帳號投影來自外部服務契約，不是本機 per-routine 算價器。

因此以下歷史段落的「完整成本彙整尚缺」保留為 Filicon 的已知統計限制／驗收邊界，不逕列為 reconstructed 原版已確認卻尚未補齊的使用者功能。provider `costMicros` 與隔離 fixture 數值不是核對過的帳單；automation 的未知成本仍保留 nil，不補零或虛構價格。live account／billing、群組／peer 完整統計及所有取消／刪除路徑仍需各自驗收。

最後完整串行 `usage-attribution-full.log` exit 0：135 XCTest＋1,715 Swift Testing（217 suites；核心 893／105、App 588／82），兩項 opt-in live Codex 測試略過；既有 CoreData NSXPC 診斷不是測試失敗。`usage-attribution-native.log` BUILD SUCCEEDED；`usage-attribution-package.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過。七語各 1,782 keys／0 missing。這是隔離 Debug／離線 fixture 驗證，不是 release／公證或 live 帳單驗收；本機日誌不提交，未 push、未重啟使用者 App／Xcode、未改真實帳號／群組／聊天。

## Workflow 既有對話接線與無損編輯（2026-10-03）

經人類審核的 workflow prompt steps 已接入既有 bound direct conversation 的 shared runner。入口為「自動化 → 工作流程 → 展開流程 → 審核工作流程對話」；審核涵蓋整份定義及已解析的引用，不借用 routine grant，也不把 workflow 偽裝成已保存的 automation。manual／scheduled／verified event／replay 均保留真正 runtime run ID。背景 saved facts 另行 opt-in，peer 不繼承；工具仍需原有核准，typed action steps 仍全部拒絕。問題卡片使用 `waitingForReply` 停止後續步驟，人類回覆不自動恢復整條 pipeline。這是經隔離 App fixtures 驗證的本機接線，不是 live 外部服務或整體 parity 完成證據。

`workflow-review-race-focused.log` exit 0：65 tests／9 suites（核心 24／3、App 39／5、step context 2／1）。實際 App 路徑驗證指定歷史、memory off/on、無假真人訊息、private assistant 不發表、持久 SendMessage／peer／question、雙層本機寫入核准、四條 dispatch、真實 run UUID、忙碌／silence／provider 降級拒絕、六類晚到取消及跨帳號 grant 不能取代／撤銷。reference 變更撤銷整條多步驟流程；批准的模型 workflow 刪除亦取消依賴它的 runtime，保留取消歷史而不回滾已完成效果。

編輯器不再 flatten 多個 prompt 或丟失 action／source／停用狀態；保留完整原始定義、順序與建立時間，逐步新增／移動／移除並執行完整 bounds validation。固定底部使用 macOS 原生按鈕，Return／Esc 與 saving／invalid 狀態皆有實際行為斷言；捲動至底部仍可保存／取消。七語×明暗的審核及編輯器各 28 張頂部／底部 render 通過，並逐語視覺檢查；fixture 正文／action 名稱不是 UI 翻譯。修正繁中／簡中／法文誤譯的 `@every` 語法並補七語語意斷言。七語各 1,782 keys／0 missing。

歷史紅燈保留：`workflow-final-full.log` exit 1，既有刪除測試仍預期 captured run 成功，與本批取消政策衝突，已改為斷言取消、無晚到 outputs 及 durable cancelled history。該回歸亦重現一次 visible conversation identity 在 admission await 期間被 queued canonical snapshot 覆蓋，舊審核竟獲准；workflow／routine save 現在第一個 await 前即拒絕已不相符的投影，並於 await 後再驗 canonical／projection。新增受控 queued-restore 案例，未略過失敗。另一批大量 agents 讀取失敗伴隨 `IOConsoleLocked = Yes`／Cocoa 257／EPERM；未降低 `.completeFileProtectionUnlessOpen`，不將其他語意失敗一律歸為鎖定。解鎖後最後完整串行 `workflow-review-race-full.log` exit 0：135 XCTest＋1,714 Swift Testing（217 suites；核心 893／105、App 587／82），上述刪除、過期審核、圖片圖庫及 MCP 多帳號測試均通過；兩項 opt-in live Codex 測試略過，不冒充 live 驗收。

`workflow-review-race-native.log` BUILD SUCCEEDED，`workflow-review-race-package.log` 四個執行檔、deep strict 簽章及 app／XPC entitlements 通過；這是隔離 Debug 驗證，不是 release／公證。日誌與 PNG 位於 `.build/validation/`，不提交產物。本批未 push，未啟動或重啟使用者 App／Xcode、未改真實帳號／群組／聊天。

剩餘邊界：typed action handlers／逐 payload 人類權限、原版遠端 background session／cloud group metadata、完整成本彙整、外部平台與全部分類獨立驗收仍保留。Filicon 的多步驟／action enum 是 native 擴充，不是 reconstructed 原版已存在同名模型的證據；無損編輯通過不代表這些 action 已可執行，也不把 native 擴充逕列為已確認原版功能缺口。以下有日期的 routine／text-only 段落保留當批歷史狀態，由本節的 workflow 接線取代其「workflow 全為 text-only」描述。

2026-10-03 一般代理人排程接線增量：routine 現可經人類審核綁定至既有單獨聊天，走真正 shared runner、持久 publication／問題／委派及原有工具核准，使用 service 的實際 run ID。暫時 wake 不偽造人類訊息，舊附件不自動送往 provider；saved facts 另有預設關閉的獨立同意。過期身分、忙碌／問題等待、撤銷與晚到寫入均拒絕，普通／群組 grant 不可默默互換。以下「經審核 routine 的既有單獨聊天」記錄本批證據；未綁定 routine／workflow prompt 仍是 text-only，workflow action／完整費用彙整／外部平台／全 48 分類仍須補齊或驗收。

本批最後串行 gate `routine-direct-session-full-post-translation.log` exit 0：135 XCTest＋1,682 Swift Testing（210 suites，核心 887／103、App 563／78；兩項 opt-in live Codex 測試略過）。原生建置／封裝簽章、七語各 1,754 keys／0 missing 與 14 個明暗 render 通過；最後日文／韓文既有 Conversation 誤譯修正亦由此 gate 覆蓋。不以隔離測試取代 live 外部服務驗收。

2026-10-03 排程群組接線增量（前一批）：人類可將既有 routine 明確綁定至既有群組；手動、定時與已驗證事件使用同一個真正群組 runner／持久對話，不再只是獨立 persona＋prompt 回應。背景已保存記憶另有預設關閉的獨立同意，不能借用原本 direct／group／mailbox 同意。下方「經審核 routine 的既有群組 session」記錄當批範圍及證據；一般代理人本機分支由上方新批次補上。舊段落的「automation 全為 text-only」是此前狀態，未綁定 routine 與 workflow prompt 仍維持 text-only；完整 workflow、外部平台與全 48 分類仍須補齊／驗收。

前一批群組最終串行回歸 exit 0：135 XCTest＋1,660 Swift Testing（核心 882／101 suites、App 546／76 suites；兩項 opt-in live Codex 測試略過）。原生建置、四個執行檔的封裝／deep strict 簽章及 entitlements、七語各 1,740 keys／0 missing 通過。既有 CoreData NSXPC 診斷不視為測試失敗，也不冒充 live 外部服務驗收。

2026-10-03 共用 runner 增量：工具批次、互動 callback 及 plain coordinator 已接上嚴格 provider-response 完成判定，Gemini 保留真正失敗原因；124 項聚焦回歸／9 suites、完整串行回歸 exit 0：135 XCTest＋1,640 Swift Testing（兩項 opt-in live Codex 測試略過）、原生建置、封裝和七語檢查通過。以下專節保留本批證據與尚未接線的完整背景 session／記憶 audience／外部驗收；不以安全修正關閉整體 partial。

2026-10-03 背景純文字增量：workflow／automation 的結果收集現在要求明確完成，拒絕遺失結尾、截斷、工具事件及晚到錯誤，並有累計 UTF-8 上限；明確空白 stop 和完成後 usage 仍接受。最後聚焦 41 tests／4 suites、完整串行回歸 exit 0：135 XCTest＋1,632 Swift Testing（兩項 opt-in live Codex 測試略過），原生建置／封裝簽章及七語檢查通過。這是既有 text-only 路徑的結果修正，不以此關閉背景 runner、記憶 audience、外部服務或全 48 分類驗收。

2026-10-03 workflow 生命週期增量：帳號切換現在同步撤銷整體 workflow 執行範圍，再取消 runtime 與共用代理人排程器；手動、已驗證事件、定時及重播四條入口均保留原始 dispatch fence。晚到核准／模型結果、同批後續 workflow 與舊 UI reload 不得跨越撤銷，成功歷史及 UI 投影使用同步提交 fence。43 項最終聚焦測試、原生建置／封裝簽章及七語檢查通過；最後完整回歸 exit 0：135 XCTest＋1,622 Swift Testing（兩項 opt-in live Codex 測試略過）。以下專節保留背景執行器與記憶授權的實際差異，不將本批取消修正寫成全背景 runtime 對等。

2026-10-03 最新圖片增量：第七十七／七十八階段補齊十一格式獨立傳檔 MIME、一般 AVIF／ICO／SVG 預覽判定與已驗證圖片快照／有界 PNG 縮圖，原始 CAS bytes 不替換。46 項聚焦測試、77 個新增 canonical App 案例及十四個七語預覽 render 通過。歷史中止／EPERM 日誌保留；受保護探針恢復後，最後全專案串行 gate exit 0：135 XCTest＋1,609 Swift Testing（核心 859／98 suites、App 527／74 suites；兩項 opt-in live Codex 測試略過），原生建置／封裝簽章與七語各 1,724 keys／0 missing 通過。未移除保護、未重啟使用者 App／Xcode。完整格式變體、AV／Quick Look URL 邊界、其他分類及外部驗收仍保留，不能以本批通過宣稱所有 48 分類完成。詳見 [傳檔第七十七／七十八階段](Send-message-files-parity.md)。

2026-10-03 最新 SVG 增量：第七十六階段已接入安全驗證器支援的靜態自包含 SVG，保留原檔並僅將顯示畫面轉為有界 PNG。53 項聚焦測試、56 個七語卡片與全部 436 個 canonical App 案例通過，既有頭像 SVG 回歸未受影響。最後全專案串行 gate exit 0：135 XCTest＋1,593 Swift Testing（核心 853、App 517）；原生建置／封裝簽章、七語各 1,724 keys／0 missing 通過。完整瀏覽器 SVG、真實 HEIF、其他變體、獨立傳檔 MIME 及其他分類驗收仍保留，不將本批靜態子集寫為全部對等。詳見 [傳檔第七十六階段](Send-message-files-parity.md)。

2026-10-03 最新增量：第七十五階段補上真正 AVIF／ICO 的經審核圖庫及共用預覽，保留原始 bytes／完整核准與 strict incoming／SendToAgent 邊界；八格式 viewer、42 個七語卡片與全部 386 個 canonical App 案例通過。最新全專案串行 gate exit 0：135 XCTest＋1,587 Swift Testing（核心 847、App 517）；原生建置／封裝簽章及七語各 1,724 keys／0 missing 通過。SVG、真實 HEIF、未覆蓋變體、獨立傳檔 MIME 與完整 lifecycle／外部驗收仍保留。以下日期段落是歷史進度，不能將當時 AVIF／ICO 尚缺當成目前狀態。詳見 [傳檔第七十五階段](Send-message-files-parity.md)。

2026-10-03 增量：經審核本機圖庫已接入 GIF／APNG／WebP 動畫及 TIFF／BMP／HEIC，原始 CAS bytes 與完整核准不變，strict incoming／SendToAgent 仍限唯一單幀 PNG／JPEG。核心 27、App 12 項聚焦測試（含全部 366 個 canonical publication 案例）通過。完整回歸首輪途中鎖定而中止，保留失敗日誌；受保護探針恢復後，最後完整串行 gate exit 0：135 XCTest＋1,586 Swift Testing（核心 846、App 517），原生建置／封裝簽章及七語各 1,724 keys／0 missing 通過。其他格式、真實 HEIF、獨立傳檔 MIME、快取及完整 lifecycle／外部服務驗收仍保留；原版不索引 text gallery 的別名，因此該 Filicon 限制不是已確認原版功能缺口。詳見 [傳檔第七十四階段](Send-message-files-parity.md)。

2026-10-02 增量：本機獨立傳檔、HTTPS 附件 locator 及文字內 local／HTTPS 混合圖片集已接入 direct、前景／背景群組、mailbox 與 direct peer；有完整核准、配額、重開及撤銷隔離測試。第七十一階段新增 GIF／APNG／WebP 有界內嵌播放；第七十二階段移除經審核圖庫的四張限制與 viewer 前 50 張截斷，新增有界本機縮圖；第七十三階段支援重複來源的獨立位置與說明，並修正直接對話 transcript 副本仍拒絕重複附件的實際缺陷。受保護儲存探針恢復正常後，最新全專案串行測試 exit 0（135 XCTest＋1,577 Swift Testing）；原生建置、封裝簽章／entitlements、七語各 1,723 keys／0 missing 通過。canonical App 路徑的原有 116、增加大量圖片 30、重複圖片 40 案例及 group／mailbox GIF／APNG 保存重開均通過；未移除檔案保護、未重啟 App／Xcode、未修改真實帳號或群組。模型輸入／SendToAgent 四張、本機 5／12 MiB 與工具參數預算不變。下方日期段落是歷史進度，不能以「尚未接線」覆蓋後續實作；最新媒體證據與本機格式、大檔、alias 搜尋、快取、完整 crash／UI lifecycle 等邊界見 [傳檔第六十九至七十三階段](Send-message-files-parity.md)。所有 48 分類仍須逐項驗收，不以本批回歸綠燈宣稱全功能對等。

本檔不取代使用者要求或縮小 parity 範圍。基準 Filicon `a7ca268`、reference `a9f633e09d49a85829b8236331b9e21f7e612634`；工作樹檢查為乾淨。沒有啟動 App、使用外部帳號或重新驗證 release。

## Matrix 不是完成證明

`PARITY.md` 有 48 個 ID；2026-10-05 因確認 `UI-04` 尚缺 reference 的完整 math／diagram runtime 與 viewer，將該歷史 complete 修正為 partial。其後三種有界 diagram viewer、公開 pinned KaTeX、prose／table inline math 已接線（見本文件最上方各節），但 opaque asset bytes、完整 strict Mermaid runtime／語法／精確幾何及必要 runtime 驗收仍保留。矩陣現為 42 個歷史 complete、5 個 partial（UI-04、AGENT-01／02／04、AUTO-03）、1 個 NA（UPD-04）。complete 必須逐項連到當前可達流程、對應測試及必要 runtime 驗收；「final gates passed」本身不能證明全功能對等。近期完整 Swift 測試／原生 build／package verifier 是回歸與封裝證據，不替代外部帳號、權限 UI 或 release 驗收；更早日期段落的 43／4／1 是當時紀錄。

以下保留全部驗收範圍：UI-01…04、CONV-01…04、ATT-01…04、PROV-01…04、MCP-01…04、AGENT-01…04、AUTO-01…04、COMP-01…04、ACCT-01…04、NOTIF-01…04、PERS-01…04、UPD-01…04。尚未逐項重驗者標記為未重驗，不推論缺失，也不視為已完成。

## 自身側欄可見性：基準缺口與實作驗收

以下依提交順序保留歷史進度；最新 App 接線狀態見本節末的「模型入口」。不以中間階段的「尚未接線」當成目前結論，也不以此單一功能取代其餘 48 項驗收。

- reference `runner/tools/sand-state-tool.ts` 的 settings schema／dispatch 接受 optional boolean `hidden_from_sidebar` 與 `notify_on_updates`，只更新提供欄位；`extensions/memory/agent-state.ts/updateSettings` 寫入設定後回報成功，空修改拒絕。
- reference session summary 讀 settings.hiddenFromSidebar 並投影為 isHiddenFromSidebar；工具描述明示隱藏不封存、不停止任務，仍可搜尋與由 Hidden chats 恢復。
- 注意 production composition 的 createAgentState options 未提供這個函式要求的 writeSettings。上述是已確認的 schema／實作／UI 設計，不宣稱該 reconstructed production 工具路徑已跑通。
- Filicon `AgentSettingsChange` 只有通知布林值，`AgentManagementSession` 明確拒絕 hidden_from_sidebar，測試也固定為拒絕；人工 `setConversationHidden` 只改 conversation.hiddenAt，先變更記憶體再 Task persist。模型工具不能直接呼叫此 fire-and-forget setter 並立即回報保存成功。

補齊的驗收要求：

1. Host 依 account＋自身 agent binding 選唯一聊天，不能依標題、任意 conversation ID 或群組發話位置猜測目標；不存在／歧義不得隱藏他人聊天。
2. 明確 before/after 核准，partial fields 保留，通知與可見性不可互相覆寫。若合併修改，成功回報必須反映真正已持久化結果，不以部分保存冒充原子成功。
3. Stop／切帳號／封存／聊天刪除或重新綁定／stale approval 均重驗；失敗不產生不可恢復的 UI 隱藏，不捏造成功。
4. 隱藏不刪歷史、不撤銷工作、不移出群組；搜尋／Hidden chats 可恢復，重開保留。同一 action 的重播不得重複變更。
5. 七語核准與狀態、fixture App 接線測試、儲存失敗／重開及帳號隔離測試、完整回歸和原生封裝驗證；不得操作真實群組或聊天。

### 儲存基礎進度（2026-09-27）

已新增 host-owned `AgentSidebarVisibility`，以 account／agent／conversation 三者精確綁定並保留 revision；舊資料缺少此欄位時預設空陣列。`AgentSettingsChange` 可攜帶此變更，與通知設定在同一次 agents state 原子寫入中提交；失敗一併回滾，快照串流包含已保存的可見性資料。隔離測試涵蓋混合提交、重開、帳號隔離、過期提案、取消及磁碟失敗。

這只是儲存基礎，不列完整功能完成：AgentService 不持有聊天資料庫，不能自行證明 conversation binding 有效；仍需 host 唯一聊天解析、提交前綁定重驗、七語核准、UI 投影及人工隱藏／恢復使用相同來源。模型 schema／執行器仍明確拒絕 `hidden_from_sidebar`，不會提前啟用。

驗證：`AgentSettingsChangeTests` 9 tests 通過、完整 nonparallel Swift tests exit 0、原生 Debug build exit 0、verify-package deep/strict codesign 通過。日誌位於 `.build/validation/sidebar-settings-{focused,full,native}.log`（不提交產物）。沒有啟動 App 或修改真實資料。

### 精確聊天查找（2026-09-27）

`ConversationStore.uniqueBoundConversation` 透過 repository 單次、無 suspension 的 metadata 掃描解析 account＋agent 綁定；不讀訊息、不依標題、不受 UI 分頁或 hiddenAt 過濾影響。不存在回傳 nil，兩個以上相同綁定明確拒絕，空帳號拒絕。測試包含超過 50 筆的未載入頁、隱藏聊天、同名未綁定、外部帳號／另一代理人、重開、重新綁定及刪除後再次查找。

此查找只證明查詢當時唯一，**不是跨 actor 提交鎖**。模型入口仍關閉；host 接線仍須在核准後重新查找並以生命週期 fence 防止查詢與 agents state 提交間的刪除／重新綁定。UI、搜尋索引、人工恢復與權限卡片尚未共用新的可見性來源，不能列為完成。

驗證：`BoundConversationLookupTests` 通過、完整 nonparallel Swift tests exit 0、原生 Debug build exit 0、verify-package deep/strict codesign 通過。日誌 `.build/validation/sidebar-binding-{focused,full,native}.log` 不提交。

### 工具 adapter 進度（2026-09-27）

AgentManagementSession 在 host 同時提供 sidebar preparer 與 custom settings committer 時，才宣告並接受 optional `hidden_from_sidebar`。支援只改隱藏、只改通知、兩者一起改；省略欄位保留、嚴格 JSON boolean、四次共用預算、核准前後取消檢查及相同 call 的重播仍受控。preparer 必須回傳此帳號／此代理人／要求值；模型不能指定目標聊天。沒有完整 adapter 時沿用通知限定 schema，preparer 單獨注入不能啟用。新增 effective previousHidden 供 legacy hiddenAt 的核准展示，不把「沒有 override」誤當成可見。

隔離 adapter 測試已涵蓋單獨／合併變更、保存前狀態、重播、不同 payload 同 call 拒絕、缺 commit、缺核准、外部帳號、取消及非布林值。錯誤訊息補齊七語。**原生 App 尚未注入 preparer，功能仍未啟用**；核准卡片、binding fence、搜尋／UI 投影與人工恢復仍須實作並驗證，不能把 adapter 測試當成 App 端到端通過。

驗證：設定定向測試 11 項通過；最後 source 的完整 nonparallel Swift tests、原生 Debug build 均 exit 0，verify-package deep/strict 通過。`.build/validation/sidebar-adapter-{focused,full,native}.log` 為本機日誌，不提交。未啟動 App，未操作真實帳號資料。

### 核准卡片（2026-09-27）

App 的設定核准 metadata 現由共用 presentation builder 產生。可見性提案在建立核准卡片前，依 account＋agent 再查唯一聊天並核對 ID，不以來源群組或聊天標題代替目標。卡片分開列出通知與側欄的前後值、聊天名稱及完整 ID，避免在合併修改時仍宣稱「visibility unchanged」。legacy 沒有 override 時使用 host 捕捉的 effective previousHidden。原本 notification-only 卡片保持原流程。

新增七語文案；隔離渲染覆蓋七語、深淺色、隱藏／恢復兩方向的 380 pt 寬度。檢視繁中淺色與法文深色圖片無文字裁切或重疊。卡片 metadata 不含 account ID 或私有 instructions。此批仍未啟用原生 preparer；提交時的 binding fence、sidebar／搜尋投影及人工恢復還未接妥，不宣稱可見性端到端已完成。

驗證：通知核准生命週期及兩組七語渲染定向測試通過，完整 nonparallel Swift tests／原生 Debug build 均 exit 0，verify-package deep/strict 通過。日誌 `.build/validation/sidebar-approval-{focused,full,native}.log`，渲染 `.build/validation/sidebar-approval-renders/` 不提交。未啟動使用者 App。

### 可見性搜尋投影（2026-09-27）

新增 Domain `ConversationVisibilityOverride`，只對相符的 conversation＋account／agent binding 生效，否則保留 legacy hiddenAt。repository 在訊息 FTS、媒體、備援掃描與聊天搜尋排名／上限前套用 override；備援的聊天掃描上限也在可見性過濾之後。串流 live input 與 persisted hit 使用相同、經資料庫 binding 驗證的可見性，避免已恢復的舊 hiddenAt 聊天仍不可搜尋。includeHidden 保留既有含隱藏搜尋用途；不改寫歷史或 legacy 欄位。測試以 56 個命中驗證排除／恢復、limit=1、三種搜尋、備援、串流，以及重新綁定後舊 override 不再生效。

此 API 尚待 App 將已保存的 agent visibility snapshot 傳入，並與側欄列表、人工隱藏／恢復及 lifecycle fence 一起接線；不視為使用者端功能已完成。

驗證：定向搜尋測試通過；包含最終串流與備援規則的完整 nonparallel Swift tests exit 0，原生 Debug build exit 0，verify-package deep/strict 通過。日誌 `.build/validation/sidebar-search-{focused,full,native}.log` 不提交。

### App 可見性與人工恢復（2026-09-27）

App 現在於啟動、重新載入及 agent snapshot 更新時讀取已保存的側欄設定；側欄、隱藏聊天、預設選取與三種搜尋共用精確 binding 的 effective visibility。使用 snapshot revision 防止較舊的串流事件覆蓋人工操作剛取得的新狀態，設定更新也會使搜尋結果失效並重新查詢。

已綁定成員的聊天由人工隱藏／恢復時，先驗證目前帳號及 durable conversation binding，再保存 override，成功後才改畫面；磁碟失敗保留原狀。刪除聊天及切換帳號會關閉待提交 lifetime。人工可恢復已封存成員的聊天，但不解除封存、不改通知、不改寫聊天歷史。未綁定聊天仍沿用 legacy hiddenAt 路徑。本批的隔離 App 測試涵蓋保存／重開／搜尋、磁碟失敗、外部帳號、封存後恢復及舊快照拒絕。

模型 preparer 仍未注入。接續須完成模型核准後的唯一 binding 重驗及生命週期提交 fence、可見性 quota 記帳，再做模型端到端測試；本批不代表原版設定工具已完整啟用。

驗證：定向測試通過；含最終 revision 防護的完整 nonparallel Swift tests 與原生 Debug build 均 exit 0，verify-package deep/strict 通過。日誌 `.build/validation/sidebar-app-{focused,full,native}.log` 不提交。未啟動 App 或修改真實資料。

### 唯一 binding 提交憑證（2026-09-27）

新增短期 `ConversationBindingLease`。repository 在同一次無 suspension 的操作中查找唯一綁定並登記憑證；保存聊天集合前，若目標被刪除、重新綁定或新增第二個相同 account／agent 綁定，先同步撤銷。改名及新增訊息不撤銷。`AgentService.applyBoundSettingsChange` 檢查精確 account／agent／conversation，依「binding lease → settings lifetime → 同步磁碟保存」順序持鎖，讓撤銷和設定保存有明確先後；未保存不產生 receipt，通知與可見性仍同時提交。

隔離測試涵蓋改名／訊息成功、刪除／重綁／重複／手動撤銷取消、錯誤目標拒絕及重開後兩欄位一致；模糊 binding 也不能取得憑證。此憑證只保護透過核發它的 repository 執行的寫入，**不是跨程序或不同 repository instance 的資料庫鎖**。

App 尚未啟用模型 preparer；還要將憑證取得、finally 撤銷、來源生命週期、quota 及保存後畫面接線並完成 App 測試。來源查找確認目前 AppModel 建立一個 ConversationStore，該 store 快取一個 repository；若新增不同 repository instance 的寫入路徑，必須先統一或擴充 fence，不能直接宣稱端到端已完成。

驗證：定向 13 項測試通過，含最終精確錯誤斷言的完整 nonparallel Swift tests／原生 Debug build 均 exit 0，verify-package deep/strict 通過。日誌 `.build/validation/sidebar-lease-{focused,full,native}.log` 不提交；未啟動使用者 App，未改真實資料。

### 模型入口（2026-09-27）

App 已注入 sidebar preparer。模型可提出 optional `hidden_from_sidebar`／`notify_on_updates`，至少一項；host 依當前帳號和自身 agent 查唯一 direct chat，模型無法指定目標 ID。核准卡列出兩個設定的 before/after 及聊天 ID。核准後重新取得 repository lease；聊天刪除或帳號切換會同步撤銷 App 登記的 lease，原有 session lifetime 保護 Stop。legacy hiddenAt 變更也撤銷 lease，避免核准舊狀態後覆蓋人工操作。通知與側欄各自先保留 quota，兩者由同一次 agents state 保存；保存後才更新共用 snapshot。晚到的 quota 記帳錯誤保留 durable receipt，不謊稱資料回滾。

App fixture 覆蓋隱藏／恢復、合併修改及單改可見性保留通知、核准前未變更、拒絕／停止／切帳號／刪除／重複綁定／封存／磁碟失敗／人工版本衝突、重開保留與不影響群組成員及他人通知。缺少或歧義聊天在核准前拒絕。服務／repository 測試另涵蓋重新綁定、舊 hiddenAt 變更、嚴格 boolean、重播、保存失敗及精確帳號投影。

驗證：runtime 最終 source 的完整 nonparallel Swift tests／原生 Debug build exit 0，verify-package deep/strict 通過；最後新增的人工版本衝突及 legacy hiddenAt 測試再定向通過（App 20＋2 cases，repository 8 cases＋查找測試）。日誌 `.build/validation/sidebar-host-{focused,full,native,final-focused}.log` 不提交。

原生 App 採單一 ConversationStore／repository；憑證仍不是跨程序 CAS。未做真實帳號操作、沒有啟動使用者 App；整體 parity 仍須下列其他分類的當前證據，不能標記全部完成。

## 必須保留的其他分類

- 圖片頭像：模型主機／box 來源、獨立讀取與圖片預覽核准、提交、direct／mailbox／remote fixture，以及人工匯入前配額已接線（截至 `549f96f`）。見 [Avatar-image-parity.md](Avatar-image-parity.md) 第七至十階段；CAS 回收／崩潰復原、完整 SVG 範圍、最低 macOS 與真實遠端服務驗收仍保留，不能標為整體完成。
- 檔案／媒體：`SendMessage` 的本機獨立檔案、HTTPS locator 與本機／遠端文字圖片集已接入上述五條 App 路徑，隔離測試不等同真實服務驗收。遠端有界動畫、四張以上的經審核圖庫、重複來源、真正 AVIF／ICO、安全驗證器支援的靜態自包含 SVG、十一格式獨立傳檔 MIME 及一般圖片驗證快照已實作；第七十八階段最後完整串行 gate 通過。大檔、更廣 SVG、真實 HEIF、未覆蓋格式變體、快取、AV／Quick Look URL 與完整 crash／UI lifecycle 邊界仍保留。text-gallery 別名索引不列為原版缺失功能，見 [Send-message-files-parity.md](Send-message-files-parity.md)。reference composition 未注入 box resolver，不能把可選介面當成遠端端到端證據；保存 HTTPS locator 也不是授予下載權限。

- 記憶：最新保存／搜尋／synthesis／episode／project recall 證據見 `Memory-archive-parity.md`；跨 epoch snapshot 是未接線參考設計，見 `Memory-snapshot-audit.md`，不能自行換成永久 cache。
- 協作／訊息：AGENT-02／04 的歷史缺項需與 `Agent-collaboration-parity.md` 後續進度及 current source 逐項對照；不能用舊行的「缺」覆蓋已完成的接線，也不能以有 UI 就宣稱工具／背景路徑完成。
- 平台事件：AUTO-03 的 Teams 使用者驗證、GitHub CI-completed 後端契約、Slack 名稱／自身身分映射等仍有差異，詳見下節再核對。reference 未提供 checks 彙整演算法，不因 generic matcher 通過而放寬驗證政策。
- 發佈／外部能力：UPD-03 的既有 release 是歷史證據，本目標禁止 push／真實帳號修改；不能擅自發新版本、連接帳號、安裝插件或替使用者授權。最終報告須明列尚需哪些外部驗收與決策，不把它們藏在 complete 標籤後。

## 平台觸發：當前契約與後端邊界再核對（2026-10-03）

Filicon `aa3a59c`，reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。本節是實際 source 呼叫鏈及本批既有隔離測試結果核對，不是連線平台或執行 reconstructed App；未取得真實憑證、未連接帳號、未安裝 webhook、未改使用者資料。

reference `source/host/extensions/automations/extension.ts` 的 production composition 建立 `AutomationsService` backend client、`SandAutomationCloudSync`、`createBackendRelaySources` 和 fire consumer，皆由 reference auth／backend URL 提供權限。這不是可直接移植的無帳號本機平台 runtime。`backend-relay-source.ts` 透過 `/sand/listener-subscriptions` 及 `/sand/listener-events/poll` 的 bearer-authenticated 後端取得事件／scope 狀態，再交 local hub；Filicon 不具備或借用該產品私有 backend／登入。

| 分類／能力 | reference 的已確認契約 | Filicon 當前邊界與下一個必要條件 |
| --- | --- | --- |
| AUTO-03／GitHub CI | `sand-automation-cloud-sync.ts` 將 repo、branch、SUCCESS／FAILURE／ANY 編成 `GitCICompletedEvent`，後端 relay 交付已分類的 `ci-passed`／`ci-failed` | 本機 normalizer 只承認同 repo 的 completed push `workflow_run`；不是等同後端 CI-completed 契約。該 source 呼叫鏈沒有 all-checks 查詢／彙整演算法，proto 也僅有欄位，不能把歷史「checks 彙整」用語當成已讀過的完整實作。若補此能力，須先定義 CI 完成範圍、可信事件／查詢來源、branch／commit／重跑身分及 pending／取消語意，不能因單一 workflow success 就回報所有 checks 通過。 |
| AUTO-03／Slack 名稱與自身反應 | relay 訂閱 channel 文字，後端回報 unresolved／bot membership；wire event 的 channelName／channelId 與 isSelf 由後端供應，cloud trigger 使用 onlyOwnerReactions | 本機入口接受明確 conversation ID 或 *，沒有可信的人類登入身分／名稱目錄，bySelf true 仍拒絕。`SlackChannelConnector.profile` 的 auth.test 回報配置 token 所屬 bot，不能冒充人類 owner。下一步須有帳號＋workspace 綁定的使用者授權／可信目錄及撤銷策略，不接受 webhook 自報 isSelf 或猜測名稱。 |
| AUTO-03／Teams 已登入使用者限制 | cloud trigger 傳 tenant／team／channel、literal／regex 及 blockUnauthenticatedTeamsUsers；reference matcher 在 platformMatched 邊界依賴後端驗證 | Filicon outgoing HMAC 僅證明傳輸，aadObjectId 不證明登入 Filicon。預設登入限制下事件仍 fail closed；模型／人工只能保存受限定義。須補可信 tenant＋application-user 綁定、登入驗證與撤銷／帳號切換，不能把簽章、AAD 字串或 payload authenticated=true 當作該權限。 |

`native-image-preview-unlocked-full.log` 中 `GitHub routine event boundaries`、`Slack routine event boundaries`、`Teams outgoing event boundaries` 三個現存 suite 均通過；包含九種 workflow conclusion、偽 self 拒絕，以及 signed webhook／AAD 不代表 application-user authentication。這些證明目前有限契約與 fail-closed 行為，不證明新平台能力已補齊。完整回歸及封裝證據見本檔最新圖片段落，沒有因 documentation 再核對修改 production 政策或重新執行 live 測試。

AUTO-03 維持 partial，不能因通用 HMAC／matcher 已有就改為 complete；也不能僅見外部 proto 就聲稱原版後端實作已在 reconstructed 倉庫。此核對只涵蓋三條平台流程，其餘 48 分類、人類互動、release／最低 macOS 及真實外部驗收繼續保留，不將平台邊界縮小為圖片工作。

## 背景執行流程：workflow 帳號撤銷與未補齊邊界（2026-10-03）

reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。`source/host/extensions/transcript/automation-run-path.ts` 先 `resolveBackgroundSession`，再進同一 session 的 exclusive run；一般代理人呼叫既有 `runner.run`（hidden／automationWake），群組則進 `runGroupAutomation`。這是已確認的背景 session／runner 接線，不是獨立的 persona＋prompt 查詢。另一方面 `host-runner-composition.ts` 的 production context dependencies 仍將 memoryStore／memorySnapshots／userMemory／projectMemory 回傳 null，不能據此宣稱 reconstructed production 已證明所有背景記憶注入。

此生命週期修正當時，Filicon `AppAutomationExecutor` 與 `AppWorkflowPromptExecutor` 都只使用 profile instructions、提示詞及後者的 prior outputs 呼叫普通 provider stream。後續兩批已接入經人類獨立審核的本機 routine 群組及單獨聊天 runner，詳見下方專節；未綁定 routine／workflow prompt 仍是 text-only，workflow action 的 App handler 仍全部拒絕。共用 agent lane 本身不等於共用聊天／mailbox、記憶或完整背景 runtime，AGENT-01／02／04 與 AUTO-03 整體不改為 complete。

既有共享事實 consent 明確只涵蓋 bound direct chats、group chats 與 mailbox turns（`en.lproj/Localizable.strings` 的 Shared facts 文案）。本批沒有自動把已核准事實送往無人值守 automation／workflow，也沒有賦予新的工具或帳號權限。後續 routine 背景記憶使用新的獨立 opt-in，不借用該既有 consent，也不把共用 scheduler 當成同意；workflow 背景記憶尚未接入。

本批修正先前可直接重現的生命週期缺口：原 App 切帳號只取消排程器，沒有取消多步驟／批次 workflow 的整個 runtime。

- 新增 process-local `AgentWorkflowExecutionScope`，在切帳號第一個 await 之前同步 suspend。每次 suspend／invalidate 都永久撤銷舊 lease；重疊切換須全部 resume 後才能接受新 dispatch，不會重新啟用舊 lease。lease 不持久化，不是 tool permission。
- Service 與 runtime 各自捕捉 scope，繼承的 host lease 只補充、不取代自身撤銷；即使上游使用另一個獨立 scope，runtime cancelAll 仍阻止同批下一個 workflow。每一步、核准返回後、進入 agent lane 後、模型每個事件及空串流結束後均重驗。已撤銷時晚到一般錯誤／deadline 仍記為 cancelled，不冒充失敗後可接續或成功。
- 最終成功歷史／磁碟寫入及 UI 投影持有全部相依 scope 的鎖，依 ObjectIdentifier 排序、同一 scope 去重；同步保存與撤銷有明確先後，不以 preflight check 代替提交 fence。這不新增磁碟交易格式；保存本身失敗仍回報失敗，不捏造已落盤回條。
- 四條 App dispatch 在跨 actor 之前捕捉原始 lease；service 的 store 查找後及 runtime admission 再重驗，舊 dispatch 不能取消相同 ID 的新流程。舊 schedule tick 不推進下次時間，run／replay／event 的 UI reload 在 await 後重驗，不覆蓋新狀態。
- cancelAll 不清空定義、刪除歷史或提前釋放仍未 unwound 的 active agent lane。新流程在原 operation 收尾後可正常執行。這是合作式取消與結果隔離，不是回滾已完成的外部動作，也不能強制停止忽略取消、永不返回的第三方 executor。

隔離測試使用固定日期／識別與受控 gate、CustomDump 狀態斷言，涵蓋四條入口、八種 runtime／上游 scope 組合、晚到錯誤與核准、相同 ID 新舊 dispatch、實際 App 切帳號排隊、文字／空串流、UI reload、新流程及 service 重開，以及同步保存／撤銷順序與繼承 scope 去重。早期兩輪測試編譯問題（async autoclosure／非 Equatable request）與時間精度 fixture 的紅燈日誌保留；`workflow-account-scope-focused-commit-fence.log` exit 0：43 tests／4 suites。最後完整串行回歸 `workflow-account-scope-full-final.log` exit 0：135 XCTest＋1,622 Swift Testing（核心 860／98 suites、App 531／74 suites；兩項 opt-in live Codex 測試略過）。`workflow-account-scope-native-final.log` BUILD SUCCEEDED，`workflow-account-scope-package-final.log` deep／strict 簽章、四個執行檔及 app／XPC entitlements 核對通過；七語各 1,724 keys／0 missing，受保護儲存探針成功。第一輪完整回歸也是 exit 0，但發生於最後同步提交修正之前，不作為最終 gate。日誌在 `.build/validation/`，不提交產物。沒有 push、啟動／重啟使用者 App／Xcode、操作真實模型／帳號／群組或改變檔案保護。

## 背景純文字完成：不能將未完成的模型串流當成任務成功（2026-10-03）

沿用上節 reference automation 的 existing runner／group orchestration 證據，這輪另外修正 Filicon 的兩個簡化 executor：原程式僅收集 textDelta，在串流結束後就回傳結果，沒有檢查 finish reason，也會忽略未執行的工具事件。`AutomationService` 會將該回傳值記為 ok，workflow 則可能繼續下一步並保存 succeeded，不能把這種收集結果當成完成證據。

`TextOnlyInference` 現在共用於兩條 App 路徑，只接受單一明確 stop 且正常 stream end；明確空白 stop 是允許的 silence，不是 missing completion。未知／缺失 completion、length、重複 stop、所有 tool-call／arguments／result，以及 stop 後的 text／reasoning／response-start 都失敗；cancelled 為 CancellationError。usage 在 stop 前後均可接收，符合既有 OpenAI-compatible parser 的完成後用量事件；不保存 reasoning。每個事件、結尾及 thrown error 路徑重驗 Task／host validation，帳號撤銷仍由上一批 lease 保護。晚到 transport error 不被先前 stop 吞掉；沒有自動 retry 或重跑已開始的推論。

單一回應累計最多 100,000 UTF-8 bytes，以剩餘 bytes 比較防整數相加溢位，Unicode 與跨 chunk 逐筆計算；超限整次失敗而非把截斷草稿當成功。automation 原先無回應累計上限，持久 history 仍只保存既有 300-character 摘要與成功用量。workflow 另保留整個 run 各步合計上限、歷史／定義格式及既有 deadline。這是 collector 的正文上限，不是任意 provider buffer／CPU／永不返回串流的完整資源保證。

隔離 collector 與實際 App workflow／automation 雙入口案例使用固定日期、temp store、受控 validate 與 CustomDump，核對正常／silence、缺失結尾、length／cancelled／unknown／tool-use、各種工具事件、Unicode／跨 chunk 上限、完成後正文、late error、Stop／revocation、未執行下一步、未存 PRIVATE_DRAFT／偽造工具成功及成功 usage。實際 App 雙入口有 26 組 completion 案例；第一輪 NormalizedToolCall fixture 建構缺少 try 的編譯失敗日誌 `background-text-completion-focused.log` 保留。修正後最後聚焦 `background-text-completion-focused-repair.log` exit 0：41 tests／4 suites。

最後完整串行回歸 `background-text-completion-full.log` exit 0：135 XCTest＋1,632 Swift Testing（核心 869／99 suites、App 532／74 suites；兩項 opt-in live Codex 測試略過）。`background-text-completion-native.log` BUILD SUCCEEDED；`background-text-completion-package.log` 四個執行檔、deep／strict 簽章及 app／XPC entitlements 核對通過。七語各 1,724 keys／0 missing。日誌位於 `.build/validation/`，不提交產物；略過的兩項 live 測試不算真實 Codex／外部服務驗收證據。

沒有增加或實際執行工具、傳送已同意事實到背景、修改真實帳號／群組、push 或啟動／重啟使用者 App／Xcode。本批成功只證明 text-only 推論完成，不證明模型所聲稱的網站、登入或外部動作真的完成；原版完整 background session／management／group runner、需新 audience 同意的背景記憶、平台後端及其他分類驗收仍保留，不能上調整體 partial 或宣稱全 48 分類完成。

## 經審核 routine 的既有單獨聊天（2026-10-03）

對照同一 reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `source/host/extensions/transcript/automation-run-path.ts` 109–237 行：一般代理人先解析 background session，再取既有 runner、exclusive run，以 hidden／允許 silence／automationWake 執行。Filicon 現在接上經人類審核的本機既有 bound direct conversation，不將 reference 的遠端 session 或雲端帳號服務當作已還原。

入口為「自動化 → 展開排程 → 背景代理人對話」。人類審閱完整 task、代理人及 provider／model，選擇該 account／agent 已綁定的既有對話，再按「核准代理人對話」。背景 saved facts 另以預設關閉的 toggle 獨立同意；取消不保存。若已綁另一 session 類型須先撤銷；跨帳號 grant 明示須在原帳號撤銷，不誤標為 text-only。

- Host-only `automation-direct-sessions.json` 保留 account／automation owner、不可變定義摘要及 conversation／persona／provider／model／reasoning 摘要。save／revoke 使用 CAS、私有檔案權限及同步 lease commit，routine import／模型定義不能產生 grant。審核後定義、身分或綁定變更會要求重新審核，不 fallback 至普通推論；canonical 與 UI projection 都重驗。一般／群組 grant 的互斥是同一 App admission 保護，不宣稱跨 process transaction。
- manual／scheduled／verified event 由同一 executor callback 接入既有 `startTurn`／`TurnCoordinator`／AgentMessagingSession，工具 context 使用 service 已保存的實際 run UUID。手動沿 user lane、定時／事件沿 background lane，180 秒為合作式期限。只讀指定對話歷史、不讀別的對話；臨時 wake 不寫成 `.user`，歷史附件／remote image metadata 不自動送出或下載。host timeline 保存實際 run、routine 名稱及狀態。
- SendMessage 發表真正對話回覆，普通 assistant 文字保持私有，silence／PASS 仍可完成；host 的 generic run finished 不冒充外部任務完成。問題卡片保存於實際對話，run 收尾後可由人類選項接回新的 supervised turn；未回答的問題／secret、忙碌及同步中的對話不被新 wake 打斷或自動重試。
- 背景記憶關閉時無 recall／SearchMemory／mutation；開啟時僅該已審核 agent 依原私人、共享 user、joined project 邊界使用 saved facts。SendToAgent 仍先取得真實 recipient／payload 核准，peer 不繼承記憶 grant；不自動收集 routine wake 的 suggestions、episodes 或 synthesis。檔案、連線與其他工具保留原本核准，不因排程同意而升權。
- Stop、撤銷／替換、切帳號、routine 改動／停用／刪除、persona／model／binding 變更與聊天刪除撤銷舊執行。推論及 publication 重驗 child lease；最後 `ConversationRepository.upsert` 在 SQLite 同步保存處持有 lease，重驗 canonical binding／provider／model／reasoning，避免 quota await 後的晚到寫回與已刪聊天復活。取消收尾僅可在原 account lease 有效時保存終態。這不是跨 process 訊息版號 CAS、任意 provider 的強制終止，亦不能回滾已完成外部效果。

聚焦四個新增 suites 共 22 tests 通過，包含無 grant 保持 text-only、memory off/on、持久重開／scheduled tick、六類 stale review／busy／pending question、六類過期審核視窗、問題的人類續接、peer 允許／拒絕及私有事實隔離、歷史附件不轉送、silence、provider 不可降級、實際雙層本機寫入核准／拒絕、五類晚到核准取消及兩種 history 完整性／六類最終 canonical write fence。實際 run UUID、primary usage、沒有假真人訊息及私人草稿不發表均有斷言。測試使用隔離 fixtures、fake provider、固定日期、受控 gates 及 CustomDump，不使用真實帳號或模型。

初始語意紅燈及中間定位日誌保留：最初 runner 將 ephemeral wake 誤當成已保存真人圖片來源，沒有圖片的 routine 也在準備 SendToAgent 時取消，已將兩個 image source 設為 nil。測試中另修正 selected conversation、核准 target 欄位、拒絕工具但 owner 正常完成的結果分類，以及歷史附件 fixture 的 canonical／projection 一致性；不把這些 fixture 修正寫成新的 production 保證。曾中止僅由本輪啟動的兩個測試 process，未停止使用者 App 或 Xcode。

`routine-direct-session-focused-final.log` exit 0（核心 5／2 suites、App 17／2 suites）；第一輪完整 `routine-direct-session-full-final.log` 亦 exit 0，但最後語意核對才發現既有日文 Conversation 誤譯為 conversion、韓文誤譯為 field of research。已修正並加入正確語意斷言，重新渲染及檢視兩語畫面。最後 `routine-direct-session-full-post-translation.log` exit 0：135 XCTest＋1,682 Swift Testing（210 suites，核心 887／103、App 563／78；兩項 opt-in live Codex 測試略過）。略過的測試不算真實模型驗收。

最後 `routine-direct-session-native-post-translation.log` BUILD SUCCEEDED，`routine-direct-session-package-post-translation.log` 四個執行檔、deep／strict 簽章及 app／XPC entitlements 通過，七語各 1,754 keys／0 missing。14 個七語明暗核准畫面 render 通過，並逐語檢查長說明、選項與按鈕換行。日誌及 PNG 位於 `.build/validation/`，不提交產物；未更改 xcode-select、未啟動／重啟使用者 App／Xcode、未 push、未更動真實帳號／群組／聊天。

剩餘邊界：primary 成功回應 input／output tokens 已記錄，但 peer／全群組／價格／預算並未完整彙總；不把 unknown 算成零成本。workflow shared runner／action、原版雲端 background session／group metadata、外部平台、release／公證／最低 macOS、live provider 及全 48 分類獨立驗收仍保留，AGENT-01／02／04、AUTO-03 整體不改為 complete。

續核對的 workflow 入口：reference `workflow-commands.ts` 的 `runAgentWorkflowNow` 在 `workflowToAutomation` 有排程 projection 時呼叫 `fireAutomation`，否則呼叫 `sendPrompt` 並附上 workflow rich-text reference；`expandWorkflowReferences` 將有界 recipe 交給同一對話 runner。Filicon `AppWorkflowPromptExecutor` 仍是獨立 text-only，`AppWorkflowNoAuthorityActionHandler` 全拒絕。下一批須處理這個實際執行差異及明確人類授權；Filicon 自身的多步驟／action enum 不是所核對原版同名模型的證據，不自行建立未經核對的廣泛 action 權限。

## 經審核 routine 的既有群組 session（2026-10-03）

reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `source/host/extensions/transcript/automation-run-path.ts` 68–105 行會將 group automation seed 寫入群組 session，再交給 background／automation `GroupChatOrchestrator`；109–239 行另保留一般代理人的 existing runner、exclusive run、真正 run ID 及 event wake。Filicon 本批接上經人類審核的本機既有群組分支，不聲稱 reconstructed production 的外部後端或背景記憶已實際驗收。

入口是「自動化 → 展開排程 → 背景群組會話」，選擇包含該排程擁有者的既有群組後，審閱完整排程本文、目標群組、成員及群組目標，再按「核准群組會話」。可從同一處開啟群組或撤銷綁定。背景已保存記憶預設關閉，須在這個視窗另行同意；取消不保存 grant。七語文案、明暗外觀與長說明換行均有隔離 render。

- `AutomationRunExecutor` 接收 service 已保存的 running record，而非隨機另建 run ID；手動／定時／事件使用相同 dispatch。host-only `automation-group-sessions.json` 不屬於 routine import／`update_state` schema。grant 精確綁 account、routine owner／definition digest／revision、group name／goal／member IDs，CAS 寫入、私有檔案權限及最終 lease commit 保護保存。變更後必須重新審核；存在但失效的 grant 拒絕執行，不默默退回另一模型呼叫。不存在 grant 的 routine 保持有界、嚴格完成的 text-only 路徑。
- seed 具有實際 automation／run ID、host name 及外部事件標記，寫入真正群組紀錄並顯示排程標記。事件本文與 `@` mention 是不可信任務資料，不能縮小／擴大已審核的整群 audience，也不是檔案、瀏覽器、連線或動作權限。
- 透過既有 `GroupConversationResponder`／`TurnCoordinator`，使用各成員的目前 persona／模型、SendMessage／SendToAgent／管理工具、真正 publication、PASS 及 tool receipts；每位成員各自取得共用 scheduler lane，不在持有擁有者 lane 時再等待自己的 lane。手動使用 user lane，定時／事件使用 background lane 與既有 180 秒合作式期限。
- 背景記憶同意獨立且限已審核成員；原本 account、私人 owner、共享事實及 joined-project 限制仍有效。關閉時不 recall、不暴露 SearchMemory，偽造 memory mutation 仍拒絕。群組外委派不能繼承該 memory grant。routine seed 不自動收集 suggestions／episodes／synthesis；這不是允許發布無關私人事實，也不擴充 provider／file／browser 授權。
- 忙碌、停止中或正在等待人類回答問題的群組拒絕新的 wake，不打斷現有工作、不自動重試。問題保留在實際群組，正常人類選擇可續接原發問者；回傳的 generic run finished 摘要不宣稱整個外部任務完成。
- Stop、撤銷／替換 grant、切帳號、人工修改／停用／刪除 routine 同步撤銷舊 run scope；已核准模型修改在定義真正保存後撤銷。推論開始、每個 event、委派 publication 與收尾均重驗。排隊的取消清理只作用於原 run lease，不可停止同群組較新的人工工作。晚到核准不得產生檔案；已完成的外部效果不能回滾。

聚焦隔離測試 `RoutineGroupSessionTests`、`RoutineGroupSessionRenderTests`、`AutomationGroupBindingTests`、`AutomationRunContextTests` 與既有 group approval／background execution 回歸通過，含工程師／設計師共同發話、memory off/on／peer 隔離、持久重開、三條 dispatch、事件 mention、過期定義／目標／成員／帳號、實際雙層本機寫入核准、拒絕、五種晚到核准取消、問題續接與忙碌排斥。初始 `routine-group-session-red.log` 保留 13 個語意失敗斷言；曾實際重現舊 executor 走 plain、缺少群組 seed 及 stale grant 仍成功。第一輪原生建置 `routine-group-session-native.log` 發現新 SwiftUI source 未加入 Xcode 清單，已補 `project.pbxproj`，保留失敗日誌，不以 SwiftPM 綠燈取代原生建置。

最後檢查另補上群組紀錄讀取返回後的 account generation 重驗：seed UI 投影有同步 lease commit，取消後的 canonical tool statuses 只在原帳號／原 run 身分仍相符時更新，舊讀取不可覆蓋新帳號畫面。第一輪完整回歸 `routine-group-session-full.log` exit 0：135 XCTest＋1,660 Swift Testing（核心 882／101 suites、App 546／76 suites），但發生於此最後修正之前，不作最終 gate。修正後 `routine-group-session-native-final.log` BUILD SUCCEEDED，`routine-group-session-package-final.log` 四個執行檔、deep／strict 簽章及 app／XPC entitlements 通過。七語各 1,740 keys／0 missing；14 個明暗 render 及逐語視覺檢查完成。日誌／PNG 位於 `.build/validation/`，不提交產物；Xcode 請開啟 `Filicon.xcworkspace` 並使用 `Filicon App` scheme。

最後完整串行 gate `routine-group-session-full-final.log` exit 0：135 XCTest＋1,660 Swift Testing（206 suites，核心 882／101、App 546／76）；兩項 opt-in live Codex 測試略過，不算真實模型驗收。先前聚焦 `routine-group-session-focused.log` 共 53 tests／6 suites 通過；最後 UI 投影修正另由完整 gate 覆蓋。未移除系統保護，未更改 xcode-select，未啟動使用者 App／Xcode。

當批剩餘邊界：只綁本機既有群組，當時尚缺的一般 solo agent 本機既有對話分支由上方專節補上；workflow shared runner／action handlers 及原版 cloud group 成員 metadata 仍未完整還原。群組 token／cost 尚未彙整至 automation history；未知維持 nil，不當作零費用，核准畫面明示沒有價格或全群組預算保證。fixture 的本機寫入使用真實 permission receipt／host 執行，但不是 packaged XPC／live provider／真實外部帳號驗收；release、公證、最低 macOS、平台後端及其餘分類仍保留。未 push、未啟動／重啟使用者 App／Xcode、未更動真實帳號／群組／聊天。

## 共用 runner 完成：未完成的工具回應不得觸發 host 效果（2026-10-03）

本輪持續核對 reference `a9f633e09d49a85829b8236331b9e21f7e612634` 的 `automation-run-path.ts`：真正 background session 走相同 session 的 exclusive run，並區分一般 runner 與 group orchestrator。接線前，新隔離測試重現 Filicon 已使用的 ToolLoop／TurnCoordinator 漏洞；這不是 reference 已執行通過的聲明，也不能以修正該漏洞替代完整背景執行器。

- 新增內部 `InferenceResponseCompletion`，只判定一個 provider response，不誤把 multi-step ToolLoop 的每個 toolUse 當成整個 turn 的 final stop。普通批次每一步要求一次明確完成，toolUse 對應非空、完整且有效的呼叫；最終無呼叫只能 stop。缺少完成、length、unknown、cancelled、矛盾 stop、重複完成、完成後正文／推理／start／工具及 provider 偽造 result 均拒絕。取消維持 CancellationError，length 維持 truncated；完成後 usage 仍允許。
- 普通批次等串流正常 EOF、再次檢查 Task 及完成狀態後，才解析 executor／schema、開始效果及交易記錄。late transport error 不因先收到 toolUse 被吞掉。既有 pending argument 型別錯誤、八步限制、parallel-safe／順序批次、問題 suspension、事件 acknowledgement 與 lane cleanup 保留。三個舊 multi-call fixture 原先每個呼叫都附 completion，已修正為每批一次，不放寬 runtime 來配合錯誤 fixture。
- 互動 provider 的工具仍只透過 host callback 執行／持久化／回傳。外層只接受明確 stop，並在傳送 stop 給 consumer 前關閉新 callback；還有 active callback 時不報成功，收尾仍等待已接受呼叫。provider 的工具事件不能偽造執行。這不回滾 stop 前已完成的工具，也不宣稱能強制中斷不合作的 executor、任意 buffer 或永不返回的串流。
- plain TurnCoordinator 與 TextOnlyInference 使用相同完成判定，plain 路徑不得靠 EOF 或工具宣稱成功；text-only 的 100,000 UTF-8 bytes、usage／reasoning 與 host lease 檢查維持原義。沒有新增權限或默認背景工具。
- Gemini 原先只要 hadTools 就把任何完成理由改成 toolUse，新 HTTP fixture 確認 length／unknown／cancelled 都會錯誤執行一次。現在只把有效 stop＋工具轉為 toolUse，其他完成原因保留。測試使用 URLProtocol 封閉的假回應與 fixture key，不呼叫 Gemini 帳號或網路。

依測試技能使用固定 conversation ID、受控 gate、假 provider／executor／transaction hook 與 CustomDump。`shared-runner-completion-red.log` 為新 6 項測試函式、49 初始案例的 56 個失敗斷言；另 `shared-runner-gemini-red.log` 為 2 項函式／7 案例的 9 個失敗斷言，包含 host effect 實際被執行的探針。修正後 runner completion 有 58 案例，Gemini 7 案例；實際 App 群組／mailbox／現有 background 入口、排程、Stop／切帳號、核准、provider contract、工具順序與舊批次回歸共 124 tests／9 suites 在 `shared-runner-completion-focused-final.log` 通過。早期普通 `xcodebuild` 因系統選用 CommandLineTools 無法啟動；指定完整 Xcode 的 `shared-runner-completion-native-final.log` BUILD SUCCEEDED，未變更 xcode-select 或使用者 Xcode 狀態。`shared-runner-completion-package.log` 四個執行檔、deep／strict 簽章與 app／XPC entitlements 通過，七語各 1,724 keys／0 missing。

最後完整串行回歸 `shared-runner-completion-full.log` exit 0：135 XCTest＋1,640 Swift Testing（核心 877／100 suites、App 532／74 suites；兩項 opt-in live Codex 測試略過）。略過測試不算真實 Codex／外部服務驗收。日誌在 `.build/validation/`，不提交產物。本批未 push、未啟動／重啟使用者 App／Xcode、未修改真實帳號／群組／連線、未延伸 direct／group／mailbox 的記憶 consent。真正 automation／workflow background session、management／group runner、獨立工具與記憶授權及外部平台／其他分類驗收仍保留。
