# #663：PR #668 第 2 輪證據補件

本文件補正 PR 說明的過期版本資訊；原 PR 說明依指示不修改。
本輪沒有變更產品、spec 或驗收行為，僅保存既有證據與本輪切片驗證。

## RED exemption

Reason: 本提交只補正審查證據與版本清單，沒有新增或修改產品行為、測試或規格。

## 版本範圍

本輪開始時本地 HEAD、遠端分支與 PR head 均為
`2e91cbc2957304a2d4328830d0885a019019de93`，無須合併。
base `origin/m3/5-acceptance` 為 `dded095dbc88bad99771c5656bb1007563fb7588`。
該 base 到 `2e91cbc` 共 33 個提交，完整清單見下方。
PR 原說明的 `d3a18ff`、31 個提交與「遠端 PR head 待 workflow 發布」皆為過期資訊。
本證據文件提交會再增加一個 docs-only commit；workflow 發布時須另外列出其 SHA，
並以發布後的 head 執行 gate，不能將 `2e91cbc` 的結果稱為新 head 的結果。

## RED

以下逐字保留既存 `.agents/state/red-evidence.md` 的兩段實際失敗紀錄；
原始 Docker 輸出分別在 `review1-window-red.log` 與 `review1-slow-red.log`。
本輪沒有重造歷史 RED，也沒有為文件變更故意破壞產品。

```text
just test unit test/unit/verify_realbox_spec.bats --filter 'full 5.2 retains apply window evidence'
not ok 1 #663: full 5.2 retains apply window evidence after cleanup inventory failure
```

`2e91cbc` 的案例原先在檢查 `${directory}/before` 時失敗，修正後保留所有權證據。

```text
just test unit test/unit/verify_realbox_spec.bats --filter 'slow sweep retry'
not ok 1 #663: a slow sweep retry near its deadline stays inconclusive
```

`8da77f8` 的這份 RED 是前輪暫時還原 retry 條件後的新執行紀錄，
不是該提交當時的紀錄，無法據此證明原提交當時的 TDD 順序。

## GREEN

前輪原始日誌 `review1-window-green.log` 與 `review1-slow-green.log`
分別記錄這兩支案例 `ok 1`；完整流程／清理回歸切片為 4/4。
PR 已有[補件留言](https://github.com/ycpss91255/worktool/pull/668#issuecomment-6500721617)，
不能再宣稱這兩支案例完全沒有 RED/GREEN 證據。

本輪在未修改產品或 spec 的情況下重跑切片，Docker 輸出如下：

```text
just test unit test/unit/verify_realbox_spec.bats --filter 'full 5.2 retains apply window evidence|slow sweep retry'
1..2
ok 1 #663: full 5.2 retains apply window evidence after cleanup inventory failure
ok 2 #663: a slow sweep retry near its deadline stays inconclusive
[ci] unit bats OK
```

原始輸出保留於 `.agents/state/review2-green.log`。

## Gate 範圍與交接

`2e91cbc` 上的既有 workflow 紀錄：

- `m3-r20-52auto-f-pr-loop-663-Fix-1-8`：`just test lint`，rc=0。
- `m3-r20-52auto-f-pr-loop-663-Fix-1-9`：
  `just test changed --base origin/m3/5-acceptance`，rc=0；
  TAP `1..637`，637 個 `ok`、無 `not ok`，結尾為 `[ci] unit bats OK`。

上述原始日誌與 rc 保留於 `.agents/state/job/<job>/`，也已發布於上述 PR 留言。
先前 `--base f52bd3c` 被終止的執行不算通過。
本輪依「只跑切片與 lint、長 gate 由 workflow 負責」的指示，
不執行 `changed`，不將舊結果冒稱為本輪執行；workflow 須在發布後前景執行完成
`just test changed --base origin/m3/5-acceptance`，再附上新 head 與結果供審查。

## 既有 33 個提交

- `8cda7cf` Automate Ghostty reload and owned window evidence without a tty
- `43d11ed` Verify standalone apply and preserve inconclusive timeout recovery
- `7244b00` Confirm owned windows close and escalate ignored hangups safely
- `49feae6` Document automatic Ghostty acceptance and update window fixtures
- `71e02e5` Print the subjective smoothness reminder after all cleanup
- `6ef4a9f` Clarify automatic window verification help and IPC guarantees
- `406b028` Resolve ShellCheck findings in window ownership and document assertions
- `11e2d2b` Preserve process inventory failure codes in automatic window fixtures
- `16f9790` Stop reporting removed fixture windows during restore retries
- `5ccea46` Keep no-backup restores quiet when no window check runs
- `08da9d5` Handle empty stderr when checking automated restore prompts
- `8c8ea36` Target backup removal failure without breaking owned window cleanup
- `5b44e13` Verify direct fish entry through automatic window evidence
- `847feac` Provide automatic window tools for owned HOME acceptance
- `1242ac7` Provide automatic window tools for isolated desktop export acceptance
- `13817cb` Fix window ownership across container exec topology
- `02ea056` Correct acceptance source credit to PR 668
- `b601733` Preserve host parent topology in restored-window fixtures
- `0d8ea5f` Fix Ghostty window ownership through supported working directories
- `02bcda5` Fix restore window cleanup after inventory failure
- `de9b4fb` Preflight window tools before applying or restoring config
- `e38a2bf` Restore realbox coverage for preserved user content
- `9b39950` Restore realbox detection of destructive distrobox apply
- `03ef592` Bound automatic window discovery with one process snapshot per poll
- `a27434a` Sweep queued owned windows after discovery times out
- `f52bd3c` Name the window input test after its ignored argument
- `08a78a0` Preserve confirmation failure over inconclusive restore
- `406f5a2` Keep window ownership evidence when cleanup inventory fails
- `2a5d85d` Require an external kill binary before mutating realbox state
- `94fd221` Describe automatic window evidence in the acceptance test name
- `d3a18ff` Retain ownership evidence when the final snapshot times out
- `8da77f8` Stop sweep retries one second before the cleanup deadline
- `2e91cbc` Keep retained window evidence through full realbox restore
