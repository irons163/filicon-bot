# 長期記憶容量與歷史檢索核對

核對日期：2026-09-27。參考 `grok-bot-0.18-reconstructed` commit `a9f633e09d49a85829b8236331b9e21f7e612634`；Filicon 基準 `94937dd`。原始碼核對，不是真實模型或 UI 驗收。

## 參考實際行為

- `source/host/extensions/memory/memory-service.ts` 的 `FileMemoryStore.facts()` 讀取 `profile.md` 與所有月份 log 檔；`addMemory()` 正規化／去重後追加對應月份檔案，這條路徑沒有 48 筆或 12,000 字儲存上限。
- 同檔 `listMemories(limit = 100)` 是一次讀取結果的限制，先 profile、再日期排序，不是保留容量。`recall` 同樣只裁切注入結果，不刪檔案中的歷史。
- `source/host/runner/sand-memory.ts`：`MEMORY_EXTRACTION_ARCHIVE_SCAN_LIMIT = 500` 是抽取時掃描筆數；`gatherExtractionMemories` 在已注入記憶之外，從這批歷史候選依 token overlap 選最多 10 筆。不能把 500 當作 archive 容量。
- `source/host/runner/turn-memory.ts` 的 `runMemoryExtraction` 確實傳入 `recall(30)`、`listMemories(500)` 及當回合文字。
- `renderMemorySystemPrompt` 告知代理人可用 Read／Shell 查 profile／log 以取得未注入的舊記憶。這是參考環境的工具能力；不代表 Filicon 已有任意檔案讀取授權。
- 補核對：`memory-service.ts` 的 `prepareSynthesis()` 以完整歷史建立 fingerprint，但給模型的記憶按 explicit、profile、近期排序、ID 去重後取最多 `MEMORY_SYNTHESIS_INPUT_LIMIT = 512` 筆。`applySynthesis()` 檢查完整 fingerprint，且 update/remove ID 必須在選中 snapshot 內。先前把「逐批遍歷所有歷史」列為原版必要功能不準確；原版並不保證每筆歷史都会被 synthesis 檢視。

## Synthesis 候選與完整歷史界線（2026-09-27）

- `AgentMemorySynthesisSnapshot` 保留所有私人事實與 tombstones 供 equality/stale fence，另產生 explicit 優先、profile 次之、日期新到舊的最多 512 個候選；Filicon 額外限制實際事實 JSON 64,000 bytes，不截斷內容，超預算者略過但仍保留在完整歷史。
- Proposal／verification 使用同一 `inputMemories`；`mutableMemoryIDs` 只包含該投影中 host origin 為 synthesis 的項目。Apply 仍從完整歷史修改，沒有把投影當完整儲存覆寫；未入選資料變动仍造成 stale，未入選目標不得 update/remove。
- 這取代下方歷史進度中的「大容量 synthesis 分批待補」說法：parity 所需是有界候選與完整資料 fence，不是自行加入遍歷批次。原版同樣可能持續略過較舊事實；不宣稱所有歷史自動整理完成。
- 602 筆歷史測試驗證 explicit／profile 優先、64,000-byte 事實預算、正常提交後重開保留 603 筆、未入選 ID 不得刪除、未入選資料被人類刪除後舊提案失效。完整測試 exit 0（`.build/validation/memory-synthesis-projection-full.log`）、原生 Debug 建置與封裝簽章通過。未啟動 App 或使用真實模型。

## Filicon 已有與缺少

| 面向 | 現況與證據 | 結論 |
| --- | --- | --- |
| 長期保存 | `AgentService` 的 explicit、suggestion、synthesis、episode 四條保存入口已移除歷史 48 筆／12,000 字限制；私人、使用者共享與專案 scope 同步套用，仍保留 8 筆 profile 限制與單筆驗證 | 可追加歷史，但尚未完成大資料量驗收與 profile 容量對齊 |
| 注入裁切 | `AgentMemoryRecall` 按 scope、重要性／相關性與 bytes 選取；未注入不等於刪除 | 基本區別已存在，不應為擴容取消 prompt 預算 |
| 歷史搜尋 | `AgentMemorySearchPage` 可分頁搜尋所有可見已存事實，每頁最多 8 筆及 7,000 bytes；session 另有 32 次上限 | 搜尋全部保存歷史，不是只搜注入結果 |
| 抽取候選 | `AgentMemorySuggestionExtractor` 使用 `AgentMemoryExtractionContext`：私人近期 recall，加上 profile 優先／日期排序的最多 500 筆歷史候選中最相關的 10 筆；跨池正規化去重，事實陣列 JSON 上限 16,000 bytes，不截斷事實 | 抽取投影已補；500 是候選筆數，不是保存容量 |
| 檔案 archive | 事實仍存在 `agents.json`；超過 recall 預算的事實不刪除，可搜尋／刪除／重開；沒有原版月份記憶目錄 | 語意上保留歷史，月份檔案與大資料量效能尚未對齊 |
| 來源與刪除 | 已有 host episode origin、synthesis origin、顯式刪除 tombstone 與帳號／作者／project 邊界 | 新儲存層必須沿用，不能以 archive 重新喚回已忘記事實 |

## 下一階段必要驗收

1. 分開「長期保存容量」與「每次注入／抽取預算」；讓超過目前 48 筆的正常新增保留歷史，不以刪舊事實換空間，也不向模型傳送全部歷史。
2. 保留既有來源、日期、帳號、作者與 project 身分，舊儲存可載入；每個新增／刪除入口採同一持久化與失敗策略，不能只讓 episode 超額而漏掉其他入口。
3. 搜尋與人類管理頁能分頁取得未注入歷史；忘記操作跨保存區域一致且重開後不復活。非成員、其他帳號及其他代理人的私人事實仍不可讀。
4. 抽取候選涵蓋 bounded archive scan 與相關性挑選；synthesis 的 snapshot／verification／stale 檢查仍完整，payload 有明確上限。
5. 加入超過 48 筆／12,000 字、歷史命中、相同內容去重、刪除重開、儲存失敗回滾、帳號／project 隔離與輸入預算測試，並驗證 UI 管理流程。

此核對不新增檔案／Shell 權限，不調高真實使用者配額或擅自移動既有資料。長期記憶整體仍為 partial；上列是尚待實作的功能要求，不是已完成宣告。

## 歷史保存路徑（2026-09-27）

- 四條保存入口移除 48 筆／12,000 字總量拒絕條件，沿用原有單一 JSON 原子保存與失敗回滾，不新增第二份 archive 或遷移真實資料。Profile 仍限 8 筆；單筆內容、審批、tombstone、來源與 scope 驗證保留。
- 顯式寫入改用與 suggestion／synthesis／episode 相同的正規化 fact key 去重；比較仍限同一私人／共享／專案保存範圍。
- 新整合測試先以 explicit 保存 60 筆、超過 12,000 字，再通過 suggestion approval、兩階段 synthesis、兩階段 episode 保存；重開保留 63 筆與來源，recall 仍裁切。私人／共享測試涵蓋舊筆數及字數上限、重開、刪除再重開；專案測試涵蓋兩種舊上限與離開成員刪除。
- 這不是全部 archive parity 完成：目前仍整份 JSON 保存；大資料量 I/O、管理介面分頁、synthesis 分批、profile 容量差異及月份檔案布局仍待处理。上方必要驗收清單是整體要求，本節只記錄已完成部分。
- 最終完整 `swift test --no-parallel` exit 0（`.build/validation/memory-retention-final.log`），原生 Debug 建置與 App／XPC 封裝簽章驗證通過。七語限制提示已更新；沒有啟動 App 或變動真實資料。

## 抽取投影驗證（2026-09-27）

- `AgentMemorySuggestionTests` 9 tests 通過：新增 520 筆純資料 fixture 的近期＋歷史選擇、500 筆外不命中、輸入順序無關、跨帳號／作者／共享 scope 排除、跨 tier 去重及 JSON escape／多位元組大小檢查；既有 provider 輸入隔離與撤銷測試維持通過。
- 完整 `swift test --no-parallel` exit 0（`.build/validation/memory-extraction-context-full.log`）；原生 `Filicon App` Debug 建置與 `verify-package.sh --xcode-debug` 通過，未啟動 App。
- fixture 的 520 筆只驗證投影，不代表持久化已支援超過 48 筆。下一步仍須處理整份抽取輸入／synthesis 預算、儲存容量與管理介面。

## 人類管理頁分頁（2026-09-27）

- `memoryEditorPage` 在 actor 內先篩選帳號／scope，再依既有穩定排序切每頁 20 筆；shared／project 保留離開或封存作者的記憶供人類管理，不擴大模型讀取權限。
- AppModel 包裝沿用帳號 generation fence；SwiftUI 僅持有目前頁面，七語上一頁／下一頁／頁碼，重新整理與刪除回第一頁。非同步結果與錯誤受 request ID 與帳號檢查保護；帳號、代理人或 scope 變更重設頁面。
- 頁面是新鮮快照而非跨頁凍結游標；外部新增／刪除可能改變邊界，可重新整理。越界頁碼會 clamp，不留空白末頁。Service 仍從整份已載入 JSON 排序，這次不宣稱磁碟分頁或大資料量 I/O 已解決。
- 私人／共享 41 筆測試驗證 20／20／1、負值／Int.max clamp、跨帳號隔離、末頁刪除後重開；專案頁合併結果等於完整 editor 清單。七語控制項在 340pt 寬度渲染首／中／末頁；檢視繁中、法文圖未見截斷。
- 完整測試 exit 0（`.build/validation/memory-editor-page-final.log`）、原生 Debug 建置、App／XPC 封裝簽章驗證通過。圖片位於 `/private/tmp/filicon-memory-pages-review/memory-pages-*.png`；這是隔離控制項渲染，不是真實 App 點擊驗收。

## 輸入總量防線（2026-09-27）

- 抽取的 user／assistant 各取最多 8,000 Unicode scalars（不再僅依 grapheme 數），整份編碼 JSON 上限 128,000 bytes；測試用一個包含 100,000 組合符號的字元驗證不能繞過限制。這只限制背景抽取輸入，不更動原對話。
- Synthesis proposal JSON 上限 262,144 bytes，verification JSON 上限 524,288 bytes，超限拒絕送到對應 provider 階段；不截掉證據或 mutable IDs，也不保存提案。加入 12 個各欄合法、但 escaping 後總量超限的案例。
- 這是 fail-closed 大小防線，不是大容量 synthesis 的完整解法。擴容仍須加入可處理全部歷史的分批／候選策略、保持 snapshot stale 檢查與刪除邊界，避免僅因 archive 增長而永久無法 synthesis。
- 完整 `swift test --no-parallel` exit 0（`.build/validation/memory-payload-budget-full.log`）、原生 Debug 建置及 App／XPC 封裝簽章檢查通過；未使用真實帳號資料或啟動 App。
