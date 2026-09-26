# 長期記憶容量與歷史檢索核對

核對日期：2026-09-27。參考 `grok-bot-0.18-reconstructed` commit `a9f633e09d49a85829b8236331b9e21f7e612634`；Filicon 基準 `94937dd`。原始碼核對，不是真實模型或 UI 驗收。

## 參考實際行為

- `source/host/extensions/memory/memory-service.ts` 的 `FileMemoryStore.facts()` 讀取 `profile.md` 與所有月份 log 檔；`addMemory()` 正規化／去重後追加對應月份檔案，這條路徑沒有 48 筆或 12,000 字儲存上限。
- 同檔 `listMemories(limit = 100)` 是一次讀取結果的限制，先 profile、再日期排序，不是保留容量。`recall` 同樣只裁切注入結果，不刪檔案中的歷史。
- `source/host/runner/sand-memory.ts`：`MEMORY_EXTRACTION_ARCHIVE_SCAN_LIMIT = 500` 是抽取時掃描筆數；`gatherExtractionMemories` 在已注入記憶之外，從這批歷史候選依 token overlap 選最多 10 筆。不能把 500 當作 archive 容量。
- `source/host/runner/turn-memory.ts` 的 `runMemoryExtraction` 確實傳入 `recall(30)`、`listMemories(500)` 及當回合文字。
- `renderMemorySystemPrompt` 告知代理人可用 Read／Shell 查 profile／log 以取得未注入的舊記憶。這是參考環境的工具能力；不代表 Filicon 已有任意檔案讀取授權。

## Filicon 已有與缺少

| 面向 | 現況與證據 | 結論 |
| --- | --- | --- |
| 長期保存 | `AgentService` 的 explicit、suggestion、synthesis、episode 四條保存入口皆受 48 筆／12,000 字私人容量限制；另有 8 筆 profile 限制 | 不是參考的持續追加歷史 |
| 注入裁切 | `AgentMemoryRecall` 按 scope、重要性／相關性與 bytes 選取；未注入不等於刪除 | 基本區別已存在，不應為擴容取消 prompt 預算 |
| 歷史搜尋 | `AgentMemorySearchPage` 可分頁搜尋所有可見已存事實，每頁最多 8 筆及 7,000 bytes；session 另有 32 次上限 | 不是只搜注入結果，但搜尋空間仍受保存容量限制 |
| 抽取候選 | `AgentMemorySuggestionExtractor` 傳入 existingPrivateFacts；目前不是獨立的 500 掃描＋10 個歷史相關候選分支 | 需在擴容前核對並限制實際模型輸入 |
| 檔案 archive | 事實存在 `agents.json`，沒有原版月份記憶目錄，也沒有等價的超出 active 容量後保留區 | 尚缺，不能只提高常數就稱完成 |
| 來源與刪除 | 已有 host episode origin、synthesis origin、顯式刪除 tombstone 與帳號／作者／project 邊界 | 新儲存層必須沿用，不能以 archive 重新喚回已忘記事實 |

## 下一階段必要驗收

1. 分開「長期保存容量」與「每次注入／抽取預算」；讓超過目前 48 筆的正常新增保留歷史，不以刪舊事實換空間，也不向模型傳送全部歷史。
2. 保留既有來源、日期、帳號、作者與 project 身分，舊儲存可載入；每個新增／刪除入口採同一持久化與失敗策略，不能只讓 episode 超額而漏掉其他入口。
3. 搜尋與人類管理頁能分頁取得未注入歷史；忘記操作跨保存區域一致且重開後不復活。非成員、其他帳號及其他代理人的私人事實仍不可讀。
4. 抽取候選涵蓋 bounded archive scan 與相關性挑選；synthesis 的 snapshot／verification／stale 檢查仍完整，payload 有明確上限。
5. 加入超過 48 筆／12,000 字、歷史命中、相同內容去重、刪除重開、儲存失敗回滾、帳號／project 隔離與輸入預算測試，並驗證 UI 管理流程。

此核對不新增檔案／Shell 權限，不調高真實使用者配額或擅自移動既有資料。長期記憶整體仍為 partial；上列是尚待實作的功能要求，不是已完成宣告。
