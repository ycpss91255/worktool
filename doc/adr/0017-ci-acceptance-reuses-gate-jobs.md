# 0017 CI 的驗收 2.1／2.3 沿用同一個 run 的 gate job

- 狀態：已採納（2026-11-10）
- 討論：#824（維護者最終決定第 1 項，原話「ok 依據你建議的做」）、#833、#687
- 依據 ADR-0007（永不靜默失敗）與 ADR-0010（黑箱可驗）。

## 背景

milestone-gate PR 的 `verify-all` 以 `just verify all` 實跑非實機驗收。其中 2.1（裸 `just test` 七個階段）與 2.3（integration 與 system-real 的 ghostty 鏈）在 CI 裡把同一個 run 的 gate job 剛跑過的 tier 又跑一次：同一個 head sha、同一組 runner，結果只會重複，卻把 milestone PR 的 CI 拉長數十分鐘，與 #824 的五分鐘目標衝突。

## 決策

1. CI 中 `verify-all` 依賴 `gate` 與 `test-system-real`，在它們完成後才開始，並以 `WORKTOOL_VERIFY_GATE_RUN`／`_SHA`／`_REPO` 指名自己的 run 與 PR head sha。
2. 有這三個變數時，`script/verify/gate.sh` 的 2.1 判讀該 run 中每個架構、裸 `just test` 每個階段的 gate job；階段集合讀自 `script/test/test.sh` 的 `HOST_STEPS`，不另寫一份清單。2.3 判讀每個架構的 integration 與 system-real job，並下載它們的 log，以本機模式相同的區塊檢查判讀。
3. fail closed：job 缺少、重複、未完成、skipped、cancelled、非 success、run 或 head sha 不符，都使該項失敗；查詢失敗也失敗。三個變數只設一部分是 UNAVAILABLE（3），不退回本機模式。stdout 列出每個沿用的 job（名稱、結果、run、job id）。
4. 本機 `just verify gate`／`just verify all` 不設這三個變數，照常完整執行 tier。

## 影響與限制

milestone PR 的 CI 時間變成 gate 的時間加上 `verify-all` 其餘群組的時間；gate 紅時 `verify-all` 被 skip，`ci-passed` 在 milestone-gate PR 上把它讀成失敗。CI 模式相信 GitHub Actions 回報的 job 結論與 log；job 名稱與階段的對應（`lint`、`test-<階段>`，各帶 runner）及 runner 集合（`lib/verify_ci_gate.sh` 的 `verify_ci_gate_runners`，由 spec 對 ci.yml 檢查）若改變，判讀會失敗而不是誤判通過。main 的 unit 分片（#831）與 gate 合併（#841）同步進驗收分支時，對應規則要一起更新。
