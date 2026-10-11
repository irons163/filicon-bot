# 當次頻道圖片的外部回覆驗收（2026-10-10–11）

## 範圍與原始依據

基線 `a7d9378` 已支援 incoming PNG／JPEG 的原 owner own-DM 推論、保存及獨立核准後的單一 peer 委派，
但外部 `SendMessage` 只接受另行授權的 file／HTTPS locator，不能使用當次 native capture。
唯讀核對 reconstructed HEAD `a9f633e09d49a85829b8236331b9e21f7e612634`，本次核對的檔案為：

- `source/host/extensions/transcript/background-wakes.ts:200–252`：incoming 當次圖片進自己的背景 direct runner。
- `source/host/extensions/transcript/send-message-tool.ts`、`send-message-shaping.ts`：文字圖片可帶明確 channel target。
- `source/shared/channel-messaging.ts:42–70`：文字只取第一個有效 image，以全文為 caption；standalone attachment 使用 URL 與 alt。
- `source/host/connectors/channel-attachment.ts`：來源取得後上傳真正 bytes，不把本機路徑當成外部圖片。

本批只補「當次 admitted PNG／JPEG → 全新圖片／目的地／全文核准 → 外部 channel queue」。
不新增任意歷史圖片、舊 callback、其他 host 的圖片 capability、群組圖片廣播或 private history sharing。
standalone `attachment.image_id` 仍不接受；既有 URL attachment 契約不變。

## Authority、圖片與保存邊界

外部 transaction 的 current image directory 只由原 native incoming execution 提供，最多四張已驗 metadata。
沒有 directory 的其他 host 維持拒絕 image ID；同回合的 discarded images 也須逐一匹配 directory，
不能把非法來源藏在不傳送的第二張。schema 只列該 directory 的 exact ID；模型字串不是路徑、URL 或讀取權限。

shared source adapter 取得該次 immutable capture，不重新打開 channel CAS 或原歷史圖片，不降級成檔案／網路讀取。
每個 await 前後仍重驗原 account／binding／persona／model／reasoning、channel admission、原 run、native scope 與 lifetime。
排隊前仍驗原 owner 的唯一 enabled connection、完整 address／thread、bytes／digest／MIME／size，
沿用 app-wide quota 與 no-follow channel CAS 安裝；拒絕、Stop 或 ABA 不復活已失效的 run。

原聊天保留完整 review，額外顯示實際捕捉圖片、檔名及完整 ID。資料只來自當前 process-local pending registry，
須對應唯一 canonical card；偽造、其他聊天、過期或已結束卡片無預覽／核准能力。
一般 auto-allow rule 不能跳過圖片／destination／全文的人類核准。
圖片 ID 使用既有「圖片」標籤而非「來源網址」，首張 alt 也列入核准說明。
多圖仍只送第一張，其餘 ID／alt 明確列為未送出，不私下改成多次傳送。

queue origin 與 canonical external publication 共用 typed source：`url` 或 `imageID` 二擇一，後者為 lowercase SHA-256。
首張 captured ID 必須與唯一 outbound file digest 及 PNG／JPEG MIME 相符；來源歷史只是 inert evidence，不能取得新 capability。
舊 URL JSON 的解碼與原 keys 編碼相容。FiliconChannels 明確依賴既有 FiliconDomain，沒有新增第三方套件。
成功後仍依 durable queue receipt 保存／投影，queued 不等於 delivered；只有既有 transport worker 才傳送。

## 測試與歷史

測試使用真正隔離 listener／AppModel／canonical stores／quota／native review／ChannelService queue。
provider fixture 只控制外部 inference，connector probe 只替代遠端 transport；沒有注入假 admission 或核准。
新十個 methods 最後共 67 個展開 cases，涵蓋 PNG／JPEG × ID string／帶描述 object、拒絕／Stop／account 與七種 ABA、
CAS corruption／symlink、capture 後移走原 blob、後續 envelope 猜舊 ID、discarded 非法 ID、typed codec 相容及無網路 fallback。
正案以明確 offline flush 核對真正 connector 收到 exact bytes，且 delivery projection 不改原 publication identity。

七語 native render 各明暗 × 320／560 共 28 PNG，實際顯示 `TranscriptMessageView` 中的 capture，不注入假 bitmap。
語言以 task-local override 在建立 native proposal 前指定，不改使用者偏好；此後逐張原生 4x render／像素／exact OCR。
同時要求實際圖片、原檔名、完整 outgoing text 與 address 可見，英文標題不得省略；核准／拒絕動作仍由原卡片提供。
已目視 focused v4 七語 dark narrow，以及英文 light wide：未見裁切或重疊。
歷史保存文字不因此宣稱能隨事後語言設定重翻；未做真人／VoiceOver 驗收。

`.build/validation/` 保留原始 logs／PNG，不刪除或拼接早期失敗：

- `inbound-image-publication-red-v1.log` exit 1：預設 CommandLineTools 缺 Testing 模組，未執行功能測試；後續只於本次命令指定完整 Xcode，不改全域 developer directory。
- `inbound-image-publication-red-v2.log` exit 1：新增 Domain import 尚未宣告 direct target dependency，編譯未取得最後 shared source API；補明確本機 target dependency。
- `inbound-image-publication-focused-v1.log` exit 1：optional Sendable closure 的 ternary 觸發 compiler diagnostic failure；改明確 if 分支，沒有放寬 actor isolation。
- `inbound-image-publication-focused-v2.log` exit 1：兩圖 fixture 缺必要 senderDisplayName，尚未執行；補原 envelope 欄位。
- `inbound-image-publication-focused-v3.log` exit 0：當時十 methods／44 cases 通過（core 3／2 suites，App 7／2），UI 23.777 秒；早於最後圖片標籤／描述及 language-before-proposal 修正，不作最後 source gate。
- `inbound-image-publication-regression-v1.log` 主動中止，terminal exit 130：廣域測試未明確傳 `--no-parallel`，實際 helper 同時啟動大量 App／UI cases，多個既有純文字 review／新 incoming cases 未在時限內就緒；不能作回歸成功或完整失敗數。未發現本輪 EPERM，未將每個 issue 都歸因於資源競爭；保留原 log，以相同完整 filter 明確串行重驗，不改斷言。
- `inbound-image-publication-focused-v4.log` terminal exit 0：最後產品／測試 source 重新編譯，明確 `--no-parallel --force-resolved-versions`，十 methods／46 cases 通過（core 3／2 suites、0.007 秒；App 7／2、17.676 秒）。`InboundImagePublicationUIV4` 中本批 28 PNG 全數存在；七語 UI 14.505 秒。
- `inbound-image-publication-localization-v1.log` exit 0：七語各 1,817 keys／0 missing，未增加缺漏字串。
- `inbound-image-publication-regression-v2.log` terminal exit 1：相同完整 related filter 明確串行，core 40 methods／4 suites 及 channel 16／1 通過；App 105／9、1,355.154 秒、900 issues。其中法文 620 寬 dark 舊外部附件卡的 exact OCR 將 `EXCLUDED_IMAGE` 認為 `EXCLUDED_|MAGE`，保存 PNG 目視完整，沒有裁切。其餘 899 issues 來自 mailbox suite 未到 expected boundary／routine consent save 拒絕，當輪沒有 EPERM 診斷，根因尚未確認，不歸因於鎖屏或資源競爭，也不以其他 suites 成功抵銷。
- 舊附件核准卡的測試改為原 native view 直接繪製 4x bitmap，並非放大原圖；保留 exact OCR／全部 markers／完整 live review 前後比較，不用 custom words 或 fuzzy match。`inbound-image-publication-regression-diagnostic-v1.log` 重編譯、terminal exit 0：同法文等七語明暗寬窄方法的 14 cases 與兩個原失敗 mailbox methods／8 cases，共 3 methods／2 suites（25.910 秒）通過。mailbox 產品與測試 source 未改，不宣稱根因已定位或整個 related 已通過；原完整 filter 的 v3 尚待。
- `inbound-image-publication-native-v1.log` terminal exit 0／BUILD SUCCEEDED；`inbound-image-publication-native-verify-v1.log` 獨立 exit 0。隔離 arm64 native Debug 的四 executable、offline resources、app／XPC entitlements、deep strict codesign 通過；沒有 launch 或操作使用者的 DerivedData。
- `inbound-image-publication-regression-v3.log` 主動中止、terminal exit 130，不能作完整失敗數或 green。相同完整 filter 的前八個 App suites（包括 incoming／direct／group／舊附件卡畫面）均通過，mailbox 中重現 queued receipt 被背景 worker 合法送出：實際 `.delivered`／attempt 1／已發送 bytes，而斷言要求 `.queued`／attempt 0／未送出，連帶 canonical projection 與 reopened queue 比對失敗。fixture 仍使用正式兩秒 tick，不能假定 assertions 一定先跑完；只在該 suite 三個隔離 AppModel 建立點注入既有 `channelDeliveryTick`，停止自動 tick。送達／失敗回報案例仍透過原 `ChannelService.flush` 明確推進真正 worker，所有原 receipt／history／sent／reopen 比對保留；產品 cadence 不變。這項已確認競爭不解釋 v2 所有 899 issues。
- `inbound-image-publication-package-v1.log` terminal exit 0；`inbound-image-publication-package-verify-v1.log` 獨立 exit 0。事先確認不存在的新 `InboundImagePublicationPackageV1/Filicon.app` 完整 Debug 封裝，四 executable、offline resources、app／XPC entitlements、deep strict codesign 通過，未執行提示中的 smoke launch。只於該次命令提供完整 Xcode 及 command-local swift wrapper，所有 build 加 `--force-resolved-versions`；Package.resolved 保持原樣，沒有全域 toolchain／script／依賴版本變更。

產品／原新測試 source hashes 記於 `inbound-image-publication-source-v1.sha256`；舊附件卡 4x 測試修正後的 15 個檔案另記於 `inbound-image-publication-source-v2.sha256`，mailbox fixture 時鐘隔離後 16 個檔案記於 `inbound-image-publication-source-v3.sha256`，原產品 source 未變。

### 無 filter 全套回歸

`inbound-image-publication-full-v1.log` 已 terminal exit 1。17 個 Swift Testing runners 共 2,298 methods／268 suites；
App 861／105、3,734.519 秒、16 issues，不能算整批 green。17 個 XCTest runners 共 135 tests／0 failures；
core 1,093 methods／122 suites 通過，兩項 opt-in installed Codex live skipped。所有失敗集中以下兩個既有 suites，
不是本批新十 methods 的失敗；本批圖片核准 UI 在 full v1 也通過，28 PNG 全數存在，另目視英文 dark 320、法文 light 560、繁中 dark 320，未見裁切／重疊。

- Background direct 的 routine attachment approve 與 scheduled workflow reopen 兩 methods／2 issues：`sent == []` 比對取得已送出 outbound。原 fixture default 兩秒 tick 合法執行早於斷言；只在該 suite 原始與 reopened AppModel 兩個建立點注入既有 `channelDeliveryTick`，停止自動 tick。送達／失敗案例仍明確推進真正 `ChannelService.flush`，所有原斷言與正式 cadence 不變。17 檔 hashes 當時記於 `inbound-image-publication-source-v4.sha256`，前 16 檔的 v3 hashes 當時全部仍匹配。
- Group attachment 的兩 methods／8 issues：AVIF／JPEG 與 HTTPS approve 重現 canonical 實際 `.delivered`／attempt 1，斷言要求 `.queued`／attempt 0；完整 bytes／檔名／來源未變。只在該 suite 本機與 HTTPS queued-boundary fixtures 及 retained-preview fixture 三個 AppModel 建立點隔離自動 tick，`delivery-progress` 仍明確 flush，全部原 canonical／matches／bytes／sent 比對保留。17 檔 hashes 當時記於 `inbound-image-publication-source-v5.sha256`。
- 同一 Group attachment suite 的舊七語 UI 方法另有 6 個 deadline issues，耗時 858.464 秒：zh-Hans 620、fr 340、es 620、ja 340／620、ko 340 超過原每案例一分鐘，不能用 queue 競爭解釋；當輪只產生 54／56 PNG。後續將明暗提升為參數矩陣的獨立案例，14 cases 改 28 cases，各自取得 fresh native source／send review；仍為原 56 個 native renders、全部 exact OCR markers、前後 live approval 比對及原每案例一分鐘期限，沒有延長 deadline、減少畫面或模糊字串。

上述後續只改既有 tests，產品 source 與已驗 native／standalone 相同；17 檔最後 hashes 記於
`inbound-image-publication-source-v6.sha256`，啟動第二輪前全數驗證匹配。
`inbound-image-publication-full-v2.log` 重新編譯上述 v6 source、明確 `--no-parallel --force-resolved-versions` 且無 filter。
已觀察 incoming suite 的四個 UI deadline issues：既有 peer review 的 es／ja／ko 三 cases（方法 255.726 秒），
以及本批外部 channel review 的 en 一 case（方法 226.909 秒），每案仍在一個 deadline 內連續畫四張。
該 suite 最後 786.278 秒／4 issues；本批 28 張圖片與目的地 PNG 全數存在，peer review 只留下 24／28 張。
為重驗修正後 source，唯讀確認自己的 swift-test PID／完整 argv 後只中止本輪測試，terminal exit 130；
不是完整失敗總數，也不是回歸 green。其餘 suites 成功不抵銷這四項，未停止 App 或 Xcode。
自己的 helper 原生抽樣 `inbound-image-publication-full-v2-sample-v1.txt` 顯示當時正在 peer review 的
`NSWindow.setContentView`／SwiftUI preference graph 繪製，不是 log 最後印出的 self-target rejection；
未據此宣稱全域資源或鎖屏是逾時的已確認根因。

兩個 incoming UI methods 的明暗／寬度也改成獨立參數，原各 7 cases 改各 28 cases，
每案 fresh native pending review、原一分鐘 deadline、全部原像素／exact OCR／canonical 前後與拒絕清理斷言保留；
兩方法合計仍為原 56 native renders，沒有擴充期限或縮小語言／畫面覆蓋。
最後 17 檔 hashes 記於 `inbound-image-publication-source-v7.sha256`；只再改測試，產品 source 未變。
`inbound-image-publication-focused-v5.log` 重新編譯 240.50 秒、terminal exit 0：選本批十 methods 及既有 peer UI 方法，
共 11 methods／95 展開 cases（core 3／2 suites、0.062 秒；App 8／2 suites、128.687 秒）。
其中新十 methods 為 67 cases，既有 peer UI 28 cases；兩個 UI 方法各 28 cases 全通過，耗時 64.759／49.416 秒。
`InboundImagePublicationUIV5` 兩組各 28 PNG 全數存在，17 檔 v7 hashes 啟動最後全套前全部匹配。
`inbound-image-publication-full-v3.log` 使用最後 v7 source 重新建置，無 filter、明確
`--no-parallel --force-resolved-versions`，terminal exit 0，涵蓋原完整 related 範圍。
17 個 Swift Testing runners 共 2,298 methods／268 suites、0 failed runners；
17 個 XCTest runners 共 135 tests／0 failures；兩項 opt-in installed Codex live tests skipped。
App 861 methods／105 suites（1,256.634 秒）、core 1,093／122（137.506 秒）通過，沒有 failure lines。
其中 incoming suite 234.803 秒、background direct 29.198 秒、group attachment 35.905 秒、
actual direct／group-origin peer channel publication 200.109 秒，先前完整回歸失敗的範圍均已重新執行通過，
不是只以 focused 或其他 suite 成功抵銷歷史失敗。

`InboundImagePublicationUIFullV3` 本批外部圖片核准 28 PNG、既有 incoming peer 核准 28 PNG、
既有外部附件 source／send 各 28 PNG 全數存在（相關 112 native renders）。
本批與 peer 七語 UI 方法各 28 cases，分別 59.336／65.403 秒通過；
舊附件 UI 28 cases／56 renders（29.201 秒）通過，所有原 exact OCR／pixels／live review 比對與一分鐘 case deadline 保留。
另目視 full v3 的外部核准英文 dark 320、法文 light 560、繁中 dark 320，
及舊外部附件的法文 dark 620／日文 light 340，完整文字、圖片、來源／目的地與按鈕未見裁切／重疊。
這不宣稱全部畫面真人或 VoiceOver 驗收。

最後 17 個 source／test hashes 與 v7 全數匹配；十個產品／manifest 檔案與先前 native／standalone
兩套 Debug build 時相同，各自獨立 verify 已 exit 0。七語各 1,817 keys／0 missing、
Package.resolved 未改、diff check 與新增內容的憑證／個人路徑基本掃描亦通過；
此有限掃描不是完整安全審計。所有歷史失敗與 artifacts 保留，最後必要 gates 通過，隨本批本機提交，未 push。

## 保留缺口

其他 incoming 格式／host／runtime 的圖片與 private context sharing、真實 Slack／Discord／AI 帳號、
真人／VoiceOver／最低 macOS、Release／Developer ID／公證仍需另驗。
48 分類及整體 partial 不變；不 push、不啟動或重啟 App／Xcode、不改真實帳號／群組／聊天、不清理歷史 artifacts。
