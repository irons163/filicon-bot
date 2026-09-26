# Episodic 記憶：參考行為與待實作驗收

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
