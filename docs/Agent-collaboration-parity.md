# 協作能力核對紀錄（2026-09-18）

參考來源為非官方 `grok-bot-0.18-reconstructed`，不是官方產品原始碼。
此表只涵蓋已讀過來源且對照現行接線的協作功能；未涵蓋功能不能推定完成。

| 行為 | reconstructed 證據 | Filicon 現況與驗證 |
|---|---|---|
| 群組接續、角色、PASS、取消 | `source/host/groups/`、群組 runner | 已接線，`GroupCollaborationTests`；保留三輪／十則上限 |
| 向使用者明確發訊 | `source/host/extensions/transcript/send-message-shaping.ts`、`agents/agent-messaging.ts` 的 SendMessage 區分 | 已接線文字版 `AgentUserMessageTool`；群組中即時落盤／顯示，peer wake 回報到來源 UI；每 turn 兩則，final 不重複；`AgentUserMessageToolTests`、`AgentBackgroundExecutionTests` |
| 非同步單一同伴委派、回信喚醒 | `source/host/extensions/transcript/agent-to-agent-messaging.ts` | 已有 `SendToAgent` → durable mailbox → wake → reply wake；新委派顯示完整 payload approval |
| 手動訊息執行 | 同一 inbound wake 機制 | 「代理人 → 訊息」Send 已接上真實 ToolLoop，不再只存信；頁面不必保持選取；審批、資料夾選擇、取消都沿用 host 路徑 |
| 上下文跨次請求／重開 | `resolveBackgroundSession`、agent transcript store | **部分**：account/origin/agent 隔離的 30 則 peer 上下文與穩定 inference ID 已落盤；不是原版橫跨所有 DM／群組的統一私人記憶、記憶編輯或完整長期背景 session |
| 每 agent 統一 exclusive lane | `runLifecycle.enqueueExclusiveRun(session.id, …)` | **尚缺完整版本**：同一來源 mailbox 禁止重疊；不同來源目前不是統一 per-agent scheduler |
| 群組目標／broadcast | `sendToAgent` → `postToGroup`；directory 中的 group addresses | **尚缺**：目前只接受單一 active agent UUID；不以隱含 fan-out 代替 |
| 圖片訊息 | `loadAgentInboundImages`／`selectedImages` | **尚缺**：目前 peer SendToAgent 與 SendMessage 是文字，不能把普通聊天附件功能算作已接線 |
| 優先訊息中斷非使用者工作 | `steerRecipientForPriorityPeer`，先檢查 active lane != user | **尚缺**：manual priority 為 mailbox metadata；不會中斷正在執行的 agent/user turn |
| 模型建立／編輯代理人 | `source/host/agents/agent-messaging.ts`: CreateAgent、UpdateAgent | **尚缺**：現有 UI/service CRUD 不是模型工具；需另接審批與安全欄位限制 |

## 安全差異

- 委派不是新的檔案／程序／外部服務授權。所有實際工具仍用來源 conversation scope 與新的 run ID。
- 持久上下文不儲存可重放的 permission receipts、system persona 或工具執行 token。
- 已停止、已切換帳號或重啟後的未完訊息不會自動重新執行；重啟保留紀錄並標示取消。恢復未知副作用的工作仍須新的使用者請求。
- 各代理人的 persona 及不同 account/origin 上下文不會互相複製。

## 驗證範圍

使用可控制的 provider 驅動真實 AppModel、ToolLoop、持久化與審批，包含真實本機 fixture 寫檔；不使用使用者的專案檔案、不連線付費／live 模型、不重啟使用者的 App。
七語言 UI render 是版面檢查，不是宣稱七語言完整產品逐頁驗收。
本輪最終測試報告：134 XCTest、561 Swift Testing，零失敗；兩個需主動啟用的 live Codex 測試未執行。
原生 `Filicon App` Debug build 與嚴格簽章驗證通過。七語言各 1,393 keys，缺漏為零。
新增測試也確認：已發出的進度在後續失敗或停止後仍保留，不被終止狀態清掉。
中途一次完整重跑曾卡在既有檔案鎖測試的子程序清理；隔離執行及最後完整重跑均通過，未宣稱該偶發測試問題已根治。
完整產品 parity 仍未完成，原矩陣的歷史 release／test 結果不得替代此核對。
