# 0018 tier 隔離守門放在 nightly 的完整序列執行

- 狀態：已採納（2026-11-10）
- 討論：#824（維護者最終決定第 3 項）、#835
- 依據 ADR-0007（永不靜默失敗）與 ADR-0009（冪等）。

## 背景

tier 與 spec 一向以固定順序執行；一個 tier 依賴前一個 tier 留下的狀態、或在 host 留下容器與檔案，固定順序與每次都是全新的 CI runner 都看不出來。#824 決定加一道守門：隨機順序執行、每個 tier 後檢查殘留，依成本決定放在 PR 或 nightly，PR CI 維持 5 分鐘內。

## 決策

1. `just test isolation`（`script/test/isolation.sh`）以 seed 隨機排列裸 `just test` 的階段（讀 `script/test/test.sh` 的 `HOST_STEPS`），並隨機排列 unit、matrix、system、acceptance 的 spec 檔；印出 seed，`--seed N` 以同一個 LCG 重現完全相同的順序。
2. 每個階段前後各取一次 host 快照：docker 容器與 volume、checkout 內的檔案（`git status --ignored`，排除 `.agents/state/`）、`$HOME` 與呼叫者在 `${TMPDIR:-/tmp}` 下的直接項目。多出任何一項即失敗，列出殘留與階段；階段本身失敗即停。
3. 放在 nightly 自己的 `isolation` job（與 `full-serial` 並行、同樣兩個架構，report 兩者都成功才算綠；#836），不放 PR：快照本身很便宜（本機一次約 0.17 秒），但隨機順序要把七個階段在同一台機器上序列跑完，耗時等於一次完整的裸 `just test`（數十分鐘），放在 PR 會違反 5 分鐘目標；PR 的每個 gate leg 跑在全新 runner 上，殘留不會跨 leg 傳遞，所以 PR 上的殘留檢查價值低，不另加。

## 影響與限制

殘留檢查假設執行期間 host 上沒有其他程式建立容器或檔案；CI runner 符合，開發機上同時有其他工作時可能誤報。帶 spec 路徑的階段是窄化執行，不做必要 spec 與 TAP 計畫檢查，這些由正常 gate 負責。順序類的失敗在 nightly 才會出現，最晚隔天由 nightly 失敗 issue（#836）回報。
