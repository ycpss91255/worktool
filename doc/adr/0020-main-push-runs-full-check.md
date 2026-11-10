# 0020 main push 在合併的 sha 上跑完整檢查，排程只補空缺

- 狀態：已採納（2026-11-10）
- 討論：#851（維護者原話「我要求每一個 PR 時間就是在 5-10分鐘, PR merge 進入 main 後需要跑完整檢查, 時間不設限, 但是要確定 ci 是否有冗餘的測試」）；取代 #824 的 5 分鐘目標，延伸 ADR-0019。
- 依據 ADR-0007（永不靜默失敗）與 ADR-0010（黑箱可驗）。

## 背景

PR 的 code run 以分片與沿用結果壓在 5-10 分鐘；完整的序列裸 `just test` 與完整 2.3 原本只在每天的 nightly 與交接前的指定 sha 執行（#836、#837），一個 main sha 的完整檢查最晚隔天才知道。

## 決策

1. `nightly.yml` 加 `push: branches: [main]`：每個 main sha 都跑 `full-serial` 與 `isolation`，不限時間；run 標題 `full-serial <sha>` 讓 `full-run.sh` 直接沿用。
2. concurrency 依 sha 分組（`nightly-<sha>`），連續合併不互相取代。
3. 失敗時與排程相同，開或留言 `nightly-failure` issue，去重規則不變。
4. 排程只補空缺：先照舊在有 open `nightly-failure` issue 時略過；否則以 `full-run.sh --exclude-run <自己>` 查 main HEAD，已有綠燈（`skip-green`）或正在跑（`skip-running`）時略過並記錄原因，其餘才跑（例如 push run 被取消）。

## 影響與限制

main push 的完整檢查在合併後才跑，紅燈不會擋住已合併的 commit，只會開 issue，並讓交接與 release 拒絕該 sha。每個 main sha 多用約 4 個 job、約 30 分鐘的 runner 時間。冗餘測試的稽核另案處理。
