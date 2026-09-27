# 模型圖片頭像來源核對（2026-09-27）

Filicon 基準 `a57e545`，reconstructed reference `a9f633e09d49a85829b8236331b9e21f7e612634`。這是下一個已確認的本機功能缺口，不代表其餘 parity 已完成。

## 原始證據

- `source/host/runner/tools/sand-state-tool.ts:149` 宣告 avatar.set 的 path；描述為已存在的主機／box 絕對路徑，不是遠端 URL。`:303` 將 path 交給 state.setAvatar。
- `source/host/extensions/memory/agent-state.ts:60` 先讀主機檔案，失敗且屬於 box root 才呼叫 readBoxFile；依內容辨識 PNG/JPEG/WebP/GIF/SVG，空資料或大於 5 MiB 拒絕（實作接受恰好 5 MiB）。來源檔不被刪除，安裝後更新頭像快取。相對路徑在此實作會 resolve，與 schema 說明不完全相同，不能把說明當成所有 runtime 行為。
- 同檔 `:61` 清除已安裝頭像並回預設；沒有自訂頭像時回報失敗。其刪除 conventional files 是參考的儲存布局，不要求 Filicon 刪除共用 CAS 圖片。
- `source/host/host-runner-composition.ts:1238–1248` 在非 shared-room turn 建立 agent state，傳入 agentDir、agentId 及呼叫 remoteBox.downloadFile 的 readBoxFile callback。這裡有來源接線證據，與先前 settings 缺 writeSettings callback 不同；仍未執行真實 reference 遠端服務。

## Filicon 目前可達流程

| 入口 | 目前證據 | 結論 |
| --- | --- | --- |
| 人工圖片頭像 | AppModel.importAgentAvatar → AgentAvatarStore.importImage(at:crop:shape:)；AgentTests 的 avatar crop/CAS 測試 | 已有人工匯入，不等於模型路徑已接線 |
| 模型頭像 | AgentAvatarChange 只帶 pet、previousAvatar；AgentManagementSession 只接受 pet_id 或 clear，AgentAvatarChangeTests 明確拒絕 path | 主機／box 圖片仍缺 |
| 核准與保存 | AppModel.authorizeAgentAvatarChange 只預覽 pet；commitAgentAvatarChange 走 quota 與 lifetime；AgentService 合併單一頭像欄位 | 可重用生命週期，但不能拿寵物預覽核准任意圖片 |
| 主機檔案權限 | localToolRuntime、WorkspaceFolderCoordinator、受授權 root 的 readFile | 已有權限基礎；模型頭像不能直接 Data(contentsOf:) 繞過它 |
| 遠端檔案 | HTTPSRemoteComputerBackend.download(agentID:path:maximumBytes:) | 已有有界下載；未與模型頭像的 host 固定 agent/runtime 相連，不證明 live 服務可用 |
| 圖片解碼／保存 | AgentAvatarStore：人工上限 25 MiB、ImageIO 有界縮圖、256 px PNG CAS；AgentImageStore：當輪 PNG/JPEG 附件 | 兩者來源／格式不同；不得用只接受當輪附件 ID 代替原版模型檔案路徑能力 |

## 完成條件

1. 保留現有 pet_id／clear，新增模型檔案圖片來源；欄位互斥、嚴格型別，owner／帳號／runtime 由 host 固定。不得安裝到其他代理人或自動下載任意 URL。
2. 主機來源必須經現有工作區讀取授權／對話內要求；路徑正規化、符號連結、非 regular file、大小上限與撤銷均檢查。遠端來源只用已配置且授權的自身 runtime；缺服務明確失敗，不假裝已安裝。
3. 準備不可變、有界圖片 bytes，預覽與保存綁同一內容指紋；核准後不重新讀可被替換的原路徑。圖片預览不啟動腳本或額外網路。PNG/JPEG/WebP/GIF/SVG 的支援與動畫／向量轉換必須逐項驗證；尚未支援的格式明列缺口，不默默當作完整 parity。
4. 明確展示新圖片及原頭像，核准才更新 profile。Stop／切帳號／封存／人工頭像變更／來源失效／儲存失敗均不得提交過期提案。保留歷史／群組／私人 persona，source file 不刪，CAS 多餘暫存要有清理策略。
5. 沿用四次修改額度、嚴格重播、quota、durable receipt；preview 拒絕不捏造成功。清除恢復 Codex 是 Filicon 的既有預設，不要求改為 reference 圖示。
6. 隔離測試覆蓋主機與假遠端兩路、格式／大小／權限／路徑／替換攻擊、核准生命周期、重開、七語圖片核准與原生建置。真實遠端帳號驗收另外列出；不登入或修改使用者真實資料。

## 第一階段：不可變圖片準備

`AgentAvatarStore.prepareImage(data:crop:shape:)` 現在產生只能由有界解碼器建立的 `PreparedAgentAvatar`，包含固定 PNG bytes 與內容指紋；準備本身不寫入磁碟。`install` 保存同一份 bytes，不重新開啟原始來源。人工匯入也改走此流程，使用同一個檔案 descriptor 檢查 regular file、限制讀取大小，拒絕最末層符號連結及非 file URL。

CAS 已存在時必須與準備資料完全相同；讀取頭像也核對內容指紋。損壞的既有 blob 不會被默默採用或覆寫。`PreparedAgentAvatarTests` 覆蓋準備零寫入、來源 bytes 改變後仍保存原內容、重複安裝／重開、損壞 CAS、空資料、無效格式、大小上限、符號連結與非 regular file。

驗證：完整非平行 Swift 測試、原生 `Filicon App` Debug 建置及 `verify-package.sh --xcode-debug` 均通過。未啟動 App、未操作真實群組／帳號資料。測試 target 明確加入既有 CustomDump product，避免隱含依賴導致連結失敗。

這只是共享 codec 基礎，不是模型圖片功能完成：尚未接模型主機／box 來源授權、5 MiB 模型限制、圖片核准及其生命週期，也尚未逐項驗證五種參考格式。檔案路徑檢查不宣稱能抵禦所有父目錄並行替換；模型來源仍須走既有工作區授權，不能直接呼叫人工匯入繞過權限。下一個切點是來源解析與真正圖片核准。

## 第二階段：受控模型提案與保存

第一階段之後新增圖片提案介面：`AgentAvatarChange.image` 保存不可變準備資料，pet 與 image 互斥，clear 不可帶任一來源。模型來源大小限制是大於零且至多 5 MiB（包含邊界），獨立於人工匯入的 25 MiB 限制。

`AgentManagementSession` 只有同時注入 `prepareAvatarImage`、獨立的 `authorizeAvatarImage` 與自訂 `commitAvatar` 才宣告／接受 `path`。原本寵物核准 callback 不會核准圖片。path 必須為絕對檔案路徑，拒絕 URL、父路徑跳脫、控制字元、雙斜線前綴、混用 pet_id、任意 owner 及其他欄位。與參考實作會 resolve 相對路徑不同，Filicon 目前不推測主機或遠端的 cwd。

來源讀取前後和核准後均檢查 lifetime；重播已完成的同一 call 不重讀來源。`AgentService.applyAvatarChange(...,imageStore:)` 在 lifetime 的同步提交區內重驗 owner／封存／原頭像，安裝原封不動的準備 bytes 後才更新 profile；沒給 imageStore 則失敗。只合併頭像欄位，保留私人指令等資料。若後續 profile 寫入失敗，可能留下不被 profile 引用的 CAS blob；不刪除共享 blob，回收策略尚待後續整合。

`AgentImageAvatarChangeTests` 驗證八種接線組合、圖片專用預覽、owner 綁定、保存／重開／重播、核准拒絕、封存、人工修改衝突、Stop 於讀取／核准期間、缺 store、磁碟失敗、durable receipt 及 5 MiB 邊界。這裡的 preparer 是隔離測試提供的資料，不代表主機／box 檔案權限已實接。

驗證：第二階段的完整非平行 Swift 測試、原生 Debug 建置及封裝檢查皆通過；新增案例也實際執行包含 durable receipt 的分支。沒有啟動使用者 App 或更改真實資料。

**App 尚未啟用 path**：目前仍缺 App 的來源讀取 adapter、真正圖片核准 UI 與七語顯示、完整格式驗證、quota／帳號切換整合及 CAS 清理策略。上述初始可達流程表代表 `a57e545` 基準；現行底層提案能力已增加，但使用者端尚未達到完整圖片 parity。

## 第三階段：具體來源讀取器

`AgentAvatarSourceReader` 實際使用 WorkspaceAuthorizationStore／WorkspaceFolderCoordinator／ToolPermissionPolicy 及 LocalToolRuntime：找最長的完整路徑元件匹配授權 root，缺失或失效時要求使用者選擇資料夾；不把選擇其他資料夾當作改讀另一檔案的授權。資料夾授權不取代 exact-operation read review。核准前後與 helper 回傳後都檢查有效 scope／Never policy／原 grant 身分，準備圖片不安裝 CAS。LocalToolRuntime 使用既有 descriptor-relative safe filesystem；該讀取現在以 O_NONBLOCK 開啟後才檢查 regular file，避免 FIFO 在檢查前阻塞。

`AgentRemoteAvatarSourceReader` 使用固定 backend 與 host-selected remoteAgentID，不取工具參數中的 owner 或 UI 目前選取電腦。沿用 RemoteFileTransfer 的 5 MiB 有界下載與 size/SHA-256 完整性驗證，下載前後檢查 scope、先經獨立讀取核准，不自動登入、啟動遠端 runtime 或上傳檔案。

隔離來源測試使用具體 LocalToolProcessHost（in-process、仍驗證 operation receipt）讀取暫存檔，以及 fake RemoteFileBackend；不是只 stub 圖片結果。覆蓋既有／新增／更新 grant、同前綴不同資料夾、選錯資料夾、拒絕、Never、核准後撤銷／scope／policy 變更、符號連結、目錄、FIFO、大小超限、遠端 owner／大小參數、內容指紋失敗及下載後 scope 失效。沒有操作真實帳號／書籤／來源檔案。

仍未在 AppModel 注入這兩個讀取器，沒有開放使用者端 path schema。接下來須完成來源路由與帳號／remote profile revision fence、圖片專用 UI、quota 與保存整合、格式測試；真實遠端 HTTP 服務驗收另列。這些 reader 自身不會把 local 權限拒絕偷偷轉成 remote download。

驗證：第三階段完整非平行 Swift 測試、原生 Debug 建置、封裝／簽章檢查通過。来源 suite 實際跑過 15 種本機情境及 5 種假遠端情境；沒有啟動 App 或重啟 Xcode。

## 第四階段：不可變圖片核准預覽

新增記憶體內的 `AgentAvatarApprovalPreview`，核對 owner、action、SHA-256、PNG 格式及 256×256 尺寸。核准畫面使用已捕捉的 bytes 顯示新舊圖片及裁切形狀，不在渲染時開啟來源路徑；圖片內容不放入聊天 metadata 或稽核資料。缺失／不相符的預覽顯示拒絕重試提示，群組核准按鈕停用，單獨對話核准動作也由 resolver 拒絕。拒絕入口保持可用。

AppModel 圖片專用核准流程按 pending ID 保留預覽，結束時移除，並檢查帳號 generation 與對話 scope。這個 authorizer 尚未注入模型 session，因此仍未開放 path schema，不代表完整使用者流程已啟用。

新增測試覆蓋 metadata 竄改／缺欄位、損壞舊圖片、沒有記憶體預覽不得核准，以及七語 × 深淺色 × 有／無預覽共 28 種渲染。抽查繁中與法文渲染未見文字裁切。原生專案清單也重新產生，納入來源讀取器及預覽檔案，避免 SwiftPM 測試通過卻漏入 Xcode target。

下一階段仍須實接來源與核准、quota／帳號／remote profile fence、格式矩陣及 CAS 回收；不以 UI 測試取代這些執行流程驗收。

本階段驗證：4 項專項測試（含 28 種圖片渲染）通過；重新產生 Xcode 專案後原生 Debug 建置及封裝簽章檢查通過。2026-09-27 完整測試重跑時系統處於鎖定狀態（CGSSessionScreenIsLocked=Yes），多項暫存資料讀取遭 Code 257／EPERM 拒絕；完整套件尚未通過，須解鎖後重跑，不把這次結果記成成功。

## 第五階段（部分）：格式驗證

隔離記憶體測試已驗證 PNG、JPEG、GIF 輸入都轉為單幀 256×256 PNG，並使用紅／藍雙幀 GIF 驗證輸出確實等於第一幀的正規化結果。兩項測試（含三種格式參數）通過，不使用真實檔案或外部圖片。這明確記錄動畫會凍結在第一幀，不宣稱保留動畫。WebP 與 SVG 仍待各自驗證／安全實作；完整套件仍受上述鎖定環境影響而待重跑。

後續 WebP 驗證：`bundledWebPDecodesToBoundedPNG` 使用 repo 內九個既有寵物素材，先確認 ImageIO 辨識為 `org.webmproject.webp`，再驗證 codec 輸出為小於 1 MiB 的單幀 256×256 PNG、保留原始 bytes 數量，且只有 12-byte header 的截斷資料不能通過。九個案例全部通過；PNG／JPEG／GIF 及 GIF 首幀測試一併重跑通過。此證據涵蓋目前主機的九個 WebP 素材，不宣稱涵蓋所有 WebP 編碼變體或最低支援 macOS 的解碼能力。

再次核對 reference `sand-state-tool.ts:149` 與 `agent-state.ts:60`，五格式清單確實包含 SVG；Filicon 尚無 SVG 專用轉換器，因此這項仍未完成。不得為了顯示頭像載入含腳本或任意外部資源的 SVG；後續安全渲染與驗收需要另行實作。來源 adapter 與圖片核准尚未注入 AppModel session，模型 path 仍未對使用者開放。

### 後續：受限靜態 SVG 轉換

新增 `StaticSVGAvatar`，在交給 AppKit 前以 UTF-8 XML 預檢及 element／attribute allowlist 驗證。macOS 原生 AppKit 可以解碼測試 SVG，但 ImageIO 現有縮圖流程對同一資料沒有有效影格；因此向量走獨立、有界的 bitmap 繪製，再沿用既有裁切、256×256 PNG 與 CAS 指紋流程。不使用 WebView、網路、外部命令或來源 URL。

支援形狀、路徑、群組變形與本地 linear／radial gradient；拒絕腳本、事件、DTD／entity declaration、處理指令、CSS、外部 image、foreignObject、動畫、use、clip／mask、文字節點元素等未列入功能。只允許指向已定義 gradient ID 的本地 paint reference，拒絕重複 ID 及 gradient 內資源引用。XML 上限為 5 MiB、64 層、4096 節點與單屬性 65536 bytes；根尺寸須有限且至多 20000，繪製 bitmap 最長邊至多 1024。UTF-16／32 XML 不得绕過 UTF-8 檢查。

這是**受限的靜態 SVG 支援，不是完整 SVG 相容**。原版保存任意 sniff 通過的 SVG bytes，Filicon 則拒絕上述未支援功能，不會默默刪除它們後回報成功；差異仍保留，尤其既有圖檔若使用 style、文字、clip、mask 或 use，需後續擴充與驗收。三個有效向量案例確認中央像素非透明及 PNG 可重現，拒絕案例涵蓋外部／file／data URL、字元參照繞過、XML 實體、遞迴與過量結構；PNG／JPEG／GIF／WebP 測試一併回歸。

本批最終驗證：鎖屏標記消失後，完整非平行 Swift 測試 exit 0，涵蓋最後加入的重複 ID 與 UTF-16 拒絕案例，也重新驗證前兩批圖片預覽／格式修改。原生 Debug 建置 exit 0，`verify-package.sh --xcode-debug` 的 deep strict 簽章與封裝檢查通過。日誌為 `.build/validation/avatar-svg-{full,native}.log`。未啟動使用者 App 或 Xcode、未改真實資料；最低支援 macOS 的原生 SVG 解碼仍未實機驗收，來源接線等其他缺口維持未完成。
