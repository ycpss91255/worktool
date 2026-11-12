# 0017 CI 的驗收 2.1／2.3 沿用同一次 run 的 gate job

- 狀態：已採納（2026-11-10）
- 討論：#824（維護者最終決定第 1 項）、#833、#687；實作與接線：#923、#926、#951、#961；文件恢復：#976
- 依據 ADR-0007（永不靜默失敗）與 ADR-0010（黑箱可驗）。

## 背景

milestone-gate PR 的 `verify-all` 執行非實機驗收。驗收 2.1 的裸 `just test` 與 2.3 的 integration、system-real，在 CI gate 已執行同一 head 的測試後再次執行，增加等待時間。#824 的最終決議以判讀同一次 run 的結果取代 CI 中這兩項的重跑；此前要求 2.3 自行重跑的決定已被取代。

## 決策

1. milestone-gate PR 的 CI 中，`verify-all` 等候 `gate`、`test-unit-verdict` 與 `test-system-real`，並將本次 run ID、PR head SHA 與 repository 透過 `WORKTOOL_VERIFY_GATE_RUN`、`WORKTOOL_VERIFY_GATE_SHA`、`WORKTOOL_VERIFY_GATE_REPO` 傳給驗收程序。
2. 2.1 判讀每個架構、裸 `just test` 所有 tier 的必要 gate job；tier 集合從 `script/test/test.sh` 的 `HOST_STEPS` 推得。2.3 判讀每個架構的 integration 與 system-real job，下載日誌並套用與本機相同的區塊檢查。
3. job 名稱與架構由同一 checkout 的 `.github/workflows/ci.yml` 推導：依 gate matrix 的 tier 對應 leg，否則使用該 tier 的 verdict 或獨立 job。unit 分片由聯集 verdict 判定（ADR-0016）。tier 無法對應 job 即失敗，不另維護一份固定清單。
4. 必要 job 必須在指定 run 中恰好出現一次，已完成、結論為 success 且 head SHA 相符。缺少、重複、未完成、skipped、cancelled、非 success、run 或 SHA 不符，以及查詢或日誌取得失敗，均不通過；輸出列出沿用的 job。三個 CI 參數只設定部分或格式有誤時回報無法判定，不退回本機模式。
5. 本機未設定這三個參數時，`just verify gate`／`just verify all` 照常完整執行 2.1 與 2.3。其他驗收項目維持各自規則。

## 影響與限制

此判讀依賴 GitHub Actions 回報的 job 結論、head SHA 與日誌，以及 workflow 的 job 命名與矩陣結構；無法取得必要證據時不通過。同一次 run 不表示 job 在同一台實體 runner 執行，也不保證固定的 CI 完成時間。

這項機制只涵蓋 CI 自動驗收的 2.1／2.3，不取代實機驗收、最終 milestone PR 固定 head 的雙架構實跑與人類核准；交接前同 commit 的完整序列執行另見 ADR-0019。一般 PR 的 prior-run meta 路徑是另一項機制，不是此處的同 run 判讀。
