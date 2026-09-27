# SendMessage 檔案與媒體交付核對

2026-09-27；Filicon 基準 `549f96f`，reference `grok-bot-0.18-reconstructed` 基準 `a9f633e09d49a85829b8236331b9e21f7e612634`。狀態：**已確認差異，尚未實作**。本文件不代表全部 parity 已重驗。

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
