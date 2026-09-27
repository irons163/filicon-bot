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
