# 完成驗收入口（2026-09-27）

本檔不取代使用者要求或縮小 parity 範圍。基準 Filicon `a7ca268`、reference `a9f633e09d49a85829b8236331b9e21f7e612634`；工作樹檢查為乾淨。沒有啟動 App、使用外部帳號或重新驗證 release。

## Matrix 不是完成證明

`PARITY.md` 有 48 個 ID：43 個歷史 complete、4 個 partial（AGENT-01／02／04、AUTO-03）、1 個 NA（UPD-04）。complete 必須逐項連到當前可達流程、對應測試及必要 runtime 驗收；「final gates passed」本身不能證明全功能對等。近期完整 Swift 測試／原生 build／package verifier 是回歸與封裝證據，不替代外部帳號、權限 UI 或 release 驗收。

以下保留全部驗收範圍：UI-01…04、CONV-01…04、ATT-01…04、PROV-01…04、MCP-01…04、AGENT-01…04、AUTO-01…04、COMP-01…04、ACCT-01…04、NOTIF-01…04、PERS-01…04、UPD-01…04。尚未逐項重驗者標記為未重驗，不推論缺失，也不視為已完成。

## 自身側欄可見性：基準缺口與實作驗收

以下依提交順序保留歷史進度；最新 App 接線狀態見本節末的「模型入口」。不以中間階段的「尚未接線」當成目前結論，也不以此單一功能取代其餘 48 項驗收。

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

### 可見性搜尋投影（2026-09-27）

新增 Domain `ConversationVisibilityOverride`，只對相符的 conversation＋account／agent binding 生效，否則保留 legacy hiddenAt。repository 在訊息 FTS、媒體、備援掃描與聊天搜尋排名／上限前套用 override；備援的聊天掃描上限也在可見性過濾之後。串流 live input 與 persisted hit 使用相同、經資料庫 binding 驗證的可見性，避免已恢復的舊 hiddenAt 聊天仍不可搜尋。includeHidden 保留既有含隱藏搜尋用途；不改寫歷史或 legacy 欄位。測試以 56 個命中驗證排除／恢復、limit=1、三種搜尋、備援、串流，以及重新綁定後舊 override 不再生效。

此 API 尚待 App 將已保存的 agent visibility snapshot 傳入，並與側欄列表、人工隱藏／恢復及 lifecycle fence 一起接線；不視為使用者端功能已完成。

驗證：定向搜尋測試通過；包含最終串流與備援規則的完整 nonparallel Swift tests exit 0，原生 Debug build exit 0，verify-package deep/strict 通過。日誌 `.build/validation/sidebar-search-{focused,full,native}.log` 不提交。

### App 可見性與人工恢復（2026-09-27）

App 現在於啟動、重新載入及 agent snapshot 更新時讀取已保存的側欄設定；側欄、隱藏聊天、預設選取與三種搜尋共用精確 binding 的 effective visibility。使用 snapshot revision 防止較舊的串流事件覆蓋人工操作剛取得的新狀態，設定更新也會使搜尋結果失效並重新查詢。

已綁定成員的聊天由人工隱藏／恢復時，先驗證目前帳號及 durable conversation binding，再保存 override，成功後才改畫面；磁碟失敗保留原狀。刪除聊天及切換帳號會關閉待提交 lifetime。人工可恢復已封存成員的聊天，但不解除封存、不改通知、不改寫聊天歷史。未綁定聊天仍沿用 legacy hiddenAt 路徑。本批的隔離 App 測試涵蓋保存／重開／搜尋、磁碟失敗、外部帳號、封存後恢復及舊快照拒絕。

模型 preparer 仍未注入。接續須完成模型核准後的唯一 binding 重驗及生命週期提交 fence、可見性 quota 記帳，再做模型端到端測試；本批不代表原版設定工具已完整啟用。

驗證：定向測試通過；含最終 revision 防護的完整 nonparallel Swift tests 與原生 Debug build 均 exit 0，verify-package deep/strict 通過。日誌 `.build/validation/sidebar-app-{focused,full,native}.log` 不提交。未啟動 App 或修改真實資料。

### 唯一 binding 提交憑證（2026-09-27）

新增短期 `ConversationBindingLease`。repository 在同一次無 suspension 的操作中查找唯一綁定並登記憑證；保存聊天集合前，若目標被刪除、重新綁定或新增第二個相同 account／agent 綁定，先同步撤銷。改名及新增訊息不撤銷。`AgentService.applyBoundSettingsChange` 檢查精確 account／agent／conversation，依「binding lease → settings lifetime → 同步磁碟保存」順序持鎖，讓撤銷和設定保存有明確先後；未保存不產生 receipt，通知與可見性仍同時提交。

隔離測試涵蓋改名／訊息成功、刪除／重綁／重複／手動撤銷取消、錯誤目標拒絕及重開後兩欄位一致；模糊 binding 也不能取得憑證。此憑證只保護透過核發它的 repository 執行的寫入，**不是跨程序或不同 repository instance 的資料庫鎖**。

App 尚未啟用模型 preparer；還要將憑證取得、finally 撤銷、來源生命週期、quota 及保存後畫面接線並完成 App 測試。來源查找確認目前 AppModel 建立一個 ConversationStore，該 store 快取一個 repository；若新增不同 repository instance 的寫入路徑，必須先統一或擴充 fence，不能直接宣稱端到端已完成。

驗證：定向 13 項測試通過，含最終精確錯誤斷言的完整 nonparallel Swift tests／原生 Debug build 均 exit 0，verify-package deep/strict 通過。日誌 `.build/validation/sidebar-lease-{focused,full,native}.log` 不提交；未啟動使用者 App，未改真實資料。

### 模型入口（2026-09-27）

App 已注入 sidebar preparer。模型可提出 optional `hidden_from_sidebar`／`notify_on_updates`，至少一項；host 依當前帳號和自身 agent 查唯一 direct chat，模型無法指定目標 ID。核准卡列出兩個設定的 before/after 及聊天 ID。核准後重新取得 repository lease；聊天刪除或帳號切換會同步撤銷 App 登記的 lease，原有 session lifetime 保護 Stop。legacy hiddenAt 變更也撤銷 lease，避免核准舊狀態後覆蓋人工操作。通知與側欄各自先保留 quota，兩者由同一次 agents state 保存；保存後才更新共用 snapshot。晚到的 quota 記帳錯誤保留 durable receipt，不謊稱資料回滾。

App fixture 覆蓋隱藏／恢復、合併修改及單改可見性保留通知、核准前未變更、拒絕／停止／切帳號／刪除／重複綁定／封存／磁碟失敗／人工版本衝突、重開保留與不影響群組成員及他人通知。缺少或歧義聊天在核准前拒絕。服務／repository 測試另涵蓋重新綁定、舊 hiddenAt 變更、嚴格 boolean、重播、保存失敗及精確帳號投影。

驗證：runtime 最終 source 的完整 nonparallel Swift tests／原生 Debug build exit 0，verify-package deep/strict 通過；最後新增的人工版本衝突及 legacy hiddenAt 測試再定向通過（App 20＋2 cases，repository 8 cases＋查找測試）。日誌 `.build/validation/sidebar-host-{focused,full,native,final-focused}.log` 不提交。

原生 App 採單一 ConversationStore／repository；憑證仍不是跨程序 CAS。未做真實帳號操作、沒有啟動使用者 App；整體 parity 仍須下列其他分類的當前證據，不能標記全部完成。

## 必須保留的其他分類

- 下一個已確認本機缺口：模型主機／box 圖片頭像；已核對 reference schema、state 實作及 composition 的 readBoxFile 接線，以及 Filicon 僅 pet 的模型入口與可重用基礎。來源、差異與完整驗收條件见 [Avatar-image-parity.md](Avatar-image-parity.md)，不能以人工圖片 UI 或當輪附件 ID 替代。

- 記憶：最新保存／搜尋／synthesis／episode／project recall 證據見 `Memory-archive-parity.md`；跨 epoch snapshot 是未接線參考設計，見 `Memory-snapshot-audit.md`，不能自行換成永久 cache。
- 協作／訊息：AGENT-02／04 的歷史缺項需與 `Agent-collaboration-parity.md` 後續進度及 current source 逐項對照；不能用舊行的「缺」覆蓋已完成的接線，也不能以有 UI 就宣稱工具／背景路徑完成。
- 平台事件：AUTO-03 的 Teams 使用者驗證、GitHub checks 彙整、Slack 名稱／自身身分映射等仍需逐項來源核對和平台驗收；不因 generic matcher 通過而放寬驗證政策。
- 發佈／外部能力：UPD-03 的既有 release 是歷史證據，本目標禁止 push／真實帳號修改；不能擅自發新版本、連接帳號、安裝插件或替使用者授權。最終報告須明列尚需哪些外部驗收與決策，不把它們藏在 complete 標籤後。
