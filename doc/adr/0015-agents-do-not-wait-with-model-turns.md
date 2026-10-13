# 0015 Agent 不花模型回合等待工作

- 狀態：已採納（2026-10-12）
- 討論：#550；問題證據：#541 的修正紀錄
- 依據 ADR-0007（永不靜默失敗）、ADR-0008（just 唯一入口）與 ADR-0010（黑箱可驗）；配合 ADR-0014：保留切片測試與推送前 gate，改變長工作的執行與結果交接方式。

## 背景

#541 的修正中，codex 被外層 timeout 中斷後，多次重新載入上下文只為等待測試。`tail --pid`、持續追蹤 log、sleep 輪詢讓模型回合承擔作業系統能完成的等待，也把大量 log 帶進上下文。

## 決策

1. 共用 `.agents/script/job.sh`，使用者入口是 `just job start|wait|status`。工作脫離呼叫行程，pid、log、rc 存於 `.agents/state/job/<name>/`。名稱不得穿越目錄；既有名稱不得覆寫。#550 明確指定的 `job.sh` 是 `.agents/script/` 頂層可執行檔的唯一例外，lint 仍拒絕其他頂層腳本。
2. `wait` 以單次阻塞收集結果，只輸出結果與 log 尾段；失敗優先輸出失敗段落。成功退出 0、失敗退出 1、仍執行退出 124、參數錯誤退出 2。完整 log 留在 state，不傳回實作 agent。
3. 擴充已註冊的 `enforce_long_job_timeout.sh`，所有 agent 的前景純等待與輪詢都拒絕：tail 跟蹤、watch、超過 5 秒的單獨 sleep、while／until 加 sleep。一般 session 的 shell 內建 `wait` 可等待自己啟動的行程（#552）；只有 `pr-loop` 角色拒絕內建 `wait`。短 sleep、背景工具通知、Monitor、一般 session 的 job wait，以及有 timeout 的單次阻塞呼叫維持允許。
4. pr-loop 的每次 codex exec（含 resume 與複驗）帶 `WORKTOOL_AGENT_ROLE=pr-loop`。這個角色只做切片 spec 與 lint，不能執行長 gate 或任何等待，即使工具設有 timeout 或背景旗標也一樣。
5. workflow 的獨立低 effort agent 使用 job start 加 job wait 執行長 gate，成功後才發布；失敗只交回摘要讓 codex 修正，再跑 gate。CI checks 也走 job。沒有角色標記的維護者獨立驗收 session 仍能執行 `just verify all`、`realbox`、`just test`。

## 影響與限制

ADR-0014 的推送前 lint 與 changed 要求不變，pr-loop 由 workflow 承擔長 gate。依 #554，Claude 一般 session 的長工作仍須符合既有 timeout 規則；實作端 CLI 的 PreToolUse 輸入以 `turn_id` 欄位辨識，shell `tool_input` 只有 `command`，因此不套用 Claude 專屬時間上限要求，由外層 runner 限時。兩種來源的輪詢封鎖與 pr-loop 角色限制相同；若 CLI 日後改變輸入格式，來源判斷可能失準。角色標記能被 unset；直譯器、字串拼接與自訂腳本包住的等待不在檢查範圍內。這是工作分工約束，並非防止惡意繞過的安全邊界。

hook 與 job 的 Docker spec 驗證公開行為；workflow spec 驗證 stage 交接與提示契約。合併後依 #550 在實際 harness 驗證 subagent 拒絕輪詢、workflow codex 拒絕 changed，以及一般驗收路徑仍可使用，結果貼於 PR。
