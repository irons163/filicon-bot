# 協作能力核對紀錄（2026-09-19）

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
| 模型修改自身公開資料 | `source/host/runner/tools/sand-state-tool.ts` 的 `update_state` profile/set；`source/host/extensions/memory/agent-state.ts` 的 `updateProfile` | **已接線受限版本**：`update_state(target:"profile", action:"set", name?, description?)`。身分由 host 固定；不得傳入別人的 ID。可明確清空公開 description，省略欄位保留原值；私人 persona 不變。每次仍需使用者核准，與 CreateAgent／UpdateAgent、memory、avatar 及 routine 變更共用四次上限。下一個群組回合重新載入 profile，原請求參與成員不擴大。memory／avatar 支援範圍見其他列；routine 支援下列有限 create/update/pause/resume/delete；workflow／settings／channel／project 路由仍缺 |
| 模型修改自身頭像 | `source/host/runner/tools/sand-state-tool.ts` 的 avatar set/clear；`source/host/extensions/memory/agent-state.ts` 的 setAvatar/clearAvatar | **部分接線，來源不同**：群組／mailbox 可呼叫 `update_state(target:"avatar", action:"set", pet_id:...)` 選九種內建小寵物，或 `action:"clear"`（不得附 pet_id）恢復 Codex。每次顯示新頭像與原頭像類型並核准；只可改 host 固定的自身 ID。與 profile／memory 共用四次上限，Stop／帳號切換撤銷、核准期間頭像被改則拒絕舊提案；只合併頭像，不覆蓋其他欄位、不刪舊圖片檔案。**未還原參考的任意 host/box path 圖片安裝**，不接受路徑、URL、base64 或模型生成圖；不能視為完整 avatar parity。`AgentAvatarChangeTests`、`AgentManagementAppIntegrationTests` |
| 明確保存／忘記自身事實 | `source/host/runner/tools/sand-state-tool.ts` 的 memory write/forget；`source/host/extensions/memory/agent-state.ts` 的 memory shards | **已接線受限版本**：群組／mailbox 的 `update_state(target:"memory", action:"write"或"forget", fact:...)` 預設為私人 `scope:"agent"`，共享 scope 見下一列。write 的 tier 接受 profile／log／note（預設 log），forget 使用記錄原文且不得傳 tier。帳號＋代理人由 host 固定，跨 origin、重啟後同一代理人的 group/mailbox runtime 會取得已核准事實，其他代理人／帳號不注入私人事實。每次增刪都顯示全文並核准；UI「代理人 → 編輯 → 代理人記憶」可重新整理、檢視及確認忘記。每事實 1,000 字元；每帳號／代理人 48 項（含最多 8 項 profile）、合計 12,000 字元；不自動淘汰。**尚缺**：project scope、DM／自動化等其他入口統一記憶、完整私人歷史 session。不是自動捕捉整段聊天。`AgentMemoryTests`、`AgentManagementAppIntegrationTests` |
| 共享使用者事實 | `memory-service.ts` 的 `SharedUserMemoryStore`、`sand-memory.ts` 的 `renderUserMemorySystemPrompt`／`mergeUserMemoryShards`；`agent-state.ts` 的 user shard | **已接線受限版本**：同一工具明確指定 `scope:"user"` 後，逐次核准共享給帳號內所有現有／未來代理人的 group/mailbox 模型，含群組外代理人。省略 scope 或舊紀錄缺少 scope 一律維持 private agent。保留紀錄者 UUID、tier／日期／scope 來源；模型只能忘記自己的同 scope 原文；UI 可管理所有作者的共享紀錄。共享 account 全部作者合計 48 項、8 項 profile、12,000 字元，與私人額度分開，不自動淘汰。**差異**：寫入仍按同 scope 精確文字全體去重，召回另按大小寫／空白摺疊並保留較新原文、tier 與作者；有重要性排名與獨立預算，詳見下一列。project scope 仍拒絕，其他執行入口仍未注入，沒有自動抓取整段聊天。`AgentMemoryTests`、`AgentManagementAppIntegrationTests` |

### 自身 routine 建立／修改／暫停／恢復／刪除

已核對 reconstructed `source/host/runner/tools/sand-state-tool.ts` 的 `routine.create/update/pause/resume/delete` 分派與 `extensions/memory/agent-state.ts` 的自身排程操作。Filicon 的 group/mailbox 透過 `update_state(target:"routine", action:"pause"、"resume"或"delete", id:...)` 操作自身既有排程；這三個 action 只接受 target/action/id，不得夾帶定義欄位。目錄只列 host 固定 owner 的 ID／名稱／啟用／費用防護狀態，不列其他代理人的任務。每次展示 ID、完整任務與 trigger JSON 並重新核准，auto-review allow 不豁免，與 profile／memory／avatar 共用四次額度。

同一入口另支援有限 `action:"create"`／`"update"`：create 需 name／prompt，以及 schedule 或 trigger（不可同時指定），enabled 可省略且預設 true，ID 及 owner 由 host 產生；update 需自己的 id 及至少一個變更欄位，省略欄位保留。name 最多 80 字元、prompt 32,000、schedule 256，每 owner 最多 50 項。時間排程支援 cron／alias／`@every`（1 分鐘至 366 天）；新 schedule 固定當次 App 時區，可由有效 TZ/CRON_TZ 前綴覆蓋；舊時間定義缺少時區時，須提供 schedule 才能明確固定時區。

單個 GitHub 事件條件：`{type:"github",repo:"owner/repo",events:[...],userAllowlist?:[...],ciBranch?:...}`。repository 須具體、events 須為既有 14 種已知名稱、使用者最多 50 位；未知欄位／事件／錯誤類型／空篩選項／不合法分支會被拒絕，不默默丟掉限制。空 userAllowlist 代表不限對象；PR opened/pushed/merged/comment/inline-comment 篩選 PR 作者，review requested/approved/changes-requested/commented/thread-resolved/thread-unresolved 要求作者與操作人都在清單內，issue-assigned 篩選操作人。CI 不受使用者清單限制，必須指定一個有效分支；目前僅為該 repository 的個別 push workflow_run 完成（success／failure／timed_out），**不是原版所有 checks settled 的彙整或 PR CI**。時間、GitHub、Slack 與下述事件 OR 組合可經完整核准互換；其他平台、generic event、混合時間／事件與任意 trigger JSON 仍拒絕。既有已驗證事件連線必須另行設定，此工具不安裝／啟動 webhook、不登入外部服務；核准後待處理事件可能符合新定義。

Slack 事件寫入支援單一 `{type:"slack",channel:"C/G/D 對話 ID 或 *",match:{kind:...}}`，kind 為 message／mention／keyword／reaction；keyword 最多 120 字元，reaction 最多 8 個表情短名稱，清單省略或留空代表所有表情。channel 最多 80 字元且只接受具體 ID 或 `*`；`*` 涵蓋所有已設定連線實際送達的對話，不授予額外 Slack 存取權。mention 是 App／bot 被提及，mention/reaction 需既有已驗證的事件入口；既有 channel 訊息路徑仍支援 message/keyword，沿用 connector 的過濾方式，未保留 event subtype，因此不宣稱與 webhook 分類等同。已驗證 webhook 僅普通使用者訊息及對訊息新增的表情觸發；bot／subtype／編輯／刪除訊息、撤回表情與檔案表情不觸發。不支援原版的 `#channel`／`@人名` 解析與 `bySelf:true`：目前無可靠的使用者身分對應，因此明確拒絕，不把機器人身分當成使用者。未知／混用／null 欄位及無效篩選會在核准前拒絕；預覽顯示完整正規化條件與範圍限制。

另支援純事件 OR 組合：`trigger:{type:"group",listeners:[...]}` 或裸 `trigger:[...]`，原始輸入限 1–8 個 GitHub／Slack 條件且不得巢狀。所有條件先驗證，任一無效就拒絕整份提案，不丟棄限制；正規化後排序、去除完全相同條件，只剩一項則儲存為單一 trigger。任一條件命中同一任務即能觸發，不要求全部成立；同筆事件命中多條只納入一次，不同事件仍可能造成後續執行及費用。每條各自的頻道／repo／作者／操作人／CI 分支篩選維持不變，未命中內容不送入 prompt。去重包含 connector ID 及事件 ID、批次 key 使用長度分隔，防止跨平台 ID 碰撞和分隔符別名；已處理的送達紀錄在重新載入後仍去重。預覽顯示完整 OR 定義以及所有涉及平台的限制，不增加外部連線或權限。模型入口仍拒絕時間條件混合、generic event、其他平台及巢狀組合；後續已補 `.anyOf` 最早時間與事件共用執行基準的引擎基礎，但模型 schema、核准說明與完整混合條件寫入尚未開放。

建立／修改完整核准卡顯示新定義與 enabled；修改另展示舊 name／完整 prompt／trigger／enabled。新增／改排時間從核准提交後算，不補跑等待期間錯過的次數、不立即 Run Now；只改 name/prompt 保留現有 nextRun。提交時重新驗證容量、時程、費用防護及定義，沿用儲存額度與同步 lifetime fence；原子候選儲存成功才發布，durable receipt 區分寫入成功與後續 bookkeeping 失敗。修改只合併核准定義並保留最新 lastRun／history，已開始或排隊的 executor 保留舊任務。費用防護生效時拒絕啟用的新定義，受防護排程不得修改；可建立停用草稿，不因此解除任何防護。

暫停只禁止後續觸發，不取消已開始或已交給 executor 排隊的執行。恢復保留定義／歷史，按目前時間重新計算下一次觸發，不呼叫 Run Now、不補跑錯過的時間。費用防護暫停與未知 trigger（含巢狀）拒絕由此工具恢復，須由使用者到自動化頁檢視。核准後再次驗證 owner、revision、名稱／prompt／trigger／啟用及 guard 狀態；既有執行更新的 history／lastRun 不被舊 snapshot 蓋掉。儲存 candidate 成功後才改記憶體，寫檔失敗不得偷偷啟用工作。同步 lifetime 撤銷 fence 與 session receipt 沿用既有管理工具的語意。

刪除先展示無法復原的警告，核准 action 標為 destructive。原子移除定義及其費用防護 ID，不改其他排程、防護政策、執行歷史、wake 或 claims；寫檔失敗時記憶體不變。已開始／已交給 executor 排隊的執行不取消，完成後仍寫入歷史，不會把定義加回；尚未 dispatch 的 cron／事件批次重查定義後跳過已刪項目。執行歷史留在儲存空間，但現有 UI 不提供已刪排程的歷史入口，也沒有還原命令。不刪產出檔案、不斷開外部服務。可刪除停用／費用防護／未知 trigger 的定義，但不能藉此解除其他任務的防護。

這是 **部分還原**：除上述有限 GitHub／Slack 外，參考的其他 event/platform、時間與事件混合組合 create/update、Slack 名稱解析／自身身分篩選、GitHub checks 彙整及連動工作流程審查仍未接線（UI 既有操作不受影響）；Filicon 對每種 routine 變更都要求明確核准，也沒有因本項替自動化推論加上 host 工具。不是完整原版 automation runtime。

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

本輪引擎修改尚未提交；未 push、未重啟 App，未更動實際群組、聊天或排程。
