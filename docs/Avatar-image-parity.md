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

下一個實作切點是不可變 bytes 的圖片準備／CAS 介面，再接 host 來源解析與真正圖片核准。只新增 bytes helper 或 schema 都不算此功能完成。
