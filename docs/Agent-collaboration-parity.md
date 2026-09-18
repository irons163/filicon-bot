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
| 每 agent 統一 exclusive lane | `runLifecycle.enqueueExclusiveRun(session.id, …)` | 已接上 App 內共用 `AgentExecutionScheduler`：群組回合、跨來源 mailbox、子任務、自動化、工作流程、頻道回覆共用每 agent 一般工作 FIFO（優先訊息例外見下列）；不同 agent 可並行。`AgentExecutionSchedulerTests` 與 `AgentBackgroundExecutionTests` 驗證排隊、取消、逾時與主要 App 入口。**不是完整原版 runtime**：未綁定 agent profile 的一般單獨聊天仍只按 conversation 排程；不包含跨程序協調或重啟排程重播；有限優先中斷見下列 |
| 群組目標／broadcast | `source/host/extensions/transcript/shared-rooms.ts` 的 `postToGroup`；`agents/agent-messaging.ts` directory | **已接線受限文字版**：群組／mailbox 的 `SendToAgent` 接受自己所屬、所有成員均啟用中的其他群組 UUID。完整成員、群組與文字審批後原子貼入共用房間，再讓其他成員用既有群組 runner 回覆；不是逐人私訊。來源對話私人上下文不轉貼，工具仍沿用來源核准範圍與新 run ID。每次最多兩個不同群組／六次總委派，群組各保留三輪／十則上限與每回合 180 秒期限。**與參考的差異**：忙碌群組拒絕而非排入其 active lane；目前房間使用 SendMessage；發起者不因自己的貼文再自動喚醒；不含跨所有房間的統一私人記憶。`AgentGroupMessagingTests`、`AgentGroupMessagingAppTests` |
| 圖片訊息 | `loadAgentInboundImages`／`selectedImages`、`agents/agent-messaging.ts` 的 images | **已接線受限版本**：代理人 → 訊息可手動選擇 PNG/JPEG，實際位元組傳入支援看圖的收件模型。peer `SendToAgent(images:[id])` 只能轉交本次收到的圖片，回信也必須重新預覽核准；拒絕任意路徑、網址、base64 與其他訊息的 ID。最多四張／單張 5 MB／合計 12 MB，存為雜湊驗證的獨立 blobs。**尚缺**：參考的 file/HTTPS 圖片來源、模型新產生的圖片、一般群組輸入圖片、SendMessage 圖片、歷史圖片自動重播。群組目標圖片明確拒絕；不支援看圖的模型明確失敗，不默默丟棄圖片。`AgentImageMessagingTests`、`AgentImageAppIntegrationTests` |
| 優先訊息中斷非使用者工作 | `steerRecipientForPriorityPeer`，先檢查 active lane != user | **已接線受限版本**：單一 peer 的 `priority:true` 每次須核准（回信也不豁免），manual Priority 也接上排程。來源回合結束並 drain 後，可取消收件者正在執行的背景 peer／委派群組回覆／排程自動化，等 host 工具清理完才啟動優先工作。排隊中的使用者工作及較早優先訊息不被插隊；前景群組、手動 mailbox 首回合、手動 Run Now、channel／workflow／subtask 均受保護。不自動重播被中斷工作；群組 priority 拒絕。**差異**：不是參考的 enqueue 當下立即中斷，保護範圍更保守。`AgentExecutionSchedulerTests`、`AgentMessagingSessionTests`、`AgentBackgroundExecutionTests` |
| 模型建立／編輯代理人 | `source/host/agents/agent-messaging.ts`: CreateAgent、UpdateAgent | **已接線受限版本**：群組、手動 mailbox 與 peer wake 提供 `CreateAgent(name, description?)`／`UpdateAgent(agent_id, name?, description?)`。每次完整顯示變更並明確核准；每個來源請求共用四次上限。新代理人沿用發起者 provider/model，description 成為公開摘要與初始指令；Update 只合併名稱與公開摘要，不修改私人指令。`AgentManagementSessionTests`、`AgentManagementAppIntegrationTests`。不替未綁定 agent 的一般 DM 加上管理權限 |
| 模型修改自身公開資料 | `source/host/runner/tools/sand-state-tool.ts` 的 `update_state` profile/set；`source/host/extensions/memory/agent-state.ts` 的 `updateProfile` | **已接線受限版本**：`update_state(target:"profile", action:"set", name?, description?)`。身分由 host 固定；不得傳入別人的 ID。可明確清空公開 description，省略欄位保留原值；私人 persona 不變。每次仍需使用者核准，與 CreateAgent／UpdateAgent 共用四次上限。下一個群組回合重新載入 profile，原請求參與成員不擴大。仍未提供此工具的 memory／routine／workflow／settings／channel／project／avatar 路由，也不是原版私人記憶服務 |

## 安全差異

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

最終完整套件為 134 XCTest、629 Swift Testing（81 suites），零失敗；兩個 opt-in live Codex 測試仍未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign 與 `git diff --check` 通過。七語言各 1,413 keys、零缺漏；實際圖片預覽／揭露元件產出七語言 PNG，繁中與法文已目視檢查。這不是完整產品逐頁驗收或真實模型端到端驗證，也不是 release 公證。未 push、未重啟使用者的 App；本批圖片修改尚未提交。剩餘範圍仍以上表的部分／尚缺為準。
