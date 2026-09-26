# Episodic 記憶：參考行為與待實作驗收

本文保留各批歷史核對，較早段落的「尚未實作」以後續進度段落為準；不代表目前仍全部缺少。整體仍為 partial，尚未完成端到端驗收。

核對日期：2026-09-27。參考 repository `grok-bot-0.18-reconstructed`，HEAD `a9f633e09d49a85829b8236331b9e21f7e612634`。這是原始碼行為核對，並非真實模型執行驗收。Filicon 對照基準為 `2cb08f9`。

## 兩條互斥的參考流程

`source/host/runner/turn-memory.ts` 的 `runTurnMemory` 先檢查 `recordMemoryEvidence`。存在時清除 pending episode turns、交出本回合 evidence，立即 return；不執行舊 extraction 或 episode 摘要。

`source/host/extensions/memory/memory-service.ts` 的 getter 僅在 dreaming 啟用時提供 `recordMemoryEvidence`。`extension.ts` 由 `sand_memory_dreaming` experiment gate 啟動 synthesis；`production.ts` 接 debounce、polling、retry、deadline。故「原版所有模式都每六回合追加 episode」是不正確的要求。

未提供 synthesis evidence 接口時才走舊流程：

1. `turn-settle.ts` 排除 superseded、hidden、空 prompt；舊流程另要求 `isMemorableExchange`，短問候／致謝等不計入。
2. 先 extraction，再將當次 user／agent／timestamp 存入 session 的 episode progress。
3. `sand-memory.ts` 預設間隔 6，環境變數 `SAND_MEMORY_EPISODE_INTERVAL` 可改為正整數。
4. `agent-db.ts` 保存 session KV；每側文字截至 2,000 個 JavaScript 字元，保留最新 64 回合。這是有持久化的進度，不是單次 session 物件內計數。
5. 達到間隔後按時間順序摘要一至兩句，捕捉工作主線、決策與結果，使用絕對日期；空結果或 `NONE` 不寫入。
6. 非空摘要以前綴 `[episode] ` 保存為 log，時間為最後一筆 pending turn。摘要嘗試的 finally 清掉 pending，即使模型失敗也不保留該批等待下次重試；維護失敗不使前景回合失敗。
7. recall 中 episode importance 為 1.5，普通 log 為 1，note 為 0.5，搭配 30 天半衰期排序；未注入的歷史仍可留在磁碟查詢。

## Filicon 現況與真正缺口

`AgentMessagingSession` 已分別取得人工審核候選及自動 synthesis 的 consent；兩者目前可同時啟用，不等同原版 experiment 的互斥分支。不能為了照搬舊分支，在使用者停用自動 synthesis 時偷偷自動保存 episode，也不能把既有「當前回合」候選授權解讀成跨回合逐字內容持久化同意。

現有 synthesis queue 會合併有界證據，但不是六回合事件摘要進度。`AgentMemory` 有 profile／log／note，沒有 episode 來源型別或受 host 控制的權重。`AgentMemoryRecall` 有 note 降權，但沒有 episode 的 1.5 權重。單純讓模型在 fact 前加 `[episode]` 不構成完成，也不可把任意文字前綴當成提升權重的可信來源。

仍需實作並驗證：

- 明確的 episodic 啟用／模式說明與七語費用、跨回合保存範圍揭露；不得隱含擴大既有 consent。
- 帳號、代理人、來源對話、consent revision 隔離的有界進度；重開、重複回合、停止、刪除對話、移除成員、停用及切帳號的處理。
- 六個合格回合觸發，短問候不觸發；synthesis 啟用時不再同批執行舊 episode 分支。
- 無工具、有限輸入／輸出／耗時的摘要請求，絕對日期及 `NONE` 行為；既有驗證／人工審核安全流程不可被繞過。
- host-owned episode 來源與 recall 權重、搜尋與編輯顯示、刪除後不復活；不自動刪除其他記憶來騰配額。
- 結果、模型失敗、取消、持久化失敗的原子收尾及重開驗收；記憶容量／archive 與原版差異另列，不以狹窄 queue 測試宣稱整體等價。

目前沒有把以上缺口標為完成。本核對修正的是後續實作的分支條件，沒有修改 runtime、真實聊天或帳號資料。

## 進度元件（2026-09-27）

`AgentMemoryEpisodeProgress` 已實作可編解碼的 account／agent／origin／revision 身分、預設六回合門檻、原版英文 trivial-exchange 篩選、每側 2,000 UTF-16 單位及最近 64 回合上限。避免切斷 surrogate pair；最近 128 個回合 ID 用於有界去重，不是永久去重。摘要結果 whitespace 正規化、500 UTF-16 上限與 NONE 處理也有測試。

摘要嘗試收尾只移除該批回合，保留執行中新增的回合；失敗批次不應自動重跑。編解碼會拒絕超量、重複或缺少去重 ID 的進度。這只是純值元件，**尚未接入持久化 store、App consent、synthesis 互斥分支或模型 runner**；持有 progress 本身不是授權，也未寫入任何真實聊天。完整 episodic 功能仍 partial。

## 儲存與授權基礎（2026-09-27）

後續已將 progress 接入 `AgentPersistentState`／`AgentService`，取代上一段 store 尚缺的記述。舊資料欄位缺省為空；新增獨立 `AgentMemoryEpisodeSettings`，預設停用。record 同時檢查 saved revision、active agent、lifetime 和 synthesis 未啟用；全 store 最多 64 個來源進度，滿額拒絕新增，不淘汰其他來源。

設定更新會清除該 account／agent 的進度；啟用 synthesis 額外撤銷 episode consent，之後停用 synthesis 不會自動重啟跨回合收集。封存代理人清除其進度與授權，restore 不復活；來源清除 API 按 account／origin 隔離。所有改動沿用原子儲存與失敗回滾。隔離測試覆蓋重開去重、舊資料、取消、寫入失敗、synthesis 互斥與 account／origin 清除。

**尚待 App 七語同意介面、前景完成事件及停止／刪除／切帳號接線、摘要 runner、保存與 host episode 來源權重。** 現在沒有使用者入口會啟用此功能，也沒有自動保存真實跨回合文字；不能以儲存層測試宣稱端到端完成。

本批驗證：完整非並行 Swift 測試 exit 0（`memory-episode-store-full.log`）、原生 `Filicon App` Debug 建置 exit 0（`memory-episode-store-native.log`）、封裝 deep/strict 簽章及 app／XPC entitlements 檢查通過；未啟動 App。

## 摘要執行基礎（2026-09-27）

`runMemoryEpisode` 已接六回合門檻、每來源單一在途執行、無工具摘要與獨立驗證、NONE／拒絕不保存。transport 使用背景 lane，兩段共用 90 秒上限（每請求另有限時）；不攜帶 persona 或對話工具。尚未由 App 自動呼叫。

為避免崩潰後重送跨回合文字，批次在呼叫模型前先原子消耗並保存；若消耗保存失敗不呼叫模型。這比原版 finally 清 pending 更保守：模型失敗、取消或崩潰皆不重試此批，執行中新增回合保留。最終保存重新檢查 consent revision／lifetime／來源撤銷；tombstone、重複與配額沿用既有規則，不刪其他記憶騰空間。

新增 host-owned `.episode` 來源，私有 log、時間取最後回合，recall importance 1.5；公共 write 不能偽造來源，`[episode]` 字樣不提升權重。仍待來源 UI 呈現、七語 consent／費用說明、App 前景與生命週期接線；端到端保持 partial。

此批完整非並行測試（`memory-episode-runner-full.log`）與原生建置（`memory-episode-runner-native.log`）exit 0；runner 包含 9 種結果／撤銷／新增回合情境，transport 成功與逾時皆經測試。使用隔離測試 provider，沒有真實模型或使用者聊天驗收。

## 聊天完成接線（2026-09-27）

`AgentMessagingSession` 在 prepare 時捕捉獨立 episode consent，只有已保存的前景回覆完成後才累積及嘗試摘要；synthesis 啟用時不準備 episode。App 的群組／綁定 direct 入口已提供 transport。正常完成跨 session 累積；未 prepare、PASS、停用不觸發。episode 寫入同時受 session 與 account／origin composite lifetime 保護，Stop 或父來源撤銷後不可寫入。

此接線仍不提供啟用 UI，也**尚未完成 Stop／刪除／成員變更時清理既存 pending 文字**（目前 lifetime 阻止新寫入，不能替代清理）；後續需把 source 清理與 UI 授權一起驗收。session 測試包含 7 種啟用／撤銷／synthesis 分支，跨六個 session 只生成一筆事件記憶。

本批完整非並行測試 `memory-episode-session-full.log` 及原生建置 `memory-episode-session-native.log` exit 0，封裝簽章／entitlements 通過；未使用真實模型、聊天或帳號。

## Pending 清理接線（2026-09-27）

App 原有 origin invalidation（direct Stop／刪除、group Stop／成員更新）現在排入序列清理；切帳號排入舊帳號整體清理。新 session prepare episode 前等待已捕捉的 account／origin 清理成功，舊 session 由既有 lifetime 即時撤銷，避免遲到清理刪除新回合。清理失敗則不再收集 episode；再次 invalidation 可重試清理。已保存記憶不受清理影響。

針對清理的 App 測試直接呼叫 Stop／delete／account 入口並重開 store 驗證 pending 消失、既存記憶保留；session 測試驗證 cleanup failure 不發出模型請求。尚待七語啟用 UI、來源顯示及使用者可見的清理失敗診斷；不能稱端到端已完成。

本批完整非並行測試 `memory-episode-cleanup-full.log`、原生建置 `memory-episode-cleanup-native.log` exit 0；封裝 deep strict 簽章與 entitlements 通過。

## 七語啟用介面（2026-09-27）

代理人記憶設定新增預設關閉的事件摘要入口，啟用前明示跨回合有限文字保存、六回合門檻、額外模型費用、獨立驗證後免逐筆核准儲存，以及清理與 synthesis 互斥。七種語言均有翻譯；synthesis 啟用確認也包含事件摘要撤銷說明。App 設定 API 使用 account／revision／UI lifetime 防護，啟用前等待既有清理成功，清理失敗則拒絕啟用並顯示錯誤。

完整非並行測試 `memory-episode-ui.log` exit 0；最後新增的 App 授權測試另以 `memory-episode-ui-app.log` 通過（13 tests），覆蓋重開持久化、舊授權、跨帳號拒絕與 synthesis 撤銷。七語明暗色 380pt 渲染檢查通過；原生建置 `memory-episode-ui-native.log` 與封裝 deep strict／entitlements 通過。未啟動真實 App。

仍待事件來源 UI 標示、執行期間清理失敗的固定診斷提示，以及實際互動端到端驗收；保持 partial，不宣稱原版功能全部完成。

## 記憶來源顯示（2026-09-27）

已保存記憶清單現在依 host-owned `origin` 顯示已核准記憶、自動記憶整合或事件摘要，七語皆翻譯；不依 fact 文字或 `[episode]` 前綴推測來源。沿用原有日期、層級、共享作者與忘記操作。

App 聚焦測試 `memory-origin-label.log` 通過（13 tests），包含三個來源映射及七語明暗色 380pt 渲染；另檢視繁中 light 產圖，文字未截斷。原生建置 `memory-origin-label-native.log` 與封裝 deep strict／entitlements 通過。本批未重跑完整測試；未啟動真實 App。仍待執行期間清理失敗的固定診斷提示與實際互動端到端驗收。

## 清理失敗提示（2026-09-27）

origin／account 清理失敗現在透過既有 App 錯誤提示顯示七語固定訊息，不包含路徑、帳號 ID 或聊天文字；提示說明停止收集、保留已存記憶及檢查儲存空間／檔案存取後重試。提示受 account lifetime 保護，已撤銷世代不能顯示遲到錯誤。清理 Task 仍拋出錯誤，沒有把顯示提示當成成功或放行收集。

隔離 App 測試以目錄取代 fixture 的 agents.json 造成儲存失敗，驗證 Stop 與 account 清理錯誤可見、readiness 拒絕、恢復檔案後重試成功；七語翻譯皆檢查。聚焦 `memory-cleanup-diagnostic.log` 通過 14 tests。原生建置 `memory-cleanup-diagnostic-native.log` 與封裝驗證通過。

完整非並行回歸 `memory-cleanup-diagnostic-full.log` exit 0。

後續驗收仍須包含真實 App 入口的六回合整合，以及清理失敗後退出／重開的處理：目前清理 barrier 是程序內 Task，不能據此宣稱跨程序失敗隔離已完成。未操作真實資料或啟動 App。
