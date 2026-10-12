# 靜態 WebP 對話輸入驗收（2026-10-12）

## 範圍與依據

基線 `e1707b7` 已驗 PNG／JPEG／單幀 GIF 的有界圖片輸入。
本批補靜態 WebP：手動 mailbox／群組、foreground direct 的圖片 publication／
`SendToAgent`，以及當次 admitted channel 的原 owner own-DM、單一 peer 委派與
fresh 圖片／目的地／全文人類核准後的外部首張回覆。
不加入動畫、任意歷史圖片、群組圖片廣播、private history sharing 或新的 host。
既有通用檔案輸入、經審核 gallery／動畫展示政策不改寫。

唯讀核對 reconstructed `a9f633e09d49a85829b8236331b9e21f7e612634`：
`source/shared/media/media-extensions.ts` 列出 `.webp: image/webp`；
`source/host/selected-image-inputs.ts` 依 MIME 表載入選取圖片。
這是已確認的共用圖片輸入差異，不代表所有遠端 connector／真人帳號已驗。

2026-10-12 核對的官方格式依據：

- [OpenAI image input](https://developers.openai.com/api/docs/guides/images-vision) 接受 WebP。
- [Claude vision](https://platform.claude.com/docs/en/build-with-claude/vision) 接受 WebP；不支援動畫。
- [Gemini image understanding](https://ai.google.dev/gemini-api/docs/image-understanding) 接受 WebP。
- [WebP RIFF container](https://developers.google.com/speed/webp/docs/riff_container) 定義 RIFF 長度、
  VP8／VP8L frame 尺寸、VP8X canvas／animation flag 及 ANIM／ANMF chunks。

本批各 provider 的 WebP wire payload 均保留原始 bytes／MIME，Gemini 不轉換 WebP。
既有單幀 GIF 的 Gemini transient PNG 相容處理保留。
provider 契約使用離線 HTTP probe，不是外部服務／模型／真人帳號的成功證據。

## 安全與介面邊界

- 仍限四張、每張 5 MiB、整批 12 MiB、單邊 8,192 及每張 16,000,000 pixels。
- 原始 RIFF 長度必須吻合，不收尾隨 bytes；chunks 大小與偶數 padding 完整。
  VP8X canvas 與 VP8／VP8L frame 尺寸各自有界，完整解碼前即檢查。
  拒絕 animation flag、ANIM／ANMF（即使只有一幀或旗標缺漏）、重複 frame／VP8X。
  這只是 header／container 邊界，不能替代 ImageIO 完整解碼、單幀與 complete status。
- 保留 SHA-256／MIME／大小核對、CAS 防替換、scope／account／run／persona ABA fences、
  人類 exact review、Stop／拒絕／保存失敗及重開後不自動重播等原防護。
  原 unsupported-type 測試改用仍不支援的 AVIF，不移除格式拒絕案例。
- 選檔器使用系統 WebP UTType；七語新增清楚的單幀格式與原容量提示。
  舊 GIF catalog keys 保留，不改使用者訊息、檔名、帳號或語言偏好。
- 真正的 libwebp 小型靜態／動畫 fixtures 在記憶體離線產生並固定為測試 bytes，
  不依賴網路、repo 寵物素材或本機 WebP encoder；未新增套件依賴。

## 驗證紀錄

所有模型／connector 均為離線 probe，資料只在隔離測試目錄；
仍執行實際 AppModel／native listener／持久 stores／quota／queue／核准卡流程。
本機為 macOS 26.7／Swift 6.4；native build 使用 SDK 27、arm64 Debug。
依 Swift Testing／CustomDump 指引保留完整 bytes／metadata／canonical state 比對，
SwiftUI 指引用於七語完整文字換行與實際原生預覽，不以 key audit 代替畫面驗證。

- `static-webp-input-red-v1.log`：terminal exit 1，重建 10.49 秒，
  10 methods／3 suites 有七個有效 WebP 拒絕 issues（own capture 兩 cases、
  mailbox 一 case、lossy／lossless／extended 三 cases、provider 一 case）。
  fixtures 的 ImageIO 解碼、尺寸與 type 斷言通過，確認是舊 allowlist 功能缺口。
  紅燈時所有 WebP 都被拒絕，不能以負例 pass 宣稱已驗 header 安全。
- `static-webp-input-core-v1.log`：terminal exit 0，10 methods／3 suites 通過。
  lossy／lossless／extended／alpha 完整解碼、原圖格式、20 個 raw header／動畫／
  截斷／尺寸拒絕 cases、五家 provider 的原始 wire bytes 與 mailbox 重讀通過。
  這是較早的 core source；其後另補完整 prefix／邊界及 App 路徑，須以最後 source 重驗。
- `static-webp-input-localization-v1.log`：terminal exit 0；七語各 1,821 keys，0 missing。
  key audit 不代表逐句母語審核；另需 actual resources 與 native 畫面檢查。
- `static-webp-input-focused-v1.log`：terminal exit 0，重建 105.32 秒；
  core 12 methods／3 suites（0.787 秒）、App 34／6（99.054 秒）通過。
  包含原 GIF provider failure 防護、原 group／direct／peer 與新 WebP 的實際核准、
  ABA／取消／拒絕、保存失敗、缺漏恢復及不重播舊圖片。
  `StaticWebPInputUIV1` 保留原 PNG／GIF 與新 WebP native 圖片預覽；
  目視法文 WebP 說明與英文 320 dark 外部核准卡，原圖、完整目的地／全文、
  digest、MIME／大小、Approve／Reject 及格式／容量提示可見，未見新裁切。
- 靜態追查另找到 Slack／Discord 真正下載入口的 MIME sniff 漏點：
  `static-webp-input-connector-red-v1.log` terminal exit 1，重建 10.21 秒；
  兩個 methods／六 cases，其中兩個 WebP 下載 cases 出現四個差異，
  真正 connector 把已下載原始 WebP 判成 `application/octet-stream`。
  補 RIFF＋WEBP magic 辨識；仍不信遠端 MIME／HTTP header／副檔名，
  此分類不代替下游完整圖片驗證，也不改 generic channel 檔案／動畫 transfer 政策。
  最後 source 需重新執行 focused，不能沿用漏點修正前的 v1 結論。
- `static-webp-input-focused-v2.log`：最後 v2 source 重新編譯，terminal exit 0；
  core 12 methods／3 suites（0.338 秒）、整個 ChannelTests 11／1（0.203 秒）、
  App 34／6（84.379 秒），合計 57 methods／10 suites／425 cases 通過。
  包含真正 Slack／Discord 下載的原始 bytes／MIME／digest、誤導檔名與遠端 MIME、
  四種偽 RIFF／WEBP magic 拒絕；只進行離線 GET，不發送外部訊息。
  原 PNG／GIF、完整 prefix／尺寸邊界、損壞／動畫／截斷 WebP、
  publication／peer／channel review 的完整保存與撤銷防護均保留。
  `StaticWebPInputUIV2` 保存 79 張 native PNG；其中新 WebP 有七語 peer
  說明與八個 incoming 明暗／寬度畫面，像素與 OCR 斷言通過。
  已逐張目視七語 WebP peer 說明，圖片、收件者、完整說明、檔名／digest
  與格式／容量提示可見；另目視 v2 英文 320 dark 外部回覆核准卡及
  560 light peer 核准卡，圖片、完整內容／目的地與 Approve／Reject 可見。
  不稱全部 79 張人工目視或逐句母語審核。
- `static-webp-input-localization-v2.log`：最後 source 七語各 1,821 keys，
  0 missing、terminal exit 0。
- 最後 source 固定為 `static-webp-input-source-v2.sha256`，
  `static-webp-input-pre-full-v1-check.log` 與
  `static-webp-input-during-full-source-check-v1.log`／`v2.log`
  均確認產品／測試 source 未變。
- `static-webp-input-full-v1.log`：同一最後 source 的 fresh 無 filter 串行
  完整回歸 terminal exit 0，2,311 Swift Testing methods／268 suites／17 runners，
  135 XCTest／0 failures／17 runners，0 recorded issues。
  core 1,098／122（53.975 秒）、App 867／105（1,012.309 秒）、
  Agents 57／8（3.480 秒）；原完整 Mailbox、routine／workflow／card 恢復、
  原 PNG／GIF 與新 WebP 的完整測試範圍保留，沒有 filter 或刪除原斷言。
  兩項 installed Codex opt-in live tests skipped，不算外部服務通過。
  既有 CoreData／NSXPC 系統診斷保留，不稱其 runtime 已修復。
  `static-webp-input-full-v1-summary.log` 記錄逐 runner 統計，
  `static-webp-input-post-full-v1-check.log` 再確認最後 source hashes 吻合。

- `static-webp-input-native-v1.log`：隔離 DerivedData 的 arm64 native Debug
  build terminal exit 0／BUILD SUCCEEDED；
  `static-webp-input-native-verify-v1.log` 的獨立 `--xcode-debug` verify exit 0。
- `static-webp-input-package-v1.log`：事先確認不存在的新 standalone Debug
  bundle 建置、封裝及內建 verify terminal exit 0；
  `static-webp-input-package-verify-v1.log` 再次獨立 verify exit 0。
  四個 executables、app／XPC entitlements、deep strict codesign、
  KaTeX 0.16.45／20 fonts／MIT 及 Mermaid 11.16.0／MIT／72 notices 均通過。
  僅重用已檢視的 command-local Swift wrapper 固定 resolved versions；
  未改全域工具鏈、套件依賴、已存在 bundles 或使用者 App／Xcode。
  未執行封裝 script 印出的 launch smoke；Debug／ad-hoc 不等於 Release／公證。
- `static-webp-input-post-build-v1-check.log` 再確認最後產品／測試 source
  hashes 未變；提交前 source、證據 hashes 及 `git diff --check` 另核對。
  最後本批 logs 的指紋保存於 `static-webp-input-evidence-v1.sha256`。

本批必要 gates 通過，隨本批本機提交，未 push。
只關閉上述靜態 WebP 輸入缺口；整體 48 分類與 partial 不變。

## 保留項目

未驗真人 provider／connector、最低 macOS 14、實際使用者 App／XPC runtime、
Release Developer ID／公證；沒有 launch／重啟 App／Xcode、push 或修改真實帳號／群組。
其他輸入格式、其他 host、private history sharing 與整體 parity 仍是獨立工作。
