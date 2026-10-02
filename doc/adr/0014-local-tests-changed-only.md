# 0014 本機只測改動，全部 tier 交由 CI

- 狀態：已採納（2026-10-01）
- 討論：#300（決策與驗收）；取代 #274 的「本機 lint + unit 整層 + 改動觸及的層」決議
- 修訂：2026-10-02，依 #376 的範圍與驗收修訂決策 6，取消未知影響時的本機完整 unit fallback。

## 背景

#274 決定 agent 在本機執行 lint、完整 unit tier，以及改動觸及的其他 tier。隨著測試層與實機案例增加，完整 tier 會重複 CI 已負責的工作，也讓每個 TDD 切片等待與該切片無關的案例。

#298 提供 `just test <tier> <spec...> [--filter REGEX]`，#299 提供 `just test changed`，因此本機已能精準執行當下 spec，並在推送前依 diff 補跑所有受影響的 spec。

## 決策

1. TDD 的 RED/GREEN 迴圈只執行當下切片的 spec：`just test <tier> <spec...> [--filter REGEX]`。本機不得執行完整 tier。
2. 每次推送前，本機阻塞執行 `just test lint` 與 `just test changed`。
3. GitHub CI 執行全部 tier，作為 branch protection 所需 `ci-passed` 的完整驗證。
4. 所有測試仍只經 `just test ...` 在 Docker 內執行；本決策只改變本機選取範圍，不建立另一套測試入口。
5. 本決策取代 #274 要求本機執行完整 unit tier 的部分。
6. `just test changed` 的自動選取只執行 lint、改到或映射到的 unit spec 與 matrix spec；依 #376，無法判定影響、缺少映射 spec、測試基礎設施變更或無法讀取 diff 時，列出檔名（若可取得）與原因，提示交由 CI 驗證，不在本機跑整層；同次改動已選出的 spec 仍執行。integration、system、system-real、acceptance 與 Ghostty／system-real runner 映像一律提示並交由 CI 驗證，開發者仍可明確執行個別重 tier 指令。

## 影響

- `.claude/workflows/pr-loop.js` 的預設 gate 是 `just test lint` 與 `just test changed`；Implement 與 Fix 的 codex、Claude 路徑共用同一組本機測試規則。
- `.claude/workflows/milestone-fanout.js` 將每個 item 的 `gates` 原樣轉傳；未指定時由 `pr-loop` 使用上述預設。
- `test/unit/workflow_spec.bats` 從 workflow 公開輸出驗證兩種 implementer 的 Implement 與 Fix 提示，不再要求本機跑完整 tier。
- 完整測試覆蓋的證據由 GitHub CI 留存；本機證據包含切片 spec 的 RED/GREEN，以及推送前 lint 與 changed 的結果。

## 被取代的方案

- **本機固定跑完整 unit tier。** 這是 #274 的決議；完整驗證已由 CI 負責，本機重跑會拉長每個切片的回饋時間。
- **本機跑全部 tier。** 與 CI 重複，且 system-real 等 tier 成本高，不適合作為每個切片或每次推送的本機 gate。
- **本機只跑當下 spec，不跑 changed。** 當改動影響共用 library 或多個 spec 時可能漏掉相鄰回歸；`just test changed` 負責推送前補齊這一層。
