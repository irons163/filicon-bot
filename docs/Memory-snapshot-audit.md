# 記憶快照：設計與實際接線核對

2026-09-27；reference `grok-bot-0.18-reconstructed` HEAD `a9f633e09d49a85829b8236331b9e21f7e612634`，Filicon `6966670`。本次為靜態呼叫鏈核對，沒有執行原版或真實 App。

## 參考設計確實存在

- `source/host/runner/sand-memory.ts:30` 的 `resolveFrozenMemoryPrompt`：同 epoch 有 snapshot 時直接重用 render；沒有事實時不產生 snapshot，有事實時保存 render＋epoch。
- `system-prompt-assembly.ts:188` 支援 snapshot store 與 disable 開關，成功取得資料時可沿用上述設計。
- `extensions/session/agent-db.ts:257` 有讀寫 memory snapshot 的持久化方法。

## 但目前 reconstructed production 沒有接通

- 全 source 的 `createSystemPromptAssembly` 唯一實例化位於 `host-runner-composition.ts:1339`；該依賴在 1353–1357 行傳入 `compactionEpoch: () => 0`，memoryStore、memorySnapshots、userMemory、projectMemory 都回傳 null。
- `getMemorySection` 在 memoryStore 為 null 時直接 return，因此這條路徑不會走 snapshot resolver。
- composition 另有 runnerOptions 與 setter 傳入 session memory／db，但 `sand-agent-runner.ts` 的 `#memoryStore`／`#memorySnapshots` 在目前 source 中只有宣告與 setter 賦值，沒有讀取；不能以 setter 存在推論已注入或已凍結。
- 全 source 中 `resolveFrozenMemoryPrompt` 的唯一呼叫位於上述 assembly；`getMemoryPromptSnapshot` 的消費也只在此處。此結論限該 reference commit，不推論原始閉源產品或其他版本的行為。

因此前輪把它列為「原版目前執行中的剩餘差異」證據不足。正確狀態是 **參考設計存在、production 接線缺漏；Filicon 未實作跨 epoch 記憶凍結**，不是已完成，也不是確定要把当前即時記憶改成永久快取。

## Filicon 現況與若要補設計的前置條件

- `ToolLoop.swift` 每次模型工具迴圈會向 host executors 重新取得 runtime context；`AgentManagementSession` 重新取得 account／agent 的 memory access 與 joined projects，再做 recall。
- 管理 session 以 originating request 建立，不是持久 conversation epoch。`AgentConversationStore` 保留最近 30 則 peer context，群組 responder 選最近 40 則；這些裁切不等同語意摘要或 compaction epoch。
- 不能在 management actor 加一份跨請求不明期限的 String 快取便宣稱 parity。若實作設計，需先定義並接線 conversation／agent／account 的 context epoch、持久化與重開策略，再限定快照只含記憶資料，不得凍結工具能力／授權／群組成員。
- 必須測試同 epoch 穩定、空記憶之後首次保存可見、epoch 更新、跨帳號／代理人隔離、Forget 與離開專案後不再注入舊事實、撤銷及保存失敗。已送出的 transcript 不能被新快照機制宣稱抹除。

這項仍保留為設計缺口；不以狹義靜態核對宣稱整體 parity 完成。下一輪優先回到完整 parity matrix 的已確認可達流程與缺口，避免僅因看見未使用 helper 就擴張實作範圍。
