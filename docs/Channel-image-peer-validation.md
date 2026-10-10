# 頻道圖片的單一成員委派（2026-10-10）

## 本批範圍與原始依據

基線 `5edeee9` 已讓當次 incoming PNG／JPEG 進入原 owner own-DM 推論、保存及預覽，
但 background direct 的 `directRequestImages` 永遠為空，不能將當次圖片委派給另一位成員。
重新唯讀核對 reconstructed HEAD `a9f633e09d49a85829b8236331b9e21f7e612634`：

- `source/host/extensions/transcript/background-wakes.ts:200–252`：channel wake 的當次圖片交給自己的背景 direct runner。
- `source/host/runner/tools/sand-agent-management-tools.ts:1–136`：`SendToAgent` 可解析圖片並交給真正的單一收件人；群組仍為純文字。
- `source/host/extensions/transcript/agent-to-agent-messaging.ts:42–112,217–223`：真正排入單一 peer mailbox，該 peer 的 runner 收到圖片，而不是只顯示假委派文字。

Filicon 這批只補「當次原生 admitted channel PNG／JPEG → 人類預覽核准 → 單一 peer」；
不接受原版的任意 `file://`／HTTPS 圖片 locator，也不新增外部圖片送件或群組圖片廣播權限。

## Authority 與保存邊界

原 incoming execution 先重驗 account／own-DM binding／persona／model／reasoning、channel admission、
canonical source 與 process-local execution identity，再以該次 immutable capture 安裝 peer image CAS。
使用既有 app-wide quota 與 descriptor-relative exclusive CAS 寫入；每個 await 前後重驗 execution。
沒有重開原 channel CAS、讀取保存歷史圖片、任意檔案／網址或從模型 ID 建立 capability。
安裝時間不取代 remote receipt metadata 的原時間。

`AgentMessagingSession` 仍只供原 sender 取得這份 current directory。真正送出前，
既有工具重驗原 sender／單一 active recipient／圖片 ID／bytes，始終顯示完整收件人、
文字與圖片預覽，並等待原生人類核准；一般 allow rule 不能跳過。核准後重新取得 current
directory、驗證 exact CAS bytes，才持久保存並排入真正 peer mailbox。
拒絕、Stop、account／connection／binding／persona／hidden／model／reasoning ABA 不復活舊 run。
group target 仍拒絕圖片，peer 的模型不支援圖片時明確 failed，不改模型或偷偷降級文字。

收件 peer 只取得已核准的 task 與圖片，不借原聊天、原 remote envelope 或自己的私人歷史。
正常 peer transcript 保存與預覽維持既有 CAS／references。後續 text envelope 或 fresh human
card callback 不能沿用舊 capture／review，即使猜中已保存的 image ID 也無效。
圖片本身仍是不可信資料，不是人類指令、對外發送或檔案修改許可。

## 原聊天的核准畫面

檢查真正 `TranscriptMessageView` 發現舊 direct review 只有文字，雖然 group／mailbox
panel 已有圖片預覽，不能據此宣稱 direct 也有。這批沿用既有真實 CAS preview 元件，
在原聊天的 `SendToAgent` 卡片顯示圖片、原檔名、完整 image ID，原卡片保留收件人與
完整委派文字及核准／拒絕動作。顯示資料只從當前 account／run 的 native pending
registry 取得，須匹配唯一 canonical card；偽造卡片、其他聊天、過期或結束的 review
不能沿用。沒有從模型的 card metadata 或保存的舊 card 自行建立預覽／轉寄許可。

新增實際 listener → review → `NSHostingView(TranscriptMessageView)` 的 28 張畫面檢查：
七語 × 明暗 × 320／560 寬度，不前景開窗、不預先注入 bitmap；等待原元件真的讀入 fixture
CAS，以同一原生視窗色彩管理的原圖參考像素和 OCR 驗證實際圖片、檔名及完整委派文字。
參考 swatch 在真正聊天掛載前移除，不注入聊天元件；必須等實際 CAS 圖片與完整文字都出現。
英文窄版標題另以完整 OCR 斷言防止省略號。畫面測試不送 peer／channel，
並比對完整保存聊天不變，最後由原生拒絕解除等待。最後 focused／related／無 filter full
均已通過；完整證據及保留的失敗歷史如下。

## 驗證結果與歷史

`.build/validation/` 保留各輪輸出，不刪除或拼接失敗結果：

- `inbound-image-delegation-red-v1.log` exit 1：新測試成功編譯；PNG／JPEG 兩個真正 listener cases 都未能進入圖片委派核准，重現 background image directory 為空的缺口（4 issues）。
- `inbound-image-delegation-focused-v1.log` exit 1：新接線在 Sendable closure 直接讀 MainActor property，編譯拒絕；改於 host actor 先捕捉分類，沒有放寬 actor isolation。
- `inbound-image-delegation-focused-v2.log` exit 1：呼叫既有 captured image API 漏傳必要的 `altText`，尚未執行；補上原 metadata 的值。
- `inbound-image-delegation-focused-v3.log` exit 1：四個新 methods 中，PNG／JPEG 與 13 種拒絕／失效／CAS cases 通過；captured-byte／unsupported-peer 兩案仍各有兩 issues。兩案 fixture 未切到原 owner 聊天就按 transcript review；原生 `transcriptCardContext` 只接受目前原聊天的唯一 live card，正確拒絕，後續等待因此逾時。修正 fixture 的實際選擇動作，另保留錯聊天按下不能核准的斷言；沒有放寬卡片 router 或資料比對。最後非法 target cases 尚待重新編譯，不能借較早 artifacts 宣稱通過。
- `inbound-image-delegation-focused-v4.log` exit 0：重新建置後五個新 methods／一 suite、23 cases（11.051 秒）通過，含 PNG／JPEG、13 種拒絕／失效／CAS、捕捉後 channel CAS 改寫、舊 envelope ID、不支援圖片的 peer、非法 target／locator。此時尚未加入 direct 核准畫面修正，不能替最後 UI source 作綠燈。
- `inbound-image-delegation-ui-red-v1.log` exit 1：原 direct renderer 的七語新測試真正編譯／執行，57 issues；28 張畫面均沒有實際圖片或檔名，另一次 OCR 未識別完整委派文字，重現核准畫面漏點。
- `inbound-image-delegation-ui-green-v1.log` exit 1：畫面修正已編譯，但兩方法／九 cases 在核准卡片就緒邊界逾時（18 issues），尚未進入 bitmap 比對。當時系統 `CGSSessionScreenIsLocked=Yes`；保留失敗，新增隔離 fixture 的 run／tool／App error 診斷，尚不將鎖定當作已證明的唯一原因。已請使用者解鎖；不能借較早 v4 或 native build 關閉 UI／full gates。
- `inbound-image-delegation-ui-diagnostic-v1.log` exit 1：單方法 PNG／JPEG 兩 cases、6 issues；native inbound runs／tool results 都為空，失敗在 listener admission 之前，沒有圖片委派／peer runner 成功聲稱。
- `inbound-image-delegation-ui-diagnostic-v2.log` exit 1：重新編譯後同兩 cases、8 issues；failure-only 診斷真正重新開啟各自 fixture 的 `agents.json`，皆回 `NSCocoaErrorDomain 257`／underlying `NSPOSIXErrorDomain 1 Operation not permitted`。結合系統鎖定狀態，已確認受保護暫存 store 不可讀，會擋住 native bootstrap／listener。沒有去掉 `.completeFileProtectionUnlessOpen`、改檔案權限、跳過 admission 或放寬斷言。需解鎖後重新跑最後 UI／related／full，不反覆重跑或將此結果算 green。
- `inbound-image-delegation-focused-v5.log` exit 1：解鎖後五個功能 methods／23 cases 再次通過，七語 UI 仍有 28 issues（27 次固定 RGB 門檻失敗、一次 60 秒 time limit）。實際保存 PNG 已顯示圖片；獨立 AppKit 診斷確認同一原圖在 ImageRenderer 與原生視窗 cache 的色彩管理輸出不同。改以原圖經相同原生視窗的 swatch 校準、每色差小於 0.02，仍須超過 100 個真實圖片取樣點，不接受 metadata／spinner。目視另發現英文窄版標題省略，產品補垂直換行並加入完整標題 OCR。
- `inbound-image-delegation-focused-v6.log` exit 1：五個功能 methods／23 cases 與 28 張圖片像素檢查通過，但六次文字 OCR 在圖片剛載入、文字尚未完成換行的瞬間失敗；保存畫面目視可見完整委派文字。測試改為同時等待圖片像素和完整檔名／委派文字／英文標題，不刪除或降低原斷言，最後結果仍待 v7 與完整 gates。
- `inbound-image-delegation-focused-v7.log` exit 0：最後 source 重新建置，六 methods／一 suite、30 cases（10.508 秒）全部通過。`InboundImageDelegationUIV4` 實際保存 28 張 PNG；七語窄版 dark，以及英文／法文 wide light 已逐張目視，圖片、完整標題、image ID、recipient／委派文字與核准／拒絕按鈕未見裁切或重疊。既有 Finding 4 是 pending 建立時保存的文字，不宣稱歷史內容跟隨語言即時重翻；未以前景 App 或真人／VoiceOver 驗收代替隔離 UI 測試。
- `inbound-image-delegation-native-v1.log` exit 0 是 UI 修正前的獨立 build；當時產品 source 的 `inbound-image-delegation-native-v2.log` exit 0／BUILD SUCCEEDED，`inbound-image-delegation-native-verify-v2.log` 獨立 exit 0。窄版標題修正後另跑下列 v3。未 launch；Debug／ad-hoc 不算 Release／公證。
- `inbound-image-delegation-package-v1.log` 與獨立 `inbound-image-delegation-package-verify-v1.log` 均 exit 0：事先確認不存在的 `InboundImageDelegationPackageV1/Filicon.app`，四個 executable、離線 resources、app／XPC entitlements 與 deep strict codesign 驗證通過。未 smoke launch，未覆寫／刪除舊 bundle。
- `inbound-image-delegation-localization-v2.log` exit 0：七語各 1,817 keys，0 missing。沿用既有翻譯，沒有新增缺漏 key。
- 最後窄版標題修正後，`inbound-image-delegation-native-v3.log` BUILD SUCCEEDED／exit 0，獨立 `inbound-image-delegation-native-verify-v3.log` exit 0。未 launch 或改使用者 Xcode 的 DerivedData。
- `inbound-image-delegation-related-v1.log` exit 0：重新建置的原範圍通過，三個 test runner 分別 83 methods／5 suites、21／1、45／2，合計 149 methods／8 suites。包含真正 inbound／preview／SendToAgent、圖片 session 與原 source admission 的正反回歸，不縮小失敗範圍。
- `inbound-image-delegation-full-v1.log` 在全範圍執行中記錄一個 UI issue 後主動中止，terminal exit 130，不算 full green 或完整失敗數。簡中 case 的 OCR 將 `EXACT_CURRENT_IMAGE_PEER_TASK` 讀為 `EXAT_CURRENT_IMAGE_PEER_TASK`；其餘本批功能 cases 通過。保留原 log，改以原生 view 直接繪製 4x bitmap（不是放大舊截圖），維持 exact OCR、不接受 fuzzy 比對或把預期 task 加入 OCR custom words；最後測試 source 改動後須重跑 focused／原 related 範圍與無 filter full。
- `inbound-image-delegation-focused-v8.log` exit 0：最後 4x 測試 source 重新編譯，六 methods／一 suite、30 cases（30.755 秒）通過；七語 UI 26.671 秒，`InboundImageDelegationUIV5` 28 張 PNG。簡中 dark wide 的完整 task 已再目視；產品 source 未變，不借 v7 green 代替此輪。
- `inbound-image-delegation-related-v2.log` exit 0：最後 4x 測試 source 再跑原完整相關 filter，83／5（3.906 秒）、21／1（0.782 秒）、45／2（77.361 秒），合計 149 methods／8 suites 全數通過。所有原 cases／exact OCR／來源與 canonical 隔離斷言保留。
- `inbound-image-delegation-full-v2.log` terminal exit 0：最後 source 重新建置、無 filter、無 parallel 的完整套件，17 個 Swift Testing runners 共 2,288 methods／268 suites，以及 17 個 XCTest runners 共 135 tests；0 issue／failure。App runner 為 854 methods／105 suites（722.290 秒），core 為 1,090／122（52.163 秒）。兩項 opt-in installed Codex live tests 明確 skipped，不算已驗真實環境。本批六 methods／30 cases 全數通過，七語 UI 為 20.326 秒；`InboundImageDelegationUIFullV2` 中本批檔名的 28 張 PNG 全數存在（其他既有 UI tests 的輸出不併入這個數字）。另目視此輪英文 light narrow、簡中 dark wide、韓文 dark narrow、日文 light wide 的完整圖／標題／ID／收件人／委派文字／按鈕，未見裁切或重疊。
- `inbound-image-delegation-package-v2.log` 與獨立 `inbound-image-delegation-package-verify-v2.log` 均 exit 0：標題修正後以另一個事先確認不存在的 `InboundImageDelegationPackageV2/Filicon.app` 完整重包四 executable，離線 resources／app 與 XPC entitlements／deep strict codesign 全數通過；沒有 smoke launch 或刪除舊 bundle。
- `inbound-image-delegation-localization-v3.log` exit 0：最後產品七語各 1,817 keys，0 missing。

Swift 測試技能用於隔離真實 listener／quota／canonical stores／mailbox 與完整 typed value 比對；
native provider fixture 僅控制外部 inference，不注入 fake admission、review、送件或 peer runner。
SwiftUI 技能用於沿用既有自適應 preview，保持實際原卡片動作不變；沒有把假圖注入 UI 測試。
`inbound-image-delegation-source-v3.sha256` 是窄版標題修正前的已核對歷史；最後三個產品檔與
測試檔於 4x 畫面測試修正前記於 `inbound-image-delegation-source-v4.sha256`；修正後記於
`inbound-image-delegation-source-v5.sha256` 且逐項核對 OK，產品 source 未變。使用者解鎖後
native／standalone／localization gates 已補驗通過，最後 focused v8／related v2 通過，
無 filter full v2 已 terminal exit 0。最後 source hashes／diff check 再驗通過；新增內容的常見
secret／私人絕對路徑檢查無發現，不等於完整安全稽核。這批與本紀錄一併提交，不 push；
不把先前產品 source 的 focused v4 或單獨 build 當成完整回歸。

## 仍未完成

其他 incoming 格式、跨全部 host／runtime 的圖片與 private context sharing、incoming 圖片對外
publication 的完整流程、真實 Slack／Discord／AI 帳號、真人／VoiceOver／最低 macOS、Release／
Developer ID／公證等仍需另驗。48 分類與整體 partial 不變。本批不 push、不啟動或重啟 App／
Xcode，也不改真實群組、聊天或帳號。
