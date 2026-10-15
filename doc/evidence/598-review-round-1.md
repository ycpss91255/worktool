# #598：PR #599 第 1 輪驗收證據

本輪補齊驗收證據，不改產品行為或既有 PR 說明。以下是 2026-10-15
在 `fix/598-54-outer-interrupt` worktree 實際重播的結果，並非原始開發當時
未保存的執行紀錄。所有測試均經 `just test unit <spec> [--filter <pattern>]`
在 Docker 執行；沒有執行完整 tier、`just test changed` 或長 gate。

## 重播方法

不切換或改寫提交歷史，也不建立其他 checkout。依序以 `git show <commit>:<path>`
將歷史版本的 `script/verify/realbox.sh`、`lib/realbox_interrupt.sh` 與
`test/unit/verify_realbox_matrix_spec.bats` 放回目前 worktree。
每個案例先保留新增的測試、使用尚未修正的產品版本取得 RED，再套入修正取得 GREEN。
結束時三個檔案均還原為 `7d9e3a6`；本輪提交只增加本證據文件。
本輪執行主機為 x86_64；這份證據不宣稱已在本機重播 arm64 的排程條件。

## 第一個行為：只有擁有者能執行 EXIT 清理

測試：`5.4: outer interruption during a box query keeps cleanup in the owning shell`。
篩選參數：`--filter 'during a box query'`。
注入方式是在 box-list pipeline producer 安裝繼承的 EXIT／TERM handler，
待 driver 對整個 process group 發出 TERM，強制非擁有者進入 EXIT trap。

RED 使用完整 `19ff972` 的測試與產品版本，1 次執行、1 次失敗，runner exit 1：

```text
1..1
not ok 1 5.4: outer interruption during a box query keeps cleanup in the owning shell
#   `assert_line 'rc=143'' failed
# .../lib/realbox_interrupt.sh: line 183: wait: pid 243 is not a child of this shell
# [INFO] interrupt cleanup: stopped child rc=127 (expected after termination)
# [INFO] interrupt cleanup: stopped child rc=143 (expected after termination)
# .../lib/realbox_interrupt.sh: line 50: .../wt-m3-54.PoOIvPny/groups: No such file or directory
# exit-signal=none
# rc=1
# exit-shell=250 subshell=1 child=243
# exit-shell=166 subshell=0 child=243
```

這份輸出直接顯示 subshell 先嘗試回收非自己擁有的 child（得到 127），隨後擁有者再清理，
讀取 `groups` 時暫存目錄已被另一個 EXIT 清理移除，最終 `rc=1`。
修正以 `BASHPID` 與登記 trap 的 owner 比對，讓非擁有者在改 trap、wait 或刪除目錄前返回。

中間版本 `f059cb4` 單獨重跑 1 次仍 RED：上述兩種檔案／wait 錯誤消失，
但最後為 `rc=0`。沒有將它計為 GREEN；`7d9e3a6` 的完整修正版才通過
同一個未更動的注入案例，1 次執行、0 次失敗（見下方共同 GREEN 輸出）。

## 第二個行為：重用已回收的子行程狀態

測試：`5.4: outer interruption after child exit reuses its recorded status`。
篩選參數：`--filter 'after child exit'`。
將 child 設為直接 `exit 143`，在 `_54_assert` 的 capture 驗證階段才通知
driver 發 TERM；攔截 `wait` 並記錄每次結果。除了最終 `rc=143`，
spec 還要求 wait 紀錄恰好一行 `143`，避免 EXIT 清理第二次回收同一個 child。

RED 使用 `1880148` 的 spec、`f059cb4` 的產品（即 `1880148^`），
1 次執行、1 次失敗，runner exit 1：

```text
not ok 1 5.4: outer interruption after child exit reuses its recorded status
#   `assert_output '143'' failed
# expected (1 lines):
#   143
# actual (2 lines):
#   143
#   143
```

套入 `1880148` 的產品修正後，同一條件 1 次執行、0 次失敗，runner exit 0：

```text
1..1
ok 1 5.4: outer interruption after child exit reuses its recorded status
[ci] unit bats OK
```

## 第三個行為：記錄 child 狀態後才傳遞 signal

測試：`5.4: outer interruption during status collection records the child before cleanup`。
篩選參數：`--filter 'during status collection'`。
child 直接 `exit 143`，在攔截的 `wait` 內送出 ready 並延遲 0.5 秒，
讓 TERM 確定落在狀態交接中。spec 要求最終 `rc=143`、cleanup 記錄 child rc 143，
且 wait 紀錄只有一行 `143`。

RED 使用 `386ff7f` 的 spec、`1880148` 的產品（即 `386ff7f^`），
1 次執行、1 次失敗，runner exit 1。外層 rc 雖為 143，cleanup 卻遺失 child 的
143 紀錄；因此這個 RED 證明的是狀態交接問題，不冒充第一個案例的 `rc!=143` 重現：

```text
not ok 1 5.4: outer interruption during status collection records the child before cleanup
#   `assert_line '[INFO] interrupt cleanup: stopped child rc=143 (expected after termination)'' failed
# output (4 lines):
#   [FAIL] interrupt assemble INT: observable event missed
#   Terminated                 sleep 0.5
#   exit-signal=none
#   rc=143
```

套入 `386ff7f` 的產品修正後，同一條件 1 次執行、0 次失敗，runner exit 0：

```text
1..1
ok 1 5.4: outer interruption during status collection records the child before cleanup
[ci] unit bats OK
```

三個 RED 都取得後，還原 `7d9e3a6`，用同一份 spec 的三個原始案例重跑：

```bash
TEST_IMAGE_PREBUILT=1 just test unit test/unit/verify_realbox_matrix_spec.bats --filter 'during a box query|after child exit|during status collection'
```

共同 GREEN（3 個案例各 1 次、0 次失敗，runner exit 0）：

```text
1..3
ok 1 5.4: outer interruption during a box query keeps cleanup in the owning shell
ok 2 5.4: outer interruption after child exit reuses its recorded status
ok 3 5.4: outer interruption during status collection records the child before cleanup
[ci] unit bats OK
```

## 負載條件與計數方式

完整 matrix spec 使用以下指令重跑，逐次保存退出碼與 TAP 結果：

```bash
TEST_IMAGE_PREBUILT=1 WORKTOOL_STRESS=1 just test unit test/unit/verify_realbox_matrix_spec.bats
```

`TEST_IMAGE_PREBUILT=1` 只重用本輪首次 `just test` 建置的 Docker image，
測試仍在 Docker 執行。`WORKTOOL_STRESS=1` 啟用既有
`test/helper/interrupt_load.bash`：四個 `yes` worker 與每個 matrix test
綁定同一顆容器允許的 CPU，teardown 會終止與回收 worker。
每次重跑都是完整的單一 spec，沒有將單一案例次數冒充整份 spec 次數。
修正前兩輪依序執行；修正後兩輪與 `verify_realbox_spec.bats` 有重疊執行，
額外形成容器間的 CPU 競爭。這些次數是本機驗收樣本，沒有推估 CI 的自然失敗率。

修正前使用 `19ff972`：產品與 `f9f2fd9` 相同，加上第一個確定性注入案例，
每輪共 18 個 case。兩輪 runner 均 exit 1：

| 回合 | case 數 | 通過 | 失敗 | 失敗案例 |
| --- | ---: | ---: | ---: | --- |
| before-load-1 | 18 | 17 | 1 | box-query 注入案例，`rc=1` |
| before-load-2 | 18 | 17 | 1 | box-query 注入案例，`rc=1` |

合計 2 次完整 spec、36 個 case、2 次確定性失敗。兩輪都同時出現
`not a child of this shell`、`groups: No such file or directory` 與 `rc=1`；
原有的外層中斷案例則兩輪皆通過。這是注入條件下的重現率，沒有把它解讀成
自然排程下偶發問題的發生率。

修正後使用完整 `7d9e3a6` 的產品與 spec，兩輪 runner 均 exit 0：

| 回合 | case 數 | 通過 | 失敗 | skip |
| --- | ---: | ---: | ---: | ---: |
| after-load-1 | 20 | 20 | 0 | 0 |
| after-load-2 | 20 | 20 | 0 | 0 |

合計 2 次完整 spec、40 個 case、0 次失敗。
相較修正前多出的兩個 case 是上文的狀態重用與狀態交接回歸測試；
共同的 18 個 case 則從修正前 34/36 通過，變成修正後 36/36 通過。
box-query 注入案例在負載下從 2/2 失敗變成 0/2 失敗。
三個新回歸案例在最終版本各執行 3 次（無負載 1 次、負載 2 次），各 0/3 失敗。

## #596 與既有 signal 契約

一般模式完整 realbox spec 使用以下指令執行，runner exit 0：

```bash
env -u WORKTOOL_STRESS TEST_IMAGE_PREBUILT=1 just test unit test/unit/verify_realbox_spec.bats
```

TAP 計畫 195 個 case，其中 193 通過、2 個既有壓力案例依原規則 skip、0 失敗。
這兩個壓力案例另有實際執行結果：HUP 60 次、0 失敗；timeout descendant
單獨重跑 30 次、0 失敗，詳見下節。一般模式沒有冒充已執行被 skip 的壓力案例。

```text
1..195
ok 12 5.1: group HUP under CPU load finishes before cleanup during assemble and bench # skip set WORKTOOL_STRESS=1 to run CPU repro
ok 168 timeout cleanup: realbox kills a TERM-ignoring just descendant
ok 169 timeout cleanup: TERM-ignoring just descendant under CPU load # skip set WORKTOOL_STRESS=1 to run CPU repro
ok 195 #562: successful assemble with an unknown confirmation reports uncertainty
[ci] unit bats OK
```

第一輪修正後 matrix 負載測試也涵蓋 #596 的期限案例，全部通過：

```text
ok 11 5.4: killed supervisor leaves no child holding the test pipe
ok 16 5.4: a missing observable event fails within the unit deadline
ok 17 5.4: a failed observer cannot leave the cell waiting forever for its child
ok 18 5.4: outer cleanup bounds the wait for a TERM-ignoring child
ok 19 5.4: matrix fixture residents expire without supervisor signals
ok 20 5.4: removing matrix evidence remains part of successful cleanup
[ci] unit bats OK
```

`TEST_IMAGE_PREBUILT=1 WORKTOOL_STRESS=1 just test unit test/unit/verify_run_signal_spec.bats`
為 9/9 通過、0 skip、runner exit 0。該 spec 與 `lib/verify_run.sh` 在
`f9f2fd9..7d9e3a6` 間沒有變動；它在修正前 matrix 負載回合之間執行。
其中的自然 HUP 壓力迴圈也執行 60 次、0 次失敗：

```text
# verify_run HUP load failures=0/60
ok 4 verify_run: HUP under CPU load always finishes before cleanup
ok 5 verify_run: a signal-ignoring child is killed within the grace period
ok 7 verify_run: deadline KILL is 124 while a command's own 137 is preserved
ok 9 verify_stop_group: a group still observable after KILL fails within a deadline
[ci] unit bats OK
```

## 額外 realbox 壓力回合的失敗紀錄

除了 #598 要求的 matrix 負載重跑，本輪也曾對整份 `verify_realbox_spec.bats`
設定 `WORKTOOL_STRESS=1`，與兩輪 matrix 有重疊執行。
結果是 194 個通過、1 個失敗、0 skip，runner exit 1，沒有將這輪計為 GREEN。
唯一失敗為原有的 `timeout cleanup: TERM-ignoring just descendant under CPU load`：
30 次都沒有在其 0.2 秒 timeout 前建立 child pid 檔，ready=0/30。
同一輪的 realbox HUP 壓力測試則為 60 次、0 次失敗。

```text
# realbox HUP load failures=0/60
ok 12 5.1: group HUP under CPU load finishes before cleanup during assemble and bench
# timeout descendant attempts=30 failures=30
# timeout descendant load failures=30/30 ready=0/30
not ok 169 timeout cleanup: TERM-ignoring just descendant under CPU load
```

這份輸出表示 child 未就緒，沒有觀察到該案例原本要驗證的就緒 child 回收行為。
先前案例仍保留原始斷言與 timeout，沒有調整期限、跳過失敗或修改產品來取得 GREEN。

兩輪 matrix 完成後，對同一版本單獨重跑失敗的壓力案例（一般模式 realbox spec
仍有重疊執行，但沒有其他 `WORKTOOL_STRESS` worker）：

```bash
TEST_IMAGE_PREBUILT=1 WORKTOOL_STRESS=1 just test unit test/unit/verify_realbox_spec.bats --filter 'timeout cleanup: TERM-ignoring just descendant under CPU load'
```

結果為 30/30 child 就緒、0/30 失敗，runner exit 0：

```text
1..1
# timeout descendant attempts=10 failures=0
# timeout descendant attempts=20 failures=0
# timeout descendant attempts=30 failures=0
# timeout descendant load failures=0/30 ready=30/30
ok 1 timeout cleanup: TERM-ignoring just descendant under CPU load
[ci] unit bats OK
```

因此本輪保留並行壓力失敗與單獨重跑成功兩份結果，不將並行的失敗輪改寫為成功。

## Lint

`TEST_IMAGE_PREBUILT=1 just test lint` 在 Docker 執行，runner exit 0：

```text
[ci]   found 196 script(s)
[ci] ShellCheck OK
[ci] Checking script layout and process artifacts
[ci] Script layout OK
```

## 原始輸出

完整原始輸出保留在本 worktree 被忽略的 `.agents/state/598-review1/`，
本文件收錄可隨提交審查的關鍵輸出與計數。`red-query.log`、`red-reuse.log`、
`red-collection.log` 分別對應三個 RED；`intermediate-query.log` 是仍失敗的
`f059cb4`；`green-reuse.log`、`green-collection.log` 與 `green-final-regressions.log`
保留逐切片及最終 GREEN。`before-load-1.log`、`before-load-2.log` 保留修正前負載回合；
`after-load-1.log`、`after-load-2.log` 保留修正後負載回合。
`green-signal.log`、`green-realbox-normal.log` 與 `lint.log` 保留相應的驗證結果；
`realbox-extra-stress.log` 與 `realbox-timeout-isolated.log` 保留額外壓力測試及單獨重跑結果。
