# 協作能力核對紀錄（更新至 2026-09-25）

## 獨立信箱的持久短地址（2026-09-25）

信箱新增主程式持有的地址索引及人類輸入來源集合，與訊息原子保存；按 origin／sender／recipient 分開編號，沿用 tNu／tNsM／tbsM 文法。配置器讀完整保存歷史而非最近 40 則，重啟補齊舊記錄時保留既有地址，不把來源不明的舊輸入推定為人類。問題答案與安全輸入回條使用既有主程式來源證明。

replyDirectory 帶出短地址，先在完整可見範圍排除重複／無效地址後才截為 40 則。publish 回傳保存後的正式地址；AgentInboundOutput 將其交還工具，使同回合可用短地址作 reply_to。同步到群組的投影不攜帶信箱地址，避免污染另一命名空間。正式回條可重送，模型仍不能指定新地址。配置失敗／保存失敗不先更改記憶體狀態。

使用 pfw-testing／CustomDump 測試來源分類、雙向信箱隔離、舊格式載入、保存再解碼、42 則目錄截斷／重啟、重複地址落在目錄外、正式回條重送及模型同回合 UUID／短地址引用。點擊跳轉仍未接到信箱 UI，因此信箱工具提示明確保留此限制；群組既有 sand-msg 導航與折疊提示不變。AGENT-02 仍 partial。

驗證：`mailbox-address-full-final.log` 完整測試 exit 0；最後同步投影隔離調整以 `mailbox-address-mirror-final.log` 82 tests 驗證通過；`mailbox-address-mirror-native.log` 原生建置與 `mailbox-address-mirror-package.log` 封裝／deep strict codesign 均通過。沒有重啟使用者 App 或修改真實資料。

## 人工回應的訊息身分一致性（2026-09-25）

延伸前一批 ID 邊界檢查至 answerQuestion／resolveSecretRequest：它們產生的新收件也必須避開全部既有收件與發布 ID，與普通 send／publish 共用 containsMessageID。問題答案及安全輸入回條不再能與原卡片共用 ID；拒絕時不更新卡片、不排入新工作、不寫入磁碟。

先以 `mailbox-response-collision-before.log` 重現兩個 response-publication 案例未拋錯且更動記憶體／檔案，再修正共用檢查。回歸沿用 pfw-testing／CustomDump，比對完整狀態與磁碟內容。此為短地址接線前的身分一致性修補，不宣稱信箱短地址／sand-msg 導航完成。

驗證：`mailbox-response-collision-full.log` 完整非並行測試、`mailbox-response-collision-native.log` 原生建置、`mailbox-response-collision-package.log` 封裝與 deep strict codesign 全部 exit 0。沒有重啟使用者 App／Xcode或更改真實資料。

## 引用重送與訊息 ID 邊界（2026-09-25）

已保存的信箱發布先核對完整回條再查新引用目錄，因此原目標被最近 40 則目錄排除後，完全相同的重送仍成功且不重寫資料。變更引用的重送仍拒絕；新發布不能使用任何既有收件／發布 ID，新收件也不能撞到發布 ID。保留 running、lifetime、scope、作者、內容及新發布的圖片驗證與兩則上限。

使用 pfw-testing／CustomDump 補上 40 則邊界、變更重送、雙向 ID 衝突與儲存內容不變的回歸測試。`mailbox-replay-tests.log` 21 tests 通過；擴大信箱與 session／App 假服務整合驗證 `mailbox-replay-final-tests.log` exit 0。未重啟 App、未使用真實資料。此為正確性修補，不代表穩定短地址或 sand-msg 導航完成，AGENT-02 仍 partial。

## 安全憑證請求引用（2026-09-25）

獨立信箱 secret-request 現在接受 optional reply_to，透過既有目錄解析為 UUID，App 傳至 publishSecretRequest 並在保存時重驗參與者／origin／目標。回條重送比較內容與引用 UUID，改變引用不會重建請求。只增加訊息關聯，不改變目的地、帳號、credential writer、暫停、新回合或授權流程；value／text／path 等額外輸入仍拒絕。

使用 testing／CustomDump 技能驗證有引用的重送與拒絕變更；App 假 provider／writer 的提供、關閉、回條失敗重試、帳號切換、雙方封存及 Stop 七種情境全部改用引用請求並通過。模型層保持原有安全狀態管理，不把憑證交給畫面引用。`secret-reply-final-tests.log`、`secret-reply-full-tests.log` 完整回歸與 `secret-reply-native.log` 均 exit 0，封裝／deep strict codesign 通過。未操作真實憑證或重啟 App。此項取代上方舊的 secret-request reply_to 缺口；短地址與 sand-msg 導航等其餘差異仍保留，AGENT-02 partial。

## 引用完整回歸與明暗驗收（2026-09-25）

確認 IOConsoleLocked=No 後補跑 `mailbox-reply-complete-recheck.log`，完整非並行 swift test exit 0；前幾輪 mailbox receipt／question／quote UI 的待解鎖驗證已補齊，並非跳過失敗案例。未降低檔案保護。新增七語言明暗雙模式渲染，`mailbox-quote-dark-tests.log` 14 案例通過；人工檢視繁中、法文 dark 引用及問題卡片，未見裁切。測試使用 SwiftUI／testing 技能，沒有啟動使用者 App 或修改真實資料。

重新查核原版 send-message-tool.ts：短地址同時供 reply_to 與 sand-msg 點擊導航使用；目前信箱只有 UUID 引用，不把摘要 UI 視為短地址完成。短地址持久化／編號、導航、展開互動與圖片引用驗收仍待處理；secret-request 的 reply_to 也是原版支援、目前 native 尚未接線的剩餘差異。AGENT-02 維持 partial。

## 信箱引用摘要畫面（2026-09-25）

已保存的信箱 publication 現在顯示引用作者與最多 240 字摘要，可展開原文與圖片；不存在或重複 ID 顯示既有的「原訊息無法使用」。原訊息解析限制同 sender／recipient／origin、截至引用 publication 之前，不使用模型的 40 則目錄上限，避免較舊的合法引用失去顯示。未加入跨信箱跳轉或猜測來源。

SwiftUI 技能用於 disclosure 摘要，testing／CustomDump 用於同範圍、重複、未來、跨 scope／sender 查找測試及七語言畫面渲染。修正既有畫面測試只設 environment locale、未設 App TaskLocal 語系的問題；人工檢視繁中與修正後法文圖，文字可見且未截斷。`mailbox-quote-ui-tests.log`、`mailbox-quote-ui-native.log` 通過，package／deep strict codesign 通過。未啟動使用者 App。暗色、展開互動及圖片引用仍需進一步 UI 驗收；短地址與 sand-msg 導航仍未完成，完整回歸仍待補驗，AGENT-02 partial。

## 信箱問題引用接線（2026-09-25）

publishQuestion 可保存 replyToMessageID，沿用同參與者／origin 引用目錄及共用保存驗證；獨立信箱 SendMessage 的 widget reply_to 接入此路徑。提問後仍暫停原回合，回答或關閉後才以新的人類回合續聊，不繼承工具權限。不存在、自我、跨範圍引用不會保存或造成暫停；保存成功後不得繼續發布。

使用 testing／CustomDump 技能補保存與假 provider 整合驗證。`mailbox-question-reply-tests.log` 兩項測試共七案例通過，`mailbox-question-reply-native.log` 原生建置與封裝／deep strict codesign 通過。系統仍鎖定，前輪廣泛回歸的 protected-file EPERM 待解鎖補驗，不能用本次定向通過代替完整回歸。引用的畫面卡片與短地址仍待補齊，未宣稱全面 parity；未啟動 App 或修改真實資料。

## 信箱同回合發布回條（2026-09-25）

獨立信箱使用 host 提供的 receiptSenderID／publishReceipt，只有正式保存後才回傳 RoomMessage。共用工具重驗 sender、scope、內容、圖片及 reply target，將新 UUID 加入本回合目錄；模型可先發布進度，再以 UUID 引用該訊息。鏡像顯示失敗仍不要求重發已保存訊息。非獨立信箱入口保留原 transport，不自動增加能力；secret／question 暫停流程不變。

testing／CustomDump 測試驗證回條、工具層重送與兩則額度，以及假模型兩次不同 call 的保存引用。`mailbox-receipt-unit-tests.log` 8 tests 通過、`mailbox-receipt-session-tests.log` 通過，原生建置及 package／deep strict codesign 通過。首輪廣泛回歸 `mailbox-receipt-tests.log` 有鎖定狀態（IOConsoleLocked=Yes）的 protected-file EPERM；另新測試原本用重複 call ID，被既有 ToolLoop 拒絕，已改為工具層驗證重送並單獨通過整合測試。不把所有失敗歸因於鎖定；完整回歸仍待解鎖補驗。未改檔案保護、真實資料或重啟 App。引用 UI、短地址與 question 引用仍未完成，AGENT-02 partial。

## 獨立信箱引用模型接線（2026-09-25）

host 開啟 supportsMailboxQuestions 的獨立信箱回合，現在將保存層引用目錄交給 SendMessage，text／image publication 可帶 reply_to UUID。輸出鏡像保留 replyToMessageID，保存時再次核對目標；背景及其他未開啟入口不提供引用。引用目錄無法取得時不提供候選，不猜測目標。端到端假 provider 測試覆蓋開啟時保存 inbound 引用、關閉時路由拒絕且無 publication。

`mailbox-reply-wiring-tests.log`、`mailbox-reply-full-tests.log`、`mailbox-reply-native.log` 均 exit 0；封裝及 deep strict codesign 通過。未啟動使用者 App、未連接真實帳號。仍缺信箱引用視覺卡片、短地址、同回合新增 publication receipt 目錄、question 引用接線；不能宣稱原版 reply_to 全面對齊，AGENT-02 保持 partial。

## 信箱引用保存基礎（2026-09-25）

AgentMessenger 新增同 sender／recipient／origin、截至目前 inbound 的引用目錄，最多 40 則，排除重複 ID 與空白內容。保存 replyToMessageID 時核對目錄並拒絕自我引用；既有兩則額度、停止 fence 與 exact replay 保留。隔離測試覆蓋保存／重載／重送、不同 sender／scope、未來及不存在目標、目前 inbound 與已保存 publication 引用。`mailbox-reply-tests.log` exit 0。這是保存層基礎，尚非完成模型入口、引用顯示或原版短地址；AGENT-02 仍 partial。測試使用 testing／CustomDump 技能，未碰真實資料。

## 模型斷線操作的帳號隔離（2026-09-25）

`update_state(target:channel,action:disconnect)` 現在以 management session 的 host account 篩選 ownerAccountID，同 agent 在其他帳號下的連線不進候選，也不造成 ambiguous。舊無 owner 的連線只屬 local。提案保留 owner，App 在核准及提交時核對目前帳號；既有 lifetime／revision／完整 connection snapshot 仍拒絕等待期間的變更。測試覆蓋同 agent 跨帳號兩條連線只刪自己，以及只剩另一個帳號時不提出核准、不刪除；帳號由 host 提供，模型不能指定。

此修正延續原版自己的 channel disconnect，不增加自動斷線、憑證刪除或遠端 OAuth 撤銷。全域 channel UI／收送帳號策略仍是另列缺口。

驗證：首輪 `channel-account-full-tests.log` 在 IOConsoleLocked=No 前後檢查下仍有 protected-file EPERM 及衍生斷言，不能只以畫面鎖定解釋。未改保護設定；獨立暫存 plain／protected 讀寫均成功，`channel-account-focused-recheck.log` 17 tests／2 suites 通過，再執行完整 `channel-account-full-recheck.log` exit 0，先前失敗的 updater、credential、agents、channels、MCP 與 UI 回歸均恢復。`channel-account-native.log` 原生建置 exit 0，package verifier／deep strict codesign 通過。下方前幾輪「待解鎖完整回歸」現已補驗；暫時 EPERM 的底層原因未完全證實，不聲稱修改程式已修復 OS 保護問題。測試使用 testing／CustomDump 技能，未操作真實帳號或重啟使用者 App。

## 遠端帳號與 Filicon 帳號分離（2026-09-24）

端到端檢查發現既有 `ChannelConnection.accountID` 由 refreshProfile 寫入遠端 workspace／user ID；先前 secure request／GetChannelStatus 將它當 Filicon account scope 比對會錯誤拒絕已登入的連線。新增 optional `ownerAccountID`，新 token／OAuth 連線記錄建立開始時的 Filicon account；遠端 profile 刷新仍只更新 accountID。憑證目的地及狀態查詢改比對 authorizationAccountID，缺少 owner 的舊資料只歸 local，不根據遠端 ID 推測帳號歸屬。沒有搬移或改寫使用者真實資料。

隔離 fixtures 明確包含不同 remote／local ID，新增 Codable 舊資料相容及 profile 刷新不改 owner 測試。此修正限於憑證／狀態的身份邊界，不能據此宣稱整個 channel subsystem 已做完整多帳號隔離；既有全域 channel UI／收送與帳號轉移策略仍需核對。完整回歸仍待解鎖，AGENT-02 維持 partial。

驗證：`channel-owner-final-focused.log` exit 0、`channel-owner-native.log` exit 0，封裝／deep strict codesign 通過。較廣的 `channel-owner-focused.log` 僅 onlyWriterSeesValueAndRetriesCannotOverwriteIt 在重讀 channels.json 時因 IOConsoleLocked=Yes 遇 EPERM，未降低保護或跳過後聲稱完整通過。

## 提交後驗證認證（2026-09-24）

最終針對性測試 `channel-status-focused.log`、原生建置 `channel-status-native.log` 均 exit 0，封裝與 deep strict codesign 通過；完整回歸仍待解鎖。

原版 `sand-secret-request.ts` 的回條要求後續查核 connector 狀態。Filicon 增加原生 `GetChannelStatus(platform:slack|discord)`，在有 ChannelService 的管理 session 提供；不是原版 MCP server 狀態工具的別名。host 固定 account／agent／origin，只查自己的唯一既有連線，最多八次。實際 profile 查詢只回 authenticated／unverified 等固定狀態，不回傳 identity、憑證或底層錯誤，不保存 profile、不啟用或重建連線。unverified 不區分網路故障或無效認證；authenticated 只代表當次 profile 驗證，不代表 listener 健康、訊息送達或新權限。查詢期間更新憑證／連線後的舊結果回 stale，session 關閉或代理人封存不回報成功。

使用 testing／CustomDump 技能與假 connector 驗證帳號／owner 隔離、disabled、認證成功、錯誤遮蔽、拒絕模型指定 owner、關閉及憑證換代。新增測試通過；較廣回歸記錄 `channel-status-tests.log` 遇到鎖定畫面時受保護 fixture 讀取 EPERM（已確認 IOConsoleLocked=Yes），尚不能宣稱完整回歸通過。仍需解鎖後補驗；真實遠端登入、新連線建立、其他入口與 MCP 狀態仍保留原範圍，AGENT-02 partial。

## 憑證更新後的監聽連線（2026-09-24）

確認 Slack 輪詢在開始時解析 token 並持有至結束。安全提交現在透過 ChannelService 的同步 commit 操作，在成功寫入後使舊 profile 查詢失效，取消舊 listener，使用原 inbound callback 和最新 cursor 重建原本正在執行的 listener。寫入失敗或已提交 receipt 重送不重建；已停止的連線不會被自動啟用。此處只代表重新載入認證，不宣稱遠端登入成功；已開始的外部請求不能撤回。

隔離測試覆蓋成功、重送、失敗、停止與舊 profile 結果拒收，使用假 connector／writer，不操作真實連線。此段取代下方「未重建既有 listener」缺口；新連線建立、登入狀態回報、群組／直接聊天入口與真實登入驗收仍未完成，AGENT-02 維持 partial。

驗證：`credential-refresh-full-tests.log` 完整非並行測試 exit 0，`credential-refresh-native.log` 原生建置 exit 0，package verifier／deep strict codesign 通過。使用 testing／CustomDump 技能撰寫隔離生命週期測試，未啟動 App 或操作真實帳號。

## 憑證請求第五步：獨立信箱的模型／卡片／新回合接線（2026-09-24）

獨立信箱的 `SendMessage` 現在可由 host 明確開啟 `type:secret-request`；一般直接聊天、群組與背景 wake 不因此自動取得這項能力。嚴格接受 type＋secret metadata，拒絕 value、text、reply_to 或額外欄位；共用兩則發布額度、重送 receipt 與停止 fence，保存後以 ToolTurnSuspension 結束回合。請求錯誤固定回應，不把底層 diagnostics 回傳模型。模型 runtime 說明目前只支援其同帳號、同 owner、唯一且 enabled 的既有 Slack／Discord bot token 連線，不能藉此建立新連線或選 Keychain key。

App 在保存請求後建立短暫 submission 與卡片模型，顯示 masked input 和 host 目的地；完成原回合前不允許輸入操作。提供後經安全 writer 寫入，再保存 value-free response 並以新 session／user lane 續聊，關閉則保存 dismissed response。secretResponse 不享有 peer 自動回信豁免，不繼承舊圖片、priority、工具核准；模型只看到固定的已提供或關閉說明，不能據此宣稱遠端登入成功。

卡片切離畫面清掉 draft，但保留請求，避免捲動就意外取消。Stop、新人類訊息、帳號 transition、owner／sender 封存會同步關閉 submission／清掉輸入；失效或完成的 durable card 不再提供編輯入口。提交期間仍由 submission 與 channel actor 的 fence 重驗目的地。提供後若聊天保存失敗，卡片顯示「憑證已儲存，回條未保存」及重試；重試只保存 receipt，不再次輸入或寫入憑證。未保存的 receipt 不跨重啟恢復，重啟仍保守退休未完成卡片，不能宣稱 Keychain／JSON 跨系統原子交易。

新增工具 schema／額外欄位／錯誤遮蔽測試；App 假 provider＋假 writer 端到端覆蓋提供、關閉、回條保存失敗重試、帳號切換、owner／sender 封存與 Stop。假值不進模型訊息或 mailbox JSON；保存失敗重試只寫一次，權限維持不變。卡片 recovery 增加七語言明暗渲染，人工檢視繁中 light 與法文 dark，無輸入欄重現或文字截斷。SwiftUI／observable-models 技能用於卡片狀態與畫面分離；testing／CustomDump 技能用於生命周期及端到端驗證。

驗證記錄：`.build/validation/secret-wiring-focused-tests.log`、`secret-wiring-full-tests.log`、`secret-wiring-native.log`，完整測試及原生建置 exit 0，package verifier／deep strict codesign 通過。仍只使用隔離 fixtures，未讀寫真實 Keychain、未連外驗證 bot 登入，也未啟動使用者 App／Xcode。

**未完成的原版範圍仍保留**：群組／直接聊天 secret-request、reply_to、新連線建立、其他 connector／field、寫入後既有 listener 的重建與登入狀態回報，以及真實 Keychain／遠端登入驗收。現有 listener 可能仍持有舊認證，不能把已儲存視為已套用到連線。AGENT-02 維持 partial。此段取代下方歷史紀錄「完全沒有模型入口或續接」的描述，不代表 secret-request 全面完成。

## 憑證請求第四步：信箱保存與不含值的回條（2026-09-24）

請求 metadata 移到 FiliconAgents 共用，AppServices 保留 typealias；新增嚴格 Codable 解碼，仍拒絕 value／額外欄位並只回傳固定錯誤。RoomMessage 的 optional `secretRequest` 和 AgentMessage 的 host-only `secretResponse` 保持舊資料相容。卡片只保存 label／description／connector／field、host account／member／connection ID、狀態與 response ID，沒有憑證欄位或 Keychain key。

`AgentMessenger.publishSecretRequest` 使用同一兩則發布額度；已發布請求阻止後續新發布，相同 ID／內容的重送則回傳原卡片。一般 publish／send 與跨群組報告入口拒絕偽裝此卡片或人類回條。`resolveSecretRequest` 重驗完成回合、account／scope／connection／作者與成員、active profile、pending 及 lifetime，將卡片結果與新的 queued 回應一次原子保存。新回合不繼承 priority、圖片或原 chain；重複／並發提交只有一個成功。保存失敗不改記憶體狀態，也不排入回應。

啟動時 pending 憑證卡片退休，queued 回應取消，不自動執行；取消／失敗回合也退休 pending 卡片。人類新訊息只退休同 account／scope 的請求，peer 訊息不會；另提供 host 明確退休 API。這不是帳號事件的 App 接線，host 仍須同步關閉 lifetime 與 submission，然後呼叫退休。

`AgentSecretSubmission.recordMailboxReceipt` 只接受自身已 stored 的結果，並核對 publication ID、request、owner／account／scope／connection 後交給信箱原子保存；測試串起假 writer 到 durable receipt，確認假值不在 mailbox JSON。**Keychain 與 JSON 不是跨系統交易**：若寫入成功但信箱保存失敗，憑證可能已存，不能向使用者宣稱沒存；host 需保留 submission 的 stored receipt 重試保存，不得重新索取或覆寫值。重啟對未解決卡片採失效，不宣稱跨程序 exactly-once。

8 項新測試含參數案例涵蓋保存／關閉、帳號與範圍不符、封存、重啟、保存失敗、並發、人類 move-on、重送與額度、舊資料以及值隔離。使用 testing／CustomDump 技能與隔離臨時資料，沒有真實 Keychain 或帳號存取。完整回歸記錄 `.build/validation/mailbox-secret-full-tests.log`，原生建置記錄 `.build/validation/mailbox-secret-native.log`；建置 exit 0，編譯器仍輸出既有 weak capture／Security deprecated 警告。

**仍未完成實際功能入口**：App 卡片掛載、模型 schema／暫停、fresh session 採用 durable 回應、host Stop／帳號切換接線、新連線建立與遠端登入驗收還未接通。AGENT-02 維持 partial，不以保存層替代原版完整流程。

## 憑證請求第三步：遮罩卡片元件與輸入生命週期（2026-09-24）

新增 `AgentSecretRequestCard`／`AgentSecretRequestCardModel`，SecureField 使用短暫 draft；提交前即清空，無效輸入、寫入失敗、取消與畫面消失均清空。模型不保存提交值或底層錯誤，reflection 隱藏 draft；失敗只呈現固定狀態。寫入失敗須重新輸入。關閉或 Task 取消後的遲到 receipt 不觸發續接 callback，成功 callback 只帶不含值的 receipt，一張卡片不重複提交。production initializer 接既有 `AgentSecretSubmission`／ChannelService／注入的 writer；host 必須在帳號、owner、Stop 等失效事件同步 invalidate，不能只依賴畫面消失。Swift String 不保證記憶體零化。

卡片顯示請求 label／description 與 host 固定的 connector／連線名稱，明示本機儲存不代表遠端認證成功或其他工具核准。新增九個七語言字串；隔離的 NSHostingView 渲染涵蓋七語言明暗模式，人工檢視繁中 light、法文 dark 的遮罩與窄版換行。SwiftUI／observable-models 技能用於狀態與畫面分離；測試技能用於失敗重試、輸入清除、遲到完成及取消的回歸。

**這仍是未掛入實際對話的 UI 元件，不是可用的 secret-request 入口。** 模型 schema、對話持久化、host 生命週期接線、保存後新 turn 續接與新連線建立尚未完成，AGENT-02 維持 partial。UI 測試只用假憑證與假寫入 closure；未執行真實 Keychain 寫入、遠端登入、live 模型或啟動使用者 App。完整回歸記錄 `.build/validation/secret-card-full-tests.log`；原生建置記錄 `.build/validation/secret-card-native.log`，package verifier 與 deep strict codesign 通過。

## 憑證請求第二步：值隔離與同步提交閘門（2026-09-24）

新增 `AgentSecretValue` 作為短暫輸入：不提供 Codable／Hashable 或公開讀取值，description、debugDescription 與 reflection 隱藏內容；空白、控制字元與超過 16 KiB 的輸入拒絕。不宣稱 Swift String 記憶體零化，未來 UI 仍須在完成、取消及帳號切換時清空欄位。

`AgentSecretSubmission` 只保存 pending／stored(value-free receipt)／dismissed／cancelled。提交使用 `ChannelService.withCredentialSnapshot`，在同一 actor turn 重驗固定目的地後執行同步 writer，並持有同步 lifetime fence，避免連線替換或 Stop 插在驗證和寫入之間。host 在 Stop／account／owner 變更前仍必須呼叫 close，App 接線尚待完成。並發或重複提交只寫一次，後續不同輸入不覆蓋同一請求已儲存的值；失敗只回傳 writeFailed，不洩漏底層錯誤中的輸入。取消已排隊的 Task 或關閉請求不會遲到寫入。

新增 `KeychainCredentialStore.secretRequestWriter`，沿用 channel UUID 的既有 Keychain mapping 與 WhenUnlockedThisDeviceOnly 保護，使用非互動式 Security 呼叫，避免持有提交 fence 等待 Keychain dialog；鎖定／不可存取時失敗，可由人類解鎖後重試。一般 set 路徑保留原有行為。回條只包含 requestID，acknowledgement 明示「已儲存」不是遠端登入成功或額外工具核准。

**仍不是可用的 secret-request 產品入口**：沒有 SecureField／tool schema、對話保存／暫停續接、新連線建立或外部登入驗收；receipt 目前由呼叫端取得，未與 transcript 持久化整合，不能宣稱跨程序 exactly-once。測試注入記憶體 writer，沒有讀寫真實 Keychain；生產 Security 寫入器只完成編譯／封裝驗證，不能把 mock 通過說成真實 Keychain round-trip。下一步需接完整 host UI 與持久化後續接，才可向模型公開。使用 Swift testing／CustomDump 技能、固定 scope／request／connection 識別碼驗證敏感值不出現在 public descriptions、回條、channel JSON，以及失敗重試、並發、失效與排隊取消。

本批完整非並行回歸 exit 0（`.build/validation/secret-submission-full-tests.log`），原生 Debug build、deep strict codesign 與 package verifier 通過。新提交層 6 項測試含參數案例，與既有 metadata 9 項一起覆蓋安全契約。沒有 live 模型呼叫、UI 新字串、push、App／Xcode 啟動或真實帳號／群組變更。

## 憑證請求第一步：原版 metadata 與 host 目的地契約（2026-09-24）

參考 `source/host/runner/tools/send-message-schema.ts`、`sand-secret-request.ts` 與 `send-message-tool.ts`：`secret-request` 是獨立於 widget 的遮罩輸入，包含 label／description／connector／field；模型只收到已提供的 acknowledgement，憑證值直接寫到目的地，不進對話。本輪新增 `AgentSecretRequest` 的嚴格解析／可編碼 metadata，拒絕 value、token、password、agent/account/connection ID、路徑或 Keychain reference 等額外欄位。label 單行 120、description 區塊 400 的顯示上限沿用來源意圖，Swift 以完整字元切割，避免切斷 emoji；16 KiB 輸入上限及控制／雙向字元防護為本機安全限制。解析錯誤不附輸入內容。

新增 host-only `AgentSecretRequestDestination`，只從既有連線選出同帳號／代理人的唯一目的地，不接受模型提供 Keychain key。目前僅辨識 Filicon 已實作的 Slack／Discord bot token；OAuth／不明 field／未實作平台／多個匹配連線不任選。提交前可重驗 account、agent、conversation、owner、名稱、credential reference、連線啟用與 auth kind 等，避免等待輸入期間被換目標；正常 cursor／lastActivity 更新不造成失效。

**尚未向模型或使用者開放 secret-request**：目前只有契約，沒有 SecureField、Keychain 寫入、儲存回條、暫停／續接或新連線建立。既有連線的驗證不能代替原版「尚未連接時請求憑證」流程。下一步必須完成上述整條流程與密碼不入 transcript／log／model 的驗證，才可更新 tool schema。九項測試含參數案例涵蓋正規化／編碼、Unicode、額外憑證與目的地欄位、錯誤／過大輸入、唯一目的地、帳號／代理人隔離、目的地變更與不支援的 field。使用 Swift testing／CustomDump 技能、固定識別碼與日期；只用記憶體 fixture，未讀寫任何真實 Keychain／帳號。

最終完整非並行測試 exit 0（`.build/validation/secret-request-contract-full-tests.log`）；原生 Debug build、deep strict codesign 與 package verifier 通過。早期聚焦測試指出 emoji 的 ZWJ 被控制字元檢查誤擋，以及 polling metadata 的舊編譯結果；修正後完整回歸已涵蓋兩者。沒有新增 UI 字串或 live 服務呼叫，未啟動 App／Xcode、未 push；尚未接線部分仍明列為缺口。

## 信箱提問接線第二步：模型暫停、回答 UI 與新回合（2026-09-24）

獨立信箱的 host session 現在明確啟用 widget；一般群組來源的 peer session 預設仍不藉此啟用信箱卡片，群組提問維持原本的群組路徑。SendMessage 保存問題後的 ToolTurnSuspension 成為正常暫停，delivery 完成並保留問題，不再標為執行失敗。App 信箱已發布回覆區沿用七語言 GroupQuestionCard，提供選項、自訂回答、略過與已回答狀態，不重複顯示 prompt。

人類回答入口先保留作用域，使用全新 session／工具核准回合，原子解答後只採納 host 返回的新訊息，不經普通 send 偽造 provenance。只有提問者收到結構化的人類回答；提示明示問題與選項是 assistant-authored data，並非工具權限。答案不保留舊圖片、priority 或 peer 回信豁免；再轉交給原寄件者仍需新核准。帳號切換、Stop、封存、失效與重複回答維持拒絕。普通人類訊息與同帳號／scope 的 dismissOnMoveOn 問題退休一次落盤；其他帳號、scope、peer send 不退休，保存失敗不留半個更新。

新增 session 選項／自訂／略過續接、停止 fence、禁止未啟用入口、轉交核准測試；App 回答、帳號／封存與寫入權限不擴張測試；move-on 六種情境；七語言 mailbox 卡片渲染。已目視檢查繁體中文 fixture，選項內容是模型原文，控制項與安全提示已本地化。使用 Swift testing／CustomDump 與 SwiftUI 技能；無真實帳號／群組操作，未啟動 App 或 Xcode。首輪完整回歸僅舊測試的「mailbox 不支援 widget」文字斷言失敗，更新為明確 host capability 後重跑。

最終完整非並行回歸 exit 0（`.build/validation/mailbox-question-wiring-final-tests.log`）；原生 Debug build、deep strict codesign、package verifier 通過。七語言各 1,661 keys 零缺漏，未新增 UI 字串。live 模型 opt-in 未啟用，未 push。

這只補齊獨立信箱 widget 接線，不代表原版所有卡片／跨 session／外部 channel 能力完成；AGENT-02 仍 partial，整體計數不變。下方「第一步尚未接線」是前一提交歷史，已由本節取代。

## 信箱提問接線第一步：原子保存與回答續接契約（2026-09-24）

`AgentMessenger` 新增 host 專用 `publishQuestion`／`answerQuestion`，沿用 `AgentQuestion` 的有界選項、自訂回答與略過語意。問題保存進既有 delivery publications，與文字共用兩則上限，保存問題後不再接受後續發文。帳號、原對話、提問代理人與兩位參與者由 host 固定；一般 `publish` 不能夾帶 question／群組引用 metadata，普通 `send` 也不能注入 human-answer provenance。

回答要求原 delivery 已完成、問題未回答／退休、同帳號／scope、參與者仍 active。跨 actor 取得名單後重驗整筆 mailbox snapshot，並在同一 publication lifetime 內把選擇與唯一 responseMessageID、host `MailboxQuestionResponse` provenance、全新 queued 回合一次落盤。重複／並發回答不能新增第二筆，失敗不留下半個回答。續接保留原寄件者、只送原提問者，不攜帶舊圖片、工具權限或 priority；重啟會沿用既有 queued→cancelled 回復，不自行執行答案。舊訊息省略新 optional provenance 仍可解碼。

**這批尚未開放產品功能**：模型 publisher、暫停結果處理、App 回答／續接、move-on retirement 與 UI 都還沒接上。這是完整信箱 widget 的底層第一步，不是原版提問功能已完成，也不新增 complete 列。下一步須接上 host 人類回答入口、作用域／帳號切換與新回合工具核准，才可向模型公開 widget；不能只把保存的 pending question 畫成可點卡片。

使用 Swift testing／CustomDump 技能，7 項測試（另含參數案例）覆蓋選項／自訂／略過、持久化重開、同時回答、scope／帳號／封存／取消／非完成回合、共享發布額度、偽造 metadata、舊資料及保存失敗回滾，exit 0。原生 Debug build、deep strict codesign、package verifier 通過。首輪與圖片一起跑遇到 81 issues，輸出顯示受保護圖片讀取拒絕，同時 `IOConsoleLocked=Yes`；新信箱 suite 本身通過。稍後系統已解鎖，已重新啟動完整回歸，最終結果另記。沒有降低檔案保護、重啟 App／Xcode、push 或操作真實信箱。

解鎖後完整非並行回歸 exit 0（`.build/validation/mailbox-question-full-tests.log`），包含先前失敗的圖片案例；先前鎖定失敗保留於 `.build/validation/mailbox-question-store-tests.log`。live 模型 opt-in 仍未啟用。下一批不能把這次底層通過當成尚未接線的信箱 widget 已驗收。

## 本輪增量：SendMessage 原版文字格式（2026-09-24）

本機 reconstructed `source/host/runner/tools/send-message-tool.ts` 使用 `{type:"text",content:"..."}`，Filicon 先前只接受 `{text:"..."}`。此次在共用 `AgentUserMessageTool` 接上原版文字格式，schema 與描述明示新舊兩種格式，不能混合。文字正規化、8,000 字上限、兩次發布預算、call receipt／內容去重、scope／Stop、reply_to 解析和當前圖片核准都共用既有流程；同 call ID 從原版格式換成等效 shorthand 回傳相同 receipt，不重複發布。未知 type、缺 content、同時 text/content、外部 channel／收件者、不可用圖片／引用與非文字 content 都拒絕。

圖片仍只能使用本輪 host 圖片 ID；這不是原版任意 URL／路徑附件的完成，也沒有新增 mailbox／單獨聊天引用或提問。新增文字格式邊界測試，擴充群組引用的跨格式 replay，以及圖片批准／拒絕與 mailbox 保存重開的雙格式測試。43 項／4 suites 聚焦測試通過；本批不新增 UI／翻譯字串，整體 parity 計數不變。

GitHub CI 的來源規格仍要求 branch 上 settled checks，而本機現有入口只有 workflow_run 分類。webhook HMAC 密鑰不是 GitHub API 讀取憑證，不能藉此假造整批檢查完成或挪用其他 App 登入；已向使用者詢問新增獨立 token 設定或保留此外部缺口的選擇。此次未改 GitHub CI 行為或任何真實連線。

本批完整非並行 `swift test` exit 0（`.build/validation/sendmessage-reference-full-tests.log`），原生 Debug build、deep strict codesign 與 package verifier 通過；live opt-in 模型測試未啟用。使用 Swift testing／CustomDump 技能檢查 receipt、輸出與持久化結果。沒有 push、啟動／重啟使用者 App 或 Xcode、修改真實帳號／群組資料；不是外部服務驗收。

## 範圍校正：generic 不是已證實的原版模型排程路由（2026-09-24）

重新核對本機 reconstructed `source/host/runner/tools/sand-state-tool.ts:121` 的 `triggerMemberSchema`，只列 cron、Slack、GitHub、Microsoft Teams、Linear、Sentry、PagerDuty；接下來的 trigger schema 允許單條、group 或 array，沒有 generic／event／connector 類型。`frontend/src/recovered/features/automations/routines/trigger-schema.ts` 的 `RoutineListener` 亦只有這七類。因此，先前把「generic 模型 create/update 未支援」混列為原版缺口並不精確：它是 Filicon-native 功能邊界，不是目前來源證據支持的 parity 待辦。此次不新增模型 generic 權限入口，也不改手動 connector 編輯／比對功能。

新增 `nativeConnectorConditionsAreNotModelRoutineRoutes` 回歸測試，覆蓋 create/update × single/array/group，以及 generic/event/connector 三種假路由；含合法 Slack 分支的混合 OR 仍整筆拒絕，不靜默捨棄條件。核准 callback 不應被呼叫，所有代理人的排程及持久化 bytes 必須不變。既有 schema 測試同時固定七種 model member 類型。

此校正不提高完成數，仍為 43 complete／4 partial／1 NA。真正已確認的剩餘差異包括 GitHub settled checks（現為單一 workflow）、Slack 名稱／自身身分解析、Teams 可信使用者身分、mailbox／單獨聊天引用與提問、任意附件與安全憑證請求、原版記憶與跨程序協作生命週期。這些不能因測試通過或把 native 限制移出 parity 待辦就視為完成；外部平台需要的帳號與服務驗收仍另列。

驗證：`swift test --filter 'AgentRoutineChangeTests/' --no-parallel` exit 0，62 tests／1 suite（參數案例另含其內），紀錄 `.build/validation/routine-reference-boundary-tests.log`。本批只改測試與文件，不改產品程式；未重跑全套、原生封裝或 live 驗收，不沿用上一批結果宣稱本批全驗證。使用 Swift testing／CustomDump 技能比較完整 state 與持久化 bytes；未 push、重啟 App／Xcode 或操作真實資料。

## 本輪修正：表格解析使用已驗證資料（2026-09-24）

CSV／TSV 和 XLSX 預覽原先在 gate 後重新從原 URL 解析。本批 gate 保留表格快照，`AttachmentSpreadsheetSnapshotParser` 依檔名格式 dispatch，CSV／TSV 直接使用 Data parser；XLSX 先驗證 50 MB 上限，再於 mkdtemp 私有目錄建立 0600 archive 副本，交既有 ZIP preflight／展開／XML 安全解析流程，成功或失敗均 defer 清理快照。這避免原預覽路徑被替換影響資料來源，但不聲稱能隔離相同 UID 惡意程序，也沒有替換 XLSX 的系統工具實作。既有展開量、entry、路徑、列欄與文字限制保留，不執行公式、宏、外部連結。

SwiftUI load 清除舊狀態並在結果返回時檢查取消，避免顯示遲到解析；按 SwiftUI 技能改用直接 sheet selection binding，選取值於解析完成時設定。23 項附件聚焦測試通過，涵蓋 CSV／TSV 原檔替換及刪除後仍解析原快照、XLSX 替換後快照值與公式快取一致，並重跑既有 archive 安全案例。完整非並行 swift test、原生 Debug build、deep strict codesign 及 package verifier 均 exit 0；live 模型 opt-in 測試仍跳過。沒有重啟使用者 App／Xcode、push 或碰真實資料。影音與 Quick Look 未在此批修正，沒有新增 complete parity 列。

## 本輪修正：PDF 共用已驗證文件快照（2026-09-24）

PDF 原先在 gate 驗證後於 metadata loader 與 native view 各自 `PDFDocument(url:)` 重讀。本批使用 gate 已驗證 Data 初始化單一文件供預覽、頁數、文字擷取與搜尋使用；圖片快照防護保留，影音與其他格式不額外保留 Data。搜尋 coordinator 同時比較文件 identity 與字詞，換文件時即使查詢相同也更新高亮。匯出文字仍重驗預覽檔完整性，不因持有快照就放寬匯出政策。

新增實際 PDF fixture 測試：驗證後 atomic 替換路徑會被再次驗證拒絕，原快照的頁數／文字不變且無 documentURL；刪除路徑後仍可在快照搜尋。換文件、返回原文件、清空查詢及 nil／損壞資料也有覆蓋。22 項附件聚焦測試、原生 Debug build、deep strict codesign 及 package verifier 通過。使用 SwiftUI／測試技能保持 view 與搜尋行為分離、以具體狀態差異斷言。沒有重啟使用者 App／Xcode、push 或碰真實資料。影音／Quick Look 路徑式載入未在這批修正，整體 parity 計數不變。

PDF 本批完整非並行 `swift test` 亦 exit 0；live 模型 opt-in 測試仍跳過，沒有真實 App 點擊驗收。

## 本輪修正：主圖解碼使用已驗證快照（2026-09-24）

延續先前縮圖的完整性防護，主圖先前仍在 gate 驗證後使用 `NSImage(contentsOf:)` 重新讀路徑。本批讓 gate 將已驗證的圖片 Data 傳入 `AttachmentImageView`，由資料初始化 NSImage，縮放重繪不重新讀檔。只有圖片保留這份快照，其他媒體在檢查後不額外留存整份資料；取消的驗證不發佈結果，切換圖片沿用 preview identity 重建。按 SwiftUI 技能將驗證 task 行為移出 view action closure。

新增主圖回歸測試：驗證後原路徑遭 atomic 替換／刪除，快照仍解碼原始尺寸，對已替換路徑重新驗證會拒絕；nil／無效圖片不能解碼。31 項附件與群組圖片聚焦測試通過，包含七語言圖片渲染；原生 Debug build、deep strict codesign 與 package verifier 通過。沒有重啟使用者 App／Xcode、push 或操作真實資料。這是圖片載入安全修正，不是新完成的 parity 列，也未修正 PDF／AV／Quick Look 各自的 URL 載入流程。

本批完整非並行 `swift test` 亦 exit 0；live 模型 opt-in 測試仍跳過，未宣稱真實 App 點擊或外部服務驗收。

## 本輪增量：文字內圖片逐張描述（2026-09-24）

依 reconstructed `SendMessage` 的 text/images/alt 行為，Filicon 的 `images` 現可混用精確本輪圖片 ID 字串與 `{image_id,alt}`。保留本機安全 ID 模型，不採用來源任意 URL／路徑；最多四張、ID 不重複，object 不接受未定義欄位。每張描述最多 500 字／2,000 UTF-8 bytes，拒絕控制字元與非字串，空白正規化。單張附件與文字內圖片共用驗證邏輯，全部描述包含在預覽核准與 replay payload 中；相同圖片不能只改描述再次發布。既有 metadata annotation 核對、當前來源限制、拒絕及停止流程不變，沿用上一批描述顯示，沒有新增 UI 或翻譯字串。

測試涵蓋新舊項目混用、核准／拒絕、超長字數／UTF-8 bytes、控制字元、非字串、URL／路徑、重複 ID、同 call ID 改描述與不同 call ID 重複發布。信箱測試同時驗證 standalone／inline 保存重開與不重複 final。完整非並行 `swift test` exit 0，原生 `Filicon App` Debug build、deep strict codesign 與 package verifier 通過；live 模型 opt-in 測試仍跳過。沒有重啟使用者 App／Xcode、push 或真實帳號操作。其他附件種類、安全憑證請求等既有 partial 缺口未完成，整體 43 complete／4 partial／1 NA。

## 解鎖後完整回歸（2026-09-24）

使用者解鎖後確認 `IOConsoleLocked = No`，在 `fcc8354` 重跑完整非並行 `swift test --scratch-path .build/validation/markdown-prose.SDrQnO/spm --no-parallel`，exit 0。圖片 storage/delivery、App 圖片、WorkflowService／AgentWorkflow 與 SharedRoom 均通過；前次 EPERM／malformedState 未重現。工作流程與共享聊天室落盤使用 `.completeFileProtectionUnlessOpen`，前次失敗期間系統確實鎖定；此次沒有修改或降低檔案保護。前次失敗保留於下文作為驗證歷程，不再是目前圖片描述功能的未通過狀態。沒有啟動／重啟使用者 App、Xcode、真實模型或帳號，也沒有 push。原版逐張 inline image alt、其他附件種類及既有 partial 項目仍待完成，不能把回歸全綠當成功能全對等。

## 本輪增量：經核准的單張圖片描述（2026-09-24）

對照 reconstructed 附件的 `alt`，單張無文字圖片發布可附上 500 字／2,000 UTF-8 bytes 以內的純文字描述，控制字元拒絕、空白正規化。描述在核准卡完整呈現，並提供懸停提示、圖片檢視說明與 accessibility label；不將描述解讀為 Markdown、工具指令或授權。群組與信箱只允許替目前 incoming 圖片加描述，ID、檔名、MIME、長度、種類與建立時間仍須符合來源；不放寬路徑、URL、歷史圖片或收件者。重新使用 call ID 但修改描述會拒絕，同圖片另換 call ID 亦不重複發布。舊資料缺少 `altText` 仍可解碼。

21 項 storage/delivery 與 19 項 App 測試曾分別通過，涵蓋描述核准、拒絕、來源過期、重送、群組及信箱重開、來源 metadata 防竄改；七語言渲染並抽查繁中圖集，原生 Debug build、deep strict codesign 與 package verifier 通過。最初測試的 async autoclosure 編譯錯誤與日期序列化精度斷言已修正後重跑。七語言各 1,661 keys 零缺漏。完整非並行回歸仍失敗，包含 WorkflowService／AgentWorkflow 暫存 JSON 重讀 EPERM 以及 SharedRoom malformedState。最後一次圖片聚焦重跑亦出現圖片暫存檔 EPERM 與連帶斷言失敗，尚未得到最後一次全綠結果；不能宣稱全套成功或確定均由本次改動造成。沒有重啟使用者 App／Xcode、push 或操作真實帳號。多張圖片逐張描述、其他附件種類與其餘 partial 缺口仍未完成。

## 本輪增量：群組行內訊息引用樣式與缺口校正（2026-09-23）

檢查現有程式與測試後，`sand-msg:<shortAddress>` 的**同群組安全跳轉**早已存在：只有保存且唯一、位於本文之前的有效位址可開啟；缺失連結只留下標籤，不開外部 App。較早段落把「chip」統稱為缺口，容易誤解成無法跳轉。本批只將有效引用改為有底色、加重字重的行內強調；一般 HTTPS 連結、無效引用和 code／math／table 不套用。這是原生 `Text` 內的 chip-like 樣式，**不是** reconstructed 的圓角 chip 像素一致實作，也沒有新增 mailbox 引用能力。mailbox 的內部 `AgentMessage` 與使用者聊天的 `RoomMessage` 分開保存，不能直接沿用群組位址而產生無法定位的假引用。

聚焦 Rich Markdown **19 項／2 suites** 與群組七語言 × 明暗畫面 **7 項／1 suite** 通過；抽看繁中暗色、法文淺色，標籤完整且無效位址不突出。原生 Debug 建置、deep strict codesign、package verifier 通過。完整非並行回歸此次**未通過**：多個無關持久化測試在 macOS 系統暫存目錄新寫的 JSON 重讀時收到 `EPERM`；以工作區 `TMPDIR` 重跑受影響的 Agent workflow suite 仍落到系統目錄並重現。這次不能宣稱全套回歸通過或判定為本批 UI 改動造成；待系統檔案存取恢復後需重跑。未啟動／重啟使用者 App 或 Xcode、未 push。整體仍 **43 complete／4 partial／1 NA**；圓角 chip 樣式、mailbox／單獨聊天引用與提問、跨 session/fork、外部 channel、獨立附件、安全憑證請求、cloud-agent 卡及其他 partial 缺口仍未完成。

接續校正：背景群組問題卡已可用，但 `SendMessage` 的模型說明殘留「背景不支援 widget」一句；已改為明示受督導的群組 peer wake 可以送一張問題卡、該 wake 結束後由人類在**新群組回合**回答，mailbox／單獨聊天則仍不支援。App 測試核對實際送入模型的 system 提示與保存／恢復路徑。先前 `EPERM` 的同一暫存檔後來可以正常讀取，完整**非並行**回歸重新執行為 exit 0，原生 Debug 建置、deep strict codesign 與 package verifier 再次通過；最初失敗仍保留為環境事件，並非隱去。沒有啟動／重啟使用者 App 或 Xcode、沒有 push 或碰真實資料。

## 本輪增量：本輪圖片的無文字發布（2026-09-23）

對照非官方 reconstructed 的 `SendMessage(type:"attachment")`，本批只接上**目前使用者／同伴送入的單張 PNG/JPEG**：模型使用 host 提供的精確 `image_id`，不能指定路徑、URL、歷史圖片或自行選收件者。已存在的圖片儲存與預覽授權仍是必經路徑；核准前後重新載入驗證，群組另檢查來源人類訊息、成員、回合及 publication lifetime，信箱檢查當前 incoming 圖片、作者和對話。文字空白但圖片存在才視為有效發布；兩則上限、同回合去重、Stop／拒絕／過期防護不變。

群組保存後可取得 host 回條，只有圖片的列亦能作 `reply_to` 目標；討論串可顯示圖片且不誤標「文字回覆」。信箱在原 delivery 內原子保存，來源畫面顯示圖片，不出現空白文段，模型 final 不重複發布。隔離測試涵蓋無效 ID／路徑／URL、混合欄位、重播、預覽批准／拒絕、過期、群組與信箱重開、App 核准卡與停止；本批聚焦測試及完整非並行 `swift test` 均 exit 0。`Filicon App` Debug build、deep strict codesign 與 package verifier 亦通過。沒有啟動／重啟使用者 App 或 Xcode、沒有 push 或操作真實群組／帳號。這不是任意本機或網路附件、影片，也不是來源完整外部 channel 附件；`AGENT-02` 仍為 partial，整體 **43 complete／4 partial／1 NA**。

## 本輪增量：來源對話授權下的群組背景引用（2026-09-23）

接續 `1f0e4c1` 的記憶建議，對照本機非官方 reconstructed `source/host/runner/tools/send-message-tool.ts` 的一般 `reply_to`：Filicon 先前只有前景人類群組回合可由 SendMessage 引用，透過 `SendToAgent` 發到群組後喚醒的其他代理人只能送純文字。本批讓**已核准、受督導的群組 peer-message wake** 也能引用同一目標群組最近 40 筆可用訊息，包含剛收到的同伴發文；來源對話 ID 仍用於工具權限與 Stop，引用目標和保存回條則固定在群組 ID。不能以來源對話的其他群組位址猜測或引用。

- 背景 SendMessage 支援文字、可選 `reply_to`，也能送一個必要的選項問題（可同時引用）；不繼承人類當前串接的預設引用，不取得歷史圖片 ID，也不能變更作者／收件群組。跨群組 ID 與圖片均拒絕，無效引用不退回普通訊息。群組服務在落盤後才回傳 messageID／shortAddress；已保存的訊息／問題及引用可重新讀取，群組討論串投影仍定位原文。問題送出後立刻停止該背景喚醒，往後使用者於群組回答才啟動**新的**人類回合，僅續接原提問者，不重啟來源 peer session；他帳號不能回答，成員變更或封存亦沿用既有失效檢查。Session 關閉與來源 Stop／帳號撤銷同步取消尚未出版的 lifetime；成員變更透過既有 App 停止群組工作。
- App 層隔離 fixture 驗證跨對話來源、目標群組回條與重開、跨群組引用／圖片拒絕；背景問題測試涵蓋暫停、帳號隔離、重開答題及僅原作者續接；另一測試驗證關閉 session 後遲到文字／問題均無法發布。舊相容 `onPublication` 的 delegated wake 無法提供 durable receipt，仍不獲得引用權限。沒有操作真實帳號、群組或模型。

背景引用第一批已提交 `ba6b915`，該批完整回歸為 1,109 個 Swift Testing。本次加入背景選項問題後，群組 App 聚焦 **19 項／1 suite**、完整**非並行**回歸 **135 XCTest、1,110 Swift Testing／125 suites**（App **366／49 suites**）皆通過；原生 Debug 建置、deep strict codesign 與 package verifier 通過。一次在前一批並行聚焦跑法中，既有圖片／暫存檔測試發生 `EPERM` 與隨後資料重開失敗，未視為通過或歸因於這次改動；非並行重跑皆通過，仍應另查測試環境並行穩定性。未啟動／重啟使用者 App 或 Xcode、未 push。來源完整自動記憶、episode、archive、跨 session/fork、chip、mailbox／單獨聊天引用與提問、外部 channel、獨立附件、安全憑證請求及供應商 cloud-agent 卡仍缺；整體 **43 complete／4 partial／1 NA**。

## 本輪增量：逐筆審核的自動記憶建議（2026-09-23）

上一批群組引用回覆已提交 `e5cad3c`。對照本機非官方 reconstructed 的 `source/host/runner/turn-memory.ts` 與 `sand-memory.ts`：來源在回合後嘗試抽取記憶及 episode；本批只做可審核、帳號隔離的原生候選，沒有自動改寫或刪除既有記憶。

- **Agents → Edit → Memory suggestions** 以帳號＋代理人分別開啟，預設關閉。畫面事先揭露額外模型費用、送出的資料範圍和審核方式；候選卡顯示完整事實及當次使用者原文證據，逐筆「保存為私人記憶」須再確認，也可略過。停用清除尚未核准候選，已核准的事實維持原有 Forget 入口。
- 僅完成的前景群組人類請求觸發，收集該代理人的當次人類文字、最後一則有用回覆與自己的私人事實；不複製舊群組歷史、peer 內容、附件、共享／專案記憶或私人 persona。群組回答／委派工作先完成，額外請求在同代理人的背景序列執行，最多 30 秒、無工具。等待時顯示「正在整理記憶建議」。若模型輸出錯誤／逾時，既有回答仍成功，該回合不自動重試。
- 輸出僅接受最多四筆嚴格 JSON，每筆最多 1,000 字／4,000 UTF-8 bytes，證據須為當次使用者文字的連續原文；拒絕工具事件、不完整結束、額外欄位和控制字元。原文內的指令仍當資料。候選不參加召回／搜尋、不得擴成共享記憶或工具授權；同事實正規化去重、每代理人最多 12 筆待審、保留最近 32 個已處理回合回條。這些驗證不能證明模型從不提出敏感內容，保存前仍需人工檢視。
- 停止、關閉 session、帳號或群組成員切換、停用再啟用、封存及儲存失敗均防止遲到候選寫入。審核操作重新驗證帳號、代理人、候選內容與設定 revision；保存記憶與移除候選同次原子寫入。持久欄位可省略，舊資料照常載入。
- Swift 測試／CustomDump 技能以隔離檔案與 fixture provider 驗證預設關閉、範圍、7 類錯誤輸出、同步撤銷、重開、去重、容量、存檔失敗回滾、App 群組整合及七語言明暗渲染。新增檔案已登錄 Xcode 原生 App 目標；初次原生建置因此處漏列失敗，補目標檔案清單後建置成功。

驗收證據：`.build/validation/memory-suggestions/`。聚焦核心 **6／1 suite** 及 App **4／1 suite** 通過；完整預設並行 **135 XCTest、1,107 Swift Testing／125 suites** 通過（App **363／49 suites，42.129 秒**）。兩項 opt-in live Codex 跳過。七語言各 **1,660 keys／零缺漏**；14 張 `ui/memory-suggestion-*.png` 產出，繁中暗色與法文淺色目視未見裁切。原生 Debug 建置、deep strict codesign 及 package verifier 通過；不是 Release 公證／live App 點擊。未 push、未啟動／重啟使用者 App／Xcode、未改真實帳號／群組／記憶或呼叫付費模型。來源完整自動記憶、episode、archive、其他入口、跨會話與其餘 `AGENT-01/02/04`、`AUTO-03` 差異仍缺；整體 **43 complete／4 partial／1 NA**。

## 本輪增量：人類群組回覆與同回合自動串接（2026-09-22）

先提交折疊投影為 `ca5a107`（`feat: fold quoted group replies into discussion threads`）。本批對照 reconstructed 的 `send-thread-stamping.ts`／`turn-runtime.ts`：人類的 reply context 綁定該回合，未明示 reply_to 的模型訊息沿用該討論串。本機採原生群組回合，回應引用當次人類訊息、仍歸到同一 root；不模擬原版獨立 session／fork。

- 群組訊息 hover 列／文字 context menu 新增「回覆」。輸入框上方顯示原文、作者、取消與同群組／@mention／非核准說明；Esc 優先關閉 mention menu，再取消引用。選擇跟各群組的文字／圖片草稿分開保留，帳號切換清除；送出失敗或使用者已改選時不清除草稿。原文不可用時保留預覽和取消入口，不假送到主線。
- `postUserMessage` 在 await 後重新檢查成員／epoch，再驗證完整群組投影中的唯一有效 target，引用與本文同次保存。損壞／循環／前向／空白／狀態／外群／未知引用不回退普通發送，保存失敗恢復完整歷史。圖片限定既有當次 host handles，圖片本身可以是回覆內容；引用預覽僅顯示 Image 字樣，不讀舊檔案。
- 正常人類回覆回合的成員 final fallback／SendMessage 文字、核准圖片及 widget 自動引用當次人類訊息。明確的合法 reply_to 優先；一般新訊息解除串接。host 預設目標在工具執行前解析，進入同一 payload／冪等回條，不於成功後偷偷改 ID；無效預設拒絕，不捏造成功。Stop／帳號／成員撤銷及兩次額度仍有效，背景／delegated wake 不繼承人類討論串。
- 選中的舊原文超過 prompt 最近 40 筆時，另附最多 2,000 字的結構化 quotation；明示不是新指令或權限，舊圖片只提供 omittedImageCount、不載入 bytes。提問答案仍只續接 asker、不是工具核准；對已在串中的問題回答／略過會把人類答案及後續成員回應留在該串，不等於任意 quote 自動回答問題。
- SwiftUI 技能維持元件只呈現／派送，選擇驗證及自動串接在 host service／投影中；Swift 測試／CustomDump 技能新增 `GroupUserReplyTests` 五項測試（含文字／圖片單獨／explicit/fallback 參數），App 四項測試涵蓋原作者與 @成員分離、文字／圖片／提問、回條、重開、過期 target、超出 prompt 的舊原文與三種 lifecycle 撤銷。更新既有 threaded-question 整體斷言，保留原文、唯一 asker、無額外核准檢查；工具與實際檔案均使用隔離 fixture。

驗收證據：`.build/validation/group-composer-thread/`。聚焦 **39 Swift Testing／5 suites** 通過（`focused-3.log`）；完整**預設並行** **135 XCTest、1,097 Swift Testing／123 suites** 通過（App **359／48 suites，34.831 秒**）。兩項 opt-in live Codex 仍跳過，沒有提高逾時或排除 UI。七語言各 **1,646 keys／零缺漏**。14 張 `ui/group-reply-composer-*.png` 簽頭／CRC／完整檔名及尺寸驗證通過：760-pixel 寬、430／482-pixel 高；繁中淺色及法文暗色目視抽查完整，未做逐張人工或真實 App 點擊。初次舊問答測試仍期待答案無 replyTo，已改為保存串接及後續 root 的完整斷言；一次新 fixture 誤用 AppModel 私有 coordinator，改用注入的隔離 coordinator，不放寬存取。畫面初始高度下限 220 points 對中文實際 215 points 過嚴，檢查完整畫面後調為 200，未改 UI 內容／字級或逾時。

最終完整並行回歸 `full-parallel-final.log` 再次通過同樣數量（App 359／48 suites，39.768 秒），包含圖片原文與明確 null 引用拒絕。原生 Debug 建置、deep strict codesign 與封裝檢查皆通過（`native-final.log`、`codesign-final.log`、`package-final.log`）；此為 ad-hoc Debug，非發佈公證或 live XPC 驗收。不 push、不啟動／重啟 App 或 Xcode、不變更真實帳號／聊天／憑證。尚缺跨 session/fork、chip、背景引用／提問、外部 channel、獨立附件、安全憑證請求及供應商 cloud-agent 卡等，整體仍 **43 complete／4 partial／1 NA**。

## 已提交增量：一般群組的折疊討論串（2026-09-22）

本批已提交為 `ca5a107`。

先提交訊息回條增量為 `36ec1fe`。對照本機非官方 reconstructed 的 `source/shared/transcript-threads.ts` 及 `source/host/extensions/transcript/send-thread-stamping.ts`：巢狀引用歸到最初 root，回覆計數及展開不等於新增成員或工具授權。本批只還原群組顯示投影，不假稱 composer／session 自動 thread stamping 已完成。

- 新增純值 `GroupThreadProjection`，以完整群組紀錄做一次、非遞迴掃描。有效向後引用歸入原始 root、保留各自 quote 和先後順序；缺失／前向／自我／循環／跨群組／空白／host 狀態／重複 ID 不隱藏，仍留主時間線。壞鏈不能變成後續引用的有效 parent；重複資料使用 entry index 呈現，不丟列或當成可導航目標。
- 一般群組在原文下顯示回覆數，可展開／收合，巢狀回覆保留引用卡。`GroupThreadPresentationState` 僅是暫存 view state，點 quote 或 sand-msg 連結先展開 root、再請求定位原文；切換帳號清除展開狀態。沒有改寫儲存資料或讓引用變成提問答案。待回答問題或待完成工具強制展開，不能以收合隱藏；UI 提示說明原因。
- 群組工具提示同步說明 secondary discussion 的折疊行為，primary answer 可省略 reply_to；不改目標驗證、兩次額度、核准、收件者或持久格式。SwiftUI 技能讓 view 只負責呈現與操作，Swift 測試／CustomDump 技能把投影、切換及定位狀態獨立驗證。
- 新增七項投影測試，涵蓋巢狀、壞鏈、外群同 ID、不消失、pending 保持開啟、展開／定位及 stale 完成、5,000 層鏈、JSON 重開。App 以 production `GroupReplyThread` 和 bubble／question card 產出七語言 × 明暗的折疊／展開／pending 組合，不是另畫 mockup；runtime prompt 另有回歸斷言。

驗收證據：`.build/validation/group-threads.sieQ6c/`。聚焦 **19 Swift Testing／2 suites** 通過，完整**預設並行** **135 XCTest、1,088 Swift Testing／122 suites** 通過（App **355／48 suites，42.562 秒**）。未排除 UI、提高逾時或改成序列；兩项 opt-in live Codex 仍跳過。七語言各 **1,644 keys／零缺漏**。`ui/group-thread-*.png` 的 14 張預期檔名、簽頭、chunk CRC、760-pixel 寬及 2,072–2,124-pixel 高度皆通過；目視抽查繁中淺色與法文暗色，計數與 pending 說明可辨、引用和選項沒有裁切。fixture 原文／名稱不強制翻譯，沒有逐張人工、pixel-perfect 或真實 App 點擊／捲動驗收。

原生 `Filicon App` Debug 建置、deep strict codesign 與 package verifier 均通過（`native.log`、`codesign.log`、`package.log`），App／XPC entitlements 符合 Support 定義。這是 ad-hoc Debug 檢查，不是發佈公證或 live XPC 驗收。不啟動產物、不重啟 App／Xcode、不改真實帳號／群組資料，未 push。整體仍 **43 complete／4 partial／1 NA**；其餘 composer／session 自動 thread stamping、chip、背景引用／問題、外部 channel、獨立附件、安全憑證請求與供應商 cloud-agent 卡等缺口繼續保留。

## 已提交增量：保存後訊息回條與同回合引用（2026-09-22）

本批已提交為 `36ec1fe`（`feat: return durable group message publication receipts`）。

開始時上一批已提交 `235e7c5`，工作目錄乾淨。使用者要求 commit 後持續補齊剩餘差異；本批核對 reconstructed 的 `source/host/runner/tools/send-message-tool.ts`，其成功結果會把 `onSendMessage` 回傳的 ID 交還模型，不是讓模型自行編號。

- `GroupAgentResponder` 新增帶已保存列的 callback，保留舊 Void callback 相容性。`GroupService` 先通過既有 epoch／lifetime／回覆／圖片／提問與額度檢查，原子保存後才回傳真正訊息；UI callback 前固定該列，不用未保存 draft 當回條。
- 一般群組的 `AgentUserMessageTool` 新增固定作者的 host publisher。成功工具結果包含 `messageID` 與有效 `shortAddress`；新列加入本回合引用目錄，初始最多 40 筆，額外最多兩筆。串流工具下一步取得更新目錄，互動式工具可直接使用前次回條，不擴大權限或回覆成員。文字、核准圖片與 choice question 共用路徑。
- 儲存失敗不回位址、不扣發布額度；同 call ID 以短位址／等價 UUID 重送不重複發布。保存後取消仍記錄成功的 side effect，避免重播副作用；停止／帳號／成員撤銷前未落盤者不發布。錯群組／作者／內容／引用／狀態／重複 ID 的 host 回條不加入目錄，既有無回條 callback 不捏造 ID。短位址與完整原歷史查重，壞位址只保留唯一 UUID；碰撞位址從本回合目錄移除。
- 問題卡成功後仍暫停，回條不解除暫停或等同核准；輸入圖片不自動轉成發布授權。模型仍不能指定訊息 ID／群組／作者、以未知位址猜測目標，或藉回條載入歷史附件。背景／mailbox／非 receipt 相容入口沒有因此得到新引用能力。
- 依 Swift 測試／CustomDump 技能新增七項隔離 store／固定資料的測試，以及兩項 App 整合（含參數化的圖片／文字／提問組合）；真實工具迴圈驗證同回合目錄更新與重開後的 ID／引用關係。既有圖片核准整合另驗證保存位址。首輪新測試因 Date 毫秒編解碼浮點精度差異失敗，改用儲存格式 round-trip 後做完整值比較，未移除欄位斷言；Swift 6 初始化編譯問題改成明確 closure 與區域值，沒有降低隔離檢查。

驗證證據：`.build/validation/message-receipts.aE0kYS/`。聚焦 **56 Swift Testing／7 suites** 通過；完整**預設並行**回歸 **135 XCTest、1,080 Swift Testing／121 suites**（App **354／48 suites，60.078 秒**）通過。兩項 opt-in live Codex 仍跳過，既有 SDK/CoreData 診斷未宣稱修復；七語言各 **1,637 keys／零缺漏**，本批沒有 UI 翻譯或新視覺驗收。原生 Debug build、deep strict codesign 與 package verifier 均通過，App／XPC entitlements 符合 Support 定義；這是 ad-hoc Debug 驗證，非新的發佈公證。未使用真實帳號、未改使用者群組資料、未啟動／重啟 App／Xcode、未 push。

剩餘原版 chip／折疊討論串、背景引用／提問、外部 channel、獨立附件、安全憑證請求與供應商 cloud-agent 卡等仍未完成；本批不改整體 **43 complete／4 partial／1 NA**。

## 已提交修正：Markdown 段落與清單呈現（2026-09-22）

開始時上一批已提交 `3aa150b`，工作目錄乾淨。本輪處理上一輪畫面抽查已記錄的 prose 段落黏連，不新增訊息路由或宣稱原版剩餘功能已完成。

- 本機 Foundation 解析實測顯示：`.full` 模式把 `First\n\nSecond` 的字元輸出為 `FirstSecond`，段落仍保留在不同的 `PresentationIntent`；原畫面直接用 `Text(attributed)`，沒有把這些 block 邊界轉成分隔。新增純顯示投影 `RichMarkdownProseLayout`，先解析完整 prose，再依 block intent 組成文字，不先切開來源 Markdown，避免破壞跨段落的 reference-style link 定義。
- 不同段落／標題／引用區塊間補空行，同一清單的相鄰項目用換行；恢復項目符號、原起始序號、巢狀縮排與同項目後續段落。標題使用原生字級，引用區塊顯示層級標記。一般 soft wrap 仍依 Markdown 合併為空格；兩個尾端空白或反斜線的 hard break 保留，LF／CRLF 同樣處理。
- 原文 run 的粗體、斜體、inline code、Unicode／emoji 與連結屬性保留。補上的分隔、編號與標記不繼承鄰近連結；既有 `sand-msg:` 有效性過濾與 openURL 攔截仍在排版之後執行。code／math／table／Mermaid 仍走原本獨立 renderer；無新網路載入、工具權限、聊天保存或成員狀態變更。
- 依 SwiftUI／Swift 測試與 CustomDump 技能把顯示投影獨立驗證；新增七項測試，含完整文字與屬性斷言、巢狀清單與延續段落、引用定義／無效連結／emoji，以及七語言明暗畫面。沿用逐 fixture 主執行緒排隊，沒有提高既有逾時、停用並行或排除 UI 測試。

驗收紀錄保存在 Git 忽略的 `.build/validation/markdown-prose.SDrQnO/`：

- 重新建置後，聚焦 **35 Swift Testing／4 suites** 通過（`focused.log`）。完整**預設並行**回歸 **135 XCTest、1,071 Swift Testing／120 suites** 通過（`full-parallel.log`），App **352／48 suites，59.750 秒**。SwiftPM 只限制建置 `--jobs 4`，沒有加 `--no-parallel`、排除 UI 或提高案例時間上限。兩項 opt-in live Codex 仍跳過；既有 SDK/CoreData 與 weak-self 診斷未列為修復。
- 七語言各 **1,637 keys／零缺漏**（`localization.log`），沒有新翻譯鍵。重新產出 **28 張本輪關注 PNG**（`ui/markdown-prose-*.png`、`ui/inline-reference-*.png`，各七語言 × 明暗）；完整檔名集合、PNG 簽頭／CRC／尺寸皆通過，寬 380 points，排版圖高 353 points、群組引用圖高 252 points。目視抽查繁中淺色排版及法文暗色群組引用：段落分開、清單序號與層級可辨識、hard break 保留、有效引用仍是連結，code 字面值未啟用。資料文字不強制翻譯；未做逐張人工、pixel-perfect baseline 或真實 App 點擊驗收。
- 原生 `Filicon App` Debug 建置（`native.log`）、deep strict codesign（`codesign.log`）與 `verify-package.sh --xcode-debug`（`package.log`）通過，App／XPC entitlements 與 `Support/*.entitlements` 相符。產物位於同目錄的 `native/Build/Products/Debug/Filicon.app`，未啟動；這是 ad-hoc Debug 驗證，不是 Developer ID 發佈簽章、公證或 live XPC 驗收。
- 最初 `/tmp` 聚焦已回報 35 項通過並抽查輸出，但之後該處紀錄／建置目錄消失，當時的完整回歸結果無法確認，不能列為通過。以上數字來自重新建置／重跑，不沿用缺失紀錄；未推測暫存移除原因，也未操作使用者 App／Xcode。

邊界：這是原生 prose 顯示修正，不是完整 CommonMark／GFM 或原版網頁 renderer 的 pixel-perfect 實作；清單與引用採原生文字標記，長行懸掛縮排／原版 chip／折疊討論串仍未還原。整體核對仍 **43 complete／4 partial／1 NA**；`complete` 只代表矩陣該列所述範圍，不等於原版全部細節已完成。未新增依賴或改動權限，未 push、未啟動／重啟 App／Xcode。

## 已提交增量：一般群組的行內訊息引用（2026-09-22）

本批已提交為 `3aa150b`（`feat: navigate inline message references in group chats`）。

開始時上一批已提交 `c842f02`，工作目錄乾淨。對照本機非官方 reconstructed 的 `source/shared/message-reference.ts` 與 `source/host/runner/tools/send-message-tool.ts`：文字中的 `[label](sand-msg:<address>)` 是訊息跳轉，不是 `reply_to` 子討論串。本輪接入一般群組的原生文字連結；沒有把自訂 URL scheme 加入全域外部開啟白名單。

- 群組以完整已載入紀錄建立一次唯讀索引，使用既有持久短位址，點擊後交給原有 ScrollViewReader 以原訊息 UUID 捲動。文字由既有發布／儲存流程保存，不改資料格式、成員選擇、問題狀態或核准流程；重開後仍能定位同一訊息。工具提示沿用本回合有界引用目錄，不把原文摘要提升為指令。
- 僅接受 canonical `sand-msg:t0u`／`sand-msg:t0s0`／`sand-msg:tbs0` 格式，且目標必須在同群組、早於連結所在訊息、非空、非 host 狀態，ID 與短位址都唯一。拒絕自身／未來訊息、僅在其他群組存在的目標、損壞角色、私人 a／附件 ua、UUID、URL host、百分比編碼、查詢、fragment、前導零及大小寫變體。另一群組的同名位址不遮蔽本群組；缺少的位址不會因後來新訊息出現而指向未來內容。
- RichMarkdownView 只有在群組明確注入 navigation capability 時才處理內部連結。無效引用保留作者寫的標籤、移除可點屬性；攔截時再次解析，任何內部 scheme 都不送往 NSWorkspace／外部 opener。一般 HTTP(S) 保持原有連結政策；內部連結不抓取預覽、不載入附件、不路由訊息、不核准工具。code／math／table 與選項問題不啟用連結，背景工具上下文不宣告此能力。
- 依 SwiftUI 技能把畫面限定為顯示與導航，索引獨立成可測試值型別；依 Swift 測試／CustomDump 技能使用隔離儲存、fixture provider、完整結果比較與注入 opener，測試不操作真實帳號、聊天或外部服務。

驗收：

- 聚焦 **24 Swift Testing／4 suites** 通過，紀錄 `/tmp/filicon-inline-reference-focused-2.log`。新增七項測試涵蓋位址解析、JSON 往返、缺失／歧義／角色／時間順序、外部 opener 隔離、原生 Markdown 屬性、群組發布與重開、不增加回覆成員及不隱含工具核准。首輪畫面 fixture 漏注入 AppModel 而中止（`/tmp/filicon-inline-reference-focused.log`）；補上隔離環境後重跑，未刪除案例或提高逾時。
- 完整**預設並行**回歸 **135 XCTest、1,064 Swift Testing／120 suites** 通過，App **345／48 suites，91.539 秒**（`/tmp/filicon-inline-reference-full-parallel.log`）。兩項 opt-in live Codex 仍跳過；既有 SDK／CoreData 相關診斷未列為本輪修復。不宣稱單次全綠保證未來所有並行負載。
- 七語言各 **1,637 keys／零缺漏**，未新增 UI 翻譯鍵。產出 **14 張行內引用 PNG**，位於 `/tmp/filicon-inline-reference-ui/inline-reference-*.png`；檢查完整檔名集合、PNG 簽頭／CRC／尺寸，全部 380-point 寬且高度在界限內。目視抽查繁中淺色及法文暗色：有效引用呈藍色、缺失標籤維持普通文字、code 保留字面值。沿用原生文字連結而非原版 chip；既有 prose renderer 的段落間距／段落黏連仍待改善，不宣稱 pixel-perfect。未做真實 App 點擊捲動或逐張人工驗收。
- 原生 `Filicon App` Debug 建置（`/tmp/filicon-inline-reference-native.log`）、deep strict codesign 與 `verify-package.sh --xcode-debug`（`/tmp/filicon-inline-reference-package.log`）通過；App／XPC entitlements 與 `Support/*.entitlements` 一致。產物 `/tmp/filicon-question-native.l2MIZt/Build/Products/Debug/Filicon.app` 未啟動；這是 ad-hoc Debug 驗證，不是 Developer ID、公證或 live XPC 驗收。

剩餘：新發布訊息的成功回條／同回合目錄擴充、原版折疊討論串與 chip 樣式、mailbox／單獨聊天／背景引用與提問、外部 channel、獨立附件、安全遮罩憑證請求及供應商 cloud-agent 卡仍缺。整體仍 **43 complete／4 partial／1 NA**，`AGENT-02` 維持 partial。未新增依賴、改 Xcode 配置／權限或啟動／重啟使用者 App／Xcode，未 push。

## 已提交增量：一般群組的持久短位址引用（2026-09-22）

本批已提交為 `c842f02`（`feat: support durable short addresses for group replies`）。

先提交上一批為 `e6030b4`（`test: stabilize concurrent execution and render fixtures`）。對照本機非官方 reconstructed 的 `source/host/extensions/transcript/transcript-entry-ids.ts` 與 `source/host/runner/tools/send-message-schema.ts`：原版使用零起算的 `t0u`、`t0s0`／`t0s1`，未有使用者訊息前為 `tbs0`。本輪接入一般群組引用，不宣稱所有 reference 訊息識別／UI 已還原。

- `RoomMessage.shortAddress` 是選用的 host 欄位；GroupService 以完整儲存紀錄按群組分配，與原 UUID 一起原子保存。舊紀錄可載入且在記憶體補位址，單純載入不寫回，下一次正常保存才持久化。既有位址不重新分配；模型的 40 筆上下文不是計數來源。原生可見 final fallback／提問／委派報告使用 s 編號，不提供原版私人推理 a／附件 ua 的位址。
- 一般群組文字／圖片與 widget 的 `reply_to` 可用本回合目錄列出的短位址或既有 UUID。先正規化成 UUID，再做回執、防重播與 publication；同一次呼叫以短位址／UUID 重送不重複發布，改目標仍拒絕。與圖片授權、問題暫停、僅續接提問者、Stop／帳號／成員失效等既有能力分離。
- 目錄仍只開放最新 40 筆同群組紀錄中的有效原文；先檢查整份傳入同群組歷史的 ID／位址重複，再取 bound。非本群組的相同短位址不遮蔽本群組對應，不存在的外群位址也不引入資料。損壞、重複、錯誤角色、非 canonical 位址不猜測修復；其唯一 UUID 仍可用。null、網址、`sand-msg:`、私有 a／附件 ua、大小寫／前導零變體及不在目錄內的位址拒絕，不退回普通訊息。host 狀態、空文字與新發布訊息不增加本回合可引用目標。
- 群組服務的對外回傳、發布 callback 與持久紀錄對齊；更新委派／工具訊息保留原位址，外部 host envelope 不能自行指定新位址。保存失敗不耗用位址或假報發布；分配上限安全回退為 UUID，不溢位。用原地更新的每群組計數器與集合掃描歷史，避免每則訊息複製逐漸增長的集合。
- 依 Swift 測試、依賴控制與 CustomDump 技能使用隔離 store、固定測試時間、fixture provider、完整資料比較；新增 `GroupMessageAddressTests`，涵蓋舊資料／重開／保存失敗、boot／多人／跨群組編號、截斷歷史、稀疏／損壞／重複位址、文字與 widget 共用正規化回執。App 測試擴充原文短位址、UUID 兩路，含 incoming 圖片下的引用提問及重開後回答者／權限不變。

驗收：聚焦 **23 Swift Testing／4 suites** 通過（`/tmp/filicon-short-address-focused-2.log`）。初次開發編譯發現 publication closure 捕捉可變訊息違反 Swift 6 隔離，改為 immutable draft 加保存後讀取；第一輪新增 store 測試發現毫秒儲存格式前後日期精度不同，改以相同儲存格式 round-trip 後比較完整值，未刪除欄位斷言。首次完整預設並行（`/tmp/filicon-short-address-full-parallel.log`）中 App **341／48 suites，126.602 秒**，七項既有畫面案例超過 60 秒，不能列為全部通過；其餘 target 與新增功能測試通過，沒有改成序列或排除畫面。

將位址分配改為原地集合更新後，最終完整**預設並行**回歸 **135 XCTest、1,057 Swift Testing／119 suites** 通過（`/tmp/filicon-short-address-final-parallel.log`），App **341／48 suites，101.761 秒**。沒有放寬時間上限、排除畫面或改成序列；最終測試與原生建置分開執行。兩項 opt-in live Codex 仍跳過，既有 CoreData NSXPC 診斷仍在；這次通過不抹除前次七項逾時，也不宣稱已根治所有並行穩定性問題。

原生 `Filicon App` Debug 建置（`/tmp/filicon-short-address-native.log`）、deep strict codesign 與 `verify-package.sh --xcode-debug` 已通過；entitlements 符合 `Support/*.entitlements`。七語言各 **1,637 keys／零缺漏**，沒有 UI／翻譯改動；未宣稱新的人工視覺驗收。本輪未新增依賴、修改 Xcode 配置或權限，未操作真實帳號、群組、憑證，未啟動／重啟使用者 App／Xcode、未 push。

剩餘：短位址目前只讀本回合 bounded directory，尚未於工具成功回條返回新訊息位址／動態加入本回合目錄；`sand-msg:` 行內跳轉、原版折疊討論串、mailbox／單獨聊天／背景引用與提問、外部 channel、獨立附件、安全遮罩憑證請求及供應商 cloud-agent 卡仍缺。整體 **43 complete／4 partial／1 NA**，`AGENT-02` 仍 partial。

## 已提交增量：並行驗收的事件同步與渲染案例邊界（2026-09-22）

先提交上一批為 `5dd0bb2`（`feat: support quoted choice questions in group conversations`）。本輪接續上一輪完整並行回歸的等待失敗，只調整測試 fixture／案例邊界與驗收文件，不改正式排程、權限、訊息路由或 UI。

- `AgentExecutionSchedulerTests` 原本以三秒輪詢等工作進入 gate 或 transport 取消；上一輪核心套件在並行負載下出現啟動等待失敗。改為 gate 真正登記 continuation 後才通知、log 收到精確事件才喚醒。觀察者分別持有可取消的 AsyncStream，取消一個不會結束其他觀察者；收到通知不會開啟 gate 或提前釋放 lane。保留原有 FIFO／priority／帳號取消／工具清理／轉向／token 預算完整斷言。每項測試仍有一分鐘上限，入列 snapshot 的三秒故障上限與正式 turn timeout 未放寬；剩餘輪詢失敗現在指向實際呼叫行，而不是 helper。
- 新增三項 fixture 回歸，檢查多個觀察者、已發生事件、取消後再次觀察、非目標 log 不喚醒，以及持有工作直到明確開 gate；使用受控開始事件而非 sleep。多觀察者測試另明確等待三者都已登記才觸發工作，避免工作先啟動、測試只覆蓋已發生事件。依 Swift 測試／依賴控制／CustomDump 技能保留隔離 fixture 與完整 log 差異；不新增套件或向正式排程加入測試 hook。
- 通知核准的七語言迴圈改為 serialized 語言案例，每案例保留開／關與明／暗四張圖；routine 預覽改為語言 × 23 情境的 serialized 案例，每案例一張圖。原有主執行緒逐圖排隊、autoreleasepool、翻譯／高度斷言與輸出檔名均保留，不把整個測試套件改成序列，也不刪情境或增加每案例的 60 秒上限。

驗收：

- 聚焦 **21 Swift Testing／2 suites** 通過（`/tmp/filicon-wait-boundaries-focused-2.log`）：排程 19 項，以及通知／routine 兩項參數化測試。開發期新增測試 helper 曾漏一個結尾括號，修正後完成此輪編譯與執行。
- `/tmp/filicon-wait-boundaries-ui/` 精確產出 **189 張 PNG**（通知 28、routine 161），依完整預期檔名集合檢查無缺漏／多餘，逐檔驗證簽頭、chunk CRC 與正尺寸。目視抽查繁中暗色通知卡及法文新增排程卡，文字完整。未宣稱逐張人工或新的 UI 設計驗收。七語言稽核仍為各 **1,637 keys／零缺漏**，本輪未改翻譯。
- 調整過程中前兩輪完整預設並行回歸均通過 **135 XCTest、1,052 Swift Testing／118 suites**（`/tmp/filicon-wait-boundaries-full-parallel-1.log`、`/tmp/filicon-wait-boundaries-full-parallel-2.log`），App 均為 **341／48 suites**，分別 **68.611／99.396 秒**。多觀察者的準備通知強化後，最終版本再次完整通過相同數量（`/tmp/filicon-wait-boundaries-full-parallel-final.log`），App **58.657 秒**。三次均使用預設並行模式，未排除渲染或降低斷言；不再只有序列診斷通過。
- 兩項 opt-in live Codex 測試仍跳過，既有 CoreData NSXPC 診斷仍在；不把套件通過當成真實帳號、原生 XPC、發佈簽章或所有未來並行負載的保證。剩餘三秒入列輪詢仍是已知的等待方式，這次沒有宣稱全部 fixture 都已改成事件同步。

本批已於下一輪提交為 `e6030b4`。未更動正式 Swift 程式、套件依賴、Xcode 配置、資料格式或權限，未啟動／重啟使用者 App／Xcode、未 push；上一批原生建置證據保留，不能當成本輪重新執行。整體仍為 **43 complete／4 partial／1 NA**，原版其餘功能缺口沒有因此完成。

## 已提交增量：引用原文的選項式提問（2026-09-22）

先提交上一批為 `6058e93`（`feat: persist quoted replies in group conversations`）。對照本機非官方 reconstructed 的 `source/host/runner/tools/send-message-tool.ts`，原版 widget 也保存 `reply_to`；本輪把它接到一般群組既有的選項問題，而不是增加其他收件者或擴大工具權限。

- 一般群組可使用 `SendMessage(type:"widget", reply_to:"<host 目錄中的 UUID>", widget:...)`。僅在 host 明確提供問題發布及問題引用能力時開放；沿用最近 40 筆同群組可引用目錄。拒絕未知／跨群組／空白／host 狀態目標、null、短地址和混入文字／圖片／作者／外部 channel；沒有能力或保存失敗時不退回普通問題。
- 問題與原文 ID 同次保存，成功後仍以 suspension 結束回合。相同呼叫重播不再發布；修改或拿掉引用目標不能重用原回執。`replyToMessageID` 只表示原文，與人類回答的 `questionReplyTo` 分離；回答／略過只續接提問者，即使被引用的訊息是另一位成員所寫，或回答含 `@everyone`／`@Designer`。原文內容與狀態不變，圖片輸入的提問也不載入／轉送原文附件。
- 重啟後可回答；Stop／帳號／成員／封存防護和 `dismissOnMoveOn` 保持有效，成員移除後再加入不復活舊問題。圖片所在回合使用同樣的問題引用接線；提問本身不請求圖片發布核准，也不因問題答案提升寫入權限。背景／delegated wake 仍拒絕。
- 引用摘要在問題卡上方，原文缺失時只停用引用按鈕；問題自身的回答／失效狀態仍由 host 決定。依 SwiftUI／模型技能維持 View 只呈現與派送操作，發布驗證保留在 service；依測試技能使用隔離 AppModel／store、fixture provider、CustomDump 完整資料比較與既有 AsyncStream 事件同步。沒有新增依賴或改變資料格式。

驗收：

- 聚焦 **35 Swift Testing／6 suites** 通過，紀錄 `/tmp/filicon-question-reply-focused-4.log`。新增五項工具測試及三項 App 測試，另擴充既有保存失敗／晚到發布／背景拒絕參數案例。涵蓋文字及圖片輸入、選項／自訂／略過、重啟、唯一續接、無隱含工具核准、保存失敗及回執重播。
- 七語言各 **1,637 keys／零缺漏**；本輪未新增翻譯鍵。七語言 × 明暗 × 等待／已回答／原文缺失／失效，產出 **56 張引用問題 PNG**，位於 `/tmp/filicon-question-reply-ui/question-reply-*.png`。逐檔驗證簽頭／chunk CRC／尺寸，380-point 寬版型通過高度界限；目視抽查繁中淺色失效卡、法文暗色等待卡，未見裁切。問題、選項及原文維持 fixture 原文，不強制翻譯資料；未做逐張人工、pixel-perfect 或 live 捲動點擊驗收。
- 開發期測試曾把失效卡片也套用等待卡的最小高度，且把記憶體 Date 與毫秒 JSON 往返後的浮點值直接比較；已依失效卡實際版型及既有持久化日期 codec 校正測試，保留全部訊息欄位比較。不改正式儲存精度，也未增加測試逾時或排除案例。
- 原生 `Filicon App` Debug 建置（`/tmp/filicon-question-reply-native-final.log`）、嚴格深層簽章與 `scripts/verify-package.sh --xcode-debug` 通過；App／XPC entitlements 與 `Support/*.entitlements` 一致。未啟動產物 `/tmp/filicon-question-native.l2MIZt/Build/Products/Debug/Filicon.app`，未做 Developer ID、公證或 live XPC 驗收。

完整回歸與已知限制：

- 首次預設並行回歸 `/tmp/filicon-question-reply-full-parallel.log` 有四項既有畫面測試超過 60 秒；新增引用問題測試通過。將 `GitHubSlackRoutineEditorTests`、`TeamsRoutineEditorTests`、`ConnectorRoutineEditorTests`、`AgentWorkflowWriteAppTests` 的七語言外層迴圈改為逐語言的 serialized 參數案例，保留所有明暗／情境、版型斷言、輸出檔名及每案例一分鐘上限，沒有排除渲染或放寬正式程式。
- 第二次預設並行回歸 `/tmp/filicon-question-reply-full-parallel-2.log` 仍未通過：既有 `AgentExecutionSchedulerTests` 四項測試共六個案例在三秒條件輪詢失敗，`AgentManagementAppIntegrationTests` 的通知核准與 routine 預覽另有兩個 60 秒逾時。前述四項畫面測試及新增引用問題通過；不能宣稱並行穩定性已修復。
- 將上述排程及六項畫面測試獨立重跑，**22 Swift Testing／6 suites** 全部通過（`/tmp/filicon-question-reply-recheck.log`）。同時輸出 **371 張既有畫面 PNG** 至 `/tmp/filicon-question-reply-existing-ui/`，含四項調整過的 182 張、通知 28 張、routine 161 張；逐檔驗證簽頭、chunk CRC 及正尺寸。單獨通過與並行失敗不同，仍需後續處理等待／渲染壅塞。
- 完整序列診斷 `swift test --no-parallel` 通過 **135 XCTest、1,049 Swift Testing／118 suites**（`/tmp/filicon-question-reply-full-serial.log`），App **341／48 suites，94.090 秒**。兩項 opt-in live Codex 測試仍跳過；既有 CoreData NSXPC 診斷未修復。內部 Task／gate 併發斷言保留，但序列通過不代表預設並行回歸已全綠；本輪未進一步改動排程正式碼或提高等待上限。

邊界：仍只限一般群組的原生引用卡；原版 `reply_to` 會折疊子討論串，本輪未還原該 UI。原版短地址／`sand-msg` 連結、mailbox／單獨聊天／背景引用與提問、外部 `channel`、獨立附件、安全遮罩憑證請求及供應商 cloud-agent 卡仍缺。整體維持 **43 complete／4 partial／1 NA**，`AGENT-02` 維持 partial。本批已於下一輪提交為 `5dd0bb2`；未 push、未啟動／重啟使用者 App／Xcode、未操作真實群組／帳號／憑證。

## 已提交增量：一般群組的引用回覆（2026-09-22）

先提交上一批為 `f8bc157`（`feat: pause group turns for durable choice questions`）。本輪對照本機非官方 reconstructed 的 `source/host/runner/tools/send-message-schema.ts`、`send-message-tool.ts` 中的 `reply_to`，補上一般群組的原生引用回覆；不是原版所有訊息路由的完整還原。

- `SendMessage(text:"…", reply_to:"<host 提供的 UUID>")` 可引用同群組近期訊息。host 只提供最近 40 筆同群組歷史內非空、非狀態通知且 ID 不重複的目標；原文摘要最多 240 字元，標示為資料而非指令。新發布訊息不在同次工具目錄內動態增加。拒絕 null、短地址、URL、其他群組／不存在的 ID、作者欄位及 `channel`；失敗不退回未引用的普通訊息。
- 保存獨立的 `replyToMessageID`，舊資料可繼續解碼；不挪用問題回答的 `questionReplyTo`。回覆作者及群組由 host 綁定，引用不增加發言者、不觸發提及、不解答選項問題或授予工具權限。沿用兩則訊息上限、去重、相同呼叫的回執及持久化失敗回滾；改變引用目標不能重播同一呼叫。Stop／帳號／成員變更後晚到的發布會被拒絕。
- 可在原有文字加圖片發布上附引用，但圖片仍只來自本輪 host 綁定的 incoming ID，需重新預覽核准且核准後重驗來源；不讀取或轉送被引用訊息的附件。取消、拒絕、來源變更不能產生新回覆。
- 群組訊息顯示原作者、純文字摘要與回到原文的按鈕，使用既有 ScrollViewReader；找不到原文時顯示七語言的停用提示，不遞迴展開引用或讀取附件。依 SwiftUI／狀態模型技能將發布與驗證留在 service；依測試／CustomDump 技能使用隔離 store、完整值差異斷言與 AsyncStream 事件同步，取消測試不以 sleep 猜測時序。

最終驗收：

- 新增聚焦 **11 Swift Testing／3 suites** 通過；紀錄 `/tmp/filicon-reply-focused-final.log`。涵蓋界限／嚴格 schema、同呼叫重播、保存失敗、舊資料、重啟、圖片核准／撤銷、App 真實工具接線、不增加成員回覆，以及 Stop／帳號／成員變更和 delegated wake 的拒絕路由。
- 完整預設並行回歸 **135 XCTest、1,041 Swift Testing／117 suites** 通過；App **338／48 suites，56.988 秒**。紀錄 `/tmp/filicon-reply-full-parallel.log`；未排除渲染或增加時間上限。兩項 opt-in live Codex 測試仍跳過，既有 CoreData NSXPC 診斷仍在，不視為本輪修復或 live 模型驗收。
- 七語言各 **1,637 keys／零缺漏**；七語言 × 明暗 × 使用者原文／代理人原文／原文缺失，共 **42 張 PNG**，位於 `/tmp/filicon-reply-ui/`。逐檔驗證簽頭、chunk CRC、非零尺寸；380-point 寬渲染通過高度界限，目視抽查繁中淺色代理人引用、法文暗色缺失卡，未見裁切。原文及回覆是 fixture 資料，不強制翻譯。未做逐張人工、pixel-perfect baseline 或 live 點擊捲動驗收。
- 原生 `Filicon App` Debug build（`/tmp/filicon-reply-native.log`）、`codesign --verify --deep --strict` 與 `scripts/verify-package.sh --xcode-debug` 通過；App／XPC entitlements 與 `Support/*.entitlements` 一致。產物 `/tmp/filicon-question-native.l2MIZt/Build/Products/Debug/Filicon.app`，未啟動。未新增依賴／修改 Xcode 配置；未做 Developer ID 發佈簽章、公證或 live XPC 操作。

邊界：當時只接一般群組的文字或本輪核准圖片；mailbox／單獨聊天／背景 peer／delegated room wake、widget 引用、原版 `t3u`／`t3s1` 短地址、`sand-msg` 內文連結和外部 `channel` 路由仍未還原。獨立附件、安全遮罩憑證請求與供應商 cloud-agent 卡也仍缺。整體維持 **43 complete／4 partial／1 NA**，`AGENT-02` 維持 partial。本批已於下一輪提交為 `6058e93`；未 push、未啟動／重啟使用者 App／Xcode、未操作真實群組／帳號／憑證。

## 已提交增量：一般群組的選項式提問與續接（2026-09-22）

先提交上一輪驗收文件為 `e1e9799`（`docs: record complete parallel regression and remaining message gaps`）。本輪接續本機非官方 reconstructed 的 `send-message-schema.ts`、`send-message-tool.ts`、`sand-widgets.ts` 所定義的選項提問，不把原版所有訊息型態一併列為完成。

- 一般群組的 `SendMessage(type:"widget", widget:...)` 支援 1–6 個選項、`label`／`value`／`description`／`style`、`helpText`、選用自訂回答及 `dismissOnMoveOn`。嚴格驗證欄位、型別、總量、字串大小與重複值；拒絕混入文字、圖片、作者或其他路由。未提供的兩個旗標預設 false。具 incoming 圖片的工具仍可提問，但提問本身不發布或轉交圖片。
- host 將問題、作者、帳號、成員快照保存至群組，再以明確 suspension 結束工具回合；streamed batch 只保存／回傳已執行前綴，不執行後續呼叫。interactive provider 即使吞掉 suspension，也不能在回呼結束後繼續呼叫工具；coordinator 等待清理後釋放 agent lane。工具紀錄保存失敗仍會停下，不因模型忽略錯誤而繼續。已核准排入本輪的 peer 工作不在等待問題期間自動 drain。
- 回答或略過只續接原提問成員，選項／自訂文字中的 `@everyone` 或非成員名稱不擴大收件者。回答與原問題狀態以同次保存提交；失敗回復記憶體，重複送出不新增訊息。重啟後從保存的卡片續接；其他帳號、封存作者、已異動成員或已回覆卡片不可再回答。成員異動會持久失效舊卡片，移除後再加入也不復活。`dismissOnMoveOn:true` 才在新的一般訊息到達時自動失效。
- 卡片可選擇後明確送出、自訂回答或關閉；完整顯示選項實際值，不把點選當成工具核准。問題／回答文字是資料，不提升為 system 指令；不支援秘密欄位，也不提示輸入密碼／API key。既有寫檔、圖片、委派審批仍獨立。依 SwiftUI／狀態模型技能將送出、帳號／成員驗證與保存放在 model/service，View 僅持有選項草稿；依測試技能使用隔離 store、fixture provider 與完整值差異斷言。

最終驗收：

- 新增聚焦 **16 Swift Testing／2 suites** 通過，含 suite 外的工具迴圈測試；紀錄 `/tmp/filicon-question-final-ui.log`。涵蓋暫停、僅續接原作者、選項／自訂／略過、重啟、重複回答、帳號／成員／封存失效、保存失敗回滾，以及 provider 吞掉 suspension 後不得再呼叫工具。
- 完整預設並行回歸 **135 XCTest、1,030 Swift Testing／115 suites** 通過，App **334／47 suites，61.998 秒**；紀錄 `/tmp/filicon-question-final-parallel.log`。未排除畫面測試或增加時間上限；兩項 opt-in live Codex 測試仍跳過，既有 CoreData NSXPC 診斷仍在，不算 live 模型驗收。
- 七語言各 **1,633 keys／零缺漏**；七語言 × 明暗 × 等待／回答／略過／失效共 **56 張 PNG**，位於 `/tmp/filicon-question-ui-final/`。逐檔驗證簽頭、chunk CRC 與非零尺寸；目視抽查繁中等待／略過及法文暗色失效卡，未見裁切。fixture 的問題／選項維持原文，並非待翻譯 UI。不是逐張人工或 pixel-perfect baseline 驗收。
- 原生 `Filicon App` Debug 建置、`codesign --verify --deep --strict` 與 `scripts/verify-package.sh --xcode-debug` 通過，App／XPC entitlements 與 `Support/*.entitlements` 一致。紀錄 `/tmp/filicon-question-native-final.log`，產物 `/tmp/filicon-question-native.l2MIZt/Build/Products/Debug/Filicon.app`；未執行 App。資源簽章 Ruby **7 runs／84 assertions**、封裝權限 Python **11 tests** 通過。未做 Developer ID 發佈簽章、公證或 live XPC 操作。

原生建置另查出資源摘要腳本的目錄授權問題：原先生成的 sandbox profile 把已宣告的 `Sources/Filicon/Resources` 當作 `literal`，無法讀取子目錄中的翻譯與頭像；單加結尾斜線仍失敗。依 [Swift Build 的 shell script input 實作](https://github.com/swiftlang/swift-build/blob/main/Sources/SWBTaskConstruction/TaskProducers/BuildPhaseTaskProducers/ShellScriptTaskProducer.swift)，在 App 的 Debug／Release 及專案產生器加入 `USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES=YES`，實際生成的同一路徑改為 `subpath`；不關閉腳本沙箱，也不放寬 App／XPC 權限。上述最終建置未另帶此旗標的命令列 override。Xcode 同時將 workspace lockfile 對齊原已提交的根目錄 `Package.resolved`：CustomDump 仍 1.7.3、IssueReporting 2.1.0；未改 Package.swift 或新增依賴，完整 Swift 測試也使用這兩版。

邊界：此提問續接僅限一般群組，不含 mailbox、私人單獨聊天、背景 peer／跨群組 wake；當時獨立附件、安全遮罩憑證請求、`reply_to`／`channel` 路由及原版供應商 cloud-agent 卡仍未還原。仍 **43 complete／4 partial／1 NA**，`AGENT-02` 維持 partial。本批已於下一輪提交為 `f8bc157`；未 push、未啟動／重啟使用者 App／Xcode、未操作真實群組／帳號／憑證。

## 本輪驗收：完整並行與非並行回歸（2026-09-22）

先提交上一批為 `2433983`（`test: keep UI rendering from starving parallel integration tests`）。提交前渲染排程、MCP OAuth 與群組圖片的 **20 Swift Testing／3 suites** 通過；此次受保護檔案可正常讀取，沒有修改或關閉檔案保護。以下驗收皆針對該 commit，未排除渲染或整合測試、未增加時間上限，也未在失敗後自動重試。

| 執行模式 | 結果 | App 測試耗時 | 紀錄 |
|---|---|---|---|
| 預設並行，第 1 次 | exit 0；135 XCTest、1,014 Swift Testing／113 suites | 329 項／46 suites，59.772 秒 | `/tmp/filicon-render-unlocked-parallel-1.log` |
| 預設並行，第 2 次 | exit 0；135 XCTest、1,014 Swift Testing／113 suites | 329 項／46 suites，59.577 秒 | `/tmp/filicon-render-unlocked-parallel-2.log` |
| 明確 `--no-parallel` 對照 | exit 0；135 XCTest、1,014 Swift Testing／113 suites | 329 項／46 suites，70.655 秒 | `/tmp/filicon-render-unlocked-serial.log` |

三次均未再出現前輪的 60 秒逾時、Cocoa 257／POSIX 1 檔案拒讀或索引越界。以上採各 test target 的摘要加總（含 Swift Testing 單數 `suite` 的摘要）；兩項 opt-in live Codex 測試均跳過，**不算 live 驗收**。既有 CoreData NSXPC 診斷仍在，不能宣稱已修復所有系統診斷或未觀察到的競態。先前鎖定狀態下的失敗紀錄保留為歷史，不再列為目前尚待執行的回歸。

七語言 audit 仍為各 **1,624 keys／零缺漏**；本輪未修改程式碼、翻譯、依賴或封裝，只補驗收與測試操作文件。上一輪 **789 張 PNG** 的驗證仍是獨立的歷史證據，這三次完整回歸沒有設定 PNG 輸出，不宣稱重新產出或逐張目視比對。未重跑原生 App build、XPC smoke、Developer ID 簽章或公證。

接續核對的具體功能缺口：本機非官方 reconstructed 的 `source/host/runner/tools/send-message-schema.ts` 與 `send-message-tool.ts` 定義 `text`、`attachment`、`widget`、`cursor-agent`、`secret-request` 五種訊息；Filicon 的 `Sources/FiliconAppServices/AgentUserMessageTool.swift` 目前只接受文字與本輪 host 提供的圖片 ID。**選項式提問及其回覆／取消續接、獨立附件、安全遮罩憑證請求仍未接在這個代理人工具上**；原版 `reply_to`／`channel` 路由亦不能因 App 另有一般回覆／頻道功能就視為已對等。原版 cloud-agent 卡屬不同供應商 runtime，不以假卡片冒充。上述為缺口確認，本輪沒有實作、登入服務或要求任何憑證；後續可先獨立處理不涉及外部帳號的選項式提問。

整體仍 **43 complete／4 partial／1 NA**。此批驗收文件已於下一輪提交為 `e1e9799`；未 push、未啟動／重啟使用者 App／Xcode、未操作真實群組／排程／帳號／憑證。

## 已提交增量：並行 App 測試的渲染排程（2026-09-22）

先提交上一批為 `448e187`（`fix: preserve subagent steering across completion`），提交前含取消／群組交接的 **35 Swift Testing／3 suites** 通過，diff check 通過。本輪只修改測試與文件，不改 App 行為、權限或功能 parity 狀態。

- App-only 預設並行基準再次出現大量 60 秒逾時及 `GroupImageAppTests` 陣列越界（`/tmp/filicon-app-parallel-baseline.log`）。取樣顯示主執行緒長時間同步執行多語言渲染；單一排程核准測試就連續繪製 **7 語言 × 23 情境 = 161 張**。約執行 40 秒時，取樣記錄的峰值記憶體為 **2.0 GB**（`/tmp/filicon-app-parallel-baseline.sample.txt`）。診斷性排除渲染後，其餘 **293 項／45 suites** 在 **10.535 秒**通過；這只是對照實驗，最終驗收不排除畫面測試。
- 新增測試專用 `withUIRenderTurn`：先檢查取消、每次只放行一個渲染 fixture、在主佇列下一輪恢復、再次檢查取消，再於 autorelease pool 內建立 host／bitmap／PNG。正常、拋錯或取消都歸還位置；不讓所有畫面測試一起恢復成主執行緒工作突發。測試本體及非渲染整合工作仍並行，不對整套測試加 serialized。
- 保留七語言、明暗模式、情境、尺寸／內容斷言及輸出檔名。三個最大的 84／98／161 張渲染批次改為每語言一個參數化案例，只有同一測試的語言案例依原先順序執行，各案例沿用既有 60 秒上限；不同測試仍並行。沒有增加整合測試期限或刪掉情境。
- 新增 **5 項**排程回歸，涵蓋並行／連續 fixture 之間主佇列能前進、取消不再繪圖、七語言 TaskLocal 在成功／拋錯後恢復，以及失敗後仍能繼續渲染。未新增依賴；依 Swift 測試／CustomDump 技能採受控事件與完整差異斷言。
- MCP OAuth fixture 的固定兩秒輪詢曾在第一輪修正後單獨失敗（`/tmp/filicon-app-render-cooperative-1.log`）。改用有界單筆 AsyncStream 接收真正的 opener 事件，並在退出時取消 authentication task；整項測試明定一分鐘故障上限，仍驗證錯誤 state 與 logout 後回呼不能提交。未變動正式 OAuth 逾時、驗證或登入流程。
- 圖片歷史測試在非致命 count 斷言後加上 `#require` 再索引，保留原有精確 count／附件斷言，避免逾時後被第二個 index trap 掩蓋。

中間驗證：初版合作式渲染通過 App **328 項／46 suites** 及全專案 **135 XCTest、1,013 Swift Testing／113 suites**；但開啟大量 PNG 輸出的壓力測試仍逾時。加入單一渲染放行後，登入／核准／協作工作約 15 秒內完成，只剩上述三個大批次超時，據此再拆每語言案例。這些失敗紀錄保留在 `/tmp/filicon-render-artifacts.log`、`/tmp/filicon-render-admission-artifacts.log`，不以先前通過結果當成最終修正的驗收。

該批提交前的驗證與限制（歷史紀錄）：

- 最終程式版本的 App 預設並行驗證（含大量 PNG 寫出）**329 Swift Testing／46 suites 全數通過，58.733 秒**，紀錄 `/tmp/filicon-render-final-artifacts.log`。產物為 `/tmp/filicon-render-final.KgVbOj/` 的 **789 張 PNG**：七語言各 112 張，另有 5 張 compact／narrow／dark／empty／direct layout。逐檔驗證 PNG 簽頭、每個 chunk CRC 與非零尺寸；目視抽查繁中唯讀 Teams sheet、法文暗色無效 connector 表單，未見內容被裁切。不是宣稱逐張人工比對或 pixel-perfect baseline 驗收。
- 該批提交前最後一次完整預設並行回歸**未通過**（`/tmp/filicon-render-final-parallel-1.log`）：多個儲存／附件／代理人測試收到 **Cocoa 257／POSIX 1 Operation not permitted**，並觸發其他既有未防護測試的索引越界。隨後只讀檢查確認 `CGSSessionScreenIsLocked=Yes`。沒有將鎖定造成的受保護檔案錯誤當成本輪渲染問題，也沒有弱化檔案保護；fail-fast 停止後，第二次完整並行及最新非並行回歸當時尚未執行，留待解鎖後再驗證（後續結果見本文件首節）。中間版完整通過結果不可冒充最終版本已完整通過。
- 不涉及受保護檔案的 **5 項 UI render scheduling 回歸，預設並行連續 20 輪全數通過**（`/tmp/filicon-render-scheduler-stress-1.log` 至 `-20.log`）。任一輪失敗即停止，不以重試隱藏失敗；此聚焦結果不代替待解鎖的完整驗證。
- 七語言各 **1,624 keys／零缺漏**、`git diff --check` 通過。兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷與編譯的 CKShareMetadata context 警告未列為本輪修復。未修改正式 UI／翻譯／封裝，未重跑 native App build／簽章／公證。

本批已於下一輪提交為 `2433983`；其後完整回歸結果見上節。未 push、未啟動／重啟使用者 App／Xcode、未操作真實群組／排程／帳號／憑證。整體仍 **43 complete／4 partial／1 NA**，非 live 服務或 release 公證驗收。

## 已提交增量：轉向與完成交界、協作測試的受控時序（2026-09-22）

先提交上一批為 `3be702e`（`fix: verify macOS system aliases in debug packages`），提交前 Ruby **7 tests／80 assertions**、Python **11 項政策測試**、shell 語法與 diff check 通過。本輪處理先前完整並行回歸發現的協作時序問題，不提高功能 parity 狀態。

- `SubagentService` 原先只有 `.interrupted` 才處理 pending steer；若中斷到達時 transport 已正常完成，已接受的轉向會被丟棄並回報舊結果。以受控 gate 先讓 runtime 啟動、接受轉向、再返回 `.completed`，舊碼穩定出現四項斷言失敗（`/tmp/filicon-steering-red.log`）。現在先累計 usage、檢查原有 token 預算，再處理待續指令；正常完成不再忽略它。取消仍優先，不新增權限或解除費用限制。
- 新增完成交界／預算不足的參數化回歸及「取消優先於轉向」回歸，檢查實際 prompt 次數、結果、累計 usage、唯一 wake／取消無 wake。不是宣稱所有 runtime 的啟動、中斷或後端停止時序都已重新驗證。
- 將原本等 10 ms 的群組 Stop／子代理 steer 測試改成 runtime 準備好 continuation 後才送出的啟動事件。跨對話並行測試不再假設 80 ms 內能重疊：明確 hold transport，確認另一對話已開始、同對話第二回合已排隊，再釋放；仍精確檢查同對話最高 1、全域最高 2。fixture 等待支援取消，不以擴大延遲作為同步。
- 第二次完整預設並行回歸另重現取消測試的 1 秒啟動輪詢失敗（`/tmp/filicon-steering-full-parallel-final.log`）。該測試改為等待啟動／取消事件及 send task 完成，transport 不再五秒後自行完成；排隊可見性仍有 10 秒故障上限，測試有 1 分鐘上限。保留精確啟動次數、取消次數、完成次數及排隊清空檢查。
- 第一次完整回歸的群組交接驗收多記一次 `.writeFile`（`/tmp/filicon-steering-full-parallel.log`）。`resolveLocalToolApproval` 與 UI snapshot 更新為非同步，broker 會原子移除 request，輪詢可能重複看到同一 ID。測試現在每個 ID 只決定一次；**仍要求完整「寫、讀、寫、讀」及工程／設計／工程／設計四回合**，新 ID 的多餘請求仍會失敗。不修改正式核准政策、UI 或 broker。

依 Swift 測試／CustomDump 技能採用隔離 store、受控 continuation／事件與完整值差異斷言。未新增套件依賴、未將測試全面標記 serialized、未提高 App 整合套件的逾時限制。

驗證與剩餘限制：

- 修正後協作聚焦 **32 Swift Testing／2 suites** 通過，預設並行連續 **20 輪**通過（`/tmp/filicon-steering-focused-final.log`、`/tmp/filicon-steering-stress-1.log` 至 `-20.log`）。此輪次在後續取消 fixture 與群組核准輪詢調整前執行，不當作這兩項修改的重複驗收。
- 最新完整預設並行回歸中，核心 **480 Swift Testing／43 suites** 與 agents **36／3 suites** 通過；App 整合測試仍大量 60 秒逾時，隨後既有測試索引越界中止（`/tmp/filicon-steering-full-parallel-verified.log`）。沒有找到此輪 Cocoa 257／受保護檔案錯誤證據，不歸因於鎖屏。整套並行穩定性仍未解，不能以聚焦測試或非並行通過代替。
- 完整 `swift test --no-parallel` **135 XCTest、1,009 Swift Testing／112 suites 全數通過**（`/tmp/filicon-steering-full-serial.log`）；兩項 opt-in live Codex 測試未啟用，既有 CoreData NSXPC 診斷仍在。
- 最後補上啟動等待失敗時的 fixture 取消清理後，包含前述取消與群組交接的 **35 Swift Testing／3 suites** 聚焦通過，並以預設並行連續 **20 輪**全過（`/tmp/filicon-steering-final-focused.log`、`/tmp/filicon-steering-final-stress-1.log` 至 `-20.log`）。未用 retry 隱藏單次失敗，任一輪失敗即停止。
- 七語言各 **1,624 keys／零缺漏**、`git diff --check` 通過。此輪未修改 UI、翻譯、Package.swift 或封裝設定；未重跑原生 App 封裝／簽章或操作 live runtime，不以先前封裝成果冒充本輪完整產品驗收。

本批已於下一輪提交為 `448e187`；未 push、未啟動／重啟使用者 App／Xcode、未操作真實群組／排程／帳號／憑證。整體仍 **43 complete／4 partial／1 NA**。

## 已提交增量：Debug 封裝驗證的系統路徑別名（2026-09-22）

先提交上一批為 `7cfd698`（`fix: track resource-only Xcode signing inputs`），提交前 Ruby **7 tests／80 assertions**、七語言 audit 與 diff check 通過。本輪接續修正上一輪完整封裝檢查的 `/var`／`/private/var` 路徑誤判，不提高功能 parity 狀態。

- 將既有 signed entitlement 的額外政策檢查抽成 `scripts/verify-package-entitlements.py`，供 shell verifier 與獨立 fixtures 共用；metadata、app／XPC 必要 entitlements、helper 組裝及最後 deep strict codesign 仍由原 wrapper 驗證。
- Debug 仍要求唯一一個 read-only 例外，且指向本次被驗證的完整 `Filicon.app/` 目錄。只增加 macOS `/var`→`/private/var`、`/tmp`→`/private/tmp` 的等價字串候選，先用 lstat／readlink 確認系統別名是 root-owned symlink 且目標完全符合白名單。參考 [Python readlink 文件](https://docs.python.org/3/library/os.html#os.readlink)；不對簽入的 exception 路徑呼叫 realpath，避免把可重新導向的任意 symlink 當成授權依據。
- 拒絕父／子／同前綴目錄、`..`、多餘斜線、錯誤型別、多個路徑、read-write／其他 exception、App 自身 exception；Release 仍拒絕全部 development exception 與 debugger rights。未修改任何 entitlements、簽署身分、App runtime 或使用者權限。
- 10 項政策測試先以舊字串比對重現兩個系統別名失敗，修正後全過（`/tmp/filicon-package-alias-red.log`、`/tmp/filicon-package-alias-tests.log`）。涵蓋真實 `/var`／`/tmp` fixture、Unicode／空白、任意 symlink（含父層 alias）、錯誤系統 alias／owner／型別、CLI XML／binary plist 及不合法輸入。
- 同一個未修改、未重簽的隔離 Debug App，修正前完整 verifier 拒絕、修正後包含 helpers／XPC 與 deep strict 全部通過（`/tmp/filicon-package-alias-native-before.log`、`/tmp/filicon-package-alias-native-after.log`）。未帶 `--xcode-debug` 時仍正確拒絕該 Debug App（`/tmp/filicon-package-alias-shipping-rejection.log`）。
- 資源 smoke 每次建置現在都使用副本內的完整 package verifier，版本／build 從該副本 Support/Info.plist 讀取，不硬編碼；驗證失敗保留個別 package log 並中止。仍不啟動 App。

最終驗證：

- 補上同前綴非目錄邊界與絕對 system-link target 後，Python **11 項政策測試**全過（`/tmp/filicon-package-alias-tests-final.log`）；既有 Ruby **7 tests／80 assertions**、shell 語法、七語言 **1,624 keys／零缺漏**及 diff check 通過。
- **13 次原生 Debug build／deep strict／完整 package verifier 全過**，包含七語言更新後的 built strings 內容、資源新增／移除與 no-op。fixture 位於 `/var/folders/…/filicon-resource-signing.TGyLa6/`，來源與 DerivedData 名稱含空白，逐步 package log 隨同保留（總紀錄：`/tmp/filicon-package-alias-smoke.log`）。
- 同一隔離副本的 **Release arm64＋x86_64 原生 build 與 shipping 模式完整 verifier 全過**（`/tmp/filicon-package-alias-release-build.log`、`/tmp/filicon-package-alias-release-verify.log`）。Release 不含開發例外；錯用 Debug 模式也會被拒絕（`/tmp/filicon-package-alias-debug-mode-rejection.log`），與前述 Debug 不得通過 shipping 檢查形成雙向回歸。僅 ad-hoc 簽章 fixture，未用 Developer ID／notary、未產生可發布版本或執行 App。

本輪只有打包／驗證腳本與文件變更，不宣稱修復既有並行測試時序問題；未重跑 Swift 套件，上一輪非並行完整結果保留為歷史證據。本批已於下一輪提交為 `3be702e`；未 push、未啟動／重啟使用者 App／Xcode、未操作真實群組／排程／連線／憑證。整體仍 **43 complete／4 partial／1 NA**。

## 已提交增量：Xcode 資源增量建置的簽章依賴（2026-09-22）

先提交上一批為 `e00bab1`（`feat: approve restricted Teams routine proposals`），提交前 **70 Swift Testing／3 suites 通過**（`/tmp/filicon-teams-proposal-precommit.log`），七語言 audit 與 diff check 通過。原始參考 `hidden_from_sidebar` 作用於代理人側欄項目；Filicon 現行側欄列群組／一般聊天，尚無一對一對應，因此沒有假接設定或把隱藏改成封存。本輪先修正過往兩次已記錄的原生建置簽章缺陷，parity 功能狀態不提高。

- 在隔離來源副本先完成原生 Debug build 與嚴格驗簽，再連續修改翻譯。第一次碰上 Info.plist／embedded-product 工作而有 CodeSign；第二次僅複製 es／ko 翻譯後顯示 BUILD SUCCEEDED，卻沒有 CodeSign，deep strict 驗證失敗（`/tmp/filicon-signing-repro2.log`）。單獨設置 `ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING=YES` 也未解決，故未加入此旗標。
- 新增 `Track Resource Signing` phase，明確宣告唯讀來源資源樹／腳本與 bundle 輸出 `FiliconResources.sha256`。每次建置掃描檔案成員與內容，穩定排序、相對路徑、SHA-256；變更才更新摘要，不在來源樹產生檔案，拒絕 symlink 資源／輸出，包含 Unicode、空白、換行與 dotfiles。每次掃描是為了納入新增／移除資源；unchanged 摘要保留 mtime。
- 簽署仍由 Xcode 原有 CodeSign 執行，保持既有 identity／entitlements／helpers／XPC 與 script sandbox；沒有事後手動補簽、放寬權限或關閉驗證。此設計依據 [Swift Build 的 declared script outputs 追蹤](https://github.com/swiftlang/swift-build/blob/main/Sources/SWBTaskConstruction/TaskProducers/BuildPhaseTaskProducers/ShellScriptTaskProducer.swift) 與本機實測，而非假設每個 Xcode 版本都有相同缺陷。
- 依 SPM／Xcode 技能同步 checked-in project 與 Ruby generator，隔離副本重新產生後 phase 設定一致。未修改 Package.swift 或新增依賴；不改應用程式 UI／執行邏輯。本輪先使用 Swift 測試技能驗證前批；腳本本身使用獨立 Ruby fixtures 與實際 xcodebuild 回歸，沒有新增 SwiftUI 修改。

驗證：

- Ruby fixtures **7 tests／80 assertions** 通過；shell／Ruby 語法與 diff check 通過。七語言各 **1,624 keys，零缺漏**。
- 完整隔離 smoke **13 次原生 Debug build＋deep strict codesign 通過**，包含穩定後的七語言逐一變更、built strings 內容比對、資源新增／移除與無變更建置。資源變更均有原生 CodeSign；兩次無變更建置沒有 CodeSign，摘要亦保留。來源／DerivedData 路徑含空白，helpers／XPC 由 deep strict 一併驗證。紀錄：`/tmp/filicon-resource-signing-smoke-final.log`；產物與逐步紀錄：`/var/folders/34/yb_61rwx2kd7pc6f1xd7l80w0000gn/T/filicon-resource-signing.Z1uvB0/`。
- 首次 smoke 的 PlistBuddy fixture key 含空白卻未加引號，誤讀既有 `Filicon` key；確認 source／built resource 均正確後修正測試查詢，重新完整跑過，沒有刪掉內容斷言。
- 額外嘗試完整 package verifier 時發現既有 Debug 路徑比對限制：Xcode 簽入 `/var/folders/…/Filicon.app/`，verifier 將相同位置解析成 `/private/var/folders/…/Filicon.app/` 後以字串比較而拒絕。即使輸入 canonical 路徑，Xcode 仍產生 `/var` 形式（`/tmp/filicon-resource-signing-smoke-verified.log` 與 `filicon-resource-signing.SPNMkj/package-verification.log`）。本輪未放寬該驗證器或 entitlement；完整 package verifier 不算通過，smoke 的驗收邊界保持原生建置／內容／嚴格簽章，不宣稱 release／公證驗收。此路徑正規化問題留待後續修正。
- 初次未明確傳入 `--no-parallel` 的完整測試出現 coordinator／subagent 時序失敗、大量 60 秒 App approval 逾時，並觸發既有測試索引越界（`/tmp/filicon-resource-signing-swift-tests.log`）。沒有 Cocoa 257 或鎖定證據，不歸因為檔案保護，也未修改應用程式邏輯來掩蓋。
- 明確 `swift test --no-parallel` 重跑，**135 XCTest、1,007 Swift Testing／112 suites 全數通過**（`/tmp/filicon-resource-signing-swift-serial.log`）。兩項 opt-in live Codex 測試未啟用；CoreData NSXPC 診斷仍在。非並行通過不代表先前並行時序風險已根治。

本批已於下一輪提交為 `7cfd698`；未 push、未啟動／重啟使用者 App／Xcode，未操作聊天／群組／外部帳號或憑證。整體仍 **43 complete／4 partial／1 NA**，不是「原版全部都有」。

## 已提交增量：受核准的 Teams 排程定義提案（2026-09-22）

先提交上一批為 `a217e93`（`feat: add approved project-scoped shared memory`），提交前 **23 Swift Testing／3 suites 通過**（`/tmp/filicon-project-memory-precommit.log`）。本輪核對本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts`：Microsoft Teams trigger 支援 tenantId、teamId／teamIds、channelIds 與文字／政策欄位。原生入口沒有可信應用程式使用者身分，故只補受限的模型定義路由，不宣稱 Teams 雲端 runtime 已完成。

- 群組／mailbox 的自身 routine create/update 可用 `type:microsoftTeams`，單一條件、平面 group 或 bare array，與既有時間／平台條件共用最多八個 OR 分支。tenantId 須為 UUID；teamId 與 teamIds 合併，去重前合計 1–50 筆；channelIds 最多 50，空清單表示所選團隊內不限頻道。每 ID 最多 200 UTF-8 bytes，不接受空白、控制字元、逗號或萬用字元。不解析名稱、不猜測 ID。Graph team UUID 正規化，opaque Bot／channel ID 保留大小寫。
- messageContains 必填 1–120 字元 literal，不接受控制字元；messageContainsIsRegex 僅 false，blockUnauthenticatedTeamsUsers 僅 true，省略使用上述安全預設。null、錯誤型別、未知欄位與任一無效分支使整個提案失敗，不丟棄篩選。teamId/teamIds aliases、重排與重複項目具有相同 canonical replay receipt；原始清單上限不因去重而繞過。
- 完整新舊定義與啟用狀態需獨立核准，host 固定身分。保存時再次驗證 Teams 條件及舊定義；regex／放寬登入／空篩選等舊格式不得由模型轉換。沿用 owner／revision／lifetime、Stop／帳號切換／封存、費用保護、四次共用額度、原子保存／失敗回滾／durable receipt，保留執行歷史與進行中的任務。
- **只保存定義，不啟用 Teams 事件執行。** blockUnauthenticatedUsers=true 保持不變，HMAC 或 payload 的 authenticated=true 仍不能代替可信登入身分。其他 OR 分支及使用者明確 Run Now 仍可執行並產生模型費用；沒有新連線、登入、webhook、工具權限、Graph subscription 或主文判定。核准卡頂端與工具回覆／runtime／schema 明示限制，七語言同步新增提示與錯誤。

依 Swift 測試／CustomDump 技能使用固定時間、隔離 store、受控 continuation、完整值比較與 fixture provider；依 SwiftUI 技能沿用既有核准明細，將重要限制置頂，不自造 binding。新增五項核心測試函式與一項雙外觀渲染測試；擴充既有 create/update 的核准、拒絕、Stop／延遲 commit、帳號、封存、stale、保存失敗、容量／receipt／身分測試，包含 group 與 mailbox。首次編譯修正 let 字串組合與測試 optional description；首次實際聚焦有兩項舊 schema 數量斷言失敗（6 issues），更新為包含 Teams 的精確型別集合與數量，不弱化驗證（`/tmp/filicon-teams-model-focused3.log`）。

聚焦回歸 **81 Swift Testing／4 suites 通過**（`/tmp/filicon-teams-model-focused-final.log`）。產生 **28 張 Teams 核准明細**：單一 create/update × 七語言（380 點寬），以及 Teams＋cron 混合 update × 七語言 × 明暗（440 點寬）；並重新產生既有各平台預覽（`/tmp/filicon-teams-model-previews/`）。逐語檢視至少一張，另檢視繁中／法／西／日／韓深色卡，未見文字裁切。修正既有 Enabled 西文殘留英文、韓文誤譯與日文動作式用詞後，重新渲染並通過兩項預覽測試（`/tmp/filicon-teams-model-preview-final.log`）。只驗證核准明細，不是全產品逐頁或 live 模型驗收；fixture 名稱／任務仍是使用者內容。

最終完整 `swift test --no-parallel` **135 XCTest、1,007 Swift Testing／112 suites 全數通過**（`/tmp/filicon-teams-model-full-final.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。七語言各 **1,624 keys、零缺漏**，`git diff --check` 通過。

原生增量 build 成功，但最後三語言資源更新未重新執行 CodeSign，嚴格驗簽發現 ja／es／ko 與舊 seal 不一致（`/tmp/filicon-teams-model-native-verified.log`）。改用全新隔離 DerivedData `/tmp/filicon-teams-model-native.vOK7XS` 完整建置，**原生 Debug build 與 deep strict codesign 通過**，包含 helpers／XPC（`/tmp/filicon-teams-model-native-clean.log`）。沒有手動補簽、修改使用者 Xcode 產物或宣稱增量簽章問題已根治。既有 optional-to-Any、weak capture、AppIntents metadata／ad-hoc runtime 提示仍在；不是 release 簽署／公證驗收。

本批已於下一輪提交為 `e00bab1`；未 push、未啟動／重啟使用者 App／Xcode、未操作真實聊天／群組／排程／外部帳號或憑證。`AGENT-01`／`AUTO-03` 維持 partial，整體仍 **43 complete／4 partial／1 NA**。

## 已提交增量：受核准的專案共享記憶（2026-09-22）

先提交上一批為 `391a9ff`（`feat: approve account-scoped collaboration project membership`），提交前專案核心／App 聚焦 **14 Swift Testing／2 suites 通過**（`/tmp/filicon-project-precommit.log`）。本輪核對本機非官方 reconstructed 的 `source/host/extensions/memory/agent-state.ts` 與 `source/host/runner/tools/sand-state-tool.ts`：project memory 要求專案存在及自身成員資格，記錄以 writer 區分。本輪接上受限制的原生對應，不以此宣稱完整原版 runtime。

- 群組／mailbox 的 `update_state(target:"memory",action:"write"|"forget",scope:"project",project:"exact-slug",fact:...)` 必須已有 active 成員資格。host 固定帳號與代理人，模型只能忘記自己記錄的精確事實；scope／slug／其他欄位混用拒絕。寫入與忘記皆獨立明確核准，不沿用 auto-review allow；卡片展示全文、作者、專案與成員數量。
- 事實只供同帳號此專案的目前／未來成員及其配置模型於群組／mailbox 回合召回，包含此聊天以外的成員。離開不刪事實、停止後續讀取；重新加入恢復存取，已傳送訊息及 in-flight context 不會撤回。加入／離開核准與工具回覆已同步揭露此影響；私人記憶不自動轉為共享，檔案／工具權限不變。
- `AgentService` 提案捕捉完整專案快照／revision；提交再次驗證，leave/rejoin ABA、其他成員變更、owner 封存、Stop／帳號切換使未提交變更失效。沿用原子保存／失敗回滾／成功 receipt，以及四次修改共用額度和 tool-call 重播防護。容量為每專案跨 writer 共用 48 筆／8 筆基礎事實／12,000 字元，每筆 1,000 字元，與 reference 每 writer shard 容量並非完全相同。
- 自動召回沿用有界關鍵字與排序；專案額外的總預算為所有已加入專案合計 8 筆／4,000 JSON bytes 基礎事實、15 筆／2,000 bytes 近期事實，不乘以專案數。不同專案相同文字不互相去重，省略不刪除。
- `SearchMemory` 加入 `scope:project`，可選精確 `project`；all 亦包含已加入專案。先以同一 actor 快照過濾帳號／成員身分，再搜尋／分頁；相關成員 revision 也綁定 cursor，離開再加入仍不得續用舊游標。保留每頁八筆／8 KiB JSON、32 次讀取額度、來源與 canForget。純資料投影 API 未提供 joined 集合時預設拒絕所有 project records，連作者本人亦同。
- 人類編輯器 **代理人 → 編輯 → 專案記憶** 列出本帳號全部專案事實，標示專案與作者，可刪除已離開／封存作者的記錄；此全帳號查閱／刪除入口不暴露給模型。舊無 scope 記憶仍為私人；project 欄位與 scope 不一致、缺失或路徑式 slug 的儲存資料解碼保守失敗，不默默擴大可見範圍。

依 Swift 測試／CustomDump 技能使用隔離 store、固定時間、完整值比較與 fixture provider；依 SwiftUI 技能重用既有核准卡與記憶列表，不新增自訂 binding。新增九項核心與三項 App 測試函式（包含六組核准結果），涵蓋寫入／忘記、私有與跨帳號隔離、非成員、ABA／封存／保存失敗、共用容量／重播／四次額度、搜尋游標、mailbox recipient 身分及人類刪除。開發中的既有 invalid-scope 測試改驗專案欄位錯誤／預設拒絕；App 首次聚焦因 Date 次毫秒往返差異有一項失敗，改以完整毫秒 Codable 值比較後通過，未忽略時間欄位或放寬產品驗證。

最終聚焦 **23 Swift Testing／3 suites 通過**（`/tmp/filicon-project-memory-focused-final.log`）。產生 **28 張專案記憶核准明細**（寫入／忘記 × 七語言 × 明暗）及重新產生 **42 張專案成員核准明細**（`/tmp/filicon-project-memory-previews/`）；逐語檢視共享記憶淺色卡，另檢視繁中／法文深色忘記卡和英文加入／繁中離開卡，380 點寬未見文字裁切。英文 fixture 姓名／事實保留為使用者內容。只驗證明細元件，非全產品逐頁或 live 模型驗收。

最終完整 `swift test --no-parallel` **135 XCTest、1,001 Swift Testing／112 suites 全數通過**（`/tmp/filicon-project-memory-full-final.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。原生 `Filicon App` Debug build（`/tmp/filicon-project-memory-native.log`）及產物 deep strict codesign 通過，含 helpers／XPC，不是 release 公證驗收。七語言各 **1,619 keys、零缺漏**，`git diff --check` 通過。未 push、未啟動／重啟使用者 App／Xcode、未操作真實聊天／群組／專案／外部帳號或憑證。本批已於下一輪提交為 `a217e93`。仍缺自動記憶抽取／任意 archive、其他執行入口與完整 persona/runtime；`AGENT-01` 維持 partial，整體 **43 complete／4 partial／1 NA**。

## 已提交增量：受核准的協作專案成員資格（2026-09-21）

先提交上一批為 `6eaf146`（`feat: add validated manual Teams routine editing`），提交前 Teams 編輯／事件／App 聚焦 **91 Swift Testing／5 suites 通過**（`/tmp/filicon-teams-editor-precommit.log`）。此輪核對本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts` 與 `source/host/extensions/memory/agent-state.ts`：create 是建立後加入、已存在時只加入不覆蓋 metadata，join 須存在，leave 不刪除 project；project memory 為另一條需成員身分的路由。本批只補前者，不宣稱還原完整共享專案記憶。

- 群組／mailbox 使用 `update_state(target:"project",action:"create"|"join"|"leave",project:slug)`。host 固定自身代理人及帳號；create 另需名稱、可選說明，join／leave 不接受其他欄位。JSON 上限 8 KiB；slug 為最多 64 UTF-8 bytes 的小寫 ASCII 字母／數字與單一連字號，拒絕路徑。名稱最多 200、說明最多 1,000 UTF-8 bytes，拒絕控制字元後才去除首尾空白。
- 帳號內最多 50 個專案，含空專案；已加入／已離開回傳 no-op error，不當成新變更。create existing 保留全部舊 metadata，離開只移除自己、保留其餘成員及專案。獨立明確核准不可沿用 auto-review allow；七語言卡片完整顯示 metadata、加入／離開前後與成員數量，提醒名稱／說明為同帳號目前及未來代理人及其模型共享資料。
- 模型目錄只注入該帳號的 slug／name／自身 joined，不包含 peer 名單、description 或私人事實，並標記為不受信任資料。project 不是群組、檔案授權或工作指派；不新增聊天／wake／任務／資料夾、不改私人 persona 或記憶。`scope:project` 記憶仍拒絕。
- 提案由 AgentService 快照產生，提交時重驗完整舊值及持久化 revision，涵蓋 leave/rejoin ABA、並行建立與容量競爭；同步 lifetime fence 擋下 Stop／取消／帳號切換後未提交的變更，也重驗 owner 是否封存。沿用原子保存與完整回滾；保存成功才記 receipt，後續 bookkeeping 失敗不誤報未執行。重播同 call 返回結果、pending 重複拒絕，與既有狀態修改共用四次額度。不是跨程序直接改檔的 CAS。
- `agents.json` 加入可省略的 projects，舊檔缺鍵時為空清單；不遷移聊天／私人記憶／資料夾。沒有專案 rename/delete、專用手動管理 UI、reference project.md 或 project memory。AgentService 原有 agents 為本機 roster，本批 project records 才有明確 account scope。

依 Swift 測試／CustomDump 技能使用隔離 store、固定時間、完整值比較及受控 continuation gate；依 SwiftUI 技能重用群組／mailbox 核准卡，不引入新的自訂 binding。新增十項核心測試與四項 App 測試函式（含拒絕／Stop／帳號／封存／保存失敗等參數），檢查身分隔離、嚴格欄位與 UTF-8 上限、create-is-join、持久化／舊格式、私人記憶保留、stale／ABA、容量、延遲 commit、receipt、共用額度及 mailbox recipient。開發中修正 fixture 的 ToolCallID 建構與 App 私有存取編譯錯誤，沒有開放產品私有 service 供測試使用。

最後檢查發現 quota ledger 為 App-wide，僅以 slug 當用量 key 會讓不同帳號同名專案互相覆蓋計數。本輪改用有界 account 編碼＋slug 複合 key，不改檔案路徑；補上不同帳號／分隔字元／最大長度及真實 App 核准保存後的 ledger 檢查。兩項聚焦測試（含六組保存結果）通過（`/tmp/filicon-project-quota.log`），原生 build 與 deep strict 簽章重新通過，再重跑全套驗證。

初次聚焦 **12 Swift Testing／2 suites 通過**（`/tmp/filicon-project-focused3.log`），其後補上舊檔／私人記憶回歸。首次完整回歸在舊 profile 測試有 **1 issue**（`/tmp/filicon-project-full.log`）：原測試把 project 視為未知 route、預期 profile.invalidFields；新增 project validator 後回傳 project.invalid。將該非法 profile 欄位案例獨立檢查精確錯誤，保留未知 route 拒絕測試，未放寬產品驗證。

核准明細產生 **42 張預覽**（create／join／leave × 七語言 × 明暗，380 點寬；`/tmp/filicon-project-previews/`），每種語言至少檢視一張；英文 fixture 的姓名／名稱／說明保留為使用者資料，不自行翻譯。修正建立預覽的成員數量為 0→1 後重新產生全部預覽，另檢視繁中／法／韓建立卡。只驗證此核准明細，非全產品 UI 或真實模型驗收。

最終完整 `swift test --no-parallel` **135 XCTest、989 Swift Testing／111 suites 全數通過**（`/tmp/filicon-project-full-verified.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。原生 `Filicon App` Debug 增量 build（`/tmp/filicon-project-native-final.log`）及產物 deep strict codesign 通過，含 helpers／XPC；不是 release 簽署／公證驗收。最終預覽測試另外通過（`/tmp/filicon-project-previews-final.log`）。七語言各 **1,607 keys、零缺漏**，`git diff --check` 通過。未 push、未啟動／重啟使用者 App／Xcode、未改實際聊天／群組／專案／排程／連線／憑證。本批已於下一輪提交為 `391a9ff`。`AGENT-01` 仍為 partial；整體維持 **43 complete／4 partial／1 NA**。

## 已提交增量：受限制的 Teams 手動條件編輯（2026-09-21）

先提交上一批為 `4a434f2`（`feat: approve disconnection of agent-owned channels`），提交前頻道／管理聚焦 64 項再次通過。此輪核對本機非官方 reconstructed 的 `sand-state-tool.ts` Microsoft Teams schema、`automation-trigger.ts` scope／filter 判定，以及 Filicon 既有原生 Teams 安全邊界；不以表單完成宣稱原版 Teams 雲端能力已還原。

- Teams 新增／既有條件編輯共用嚴格驗證：一個 tenant UUID、1–50 個 Graph UUID 或精確 Bot team ID、可留空的最多 50 個 channel ID。清單在去重前計數，空逗號項、`*`、ID 中空白／控制字元／逗號及超過 200 UTF-8 bytes 直接拒絕，不靜默丟棄。修改時只正規化 UUID；opaque ID 保留大小寫，不查名稱、不安裝連線。
- 必填 literal substring 篩選，最多 120 字元、拒絕控制字元，不把 regex 語法當成 regex 執行。原生 substring 比對仍不分大小寫且包含回覆；沒有新增主文判定。舊 regex／blockUnauthenticatedUsers=false／空篩選／無效 scope 維持 metadata-only，含其 OR 群組；完整原始 trigger 保留。未改動的 OR 分支也維持原值。
- 新增與可編輯的 Teams 條件固定保留 blockUnauthenticatedUsers=true，原生入口缺乏可信登入身分，因此 Teams 分支仍不執行；畫面新增醒目狀態並保留詳細說明。其他 OR 分支及 Run Now 不變。後端 manual-save 再驗證相同邊界，不能繞過表單放寬政策；模型 Teams create/update（單一／OR、政策兩方向）仍拒絕。
- 沿用原子手動保存、revision／lifetime／account／owner 封存及儲存失敗保護；保留 enabled、費用防護、history 與未變動的時間基準。不操作真實資料或服務。

依 Swift 測試／CustomDump 技能先重現兩項紅測試（不可編輯、空逗號被丟棄；2 tests／4 issues），以隔離 store／App fixture、固定時間檢查完整值。依 SwiftUI 技能沿用直接 state binding，Teams 欄位改為可換行、靠左的文字輸入，標籤／狀態／錯誤／限制說明補齊七語言。擴充測試時修正 async autoclosure 編譯用法；重開比較改用完整毫秒 Codable 表示，避免把 Date 次毫秒往返差異當產品錯誤，未忽略時間欄位。

驗證：聚焦 **91 Swift Testing／5 suites 通過**（`/tmp/filicon-teams-editor-verified.log`）。Teams 新增九項測試函式（含六種 App 保存結果參數）及一項模型路由拒絕測試；涵蓋 ID 原始清單／空項／UTF-8 上限、UUID 與 opaque 大小寫、文字上限／控制字元、正規表示式不轉譯、政策不放寬、舊條件不遷移、OR 分支保留、時間基準／history／持久化、表單繞過、取消／帳號／封存／stale／保存失敗、群組模型提案仍拒絕。

產生 **56 張 Teams 專用預覽**（欄位有效／無效、完整 sheet 可編輯／唯讀 × 七語言 × 明暗；`/tmp/filicon-teams-editor-previews/teams-fields-*` 及 `teams-sheet-*`），每種語言至少檢視一張。檢視後修正沿用的韓文標籤中的英文殘留、以及 macOS Form 對輸入欄的右側配置，重新渲染確認韓文與日文完整 sheet；長清單可軟換行。sheet 內容可捲動，並非全產品逐頁或真實 Teams 帳號驗收。

最後完整 `swift test --no-parallel` **135 XCTest、975 Swift Testing／110 suites 全數通過**（`/tmp/filicon-teams-editor-full-final.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。原生 `Filicon App` Debug 增量 build（`/tmp/filicon-teams-editor-native-verified.log`）及 deep strict codesign 通過，含 helpers／XPC；七語言各 **1,594 keys、零缺漏**，`git diff --check` 通過。未 push、未啟動／重啟使用者 App／Xcode、未改真實聊天／群組／排程／連線／憑證。本批已於下一輪提交為 `6eaf146`。

`AUTO-03` 仍為 partial：Teams 可信登入／主文／Graph／同步回覆／regex 與模型提案、GitHub checks 彙整、Slack 名稱／人類身分及 live 帳號驗收尚有缺口。整體維持 **43 complete／4 partial／1 NA**。

## 已提交增量：受核准的自身頻道斷線（2026-09-21）

開始時工作區乾淨，上批已提交為 `65a9352`（`fix: preserve channel state across failed writes and stale callbacks`），未重複建立空提交。Xcode 更新後 Swift 6.4 已可執行；使用新的隔離 scratch／DerivedData，先補跑上批最終驗證：**135 XCTest、953 Swift Testing／108 suites 全部通過**（`/tmp/filicon-swift64-channel-baseline.log`），原生 Debug build 與 deep strict codesign 通過（`/tmp/filicon-swift64-native.log`）。兩項 opt-in live Codex 測試未啟用；保留既有 CoreData XPC 診斷。沒有代為接受條款、變更全機 xcode-select 或啟動／重啟使用者 App。

再次核對本機非官方 reconstructed `sand-state-tool.ts` 的 channel.disconnect 路由與 `agent-state.ts` 的 disconnectChannel。Filicon 的連線庫可同平台多連線，不能照搬按平台直接刪除：

- 群組／mailbox 的 `update_state(target:"channel",action:"disconnect",platform:"slack"|"discord")` 僅接受這三個字串欄位及 4,096-byte 上限。host 固定代理人身分，只選該代理人在該平台的單一連線，停用連線也可移除；peer、未指定 owner 的 receive-only 連線不可選。多條自身連線即拒絕，要求使用者到「頻道」精確選擇，不猜測、不批次移除。沒有新增其他平台、連線建立或遠端撤權。
- 每次必須經獨立 destructive 核准，不沿用 auto-review 的工具 allow 規則。卡片顯示代理人、平台、連線名稱／ID、帳號／頻道標籤、啟用狀態，以及接收、傳送、待傳送／傳送中、失敗紀錄數量。模型結果不回傳憑證、帳號標籤、訊息內容或 peer 資料。
- 確認後刪除選中連線的本機 connection／inbound／delivery／failure wake 並停止 listener；沒有 undo。聊天紀錄、附件檔案、其他連線及 routine 保留。已接受回呼或已開始送出仍可能完成，不召回遠端訊息，也不撤銷遠端 OAuth。**鑰匙圈憑證保留**，避免刪除可能共用的 reference；核准與結果均明示，不冒充已完成遠端登出或憑證清理。
- proposal 只能由 ChannelService 的真實快照產生，process-local store revision 覆蓋全庫成功寫入，包括入站／佇列變動及相同值 ABA；資料改變即要求重新核准。不是跨程序直接改檔的 CAS，也不保證活躍高流量頻道能使用舊核准。Stop／帳號切換／取消透過同步 lifetime fence 撤銷尚未保存的提案，批准後重新檢查 owner 是否封存。持久化失敗完整回滾；只有保存成功才記 receipt，後續 UI 刷新失敗不把已完成刪除說成沒做。
- 共享既有四次修改額度，包含已保留的 pending request；重播同 call 返回原成功結果，不重複刪除；同 call 換參數、同義重複 pending／成功請求拒絕，拒絕後可重新提案。原生 AppServices 加入既有 FiliconChannels target 依賴，沒有新增套件。

依 Swift 測試／CustomDump 技能使用隔離 store、固定時間、受控 gate 與完整值差異；SwiftUI 技能用共用群組／mailbox 核准卡、不引入自訂 binding。新增 9 項核心／session 測試函式及 3 項 App 測試函式（含多組參數）；涵蓋 Slack／Discord、owner／receive-only 隔離、歧義、取消／封存／帳號／Stop、配置與資料 ABA、保存失敗回滾、延遲 commit、重播與並行重複、四次額度、durable receipt、mailbox recipient。首次測試有新 fixture 的 throws／protocol 欄位編譯問題，以及誤把已進 dead-letter 的項目算 pending；修正 fixture 為同時保留失敗紀錄與另一筆待傳送，沒有改產品狀態判定來配合測試。

聚焦 **64 Swift Testing／4 suites 通過**（`/tmp/filicon-channel-approval-focused-final.log`）。七語言卡片產生 14 張 380 點寬的明暗預覽（`/tmp/filicon-channel-approval-previews/`），逐語言檢視後修正沿用的西班牙文／韓文 enabled 標籤，改用專屬已啟用／停用鍵，並重新檢視修正後的西／韓深色預覽。不是全產品逐頁或真實 Slack／Discord 帳號驗收。

最終 **135 XCTest、965 Swift Testing／109 suites 全數通過**（明確 `--no-parallel`，`/tmp/filicon-channel-approval-full.log`）。兩項 opt-in live Codex 測試未啟用，既有 CoreData NSXPC 診斷仍在；未弱化檔案保護或跳過失敗案例。原生 `Filicon App` Debug 增量 build（`/tmp/filicon-channel-approval-native-final.log`）與產物 deep strict codesign 通過，含 helpers／XPC；本輪開始時已以新的 DerivedData 完成基準建置。七語言各 **1,586 keys、零缺漏**，`git diff --check` 通過。未 push、未啟動／重啟使用者 App／Xcode、未改實際聊天／群組／頻道／憑證；這不是正式 release 簽署或公證驗收。

工具鏈說明：CustomDump 保持 1.7.3／同 revision；Swift 6.4 改選其主要 manifest，傳遞依賴為 `swift-issue-reporting 2.1.0`，舊 Swift 6.1 manifest 則使用 `xctest-dynamic-overlay 1.13.1`。兩個 resolver lockfile 已同步反映工具鏈選擇，未將測試套件加入 App 執行期依賴，也不宣稱驗證了所有舊版 Swift。`AGENT-01` 維持 partial，整體仍 **43 complete／4 partial／1 NA**。

## 已提交增量：頻道斷線與非同步資料一致性（2026-09-21）

先提交通知設定為 `49ea201`（`feat: approve per-agent update notification settings`），提交範圍沿用上輪已驗證結果，`git diff --check` 通過。本輪核對本機非官方 reconstructed `source/host/extensions/memory/agent-state.ts` 的 disconnectChannel 與 `sand-state-tool.ts` 的 channel/disconnect，發現 native 手動斷線流程已有必須先修的競爭與寫檔失敗問題；本批是安全前提，**沒有新增模型斷線路由或核准 UI**。

- `ChannelService.persist` 維持上次成功保存的完整狀態。connection、inbound、delivery、failure wake 任一保存失敗均回滾，避免稍後無關操作將失敗變更一起寫入。remove／disable 成功持久化後才取消 listener；失敗不使仍存在的連線悄悄停止接收。
- refreshProfile 不再把陣列 index 帶過 await。回傳時依精確 ID、process-local 配置世代與最新 request ID 重驗，移除／同 ID 重建、配置重設、停用再啟用、較新 refresh 或取消均使舊結果失效。只合併 profile/accountID，保留等候期間已接受的 cursor／activity。不新增跨程序／外部直接改檔的 CAS。
- listener 具有每次 start 的 token，接收時核對 token、enabled、固定 connection ID 與平台，舊 listener 不能把另一條連線的 envelope 寫入；晚到錯誤亦核對存活身分。配置 save 成功會停止捕捉舊配置／憑證的 listener，由 caller 明確 start 新配置，既有 App 新增連線路徑本來就會 start。已接受的回呼不會被撤回。
- flush 於每筆開始時重驗狀態／到期時間並保留 process-local in-flight ID，避免重疊 flush 的舊清單把已完成項目再次送出。sending checkpoint 無法持久化即不呼叫 connector。傳送中刪除不復活紀錄；不宣稱能取消已開始的外部送出。結果保存失敗保留 durable sending，當前程序不立即重送；沿用重啟時改 retrying 並使用同一 idempotency key 的復原行為，不是 exactly-once，仍取決於 connector／遠端服務。
- 依 Swift testing／dependencies／CustomDump 技能使用隔離 store、固定時間、受控 continuation gates 與完整值快照。依 SPM 技能只把現有 CustomDump product 加入頻道 test target，不新增 package 或產品執行期依賴。沒有 UI／字串修改。

驗證紀錄：

- 先用兩項紅測試重現：failed removal 導致記憶體資料遺失，移除第一條連線後 profile 回傳污染原本第二條連線。**2 tests／4 issues**（`/tmp/filicon-channel-lifecycle-red.log`），不是僅推測風險。
- 修正後 **11 tests／2 suites 通過**（`/tmp/filicon-channel-lifecycle-focused.log`）。擴充 fixture 最初漏 return，修正編譯並移除多餘 try 後，**20 tests／2 suites 通過**（`/tmp/filicon-channel-lifecycle-extended.log`）；涵蓋同 ID 重建、停用 ABA、取消、較新 refresh、activity 合併、六種保存失敗、失敗斷線仍可接收、listener 跨連線／平台隔離、重疊 flush、sending checkpoint 失敗、late success/failure 不復活，以及既有頻道回歸。
- 原生 `Filicon App` Debug build 通過（`/tmp/filicon-channel-lifecycle-native.log`），`codesign --verify --deep --strict` 通過，包含 helpers／XPC；這次非 clean build，保留 ad-hoc／AppIntents 的既有提示。
- 又加三項測試函式（四種 case）：成功刪除僅影響選中連線、send result 保存失敗不誤報成功／重啟沿用 key、失敗配置寫入不撤銷既有 profile request。**最後版本已編譯，但沒有完成執行**（`/tmp/filicon-channel-lifecycle-focused-final.log`）：SwiftPM helper dlopen 找不到 Testing.framework 並 signal 5。之後唯讀檢查本機 Xcode Info.plist 為 **27.0**、app 時間為本輪 20:21，Xcode／xcrun 指令要求同意授權條款。已請使用者自行開啟 Xcode 完成條款及初始化，未代為接受、未更改全機 xcode-select 或繞過工具鏈要求。
- 七語言各 **1,571 keys、零缺漏**，`git diff --check` 通過。最終聚焦回歸與完整測試尚待 Xcode 初始化後重跑，不能援引先前通過數字宣稱本輪全套成功；沒有啟動 live 模型／外部帳號／平台測試。

使用者再次要求 commit 後繼續；提交前重新確認 Xcode **27.0（27A266a）**，`xcodebuild -checkFirstLaunchStatus` 回傳 69，`xcrun swift --version` 仍明確回報未同意授權條款。因此依使用者要求提交現有變更，但不把追加測試或完整套件標示通過。提交前 `git diff --check` 通過；未代為接受條款、未繞過初始化。

未 push、未啟動／重啟使用者 App／Xcode，未操作實際群組／頻道／憑證。下一步先完成驗證，再接上受核准的自身 channel.disconnect：需限制 owner／精確目標與歧義拒絕，完整揭露本機歷史／佇列移除、金鑰處理和已開始送出的限制。`AGENT-01` 與其餘 partial 保留。

## 已提交增量：受核准的自身更新通知設定（2026-09-21）

先提交上一批為 `4a994a4`（`feat: approve deletion of agent-owned reusable workflows`），提交前 **26 Swift Testing／3 suites 通過**（`/tmp/filicon-workflow-delete-precommit.log`）。本輪對照本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts` settings/set 與 `source/host/extensions/memory/agent-state.ts` updateSettings，只補有原生對應的 `notify_on_updates`，不宣稱整個 settings/state 已對等。

- 群組／mailbox 可用 `update_state(target:"settings",action:"set",notify_on_updates:Bool)` 提案。只接受這三個欄位、4,096-byte JSON 上限，嚴格驗證 JSON boolean，拒絕 0/1、字串、null、owner／permission 與其他欄位。`hidden_from_sidebar` 沒有相同原生側欄對象，單獨或混合提案均拒絕，不偷偷改成 archive。
- host 綁定自身 agent，獨立 authorizer 預設拒絕；即使 auto-review allow 也必須逐次明確核准。卡片顯示成員、原值／新值與影響範圍。不讓 profile／workflow 等核准授權靜音，沿用共用四次額度、精確重播回執、取消／帳號切換至最終同步保存的 lifetime 防護。
- `AgentProfile.notifyOnAgentUpdates` 持久化，舊資料預設 true；新建預設開啟，建立頁可選關閉，clone 維持新 agent 的開啟預設。專用可持久化 revision 在實際開關變更時更新，防止提案期間關閉再開啟（ABA）與舊編輯器覆寫。核准只合併該設定，保留其他最新欄位；disk save 失敗回滾，save 成功後晚到記帳失敗保留 durable receipt。同值設定不產生假變更。不是跨程序／外部檔案編輯的 CAS。
- 由原先固定 true 的 `AgentNotificationProjection` 接到實際 preference，只控制 agent roster 完成／等待輸入的系統通知。不是整個 App 或所有對話的靜音；不隱藏 approval cards、未讀數、Dock badges，不改工作／成員／可見性／權限，也不移除既有通知。開啟不補送已觀察的過去通知，實際 delivery 仍受 macOS 授權、focus 與 throttle 約束。設定屬本機共用 profile，跨使用該 profile 的群組／帳號，不是帳號隔離的 memory。
- 依 SwiftUI 技能加上 Agents → Edit →「代理人更新通知」切換並儲存，使用直接 state binding；核准細節／影響說明抽為可重用元件，補齊七語言。舊 editor 若設定已變更會顯示可翻譯錯誤，要求重新開啟，不靜默覆蓋。

測試先重現缺少 route：第一次 fixture 缺少 `try`，修正可編譯後確實收到 `.invalidFields` 而非預期的 `.approvalRequired`（`/tmp/filicon-settings-red.log`）。產品補齊後，初版 private-marker 斷言誤把系統說明的通用詞 PRIVATE 當資料外洩；改為精確 fixture 值／路徑比對，沒有刪除隔離斷言。

驗證狀態：

- 聚焦 **22 Swift Testing／4 suites、3 XCTest 通過**（`/tmp/filicon-settings-focused-final.log`），包含新設定路徑、現有頭像、通知 policy／projection，群組批准／拒絕／Stop／帳號／ABA／封存 × 開關兩方向、mailbox recipient、手動新建／編輯與重開、資料遷移、寫檔回滾、延遲 commit 撤銷、同 call id 重播與共用預算。範圍均為隔離 fixture，非真實付費模型或帳號。
- 原生 `Filicon App` **clean build 與 deep strict codesign 通過**（`/tmp/filicon-settings-native.log`），含 helpers／XPC；既有 AppIntents metadata／ad-hoc runtime 提示保留。後續釐清通知權限文字（設定可開啟，delivery 才受系統授權控制），呈現／policy 回歸 **6 Swift Testing／2 suites、3 XCTest 通過**（`/tmp/filicon-settings-presentation-final.log`），原生增量 build／deep strict codesign 再次通過（`/tmp/filicon-settings-native-final.log`）。
- 七語言各 **1,571 keys、零缺漏**；28 張 380 點寬核准 fixture 預覽（開／關 × 七語言 × 明暗）在 `/tmp/filicon-settings-previews/`，每種語言至少檢視一張，未見裁切。不是全產品逐頁或 live App 驗收。
- 完整 `swift test --no-parallel` **135 XCTest 通過，但 939 Swift Testing／107 suites 回報 75 issues，未通過**（`/tmp/filicon-settings-full.log`）。執行中 Mac 鎖定，已確認 `CGSSessionScreenIsLocked=Yes`；多個既有與新測試重開 protected agents/workflows/channels/MCP/image 檔案回報 Code 257／EPERM，另有 state 為空／malformed 等衍生斷言。不能在未解鎖重跑前把所有失敗一概判為環境問題或宣稱全套成功。已請使用者解鎖，未移除檔案保護或忽略失敗。

- 偵測到鎖定旗標解除後重跑，**135 XCTest 通過；939 Swift Testing／107 suites 剩 1 issue**（`/tmp/filicon-settings-full-final.log`），不再有 protected-file 重開失敗。剩餘項是舊 `ownProfileRejectsOtherStateRoutesFieldsAndIdentitySpoofing` 對 settings 非法 profile 欄位預期通用 `.invalidFields`；新增 route 改回傳精確 `.invalid`。改為獨立驗證 `AgentSettingsChangeError.invalid`，仍要求該非法提案被拒絕，不移除範圍保護。

- 最後完整 `swift test --no-parallel` **135 XCTest、939 Swift Testing／107 suites 全數通過**（`/tmp/filicon-settings-full-verified.log`）。兩項 opt-in live Codex 測試未啟用，既有 CoreData NSXPC 診斷仍在；沒有跳過失敗測試或降低檔案保護。這是隔離回歸，非真實 macOS 通知投遞／帳號驗收。

本批已於下一輪提交為 `49ea201`；未 push、未啟動／重啟使用者 App／Xcode，未操作真實群組、排程或外部服務。`AGENT-01` 與其餘 partial 項目保留，不以本輪通知開關宣稱原版完整對等。

## 已提交增量：受核准的自身工作流程刪除（2026-09-21）

先提交上一批為 `a4e5d4c`（`feat: approve agent-owned workflow creation and rewriting`）；提交前 **32 Swift Testing／5 suites 與 14 XCTest 通過**。本輪核對本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts`（workflow/delete）及 `source/host/extensions/memory/agent-state.ts`（deleteWorkflow）。補 Filicon-native 受限對應，不宣稱完整原版 workflow/state parity。

- 群組／mailbox 使用 `update_state(target:"workflow",action:"delete",id:...)`，只接受這三個字串欄位及精確 ID，JSON 不超過 4,096 bytes。身分由 host 固定；只允許自身本機、手動、單一 prompt、全文不超過 8,000 UTF-8 bytes 的定義。peer／未指定 owner／source-linked／learning／多步驟／action／scheduled 拒絕，不接受 authority/body 等混入欄位。
- 刪除與 workflow write 使用獨立 authorizer，預設拒絕，不繼承 profile/write 或 auto-review allow。逐次 destructive 核准顯示完整舊定義、ID、enabled 狀態及已知直接引用總數／前 100 個名稱與 ID；不把 peer 正文或引用清單送回請求模型。
- 核准明示無法復原。僅原子移除共用定義，既有 run history 仍可在工作流程全域歷史依 ID 檢視；已取得內容的執行繼續。其他 workflow、routine、排程、檔案、來源、連線、權限均不連帶刪除／停止／改寫；未來引用可能失敗或省略內容。流程庫仍是本機共用內容，非帳號隔離記憶。
- 原子 commit 核對同 store revision 與完整舊定義，任何 library save／同值重設均使舊提案失效，刪除重建亦受保護；不是跨程序或外部直接改檔的版本鎖。Stop／帳號切換同步撤銷，核准後重驗未封存 owner；共用四次修改上限與 pending reservation／精確重播。durable receipt 區分實際刪除和後續記帳錯誤，不會將成功刪除誤報失敗而重試；刪除不需要新增儲存額度。

依 Swift 測試／CustomDump 技能使用隔離資料、受控 continuation gate 與 fixture provider；先用缺少獨立核准路由的紅測試重現。新增拒絕／Stop／帳號切換／封存／stale／相同 ID 重建／同值重設／磁碟失敗、完整核准 metadata、peer 與跨 mailbox 身分、防重播／四次預算、commit 前撤銷、已捕捉執行與持久歷史測試。修正新測試 async autoclosure 用法；Swift 6.3.3 曾在 provider 閉包的複合 `#expect` 觸發 SendNonSendable 編譯器 crash，改以相同語意的字串清單／CustomDump 比對後可編譯。ABA 測試原先誤將重建後由 store 更新的時間戳與刪除前比較，現檢查拒絕核准後完整保留重建定義，另有同值重設 revision 測試，不弱化產品防護。

第一次可執行的聚焦回歸遇到 macOS 鎖定（已確認 `CGSSessionScreenIsLocked=Yes`），受保護的 workflows/history 檔案重開回報 Code 257／EPERM；包括既有測試亦失敗（`/tmp/filicon-workflow-delete-focused-final.log`）。沒有移除檔案保護、跳過錯誤來宣稱全套通過。鎖定解除後重跑，持久化測試恢復；另確認 mailbox 將拒絕以 typed error 回傳，而非群組的 error-result wrapper，修正 fixture 接住 `.unavailable` 後再提案自身 ID，未改產品權限或延長等待。

最終驗證結果：

- 聚焦 **26 項／3 suites 通過**（`/tmp/filicon-workflow-delete-focused-verified.log`）；包括 create/write 舊回歸、刪除生命週期、群組六種核准結果、mailbox recipient、history 重開與已捕捉執行。先前不依賴重開檔案的 fence／UI 聚焦 **8 項／2 suites 通過**（`/tmp/filicon-workflow-delete-fences.log`）。
- 完整 `swift test --no-parallel` **134 XCTest 與 929 Swift Testing／106 suites 全數通過**（`/tmp/filicon-workflow-delete-full.log`）。兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷保留，不代表真實帳號端到端驗收。上輪安全金鑰等待不穩定性沒有在本輪重現，未宣稱已根治。
- 原生 `Filicon App` clean build 通過（`/tmp/filicon-workflow-delete-native.log`），最後 schema 說明更新後再 build／deep strict codesign 通過（`/tmp/filicon-workflow-delete-native-final.log`），包含 helpers／XPC。僅 ad-hoc Debug 驗證，既有 AppIntents metadata／hardened runtime 提示仍在，未做 release 公證。
- 七語言各 **1,562 keys、零缺漏**；localization audit／`git diff --check` 通過。依 SwiftUI 技能調整共用核准元件，create/update/delete × 七語言 × 明暗共 **42 張** 420 點寬 fixture 預覽（`/tmp/filicon-workflow-delete-previews/`），刪除畫面每種語言至少檢視一張，未見裁切；不是全產品逐頁或 live App 驗收。

本批已在下一輪提交為 `4a994a4`，未 push、未啟動／重啟使用者 App 或 Xcode 工作程序，未操作真實資料／模型／外部帳號。`AGENT-01` 及其他 partial 保留。

## 已提交增量：受核准的自身工作流程建立／全文改寫（2026-09-21）

先提交上一批為 `d2ec81f`（`fix: drain process output before reporting completion`），提交前 **34 項／4 suites** 回歸通過。本輪核對本機非官方 reconstructed 的 `source/host/runner/tools/sand-state-tool.ts` 與 `source/host/extensions/memory/agent-state.ts`：原有 `update_state(target:"workflow",action:"write",name,description,body,id?)` 是可重用程序的建立／改寫，不是立即執行或 routine 排程。本輪補 Filicon-native 受限對應，未宣稱原版所有 workflow/state 能力均已還原。

- 群組與 mailbox 接上同一路由；host 綁定發起代理人，新建 ID 由 host 產生，改寫只接受自己的精確 native ID。名稱／說明／全文皆必填，分別最多 80 字元／1,536 字元／8,000 UTF-8 bytes；外圍空白裁除，名稱／說明換行正規化，body 中的 frontmatter 仍是純提示文字，不解析成權限或 trigger。
- 只允許自己擁有的本機、手動、單一 prompt 定義。未指定 owner／peer、source-linked 匯入、受管理的 learning workflow、多步驟／action／scheduled 定義拒絕；無來源標記且由使用者明確指派 owner 的匯入副本視為本機定義。新建為 enabled/manual；改寫保留 ID、owner、enabled、trigger、createdAt 和歷史。不支援 delete、enable/disable、source 路徑／URL、權限欄位或立即執行。
- 即使 auto-review allow 仍逐次顯示完整 before/after 核准。核准卡明示流程庫是本機工作區共享內容，**不是私人或帳號隔離記憶**；其他代理人及其模型、現有／未來 workflow 和 routine 可經引用取得內容，改名可能破壞名稱引用；已執行請求保留當時快照。列出已知直接引用總數與最多 100 個名稱／ID，僅為當下提示，不是完整或凍結的影響名單；不向請求模型回傳 peer 流程正文或引用清單。
- `AgentWorkflowStore` 在原子儲存內核對 library revision 及完整舊定義；同一 store 的任何成功修改（包含無關流程與相同值還原）都使待核准提案失效。這是 in-process fence，**不宣稱能協調其他程序或外部直接改檔**。Stop／帳號切換使用同步 lifetime fence；核准後重驗代理人未封存。與 profile／memory／avatar／routine 共用四次修改額度、pending reservation、精確重播、quota 與 durable receipt；儲存後記帳失敗仍如實回報已保存，沒有重複寫入。

依 Swift 測試／CustomDump 技能使用隔離目錄、固定 IDs／時間、受控核准 gate 與 fixture provider，先重現缺少路由的兩項紅測試。覆蓋群組 create/update 的批准／拒絕／停止／帳號切換／stale／封存共 12 種案例、mailbox recipient 身分、全文 metadata、同源保存／重開、來源／owner／步驟／trigger 保護、UTF-8／字數界線、frontmatter 純文字、pending duplicate、共用四次額度與晚到記帳錯誤。初版 App 重開測試誤比較未排序 dictionary JSON bytes，改為以持久化時間精度比較完整 workflow 值，未放寬產品斷言。

依 SwiftUI 技能將全文核准內容分離為元件，渲染 create/update × 七語言 × 明暗共 28 張 420 點寬預覽，每種語言各人工檢視至少一張；發現既有西文／韓文的通用 Enabled 翻譯不適用，改用本元件專用狀態翻譯。原生 clean build 首次發現新元件漏入 target，依 SPM／Xcode 技能補四筆專案參照，保留既有 target/scheme IDs，避免產生器全面重編號。需從 `Filicon.xcworkspace` 選 `Filicon App`，不是 package executable。

驗證結果：

- 初步含既有 workflow／profile／引用路徑的聚焦回歸 **29 項／5 suites 通過**（`/tmp/filicon-workflow-write-focused-final.log`）；新增精確上限、frontmatter、共用預算與相同值重設 revision 測試後，**12 項／2 suites 通過**（`/tmp/filicon-workflow-write-boundaries.log`）。後續語言調整再納入最後完整回歸。
- 首次完整執行 **918 Swift Testing／106 suites 通過，但 134 XCTest 中有一項失敗**：既有 `testRemoteProxySendsHelloHeartbeatAndHandbackCancelsCeremony` 的 waitUntil 回報 Condition did not become true（`/tmp/filicon-workflow-write-full.log`）。該 helper 只有 1,000 次 Task.yield 上限，且多個條件共用同一失敗行，日誌無法辨別是哪一階段；本輪沒有改該測試或安全金鑰程式，不能據此斷言產品錯誤或根因已消除。對使用者的首次「全套通過」摘要已更正。
- 最後以完整原始碼重跑 `swift test --no-parallel`，**134 XCTest、918 Swift Testing／106 suites 全數通過**（`/tmp/filicon-workflow-write-full-final.log`）；兩項 opt-in live Codex 測試未啟用，既有 CoreData NSXPC 診斷仍在。另單獨重跑安全金鑰 14 項 XCTest 全過（`/tmp/filicon-workflow-write-security-followup.log`）；重跑成功不代表上項等待不穩定性已根治。
- 原生 `Filicon App` **clean build 通過**（`/tmp/filicon-workflow-write-native-final.log`）；最後錯誤文字／描述調整再 build 與 `codesign --verify --deep --strict` 通過（`/tmp/filicon-workflow-write-native-verified.log`），包含 helpers／XPC。僅 ad-hoc Debug 驗證，既有 AppIntents metadata／runtime 提示保留，未做 release 公證。
- 七語言各 **1,558 keys、零缺漏**，localization audit／`git diff --check` 通過。核准元件預覽在 `/tmp/filicon-workflow-write-previews/`；修正後再檢視西文／韓文。這是新增元件的 fixture 渲染，不是全產品逐頁驗收或使用者 App 的 live 操作。

本批已在下一輪提交為 `a4e5d4c`，未 push、未啟動／重啟使用者 App 或 Xcode 工作程序，未操作真實資料／模型／外部帳號。`AGENT-01` 與其餘 partial 項目保留，不以本輪增量宣稱全功能完成。

## 已提交增量：本機程序輸出收尾與錯誤標記（2026-09-21）

先提交上一批為 `26d789c`（`feat: add scoped read-only search for approved agent memories`），提交前 **81 項／6 suites** 回歸通過。本輪處理上輪完整套件實際出現的 stdout 遺失：舊 `ProcessSupervisor.didExit` 先關閉 readability handlers／公布退出，而 bytes 還可能在等待 actor 接收的 Task 中，造成已完成的 snapshot 為空或之後又增長。本批為 native 執行可靠性修正，不新增原版雲端能力。

- 改為程序退出狀態與 stdout／stderr 的 EOF 都已交付後，才回報 `isRunning=false` 與 exitStatus。收尾期間仍可讀增量輸出，拒絕對已退出的程序送 stdin；完成後 output／offset 穩定，沒有晚到 bytes 回頭改寫終態。
- 新增 queue-confined `LocalProcessOutputReader`，使用 nonblocking dispatch source。每條管線一次最多一個 64 KiB 區塊，等 supervisor 接收後才續讀，EOF 不能超車；合併 10 MiB 上限與超限終止保留。只保證各管線內順序，不宣稱 stdout 與 stderr 有全域發生順序。取消時平衡 suspend/resume，取消 handler 關閉其擁有的 descriptor。
- 直接子程序退出後，若繼承管線的其他 writer 不關閉，最多安排一秒收尾等待，再停止收集並回報可能不完整的 `terminationError`；使用者 Stop 也可結束收尾，但錯誤理由與期限到期分開。已讀、等待交付的區塊先確認再送 terminal event。此階段不向已知退出的 PID／process group 發送訊號；一般尚在執行的程序仍沿用 TERM／KILL、原執行逾時與 run/generation 防護。不是任意背景子孫程序管理，也不保證收集期限之後的輸出。
- App 原先將含 terminationError 的 process JSON 當成功工具結果。現改為 `isError=true`，保留 partial bytes、offset、exit code 與診斷；逾時／超限／收尾失敗不再顯示為成功卡片。正常完成或單純非零 exit code 的既有結果契約不變。本批未變更 UI 版面、權限或使用者設定。

依 Swift 測試／SPM 技能，只在 local-tools 測試 target 加入專案既有 CustomDump，沒有新增 runtime 依賴。測試使用隔離目錄、固定 scope IDs、短命 fixture 程序與 continuation handshake：先修正新增測試的 async autoclosure 編譯錯誤，再用舊 supervisor 加入不改預設行為的時序 hook，確實重現 **7 個失敗斷言**（`/tmp/filicon-process-output-red-final.log`）。新版通過受控晚到 stdout/stderr、768 KiB 雙管線＋增量 offset、空輸出／提前關管線、期限／Stop、reader 取消不能超車、25 次快速退出與同 supervisor 的 12 個並行程序。另先重現 App **3 個錯誤標記失敗**（`/tmp/filicon-process-result-red.log`），再驗證四種 snapshot 保留完整 JSON 且錯誤標記正確。測試等待只用於觀察真實 I/O／期限，沒有用延長睡眠修補產品競態。

驗證結果：

- supervisor 聚焦 **20 項／2 suites 通過**（`/tmp/filicon-process-output-regression.log`）；含 App 錯誤映射／群組核准的擴大回歸 **33 項／4 suites 通過**（`/tmp/filicon-process-output-app-regression.log`）。其後新增的 12 程序並行隔離測試納入完整套件。
- 最終 `swift test --no-parallel` **134 XCTest、906 Swift Testing／104 suites 全數通過**（`/tmp/filicon-process-output-full-final.log`），兩項 opt-in live Codex 測試未啟用；既有 CoreData NSXPC 診斷仍在。本輪原有 stdin 測試、輸出上限、逾時與程序群終止均通過，沒有放寬斷言或省略失敗測試。
- 原生 `Filicon App` **clean build、deep strict codesign 通過**，包含 helpers 與 XPC（`/tmp/filicon-process-output-native-final.log`）；既有 AppIntents metadata／ad-hoc runtime 提示仍在。沒有執行 release 公證或啟動使用者 App。
- 七語言各 **1,545 keys、零缺漏**，localization audit 與 `git diff --check` 通過；本輪沒有新增 UI 標籤／版面，不宣稱全 UI 視覺驗收。

本批已在下一輪提交為 `d2ec81f`；未 push、未啟動／重啟 App 或使用者 Xcode 工作程序、未存取 live 模型。保留原有 parity partial 項目，不宣稱所有程序生命週期或原版能力已完整還原。

## 已提交增量：只讀搜尋未注入的已核准記憶（2026-09-21）

先提交上一批為 `7814a77`（`feat: recall relevant approved memories for current agent messages`），提交前 **55 項／5 suites** 回歸通過。本輪核對本機非官方 reconstructed 的 `host/runner/sand-memory.ts`：提示明確允許以 Read／Shell grep `profile.md` 與 `log/` 找未列出的舊事實。本輪提供 **Filicon-native `SearchMemory` 對應**，不是宣稱原版有同名工具，也不向模型開放 App 內部儲存檔案。

- 群組／mailbox 模型可主動搜尋目前帳號、自身私人與已明確核准的帳號共享事實。帳號和代理人由 host 綁定，先隔離再計算匹配、數量與分頁，不能傳入其他 agent/account/path。讀取不要求新的寫入核准，但不擴大既有分享；寫入／忘記仍走原核准流程。原文、scope、tier、日期、作者及 canForget 完整保留，搜尋不去重或修改記錄；讀到別人共享的事實不代表能刪除。
- `query` 最多 256 Unicode scalars，使用忽略大小寫／重音／全半形的字串子串比對；不是 regex、詞項相關性或語意搜尋。空／省略 query 可瀏覽，只有空白的 query 拒絕。scope 只接受 agent/user/all；每頁最多八筆完整事實，包含 metadata 的 JSON 不超過 8 KiB。過大事實整筆略過並回報本頁省略數，totalMatches 包含它們；游標仍前進，可從 editor 檢視，不截斷成錯誤事實。
- 續頁只接受 opaque cursor，綁目前 owner／run／session、原查詢／範圍及可見資料 fingerprint。選取範圍新增／刪除／變更即拒絕舊頁；其他帳號、私人 peer 或不在選取範圍的變更不影響游標。cursor 不快取事實。每次原始請求的代理人共用 32 次讀取額度，與四次修改核准額度分離；actor hop 前保留讀取額度，資料 actor 內驗 owner，回傳後重驗 Stop／session lifetime。封存或關閉後拒絕搜尋。
- 沿用 group/mailbox 的工具 metadata 投影：共用歷史只保留工具名稱／狀態，不加入原始私人搜尋結果。系統描述及結果仍將事實標示為不可信資料，禁止把事實當權限或擅自轉寄；這不代表模型最終文字已被自動隱私審查。三種錯誤補七語言 catalog；未變動 UI 版面。

依 Swift 測試技能使用隔離儲存、固定排序日期／ID、fixture model 與 CustomDump。先以未接線版本重現四項缺少 SearchMemory 的紅測試（`/tmp/filicon-memory-search-red.log`）；新增九項核心／工具測試及一項兩路徑 App 測試，涵蓋七語言、字串／scope 邊界、escaped UTF-8 預算、超大記憶、分頁／重播／失效／身份隔離、唯讀存檔 bytes、關閉／封存、32 次上限與獨立修改核准。App fixture 實際呼叫工具找出未注入的舊事實，並確認另一成員的請求與群組／mailbox 共用歷史沒有收到私人原文。不是 live 模型或跨平台帳號驗收。

驗證結果：

- 聚焦 **95 項／7 suites 通過**，包含記憶／核准／跨對話／App 整合及 LocalTools（`/tmp/filicon-memory-search-regression.log`）。最後將 cursor fixture 改為實際含有 query，確認「新事實不匹配查詢、但同 scope 仍使游標失效」；九項記憶搜尋測試再次全過（`/tmp/filicon-memory-search-scope-final.log`），產品碼未變。
- 首次完整回歸 134 XCTest 通過，897 Swift Testing 中既有 `stdinCanBeSentAndIsRejectedAfterExit` 一項失敗：預期 14 bytes 卻收到 0 bytes（`/tmp/filicon-memory-search-full.log`）。檢查 `ProcessSupervisor` 發現輸出以非同步 Task 入列，而 didExit 可先移除讀取 handler 並公布結束；這是尚未修正的輸出收尾時序風險，不能以稍後重跑通過宣稱根治。本批沒有修改該元件或放寬測試。
- 加入選取範圍／共享作者 cursor 測試後，非並行完整重跑 **134 XCTest、898 Swift Testing／102 suites 全數通過**（`/tmp/filicon-memory-search-full-final.log`）。兩項 opt-in live Codex 測試仍未啟用；既有 CoreData NSXPC 診斷仍在。
- 原生 `Filicon App` **clean build 及 deep strict codesign 通過**，包含兩個 helper 與 XPC（`/tmp/filicon-memory-search-native.log`）。既有 AppIntents metadata／ad-hoc runtime 提示仍在；未啟動 App。
- 七語言各 **1,545 keys、零缺漏**，localization audit 與 `git diff --check` 通過。沒有 UI 版面變更，也未宣稱全產品逐頁視覺驗收。

本批已在下一輪提交為 `26d789c`。`AGENT-01` 維持 partial：仍缺 project 記憶、自動抽取、任意 archive／檔案／語意檢索、其他執行入口及完整原版 persona/runtime；本輪未 push、未啟動／重啟使用者 App、未更動真實資料。

## 已提交增量：依當前訊息召回已核准的相關記憶（2026-09-20）

先提交上一批為 `3fc0d91`（`fix: validate connector event filters and enable safe editing`），提交前 **59 項／7 suites** 回歸通過。本輪核對本機非官方 reconstructed 的 `host/runner/sand-memory.ts`：`selectRelevantMemories` 以關鍵字重疊排序，`gatherExtractionMemories` 把相關 archive facts 加入記憶抽取輸入；`turn-memory.ts` 接上抽取，而 `memory-service.ts` 的一般 recall 仍以近期為主。因此這輪是 **Filicon-native 召回增強**，不是宣稱已完整還原原版的自動抽取或語意搜尋。

- `AgentMemoryQuery` 僅保留有界、去重的詞項，最多前 4,096 Unicode scalars／128 個詞項；一般字詞長度 2–64，排除部分英／法／西常見詞；漢字／假名／韓文使用相鄰雙字。忽略大小寫、重音與全半形，重複詞不加分；不是同義詞／翻譯／向量搜尋。超限不掃描完整長輸入，也不把截斷的半個詞當完整詞。
- scope／account 可見性先篩選，原有私人／共享與 foundational／recent 四個池、筆數／UTF-8 JSON bytes 預算、完整事實與來源 metadata 不變。同池優先字詞交集數，再用既有日期／note 重要性／固定 ID 排序；無相關詞時完全沿用原排序。正規化去重仍先保留最新原文及作者，不以相關性復活舊副本；太大事實整筆略過，不截斷或擠占其他池。
- 一般群組只取當前使用者訊息；群組間 peer wake 只取本次傳入訊息；mailbox／手動代理人訊息只取該封 inbound。工具值綁定 immutable query，不用共用的 last-query 狀態，不混入歷史、其他代理人答覆、圖片或檔案內容；不把原始 query 注入系統提示或寫入儲存。既有 owner／account／conversation／archived／Stop 與逐次修改核准保護保留。
- 按 Swift 測試技能使用固定日期／排序 ID、隔離存檔、fixture provider 與 CustomDump。核心涵蓋七語言例句、Unicode／詞項上限、去重與 escaped byte budgets；三條對話路徑先重現 **6 個失敗斷言**（`/tmp/filicon-memory-query-wiring-red.log`），接線後確認連續不同主題不串 query、舊歷史不影響召回、私人／跨帳號事實不漏出、共享事實保留且存檔 bytes 不變。另驗證同 session 的獨立工具 snapshot、錯誤 conversation、封存與停止後拒絕召回。

驗證結果：

- 接線聚焦回歸 **54 項／5 suites** 通過（`/tmp/filicon-memory-relevance-wiring.log`）；其後新增的獨立 snapshot／生命週期測試也納入下列完整回歸。
- 完整 `swift test --no-parallel` **134 XCTest、888 Swift Testing／101 suites** 通過（`/tmp/filicon-memory-relevance-full.log`），兩項 opt-in live Codex 測試未啟用。
- 原生 `Filicon App` **clean build 與 deep strict codesign 通過**，包含兩個 helper 與 XPC（`/tmp/filicon-memory-relevance-native.log`）；既有 AppIntents metadata／ad-hoc 提示仍在。僅建置／驗簽，不啟動使用者 App。
- 本批無 UI 或字串 catalog 變更；七語言各 **1,542 keys、零缺漏**，`git diff --check` 通過。沒有重新宣稱全 UI 視覺或 live 模型驗收。

本批已在下一輪提交為 `7814a77`；未 push、未啟動／重啟使用者 App、未更動真實聊天／群組／記憶或呼叫 live 模型。`AGENT-01` 維持 partial：仍缺 project 記憶、自動抽取、任意 archive search、其他執行入口及完整原版 persona/runtime。

## 已提交增量：通用連接器事件篩選的安全比對與手動編輯（2026-09-20）

上一批提交為 `fd0a334`（`feat: add validated GitHub and Slack routine editors`），提交前 60 項／7 suites 回歸通過。本批是 Filicon-native generic connector 的安全補強；不把它稱作 reconstructed 雲端能力還原，不增加 Teams 身分或外部帳號接線。

- 修正原本 JSON 解析失敗／非物件被視為 match-all 的錯誤，以及以 `String(describing:)` 比對造成的型別混淆。儲存與執行共用有界驗證：重複鍵（包含 escape 後相同鍵）、損壞資料、陣列／純量根、超限條件均拒絕，不丟棄篩選。舊損壞條件原樣保留，但其事件分支不匹配；其他有效 OR 成員或明確 Run Now 不受這個分支阻擋。
- 精確 connector UUID 與事件類型；所有最上層條件必須符合，巢狀物件完整比較且無關鍵排序，陣列保留順序，字串不做 Unicode 正規化，布林／數字／字串不互轉。十進位數字保留係數與指數，避免浮點捨入把不同長 ID 或高精度小數變成相同值；1、1.0、1e0 相等。空物件僅匹配同 connector/kind 的有效物件 payload，損壞 payload 不匹配。
- 限制明示為 filters 16 KiB、payload 1 MiB、根深度 0 至最大 16、含容器最多 4,096 個值、單一數字 256 字元／原始指數絕對值 10,000。event kind 為 1–128 字元、無控制字元或前後空白。不查名稱、不建立連線、不驗證 connector 是否在線；仍須既有事件來源。
- 原生新增與既有排程編輯共用草稿驗證，支援 generic 與已支援時間／平台條件的平面 OR，未改的 JSON bytes 保留。損壞的既有條件只可改名稱／任務，不能藉編輯靜默修復或放寬。沿用 revision、lifetime、原子儲存、取消／stale／磁碟失敗保護；模型 `update_state` generic create/update 仍明確拒絕。
- 依 SwiftUI 與測試技能，把驗證置於可測草稿與核心服務，使用 value binding、固定 ID／時間、隔離儲存、fixture executor 與 CustomDump 比較。最初測試程式的 async assertion 編譯錯誤已修正，再針對未修 matcher 實際重現 20 個失敗斷言（`/tmp/filicon-connector-filter-red.log`）。另外涵蓋 JSON 語法／UTF-8／escape／邊界、型別／精度／巢狀比對、persisted legacy、手動 OR 編輯／重開／去重／connector scope、App 儲存／取消／stale／磁碟失敗與模型權限不擴大。測試 fixture 曾把同 connector／同 delivery ID 用於兩種事件類型，觸發正確的既有去重；已改用不同 delivery ID，不修改產品的去重規則。

最終驗證：

- 聚焦回歸 **59 項／7 suites 通過**（`/tmp/filicon-connector-focused-final.log`）。
- 完整 `swift test --no-parallel` **134 XCTest、882 Swift Testing／101 suites 通過**，兩項 opt-in live Codex 測試未啟用（`/tmp/filicon-connector-full-final.log`）。既有 CoreData NSXPC 診斷仍在，未造成測試失敗。
- 原生 `Filicon App` **clean build 與 deep strict codesign 通過**，包含新 matcher、兩個 helper 及 XPC（`/tmp/filicon-connector-native-final.log`）；AppIntents metadata 與 ad-hoc runtime 提示仍在。
- NSHostingView 產生 generic 有效／空條件／重複鍵三態 × 七語言 × 明暗 **42 張**，完整 editor sheet 七態 **98 張**，另重跑既有預覽；驗證 fitting size，人工抽查七語言代表畫面與完整可編輯／唯讀 sheet。長表單可捲動，底部取消／儲存固定；產物 `/tmp/filicon-connector-previews/`，不是使用者 App 的 live UI 驗收。
- 預覽抓到舊選單 `Connector event` 在所有 catalog 皆未登錄，已補鍵與翻譯並納入斷言，JSON 欄位增加固定標籤；也修正本表單既有法／西／韓／繁中標籤。這說明僅 catalog key 對齊不代表全 UI 已翻譯。最終七語言各 **1,542 keys、零缺漏**，`git diff --check` 通過。

本批已在下一輪提交為 `3fc0d91`；未 push、未啟動／重啟使用者 App、未更動真實聊天／群組／排程／連線。`AUTO-03` 維持 partial：Teams 身分／主文／Graph／同步回覆與條件編輯、GitHub checks 彙整、Slack 名稱／人類身分映射及 live 帳號驗收仍未齊備。

## 已提交增量：GitHub／Slack 排程條件的安全新增與編輯（2026-09-20）

上一批已提交 `aa29b36`（`feat: safely edit existing routine definitions`），提交前再次通過 52 項／6 suites 聚焦回歸。本輪核對本機非官方 reconstructed 的 `sand-state-tool.ts` 與現行平台 matcher／ingress，補上既有 GitHub／Slack 排程的手動條件編輯，也收緊共用新增表單。

- GitHub 改為 14 種事件勾選、具體 owner/repo、單一精確 CI 分支及最多 50 個登入名稱。拒絕未知事件、空逗號項、無效分支／使用者、缺少分支的 CI，原始清單限制在去重前套用。不再依賴會丟掉條件的舊 initializer。說明明示個別 push workflow 完成不是 checks 彙整，CI 不套用使用者篩選；議題指派事件依目前 native 實作篩選操作人，不宣稱是受指派者。
- Slack 只接受 C/G/D 對話 ID 或 `*`，四種比對模式不再將未知值退回 message。關鍵字與表情使用獨立欄位，切換後保留並顯示不適用的篩選，要求明確清除；拒絕過長關鍵字、截斷對話 ID、無效／超過八個表情、空逗號項與會被有損轉換的 `::` 表情後綴。七語言說明明示 bot/app mention、既有連線與費用、不支援名稱／bySelf。
- 既有支援格式可編輯，並可與 cron／Linear／Sentry／PagerDuty 組成最多八項平面 OR。未改動的成員保留原值；名稱型 Slack、bySelf true、未知事件或不支援格式維持 trigger 唯讀，只能改名稱／任務，不放寬限制。沿用上一批原子 revision／lifetime 儲存，不新增外部授權或立即執行。
- 依 SwiftUI／測試技能，checkbox 使用 value subscript 的衍生 binding，邏輯留在可測草稿；以隔離目錄、固定事件時間／ID、fixture executor 和 HMAC 驗證資料測試，不呼叫真實模型。新增 12 項測試，包含 14 種 GitHub／四種 Slack 比對、原始輸入邊界、完整 round-trip、OR／history／時間錨點／重播、App 儲存／取消／stale／磁碟失敗與舊格式保留。先以三項紅測試重現 42 個失敗斷言，再修正；開發中另修正錯誤分類，並依 store 的 millisecondsSince1970 編碼邊界比較持久化日期，避免測試誤判次微秒往返差異。

驗證：

- 聚焦回歸 **60 項／7 suites 通過**：`/tmp/filicon-github-slack-focused-final.log`。
- 非並行完整回歸 **134 XCTest + 873 Swift Testing／99 suites 通過**；兩項 opt-in live Codex 測試仍未啟用：`/tmp/filicon-github-slack-full.log`；測試程序仍有 CoreData NSXPC 診斷訊息，未造成測試失敗。
- 原生 `Filicon App` **clean build 通過**，`codesign --verify --deep --strict` 驗證 App、兩個 helpers 與 XPC 通過：`/tmp/filicon-github-slack-native.log`。既有 AppIntents metadata／ad-hoc runtime 提示仍在。
- NSHostingView 產生 GitHub／Slack／不相容條件三態 × 七語言 × 明暗共 **42 張**，完整 editor sheet 五態共 **70 張**，另外重跑既有平台 84 張；驗證 fitting size，人工抽查各語言和唯讀狀態、修正後再渲染。表單可捲動，取消／儲存固定於底部。產物：`/tmp/filicon-github-slack-previews/`，不是使用者 App 的 live UI 驗收。
- 七語言各 **1,537 keys、零缺漏**。視覺檢查發現並修正舊有法文 CI 分支、韓文比對／關鍵字／提及／表情，以及相關六語言欄位標籤。新增明確翻譯回歸斷言。`git diff --check` 通過。

本批已在下一輪提交為 `fd0a334`；未 push、未啟動／重啟 App、未更動真實群組／聊天／排程／連線。`AUTO-03` 維持 partial：當時 Teams／generic 條件專用編輯、Teams 可信身分／主文／Graph／同步回覆、GitHub checks 彙整、Slack 名稱／人類身分映射及 live 帳號驗收仍有差異。

## 已提交增量：既有排程的手動編輯與儲存生命週期（2026-09-20）

上一批已提交 `f874dcd`（`fix: add validated platform event menus for new routines`），提交前再次通過 59 項／6 suites 聚焦回歸。本批補自動化清單的「編輯」入口，不更動外部連線或立即執行排程。

- 支援名稱、任務內容與 cron／interval、canonical Linear／Sentry／PagerDuty 及其最多八項平面 OR 條件。其他平台、legacy／unknown／含不支援成員的組合，只能改名稱與任務內容，原始 trigger 唯讀保留。未變動的成員保留 nil 時區、UUID 大小寫及精確 ID 等原有值，不因只改另一分支而重寫。
- 服務層在同一 actor turn 比對原始定義／revision 並原子寫入；編輯期間新執行紀錄、wakes、claims、費用保護和現行 runtime 欄位保留，不接受草稿夾帶 owner／enabled／guardPaused／revision／createdAt 變更。只改名稱／任務／事件篩選，不重設未改動的時間條件；改動時間條件則從儲存時間重算，下次時間仍尊重停用及費用暫停。
- 執行中的工作沿用啟動時任務，完成後保留新定義與新排程。儲存不是 Run Now；已入列事件可能符合新條件並產生模型費用。取消／關閉、帳號切換、封存 owner 撤銷未提交寫入；另一處修改、停用再啟用、刪除或費用保護變更會拒絕 stale 草稿。磁碟寫入失敗不公布假成功，草稿留在編輯視窗；已持久化的收據和後續 quota 記帳錯誤分開處理。
- 依 SwiftUI 技能分離可測草稿、欄位和儲存動作；沿用既有 lifetime／quota，不新增依賴或自造 Binding。新增八個七語言文字項目，人工檢查時修正日／韓「指令」、法／西／韓「排程」及韓文「時區」既有誤譯。七語言各 1,520 keys、零缺漏不等於全產品翻譯品質保證。

依 Swift 測試技能使用隔離目錄、固定識別／時間、受控 executor 與 continuation handshake，新增 `ManualRoutineEditTests` 11 項及 `RoutineEditAppTests` 七項，涵蓋執行進度／歷史保留、執行中編輯、無變更、時間重新計算、stale／不可變欄位繞過、取消／帳號／封存、寫入失敗重試、未知格式保留、App 儲存和七語言。聚焦回歸 **52 項／6 suites 通過**（`/tmp/filicon-routine-edit-focused-final.log`）。NSHostingView 產生三種完整 sheet 狀態 × 七語言 × 明暗，共 42 張，驗證 fitting size，並人工抽查每種語言代表圖；長表單保留原生捲動、取消與儲存固定在下方。產物在 `/tmp/filicon-routine-edit-previews/`，不是使用者 App 的 live UI 驗收。

完整回歸：鎖定時擴大並行回歸的四項既有頭像／記憶測試失敗；非並行完整測試雖通過 134 XCTest，Swift Testing 在 agents／workflows 等受保護檔案重開時回報 Cocoa 257／EPERM，後續既有跨對話測試的索引越界使 helper 中止（`/tmp/filicon-routine-edit-focused.log`、`/tmp/filicon-routine-edit-full.log`）。隔離重跑同樣失敗，不是已證實的並行 flake；IORegistry 當時明確回報 `CGSSessionScreenIsLocked=Yes`。未削弱 `.completeFileProtectionUnlessOpen`、未跳過測試；系統解除鎖定旗標後，完整 `swift test --no-parallel` **134 XCTest、861 Swift Testing／98 suites 全數通過**（`/tmp/filicon-routine-edit-full-unlocked.log`），受保護檔案重開及後續索引越界未再出現。兩項 opt-in live Codex 測試未執行；既有 CoreData/XPC 診斷仍存在。不宣稱更早的並行時序問題已修好。

原生驗證：最初 Debug build 與嚴格簽章通過；最終三語言標籤更新後，增量 build 成功但 `codesign --verify --deep --strict` 回報 ko／es／fr 資源與舊 seal 不一致。同一隔離 DerivedData 執行完整 `clean build` 後，**原生 Debug build 及嚴格 deep／strict 簽章皆通過**（`/tmp/filicon-routine-edit-native-clean.log`）。未修改使用者 Xcode 產物或宣稱增量簽章問題已根治；既有 AppIntents／ad-hoc 提示仍在，未執行 release 公證。

本批已在下一輪提交為 `aa29b36`；未 push、未啟動／重啟 App、未更動真實群組／聊天／排程／連線。當時 `AUTO-03` 維持 partial：GitHub／Slack／Teams／generic 條件專用編輯、Teams 可信身分／主文／Graph／同步回覆、GitHub checks 彙整、Slack 名稱／人類身分映射及 live 帳號驗收仍有差異。

## 已提交增量：手動新增 Linear／Sentry／PagerDuty 排程（2026-09-20）

上一批已提交 `4222c64`（`fix: preserve safe retries and revoke stale webhook admissions`），提交前再次通過 87 項／10 suites 聚焦回歸。接著核對本機非官方 reconstructed 參考 `source/host/runner/tools/sand-state-tool.ts` 與現行 `PlatformTriggers.swift`：手動建立表單仍接受任意 Event，預設 issue-updated／issue-created／incident-triggered 與受支援的 canonical case 不一致，且缺少新狀態／週期篩選欄。

- 自動化 → 新增排程：三種平台改用事件選單，Linear 三種、Sentry 六種、PagerDuty 五種選項。預設改為 issueCreated／issueCreated／incidentTriggered，實際傳入的 case 與 ingress 相同，不再讓 arbitrary allowedEvents 自我驗證。
- Linear 明確區分 team/project/new-status/cycle UUID；Sentry 使用精確十進位 project ID；PagerDuty 使用精確且區分大小寫的 service ID。每欄原始清單最多 50 筆、先驗證再去重；UUID 正規化大小寫，但十進位前導零和服務 ID 大小寫保留。空白欄表示不限，逗號空項、未知 case、無效／超限／不適用的篩選拒絕建立，畫面顯示本地化錯誤。Linear 切換事件時保留現有篩選欄，讓使用者清除不相容條件，不暗中放大範圍。
- 依 SwiftUI 技能將驗證留在可測草稿層，事件欄位依狀態呈現；沒有自造 Binding。七語言新增 22 個文字項目；品牌名稱保留 Linear／Sentry／PagerDuty，修正表單內西文／韓文 Trigger 翻譯。說明明示現有驗證入口、ID 不是名稱、空欄不限、週期完成不等於日期到期，以及未來模型費用；不安裝帳號／webhook、不授予工具權限。

依 Swift 測試技能使用固定時間／識別、隔離檔案及受控 executor。新增 `RoutineListenerEditorTests` 八項測試，涵蓋所有選項的真實 HMAC fixture → normalizer → 草稿 matching、精確反例、0/50/51 原始筆數、空項、UUID／數字／opaque ID 邊界、不適用欄位保留、JSON round-trip、儲存／重開／混合 OR 一次執行／重試去重、legacy 定義不被遷移。首次測試確認缺少 132 項非英文翻譯斷言，加入 catalog 後通過；此為新增翻譯的紅燈證據，不宣稱已對舊表單跑完整 red suite。

聚焦回歸 **59 項／6 suites** 通過（`/tmp/filicon-case-editor-focused.log`）。最終完整 `swift test --no-parallel` **134 XCTest、843 Swift Testing／96 suites** 通過（`/tmp/filicon-case-editor-full-final.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build 與 `codesign --verify --deep --strict` 通過（`/tmp/filicon-case-editor-native-final.log`）；既有 CoreData/XPC 診斷及 AppIntents/ad-hoc signing 提示仍在，沒有測試失敗。

NSHostingView 以 440 pt 寬渲染六種表單狀態 × 七語言 × 明暗兩種外觀，共 84 張；包含保留不相容篩選的錯誤態，驗證 fitting size，人工抽查各語言的代表畫面並修正品牌翻譯。產物在 `/tmp/filicon-case-editor-previews/`，不是操作使用者 App 的 live UI 驗收。七語言各 **1,512 keys、零缺漏**，`git diff --check` 通過。

本批已在下一輪提交為 `f874dcd`；未 push、未啟動／重啟使用者 App、未更動真實群組／聊天／排程／連線。`AUTO-03` 維持 partial：當時尚無既有儲存排程的專用手動編輯表單；Teams 可信使用者／主文／Graph／同步回覆、GitHub checks 彙整、Slack 名稱／人類身分映射及實際帳號端到端驗收仍有差異。

## 已提交增量：共用事件入口的安全重試與接收生命週期（2026-09-20）

上一批 Teams 入口修正已提交 `dbd8505`，提交前再次通過 156 項聚焦回歸（`/tmp/filicon-teams-events-precommit.log`）。本批檢查共用 ingress → TriggerHub → EventBatcher 接線，補上入列拒絕、停用／移除路由及 listener 重建時的處理，不擴充外部帳號權限或 Teams 雲端功能。

- sink 明確拒收時，原先已寫入的 nonce 會被安全釋放，HTTP 503 後仍可在簽章有效期間重試；初次 nonce 儲存失敗不呼叫 sink，並回復記憶體。若釋放 nonce 寫入失敗，保留標記並回 500，維持有界防重放。已接受事件即使後續 state／audit 寫入失敗也不釋放，不能誤認為未交付再跑一次。
- 入列交接中的 nonce 不因時間窗到期而被其他請求清掉；接受後從完成時間更新 replay window。保留入列前落盤的保守邊界，但佇列仍在記憶體，崩潰在保留標記與交接之間是未知結果，不自動重播，也不保證 crash-safe／exactly-once／永久去重。
- 金鑰查詢返回後，以當下時間驗證適用的簽章時間戳，並重驗 route revision 和 listener generation。停用、移除、換 provider／secret reference，甚至停用再啟用／移除再加入相同定義，都使舊待處理請求失效；其他路由的修改不受影響。route 儲存失敗回復舊定義。Stop／rebind 也拒收舊 connection 尚未交付的請求、忽略舊 listener callbacks；已開始交接的工作不宣稱撤回。
- 佇列身份採 connector ID＋external event ID，不再讓不同連線同名事件互相擋掉。已驗證且重新簽署、同連線同事件的待處理副本回成功，不再混同容量不足；滿 500 筆時副本仍可確認但不增加筆數。batcher 原有公開 enqueue 回傳「是否新增」的契約保留，由 hub 區分 duplicate 與 full；既有簽章、防重放、流量、payload 限制及 25 筆分批不變。成功回應僅表示入列，不代表排程或模型已完成。

依 Swift 測試技能使用固定時間、精確 fixture IDs、隔離目錄、受控 secret／sink 與 continuation handshake，沒有依靠 sleep 猜測競態。新增 `IngressAdmissionTests` 13 項／21 個參數展開案例，先重現原有 39 個斷言失敗（`/tmp/filicon-ingress-admission-red.log`）。包含初次保留／釋放／audit 儲存失敗、重開、防重播、延遲金鑰與 timestamp 過期、跨時間窗的 pending nonce、八種路由／listener 變更、無關路由、舊 connection、Stop 在 handoff 後的界線，以及真實 hub 滿佇列重試。

原有增量建置產物曾在測試 helper 發生 SIGILL／SIGBUS，堆疊位於變更後的 actor 介面；未以略過測試處理。新建隔離 scratch 目錄 `/tmp/filicon-ingress-admission-build.lShcvK` 完整重建後，28 項／3 suites 聚焦回歸通過（`/tmp/filicon-ingress-admission-clean.log`）；其後包含七種平台與混合事件的並行回歸 **87 項／10 suites 通過**（`/tmp/filicon-ingress-admission-regression.log`），未再出現崩潰。此結果支持舊增量產物相關，不宣稱已根治 SwiftPM 快取問題，也未清除使用者既有建置目錄。

完整 `swift test --no-parallel` 為 **134 XCTest、835 Swift Testing／95 suites 通過**（`/tmp/filicon-ingress-admission-full.log`）；兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build 與 `codesign --verify --deep --strict` 通過（`/tmp/filicon-ingress-admission-native.log`），七語言各 1,490 keys、零缺漏，`git diff --check` 通過。仍有既有 normalizer 的 optional-to-Any 編譯警告、CoreData XPC 診斷與原生 AppIntents／ad-hoc 提示；不宣稱修復所有並行時序問題。本批未變更 UI，未宣稱全產品逐頁語言或 live 平台驗收。

本批已在下一輪提交為 `4222c64`；未 push、未啟動或重啟使用者 App、未更動真實群組／聊天／資料／排程／連線。`AUTO-03` 維持 partial：Teams 可信使用者／主文判定／Graph 接線與同步回覆、GitHub checks 彙整、Slack 身分／名稱映射等仍未完整還原。

## 已提交增量：Teams 傳出事件安全判定與去重（2026-09-20）

上一批 Linear 週期提案已提交 `054d8d3`。此輪核對 reconstructed 的 `sand-state-tool.ts`（Graph team IDs）、`automation-trigger.ts`（登入條件需要 platformMatched；未設文字篩選時排除 rootMessageId 回覆）、`sand-automation-cloud-trigger.ts` 及 `sand-automation-fire-consumer.ts`（雲端已分類的通知與有界欄位）。現有 macOS HMAC 傳出 webhook 不能冒充該雲端服務。

2026-09-20 查閱 Microsoft [outgoing webhook](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-outgoing-webhook)、[TeamInfo](https://learn.microsoft.com/en-us/javascript/api/%40microsoft/agents-hosting-extensions-teams/teaminfo?view=agents-sdk-js-latest) 與 [Activity protocol](https://github.com/microsoft/botframework-sdk/blob/main/specs/botframework-activity/botframework-activity.md)。文件的 HMAC 驗證通訊；aadGroupId 與 Bot team ID 分開；replyToId 為可省略欄位。據此採以下保守適配，並非 live 帳號驗收：

- 不再把簽章、from.aadObjectId 或 payload 的 authenticated/platformMatched 當 Filicon 使用者登入證據。原生入口沒有可信使用者映射，blockUnauthenticatedUsers 為 true 時一律不匹配，舊佇列的 authenticated=true 也不能通過。沒有改寫或放寬既有定義。
- Graph UUID 篩選僅使用 channelData.team.aadGroupId，缺少時不從 Bot ID 或名稱猜測；舊 Bot ID 保留 teamId 精確比對，另存 graphTeamId。租戶／Graph UUID 正規化大小寫，Bot／channel ID 保留原字串。
- 僅分類具有 type=message、channelId=msteams、conversationType=channel 與有效 tenant/team/channel/conversation/sender/activity ID、最多 4,000 字元文字的活動；編輯／刪除／invoke／typing／其他 type、非頻道與缺欄上下文不啟動排程。明確 bot role 排除，但沒有把缺少 role 解讀成已驗證的人類登入。
- reference 空文字篩選只接受主文；原生 replyToId 缺省無法證明主文，也不解析不透明 conversation ID 猜測。目前即使既有條件明確允許未登入者，仍須非空 substring/regex 文字篩選，這類 reference 規則可接受回覆。未加入 Graph 根訊息查詢或全部頻道訂閱。
- HMAC 仍驗證 raw body，接受 base64 或已解碼金鑰，body digest 仍作 ingress nonce。支援訊息的事件 ID 另外 hash tenant/Bot-team/channel/conversation/activity；重新簽章、改 timestamp 或增減可選 Graph metadata 不改身分；不同頻道／對話／活動分開，既有 connector scope 保留。無效或超長 activity ID 拒絕而非截斷。超過 replay cache 後仍由保留的 history 去重，但兩者都過期後並非永久防重放，沒有簽章時間戳證明新鮮度，沒有遷移舊 receipts。

**目前手動 Teams 編輯器仍保留 blockUnauthenticatedUsers 預設 true，因此其中的 Teams 事件條件不會執行。** 畫面已明示此限制，文字欄改標必填；OR 中的其他 listeners／明確 Run Now 不受此事件判定影響。未增加放寬權限開關，Teams 模型 routine create/update 仍拒絕。後續須完成可信身分／主文事件接線及完整核准，不能把這批稱為 Teams 全功能可用。

依 Swift 測試技能，以固定時間、隔離目錄、測試 secret/executor 和 CustomDump 重現錯誤再修正；新增八項 Teams 測試，涵蓋六種非訊息 type、舊登入旗標、Graph/Bot namespace、篩選、缺欄／超限、回覆／未知根、簽章篡改、同 ID 重新送達、重開／cache 過期後 history 去重及預設政策保留。更新舊 fixture，避免其把 HMAC 錯當登入。依 SwiftUI 技能，把提示抽成不含業務邏輯的元件並補兩項 localization／render 測試；七語言、明暗共 14 張、440 點寬預覽，驗證 fitting height，每種語言各人工檢視一張未見截斷（`/tmp/filicon-teams-review.JDWLc0/`）。不是全產品 UI 逐頁驗收。

驗證：156 項 Swift Testing／13 suites 聚焦回歸通過（`/tmp/filicon-teams-events-regression.log`）；`swift test --no-parallel` 完整回歸為 **134 XCTest、822 Swift Testing／94 suites 通過**（`/tmp/filicon-teams-events-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-teams-events-native.log`）與 `codesign --verify --deep --strict` 通過；七語言各 1,490 keys、零缺漏，`git diff --check` 通過。新元件的並行警告已消除；仍有既有 CoreData XPC 診斷及原生 AppIntents metadata／ad-hoc runtime 提示，未宣稱修好先前並行測試時序問題。此為隔離 fixture／原生建置驗證，不是 live Teams 或 release 公證驗收。

本批已在下一輪提交為 `dbd8505`；未 push、未啟動或重啟使用者 App、未改實際聊天／群組／資料／排程／連線。`AUTO-03` 維持 partial，仍缺 Teams 身分映射／主文判定／Graph subscription／模型提案與 outgoing webhook 同步回覆的帳號端到端驗收，以及既有 GitHub checks 彙整、Slack 名稱／人類身分映射等差異。


## 已提交增量：Linear 週期完成的自身排程提案與完整核准（2026-09-20）

上一批已提交為 `ddf7587`。再次核對 reconstructed `sand-state-tool.ts` 的 endOfCycle／cycleIds shape 與 `shared/automations.ts` 三種 Linear cases，接上群組及 mailbox 的自身 routine create/update，可單項或與 cron／GitHub／Slack／Linear issue／Sentry／PagerDuty 組成最多八項平面 OR。這是原生完成事件的受核准提案，不是新增雲端連線或還原原版全部平台語意。

- cycleIds 僅用於 endOfCycle，statusIds 僅用於 statusChanged；原始清單最多 50 個精確 UUID，先驗證再正規化大小寫、排序去重。省略／空清單表示不限。原生 Cycle 無 project 關聯，因此非空 projectIds 拒絕，省略或空清單才可用；不猜測專案、不丟棄指定條件。schema 列出三種互斥 event shape 並說明 project 限制，解析器與核心再次驗證，拒絕 null、未知欄位、錯誤型別、不適用／無效／超限篩選；混合組內任一無效即整份拒絕。
- 沿用固定 owner、完整 before/after 任務／trigger／enabled／時區核准、四次共用變更預算、50 筆容量、durable receipt、原子儲存、Stop／帳號切換／stale／費用防護。模型不能自行解除保護、取得新工具權限或要求立即執行；修改與核准恢復保留歷史，不自動啟用舊資料，legacy cycle entity 不得被模型暗中轉成完成事件。
- 成功回條、runtime 與七語言核准說明明示既有驗證入口、不安裝／啟動連線、completedAt 的明確完成轉換（含提前完成）、日期到期本身不觸發、精確 UUID 和專案限制、有限防重播及佇列事件／模型費用。沒有新增 poller 或手動 cycle 編輯器。

依 Swift 測試技能採固定時間、隔離目錄、受控 provider／核准 gate 與 CustomDump。先重現兩項測試中的 18 個提案／schema 失敗（`/tmp/filicon-cycle-proposal-red.log`），新增 cycle create／恢復與 legacy 保護測試，擴充 0/50/51 UUID 邊界、case 專屬欄位、核心繞過、大小寫與重複收據、歷史保留、取消／拒絕／儲存失敗／費用／容量矩陣。群組為 18 情境 × 四種結果（72 案例），mailbox 為 18 情境並驗證 recipient owner；混合 fixtures 同時含 Linear issue 和 cycle，不讓其中一項被覆蓋。

依 SwiftUI 技能，安全判斷留在 service/parser，畫面只顯示 host 的核准定義。固定 380 點寬度完成 21 情境 × 七語言共 147 張預覽，並驗證 fitting height（`/tmp/filicon-cycle-proposal-review.XV0tRi/`）。實際檢視繁中 cycle update、法文 cycle create、繁中七項混合 OR 預覽，未見截斷；不是全產品逐頁或每張語言圖人工驗收。各語言 1,488 keys、零缺漏。

驗證：146 項 Swift Testing／12 suites 聚焦回歸通過（`/tmp/filicon-cycle-proposal-focused.log`）；明確 `swift test --no-parallel` 完整回歸為 **134 XCTest、812 Swift Testing／93 suites 通過**（`/tmp/filicon-cycle-proposal-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-cycle-proposal-native.log`）、產物 `codesign --verify --deep --strict`、localization audit 及 `git diff --check` 通過。仍有既有 CoreData XPC 診斷及 ad-hoc runtime 提示；未宣稱修復先前並行時序問題，也不是 live Linear 帳號或 release 公證驗收。

本批提案增量已在下一輪提交為 `054d8d3`，提交前再次通過 146 項聚焦回歸（`/tmp/filicon-cycle-proposal-precommit.log`）。未 push、未啟動或重啟使用者 App，未更動真實群組／聊天／排程／連線。`AUTO-03` 維持 partial：平台專用編輯器、原版雲端專案關聯、GitHub checks 彙整、Slack 名稱／人類身分映射等仍有差異，不能將本批稱為「原版都有了」。

參考來源為非官方 `grok-bot-0.18-reconstructed`，不是官方產品原始碼。
此表只涵蓋已讀過來源且對照現行接線的協作功能；未涵蓋功能不能推定完成。

| 行為 | reconstructed 證據 | Filicon 現況與驗證 |
|---|---|---|
| 群組接續、角色、PASS、取消 | `source/host/groups/`、群組 runner | 已接線，`GroupCollaborationTests`；保留三輪／十則上限 |
| 向使用者明確發訊 | `source/host/extensions/transcript/send-message-shaping.ts`、`agents/agent-messaging.ts` 的 SendMessage 區分 | 已接線 `AgentUserMessageTool`：一般群組可發布本輪使用者點名給自己的圖片，mailbox/peer wake 可發布本次 incoming 圖片，均需文字與獨立預覽核准。群組直接原子保存 room reply；mailbox 先保存發布紀錄，再鏡射來源 UI。Stop／失敗／重啟保留已發布內容，最多兩則、final 不重複；不新增回覆者或自動重送圖片給其他模型。不等於完整圖片來源。`AgentUserMessageToolTests`、`AgentBackgroundExecutionTests`、`AgentImageMessagingTests`、`AgentImageAppIntegrationTests` |
| 非同步單一同伴委派、回信喚醒 | `source/host/extensions/transcript/agent-to-agent-messaging.ts` | 已有 `SendToAgent` → durable mailbox → wake → reply wake；新委派顯示完整 payload approval |
| 手動訊息執行 | 同一 inbound wake 機制 | 「代理人 → 訊息」Send 已接上真實 ToolLoop，不再只存信；頁面不必保持選取；審批、資料夾選擇、取消都沿用 host 路徑 |
| 上下文跨次請求／重開 | `resolveBackgroundSession`、agent transcript store | **部分**：account/origin/agent 隔離的 30 則 peer 上下文與穩定 inference ID 已落盤；另有逐次審批的 account/agent 持久事實（見 memory 列），不隨 origin 隔離。不是原版橫跨所有 DM／群組的統一私人上下文或完整長期背景 session |
| 每 agent 統一 exclusive lane | `runLifecycle.enqueueExclusiveRun(session.id, …)` | 已接上 App 內共用 `AgentExecutionScheduler`：群組回合、跨來源 mailbox、子任務、自動化、工作流程、頻道回覆共用每 agent 一般工作 FIFO（優先訊息例外見下列）；不同 agent 可並行。`AgentExecutionSchedulerTests` 與 `AgentBackgroundExecutionTests` 驗證排隊、取消、逾時與主要 App 入口。**不是完整原版 runtime**：未綁定 agent profile 的一般單獨聊天仍只按 conversation 排程；不包含跨程序協調或重啟排程重播；有限優先中斷見下列 |
| 群組目標／broadcast | `source/host/extensions/transcript/shared-rooms.ts` 的 `postToGroup`；`agents/agent-messaging.ts` directory | **已接線受限文字版**：群組／mailbox 的 `SendToAgent` 接受自己所屬、所有成員均啟用中的其他群組 UUID。完整成員、群組與文字審批後原子貼入共用房間，再讓其他成員用既有群組 runner 回覆；不是逐人私訊。來源對話私人上下文不轉貼，工具仍沿用來源核准範圍與新 run ID。每次最多兩個不同群組／六次總委派，群組各保留三輪／十則上限與每回合 180 秒期限。**與參考的差異**：忙碌群組拒絕而非排入其 active lane；目前房間使用 SendMessage；發起者不因自己的貼文再自動喚醒；不含跨所有房間的統一私人記憶。`AgentGroupMessagingTests`、`AgentGroupMessagingAppTests` |
| 圖片訊息 | `loadAgentInboundImages`／`selectedImages`、`agents/agent-messaging.ts` 的 images；`shared-rooms.ts` 的四張限制與 `send-pipeline.ts` 的選圖路徑 | **已接線受限版本**：代理人 → 訊息及一般群組輸入均可手動選擇 PNG/JPEG，實際位元組傳入支援看圖的收件模型。群組預覽揭露保存／模型收件範圍，依本輪使用者 @mention 選擇成員；全部指定模型通過驗證才貼文，失敗保留草稿。`SendToAgent(images:[id])` 只能轉交本次收到的 peer 圖片，或 host 指定且使用者本輪點名給自己的群組圖片；每次顯示收件人、文字與圖片重新預覽核准，回信及同群組成員也不豁免。`SendMessage` 可將這些圖片另行審批後發布到來源對話，群組核准卡揭露房間與完整成員，不擴大模型收件者。拒絕任意路徑、網址、base64 與其他訊息的 ID。最多四張／單張 5 MB／合計 12 MB，存為雜湊驗證的獨立 blobs。**尚缺**：參考的 file/HTTPS 圖片來源、模型新產生的圖片、歷史圖片自動重播。`SendToAgent` 群組目標附圖仍明確拒絕；不支援看圖的模型明確失敗，不默默丟棄圖片。`AgentImageMessagingTests`、`AgentImageAppIntegrationTests`、`GroupImageAppTests`；本輪群組發布的驗證狀態見文末 |
| 優先訊息中斷非使用者工作 | `steerRecipientForPriorityPeer`，先檢查 active lane != user | **已接線受限版本**：單一 peer 的 `priority:true` 每次須核准（回信也不豁免），manual Priority 也接上排程。來源回合結束並 drain 後，可取消收件者正在執行的背景 peer／委派群組回覆／排程自動化，等 host 工具清理完才啟動優先工作。排隊中的使用者工作及較早優先訊息不被插隊；前景群組、手動 mailbox 首回合、手動 Run Now、channel／workflow／subtask 均受保護。不自動重播被中斷工作；群組 priority 拒絕。**差異**：不是參考的 enqueue 當下立即中斷，保護範圍更保守。`AgentExecutionSchedulerTests`、`AgentMessagingSessionTests`、`AgentBackgroundExecutionTests` |
| 模型建立／編輯代理人 | `source/host/agents/agent-messaging.ts`: CreateAgent、UpdateAgent | **已接線受限版本**：群組、手動 mailbox 與 peer wake 提供 `CreateAgent(name, description?)`／`UpdateAgent(agent_id, name?, description?)`。每次完整顯示變更並明確核准；每個來源請求共用四次上限。新代理人沿用發起者 provider/model，description 成為公開摘要與初始指令；Update 只合併名稱與公開摘要，不修改私人指令。`AgentManagementSessionTests`、`AgentManagementAppIntegrationTests`。不替未綁定 agent 的一般 DM 加上管理權限 |
| 模型修改自身公開資料 | `source/host/runner/tools/sand-state-tool.ts` 的 `update_state` profile/set；`source/host/extensions/memory/agent-state.ts` 的 `updateProfile` | **已接線受限版本**：`update_state(target:"profile", action:"set", name?, description?)`。身分由 host 固定；不得傳入別人的 ID。可明確清空公開 description，省略欄位保留原值；私人 persona 不變。每次仍需使用者核准，與 CreateAgent／UpdateAgent、memory、avatar 及 routine 變更共用四次上限。下一個群組回合重新載入 profile，原請求參與成員不擴大。memory／avatar 支援範圍見其他列；routine 支援下列有限 create/update/pause/resume/delete；workflow 已補下列受限 write/delete；settings 已補下列受限通知開關；側欄顯示／channel／project 路由仍缺 |
| 模型修改自身通知設定 | `sand-state-tool.ts` 的 settings/set；`agent-state.ts` 的 updateSettings | **已接線受限版本**：只接受 `target:settings,action:set,notify_on_updates:boolean`，host 固定自身 ID。逐次明確 before/after 核准，與其他修改共用四次上限；專用持久化 revision 防 ABA 與舊 editor 覆蓋，Stop／帳號切換同步撤銷。UI Agents → Edit 可手動開關並儲存。僅控制 agent roster 完成／等待輸入系統通知，不關對話通知、核准卡、未讀／Dock，也不影響任務與權限；舊資料預設開啟、不補送通知，macOS delivery 權限仍必要。本機共用 profile，非 account-scoped。**未還原 hidden_from_sidebar**；其他欄位／混合提案一律拒絕，不混用封存。不是跨程序 CAS。 |
| 模型建立／改寫／刪除自身工作流程 | `sand-state-tool.ts` 的 workflow/write/delete；`agent-state.ts` 的 writeWorkflow/deleteWorkflow | **已接線受限版本**：own local manual single-prompt 的 create/full rewrite，名稱／說明／全文必填，body 最多 8 KiB 以下的 8,000 UTF-8 bytes；逐次全文核准、共享引用影響揭露、同 store revision／取消防護。無來源且經使用者指派 owner 的匯入副本視為本機定義；來源連結／learning／peer／多步驟／action／scheduled 拒絕。儲存不執行、不授予權限；delete 另走同樣 own/local/manual/single-prompt 上限、精確 ID 與獨立 destructive 核准，保留 run history 與已取得內容的執行，不連帶刪除其他流程／排程／檔案；引用可能失敗或省略內容。其他 workflow 操作仍未全面還原，不能視為帳號隔離記憶。 |
| 模型修改自身頭像 | `source/host/runner/tools/sand-state-tool.ts` 的 avatar set/clear；`source/host/extensions/memory/agent-state.ts` 的 setAvatar/clearAvatar | **部分接線，來源不同**：群組／mailbox 可呼叫 `update_state(target:"avatar", action:"set", pet_id:...)` 選九種內建小寵物，或 `action:"clear"`（不得附 pet_id）恢復 Codex。每次顯示新頭像與原頭像類型並核准；只可改 host 固定的自身 ID。與 profile／memory 共用四次上限，Stop／帳號切換撤銷、核准期間頭像被改則拒絕舊提案；只合併頭像，不覆蓋其他欄位、不刪舊圖片檔案。**未還原參考的任意 host/box path 圖片安裝**，不接受路徑、URL、base64 或模型生成圖；不能視為完整 avatar parity。`AgentAvatarChangeTests`、`AgentManagementAppIntegrationTests` |
| 明確保存／忘記自身事實 | `source/host/runner/tools/sand-state-tool.ts` 的 memory write/forget；`source/host/extensions/memory/agent-state.ts` 的 memory shards | **已接線受限版本**：群組／mailbox 的 `update_state(target:"memory", action:"write"或"forget", fact:...)` 預設為私人 `scope:"agent"`，共享 scope 見下一列。write 的 tier 接受 profile／log／note（預設 log），forget 使用記錄原文且不得傳 tier。帳號＋代理人由 host 固定，跨 origin、重啟後同一代理人的 group/mailbox runtime 會取得已核准事實，其他代理人／帳號不注入私人事實。每次增刪都顯示全文並核准；UI「代理人 → 編輯 → 代理人記憶」可重新整理、檢視及確認忘記。每事實 1,000 字元；每帳號／代理人 48 項（含最多 8 項 profile）、合計 12,000 字元；不自動淘汰。**尚缺**：project scope、DM／自動化等其他入口統一記憶、完整私人歷史 session。不是自動捕捉整段聊天。`AgentMemoryTests`、`AgentManagementAppIntegrationTests` |
| 共享使用者事實 | `memory-service.ts` 的 `SharedUserMemoryStore`、`sand-memory.ts` 的 `renderUserMemorySystemPrompt`／`mergeUserMemoryShards`；`agent-state.ts` 的 user shard | **已接線受限版本**：同一工具明確指定 `scope:"user"` 後，逐次核准共享給帳號內所有現有／未來代理人的 group/mailbox 模型，含群組外代理人。省略 scope 或舊紀錄缺少 scope 一律維持 private agent。保留紀錄者 UUID、tier／日期／scope 來源；模型只能忘記自己的同 scope 原文；UI 可管理所有作者的共享紀錄。共享 account 全部作者合計 48 項、8 項 profile、12,000 字元，與私人額度分開，不自動淘汰。**差異**：寫入仍按同 scope 精確文字全體去重，召回另按大小寫／空白摺疊並保留較新原文、tier 與作者；有重要性排名與獨立預算，詳見下一列。project scope 仍拒絕，其他執行入口仍未注入，沒有自動抓取整段聊天。`AgentMemoryTests`、`AgentManagementAppIntegrationTests` |

### 自身 routine 建立／修改／暫停／恢復／刪除

已核對 reconstructed `source/host/runner/tools/sand-state-tool.ts` 的 `routine.create/update/pause/resume/delete` 分派與 `extensions/memory/agent-state.ts` 的自身排程操作。Filicon 的 group/mailbox 透過 `update_state(target:"routine", action:"pause"、"resume"或"delete", id:...)` 操作自身既有排程；這三個 action 只接受 target/action/id，不得夾帶定義欄位。目錄只列 host 固定 owner 的 ID／名稱／啟用／費用防護狀態，不列其他代理人的任務。每次展示 ID、完整任務與 trigger JSON 並重新核准，auto-review allow 不豁免，與 profile／memory／avatar 共用四次額度。

同一入口另支援有限 `action:"create"`／`"update"`：create 需 name／prompt，以及 schedule 或 trigger（不可同時指定），enabled 可省略且預設 true，ID 及 owner 由 host 產生；update 需自己的 id 及至少一個變更欄位，省略欄位保留。name 最多 80 字元、prompt 32,000、schedule 256，每 owner 最多 50 項。時間排程支援 cron／alias／`@every`（1 分鐘至 366 天）；新 schedule 固定當次 App 時區，可由有效 TZ/CRON_TZ 前綴覆蓋；舊時間定義缺少時區時，須提供 schedule 才能明確固定時區。

單個 GitHub 事件條件：`{type:"github",repo:"owner/repo",events:[...],userAllowlist?:[...],ciBranch?:...}`。repository 須具體、events 須為既有 14 種已知名稱、使用者最多 50 位；未知欄位／事件／錯誤類型／空篩選項／不合法分支會被拒絕，不默默丟掉限制。空 userAllowlist 代表不限對象；PR opened/pushed/merged/comment/inline-comment 篩選 PR 作者，review requested/approved/changes-requested/commented/thread-resolved/thread-unresolved 要求作者與操作人都在清單內，issue-assigned 篩選操作人。CI 不受使用者清單限制，必須指定一個有效分支；目前僅為該 repository 的個別 push workflow_run 完成（success／failure／timed_out），**不是原版所有 checks settled 的彙整或 PR CI**。時間、GitHub、Slack 與下述混合 OR 組合可經完整核准互換；其他平台、generic event 與任意 trigger JSON 仍拒絕。既有已驗證事件連線必須另行設定，此工具不安裝／啟動 webhook、不登入外部服務；核准後待處理事件可能符合新定義。

Slack 事件寫入支援單一 `{type:"slack",channel:"C/G/D 對話 ID 或 *",match:{kind:...}}`，kind 為 message／mention／keyword／reaction；keyword 最多 120 字元，reaction 最多 8 個表情短名稱，清單省略或留空代表所有表情。channel 最多 80 字元且只接受具體 ID 或 `*`；`*` 涵蓋所有已設定連線實際送達的對話，不授予額外 Slack 存取權。mention 是 App／bot 被提及，mention/reaction 需既有已驗證的事件入口；既有 channel 訊息路徑仍支援 message/keyword，沿用 connector 的過濾方式，未保留 event subtype，因此不宣稱與 webhook 分類等同。已驗證 webhook 僅普通使用者訊息及對訊息新增的表情觸發；bot／subtype／編輯／刪除訊息、撤回表情與檔案表情不觸發。不支援原版的 `#channel`／`@人名` 解析與 `bySelf:true`：目前無可靠的使用者身分對應，因此明確拒絕，不把機器人身分當成使用者。未知／混用／null 欄位及無效篩選會在核准前拒絕；預覽顯示完整正規化條件與範圍限制。

單個 Linear 事件條件使用 `{type:"linear",event:{case:"issueCreated"或"statusChanged",statusIds?:[...]},teamIds?:[...],projectIds?:[...]}`；statusIds 只能用於 statusChanged，篩選改變後的新狀態。每份清單最多 50 個精確 UUID，省略／空清單表示不限；核准前統一 UUID 大小寫、排序、去重。名稱、endOfCycle／cycleIds、未知欄位、null、錯誤型別與無效 ID 皆拒絕，不會忽略篩選而擴大觸發。須既有驗證入口，核准不安裝連線、不增加工具或權限。獨立 Linear 型別沿用 primaryIDs（團隊）／secondaryIDs（專案）的舊儲存欄位；舊資料缺少 statusIDs 仍可載入，不自動轉換或啟用。

另支援時間／事件 OR 組合：`trigger:{type:"group",listeners:[...]}` 或裸 `trigger:[...]`，原始輸入限 1–8 個 cron／GitHub／Slack／Linear 條件且不得巢狀。時間條件使用 `{type:"cron",schedule:"..."}`，也可單獨使用或組成純時間群組。每個時間條件在核准前固定 App 時區或有效 TZ/CRON_TZ 覆蓋；模型提案的每項時間條件皆須在 366 天內有下一次執行，間隔限 1 分鐘至 366 天。所有條件先驗證，任一無效就拒絕整份提案，不丟棄限制；正規化後排序、去除完全相同條件，只剩一項則儲存為單一 trigger。任一條件命中同一任務即能觸發，不要求全部成立；同筆事件命中多條只納入一次，不同事件仍可能造成後續執行及費用。每條各自的頻道／repo／作者／操作人／CI 分支／Linear 團隊、專案與新狀態篩選維持不變，未命中內容不送入 prompt。去重包含 connector ID 及事件 ID、批次 key 使用長度分隔，防止跨平台 ID 碰撞和分隔符別名；已處理的送達紀錄在重新載入後仍去重。預覽顯示完整 OR 定義以及所有涉及平台的限制，不增加外部連線或權限。模型入口仍拒絕 generic event、其他平台及巢狀組合，不可同時指定 top-level schedule 與 trigger。時間條件取最早下次執行，同時命中只執行一次、不補跑；所有條件共用最近執行基準，因此事件與手動執行也會重設 interval 計時。完整新舊核准畫面以七語言揭露時區固定、間隔重設及額外執行費用；不是手動混合條件編輯器。

建立／修改完整核准卡顯示新定義與 enabled；修改另展示舊 name／完整 prompt／trigger／enabled。新增／改排時間從核准提交後算，不補跑等待期間錯過的次數、不立即 Run Now；只改 name/prompt 保留現有 nextRun。提交時重新驗證容量、時程、費用防護及定義，沿用儲存額度與同步 lifetime fence；原子候選儲存成功才發布，durable receipt 區分寫入成功與後續 bookkeeping 失敗。修改只合併核准定義並保留最新 lastRun／history，已開始或排隊的 executor 保留舊任務。費用防護生效時拒絕啟用的新定義，受防護排程不得修改；可建立停用草稿，不因此解除任何防護。

暫停只禁止後續觸發，不取消已開始或已交給 executor 排隊的執行。恢復保留定義／歷史，按目前時間重新計算下一次觸發，不呼叫 Run Now、不補跑錯過的時間。費用防護暫停與未知 trigger（含巢狀）拒絕由此工具恢復，須由使用者到自動化頁檢視。核准後再次驗證 owner、revision、名稱／prompt／trigger／啟用及 guard 狀態；既有執行更新的 history／lastRun 不被舊 snapshot 蓋掉。儲存 candidate 成功後才改記憶體，寫檔失敗不得偷偷啟用工作。同步 lifetime 撤銷 fence 與 session receipt 沿用既有管理工具的語意。

刪除先展示無法復原的警告，核准 action 標為 destructive。原子移除定義及其費用防護 ID，不改其他排程、防護政策、執行歷史、wake 或 claims；寫檔失敗時記憶體不變。已開始／已交給 executor 排隊的執行不取消，完成後仍寫入歷史，不會把定義加回；尚未 dispatch 的 cron／事件批次重查定義後跳過已刪項目。執行歷史留在儲存空間，但現有 UI 不提供已刪排程的歷史入口，也沒有還原命令。不刪產出檔案、不斷開外部服務。可刪除停用／費用防護／未知 trigger 的定義，但不能藉此解除其他任務的防護。

這是 **部分還原**：除上述有限 GitHub／Slack／Linear 外，Linear endOfCycle／cycleIds、參考的其他 event/platform、Slack 名稱解析／自身身分篩選、GitHub checks 彙整及連動工作流程審查仍未接線（UI 既有操作不受影響）；Filicon 對每種 routine 變更都要求明確核准，也沒有因本項替自動化推論加上 host 工具。不是完整原版 automation runtime。

### 記憶召回規則

`AgentMemoryRecall` 在 scope/account 過濾後才去重及排序，私人、共享、基礎事實、近期事實四個池分開處理。profile 優先保留較新項目；近期 log/note 採參考 `sand-memory.ts` 的相對排名 `log2(importance) + createdAt / 30 天`，note 的 importance 為 0.5、log 為 1。這是排序，不是 30 天到期或刪除。相同大小寫／空白正規化文字只在同池摺疊，保留較新原文與作者；不自動覆寫或解決語意矛盾。

私人 profile/recent 的 JSON UTF-8 預算為 8,000/4,000 bytes，共享為 4,000/2,000 bytes，含作者、日期、scope、canForget、跳脫字元及陣列分隔；件數上限各為 8/30、8/15。過大的單項完整省略、嘗試下一項，不截斷事實。這比參考按文字長度、首項可超額的規則更嚴格。所有省略項仍落盤及計入儲存上限，編輯頁列出全部；runtime 回報省略數並提示到編輯頁檢視，不憑空承諾可 grep 私人資料目錄。`note` 以明確 enum 儲存，不用可偽造的文字前綴辨識；參考的自動 extraction／episode／freeze／搜尋回填尚未實作。`AgentMemoryRecallTests`、`AgentMemoryTests`、`AgentManagementAppIntegrationTests` 覆蓋此有限版本。

## 安全差異

- 頭像工具只引用隨 App 提供的小寵物 ID；不讀取任意檔案、不呼叫外部影像服務。host 綁定 owner 與 previous avatar，逐次完整預覽核准，auto-review allow 不豁免。儲存與撤銷在同一同步臨界區，原子寫入失敗回復；session 內的已提交 receipt 避免後續 quota bookkeeping 失敗引發重複修改（不是跨重啟的呼叫去重）。恢復 Codex 不刪除原自訂圖片。名稱／指令／模型被其他操作更新時保留最新值，不以整份舊 profile 覆寫。
- 群組圖片轉交的目錄由 host 綁定 group/user message/member ID，不接受模型指定來源訊息；只限最近一次使用者請求且確實被該輪指定的成員，未被點名、其他房間、歷史／未綁定的執行不得取得圖片 handles。核准返回後重新檢查來源與 bytes；一般 auto-review allow 不略過圖片核准。委派房間回合不繼承來源房間圖片；peer 只收到核准的任務文字與圖片，不複製群組私人上下文。
- 群組直接附圖只接受 host 匯入並驗證的 PNG/JPEG；bytes 綁定本次已成功貼出的 user message ID 與 metadata，不從歷史重新載入。後續文字回合只帶歷史圖片數量，delegated wake 不重播舊 user 圖片；own-agent 暫存上下文也移除附件 handles。圖片在群組內保存不代表後續自動送給所有模型。preflight 等待期間 Stop／帳號切換／成員變更拒絕舊送出；訊息超過 8,000 字直接拒絕，不截掉尾端 @mention 後擴大收件範圍。貼文寫入失敗回復記憶體並保留輸入。選圖草稿按群組隔離、切換帳號清除；不自動刪除已匯入 blobs。
- 記憶是使用者逐項核准的背景資料，不是 system persona、授權或動作完成證據。模型取得 JSON 事實時有 data-only 警示，但這不是防 prompt injection 的保證；真正的工具核准仍由 host 控制。模型不得傳 agent/account ID、混入 profile 欄位或寫入未知 state scope。私人事實不自動傳入其他代理人或複製到 clone；明確 scope user 的核准資訊揭露群組外及未來代理人也會取得共享事實（含新 clone 的群組／mailbox 回合），不另外複製紀錄。忘記只停止未來注入，不清除已送出的對話或執行中的模型上下文。
- 記憶 Stop／帳號切換使用同步撤銷 fence；儲存及 receipt 在同一 actor turn 完成，寫檔失敗回復原狀。忘記重新檢查完整 record identity／帳號／代理人／事實／tier，避免舊提案刪掉新紀錄，不以 JSON 往返的 Date 浮點微差當作內容變更。封存後模型不能新增事實，使用者仍可移除舊事實；滿額不自動刪除任何舊記憶。
- `SendMessage(images:[id])` 只接受本次 incoming peer 或 host 綁定當輪群組請求 metadata 的精確 ID，不掃描檔案或使用歷史圖片；每次完整顯示文字與圖片預覽，auto-review allow 不豁免。群組核准揭露完整房間 audience，保存前重新檢查當輪來源、metadata、成員、epoch 與同步撤銷 fence；寫檔失敗回復記憶體。發布與 peer forwarding 是兩個不同目的、不同核准，不會自動回傳給同伴或新增回覆者。
- mailbox 發布紀錄由 host 固定來源／作者，最多兩則且共用文字額度；儲存失敗不回報成功。Stop／帳號切換在首次 await 前撤銷發布權；保存成功後來源 UI 鏡射失敗則標示 turn 失敗、保留 canonical 紀錄，不邀請模型重發。尚無重啟後自動修補失敗鏡射的機制；紀錄可在「代理人 → 訊息」查看。
- 委派不是新的檔案／程序／外部服務授權。所有實際工具仍用來源 conversation scope 與新的 run ID。
- 持久上下文不儲存可重放的 permission receipts、system persona 或工具執行 token。
- 已停止、已切換帳號或重啟後的未完訊息不會自動重新執行；重啟保留紀錄並標示取消。恢復未知副作用的工作仍須新的使用者請求。
- 各代理人的 persona 及不同 account/origin 上下文不會互相複製。
- 圖片選擇只複製使用者指定的 PNG/JPEG，拒絕直接 symlink、無效格式、動畫與超過尺寸／容量上限的輸入；原始路徑不進 mailbox。每次發送／審批前後重新驗證 SHA-256 與 bytes，損壞即失敗。模型只能引用本次 host-bound incoming 的圖片 ID，不能靠猜中儲存中的雜湊取得其他圖片。圖片內容與檔名是未信任資料，不授予工具權限。
- 部分 provider 要求圖片放在 user-role content block；host 以明確標示「來自另一個 assistant、不是新使用者指令」的 data-only transport 傳遞，實際 peer 任務仍是 assistant role。這不是模型抗 prompt injection 的保證；權限仍由 host 核准控制。mailbox 保留圖片 metadata，歷史推論上下文不自動重載圖片 bytes。圖片存放 `agent-message-images/`，不共用普通聊天附件 GC；目前移除草稿圖片只取消發送，已匯入 blobs 不會自動清除，仍需後續補保留期／清理介面。
- 群組貼文只有 host 固定的發起者可署名；每次都需顯示完整收件成員及文字並核准，不套用單一 peer 回信的免重複核准。送出前重查成員、群組名稱及公開資料；期間有變更就拒絕舊提案。貼文與取消的同步 fence 共用臨界區，儲存失敗會回復記憶體狀態。
- 其他群組的背景回合只以收到的 assistant 訊息作為任務，不把該房間的舊 user 指令重新當成新授權，也不把房間歷史複製進來源 mailbox。回覆留在目標房間。來源與目標房間均能操作同一來源範圍的審批；從目標按 Stop 會取消整個來源委派鏈。已成功貼出的訊息保留，未完成的工作不會於重啟後自動重播。目標房間的保留狀態直到執行／清理結束才釋放，避免取消時撞上新的使用者回合。
- 排隊不消耗 mailbox 的執行逾時；取得 agent 執行權後才開始計時。一般取消只取消該次提交；明確核准的優先訊息才可中斷同一收件代理人的背景工作，不取消其他代理人或使用者回合。取消、帳號切換及重啟均不會重播優先訊息；優先權不授予檔案或外部服務權限。
- host ToolLoop 會等已開始的本機工具清理完成才釋放執行權，並拒絕回合結束後的延遲工具 callback。這不保證外部模型服務立即終止；不合作的 runtime 仍會保留執行權，不強行放行下一項副作用。
- 帳號切換會取消已排入的 agent 工作，並呼叫執行中子任務的停止 hook；排隊中的子任務不會呼叫 runtime interrupt。頻道回覆取得執行權後重新檢查帳號世代、連線及 agent 狀態。
- 模型不能用 profile tools 刪除／封存代理人、變更群組成員、讀取私人指令或更改權限。建立代理人不會自動執行；後續 `SendToAgent` 要另行核准。一般 auto-review allow 規則不跳過這些核准。
- UpdateAgent／update_state 審批期間若公開名稱／摘要被其他操作改動，拒絕舊提案；若只有私人指令、模型、頭像或狀態被修改，保留最新值；已封存的代理人拒絕寫入。此處比 reconstructed 合併 description/persona 的設計更窄，不能視為完整 persona 編輯。
- Stop／帳號切換在第一次 await 前撤銷 profile 寫入權；AgentService 在同一 actor turn 中檢查撤銷、原子儲存與發布，儲存失敗會回復記憶體狀態。成功儲存留有 session receipt，後續 bookkeeping 失敗不會讓重試再新增一名代理人。這不是跨帳號、跨重啟的持久操作去重。

## 驗證範圍

使用可控制的 provider 驅動真實 AppModel、ToolLoop、持久化與審批，包含真實本機 fixture 寫檔；不使用使用者的專案檔案、不連線付費／live 模型、不重啟使用者的 App。
七語言 UI render 是版面檢查，不是宣稱七語言完整產品逐頁驗收。
上一輪（`324d62e`）測試報告：134 XCTest、561 Swift Testing，零失敗；兩個需主動啟用的 live Codex 測試未執行。
原生 `Filicon App` Debug build 與嚴格簽章驗證通過。七語言各 1,393 keys，缺漏為零。
新增測試也確認：已發出的進度在後續失敗或停止後仍保留，不被終止狀態清掉。
中途一次完整重跑曾卡在既有檔案鎖測試的子程序清理；隔離執行及最後完整重跑均通過，未宣稱該偶發測試問題已根治。
完整產品 parity 仍未完成，原矩陣的歷史 release／test 結果不得替代此核對。

### 後續排程驗證（2026-09-18）

新增每 agent 執行排程後，最終完整測試為 134 XCTest、575 Swift Testing，零失敗；兩個 opt-in live Codex 測試仍未執行。原生 `Filicon App` Debug build、`codesign --verify --deep --strict`、七語言 1,393 keys 零缺漏均通過。未重啟使用者的 App，未測試真實外部頻道或付費模型。

完整重跑也發現並修正：CLI 取消測試在 runner 尚未啟動前就取消的競態；MCP 審批舊 expiry task 可能影響重用 ID 的新請求（加入每次請求 token 並正確處理計時器取消）；既有檔案鎖測試在子程序已退出後仍卡住的 `waitUntilExit()`（取樣確認後改為非阻塞退出通知）。這些問題未以略過測試處理，最後兩次完整重跑均通過。

### Profile tools 驗證（2026-09-18）

新增的四個 App 整合測試（包含參數化拒絕／Stop／帳號切換、群組／手動 mailbox、七語言 render）與八個 session 測試均已通過。先前兩個重開資料測試被 macOS 鎖定畫面的檔案保護擋住；解鎖後也修正測試中即時 Date 經 JSON 往返的浮點精度差異，改以注入固定時間驗證，沒有降低檔案保護。最終完整套件為 134 XCTest、587 Swift Testing，零失敗；兩個 opt-in live Codex 測試仍未啟用。原生 Debug build 與嚴格簽章驗證通過；七語言各 1,395 keys，零缺漏。未 push、未重啟使用者的 App。

### Own-profile 驗證（2026-09-18）

上一批 profile tools 已提交為 `1fb956f`。本批補上上述狹義 profile/set 路由：session 測試涵蓋 host 身分、防冒用、未知路由、空白摘要、欄位保留、舊提案、封存、拒絕、撤銷、重播及三種工具共用額度。App 整合測試實際走群組／mailbox 的 ToolLoop 與審批，確認下一個群組回合讀到新公開資料，沒有改動群組成員；mailbox 的 self 是收件代理人，不是寄件者。一般 auto-review allow 也仍顯示核准要求。

完整套件為 134 XCTest、595 Swift Testing，零失敗；兩個 opt-in live Codex 測試仍未啟用。原生 `Filicon App` Debug build 與 `codesign --verify --deep --strict` 通過。七語言各 1,397 keys，零缺漏；清空摘要的審批元件產出七語言 PNG，繁中與法文已目視檢查。這不是完整產品逐頁驗收，也未呼叫真實外部服務或付費模型。未 push、未重啟使用者的 App。

### 群組目標驗證（2026-09-18）

上一批 own-profile 已提交為 `ffe5447`。本批新增八個 routing 測試與七個 App 整合測試，包含參數化的拒絕、停止、帳號切換、成員／群組名稱變更與封存；也覆蓋原子儲存失敗回復、精確重播、共用額度、PASS、不支援欄位、未知／非成員群組、延後喚醒、忙碌群組不被打斷，以及群組／手動 mailbox 來源的實際回覆路徑。目標群組的資料修改仍在來源 scope 出現核准；從目標按 Stop 可取消這些待核准操作。測試使用可控制的 provider 和獨立暫存資料，沒有操作使用者的真實群組或專案。

最終完整套件為 134 XCTest、610 Swift Testing，零失敗（兩個 opt-in live Codex 測試未啟用）。原生 `Filicon App` Debug build、嚴格 deep codesign 驗證、`git diff --check` 通過；這是本機 Debug 驗證，不是 release 公證／上架驗證。七語言各 1,400 keys，零缺漏；群組 audience 核准元件產出七語言 PNG，繁中及法文已目視檢查，並非整個產品逐頁驗收。未 push、未重啟使用者的 App。其餘差異與未完成項目仍依上表列為部分／尚缺。

### 優先訊息驗證（2026-09-18）

上一批群組目標已提交為 `7d81e51`。本批補有限優先中斷：測試涵蓋背景清理後交棒、前景與排隊使用者回合受保護、優先佇列順序、不同 agent 隔離、已取消請求不插隊、真實 ToolLoop 工具清理、優先回信另行核准、持久 priority 與排序、去重／重播、防格式混淆、群組拒絕 priority。AppModel 整合測試確認一般 auto-review allow 不跳過優先核准，拒絕或停止待核准提案不影響既有背景工作；手動 Priority 接線與使用者 mailbox 首回合保護也通過。

依測試技能使用可控制的 gate 驗證競態，未用真實模型或使用者資料。最終完整套件為 134 XCTest、619 Swift Testing，零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign 與 `git diff --check` 通過。七語言各 1,402 keys，零缺漏；優先訊息提示產出七語言 PNG，繁中與法文已目視確認換行完整。仍不是整個產品逐頁或 release 公證驗收。未 push、未重啟使用者的 App。圖片傳遞、跨對話統一私人記憶、其他 update_state 路由等仍未完成；完整產品 parity 不能宣稱已達成。

### Peer 圖片訊息驗證（2026-09-18）

上一批優先訊息已提交為 `ee76056`。本批提供上表所述的受限圖片傳遞，並修正 `SendMessage` 過去會忽略不支援欄位的問題，避免回報成功卻漏掉圖片。依 SwiftUI 技能將預覽呈現與載入分開；切換帳號會清除草稿圖片並重新載入預覽，選檔視窗也綁定開啟時的帳號。

依測試技能使用可控制的 provider、獨立暫存圖片與 CustomDump 比對實際推論 bytes、持久 metadata、審批內容與排程結果。新增測試涵蓋 PNG/JPEG、偽裝副檔名、無效／超大檔案、symlink／遠端 URL、重複／總量限制、MIME 與雜湊不符、不支援圖片的模型、舊資料解碼、重啟不重播、host-bound current-image allowlist、群組拒絕、SendMessage 明確拒絕、完整 ToolLoop 重複 call ID 拒絕，以及核准／拒絕／Stop／帳號切換／審批後圖片被竄改。圖片回信也必須重新核准，auto-review allow 不豁免。歷史推論不會偷偷重新傳送舊圖片。

最終完整套件為 134 XCTest、629 Swift Testing（81 suites），零失敗；兩個 opt-in live Codex 測試仍未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign 與 `git diff --check` 通過。七語言各 1,413 keys、零缺漏；實際圖片預覽／揭露元件產出七語言 PNG，繁中與法文已目視檢查。這不是完整產品逐頁驗收或真實模型端到端驗證，也不是 release 公證。未 push、未重啟使用者的 App；本批圖片修改已在下一輪提交為 `16d0fa1`。剩餘範圍仍以上表的部分／尚缺為準。

### SendMessage 圖片發布驗證（2026-09-18）

上一批 peer 圖片已提交為 `16d0fa1`。本批將 `SendMessage` 擴為受限圖片發布：只有這次 incoming 圖片的 ID 能被引用，host 決定作者與來源對話。每次重新預覽核准，不繼承 peer forwarding 或 auto-review allow 的授權；一般群組上下文仍提供文字版 schema。mailbox 的 `publications` 保存完整文字與圖片 metadata，舊資料缺少此欄位仍可讀取；來源房間鏡射與 mailbox 都可呈現圖片。canonical 保存後不因鏡射或後續推論失敗邀請重發，已發布內容也不被 Stop、terminal response 或重啟清空。未實作失敗鏡射的自動重建。

依 SwiftUI 技能重用圖片預覽與獨立回覆區塊，依測試技能以 CustomDump 比對持久內容，使用受控 provider 與隔離暫存資料。新增測試涵蓋當次 ID allowlist、拒絕 URL／歷史 ID／重複圖片、缺少 authorizer 預設拒絕、重播與更改 payload 拒絕、文字／圖片共用兩則額度、來源及作者防冒用、原子儲存失敗回復、同步撤銷、舊資料解碼、重啟保留、鏡射失敗仍保存、final 不重複。AppModel 實際核准流程涵蓋核准、拒絕、Stop、帳號切換、核准期間 bytes 損壞、發布後 Stop 及重啟載入圖片，並確認沒有意外喚醒同伴。

最終完整套件為 134 XCTest、636 Swift Testing（81 suites），零失敗；兩個 opt-in live Codex 測試仍未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign 與 `git diff --check` 通過。七語言各 1,416 keys、零缺漏；圖片發布預覽／標籤版面產出七語言 PNG，繁中與法文已目視檢查。這是隔離 fixture 與元件版面驗證，不是完整產品逐頁、真實模型端到端或 release 公證驗收。未 push、未重啟使用者的 App；本批發布修改已在下一輪提交為 `4548163`。任意 file/HTTPS 或新生成的圖片、一般群組圖片輸入、歷史圖片重播與其餘原版 runtime 差異仍未完成。

### Own-agent memory 驗證（2026-09-18）

上一批圖片發布已提交為 `4548163`。本批新增上表的有限自身事實記憶，所有 write/forget 逐次核准，auto-review allow 不豁免；一般群組及 mailbox/peer wake 使用同一 account/agent 所屬事實，不合併私人對話全文。身分與 account 不接受模型指定；scope 只允許 agent、tier 只允許 profile/log。編輯頁可檢視、重新整理及確認忘記，不需要模型配合。未新增獨立自動捕捉／摘要服務，也未聲稱共享 user/project 記憶或完整 runtime 已還原。

依 SwiftUI 技能將非同步載入／按鈕動作抽成具名方法；依測試技能注入固定時間、使用可控制的 gate 和隔離 fixture，以 CustomDump 比對持久結果。新增九個記憶測試與四個 App 整合測試（含參數化案例），涵蓋跨來源／重啟載入、帳號／代理人隔離、clone 不複製、非法欄位／未知 scope、profile 共用額度、滿額不淘汰、拒絕／Stop／帳號切換、等待中的 commit 撤銷、核准後 stale／封存檢查、原子儲存失敗回復及成功 receipt。App 測試實際走群組／mailbox ToolLoop 與核准，驗證 mailbox 記憶屬於收件代理人。跨重啟 UI 刪除測試抓到 Date JSON 浮點往返被誤判 stale，已修正為 record identity＋內容比對；替換成新 ID 的相同文字仍拒絕舊提案，刪除寫檔失敗仍保留原記憶。

最終完整套件為 134 XCTest、649 Swift Testing（82 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign 與 `git diff --check` 通過。七語言各 1,431 keys、零缺漏；真實審批元件產出七語言 PNG，繁中與法文已目視檢查。這不是完整產品逐頁驗收、live 模型驗證或 release 公證。未 push、未重啟使用者的 App；本批記憶修改已在下一輪提交為 `33a3d2a`。其餘缺項仍以上表與 parity 矩陣為準。

### Shared user memory 驗證（2026-09-18）

上一批私人記憶已提交為 `33a3d2a`。本輪依 reconstructed 的「各作者單獨寫入，共同讀取」設計新增受核准的 scope user；不擴大既有私人記憶的使用範圍。SwiftUI 將私人／共享區塊分開，共享區顯示記錄者，刪除確認提示會影響所有代理人；審批畫面揭露 current/future、群組外代理人及其配置的模型。scope 也是去重 fingerprint 與精確刪除 fence 的一部分，改 scope 的舊 call ID 不能重播成共享；帳號切換、Stop、每來源四次額度與原子儲存沿用原有 fence。

以受控 provider 和獨立暫存資料新增／擴充：共享全文及 audience 核准、拒絕／Stop／帳號切換、延遲 commit 撤銷、其他代理人不能刪別人的 shard、私人／共享同文字分開、跨作者共享額度、持久化失敗 rollback、相同文字的競態去重、舊紀錄缺少 scope 維持私人、未知 scope 解碼失敗，以及跨群組／mailbox／重開／clone／帳號隔離及使用者從編輯頁忘記他人共享紀錄。七語言私人／共享審批元件可 render，繁中與法文已目視檢查。

中途本機鎖定時，macOS `.completeFileProtectionUnlessOpen` 阻擋重新讀取 fixture `agents.json`（Cocoa 257／POSIX 1），影響 6 個跨重啟測試；解鎖後重新執行全部 24 個記憶／App 整合測試均通過。未降低檔案保護，未永久略過這些測試。

最終完整套件為 134 XCTest、653 Swift Testing（82 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,440 keys 零缺漏及 `git diff --check` 通過。依 SwiftUI 技能把私人與共享記憶分成獨立區塊，依測試技能使用固定時間、可控制的 gate 與 CustomDump 驗證實際持久結果。這不是完整產品逐頁、live 模型或 release 公證驗證。未 push、未重啟使用者的 App，共享記憶修改已在下一輪提交為 `d891ad3`。

### Note 與預算召回驗證（2026-09-18）

上一批共享記憶已提交為 `d891ad3`。本輪補上上述 note 與召回規則，未擴大共享、檔案或工具權限。依 SwiftUI 技能共用 tier 標籤，並在核准卡與記憶編輯區清楚揭露「僅送出排序後部分事實、省略不刪除」；新增 note 後也修正管理清單排序，避免 log/note 互相比較時破壞一致的排序關係。

依測試技能用固定日期與 UUID、可控制的 provider/gate 及 CustomDump 驗證：重要性／日期／穩定次序、前綴不可冒充 tier、去重前先隔離帳號與代理人、保留來源及精確原文、私人／共享與 profile/recent 分池、UTF-8／跳脫／metadata 預算、過大單項不截斷也不阻塞小項、核准前不儲存、Stop／帳號切換／延後 commit 撤銷、call ID 不可偷偷改 tier、重啟後 note 保留與 exact-text forget。App 整合測試確認實際群組與 mailbox 收到有界集合，省略的 note 仍能從編輯頁刪除且跨重啟生效。七語言 profile/note × private/shared 核准元件均 render，繁中與法文已目視檢查。

30 個定向測試通過；最終完整套件 134 XCTest、659 Swift Testing（83 suites），零失敗，兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,443 keys 零缺漏及 `git diff --check` 通過。測試只用隔離 fixture，未呼叫付費模型、未重啟 App、未 push。這不是完整產品逐頁或 release 公證驗證；本批已在下一輪提交為 `aaeadcd`。project 記憶、所有入口統一 runtime、自動 extraction／archive search 等差異仍保留為未完成。

### 群組直接附圖驗證（2026-09-19）

上一批記憶召回已提交為 `aaeadcd`。本輪群組 composer 增加選圖、緊湊預覽、移除及收件範圍說明；支援無文字的圖片訊息。先驗證全部指定成員模型，再保存 user message；bytes 綁定本次 message ID、metadata 與原先選定成員 ID，即使後續名字／路由改動，也不能擴大圖片收件對象。不把一般群組圖片加入 peer 圖片轉發或 SendMessage 發布的 allowlist。

依 SwiftUI 技能拆分純預覽呈現與非同步載入、使用群組專屬草稿；依測試技能以受控 provider/gate、獨立暫存 PNG 及 CustomDump 檢查實際請求。新增 10 項測試（含參數化案例），涵蓋圖片 bytes、image-only、單人 @mention／全員、持久預覽、後續回合／delegated wake／own-agent context 不重播、不支援圖片／未知成員／過長文字／重複／遺失／損毀輸入、保存失敗 rollback、草稿隔離、Stop／帳號切換／成員變更及錯誤 request/recipient binding。七語言附圖區產出 PNG，繁中與法文已目視確認圖片、文案及按鈕未裁切。

最終完整套件 134 XCTest、669 Swift Testing（84 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,445 keys 零缺漏及 `git diff --check` 通過。未呼叫真實／付費模型、未 push、未重啟使用者的 App。這不是完整產品逐頁或 release 公證驗收。本批群組附圖修改已在下一輪提交為 `4cf98a4`；當時生成圖片、任意 file/HTTPS 載入、一般群組圖片再轉發／發布、歷史圖片重播及匯入 blobs 的保留期清理仍未補齊。

### 群組圖片轉交驗證（2026-09-19）

上一批群組附圖已提交為 `4cf98a4`。本輪補群組 responder → 單一 peer 的 current-request 圖片 ID 路由，沿用既有收件人／全文／圖片預覽核准、真實 bytes 傳送及 mailbox 持久化。不增加群組目標附圖或直接群組 SendMessage 圖片發布，也不增加任意檔案／網址讀取權。圖片不可用的錯誤訊息同步調整為七語言的「本次請求」。

依測試技能以隔離暫存圖片、受控 provider 及 CustomDump 新增來源綁定、過期／外房間／未點名／未綁定／歷史圖片拒絕、核准後來源變更、去重及 App 真實 ToolLoop 核准／拒絕／Stop／帳號／成員變更／圖片損壞／持久化案例。核准前不喚醒收件模型；群組內未被點名的成員與群組外單一代理人都需另行核准，收到的是精確圖片 bytes 與核准文字，不複製來源房間上下文。重啟後 mailbox 與群組圖片仍可載入。

初次執行遇到 macOS 螢幕鎖定（`CGSSessionScreenIsLocked=Yes`），受保護 fixture blobs 的讀寫回傳 Cocoa 257／513、POSIX 1，既有圖片測試也同樣失敗。使用者解鎖後，29 項圖片定向測試（含參數化案例）與完整套件均重新通過；未降低檔案保護或略過相關案例。

最終完整套件為 134 XCTest、672 Swift Testing（84 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、包含新增案例的 `swift build --build-tests`、七語言各 1,445 keys 零缺漏及 `git diff --check` 通過。本輪沿用已存在的圖片核准 UI，未增加新的畫面；這不是完整產品逐頁或真實付費模型驗收。本批已在下一輪提交為 `42fe95d`；未 push、未重啟使用者的 App。

### 群組附圖回覆驗證（2026-09-19）

上一批圖片轉交已提交為 `42fe95d`。本輪讓一般群組 responder 的 `SendMessage` 使用本次已提供給自己的圖片，逐次預覽核准後保存附圖回覆。來源 user message、group、作者與同步撤銷 lifetime 都由 host 綁定，不接受模型指定；原有文字 responder 透過相容橋接保持行為。已保存的回覆不因後續推論失敗、Stop 或重啟而消失，final 不重複。這不是群組目標圖片 broadcast、新生成圖片或歷史圖片自動重播。

依 SwiftUI 技能重用 audience 與圖片預覽元件，分開說明「在此群組保存回覆」及「委派其他群組、喚醒成員」，避免核准文案誤導。依測試技能使用隔離圖片、受控 provider 和 CustomDump 驗證實際 bytes、來源綁定、metadata、持久化與取消；新增案例涵蓋核准／拒絕／Stop／帳號切換／成員變更、舊請求與外來圖片拒絕、缺少 authorizer 預設拒絕、核准後 bytes 損壞、同步撤銷、原子儲存失敗 rollback、發布後推論失敗與停止、重啟圖片仍可讀，以及不意外喚醒未點名成員。七語言核准元件產出 PNG，繁中與法文已目視確認換行及預覽完整。

54 項定向測試通過；最終完整套件為 134 XCTest、676 Swift Testing（84 suites），零失敗，兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,446 keys 零缺漏及 `git diff --check` 通過。本批在下一輪提交為 `1bd9e0a`；未 push、未重啟使用者的 App、未呼叫付費模型。這不是完整產品逐頁、真實模型端到端或 release 公證驗收，剩餘原版差異仍以上表為準。

### 自身頭像變更驗證（2026-09-19）

上一批群組附圖回覆已提交為 `1bd9e0a`。重新讀取 reconstructed 的 `shared-rooms.ts:postToGroup` 後確認：該入口只接受文字與 priority，並未接圖片；不能把 shared-room 鏡射的圖片功能誤認為跨群組 SendToAgent 圖片委派。故未擴加這條圖片路由，改補已確認的 `update_state` avatar set/clear，來源限 Filicon 現有九種內建小寵物，與參考的任意 host/box 圖片路徑安裝仍有差異。

依 SwiftUI 技能將頭像核准卡獨立呈現，顯示發起者、新頭像、舊小寵物或「自訂／預設」類型，以及不影響其他欄位／不刪圖的說明。依測試技能用固定 fixture 時間、可控制的 gate、隔離暫存資料及 CustomDump 驗證核准前不寫入、九種小寵物、恢復 Codex、拒絕外來 ID／路徑／URL／錯誤欄位、預設拒絕、共用四次預算、call ID 重播／變更 payload、來源 scope、Stop／帳號切換／延後 commit 撤銷、頭像 stale／封存、其他 profile 欄位保留、儲存失敗 rollback、已提交 receipt、重啟保存及不刪自訂圖片。App 整合覆蓋群組及手動 mailbox，後者只改收件代理人。初次測試發現測試 peer 未固定時間導致 JSON Date 浮點往返比較不穩，已改為固定日期並完整重跑；未放寬正式程式的檢查。

53 項定向測試通過；最終完整套件為 134 XCTest、686 Swift Testing（85 suites），零失敗，兩個 opt-in live Codex 測試未啟用。完整執行中帳號測試曾輸出 CoreData NSXPCConnection 診斷，相關測試仍通過，這不等同已驗證真實帳號服務。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,453 keys 零缺漏及 `git diff --check` 通過；set/clear 核准卡產出七語言 PNG，繁中 set 與法文 clear 已目視檢查。此為隔離 fixture 與元件驗證，不是完整產品逐頁、live 模型或 release 公證驗收。本批在下一輪提交為 `2fb6528`；未 push、未重啟使用者的 App。

### 自身 routine 暫停／恢復驗證（2026-09-19）

上一批自身頭像已提交為 `2fb6528`。本批新增上述有限 routine pause/resume；依 SwiftUI 技能分離純核准畫面，依 SPM 技能讓 AppServices 依賴既有 Automations 模組，不新增外部套件。排程批次等待前一工作時，舊 snapshot 可能仍啟動剛被暫停的下一工作；已在每次自動觸發前重查 enabled/revision，手動 Run Now 語意不變。

依測試技能使用固定時間、可控制的 gate、隔離暫存資料及 CustomDump 驗證：核准前不變更、own-only 目錄及身分、pause/resume 精確重播與共用四次預算、拒絕無效 action／欄位／外來 ID、預設拒絕、Stop／帳號切換／延後 commit 撤銷、核准期間編輯／刪除／封存、定義 stale、執行歷史保留、寫檔失敗 rollback、成功 receipt、跨重啟，以及不得越過 spend guard 或巢狀未知 trigger。App 真實 ToolLoop 測試包括 group／mailbox，mailbox 只能改收件者的排程；超過 2,000 字摘要上限的完整任務仍在核准 metadata 保留。排程與事件批次的暫停競態也有獨立測試。

最初更新 schema 時調整了原先將 routine 一律視為未知路由的舊測試；mailbox fixture 也改為依真實 ToolLoop 的 throw 語意檢查拒絕，而不是把失敗當 NormalizedToolResult。中途 macOS 螢幕鎖定（CGSSessionScreenIsLocked=Yes）導致受保護 agents.json 回傳 Cocoa 257／POSIX 1，影響既有重啟載入測試；未降低檔案保護。偵測解鎖後完整重跑通過。

19 項定向測試（含參數化案例）通過；最終完整套件 134 XCTest、696 Swift Testing（86 suites），零失敗；兩個 opt-in live Codex 測試未啟用。原生 Filicon App Debug build、嚴格 deep codesign、七語言各 1,462 keys 零缺漏與 git diff --check 通過；pause/resume 核准卡產出七語言 PNG，繁中 pause 與法文 resume 已目視確認。這不是完整產品逐頁、真實／付費模型或 release 公證驗收。本批在下一輪提交為 `88b84c1`；未 push、未重啟使用者的 App。

### 自身 routine 刪除驗證（2026-09-19）

上一批暫停／恢復已提交為 `88b84c1`。本批接上 reconstructed `routine.delete` 的自身排程入口，沿用完整核准、四次預算、同步 lifetime fence 與 durable receipt；不修改使用者實際排程。核准新增穩定 ID 及 destructive 風險，七語言明示無法復原。定義比對另包含 createdAt，避免刪除後用相同 ID 重建的另一份定義被舊核准刪掉。原子候選寫入同時清除該排程的 spend-guard ID，其他防護不變。

依 SwiftUI skill 將標題／警告集中為純畫面屬性；依測試 skill 使用隔離 fixture、固定觸發時間、可控制的 executor gate 與 CustomDump 完整差異，測試啟用／停用／費用防護／未知觸發的刪除、外來 owner 拒絕、預設拒絕、group／mailbox 明確核准、auto-review 不豁免、Stop／帳號切換／延後 commit 撤銷、核准期間編輯／刪除／同 ID 重建／owner 封存、寫檔失敗 rollback、共用四次上限與 receipt 重播。另驗證 cron／事件批次跳過已刪排程、刪除時仍在執行的工作正常收尾且不重建定義、歷史／wake 保留及重啟後仍無定義。沒有自動還原或已刪排程歷史 UI。

首輪新增跨重啟的完整 equality 揭露 Date 經 Unix 毫秒 JSON round-trip 的浮點精度差；測試的預期值改用實際儲存編碼精度，保留全部欄位比對，未改 production 儲存或忽略日期。重跑 38 項定向測試通過；完整套件 134 XCTest、699 Swift Testing（86 suites）零失敗，兩個 opt-in live Codex 測試仍未啟用。原生 Filicon App Debug build、嚴格 deep codesign、七語言各 1,465 keys 零缺漏及 git diff --check 通過；pause/resume/delete 核准卡均有七語言 PNG，繁中與法文 delete 已目視確認。

這是隔離 fixture／元件測試，不是全產品逐頁、live 模型或 release 公證驗收；當時 routine create/update 模型入口仍缺。本批已提交為 `d651e4a`；未 push、未啟動或重啟使用者的 App。

### 自身時間排程建立／修改驗證（2026-09-19）

上一批刪除已提交為 `d651e4a`，本輪開始時工作目錄乾淨。重新核對 reconstructed 的 routine create/update 後，補上上述有限時間排程入口，不延伸 event/platform/combined trigger、工作流程寫入或未經核准的模型行為。依 SwiftUI skill 讓核准卡分別展示完整「目前排程／提議的排程」與費用、未補跑及未授予工具權限的說明；七語言 pause/resume/delete/create/update 均產出 PNG，繁中 update 與法文 create 已目視確認無裁切。這是元件檢查，不是全產品逐頁驗收。

依測試 skill 使用固定時間／ID、隔離暫存資料、可控制的 provider/executor gate 及 CustomDump，比對核准前不寫入、host owner/ID、預設 enabled、App 時區與明確 TZ 覆蓋、UTF-8 長任務、省略欄位保留、核准後才算 nextRun、name/prompt-only 保留原時間、執行中仍用舊任務而新定義與歷史不被完成回報覆寫。另覆蓋錯誤欄位／類型／null／外來 ID、interval 範圍、預設拒絕、容量、費用防護、event 不被偷偷轉換、拒絕／Stop／帳號切換／owner 封存／延後 commit、核准期間定義變更、寫檔失敗 rollback、durable receipt、共用四次預算及精確 call 重播。App 真實 ToolLoop 包含群組及 mailbox；mailbox 的 owner 是收件代理人，auto-review allow 不跳過完整核准。

首輪新增測試有 `try`／async autoclosure 編譯問題，修正後又找到測試重用已完成 call ID，改成獨立 ID 以實際驗證 event-trigger 拒絕，未放寬 production 重播防護。47 項定向測試先通過，再補上預設拒絕及執行中修改案例；最終完整套件 134 XCTest、710 Swift Testing（86 suites）零失敗，兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,473 keys 零缺漏及 `git diff --check` 通過。

本批已在下一輪提交為 `6f5e9fc`；未 push、未操作使用者的實際排程或聊天、未重啟 App、未呼叫付費模型。這不是 live 模型、外部服務或 release 公證驗收；完整 reconstructed parity 仍未完成，當時非時間觸發的模型寫入與其他 runtime／memory／state 路由差異繼續保留為未完成。

### 自身 GitHub 事件排程建立／修改驗證（2026-09-19）

上一批時間排程已提交為 `6f5e9fc`。本輪重新讀取 reconstructed `sand-state-tool.ts`、`automation-trigger.ts`，接上前述有限 GitHub create/update，不擴充其他平台、複合觸發條件或隱式工具權限。依 SwiftUI 技能沿用獨立核准元件，展示完整新舊定義；新增七語言說明既有連線、待處理事件、作者／操作人篩選與 CI 非彙整限制。GitHub create/update 皆產出七語言 PNG，繁中 update、法文 create 已目視確認全文與篩選條件無裁切；這只是元件驗證，不是全產品逐頁驗收。

核對 [GitHub webhook 事件文件](https://docs.github.com/en/webhooks/webhook-events-and-payloads) 與 [Actions 觸發文件](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows) 後，修正 normalize：PR synchronize／review_requested、review-thread resolved/unresolved；一般 branch push 不再冒充 PR pushed，一般 issue 留言不再冒充 PR comment，未知 review state 不作 commented。CI 僅接受同 repository、push 觸發、completed 的 workflow_run；success 對應 passed，failure/timed_out 對應 failed，取消／略過／未知結論及 PR/fork workflow 不觸發。尚未做原版 checks 彙整，文件、schema、runtime、工具結果及核准皆明示差異。

另修正 PR 作者與操作人篩選，並在每個 routine 分批前篩除不匹配事件，避免只因同批有一筆符合條件，就把其他 repo／使用者的 payload 一起送給模型。核准測試發現 GitHub events 的 Set 編碼順序不固定，已讓編碼排序，保留既有 Codable 欄位格式及讀取相容性。

依測試技能使用隔離暫存資料、受控 provider／gate、固定時間與 CustomDump，新增 GitHub 定義正規化、完整核准、14 種事件篩選、嚴格拒絕無效／未知／混用欄位、時間↔GitHub 轉換、省略觸發條件保留、歷史與重啟、call 重播、共用四次預算、容量、預設拒絕、外來 owner、費用防護核准前後重查、stale／封存／寫檔失敗、Stop／延後 commit 撤銷。App 真實 ToolLoop 覆蓋群組與 mailbox 的核准／拒絕／停止／帳號切換；mailbox 只能更動收件人的排程。事件測試使用 fixture HMAC 經 controller → normalizer → matcher → executor → history，拒絕無效簽章與重播，沒有開啟 HTTP listener、呼叫 GitHub 或付費模型。

65 項定向測試（含參數化案例）通過；最終完整套件為 134 XCTest、720 Swift Testing（87 suites）零失敗，兩個 opt-in live Codex 測試未啟用。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,475 keys 零缺漏與 `git diff --check` 通過。這不是外部服務端到端或 release 公證驗收。

完整套件中的帳號測試仍有 CoreData NSXPCConnection 診斷但測試通過；原生 build 有「未依賴 AppIntents，因此略過 metadata extraction」警告，未出現編譯錯誤。不將這些結果視為真實帳號連線或 AppIntents 整合已驗證。

本批 GitHub 事件修改已在下一輪提交為 `129d804`；未 push、未重啟 App、未變更使用者實際群組或排程。完整 reconstructed parity 仍未完成；其他事件平台、複合觸發、CI checks 彙整、工作流程審查與既有 runtime／memory／state 差異仍保留待補。

### 自身 Slack 事件排程建立／修改驗證（2026-09-19）

上一批 GitHub 事件排程已提交為 `129d804`。本輪重新核對 reconstructed 的 `sand-state-tool.ts`、`automation-trigger.ts`，接上上述有限 Slack create/update；不擴充其他平台或複合觸發，不授予工具或登入外部服務。原版的頻道／人名解析與自身表情篩選仍未完成，因此明確拒絕，不以 bot 身分代替使用者。表情短名稱可去冒號、轉小寫、排序去重；未知／無效項目及 `::suffix` 不可靜默丟棄或放寬。

依 [Slack reaction_added](https://docs.slack.dev/reference/events/reaction_added/)、[message](https://docs.slack.dev/reference/events/message/) 與 [app_mention](https://docs.slack.dev/reference/events/app_mention/) 官方格式，修正表情事件從 `item.channel` 取得對話，actor 使用 `user` 而非原訊息的 `item_user`。驗證事件入口只接受普通使用者 message/app_mention 與對 message 的 reaction_added；removed/file reaction、bot／subtype／hidden／編輯／刪除／未知事件不得落入 wildcard message。簽章內容中的自訂 `is_self` 不作身分依據。既有 channel polling 仍沿用 connector 過濾，沒有 event subtype，不宣稱與 webhook 分類相同；既有無 marker 的 normalized event 相容性保留。

依 SwiftUI 技能維持核准畫面與寫入邏輯分離，展示完整 before/after、正規化條件、既有連線、`*` 範圍、App 提及、空表情清單、身分限制與費用。create/update 七語言皆產出 PNG，繁中 update 與法文 create 已目視確認無裁切；這是元件檢查，不是整個產品逐頁驗收。

依測試技能使用隔離暫存資料、受控 provider/gate、固定邏輯時間與 CustomDump。涵蓋四種 match、C/G/D/*、80/120 字元及 8 個表情的上下界、省略及空清單、預設 enabled、完整核准、未知／null／錯誤型別／混用欄位拒絕、時間↔GitHub↔Slack 轉換、省略保留、歷史與重啟、call 重播、四次額度、容量、owner、費用防護前後重查、stale／封存／寫檔失敗、Stop／延後 commit，以及 App 群組／mailbox 的拒絕與帳號切換。fixture HMAC 經 ingress controller → normalizer → matcher → executor → history，驗證簽章與重播，未開啟 Slack listener 或連線 Slack、未呼叫付費模型。完整套件原有 loopback listener fixture 不受影響。

74 項定向測試（含參數化案例）曾通過；最後完整套件為 134 XCTest、729 Swift Testing（88 suites），零失敗，兩個 opt-in live Codex 測試未啟用。回歸時補強既有 ingress fixture，改成以 Bool 驗證 JSON 布林值，避免 NSNumber 描述為 1 而誤比對字串 true。原生 `Filicon App` Debug build、嚴格 deep codesign、七語言各 1,477 keys 零缺漏及 `git diff --check` 通過。驗證沒有使用正式 Slack 帳號或付費模型，不是外部服務端到端或 release 公證驗收；Debug ad-hoc build 仍有未依賴 AppIntents 而略過 metadata extraction 的既有警告。 帳號測試仍輸出既有 CoreData NSXPCConnection 診斷但測試通過；不視為真實帳號連線已驗證。

本批 Slack 修改已在下一輪提交為 `6fb3d04`；未 push、未重啟 App、未變更使用者實際群組、聊天或排程。完整 reconstructed parity 仍未完成：其他平台／複合 trigger、Slack 名稱與人類身分映射／輪詢事件分類、GitHub checks 彙整、工作流程審查及既有 runtime／memory／state 差異仍待補。

## 本輪增量：GitHub／Slack 純事件 OR 組合（2026-09-19，完整回歸待解鎖）

上一批已提交為 `6fb3d04`。再次核對 reconstructed `sand-state-tool.ts`、`automation-trigger.ts` 的 group／array／任一命中設計；本輪只接上已支援的 GitHub／Slack 組合，保留完整核准、費用防護、身份及帳號邊界。參考允許 cron 與事件混用，而 Filicon 既有 `.anyOf` 不計算 nextRunAt，因此本輪明確拒絕，不將此限制說成完整 parity。

測試先重現跨連線相同 externalEventID 被誤當已執行（第二次少一筆 run），再修正 execution claim 為 connector＋delivery ID，並加上長度分隔防批次 ID 混淆。事件不因多個條件命中而重複納入；各平台的原有過濾與 ingress 認證流程保留。

已驗證：

- 聚焦 59 項 Swift Testing／6 suites 通過（包含參數化 cases）：OR 建立／修改與時間、單事件互換、完整新舊預覽、重播正規化、1／8 項邊界、惡意／未知／混合／巢狀欄位、直接提交繞路、停止與核准之間／提交之間撤銷、拒絕、切換帳號、sender／recipient 隔離、費用防護、容量、儲存失敗及 durable receipt；以及 matcher、批次隔離、事件持久化去重、pause/resume/delete。`/tmp/filicon-event-group-verified.log`。
- 七語言均 1479 keys、0 missing。核准元件產出 create/update 七語言 PNG，繁中 update 與法文 create 已目視確認全文、OR 說明及雙平台警告無裁切；不是全產品逐頁驗收。`/tmp/filicon-event-group-review/`。
- 原生 `Filicon App` Debug 建置成功，產物 `codesign --verify --deep --strict` 通過；未啟動產物。`/tmp/filicon-event-group-native.log`。
- `git diff --check` 通過。沒有付費模型、實際 Slack/GitHub 帳號或外部 webhook 的驗證，只有隔離 fixtures。

完整回歸尚未完成：較廣的 `AgentManagementAppIntegrationTests` 在受保護 `agents.json` 重新讀取時收到 `NSCocoaErrorDomain 257 / NSPOSIXErrorDomain 1`；獨立重跑頭像持久化測試也失敗，IORegistry 顯示 `CGSSessionScreenIsLocked=Yes`。既有檔案使用 `.completeFileProtectionUnlessOpen`，未為過關而削弱保護。已請使用者解鎖，解鎖後須重跑完整套件才可宣稱全部通過。紀錄：`/tmp/filicon-event-group-targeted.log`、`/tmp/filicon-event-group-reload-check.log`。新功能的聚焦通過不代替完整回歸。

本批 OR 修改已在下一輪提交為 `c642048`；提交前再次通過 59 項聚焦測試（`/tmp/filicon-event-group-precommit.log`）。未 push、未重啟 App，未更動實際群組、聊天或排程。

## 本輪增量：混合時間／事件排程引擎基礎（2026-09-19，完整回歸待解鎖）

上一批已提交為 `c642048`。核對 reconstructed `source/host/automations/automation-store.ts` 的 `earliestNextRunAt`／`recordRunWith`，及 `source/shared/automation-schedule.ts` 的 `computeNextRunAt`／`automationAnchor` 後，補上內部平面 `.anyOf` 的時間分支。這輪刻意不開放模型建立／修改混合條件，不改 schema、工具說明或核准 UI；這些仍是下一階段缺項，不能宣稱已達完整原版 parity。

行為與安全邊界：

- 各 cron／interval 成員計算後取最早時間；同時命中或錯過多個時段只執行一次，不補跑。時區與 TZ/CRON_TZ 前綴沿用既有排程器。每個任務只有一個最近執行基準，包含事件及手動執行；因此事件也會重設 `@every` 的等待時間，並非每個 listener 獨立計時。
- 某個合法 calendar 條件在既有 366 天搜尋範圍內無下次時間（如遠期閏日），不阻止其他 OR 成員；所有時間成員都無下一次時間時為 nil。不擴大搜尋範圍；單一 cron 原本的 no-run error 行為保留。無效語法／時區不默默忽略，停用時也拒絕無效時區。巢狀及超過 8 項仍拒絕。
- 複合條件包含未知 trigger 時不新增時間排程，既有事件匹配語義不變。重新載入舊的 `nextRunAt=nil` 定義不自動啟用時間分支或遷移使用者設定；只有明確 save／enable 或正常執行後重新計算。
- 執行批次等待其他任務時，如果該任務已被事件或手動執行更新了 nextRun，舊的到期 snapshot 不得再執行；除 revision 外重新比對 nextRunAt。暫停／費用防護同時阻擋時間與事件，使用者恢復後從恢復時刻安排，不立即執行。
- 一般 save、setEnabled、開始執行時，先算時間並原子儲存 candidate，成功後才發布記憶體狀態、run claim 與 busy 狀態。排程計算／寫檔失敗不留下幽靈定義或卡住 scheduled retry。此處不是事件送達重試佇列改造；既有 ingress/event 去重與忙碌時處理方式未擴充。

依測試技能使用固定邏輯時間、隔離暫存資料及 executor gate，不等真實排程也不呼叫模型。先以新增測試重現 `.anyOf` 沒有 nextRun、停用定義未檢查時區、寫檔失敗發布狀態與消耗 claim（`/tmp/filicon-mixed-schedule-red.log`）。修正後新增 13 項測試，涵蓋最早時間／同時命中、逾期合併、事件及手動基準、跨時區與 DST、明確 TZ 覆蓋、閏日搜尋邊界、純事件／未知條件、舊資料不自動啟用、reload、pause/resume、費用防護、暫停中模型不可解除防護、stale batch、語法／時區／巢狀／容量、create/update/enable/fire 寫檔失敗及排程計算失敗回滾。

最終聚焦回歸為 78 項 Swift Testing／8 suites 通過（含參數化 cases），包含既有 cron、ingress、GitHub／Slack／OR、routine 審批、群組／mailbox 核准與拒絕／停止及七語言預覽測試。紀錄 `/tmp/filicon-mixed-schedule-regression.log`。原生 `Filicon App` Debug build（`/tmp/filicon-mixed-schedule-native.log`）、產物嚴格 deep codesign 及 `git diff --check` 通過；只建置，未啟動產物。無新 UI 文案；本輪沒有新增視覺驗收。

IORegistry 仍回報 `CGSSessionScreenIsLocked=Yes`，上一批完整回歸受 `.completeFileProtectionUnlessOpen` 檔案重新讀取限制仍未解除；本輪不重複把已知受鎖定影響的全套測試當作成功，未削弱檔案保護。解鎖後仍須重跑完整套件。這不是 live 模型、外部事件服務或 release 公證驗收。

本批引擎修改已在下一輪提交為 `6882ba4`；提交前再次通過 78 項聚焦測試（`/tmp/filicon-mixed-schedule-precommit.log`）。未 push、未重啟 App，未更動實際群組、聊天或排程。

## 本輪增量：模型混合時間／事件提案與完整核准（2026-09-19，完整回歸待解鎖）

上一批已提交為 `6882ba4`。再次核對 reconstructed `source/host/automations/automation-trigger.ts` 與 `source/host/runner/tools/sand-state-tool.ts` 的 cron member、flat group／array 與 schedule／trigger 互斥格式，接上群組／mailbox 的混合條件建立、修改及核准。沒有增加其他平台或外部連線。

- `trigger:{type:"cron",schedule:"..."}` 可單獨使用，或與 GitHub／Slack 放入 1–8 項 group／裸陣列，也支援純時間組合。時間字串正規化空白，所有成員驗證後排序、精確去重，單項折疊；相同 call 的重排／重複成員不造成第二次寫入。未知欄位、null、錯誤型別、巢狀、超量、其他平台及同時傳入 top-level schedule／trigger 仍整份拒絕，不忽略無效條件。
- 每個時間條件在核准前固定當次 App 時區，可由有效 TZ/CRON_TZ 前綴覆蓋；模型不能另外夾帶 timeZoneIdentifier 或 member-level enabled/prompt。模型提案每項時間條件皆須在 366 天內可執行，間隔限 1 分鐘至 366 天；停用提案同樣驗證。這比內部引擎容許 dormant calendar 分支更嚴格，不宣稱兩層限制相同。
- 核准顯示完整新舊任務、trigger JSON、enabled 與每個時區；七語言新增最早時間、同時命中一次、不補跑、事件／手動執行重設間隔及可能增加模型費用的說明。不是每個條件獨立計時，也不是新增手動混合條件編輯器。
- 新增／重新排程從核准提交時安排，不立即 Run Now。只改名稱／prompt 保留最新 nextRun、lastRun 及歷史；核准等待中發生事件執行，也不被舊 snapshot 覆蓋。可與純時間、單一事件及事件組合互換。owner、四次共用額度、50 項容量、費用防護、fresh approval、Stop／帳號切換、stale 及原子儲存／durable receipt 邊界保留。

依測試技能使用隔離暫存資料、固定時間、受控 provider／executor 及 CustomDump；依 SwiftUI 技能將條件判斷保留在既有資料與核准層，呈現可換行的完整說明。驗證包括 interval 兩端邊界、TZ／CRON_TZ、1／8 項、重排與去重、最早 nextRun、開／關建立、事件執行與修改競合、history/reload，以及群組／mailbox 拒絕、Stop、帳號切換、owner、費用防護、容量、寫檔失敗與持久 receipt。測試曾因 fixture 使用錯誤 Slack payload key `reactionEmoji` 失敗，已改成 normalizer/matcher 實際使用的 `reaction`，未放寬產品過濾器。

最終驗證：

- 85 項 Swift Testing／8 suites 通過（包含參數化 cases），紀錄 `/tmp/filicon-mixed-routine-verified.log`。
- 七語言各 1,480 keys、零缺漏。核准元件 create/update mixed 均產出七語言 PNG；繁中 update 及法文 create 已目視確認完整條件與所有警告沒有裁切。預覽位置 `/tmp/filicon-mixed-routine-review/`；這是核准元件檢查，不是全產品逐頁驗收。
- 原生 `Filicon App` Debug build 成功（`/tmp/filicon-mixed-routine-native.log`），產物 `codesign --verify --deep --strict` 通過；未啟動產物。`git diff --check` 通過。沒有使用付費模型、正式 Slack/GitHub 帳號或外部 webhook；不是 release 公證驗收。

IORegistry 仍回報 `CGSSessionScreenIsLocked=Yes`。完整回歸的受保護檔案重新讀取限制仍在，未為過關而削弱保護；解鎖後仍須重跑，不能將聚焦通過說成全套通過。完整 reconstructed parity 仍缺其他平台模型寫入、Slack 名稱／人類身分解析、GitHub checks 彙整，以及前述 memory／runtime／state 差異。

本批提案與核准修改已在下一輪提交為 `64ce20b`；提交前再次通過 85 項聚焦測試（`/tmp/filicon-mixed-routine-precommit.log`）。未 push、未重啟 App，未更動使用者實際群組、聊天或排程。

## 本輪增量：Linear 事件分類、送達識別與防重播基礎（2026-09-19，完整回歸待解鎖）

上一批已提交為 `64ce20b`。核對 reconstructed `automation-trigger.ts` 的 issueCreated／statusChanged／endOfCycle 與篩選規則，以及 `sand-state-tool.ts` 的 Linear schema 後，發現既有 ingress 尚未把事件轉成可用的原版 case，且 `webhookId` 被誤用為送達 ID。參照 [Linear 官方 webhook 格式與驗證說明](https://linear.app/developers/webhooks)（2026-09-19 查閱）：Linear-Delivery 識別送達，webhookId 識別 webhook 設定；updatedFrom 表示變更前的屬性，HMAC 僅涵蓋原始 body，webhookTimestamp 位於已簽章的 body。

本輪只修正事件處理底層，尚不開放 Linear 模型 create/update，也未新增設定頁或連線：

- 保留既有 `event:issue` entity 名稱，另外產生 `eventCase:issueCreated`／`statusChanged`，供 Linear case matcher 精確判斷。只接受有有效 issue ID 的 Issue/create；狀態改變須 Issue/update、有效的目前 stateId，以及 updatedFrom 的不同舊 stateId 或 null。只有標題變更、未變的狀態、錯誤型別、其他 entity／action 都不冒充上述 cases；不從 Cycle 更新猜測 endOfCycle。
- `primaryIDs` 沿用實際 team ID、`secondaryIDs` 沿用 project ID；缺少 team 不再用 issue ID 代替，設定了篩選卻缺少相應欄位即不匹配。保留舊 CaseAutomationTrigger 的儲存格式與既有 entity-event 匹配，不自動修改或啟用使用者的排程。statusIds／cycleIds 等完整原版篩選及提案核准仍待接線。
- externalEventID 改用有效的 Linear-Delivery，缺省時使用已簽章 body 的 SHA-256 摘要，不再使用共用 webhookId。空白、控制字元及超過 200 字元的 delivery ID 拒絕，不截斷成可能碰撞的值。不同 issue／送達不再被同一 webhook 設定 ID 吞掉；事件依現有規則先過濾再進 prompt。
- HMAC 驗證後，只採信 body 內數值且有限的 webhookTimestamp，拒絕布林／字串／null／缺少時間。沿用既有 replayWindow（預設 300 秒），不採信未簽章的 Linear-Timestamp 覆蓋。ingress nonce 固定取 body 摘要，因此更換 delivery／timestamp 標頭不能重播相同簽章內容；時間窗內重新載入仍去重。既有 automation history 的送達去重保留。此處不是永久收據、重試佇列或跨版本歷史遷移；不自動重送先前遺漏的事件。

依 Swift 測試技能，在 ingress controller 注入預設仍為實際時間的時鐘 closure，fixture 用固定時間、隔離資料及受控 executor，避免依賴真實排程或外部帳號。新增 9 項測試，先重現 21 個失敗斷言（`/tmp/filicon-linear-ingress-red.log`），再驗證不同送達、無 delivery 標頭 fallback、標頭變造／body 變造／錯誤簽章／過期／錯誤時間、事件分類、缺少／不符篩選、legacy Codable、過濾早於 prompt、history 去重及 ingress 重開。完整簽章 → controller → normalizer → matcher → executor → history 路徑使用固定 fixture，沒有啟動 Linear listener、連線 Linear 或付費模型；既有 loopback listener 回歸測試維持原樣。

最終聚焦回歸為 94 項 Swift Testing／9 suites 通過（含參數化 cases），涵蓋既有 GitHub／Slack／OR／時間排程及群組／mailbox 審批，紀錄 `/tmp/filicon-linear-ingress-regression.log`。原生 `Filicon App` Debug build（`/tmp/filicon-linear-ingress-native.log`）、產物嚴格 deep codesign、七語言各 1,480 keys 零缺漏與 `git diff --check` 通過。無新增 UI 畫面，本輪不宣稱新增視覺驗收；不是 live Linear 或 release 公證驗收。

此基礎批次已在下一輪提交為 `5241434`；提交前再次通過 94 項聚焦回歸（`/tmp/filicon-linear-ingress-precommit.log`）。當時 Mac 仍鎖定，完整回歸尚待解鎖，未削弱保護。未 push、未重啟 App，未更動使用者實際群組、聊天、排程或連線。

## 本輪增量：Linear 模型排程提案、精確篩選與核准（2026-09-19）

上一批已提交為 `5241434`。依 reconstructed `sand-state-tool.ts` 的 Linear shape，接上 group/mailbox 的自身 routine create/update，支援 issueCreated、statusChanged、teamIds、projectIds 與改變後的新 statusIds；不支援 endOfCycle／cycleIds，亦不猜測 Cycle 更新。可和 cron／GitHub／Slack 組成最多 8 項平面 OR 條件，沿用最早排程／事件去重及完整核准語意。

- 模型每份 ID 清單最多 50 個 UUID，先檢查原始數量與所有值，再統一大小寫、去重排序。省略與空清單皆表示不限；issueCreated 不接受 statusIds（即使空清單）。未知欄位、null、錯誤型別、名稱、無效 UUID 與不支援的 case 一律拒絕，不能丟棄條件後繼續。核心提交再次驗證，不只依賴工具 schema。
- 新 `LinearAutomationTrigger` 與其他平台型別分離，沿用舊 event／primaryIDs／secondaryIDs 儲存欄位及 enum 包裝；statusIDs 缺省為空，明確 null 不視為缺省。舊 `issue` 定義維持 entity matching，不自動升級、啟用或重播。team/project/status 指定時全部必須匹配，缺少欄位不放行；UUID 大小寫一致處理，legacy 非 UUID 值維持精確比對。
- 每次預覽完整新舊 prompt／trigger／enabled，新增七語言 Linear 限制說明，揭露既有驗證入口、不安裝連線、空清單不限、只看真正事件與可能的模型費用。原有四次修改預算、owner 綁定、Stop／帳號切換撤銷、費用防護與持久化收據均沿用。未新增手動 Linear 編輯器、名稱解析、外部連線或自動化工具權限。
- 依 Swift 測試技能使用隔離暫存資料、固定邏輯時間、受控 provider/executor/gate 與 CustomDump；涵蓋 create/update、完整核准與拒絕、0/50/51 邊界、status 改變後篩選、缺少 ID、舊 Codable、核心繞過拒絕、UUID 正規化／重播、時間及事件轉換、省略保留、歷史重開、費用保護、容量、延遲 commit／Stop／帳號切換與 mailbox owner。App OR fixtures 現在含 GitHub／Linear／Slack，mixed 再加入 cron。

最終聚焦回歸 101 項／9 suites 通過（`/tmp/filicon-linear-proposals-final-regression.log`）。七語言共 105 個核准預覽（15 情境 × 7 語言），固定 380 點寬度檢查容納高度；另實際檢視繁中修改與法文建立圖，未見截字。測試截圖改以內容 fitting height 輸出，避免空白邊界；不是完整產品逐頁視覺驗收。各語言 1,482 keys、零缺漏。原生 `Filicon App` Debug build（`/tmp/filicon-linear-proposals-native.log`）及產物 `codesign --verify --deep --strict` 通過，未啟動產物；仍有既有 AppIntents metadata 略過及 ad-hoc runtime 提示。

這次系統不再回報先前的鎖定旗標，完整套件沒有重現受保護檔案重新讀取失敗。預設執行完整套件時，134 XCTest 通過，但 Swift Testing 有 5 項既有測試／6 個斷言失敗：conversation 取消／跨 conversation 並行、subagent steer、程序 stdout 及群組核准重複觀測（`/tmp/filicon-linear-proposals-full.log`）。這 5 項隔離重跑皆通過（`/tmp/filicon-linear-proposals-failure-recheck.log`）；明確 `swift test --no-parallel` 的完整重跑為 **134 XCTest、774 Swift Testing／91 suites，全數通過**（`/tmp/filicon-linear-proposals-full-serial.log`）。兩項需 opt-in 的 live Codex 測試未執行。保留並行不穩定問題，不宣稱本輪已根治，也未放寬檔案保護或調整那些測試的門檻。

本批 Linear 模型提案與核准修改已在下一輪提交為 `866b368`；提交前再次通過 101 項聚焦測試（`/tmp/filicon-linear-proposals-precommit.log`）。未 push、未重啟使用者 App、未改真實聊天／群組／排程／連線，未連線 Linear 或付費模型。完整原版 parity 仍未完成；後續仍有 Linear 週期結束、其他平台模型提案、Slack 名稱／人類身分、GitHub checks 彙整及記憶／runtime 差異。

## 本輪增量：Sentry 事件分類、專案篩選與防重播基礎（2026-09-19）

上一批已提交為 `866b368`。核對 reconstructed `source/host/automations/automation-trigger.ts` 的 Sentry cases／projectIds 與 `sand-state-tool.ts` schema，以及 [Sentry webhook 說明](https://docs.sentry.io/integrations/integration-platform/webhooks/)和 [issue payload](https://docs.sentry.io/integrations/integration-platform/webhooks/issues/)（2026-09-19 查閱），確認既有 normalizer 讀錯專案位置，也未把 action 轉成原版 cases。這輪只補事件基礎，不開放 Sentry 模型 create/update、不新增專用編輯器或外部連線。

- `Sentry-Hook-Resource: issue` 加上有效十進位字串 issue ID，才將 created／resolved／assigned／archived／unresolved 對應成五種 canonical issue case。issueAny 只接受這五類，不接受 comment／installation／error／alerts、未知 action 或無效 issue；不把 action 相同的其他 resource 當 issue。舊式 ignored action 未擅自當成目前文件的 archived；舊 raw-action 排程仍可依原有規則處理。
- canonical `primaryIDs` 精確比對 `data.issue.project.id`，不使用 slug、名稱、issue ID、installation 或頂層 data.project 代替。指定篩選但缺少或無效 ID 即不匹配，空清單才代表不限；不支援的 secondaryIDs 非空即拒絕匹配。保留 CaseAutomationTrigger Codable 與舊 raw-action 的 event／primaryId／secondaryId 比對，不改寫或啟用使用者定義。
- HMAC 只涵蓋 body，因此 nonce 和 externalEventID 都使用 body SHA-256；Sentry 文件的 Request-ID 與既有 sentry-hook-request-id alias 僅作診斷，前者優先，兩者都需非空／無空白控制字元／最長 200 字元。相同 body 即使更換標頭仍視為同一事件；同一 issue 不同 action/body 不會因共用 installation 或 Request-ID 而遺漏。相同 body 的不同合法送達亦會合併，這是明確的保守去重行為。
- ingress nonce 快取仍受既有時限限制（預設 300 秒），重開可讀回；時限後已有且仍保留的 run history 仍依 body digest 去重。Sentry 未提供簽章涵蓋的時間戳，本輪不宣稱能驗證新鮮度或永久防重播；兩層紀錄過期後，舊的有效簽章仍可能被接收。保留原有可選 x-filicon-timestamp 檢查，但該值不是 Sentry 簽章證據。未遷移舊收據，也未新增重試佇列。

依 Swift 測試技能採固定時間、隔離暫存目錄、受控 executor／secret 與 CustomDump，先重現 60 個失敗斷言（`/tmp/filicon-sentry-events-red.log`），再使新增 8 項 Sentry 測試通過。包含五種事件、issueAny、錯誤 resource／action／ID、legacy Codable、body／secret 變造、標頭重命名、Request-ID alias、過長 ID、簽章前綴、先過濾再進 prompt、ingress 重開及超過快取時限後的 history 去重。無實際模型、帳號或公網呼叫；完整簽章至 executor/history 路徑在隔離 fixture 內驗證。

依 SwiftUI 技能，安全與事件邏輯仍留在非 UI 模組，設定 caption 只透過既有語言目錄呈現。本輪更新的 Sentry 驗證說明已補七語言，新增測試確認翻譯與協定欄位名稱；七語言各 1,483 keys、零缺漏。未新增畫面配置，不宣稱全產品視覺驗收。

驗證：117 項 Swift Testing／11 suites 聚焦回歸通過（`/tmp/filicon-sentry-events-regression.log`）；明確 `swift test --no-parallel` 完整回歸為 134 XCTest、783 Swift Testing／92 suites 通過（`/tmp/filicon-sentry-events-full-serial.log`），兩項 opt-in live Codex 測試未執行。既有通用 ingress fixture 亦改用 Sentry 文件的 Request-ID 與 data.issue.project 格式；舊格式由專門的 legacy 測試保護。上一批發現的並行測試時序不穩定未宣稱已修復。原生 `Filicon App` Debug build（`/tmp/filicon-sentry-events-native.log`）、產物 `codesign --verify --deep --strict` 及 `git diff --check` 通過；只有既有 AppIntents metadata／ad-hoc runtime 提示，未啟動產物。

此 Sentry 基礎批次已在下一輪提交為 `ca8e570`；提交前再次通過 117 項聚焦回歸（`/tmp/filicon-sentry-events-precommit.log`）。未 push、未重啟使用者 App、未動實際聊天／群組／排程／連線。原版全部能力仍未完成，不能將這批底層測試當成 Sentry 帳號端到端或產品全量驗收。

## 本輪增量：Sentry 自身排程提案與完整核准（2026-09-19）

上一批已提交為 `ca8e570`。依 reconstructed `source/host/runner/tools/sand-state-tool.ts` 的 Sentry shape 與 `source/shared/automations.ts` 六種 cases，接上群組／mailbox 的自身 routine create/update。可單獨使用或與 cron、GitHub、Slack、Linear 組成最多八項平面 OR 條件；並未接上其他平台或暗中建立外部連線。

- 支援 issueCreated／issueResolved／issueAssigned／issueArchived／issueUnresolved 及 issueAny；最後一項僅指前五種 issue cases，不包含所有 Sentry 事件。`projectIds` 空白／省略表示任意專案；最多 50 個精確十進位字串，各 1–200 位 ASCII 數字，先驗證原始清單再排序去重。保留前導零，不做數值轉換、名稱／slug 查找或修剪無效 ID。
- schema、解析器與核心寫入均有驗證。拒絕 null、錯誤型別、未知欄位／事件、secondary/team/status filters、超限及巢狀群組；混合組合中任一項無效就整份拒絕，停用提案也不例外。既有 raw-action 定義保留原意，不允許透過模型 update 偷換為新 canonical case；既有 pause/resume/delete 語意未改。
- 沿用固定 owner、完整 before/after、enabled、時區核准、四次共用變更預算、50 筆容量、費用防護、Stop／帳號與等待期間變更的取消邊界、原子儲存和 durable receipt。修改保留歷史，可在核准後切換 Sentry／時間／混合條件；未要求立即執行或補跑，不授予新工具權限。
- `CaseAutomationTrigger` 的 ID 集合以排序陣列編碼，使持久化和核准 JSON 穩定；儲存鍵與解碼型別不變，也保留 PagerDuty／舊資料語意。七語言提示明示既有驗證連線、五種 issue 範圍、精確 ID、有限重播保護、無簽章新鮮度證明、佇列事件與費用。

依 Swift 測試技能使用固定時間、隔離資料、受控模型與 CustomDump，先重現 4 個 create 參數案例的 invalidDefinition（`/tmp/filicon-sentry-proposals-red.log`），再補六種 case／ID 邊界、核心繞過、歷史保留、重複請求、完整核准與取消／拒絕／帳號切換／費用防護／容量／儲存失敗測試。群組與 mailbox fixtures 均包括 Sentry 單項及所有已支援平台的混合條件。沒有呼叫實際模型或外部帳號。

依 SwiftUI 技能，安全邏輯仍留在 service/parser，核准 UI 只顯示 host 產生的完整定義與說明。七語言共 119 張核准 fixture 圖成功渲染（`/tmp/filicon-sentry-routine-review`）；實際檢視繁中 update 和法文 create 的 Sentry 預覽，未見截斷；不代表整個產品或所有語言已做人工視覺驗收。目錄各 1,485 keys、零缺漏。

驗證：122 項 Swift Testing／11 suites 聚焦回歸通過（`/tmp/filicon-sentry-proposals-focused.log`）；明確 `swift test --no-parallel` 完整回歸為 134 XCTest、788 Swift Testing／92 suites 通過（`/tmp/filicon-sentry-proposals-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-sentry-proposals-native.log`）、產物 `codesign --verify --deep --strict`、localization audit 與 `git diff --check` 通過；僅既有 AppIntents／ad-hoc runtime 提示。未宣稱已修復先前的並行測試時序問題。

此提案增量已在下一輪提交為 `24431bf`；提交前再次通過 122 項聚焦回歸（`/tmp/filicon-sentry-proposals-precommit.log`）。未 push、未啟動或重啟 App、未更動真實聊天／群組／排程／連線。`AUTO-03` 仍為 partial：後續可核對 PagerDuty 事件與模型提案、Linear endOfCycle／cycleIds、GitHub checks 彙整與 Slack 名稱／身分映射；不能將本批視為原版全部能力或 Sentry live 帳號驗收完成。

## 本輪增量：PagerDuty 事件分類、服務篩選與防重播基礎（2026-09-19）

上一批已提交為 `24431bf`。核對 reconstructed `source/shared/automations.ts`、`source/host/automations/automation-trigger.ts` 與 `sand-state-tool.ts` 的四種 incident cases、incidentAny 和 serviceIds，以及 PagerDuty 官方的 [V3 payload](https://github.com/PagerDuty/developer-docs/blob/main/docs/webhooks/01-Overview.md)、[signature protocol](https://github.com/PagerDuty/developer-docs/blob/main/docs/webhooks/04-Signatures.md) 和 [delivery behavior](https://github.com/PagerDuty/developer-docs/blob/main/docs/webhooks/02-Behavior.md)（2026-09-19 查閱）。本輪只補 ingress／matching 基礎，未開放 PagerDuty 模型 create/update 或新增外部連線。

- 將 incident.triggered／acknowledged／resolved／escalated 對應成 incidentTriggered／incidentAcknowledged／incidentResolved／incidentEscalated；incidentAny 只含這四類，排除 reopened／reassigned／priority_updated、service、未知事件。需 nested event、有效 event.id、resource_type=incident、data.type=incident 與有效 data.id；不將舊平面 payload 自動升級成 canonical 事件。
- canonical primaryIDs 精確篩選 event.data.service.id，且 type 必須為 service_reference；不使用摘要名稱、incident ID、頂層 service 或訂閱 ID，也不忽略大小寫。缺少／無效服務 ID 不得命中指定篩選；空集合表示任意有效事故。secondaryIDs 不受支援且不會被靜默忽略。舊 raw event-type 定義及 primaryId／secondaryId 保留原義與 Codable 格式，不遷移或自動啟用。
- 簽章僅接受逗號分隔的 v1=HMAC(rawBody) 候選值；支援輪替期間多候選，忽略未知版本，不接受裸 digest。用 body digest 作 nonce，避免改 unsigned delivery header 重播或共用 webhookId 漏掉不同事件。用已簽章 event.id 作 history 身分；缺少 ID 的 legacy payload 退回 body digest。存在但無效的事件 ID 直接拒絕，不截斷；事件／事故／服務 ID 與診斷 delivery ID 限非空、最長 200 字元、無空白／控制字元。X-Webhook-Id 及舊 x-pagerduty-delivery alias 僅供診斷，前者優先。
- occurred_at 是事件發生時間，不是送達新鮮度證據；不拿它套 300 秒時限而誤拒絕延後重試。保留原可選 x-filicon-timestamp 檢查，但未宣稱它受 PagerDuty 簽章保護。預設 300 秒 ingress nonce cache 可跨重開，時限後依仍保留的 run history 去重；兩者清除／過期後仍非永久防重播。未遷移歷史收據或新增重試佇列。

依 Swift 測試技能使用固定時間、隔離暫存目錄、受控 secret／executor 與 CustomDump，先重現 8 項測試中的 63 個失敗斷言（`/tmp/filicon-pagerduty-events-red.log`），再使全部通過。包含四種事件、incidentAny、wrong-platform/resource/type/ID、精確服務篩選、legacy round-trip、UTF-8 本文、版本／輪替／body 與 secret 變造、未簽章標頭變更、長 ID、重開與快取時限後 history 去重。同一事故不同事件不漏發，同一 signed event ID 換 envelope 仍只執行一次。受控 ingress→service→executor/history 流程驗證先篩選再進 prompt，未呼叫真實模型或 PagerDuty 帳號。

驗證：131 項 Swift Testing／12 suites 聚焦回歸（`/tmp/filicon-pagerduty-events-focused.log`）；明確 `swift test --no-parallel` 完整回歸為 134 XCTest、797 Swift Testing／93 suites 通過（`/tmp/filicon-pagerduty-events-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-pagerduty-events-native.log`）、產物 `codesign --verify --deep --strict`、localization audit 與 `git diff --check` 通過。驗證說明已有七語言，各 1,486 keys、零缺漏；測試檢查翻譯和協定欄位名稱，沒有新增版面或宣稱全產品人工視覺驗收。完整回歸仍有 CoreData NSXPC 診斷但零測試失敗，原生建置為既有 ad-hoc runtime 提示；先前並行時序穩定性問題未宣稱修復。

此 PagerDuty 基礎批次已在下一輪提交為 `e92a1de`；提交前再次通過 131 項聚焦回歸（`/tmp/filicon-pagerduty-events-precommit.log`）。未 push、未啟動或重啟使用者 App、未改實際聊天／群組／排程／連線。`AUTO-03` 仍為 partial；下一批可接 PagerDuty 自身模型排程提案、完整核准及混合 OR。其他剩餘差異包含 Linear endOfCycle／cycleIds、GitHub checks 彙整及 Slack 名稱／身分映射，不能將底層 fixture 視為原版完整能力或帳號端到端驗收。

## 本輪增量：PagerDuty 自身排程提案與完整核准（2026-09-20）

上一批已提交為 `e92a1de`。依 reconstructed `source/host/runner/tools/sand-state-tool.ts` 的 PagerDuty shape 與 `source/shared/automations.ts` 五種 cases，接上群組／mailbox 的自身 routine create/update。可單獨使用，或與 cron、GitHub、Slack、Linear、Sentry 組成最多八項平面 OR 條件；不新增外部連線或手動專用編輯器。

- 支援 incidentTriggered／incidentAcknowledged／incidentResolved／incidentEscalated 及 incidentAny；最後一項僅指前四種事故事件。`serviceIds` 省略／空清單表示任意服務；原始清單最多 50 個不透明、區分大小寫的 ID 字串，各 1–200 字元，先完整驗證再排序去重。不修剪或改寫大小寫，不做名稱查找或猜測 ID；拒絕空字串、空白／控制字元與 `*`。不宣稱能從字串外觀驗證服務是否真實存在。
- schema、解析器與核心提交都驗證支援範圍。拒絕未知 case／欄位、null、錯誤型別、secondary filters、超限與巢狀群組；任一成員無效就整份拒絕，停用提案也不例外。舊 raw-event 定義保留原義，不允許模型 update 將它轉為 canonical case；既有儲存格式與 pause/resume/delete 語意維持不變。
- 沿用固定 owner、完整 before/after prompt／trigger／enabled／時區核准、四次共用變更預算、50 筆容量、費用防護、Stop／帳號切換／等待期間變更的取消邊界、原子儲存及 durable receipt。修改保留執行歷史，可核准後切換時間、PagerDuty 與混合條件；省略觸發條件就保留。不要求立即執行或補跑，不授予新工具權限。
- 核准與成功回條明示需既有已驗證入口、不安裝或啟動連線、精確服務範圍、incidentAny 的四類限制、有限防重播、occurred_at 非送達新鮮度證據及佇列事件／模型費用。所有已支援平台的混合 OR 預覽包含每項條件與各平台警告，不隱藏 PagerDuty 限制。

依 Swift 測試技能使用固定時間、隔離目錄、受控 provider／executor／核准 gate 與 CustomDump。先重現四個 create 參數案例的 invalidDefinition（`/tmp/filicon-pagerduty-proposals-red.log`），再補五種 case、0/50/51 清單邊界、1/200 字元、大小寫精確性、核心繞過拒絕、legacy 轉換拒絕、完整核准、歷史重開、重複請求、拒絕／停止／帳號切換／費用防護／容量／儲存失敗測試。群組核准矩陣為 16 種情境 × 四種結果，跨對話 mailbox 的 16 種情境亦檢查 recipient owner，包含 PagerDuty 單項與混合 OR。未呼叫真實模型或外部帳號。

依 SwiftUI 技能，解析與安全邏輯留在 service，核准元件只顯示 host 產生的完整定義及說明。七語言共 133 張 routine 預覽（19 情境 × 七語言）於固定 380 點寬度成功渲染，並檢查 fitting height；輸出 `/tmp/filicon-pagerduty-routine-review.TS0Ovo/`。實際檢視 `routine-update-pagerduty-zh-Hant.png`、`routine-create-pagerduty-fr.png` 與 `routine-create-mixed-zh-Hant.png`，未見內容裁切；不是全產品逐頁或七語言逐張人工驗收。各語言 1,488 keys、零缺漏。

驗證：136 項 Swift Testing／12 suites 聚焦回歸通過（`/tmp/filicon-pagerduty-proposals-focused.log`）；明確 `swift test --no-parallel` 完整回歸為 **134 XCTest、802 Swift Testing／93 suites 通過**（`/tmp/filicon-pagerduty-proposals-full.log`），兩項 opt-in live Codex 測試未執行。原生 `Filicon App` Debug build（`/tmp/filicon-pagerduty-proposals-native.log`）、產物 `codesign --verify --deep --strict`、localization audit 與 `git diff --check` 通過。完整測試仍有 CoreData XPC 診斷但零失敗；原生建置為既有 ad-hoc runtime 提示。未宣稱已修復先前的並行測試時序問題，也不是真實 PagerDuty 帳號或 release 公證驗收。

此提案批次已在下一輪提交為 `abd68c5`；提交前再次通過 136 項聚焦回歸（`/tmp/filicon-pagerduty-proposals-precommit.log`）。未 push、未啟動或重啟使用者 App、未改實際聊天／群組／排程／連線。`AUTO-03` 仍為 partial：仍缺平台專用編輯器、Linear endOfCycle／cycleIds、GitHub checks 彙整及 Slack 名稱／身分映射等完整語意；不能把本批增量稱為原版所有能力皆已完成。

## 本輪增量：原生 Linear 週期完成事件與精確篩選基礎（2026-09-20）

上一批已提交為 `abd68c5`。核對 reconstructed `sand-state-tool.ts`、`automation-trigger.ts`、`sand-automation-cloud-trigger.ts` 與 `sand-automation-fire-consumer.ts`，確認原版將 endOfCycle／cycleIds 送到雲端，收到的是已分類的完成通知，並非本機將一般 Cycle 更新直接當成週期結束。此輪提供 macOS 的原生 webhook 適配，不能宣稱已還原雲端全部語意。

2026-09-20 查閱 [Linear webhook 文件](https://linear.app/developers/webhooks)及官方 SDK 的 [Cycle schema](https://github.com/linear/linear/blob/3addb24bdf771700da1c050742e70e645cc7e36a/packages/sdk/src/schema.graphql)、[CycleWebhookPayload](https://github.com/linear/linear/blob/3addb24bdf771700da1c050742e70e645cc7e36a/packages/sdk/src/_generated_documents.ts)：更新包含先前變更值，completedAt 為完成時間；Cycle 有 teamId，但沒有 projectId。以下事件判定是基於這些欄位的本機保守實作，尚未取得 live 帳號驗證：

- 必須是已驗證的 Cycle/update、有效 cycle/team UUID、`updatedFrom.completedAt` 明確為 null、新 completedAt 為有效且不晚於本機接收時間的帶時區時間戳，才產生 eventCase=endOfCycle 與正規化 cycleId。不靠 endsAt 是否過期、時鐘前進、封存、進度、名稱或缺少舊值推測；一般完成與提前完成都可符合，不必等待舊 endsAt。
- 只以 team UUID 和 cycleIDs 精確篩選；UUID 忽略字母大小寫，空集合表示不限。原生 Cycle 沒有專案關係，要求 project 篩選即不匹配，即使 payload 額外帶 projectId 也不放行；不從 issue 或名稱補猜。週期不接受 statusIDs，issue／其他事件不接受 cycleIDs，不能忽略不支援的限制。
- 既有 Linear 儲存鍵及舊建構介面保留，新增 cycleIDs 只在非空時寫出排序陣列，缺省解碼為空，明確 null／錯誤型別拒絕。舊 issue／cycle entity matching 保留；raw endOfCycle 標籤本身不作完成證據。沒有自動改寫或啟用任何既有定義。
- 已分類完成的 externalEventID 由 cycle UUID 與毫秒精度的完成時間組成；等價時區表示、新 delivery header、重新簽章且刷新 webhookTimestamp 的重試，均不能重複執行仍保留的完成紀錄。不同 cycle 或較晚完成時間則區分；既有 connector scope 繼續隔離事件身分。其他 Linear 事件維持 Linear-Delivery／body digest fallback。簽章、signed webhookTimestamp 時限和 body digest 快取不放寬；歷史及快取過期後仍非永久去重，未新增 poller、連線或公開入口。

本輪先做底層，不開放 cycle 的模型 create/update 或編輯器；既有 Linear 提案入口仍明確拒絕 endOfCycle／cycleIds，核心亦拒絕直接繞過寫入，不會顯示已支援卻無完整核准說明的選項。下一批需接上提案、完整變更核准、專案篩選限制與七語言提示。

依 Swift 測試技能使用固定時間、隔離資料、受控 executor／secret 與 CustomDump，先以兩項測試重現 14 個分類／身分斷言失敗（`/tmp/filicon-linear-cycle-red.log`），再補八項測試：明確完成／提前完成、無效與未完成事件、時間格式與未來值、UUID／專案／狀態篩選、legacy Codable、核心提案拒絕、純時間前進不得觸發、簽章至 executor/history 的先篩選再執行、重開及超過快取期限後的去重。核准、費用、Stop、群組／mailbox 等既有回歸保持通過；未呼叫真實模型或外部帳號。

聚焦回歸為 144 項 Swift Testing／12 suites 通過（`/tmp/filicon-linear-cycle-regression.log`）。明確 `swift test --no-parallel` 完整回歸為 **134 XCTest、810 Swift Testing／93 suites 全數通過**（`/tmp/filicon-linear-cycle-full.log`），兩項 opt-in live Codex 測試未執行；不宣稱已修復先前的並行時序問題。原生 `Filicon App` Debug build（`/tmp/filicon-linear-cycle-native.log`）及產物 `codesign --verify --deep --strict` 通過；本輪未啟動產物。七語言各 1,488 keys、零缺漏，沒有新增 UI 版面，不宣稱本輪另做全產品視覺驗收。完整測試仍有既有 CoreData XPC 診斷但零失敗，原生建置有既有 AppIntents metadata／ad-hoc runtime 提示；`git diff --check` 通過。這不是 live Linear 或 release 公證驗收。

此底層批次已在下一輪提交為 `ddf7587`；提交前再次通過 144 項聚焦回歸（`/tmp/filicon-linear-cycle-precommit.log`）。未 push、未重啟使用者 App、未更動實際群組／聊天／排程／連線。`AUTO-03` 維持 partial；當時 cycle 模型提案／專用編輯器、原版雲端專案歸屬、GitHub checks 彙整、Slack 名稱／人類身分映射等差異仍在。
