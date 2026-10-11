# 單幀 GIF 對話輸入驗收（2026-10-11）

## 範圍與依據

基線 `3c69fd6` 已有當次 PNG／JPEG incoming admission、原 owner own-DM 推論、
單一 peer 委派與 fresh human review 後的外部回覆。本批只擴充為單幀 GIF，
不加入動畫、其他格式、任意歷史圖片、private history sharing 或新的執行 host。
foreground direct 本批新增的是當次 GIF 的圖片 publication／`SendToAgent` allowlist，
不是重寫既有通用檔案附件輸入、gallery／遠端來源或所有 provider 的媒體政策。

唯讀核對 reconstructed `a9f633e09d49a85829b8236331b9e21f7e612634`：

- `source/shared/media/media-extensions.ts` 列有 GIF MIME。
- `source/host/selected-image-inputs.ts` 依該表載入選取圖片。
- `source/host/extensions/transcript/background-wakes.ts:238` 將當次 incoming images 傳入 selectedImages；
  `send-message-shaping.ts:290–296` 收集 envelopes 的圖片而不另限 PNG／JPEG。

這證明共用圖片輸入契約存在 GIF 路徑，不代表已驗所有原版遠端 connector 或真人帳號。

2026-10-11 查閱的供應商官方依據：

- [OpenAI image input requirements](https://developers.openai.com/api/docs/guides/images-vision)：接受非動態 GIF。
- [Claude vision formats](https://platform.claude.com/docs/en/build-with-claude/vision)：接受 GIF，但不處理動畫。
- [Gemini image formats](https://ai.google.dev/gemini-api/docs/image-understanding)：列 PNG／JPEG／WebP／HEIC／HEIF，沒有 GIF。

因此 Gemini 僅於 transient HTTP image payload 將已驗單幀 GIF 轉為 PNG；
其餘圖片不轉碼，原 canonical metadata、CAS、預覽、peer 與外部 publication 仍保留原 GIF bytes。
轉碼前後維持尺寸、像素、個別及整批大小上限，失敗不發出圖片推論 HTTP，不改成純文字或擷取動畫首幀。
這是格式相容處理，不改模型選擇或推論／送件的授權。

## 驗證紀錄

所有測試資料均位於隔離暫存根目錄；模型與 connector 使用離線 probe，
原 native listener／AppModel／核准卡／canonical stores／quota／queue 流程不以假 admission 取代。

- `static-gif-input-red-v1.log`：terminal exit 1，3 methods／2 suites；
  有效 GIF 的 mailbox import 一 case與 incoming capture 兩 cases 被舊程式拒絕。
  原 PNG／JPEG 與 GIF 動畫／截斷／尺寸拒絕 cases 通過，這是功能紅燈而非工具鏈失敗。
  此時舊 allowlist 拒絕所有 GIF，不能以尺寸拒絕 pass 證明已防住 GIF 畫布；真正漏洞見 focused v2。
- `static-gif-input-focused-v1.log`：terminal exit 1，測試尚未執行；
  新 provider test 的巢狀 `#require` 巨集不能編譯，拆成兩個等價的必要條件後重建，未移除斷言。
- 靜態稽核另外找到 foreground direct 的兩個 PNG／JPEG MIME allowlist；
  一併補 GIF，並將 actual direct publication／direct-to-peer 的核准、Stop、帳號切換、
  保存失敗及 restart／recovery cases 擴到 GIF，而不是只驗 native channel 正例。
- `static-gif-input-localization-v1.log`：terminal exit 0；七語各 1,819 keys、0 missing。
- `static-gif-input-focused-v2.log`：terminal exit 1，重建 511.79 秒；
  core 9 methods／3 suites 有 19 issues，App 15 methods／6 suites 通過（33.324 秒）。
  其中兩個是真正 GIF logical screen 超寬／超高被 ImageIO 以較小 frame 尺寸回報，
  因而漏過原尺寸檢查；新增原始 GIF header 畫布上限，再保留完整解碼／幀數檢查。
  其餘 17 issues 為 provider test 將模型目錄 GET 也誤計成圖片推論 HTTP，
  改為離線 503 catalog fallback，仍嚴格拒絕任何推論 POST，沒有放寬圖片斷言。
  actual bitmap fixture 亦改明確 device RGB，避免 NSNamedColorSpace 警告及不確定像素。
- `static-gif-input-focused-v3.log`：terminal exit 0，重建 359.25 秒；
  core 9 methods／3 suites／51 cases（0.322 秒）、App 15 methods／6 suites／158 cases（43.092 秒），
  合計 24 methods／9 suites／209 cases，沒有移除前述失敗案例。
  包括 GIF 超寬／超高／像素／零尺寸／動畫／截斷拒絕、Gemini 十個失敗前不發出推論 POST cases，
  以及 direct／group／incoming／peer／外部回覆的原核准、Stop、account／run／ABA、保存與 recovery 防護。
- `StaticGIFInputUIV3` 留存 22 張真正 native 圖片預覽：
  GIF 的 peer／channel 核准各明暗 × 320／560 兩寬度共八張，加上七語 PNG／GIF 說明各一張。
  人工檢視最後 source 的窄版深色外部核准及七語 GIF 圖片說明；圖片、目的地、全文、digest、
  MIME／大小、Approve／Reject 及完整 GIF 限制提示沒有因新格式文字而被裁切。
- `static-gif-input-localization-v2.log`：terminal exit 0；七語各 1,819 keys、0 missing。
  focused 另以七個 actual resource cases 核對新 GIF 提示、錯誤與原大小限制，不僅計 key 數。
- `static-gif-input-native-v1.log`：隔離 arm64 native Debug `Filicon App` build succeeded；
  `static-gif-input-native-verify-v1.log` 獨立驗證 terminal exit 0。
- `static-gif-input-package-v1.log`：全新 standalone Debug package terminal exit 0；
  `static-gif-input-package-verify-v1.log` 再獨立驗證 terminal exit 0，不只計內建 package verify。
  兩種 bundle 均核對四個 executable、app／XPC entitlements、deep strict codesign、
  KaTeX 0.16.45／20 fonts／MIT、Mermaid 11.16.0／MIT／72 pinned notices；沒有 launch。
- 以上 focused／兩種 build 使用同一產品 source；測試案例分組修正前，
  `static-gif-input-source-v3.sha256` 與 `static-gif-input-source-final-check-v3.log` 核對通過。
  分組修正後另以 `static-gif-input-product-final-check-v3.log` 核對全部非 Tests source 未變，
  因此兩種產品 build／verify 仍對應本批產品；最後測試 source 記於 `static-gif-input-source-v4.sha256`，
  focused／無 filter full 必須重新執行，不沿用 v3 測試結論。
  `Package.swift`／`Package.resolved` 未改，無新增依賴；原生建置與測試只逐指令選 Xcode toolchain。
  本機 Swift 6.4、macOS 26.7（25G229）／arm64；native build 使用 macOS 27.0 SDK。
  這些 Debug gates 不代替最低 macOS 14 或實際使用者 App／XPC runtime 驗收。
- 無 filter 串行完整回歸 `static-gif-input-full-v1.log` terminal exit 1：
  17 runners 共 2,303 Swift Testing methods／268 suites，App 864／105（1,899.001 秒）有 196 issues，
  Agents 57／8 有 7 issues；17 XCTest runners 共 135 tests／0 failures，兩項 opt-in live skipped。
  既有 `GroupChannelPublicationAppTests.approvalCardRetainsWholePayload(language:width:)` 記錄三個 60 秒逾時
  （en 340／620、zh-Hant 340）。`static-gif-input-full-sample-v1.txt` 顯示當時正在 Vision OCR，
  日誌緩衝使檔案數分鐘未更新；之後已繼續推進，28 PNG 全數存在，但不能算 green。
  僅將明暗外觀拆成獨立 case，保留 60 秒上限、七語 × 兩寬 × 明暗的全部 28 張畫面，
  保留全文首尾、目的地、核准前不送出及拒絕後不排隊等原斷言。
  後段另有 Routine direct／group、SendToAgent、Updater、Workflow direct 的 193 issues；
  Agents 七個 errors 明確為受保護的隔離 agents.json／workflows.json／runs.json 讀取 EPERM。
  不把其餘 nil／保存／審批失敗一概歸因於鎖屏或資源競爭。
  保留產品與這些 suites 的原斷言／檔案保護，另外重測後再作無 filter full 驗收。
- `static-gif-input-focused-v4.log` terminal exit 0，最後 v4 source 重新編譯 12.79 秒：
  core 9 methods／3 suites／51 cases（0.181 秒），App 24 methods／8 suites／245 cases（57.966 秒），
  合計 33 methods／11 suites／296 cases；包括原 GIF 範圍、foreground group publication 及 delegated group publication。
  修正分組後的 `approvalCardRetainsWholePayload(language:appearance:)` 全部 28 cases 通過（28.060 秒），
  `StaticGIFInputUIV4` 共 50 張 native PNG，原 22 張加上 28 張完整 outgoing payload 核准畫面。
  另目視 v4 的法文 340 dark 長全文、英文 320 dark GIF channel review 及西文 GIF disclosure；
  全文首尾、目的地、digest／MIME、原圖、完整格式限制及核准／拒絕按鈕可見，未見新裁切。
  這只證明最後 focused gate，不代替完整回歸或真實服務。
- `static-gif-input-regression-diagnostic-v1.log` terminal exit 1：原失敗的八個 suites 重驗，
  App 73 methods／5 suites（138.475 秒）有 193 issues，Agents 29／3（2.788 秒）有七個受保護檔案 EPERM。
  原 assertions／產品 source 未變，沒有因 GIF focused 通過而忽略這輪失敗。
- `static-gif-protection-probe-v1.log` terminal exit 0：隔離 ordinary／
  `completeFileProtectionUnlessOpen` 兩個小檔均寫入、關閉後重新讀取成功。
  接著 `static-gif-input-regression-diagnostic-v2.log` 重新編譯（3.21 秒），terminal exit 0：
  同八個 suites 的 App 73 methods／5 suites（28.181 秒）、Agents 29／3（1.823 秒）全部通過。
  此間只新增忽略的獨立診斷工具，未修改失敗 suites、產品或檔案保護。
  這確認這次重測時檔案存取已可用，不代替前兩輪全部 issues 的個別根因證明。
- 最後 v4 source 的無 filter、`--no-parallel --force-resolved-versions` 完整回歸
  `static-gif-input-full-v2.log` 主動中止，terminal exit 130，不是完整失敗數或 green。
  執行前 `static-gif-input-pre-full-v2-check.log` hashes 全數符合；core 1,095 methods／122 suites
  （55.167 秒）通過，原 foreground group review 的 28 cases 亦通過（20.753 秒）。
  後段 Mailbox channel publication 出現儲存不可用／審批邊界未到達。
  `static-gif-input-screen-locked-v1.log` 當下明確記錄 `CGSSessionScreenIsLocked=Yes`；
  同時 `static-gif-protection-probe-locked-v1.log` 顯示先前相同 bytes 的 ordinary 檔仍可讀，
  protected 檔改為 EPERM。這確認當下鎖定與檔案存取障礙，不將每項 Mailbox issue 擅自作個別根因結論。
  唯讀核對 PID 31826 的完整 argv 及 stdout 指向本輪 log 後，只中止自己的測試，helper 一併結束。
  未停 App／Xcode，未降低檔案保護；當時等待使用者解鎖後重驗失敗 suites 及無 filter full。
- 續跑前重新讀取同一組 ordinary／protected 診斷檔，兩者均可讀且 bytes digest 相同，
  沒有重新寫入 protected 檔來掩蓋拒讀。`static-gif-input-resume-source-check-v1.log` 核對 v4 source 通過。
  `static-gif-input-regression-diagnostic-v3.log` terminal exit 0，重建 2.55 秒：
  原 Mailbox channel publication 完整 suite 的 24 methods／1 suite（155.551 秒）通過，
  原 assertion／產品 source／檔案保護未變，沒有以選取正例取代失敗 scope。
  這只證明本次重測通過，不追溯將 full v2 每項 issue 都歸因於鎖定。
  隨後以 fresh 無 filter full v3 作最後回歸；只在測試命令存續期間以 `caffeinate -di` 保持顯示器／系統喚醒，
  不更改鎖定／密碼設定，命令結束即解除自己的 assertion。
- `static-gif-input-full-v3.log` terminal exit 0，重建 3.38 秒：
  無 filter／串行／固定 resolved versions，17 Swift Testing runners 共 2,303 methods／268 suites 通過，
  17 XCTest runners 共 135 tests／0 failures；App 864 methods／105 suites（1,077.679 秒），
  core 1,095／122（87.792 秒），Agents 57／8（1.985 秒）。
  原 Mailbox suite 在完整回歸亦通過（104.803 秒），28 個 outgoing 核准畫面 cases 通過（32.519 秒），
  原先失敗的 Routine／Workflow／SendToAgent／Updater／Agents suites 全部保留在無 filter 回歸中。
  兩項真人 Codex opt-in skipped；既有 CoreData／NSXPC 診斷仍留在 log，不能稱外部 runtime 已修復。
  `StaticGIFInputUIFullV3` 保留完整回歸畫面，另目視本輪法文及韓文 GIF 說明，
  圖片、完整標題、收件者、filename／digest 及四張／5 MB／12 MB 提示可見，未見新裁切；
  不將完整輸出張數當成逐張人工驗收。
- 最後 `static-gif-input-source-final-check-v5.log` 核對原 v4 的全部產品／測試 source hashes 通過，
  full v3 後沒有再更動產品或測試；`Package.swift`／`Package.resolved` 仍未改，
  提交前另以 `static-gif-input-precommit-source-check-v1.log` 再次核對相同 source 通過，
  最後 `git diff --check` 通過。單幀 GIF 本批必要 gates 完成，隨本批本機提交，未 push。
  沒有降低檔案保護、移除失敗案例、停用原斷言或重啟使用者 App／Xcode。

## 保留邊界

仍最多四張、每張 5 MiB、整批 12 MiB；只接受完整解碼且單幀、每邊最多 8,192、最多 16M 像素。
選檔器與七語提示同步，舊錯誤文字翻譯保留以顯示既有歷史。
本批圖片委派／外部送件仍使用原 scope／receipt／account／run／Stop／ABA 與逐次人類核准。

真實 AI／Slack／Discord、其他 MIME／host、VoiceOver／真人、最低 macOS、Release／Developer ID／公證仍未驗。
48 分類與整體 partial 不變；不 push、不啟動／重啟 App 或 Xcode、不改真實資料、不清理歷史 artifacts。
