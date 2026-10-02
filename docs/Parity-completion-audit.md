# 完成驗收入口（2026-09-27）

2026-10-03 背景純文字增量：workflow／automation 的結果收集現在要求明確完成，拒絕遺失結尾、截斷、工具事件及晚到錯誤，並有累計 UTF-8 上限；明確空白 stop 和完成後 usage 仍接受。最後聚焦 41 tests／4 suites、完整串行回歸 exit 0：135 XCTest＋1,632 Swift Testing（兩項 opt-in live Codex 測試略過），原生建置／封裝簽章及七語檢查通過。這是既有 text-only 路徑的結果修正，不以此關閉背景 runner、記憶 audience、外部服務或全 48 分類驗收。

2026-10-03 workflow 生命週期增量：帳號切換現在同步撤銷整體 workflow 執行範圍，再取消 runtime 與共用代理人排程器；手動、已驗證事件、定時及重播四條入口均保留原始 dispatch fence。晚到核准／模型結果、同批後續 workflow 與舊 UI reload 不得跨越撤銷，成功歷史及 UI 投影使用同步提交 fence。43 項最終聚焦測試、原生建置／封裝簽章及七語檢查通過；最後完整回歸 exit 0：135 XCTest＋1,622 Swift Testing（兩項 opt-in live Codex 測試略過）。以下專節保留背景執行器與記憶授權的實際差異，不將本批取消修正寫成全背景 runtime 對等。

2026-10-03 最新圖片增量：第七十七／七十八階段補齊十一格式獨立傳檔 MIME、一般 AVIF／ICO／SVG 預覽判定與已驗證圖片快照／有界 PNG 縮圖，原始 CAS bytes 不替換。46 項聚焦測試、77 個新增 canonical App 案例及十四個七語預覽 render 通過。歷史中止／EPERM 日誌保留；受保護探針恢復後，最後全專案串行 gate exit 0：135 XCTest＋1,609 Swift Testing（核心 859／98 suites、App 527／74 suites；兩項 opt-in live Codex 測試略過），原生建置／封裝簽章與七語各 1,724 keys／0 missing 通過。未移除保護、未重啟使用者 App／Xcode。完整格式變體、AV／Quick Look URL 邊界、其他分類及外部驗收仍保留，不能以本批通過宣稱所有 48 分類完成。詳見 [傳檔第七十七／七十八階段](Send-message-files-parity.md)。

2026-10-03 最新 SVG 增量：第七十六階段已接入安全驗證器支援的靜態自包含 SVG，保留原檔並僅將顯示畫面轉為有界 PNG。53 項聚焦測試、56 個七語卡片與全部 436 個 canonical App 案例通過，既有頭像 SVG 回歸未受影響。最後全專案串行 gate exit 0：135 XCTest＋1,593 Swift Testing（核心 853、App 517）；原生建置／封裝簽章、七語各 1,724 keys／0 missing 通過。完整瀏覽器 SVG、真實 HEIF、其他變體、獨立傳檔 MIME 及其他分類驗收仍保留，不將本批靜態子集寫為全部對等。詳見 [傳檔第七十六階段](Send-message-files-parity.md)。

2026-10-03 最新增量：第七十五階段補上真正 AVIF／ICO 的經審核圖庫及共用預覽，保留原始 bytes／完整核准與 strict incoming／SendToAgent 邊界；八格式 viewer、42 個七語卡片與全部 386 個 canonical App 案例通過。最新全專案串行 gate exit 0：135 XCTest＋1,587 Swift Testing（核心 847、App 517）；原生建置／封裝簽章及七語各 1,724 keys／0 missing 通過。SVG、真實 HEIF、未覆蓋變體、獨立傳檔 MIME 與完整 lifecycle／外部驗收仍保留。以下日期段落是歷史進度，不能將當時 AVIF／ICO 尚缺當成目前狀態。詳見 [傳檔第七十五階段](Send-message-files-parity.md)。

2026-10-03 增量：經審核本機圖庫已接入 GIF／APNG／WebP 動畫及 TIFF／BMP／HEIC，原始 CAS bytes 與完整核准不變，strict incoming／SendToAgent 仍限唯一單幀 PNG／JPEG。核心 27、App 12 項聚焦測試（含全部 366 個 canonical publication 案例）通過。完整回歸首輪途中鎖定而中止，保留失敗日誌；受保護探針恢復後，最後完整串行 gate exit 0：135 XCTest＋1,586 Swift Testing（核心 846、App 517），原生建置／封裝簽章及七語各 1,724 keys／0 missing 通過。其他格式、真實 HEIF、獨立傳檔 MIME、快取及完整 lifecycle／外部服務驗收仍保留；原版不索引 text gallery 的別名，因此該 Filicon 限制不是已確認原版功能缺口。詳見 [傳檔第七十四階段](Send-message-files-parity.md)。

2026-10-02 增量：本機獨立傳檔、HTTPS 附件 locator 及文字內 local／HTTPS 混合圖片集已接入 direct、前景／背景群組、mailbox 與 direct peer；有完整核准、配額、重開及撤銷隔離測試。第七十一階段新增 GIF／APNG／WebP 有界內嵌播放；第七十二階段移除經審核圖庫的四張限制與 viewer 前 50 張截斷，新增有界本機縮圖；第七十三階段支援重複來源的獨立位置與說明，並修正直接對話 transcript 副本仍拒絕重複附件的實際缺陷。受保護儲存探針恢復正常後，最新全專案串行測試 exit 0（135 XCTest＋1,577 Swift Testing）；原生建置、封裝簽章／entitlements、七語各 1,723 keys／0 missing 通過。canonical App 路徑的原有 116、增加大量圖片 30、重複圖片 40 案例及 group／mailbox GIF／APNG 保存重開均通過；未移除檔案保護、未重啟 App／Xcode、未修改真實帳號或群組。模型輸入／SendToAgent 四張、本機 5／12 MiB 與工具參數預算不變。下方日期段落是歷史進度，不能以「尚未接線」覆蓋後續實作；最新媒體證據與本機格式、大檔、alias 搜尋、快取、完整 crash／UI lifecycle 等邊界見 [傳檔第六十九至七十三階段](Send-message-files-parity.md)。所有 48 分類仍須逐項驗收，不以本批回歸綠燈宣稱全功能對等。

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

- 圖片頭像：模型主機／box 來源、獨立讀取與圖片預覽核准、提交、direct／mailbox／remote fixture，以及人工匯入前配額已接線（截至 `549f96f`）。見 [Avatar-image-parity.md](Avatar-image-parity.md) 第七至十階段；CAS 回收／崩潰復原、完整 SVG 範圍、最低 macOS 與真實遠端服務驗收仍保留，不能標為整體完成。
- 檔案／媒體：`SendMessage` 的本機獨立檔案、HTTPS locator 與本機／遠端文字圖片集已接入上述五條 App 路徑，隔離測試不等同真實服務驗收。遠端有界動畫、四張以上的經審核圖庫、重複來源、真正 AVIF／ICO、安全驗證器支援的靜態自包含 SVG、十一格式獨立傳檔 MIME 及一般圖片驗證快照已實作；第七十八階段最後完整串行 gate 通過。大檔、更廣 SVG、真實 HEIF、未覆蓋格式變體、快取、AV／Quick Look URL 與完整 crash／UI lifecycle 邊界仍保留。text-gallery 別名索引不列為原版缺失功能，見 [Send-message-files-parity.md](Send-message-files-parity.md)。reference composition 未注入 box resolver，不能把可選介面當成遠端端到端證據；保存 HTTPS locator 也不是授予下載權限。

- 記憶：最新保存／搜尋／synthesis／episode／project recall 證據見 `Memory-archive-parity.md`；跨 epoch snapshot 是未接線參考設計，見 `Memory-snapshot-audit.md`，不能自行換成永久 cache。
- 協作／訊息：AGENT-02／04 的歷史缺項需與 `Agent-collaboration-parity.md` 後續進度及 current source 逐項對照；不能用舊行的「缺」覆蓋已完成的接線，也不能以有 UI 就宣稱工具／背景路徑完成。
- 平台事件：AUTO-03 的 Teams 使用者驗證、GitHub CI-completed 後端契約、Slack 名稱／自身身分映射等仍有差異，詳見下節再核對。reference 未提供 checks 彙整演算法，不因 generic matcher 通過而放寬驗證政策。
- 發佈／外部能力：UPD-03 的既有 release 是歷史證據，本目標禁止 push／真實帳號修改；不能擅自發新版本、連接帳號、安裝插件或替使用者授權。最終報告須明列尚需哪些外部驗收與決策，不把它們藏在 complete 標籤後。

## 平台觸發：當前契約與後端邊界再核對（2026-10-03）

Filicon `aa3a59c`，reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。本節是實際 source 呼叫鏈及本批既有隔離測試結果核對，不是連線平台或執行 reconstructed App；未取得真實憑證、未連接帳號、未安裝 webhook、未改使用者資料。

reference `source/host/extensions/automations/extension.ts` 的 production composition 建立 `AutomationsService` backend client、`SandAutomationCloudSync`、`createBackendRelaySources` 和 fire consumer，皆由 reference auth／backend URL 提供權限。這不是可直接移植的無帳號本機平台 runtime。`backend-relay-source.ts` 透過 `/sand/listener-subscriptions` 及 `/sand/listener-events/poll` 的 bearer-authenticated 後端取得事件／scope 狀態，再交 local hub；Filicon 不具備或借用該產品私有 backend／登入。

| 分類／能力 | reference 的已確認契約 | Filicon 當前邊界與下一個必要條件 |
| --- | --- | --- |
| AUTO-03／GitHub CI | `sand-automation-cloud-sync.ts` 將 repo、branch、SUCCESS／FAILURE／ANY 編成 `GitCICompletedEvent`，後端 relay 交付已分類的 `ci-passed`／`ci-failed` | 本機 normalizer 只承認同 repo 的 completed push `workflow_run`；不是等同後端 CI-completed 契約。該 source 呼叫鏈沒有 all-checks 查詢／彙整演算法，proto 也僅有欄位，不能把歷史「checks 彙整」用語當成已讀過的完整實作。若補此能力，須先定義 CI 完成範圍、可信事件／查詢來源、branch／commit／重跑身分及 pending／取消語意，不能因單一 workflow success 就回報所有 checks 通過。 |
| AUTO-03／Slack 名稱與自身反應 | relay 訂閱 channel 文字，後端回報 unresolved／bot membership；wire event 的 channelName／channelId 與 isSelf 由後端供應，cloud trigger 使用 onlyOwnerReactions | 本機入口接受明確 conversation ID 或 *，沒有可信的人類登入身分／名稱目錄，bySelf true 仍拒絕。`SlackChannelConnector.profile` 的 auth.test 回報配置 token 所屬 bot，不能冒充人類 owner。下一步須有帳號＋workspace 綁定的使用者授權／可信目錄及撤銷策略，不接受 webhook 自報 isSelf 或猜測名稱。 |
| AUTO-03／Teams 已登入使用者限制 | cloud trigger 傳 tenant／team／channel、literal／regex 及 blockUnauthenticatedTeamsUsers；reference matcher 在 platformMatched 邊界依賴後端驗證 | Filicon outgoing HMAC 僅證明傳輸，aadObjectId 不證明登入 Filicon。預設登入限制下事件仍 fail closed；模型／人工只能保存受限定義。須補可信 tenant＋application-user 綁定、登入驗證與撤銷／帳號切換，不能把簽章、AAD 字串或 payload authenticated=true 當作該權限。 |

`native-image-preview-unlocked-full.log` 中 `GitHub routine event boundaries`、`Slack routine event boundaries`、`Teams outgoing event boundaries` 三個現存 suite 均通過；包含九種 workflow conclusion、偽 self 拒絕，以及 signed webhook／AAD 不代表 application-user authentication。這些證明目前有限契約與 fail-closed 行為，不證明新平台能力已補齊。完整回歸及封裝證據見本檔最新圖片段落，沒有因 documentation 再核對修改 production 政策或重新執行 live 測試。

AUTO-03 維持 partial，不能因通用 HMAC／matcher 已有就改為 complete；也不能僅見外部 proto 就聲稱原版後端實作已在 reconstructed 倉庫。此核對只涵蓋三條平台流程，其餘 48 分類、人類互動、release／最低 macOS 及真實外部驗收繼續保留，不將平台邊界縮小為圖片工作。

## 背景執行流程：workflow 帳號撤銷與未補齊邊界（2026-10-03）

reference HEAD 仍為 `a9f633e09d49a85829b8236331b9e21f7e612634`。`source/host/extensions/transcript/automation-run-path.ts` 先 `resolveBackgroundSession`，再進同一 session 的 exclusive run；一般代理人呼叫既有 `runner.run`（hidden／automationWake），群組則進 `runGroupAutomation`。這是已確認的背景 session／runner 接線，不是獨立的 persona＋prompt 查詢。另一方面 `host-runner-composition.ts` 的 production context dependencies 仍將 memoryStore／memorySnapshots／userMemory／projectMemory 回傳 null，不能據此宣稱 reconstructed production 已證明所有背景記憶注入。

Filicon `AppAutomationExecutor` 與 `AppWorkflowPromptExecutor` 目前仍使用 profile instructions、提示詞及後者的 prior outputs 呼叫普通 provider stream；共用代理人 lane 不等於共用聊天／mailbox 的管理工具、互動卡、記憶或群組 session。workflow action 的 App handler 仍全部拒絕。此差異繼續列入 AGENT-01／02／04 與 AUTO-03 核對，不以本批修正宣稱已對齊完整 runner。

既有共享事實 consent 明確只涵蓋 bound direct chats、group chats 與 mailbox turns（`en.lproj/Localizable.strings` 的 Shared facts 文案）。本批沒有自動把已核准事實送往無人值守 automation／workflow，也沒有賦予新的工具或帳號權限；若後續接入背景記憶，須明確處理該 audience／授權範圍與撤銷，不把共用 scheduler 當成同意。

本批修正先前可直接重現的生命週期缺口：原 App 切帳號只取消排程器，沒有取消多步驟／批次 workflow 的整個 runtime。

- 新增 process-local `AgentWorkflowExecutionScope`，在切帳號第一個 await 之前同步 suspend。每次 suspend／invalidate 都永久撤銷舊 lease；重疊切換須全部 resume 後才能接受新 dispatch，不會重新啟用舊 lease。lease 不持久化，不是 tool permission。
- Service 與 runtime 各自捕捉 scope，繼承的 host lease 只補充、不取代自身撤銷；即使上游使用另一個獨立 scope，runtime cancelAll 仍阻止同批下一個 workflow。每一步、核准返回後、進入 agent lane 後、模型每個事件及空串流結束後均重驗。已撤銷時晚到一般錯誤／deadline 仍記為 cancelled，不冒充失敗後可接續或成功。
- 最終成功歷史／磁碟寫入及 UI 投影持有全部相依 scope 的鎖，依 ObjectIdentifier 排序、同一 scope 去重；同步保存與撤銷有明確先後，不以 preflight check 代替提交 fence。這不新增磁碟交易格式；保存本身失敗仍回報失敗，不捏造已落盤回條。
- 四條 App dispatch 在跨 actor 之前捕捉原始 lease；service 的 store 查找後及 runtime admission 再重驗，舊 dispatch 不能取消相同 ID 的新流程。舊 schedule tick 不推進下次時間，run／replay／event 的 UI reload 在 await 後重驗，不覆蓋新狀態。
- cancelAll 不清空定義、刪除歷史或提前釋放仍未 unwound 的 active agent lane。新流程在原 operation 收尾後可正常執行。這是合作式取消與結果隔離，不是回滾已完成的外部動作，也不能強制停止忽略取消、永不返回的第三方 executor。

隔離測試使用固定日期／識別與受控 gate、CustomDump 狀態斷言，涵蓋四條入口、八種 runtime／上游 scope 組合、晚到錯誤與核准、相同 ID 新舊 dispatch、實際 App 切帳號排隊、文字／空串流、UI reload、新流程及 service 重開，以及同步保存／撤銷順序與繼承 scope 去重。早期兩輪測試編譯問題（async autoclosure／非 Equatable request）與時間精度 fixture 的紅燈日誌保留；`workflow-account-scope-focused-commit-fence.log` exit 0：43 tests／4 suites。最後完整串行回歸 `workflow-account-scope-full-final.log` exit 0：135 XCTest＋1,622 Swift Testing（核心 860／98 suites、App 531／74 suites；兩項 opt-in live Codex 測試略過）。`workflow-account-scope-native-final.log` BUILD SUCCEEDED，`workflow-account-scope-package-final.log` deep／strict 簽章、四個執行檔及 app／XPC entitlements 核對通過；七語各 1,724 keys／0 missing，受保護儲存探針成功。第一輪完整回歸也是 exit 0，但發生於最後同步提交修正之前，不作為最終 gate。日誌在 `.build/validation/`，不提交產物。沒有 push、啟動／重啟使用者 App／Xcode、操作真實模型／帳號／群組或改變檔案保護。

## 背景純文字完成：不能將未完成的模型串流當成任務成功（2026-10-03）

沿用上節 reference automation 的 existing runner／group orchestration 證據，這輪另外修正 Filicon 的兩個簡化 executor：原程式僅收集 textDelta，在串流結束後就回傳結果，沒有檢查 finish reason，也會忽略未執行的工具事件。`AutomationService` 會將該回傳值記為 ok，workflow 則可能繼續下一步並保存 succeeded，不能把這種收集結果當成完成證據。

`TextOnlyInference` 現在共用於兩條 App 路徑，只接受單一明確 stop 且正常 stream end；明確空白 stop 是允許的 silence，不是 missing completion。未知／缺失 completion、length、重複 stop、所有 tool-call／arguments／result，以及 stop 後的 text／reasoning／response-start 都失敗；cancelled 為 CancellationError。usage 在 stop 前後均可接收，符合既有 OpenAI-compatible parser 的完成後用量事件；不保存 reasoning。每個事件、結尾及 thrown error 路徑重驗 Task／host validation，帳號撤銷仍由上一批 lease 保護。晚到 transport error 不被先前 stop 吞掉；沒有自動 retry 或重跑已開始的推論。

單一回應累計最多 100,000 UTF-8 bytes，以剩餘 bytes 比較防整數相加溢位，Unicode 與跨 chunk 逐筆計算；超限整次失敗而非把截斷草稿當成功。automation 原先無回應累計上限，持久 history 仍只保存既有 300-character 摘要與成功用量。workflow 另保留整個 run 各步合計上限、歷史／定義格式及既有 deadline。這是 collector 的正文上限，不是任意 provider buffer／CPU／永不返回串流的完整資源保證。

隔離 collector 與實際 App workflow／automation 雙入口案例使用固定日期、temp store、受控 validate 與 CustomDump，核對正常／silence、缺失結尾、length／cancelled／unknown／tool-use、各種工具事件、Unicode／跨 chunk 上限、完成後正文、late error、Stop／revocation、未執行下一步、未存 PRIVATE_DRAFT／偽造工具成功及成功 usage。實際 App 雙入口有 26 組 completion 案例；第一輪 NormalizedToolCall fixture 建構缺少 try 的編譯失敗日誌 `background-text-completion-focused.log` 保留。修正後最後聚焦 `background-text-completion-focused-repair.log` exit 0：41 tests／4 suites。

最後完整串行回歸 `background-text-completion-full.log` exit 0：135 XCTest＋1,632 Swift Testing（核心 869／99 suites、App 532／74 suites；兩項 opt-in live Codex 測試略過）。`background-text-completion-native.log` BUILD SUCCEEDED；`background-text-completion-package.log` 四個執行檔、deep／strict 簽章及 app／XPC entitlements 核對通過。七語各 1,724 keys／0 missing。日誌位於 `.build/validation/`，不提交產物；略過的兩項 live 測試不算真實 Codex／外部服務驗收證據。

沒有增加或實際執行工具、傳送已同意事實到背景、修改真實帳號／群組、push 或啟動／重啟使用者 App／Xcode。本批成功只證明 text-only 推論完成，不證明模型所聲稱的網站、登入或外部動作真的完成；原版完整 background session／management／group runner、需新 audience 同意的背景記憶、平台後端及其他分類驗收仍保留，不能上調整體 partial 或宣稱全 48 分類完成。
