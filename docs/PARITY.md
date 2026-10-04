# Filicon / Grok Bot 0.18 功能 parity matrix（current implementation）

2026-10-05 hidden confirmation 的 Stop 增量：審核 ID 在原 run admission 時保留，不因 broker 解決便遺失尚未保存完成的卡；點擊同步捕捉 original execution，晚到 action 不重獲無 fence 的保存權限。正常回合等待已點擊的 review 保存完成後才寫 final snapshot；取消立即撤銷／解除等待，只退休原 owner unfinished rows 及窄投影取消卡，已完成／無關內容與 local permission gate 保留。有效 SQL 故障紅燈、65 項最後聚焦、完整 source gates 與未完成外部邊界見 [完成驗收入口](Parity-completion-audit.md)。

2026-10-04 群組 unread UI 增量：真正群組側欄顯示 canonical count 至 `99+`、七語右鍵 read／unread；人類點選明確讀原群組，focus／arrival 保留 manual-unread。排隊前同步派生原 store／membership／account lease，refresh 不 retarget／撤銷人類選擇；away-and-back、過期 visible history 與保存失敗均保守拒絕。真正 App member-publication callback 刷新 projection，read 不回答 question／改排程／授權。來源、有效 UI 紅燈、七語明暗實際 sidebar 與最後 gates 見 [完成驗收入口](Parity-completion-audit.md)。這取代下段 storage-only 的 UI 未接線記述；真人 focus／VoiceOver、完整群組帳號隔離、cross-instance／process CAS、legacy fallback、雲端及其他外部／release／全 48 分類仍保留，整體 partial 不上調；未 push、重啟使用者 App／Xcode 或改真實資料。

2026-10-04 群組 unread storage 增量：精確 group ID 的 read fields／manual flag／count／activity receipt IDs 與公開訊息同一 atomic JSON envelope 保存；歷史 seed／replay、工具更新與 metadata 不重算。完整保存失敗回滾；原 GroupService instance／membership／可撤銷 host lease 到 final save，automatic view 不清新 arrival 或後來的 manual-unread，read 不回答 question 或放寬權限。69 tests／9 suites 聚焦通過；來源與最後 gates 見 [完成驗收入口的「群組聊天的 canonical 已讀／未讀儲存基礎」](Parity-completion-audit.md)。本批只有 storage foundation；群組 sidebar count／manual actions／visible callback／refresh、真人／VoiceOver、完整帳號隔離與其他外部／全 48 分類仍保留，整體 partial 不上調；未 push、重啟 App／Xcode 或改真實資料。

2026-10-04 hidden activity-answer acknowledgment 增量：實際 host 選擇及 native receipt 落盤後，原 account／agent／canonical chat 的 shared runner 做一次無假 user row 的短確認；忙碌／pending 人類回覆時 click FIFO 排隊，process-local queue 上限 64、重開不 replay。原 binding lease／account generation／provider identity 直到訊息及 review card SQL commit，工具／peer／記憶同意不放寬；模型失敗不回滾排程選擇或補跑舊任務。Stop／ownership cycles 拒絕晚到模型發表，native cleanup 僅取消原 owner 的已知 unfinished run／review IDs，不覆蓋快照／無關內容；172 tests／7 suites 聚焦通過。來源、有效紅燈及本批最後 gates 見 [完成驗收入口的「回答活動卡片後的原聊天確認回合」](Parity-completion-audit.md)。只取代下方 canonical direct branch 的 hidden acknowledgment 差異；legacy fallback、group state、帳號遷移、雲端及真人／live／release／全 48 分類仍保留，整體 partial 不上調，未 push／重啟 App 或 Xcode／改真實資料。

2026-10-04 retained nudge 回答增量：automatic pause 後，同一 cycle 的未回答原 nudge 可使用其原 Keep／Pause／Never ask 選項；新 paused 卡片保留 Resume／Stay paused。只接受原 host outbox entry、account／owner／chat／lease；cycle 結束、已回答、錯選項、ownership cycle 或模型／匯入 metadata 不取得 authority，無 entry 的 workspace 回呼仍要求當前 stage。兩個 stages 必須共用原目的地，矛盾 outbox 不改寫來源。沒有新模型回合、工具／記憶授權或真實資料修改；最後證據見 [完成驗收入口的「同一次檢查保留原卡片的回答選項」](Parity-completion-audit.md)。本項取代下方歷史 retained nudge 唯讀差異；hidden model acknowledgment、legacy fallback、group state、帳號遷移、雲端及真人／live／release／全 48 分類仍保留，整體 partial 不上調，未 push／重啟 App 或 Xcode。

2026-10-04 背景活動提醒增量：canonical direct chat 的第一次 nudge，先保存原 account／owner 的永久卡片，再將 host reminder 附於同一次 background wake；manual／reviewed group／後續 awaiting-ack 不重送，重開／scope replacement／view／answer 不復活。原始 binding／lifetime、await 後 admission 重驗與即時時區已測試；不增加模型回合、工具／記憶權限，不將 reminder 或假回答寫入聊天。最後聚焦 151 tests／6 suites、完整串行 135 XCTest＋1,830 Swift Testing（220 suites，兩項 opt-in live 測試略過）、原生建置／隔離 Debug 封裝簽章及七語各 1,795 keys／0 missing 通過。來源、有效紅燈及本批最終 gates 見 [完成驗收入口的「背景回合的一次性活動提醒」](Parity-completion-audit.md)。只取代 canonical branch 的「host nudge reminder 未接線」；hidden model answer acknowledgment、retained 舊 nudge entry 回答、legacy fallback、group state、雲端／帳號遷移、真人／live／release／全 48 分類仍保留，整體 partial 不上調。未 push、重啟 App／Xcode 或改真實資料。

2026-10-04 活動提醒永久紀錄增量：exact owner 單獨聊天保存 host widget entries 與五種 native system 回答確認；schema 3 immutable outbox 保留各 stage prompt／ack ID 及原目的地，回答＋schedule 同筆保存，聊天另以 canonical transaction 更新 prompt＋ack。保存故障重開可補 receipt，不重套用或 retarget，不宣稱跨 store 原子交易。新 prompt 計一次未讀、ack／replay 不計；舊 owner／phase／account／lease fence 與既有同意不放寬。144 tests／6 suites 聚焦、98 個七語明暗歷史卡 render、日文長標題 OCR、原生建置／離線封裝簽章及七語各 1,795 keys／0 missing 通過。direct／group 原生 paused 卡片拒絕錯階段選項，真正 Resume 保留原有審核及排程執行斷言；核心服務層的 continuing 相容回答不刪除。最後完整串行 `spend-guard-transcript-full-final-v2.log` exit 0：135 XCTest＋1,823 Swift Testing（220 suites，兩項 opt-in live 測試略過）；較早鎖定失敗與 fixture 契約失敗各自保留。詳見 [完成驗收入口的「活動提醒的永久聊天紀錄與回答確認」](Parity-completion-audit.md)。這取代較早「沒有永久 entries／回答確認」，不關閉 reference 舊 nudge entry 的回答差異、hidden model acknowledgment／host reminder、group state、雲端、帳號遷移、真人／live／release／全 48 分類；整體 partial 不上調，未 push、重啟使用者 App／Xcode 或改真實資料。

2026-10-03 聊天活動卡片增量：原生單獨聊天接上 exact owner 的已保存 activity card，與工作區共用五種回答及原有 pause／resume 保存流程。唯一 canonical binding、原始 account generation／lease 與最終同步提交 fence 拒絕換綁定／隱藏／移除／封存／帳號循環、歧義和過期階段；切換聊天不改投人類已點選的回答。查看不回答或恢復，寫入失敗保留可重試卡片，不增加工具／peer／記憶權限。126 tests／6 suites 聚焦及 28 個七語明暗窄版 render 通過，詳細最終 gates 見 [完成驗收入口的「聊天內的原生活動提醒卡片」](Parity-completion-audit.md)。這僅取代「只有自動化工作區入口」；尚非永久 transcript widget entries／回答確認／host reminder，其他 group、雲端、帳號遷移、真人／live／release／全 48 分類保留，整體 partial 不上調。未 push、重啟使用者 App／Xcode 或改真實資料。

2026-10-03 活動 guard canonical source 增量：bound direct-chat routine 的 unread count／view time 現在由當前帳號／exact owner 的 canonical DB 提供，不再按 pending wakes 近似；live repository observation 在成功 COMMIT 後發布，排隊批次仍取最新 read state。explicit activity read 同步更新其唯一 bound chat，但不回答 card 或恢復任務；原始 owner lifetime、reviewed group 豁免及工具核准不變。缺失／損壞／歧義 source 不退回猜測 count，沒有 canonical chat 的明確 legacy text-only host 才保留 fallback。172 tests／24 suites 聚焦通過，最後完整串行 gate exit 0：135 XCTest＋1,795 Swift Testing（220 suites，兩項 opt-in live 測試略過），七語各 1,789 keys／0 missing。完整證據與同 repository／cross-store 邊界見 [完成驗收入口的「活動提醒改讀 canonical 單獨聊天狀態」](Parity-completion-audit.md)。本項局部取代下方同日歷史 counter 未接線的部分；group state、chat widget／host reminder、完整 core account migration、真人／live／release／全 48 分類仍保留，整體 partial 不上調。未 push、重啟使用者 App／Xcode 或改真實資料。

2026-10-03 單獨聊天未讀 UI 增量：canonical count 接上側欄標記及七語右鍵「標示為已讀／未讀」，focused／visible 的當前 native direct chat 自動 viewed，不要求 routine／binding；有 binding 仍重驗 exact account／owner。manual unread 保留至明確人工清除，排隊前擷取 action 身分，換帳號／換綁定循環、封存、移除、失焦與新訊息的舊回呼拒絕；保存失敗不冒充零未讀，舊 refresh 不蓋新手動狀態。這不回答／恢復 activity card；guard canonical counter、group state、widget／reminder、完整 core account migration、真人／live／release／全 48 分類仍保留。新 gate 及 reference 邊界見 [完成驗收入口的「單獨聊天的 canonical 未讀畫面接線」](Parity-completion-audit.md)，下方同日較早未接線描述保留為歷史，整體 partial 不上調，未 push／重啟使用者 App／改真實資料。

2026-10-03 聊天未讀 storage 增量：SQLite schema 17 保存 canonical activity／view time、manual unread 與 count，訊息 ID receipts 與正文同筆交易，串流完成／歷史重存／編輯／還原不重複計數。舊 JSON／schema 16 遷移不產生整批未讀；換綁定不轉移舊 owner 的狀態。exact binding＋同步 commit guard 保護 read action，保存失敗整筆回滾。損壞或缺失 read row 不當成已讀，原始證據保留在 private quarantine；有效 manual state 與刪除訊息 receipts 保留。18 個新增測試及既有回歸共 88 tests／23 suites 聚焦通過；來源、有效紅燈及本批最終 gate 見 [完成驗收入口的「聊天資料庫未讀／手動未讀基礎」](Parity-completion-audit.md)。這只取代下方歷史「沒有聊天未讀資料庫」的描述，畫面 manual-read／unread、visible chat 自動記錄與 guard canonical count 接線、group chat state、widget／host reminder、真人 UI、live／release／全 48 分類仍保留。pending wakes 目前仍是 guard 的近似 signal，整體 partial 不上調。未 push、未重啟使用者 App／Xcode、未改真實資料。

2026-10-03 綁定聊天查看增量：只有目前帳號、唯一 canonical binding、未封存 owner 的單獨聊天，在主工作區真正取得焦點／可見且最新訊息載入後，才更新該 owner 的 automation 活動查看時間；未綁定、跨帳號、歧義聊天或被模態介面覆蓋不接受。畫面切換、失焦、換綁定再換回來及 account generation 使排隊／晚到工作失效；最終保存沿用可撤銷 lifetime 與同 repository 的 binding lease。較舊或相同時間不倒退、不重算舊執行。查看不回答提醒、不解除 guard pause，不修改任務或原有工具核准。43 tests／3 suites 聚焦通過；有效 monotonic 與 queued rebind 紅燈日誌保留，最終完整 gate 紀錄見 [完成驗收入口的「綁定單獨聊天的可見活動時間」](Parity-completion-audit.md)。

最後修正版完整串行 `spend-guard-chat-view-full-post-rebind.log` exit 0：135 XCTest＋1,753 Swift Testing（219 suites，兩項 opt-in live Codex 測試略過）；原生建置／四執行檔封裝簽章、七語各 1,787 keys／0 missing 及 28 個窄版明暗 render 通過。這取代前批「對話查看完全未接線」的部分，不是 reference transcript DB unread／manual-unread 完成：pending wakes 仍為近似 signal，沒有新增聊天未讀資料庫、手動未讀旗標或聊天 widget／host reminder；未綁定聊天仍使用明確 owner 已讀入口。控制模型測試／離屏 render 不等於真人焦點、VoiceOver 或跨 process lease 驗收。雲端 session、完整帳號資料遷移、live／release 及全 48 分類仍保留，整體 partial 不上調。未 push、未重啟使用者 App／Xcode、未改真實資料。

2026-10-03 已審核 group routine 活動豁免增量：trusted host 以 canonical human binding／account／任務 digest／群組成員解析執行 session，不接受模型或匯入的 mode 提示；群組排程不受同 owner 單人活動提醒／pause 影響。batch 保留原 binding ID 與可撤銷 lifetime，撤銷後不換群組或降級 plain；真正人工停用、內容重新審核與原有工具權限不變。新 wakes 保存排程關聯，group 歷史裁至 20 筆後仍不污染單人 unread；未知舊 wake 保守處理，既有 guard-paused group 不自動重啟。177 tests／12 suites 聚焦通過；最後完整串行 gate exit 0：135 XCTest＋1,747 Swift Testing（219 suites，兩項 opt-in live Codex 測試略過），原生建置／四執行檔封裝簽章、七語各 1,787 keys／0 missing 及 28 個窄版明暗 render 通過。詳見 [完成驗收入口的「經審核群組排程的活動保護豁免」](Parity-completion-audit.md)。這取代下方前批「群組仍套用 guard」的本機差異，不關閉真正聊天 unread／widget、雲端 session、帳號資料遷移、live／release 或全 48 分類驗收。

2026-10-03 活動提醒增量：automation spend guard 改為 per-agent 的持久狀態及精確 owner／card／account／generation 回答；打開共用工作區不再把全部代理人當成已讀。「標示為已讀」不回答提醒或解除暫停。Keep／Resume 延後檢查 30 天、Never ask 限該 owner，只恢復 guard 自己暫停的項目並從目前時間重新排程；人工停用不被恢復。自動 pause／resume 保留已審核 definition revision，以獨立 owner dispatch epoch 阻止舊事件／定時／coalesced 批次補跑；寫入失敗不部分變更或提前撤銷 batch。實際 direct／group runner 與 grant 保存回歸通過，不新增工具／背景記憶權限。

最後聚焦 156 tests／11 suites、完整串行 `spend-guard-full-final.log` exit 0：135 XCTest＋1,741 Swift Testing（219 suites，兩項 opt-in live Codex 測試略過），原生建置／四執行檔封裝簽章、七語各 1,787 keys／0 missing 及 28 個窄版明暗卡片 render 通過。原版群組 session 豁免、真正 transcript unread／對話查看、聊天 widget／host reminder、完整帳號資料隔離與 live／release／全 48 分類仍保留；整體 partial 不上調。詳細來源、紅綠燈與原生／封裝 gate 見 [完成驗收入口的「擁有者隔離的自動化活動提醒與安全恢復」](Parity-completion-audit.md)。未 push、未重啟使用者 App／Xcode、未改真實資料。

2026-10-03 用量歸屬增量：一般直接對話收尾現在使用 admission 捕捉的 account＋provider，不把收到的 usage 記到後來選取的帳號／供應商；usage receipt 只更新統計投影，不覆蓋獨立畫面偏好。實際 App 受控 fixture 的成功／失敗 × 三種晚到變更共六種情境通過，最後聚焦 33 tests／3 suites、原生建置／四執行檔封裝簽章與七語各 1,782 keys／0 missing 通過；完整串行 `usage-attribution-full.log` exit 0：135 XCTest＋1,715 Swift Testing（217 suites，兩項 opt-in live Codex 測試略過）。

原版來源再核對：`AutomationRun`／`finishAutomationRun` 沒有 per-routine token／price／cost 欄位，turn usage 另依 session／request 回報 telemetry，spend guard 是閒置／未讀／執行次數提醒而非金額預算。故下方歷史「完整費用彙整」是 Filicon 已知統計／外部驗收邊界，不直接證明原版已有同等功能而本機漏做；未知不當零、provider 數值不冒充已核對帳單。群組／peer／所有取消刪除用量、live billing、release 及全 48 分類仍保留，整體 partial 不上調。來源及紅綠燈證據見 [完成驗收入口的「回合用量歸屬與原版費用契約核對」](Parity-completion-audit.md)。未 push、未重啟使用者 App／Xcode、未改真實資料。

2026-10-03 workflow 接線與無損編輯增量：經人類審核的 workflow prompt steps 現在使用該 account／agent 的既有 bound direct conversation 和真正 shared runner；審核包含完整定義及引用，獨立於 routine grant，manual／scheduled／verified event／replay 保留 runtime 真正 run ID。背景 saved facts 預設關閉、peer 不繼承；SendMessage／問題／委派與本機工具仍保有既有核准。問題使流程進入 `waitingForReply`、停止後續步驟，人類回答不自動續跑整條 pipeline。過期、跨帳號、忙碌及已撤銷審核不得 fallback；定義及引用修改／刪除會取消依賴它的 runtime，保留歷史、不回滾完成效果。workflow／routine 保存第一個 await 前及其後均驗證對話身分，補上舊 UI 投影被 queued snapshot 蓋回後審核誤通過的競態。

編輯器逐步保留 prompt／action 順序、啟用狀態、來源及建立時間，不再 flatten；完整定義 bounds validation、固定底部原生保存／取消、Return／Esc 及 saving 狀態已有實際測試。最後 `workflow-review-race-full.log` exit 0：135 XCTest＋1,714 Swift Testing（217 suites；核心 893／105、App 587／82，兩項 opt-in live Codex 測試略過）；65 tests／9 suites 聚焦、原生建置／四執行檔封裝簽章、七語各 1,782 keys／0 missing 及審核／編輯器各 28 張明暗頂部／底部 render 通過。歷史失敗及鎖定日誌保留，未降低檔案保護。

下方日期段落保留當批歷史，「workflow 全為 text-only」由本次接線取代；未綁定 prompt 仍為有界 text-only。typed action 是 Filicon native 擴充且仍拒絕執行，不逕當作已確認原版缺口。完整成本彙整、遠端 session／cloud metadata、外部服務、release 及全 48 分類獨立驗收仍保留，整體 partial 不上調。詳見 [完成驗收入口的「Workflow 既有對話接線與無損編輯」](Parity-completion-audit.md)。未 push、未重啟使用者 App／Xcode、未改真實帳號或群組資料。

2026-10-03 一般代理人排程接線增量：人類現在可將 routine 綁定至該代理人的既有單獨聊天，使用相同持久對話、persona／模型及 shared tool runner。背景喚醒是暫時 host 資料，不偽造人類訊息、不自動轉送歷史附件；SendMessage、問題卡片、SendToAgent 及本機工具保留真實核准。背景 saved facts 仍須獨立 opt-in，委派不繼承。過期審核／忙碌對話拒絕執行，撤銷／切帳號／刪除／身分變更及最後 SQLite 寫入均有 fence。一般及群組 session 不可互相默默取代；workflow prompt／action、費用彙整、雲端／外部平台及全 48 分類驗收仍保留，整體 partial 不上調。詳見 [完成驗收入口的「經審核 routine 的既有單獨聊天」](Parity-completion-audit.md)。

本批最後串行 gate `routine-direct-session-full-post-translation.log` exit 0：135 XCTest＋1,682 Swift Testing（210 suites；核心 887／103、App 563／78，兩項 opt-in live Codex 測試略過）。原生建置／封裝簽章、七語各 1,754 keys／0 missing 與 14 個明暗 render 通過；最後修正既有日文／韓文 Conversation 誤譯並補語意斷言。驗收僅限隔離 fixtures，不取代 live 帳號、release 或其他分類驗收。

2026-10-03 排程群組接線增量（前一批）：經人類明確審核的既有 routine／既有群組現已使用真正 shared runner、持久群組 seed／publication／互動卡及實際 run ID，三條 manual／scheduled／event 入口共用。背景 saved facts 另有預設關閉、限已審核成員的獨立同意；原有工具核准不放寬，忙碌／等待問題的群組不被打斷，撤銷／切帳號／定義修改與晚到核准均重驗。舊段落中的 automation 全為 text-only 是此前狀態；目前未綁定 routine 與 workflow prompt 仍為 text-only。當時尚缺的一般代理人本機分支由上方新批次補上；workflow action／runner、費用彙整、外部平台及全 48 分類驗收仍保留，AGENT-01／02／04、AUTO-03 整體不改為 complete。詳見 [完成驗收入口的「經審核 routine 的既有群組 session」](Parity-completion-audit.md)。

前一批群組最終串行回歸 exit 0：135 XCTest＋1,660 Swift Testing（核心 882／101 suites、App 546／76 suites；兩項 opt-in live Codex 測試略過），原生建置／封裝簽章與七語各 1,740 keys／0 missing 通過；不取代 live 帳號、release 或其餘分類驗收。

2026-10-03 共用 runner 增量：普通 ToolLoop 每一步必須明確 toolUse 且正常 EOF 後才能執行工具；截斷、取消、缺少完成、stop 與工具矛盾、完成後追加內容／呼叫及晚到錯誤均拒絕。互動 provider 在 stop 送到 consumer 前封閉新 callback；plain TurnCoordinator 與 TextOnlyInference 共用完成判定。Gemini 不再用「曾出現工具」掩蓋 length／cancelled／unknown。聚焦 124 tests／9 suites、完整串行回歸 exit 0：135 XCTest＋1,640 Swift Testing（核心 877、App 532；兩項 opt-in live Codex 測試略過）、原生建置／封裝簽章、七語各 1,724 keys／0 missing 通過。這是背景共用 runner 接線前的執行安全修正，尚未接上完整 background session／group runner 或擴大記憶 audience，不上調整體 partial。詳見 [完成驗收入口的「共用 runner 完成」](Parity-completion-audit.md)。

2026-10-03 背景純文字增量：workflow／automation 共用有界、明確完成的 `TextOnlyInference`；缺少 completion、截斷、取消、工具事件、完成後正文或晚到 transport error 不再誤報成功，明確 silence 與 stop 後 usage 保留。單一回應累計 100,000 UTF-8 bytes，不將截斷當結果；workflow 各步合計上限另保留。最後聚焦 41 tests／4 suites、完整串行回歸 exit 0：135 XCTest＋1,632 Swift Testing（核心 869、App 532；兩項 opt-in live Codex 測試略過），原生建置／封裝簽章及七語各 1,724 keys／0 missing 通過。不宣稱共用協作 runner、工具執行、記憶授權或全 48 分類完成。詳見 [完成驗收入口的「背景純文字完成」](Parity-completion-audit.md)。

2026-10-03 workflow 撤銷增量：切帳號同步撤銷整個多步驟／批次 runtime，四條入口保留原始 lease，晚到核准／provider 結果、後續批次及舊 UI reload 均重驗，最終成功歷史與 UI 投影有同步提交 fence；自有 scope 不被外來 lease 取代，重疊切換未結束不接新工作，取消不刪定義或提前釋放 lane。43 tests／4 suites 最終聚焦、原生建置／封裝簽章及七語檢查通過；最後完整串行回歸 exit 0：135 XCTest＋1,622 Swift Testing（核心 860、App 531；兩項 opt-in live Codex 測試略過）。automation／workflow prompt 仍非 reference background session 的完整管理／群組 runner；既有記憶 consent 限 direct／group／mailbox，未默默擴大到無人值守流程。此為生命週期修正，不上調 AGENT-01／02／04 或 AUTO-03 的整體 partial；詳見 [完成驗收入口的「背景執行流程」](Parity-completion-audit.md)。

2026-10-03 平台再核對：AUTO-03 的 reference production 接線使用 bearer-authenticated 雲端 relay／AutomationsService，不是完整本機後端。GitHub source 已確認 CI-completed 契約，但未提供 all-checks 彙整實作；Slack 名稱／isSelf 與 Teams 已登入驗證也依賴後端。Filicon 的個別 push workflow、明確 Slack ID／非 self 與 Teams fail-closed 邊界仍 partial，未連線真實帳號或借用私有登入。詳見 [完成驗收入口的「平台觸發」](Parity-completion-audit.md)，不以歷史 complete／generic ingress 取代平台驗收。

2026-10-03 最新圖片增量：第七十七階段補齊獨立傳檔十一格式的實際 MIME，新增七條 App 路徑共 77 個案例；第七十八階段修正一般預覽遺漏的 AVIF／ICO／SVG 判定，主圖改取型別化已驗證快照，縮圖為最大邊 256 的 PNG，安全 SVG 顯示最大邊 1,024，原檔不替換。46 項聚焦測試與十四個七語預覽 render 通過。前次鎖定／EPERM 中止日誌保留；受保護探針恢復後，最後全專案串行 gate exit 0：135 XCTest＋1,609 Swift Testing（核心 859、App 527；兩項 opt-in live Codex 測試略過）。原生建置／封裝簽章與七語各 1,724 keys／0 missing 通過。嚴格模型輸入、檔案／圖庫不同上限、SVG 安全子集與 AV／Quick Look URL 邊界不變；更廣格式、完整 lifecycle、其他分類／外部服務仍待驗收，不宣稱全部完成。詳見 [傳檔第七十七／七十八階段](Send-message-files-parity.md)。

2026-10-03 最新 SVG 增量：第七十六階段共用既有頭像 XML 安全驗證器，接入經審核的自包含靜態 SVG 原檔保存與 bounded PNG 顯示；保留腳本、外部資源、CSS／style、動畫與未支援元素拒絕，不宣稱完整瀏覽器 SVG 對等。53 項聚焦測試通過，含實際向量顏色、原檔／alias／重開、九格式 viewer、56 個七語卡片與全部 436 個 canonical App 案例。最新完整串行 gate exit 0：135 XCTest＋1,593 Swift Testing（核心 853、App 517），原生建置／封裝簽章與七語各 1,724 keys／0 missing 通過。更廣 SVG、真實 HEIF、格式變體、獨立傳檔 MIME、完整 lifecycle／外部服務驗收仍保留；詳見 [傳檔第七十六階段](Send-message-files-parity.md)。

2026-10-03 最新媒體增量：第七十五階段以真正 AVIF／ICO bytes 補上經審核本機圖庫及共用 local／remote 預覽；核對來源型別、偽 MIME／截斷拒絕、精確原檔保存／重開、八格式 viewer、42 個七語實際卡片及全部 386 個 canonical App 案例。最後完整串行 gate exit 0：135 XCTest＋1,587 Swift Testing（核心 847、App 517）；原生建置／封裝簽章、七語各 1,724 keys／0 missing 通過。strict incoming／SendToAgent 限制及既有 model history 投影不變；SVG、真實 HEIF、尚未覆蓋的格式變體、獨立傳檔 MIME、完整 lifecycle／外部服務邊界仍保留，不宣稱整體完成。詳見 [傳檔第七十五階段](Send-message-files-parity.md)。

2026-10-03 媒體增量：第七十四階段將經審核的本機圖庫與嚴格 incoming／SendToAgent 圖片入口分開，已補 GIF／APNG／WebP 動畫及 TIFF／BMP／HEIC 顯示；原始 bytes、位置／說明、核准與 scope／quota／CAS 保護不變。核心 27 與 App 12 項聚焦測試通過，含新增 60 個格式、120 個動畫邊界與既有 186 個 canonical App 案例。完整回歸首輪途中 macOS 再度鎖定並保留失敗日誌；受保護探針恢復後，最後全專案串行 gate exit 0：135 XCTest＋1,586 Swift Testing，其中核心 846／97 suites、App 517／74 suites；原生建置／封裝簽章、七語各 1,724 keys／0 missing 通過。HEIF 目前僅 decoder 清單，沒有 genuine fixture 證據；原版明確列出的 SVG／AVIF／ICO、獨立檔案 MIME、快取及真實外部驗收仍保留。圖庫別名搜尋是 Filicon 已知限制，但原版 media index 不索引 text gallery，不列作已確認 parity 缺口；詳見 [傳檔第七十四階段](Send-message-files-parity.md)。

2026-10-02 媒體增量：本機獨立檔案、HTTPS 附件 locator、local／HTTPS 混合文字圖片集已接入 direct、前景／背景群組、mailbox 與 direct peer，包含不可變 bytes 的完整核准、配額、順序保存、重開與撤銷隔離測試。第七十一階段補上遠端 GIF／APNG／WebP 有界內嵌播放；第七十二階段移除人類可見、經審核圖庫的四張限制及 viewer 前 50 張截斷，補上有界本機縮圖；第七十三階段支援重複來源的獨立位置／說明／精確 viewer 選取，修正 SQLite 已保存後 transcript 副本仍拒絕重複來源的漏點。系統存取恢復後，最新完整串行回歸 135 XCTest＋1,577 Swift Testing、原生建置、封裝及七語各 1,723 keys／0 missing 通過，包含原有 116、增加大量圖片 30 與重複圖片 40 個 canonical App 案例，以及 group／mailbox 動畫保存重開；這是本批回歸證據，不是全功能對等。模型輸入／SendToAgent 四張、本機 5／12 MiB、工具 40,000-byte 預算與完整核准不變；重複圖片各自計入 publication bytes，CAS／磁碟 quota 只計一個實體 blob。每張遠端卡保有獨立任務及 scope／redirect 檢查，需明確下載後才顯示；locator 不等於已驗證內容或網路權限。其他本機圖片／動畫格式、大檔、alias 獨立媒體搜尋、快取、完整 crash／UI lifecycle、最低實際 macOS 及真實外部服務驗收仍保留；詳見 [傳檔第六十九至七十三階段](Send-message-files-parity.md)。

完成驗收入口：見 [Parity-completion-audit.md](Parity-completion-audit.md)。本表 43 個歷史 complete 並非今日逐項端到端驗證；尚未重驗者不構成整體完成證明。下方矩陣及日期段落保留歷史證據，當前狀態須對照各分類的後續核對紀錄，不能把已接線功能再次列為缺失。自身 `hidden_from_sidebar` 的核准／持久化／UI／模型接線已於 `a57e545` 完成隔離驗證。圖片頭像的來源、預覽、提交與人工配額已接線，剩餘邊界見 [Avatar-image-parity.md](Avatar-image-parity.md) 第七至十階段；媒體最新狀態與未驗收邊界見上段及 [Send-message-files-parity.md](Send-message-files-parity.md)。

最新記憶核對（2026-09-27，`94937dd`）：episodic 的獨立七語 consent、跨回合進度、六回合摘要／獨立驗證、host 來源權重與 UI、App direct／group 接線及清理復原紀錄已實作並有隔離測試。下方同日及更早「尚缺」記述為歷史進度，以 [Episodic-memory-parity.md](Episodic-memory-parity.md) 後續段落為準。整體仍 partial：四條記憶保存入口已移除 48 筆／12,000 字歷史總量限制，另已移除 8 筆 profile 保存限制，保留有界 recall／search／抽取，新增 63 筆多來源重開測試；仍不等價於參考月份 log，人類管理頁已接每頁 20 筆與七語控制項；synthesis 已對齊原版最多 512 候選與完整歷史 stale fence（原版不逐批遍歷），另有 64,000-byte 投影上限；私人／共享 profile 筆數已改 100／50；專案已按有事實／最近日期／slug 選最多三個，各池獨立 25-profile／10-recent 與 JSON bytes 預算，未入選仍可搜尋；文字與 JSON 預算差異、大資料量磁碟 I/O 仍需保留驗收邊界；月份檔案布局差異本身不等同缺少使用者功能。原版 500 是抽取掃描上限而非儲存容量。下一階段明確驗收見 [Memory-archive-parity.md](Memory-archive-parity.md)。復原紀錄自身無法落盤與 UI 事件尚未送达 service 就崩潰的邊界、真實模型／UI／外部服務驗收仍保留。

Sweep 診斷（2026-09-27）：背景日期檢查在 runner 啟動前發生的失敗／取消，已接入獨立最近 64 筆分類摘要，不偽造 agent ID、不保存原始錯誤或路徑、不覆蓋前景錯誤；await 前捕捉 account journal，避免晚到結果污染新帳號。這是 diagnostics，不是使用者通知或自動重試；episodic 與外部驗收仍 partial。

Episodic 分支核對（2026-09-27）：原版 `runTurnMemory` 在 synthesis evidence 接口存在時清除 episode pending 並 return；每六回合摘要是舊流程分支，不與 synthesis 同批執行。Filicon 尚缺該分支的明確 consent／跨回合進度／host episode 來源與權重；不得把停用 synthesis 當成自動保存 episode 的授權。具體來源及驗收見 [Episodic-memory-parity.md](Episodic-memory-parity.md)，狀態仍 partial。

記憶診斷（2026-09-27）：pipeline 回報一次有界結果分類／evidence／input memory／proposal change 數／monotonic 耗時；App 最近 64 筆僅記憶體 journal，切帳號替換並在 root diagnostics 匯出不含正文的摘要。queue admission 淘汰另有 64 筆上限；尚未 run 的 sweep 錯誤提示仍缺，episodic／外部服務驗收維持 partial。最終驗證見協作核對紀錄。

App temporal 排程（2026-09-26）：啟動與每小時 sweep 接入 worker，每次最多新增 4 位到期且 opt-in 的代理人；排除已排隊相同 consent，跨帳號 await／保存由 generation 與 lifetime 保護。七語提示說明無新聊天仍可能產生模型費用。取代下方 startup／hourly 尚缺的歷史記述；失敗觀測、episodic、外部服務驗收仍 partial。最終驗證見協作核對紀錄。

Temporal worker 接線（2026-09-26）：日期批次具有獨立可撤銷來源，App runner 傳遞日期標記，production pipeline 回報 24 小時 receipt；取消／stale 不回報。審批恢复後完整非並行測試、原生建置與封裝簽章通過，包含 7 種 worker／9 種 receipt 情境。App startup／hourly sweep 仍缺，維持 partial。

Temporal queue（2026-09-26）：支援空 evidence 日期檢視批次及與聊天證據合併，重排保留標記且不覆蓋新版 consent；仍待 worker／App hourly sweep 與完成回報接線，定期檢視維持 partial。

定期記憶檢視 receipt（2026-09-26）：已加入獨立持久化 24 小時到期紀錄與最多 4 位 account／consent 篩選，尚未接 hourly timer／temporal queue／完成回報，定期檢視仍 partial。

記憶 stale 重排（2026-09-26）：記憶快照變動使用專用錯誤，worker 保留 evidence 並 debounce 後重做提案／驗證；授權 stale、Stop 與來源撤銷不重排。恢復保留較新 evidence 與 consent，不重用過期 verdict。此項取代下方 stale 尚缺記述；temporal、失敗觀測、episodic 與外部驗收仍 partial。

背景記憶 App 接管（2026-09-26）：bound direct／group 完成回覆後入列共用 worker，15 秒 debounce 跨來源合併；正常 session close 不取消已交出的工作。account／origin／session composite lifetime 保护最終保存，Stop／刪除 direct／群組成員更新／切帳號撤銷；取代下方尚未 App 接線的記述。temporal sweep、stale 重排、失敗觀測、episodic 與外部驗收仍 partial。

記憶背景 worker 基礎（2026-09-26）：加入可取消 debounce timer、序列批次 runner、pending／ready／active 去重及來源／代理人／revision／shutdown 撤銷。僅為可測試 host component，尚未接 AppModel／MessagingSession 的正常收尾接管與生命週期，現行 App 仍逐回合處理；temporal、stale 重排、episodic 與外部驗收仍 partial。

記憶 evidence queue 基礎（2026-09-26）：新增 account／agent 隔離的 host queue，64 pending／每組 12 筆、15 秒 nextRun、revision 隔離、去重與來源取消，以及 ready batch 原子取出。尚未接 App background owner／timer／in-flight lifetime，現行 App 仍逐回合執行；temporal、stale 重排、episodic 與外部驗收仍 partial。

記憶整合整組期限（2026-09-26）：proposal／verification 共用預設 90 秒 deadline，含 coordinator／agent lane 排隊；每次 retry 重新起算，逾時只取消該 submission 並拒絕晚到結果。既有 stage 45 秒上限仍保留。此項更新下方整組期限尚缺的歷史記述；debounce／queue／temporal／episodic 與真實模型驗收仍 partial。

解鎖後完整回歸補驗（2026-09-26）：`memory-synthesis-retry-full.log` 完整非並行套件 exit 0，原生建置／封裝簽章亦通過；下方兩輪因鎖定而保留的持久化重開驗收缺口已解除，不代表其餘功能 parity 已完成。

記憶整合有界重試（2026-09-26）：公開 run 最多三次 proposal＋verification，等待 2／4 秒；固定 evidence／snapshot，取消與 stale 不重試，保存不在 retry 區域。七種新情境及既有 pipeline／App lifecycle 聚焦驗證通過。原版整組 90 秒 deadline（含排程）、debounce、pending evidence queue、temporal sweep、episodic 與外部驗收仍 partial；下方重試尚缺的歷史記述由此更新。

自動記憶 App 生命週期補驗（2026-09-26）：16 種直接／群組假 provider 整合情境通過，覆蓋實際啟用保存與停止、切帳號、停用再啟用、刪除／移除成員拒絕晚到提交；取代下方 synthesis 專用 App 生命週期待驗記述。這些是現存隔離 instance 驗證，完整回歸及磁碟重開仍被螢幕鎖定阻擋；排程／重試／temporal／episodic 及真實模型缺口不變。

自動記憶 UI 獨立授權（2026-09-26）：代理人記憶設定加入獨立啟用確認／停用與七語系費用、證據及自動修改範圍揭露，AppModel 延用帳號 generation／UI lifetime／quota 寫入保護。隔離設定保存、過期與跨帳號拒絕、七語系離屏檢查通過。此項補齊下方 UI 缺口，但不代表 synthesis 專用完整 App 生命週期、排程、episodic 或真實模型驗收已完成，仍 partial。

前景回合記憶整合接線（2026-09-26）：App 的綁定直接聊天與群組 session 已注入 synthesis transport；沿用 host 準備的人類訊息與該代理人完成回覆，僅在獨立設定啟用時處理，PASS／空回覆不處理，重複收尾不再執行。停止及關閉沿用同一撤銷 lifetime。六種隔離 session 情境通過；尚缺使用者設定 UI、App 層 synthesis 專用生命週期整合驗收、debounce／temporal 排程及真實模型驗收，整體仍 partial。此項取代下方前景接線尚缺的歷史描述。

自動記憶獨立授權與端到端接線（2026-09-26）：新增每帳號／代理人的 synthesis 設定，預設關閉且不繼承建議設定。host run 已串起設定重驗、兩階段 tool-free provider 與原子保存；每次設定變更產生新 revision，停用或停用再啟用均使舊回合失效，排程 onStart 也重驗。App 設定 UI、前景完成後觸發、debounce／temporal 排程與真實模型驗收尚未完成，仍 partial。

記憶整合模型連接層（2026-09-26）：新增 tool-free transport，經現有 provider／background scheduler 執行獨立請求，限制輸入與輸出 bytes、要求 stop、拒絕工具事件與異常終止，設定變更及取消拒絕晚到結果，每段預設 45 秒上限。尚未接 App 啟用／協調器呼叫、排程及真實模型驗收；螢幕鎖定造成的完整回歸缺口仍保留。

兩階段記憶協調（2026-09-26）：新增內部 host pipeline，對 completed exchange 證據做有界檢查，非空提案必須另取嚴格 boolean 驗證回覆才進入 snapshot-fenced 保存。拒絕、格式錯誤、取消、transport 失敗與 stale 都不套用提案。此入口尚未接真正 tool-free provider transport、opt-in 設定、排程或 App；不代表獨立模型驗證已在使用者對話啟用，整體仍 partial。

記憶整合保存基礎（2026-09-26）：新增 explicit／synthesis 來源，舊 Filicon 記憶仍預設 explicit；明確刪除保存限定範圍的正規化 SHA-256 指紋，人工重建解除相同指紋。內部 synthesis 保存入口重驗包含來源與刪除紀錄的快照、只改 generated 私有記憶、整批限制與原子保存／失敗回滾。尚未暴露為模型工具或 App 自動流程；獨立語意驗證、opt-in 設定、排程與 episodic 仍待接線，AGENT-01 保持 partial。

記憶整合提案驗證基礎（2026-09-26）：對照原版 synthesis 的 create／update／remove 與 sourceEvidenceIds，新增內部純解析契約；限制本文／批次大小、已知 evidence、host 可修改 ID、每筆只改一次及 clock 不可單獨建立新事實。這不是自動記憶功能完成：尚未接 provider 提案／獨立語意驗證、來源持久化、原子快照套用、tombstone／排程與 UI。既有人工核准記憶不變，AGENT-01 仍 partial。

直接同儕安全輸入（2026-09-26）：已接直接委派的 secret publisher、動態安全卡、提交／取消後保留 binding 的新回合、同儕回覆及 retired 歷史恢復。七種隔離 App 情境驗證，只有 host 已配置的唯一 Slack／Discord bot token 可作目的地，憑證不進模型／聊天；其他 connector、任意網站帳密與真實登入驗收仍 partial。此項取代下方「直接同儕憑證卡尚未接上」歷史狀態，詳細限制與證據見協作核對紀錄。

直接同儕雲端參照卡（2026-09-26）：SendMessage cursor-agent 已接直接 mailbox、canonical 驗證、自己聊天室的持久卡片與恢復；衝突不覆寫，恢復不重跑模型。它是手動開啟既有 Cursor 代理人的連結，不是雲端啟動／查詢／控制權限；憑證卡及其他外部服務缺口仍維持 partial。詳見協作核對紀錄。

綁定直接聊天→所屬群組文字轉交（2026-09-26）：前景及回答續接 factory 接上完整 audience／本文核准、持久發文及有界群組回覆；核准期間身份或成員變更拒絕，背景群組不繼承直接聊天私人圖片。六種隔離 App 情境及既有圖片／委派回歸驗證；詳細證據見協作核對紀錄。圖片群發、任意 file／HTTPS 來源、跨群組統一歷史與其他互動卡仍 partial。

圖片故障補驗（2026-09-26）：`d7dba12`、`1656d39` 補齊隔離 host 重建、SQLite 寫入拒絕／重試、canonical blob 遺失／損壞及附件 metadata 衝突測試；完整非並行回歸通過，取代下方相應待補驗記述，仍非真實 UI／外部模型驗收。

直接同儕圖片接線（2026-09-26）：已接前景當輪 PNG／JPEG 的 owner 驗證與匯入、獨立轉交／發布核准、收件人推論、附件投影／SQLite 保存及缺漏恢復；後續人類回合不自動重送歷史同儕圖片。五類 App fixture 通過，取代下方「App 尚未接上」歷史狀態。真實 UI／外部模型、任意圖片來源及圖片專用故障／重啟補驗仍待完成，未上調整體 partial。

直接圖片目錄契約（2026-09-26）：session 新增 host 的當輪圖片 callback，限綁定 owner／account，核准後重驗，peer wake 維持精確 incoming 圖片。八類 fixture 檢查實際圖片推論與來源／停止／核准拒絕。App 尚未接上，直接圖片功能仍 partial；詳見協作核對紀錄。

同儕問題恢復來源補強（2026-09-26）：回答回條之外，另核對回答交付本身的 directOriginBinding 與 originConversationID；缺失／其他聊天／其他帳號三個案例先重現失敗，再通過修正後的聚焦回歸。避免原問題卡接受來源不完整的回答關聯，不增加工具權限或模型執行。

同儕問題卡恢復（2026-09-26）：恢復入口現在也補回 canonical 問題卡與回答後代理人的發布文字，不把人類回答投影為代理人訊息。問題、回答回條、原交付的帳號／作者／來源／UUID／答案均交叉核對；缺失、歧義及不一致紀錄拒絕。八類持久化案例與待回答／已回答整合案例驗證恢復不改信箱、不重新執行、不重複回答。取代下方問題卡恢復尚缺的歷史描述；憑證／雲端／圖片同儕卡及其他既有缺口仍 partial。

直接同儕問題卡接線（2026-09-26）：SendToAgent 被喚醒的代理人可在自己的綁定聊天室發布問題卡，使用者選項／自訂／取消回答開啟新回合，後續代理人回覆投影回原提問聊天室，不把人類回答標成同儕訊息。原帳號／binding 重驗、忙碌與停止連動、重複回答拒絕、刪除及重新開啟均納入七類整合測試。七語系明暗色離屏渲染通過，繁中淺色／法文深色人工檢視無裁切；完整回歸、原生建置、封裝簽章通過。未順帶開放直接同儕雲端卡／憑證／圖片；缺漏問題卡恢復與回答回合文字恢復仍待補，不上調整體 partial。

同儕問題回答來源（2026-09-26）：answerQuestion 要求 host 明確匹配原 directOriginBinding，回答新交付保留該 binding 並使用新 session chainID；不匹配／缺少 binding、跨帳號及替舊信箱注入 binding 均拒絕，不改既有信箱。五類持久化與重新載入案例、六類 session 選項／自訂／取消回答驗證，聚焦 39 項及完整回歸、原生建置、封裝簽章通過。原直接聊天仍未啟用同儕問題卡：卡片顯示與回答後回覆投影尚待接線，整體 partial 不變。

綁定直接聊天記憶建議（2026-09-26）：在既有具 SendMessage 工具的綁定直接聊天接入 opt-in 提取及既有逐筆審核；僅取目前非引用人類訊息與已完成回覆，不以同儕歷史、問題選項或憑證回條當作人類事實。模型提取無工具，結果是私有待審核候選，不直接保存永久記憶。啟用／停用、停止、帳號切換、刪除聊天與晚到結果測試通過，完整回歸、原生建置、封裝簽章通過。原版記憶重寫／episodic 流程、同儕問題回答後回到專屬聊天室、圖片／群組轉送仍 partial。

恢復重新載入／重試補驗（2026-09-26）：隔離 AppModel 重新建立後可恢復 canonical 文字，持久刪除界線仍生效；SQLite 寫入失敗解除後可重試，重複恢復不新增訊息、不改信箱、不重跑代理人。恢復整合擴為八類，與七語系明暗色離屏設定面板測試通過；未重啟使用者 App，也不代表真實外部服務驗收完成。

同儕文字恢復入口（2026-09-26）：綁定聊天的模型設定面板新增七語系「恢復代理人訊息」，從 canonical 已結束交付補回缺漏文字／聊天，不重跑代理人，不復活刻意刪除的聊天；帳號、身份、衝突與保存失敗均拒絕，支援忙碌／取消狀態。六類恢復整合情況、既有直接委派回歸、七語系明暗色初始按鈕渲染、完整測試、原生建置與封裝簽章通過。取代下方入口未接線狀態；互動／媒體恢復、原版每代理人唯一聊天及真實 UI 驗收仍 partial。

投影刪除保護（2026-09-26）：綁定聊天刪除前持久保存 retiredProjectionIDs；即時投影核對 origin／destination，避免重開後把已刪除聊天建回。原始 mailbox／context 保留，保存失敗不執行資料庫刪除。恢復入口仍未完成，整體 partial。

唯讀同儕恢復清單（2026-09-26）：持久 startedAt 區分已開始與只排隊；清單僅提供同來源、已結束的 canonical 文字，排除人類／互動／媒體／歧義紀錄，不執行模型或寫信箱。host 保存／恢復入口及 UI 尚未接上，整體維持 partial。

直接委派來源（2026-09-26）：delivery 保存 host 選定的原始帳號／代理人 binding，即時投影重驗；群組／人類信箱與舊資料不猜測補值。帳號不符拒絕送出，同一回覆鏈保持原始身份。這是恢復來源基礎，尚非恢復 UI／執行授權；整體仍 partial。

純文字最終回覆保存（2026-09-26）：新增 canonical finalPublication，與 completed 同步保存 UUID／完整文字，直接投影核對完整紀錄而非截斷摘要。非法作者／範圍／UUID／文字／狀態拒絕，投影失敗不重跑 provider。恢復 UI 與歷史帳號／來源證明仍未完成，不提升整體 partial。

同儕聊天忙碌／停止連動（2026-09-26）：列表、標題和輸入列共用背景委派狀態，拒絕競爭送出及模型同步；從收件人聊天停止或刪除會取消來源委派，依 session 清理狀態。11 類直接委派整合情況、完整回歸、原生建置、封裝及簽章通過。關閉下方背景狀態缺口，其餘 partial 不變。

直接同儕文字投影接線（2026-09-26）：已批准直接委派的 incoming／publication 依 canonical delivery 驗證後保存到收件人的綁定聊天室；回给原代理人則使用原聊天，顯示實際作者，後續模型 context 保留非人類／非授權標記。九類整合情況加驗四則訊息歸屬、SQLite 重開與模型上下文，明暗色發言者渲染已人工檢視。互動／媒體卡、保存失敗恢復、背景狀態連動及原版每代理人唯一聊天仍 partial。

同儕投影事件（2026-09-26）：drain 提供帶來源的 incoming／publication 回呼，canonical 發布後才投影，排除私有草稿、工具活動及人類回條的錯誤歸屬；鏡像失敗不引導重複 SendMessage。AppModel 的聊天室保存與顯示仍未接入，維持 partial。

同儕來源持久化（2026-09-26）：新增 ChatMessage 可選 AgentMessageSource（account／origin／delivery／sender／recipient／incoming 或 publication），schema 13、JSON、分頁、部分歷史更新與 salvage 保留；非法来源與角色不降級成無歸屬文字，舊資料不猜測身份。這是後續每位代理人自己的直接聊天室投影基礎，尚未接顯示或模型上下文，不提升整體 partial 判定。

綁定直接聊天管理接線（2026-09-26）：共用既有管理 session 的 CreateAgent／UpdateAgent／update_state／記憶搜尋／連接器狀態工具，核准預覽與群組共用完整變更元件，保存起始 binding 並拒絕途中替換；改名後委派仍需各別核准。32 個直接整合情況、七語系預覽、完整回歸、原生建置、封裝及簽章通過。記憶分享說明已納入綁定直接聊天。取代下方「管理／記憶工具未接線」狀態；自動記憶建議／重寫、同儕投影、群組／圖片轉送、同儕互動卡及真實外部驗收仍 partial。

綁定直接聊天文字委派（2026-09-26）：SendToAgent 已接明確收件人／完整內容核准、原身份重驗及 foreground lane 釋放後的有界同儕回覆鏈；信箱保存交付與回覆，Stop／刪除／封存／帳號轉換取消。新增 9 個直接整合情況，最後完整回歸、原生建置、封裝與簽章通過。未綁定聊天不開放。管理／記憶工具、群組與圖片转送、同儕互動卡與直接對話投影仍未接線；整體 partial 不變。

解鎖完整補驗（2026-09-26）：c606a21 的完整非並行 direct-secret-unlocked-full.log exit 0，包含直接憑證 13 個整合情況，關閉下方兩輪因鎖定留下的完整回歸缺口。未操作真實憑證／外部登入。另確認綁定代理人的直接聊天只接 SendMessage，SendToAgent／管理工具仍未接線，整體維持 partial。

憑證取消回條重試（2026-09-26）：取消保存失敗可重試，不重開輸入、不重寫憑證；重複取消與失效後晚到結果不重入。七語系明暗色畫面及 34 項聚焦測試、原生建置與封裝／簽章通過。新增 SQLite 取消失敗整合案例與完整回歸仍待螢幕解鎖補驗，不變更整體 partial 判定。

直接憑證接線（2026-09-26）：綁定代理人的直接聊天已串接 SendMessage secret-request、安全輸入、實際 submission 回條保存與新回合恢復；限既有唯一 Slack／Discord bot token 目的地。12 個隔離生命週期案例及首輪完整回歸通過，最終原生建置／封裝通過；最後 UI 調整後完整重驗遇 macOS 鎖定及受保護 fixture EPERM，待解鎖補驗，不能宣稱最終全綠。未進行真實 Keychain／外部登入驗收，其他平台／欄位仍未完成。

憑證歷史卡片（2026-09-26）：typed direct request 在通用 renderer 中唯讀顯示；pending 無 live submission 時不轉圈、不提供動作，stored 不宣稱遠端登入已驗證。封鎖通用 retry／dismiss 繞過專用回條流程。32 項聚焦測試、七語系明暗色渲染、完整回歸、原生建置與封裝／簽章通過。此時的直接憑證輸入／恢復尚未接線，後續以上方接線紀錄為準。

直接憑證請求契約（2026-09-26）：新增不含值的持久 request/binding/destination/state/responseID、以實際 submission 結果產生回條，以及禁止退回舊通用憑證路由。29 項聚焦測試、完整非並行回歸、原生建置及封裝／簽章驗證通過。直接聊天的 publishSecret、輸入 UI 與恢復回合仍未啟用；不能將資料契約視為完整 secret-request 功能。

既有代理人聊天模型同步（2026-09-26）：新增七語系「同步代理人模型」，查詢活躍 profile 並保存 provider/model／重設 reasoning，拒絕跨帳號、封存、執行中與重複同步。失敗只還原模型欄位；保留聊天身份與訊息。關閉下方 profile 模型修改後缺少同步流程的缺口，direct secret-request 與整體 partial 狀態不變。

代理人聊天入口（2026-09-26）：代理人列表已可建立持久綁定的新單獨聊天；保存成功才導覽，封存／缺失／寫入失敗不新增畫面，一般模型控制不可覆寫綁定設定。聚焦 10 項測試通過。profile 模型修改後的同步、direct secret-request 及真實 UI 驗收仍待完成，不上調整體 partial。

單獨聊天代理人執行驗證（2026-09-26）：持久 binding 已接 startTurn 的帳號／存活 profile／模型檢查、身份指令與共用 agent lane；排隊後再驗證，失效不退回一般聊天。聚焦測試通過。尚未新增 UI 選擇／建立入口或 direct secret-request，不將 binding 當作工具授權，整體仍為 partial。

單獨聊天代理人關聯儲存（2026-09-25）：新增 accountID＋agentID 可選持久身份，schema 12、JSON、分頁與 salvage 均保留；舊資料不猜測關聯。16 項聚焦測試通過。UI 選擇／建立、執行身份與權限套用及 direct secret-request 仍待接線，不上調 partial 狀態。

直接引用 scope 補強（2026-09-25）：畫面快照攜帶帳號 generation，帳號切換即撤銷舊解析／捲動，不因相同對話 UUID 重新啟用。direct secret-request 仍缺 host-owned 對話／代理人關聯；已核對原版提交與恢復語意，不能以任意既有連接器替代。

直接引用完整回歸補驗（2026-09-25）：不改碼／不放寬檔案保護，確認當前系統未鎖定後，先前 MCP 與 updater 失敗案例重驗通過；完整非並行 direct-reference-ui-full-unlocked.log exit 0。關閉下方直接引用 UI 的完整回歸缺口。當時 EPERM 的唯一根因未被記錄證明；其他 parity 與真實 UI／外部驗收仍未完成。

直接聊天引用 UI（2026-09-25）：已接入 Markdown、完整歷史載入、顯示視窗展開與跳轉，SendMessage 正式啟用 sand-msg 提示。本批 27 項整合測試、原生建置及封裝通過；完整回歸有多模組暫存 JSON EPERM 與 updater 保存斷言失敗，MCP 單獨重驗亦失敗，待診斷。取代下方尚未接 UI 的狀態，但不代表整體 AGENT-02 或完整驗收完成。

直接聊天引用索引（2026-09-25）：新增完整歷史限定、對話隔離、重複／已刪除地址保留檢查的 sand-msg 索引，聚焦 10 項測試通過。尚未接 UI 與分頁跳轉，工具仍不宣告支援 inline navigation；AGENT-02 保持 partial。

工具事件順序補驗（2026-09-25）：修正工具執行可能超前主程式 pending 狀態保存的競態；正式工具迴圈現在等待事件處理成功後再繼續。完整回歸 tool-event-order-full.log exit 0，新增六組慢速／失敗保存案例通過；關閉上一輪群組事件順序失敗，未改剩餘功能 partial 狀態。

直接聊天短地址接線（2026-09-25）：完整歷史保存時配置 tNu／tNsM（啟動前發布為 tbsM），schema 11 保存已用地址保留紀錄，刪除訊息不重用地址。SendMessage 目錄與成功保存回條帶入短地址，reply_to 可引用本對話目錄或同回合回條；只發布工具的空白佔位／私人推理不分配公開地址。此項取代下方「配置／工具目錄與回條未接線」的缺口；sand-msg 正文點擊跳轉尚未接上，其他 secret-request／外部服務等仍 partial。

直接聊天短地址儲存基礎（2026-09-25）：ChatMessage 與 SQLite schema 10 增加可選 shortAddress，完整讀寫、分頁、JSON 相容及有效資料復原均保存此欄位。舊資料不猜測地址。這是接入原版持久引用身份的必要基礎，尚未啟用直接聊天地址配置、工具目錄／回條或 sand-msg UI；AGENT-02 仍 partial，不算完整短地址功能。

圖片發布補驗（2026-09-25）：修正既有安全金鑰測試的排程等待上限後，完整非並行回歸 direct-images-full-recheck.log exit 0；下列該輪偶發測試失敗已補驗，功能範圍與 partial 狀態不變。

直接聊天圖片發布（2026-09-25）：SendMessage 現可發布本回合最後一則使用者訊息所附的 PNG／JPEG，支援附文字或獨立 attachment、UUID reply_to／保存回條。發布前顯示檔名、替代文字與說明供核准，核准前後重新驗證來源及內容；保存後建立獨立附件引用。此項取代直接聊天圖片完全未接線的描述，但任意路徑／HTTPS／生成檔案、影片及一般文件發布仍未完成，secret-request／短地址等缺口不變，AGENT-02 仍 partial。驗證與完整回歸中的既有安全金鑰測試偶發失敗詳見協作紀錄。

直接聊天選項問答（2026-09-25）：SendMessage `type:widget` 已接入正式保存、UUID 引用／回條、暫停回合，以及人類選項／自訂文字／取消後的續聊。沿用群組問答介面；`dismissOnMoveOn` 只在明確設為 true 時隨新訊息失效，回答不改工具權限。此項取代下方直接聊天 widget 尚未接線的描述。圖片、secret-request、短地址／sand-msg 和外部服務驗收等仍有缺口，AGENT-02 仍 partial。

直接聊天雲端引用（2026-09-25）：SendMessage `type:cursor-agent`／`bcId` 已接入正式保存、UUID 回條與 reply_to，可由同回合下一則文字引用。外部卡片沿用七語言 Cursor 引用介面，只在使用者點擊時開啟固定 cursor.com；與既有本機代理導航分離。此項取代下方直接聊天 cloud-agent 入口尚未接線的記錄。圖片／widget／secret-request、短地址／sand-msg，以及遠端 title／status／帳號驗收仍未完成，AGENT-02 維持 partial。

直接聊天引用回條（2026-09-25）：SendMessage text 已支援同對話 UUID `reply_to` 與成功保存後的 messageID 回條，同回合後續發布可以引用前一則新訊息。工具目錄不帶入其他對話，保存時重新檢查目標仍存在；使用既有直接聊天引用預覽／跳轉。此項取代下方「直接聊天 reply_to／UUID 回條完全未接線」的記錄。短地址、正文 sand-msg 導航及其餘圖片／widget／secret-request／cloud-agent 型別仍未完成，AGENT-02 仍 partial。

直接聊天正式發布（2026-09-25）：有工具能力的直接聊天已接入 SendMessage text，進度與結果分則保存；草稿／reasoning 不投影、不進對話記憶，未發布且無工具活動時移除空佔位。停止、刪除或帳號切換後拒絕遲到發布，完成通知採最後正式發布。純文字模型與離線 Demo 保留文字回答。此項取代下方「直接聊天完全缺少 SendMessage 入口」的描述；直接聊天圖片／widget／secret-request／cloud-agent／reply_to 工具參數與回條地址仍未接線，AGENT-02 維持 partial，不能宣稱所有型別 parity。

正式發布界線（2026-09-25）：有 SendMessage 的群組／背景群組／信箱不再顯示未發布的 final-text，工具狀態也不投影中途草稿；保存摘要與記憶整理只採用正式發布。純文字模型或未配置工具執行器保留正常回答途徑。此項取代舊記錄的 SendMessage final fallback 差異，直接聊天發布入口及其餘 AGENT-02 差異仍 partial；驗證詳見協作核對紀錄。

雲端 ID 校正（2026-09-25）：以原版 trimmed opaque ID 契約取代上一批 bc- 英數限制；Unicode／特殊字元編碼為固定 cursor.com 下單一路徑片段。仍保留 canonical summary 8,000-byte 預算、控制字元及純 dot-segment 拒絕，不接外部認證／title resolver。此項取代下方「只接受有界 bc- ID」的描述。聚焦測試、原生建置、封裝與簽章通過；解鎖後完整回歸 exit 0，同時關閉前輪雲端卡片的待補驗缺口。整體仍 partial。

雲端引用卡片（2026-09-25）：有保存回條的一般／背景群組及独立信箱已接入 `SendMessage type:cursor-agent` 與 `bcId`／reply_to，沿用發布額度、身份、保存和引用限制。七語言卡片點擊開啟固定 cursor.com 網址，不在發布時查詢或啟動遠端工作。只接受有界 bc- ID，不支援自訂網站 base、遠端 title resolver 或直接聊天入口；不是雲端帳號完整驗收。此項取代「完全缺少供應商 cloud-agent 卡」的歷史描述，其餘 AGENT-02 差異仍 partial，詳見協作核對紀錄。

信箱引用導航（2026-09-25）：已接上 sand-msg 正文連結與引用卡片的原訊息定位，使用完整且分方向／origin 的主程式快照；超過目前 500 則的目標可載入並維持列表上限。非法／跨範圍／未來／模糊引用不啟用，導航不改檔案、未讀或執行狀態。完整測試、七語言明暗渲染、原生建置與封裝通過；實際使用者視窗點擊尚未進行，未重啟 App。本項取代下方「信箱 sand-msg UI 跳轉仍待完成」的實作缺口，其餘 AGENT-02 差異仍 partial。

信箱短地址（2026-09-25）：已按 directed mailbox 持久保存 tNu／tNsM 地址，工具目錄與正式回條可用於 reply_to；人類來源由 host 記錄、舊記錄不猜測來源、重啟及超過 40 則不重新編號。群組同步不帶入信箱地址。完整回歸、最後 82 項信箱／群組整合測試、原生建置與封裝通過。信箱 sand-msg UI 跳轉仍待完成，AGENT-02 partial；詳見協作核對紀錄。

安全請求引用（2026-09-25）：獨立信箱 secret-request reply_to 已串接模型、App 與保存層，重送核對引用且保持憑證不進模型。工具測試、七種 App 安全生命週期、完整回歸、原生建置及封裝通過。短地址、sand-msg 導航及其他入口差異仍待補齊，AGENT-02 partial。

引用完整補驗（2026-09-25）：解鎖後 `mailbox-reply-complete-recheck.log` 完整測試 exit 0，先前信箱引用相關待補驗已完成。另七語言 light／dark 共 14 渲染案例通過，人工檢視繁中及法文 dark。短地址／sand-msg 導航、展開與圖片互動驗收、secret-request reply_to 仍待完成，不改 complete 計數。

信箱引用 UI（2026-09-25）：新增同信箱引用摘要／展開內容與 unavailable 狀態，拒絕跨範圍、未來與重複目標；七語言 light 渲染與定向查找測試、原生建置及封裝通過。暗色／展開互動／圖片驗收、短地址與 sand-msg 導航仍待補，完整回歸亦待補驗；AGENT-02 partial。

信箱問題引用（2026-09-25）：widget reply_to 已接模型至保存層，沿用範圍驗證及提問暫停／新回合回答。七個定向案例、原生建置、封裝通過；完整回歸仍待補驗。引用卡片與短地址仍未完成，AGENT-02 partial。

信箱同回合回條（2026-09-25）：正式保存的 text／image publication UUID 可供同回合後續 reply_to 使用，共用 sender／scope／內容驗證。工具層與單獨 session 測試、原生建置及封裝通過；廣泛回歸遇 protected-file EPERM，完整補驗待解鎖。引用 UI、短地址、question 引用仍未完成，AGENT-02 partial。

信箱引用增量（2026-09-25）：獨立信箱 SendMessage 接入同參與者／origin 的 reply_to UUID 目錄及保存時重驗；跨範圍、未來、自我及未知引用拒絕。完整回歸、原生建置、封裝及 deep strict codesign 通過。引用卡片、短地址、同回合新增 receipt 及 question 引用仍待接線，AGENT-02 partial、complete 計數不變。

模型斷線帳號隔離（2026-09-25）：own-channel disconnect 以 host 帳號＋agent 篩選，另一帳號不列入候選、不刪除；App 核准及提交重驗 owner。全域 channel UI／收送策略仍未宣稱全面隔離，complete 計數不變。

完整驗收補跑（2026-09-25）：`channel-account-full-recheck.log` 完整非並行測試 exit 0，原生建置、封裝及 deep strict codesign 通過；下方 channel status／owner identity 的待解鎖補驗已完成。前一次 EPERM 保留紀錄，原因未完全確認，未降低檔案保護。

連線身份修正（2026-09-24）：遠端 accountID 與 Filicon ownerAccountID 分離，避免遠端登入後安全憑證卡片／GetChannelStatus 找不到自己的連線。舊資料僅回退 local，新建立連線明確記錄 host owner。channel 全域 UI／收送的完整多帳號策略仍待核對，完整回歸待解鎖；不改 complete 計數。

憑證驗證查詢（2026-09-24）：新增 host-scoped GetChannelStatus，以唯讀 profile 查詢回報自己的既有 Slack／Discord 認證，不揭露 secret／identity／diagnostics，不以登入成功代表送達或 listener 健康。新增隔離測試通過；廣泛回歸受鎖定檔案保護影響待補驗。不是原版 MCP 狀態功能的全面替代，AGENT-02 維持 partial。

憑證更新連線（2026-09-24）：成功安全寫入後會重建原本運行中的 listener 並排除舊 profile 結果；失敗／重送不重建，停止的連線不自動啟用。遠端登入狀態、新連線與其他 secret-request 入口仍未完成，AGENT-02 維持 partial。

獨立信箱憑證流程（2026-09-24）：已接上模型 secret-request、遮罩卡片、既有 Slack／Discord token 目的地、安全提交、durable 回條與新 session 續聊。保存回條失敗可不重寫憑證地重試；account／Stop／封存及工具邊界有隔離測試。群組／直接聊天、reply_to、新連線／其他 connector 及真實 Keychain／遠端登入驗收仍未完成，AGENT-02 維持 partial；詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

安全憑證信箱保存（2026-09-24）：加入不含值的卡片／回應、原子完成與新 queued 訊息、重複提交防護、重啟退休及 scoped move-on；成功 submission 可核對目的地後保存 durable receipt。尚未接 App／模型入口與 fresh session 續接，Keychain 與 JSON 也不是跨系統交易；AGENT-02 繼續 partial。詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

安全憑證卡片元件（2026-09-24）：新增 SecureField 與可測試輸入模型，提交即清空、失敗重輸、關閉／取消排除遲到續接，七語言明暗渲染與生命週期測試通過。尚未掛入對話或向模型公開，仍缺持久化、host 失效接線、新 turn 續接與新連線建立；不能視為完整 secret-request，AGENT-02 維持 partial。此進度取代下方歷史段落「沒有 SecureField 元件」的描述，詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

安全憑證提交閘門（2026-09-24）：新增不序列化輸入值、同步目的地重驗＋寫入 fence、一次提交 receipt 與 Keychain writer。測試用記憶體 writer，不碰真實 Keychain；仍缺 UI／tool／對話持久化續接與新連線建立，不能視為原版 secret-request 完成，AGENT-02 繼續 partial。詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

安全憑證請求契約（2026-09-24）：已核對原版 secret-request 的遮罩輸入／只回報已提供語意，新增不包含憑證值的嚴格 metadata 及同帳號／代理人既有連線目的地驗證。尚未接 SecureField、Keychain、暫停續接及新連線建立，工具仍不開放 secret-request，不能宣稱功能已完成。AGENT-02 維持 partial；詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

信箱提問接線（2026-09-24）：獨立 mailbox 已接上模型 widget、正常暫停、七語言回答卡片及新 session 續接。人類回答僅交回提問者，不繼承圖片、priority、工具權限或 peer 回信豁免；普通新訊息原子退休同帳號／scope 的 dismissOnMoveOn 問題。帳號／Stop／封存／重複回答、保存失敗及 UI fixture 已加入回歸。此項取代下方歷史段落與 AGENT-02 中「mailbox 提問未接線」的描述；mailbox 引用、直接聊天 widget、外部 channel 與其他卡片缺口仍在，complete 計數不變。詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

信箱提問底層（2026-09-24）：新增 host 問題保存與回答／queued 續接的原子契約，保留帳號／scope／提問者、一次回答、兩則發布上限與失敗回滾。模型入口、UI、move-on 與 App 續接尚未接線，**mailbox widget 仍未完成**，不改 complete 數。7 項底層測試與解鎖後完整非並行回歸、原生建置／嚴格簽章／封裝通過；首輪鎖定時圖片讀取拒絕另保留紀錄。詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

文字工具格式對齊（2026-09-24）：共用 `SendMessage` 接受原版 `{type:"text",content:"..."}`，保留舊 `{text:"..."}`，混用拒絕；兩者共用發布額度、receipt／內容去重、引用及當前圖片核准。群組／mailbox 雙格式回歸、完整非並行測試、原生建置／簽章／封裝通過。任意 URL／路徑附件、mailbox 引用／提問與其他既有差異仍未完成，計數不變。詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

範圍校正（2026-09-24）：原版 `sand-state-tool.ts:121` 的模型排程 member schema 只有 cron／Slack／GitHub／Teams／Linear／Sentry／PagerDuty。generic connector 是 Filicon-native 能力；其模型寫入限制不是已確認的原版缺失，不因此擴充模型權限。新增 create/update 與混合 OR 的拒絕／不落盤回歸測試。歷史段落提及 generic 限制時應依此解讀；完成數不變，真正的 settled checks、Slack 身分、Teams 驗證與其他 partial 項目仍未完成。詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

本矩陣保留固定的 48 個 parity ID，對照目前 macOS Swift 實作。`complete` 表示該列所述能力有歷史實作證據，不代表原版所有細項均已重新核驗；`partial` 表示仍有功能、接線或驗證缺口；`NA` 表示該列是來源 runtime 的實作細節，不是 macOS 產品行為。這不是「原版功能全部都有」的保證。

表格預覽安全修正（2026-09-24）：CSV／TSV 改為直接解析 gate 已驗證資料；XLSX 使用同份資料建立 mkdtemp 私有目錄中的暫存 archive，系統 ZIP 工具不再開啟原預覽路徑，結束後清理副本。保留檔案大小、展開量、路徑／XML／列欄及不執行公式的限制。取消後不呈現遲到結果。23 項附件聚焦測試通過；不宣稱防禦相同使用者惡意程序對所有暫存檔的攻擊，影音／Quick Look URL API 仍另列核對範圍，parity 計數不變。

PDF 預覽安全修正（2026-09-24）：PDF 畫面、頁數與文字擷取改用 gate 已驗證 Data 建立的同一份 PDFDocument，不再重新以 URL 讀檔。原檔替換／刪除後預覽仍是原快照；匯出文字前仍須重驗檔案。切換文件即使搜尋字詞相同亦重算高亮，避免舊搜尋結果殘留。22 項附件聚焦測試、原生 Debug build、deep strict 簽章與封裝通過；影音／Quick Look URL 載入仍需另行核對，未增加 complete 列。

圖片主檢視器安全修正（2026-09-24）：主圖不再於完整性 gate 通過後用 `NSImage(contentsOf:)` 重讀路徑，改以 gate 的已驗證 Data 快照解碼。圖片來源被替換／刪除不會讓解碼器讀到另一份內容；重新驗證竄改檔仍拒絕，空白／無效圖片維持錯誤狀態。非圖片不保留額外 Data，PDF／影音／Quick Look 的 URL API 仍有另外的核對範圍，不宣稱全部附件 parser 均無路徑競態。31 項聚焦測試、七語言圖片渲染測試、原生 Debug build 與 deep strict 封裝檢查通過；整體 parity 計數不變。

文字內圖片描述（2026-09-24）：`SendMessage.images` 現可混用舊版 ID 字串與 `{image_id,alt}`，每張描述沿用 500 字／2,000 UTF-8 bytes 與控制字元限制；整批圖片和描述經預覽核准，回條重播驗證全部描述，不能藉換描述重複發布。信箱重開保留描述，群組沿用已驗證的 annotation 保存路徑。完整非並行回歸 exit 0，原生 Debug 建置、deep strict 簽章與封裝通過。這取代下方歷史紀錄的「inline 逐張 alt 尚缺」；任意 URL／本機檔案、影片等附件語意仍未完成，矩陣計數不變。

解鎖後驗證（2026-09-24）：確認 macOS `IOConsoleLocked = No` 後，對 `fcc8354` 重跑完整非並行 `swift test`，exit 0。先前圖片、工作流程 EPERM 與共享聊天室 malformedState 未再出現，圖片描述增量的最終回歸阻礙已解除；下方失敗紀錄保留為前次鎖定時的結果。沒有降低檔案保護、重啟使用者 App／Xcode、push 或真實帳號操作。測試通過不代表其餘 parity 缺口完成，矩陣仍 43 complete／4 partial／1 NA。

圖片描述增量（2026-09-24）：目前單張 `SendMessage(type:attachment)` 接受可選 `alt`，最多 500 字／2,000 UTF-8 bytes，拒絕控制字元。描述顯示在核准預覽、懸停、圖片檢視與輔助閱讀，隨群組／信箱保存；圖片本體與來源 metadata 仍須完全相符，只有描述可變更，重送亦驗證描述。21 項 storage/delivery 與 19 項 App 測試曾分別通過；七語言渲染、原生 Debug 建置及 deep strict 封裝檢查通過。完整回歸未通過：工作流程暫存檔 EPERM、共享聊天室 malformedState 等失敗仍需追查；最後重跑圖片聚焦套件亦出現圖片暫存檔 EPERM 和連帶斷言失敗，尚無最後一次全綠結果。多張圖片逐張描述與其他附件類型尚未補齊，整體計數不變。

附件視窗增量（2026-09-23）：將附屬 sheet 換成可調整大小的獨立原生視窗，接上 macOS 全螢幕按鈕／Control–Command–F；七語言新增 Full Screen 字串。視窗關閉帶 preview ID，避免遲到回呼誤關新預覽；主視窗關閉與帳號撤銷會關閉附件並沿用暫存清理。21 項聚焦測試通過，包含隱藏 NSWindow 的全螢幕設定、同一預覽更新、替換、主視窗關閉及帳號清理；七語言各 1,661 keys、零缺漏。沒有啟動使用者 App，實際 macOS 全螢幕動畫未驗收；原版 lightbox 外觀與 alt caption 仍非完成，整體計數不變。

圖片呈現增量（2026-09-23）：群組／信箱及核准預覽共用單張放大、多張雙欄圖集；圖片寬高共同限制，避免窄欄溢出，草稿仍保留捲動區。18 項圖片 App 聚焦測試與七語言渲染通過，原生 Debug 建置成功。這批只補呈現，不包含來源 alt caption／全螢幕檢視、任意檔案／URL／影片。`AGENT-02` 仍 partial，整體計數不變。

接續圖片檢視增量：上述圖片已接上點擊開啟既有原生附件檢視器，包含縮放、圖集切換、另存副本。使用 agent image store 的帳號隔離及完整性檢查，不拿單聊附件 store 代讀；關閉／帳號切換會撤銷待處理開啟並移除預覽副本。App 測試模組 **368 項／49 suites** 非並行通過，含毀損拒絕及清理。這是原生 sheet，並非來源的全螢幕 lightbox，也尚未支援模型 alt caption。

圖片檢視修正（2026-09-23）：發現原有 `scaleEffect` 不會同步擴大可捲動範圍，且捏合每次重新從 1 倍開始。改為保持長寬比的實際 layout 尺寸、累積手勢比例（0.1–8 倍相對初始適配尺寸）、七語言既有「縮放／重設」控制列。18 項檢視器測試、七語言隔離渲染（法文抽查）、原生 Debug build 與嚴格簽章／封裝通過。未在使用者 App 做實際手勢驗收；不計為新增完整 parity 列，原版全螢幕 lightbox／alt 等缺口仍保留。

圖集安全補強（2026-09-23）：底部縮圖原先直接按路徑解碼，現在先在背景讀取並驗證 metadata 雜湊／長度，再只解碼同一份記憶體資料；取消後不套用結果。共用驗證讀取改用 `O_NOFOLLOW`／`O_NONBLOCK` 與 descriptor `fstat`，拒絕非一般檔案、超過現有附件上限及讀取長度改變。20 項聚焦測試（含同長度竄改、symlink、FIFO、圖片開啟清理）、原生 Debug build 與嚴格簽章／封裝通過。這批是縮圖安全修正，不代表其他原生媒體 parser 的路徑重開行為皆已消除，也沒有新增原版功能完成列。

再校正（2026-09-23）：`AGENT-02` 的 `SendMessage` 已可用 `{type:"attachment",image_id:"本輪ID"}` 發布**單張、無文字**的本輪輸入圖片，群組與代理人信箱均需即時圖片預覽核准；群組可取保存回條，信箱持久化於原 incoming delivery。拒絕、停止、過期圖片與非本輪 ID 不發布，圖片不被最後一段文字重複。下方較早快照的「均需文字／獨立附件全缺」以此段為準：任意檔案／URL、影片與來源原版完整附件語意仍缺。隔離聚焦、完整非並行回歸（exit 0）、原生 Debug 建置、deep strict codesign 與 package verifier 已通過；未做 live App 點擊或真實帳號／模型驗收。整體仍 **43 complete／4 partial／1 NA**。

最新校正（2026-09-23）：`AGENT-02` 的群組 `sand-msg` 連結早已有安全跳轉，本輪加上有效引用的 chip-like 行內底色／字重；原版圓角 chip 的精確樣式仍未還原。`ba6b915` 已補群組背景 peer wake 引用，`5b90593` 已補其選項問題，因此下方較早快照所列的「背景引用／提問」或把所有 chip 當成功能缺口，應按此段修正。mailbox／單獨聊天引用與提問仍缺。這批聚焦測試和原生 Debug 建置／簽章／封裝通過；完整回歸因 macOS 暫存檔 `EPERM` 未通過，不能當成全套驗證成功。矩陣仍為 **43 complete／4 partial／1 NA**；詳見[最新協作核對](Agent-collaboration-parity.md)。

後續同日驗收：修正背景群組問題卡工具提示的舊限制敘述，實際背景問答測試通過。macOS 暫存檔恢復可讀後，完整非並行回歸重新執行通過（exit 0），原生 Debug 建置／嚴格簽章／封裝檢查再次通過。前次 `EPERM` 失敗仍是紀錄中的環境事件；不等於 live 帳號、模型或 App 點擊驗收。

最新驗收（2026-09-23）：群組引用回覆已提交 `e5cad3c`。本輪接上可選的代理人記憶建議：只在完成的前景群組回合做額外無工具模型請求；候選事實逐筆審核，核准後才進入該帳號／代理人的私人記憶，預設關閉。停止、帳號／成員切換、封存或停用時拒收遲到候選；舊 store 可省略新欄位。完整預設並行 **135 XCTest、1,107 Swift Testing／125 suites**（App 363／49 suites，42.129 秒）通過；七語言各 **1,660 keys／零缺漏**，14 張審核卡預覽及繁中／法文抽查通過。原生 Debug 建置、deep strict codesign、package verifier 通過；兩項 opt-in live Codex 仍跳過，沒有真實 App 點擊、付費模型或 live 帳號驗收。原版自動記憶改寫／episode／archive、跨 session/fork、chip、背景引用／提問、外部 channel、獨立附件與安全憑證請求等仍缺，整體 **43 complete／4 partial／1 NA**。詳見 [協作核對紀錄](Agent-collaboration-parity.md)。

接續驗收（2026-09-23）：`AGENT-02` 的**群組背景 peer-message wake** 現可在來源對話工具權限下，引用目標群組最近 40 筆可用訊息並取得保存後的 messageID／shortAddress 回條。不可引用來源其他群組，不能繼承人類串接目標或讀歷史圖片；接續增量亦已接上背景群組選項問題，回答時在新的人類群組回合僅續接原提問者。mailbox／單獨聊天引用及提問仍缺。本次完整非並行回歸 **135 XCTest、1,110 Swift Testing／125 suites** 通過；原生 Debug 建置、嚴格簽章與封裝檢查通過。前批一次並行聚焦跑法的既有圖片暫存檔 `EPERM` 與後續重開失敗另記，不當作通過。整體仍 **43 complete／4 partial／1 NA**。實作與測試範圍見 [協作核對紀錄](Agent-collaboration-parity.md)。

2026-09-21 再次核對後，為 43 筆 `complete`、4 筆 `partial`、1 筆 `NA`（`UPD-04`）。`AUTO-03` 因已確認平台事件語意缺口，維持 partial；Linear 已補事件分類、送達識別、防重播、受核准模型提案與新狀態篩選，Sentry 已補五種 issue case／issueAny、正確 project ID 篩選與 body digest 去重，已接上模型 create/update、平面混合 OR 與七語言完整核准；PagerDuty 已補四種 incident case／incidentAny、精確 service ID 篩選、僅 v1 簽章候選與 signed-body／event.id 去重，已接上自身模型 create/update、完整核准及混合 OR；先前已補原生 Cycle/update 的明確完成轉換、team/cycle UUID 篩選和完成身分去重；已接上 endOfCycle／cycleIds 自身模型提案、混合 OR、七語言完整核准與生命週期防護。上一輪修正 Teams 傳出 webhook：不再以 HMAC 當使用者登入、分離 Graph/Bot 團隊 ID、拒絕非訊息活動、加入有範圍的訊息身分去重；缺少使用者／主文證據時保守不執行，不等於已還原 Teams 雲端功能。原生無專案關聯的週期提案拒絕非空 projectIds；手動新增 Linear／Sentry／PagerDuty 已有事件選單與精確篩選；既有 cron／五平台／平面 OR 已可手動編輯；GitHub 改用 14 種事件勾選，Slack 使用對話 ID、獨立關鍵字／表情欄位，拒絕靜默丟棄事件／截斷篩選；不支援的格式仍僅名稱／任務可改、trigger 原樣保留。原生 generic connector 本輪補嚴格 JSON 篩選、型別／精度比對與既有條件編輯；損壞條件不再變成 match-all，舊定義原樣保留。這是 Filicon-native 安全補強，模型 generic create/update 仍拒絕；Teams 已補保留登入限制的 literal 條件手動編輯；原版雲端等完整語意仍未還原。`AGENT-01` 已補受審批的模型 `CreateAgent`／`UpdateAgent`、own-profile `update_state(profile.set)` 及 own-agent `memory.write/forget`；先前已接上明確核准的 `scope:user` 共享事實與 note 分級、正規化去重及有預算的記憶召回，當時跨重啟與完整套件通過。先前補依當前使用者／peer 訊息的有界關鍵字相關性召回，維持帳號／私人／共享隔離與原始預算。本輪接上只讀 `SearchMemory`，讓模型分頁搜尋已核准但未注入的原始事實；先隔離帳號／私人範圍，游標綁 owner／turn／session，資料改變即失效，不授予內部檔案存取。這是 reference Read/grep 舊記憶的 native 對應，非原版同名工具、自動抽取或語意搜尋。仍限制在有 agent 身分的群組／mailbox，不改私人 persona，現已補需成員資格的 project 記憶但仍未涵蓋其他 update_state 路由，因此維持 partial。其他列的驗證欄保留歷史紀錄，不表示本次重新驗證；先前解鎖後完整回歸通過（134 XCTest、861 Swift Testing／98 suites）；本輪驗證見最新協作核對紀錄。鎖定時曾有受保護檔案重開失敗及既有測試索引越界中止，未弱化檔案保護；解鎖重跑未再出現，不把此誤報為並行 flake。更早的並行時序穩定性問題仍保留。本輪另補共用 ingress 安全重試、等待金鑰期間的路由／listener 撤銷、pending nonce 保護及 connector-scoped 佇列去重；不是持久佇列或 exactly-once。細項見 [協作核對紀錄](Agent-collaboration-parity.md)。

## Matrix

上一輪完整重跑通過（134 XCTest、898 Swift Testing／102 suites），但首次執行的既有 stdin 輸出測試曾收到空結果。本輪已以受控時序重現並修正 `ProcessSupervisor` 的提前完成：等待雙管線輸出交付、限制收尾等待，且將 terminationError 正確映射為失敗工具結果。不是僅靠重跑通過。最終驗證及背景子孫程序等限制見最新協作核對紀錄；其他既有並行風險不宣稱一併根治。

### 1. UI surface

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| UI-01 | `Sources/Filicon/FiliconApp.swift`、`AppModel.swift`、`WorkspaceNavigationBridge.swift` 提供 app root、sidebar、workspace route、commands 與 deep-link dispatch。 | complete | final gates passed |
| UI-02 | `FiliconApp.swift` 掛載 chats、search、agents、groups、automations、channels、shared rooms、MCP、computer、plugins、account 與 update surfaces。 | complete | final gates passed |
| UI-03 | `FiliconApp.swift` composer、`ComposerDraftStore.swift`、`AttachmentLifecycle.swift` 與 `FiliconVoice` 提供 draft、file/drop/paste staging、voice、send/queue/cancel。 | complete | final gates passed |
| UI-04 | `TranscriptPresentationState.swift`、`TranscriptRichPresentation.swift`、`TranscriptCardPresentation.swift`、`TranscriptCardActionRouter.swift` 與 `RichMarkdownView.swift` 提供 rich transcript、tool/thinking cards、reaction、reply、resend/delete 與 safe links；原生 Markdown 依 block intent 保留段落、標題、清單／引用層級及 hard break，inline 屬性與連結限制不變，非完整 CommonMark/GFM 或原版 pixel-perfect 排版。 | complete | `RichMarkdownViewTests`／`GroupReplyAppTests`，本輪完整回歸與七語言畫面驗收見協作紀錄 |

### 2. Conversation / transcript

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| CONV-01 | `AppModel.swift`、`ConversationStore.swift` 與 `ConversationRepository.swift` 提供 conversation CRUD、命名、隱藏/還原、選取與 transcript ownership。 | complete | final gates passed |
| CONV-02 | `TurnCoordinator.swift` 與 `AppModel.swift` 提供每 conversation queue、streaming lifecycle、cancellation、terminal cleanup，以及獨立 conversation concurrency。 | complete | final gates passed |
| CONV-03 | `FiliconDomain/Models.swift`、`TranscriptEventHub.swift` 與 transcript action router 持久化 rich messages、tool rows、reaction、reply、queued/failed resend/delete。 | complete | final gates passed |
| CONV-04 | `Pagination.swift`、`ConversationPaginationState.swift`、`GlobalSearchService.swift` 與 `AppModel.swift` 提供 cursor paging、request fencing、dedupe、find-in-chat 與 global search。 | complete | final gates passed |

### 3. Attachments / media

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| ATT-01 | `FiliconDomain/Attachments.swift`、`AttachmentStore.swift`、`AttachmentLifecycle.swift` 與 `AttachmentReferenceRepository.swift` 提供 SHA-256 content-addressed ingest、limits、metadata、staging、read/remove、reference lifecycle 與 quota。 | complete | final gates passed |
| ATT-02 | `AppModel.swift` composer staging 與 `FiliconApp.swift` file/drop/paste UI 將 attachment 連到 user message、turn 與 provider request，並支援取消/重試。 | complete | final gates passed |
| ATT-03 | `AttachmentMediaViewer.swift`、`AttachmentQuickLook.swift` 與 `AttachmentSpreadsheetPreview.swift` 提供 image/video/audio、PDF/Quick Look、CSV/TSV/XLSX preview、download/export 與 integrity/error states。圖片主圖／縮圖先做 hash 與完整格式驗證；SVG 限既有靜態安全子集，原檔保留。AV／Quick Look 仍使用 URL，不將圖片驗證當作其他 parser 安全完成證據。 | complete | 歷史能力分類保留；`AttachmentViewerTests` 及第七十八階段完整回歸／原生封裝通過，格式變體與完整 runtime 邊界見傳檔紀錄 |
| ATT-04 | `FiliconVoice/NativeVoiceRecorder.swift`、`VoiceComposerController.swift` 與 `SystemSpeechTranscriber.swift` 提供 microphone permission、bounded recording、cancel/retry、transcription 與 transcript attachment。 | complete | final gates passed |

### 4. Providers / models

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| PROV-01 | `FiliconProviderKit/HTTPProviders.swift`、`IncrementalParsers.swift`、`Provider.swift` 與 `TurnCoordinator.swift` 統一 SSE/NDJSON streaming、usage、error、abort、tool events 與 cancellation。 | complete | final gates passed |
| PROV-02 | `OpenRouterProvider` 已由 `AppModel.swift` registry 註冊，並以 provider-scoped `CredentialRef`、descriptor、endpoint wire contract 與 catalog integration 提供 OpenRouter routing。 | complete | final gates passed |
| PROV-03 | `FiliconProviderKit/CLIProviders.swift` 的 `CodexCLIProvider` 與 `ClaudeCodeCLIProvider` 使用各自官方 CLI 的 auth session、model/reasoning flags、stream parser、error mapping 與 no-credential state；不讀私有 app auth。 | complete | final gates passed |
| PROV-04 | `ProviderCatalog.swift`、`ProviderCatalogPresentation.swift`、`ModelRefreshGuard` 與 `AppModel.swift` 提供 dynamic/static catalog、provider/model snapshot、default fallback、reasoning capability、usage 與 unavailable/error state。 | complete | final gates passed |

### 5. MCP / plugins / tools / permissions

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| MCP-01 | `ToolModels.swift`、`ToolLoop.swift` 與 provider event normalization 提供 bounded eight-step tool loop、schema validation、parallel-safe execution、ordered results、duplicate/cancel errors。 | complete | final gates passed |
| MCP-02 | `FiliconMCP/Service.swift`、`ConfigurationStore.swift`、`MCPAccountsView.swift`、`FiliconPlugins` 與 `PrivateSkillsView.swift` 提供 server/plugin catalog、account/auth、tool toggles、install/remove/rename 與 private skills。 | complete | final gates passed |
| MCP-03 | `FiliconMCP/StdioTransport.swift`、`HTTPTransport.swift`、`MCPOAuthFlow.swift`、`MCPApprovalView.swift` 與 authorized dispatcher 提供 initialize/list/call、HTTPS/stdio boundaries、OAuth state、timeout、schema/policy dispatch。 | complete | final gates passed |
| MCP-04 | `ToolPermissionPolicy.swift`、`ToolApprovalBroker`、`FiliconLocalTools` 與 approval UI 提供 always/ask/never、allow-once scope、TTL/generation fencing、admin ceiling、deny 與 replay protection。 | complete | final gates passed |

### 6. Agents / groups / channels

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| AGENT-01 | `AgentService`、`Models`、`AgentsWorkspaceScreen`、`AgentAvatarStore` 提供 UI profile CRUD。`AgentManagementSession` 在群組／mailbox 接上 `CreateAgent`／`UpdateAgent`／own-profile `update_state(profile.set)`，完整欄位審批、停止撤銷、共用四次上限、重播防護與原子儲存。只改名稱／公開摘要；新增沿用發起者模型，不複製私人上下文或自動加入群組。own-agent `memory.write/forget` 已逐次審批、帳號＋代理人隔離、跨群組／mailbox 持久化。另有 `scope:user` 的帳號內共享事實，核准列明所有現有／未來代理人及其模型，舊記憶維持私人；UI 可檢視／忘記，模型只能刪自己的記錄。note 以較低重要性參與近期排序，私人／共享各有獨立召回預算與重複摺疊，省略不刪除原記錄。已接上當前訊息的有界關鍵字召回（英／繁中／簡中／法／西／日／韓例句），群組與 peer/mailbox 使用獨立 query snapshot。本輪新增 `AgentMemorySearch`／`SearchMemory` 只讀搜尋已核准事實，最多八筆／8 KiB JSON，32 次獨立讀取額度；空查詢可瀏覽，字串子串比對不做 regex／語意搜尋，來源和 canForget 保留。cursor 綁 owner／run／session／selected store fingerprint，變更後拒絕 stale；不查原始記憶檔／舊對話／私人 peer／其他帳號，不增加自動儲存或分享。新增 own-avatar set/clear：逐次預覽核准，只能選內建 pet_id 或恢復 Codex，與 profile／memory 共用四次額度，不接受原版 host/box path 圖片來源。群組／mailbox 另接 own-routine create/update/pause/resume/delete：逐次完整 before/after 核准，建立／修改支援固定時區 cron／alias／@every、單一 GitHub／Slack／Linear／Sentry／PagerDuty trigger 或受限 Teams 定義 或 1–8 個平面時間／事件 OR 條件，省略欄位與歷史保留，核准後開始且不補跑；delete 移除定義、歷史保留。不能越過費用防護；GitHub 需既有已驗證事件入口，CI 僅個別 push workflow 完成而非 checks 彙整；Slack 限對話 ID／*，不解析名稱或篩選自身身分；時間與事件可混合且逐項固定時區，揭露 OR／間隔共用基準；已補 Teams 的精確 scope／literal 定義提案，保留登入限制、事件仍不執行；generic event 是 Filicon-native 條件，不在已核對的原版模型 schema 中，不列原版缺口；既有平台語意限制仍未消除。本輪新增 own-workflow write：群組／mailbox 可提出自身本機手動單一 prompt 的建立／全文改寫，名稱／說明／body 必填且 body 最多 8,000 UTF-8 bytes；完整 before/after 核准明示本機流程庫共享與既有／未來引用影響，並展示已知直接引用。保留 owner／trigger／enabled／歷史，不立即執行；同 store revision／Stop／帳號切換、重播及共用四次修改額度防護，拒絕 peer／source-linked／managed／多步驟／action／scheduled 定義及權限欄位。另接自身 workflow delete：只接受 target/action/精確 ID，獨立 destructive 全文核准、同樣 owner/revision/lifetime 與四次額度防護；保留可依 ID 檢視的 run history 和已取得內容的執行，其他 workflow/routine/schedule/file/source/permission 不變，未來引用可能失敗或省略內容。流程庫不是帳號隔離記憶，也非跨程序版本鎖。新增 own-settings set：僅 JSON boolean notify_on_updates，獨立明確 before/after 核准與手動切換、專用持久化 revision 防 ABA／舊 editor 覆蓋；綁定 agent roster 系統通知，不改對話通知、核准卡、未讀／Dock、任務或權限。舊資料預設開啟；local profile 非 account 隔離。hidden_from_sidebar 明確拒絕。新增 own-channel disconnect：Slack／Discord 自身單一連線、歧義拒絕、完整計數核准、資料 revision／lifetime 與失敗回滾；移除本機連線及其紀錄，保留聊天／附件／鑰匙圈，不撤回遠端授權或已開始傳送。新增 own-project create/join/leave：固定帳號／自身身分，metadata 與完整成員資格核准；create existing 不覆蓋 metadata、leave 不刪專案；最多 50 個／帳號，完整快照與 revision 防 stale/ABA、Stop／帳號／封存／失敗回滾，共用四次額度。僅帳號隔離的成員資料，沒有新增檔案授權／群組／任務或私有記憶分享；不建立 reference 專案目錄。另補 `scope:project` 共享事實：同帳號已加入成員召回／搜尋、寫入／忘記逐次核准，模型只刪自己的記錄，人類可管理已離開作者的事實；成員快照／revision 防 stale/ABA，離開後停止讀取、不刪記憶，重新加入恢復；獨立有界召回與每專案跨作者共用儲存容量，私人記憶不自動分享。本輪補預設關閉、逐筆核准的前景群組記憶建議；候選不參加召回，僅核准後成為該帳號／代理人的私人事實。仍缺原版自動改寫／episode／任意 archive 檢索、其他入口／update_state 路由與完整 persona/runtime。 | partial | `AgentProjectMemoryTests`、`AgentProjectChangeTests`、`AgentChannelDisconnectionTests`、`AgentSettingsChangeTests`、`AgentNotificationProjectionTests`、`AgentManagementSessionTests`、`AgentAvatarChangeTests`、`AgentMemoryTests`、`AgentMemoryRecallTests`、`AgentMemorySearchTests`、`AgentMemorySuggestionTests`、`AgentMemorySuggestionAppTests`、`AgentManagementAppIntegrationTests`、`AgentWorkflowWriteTests`、`AgentWorkflowWriteAppTests`；本輪驗證狀態見協作核對紀錄 |
| AGENT-02 | `GroupService.swift`、`GroupConversationResponder.swift` 提供三輪接續、角色/增量上下文、去重、PASS/失敗、stop/cancel。`AgentUserMessageTool` 已接線 `SendMessage`：一般群組可發布本輪 host 綁定且使用者指定給自己的圖片；mailbox/peer wake 可發布本次 incoming 圖片，均需文字與獨立預覽核准。群組原子保存 room reply；canonical mailbox 先持久化發布紀錄，再鏡射來源 UI。Stop／失敗／重啟保留，每 turn 至多兩則，不重複 final text、不新增回覆成員。一般群組支援 1–6 選項提問、自訂文字、略過、保存／重啟後僅續接原作者；回答不等於工具核准，帳號／成員／封存失效及重複送出有防護。文字／核准圖片與 widget 可帶 reply_to，限 host 最近 40 筆同群組目錄的可用 UUID 或持久短位址；host 依完整歷史分配 t0u、t0s0 等，不因 prompt 截斷重新編號。先解析成 UUID 再防重播，格式錯誤／歧義／越界位址拒絕。固定作者、原子保存引用、舊資料相容；卡片顯示原文並可點回，原文缺失停用，不擴大收件者、不答覆問題、不載入歷史附件。引用問題保存後暫停，回答僅續接提問者而非原文作者，關係重啟保留。停止／帳號／成員撤銷、無效目標及保存失敗不回退普通訊息或問題。一般群組文字另支援 sand-msg 行內跳轉，沿用持久短位址，只定位同群組較早且唯一的原文；無效標籤不開外部 App、不讀附件或授權工具。新增保存後成功回條：固定作者／群組的 messageID 與有效 shortAddress 由 host 回傳，最多兩筆新訊息可加入同回合目錄，文字／核准圖片／提問可引用剛發布的內容；舊無回條 callback 不捏造位址，保存失敗不耗額度，儲存後取消仍記錄冪等結果；提問照常暫停。新增一般群組折疊討論串：完整歷史的一次掃描投影歸併有效巢狀引用，計數與暫存展開狀態、引用定位先展開；問題／工具 pending 時強制開啟。損壞／循環／前向／歧義／跨群組引用留主時間線，無資料遺失或權限變更。新增人類回覆 context menu／hover 入口及可取消預覽、群組獨立草稿與 account 清理；保存時拒絕壞 target、不回退普通發送。同回合模型 publication／final 自動引用最新人類回覆，明確目標可覆蓋；串內問題答案及續接保持串接，一般新訊息回主線。舊 target 附有界 quotation、不讀歷史圖片；文字／圖片輸入與三種撤銷已有 fixture 回歸。仍缺原版 chip、跨 session/fork、mailbox／背景引用及提問、外部 channel、獨立附件、安全遮罩憑證請求及供應商 cloud-agent 卡；不能以一般 UI 已有回覆／頻道視為已接線。仍非完整圖片來源或原版 runtime。 | partial | `GroupCollaborationTests`、`GroupToolExecutionTests`、`AgentBackgroundExecutionTests`、`AgentUserMessageToolTests`、`AgentPublicationReceiptTests`、`AgentImageAppIntegrationTests`、`AgentQuestionTests`、`GroupQuestionAppTests`、`AgentReplyTests`、`AgentQuestionReplyTests`、`GroupMessageAddressTests`、`GroupMessageReferenceTests`、`GroupThreadProjectionTests`、`GroupUserReplyTests`、`RichMarkdownViewTests`、`AgentImageMessagingTests`、`GroupReplyAppTests` 及工具迴圈暫停測試；本輪完整回歸與缺口核對見協作紀錄 |
| AGENT-03 | `FiliconSharedRooms` 的 file/HTTPS transports、`SharedRoomsWorkspaceView.swift`、`FiliconChannels/ChannelService.swift` 與 REST connectors 提供 room invite/approval/member lifecycle、channel inbound/outbound、attachments、reactions、OAuth 與 delivery retry。已修正 channel 保存回滾、斷線與暫停後 listener 生命週期、非同步 profile 的配置世代與最新請求防護、重疊 flush／傳送前持久化；新增模型 own-channel disconnect，僅自身唯一 Slack／Discord 連線，獨立核准與 revision／lifetime 防護，保留鑰匙圈與遠端授權；不宣稱 live 帳號驗收。 | complete | 歷史列能力保留；本輪頻道／管理聚焦 64 項、完整 135 XCTest＋965 Swift Testing、原生 build／嚴格簽章及七語言核准卡驗證通過；先前 Xcode 初始化阻擋已解決，見最新協作紀錄 |
| AGENT-04 | `AgentMessagingSession` 提供固定寄件身分、完整 payload approval、durable queue、recipient/reply wake、權限/停止/逾時/上限。手動訊息已接上背景推論與審批 UI。已補審批後貼入自己所屬其他群組的文字訊息與房間回覆；忙碌目標拒絕，兩群組／六委派上限。`AgentConversationStore` 持久化 account/origin/agent 隔離上下文。App 共用 `AgentExecutionScheduler` 將群組、mailbox、子任務、自動化、workflow、channel reply 依 agent 串行（一般工作 FIFO），取消等待不影響其他 owner，host 工具清理後才放行。已補明確核准的 peer/manual priority：來源 drain 後可中斷背景 peer/group/排程自動化，使用者回合受保護；工具清理後才交棒、不重播。群組 priority 不支援，也非 enqueue 當下立即中斷。仍非跨全部 DM/群組統一私人記憶或完整原版 runtime；手動訊息及一般群組可輸入有界 PNG/JPEG，當輪圖片 ID 可經審批後轉交單一 peer 或 SendMessage 發布。歷史圖片不自動重播；任意圖片來源、跨程序與重啟排程仍缺。參考的 postToGroup 也是文字入口，不能將跨群組圖片視為已確認原版缺項。 | partial | `AgentMessagingSessionTests`、`SendToAgentAppIntegrationTests`、`AgentGroupMessagingTests`、`AgentGroupMessagingAppTests`、`AgentBackgroundExecutionTests`、`AgentConversationStoreTests`、`AgentExecutionSchedulerTests`、`AgentImageMessagingTests`、`AgentImageAppIntegrationTests`、`GroupImageAppTests` |

### 7. Automations

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| AUTO-01 | `FiliconAutomations/CronSchedule.swift`、`AutomationService.swift` 與 `Scheduler.swift` 提供 cron/alias/`@every`、timezone/DST、next-run、durable claim、cancel/reconcile 與 restart recovery。內部平面 `.anyOf` 已補最早時間與事件／手動共用 last-run 基準、同時命中單次執行、舊資料不自動啟用、stale batch 與開始執行寫檔失敗回滾；模型混合條件入口與七語言完整核准已接上，單項 cron／alias／interval 可與 GitHub／Slack 任意平面混合。 | complete | 本輪 85 項聚焦回歸與原生建置通過；完整回歸待 Mac 解鎖，詳見協作核對紀錄 |
| AUTO-02 | `AutomationService.swift`、`Models.swift`、`WorkflowWorkspaceView.swift` 與 AppModel integration 提供 routine CRUD、enable/disable、Run Now、next/last run 與 bounded run history。群組／mailbox 可提出自身排程 create/update（固定時區的 cron／alias／@every、單一 GitHub／Slack／Linear／Sentry／PagerDuty trigger 或受限 Teams 定義 或 1–8 個平面時間／事件 OR 條件）、pause/resume/delete；ID、完整 before/after 任務與觸發條件／enabled 核准後套用，防 stale／Stop／帳號切換／寫檔失敗；費用防護不由模型解除；修改保留現有歷史，delete 不取消已執行／已排隊工作，歷史留存但無還原入口。GitHub 可篩選 repo／事件／作者與操作人／CI 分支，須既有已驗證連線，不會自動安裝 webhook；CI 只看個別 push workflow 完成，Slack 支援普通訊息／App 提及／關鍵字／新增表情的明確 ID 或 * 篩選，不支援名稱解析或自身身分；已支援時間／事件混合 OR 的模型 create/update，每項時間皆固定時區並驗證 366 天內可執行，核准明示事件／手動執行重設間隔；Linear 支援 issueCreated／statusChanged／endOfCycle 與 teamIds／projectIds／新 statusIds／cycleIds 的明確 UUID 篩選；statusIds 僅用於狀態變更、cycleIds 僅用於週期完成，原生週期拒絕非空 projectIds；Sentry 已支援五種 issue case／issueAny 與精確十進位 projectIds 篩選、完整核准及生命週期防護；PagerDuty 支援四種 incident case／incidentAny 與精確、區分大小寫的 serviceIds 篩選、完整核准及混合 OR；尚缺 checks 彙整及其他 event/platform 的模型 create/update。 | complete | 非並行完整回歸 134 XCTest、812 Swift Testing 通過；並行測試穩定性限制詳見協作核對紀錄 |
| AUTO-03 | `PlatformTriggers.swift`、`AutomationIngress*`、`EventBatcher.swift` 與 connector integration 提供 matching／signature／去重及 audit 基礎。Linear 已補 issueCreated／statusChanged、team/project/new-status 篩選、送達識別、signed-body timestamp／digest 防重播、模型 create/update 與七語言核准；保留舊儲存，不自動遷移排程。Sentry 已補五種 issue case／issueAny、data.issue.project.id 精確篩選、body digest 作 nonce 及事件 ID、重開與 history 去重；Request-ID 僅供診斷，無簽章時間戳可證明新鮮度，也不是永久防重播；舊 raw-action 定義保留原有比對。已接上 Sentry 自身模型提案、完整核准、精確 projectIds 與平面混合 OR；PagerDuty 已補四種 incident case／incidentAny、V3 resource／type 驗證、精確 service_reference ID 篩選，body digest nonce 及已簽章 event.id history 去重；僅接受 v1 簽章候選，delivery ID 僅診斷，occurred_at 不當送達新鮮度證據；保留舊 raw-event 定義。已接上 PagerDuty 自身模型 create/update、完整核准與平面混合 OR，serviceIds 最多 50 個精確且區分大小寫的 ID，不作名稱查找或隱含連線。本輪補原生 Cycle/update 的 null→completedAt 轉換、team/cycle UUID 篩選與 cycle＋完成時間的 history 去重；不把單純日期到期當事件，原生無 project 歸屬時拒絕專案篩選。已接上 cycle 自身模型 create/update、完整核准及混合 OR，原始 cycleIds 清單最多 50 個 UUID，非空 projectIds 與不適用的 statusIds 直接拒絕；沒有自動遷移／啟用舊定義。Teams 原生入口已分離傳輸簽章與使用者登入，Graph UUID 用 aadGroupId、Bot ID 保留獨立比對；僅分類完整的頻道 message，非訊息／超限上下文不觸發，以 tenant/team/channel/conversation/activity 身分 hash 去重。保留 blockUnauthenticatedUsers 的條件一律不執行；未證明主文時須有明確文字篩選，既有權限不放寬。手動編輯器保留預設登入限制並明示不能執行，模型 Teams create/update 已接上同樣受限定義與獨立核准，Teams 事件仍不執行。共用入口已補佇列拒收後安全釋放 nonce、儲存失敗時保守拒收、金鑰返回後重驗 route revision／listener generation／適用的簽章時間戳；pending nonce 不會提前到期，接受後不撤回。佇列採 connector＋external event ID，已入列副本與容量不足分開；仍無 crash-safe delivery／exactly-once。本輪已補手動新增 Linear／Sentry／PagerDuty 的事件選單、正確預設、case 專屬 ID 欄位與七語言說明；每欄最多 50 筆原始 ID、空逗號項及無效／不適用條件拒絕，切換事件保留篩選供使用者修正，不自動放大範圍。既有定義不遷移；已補既有 cron／GitHub／Slack／Linear／Sentry／PagerDuty／平面 OR 的手動編輯，原子儲存保留 runtime／history／費用防護，拒絕 stale／取消／帳號切換／owner 封存的未提交寫入；其他 trigger 僅可改名稱與任務、原定義唯讀保留。GitHub／Slack 新增與編輯共用嚴格驗證，GitHub 14 事件勾選、精確 CI 分支／登入名稱；Slack 對話 ID／獨立關鍵字與表情篩選，保留不適用條件供明確清除。拒絕默默丟棄未知事件、截斷過長字串或省略無效篩選。舊 Slack 名稱／bySelf、未知格式唯讀。generic 已補嚴格有界 JSON、精確型別／數字與 connector scope 比對、損壞分支不匹配及既有條件手動編輯；模型 generic 寫入仍拒絕。已補 Teams 的有界 literal 條件新增／編輯：保留登入限制、嚴格清單與 scope／text 驗證，regex／不同政策／空篩選等舊格式維持唯讀，保存再驗證；不啟用 Teams 事件執行；模型提案另經完整核准與提交時重驗。仍缺原版雲端完整語意；GitHub 仍為個別 push workflow 而非 checks 彙整，Slack 仍無名稱／人類身分映射。不能將 generic matcher 或歷史 ingress 測試視為原版各事件完整還原。 | partial | `TeamsRoutineEditorTests`、`ConnectorRoutineFilterTests`、`ConnectorRoutineEditorTests`、`GitHubSlackRoutineEditorTests`、`ManualRoutineEditTests`、`RoutineEditAppTests`、`RoutineListenerEditorTests`、`IngressAdmissionTests`、`TeamsRoutineEventTests`、`PagerDutyRoutineEventTests`、`SentryRoutineEventTests`、`LinearRoutineEventTests`、`AgentRoutineChangeTests` 與 App fixtures；上一批 59 項編輯／事件／語言聚焦、42 張 generic 欄位與 98 張完整 sheet 七語言明暗渲染、原生 clean build 與嚴格簽章通過；完整回歸見最新協作核對紀錄，非 live 平台驗收 |
| AUTO-04 | `AgentWorkflowModel.swift`、`AgentWorkflowStore.swift`、`AgentWorkflowRuntime.swift`、`WorkflowService.swift` 與 `WorkflowAppIntegration.swift` 提供 SKILL/workflow import/codec、trigger/action validation、run history/cancel/replay；Teach recording queue scope 與 attachment-backed scoped auto-dispatch 已接線。 | complete | final gates passed |

### 8. Computer / local execution

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| COMP-01 | `FiliconLocalTools`、`FiliconLocalToolHelper`、`FiliconLocalToolXPCService`、`ProcessSupervisor.swift` 與 `RequestGuard.swift` 提供 command/read/write/send-input、permission gate、generation/timeout/termination 與 XPC isolation。本輪 `ProcessOutputReader` 等 stdout/stderr 確認交付後才公布完成；64 KiB 單區塊交付、10 MiB 合併上限、子程序退出後一秒有界收尾。部分輸出／diagnostics 保留，App 依 terminationError 標示工具失敗；不擴大執行授權或宣稱任意背景子孫監督。 | complete | 歷史 final gates；本輪 `ProcessOutputTests`／`LocalToolsTests`／`ProcessResultPresentationTests` 與完整驗證見協作核對紀錄 |
| COMP-02 | `HTTPSRemoteComputerBackend.swift`、`RemoteIsolation.swift`、`RemoteComputerControlsView.swift` 與 lifecycle coordinator 提供 HTTPS remote runtime status/start/update/recreate/recovery、resource caps、filesystem boundary、terminal/file transfer。 | complete | final gates passed |
| COMP-03 | `ScreenCaptureKitBackend.swift`、`VNCTrustedBridge.swift`、`VNCIsolationPolicy.swift`、`VNCTakeoverController.swift` 與 `VNCWebView.swift` 提供 trusted preview、takeover/handback、clipboard/input guard、session lease 與 reconnect。 | complete | final gates passed |
| COMP-04 | `TeachRecordingController.swift`、`TeachSensitiveMasking.swift`、`ScreenCaptureKitBackend.swift` 與 workflow integration 提供 private-monitor recording、600-second cap、mask/pause sensitive windows、save/discard、recovery/quarantine 與 update confirmation。 | complete | final gates passed |

### 9. Account / settings

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| ACCT-01 | `KeychainCredentialStore.swift` 與 `FiliconAccount/KeychainSecretStore.swift` 提供 provider/account-scoped secrets、missing/isolation handling；UI 僅顯示狀態。 | complete | final gates passed |
| ACCT-02 | `FiliconSettings/SettingsStore.swift`、`SettingsModels.swift`、`SettingsView` 與 `AppModel.swift` 提供 provider/router/model、theme/timezone、permission、usage、update、sidebar、validation、migration 與 atomic save。 | complete | final gates passed |
| ACCT-03 | `FiliconAccount/Authentication.swift`、`Connection.swift`、`HTTPSAccountProvider.swift`、`AccountExperienceView.swift` 提供 browser OAuth、restore/refresh/logout、profile、entitlement、usage、feedback 與 access/error state。 | complete | final gates passed |
| ACCT-04 | `FiliconSecurityKey`、`FiliconAutoReview`、settings integration 與 account UI 提供 WebAuthn/security-key consent、auto-review approval、notifications、local-tool settings 與 account-scoped persistence。 | complete | final gates passed |

### 10. Notifications / deep links / window

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| NOTIF-01 | `FiliconApp.swift`、`WindowStateController.swift` 與 `FiliconSettings/WindowStateStore.swift` 提供 single-window lifecycle、native commands、traffic-light window 與 restore state。 | complete | final gates passed |
| NOTIF-02 | `SystemNotifications.swift`、`AgentNotificationPolicy.swift`、`NotificationThrottle.swift`、`InAppNotificationCenter.swift` 與 Dock projection 提供 permission、needs-input/done/error notifications、focus action、throttle、tray、badge。 | complete | final gates passed |
| NOTIF-03 | `DeepLinks.swift`、`WorkspaceNavigationBridge.swift` 與 `FiliconApp.swift` `onOpenURL` 提供 strict allowlist parsing、cold-start queue、dedupe、bounded pending queue 與 route dispatch。 | complete | final gates passed |
| NOTIF-04 | `WindowStateController.swift`、`WindowStateStore.swift` 與 `WorkspaceNavigationState.swift` 持久化 bounds/maximized/navigation history，並提供 reload、error recovery 與 out-of-bounds handling。 | complete | final gates passed |

### 11. Persistence / search / recovery

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| PERS-01 | `ConversationRepository.swift`、`ConversationTranscriptService.swift`、`TranscriptEventHub.swift` 與 SQLite schema 提供 transactional transcript/session/event lifecycle、FTS、memory buffer 與 replica recovery。 | complete | final gates passed |
| PERS-02 | `AttachmentLifecycle.swift`、`AttachmentReferenceRepository.swift`、`AttachmentStore.swift` 與 message model references 提供 attachment bytes/metadata/index、dedupe、reference counts、GC 與 crash-safe commit。 | complete | final gates passed |
| PERS-03 | `StartupDataRoot.swift`、`ConversationRecovery.swift`、`StorageQuota.swift`、`SettingsStore.swift` 與 `ConversationStore.swift` 提供 canonical-root migration、corrupt quarantine、atomic settings/blob writes、quota 與 idempotent recovery。 | complete | final gates passed |
| PERS-04 | `GlobalSearch.swift`、`GlobalSearchService.swift`、`Pagination.swift`、`ConversationPaginationState.swift` 與 startup recovery 提供 message/media/roster search、paging、index fallback、rebuild、retry 與 visible recovery state。 | complete | final gates passed |

### 12. Updates / distribution

| ID | 現行實作（authoritative evidence） | 狀態 | 驗證 |
|---|---|---|---|
| UPD-01 | `scripts/package-app.sh`、`scripts/verify-package.sh`、`scripts/verify-package-entitlements.py`、`Package.swift` 與 signed app bundle 提供 build/package、nested helper/XPC assembly、metadata、hardened runtime flags 與 strict verification。Xcode 資源變更已宣告簽章輸出依賴；Debug 例外只接受完整 bundle 路徑及經確認的系統別名，Release 禁止開發例外。 | complete | 歷史 final gates；本輪政策 fixtures 與 13 次原生 Debug build／內容／deep strict／完整 package verifier 通過；詳見協作核對紀錄，非公證驗收 |
| UPD-02 | `FiliconUpdater/UpdateService.swift`、`UpdateManager.swift`、`UpdateConfigurationResolver.swift`、`BackendUpdateRequirement.swift`、`UpdatePresentation.swift` 與 `UpdateIdleMonitor.swift` 提供 channel/default/runtime checks、signed feed resolution、download/verify/stage/install、idle/required UI；runtime/default/backend requirement signal 已接線。 | complete | final gates passed |
| UPD-03 | `scripts/release-macos.sh`、`generate-update-feed.swift`、`generate-update-feed-key.swift`、`read-update-feed-key.swift`、`verify-release-artifacts.sh` 與 updater verifier/install pipeline 已完成；本機 signing key 已安全存入 Keychain，`filicon-notary` 已以 App Store Connect Team Key/issuer 驗證；`v0.18.0` 已發布 notarized/stapled ZIP、DMG 與 signed update feed 至 [GitHub Release](https://github.com/irons163/filicon-bot/releases/tag/v0.18.0)。 | complete | Apple notarization + Gatekeeper/stapler + remote checksum/feed signature passed |
| UPD-04 | Electron/ASAR/preload、Windows installer/overlay 與來源 daemon wiring 是來源 runtime 細節，不是 macOS 原生產品行為；Swift package 以原生 targets 取代它們。 | NA | final gates passed |

## Verification note

歷史 verifier 紀錄：553 tests（420 Swift Testing、133 XCTest）、WAE、release build，以及 `v0.18.0` release `0.18.0-184` 的簽署／發佈檢查曾通過。這些不是本輪重新驗證，也不能證明功能完整對等。舊版「沒有剩餘 parity gap」結論已撤回；目前至少有上述 AGENT-01/02/04 缺項，其他區域仍需逐項端到端核對。`UPD-04` 維持 NA。
