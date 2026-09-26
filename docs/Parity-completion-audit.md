# 完成驗收入口（2026-09-27）

本檔不取代使用者要求或縮小 parity 範圍。基準 Filicon `a7ca268`、reference `a9f633e09d49a85829b8236331b9e21f7e612634`；工作樹檢查為乾淨。沒有啟動 App、使用外部帳號或重新驗證 release。

## Matrix 不是完成證明

`PARITY.md` 有 48 個 ID：43 個歷史 complete、4 個 partial（AGENT-01／02／04、AUTO-03）、1 個 NA（UPD-04）。complete 必須逐項連到當前可達流程、對應測試及必要 runtime 驗收；「final gates passed」本身不能證明全功能對等。近期完整 Swift 測試／原生 build／package verifier 是回歸與封裝證據，不替代外部帳號、權限 UI 或 release 驗收。

以下保留全部驗收範圍：UI-01…04、CONV-01…04、ATT-01…04、PROV-01…04、MCP-01…04、AGENT-01…04、AUTO-01…04、COMP-01…04、ACCT-01…04、NOTIF-01…04、PERS-01…04、UPD-01…04。尚未逐項重驗者標記為未重驗，不推論缺失，也不視為已完成。

## 已核對的下一個本機缺口：自身側欄可見性

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

## 必須保留的其他分類

- 記憶：最新保存／搜尋／synthesis／episode／project recall 證據見 `Memory-archive-parity.md`；跨 epoch snapshot 是未接線參考設計，見 `Memory-snapshot-audit.md`，不能自行換成永久 cache。
- 協作／訊息：AGENT-02／04 的歷史缺項需與 `Agent-collaboration-parity.md` 後續進度及 current source 逐項對照；不能用舊行的「缺」覆蓋已完成的接線，也不能以有 UI 就宣稱工具／背景路徑完成。
- 平台事件：AUTO-03 的 Teams 使用者驗證、GitHub checks 彙整、Slack 名稱／自身身分映射等仍需逐項來源核對和平台驗收；不因 generic matcher 通過而放寬驗證政策。
- 發佈／外部能力：UPD-03 的既有 release 是歷史證據，本目標禁止 push／真實帳號修改；不能擅自發新版本、連接帳號、安裝插件或替使用者授權。最終報告須明列尚需哪些外部驗收與決策，不把它們藏在 complete 標籤後。
