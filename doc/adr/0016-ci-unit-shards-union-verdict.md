# 0016 CI 的 unit tier 分片執行，由聯集 verdict 判定整層

- 狀態：已採納（2026-11-10）
- 討論：#824（五分鐘計畫，維護者選 D2=A、D3=A：免費標準 runner 加分片）、#831（設計與驗收）
- 依據 ADR-0007（永不靜默失敗）；配合 ADR-0008（`just test` 是唯一入口）與 ADR-0014（全部 tier 由 CI 執行）。

## 背景

#689 之後 `test-unit` 在 4 vCPU 標準 runner 上仍要 8-14 分（8 jobs 時已 CPU 受限），是一般 PR 的關鍵路徑。維護者要求 CI 在 5 分鐘內完成，且不降低標準：不刪測試、不刪 tier、不刪架構。larger runner、self-hosted runner 與 merge queue 已在 #824 排除。

## 決策

1. unit tier 在 CI 拆成 N 個分片 leg（每個架構各 N 條），每條 leg 跑 `just test unit --shard I/N`；入口仍是 `just test`（ADR-0008）。
2. 分配只由「`test/unit/` 的完整檔案清單 + 權重檔」決定：每片的牆鐘時間估為 `max(負載 / bats jobs 數, 片內最長的單一案例)`，依 `max(權重, jobs × 最長案例)` 由重到輕，每檔交給加入後估計值最小的分片（#868 修訂；原本只看負載，會把其他重檔疊到單一長案例所在的分片）。權重檔另記每檔最長的單一案例（`longest/` 列）；`BATS_NO_PARALLELIZE_WITHIN_FILE` 的檔整檔序列執行，最長案例即其權重。權重來自 main push 合併的 junit 報告（#827），每個架構只在 build-image 讀一次並隨映像傳給所有分片；沒有權重時以 `@test` 行數計。權重只影響平衡。
3. 單一分片不代表整層：分片只檢查自己分到的必要 spec 與自己的精確計畫。整層規則由獨立 job `test-unit-verdict` 套用在所有分片的聯集上：每個架構恰好 N 份紀錄、各標 `i/N`、權重相同、檔案兩兩不重疊且聯集等於 verdict 自己 checkout 的檔案清單、每個必要 spec 都在且有案例、每片計畫等於其案例數且 TAP 全部 `ok`、無 `not ok`、無非預期的 `# skip`。例外僅限 unit 的三個具名 CPU 負載重現案例，且 `WORKTOOL_STRESS` 不為 `1`、skip 原因完全相符時才允許；設為 `1` 時必須執行。整層與分片聯集共用 `lib/test_shard.sh` 的豁免清單；案例與原因詳見 `doc/acceptance.md` 2.1（#945、#575）。
4. 任何缺口一律失敗（ADR-0007）：缺一份分片紀錄、多一份、標號不符、權重不一致、重疊、漏跑、計畫不符都讓 verdict 失敗。
5. 分片 leg 與 verdict 都是 leg：`ci-passed` 在 code 路徑、`prior-run`（`lib/ci_prior_run.sh`）在 meta 路徑都要求它們 `success`。verdict 不放在 `ci-passed` 裡，否則 meta 路徑可以繞過它。
6. 分片數 N 在 ci.yml 宣告一次（`shard`／`shards` 維度與 verdict 的 `UNIT_SHARDS`），`lib/ci_prior_run.sh` 的分片數與它一致；`test/unit/ci_yml_spec.bats` 斷言三者相同。N 依實測調整，以較慢的架構為準。

## 影響與限制

- 一次 run 多 2(N-1) 條 unit leg 與 1 個 verdict job，佔用 Free 方案 20 個並行 job 的額度；#824 的 S4 以合併小 job 補回。
- 本機 `just test unit` 照舊整層執行；`--shard` 主要給 CI 用。
- 守住本決策的 spec：`test/unit/test_shard_spec.bats`（分配與 verdict 的每一種缺口）、`test/unit/ci_gate_spec.bats`（分片紀錄可被 verdict 接受）、`test/unit/test_sh_spec.bats`（`--shard` 的參數規則）、`test/unit/ci_yml_spec.bats`、`test/unit/ci_prior_run_spec.bats`。

## 被取代的方案

- **verdict 放在 `ci-passed` 的一個 step。** meta 路徑的 `prior-run` 只看 leg，不採信 `ci-passed`，後續改說明的 meta run 會以綠的 `ci-passed` 取代紅的，形成假綠。
- **每個分片各自讀權重 cache。** main 在 run 進行中寫入新權重時，同架構的分片可能用不同權重而重疊或漏跑；verdict 雖會擋下，但會是偶發假紅。
- **PR 只跑受影響的測試。** 合併前少驗，違反不降低標準（#824 X1）。
