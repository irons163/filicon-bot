# 協作能力核對紀錄（更新至 2026-09-22）

## 本輪增量：受核准的 Teams 排程定義提案（2026-09-22）

先提交上一批為 `a217e93`（`feat: add approved project-scoped shared memory`），提交前 **23 Swift Testing／3 suites 通過**（`/tmp/filicon-project-memory-precommit.log`）。本輪核對本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts`：Microsoft Teams trigger 支援 tenantId、teamId／teamIds、channelIds 與文字／政策欄位。原生入口沒有可信應用程式使用者身分，故只補受限的模型定義路由，不宣稱 Teams 雲端 runtime 已完成。

- 群組／mailbox 的自身 routine create/update 可用 `type:microsoftTeams`，單一條件、平面 group 或 bare array，與既有時間／平台條件共用最多八個 OR 分支。tenantId 須為 UUID；teamId 與 teamIds 合併，去重前合計 1–50 筆；channelIds 最多 50，空清單表示所選團隊內不限頻道。每 ID 最多 200 UTF-8 bytes，不接受空白、控制字元、逗號或萬用字元。不解析名稱、不猜測 ID。Graph team UUID 正規化，opaque Bot／channel ID 保留大小寫。
- messageContains 必填 1–120 字元 literal，不接受控制字元；messageContainsIsRegex 僅 false，blockUnauthenticatedTeamsUsers 僅 true，省略使用上述安全預設。null、錯誤型別、未知欄位與任一無效分支使整個提案失敗，不丟棄篩選。teamId/teamIds aliases、重排與重複項目具有相同 canonical replay receipt；原始清單上限不因去重而繞過。
- 完整新舊定義與啟用狀態需獨立核准，host 固定身分。保存時再次驗證 Teams 條件及舊定義；regex／放寬登入／空篩選等舊格式不得由模型轉換。沿用 owner／revision／lifetime、Stop／帳號切換／封存、費用保護、四次共用額度、原子保存／失敗回滾／durable receipt，保留執行歷史與進行中的任務。
- **只保存定義，不啟用 Teams 事件執行。** blockUnauthenticatedUsers=true 保持不變，HMAC 或 payload 的 authenticated=true 仍不能代替可信登入身分。其他 OR 分支及使用者明確 Run Now 仍可執行並產生模型費用；沒有新連線、登入、webhook、工具權限、Graph subscription 或主文判定。核准卡頂端與工具回覆／runtime／schema 明示限制，七語言同步新增提示與錯誤。

依 Swift 測試／CustomDump 技能使用固定時間、隔離 store、受控 continuation、完整值比較與 fixture provider；依 SwiftUI 技能沿用既有核准明細，將重要限制置頂，不自造 binding。新增五項核心測試函式與一項雙外觀渲染測試；擴充既有 create/update 的核准、拒絕、Stop／延遲 commit、帳號、封存、stale、保存失敗、容量／receipt／身分測試，包含 group 與 mailbox。首次編譯修正 let 字串組合與測試 optional description；首次實際聚焦有兩項舊 schema 數量斷言失敗（6 issues），更新為包含 Teams 的精確型別集合與數量，不弱化驗證（`/tmp/filicon-teams-model-focused3.log`）。

聚焦回歸 **81 Swift Testing／4 suites 通過**（`/tmp/filicon-teams-model-focused-final.log`）。產生 **28 張 Teams 核准明細**：單一 create/update × 七語言（380 點寬），以及 Teams＋cron 混合 update × 七語言 × 明暗（440 點寬）；並重新產生既有各平台預覽（`/tmp/filicon-teams-model-previews/`）。逐語檢視至少一張，另檢視繁中／法／西／日／韓深色卡，未見文字裁切。修正既有 Enabled 西文殘留英文、韓文誤譯與日文動作式用詞後，重新渲染並通過兩項預覽測試（`/tmp/filicon-teams-model-preview-final.log`）。只驗證核准明細，不是全產品逐頁或 live 模型驗收；fixture 名稱／任務仍是使用者內容。

最終完整 `swift test --no-parallel` **135 XCTest、1,007 Swift Testing／112 suites 全數通過**（`/tmp/filicon-teams-model-full-final.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。七語言各 **1,624 keys、零缺漏**，`git diff --check` 通過。

原生增量 build 成功，但最後三語言資源更新未重新執行 CodeSign，嚴格驗簽發現 ja／es／ko 與舊 seal 不一致（`/tmp/filicon-teams-model-native-verified.log`）。改用全新隔離 DerivedData `/tmp/filicon-teams-model-native.vOK7XS` 完整建置，**原生 Debug build 與 deep strict codesign 通過**，包含 helpers／XPC（`/tmp/filicon-teams-model-native-clean.log`）。沒有手動補簽、修改使用者 Xcode 產物或宣稱增量簽章問題已根治。既有 optional-to-Any、weak capture、AppIntents metadata／ad-hoc runtime 提示仍在；不是 release 簽署／公證驗收。

本批新修改尚未提交；未 push、未啟動／重啟使用者 App／Xcode、未操作真實聊天／群組／排程／外部帳號或憑證。`AGENT-01`／`AUTO-03` 維持 partial，整體仍 **43 complete／4 partial／1 NA**。

## 已提交增量：受核准的專案共享記憶（2026-09-22）

先提交上一批為 `391a9ff`（`feat: approve account-scoped collaboration project membership`），提交前專案核心／App 聚焦 **14 Swift Testing／2 suites 通過**（`/tmp/filicon-project-precommit.log`）。本輪核對本機非官方 reconstructed 的 `source/host/extensions/memory/agent-state.ts` 與 `source/host/runner/tools/sand-state-tool.ts`：project memory 要求專案存在及自身成員資格，記錄以 writer 區分。本輪接上受限制的原生對應，不以此宣稱完整原版 runtime。

- 群組／mailbox 的 `update_state(target:"memory",action:"write"|"forget",scope:"project",project:"exact-slug",fact:...)` 必須已有 active 成員資格。host 固定帳號與代理人，模型只能忘記自己記錄的精確事實；scope／slug／其他欄位混用拒絕。寫入與忘記皆獨立明確核准，不沿用 auto-review allow；卡片展示全文、作者、專案與成員數量。
- 事實只供同帳號此專案的目前／未來成員及其配置模型於群組／mailbox 回合召回，包含此聊天以外的成員。離開不刪事實、停止後續讀取；重新加入恢復存取，已傳送訊息及 in-flight context 不會撤回。加入／離開核准與工具回覆已同步揭露此影響；私人記憶不自動轉為共享，檔案／工具權限不變。
- `AgentService` 提案捕捉完整專案快照／revision；提交再次驗證，leave/rejoin ABA、其他成員變更、owner 封存、Stop／帳號切換使未提交變更失效。沿用原子保存／失敗回滾／成功 receipt，以及四次修改共用額度和 tool-call 重播防護。容量為每專案跨 writer 共用 48 筆／8 筆基礎事實／12,000 字元，每筆 1,000 字元，與 reference 每 writer shard 容量並非完全相同。
- 自動召回沿用有界關鍵字與排序；專案額外的總預算為所有已加入專案合計 8 筆／4,000 JSON bytes 基礎事實、15 筆／2,000 bytes 近期事實，不乘以專案數。不同專案相同文字不互相去重，省略不刪除。
- `SearchMemory` 加入 `scope:project`，可選精確 `project`；all 亦包含已加入專案。先以同一 actor 快照過濾帳號／成員身分，再搜尋／分頁；相關成員 revision 也綁定 cursor，離開再加入仍不得續用舊游標。保留每頁八筆／8 KiB JSON、32 次讀取額度、來源與 canForget。純資料投影 API 未提供 joined 集合時預設拒絕所有 project records，連作者本人亦同。
- 人類編輯器 **代理人 → 編輯 → 專案記憶** 列出本帳號全部專案事實，標示專案與作者，可刪除已離開／封存作者的記錄；此全帳號查閱／刪除入口不暴露給模型。舊無 scope 記憶仍為私人；project 欄位與 scope 不一致、缺失或路徑式 slug 的儲存資料解碼保守失敗，不默默擴大可見範圍。

依 Swift 測試／CustomDump 技能使用隔離 store、固定時間、完整值比較與 fixture provider；依 SwiftUI 技能重用既有核准卡與記憶列表，不新增自訂 binding。新增九項核心與三項 App 測試函式（包含六組核准結果），涵蓋寫入／忘記、私有與跨帳號隔離、非成員、ABA／封存／保存失敗、共用容量／重播／四次額度、搜尋游標、mailbox recipient 身分及人類刪除。開發中的既有 invalid-scope 測試改驗專案欄位錯誤／預設拒絕；App 首次聚焦因 Date 次毫秒往返差異有一項失敗，改以完整毫秒 Codable 值比較後通過，未忽略時間欄位或放寬產品驗證。

最終聚焦 **23 Swift Testing／3 suites 通過**（`/tmp/filicon-project-memory-focused-final.log`）。產生 **28 張專案記憶核准明細**（寫入／忘記 × 七語言 × 明暗）及重新產生 **42 張專案成員核准明細**（`/tmp/filicon-project-memory-previews/`）；逐語檢視共享記憶淺色卡，另檢視繁中／法文深色忘記卡和英文加入／繁中離開卡，380 點寬未見文字裁切。英文 fixture 姓名／事實保留為使用者內容。只驗證明細元件，非全產品逐頁或 live 模型驗收。

最終完整 `swift test --no-parallel` **135 XCTest、1,001 Swift Testing／112 suites 全數通過**（`/tmp/filicon-project-memory-full-final.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。原生 `Filicon App` Debug build（`/tmp/filicon-project-memory-native.log`）及產物 deep strict codesign 通過，含 helpers／XPC，不是 release 公證驗收。七語言各 **1,619 keys、零缺漏**，`git diff --check` 通過。未 push、未啟動／重啟使用者 App／Xcode、未操作真實聊天／群組／專案／外部帳號或憑證。本批已於下一輪提交為 `a217e93`。仍缺自動記憶抽取／任意 archive、其他執行入口與完整 persona/runtime；`AGENT-01` 維持 partial，整體 **43 complete／4 partial／1 NA**。

## 已提交增量：受核准的協作專案成員資格（2026-09-21）

先提交上一批為 `6eaf146`（`feat: add validated manual Teams routine editing`），提交前 Teams 編輯／事件／App 聚焦 **91 Swift Testing／5 suites 通過**（`/tmp/filicon-teams-editor-precommit.log`）。此輪核對本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts` 與 `source/host/extensions/memory/agent-state.ts`：create 是建立後加入、已存在時只加入不覆蓋 metadata，join 須存在，leave 不刪除 project；project memory 為另一條需成員身分的路由。本批只補前者，不宣稱還原完整共享專案記憶。

- 群組／mailbox 使用 `update_state(target:"project",action:"create"|"join"|"leave",project:slug)`。host 固定自身代理人及帳號；create 另需名稱、可選說明，join／leave 不接受其他欄位。JSON 上限 8 KiB；slug 為最多 64 UTF-8 bytes 的小寫 ASCII 字母／數字與單一連字號，拒絕路徑。名稱最多 200、說明最多 1,000 UTF-8 bytes，拒絕控制字元後才去除首尾空白。
- 帳號內最多 50 個專案，含空專案；已加入／已離開回傳 no-op error，不當成新變更。create existing 保留全部舊 metadata，離開只移除自己、保留其餘成員及專案。獨立明確核准不可沿用 auto-review allow；七語言卡片完整顯示 metadata、加入／離開前後與成員數量，提醒名稱／說明為同帳號目前及未來代理人及其模型共享資料。
- 模型目錄只注入該帳號的 slug／name／自身 joined，不包含 peer 名單、description 或私人事實，並標記為不受信任資料。project 不是群組、檔案授權或工作指派；不新增聊天／wake／任務／資料夾、不改私人 persona 或記憶。`scope:project` 記憶仍拒絕。
- 提案由 AgentService 快照產生，提交時重驗完整舊值及持久化 revision，涵蓋 leave/rejoin ABA、並行建立與容量競爭；同步 lifetime fence 擋下 Stop／取消／帳號切換後未提交的變更，也重驗 owner 是否封存。沿用原子保存與完整回滾；保存成功才記 receipt，後續 bookkeeping 失敗不誤報未執行。重播同 call 返回結果、pending 重複拒絕，與既有狀態修改共用四次額度。不是跨程序直接改檔的 CAS。
- `agents.json` 加入可省略的 projects，舊檔缺鍵時為空清單；不遷移聊天／私人記憶／資料夾。沒有專案 rename/delete、專用手動管理 UI、reference project.md 或 project memory。AgentService 原有 agents 為本機 roster，本批 project records 才有明確 account scope。

依 Swift 測試／CustomDump 技能使用隔離 store、固定時間、完整值比較及受控 continuation gate；依 SwiftUI 技能重用群組／mailbox 核准卡，不引入新的自訂 binding。新增十項核心測試與四項 App 測試函式（含拒絕／Stop／帳號／封存／保存失敗等參數），檢查身分隔離、嚴格欄位與 UTF-8 上限、create-is-join、持久化／舊格式、私人記憶保留、stale／ABA、容量、延遲 commit、receipt、共用額度及 mailbox recipient。開發中修正 fixture 的 ToolCallID 建構與 App 私有存取編譯錯誤，沒有開放產品私有 service 供測試使用。

最後檢查發現 quota ledger 為 App-wide，僅以 slug 當用量 key 會讓不同帳號同名專案互相覆蓋計數。本輪改用有界 account 編碼＋slug 複合 key，不改檔案路徑；補上不同帳號／分隔字元／最大長度及真實 App 核准保存後的 ledger 檢查。兩項聚焦測試（含六組保存結果）通過（`/tmp/filicon-project-quota.log`），原生 build 與 deep strict 簽章重新通過，再重跑全套驗證。

初次聚焦 **12 Swift Testing／2 suites 通過**（`/tmp/filicon-project-focused3.log`），其後補上舊檔／私人記憶回歸。首次完整回歸在舊 profile 測試有 **1 issue**（`/tmp/filicon-project-full.log`）：原測試把 project 視為未知 route、預期 profile.invalidFields；新增 project validator 後回傳 project.invalid。將該非法 profile 欄位案例獨立檢查精確錯誤，保留未知 route 拒絕測試，未放寬產品驗證。

核准明細產生 **42 張預覽**（create／join／leave × 七語言 × 明暗，380 點寬；`/tmp/filicon-project-previews/`），每種語言至少檢視一張；英文 fixture 的姓名／名稱／說明保留為使用者資料，不自行翻譯。修正建立預覽的成員數量為 0→1 後重新產生全部預覽，另檢視繁中／法／韓建立卡。只驗證此核准明細，非全產品 UI 或真實模型驗收。

最終完整 `swift test --no-parallel` **135 XCTest、989 Swift Testing／111 suites 全數通過**（`/tmp/filicon-project-full-verified.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。原生 `Filicon App` Debug 增量 build（`/tmp/filicon-project-native-final.log`）及產物 deep strict codesign 通過，含 helpers／XPC；不是 release 簽署／公證驗收。最終預覽測試另外通過（`/tmp/filicon-project-previews-final.log`）。七語言各 **1,607 keys、零缺漏**，`git diff --check` 通過。未 push、未啟動／重啟使用者 App／Xcode、未改實際聊天／群組／專案／排程／連線／憑證。本批已於下一輪提交為 `391a9ff`。`AGENT-01` 仍為 partial；整體維持 **43 complete／4 partial／1 NA**。

## 已提交增量：受限制的 Teams 手動條件編輯（2026-09-21）

先提交上一批為 `4a434f2`（`feat: approve disconnection of agent-owned channels`），提交前頻道／管理聚焦 64 項再次通過。此輪核對本機非官方 reconstructed 的 `sand-state-tool.ts` Microsoft Teams schema、`automation-trigger.ts` scope／filter 判定，以及 Filicon 既有原生 Teams 安全邊界；不以表單完成宣稱原版 Teams 雲端能力已還原。

- Teams 新增／既有條件編輯共用嚴格驗證：一個 tenant UUID、1–50 個 Graph UUID 或精確 Bot team ID、可留空的最多 50 個 channel ID。清單在去重前計數，空逗號項、`*`、ID 中空白／控制字元／逗號及超過 200 UTF-8 bytes 直接拒絕，不靜默丟棄。修改時只正規化 UUID；opaque ID 保留大小寫，不查名稱、不安裝連線。
- 必填 literal substring 篩選，最多 120 字元、拒絕控制字元，不把 regex 語法當成 regex 執行。原生 substring 比對仍不分大小寫且包含回覆；沒有新增主文判定。舊 regex／blockUnauthenticatedUsers=false／空篩選／無效 scope 維持 metadata-only，含其 OR 群組；完整原始 trigger 保留。未改動的 OR 分支也維持原值。
- 新增與可編輯的 Teams 條件固定保留 blockUnauthenticatedUsers=true，原生入口缺乏可信登入身分，因此 Teams 分支仍不執行；畫面新增醒目狀態並保留詳細說明。其他 OR 分支及 Run Now 不變。後端 manual-save 再驗證相同邊界，不能繞過表單放寬政策；模型 Teams create/update（單一／OR、政策兩方向）仍拒絕。
- 沿用原子手動保存、revision／lifetime／account／owner 封存及儲存失敗保護；保留 enabled、費用防護、history 與未變動的時間基準。不操作真實資料或服務。

依 Swift 測試／CustomDump 技能先重現兩項紅測試（不可編輯、空逗號被丟棄；2 tests／4 issues），以隔離 store／App fixture、固定時間檢查完整值。依 SwiftUI 技能沿用直接 state binding，Teams 欄位改為可換行、靠左的文字輸入，標籤／狀態／錯誤／限制說明補齊七語言。擴充測試時修正 async autoclosure 編譯用法；重開比較改用完整毫秒 Codable 表示，避免把 Date 次毫秒往返差異當產品錯誤，未忽略時間欄位。

驗證：聚焦 **91 Swift Testing／5 suites 通過**（`/tmp/filicon-teams-editor-verified.log`）。Teams 新增九項測試函式（含六種 App 保存結果參數）及一項模型路由拒絕測試；涵蓋 ID 原始清單／空項／UTF-8 上限、UUID 與 opaque 大小寫、文字上限／控制字元、正規表示式不轉譯、政策不放寬、舊條件不遷移、OR 分支保留、時間基準／history／持久化、表單繞過、取消／帳號／封存／stale／保存失敗、群組模型提案仍拒絕。

產生 **56 張 Teams 專用預覽**（欄位有效／無效、完整 sheet 可編輯／唯讀 × 七語言 × 明暗；`/tmp/filicon-teams-editor-previews/teams-fields-*` 及 `teams-sheet-*`），每種語言至少檢視一張。檢視後修正沿用的韓文標籤中的英文殘留、以及 macOS Form 對輸入欄的右側配置，重新渲染確認韓文與日文完整 sheet；長清單可軟換行。sheet 內容可捲動，並非全產品逐頁或真實 Teams 帳號驗收。

最後完整 `swift test --no-parallel` **135 XCTest、975 Swift Testing／110 suites 全數通過**（`/tmp/filicon-teams-editor-full-final.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。原生 `Filicon App` Debug 增量 build（`/tmp/filicon-teams-editor-native-verified.log`）及 deep strict codesign 通過，含 helpers／XPC；七語言各 **1,594 keys、零缺漏**，`git diff --check` 通過。未 push、未啟動／重啟使用者 App／Xcode、未改真實聊天／群組／排程／連線／憑證。本批已於下一輪提交為 `6eaf146`。

`AUTO-03` 仍為 partial：Teams 可信登入／主文／Graph／同步回覆／regex 與模型提案、GitHub checks 彙整、Slack 名稱／人類身分及 live 帳號驗收尚有缺口。整體維持 **43 complete／4 partial／1 NA**。

## 已提交增量：受核准的自身頻道斷線（2026-09-21）

開始時工作區乾淨，上批已提交為 `65a9352`（`fix: preserve channel state across failed writes and stale callbacks`），未重複建立空提交。Xcode 更新後 Swift 6.4 已可執行；使用新的隔離 scratch／DerivedData，先補跑上批最終驗證：**135 XCTest、953 Swift Testing／108 suites 全部通過**（`/tmp/filicon-swift64-channel-baseline.log`），原生 Debug build 與 deep strict codesign 通過（`/tmp/filicon-swift64-native.log`）。兩項 opt-in live Codex 測試未啟用；保留既有 CoreData XPC 診斷。沒有代為接受條款、變更全機 xcode-select 或啟動／重啟使用者 App。

再次核對本機非官方 reconstructed `sand-state-tool.ts` 的 channel.disconnect 路由與 `agent-state.ts` 的 disconnectChannel。Filicon 的連線庫可同平台多連線，不能照搬按平台直接刪除：

- 群組／mailbox 的 `update_state(target:"channel",action:"disconnect",platform:"slack"|"discord")` 僅接受這三個字串欄位及 4,096-byte 上限。host 固定代理人身分，只選該代理人在該平台的單一連線，停用連線也可移除；peer、未指定 owner 的 receive-only 連線不可選。多條自身連線即拒絕，要求使用者到「頻道」精確選擇，不猜測、不批次移除。沒有新增其他平台、連線建立或遠端撤權。
- 每次必須經獨立 destructive 核准，不沿用 auto-review 的工具 allow 規則。卡片顯示代理人、平台、連線名稱／ID、帳號／頻道標籤、啟用狀態，以及接收、傳送、待傳送／傳送中、失敗紀錄數量。模型結果不回傳憑證、帳號標籤、訊息內容或 peer 資料。
- 確認後刪除選中連線的本機 connection／inbound／delivery／failure wake 並停止 listener；沒有 undo。聊天紀錄、附件檔案、其他連線及 routine 保留。已接受回呼或已開始送出仍可能完成，不召回遠端訊息，也不撤銷遠端 OAuth。**鑰匙圈憑證保留**，避免刪除可能共用的 reference；核准與結果均明示，不冒充已完成遠端登出或憑證清理。
- proposal 只能由 ChannelService 的真實快照產生，process-local store revision 覆蓋全庫成功寫入，包括入站／佇列變動及相同值 ABA；資料改變即要求重新核准。不是跨程序直接改檔的 CAS，也不保證活躍高流量頻道能使用舊核准。Stop／帳號切換／取消透過同步 lifetime fence 撤銷尚未保存的提案，批准後重新檢查 owner 是否封存。持久化失敗完整回滾；只有保存成功才記 receipt，後續 UI 刷新失敗不把已完成刪除說成沒做。
- 共享既有四次修改額度，包含已保留的 pending request；重播同 call 返回原成功結果，不重複刪除；同 call 換參數、同義重複 pending／成功請求拒絕，拒絕後可重新提案。原生 AppServices 加入既有 FiliconChannels target 依賴，沒有新增套件。

依 Swift 測試／CustomDump 技能使用隔離 store、固定時間、受控 gate 與完整值差異；SwiftUI 技能用共用群組／mailbox 核准卡、不引入自訂 binding。新增 9 項核心／session 測試函式及 3 項 App 測試函式（含多組參數）；涵蓋 Slack／Discord、owner／receive-only 隔離、歧義、取消／封存／帳號／Stop、配置與資料 ABA、保存失敗回滾、延遲 commit、重播與並行重複、四次額度、durable receipt、mailbox recipient。首次測試有新 fixture 的 throws／protocol 欄位編譯問題，以及誤把已進 dead-letter 的項目算 pending；修正 fixture 為同時保留失敗紀錄與另一筆待傳送，沒有改產品狀態判定來配合測試。

聚焦 **64 Swift Testing／4 suites 通過**（`/tmp/filicon-channel-approval-focused-final.log`）。七語言卡片產生 14 張 380 點寬的明暗預覽（`/tmp/filicon-channel-approval-previews/`），逐語言檢視後修正沿用的西班牙文／韓文 enabled 標籤，改用專屬已啟用／停用鍵，並重新檢視修正後的西／韓深色預覽。不是全產品逐頁或真實 Slack／Discord 帳號驗收。

最終 **135 XCTest、965 Swift Testing／109 suites 全數通過**（明確 `--no-parallel`，`/tmp/filicon-channel-approval-full.log`）。兩項 opt-in live Codex 測試未啟用，既有 CoreData NSXPC 診斷仍在；未弱化檔案保護或跳過失敗案例。原生 `Filicon App` Debug 增量 build（`/tmp/filicon-channel-approval-native-final.log`）與產物 deep strict codesign 通過，含 helpers／XPC；本輪開始時已以新的 DerivedData 完成基準建置。七語言各 **1,586 keys、零缺漏**，`git diff --check` 通過。未 push、未啟動／重啟使用者 App／Xcode、未改實際聊天／群組／頻道／憑證；這不是正式 release 簽署或公證驗收。

工具鏈說明：CustomDump 保持 1.7.3／同 revision；Swift 6.4 改選其主要 manifest，傳遞依賴為 `swift-issue-reporting 2.1.0`，舊 Swift 6.1 manifest 則使用 `xctest-dynamic-overlay 1.13.1`。兩個 resolver lockfile 已同步反映工具鏈選擇，未將測試套件加入 App 執行期依賴，也不宣稱驗證了所有舊版 Swift。`AGENT-01` 維持 partial，整體仍 **43 complete／4 partial／1 NA**。

## 已提交增量：頻道斷線與非同步資料一致性（2026-09-21）

先提交通知設定為 `49ea201`（`feat: approve per-agent update notification settings`），提交範圍沿用上輪已驗證結果，`git diff --check` 通過。本輪核對本機非官方 reconstructed `source/host/extensions/memory/agent-state.ts` 的 disconnectChannel 與 `sand-state-tool.ts` 的 channel/disconnect，發現 native 手動斷線流程已有必須先修的競爭與寫檔失敗問題；本批是安全前提，**沒有新增模型斷線路由或核准 UI**。

- `ChannelService.persist` 維持上次成功保存的完整狀態。connection、inbound、delivery、failure wake 任一保存失敗均回滾，避免稍後無關操作將失敗變更一起寫入。remove／disable 成功持久化後才取消 listener；失敗不使仍存在的連線悄悄停止接收。
- refreshProfile 不再把陣列 index 帶過 await。回傳時依精確 ID、process-local 配置世代與最新 request ID 重驗，移除／同 ID 重建、配置重設、停用再啟用、較新 refresh 或取消均使舊結果失效。只合併 profile/accountID，保留等候期間已接受的 cursor／activity。不新增跨程序／外部直接改檔的 CAS。
- listener 具有每次 start 的 token，接收時核對 token、enabled、固定 connection ID 與平台，舊 listener 不能把另一條連線的 envelope 寫入；晚到錯誤亦核對存活身分。配置 save 成功會停止捕捉舊配置／憑證的 listener，由 caller 明確 start 新配置，既有 App 新增連線路徑本來就會 start。已接受的回呼不會被撤回。
- flush 於每筆開始時重驗狀態／到期時間並保留 process-local in-flight ID，避免重疊 flush 的舊清單把已完成項目再次送出。sending checkpoint 無法持久化即不呼叫 connector。傳送中刪除不復活紀錄；不宣稱能取消已開始的外部送出。結果保存失敗保留 durable sending，當前程序不立即重送；沿用重啟時改 retrying 並使用同一 idempotency key 的復原行為，不是 exactly-once，仍取決於 connector／遠端服務。
- 依 Swift testing／dependencies／CustomDump 技能使用隔離 store、固定時間、受控 continuation gates 與完整值快照。依 SPM 技能只把現有 CustomDump product 加入頻道 test target，不新增 package 或產品執行期依賴。沒有 UI／字串修改。

驗證紀錄：

- 先用兩項紅測試重現：failed removal 導致記憶體資料遺失，移除第一條連線後 profile 回傳污染原本第二條連線。**2 tests／4 issues**（`/tmp/filicon-channel-lifecycle-red.log`），不是僅推測風險。
- 修正後 **11 tests／2 suites 通過**（`/tmp/filicon-channel-lifecycle-focused.log`）。擴充 fixture 最初漏 return，修正編譯並移除多餘 try 後，**20 tests／2 suites 通過**（`/tmp/filicon-channel-lifecycle-extended.log`）；涵蓋同 ID 重建、停用 ABA、取消、較新 refresh、activity 合併、六種保存失敗、失敗斷線仍可接收、listener 跨連線／平台隔離、重疊 flush、sending checkpoint 失敗、late success/failure 不復活，以及既有頻道回歸。
- 原生 `Filicon App` Debug build 通過（`/tmp/filicon-channel-lifecycle-native.log`），`codesign --verify --deep --strict` 通過，包含 helpers／XPC；這次非 clean build，保留 ad-hoc／AppIntents 的既有提示。
- 又加三項測試函式（四種 case）：成功刪除僅影響選中連線、send result 保存失敗不誤報成功／重啟沿用 key、失敗配置寫入不撤銷既有 profile request。**最後版本已編譯，但沒有完成執行**（`/tmp/filicon-channel-lifecycle-focused-final.log`）：SwiftPM helper dlopen 找不到 Testing.framework 並 signal 5。之後唯讀檢查本機 Xcode Info.plist 為 **27.0**、app 時間為本輪 20:21，Xcode／xcrun 指令要求同意授權條款。已請使用者自行開啟 Xcode 完成條款及初始化，未代為接受、未更改全機 xcode-select 或繞過工具鏈要求。
- 七語言各 **1,571 keys、零缺漏**，`git diff --check` 通過。最終聚焦回歸與完整測試尚待 Xcode 初始化後重跑，不能援引先前通過數字宣稱本輪全套成功；沒有啟動 live 模型／外部帳號／平台測試。

使用者再次要求 commit 後繼續；提交前重新確認 Xcode **27.0（27A266a）**，`xcodebuild -checkFirstLaunchStatus` 回傳 69，`xcrun swift --version` 仍明確回報未同意授權條款。因此依使用者要求提交現有變更，但不把追加測試或完整套件標示通過。提交前 `git diff --check` 通過；未代為接受條款、未繞過初始化。

未 push、未啟動／重啟使用者 App／Xcode，未操作實際群組／頻道／憑證。下一步先完成驗證，再接上受核准的自身 channel.disconnect：需限制 owner／精確目標與歧義拒絕，完整揭露本機歷史／佇列移除、金鑰處理和已開始送出的限制。`AGENT-01` 與其餘 partial 保留。

## 已提交增量：受核准的自身更新通知設定（2026-09-21）

先提交上一批為 `4a994a4`（`feat: approve deletion of agent-owned reusable workflows`），提交前 **26 Swift Testing／3 suites 通過**（`/tmp/filicon-workflow-delete-precommit.log`）。本輪對照本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts` settings/set 與 `source/host/extensions/memory/agent-state.ts` updateSettings，只補有原生對應的 `notify_on_updates`，不宣稱整個 settings/state 已對等。

- 群組／mailbox 可用 `update_state(target:"settings",action:"set",notify_on_updates:Bool)` 提案。只接受這三個欄位、4,096-byte JSON 上限，嚴格驗證 JSON boolean，拒絕 0/1、字串、null、owner／permission 與其他欄位。`hidden_from_sidebar` 沒有相同原生側欄對象，單獨或混合提案均拒絕，不偷偷改成 archive。
- host 綁定自身 agent，獨立 authorizer 預設拒絕；即使 auto-review allow 也必須逐次明確核准。卡片顯示成員、原值／新值與影響範圍。不讓 profile／workflow 等核准授權靜音，沿用共用四次額度、精確重播回執、取消／帳號切換至最終同步保存的 lifetime 防護。
- `AgentProfile.notifyOnAgentUpdates` 持久化，舊資料預設 true；新建預設開啟，建立頁可選關閉，clone 維持新 agent 的開啟預設。專用可持久化 revision 在實際開關變更時更新，防止提案期間關閉再開啟（ABA）與舊編輯器覆寫。核准只合併該設定，保留其他最新欄位；disk save 失敗回滾，save 成功後晚到記帳失敗保留 durable receipt。同值設定不產生假變更。不是跨程序／外部檔案編輯的 CAS。
- 由原先固定 true 的 `AgentNotificationProjection` 接到實際 preference，只控制 agent roster 完成／等待輸入的系統通知。不是整個 App 或所有對話的靜音；不隱藏 approval cards、未讀數、Dock badges，不改工作／成員／可見性／權限，也不移除既有通知。開啟不補送已觀察的過去通知，實際 delivery 仍受 macOS 授權、focus 與 throttle 約束。設定屬本機共用 profile，跨使用該 profile 的群組／帳號，不是帳號隔離的 memory。
- 依 SwiftUI 技能加上 Agents → Edit →「代理人更新通知」切換並儲存，使用直接 state binding；核准細節／影響說明抽為可重用元件，補齊七語言。舊 editor 若設定已變更會顯示可翻譯錯誤，要求重新開啟，不靜默覆蓋。

測試先重現缺少 route：第一次 fixture 缺少 `try`，修正可編譯後確實收到 `.invalidFields` 而非預期的 `.approvalRequired`（`/tmp/filicon-settings-red.log`）。產品補齊後，初版 private-marker 斷言誤把系統說明的通用詞 PRIVATE 當資料外洩；改為精確 fixture 值／路徑比對，沒有刪除隔離斷言。

驗證狀態：

- 聚焦 **22 Swift Testing／4 suites、3 XCTest 通過**（`/tmp/filicon-settings-focused-final.log`），包含新設定路徑、現有頭像、通知 policy／projection，群組批准／拒絕／Stop／帳號／ABA／封存 × 開關兩方向、mailbox recipient、手動新建／編輯與重開、資料遷移、寫檔回滾、延遲 commit 撤銷、同 call id 重播與共用預算。範圍均為隔離 fixture，非真實付費模型或帳號。
- 原生 `Filicon App` **clean build 與 deep strict codesign 通過**（`/tmp/filicon-settings-native.log`），含 helpers／XPC；既有 AppIntents metadata／ad-hoc runtime 提示保留。後續釐清通知權限文字（設定可開啟，delivery 才受系統授權控制），呈現／policy 回歸 **6 Swift Testing／2 suites、3 XCTest 通過**（`/tmp/filicon-settings-presentation-final.log`），原生增量 build／deep strict codesign 再次通過（`/tmp/filicon-settings-native-final.log`）。
- 七語言各 **1,571 keys、零缺漏**；28 張 380 點寬核准 fixture 預覽（開／關 × 七語言 × 明暗）在 `/tmp/filicon-settings-previews/`，每種語言至少檢視一張，未見裁切。不是全產品逐頁或 live App 驗收。
- 完整 `swift test --no-parallel` **135 XCTest 通過，但 939 Swift Testing／107 suites 回報 75 issues，未通過**（`/tmp/filicon-settings-full.log`）。執行中 Mac 鎖定，已確認 `CGSSessionScreenIsLocked=Yes`；多個既有與新測試重開 protected agents/workflows/channels/MCP/image 檔案回報 Code 257／EPERM，另有 state 為空／malformed 等衍生斷言。不能在未解鎖重跑前把所有失敗一概判為環境問題或宣稱全套成功。已請使用者解鎖，未移除檔案保護或忽略失敗。

- 偵測到鎖定旗標解除後重跑，**135 XCTest 通過；939 Swift Testing／107 suites 剩 1 issue**（`/tmp/filicon-settings-full-final.log`），不再有 protected-file 重開失敗。剩餘項是舊 `ownProfileRejectsOtherStateRoutesFieldsAndIdentitySpoofing` 對 settings 非法 profile 欄位預期通用 `.invalidFields`；新增 route 改回傳精確 `.invalid`。改為獨立驗證 `AgentSettingsChangeError.invalid`，仍要求該非法提案被拒絕，不移除範圍保護。

- 最後完整 `swift test --no-parallel` **135 XCTest、939 Swift Testing／107 suites 全數通過**（`/tmp/filicon-settings-full-verified.log`）。兩項 opt-in live Codex 測試未啟用，既有 CoreData NSXPC 診斷仍在；沒有跳過失敗測試或降低檔案保護。這是隔離回歸，非真實 macOS 通知投遞／帳號驗收。

本批已於下一輪提交為 `49ea201`；未 push、未啟動／重啟使用者 App／Xcode，未操作真實群組、排程或外部服務。`AGENT-01` 與其餘 partial 項目保留，不以本輪通知開關宣稱原版完整對等。

## 已提交增量：受核准的自身工作流程刪除（2026-09-21）

先提交上一批為 `a4e5d4c`（`feat: approve agent-owned workflow creation and rewriting`）；提交前 **32 Swift Testing／5 suites 與 14 XCTest 通過**。本輪核對本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts`（workflow/delete）及 `source/host/extensions/memory/agent-state.ts`（deleteWorkflow）。補 Filicon-native 受限對應，不宣稱完整原版 workflow/state parity。

- 群組／mailbox 使用 `update_state(target:"workflow",action:"delete",id:...)`，只接受這三個字串欄位及精確 ID，JSON 不超過 4,096 bytes。身分由 host 固定；只允許自身本機、手動、單一 prompt、全文不超過 8,000 UTF-8 bytes 的定義。peer／未指定 owner／source-linked／learning／多步驟／action／scheduled 拒絕，不接受 authority/body 等混入欄位。
- 刪除與 workflow write 使用獨立 authorizer，預設拒絕，不繼承 profile/write 或 auto-review allow。逐次 destructive 核准顯示完整舊定義、ID、enabled 狀態及已知直接引用總數／前 100 個名稱與 ID；不把 peer 正文或引用清單送回請求模型。
- 核准明示無法復原。僅原子移除共用定義，既有 run history 仍可在工作流程全域歷史依 ID 檢視；已取得內容的執行繼續。其他 workflow、routine、排程、檔案、來源、連線、權限均不連帶刪除／停止／改寫；未來引用可能失敗或省略內容。流程庫仍是本機共用內容，非帳號隔離記憶。
- 原子 commit 核對同 store revision 與完整舊定義，任何 library save／同值重設均使舊提案失效，刪除重建亦受保護；不是跨程序或外部直接改檔的版本鎖。Stop／帳號切換同步撤銷，核准後重驗未封存 owner；共用四次修改上限與 pending reservation／精確重播。durable receipt 區分實際刪除和後續記帳錯誤，不會將成功刪除誤報失敗而重試；刪除不需要新增儲存額度。

依 Swift 測試／CustomDump 技能使用隔離資料、受控 continuation gate 與 fixture provider；先用缺少獨立核准路由的紅測試重現。新增拒絕／Stop／帳號切換／封存／stale／相同 ID 重建／同值重設／磁碟失敗、完整核准 metadata、peer 與跨 mailbox 身分、防重播／四次預算、commit 前撤銷、已捕捉執行與持久歷史測試。修正新測試 async autoclosure 用法；Swift 6.3.3 曾在 provider 閉包的複合 `#expect` 觸發 SendNonSendable 編譯器 crash，改以相同語意的字串清單／CustomDump 比對後可編譯。ABA 測試原先誤將重建後由 store 更新的時間戳與刪除前比較，現檢查拒絕核准後完整保留重建定義，另有同值重設 revision 測試，不弱化產品防護。

第一次可執行的聚焦回歸遇到 macOS 鎖定（已確認 `CGSSessionScreenIsLocked=Yes`），受保護的 workflows/history 檔案重開回報 Code 257／EPERM；包括既有測試亦失敗（`/tmp/filicon-workflow-delete-focused-final.log`）。沒有移除檔案保護、跳過錯誤來宣稱全套通過。鎖定解除後重跑，持久化測試恢復；另確認 mailbox 將拒絕以 typed error 回傳，而非群組的 error-result wrapper，修正 fixture 接住 `.unavailable` 後再提案自身 ID，未改產品權限或延長等待。

最終驗證結果：

- 聚焦 **26 項／3 suites 通過**（`/tmp/filicon-workflow-delete-focused-verified.log`）；包括 create/write 舊回歸、刪除生命週期、群組六種核准結果、mailbox recipient、history 重開與已捕捉執行。先前不依賴重開檔案的 fence／UI 聚焦 **8 項／2 suites 通過**（`/tmp/filicon-workflow-delete-fences.log`）。
- 完整 `swift test --no-parallel` **134 XCTest 與 929 Swift Testing／106 suites 全數通過**（`/tmp/filicon-workflow-delete-full.log`）。兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷保留，不代表真實帳號端到端驗收。上輪安全金鑰等待不穩定性沒有在本輪重現，未宣稱已根治。
- 原生 `Filicon App` clean build 通過（`/tmp/filicon-workflow-delete-native.log`），最後 schema 說明更新後再 build／deep strict codesign 通過（`/tmp/filicon-workflow-delete-native-final.log`），包含 helpers／XPC。僅 ad-hoc Debug 驗證，既有 AppIntents metadata／hardened runtime 提示仍在，未做 release 公證。
- 七語言各 **1,562 keys、零缺漏**；localization audit／`git diff --check` 通過。依 SwiftUI 技能調整共用核准元件，create/update/delete × 七語言 × 明暗共 **42 張** 420 點寬 fixture 預覽（`/tmp/filicon-workflow-delete-previews/`），刪除畫面每種語言至少檢視一張，未見裁切；不是全產品逐頁或 live App 驗收。

本批已在下一輪提交為 `4a994a4`，未 push、未啟動／重啟使用者 App 或 Xcode 工作程序，未操作真實資料／模型／外部帳號。`AGENT-01` 及其他 partial 保留。

## 已提交增量：受核准的自身工作流程建立／全文改寫（2026-09-21）

先提交上一批為 `d2ec81f`（`fix: drain process output before reporting completion`），提交前 **34 項／4 suites** 回歸通過。本輪核對本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts` 與 `source/host/extensions/memory/agent-state.ts`：原有 `update_state(target:"workflow",action:"write",name,description,body,id?)` 是可重用程序的建立／改寫，不是立即執行或 routine 排程。本輪補 Filicon-native 受限對應，未宣稱原版所有 workflow/state 能力均已還原。

- 群組與 mailbox 接上同一路由；host 綁定發起代理人，新建 ID 由 host 產生，改寫只接受自己的精確 native ID。名稱／說明／全文皆必填，分別最多 80 字元／1,536 字元／8,000 UTF-8 bytes；外圍空白裁除，名稱／說明換行正規化，body 中的 frontmatter 仍是純提示文字，不解析成權限或 trigger。
- 只允許自己擁有的本機、手動、單一 prompt 定義。未指定 owner／peer、source-linked 匯入、受管理的 learning workflow、多步驟／action／scheduled 定義拒絕；無來源標記且由使用者明確指派 owner 的匯入副本視為本機定義。新建為 enabled/manual；改寫保留 ID、owner、enabled、trigger、createdAt 和歷史。不支援 delete、enable/disable、source 路徑／URL、權限欄位或立即執行。
- 即使 auto-review allow 仍逐次顯示完整 before/after 核准。核准卡明示流程庫是本機工作區共享內容，**不是私人或帳號隔離記憶**；其他代理人及其模型、現有／未來 workflow 和 routine 可經引用取得內容，改名可能破壞名稱引用；已執行請求保留當時快照。列出已知直接引用總數與最多 100 個名稱／ID，僅為當下提示，不是完整或凍結的影響名單；不向請求模型回傳 peer 流程正文或引用清單。
- `AgentWorkflowStore` 在原子儲存內核對 library revision 及完整舊定義；同一 store 的任何成功修改（包含無關流程與相同值還原）都使待核准提案失效。這是 in-process fence，**不宣稱能協調其他程序或外部直接改檔**。Stop／帳號切換使用同步 lifetime fence；核准後重驗代理人未封存。與 profile／memory／avatar／routine 共用四次修改額度、pending reservation、精確重播、quota 與 durable receipt；儲存後記帳失敗仍如實回報已保存，沒有重複寫入。

依 Swift 測試／CustomDump 技能使用隔離目錄、固定 IDs／時間、受控核准 gate 與 fixture provider，先重現缺少路由的兩項紅測試。覆蓋群組 create/update 的批准／拒絕／停止／帳號切換／stale／封存共 12 種案例、mailbox recipient 身分、全文 metadata、同源保存／重開、來源／owner／步驟／trigger 保護、UTF-8／字數界線、frontmatter 純文字、pending duplicate、共用四次額度與晚到記帳錯誤。初版 App 重開測試誤比較未排序 dictionary JSON bytes，改為以持久化時間精度比較完整 workflow 值，未放寬產品斷言。

依 SwiftUI 技能將全文核准內容分離為元件，渲染 create/update × 七語言 × 明暗共 28 張 420 點寬預覽，每種語言各人工檢視至少一張；發現既有西文／韓文的通用 Enabled 翻譯不適用，改用本元件專用狀態翻譯。原生 clean build 首次發現新元件漏入 target，依 SPM／Xcode 技能補四筆專案參照，保留既有 target/scheme IDs，避免產生器全面重編號。需從 `Filicon.xcworkspace` 選 `Filicon App`，不是 package executable。

驗證結果：

- 初步含既有 workflow／profile／引用路徑的聚焦回歸 **29 項／5 suites 通過**（`/tmp/filicon-workflow-write-focused-final.log`）；新增精確上限、frontmatter、共用預算與相同值重設 revision 測試後，**12 項／2 suites 通過**（`/tmp/filicon-workflow-write-boundaries.log`）。後續語言調整再納入最後完整回歸。
- 首次完整執行 **918 Swift Testing／106 suites 通過，但 134 XCTest 中有一項失敗**：既有 `testRemoteProxySendsHelloHeartbeatAndHandbackCancelsCeremony` 的 waitUntil 回報 Condition did not become true（`/tmp/filicon-workflow-write-full.log`）。該 helper 只有 1,000 次 Task.yield 上限，且多個條件共用同一失敗行，日誌無法辨別是哪一階段；本輪沒有改該測試或安全金鑰程式，不能據此斷言產品錯誤或根因已消除。對使用者的首次「全套通過」摘要已更正。
- 最後以完整原始碼重跑 `swift test --no-parallel`，**134 XCTest、918 Swift Testing／106 suites 全數通過**（`/tmp/filicon-workflow-write-full-final.log`）；兩項 opt-in live Codex 測試未啟用，既有 CoreData NSXPC 診斷仍在。另單獨重跑安全金鑰 14 項 XCTest 全過（`/tmp/filicon-workflow-write-security-followup.log`）；重跑成功不代表上項等待不穩定性已根治。
- 原生 `Filicon App` **clean build 通過**（`/tmp/filicon-workflow-write-native-final.log`）；最後錯誤文字／描述調整再 build 與 `codesign --verify --deep --strict` 通過（`/tmp/filicon-workflow-write-native-verified.log`），包含 helpers／XPC。僅 ad-hoc Debug 驗證，既有 AppIntents metadata／runtime 提示保留，未做 release 公證。
- 七語言各 **1,558 keys、零缺漏**，localization audit／`git diff --check` 通過。核准元件預覽在 `/tmp/filicon-workflow-write-previews/`；修正後再檢視西文／韓文。這是新增元件的 fixture 渲染，不是全產品逐頁驗收或使用者 App 的 live 操作。

本批已在下一輪提交為 `a4e5d4c`，未 push、未啟動／重啟使用者 App 或 Xcode 工作程序，未操作真實資料／模型／外部帳號。`AGENT-01` 與其餘 partial 項目保留，不以本輪增量宣稱全功能完成。

## 已提交增量：本機程序輸出收尾與錯誤標記（2026-09-21）

先提交上一批為 `26d789c`（`feat: add scoped read-only search for approved agent memories`），提交前 **81 項／6 suites** 回歸通過。本輪處理上輪完整套件實際出現的 stdout 遺失：舊 `ProcessSupervisor.didExit` 先關閉 readability handlers／公布退出，而 bytes 還可能在等待 actor 接收的 Task 中，造成已完成的 snapshot 為空或之後又增長。本批為 native 執行可靠性修正，不新增原版雲端能力。

- 改為程序退出狀態與 stdout／stderr 的 EOF 都已交付後，才回報 `isRunning=false` 與 exitStatus。收尾期間仍可讀增量輸出，拒絕對已退出的程序送 stdin；完成後 output／offset 穩定，沒有晚到 bytes 回頭改寫終態。
- 新增 queue-confined `LocalProcessOutputReader`，使用 nonblocking dispatch source。每條管線一次最多一個 64 KiB 區塊，等 supervisor 接收後才續讀，EOF 不能超車；合併 10 MiB 上限與超限終止保留。只保證各管線內順序，不宣稱 stdout 與 stderr 有全域發生順序。取消時平衡 suspend/resume，取消 handler 關閉其擁有的 descriptor。
- 直接子程序退出後，若繼承管線的其他 writer 不關閉，最多安排一秒收尾等待，再停止收集並回報可能不完整的 `terminationError`；使用者 Stop 也可結束收尾，但錯誤理由與期限到期分開。已讀、等待交付的區塊先確認再送 terminal event。此階段不向已知退出的 PID／process group 發送訊號；一般尚在執行的程序仍沿用 TERM／KILL、原執行逾時與 run/generation 防護。不是任意背景子孫程序管理，也不保證收集期限之後的輸出。
- App 原先將含 terminationError 的 process JSON 當成功工具結果。現改為 `isError=true`，保留 partial bytes、offset、exit code 與診斷；逾時／超限／收尾失敗不再顯示為成功卡片。正常完成或單純非零 exit code 的既有結果契約不變。本批未變更 UI 版面、權限或使用者設定。

依 Swift 測試／SPM 技能，只在 local-tools 測試 target 加入專案既有 CustomDump，沒有新增 runtime 依賴。測試使用隔離目錄、固定 scope IDs、短命 fixture 程序與 continuation handshake：先修正新增測試的 async autoclosure 編譯錯誤，再用舊 supervisor 加入不改預設行為的時序 hook，確實重現 **7 個失敗斷言**（`/tmp/filicon-process-output-red-final.log`）。新版通過受控晚到 stdout/stderr、768 KiB 雙管線＋增量 offset、空輸出／提前關管線、期限／Stop、reader 取消不能超車、25 次快速退出與同 supervisor 的 12 個並行程序。另先重現 App **3 個錯誤標記失敗**（`/tmp/filicon-process-result-red.log`），再驗證四種 snapshot 保留完整 JSON 且錯誤標記正確。測試等待只用於觀察真實 I/O／期限，沒有用延長睡眠修補產品競態。

驗證結果：

- supervisor 聚焦 **20 項／2 suites 通過**（`/tmp/filicon-process-output-regression.log`）；含 App 錯誤映射／群組核准的擴大回歸 **33 項／4 suites 通過**（`/tmp/filicon-process-output-app-regression.log`）。其後新增的 12 程序並行隔離測試納入完整套件。
- 最終 `swift test --no-parallel` **134 XCTest、906 Swift Testing／104 suites 全數通過**（`/tmp/filicon-process-output-full-final.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。本輪原有 stdin 測試、輸出上限、逾時與程序群終止均通過，沒有放寬斷言或省略失敗測試。
- 原生 `Filicon App` **clean build、deep strict codesign 通過**，包含 helpers 與 XPC（`/tmp/filicon-process-output-native-final.log`）；既有 AppIntents metadata／ad-hoc runtime 提示仍在。沒有執行 release 公證或啟動使用者 App。
- 七語言各 **1,545 keys、零缺漏**，localization audit 與 `git diff --check` 通過；本輪沒有新增 UI 標籤／版面，不宣稱全 UI 視覺驗收。

本批已在下一輪提交為 `d2ec81f`；未 push、未啟動／重啟 App 或使用者 Xcode 工作程序、未存取 live 模型。保留原有 parity partial 項目，不宣稱所有程序生命週期或原版能力已完整還原。

## 已提交增量：只讀搜尋未注入的已核准記憶（2026-09-21）

先提交上一批為 `7814a77`（`feat: recall relevant approved memories for current agent messages`），提交前 **55 項／5 suites** 回歸通過。本輪核對本機非官方 reconstructed 的 `host/runner/sand-memory.ts`：提示明確允許以 Read／Shell grep `profile.md` 與 `log/` 找未列出的舊事實。本輪提供 **Filicon-native `SearchMemory` 對應**，不是宣稱原版有同名工具，也不向模型開放 App 內部儲存檔案。

- 群組／mailbox 模型可主動搜尋目前帳號、自身私人與已明確核准的帳號共享事實。帳號和代理人由 host 綁定，先隔離再計算匹配、數量與分頁，不能傳入其他 agent/account/path。讀取不要求新的寫入核准，但不擴大既有分享；寫入／忘記仍走原核准流程。原文、scope、tier、日期、作者及 canForget 完整保留，搜尋不去重或修改記錄；讀到別人共享的事實不代表能刪除。
- `query` 最多 256 Unicode scalars，使用忽略大小寫／重音／全半形的字串子串比對；不是 regex、詞項相關性或語意搜尋。空／省略 query 可瀏覽，只有空白的 query 拒絕。scope 只接受 agent/user/all；每頁最多八筆完整事實，包含 metadata 的 JSON 不超過 8 KiB。過大事實整筆略過並回報本頁省略數，totalMatches 包含它們；游標仍前進，可從 editor 檢視，不截斷成錯誤事實。
- 續頁只接受 opaque cursor，綁目前 owner／run／session、原查詢／範圍及可見資料 fingerprint。選取範圍新增／刪除／變更即拒絕舊頁；其他帳號、私人 peer 或不在選取範圍的變更不影響游標。cursor 不快取事實。每次原始請求的代理人共用 32 次讀取額度，與四次修改核准額度分離；actor hop 前保留讀取額度，資料 actor 內驗 owner，回傳後重驗 Stop／session lifetime。封存或關閉後拒絕搜尋。
- 沿用 group/mailbox 的工具 metadata 投影：共用歷史只保留工具名稱／狀態，不加入原始私人搜尋結果。系統描述及結果仍將事實標示為不可信資料，禁止把事實當權限或擅自轉寄；這不代表模型最終文字已被自動隱私審查。三種錯誤補七語言 catalog；未變動 UI 版面。

依 Swift 測試技能使用隔離儲存、固定排序日期／ID、fixture model 與 CustomDump。先以未接線版本重現四項缺少 SearchMemory 的紅測試（`/tmp/filicon-memory-search-red.log`）；新增九項核心／工具測試及一項兩路徑 App 測試，涵蓋七語言、字串／scope 邊界、escaped UTF-8 預算、超大記憶、分頁／重播／失效／身份隔離、唯讀存檔 bytes、關閉／封存、32 次上限與獨立修改核准。App fixture 實際呼叫工具找出未注入的舊事實，並確認另一成員的請求與群組／mailbox 共用歷史沒有收到私人原文。不是 live 模型或跨平台帳號驗收。

驗證結果：

- 聚焦 **95 項／7 suites 通過**，包含記憶／核准／跨對話／App 整合及 LocalTools（`/tmp/filicon-memory-search-regression.log`）。最後將 cursor fixture 改為實際含有 query，確認「新事實不匹配查詢、但同 scope 仍使游標失效」；九項記憶搜尋測試再次全過（`/tmp/filicon-memory-search-scope-final.log`），產品碼未變。
- 首次完整回歸 134 XCTest 通過，897 Swift Testing 中既有 `stdinCanBeSentAndIsRejectedAfterExit` 一項失敗：預期 14 bytes 卻收到 0 bytes（`/tmp/filicon-memory-search-full.log`）。檢查 `ProcessSupervisor` 發現輸出以非同步 Task 入列，而 didExit 可先移除讀取 handler 並公布結束；這是尚未修正的輸出收尾時序風險，不能以稍後重跑通過宣稱根治。本批沒有修改該元件或放寬測試。
- 加入選取範圍／共享作者 cursor 測試後，非並行完整重跑 **134 XCTest、898 Swift Testing／102 suites 全數通過**（`/tmp/filicon-memory-search-full-final.log`）。兩項 opt-in live Codex 測試仍未啟用；既有 CoreData NSXPC 診斷仍在。
- 原生 `Filicon App` **clean build 及 deep strict codesign 通過**，包含兩個 helper 與 XPC（`/tmp/filicon-memory-search-native.log`）。既有 AppIntents metadata／ad-hoc runtime 提示仍在；未啟動 App。
- 七語言各 **1,545 keys、零缺漏**，localization audit 與 `git diff --check` 通過。沒有 UI 版面變更，也未宣稱全產品逐頁視覺驗收。

本批已在下一輪提交為 `26d789c`。`AGENT-01` 維持 partial：仍缺 project 記憶、自動抽取、任意 archive／檔案／語意檢索、其他執行入口及完整原版 persona/runtime；本輪未 push、未啟動／重啟使用者 App、未更動真實資料。

## 已提交增量：依當前訊息召回已核准的相關記憶（2026-09-20）

先提交上一批為 `3fc0d91`（`fix: validate connector event filters and enable safe editing`），提交前 **59 項／7 suites** 回歸通過。本輪核對本機非官方 reconstructed 的 `host/runner/sand-memory.ts`：`selectRelevantMemories` 以關鍵字重疊排序，`gatherExtractionMemories` 把相關 archive facts 加入記憶抽取輸入；`turn-memory.ts` 接上抽取，而 `memory-service.ts` 的一般 recall 仍以近期為主。因此這輪是 **Filicon-native 召回增強**，不是宣稱已完整還原原版的自動抽取或語意搜尋。

- `AgentMemoryQuery` 僅保留有界、去重的詞項，最多前 4,096 Unicode scalars／128 個詞項；一般字詞長度 2–64，排除部分英／法／西常見詞；漢字／假名／韓文使用相鄰雙字。忽略大小寫、重音與全半形，重複詞不加分；不是同義詞／翻譯／向量搜尋。超限不掃描完整長輸入，也不把截斷的半個詞當完整詞。
- scope／account 可見性先篩選，原有私人／共享與 foundational／recent 四個池、筆數／UTF-8 JSON bytes 預算、完整事實與來源 metadata 不變。同池優先字詞交集數，再用既有日期／note 重要性／固定 ID 排序；無相關詞時完全沿用原排序。正規化去重仍先保留最新原文及作者，不以相關性復活舊副本；太大事實整筆略過，不截斷或擠占其他池。
- 一般群組只取當前使用者訊息；群組間 peer wake 只取本次傳入訊息；mailbox／手動代理人訊息只取該封 inbound。工具值綁定 immutable query，不用共用的 last-query 狀態，不混入歷史、其他代理人答覆、圖片或檔案內容；不把原始 query 注入系統提示或寫入儲存。既有 owner／account／conversation／archived／Stop 與逐次修改核准保護保留。
- 按 Swift 測試技能使用固定日期／排序 ID、隔離存檔、fixture provider 與 CustomDump。核心涵蓋七語言例句、Unicode／詞項上限、去重與 escaped byte budgets；三條對話路徑先重現 **6 個失敗斷言**（`/tmp/filicon-memory-query-wiring-red.log`），接線後確認連續不同主題不串 query、舊歷史不影響召回、私人／跨帳號事實不漏出、共享事實保留且存檔 bytes 不變。另驗證同 session 的獨立工具 snapshot、錯誤 conversation、封存與停止後拒絕召回。

驗證結果：

- 接線聚焦回歸 **54 項／5 suites** 通過（`/tmp/filicon-memory-relevance-wiring.log`）；其後新增的獨立 snapshot／生命週期測試也納入下列完整回歸。
- 完整 `swift test --no-parallel` **134 XCTest、888 Swift Testing／101 suites** 通過（`/tmp/filicon-memory-relevance-full.log`），兩項 opt-in live Codex 測試未啟用。
- 原生 `Filicon App` **clean build 與 deep strict codesign 通過**，包含兩個 helper 與 XPC（`/tmp/filicon-memory-relevance-native.log`）；既有 AppIntents metadata／ad-hoc 提示仍在。僅建置／驗簽，不啟動使用者 App。
- 本批無 UI 或字串 catalog 變更；七語言各 **1,542 keys、零缺漏**，`git diff --check` 通過。沒有重新宣稱全 UI 視覺或 live 模型驗收。

本批已在下一輪提交為 `7814a77`；未 push、未啟動／重啟使用者 App、未更動真實聊天／群組／記憶或呼叫 live 模型。`AGENT-01` 維持 partial：仍缺 project 記憶、自動抽取、任意 archive search、其他執行入口及完整原版 persona/runtime。

## 已提交增量：通用連接器事件篩選的安全比對與手動編輯（2026-09-20）

上一批提交為 `fd0a334`（`feat: add validated GitHub and Slack routine editors`），提交前 60 項／7 suites 回歸通過。本批是 Filicon-native generic connector 的安全補強；不把它稱作 reconstructed 雲端能力還原，不增加 Teams 身分或外部帳號接線。

- 修正原本 JSON 解析失敗／非物件被視為 match-all 的錯誤，以及以 `String(describing:)` 比對造成的型別混淆。儲存與執行共用有界驗證：重複鍵（包含 escape 後相同鍵）、損壞資料、陣列／純量根、超限條件均拒絕，不丟棄篩選。舊損壞條件原樣保留，但其事件分支不匹配；其他有效 OR 成員或明確 Run Now 不受這個分支阻擋。
- 精確 connector UUID 與事件類型；所有最上層條件必須符合，巢狀物件完整比較且無關鍵排序，陣列保留順序，字串不做 Unicode 正規化，布林／數字／字串不互轉。十進位數字保留係數與指數，避免浮點捨入把不同長 ID 或高精度小數變成相同值；1、1.0、1e0 相等。空物件僅匹配同 connector/kind 的有效物件 payload，損壞 payload 不匹配。
- 限制明示為 filters 16 KiB、payload 1 MiB、根深度 0 至最大 16、含容器最多 4,096 個值、單一數字 256 字元／原始指數絕對值 10,000。event kind 為 1–128 字元、無控制字元或前後空白。不查名稱、不建立連線、不驗證 connector 是否在線；仍須既有事件來源。
- 原生新增與既有排程編輯共用草稿驗證，支援 generic 與已支援時間／平台條件的平面 OR，未改的 JSON bytes 保留。損壞的既有條件只可改名稱／任務，不能藉編輯靜默修復或放寬。沿用 revision、lifetime、原子儲存、取消／stale／磁碟失敗保護；模型 `update_state` generic create/update 仍明確拒絕。
- 依 SwiftUI 與測試技能，把驗證置於可測草稿與核心服務，使用 value binding、固定 ID／時間、隔離儲存、fixture executor 與 CustomDump 比較。最初測試程式的 async assertion 編譯錯誤已修正，再針對未修 matcher 實際重現 20 個失敗斷言（`/tmp/filicon-connector-filter-red.log`）。另外涵蓋 JSON 語法／UTF-8／escape／邊界、型別／精度／巢狀比對、persisted legacy、手動 OR 編輯／重開／去重／connector scope、App 儲存／取消／stale／磁碟失敗與模型權限不擴大。測試 fixture 曾把同 connector／同 delivery ID 用於兩種事件類型，觸發正確的既有去重；已改用不同 delivery ID，不修改產品的去重規則。

最終驗證：

- 聚焦回歸 **59 項／7 suites 通過**（`/tmp/filicon-connector-focused-final.log`）。
- 完整 `swift test --no-parallel` **134 XCTest、882 Swift Testing／101 suites 通過**，兩項 opt-in live Codex 測試未啟用（`/tmp/filicon-connector-full-final.log`）。既有 CoreData NSXPC 診斷仍在，未造成測試失敗。
- 原生 `Filicon App` **clean build 與 deep strict codesign 通過**，包含新 matcher、兩個 helper 及 XPC（`/tmp/filicon-connector-native-final.log`）；AppIntents metadata 與 ad-hoc runtime 提示仍在。
- NSHostingView 產生 generic 有效／空條件／重複鍵三態 × 七語言 × 明暗 **42 張**，完整 editor sheet 七態 **98 張**，另重跑既有預覽；驗證 fitting size，人工抽查七語言代表畫面與完整可編輯／唯讀 sheet。長表單可捲動，底部取消／儲存固定；產物 `/tmp/filicon-connector-previews/`，不是使用者 App 的 live UI 驗收。
- 預覽抓到舊選單 `Connector event` 在所有 catalog 皆未登錄，已補鍵與翻譯並納入斷言，JSON 欄位增加固定標籤；也修正本表單既有法／西／韓／繁中標籤。這說明僅 catalog key 對齊不代表全 UI 已翻譯。最終七語言各 **1,542 keys、零缺漏**，`git diff --check` 通過。

本批已在下一輪提交為 `3fc0d91`；未 push、未啟動／重啟使用者 App、未更動真實聊天／群組／排程／連線。`AUTO-03` 維持 partial：Teams 身分／主文／Graph／同步回覆與條件編輯、GitHub checks 彙整、Slack 名稱／人類身分映射及 live 帳號驗收仍未齊備。

## 已提交增量：GitHub／Slack 排程條件的安全新增與編輯（2026-09-20）

上一批已提交 `aa29b36`（`feat: safely edit existing routine definitions`），提交前再次通過 52 項／6 suites 聚焦回歸。本輪核對本機非官方 reconstructed 的 `sand-state-tool.ts` 與現行平台 matcher／ingress，補上既有 GitHub／Slack 排程的手動條件編輯，也收緊共用新增表單。

- GitHub 改為 14 種事件勾選、具體 owner/repo、單一精確 CI 分支及最多 50 個登入名稱。拒絕未知事件、空逗號項、無效分支／使用者、缺少分支的 CI，原始清單限制在去重前套用。不再依賴會丟掉條件的舊 initializer。說明明示個別 push workflow 完成不是 checks 彙整，CI 不套用使用者篩選；議題指派事件依目前 native 實作篩選操作人，不宣稱是受指派者。
- Slack 只接受 C/G/D 對話 ID 或 `*`，四種比對模式不再將未知值退回 message。關鍵字與表情使用獨立欄位，切換後保留並顯示不適用的篩選，要求明確清除；拒絕過長關鍵字、截斷對話 ID、無效／超過八個表情、空逗號項與會被有損轉換的 `::` 表情後綴。七語言說明明示 bot/app mention、既有連線與費用、不支援名稱／bySelf。
- 既有支援格式可編輯，並可與 cron／Linear／Sentry／PagerDuty 組成最多八項平面 OR。未改動的成員保留原值；名稱型 Slack、bySelf true、未知事件或不支援格式維持 trigger 唯讀，只能改名稱／任務，不放寬限制。沿用上一批原子 revision／lifetime 儲存，不新增外部授權或立即執行。
- 依 SwiftUI／測試技能，checkbox 使用 value subscript 的衍生 binding，邏輯留在可測草稿；以隔離目錄、固定事件時間／ID、fixture executor 和 HMAC 驗證資料測試，不呼叫真實模型。新增 12 項測試，包含 14 種 GitHub／四種 Slack 比對、原始輸入邊界、完整 round-trip、OR／history／時間錨點／重播、App 儲存／取消／stale／磁碟失敗與舊格式保留。先以三項紅測試重現 42 個失敗斷言，再修正；開發中另修正錯誤分類，並依 store 的 millisecondsSince1970 編碼邊界比較持久化日期，避免測試誤判次微秒往返差異。

驗證：

- 聚焦回歸 **60 項／7 suites 通過**：`/tmp/filicon-github-slack-focused-final.log`。
- 非並行完整回歸 **134 XCTest + 873 Swift Testing／99 suites 通過**；兩項 opt-in live Codex 測試仍未啟用：`/tmp/filicon-github-slack-full.log`；測試程序仍有 CoreData NSXPC 診斷訊息，未造成測試失敗。
- 原生 `Filicon App` **clean build 通過**，`codesign --verify --deep --strict` 驗證 App、兩個 helpers 與 XPC 通過：`/tmp/filicon-github-slack-native.log`。既有 AppIntents metadata／ad-hoc runtime 提示仍在。
- NSHostingView 產生 GitHub／Slack／不相容條件三態 × 七語言 × 明暗共 **42 張**，完整 editor sheet 五態共 **70 張**，另外重跑既有平台 84 張；驗證 fitting size，人工抽查各語言和唯讀狀態、修正後再渲染。表單可捲動，取消／儲存固定於底部。產物：`/tmp/filicon-github-slack-previews/`，不是使用者 App 的 live UI 驗收。
- 七語言各 **1,537 keys、零缺漏**。視覺檢查發現並修正舊有法文 CI 分支、韓文比對／關鍵字／提及／表情，以及相關六語言欄位標籤。新增明確翻譯回歸斷言。`git diff --check` 通過。

本批已在下一輪提交為 `fd0a334`；未 push、未啟動／重啟 App、未更動真實群組／聊天／排程／連線。`AUTO-03` 維持 partial：當時 Teams／generic 條件專用編輯、Teams 可信身分／主文／Graph／同步回覆、GitHub checks 彙整、Slack 名稱／人類身分映射及 live 帳號驗收仍有差異。

## 已提交增量：既有排程的手動編輯與儲存生命週期（2026-09-20）

上一批已提交 `f874dcd`（`fix: add validated platform event menus for new routines`），提交前再次通過 59 項／6 suites 聚焦回歸。本批補自動化清單的「編輯」入口，不更動外部連線或立即執行排程。

- 支援名稱、任務內容與 cron／interval、canonical Linear／Sentry／PagerDuty 及其最多八項平面 OR 條件。其他平台、legacy／unknown／含不支援成員的組合，只能改名稱與任務內容，原始 trigger 唯讀保留。未變動的成員保留 nil 時區、UUID 大小寫及精確 ID 等原有值，不因只改另一分支而重寫。
- 服務層在同一 actor turn 比對原始定義／revision 並原子寫入；編輯期間新執行紀錄、wakes、claims、費用保護和現行 runtime 欄位保留，不接受草稿夾帶 owner／enabled／guardPaused／revision／createdAt 變更。只改名稱／任務／事件篩選，不重設未改動的時間條件；改動時間條件則從儲存時間重算，下次時間仍尊重停用及費用暫停。
- 執行中的工作沿用啟動時任務，完成後保留新定義與新排程。儲存不是 Run Now；已入列事件可能符合新條件並產生模型費用。取消／關閉、帳號切換、封存 owner 撤銷未提交寫入；另一處修改、停用再啟用、刪除或費用保護變更會拒絕 stale 草稿。磁碟寫入失敗不公布假成功，草稿留在編輯視窗；已持久化的收據和後續 quota 記帳錯誤分開處理。
- 依 SwiftUI 技能分離可測草稿、欄位和儲存動作；沿用既有 lifetime／quota，不新增依賴或自造 Binding。新增八個七語言文字項目，人工檢查時修正日／韓「指令」、法／西／韓「排程」及韓文「時區」既有誤譯。七語言各 1,520 keys、零缺漏不等於全產品翻譯品質保證。

依 Swift 測試技能使用隔離目錄、固定識別／時間、受控 executor 與 continuation handshake，新增 `ManualRoutineEditTests` 11 項及 `RoutineEditAppTests` 七項，涵蓋執行進度／歷史保留、執行中編輯、無變更、時間重新計算、stale／不可變欄位繞過、取消／帳號／封存、寫入失敗重試、未知格式保留、App 儲存和七語言。聚焦回歸 **52 項／6 suites 通過**（`/tmp/filicon-routine-edit-focused-final.log`）。NSHostingView 產生三種完整 sheet 狀態 × 七語言 × 明暗，共 42 張，驗證 fitting size，並人工抽查每種語言代表圖；長表單保留原生捲動、取消與儲存固定在下方。產物在 `/tmp/filicon-routine-edit-previews/`，不是使用者 App 的 live UI 驗收。

完整回歸：鎖定時擴大並行回歸的四項既有頭像／記憶測試失敗；非並行完整測試雖通過 134 XCTest，Swift Testing 在 agents／workflows 等受保護檔案重開時回報 Cocoa 257／EPERM，後續既有跨對話測試的索引越界使 helper 中止（`/tmp/filicon-routine-edit-focused.log`、`/tmp/filicon-routine-edit-full.log`）。隔離重跑同樣失敗，不是已證實的並行 flake；IORegistry 當時明確回報 `CGSSessionScreenIsLocked=Yes`。未削弱 `.completeFileProtectionUnlessOpen`、未跳過測試；系統解除鎖定旗標後，完整 `swift test --no-parallel` **134 XCTest、861 Swift Testing／98 suites 全數通過**（`/tmp/filicon-routine-edit-full-unlocked.log`），受保護檔案重開及後續索引越界未再出現。兩項 opt-in live Codex 測試未執行；既有 CoreData/XPC 診斷仍存在。不宣稱更早的並行時序問題已修好。

原生驗證：最初 Debug build 與嚴格簽章通過；最終三語言標籤更新後，增量 build 成功但 `codesign --verify --deep --strict` 回報 ko／es／fr 資源與舊 seal 不一致。同一隔離 DerivedData 執行完整 `clean build` 後，**原生 Debug build 及嚴格 deep／strict 簽章皆通過**（`/tmp/filicon-routine-edit-native-clean.log`）。未修改使用者 Xcode 產物或宣稱增量簽章問題已根治；既有 AppIntents／ad-hoc 提示仍在，未執行 release 公證。

本批已在下一輪提交為 `aa29b36`；未 push、未啟動／重啟 App、未更動真實群組／聊天／排程／連線。當時 `AUTO-03` 維持 partial：GitHub／Slack／Teams／generic 條件專用編輯、Teams 可信身分／主文／Graph／同步回覆、GitHub checks 彙整、Slack 名稱／人類身分映射及 live 帳號驗收仍有差異。

## 已提交增量：手動新增 Linear／Sentry／PagerDuty 排程（2026-09-20）

上一批已提交 `4222c64`（`fix: preserve safe retries and revoke stale webhook admissions`），提交前再次通過 87 項／10 suites 聚焦回歸。接著核對本機非官方 reconstructed 參考 `source/host/runner/tools/sand-state-tool.ts` 與現行 `PlatformTriggers.swift`：手動建立表單仍接受任意 Event，預設 issue-updated／issue-created／incident-triggered 與受支援的 canonical case 不一致，且缺少新狀態／週期篩選欄。

- 自動化 → 新增排程：三種平台改用事件選單，Linear 三種、Sentry 六種、PagerDuty 五種選項。預設改為 issueCreated／issueCreated／incidentTriggered，實際傳入的 case 與 ingress 相同，不再讓 arbitrary allowedEvents 自我驗證。
- Linear 明確區分 team/project/new-status/cycle UUID；Sentry 使用精確十進位 project ID；PagerDuty 使用精確且區分大小寫的 service ID。每欄原始清單最多 50 筆、先驗證再去重；UUID 正規化大小寫，但十進位前導零和服務 ID 大小寫保留。空白欄表示不限，逗號空項、未知 case、無效／超限／不適用的篩選拒絕建立，畫面顯示本地化錯誤。Linear 切換事件時保留現有篩選欄，讓使用者清除不相容條件，不暗中放大範圍。
- 依 SwiftUI 技能將驗證留在可測草稿層，事件欄位依狀態呈現；沒有自造 Binding。七語言新增 22 個文字項目；品牌名稱保留 Linear／Sentry／PagerDuty，修正表單內西文／韓文 Trigger 翻譯。說明明示現有驗證入口、ID 不是名稱、空欄不限、週期完成不等於日期到期，以及未來模型費用；不安裝帳號／webhook、不授予工具權限。

依 Swift 測試技能使用固定時間／識別、隔離檔案及受控 executor。新增 `RoutineListenerEditorTests` 八項測試，涵蓋所有選項的真實 HMAC fixture → normalizer → 草稿 matching、精確反例、0/50/51 原始筆數、空項、UUID／數字／opaque ID 邊界、不適用欄位保留、JSON round-trip、儲存／重開／混合 OR 一次執行／重試去重、legacy 定義不被遷移。首次測試確認缺少 132 項非英文翻譯斷言，加入 catalog 後通過；此為新增翻譯的紅燈證據，不宣稱已對舊表單跑完整 red suite。

聚焦回歸 **59 項／6 suites** 通過（`/tmp/filicon-case-editor-focused.log`）。最終完整 `swift test --no-parallel` **134 XCTest、843 Swift Testing／96 suites** 通過（`/tmp/filicon-case-editor-full-final.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build 與 `codesign --verify --deep --strict` 通過（`/tmp/filicon-case-editor-native-final.log`）；既有 CoreData/XPC 診斷及 AppIntents/ad-hoc signing 提示仍在，沒有測試失敗。

NSHostingView 以 440 pt 寬渲染六種表單狀態 × 七語言 × 明暗兩種外觀，共 84 張；包含保留不相容篩選的錯誤態，驗證 fitting size，人工抽查各語言的代表畫面並修正品牌翻譯。產物在 `/tmp/filicon-case-editor-previews/`，不是操作使用者 App 的 live UI 驗收。七語言各 **1,512 keys、零缺漏**，`git diff --check` 通過。

本批已在下一輪提交為 `f874dcd`；未 push、未啟動／重啟使用者 App、未更動真實群組／聊天／排程／連線。`AUTO-03` 維持 partial：當時尚無既有儲存排程的專用手動編輯表單；Teams 可信使用者／主文／Graph／同步回覆、GitHub checks 彙整、Slack 名稱／人類身分映射及實際帳號端到端驗收仍有差異。

## 已提交增量：共用事件入口的安全重試與接收生命週期（2026-09-20）

上一批 Teams 入口修正已提交 `dbd8505`，提交前再次通過 156 項聚焦回歸（`/tmp/filicon-teams-events-precommit.log`）。本批檢查共用 ingress → TriggerHub → EventBatcher 接線，補上入列拒絕、停用／移除路由及 listener 重建時的處理，不擴充外部帳號權限或 Teams 雲端功能。

- sink 明確拒收時，原先已寫入的 nonce 會被安全釋放，HTTP 503 後仍可在簽章有效期間重試；初次 nonce 儲存失敗不呼叫 sink，並回復記憶體。若釋放 nonce 寫入失敗，保留標記並回 500，維持有界防重放。已接受事件即使後續 state／audit 寫入失敗也不釋放，不能誤認為未交付再跑一次。
- 入列交接中的 nonce 不因時間窗到期而被其他請求清掉；接受後從完成時間更新 replay window。保留入列前落盤的保守邊界，但佇列仍在記憶體，崩潰在保留標記與交接之間是未知結果，不自動重播，也不保證 crash-safe／exactly-once／永久去重。
- 金鑰查詢返回後，以當下時間驗證適用的簽章時間戳，並重驗 route revision 和 listener generation。停用、移除、換 provider／secret reference，甚至停用再啟用／移除再加入相同定義，都使舊待處理請求失效；其他路由的修改不受影響。route 儲存失敗回復舊定義。Stop／rebind 也拒收舊 connection 尚未交付的請求、忽略舊 listener callbacks；已開始交接的工作不宣稱撤回。
- 佇列身份採 connector ID＋external event ID，不再讓不同連線同名事件互相擋掉。已驗證且重新簽署、同連線同事件的待處理副本回成功，不再混同容量不足；滿 500 筆時副本仍可確認但不增加筆數。batcher 原有公開 enqueue 回傳「是否新增」的契約保留，由 hub 區分 duplicate 與 full；既有簽章、防重放、流量、payload 限制及 25 筆分批不變。成功回應僅表示入列，不代表排程或模型已完成。

依 Swift 測試技能使用固定時間、精確 fixture IDs、隔離目錄、受控 secret／sink 與 continuation handshake，沒有依靠 sleep 猜測競態。新增 `IngressAdmissionTests` 13 項／21 個參數展開案例，先重現原有 39 個斷言失敗（`/tmp/filicon-ingress-admission-red.log`）。包含初次保留／釋放／audit 儲存失敗、重開、防重播、延遲金鑰與 timestamp 過期、跨時間窗的 pending nonce、八種路由／listener 變更、無關路由、舊 connection、Stop 在 handoff 後的界線，以及真實 hub 滿佇列重試。

原有增量建置產物曾在測試 helper 發生 SIGILL／SIGBUS，堆疊位於變更後的 actor 介面；未以略過測試處理。新建隔離 scratch 目錄 `/tmp/filicon-ingress-admission-build.lShcvK` 完整重建後，28 項／3 suites 聚焦回歸通過（`/tmp/filicon-ingress-admission-clean.log`）；其後包含七種平台與混合事件的並行回歸 **87 項／10 suites 通過**（`/tmp/filicon-ingress-admission-regression.log`），未再出現崩潰。此結果支持舊增量產物相關，不宣稱已根治 SwiftPM 快取問題，也未清除使用者既有建置目錄。

完整 `swift test --no-parallel` 為 **134 XCTest、835 Swift Testing／95 suites 通過**（`/tmp/filicon-ingress-admission-full.log`）；兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build 與 `codesign --verify --deep --strict` 通過（`/tmp/filicon-ingress-admission-native.log`），七語言各 1,490 keys、零缺漏，`git diff --check` 通過。仍有既有 normalizer 的 optional-to-Any 編譯警告、CoreData XPC 診斷與原生 AppIntents／ad-hoc 提示；不宣稱修復所有並行時序問題。本批未變更 UI，未宣稱全產品逐頁語言或 live 平台驗收。

本批已在下一輪提交為 `4222c64`；未 push、未啟動或重啟使用者 App、未更動真實群組／聊天／資料／排程／連線。`AUTO-03` 維持 partial：Teams 可信使用者／主文判定／Graph 接線與同步回覆、GitHub checks 彙整、Slack 身分／名稱映射等仍未完整還原。

## 已提交增量：Teams 傳出事件安全判定與去重（2026-09-20）

上一批 Linear 週期提案已提交 `054d8d3`。此輪核對 reconstructed 的 `sand-state-tool.ts`（Graph team IDs）、`automation-trigger.ts`（登入條件需要 platformMatched；未設文字篩選時排除 rootMessageId 回覆）、`sand-automation-cloud-trigger.ts` 及 `sand-automation-fire-consumer.ts`（雲端已分類的通知與有界欄位）。現有 macOS HMAC 傳出 webhook 不能冒充該雲端服務。

2026-09-20 查閱 Microsoft [outgoing webhook](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-outgoing-webhook)、[TeamInfo](https://learn.microsoft.com/en-us/javascript/api/%40microsoft/agents-hosting-extensions-teams/teaminfo?view=agents-sdk-js-latest) 與 [Activity protocol](https://github.com/microsoft/botframework-sdk/blob/main/specs/botframework-activity/botframework-activity.md)。文件的 HMAC 驗證通訊；aadGroupId 與 Bot team ID 分開；replyToId 為可省略欄位。據此採以下保守適配，並非 live 帳號驗收：

- 不再把簽章、from.aadObjectId 或 payload 的 authenticated/platformMatched 當 Filicon 使用者登入證據。原生入口沒有可信使用者映射，blockUnauthenticatedUsers 為 true 時一律不匹配，舊佇列的 authenticated=true 也不能通過。沒有改寫或放寬既有定義。
- Graph UUID 篩選僅使用 channelData.team.aadGroupId，缺少時不從 Bot ID 或名稱猜測；舊 Bot ID 保留 teamId 精確比對，另存 graphTeamId。租戶／Graph UUID 正規化大小寫，Bot／channel ID 保留原字串。
- 僅分類具有 type=message、channelId=msteams、conversationType=channel 與有效 tenant/team/channel/conversation/sender/activity ID、最多 4,000 字元文字的活動；編輯／刪除／invoke／typing／其他 type、非頻道與缺欄上下文不啟動排程。明確 bot role 排除，但沒有把缺少 role 解讀成已驗證的人類登入。
- reference 空文字篩選只接受主文；原生 replyToId 缺省無法證明主文，也不解析不透明 conversation ID 猜測。目前即使既有條件明確允許未登入者，仍須非空 substring/regex 文字篩選，這類 reference 規則可接受回覆。未加入 Graph 根訊息查詢或全部頻道訂閱。
- HMAC 仍驗證 raw body，接受 base64 或已解碼金鑰，body digest 仍作 ingress nonce。支援訊息的事件 ID 另外 hash tenant/Bot-team/channel/conversation/activity；重新簽章、改 timestamp 或增減可選 Graph metadata 不改身分；不同頻道／對話／活動分開，既有 connector scope 保留。無效或超長 activity ID 拒絕而非截斷。超過 replay cache 後仍由保留的 history 去重，但兩者都過期後並非永久防重放，沒有簽章時間戳證明新鮮度，沒有遷移舊 receipts。

**目前手動 Teams 編輯器仍保留 blockUnauthenticatedUsers 預設 true，因此其中的 Teams 事件條件不會執行。** 畫面已明示此限制，文字欄改標必填；OR 中的其他 listeners／明確 Run Now 不受此事件判定影響。未增加放寬權限開關，Teams 模型 routine create/update 仍拒絕。後續須完成可信身分／主文事件接線及完整核准，不能把這批稱為 Teams 全功能可用。

依 Swift 測試技能，以固定時間、隔離目錄、測試 secret/executor 和 CustomDump 重現錯誤再修正；新增八項 Teams 測試，涵蓋六種非訊息 type、舊登入旗標、Graph/Bot namespace、篩選、缺欄／超限、回覆／未知根、簽章篡改、同 ID 重新送達、重開／cache 過期後 history 去重及預設政策保留。更新舊 fixture，避免其把 HMAC 錯當登入。依 SwiftUI 技能，把提示抽成不含業務邏輯的元件並補兩項 localization／render 測試；七語言、明暗共 14 張、440 點寬預覽，驗證 fitting height，每種語言各人工檢視一張未見截斷（`/tmp/filicon-teams-review.JDWLc0/`）。不是全產品 UI 逐頁驗收。

驗證：156 項 Swift Testing／13 suites 聚焦回歸通過（`/tmp/filicon-teams-events-regression.log`）；`swift test --no-parallel` 完整回歸為 **134 XCTest、822 Swift Testing／94 suites 通過**（`/tmp/filicon-teams-events-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-teams-events-native.log`）與 `codesign --verify --deep --strict` 通過；七語言各 1,490 keys、零缺漏，`git diff --check` 通過。新元件的並行警告已消除；仍有既有 CoreData XPC 診斷及原生 AppIntents metadata／ad-hoc runtime 提示，未宣稱修好先前並行測試時序問題。此為隔離 fixture／原生建置驗證，不是 live Teams 或 release 公證驗收。

本批已在下一輪提交為 `dbd8505`；未 push、未啟動或重啟使用者 App、未改實際聊天／群組／資料／排程／連線。`AUTO-03` 維持 partial，仍缺 Teams 身分映射／主文判定／Graph subscription／模型提案與 outgoing webhook 同步回覆的帳號端到端驗收，以及既有 GitHub checks 彙整、Slack 名稱／人類身分映射等差異。


## 已提交增量：Linear 週期完成的自身排程提案與完整核准（2026-09-20）

上一批已提交為 `ddf7587`。再次核對 reconstructed `sand-state-tool.ts` 的 endOfCycle／cycleIds shape 與 `shared/automations.ts` 三種 Linear cases，接上群組及 mailbox 的自身 routine create/update，可單項或與 cron／GitHub／Slack／Linear issue／Sentry／PagerDuty 組成最多八項平面 OR。這是原生完成事件的受核准提案，不是新增雲端連線或還原原版全部平台語意。

- cycleIds 僅用於 endOfCycle，statusIds 僅用於 statusChanged；原始清單最多 50 個精確 UUID，先驗證再正規化大小寫、排序去重。省略／空清單表示不限。原生 Cycle 無 project 關聯，因此非空 projectIds 拒絕，省略或空清單才可用；不猜測專案、不丟棄指定條件。schema 列出三種互斥 event shape 並說明 project 限制，解析器與核心再次驗證，拒絕 null、未知欄位、錯誤型別、不適用／無效／超限篩選；混合組內任一無效即整份拒絕。
- 沿用固定 owner、完整 before/after 任務／trigger／enabled／時區核准、四次共用變更預算、50 筆容量、durable receipt、原子儲存、Stop／帳號切換／stale／費用防護。模型不能自行解除保護、取得新工具權限或要求立即執行；修改與核准恢復保留歷史，不自動啟用舊資料，legacy cycle entity 不得被模型暗中轉成完成事件。
- 成功回條、runtime 與七語言核准說明明示既有驗證入口、不安裝／啟動連線、completedAt 的明確完成轉換（含提前完成）、日期到期本身不觸發、精確 UUID 和專案限制、有限防重播及佇列事件／模型費用。沒有新增 poller 或手動 cycle 編輯器。

依 Swift 測試技能採固定時間、隔離目錄、受控 provider／核准 gate 與 CustomDump。先重現兩項測試中的 18 個提案／schema 失敗（`/tmp/filicon-cycle-proposal-red.log`），新增 cycle create／恢復與 legacy 保護測試，擴充 0/50/51 UUID 邊界、case 專屬欄位、核心繞過、大小寫與重複收據、歷史保留、取消／拒絕／儲存失敗／費用／容量矩陣。群組為 18 情境 × 四種結果（72 案例），mailbox 為 18 情境並驗證 recipient owner；混合 fixtures 同時含 Linear issue 和 cycle，不讓其中一項被覆蓋。

依 SwiftUI 技能，安全判斷留在 service/parser，畫面只顯示 host 的核准定義。固定 380 點寬度完成 21 情境 × 七語言共 147 張預覽，並驗證 fitting height（`/tmp/filicon-cycle-proposal-review.XV0tRi/`）。實際檢視繁中 cycle update、法文 cycle create、繁中七項混合 OR 預覽，未見截斷；不是全產品逐頁或每張語言圖人工驗收。各語言 1,488 keys、零缺漏。

驗證：146 項 Swift Testing／12 suites 聚焦回歸通過（`/tmp/filicon-cycle-proposal-focused.log`）；明確 `swift test --no-parallel` 完整回歸為 **134 XCTest、812 Swift Testing／93 suites 通過**（`/tmp/filicon-cycle-proposal-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-cycle-proposal-native.log`）、產物 `codesign --verify --deep --strict`、localization audit 及 `git diff --check` 通過。仍有既有 CoreData XPC 診斷及 ad-hoc runtime 提示；未宣稱修復先前並行時序問題，也不是 live Linear 帳號或 release 公證驗收。

本批提案增量已在下一輪提交為 `054d8d3`，提交前再次通過 146 項聚焦回歸（`/tmp/filicon-cycle-proposal-precommit.log`）。未 push、未啟動或重啟使用者 App，未更動真實群組／聊天／排程／連線。`AUTO-03` 維持 partial：平台專用編輯器、原版雲端專案關聯、GitHub checks 彙整、Slack 名稱／人類身分映射等仍有差異，不能將本批稱為「原版都有了」。

參考來源為非官方 `grok-bot-0.18-reconstructed`，不是官方產品原始碼。
此表只涵蓋已讀過來源且對照現行接線的協作功能；未涵蓋功能不能推定完成。

| 行為 | reconstructed 證據 | Filicon 現況與驗證 |
|---|---|---|
| 群組接續、角色、PASS、取消 | `source/host/groups/`、群組 runner | 已接線，`GroupCollaborationTests`；保留三輪／十則上限 |
| 向使用者明確發訊 | `source/host/extensions/transcript/send-message-shaping.ts`、`agents/agent-messaging.ts` 的 SendMessage 區分 | 已接線 `AgentUserMessageTool`：一般群組可發布本輪使用者點名給自己的圖片，mailbox/peer wake 可發布本次 incoming 圖片，均需文字與獨立預覽核准。群組直接原子保存 room reply；mailbox 先保存發布紀錄，再鏡射來源 UI。Stop／失敗／重啟保留已發布內容，最多兩則、final 不重複；不新增回覆者或自動重送圖片給其他模型。不等於完整圖片來源。`AgentUserMessageToolTests`、`AgentBackgroundExecutionTests`、`AgentImageMessagingTests`、`AgentImageAppIntegrationTests` |
| 非同步單一同伴委派、回信喚醒 | `source/host/extensions/transcript/agent-to-agent-messaging.ts` | 已有 `SendToAgent` → durable mailbox → wake → reply wake；新委派顯示完整 payload approval |
| 手動訊息執行 | 同一 inbound wake 機制 | 「代理人 → 訊息」Send 已接上真實 ToolLoop，不再只存信；頁面不必保持選取；審批、資料夾選擇、取消都沿用 host 路徑 |
| 上下文跨次請求／重開 | `resolveBackgroundSession`、agent transcript store | **部分**：account/origin/agent 隔離的 30 則 peer 上下文與穩定 inference ID 已落盤；另有逐次審批的 account/agent 持久事實（見 memory 列），不隨 origin 隔離。不是原版橫跨所有 DM／群組的統一私人上下文或完整長期背景 session |
| 每 agent 統一 exclusive lane | `runLifecycle.enqueueExclusiveRun(session.id, …)` | 已接上 App 內共用 `AgentExecutionScheduler`：群組回合、跨來源 mailbox、子任務、自動化、工作流程、頻道回覆共用每 agent 一般工作 FIFO（優先訊息例外見下列）；不同 agent 可並行。`AgentExecutionSchedulerTests` 與 `AgentBackgroundExecutionTests` 驗證排隊、取消、逾時與主要 App 入口。**不是完整原版 runtime**：未綁定 agent profile 的一般單獨聊天仍只按 conversation 排程；不包含跨程序協調或重啟排程重播；有限優先中斷見下列 |
| 群組目標／broadcast | `source/host/extensions/transcript/shared-rooms.ts` 的 `postToGroup`；`agents/agent-messaging.ts` directory | **已接線受限文字版**：群組／mailbox 的 `SendToAgent` 接受自己所屬、所有成員均啟用中的其他群組 UUID。完整成員、群組與文字審批後原子貼入共用房間，再讓其他成員用既有群組 runner 回覆；不是逐人私訊。來源對話私人上下文不轉貼，工具仍沿用來源核准範圍與新 run ID。每次最多兩個不同群組／六次總委派，群組各保留三輪／十則上限與每回合 180 秒期限。**與參考的差異**：忙碌群組拒絕而非排入其 active lane；目前房間使用 SendMessage；發起者不因自己的貼文再自動喚醒；不含跨所有房間的統一私人記憶。`AgentGroupMessagingTests`、`AgentGroupMessagingAppTests` |
| 圖片訊息 | `loadAgentInboundImages`／`selectedImages`、`agents/agent-messaging.ts` 的 images；`shared-rooms.ts` 的四張限制與 `send-pipeline.ts` 的選圖路徑 | **已接線受限版本**：代理人 → 訊息及一般群組輸入均可手動選擇 PNG/JPEG，實際位元組傳入支援看圖的收件模型。群組預覽揭露保存／模型收件範圍，依本輪使用者 @mention 選擇成員；全部指定模型通過驗證才貼文，失敗保留草稿。`SendToAgent(images:[id])` 只能轉交本次收到的 peer 圖片，或 host 指定且使用者本輪點名給自己的群組圖片；每次顯示收件人、文字與圖片重新預覽核准，回信及同群組成員也不豁免。`SendMessage` 可將這些圖片另行審批後發布到來源對話，群組核准卡揭露房間與完整成員，不擴大模型收件者。拒絕任意路徑、網址、base64 與其他訊息的 ID。最多四張／單張 5 MB／合計 12 MB，存為雜湊驗證的獨立 blobs。**尚缺**：參考的 file/HTTPS 圖片來源、模型新產生的圖片、歷史圖片自動重播。`SendToAgent` 群組目標附圖仍明確拒絕；不支援看圖的模型明確失敗，不默默丟棄圖片。`AgentImageMessagingTests`、`AgentImageAppIntegrationTests`、`GroupImageAppTests`；本輪群組發布的驗證狀態見文末 |
| 優先訊息中斷非使用者工作 | `steerRecipientForPriorityPeer`，先檢查 active lane != user | **已接線受限版本**：單一 peer 的 `priority:true` 每次須核准（回信也不豁免），manual Priority 也接上排程。來源回合結束並 drain 後，可取消收件者正在執行的背景 peer／委派群組回覆／排程自動化，等 host 工具清理完才啟動優先工作。排隊中的使用者工作及較早優先訊息不被插隊；前景群組、手動 mailbox 首回合、手動 Run Now、channel／workflow／subtask 均受保護。不自動重播被中斷工作；群組 priority 拒絕。**差異**：不是參考的 enqueue 當下立即中斷，保護範圍更保守。`AgentExecutionSchedulerTests`、`AgentMessagingSessionTests`、`AgentBackgroundExecutionTests` |
| 模型建立／編輯代理人 | `source/host/agents/agent-messaging.ts`: CreateAgent、UpdateAgent | **已接線受限版本**：群組、手動 mailbox 與 peer wake 提供 `CreateAgent(name, description?)`／`UpdateAgent(agent_id, name?, description?)`。每次完整顯示變更並明確核准；每個來源請求共用四次上限。新代理人沿用發起者 provider/model，description 成為公開摘要與初始指令；Update 只合併名稱與公開摘要，不修改私人指令。`AgentManagementSessionTests`、`AgentManagementAppIntegrationTests`。不替未綁定 agent 的一般 DM 加上管理權限 |
| 模型修改自身公開資料 | `source/host/runner/tools/sand-state-tool.ts` 的 `update_state` profile/set；`source/host/extensions/memory/agent-state.ts` 的 `updateProfile` | **已接線受限版本**：`update_state(target:"profile", action:"set", name?, description?)`。身分由 host 固定；不得傳入別人的 ID。可明確清空公開 description，省略欄位保留原值；私人 persona 不變。每次仍需使用者核准，與 CreateAgent／UpdateAgent、memory、avatar 及 routine 變更共用四次上限。下一個群組回合重新載入 profile，原請求參與成員不擴大。memory／avatar 支援範圍見其他列；routine 支援下列有限 create/update/pause/resume/delete；workflow 已補下列受限 write/delete；settings 已補下列受限通知開關；側欄顯示／channel／project 路由仍缺 |
| 模型修改自身通知設定 | `sand-state-tool.ts` 的 settings/set；`agent-state.ts` 的 updateSettings | **已接線受限版本**：只接受 `target:settings,action:set,notify_on_updates:boolean`，host 固定自身 ID。逐次明確 before/after 核准，與其他修改共用四次上限；專用持久化 revision 防 ABA 與舊 editor 覆蓋，Stop／帳號切換同步撤銷。UI Agents → Edit 可手動開關並儲存。僅控制 agent roster 完成／等待輸入系統通知，不關對話通知、核准卡、未讀／Dock，也不影響任務與權限；舊資料預設開啟、不補送通知，macOS delivery 權限仍必要。本機共用 profile，非 account-scoped。**未還原 hidden_from_sidebar**；其他欄位／混合提案一律拒絕，不混用封存。不是跨程序 CAS。 |
| 模型建立／改寫／刪除自身工作流程 | `sand-state-tool.ts` 的 workflow/write/delete；`agent-state.ts` 的 writeWorkflow/deleteWorkflow | **已接線受限版本**：own local manual single-prompt 的 create/full rewrite，名稱／說明／全文必填，body 最多 8 KiB 以下的 8,000 UTF-8 bytes；逐次全文核准、共享引用影響揭露、同 store revision／取消防護。無來源且經使用者指派 owner 的匯入副本視為本機定義；來源連結／learning／peer／多步驟／action／scheduled 拒絕。儲存不執行、不授予權限；delete 另走同樣 own/local/manual/single-prompt 上限、精確 ID 與獨立 destructive 核准，保留 run history 與已取得內容的執行，不連帶刪除其他流程／排程／檔案；引用可能失敗或省略內容。其他 workflow 操作仍未全面還原，不能視為帳號隔離記憶。 |
| 模型修改自身頭像 | `source/host/runner/tools/sand-state-tool.ts` 的 avatar set/clear；`source/host/extensions/memory/agent-state.ts` 的 setAvatar/clearAvatar | **部分接線，來源不同**：群組／mailbox 可呼叫 `update_state(target:"avatar", action:"set", pet_id:...)` 選九種內建小寵物，或 `action:"clear"`（不得附 pet_id）恢復 Codex。每次顯示新頭像與原頭像類型並核准；只可改 host 固定的自身 ID。與 profile／memory 共用四次上限，Stop／帳號切換撤銷、核准期間頭像被改則拒絕舊提案；只合併頭像，不覆蓋其他欄位、不刪舊圖片檔案。**未還原參考的任意 host/box path 圖片安裝**，不接受路徑、URL、base64 或模型生成圖；不能視為完整 avatar parity。`AgentAvatarChangeTests`、`AgentManagementAppIntegrationTests` |
| 明確保存／忘記自身事實 | `source/host/runner/tools/sand-state-tool.ts` 的 memory write/forget；`source/host/extensions/memory/agent-state.ts` 的 memory shards | **已接線受限版本**：群組／mailbox 的 `update_state(target:"memory", action:"write"或"forget", fact:...)` 預設為私人 `scope:"agent"`，共享 scope 見下一列。write 的 tier 接受 profile／log／note（預設 log），forget 使用記錄原文且不得傳 tier。帳號＋代理人由 host 固定，跨 origin、重啟後同一代理人的 group/mailbox runtime 會取得已核准事實，其他代理人／帳號不注入私人事實。每次增刪都顯示全文並核准；UI「代理人 → 編輯 → 代理人記憶」可重新整理、檢視及確認忘記。每事實 1,000 字元；每帳號／代理人 48 項（含最多 8 項 profile）、合計 12,000 字元；不自動淘汰。**尚缺**：project scope、DM／自動化等其他入口統一記憶、完整私人歷史 session。不是自動捕捉整段聊天。`AgentMemoryTests`、`AgentManagementAppIntegrationTests` |
| 共享使用者事實 | `memory-service.ts` 的 `SharedUserMemoryStore`、`sand-memory.ts` 的 `renderUserMemorySystemPrompt`／`mergeUserMemoryShards`；`agent-state.ts` 的 user shard | **已接線受限版本**：同一工具明確指定 `scope:"user"` 後，逐次核准共享給帳號內所有現有／未來代理人的 group/mailbox 模型，含群組外代理人。省略 scope 或舊紀錄缺少 scope 一律維持 private agent。保留紀錄者 UUID、tier／日期／scope 來源；模型只能忘記自己的同 scope 原文；UI 可管理所有作者的共享紀錄。共享 account 全部作者合計 48 項、8 項 profile、12,000 字元，與私人額度分開，不自動淘汰。**差異**：寫入仍按同 scope 精確文字全體去重，召回另按大小寫／空白摺疊並保留較新原文、tier 與作者；有重要性排名與獨立預算，詳見下一列。project scope 仍拒絕，其他執行入口仍未注入，沒有自動抓取整段聊天。`AgentMemoryTests`、`AgentManagementAppIntegrationTests` |

### 自身 routine 建立／修改／暫停／恢復／刪除

已核對 reconstructed `source/host/runner/tools/sand-state-tool.ts` 的 `routine.create/update/pause/resume/delete` 分派與 `extensions/memory/agent-state.ts` 的自身排程操作。Filicon 的 group/mailbox 透過 `update_state(target:"routine", action:"pause"、"resume"或"delete", id:...)` 操作自身既有排程；這三個 action 只接受 target/action/id，不得夾帶定義欄位。目錄只列 host 固定 owner 的 ID／名稱／啟用／費用防護狀態，不列其他代理人的任務。每次展示 ID、完整任務與 trigger JSON 並重新核准，auto-review allow 不豁免，與 profile／memory／avatar 共用四次額度。

同一入口另支援有限 `action:"create"`／`"update"`：create 需 name／prompt，以及 schedule 或 trigger（不可同時指定），enabled 可省略且預設 true，ID 及 owner 由 host 產生；update 需自己的 id 及至少一個變更欄位，省略欄位保留。name 最多 80 字元、prompt 32,000、schedule 256，每 owner 最多 50 項。時間排程支援 cron／alias／`@every`（1 分鐘至 366 天）；新 schedule 固定當次 App 時區，可由有效 TZ/CRON_TZ 前綴覆蓋；舊時間定義缺少時區時，須提供 schedule 才能明確固定時區。

單個 GitHub 事件條件：`{type:"github",repo:"owner/repo",events:[...],userAllowlist?:[...],ciBranch?:...}`。repository 須具體、events 須為既有 14 種已知名稱、使用者最多 50 位；未知欄位／事件／錯誤類型／空篩選項／不合法分支會被拒絕，不默默丟掉限制。空 userAllowlist 代表不限對象；PR opened/pushed/merged/comment/inline-comment 篩選 PR 作者，review requested/approved/changes-requested/commented/thread-resolved/thread-unresolved 要求作者與操作人都在清單內，issue-assigned 篩選操作人。CI 不受使用者清單限制，必須指定一個有效分支；目前僅為該 repository 的個別 push workflow_run 完成（success／failure／timed_out），**不是原版所有 checks settled 的彙整或 PR CI**。時間、GitHub、Slack 與下述混合 OR 組合可經完整核准互換；其他平台、generic event 與任意 trigger JSON 仍拒絕。既有已驗證事件連線必須另行設定，此工具不安裝／啟動 webhook、不登入外部服務；核准後待處理事件可能符合新定義。

Slack 事件寫入支援單一 `{type:"slack",channel:"C/G/D 對話 ID 或 *",match:{kind:...}}`，kind 為 message／mention／keyword／reaction；keyword 最多 120 字元，reaction 最多 8 個表情短名稱，清單省略或留空代表所有表情。channel 最多 80 字元且只接受具體 ID 或 `*`；`*` 涵蓋所有已設定連線實際送達的對話，不授予額外 Slack 存取權。mention 是 App／bot 被提及，mention/reaction 需既有已驗證的事件入口；既有 channel 訊息路徑仍支援 message/keyword，沿用 connector 的過濾方式，未保留 event subtype，因此不宣稱與 webhook 分類等同。已驗證 webhook 僅普通使用者訊息及對訊息新增的表情觸發；bot／subtype／編輯／刪除訊息、撤回表情與檔案表情不觸發。不支援原版的 `#channel`／`@人名` 解析與 `bySelf:true`：目前無可靠的使用者身分對應，因此明確拒絕，不把機器人身分當成使用者。未知／混用／null 欄位及無效篩選會在核准前拒絕；預覽顯示完整正規化條件與範圍限制。

單個 Linear 事件條件使用 `{type:"linear",event:{case:"issueCreated"或"statusChanged",statusIds?:[...]},teamIds?:[...],projectIds?:[...]}`；statusIds 只能用於 statusChanged，篩選改變後的新狀態。每份清單最多 50 個精確 UUID，省略／空清單表示不限；核准前統一 UUID 大小寫、排序、去重。名稱、endOfCycle／cycleIds、未知欄位、null、錯誤型別與無效 ID 皆拒絕，不會忽略篩選而擴大觸發。須既有驗證入口，核准不安裝連線、不增加工具或權限。獨立 Linear 型別沿用 primaryIDs（團隊）／secondaryIDs（專案）的舊儲存欄位；舊資料缺少 statusIDs 仍可載入，不自動轉換或啟用。

另支援時間／事件 OR 組合：`trigger:{type:"group",listeners:[...]}` 或裸 `trigger:[...]`，原始輸入限 1–8 個 cron／GitHub／Slack／Linear 條件且不得巢狀。時間條件使用 `{type:"cron",schedule:"..."}`，也可單獨使用或組成純時間群組。每個時間條件在核准前固定 App 時區或有效 TZ/CRON_TZ 覆蓋；模型提案的每項時間條件皆須在 366 天內有下一次執行，間隔限 1 分鐘至 366 天。所有條件先驗證，任一無效就拒絕整份提案，不丟棄限制；正規化後排序、去除完全相同條件，只剩一項則儲存為單一 trigger。任一條件命中同一任務即能觸發，不要求全部成立；同筆事件命中多條只納入一次，不同事件仍可能造成後續執行及費用。每條各自的頻道／repo／作者／操作人／CI 分支／Linear 團隊、專案與新狀態篩選維持不變，未命中內容不送入 prompt。去重包含 connector ID 及事件 ID、批次 key 使用長度分隔，防止跨平台 ID 碰撞和分隔符別名；已處理的送達紀錄在重新載入後仍去重。預覽顯示完整 OR 定義以及所有涉及平台的限制，不增加外部連線或權限。模型入口仍拒絕 generic event、其他平台及巢狀組合，不可同時指定 top-level schedule 與 trigger。時間條件取最早下次執行，同時命中只執行一次、不補跑；所有條件共用最近執行基準，因此事件與手動執行也會重設 interval 計時。完整新舊核准畫面以七語言揭露時區固定、間隔重設及額外執行費用；不是手動混合條件編輯器。

建立／修改完整核准卡顯示新定義與 enabled；修改另展示舊 name／完整 prompt／trigger／enabled。新增／改排時間從核准提交後算，不補跑等待期間錯過的次數、不立即 Run Now；只改 name/prompt 保留現有 nextRun。提交時重新驗證容量、時程、費用防護及定義，沿用儲存額度與同步 lifetime fence；原子候選儲存成功才發布，durable receipt 區分寫入成功與後續 bookkeeping 失敗。修改只合併核准定義並保留最新 lastRun／history，已開始或排隊的 executor 保留舊任務。費用防護生效時拒絕啟用的新定義，受防護排程不得修改；可建立停用草稿，不因此解除任何防護。

暫停只禁止後續觸發，不取消已開始或已交給 executor 排隊的執行。恢復保留定義／歷史，按目前時間重新計算下一次觸發，不呼叫 Run Now、不補跑錯過的時間。費用防護暫停與未知 trigger（含巢狀）拒絕由此工具恢復，須由使用者到自動化頁檢視。核准後再次驗證 owner、revision、名稱／prompt／trigger／啟用及 guard 狀態；既有執行更新的 history／lastRun 不被舊 snapshot 蓋掉。儲存 candidate 成功後才改記憶體，寫檔失敗不得偷偷啟用工作。同步 lifetime 撤銷 fence 與 session receipt 沿用既有管理工具的語意。

刪除先展示無法復原的警告，核准 action 標為 destructive。原子移除定義及其費用防護 ID，不改其他排程、防護政策、執行歷史、wake 或 claims；寫檔失敗時記憶體不變。已開始／已交給 executor 排隊的執行不取消，完成後仍寫入歷史，不會把定義加回；尚未 dispatch 的 cron／事件批次重查定義後跳過已刪項目。執行歷史留在儲存空間，但現有 UI 不提供已刪排程的歷史入口，也沒有還原命令。不刪產出檔案、不斷開外部服務。可刪除停用／費用防護／未知 trigger 的定義，但不能藉此解除其他任務的防護。

這是 **部分還原**：除上述有限 GitHub／Slack／Linear 外，Linear endOfCycle／cycleIds、參考的其他 event/platform、Slack 名稱解析／自身身分篩選、GitHub checks 彙整及連動工作流程審查仍未接線（UI 既有操作不受影響）；Filicon 對每種 routine 變更都要求明確核准，也沒有因本項替自動化推論加上 host 工具。不是完整原版 automation runtime。

### 記憶召回規則

`AgentMemoryRecall` 在 scope/account 過濾後才去重及排序，私人、共享、基礎事實、近期事實四個池分開處理。profile 優先保留較新項目；近期 log/note 採參考 `sand-memory.ts` 的相對排名 `log2(importance) + createdAt / 30 天`，note 的 importance 為 0.5、log 為 1。這是排序，不是 30 天到期或刪除。相同大小寫／空白正規化文字只在同池摺疊，保留較新原文與作者；不自動覆寫或解決語意矛盾。

私人 profile/recent 的 JSON UTF-8 預算為 8,000/4,000 bytes，共享為 4,000/2,000 bytes，含作者、日期、scope、canForget、跳脫字元及陣列分隔；件數上限各為 8/30、8/15。過大的單項完整省略、嘗試下一項，不截斷事實。這比參考按文字長度、首項可超額的規則更嚴格。所有省略項仍落盤及計入儲存上限，編輯頁列出全部；runtime 回報省略數並提示到編輯頁檢視，不憑空承諾可 grep 私人資料目錄。`note` 以明確 enum 儲存，不用可偽造的文字前綴辨識；參考的自動 extraction／episode／freeze／搜尋回填尚未實作。`AgentMemoryRecallTests`、`AgentMemoryTests`、`AgentManagementAppIntegrationTests` 覆蓋此有限版本。

## 安全差異

- 頭像工具只引用隨 App 提供的小寵物 ID；不讀取任意檔案、不呼叫外部影像服務。host 綁定 owner 與 previous avatar，逐次完整預覽核准，auto-review allow 不豁免。儲存與撤銷在同一同步臨界區，原子寫入失敗回復；session 內的已提交 receipt 避免後續 quota bookkeeping 失敗引發重複修改（不是跨重啟的呼叫去重）。恢復 Codex 不刪除原自訂圖片。名稱／指令／模型被其他操作更新時保留最新值，不以整份舊 profile 覆寫。
- 群組圖片轉交的目錄由 host 綁定 group/user message/member ID，不接受模型指定來源訊息；只限最近一次使用者請求且確實被該輪指定的成員，未被點名、其他房間、歷史／未綁定的執行不得取得圖片 handles。核准返回後重新檢查來源與 bytes；一般 auto-review allow 不略過圖片核准。委派房間回合不繼承來源房間圖片；peer 只收到核准的任務文字與圖片，不複製群組私人上下文。
- 群組直接附圖只接受 host 匯入並驗證的 PNG/JPEG；bytes 綁定本次已成功貼出的 user message ID 與 metadata，不從歷史重新載入。後續文字回合只帶歷史圖片數量，delegated wake 不重播舊 user 圖片；own-agent 暫存上下文也移除附件 handles。圖片在群組內保存不代表後續自動送給所有模型。preflight 等待期間 Stop／帳號切換／成員變更拒絕舊送出；訊息超過 8,000 字直接拒絕，不截掉尾端 @mention 後擴大收件範圍。貼文寫入失敗回復記憶體並保留輸入。選圖草稿按群組隔離、切換帳號清除；不自動刪除已匯入 blobs。
- 記憶是使用者逐項核准的背景資料，不是 system persona、授權或動作完成證據。模型取得 JSON 事實時有 data-only 警示，但這不是防 prompt injection 的保證；真正的工具核准仍由 host 控制。模型不得傳 agent/account ID、混入 profile 欄位或寫入未知 state scope。私人事實不自動傳入其他代理人或複製到 clone；明確 scope user 的核准資訊揭露群組外及未來代理人也會取得共享事實（含新 clone 的群組／mailbox 回合），不另外複製紀錄。忘記只停止未來注入，不清除已送出的對話或執行中的模型上下文。
- 記憶 Stop／帳號切換使用同步撤銷 fence；儲存及 receipt 在同一 actor turn 完成，寫檔失敗回復原狀。忘記重新檢查完整 record identity／帳號／代理人／事實／tier，避免舊提案刪掉新紀錄，不以 JSON 往返的 Date 浮點微差當作內容變更。封存後模型不能新增事實，使用者仍可移除舊事實；滿額不自動刪除任何舊記憶。
- `SendMessage(images:[id])` 只接受本次 incoming peer 或 host 綁定當輪群組請求 metadata 的精確 ID，不掃描檔案或使用歷史圖片；每次完整顯示文字與圖片預覽，auto-review allow 不豁免。群組核准揭露完整房間 audience，保存前重新檢查當輪來源、metadata、成員、epoch 與同步撤銷 fence；寫檔失敗回復記憶體。發布與 peer forwarding 是兩個不同目的、不同核准，不會自動回傳給同伴或新增回覆者。
- mailbox 發布紀錄由 host 固定來源／作者，最多兩則且共用文字額度；儲存失敗不回報成功。Stop／帳號切換在首次 await 前撤銷發布權；保存成功後來源 UI 鏡射失敗則標示 turn 失敗、保留 canonical 紀錄，不邀請模型重發。尚無重啟後自動修補失敗鏡射的機制；紀錄可在「代理人 → 訊息」查看。
- 委派不是新的檔案／程序／外部服務授權。所有實際工具仍用來源 conversation scope 與新的 run ID。
- 持久上下文不儲存可重放的 permission receipts、system persona 或工具執行 token。
- 已停止、已切換帳號或重啟後的未完訊息不會自動重新執行；重啟保留紀錄並標示取消。恢復未知副作用的工作仍須新的使用者請求。
- 各代理人的 persona 及不同 account/origin 上下文不會互相複製。
- 圖片選擇只複製使用者指定的 PNG/JPEG，拒絕直接 symlink、無效格式、動畫與超過尺寸／容量上限的輸入；原始路徑不進 mailbox。每次發送／審批前後重新驗證 SHA-256 與 bytes，損壞即失敗。模型只能引用本次 host-bound incoming 的圖片 ID，不能靠猜中儲存中的雜湊取得其他圖片。圖片內容與檔名是未信任資料，不授予工具權限。
- 部分 provider 要求圖片放在 user-role content block；host 以明確標示「來自另一個 assistant、不是新使用者指令」的 data-only transport 傳遞，實際 peer 任務仍是 assistant role。這不是模型抗 prompt injection 的保證；權限仍由 host 核准控制。mailbox 保留圖片 metadata，歷史推論上下文不自動重載圖片 bytes。圖片存放 `agent-message-images/`，不共用普通聊天附件 GC；目前移除草稿圖片只取消發送，已匯入 blobs 不會自動清除，仍需後續補保留期／清理介面。
- 群組貼文只有 host 固定的發起者可署名；每次都需顯示完整收件成員及文字並核准，不套用單一 peer 回信的免重複核准。送出前重查成員、群組名稱及公開資料；期間有變更就拒絕舊提案。貼文與取消的同步 fence 共用臨界區，儲存失敗會回復記憶體狀態。
- 其他群組的背景回合只以收到的 assistant 訊息作為任務，不把該房間的舊 user 指令重新當成新授權，也不把房間歷史複製進來源 mailbox。回覆留在目標房間。來源與目標房間均能操作同一來源範圍的審批；從目標按 Stop 會取消整個來源委派鏈。已成功貼出的訊息保留，未完成的工作不會於重啟後自動重播。目標房間的保留狀態直到執行／清理結束才釋放，避免取消時撞上新的使用者回合。
- 排隊不消耗 mailbox 的執行逾時；取得 agent 執行權後才開始計時。一般取消只取消該次提交；明確核准的優先訊息才可中斷同一收件代理人的背景工作，不取消其他代理人或使用者回合。取消、帳號切換及重啟均不會重播優先訊息；優先權不授予檔案或外部服務權限。
- host ToolLoop 會等已開始的本機工具清理完成才釋放執行權，並拒絕回合結束後的延遲工具 callback。這不保證外部模型服務立即終止；不合作的 runtime 仍會保留執行權，不強行放行下一項副作用。
- 帳號切換會取消已排入的 agent 工作，並呼叫執行中子任務的停止 hook；排隊中的子任務不會呼叫 runtime interrupt。頻道回覆取得執行權後重新檢查帳號世代、連線及 agent 狀態。
- 模型不能用 profile tools 刪除／封存代理人、變更群組成員、讀取私人指令或更改權限。建立代理人不會自動執行；後續 `SendToAgent` 要另行核准。一般 auto-review allow 規則不跳過這些核准。
- UpdateAgent／update_state 審批期間若公開名稱／摘要被其他操作改動，拒絕舊提案；若只有私人指令、模型、頭像或狀態被修改，保留最新值；已封存的代理人拒絕寫入。此處比 reconstructed 合併 description/persona 的設計更窄，不能視為完整 persona 編輯。
- Stop／帳號切換在第一次 await 前撤銷 profile 寫入權；AgentService 在同一 actor turn 中檢查撤銷、原子儲存與發布，儲存失敗會回復記憶體狀態。成功儲存留有 session receipt，後續 bookkeeping 失敗不會讓重試再新增一名代理人。這不是跨帳號、跨重啟的持久操作去重。

## 驗證範圍

使用可控制的 provider 驅動真實 AppModel、ToolLoop、持久化與審批，包含真實本機 fixture 寫檔；不使用使用者的專案檔案、不連線付費／live 模型、不重啟使用者的 App。
七語言 UI render 是版面檢查，不是宣稱七語言完整產品逐頁驗收。
上一輪（`324d62e`）測試報告：134 XCTest、561 Swift Testing，零失敗；兩個需主動啟用的 live Codex 測試未執行。
原生 `Filicon App` Debug build 與嚴格簽章驗證通過。七語言各 1,393 keys，缺漏為零。
新增測試也確認：已發出的進度在後續失敗或停止後仍保留，不被終止狀態清掉。
中途一次完整重跑曾卡在既有檔案鎖測試的子程序清理；隔離執行及最後完整重跑均通過，未宣稱該偶發測試問題已根治。
完整產品 parity 仍未完成，原矩陣的歷史 release／test 結果不得替代此核對。

### 後續排程驗證（2026-09-18）

新增每 agent 執行排程後，最終完整測試為 134 XCTest、575 Swift Testing，零失敗；兩個 opt-in live Codex 測試仍未執行。原生 `Filicon App` Debug build、`codesign --verify --deep --strict`、七語言 1,393 keys 零缺漏均通過。未重啟使用者的 App，未測試真實外部頻道或付費模型。

完整重跑也發現並修正：CLI 取消測試在 runner 尚未啟動前就取消的競態；MCP 審批舊 expiry task 可能影響重用 ID 的新請求（加入每次請求 token 並正確處理計時器取消）；既有檔案鎖測試在子程序已退出後仍卡住的 `waitUntilExit()`（取樣確認後改為非阻塞退出通知）。這些問題未以略過測試處理，最後兩次完整重跑均通過。

### Profile tools 驗證（2026-09-18）

新增的四個 App 整合測試（包含參數化拒絕／Stop／帳號切換、群組／手動 mailbox、七語言 render）與八個 session 測試均已通過。先前兩個重開資料測試被 macOS 鎖定畫面的檔案保護擋住；解鎖後也修正測試中即時 Date 經 JSON 往返的浮點精度差異，改以注入固定時間驗證，沒有降低檔案保護。最終完整套件為 134 XCTest、587 Swift Testing，零失敗；兩個 opt-in live Codex 測試仍未啟用。原生 Debug build 與嚴格簽章驗證通過；七語言各 1,395 keys，零缺漏。未 push、未重啟使用者的 App。

### Own-profile 驗證（2026-09-18）

上一批 profile tools 已提交為 `1fb956f`。本批補上上述狹義 profile/set 路由：session 測試涵蓋 host 身分、防冒用、未知路由、空白摘要、欄位保留、舊提案、封存、拒絕、撤銷、重播及三種工具共用額度。App 整合測試實際走群組／mailbox 的 ToolLoop 與審批，確認下一個群組回合讀到新公開資料，沒有改動群組成員；mailbox 的 self 是收件代理人，不是寄件者。一般 auto-review allow 也仍顯示核准要求。

完整套件為 134 XCTest、595 Swift Testing，零失敗；兩個 opt-in live Codex 測試仍未啟用。原生 `Filicon App` Debug build 與 `codesign --verify --deep --strict` 通過。七語言各 1,397 keys，零缺漏；清空摘要的審批元件產出七語言 PNG，繁中與法文已目視檢查。這不是完整產品逐頁驗收，也未呼叫真實外部服務或付費模型。未 push、未重啟使用者的 App。

### 群組目標驗證（2026-09-18）

上一批 own-profile 已提交為 `ffe5447`。本批新增八個 routing 測試與七個 App 整合測試，包含參數化的拒絕、停止、帳號切換、成員／群組名稱變更與封存；也覆蓋原子儲存失敗回復、精確重播、共用額度、PASS、不支援欄位、未知／非成員群組、延後喚醒、忙碌群組不被打斷，以及群組／手動 mailbox 來源的實際回覆路徑。目標群組的資料修改仍在來源 scope 出現核准；從目標按 Stop 可取消這些待核准操作。測試使用可控制的 provider 和獨立暫存資料，沒有操作使用者的真實群組或專案。

最終完整套件為 134 XCTest、610 Swift Testing，零失敗（兩個 opt-in live Codex 測試未啟用）。原生 `Filicon App` Debug build、嚴格 deep codesign 驗證、`git diff --check` 通過；這是本機 Debug 驗證，不是 release 公證／上架驗證。七語言各 1,400 keys，零缺漏；群組 audience 核准元件產出七語言 PNG，繁中及法文已目視檢查，並非整個產品逐頁驗收。未 push、未重啟使用者的 App。其餘差異與未完成項目仍依上表列為部分／尚缺。

### 優先訊息驗證（2026-09-18）

上一批群組目標已提交為 `7d81e51`。本批補有限優先中斷：測試涵蓋背景清理後交棒、前景與排隊使用者回合受保護、優先佇列順序、不同 agent 隔離、已取消請求不插隊、真實 ToolLoop 工具清理、優先回信另行核准、持久 priority 與排序、去重／重播、防格式混淆、群組拒絕 priority。AppModel 整合測試確認一般 auto-review allow 不跳過優先核准，拒絕或停止待核准提案不影響既有背景工作；手動 Priority 接線與使用者 mailbox 首回合保護也通過。

依測試技能使用可控制的 gate 驗證競態，未用真實模型或使用者資料。最終完整套件為 134 XCTest、619 Swift Testing，零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign 與 `git diff --check` 通過。七語言各 1,402 keys，零缺漏；優先訊息提示產出七語言 PNG，繁中與法文已目視確認換行完整。仍不是整個產品逐頁或 release 公證驗收。未 push、未重啟使用者的 App。圖片傳遞、跨對話統一私人記憶、其他 update_state 路由等仍未完成；完整產品 parity 不能宣稱已達成。

### Peer 圖片訊息驗證（2026-09-18）

上一批優先訊息已提交為 `ee76056`。本批提供上表所述的受限圖片傳遞，並修正 `SendMessage` 過去會忽略不支援欄位的問題，避免回報成功卻漏掉圖片。依 SwiftUI 技能將預覽呈現與載入分開；切換帳號會清除草稿圖片並重新載入預覽，選檔視窗也綁定開啟時的帳號。

依測試技能使用可控制的 provider、獨立暫存圖片與 CustomDump 比對實際推論 bytes、持久 metadata、審批內容與排程結果。新增測試涵蓋 PNG/JPEG、偽裝副檔名、無效／超大檔案、symlink／遠端 URL、重複／總量限制、MIME 與雜湊不符、不支援圖片的模型、舊資料解碼、重啟不重播、host-bound current-image allowlist、群組拒絕、SendMessage 明確拒絕、完整 ToolLoop 重複 call ID 拒絕，以及核准／拒絕／Stop／帳號切換／審批後圖片被竄改。圖片回信也必須重新核准，auto-review allow 不豁免。歷史推論不會偷偷重新傳送舊圖片。

最終完整套件為 134 XCTest、629 Swift Testing（81 suites），零失敗；兩個 opt-in live Codex 測試仍未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign 與 `git diff --check` 通過。七語言各 1,413 keys、零缺漏；實際圖片預覽／揭露元件產出七語言 PNG，繁中與法文已目視檢查。這不是完整產品逐頁驗收或真實模型端到端驗證，也不是 release 公證。未 push、未重啟使用者的 App；本批圖片修改已在下一輪提交為 `16d0fa1`。剩餘範圍仍以上表的部分／尚缺為準。

### SendMessage 圖片發布驗證（2026-09-18）

上一批 peer 圖片已提交為 `16d0fa1`。本批將 `SendMessage` 擴為受限圖片發布：只有這次 incoming 圖片的 ID 能被引用，host 決定作者與來源對話。每次重新預覽核准，不繼承 peer forwarding 或 auto-review allow 的授權；一般群組上下文仍提供文字版 schema。mailbox 的 `publications` 保存完整文字與圖片 metadata，舊資料缺少此欄位仍可讀取；來源房間鏡射與 mailbox 都可呈現圖片。canonical 保存後不因鏡射或後續推論失敗邀請重發，已發布內容也不被 Stop、terminal response 或重啟清空。未實作失敗鏡射的自動重建。

依 SwiftUI 技能重用圖片預覽與獨立回覆區塊，依測試技能以 CustomDump 比對持久內容，使用受控 provider 與隔離暫存資料。新增測試涵蓋當次 ID allowlist、拒絕 URL／歷史 ID／重複圖片、缺少 authorizer 預設拒絕、重播與更改 payload 拒絕、文字／圖片共用兩則額度、來源及作者防冒用、原子儲存失敗回復、同步撤銷、舊資料解碼、重啟保留、鏡射失敗仍保存、final 不重複。AppModel 實際核准流程涵蓋核准、拒絕、Stop、帳號切換、核准期間 bytes 損壞、發布後 Stop 及重啟載入圖片，並確認沒有意外喚醒同伴。

最終完整套件為 134 XCTest、636 Swift Testing（81 suites），零失敗；兩個 opt-in live Codex 測試仍未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign 與 `git diff --check` 通過。七語言各 1,416 keys、零缺漏；圖片發布預覽／標籤版面產出七語言 PNG，繁中與法文已目視檢查。這是隔離 fixture 與元件版面驗證，不是完整產品逐頁、真實模型端到端或 release 公證驗收。未 push、未重啟使用者的 App；本批發布修改已在下一輪提交為 `4548163`。任意 file/HTTPS 或新生成的圖片、一般群組圖片輸入、歷史圖片重播與其餘原版 runtime 差異仍未完成。

### Own-agent memory 驗證（2026-09-18）

上一批圖片發布已提交為 `4548163`。本批新增上表的有限自身事實記憶，所有 write/forget 逐次核准，auto-review allow 不豁免；一般群組及 mailbox/peer wake 使用同一 account/agent 所屬事實，不合併私人對話全文。身分與 account 不接受模型指定；scope 只允許 agent、tier 只允許 profile/log。編輯頁可檢視、重新整理及確認忘記，不需要模型配合。未新增獨立自動捕捉／摘要服務，也未聲稱共享 user/project 記憶或完整 runtime 已還原。

依 SwiftUI 技能將非同步載入／按鈕動作抽成具名方法；依測試技能注入固定時間、使用可控制的 gate 和隔離 fixture，以 CustomDump 比對持久結果。新增九個記憶測試與四個 App 整合測試（含參數化案例），涵蓋跨來源／重啟載入、帳號／代理人隔離、clone 不複製、非法欄位／未知 scope、profile 共用額度、滿額不淘汰、拒絕／Stop／帳號切換、等待中的 commit 撤銷、核准後 stale／封存檢查、原子儲存失敗回復及成功 receipt。App 測試實際走群組／mailbox ToolLoop 與核准，驗證 mailbox 記憶屬於收件代理人。跨重啟 UI 刪除測試抓到 Date JSON 浮點往返被誤判 stale，已修正為 record identity＋內容比對；替換成新 ID 的相同文字仍拒絕舊提案，刪除寫檔失敗仍保留原記憶。

最終完整套件為 134 XCTest、649 Swift Testing（82 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign 與 `git diff --check` 通過。七語言各 1,431 keys、零缺漏；真實審批元件產出七語言 PNG，繁中與法文已目視檢查。這不是完整產品逐頁驗收、live 模型驗證或 release 公證。未 push、未重啟使用者的 App；本批記憶修改已在下一輪提交為 `33a3d2a`。其餘缺項仍以上表與 parity 矩陣為準。

### Shared user memory 驗證（2026-09-18）

上一批私人記憶已提交為 `33a3d2a`。本輪依 reconstructed 的「各作者單獨寫入，共同讀取」設計新增受核准的 scope user；不擴大既有私人記憶的使用範圍。SwiftUI 將私人／共享區塊分開，共享區顯示記錄者，刪除確認提示會影響所有代理人；審批畫面揭露 current/future、群組外代理人及其配置的模型。scope 也是去重 fingerprint 與精確刪除 fence 的一部分，改 scope 的舊 call ID 不能重播成共享；帳號切換、Stop、每來源四次額度與原子儲存沿用原有 fence。

以受控 provider 和獨立暫存資料新增／擴充：共享全文及 audience 核准、拒絕／Stop／帳號切換、延遲 commit 撤銷、其他代理人不能刪別人的 shard、私人／共享同文字分開、跨作者共享額度、持久化失敗 rollback、相同文字的競態去重、舊紀錄缺少 scope 維持私人、未知 scope 解碼失敗，以及跨群組／mailbox／重開／clone／帳號隔離及使用者從編輯頁忘記他人共享紀錄。七語言私人／共享審批元件可 render，繁中與法文已目視檢查。

中途本機鎖定時，macOS `.completeFileProtectionUnlessOpen` 阻擋重新讀取 fixture `agents.json`（Cocoa 257／POSIX 1），影響 6 個跨重啟測試；解鎖後重新執行全部 24 個記憶／App 整合測試均通過。未降低檔案保護，未永久略過這些測試。

最終完整套件為 134 XCTest、653 Swift Testing（82 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,440 keys 零缺漏及 `git diff --check` 通過。依 SwiftUI 技能把私人與共享記憶分成獨立區塊，依測試技能使用固定時間、可控制的 gate 與 CustomDump 驗證實際持久結果。這不是完整產品逐頁、live 模型或 release 公證驗證。未 push、未重啟使用者的 App，共享記憶修改已在下一輪提交為 `d891ad3`。

### Note 與預算召回驗證（2026-09-18）

上一批共享記憶已提交為 `d891ad3`。本輪補上上述 note 與召回規則，未擴大共享、檔案或工具權限。依 SwiftUI 技能共用 tier 標籤，並在核准卡與記憶編輯區清楚揭露「僅送出排序後部分事實、省略不刪除」；新增 note 後也修正管理清單排序，避免 log/note 互相比較時破壞一致的排序關係。

依測試技能用固定日期與 UUID、可控制的 provider/gate 及 CustomDump 驗證：重要性／日期／穩定次序、前綴不可冒充 tier、去重前先隔離帳號與代理人、保留來源及精確原文、私人／共享與 profile/recent 分池、UTF-8／跳脫／metadata 預算、過大單項不截斷也不阻塞小項、核准前不儲存、Stop／帳號切換／延後 commit 撤銷、call ID 不可偷偷改 tier、重啟後 note 保留與 exact-text forget。App 整合測試確認實際群組與 mailbox 收到有界集合，省略的 note 仍能從編輯頁刪除且跨重啟生效。七語言 profile/note × private/shared 核准元件均 render，繁中與法文已目視檢查。

30 個定向測試通過；最終完整套件 134 XCTest、659 Swift Testing（83 suites），零失敗，兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,443 keys 零缺漏及 `git diff --check` 通過。測試只用隔離 fixture，未呼叫付費模型、未重啟 App、未 push。這不是完整產品逐頁或 release 公證驗證；本批已在下一輪提交為 `aaeadcd`。project 記憶、所有入口統一 runtime、自動 extraction／archive search 等差異仍保留為未完成。

### 群組直接附圖驗證（2026-09-19）

上一批記憶召回已提交為 `aaeadcd`。本輪群組 composer 增加選圖、緊湊預覽、移除及收件範圍說明；支援無文字的圖片訊息。先驗證全部指定成員模型，再保存 user message；bytes 綁定本次 message ID、metadata 與原先選定成員 ID，即使後續名字／路由改動，也不能擴大圖片收件對象。不把一般群組圖片加入 peer 圖片轉發或 SendMessage 發布的 allowlist。

依 SwiftUI 技能拆分純預覽呈現與非同步載入、使用群組專屬草稿；依測試技能以受控 provider/gate、獨立暫存 PNG 及 CustomDump 檢查實際請求。新增 10 項測試（含參數化案例），涵蓋圖片 bytes、image-only、單人 @mention／全員、持久預覽、後續回合／delegated wake／own-agent context 不重播、不支援圖片／未知成員／過長文字／重複／遺失／損毀輸入、保存失敗 rollback、草稿隔離、Stop／帳號切換／成員變更及錯誤 request/recipient binding。七語言附圖區產出 PNG，繁中與法文已目視確認圖片、文案及按鈕未裁切。

最終完整套件 134 XCTest、669 Swift Testing（84 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,445 keys 零缺漏及 `git diff --check` 通過。未呼叫真實／付費模型、未 push、未重啟使用者的 App。這不是完整產品逐頁或 release 公證驗收。本批群組附圖修改已在下一輪提交為 `4cf98a4`；當時生成圖片、任意 file/HTTPS 載入、一般群組圖片再轉發／發布、歷史圖片重播及匯入 blobs 的保留期清理仍未補齊。

### 群組圖片轉交驗證（2026-09-19）

上一批群組附圖已提交為 `4cf98a4`。本輪補群組 responder → 單一 peer 的 current-request 圖片 ID 路由，沿用既有收件人／全文／圖片預覽核准、真實 bytes 傳送及 mailbox 持久化。不增加群組目標附圖或直接群組 SendMessage 圖片發布，也不增加任意檔案／網址讀取權。圖片不可用的錯誤訊息同步調整為七語言的「本次請求」。

依測試技能以隔離暫存圖片、受控 provider 及 CustomDump 新增來源綁定、過期／外房間／未點名／未綁定／歷史圖片拒絕、核准後來源變更、去重及 App 真實 ToolLoop 核准／拒絕／Stop／帳號／成員變更／圖片損壞／持久化案例。核准前不喚醒收件模型；群組內未被點名的成員與群組外單一代理人都需另行核准，收到的是精確圖片 bytes 與核准文字，不複製來源房間上下文。重啟後 mailbox 與群組圖片仍可載入。

初次執行遇到 macOS 螢幕鎖定（`CGSSessionScreenIsLocked=Yes`），受保護 fixture blobs 的讀寫回傳 Cocoa 257／513、POSIX 1，既有圖片測試也同樣失敗。使用者解鎖後，29 項圖片定向測試（含參數化案例）與完整套件均重新通過；未降低檔案保護或略過相關案例。

最終完整套件為 134 XCTest、672 Swift Testing（84 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、包含新增案例的 `swift build --build-tests`、七語言各 1,445 keys 零缺漏及 `git diff --check` 通過。本輪沿用已存在的圖片核准 UI，未增加新的畫面；這不是完整產品逐頁或真實付費模型驗收。本批已在下一輪提交為 `42fe95d`；未 push、未重啟使用者的 App。

### 群組附圖回覆驗證（2026-09-19）

上一批圖片轉交已提交為 `42fe95d`。本輪讓一般群組 responder 的 `SendMessage` 使用本次已提供給自己的圖片，逐次預覽核准後保存附圖回覆。來源 user message、group、作者與同步撤銷 lifetime 都由 host 綁定，不接受模型指定；原有文字 responder 透過相容橋接保持行為。已保存的回覆不因後續推論失敗、Stop 或重啟而消失，final 不重複。這不是群組目標圖片 broadcast、新生成圖片或歷史圖片自動重播。

依 SwiftUI 技能重用 audience 與圖片預覽元件，分開說明「在此群組保存回覆」及「委派其他群組、喚醒成員」，避免核准文案誤導。依測試技能使用隔離圖片、受控 provider 和 CustomDump 驗證實際 bytes、來源綁定、metadata、持久化與取消；新增案例涵蓋核准／拒絕／Stop／帳號切換／成員變更、舊請求與外來圖片拒絕、缺少 authorizer 預設拒絕、核准後 bytes 損壞、同步撤銷、原子儲存失敗 rollback、發布後推論失敗與停止、重啟圖片仍可讀，以及不意外喚醒未點名成員。七語言核准元件產出 PNG，繁中與法文已目視確認換行及預覽完整。

54 項定向測試通過；最終完整套件為 134 XCTest、676 Swift Testing（84 suites），零失敗，兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,446 keys 零缺漏及 `git diff --check` 通過。本批在下一輪提交為 `1bd9e0a`；未 push、未重啟使用者的 App、未呼叫付費模型。這不是完整產品逐頁、真實模型端到端或 release 公證驗收，剩餘原版差異仍以上表為準。

### 自身頭像變更驗證（2026-09-19）

上一批群組附圖回覆已提交為 `1bd9e0a`。重新讀取 reconstructed 的 `shared-rooms.ts:postToGroup` 後確認：該入口只接受文字與 priority，並未接圖片；不能把 shared-room 鏡射的圖片功能誤認為跨群組 SendToAgent 圖片委派。故未擴加這條圖片路由，改補已確認的 `update_state` avatar set/clear，來源限 Filicon 現有九種內建小寵物，與參考的任意 host/box 圖片路徑安裝仍有差異。

依 SwiftUI 技能將頭像核准卡獨立呈現，顯示發起者、新頭像、舊小寵物或「自訂／預設」類型，以及不影響其他欄位／不刪圖的說明。依測試技能用固定 fixture 時間、可控制的 gate、隔離暫存資料及 CustomDump 驗證核准前不寫入、九種小寵物、恢復 Codex、拒絕外來 ID／路徑／URL／錯誤欄位、預設拒絕、共用四次預算、call ID 重播／變更 payload、來源 scope、Stop／帳號切換／延後 commit 撤銷、頭像 stale／封存、其他 profile 欄位保留、儲存失敗 rollback、已提交 receipt、重啟保存及不刪自訂圖片。App 整合覆蓋群組及手動 mailbox，後者只改收件代理人。初次測試發現測試 peer 未固定時間導致 JSON Date 浮點往返比較不穩，已改為固定日期並完整重跑；未放寬正式程式的檢查。

53 項定向測試通過；最終完整套件為 134 XCTest、686 Swift Testing（85 suites），零失敗，兩個 opt-in live Codex 測試未啟用。完整執行中帳號測試曾輸出 CoreData NSXPCConnection 診斷，相關測試仍通過，這不等同已驗證真實帳號服務。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,453 keys 零缺漏及 `git diff --check` 通過；set/clear 核准卡產出七語言 PNG，繁中 set 與法文 clear 已目視檢查。此為隔離 fixture 與元件驗證，不是完整產品逐頁、live 模型或 release 公證驗收。本批在下一輪提交為 `2fb6528`；未 push、未重啟使用者的 App。

### 自身 routine 暫停／恢復驗證（2026-09-19）

上一批自身頭像已提交為 `2fb6528`。本批新增上述有限 routine pause/resume；依 SwiftUI 技能分離純核准畫面，依 SPM 技能讓 AppServices 依賴既有 Automations 模組，不新增外部套件。排程批次等待前一工作時，舊 snapshot 可能仍啟動剛被暫停的下一工作；已在每次自動觸發前重查 enabled/revision，手動 Run Now 語意不變。

依測試技能使用固定時間、可控制的 gate、隔離暫存資料及 CustomDump 驗證：核准前不變更、own-only 目錄及身分、pause/resume 精確重播與共用四次預算、拒絕無效 action／欄位／外來 ID、預設拒絕、Stop／帳號切換／延後 commit 撤銷、核准期間編輯／刪除／封存、定義 stale、執行歷史保留、寫檔失敗 rollback、成功 receipt、跨重啟，以及不得越過 spend guard 或巢狀未知 trigger。App 真實 ToolLoop 測試包括 group／mailbox，mailbox 只能改收件者的排程；超過 2,000 字摘要上限的完整任務仍在核准 metadata 保留。排程與事件批次的暫停競態也有獨立測試。

最初更新 schema 時調整了原先將 routine 一律視為未知路由的舊測試；mailbox fixture 也改為依真實 ToolLoop 的 throw 語意檢查拒絕，而不是把失敗當 NormalizedToolResult。中途 macOS 螢幕鎖定（CGSSessionScreenIsLocked=Yes）導致受保護 agents.json 回傳 Cocoa 257／POSIX 1，影響既有重啟載入測試；未降低檔案保護。偵測解鎖後完整重跑通過。

19 項定向測試（含參數化案例）通過；最終完整套件 134 XCTest、696 Swift Testing（86 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 Filicon App Debug build、嚴格 deep codesign、七語言各 1,462 keys 零缺漏與 git diff --check 通過；pause/resume 核准卡產出七語言 PNG，繁中 pause 與法文 resume 已目視確認。這不是完整產品逐頁、真實／付費模型或 release 公證驗收。本批在下一輪提交為 `88b84c1`；未 push、未重啟使用者的 App。

### 自身 routine 刪除驗證（2026-09-19）

上一批暫停／恢復已提交為 `88b84c1`。本批接上 reconstructed `routine.delete` 的自身排程入口，沿用完整核准、四次預算、同步 lifetime fence 與 durable receipt；不修改使用者實際排程。核准新增穩定 ID 及 destructive 風險，七語言明示無法復原。定義比對另包含 createdAt，避免刪除後用相同 ID 重建的另一份定義被舊核准刪掉。原子候選寫入同時清除該排程的 spend-guard ID，其他防護不變。

依 SwiftUI skill 將標題／警告集中為純畫面屬性；依測試 skill 使用隔離 fixture、固定觸發時間、可控制的 executor gate 與 CustomDump 完整差異，測試啟用／停用／費用防護／未知觸發的刪除、外來 owner 拒絕、預設拒絕、group／mailbox 明確核准、auto-review 不豁免、Stop／帳號切換／延後 commit 撤銷、核准期間編輯／刪除／同 ID 重建／owner 封存、寫檔失敗 rollback、共用四次上限與 receipt 重播。另驗證 cron／事件批次跳過已刪排程、刪除時仍在執行的工作正常收尾且不重建定義、歷史／wake 保留及重啟後仍無定義。沒有自動還原或已刪排程歷史 UI。

首輪新增跨重啟的完整 equality 揭露 Date 經 Unix 毫秒 JSON round-trip 的浮點精度差；測試的預期值改用實際儲存編碼精度，保留全部欄位比對，未改 production 儲存或忽略日期。重跑 38 項定向測試通過；完整套件 134 XCTest、699 Swift Testing（86 suites）零失敗，兩個 opt-in live Codex 測試仍未啟用。原生 Filicon App Debug build、嚴格 deep codesign、七語言各 1,465 keys 零缺漏及 git diff --check 通過；pause/resume/delete 核准卡均有七語言 PNG，繁中與法文 delete 已目視確認。

這是隔離 fixture／元件測試，不是全產品逐頁、live 模型或 release 公證驗收；當時 routine create/update 模型入口仍缺。本批已提交為 `d651e4a`；未 push、未啟動或重啟使用者的 App。

### 自身時間排程建立／修改驗證（2026-09-19）

上一批刪除已提交為 `d651e4a`，本輪開始時工作目錄乾淨。重新核對 reconstructed 的 routine create/update 後，補上上述有限時間排程入口，不延伸 event/platform/combined trigger、工作流程寫入或未經核准的模型行為。依 SwiftUI skill 讓核准卡分別展示完整「目前排程／提議的排程」與費用、未補跑及未授予工具權限的說明；七語言 pause/resume/delete/create/update 均產出 PNG，繁中 update 與法文 create 已目視確認無裁切。這是元件檢查，不是全產品逐頁驗收。

依測試 skill 使用固定時間／ID、隔離暫存資料、可控制的 provider/executor gate 及 CustomDump，比對核准前不寫入、host owner/ID、預設 enabled、App 時區與明確 TZ 覆蓋、UTF-8 長任務、省略欄位保留、核准後才算 nextRun、name/prompt-only 保留原時間、執行中仍用舊任務而新定義與歷史不被完成回報覆寫。另覆蓋錯誤欄位／類型／null／外來 ID、interval 範圍、預設拒絕、容量、費用防護、event 不被偷偷轉換、拒絕／Stop／帳號切換／owner 封存／延後 commit、核准期間定義變更、寫檔失敗 rollback、durable receipt、共用四次預算及精確 call 重播。App 真實 ToolLoop 包含群組及 mailbox；mailbox 的 owner 是收件代理人，auto-review allow 不跳過完整核准。

首輪新增測試有 `try`／async autoclosure 編譯問題，修正後又找到測試重用已完成 call ID，改成獨立 ID 以實際驗證 event-trigger 拒絕，未放寬 production 重播防護。47 項定向測試先通過，再補上預設拒絕及執行中修改案例；最終完整套件 134 XCTest、710 Swift Testing（86 suites）零失敗，兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,473 keys 零缺漏及 `git diff --check` 通過。

本批已在下一輪提交為 `6f5e9fc`；未 push、未操作使用者的實際排程或聊天、未重啟 App、未呼叫付費模型。這不是 live 模型、外部服務或 release 公證驗收；完整 reconstructed parity 仍未完成，當時非時間觸發的模型寫入與其他 runtime／memory／state 路由差異繼續保留為未完成。

### 自身 GitHub 事件排程建立／修改驗證（2026-09-19）

上一批時間排程已提交為 `6f5e9fc`。本輪重新讀取 reconstructed `sand-state-tool.ts`、`automation-trigger.ts`，接上前述有限 GitHub create/update，不擴充其他平台、複合觸發條件或隱式工具權限。依 SwiftUI 技能沿用獨立核准元件，展示完整新舊定義；新增七語言說明既有連線、待處理事件、作者／操作人篩選與 CI 非彙整限制。GitHub create/update 皆產出七語言 PNG，繁中 update、法文 create 已目視確認全文與篩選條件無裁切；這只是元件驗證，不是全產品逐頁驗收。

核對 [GitHub webhook 事件文件](https://docs.github.com/en/webhooks/webhook-events-and-payloads) 與 [Actions 觸發文件](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows) 後，修正 normalize：PR synchronize／review_requested、review-thread resolved/unresolved；一般 branch push 不再冒充 PR pushed，一般 issue 留言不再冒充 PR comment，未知 review state 不作 commented。CI 僅接受同 repository、push 觸發、completed 的 workflow_run；success 對應 passed，failure/timed_out 對應 failed，取消／略過／未知結論及 PR/fork workflow 不觸發。尚未做原版 checks 彙整，文件、schema、runtime、工具結果及核准皆明示差異。

另修正 PR 作者與操作人篩選，並在每個 routine 分批前篩除不匹配事件，避免只因同批有一筆符合條件，就把其他 repo／使用者的 payload 一起送給模型。核准測試發現 GitHub events 的 Set 編碼順序不固定，已讓編碼排序，保留既有 Codable 欄位格式及讀取相容性。

依測試技能使用隔離暫存資料、受控 provider／gate、固定時間與 CustomDump，新增 GitHub 定義正規化、完整核准、14 種事件篩選、嚴格拒絕無效／未知／混用欄位、時間↔GitHub 轉換、省略觸發條件保留、歷史與重啟、call 重播、共用四次預算、容量、預設拒絕、外來 owner、費用防護核准前後重查、stale／封存／寫檔失敗、Stop／延後 commit 撤銷。App 真實 ToolLoop 覆蓋群組與 mailbox 的核准／拒絕／停止／帳號切換；mailbox 只能更動收件人的排程。事件測試使用 fixture HMAC 經 controller → normalizer → matcher → executor → history，拒絕無效簽章與重播，沒有開啟 HTTP listener、呼叫 GitHub 或付費模型。

65 項定向測試（含參數化案例）通過；最終完整套件為 134 XCTest、720 Swift Testing（87 suites）零失敗，兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,475 keys 零缺漏與 `git diff --check` 通過。這不是外部服務端到端或 release 公證驗收。

完整套件中的帳號測試仍有 CoreData NSXPCConnection 診斷但測試通過；原生 build 有「未依賴 AppIntents，因此略過 metadata extraction」警告，未出現編譯錯誤。不將這些結果視為真實帳號連線或 AppIntents 整合已驗證。

本批 GitHub 事件修改已在下一輪提交為 `129d804`；未 push、未重啟 App、未變更使用者實際群組或排程。完整 reconstructed parity 仍未完成；其他事件平台、複合觸發、CI checks 彙整、工作流程審查與既有 runtime／memory／state 差異仍保留待補。

### 自身 Slack 事件排程建立／修改驗證（2026-09-19）

上一批 GitHub 事件排程已提交為 `129d804`。本輪重新核對 reconstructed 的 `sand-state-tool.ts`、`automation-trigger.ts`，接上上述有限 Slack create/update；不擴充其他平台或複合觸發，不授予工具或登入外部服務。原版的頻道／人名解析與自身表情篩選仍未完成，因此明確拒絕，不以 bot 身分代替使用者。表情短名稱可去冒號、轉小寫、排序去重；未知／無效項目及 `::suffix` 不可靜默丟棄或放寬。

依 [Slack reaction_added](https://docs.slack.dev/reference/events/reaction_added/)、[message](https://docs.slack.dev/reference/events/message/) 與 [app_mention](https://docs.slack.dev/reference/events/app_mention/) 官方格式，修正表情事件從 `item.channel` 取得對話，actor 使用 `user` 而非原訊息的 `item_user`。驗證事件入口只接受普通使用者 message/app_mention 與對 message 的 reaction_added；removed/file reaction、bot／subtype／hidden／編輯／刪除／未知事件不得落入 wildcard message。簽章內容中的自訂 `is_self` 不作身分依據。既有 channel polling 仍沿用 connector 過濾，沒有 event subtype，不宣稱與 webhook 分類相同；既有無 marker 的 normalized event 相容性保留。

依 SwiftUI 技能維持核准畫面與寫入邏輯分離，展示完整 before/after、正規化條件、既有連線、`*` 範圍、App 提及、空表情清單、身分限制與費用。create/update 七語言皆產出 PNG，繁中 update 與法文 create 已目視確認無裁切；這是元件檢查，不是整個產品逐頁驗收。

依測試技能使用隔離暫存資料、受控 provider/gate、固定邏輯時間與 CustomDump。涵蓋四種 match、C/G/D/*、80/120 字元及 8 個表情的上下界、省略及空清單、預設 enabled、完整核准、未知／null／錯誤型別／混用欄位拒絕、時間↔GitHub↔Slack 轉換、省略保留、歷史與重啟、call 重播、四次額度、容量、owner、費用防護前後重查、stale／封存／寫檔失敗、Stop／延後 commit，以及 App 群組／mailbox 的拒絕與帳號切換。fixture HMAC 經 ingress controller → normalizer → matcher → executor → history，驗證簽章與重播，未開啟 Slack listener 或連線 Slack、未呼叫付費模型。完整套件原有 loopback listener fixture 不受影響。

74 項定向測試（含參數化案例）曾通過；最後完整套件為 134 XCTest、729 Swift Testing（88 suites），零失敗，兩個 opt-in live Codex 測試未啟用。回歸時補強既有 ingress fixture，改成以 Bool 驗證 JSON 布林值，避免 NSNumber 描述為 1 而誤比對字串 true。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,477 keys 零缺漏及 `git diff --check` 通過。驗證沒有使用正式 Slack 帳號或付費模型，不是外部服務端到端或 release 公證驗收；Debug ad-hoc build 仍有未依賴 AppIntents 而略過 metadata extraction 的既有警告。 帳號測試仍輸出既有 CoreData NSXPCConnection 診斷但測試通過；不視為真實帳號連線已驗證。

本批 Slack 修改已在下一輪提交為 `6fb3d04`；未 push、未重啟 App、未變更使用者實際群組、聊天或排程。完整 reconstructed parity 仍未完成：其他平台／複合 trigger、Slack 名稱與人類身分映射／輪詢事件分類、GitHub checks 彙整、工作流程審查及既有 runtime／memory／state 差異仍待補。

## 本輪增量：GitHub／Slack 純事件 OR 組合（2026-09-19，完整回歸待解鎖）

上一批已提交為 `6fb3d04`。再次核對 reconstructed `sand-state-tool.ts`、`automation-trigger.ts` 的 group／array／任一命中設計；本輪只接上已支援的 GitHub／Slack 組合，保留完整核准、費用防護、身份及帳號邊界。參考允許 cron 與事件混用，而 Filicon 既有 `.anyOf` 不計算 nextRunAt，因此本輪明確拒絕，不將此限制說成完整 parity。

測試先重現跨連線相同 externalEventID 被誤當已執行（第二次少一筆 run），再修正 execution claim 為 connector＋delivery ID，並加上長度分隔防批次 ID 混淆。事件不因多個條件命中而重複納入；各平台的原有過濾與 ingress 認證流程保留。

已驗證：

- 聚焦 59 項 Swift Testing／6 suites 通過（包含參數化 cases）：OR 建立／修改與時間、單事件互換、完整新舊預覽、重播正規化、1／8 項邊界、惡意／未知／混合／巢狀欄位、直接提交繞路、停止與核准之間／提交之間撤銷、拒絕、切換帳號、sender／recipient 隔離、費用防護、容量、儲存失敗及 durable receipt；以及 matcher、批次隔離、事件持久化去重、pause/resume/delete。`/tmp/filicon-event-group-verified.log`。
- 七語言均 1479 keys、0 missing。核准元件產出 create/update 七語言 PNG，繁中 update 與法文 create 已目視確認全文、OR 說明及雙平台警告無裁切；不是全產品逐頁驗收。`/tmp/filicon-event-group-review/`。
- 原生 `Filicon App` Debug 建置成功，產物 `codesign --verify --deep --strict` 通過；未啟動產物。`/tmp/filicon-event-group-native.log`。
- `git diff --check` 通過。沒有付費模型、實際 Slack/GitHub 帳號或外部 webhook 的驗證，只有隔離 fixtures。

完整回歸尚未完成：較廣的 `AgentManagementAppIntegrationTests` 在受保護 `agents.json` 重新讀取時收到 `NSCocoaErrorDomain 257 / NSPOSIXErrorDomain 1`；獨立重跑頭像持久化測試也失敗，IORegistry 顯示 `CGSSessionScreenIsLocked=Yes`。既有檔案使用 `.completeFileProtectionUnlessOpen`，未為過關而削弱保護。已請使用者解鎖，解鎖後須重跑完整套件才可宣稱全部通過。紀錄：`/tmp/filicon-event-group-targeted.log`、`/tmp/filicon-event-group-reload-check.log`。新功能的聚焦通過不代替完整回歸。

本批 OR 修改已在下一輪提交為 `c642048`；提交前再次通過 59 項聚焦測試（`/tmp/filicon-event-group-precommit.log`）。未 push、未重啟 App，未更動實際群組、聊天或排程。

## 本輪增量：混合時間／事件排程引擎基礎（2026-09-19，完整回歸待解鎖）

上一批已提交為 `c642048`。核對 reconstructed `source/host/automations/automation-store.ts` 的 `earliestNextRunAt`／`recordRunWith`，及 `source/shared/automation-schedule.ts` 的 `computeNextRunAt`／`automationAnchor` 後，補上內部平面 `.anyOf` 的時間分支。這輪刻意不開放模型建立／修改混合條件，不改 schema、工具說明或核准 UI；這些仍是下一階段缺項，不能宣稱已達完整原版 parity。

行為與安全邊界：

- 各 cron／interval 成員計算後取最早時間；同時命中或錯過多個時段只執行一次，不補跑。時區與 TZ/CRON_TZ 前綴沿用既有排程器。每個任務只有一個最近執行基準，包含事件及手動執行；因此事件也會重設 `@every` 的等待時間，並非每個 listener 獨立計時。
- 某個合法 calendar 條件在既有 366 天搜尋範圍內無下次時間（如遠期閏日），不阻止其他 OR 成員；所有時間成員都無下一次時間時為 nil。不擴大搜尋範圍；單一 cron 原本的 no-run error 行為保留。無效語法／時區不默默忽略，停用時也拒絕無效時區。巢狀及超過 8 項仍拒絕。
- 複合條件包含未知 trigger 時不新增時間排程，既有事件匹配語義不變。重新載入舊的 `nextRunAt=nil` 定義不自動啟用時間分支或遷移使用者設定；只有明確 save／enable 或正常執行後重新計算。
- 執行批次等待其他任務時，如果該任務已被事件或手動執行更新了 nextRun，舊的到期 snapshot 不得再執行；除 revision 外重新比對 nextRunAt。暫停／費用防護同時阻擋時間與事件，使用者恢復後從恢復時刻安排，不立即執行。
- 一般 save、setEnabled、開始執行時，先算時間並原子儲存 candidate，成功後才發布記憶體狀態、run claim 與 busy 狀態。排程計算／寫檔失敗不留下幽靈定義或卡住 scheduled retry。此處不是事件送達重試佇列改造；既有 ingress/event 去重與忙碌時處理方式未擴充。

依測試技能使用固定邏輯時間、隔離暫存資料及 executor gate，不等真實排程也不呼叫模型。先以新增測試重現 `.anyOf` 沒有 nextRun、停用定義未檢查時區、寫檔失敗發布狀態與消耗 claim（`/tmp/filicon-mixed-schedule-red.log`）。修正後新增 13 項測試，涵蓋最早時間／同時命中、逾期合併、事件及手動基準、跨時區與 DST、明確 TZ 覆蓋、閏日搜尋邊界、純事件／未知條件、舊資料不自動啟用、reload、pause/resume、費用防護、暫停中模型不可解除防護、stale batch、語法／時區／巢狀／容量、create/update/enable/fire 寫檔失敗及排程計算失敗回滾。

最終聚焦回歸為 78 項 Swift Testing／8 suites 通過（含參數化 cases），包含既有 cron、ingress、GitHub／Slack／OR、routine 審批、群組／mailbox 核准與拒絕／停止及七語言預覽測試。紀錄 `/tmp/filicon-mixed-schedule-regression.log`。原生 `Filicon App` Debug build（`/tmp/filicon-mixed-schedule-native.log`）、產物嚴格 deep codesign 及 `git diff --check` 通過；只建置，未啟動產物。無新 UI 文案；本輪沒有新增視覺驗收。

IORegistry 仍回報 `CGSSessionScreenIsLocked=Yes`，上一批完整回歸受 `.completeFileProtectionUnlessOpen` 檔案重新讀取限制仍未解除；本輪不重複把已知受鎖定影響的全套測試當作成功，未削弱檔案保護。解鎖後仍須重跑完整套件。這不是 live 模型、外部事件服務或 release 公證驗收。

本批引擎修改已在下一輪提交為 `6882ba4`；提交前再次通過 78 項聚焦測試（`/tmp/filicon-mixed-schedule-precommit.log`）。未 push、未重啟 App，未更動實際群組、聊天或排程。

## 本輪增量：模型混合時間／事件提案與完整核准（2026-09-19，完整回歸待解鎖）

上一批已提交為 `6882ba4`。再次核對 reconstructed `source/host/automations/automation-trigger.ts` 與 `source/host/runner/tools/sand-state-tool.ts` 的 cron member、flat group／array 與 schedule／trigger 互斥格式，接上群組／mailbox 的混合條件建立、修改及核准。沒有增加其他平台或外部連線。

- `trigger:{type:"cron",schedule:"..."}` 可單獨使用，或與 GitHub／Slack 放入 1–8 項 group／裸陣列，也支援純時間組合。時間字串正規化空白，所有成員驗證後排序、精確去重，單項折疊；相同 call 的重排／重複成員不造成第二次寫入。未知欄位、null、錯誤型別、巢狀、超量、其他平台及同時傳入 top-level schedule／trigger 仍整份拒絕，不忽略無效條件。
- 每個時間條件在核准前固定當次 App 時區，可由有效 TZ/CRON_TZ 前綴覆蓋；模型不能另外夾帶 timeZoneIdentifier 或 member-level enabled/prompt。模型提案每項時間條件皆須在 366 天內可執行，間隔限 1 分鐘至 366 天；停用提案同樣驗證。這比內部引擎容許 dormant calendar 分支更嚴格，不宣稱兩層限制相同。
- 核准顯示完整新舊任務、trigger JSON、enabled 與每個時區；七語言新增最早時間、同時命中一次、不補跑、事件／手動執行重設間隔及可能增加模型費用的說明。不是每個條件獨立計時，也不是新增手動混合條件編輯器。
- 新增／重新排程從核准提交時安排，不立即 Run Now。只改名稱／prompt 保留最新 nextRun、lastRun 及歷史；核准等待中發生事件執行，也不被舊 snapshot 覆蓋。可與純時間、單一事件及事件組合互換。owner、四次共用額度、50 項容量、費用防護、fresh approval、Stop／帳號切換、stale 及原子儲存／durable receipt 邊界保留。

依測試技能使用隔離暫存資料、固定時間、受控 provider／executor 及 CustomDump；依 SwiftUI 技能將條件判斷保留在既有資料與核准層，呈現可換行的完整說明。驗證包括 interval 兩端邊界、TZ／CRON_TZ、1／8 項、重排與去重、最早 nextRun、開／關建立、事件執行與修改競合、history/reload，以及群組／mailbox 拒絕、Stop、帳號切換、owner、費用防護、容量、寫檔失敗與持久 receipt。測試曾因 fixture 使用錯誤 Slack payload key `reactionEmoji` 失敗，已改成 normalizer/matcher 實際使用的 `reaction`，未放寬產品過濾器。

最終驗證：

- 85 項 Swift Testing／8 suites 通過（包含參數化 cases），紀錄 `/tmp/filicon-mixed-routine-verified.log`。
- 七語言各 1,480 keys、零缺漏。核准元件 create/update mixed 均產出七語言 PNG；繁中 update 及法文 create 已目視確認完整條件與所有警告沒有裁切。預覽位置 `/tmp/filicon-mixed-routine-review/`；這是核准元件檢查，不是全產品逐頁驗收。
- 原生 `Filicon App` Debug build 成功（`/tmp/filicon-mixed-routine-native.log`），產物 `codesign --verify --deep --strict` 通過；未啟動產物。`git diff --check` 通過。沒有使用付費模型、正式 Slack/GitHub 帳號或外部 webhook；不是 release 公證驗收。

IORegistry 仍回報 `CGSSessionScreenIsLocked=Yes`。完整回歸的受保護檔案重新讀取限制仍在，未為過關而削弱保護；解鎖後仍須重跑，不能將聚焦通過說成全套通過。完整 reconstructed parity 仍缺其他平台模型寫入、Slack 名稱／人類身分解析、GitHub checks 彙整，以及前述 memory／runtime／state 差異。

本批提案與核准修改已在下一輪提交為 `64ce20b`；提交前再次通過 85 項聚焦測試（`/tmp/filicon-mixed-routine-precommit.log`）。未 push、未重啟 App，未更動使用者實際群組、聊天或排程。

## 本輪增量：Linear 事件分類、送達識別與防重播基礎（2026-09-19，完整回歸待解鎖）

上一批已提交為 `64ce20b`。核對 reconstructed `automation-trigger.ts` 的 issueCreated／statusChanged／endOfCycle 與篩選規則，以及 `sand-state-tool.ts` 的 Linear schema 後，發現既有 ingress 尚未把事件轉成可用的原版 case，且 `webhookId` 被誤用為送達 ID。參照 [Linear 官方 webhook 格式與驗證說明](https://linear.app/developers/webhooks)（2026-09-19 查閱）：Linear-Delivery 識別送達，webhookId 識別 webhook 設定；updatedFrom 表示變更前的屬性，HMAC 僅涵蓋原始 body，webhookTimestamp 位於已簽章的 body。

本輪只修正事件處理底層，尚不開放 Linear 模型 create/update，也未新增設定頁或連線：

- 保留既有 `event:issue` entity 名稱，另外產生 `eventCase:issueCreated`／`statusChanged`，供 Linear case matcher 精確判斷。只接受有有效 issue ID 的 Issue/create；狀態改變須 Issue/update、有效的目前 stateId，以及 updatedFrom 的不同舊 stateId 或 null。只有標題變更、未變的狀態、錯誤型別、其他 entity／action 都不冒充上述 cases；不從 Cycle 更新猜測 endOfCycle。
- `primaryIDs` 沿用實際 team ID、`secondaryIDs` 沿用 project ID；缺少 team 不再用 issue ID 代替，設定了篩選卻缺少相應欄位即不匹配。保留舊 CaseAutomationTrigger 的儲存格式與既有 entity-event 匹配，不自動修改或啟用使用者的排程。statusIds／cycleIds 等完整原版篩選及提案核准仍待接線。
- externalEventID 改用有效的 Linear-Delivery，缺省時使用已簽章 body 的 SHA-256 摘要，不再使用共用 webhookId。空白、控制字元及超過 200 字元的 delivery ID 拒絕，不截斷成可能碰撞的值。不同 issue／送達不再被同一 webhook 設定 ID 吞掉；事件依現有規則先過濾再進 prompt。
- HMAC 驗證後，只採信 body 內數值且有限的 webhookTimestamp，拒絕布林／字串／null／缺少時間。沿用既有 replayWindow（預設 300 秒），不採信未簽章的 Linear-Timestamp 覆蓋。ingress nonce 固定取 body 摘要，因此更換 delivery／timestamp 標頭不能重播相同簽章內容；時間窗內重新載入仍去重。既有 automation history 的送達去重保留。此處不是永久收據、重試佇列或跨版本歷史遷移；不自動重送先前遺漏的事件。

依 Swift 測試技能，在 ingress controller 注入預設仍為實際時間的時鐘 closure，fixture 用固定時間、隔離資料及受控 executor，避免依賴真實排程或外部帳號。新增 9 項測試，先重現 21 個失敗斷言（`/tmp/filicon-linear-ingress-red.log`），再驗證不同送達、無 delivery 標頭 fallback、標頭變造／body 變造／錯誤簽章／過期／錯誤時間、事件分類、缺少／不符篩選、legacy Codable、過濾早於 prompt、history 去重及 ingress 重開。完整簽章 → controller → normalizer → matcher → executor → history 路徑使用固定 fixture，沒有啟動 Linear listener、連線 Linear 或付費模型；既有 loopback listener 回歸測試維持原樣。

最終聚焦回歸為 94 項 Swift Testing／9 suites 通過（含參數化 cases），涵蓋既有 GitHub／Slack／OR／時間排程及群組／mailbox 審批，紀錄 `/tmp/filicon-linear-ingress-regression.log`。原生 `Filicon App` Debug build（`/tmp/filicon-linear-ingress-native.log`）、產物嚴格 deep codesign、七語言各 1,480 keys 零缺漏與 `git diff --check` 通過。無新增 UI 畫面，本輪不宣稱新增視覺驗收；不是 live Linear 或 release 公證驗收。

此基礎批次已在下一輪提交為 `5241434`；提交前再次通過 94 項聚焦回歸（`/tmp/filicon-linear-ingress-precommit.log`）。當時 Mac 仍鎖定，完整回歸尚待解鎖，未削弱保護。未 push、未重啟 App，未更動使用者實際群組、聊天、排程或連線。

## 本輪增量：Linear 模型排程提案、精確篩選與核准（2026-09-19）

上一批已提交為 `5241434`。依 reconstructed `sand-state-tool.ts` 的 Linear shape，接上 group/mailbox 的自身 routine create/update，支援 issueCreated、statusChanged、teamIds、projectIds 與改變後的新 statusIds；不支援 endOfCycle／cycleIds，亦不猜測 Cycle 更新。可和 cron／GitHub／Slack 組成最多 8 項平面 OR 條件，沿用最早排程／事件去重及完整核准語意。

- 模型每份 ID 清單最多 50 個 UUID，先檢查原始數量與所有值，再統一大小寫、去重排序。省略與空清單皆表示不限；issueCreated 不接受 statusIds（即使空清單）。未知欄位、null、錯誤型別、名稱、無效 UUID 與不支援的 case 一律拒絕，不能丟棄條件後繼續。核心提交再次驗證，不只依賴工具 schema。
- 新 `LinearAutomationTrigger` 與其他平台型別分離，沿用舊 event／primaryIDs／secondaryIDs 儲存欄位及 enum 包裝；statusIDs 缺省為空，明確 null 不視為缺省。舊 `issue` 定義維持 entity matching，不自動升級、啟用或重播。team/project/status 指定時全部必須匹配，缺少欄位不放行；UUID 大小寫一致處理，legacy 非 UUID 值維持精確比對。
- 每次預覽完整新舊 prompt／trigger／enabled，新增七語言 Linear 限制說明，揭露既有驗證入口、不安裝連線、空清單不限、只看真正事件與可能的模型費用。原有四次修改預算、owner 綁定、Stop／帳號切換撤銷、費用防護與持久化收據均沿用。未新增手動 Linear 編輯器、名稱解析、外部連線或自動化工具權限。
- 依 Swift 測試技能使用隔離暫存資料、固定邏輯時間、受控 provider/executor/gate 與 CustomDump；涵蓋 create/update、完整核准與拒絕、0/50/51 邊界、status 改變後篩選、缺少 ID、舊 Codable、核心繞過拒絕、UUID 正規化／重播、時間及事件轉換、省略保留、歷史重開、費用保護、容量、延遲 commit／Stop／帳號切換與 mailbox owner。App OR fixtures 現在含 GitHub／Linear／Slack，mixed 再加入 cron。

最終聚焦回歸 101 項／9 suites 通過（`/tmp/filicon-linear-proposals-final-regression.log`）。七語言共 105 個核准預覽（15 情境 × 7 語言），固定 380 點寬度檢查容納高度；另實際檢視繁中修改與法文建立圖，未見截字。測試截圖改以內容 fitting height 輸出，避免空白邊界；不是完整產品逐頁視覺驗收。各語言 1,482 keys、零缺漏。原生 `Filicon App` Debug build（`/tmp/filicon-linear-proposals-native.log`）及產物 `codesign --verify --deep --strict` 通過，未啟動產物；仍有既有 AppIntents metadata 略過及 ad-hoc runtime 提示。

這次系統不再回報先前的鎖定旗標，完整套件沒有重現受保護檔案重新讀取失敗。預設執行完整套件時，134 XCTest 通過，但 Swift Testing 有 5 項既有測試／6 個斷言失敗：conversation 取消／跨 conversation 並行、subagent steer、程序 stdout 及群組核准重複觀測（`/tmp/filicon-linear-proposals-full.log`）。這 5 項隔離重跑皆通過（`/tmp/filicon-linear-proposals-failure-recheck.log`）；明確 `swift test --no-parallel` 的完整重跑為 **134 XCTest、774 Swift Testing／91 suites，全數通過**（`/tmp/filicon-linear-proposals-full-serial.log`）。兩項需 opt-in 的 live Codex 測試未執行。保留並行不穩定問題，不宣稱本輪已根治，也未放寬檔案保護或調整那些測試的門檻。

本批 Linear 模型提案與核准修改已在下一輪提交為 `866b368`；提交前再次通過 101 項聚焦測試（`/tmp/filicon-linear-proposals-precommit.log`）。未 push、未重啟使用者 App、未改真實聊天／群組／排程／連線，未連線 Linear 或付費模型。完整原版 parity 仍未完成；後續仍有 Linear 週期結束、其他平台模型提案、Slack 名稱／人類身分、GitHub checks 彙整及記憶／runtime 差異。

## 本輪增量：Sentry 事件分類、專案篩選與防重播基礎（2026-09-19）

上一批已提交為 `866b368`。核對 reconstructed `source/host/automations/automation-trigger.ts` 的 Sentry cases／projectIds 與 `sand-state-tool.ts` schema，以及 [Sentry webhook 說明](https://docs.sentry.io/integrations/integration-platform/webhooks/)和 [issue payload](https://docs.sentry.io/integrations/integration-platform/webhooks/issues/)（2026-09-19 查閱），確認既有 normalizer 讀錯專案位置，也未把 action 轉成原版 cases。這輪只補事件基礎，不開放 Sentry 模型 create/update、不新增專用編輯器或外部連線。

- `Sentry-Hook-Resource: issue` 加上有效十進位字串 issue ID，才將 created／resolved／assigned／archived／unresolved 對應成五種 canonical issue case。issueAny 只接受這五類，不接受 comment／installation／error／alerts、未知 action 或無效 issue；不把 action 相同的其他 resource 當 issue。舊式 ignored action 未擅自當成目前文件的 archived；舊 raw-action 排程仍可依原有規則處理。
- canonical `primaryIDs` 精確比對 `data.issue.project.id`，不使用 slug、名稱、issue ID、installation 或頂層 data.project 代替。指定篩選但缺少或無效 ID 即不匹配，空清單才代表不限；不支援的 secondaryIDs 非空即拒絕匹配。保留 CaseAutomationTrigger Codable 與舊 raw-action 的 event／primaryId／secondaryId 比對，不改寫或啟用使用者定義。
- HMAC 只涵蓋 body，因此 nonce 和 externalEventID 都使用 body SHA-256；Sentry 文件的 Request-ID 與既有 sentry-hook-request-id alias 僅作診斷，前者優先，兩者都需非空／無空白控制字元／最長 200 字元。相同 body 即使更換標頭仍視為同一事件；同一 issue 不同 action/body 不會因共用 installation 或 Request-ID 而遺漏。相同 body 的不同合法送達亦會合併，這是明確的保守去重行為。
- ingress nonce 快取仍受既有時限限制（預設 300 秒），重開可讀回；時限後已有且仍保留的 run history 仍依 body digest 去重。Sentry 未提供簽章涵蓋的時間戳，本輪不宣稱能驗證新鮮度或永久防重播；兩層紀錄過期後，舊的有效簽章仍可能被接收。保留原有可選 x-filicon-timestamp 檢查，但該值不是 Sentry 簽章證據。未遷移舊收據，也未新增重試佇列。

依 Swift 測試技能採固定時間、隔離暫存目錄、受控 executor／secret 與 CustomDump，先重現 60 個失敗斷言（`/tmp/filicon-sentry-events-red.log`），再使新增 8 項 Sentry 測試通過。包含五種事件、issueAny、錯誤 resource／action／ID、legacy Codable、body／secret 變造、標頭重命名、Request-ID alias、過長 ID、簽章前綴、先過濾再進 prompt、ingress 重開及超過快取時限後的 history 去重。無實際模型、帳號或公網呼叫；完整簽章至 executor/history 路徑在隔離 fixture 內驗證。

依 SwiftUI 技能，安全與事件邏輯仍留在非 UI 模組，設定 caption 只透過既有語言目錄呈現。本輪更新的 Sentry 驗證說明已補七語言，新增測試確認翻譯與協定欄位名稱；七語言各 1,483 keys、零缺漏。未新增畫面配置，不宣稱全產品視覺驗收。

驗證：117 項 Swift Testing／11 suites 聚焦回歸通過（`/tmp/filicon-sentry-events-regression.log`）；明確 `swift test --no-parallel` 完整回歸為 134 XCTest、783 Swift Testing／92 suites 通過（`/tmp/filicon-sentry-events-full-serial.log`），兩項 opt-in live Codex 測試未執行。既有通用 ingress fixture 亦改用 Sentry 文件的 Request-ID 與 data.issue.project 格式；舊格式由專門的 legacy 測試保護。上一批發現的並行測試時序不穩定未宣稱已修復。原生 `Filicon App` Debug build（`/tmp/filicon-sentry-events-native.log`）、產物 `codesign --verify --deep --strict` 及 `git diff --check` 通過；只有既有 AppIntents metadata／ad-hoc runtime 提示，未啟動產物。

此 Sentry 基礎批次已在下一輪提交為 `ca8e570`；提交前再次通過 117 項聚焦回歸（`/tmp/filicon-sentry-events-precommit.log`）。未 push、未重啟使用者 App、未動實際聊天／群組／排程／連線。原版全部能力仍未完成，不能將這批底層測試當成 Sentry 帳號端到端或產品全量驗收。

## 本輪增量：Sentry 自身排程提案與完整核准（2026-09-19）

上一批已提交為 `ca8e570`。依 reconstructed `source/host/runner/tools/sand-state-tool.ts` 的 Sentry shape 與 `source/shared/automations.ts` 六種 cases，接上群組／mailbox 的自身 routine create/update。可單獨使用或與 cron、GitHub、Slack、Linear 組成最多八項平面 OR 條件；並未接上其他平台或暗中建立外部連線。

- 支援 issueCreated／issueResolved／issueAssigned／issueArchived／issueUnresolved 及 issueAny；最後一項僅指前五種 issue cases，不包含所有 Sentry 事件。`projectIds` 空白／省略表示任意專案；最多 50 個精確十進位字串，各 1–200 位 ASCII 數字，先驗證原始清單再排序去重。保留前導零，不做數值轉換、名稱／slug 查找或修剪無效 ID。
- schema、解析器與核心寫入均有驗證。拒絕 null、錯誤型別、未知欄位／事件、secondary/team/status filters、超限及巢狀群組；混合組合中任一項無效就整份拒絕，停用提案也不例外。既有 raw-action 定義保留原意，不允許透過模型 update 偷換為新 canonical case；既有 pause/resume/delete 語意未改。
- 沿用固定 owner、完整 before/after、enabled、時區核准、四次共用變更預算、50 筆容量、費用防護、Stop／帳號與等待期間變更的取消邊界、原子儲存和 durable receipt。修改保留歷史，可在核准後切換 Sentry／時間／混合條件；未要求立即執行或補跑，不授予新工具權限。
- `CaseAutomationTrigger` 的 ID 集合以排序陣列編碼，使持久化和核准 JSON 穩定；儲存鍵與解碼型別不變，也保留 PagerDuty／舊資料語意。七語言提示明示既有驗證連線、五種 issue 範圍、精確 ID、有限重播保護、無簽章新鮮度證明、佇列事件與費用。

依 Swift 測試技能使用固定時間、隔離資料、受控模型與 CustomDump，先重現 4 個 create 參數案例的 invalidDefinition（`/tmp/filicon-sentry-proposals-red.log`），再補六種 case／ID 邊界、核心繞過、歷史保留、重複請求、完整核准與取消／拒絕／帳號切換／費用防護／容量／儲存失敗測試。群組與 mailbox fixtures 均包括 Sentry 單項及所有已支援平台的混合條件。沒有呼叫實際模型或外部帳號。

依 SwiftUI 技能，安全邏輯仍留在 service/parser，核准 UI 只顯示 host 產生的完整定義與說明。七語言共 119 張核准 fixture 圖成功渲染（`/tmp/filicon-sentry-routine-review`）；實際檢視繁中 update 和法文 create 的 Sentry 預覽，未見截斷；不代表整個產品或所有語言已做人工視覺驗收。目錄各 1,485 keys、零缺漏。

驗證：122 項 Swift Testing／11 suites 聚焦回歸通過（`/tmp/filicon-sentry-proposals-focused.log`）；明確 `swift test --no-parallel` 完整回歸為 134 XCTest、788 Swift Testing／92 suites 通過（`/tmp/filicon-sentry-proposals-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-sentry-proposals-native.log`）、產物 `codesign --verify --deep --strict`、localization audit 與 `git diff --check` 通過；僅既有 AppIntents／ad-hoc runtime 提示。未宣稱已修復先前的並行測試時序問題。

此提案增量已在下一輪提交為 `24431bf`；提交前再次通過 122 項聚焦回歸（`/tmp/filicon-sentry-proposals-precommit.log`）。未 push、未啟動或重啟 App、未更動真實聊天／群組／排程／連線。`AUTO-03` 仍為 partial：後續可核對 PagerDuty 事件與模型提案、Linear endOfCycle／cycleIds、GitHub checks 彙整與 Slack 名稱／身分映射；不能將本批視為原版全部能力或 Sentry live 帳號驗收完成。

## 本輪增量：PagerDuty 事件分類、服務篩選與防重播基礎（2026-09-19）

上一批已提交為 `24431bf`。核對 reconstructed `source/shared/automations.ts`、`source/host/automations/automation-trigger.ts` 與 `sand-state-tool.ts` 的四種 incident cases、incidentAny 和 serviceIds，以及 PagerDuty 官方的 [V3 payload](https://github.com/PagerDuty/developer-docs/blob/main/docs/webhooks/01-Overview.md)、[signature protocol](https://github.com/PagerDuty/developer-docs/blob/main/docs/webhooks/04-Signatures.md) 和 [delivery behavior](https://github.com/PagerDuty/developer-docs/blob/main/docs/webhooks/02-Behavior.md)（2026-09-19 查閱）。本輪只補 ingress／matching 基礎，未開放 PagerDuty 模型 create/update 或新增外部連線。

- 將 incident.triggered／acknowledged／resolved／escalated 對應成 incidentTriggered／incidentAcknowledged／incidentResolved／incidentEscalated；incidentAny 只含這四類，排除 reopened／reassigned／priority_updated、service、未知事件。需 nested event、有效 event.id、resource_type=incident、data.type=incident 與有效 data.id；不將舊平面 payload 自動升級成 canonical 事件。
- canonical primaryIDs 精確篩選 event.data.service.id，且 type 必須為 service_reference；不使用摘要名稱、incident ID、頂層 service 或訂閱 ID，也不忽略大小寫。缺少／無效服務 ID 不得命中指定篩選；空集合表示任意有效事故。secondaryIDs 不受支援且不會被靜默忽略。舊 raw event-type 定義及 primaryId／secondaryId 保留原義與 Codable 格式，不遷移或自動啟用。
- 簽章僅接受逗號分隔的 v1=HMAC(rawBody) 候選值；支援輪替期間多候選，忽略未知版本，不接受裸 digest。用 body digest 作 nonce，避免改 unsigned delivery header 重播或共用 webhookId 漏掉不同事件。用已簽章 event.id 作 history 身分；缺少 ID 的 legacy payload 退回 body digest。存在但無效的事件 ID 直接拒絕，不截斷；事件／事故／服務 ID 與診斷 delivery ID 限非空、最長 200 字元、無空白／控制字元。X-Webhook-Id 及舊 x-pagerduty-delivery alias 僅供診斷，前者優先。
- occurred_at 是事件發生時間，不是送達新鮮度證據；不拿它套 300 秒時限而誤拒絕延後重試。保留原可選 x-filicon-timestamp 檢查，但未宣稱它受 PagerDuty 簽章保護。預設 300 秒 ingress nonce cache 可跨重開，時限後依仍保留的 run history 去重；兩者清除／過期後仍非永久防重播。未遷移歷史收據或新增重試佇列。

依 Swift 測試技能使用固定時間、隔離暫存目錄、受控 secret／executor 與 CustomDump，先重現 8 項測試中的 63 個失敗斷言（`/tmp/filicon-pagerduty-events-red.log`），再使全部通過。包含四種事件、incidentAny、wrong-platform/resource/type/ID、精確服務篩選、legacy round-trip、UTF-8 本文、版本／輪替／body 與 secret 變造、未簽章標頭變更、長 ID、重開與快取時限後 history 去重。同一事故不同事件不漏發，同一 signed event ID 換 envelope 仍只執行一次。受控 ingress→service→executor/history 流程驗證先篩選再進 prompt，未呼叫真實模型或 PagerDuty 帳號。

驗證：131 項 Swift Testing／12 suites 聚焦回歸（`/tmp/filicon-pagerduty-events-focused.log`）；明確 `swift test --no-parallel` 完整回歸為 134 XCTest、797 Swift Testing／93 suites 通過（`/tmp/filicon-pagerduty-events-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-pagerduty-events-native.log`）、產物 `codesign --verify --deep --strict`、localization audit 與 `git diff --check` 通過。驗證說明已有七語言，各 1,486 keys、零缺漏；測試檢查翻譯和協定欄位名稱，沒有新增版面或宣稱全產品人工視覺驗收。完整回歸仍有 CoreData NSXPC 診斷但零測試失敗，原生建置為既有 ad-hoc runtime 提示；先前並行時序穩定性問題未宣稱修復。

此 PagerDuty 基礎批次已在下一輪提交為 `e92a1de`；提交前再次通過 131 項聚焦回歸（`/tmp/filicon-pagerduty-events-precommit.log`）。未 push、未啟動或重啟使用者 App、未改實際聊天／群組／排程／連線。`AUTO-03` 仍為 partial；下一批可接 PagerDuty 自身模型排程提案、完整核准及混合 OR。其他剩餘差異包含 Linear endOfCycle／cycleIds、GitHub checks 彙整及 Slack 名稱／身分映射，不能將底層 fixture 視為原版完整能力或帳號端到端驗收。

## 本輪增量：PagerDuty 自身排程提案與完整核准（2026-09-20）

上一批已提交為 `e92a1de`。依 reconstructed `source/host/runner/tools/sand-state-tool.ts` 的 PagerDuty shape 與 `source/shared/automations.ts` 五種 cases，接上群組／mailbox 的自身 routine create/update。可單獨使用，或與 cron、GitHub、Slack、Linear、Sentry 組成最多八項平面 OR 條件；不新增外部連線或手動專用編輯器。

- 支援 incidentTriggered／incidentAcknowledged／incidentResolved／incidentEscalated 及 incidentAny；最後一項僅指前四種事故事件。`serviceIds` 省略／空清單表示任意服務；原始清單最多 50 個不透明、區分大小寫的 ID 字串，各 1–200 字元，先完整驗證再排序去重。不修剪或改寫大小寫，不做名稱查找或猜測 ID；拒絕空字串、空白／控制字元與 `*`。不宣稱能從字串外觀驗證服務是否真實存在。
- schema、解析器與核心提交都驗證支援範圍。拒絕未知 case／欄位、null、錯誤型別、secondary filters、超限與巢狀群組；任一成員無效就整份拒絕，停用提案也不例外。舊 raw-event 定義保留原義，不允許模型 update 將它轉為 canonical case；既有儲存格式與 pause/resume/delete 語意維持不變。
- 沿用固定 owner、完整 before/after prompt／trigger／enabled／時區核准、四次共用變更預算、50 筆容量、費用防護、Stop／帳號切換／等待期間變更的取消邊界、原子儲存及 durable receipt。修改保留執行歷史，可核准後切換時間、PagerDuty 與混合條件；省略觸發條件就保留。不要求立即執行或補跑，不授予新工具權限。
- 核准與成功回條明示需既有已驗證入口、不安裝或啟動連線、精確服務範圍、incidentAny 的四類限制、有限防重播、occurred_at 非送達新鮮度證據及佇列事件／模型費用。所有已支援平台的混合 OR 預覽包含每項條件與各平台警告，不隱藏 PagerDuty 限制。

依 Swift 測試技能使用固定時間、隔離目錄、受控 provider／executor／核准 gate 與 CustomDump。先重現四個 create 參數案例的 invalidDefinition（`/tmp/filicon-pagerduty-proposals-red.log`），再補五種 case、0/50/51 清單邊界、1/200 字元、大小寫精確性、核心繞過拒絕、legacy 轉換拒絕、完整核准、歷史重開、重複請求、拒絕／停止／帳號切換／費用防護／容量／儲存失敗測試。群組核准矩陣為 16 種情境 × 四種結果，跨對話 mailbox 的 16 種情境亦檢查 recipient owner，包含 PagerDuty 單項與混合 OR。未呼叫真實模型或外部帳號。

依 SwiftUI 技能，解析與安全邏輯留在 service，核准元件只顯示 host 產生的完整定義及說明。七語言共 133 張 routine 預覽（19 情境 × 七語言）於固定 380 點寬度成功渲染，並檢查 fitting height；輸出 `/tmp/filicon-pagerduty-routine-review.TS0Ovo/`。實際檢視 `routine-update-pagerduty-zh-Hant.png`、`routine-create-pagerduty-fr.png` 與 `routine-create-mixed-zh-Hant.png`，未見內容裁切；不是全產品逐頁或七語言逐張人工驗收。各語言 1,488 keys、零缺漏。

驗證：136 項 Swift Testing／12 suites 聚焦回歸通過（`/tmp/filicon-pagerduty-proposals-focused.log`）；明確 `swift test --no-parallel` 完整回歸為 **134 XCTest、802 Swift Testing／93 suites 通過**（`/tmp/filicon-pagerduty-proposals-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-pagerduty-proposals-native.log`）、產物 `codesign --verify --deep --strict`、localization audit 與 `git diff --check` 通過。完整測試仍有 CoreData XPC 診斷但零失敗；原生建置為既有 ad-hoc runtime 提示。未宣稱已修復先前的並行測試時序問題，也不是真實 PagerDuty 帳號或 release 公證驗收。

此提案批次已在下一輪提交為 `abd68c5`；提交前再次通過 136 項聚焦回歸（`/tmp/filicon-pagerduty-proposals-precommit.log`）。未 push、未啟動或重啟使用者 App、未改實際聊天／群組／排程／連線。`AUTO-03` 仍為 partial：仍缺平台專用編輯器、Linear endOfCycle／cycleIds、GitHub checks 彙整及 Slack 名稱／身分映射等完整語意；不能把本批增量稱為原版所有能力皆已完成。

## 本輪增量：原生 Linear 週期完成事件與精確篩選基礎（2026-09-20）

上一批已提交為 `abd68c5`。核對 reconstructed `sand-state-tool.ts`、`automation-trigger.ts`、`sand-automation-cloud-trigger.ts` 與 `sand-automation-fire-consumer.ts`，確認原版將 endOfCycle／cycleIds 送到雲端，收到的是已分類的完成通知，並非本機將一般 Cycle 更新直接當成週期結束。此輪提供 macOS 的原生 webhook 適配，不能宣稱已還原雲端全部語意。

2026-09-20 查閱 [Linear webhook 文件](https://linear.app/developers/webhooks)及官方 SDK 的 [Cycle schema](https://github.com/linear/linear/blob/3addb24bdf771700da1c050742e70e645cc7e36a/packages/sdk/src/schema.graphql)、[CycleWebhookPayload](https://github.com/linear/linear/blob/3addb24bdf771700da1c050742e70e645cc7e36a/packages/sdk/src/_generated_documents.ts)：更新包含先前變更值，completedAt 為完成時間；Cycle 有 teamId，但沒有 projectId。以下事件判定是基於這些欄位的本機保守實作，尚未取得 live 帳號驗證：

- 必須是已驗證的 Cycle/update、有效 cycle/team UUID、`updatedFrom.completedAt` 明確為 null、新 completedAt 為有效且不晚於本機接收時間的帶時區時間戳，才產生 eventCase=endOfCycle 與正規化 cycleId。不靠 endsAt 是否過期、時鐘前進、封存、進度、名稱或缺少舊值推測；一般完成與提前完成都可符合，不必等待舊 endsAt。
- 只以 team UUID 和 cycleIDs 精確篩選；UUID 忽略字母大小寫，空集合表示不限。原生 Cycle 沒有專案關係，要求 project 篩選即不匹配，即使 payload 額外帶 projectId 也不放行；不從 issue 或名稱補猜。週期不接受 statusIDs，issue／其他事件不接受 cycleIDs，不能忽略不支援的限制。
- 既有 Linear 儲存鍵及舊建構介面保留，新增 cycleIDs 只在非空時寫出排序陣列，缺省解碼為空，明確 null／錯誤型別拒絕。舊 issue／cycle entity matching 保留；raw endOfCycle 標籤本身不作完成證據。沒有自動改寫或啟用任何既有定義。
- 已分類完成的 externalEventID 由 cycle UUID 與毫秒精度的完成時間組成；等價時區表示、新 delivery header、重新簽章且刷新 webhookTimestamp 的重試，均不能重複執行仍保留的完成紀錄。不同 cycle 或較晚完成時間則區分；既有 connector scope 繼續隔離事件身分。其他 Linear 事件維持 Linear-Delivery／body digest fallback。簽章、signed webhookTimestamp 時限和 body digest 快取不放寬；歷史及快取過期後仍非永久去重，未新增 poller、連線或公開入口。

本輪先做底層，不開放 cycle 的模型 create/update 或編輯器；既有 Linear 提案入口仍明確拒絕 endOfCycle／cycleIds，核心亦拒絕直接繞過寫入，不會顯示已支援卻無完整核准說明的選項。下一批需接上提案、完整變更核准、專案篩選限制與七語言提示。

依 Swift 測試技能使用固定時間、隔離資料、受控 executor／secret 與 CustomDump，先以兩項測試重現 14 個分類／身分斷言失敗（`/tmp/filicon-linear-cycle-red.log`），再補八項測試：明確完成／提前完成、無效與未完成事件、時間格式與未來值、UUID／專案／狀態篩選、legacy Codable、核心提案拒絕、純時間前進不得觸發、簽章至 executor/history 的先篩選再執行、重開及超過快取期限後的去重。核准、費用、Stop、群組／mailbox 等既有回歸保持通過；未呼叫真實模型或外部帳號。

聚焦回歸為 144 項 Swift Testing／12 suites 通過（`/tmp/filicon-linear-cycle-regression.log`）。明確 `swift test --no-parallel` 完整回歸為 **134 XCTest、810 Swift Testing／93 suites 全數通過**（`/tmp/filicon-linear-cycle-full.log`），兩項 opt-in live Codex 測試未執行；不宣稱已修復先前的並行時序問題。原生 `Filicon App` Debug build（`/tmp/filicon-linear-cycle-native.log`）及產物 `codesign --verify --deep --strict` 通過；本輪未啟動產物。七語言各 1,488 keys、零缺漏，沒有新增 UI 版面，不宣稱本輪另做全產品視覺驗收。完整測試仍有既有 CoreData XPC 診斷但零失敗，原生建置有既有 AppIntents metadata／ad-hoc runtime 提示；`git diff --check` 通過。這不是 live Linear 或 release 公證驗收。

此底層批次已在下一輪提交為 `ddf7587`；提交前再次通過 144 項聚焦回歸（`/tmp/filicon-linear-cycle-precommit.log`）。未 push、未重啟使用者 App、未更動實際群組／聊天／排程／連線。`AUTO-03` 維持 partial；當時 cycle 模型提案／專用編輯器、原版雲端專案歸屬、GitHub checks 彙整、Slack 名稱／人類身分映射等差異仍在。
