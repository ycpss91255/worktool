# 0019 交接與 release 要求同一個 commit 的綠燈完整序列執行

- 狀態：已採納（2026-11-10）
- 討論：#824（維護者最終決定第 5 項）、#837；依賴 #836 的 nightly 完整序列執行
- 依據 ADR-0007（永不靜默失敗）與 ADR-0010（黑箱可驗）。

## 背景

PR CI 為了 5 分鐘目標改成分片、同檔並行與沿用 gate 結果（#824），nightly 每天在 main 上跑一次完整序列執行。但 milestone 驗收 PR 的 head 不在 main 上，nightly 的綠燈證明不了「交出去的那個 commit」；release 也一樣。

## 決策

1. Nightly（`.github/workflows/nightly.yml`）的 `workflow_dispatch` 接受 `sha`：測試在那個 commit 上跑，run 標題為 `full-serial <sha>`；格式不是完整 40 碼即失敗；不同 sha 的 run 各自排隊；這類 run 不碰 `nightly-failure` issue。
2. `.agents/script/monitor/full-run.sh` 以標題找出該 sha 最新一次 run：`completed` 且 `success`、兩架構的 `full-serial`／`isolation` 各恰好一個成功 job,並各有成功的 `Verify checkout <sha>` 步驟實際比對 HEAD 才是綠燈（0；#899 修復原判準漏查 skipped job 的缺口），較新的失敗蓋過較舊的成功，沒有 run 或查詢失敗是非綠燈（1），執行中是 pending（3）；`--dispatch` 在沒有綠燈也沒有執行中的 run 時啟動一次，`--wait N` 有界輪詢。
3. `milestone-handover` 在 Head 之後、Scratch 之前加 Full run 階段：對 PR head 執行上述檢查（必要時 dispatch），最多等 10800 秒；只有綠燈才繼續，否則回 `full-run-not-green`，不交出。
4. release 只在 `full-run.sh` 回 0 的 sha 上打 tag；日後有 release workflow 時由它強制執行同一個檢查。

## 影響與限制

交接多等一次完整序列執行（數十分鐘，與 nightly 相同的內容）；同一個 head 已有綠燈時不重跑。判定依 GitHub Actions 回報的 run 標題、結論、必要 job 與 checkout 驗證步驟；push/schedule 另核對 run headSha,dispatch 的 headSha 是 workflow ref,使用 checkout 驗證綁定 input sha。最新 skipped-success 不回退舊綠燈,缺證據的舊 run 需重跑。run/job 查詢失敗不自動 dispatch。有人手動以相同標題觸發不同內容的 run 不在防範範圍內（`run-name` 由 workflow 決定，手動輸入只能是 sha）。
