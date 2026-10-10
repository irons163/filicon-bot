# Incoming 頻道圖片驗收（2026-10-10）

後續增量：`5edeee9` 後補當次 capture 的獨立預覽核准／單一 peer 委派與 direct 圖片預覽／窄版標題換行；解鎖後最後 focused v8 六 methods／30 cases、28 張七語明暗寬窄畫面、related v2 共 149 methods／8 suites、重新建置無 filter full v2 的 2,288 Swift Testing methods／268 suites＋135 XCTest／0 failures，以及 native／standalone Debug build／獨立 verify／七語檢查／source hashes／diff check 均通過；兩項 opt-in live skipped，隨本批提交，未 push。原失敗與 full v1 中止／4x OCR 重驗保留，見 [頻道圖片委派驗收](Channel-image-peer-validation.md)。以下保留原 incoming 推論／保存增量的範圍與證據，不代表轉寄自動獲得許可。

## 本批範圍

基線 `f3a050b`。重新唯讀核對 reconstructed HEAD
`a9f633e09d49a85829b8236331b9e21f7e612634` 的
`source/host/extensions/transcript/background-wakes.ts:200–248` 與
`send-message-shaping.ts:290–296`：incoming wake 使用自己的背景 direct session，
把當次 envelopes 的 images 交給 runner；不是把群組／他人的私訊搬進推論。

Filicon 的 Slack／Discord connector 原已有驗證來源的附件下載與 channel CAS，
但 `reconcileChannelInbound` 直接略過所有帶附件的 envelope，external source codec
亦只接受零附件。本批補的是「當次 incoming PNG／JPEG 進入原 owner own-DM 推論，
並在原聊天持久保存、可預覽」，不是 incoming 檔案全格式、轉寄圖片或所有 host parity。

限制為最多 4 張、各 5 MiB、合計 12 MiB，每張須為可完整解碼的單影格 PNG／JPEG。
不支援圖片輸入的原 recipient model 明確失敗，不以文字偷偷降級；不換模型。
未新增 UI 控制，錯誤沿用既有七語訊息。

## 原生 authority 與資料邊界

- `ChannelInboundImageInput` 只能以 service 真正核發的 process-local admission 建立。
  先驗整批 metadata 的個數、唯一 lowercase SHA-256、名稱、型別、個別／總量及時間，
  再讀 exact envelope 的 channel CAS。純 `metadata(for:)`、保存 provenance 或模型 ID
  都不是讀取 capability。
- 正式 reader 使用既有 descriptor-relative／no-follow CAS 讀取。每次 await 前後
  重驗原 admission 與 inherited host lease，captured bytes 的長度、digest、完整解碼
  MIME 必須吻合。沒有任意 URL／路徑下載，也沒有新 Keychain／帳號操作。
- 一個獨立 ephemeral user transport 攜帶當次 bytes；原生 canonical remote row
  保持 external source，後續推論一律轉為 untrusted assistant context 並移除圖片。
  transport 不保存、不配置短位址，不成為人類 reaction target、核准或記憶來源。
  同 turn 的一次 hidden reply reminder 只沿用相同 capture，沒有第二次 blob 讀取。
- 原 recipient／account、unique own-DM binding、model／reasoning／persona、頻道設定
  以及 Stop／隱藏等既有 fences 繼續生效。更改後還原不能復活舊準備工作。
  Incoming 並沒有取得圖片轉寄／publication grant；對外送件仍須正常獨立核准。
- 保存時以相同 captured bytes 走一般 attachment CAS、quota 與 reference index。
  metadata 使用原收到時間，不把本機安裝時間冒充來源時間。普通 save 不能移除、
  改寫或替換已接受的 remote row。原聊天的正常預覽實際驗證 materialized bytes。
- 保存前後重驗 scope；失敗只退休該未保存訊息的 references。若 quota 回報錯誤前
  canonical row 已成功保存，保留其原圖片／references，不偽稱沒有 commit。
  無法確定保存結果時保留資料，由正常 reconciliation 修復，不刪使用者資料。
  Stage 已完成但 quota receipt 失敗的未認領 upload 保持 staged，遵守原生命週期，
  不因此啟動模型或送件。
- 帶圖片的已完成 question／secret 卡片可解析原 thread，但 fresh human callback
  只解析 metadata，不讀／重播原 image capture，不沿用舊 execution 或送件核准。

## 重現與修正歷史

所有命令輸出保留於忽略的 `.build/validation/`；以下 exit 1 未被刪除或算成功。

1. `inbound-image-red-v1.log`／`red-v2.log`：新測試的 actor await／macro autoclosure
   編譯錯誤，修正測試 API 用法，不是已執行功能的紅燈。
2. `inbound-image-red-v3.log` exit 1：成功編譯、四個新舊 own-DM × PNG／JPEG
   實際 listener cases 都未開始 incoming run，重現帶附件被略過。
3. `inbound-image-focused-v1.log` exit 1：capture core 四 cases 的完整 transport 比對
   及一個 App case 找到 prompt 重建 JSON 欄位順序不固定。產品 encoder 改 sorted keys，
   保留完整 transport 驗證，不刪欄位／降低斷言。
4. `inbound-image-focused-v2.log`、`inbound-image-related-v1.log`：測試 gate closure
   optional／Sendable 型別編譯錯誤，改顯式型別，沒有改正式 concurrency 約束。
5. `inbound-image-focused-v3.log` exit 0：core 11 methods／2 suites、Channels
   21／1、App 3／1；圖片／image-only、後續文字無重播、九種晚到 read 失效與
   metadata／bytes 拒絕通過。之後增強 native missing／corrupt CAS、preview、quota、
   圖片卡片 callback，不能以本次 green 代替後面的最後來源 gate。
6. `inbound-image-related-v2.log` exit 1：core 24 methods／5 suites、Channels 21／1
   通過；App 30／1 有六 issues。圖片卡片的 dedup fixture 誤重送另一個文字 event ID，
   因此正確開始了新 run。改為重送實際原 envelope，仍完整比對所有 runs／聊天／outbox，
   不忽略新 row 或放寬 dedup。四個實際 quota phase failures 已通過。
7. `inbound-image-related-v3.log` exit 0：上述相同相關 scope 全部通過。其後補上
   context 初始化的 native receipt／run／conversation／owner 組合驗證，並保留 canonical
   source 完整相等檢查。最後 `inbound-image-related-v4.log` 重編譯、terminal exit 0：
   core 24 methods／5 suites（0.326 秒）、Channels 21／1（0.719 秒）、App 30／1
   （57.813 秒），沒有以早一版 green 代替最後產品 source。
8. `inbound-image-full-v1.log` terminal exit 1：17 bundles 的 2,282 Swift Testing
   methods／268 suites，另 135 XCTest；App 的既有 peer image `approve` case 有兩個
   issues，其他 targets 沒有失敗，兩項 opt-in live skipped。失敗當下的完整 App dump
   顯示 `isLoadingModels=true`，送出回報「等待模型目錄在傳送前完成裝入」，所以後續
   inspection 沒有開始；不是 incoming 圖片讀取錯誤，也不歸因鎖屏。
   `selectRoute` 會另外排入 history／draft／catalog task，await 一次顯式 refresh 不保證
   最新 ticket 完成。fixture 改為等待同 peer／provider 的實際可送狀態，保留原 started、
   完成及完整 peer metadata／text 斷言；inspection 另比對整份 image-input dictionary
   必須為空。沒有放寬正式送出 guard、略過失敗 case 或改產品來源。
9. `inbound-image-related-v5.log` terminal exit 0：擴大包含完整 peer image 與
   model-catalog guard suites，合計 90 methods／9 suites 通過。
   `inbound-image-full-v2.log` 重新建置、無 filter 串行全套 terminal exit 0：
   17 bundles 的 2,282 Swift Testing methods／268 suites 及 135 XCTest／0 failures；
   App 848 methods／105 suites（553.534 秒），原 peer image method 的全部十 cases
   通過（1.368 秒）。兩項 opt-in live skipped 保留，不算 live 成功。

## 最後 gates

本批最後必要 gates 均已通過，隨本批提交。第一輪完整測試的失敗及 fixture
修正保留如上，不拼接早期 green 或以 focused 成功代替 full。產品 source 在
related v4、native v2 與 standalone package v1 後沒有再改；full v1 後只修既有
peer image test 的原生就緒等待。這只驗收上述有界 incoming 圖片增量，不代表
所有格式、轉寄、runtime 或整體 parity 完成。

| Gate／日誌（皆在 `.build/validation/`） | 本批實測 |
| --- | --- |
| `inbound-image-related-v5.log` | 重編譯 exit 0：core 24 methods／5 suites（0.349 秒）、Channels 21／1（0.705 秒）、App 45／3（61.893 秒），合計 90 methods／9 suites；包含全部原 peer image 與 model-catalog guard cases。 |
| `inbound-image-full-v2.log` | 無 filter、無 `--skip-build`、串行完整回歸 terminal exit 0：17 Swift Testing bundles 合計 2,282 methods／268 suites；17 XCTest bundles 合計 135 tests／0 failures。App 848／105（553.534 秒）。兩項 opt-in live skipped，沒有刪除或跳過第一輪失敗案例。 |
| `inbound-image-native-v1.log`、`inbound-image-native-v2.log` | 皆 exit 0／`BUILD SUCCEEDED`。全新隔離 `InboundImageNativeV1` DerivedData 起建；最後 native scope guards 後同目錄增量，v2 明確重新編譯 AppModel。 |
| `inbound-image-native-verify-v1.log` | 獨立 verify exit 0，四個 executable、app／XPC entitlements、offline KaTeX／Mermaid resources、deep strict codesign 通過；只對 Xcode Debug 使用 `--xcode-debug`，不是 Release 例外。 |
| `inbound-image-native-sources-v1.log` | exit 0：checked-in Xcode project 的 App source membership 與實際 65 個 Swift files 相同；新的 AppServices source 經 package dependency 編譯。 |
| `inbound-image-package-v1.log` | 全新 `InboundImagePackageV1/Filicon.app` 的 standalone SPM Debug 封裝 exit 0，內建 verify 通過。腳本列出的 launch smoke 命令沒有執行。 |
| `inbound-image-package-verify-v1.log` | 另行獨立 verify exit 0；四個 executable、resources、entitlements、deep strict codesign 通過，未使用 `--xcode-debug`。 |
| `inbound-image-localization-final-v1.log` | exit 0：en／zh-Hant／zh-Hans／fr／es／ja／ko 各 1,817 keys，全部 0 missing。沒有新增未翻譯的 UI 控制。 |

Native 命令為 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Filicon.xcodeproj -scheme "Filicon App"
-configuration Debug -destination 'platform=macOS,arch=arm64'
-derivedDataPath .build/validation/InboundImageNativeV1 build`。
全套命令為 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
--disable-sandbox --no-parallel`。Standalone 以 `CONFIGURATION=debug`、
`BUNDLE_PATH=.build/validation/InboundImagePackageV1/Filicon.app` 執行
`scripts/package-app.sh`；獨立 verify 對各自 bundle 使用 `--version 0.1.0 --build 1`。
沒有改系統 developer directory，也沒有啟動包好的 App。

測試依 Swift Testing／Dependencies／CustomDump 技能，沿用可注入 reader／worker
與 native readiness，完整比較 canonical codec、reference index、inference image
dictionary 及不相關聊天／送件佇列。沒有增加測試專用產品捷徑、關閉送出 guard、
縮小原斷言或略過失敗案例；提交前再次比對本批十個產品／測試來源未變動，
`git diff --check` 與最後文件差異檢查通過。全部測試／bundle／日誌保留，未清理檔案。

## 保留的缺口

這批是隔離資料與 native code 的 deterministic 驗證，沒有真實 Slack／Discord 帳號
的收件／下載／送件驗收，也沒有 launch 或重啟使用者 App／Xcode。
沒有對真實帳號、群組或聊天寫入，未 push。

Incoming 圖片轉寄、非 PNG／JPEG 附件、private DM context sharing、hidden fallback／
unified runtime、其他 host 的獨立反應／取消驗收，以及真人／VoiceOver／最低 macOS／
Release／Developer ID／公證與外部服務仍保留。Debug／ad-hoc 不是 release 或 live XPC
驗收；兩項 opt-in live test 的 skipped 不能當成功。48 分類及整體 partial 不上調。
