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

## 必須保留的其他分類

- 記憶：最新保存／搜尋／synthesis／episode／project recall 證據見 `Memory-archive-parity.md`；跨 epoch snapshot 是未接線參考設計，見 `Memory-snapshot-audit.md`，不能自行換成永久 cache。
- 協作／訊息：AGENT-02／04 的歷史缺項需與 `Agent-collaboration-parity.md` 後續進度及 current source 逐項對照；不能用舊行的「缺」覆蓋已完成的接線，也不能以有 UI 就宣稱工具／背景路徑完成。
- 平台事件：AUTO-03 的 Teams 使用者驗證、GitHub checks 彙整、Slack 名稱／自身身分映射等仍需逐項來源核對和平台驗收；不因 generic matcher 通過而放寬驗證政策。
- 發佈／外部能力：UPD-03 的既有 release 是歷史證據，本目標禁止 push／真實帳號修改；不能擅自發新版本、連接帳號、安裝插件或替使用者授權。最終報告須明列尚需哪些外部驗收與決策，不把它們藏在 complete 標籤後。
