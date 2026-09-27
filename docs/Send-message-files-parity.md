# SendMessage 檔案與媒體交付核對

2026-09-27；來源核對 Filicon 基準 `549f96f`，reference `grok-bot-0.18-reconstructed` 基準 `a9f633e09d49a85829b8236331b9e21f7e612634`。狀態：**來源、交易與快照儲存元件已實作，App 發佈尚未接線**。本文件不代表全部 parity 已重驗。

## 來源證據

- Reference `source/host/runner/tools/send-message-schema.ts`：文字可帶 `images:[{url,alt?}]`；獨立附件使用 `type:attachment,url`，接受 file／HTTPS scheme。
- `source/host/runner/tools/send-message-tool.ts` 的 `resolveAttachmentSource`：file URL 先嘗試 host ingest，失敗才嘗試可選 box resolver，再退回原 URL。退回 URL 不證明檔案存在或成功交付。
- 同檔 `buildSandSendMessage`：文字图片與獨立附件可附尺寸；HTTPS 在可選 classifier 判斷為 file 時轉成文字 URL。不能一概宣稱原版會下載每個 HTTPS 檔案。
- `source/host/host-runner-composition.ts` 的 `sendMessage` 組裝注入 `hooks.ingestAttachment`、可選尺寸讀取、transport 及保存 receipt；此處未注入 `resolveBoxAttachment` 或 `classifyAttachment`。box 介面存在不等於這條 production 路徑已接線。

## Filicon 現況

`Sources/FiliconAppServices/AgentUserMessageTool.swift` 的 schema、runtime context 與 execute 都只允許當輪 `availableImages` 中的精確 ID。獨立附件形狀是 `type:attachment,image_id`，`url` 被 unknown-field 檢查拒絕；文字圖片也不能使用 URL。這是明確安全限制，不是顯示層漏畫卡片。

`AgentImageStore.swift` 限制單幀 PNG／JPEG、每張 5 MiB、最多四張／總計 12 MiB。它不能充當任意文件或影片的交付介面。既有圖片預覽核准與保存 receipt 可沿用概念，但不能僅放寬 schema 就聲稱已支援新產生檔案。

## 待實作順序與驗收

1. 本機產物：從已授權工作區安全讀取，固定執行者／帳號／來源對話；拒絕 traversal、symlink、非 regular file、超限與未授權路徑。讀取權限和發佈權限分開處理。
2. 不可變交付：先擷取有界 bytes、hash、檔名、型別；以這份快照呈現核准。使用者核准後不能重讀已被替換的來源；quota 必須在安裝附件前保留。
3. 持久化：真正保存附件與訊息後才回傳 receipt；拒絕、Stop、切帳號、刪除來源、磁碟失敗不得回報成功。相同 call 重播不能重複發佈，崩潰孤立 blob 必須可記帳，不擅自刪除既有資料。
4. 顯示：group、direct、mailbox 各自驗證正確接收者、重開仍可讀、圖片隨文字與文件獨立附件；不把任意 HTML／SVG 當可執行內容載入。文件／影片不能偽裝成 `AgentImageStore` 圖片。
5. 遠端與 HTTPS：另核對真實 production 路徑，再分開設計 backend revision／固定 agent fence、下載大小、redirect／網路目的地與凭證隔離；不繼承本機核准，不靜默跨來源 fallback，不因 reference 接受 URL 就自動联网。

測試須包含成功、拒絕、取消、來源替換、帳號／對話失效、配額／保存失敗與重播。僅有 schema 或 store 單元測試不算 App 完成；真實外部服務驗收另列。此輪只做 read-only source audit 與文件修正，沒有 runtime 變更，沒有執行／重啟 App 或修改真實資料。

## 第一階段：本機來源與不可變快照

從既有 avatar adapter 抽出 `AuthorizedAgentFileReader`，保留工作區最長 component-boundary 配對、重新授權不更換目標、readFile policy／核准、grant 及 scope 重驗、helper 的 descriptor-relative regular-file 讀取。Avatar 現在也使用這個共用實作，不另開未授權的檔案讀取入口。

新增 `AgentPublicationFileSource`：只接受無 host、query、fragment 的本機 file URL；明確 percent decode 後拒絕 NUL／控制字元、相對路徑、traversal 及非 canonical 路徑。直接使用 URL 的正規化 path 可能丟棄 NUL，因此不把正規化視為輸入驗證。結果只含不可變 bytes、basename 與 SHA-256，不保留原始 URL、不寫 CAS、不保存訊息，也不推測 MIME 或執行檔案內容。空檔案是合法檔案，不套用圖片的非空要求。

目前受既有 helper 10 MiB transport 限制；這是尚未完成的大檔／媒體交付邊界，不是改寫原定需求。讀取完成後的發佈核准、配額、附件安裝、receipt、三種聊天畫面與更大媒體／遠端路徑都尚未接線；工具 schema 仍拒絕 URL。

隔離測試涵蓋有效含空白／中文 URL、12 種不合法 URL、正常／空檔案、拒絕、never、撤銷、symlink、directory、超限；讀取後改寫來源仍保有原始 bytes／hash，並核對準備不建立附件目錄。既有 avatar 來源測試同跑以驗證抽取未破壞授權、scope、FIFO 與遠端行為。依 pfw-testing 使用隔離 helper／grant 與 CustomDump 狀態比對，不改真實資料。

驗證：定向測試、完整非平行 Swift 測試、原生 Debug build 均 exit 0；封裝與 deep strict 簽章檢查通過。日誌 `.build/validation/publication-source-{focused,full,native}.log` 不提交。未啟動 App／Xcode，未連線外部服務。

## 第二階段：核准與 durable receipt 交易層（2026-09-28）

`PreparedAgentPublicationFile` 移至 AppServices 成為不可變共用型別，驗證 basename 與既有文件／影片大小上限，保留 bytes／SHA-256。來源 adapter 仍受 helper 10 MiB 限制，移動型別不代表大檔 transport 已完成。

新增 host-bound `AgentFilePublicationTransaction`：固定 conversation／sender，準備來源後重新檢查 scope，再將精確快照與 reply target 交給獨立 authorize，核准後再次檢查才進入 commit。沒有預設放行的 callback；真正的 commit 必須由 App 執行 quota、精確 bytes 安裝、訊息保存及最終生命週期檢查。此層不自行讀取磁碟、不假造 RoomMessage，也尚未接入 `AgentUserMessageTool` schema。

commit 回條須匹配對話、sender、reply、檔名、bytes 數、digest，且不能重用本交易已見的 message ID。成功回條按 run／call ID 保存；相同輸入重播不再讀取、核准或寫入，更換輸入拒絕。保存一旦嘗試但拋錯或回條不符，該 identity 標為結果不明，禁止盲目重試；未提供 crash recovery，也不能假設未知保存已回滾。成功保存期間到達的取消不抹除 durable receipt，close 後只允許查回既有精確回條，不允許新發佈。這是記憶體內 per-turn 保護，不是跨程序去重。

測試用隔離 callback 驗證正常、拒絕、read／review 後撤銷、prepare／save 失敗、六種回條不符、錯誤 context、close、八種無效檔名；continuation 控制核准／保存等待，驗證並行重入拒絕，以及 Stop 在核准階段不保存、在保存成功後不遺失 receipt。沒有真實帳號或附件保存副作用。

待完成：App quota／附件保存 callback、核准 UI、模型 schema、group／direct／mailbox 的附件欄位及顯示、持久化重開與完整整合測試；大檔、遠端／HTTPS 及復原邊界仍保留。

驗證：定向測試通過；含最終 Stop／並行情境的完整非平行 Swift 測試及原生 Debug build exit 0，deep strict 封裝／簽章通過。日誌 `.build/validation/publication-transaction-{focused,full,native}.log`。`pfw-testing` 的可控依賴方式用於精確暫停邊界，沒有用真實帳號、App 重啟或外部服務測試代替。

## 第三階段：快照附件儲存（2026-09-28）

`AttachmentStore.ingest(prepared:createdAt:)` 安裝已擷取 bytes，不重讀來源。固定 root descriptor 與 shard descriptor，以 `O_NOFOLLOW` 拒絕符號連結；blob 也拒絕 directory／FIFO。獨占 temporary file、同步內容後以不覆寫的 `linkat` 建立 CAS 名稱，既有或競爭勝出的 blob 必須大小與完整 bytes 都一致，不覆寫損壞內容。root 的祖先仍由 host 選定並信任，這不是對任意模型目的路徑的寫入 API。

暫存檔沿用根目錄 `.ingest-` 命名，能被既有 inventory／reconcile 辨識。注入 blob 已写入、upload index 尚未保存的中斷後，隔離復原會將未索引內容移到可回復 quarantine，重新 stage／commit 後可讀；沒有對真實資料執行 reconcile 或自動清理。這不等於交易 receipt 跨程序復原或全部 crash 邊界完成。

新增 `AttachmentLifecycle.stage(prepared:)`，quota check 在 blob 安裝前，並沿用 staged upload／reference repository。這個既有 quota check 是政策檢查，**不是 AppQuotaWriter 的原子 reservation**；App 仍須在此操作外保留配額及檢查最終 scope，不能以本輪測試宣稱該接線完成。

檔名保留精確 basename；MIME 由 host 推斷，不接收模型指定值。HTML／XHTML 降為一般二進位附件；圖片只有通過現有 PNG／JPEG 驗證才標為可顯示圖片，SVG 或假圖片降為二進位。其他型別依副檔名推斷，尚非完整媒體內容驗證，也未新增自動執行或 HTML renderer。

隔離測試涵蓋文字／空檔案／HTML／SVG／假圖片、重開、reference commit、重用去重、兩個 store 並行、內容損壞、shard／blob symlink、FIFO、directory、quota 拒絕及 staging 中斷復原。依 pfw-testing 注入固定時間與故障點，驗證 bytes、metadata、索引與外部目錄未被改寫。

仍待 App 發佈核准 UI、原子配額、模型入口、三種聊天附件接線，以及大檔／远端來源與整體端到端驗收。

驗證：定向測試通過；含最終並行及中斷復原測試的完整非平行 Swift 測試、原生 Debug build 均 exit 0，deep strict 封裝／簽章通過。日誌 `.build/validation/publication-storage-{focused,full,native}.log` 不提交，未啟動 App／Xcode。

## 第四階段：可選模型工具入口（2026-09-28）

`AgentUserMessageTool` 可由 host 注入 `AgentFilePublicationTransaction`。origin tool scope、實際 destination 與 sender 都必須精確符合，否則不注入、不宣告 `url`，執行也拒絕。交易新增獨立 destination ID，以支援群組的 virtual tool scope，不把模型傳入值當收件人。

有完整交易能力才宣告 `type:attachment,url:file:///...`；暫不接受 HTTPS、混用文字／圖片欄位、alt 或 channel。reply_to 由既有 host directory 解析，支援明確引用及 host 選定的預設 thread。與文字／圖片／卡片共用兩次發佈額度；call ID 不能跨類型重用。相同 call 精確重播不再發佈，不同 call 的相同 digest 也不再發佈；同一路徑產生不同 bytes 則不被 URL 字串去重誤擋。

工具 close 會關閉交易，停止等待核准後的提交。保存成功才回傳 message ID，並保留晚到取消時的成功回條。檔案回條暫不加入這一輪的 reply directory，runtime instructions 明示此邊界，不能將它誤當已完成所有引用功能。`publishedTexts` 中的附件摘要僅供當輪發佈／額度追蹤，不代表另存了一則文字訊息。

隔離工具測試覆蓋正確／錯誤 origin、sender、destination、缺少 capability、文字共用額度、跨類型 ID、重播／重複內容、拒絕、close、無效欄位，以及明確／預設 reply。交易 callback 仍是 fixture，不宣稱 App 已端到端接線。

App 目前未注入檔案交易，因此真實對話仍維持原先權限。下一步仍是 App 核准 UI、原子 quota、訊息附件欄位與保存 callback，以及 group／direct／mailbox 整合驗收。文字搭配新圖片、檔案 alt、檔案回條引用、大檔／遠端／HTTPS 也仍待完成。

驗證：定向測試通過，補齊引用測試的模組匯入後，最終完整非平行 Swift 測試 exit 0；原生 Debug build 及 deep strict 封裝／簽章通過。日誌 `.build/validation/publication-tool-{focused,full,native}.log`。依 pfw-testing 使用可控 prepare／authorize／commit fixture，未啟動 App、未改真實資料。

## 第五階段：群組檔案訊息保存邊界（2026-09-28）

RoomMessage 新增可選 files 欄位，舊資料缺少欄位仍可解碼；不把新檔案塞入只允許當輪來源的 images。ReviewedGroupFile 是不可由 JSON 解碼的 host attestation，攜帶檔案 metadata、固定群組、成員及可撤銷 lifetime。host 必須先完成 bytes 保存、核准與 quota；此型別本身不證明磁碟檔案存在，也不代替這些步驟。

GroupService 在保存前檢查群組、當前成員及不混用圖片／問題／雲端卡片，透過同一同步 lifetime 鎖完成資料保存。檔案訊息共用回覆額度，以 digest 去重，允許無文字附件；引用編號、thread projection 及未讀判斷辨識 files。保存 callback 回傳的是持久化後含短編號的訊息。模型工具的檔案回條仍未接入 reply directory，兩者不可混為已完成。

隔離測試涵蓋舊 JSON、檔案重開、檔案引用、錯誤群組／成員、撤銷、混用欄位、重複內容及無效 metadata。依 pfw-testing 使用固定附件時間及隔離資料目錄。App 尚未注入檔案交易，沒有變更真實對話、重啟 App 或放寬實際工具權限。

待完成仍包含 App 核准 UI、原子 quota／blob reference 與訊息保存整合、檔案顯示，以及 direct／mailbox 接線、大檔與遠端來源。此階段不宣稱端到端可用。

驗證：修正測試對既有毫秒時間格式的比較後，完整非平行 Swift 測試 exit 0；原生 Debug build、deep strict 封裝／簽章均通過。日誌 `.build/validation/publication-group-{full,native}.log`。未啟動 App／Xcode。

## 第六階段：群組檔案卡片與預覽（2026-09-28）

群組訊息的 files 顯示檔名、大小及預覽按鈕，不再將含檔案的訊息標示為純文字。點擊會核對目前帳號 generation、所選群組與已保存訊息中的完整 metadata，再從 AttachmentStore 驗證 CAS bytes，交給既有附件預覽。切換群組、偽造 metadata、錯誤訊息／群組與缺少 blob 均不開啟。這不會讀取原始 file URL，也不會自動執行附件。

單獨聊天 peer projection 現在合併 canonical publication 的 images 與 files；files 從 AttachmentStore 驗證並補 reference，不經圖片解碼器。incoming peer message 暫不允許附加未存在於 canonical incoming schema 的 files。端到端檔案 transaction 尚未注入，該 projection 接線仍需隨後以完整 direct／mailbox 發佈案例驗收。

依 pfw-modern-swiftui 使用 callback 傳遞開啟動作，依 pfw-testing 以隔離已保存群組及 CAS fixture 驗證六種預覽情況。七語系離屏 render 通過，繁中截圖人工檢視檔名／大小／預覽圖示無截斷。未開啟使用者 App、未改真實帳號或群組。下一步仍為實際核准及原子 quota 的發佈接線，不宣稱全部完成。

驗證：定向與完整非平行 Swift 測試 exit 0；原生 Debug build、deep strict 封裝／簽章通過。日誌 `.build/validation/group-file-preview-{focused,full,native}.log`，離屏截圖 `.build/validation/group-file-ui/`，均不提交。

## 第七階段：群組 messaging session 交易接線（2026-09-28）

AgentMessagingSession.savedGroupPublisher 可接收 host 的 AgentGroupFilePublicationServices（來源擷取、發佈核准、配額／儲存 commit 三項皆必填），建立綁定當輪 sender 與群組的 AgentFilePublicationTransaction。缺少服務仍不宣告或接受檔案 URL。前景群組完成此接口；背景群組／mailbox 尚未加入。

交易開始、核准後及保存 callback 前，重新驗證最新使用者訊息 ID、當輪被選中的成員與 session 未關閉。host 安裝後回傳的 metadata 必須符合核准快照 digest、檔名、大小；再使用 session lifetime 呼叫 GroupService 保存。保存後驗證訊息群組、作者、reply target 與附件，才建立交易回條，不用假 UUID 代表成功。

隔離 session→tool→transaction→AttachmentStore→GroupService 測試涵蓋成功、精確重播、重開、拒絕、核准後換輪、保存前換輪、錯誤 metadata、close 與未注入服務。依 pfw-testing 使用固定快照與注入 callback；未改真實資料。測試 host commit 尚不代表 App 的核准／quota 接線完成；AppModel 目前仍未注入 services，此缺口保留供下一步實作，不宣稱使用者端已能傳檔。

驗證：定向與完整非平行 Swift 測試 exit 0；原生 Debug build 與 deep strict 封裝／簽章通過。日誌 `.build/validation/group-file-session-{focused,full,native}.log`。未啟動 App 或 Xcode。

## 第八階段：App 前景群組傳檔接線（2026-09-28）

AppModel 已加入來源讀取、群組內核准與 quota／附件保存服務。核准資料固定檔名、大小、digest 及成員範圍；來源 bytes 在核准前形成快照。保存前建立附件 owner，使用同一預先配置的訊息 ID 保存群組訊息；若保存後發生 ledger 錯誤，查回已保存訊息，不刪除其附件。quota 重算納入 active／quarantined blobs。純文字使用者請求也會取得 session publisher，圖片轉貼仍受原本來源限制。

檢查確認 GroupService.updateMembers 會停止舊 epoch，recordExplicitReply 在不讓出 actor 的保存區段檢查 epoch；App 更新成員也先取消執行。隔離 App fixture 涵蓋核准、拒絕、停止、帳號切換、成員變更及核准後來源內容變更，六種情境均通過。

完整套件另抓到 choice answer 的自訂文字含 @名字時，session 來源驗證與 GroupService 的 asker-only 路由不一致；來源驗證改以已保存問題的 responseMessageID／senderID 決定收件者，維持問題回答不構成重新指派成員。修正後完整非平行 Swift 測試 exit 0。

Xcode 專案補列 AgentPublicationFileSource.swift，最終原生 Debug build 與 deep strict 封裝／簽章通過。第一次完整測試因鎖定時受保護的 agents.json 回報 EPERM 而停止；解鎖後重跑，未降低檔案保護。最終日誌 `.build/validation/group-file-app-{full,native,compile}.log`。依 pfw-testing 使用隔離 fixture 驗證保存 bytes 及撤銷，不重啟使用者 App，不改真實資料。

後續仍包含 direct／mailbox／背景群組接線、檔案回條引用、遠端來源、媒體能力與故障復原驗收；前景接線不能代表上述差異已完成。

## 第九階段：檔案回條與引用清單（2026-09-28）

群組 session 把實際保存的 RoomMessage 帶入檔案交易回條；SendMessage 僅在訊息 ID、群組、作者、reply target、附件 digest／檔名／大小及訊息形態相符時，加入本輪引用清單。只有交付摘要而沒有保存訊息的舊 host callback 仍可回報交付成功，但不宣告可引用地址。短地址沿用既有衝突檢查，不自行生成。

歷史引用清單納入 file-only 訊息，不把檔案 bytes 或來源 URL 提供給模型。隔離測試涵蓋送檔後第二則訊息引用、精確重播、重開後的檔案地址，以及缺少保存訊息、錯誤群組／作者／digest／訊息 ID 不得成為引用目標。引用不構成附件讀取或轉寄授權。依 pfw-testing 使用 host fixture 與保存回條比較。

此階段不新增 direct／mailbox／背景群組的傳檔入口，遠端來源、媒體能力與故障復原驗收仍待完成。

驗證：定向與最終完整非平行 Swift 測試 exit 0；原生 Debug build、deep strict 封裝／簽章通過。日誌 `.build/validation/file-receipt-{focused,full,native}.log`。未重啟使用者 App、未修改真實帳號／群組資料。

## 背景群組接線前的 scope 審查（2026-09-28）

目前不可直接將前景 groupFiles 注入背景 publisher。核對現行程式得到以下具體差異：

- AppModel.runGroupDelegation 以目的 groupID 建立 responder，但 toolScopeID 保留 originID；delegatedGroupOrigins 是目的群組到來源對話的對應，finishGroupDelegation 會移除該對應。
- AgentMessagingSession.savedBackgroundGroupPublisher 的 conversationID 為 originConversationID，而 replyGroupID 為目的 groupID；背景沒有當輪人類訊息或可轉貼圖片，不能套用 availableImages 的 groupUserMessageID 檢查。
- makeGroupFileServices 目前在 session 建立時擷取來源群組；prepareGroupPublicationFile 又要求 context.conversationID 等於該群組。背景來源可能是 direct／mailbox，不一定是群組。
- authorizeGroupPublicationFile 的 ApprovalFence、核准所在 conversationID，目前也使用同一群組 ID。背景必須把執行／核准的來源 scope 與核准摘要中的目的群組分開。
- commitGroupPublicationFile 的附件 owner 與保存 RoomMessage 必須使用目的群組；但取消檢查必須同時驗證來源仍執行、delegatedGroupOrigins 未改、帳號 generation、目的成員快照以及 session lifetime。僅檢查某個群組正在執行不足以排除後來的新委派。

下一步應由 host 在已成立的委派中提供目的群組專屬服務，固定來源、目的與該次委派身分，不由模型傳入目的地。保存 callback 繼續走目的 GroupService 的 epoch／lifetime 檢查；成功後回條可引用目的群組訊息，不能把地址註冊到來源對話。

最低整合驗收：來源與目的不同的成功保存及重開；來源停止／切帳號；目的成員變更；原委派結束後同一群組的新委派；錯誤來源 context；拒絕核准；配額或保存失敗；核准後來源檔案變更；背景仍不能取得人類圖片轉貼權限。必須檢查目的附件 owner 與來源沒有多出訊息，不能只看成功字串。

此節是程式路徑審查，不是背景傳檔完成證據；未放寬 runtime 權限或新增對外連線。

## 第十階段：背景群組 session 的明確 host 能力（2026-09-28）

savedBackgroundGroupPublisher 現在可接收 AgentBackgroundGroupFileServices，內含固定 originID、groupID、三個檔案服務 callback 及必填的委派有效性檢查。來源／目的不符立即拒絕；缺少能力不宣告檔案 URL。前景與背景共用保存／回條驗證，但背景不使用人類訊息 ID 或圖片 forwarding directory。

交易 context 仍限定來源對話，Review、附件訊息與 reply directory 使用目的群組。準備前、核准後、保存 callback 前驗證 session 未關閉、host 委派有效、目的成員快照相符、作者未封存。真正保存仍由 GroupService 的 epoch 與 publication lifetime 控制。host validator 必須綁定確切 dispatch；此 API 不會自行推測 App 的委派身分。

隔離 fixture 涵蓋來源與目的不同的保存／重播／重開、拒絕、成員變更、session close、host 撤銷、錯誤能力來源／目的、錯誤呼叫 context、缺少能力，以及不能順便轉貼未知人類圖片。驗證目的檔案 bytes，來源沒有新群組訊息。依 pfw-testing 注入服務與可撤銷委派 fixture，不接觸真實資料。

App／responder 尚未注入這項背景能力，仍須接上確切 delegatedGroupPosts 身分、來源核准、目的 owner／quota 與 App 層停止／ABA 測試；此階段不是使用者端背景傳檔完成證據。

驗證：定向與完整非平行 Swift 測試 exit 0；原生 Debug build、deep strict 封裝／簽章通過。日誌 `.build/validation/background-file-session-{focused,full,native}.log`。未重啟 App／Xcode、未改真實帳號／群組資料。

## 第十一階段：App 背景群組傳檔接線（2026-09-28）

AppModel.runGroupDelegation 現在提供該次委派專屬的背景檔案能力，GroupConversationResponder 將它傳入背景 publisher。能力固定來源、目的、帳號 generation 與 delegatedGroupPosts.message.id；準備、核准後及保存前都檢查確切委派、來源仍執行、目的成員快照與作者有效性。不能只用相同群組仍存在判定舊委派有效。

檔案讀取與核准沿用來源 conversation scope；核准摘要顯示目的群組與成員；配額、附件 owner、RoomMessage 與回條則落在目的群組。保留 GroupService 的 epoch／lifetime 保存檢查，不把背景委派變成人類圖片授權。

App 隔離 fixture 以不同來源／目的群組實際執行 SendToAgent → SendMessage，與前景共用 14 種案例：核准、拒絕、停止來源、停止目的、切帳號、改成員、核准期間替換來源內容。驗證來源沒有附件訊息，目的重開後 bytes 與核准快照一致、附件 owner 可讀，以及 quota reconcile 沒有新增錯誤。依 pfw-testing 使用隔離資料與 helper，不碰真實資料或啟動 App。

仍待獨立驗收：direct／mailbox 來源的 App 背景檔案流程、同一目的群組被下一次委派重用的 ABA 情境、配額／保存故障注入及 crash recovery。direct／mailbox 本身傳檔、遠端來源與媒體能力亦未完成；本階段不代表整體 parity 完成。

驗證：14 種 App 定向案例與最終完整非平行 Swift 測試 exit 0；原生 Debug build、deep strict 封裝／簽章通過。日誌 `.build/validation/background-file-app-{target,final-full,native}.log`。整理測試 fixture 時曾把 ToolName 宣告為 String 導致編譯失敗，修正後重跑完整套件通過。未重啟使用者 App／Xcode。

## 第十二階段：direct／mailbox 來源與停止修正（2026-09-28）

隔離 App 測試擴充到綁定單獨聊天與代理人信箱作為委派來源，經由真實 App 的 SendToAgent 核准與背景群組 SendMessage 流程交付檔案。四條路徑（前景、群組來源、direct 來源、mailbox 來源）各驗證核准、拒絕、停止來源、停止目的、切帳號、改成員、核准期間替換來源檔案，共 28 種情境；核准必須等待不同的 review ID，不能將尚未完成的非同步委派核准誤當成送檔核准。

新增測試重現 direct 來源的停止缺陷：stopGroup 原本只分 mailbox 或 group 來源，direct 來源被當作沒有執行中的群組而直接返回，晚到核准仍能送檔。現在辨識 directMessagingScopes，呼叫既有 cancelConversationWork(originID)，取消確切來源而非目前 UI 選取對話。重跑 28 種情境通過，包含晚到核准不落檔、來源／目的停止收尾、pending approvals 清空、目的群組重開後的附件 owner／bytes 驗證。

這是 direct／mailbox **委派至群組**的傳檔驗收，不代表 direct／mailbox 本身已有一般檔案發布入口。同一目的群組的新委派取代舊委派（ABA）、配額／保存故障及 crash recovery 仍待驗證；遠端來源與媒體能力亦未完成。依 pfw-testing 使用隔離 helper／資料，不改真實聊天、不重啟 App。

驗證：28 種定向案例及完整非平行 Swift 測試 exit 0；原生 Debug build、deep strict 封裝／簽章通過。日誌 `.build/validation/direct-background-files-{target-final,full,native}.log`。初版測試有 optional UUID／review ID 型別編譯錯誤及未等待非同步核准的時序問題，修正後才重現並修復上述 direct 停止缺陷。

## 第十三階段：配額失敗與已保存附件的復原（2026-09-28）

四條 App 路徑各增加保存前 reservation 失敗、blob 記帳後失敗、訊息已保存後 quota commit 失敗，共 12 種故障案例（總計 40 種）。故障僅在傳檔核准時啟用；訊息後故障會先讀取隔離 groups.json 確認檔案訊息已落盤。檢查實際觸發故障、目的訊息數、重開附件 owner／bytes、成功工具活動及配額 reconcile，不只核對文字回覆。

測試重現晚到 quota 錯誤造成已保存附件引用被刪除：commitGroupPublicationFile 的復原比較用了 stage 回傳的 metadata，但 attachmentLifecycle.commit 回傳的是 SQLite timestamp round-trip 後的 metadata，Date 浮點精度可能不同。原本完整相等比較因此失敗，進入清理分支。修正為保留 commit 回傳、實際交給 save 的 metadata，復原時仍完整比較已保存訊息 ID／作者／附件，而非放寬成只比較 digest。

最初 40 案例跑法在 direct 來源失敗；不改程式重跑又在 foreground／mailbox 重現。修正後定向案例全部通過。保存前或 blob 階段錯誤沒有附件訊息；訊息保存後錯誤仍取得成功工具活動，附件可透過目的 owner 讀取。依 pfw-testing 使用隔離 quota fault injector，未改真實資料或重啟 App。

此階段不是所有儲存故障驗收：GroupService 實際保存失敗、程序中止／crash recovery、委派重用（ABA）仍待補驗。direct／mailbox 本身一般檔案發布、遠端 URL／媒體能力缺口也仍存在。

驗證：40 種定向情境與完整非平行 Swift 測試 exit 0；原生 Debug build、deep strict 封裝／簽章通過。故障重現日誌 `.build/validation/group-file-quota-{target,repeat}.log`；修正後 `.build/validation/group-file-quota-{fixed,full,native}.log`。完整回歸亦包含成功工具活動斷言。

## 第十四階段：群組訊息實際寫入失敗（2026-09-28）

在傳檔核准期間，測試把隔離 fixture 的 groups.json 移至備份位置、以目錄佔住原路徑，使 GroupService 的 atomic write 真正失敗，而不是僅由 quota callback 模擬錯誤。來源涵蓋前景群組、群組委派、direct 委派、mailbox 委派；四種新增案例與既有 40 種合計 44 種。

等執行完全收尾後，確認記憶體無檔案訊息、SQLite 中該 blob 的 reference count 為 0、blob 已進入 quarantined 且 byte count 相符，再還原原始快照並重新載入，確認沒有新檔案訊息。檢查 quarantine 防止「根本未執行到寫入」形成假陽性。此測試只移動／還原各案例自己建立的臨時檔，沒有修改真實 groups.json。依 pfw-testing 驗證狀態與可重開資料。

底層寫入失敗的既有清理流程符合上述斷言，本批沒有變更 production code。程序中止／crash recovery 與委派重用（ABA）尚未由這些案例證明；direct／mailbox 自身一般檔案發布及遠端／媒體能力仍未完成。

驗證：44 種定向情境通過，補上 quarantine 斷言後完整非平行 Swift 測試 exit 0；日誌 `.build/validation/group-file-write-failure-{target,full}.log`。本批僅測試與文件變更，未重建或啟動使用者 App；production build／簽章證據沿用第十三階段。

## 第十五階段：direct／mailbox 入口審查與未授權檔案防護（2026-09-28）

重新核對 reference `source/host/runner/tools/send-message-tool.ts`：attachment URL 經 resolveAttachmentSource，再由 onSendMessage 保存；因此尚缺的 direct／mailbox 一般檔案發布不是可忽略項目。Filicon 的 direct publisher 在 AppModel.startTurn 建立，目前只接圖片驗證／核准及 publishDirectText；信箱 publisher 在 AgentMessagingSession.drain 使用 AgentInboundOutput.publish → AgentMessenger.publish，也尚未注入 filePublication。

入口審查發現 AgentMessenger.publishValidated 驗證文字／圖片但未拒絕 RoomMessage.files，updateDelivery 的純文字 finalPublication 同樣漏檢。雖然現有工具尚不產生此欄位，新的 host 接線若直接傳 RoomMessage，會跳過一般檔案的來源核准與引用建立。因此兩個舊入口先明確拒絕非空 files；新增文字夾檔、已知圖片混檔及 finalPublication 夾檔測試，並驗證拒絕後狀態不變。依 pfw-testing 保留現有合法圖片／文字保存回歸。

這項防護不是傳檔功能替代品。後續必須加入 host-only 已核准檔案證明、固定 mailbox incoming／origin／sender、原始檔案 bytes 與核准、quota／附件 owner、canonical receipt、信箱保存與 direct mirror／preview；不能只把 files 放進既有文字 callback。direct 歷史投影目前只填 images，file-only 引用也須一併驗收。未放寬遠端存取或既有圖片授權。

驗證：完整非平行 Swift 測試 exit 0，原生 Debug build 與 deep strict 封裝／簽章通過，日誌 `.build/validation/mailbox-file-admission-{full,native}.log`。初版 fixture 誤用不存在的 AttachmentKind.file，改為 document 後完整驗證通過。未重啟 App 或修改真實資料。

## 第十六階段：信箱已核准檔案的正式保存入口（2026-09-28）

新增非 Codable 的 ReviewedMailboxFile，固定 incoming ID、origin、sender、訊息 ID、檔案 metadata、reply target 與 lifetime。publishFile 只接受此 host envelope；既有 publish 與 finalPublication 仍拒絕未核准 files。與群組共用 metadata 格式驗證，保存仍走信箱的 running delivery、作者／來源、唯一 ID、兩則上限、取消 fence 與 atomic write。檔案本身的 bytes、核准、quota 和 owner 必須由 host 先完成，這個入口不授予讀寫權限。

file-only 訊息加入 replyDirectory，保存後回傳具短地址的 canonical receipt。依 pfw-testing 新增隔離測試：錯誤 incoming／origin／author、實際信箱寫入失敗與狀態不變、相同 envelope 重播、ID 重用／變更、一般入口拒絕已保存檔案、引用檔案訊息、發布上限、lifetime 取消與重開後 metadata 保留。

這是保存層，不代表 App 信箱傳檔已完成：AgentMessagingSession 的 filePublication、App host 的來源核准／blob owner／quota、direct mirror／preview 尚須接線與端到端測試。direct 自身檔案發布、遠端 URL／媒體與 ABA／crash recovery 缺口仍保留。

驗證：完整非平行 Swift 測試 exit 0；追加 ID 重用與上限斷言後定向測試 exit 0。原生 Debug build 與 deep strict 封裝／簽章通過。日誌 `.build/validation/mailbox-reviewed-file-{full,final-target,native}.log`。未啟動或重啟使用者 App，未修改真實資料。
