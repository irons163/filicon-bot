# SendMessage 檔案與媒體交付核對

2026-09-27；來源核對 Filicon 基準 `549f96f`，reference `grok-bot-0.18-reconstructed` 基準 `a9f633e09d49a85829b8236331b9e21f7e612634`。狀態：**來源準備層已實作，發佈尚未接線**。本文件不代表全部 parity 已重驗。

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
