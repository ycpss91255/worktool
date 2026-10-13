# #568：interrupt fixture 的 HUP fork 時間窗

只修改測試 fixture，不修改產品的訊號處理或 KILL 寬限時間。

## 重現方式

由既有 `just test` 介面在 Docker 內執行，host 不執行 Bats 或負載行程：

```sh
just test unit test/unit/verify_run_signal_spec.bats --filter 'HUP under CPU load'
just test unit test/unit/verify_realbox_spec.bats --filter 'HUP under CPU load'
```

重現程式為 `test/helper/interrupt_load.bash` 與上述兩個 spec 的負載案例。
每輪在一顆可用 CPU 上啟動四個 `yes` 行程，只將 fixture 子行程綁到該 CPU；
訊號發送端保留原來的 CPU affinity。fixture 在綁定前配置 50 MB shell 變數，
放大 fork 成本，並將 xtrace 寫入測試暫存目錄。
重現案例使用共享訊號驅動器的暫存副本，以 1 ms 輪詢 `ready`，再延遲 0–9 ms
送出 HUP，以探查 fork 時間窗；共享驅動器與產品程式均不修改。
每個案例執行 60 次；realbox 交替測 assemble／bench，各 30 次。
案例會列印失敗的 status、output、events 與總次數，結束後清除 CPU 負載。

時間窗仍受排程影響，修正前也可能有整輪零失敗。下表記錄實際觀察值，
不是每次執行必須得到的失敗次數。

## RED 證據

| 切片 | RED commit | 失敗次數 | 失敗症狀 |
| --- | --- | --- | --- |
| verify_run | `c7c258a` | 5/60 | `exit-signal=none`、`rc=129`；events 只有 `cleanup` |
| realbox assemble／bench | `dab476e` | 9/60 | `exit-signal=none`、`rc=129`、`cleanup-rc=0`；events 只有 `cleanup` |

兩個 RED 案例均以零失敗為斷言，因此負載重現失敗時 spec 返回非零。

## GREEN 證據

| 切片 | 修正後失敗次數 | spec 結果 |
| --- | --- | --- |
| verify_run | 0/60 | 8/8 通過 |
| realbox assemble／bench | 0/60 | 184/184 通過 |
| realbox matrix | 不另計 HUP 負載；確認搜尋到的 TERM fixture | 11/11 通過 |

完整的受影響 spec 與 lint 都只經由 Docker 內的既有介面執行：

```sh
just test unit test/unit/verify_run_signal_spec.bats
just test unit test/unit/verify_realbox_spec.bats
just test unit test/unit/verify_realbox_matrix_spec.bats
just test lint
```

三個 spec 的尾端均為 `[ci] unit bats OK`。
lint 尾端為 `[ci] ShellCheck OK`、`[ci] Script layout OK`。
SC2016 以雙引號及跳脫 `$` 修正字面替換，不新增 ShellCheck disable。
修正引號後只重驗負載案例，沒有重跑已完成的其他案例。
未執行任何完整 tier、長 gate 或 CI 等待；未推送、建立 PR 或合併。

## 搜尋範圍

以 `rg 'touch.*ready' test` 與相鄰的 trap／sleep 檢查找到三處：

- `verify_run_signal_spec.bats` 的 `setup`：`sleep 3` 改成背景 sleep 與 wait。
- `verify_realbox_spec.bats` 的 `_prepare_group_interrupt`：同樣改為背景 sleep 與 wait。
- `verify_realbox_matrix_spec.bats` 的 outer interruption fixture：迴圈中的
  `sleep 0.1` 改成背景 sleep 與 wait。

三處 trap 都先結束背景 sleep，再執行原來的完成／退出行為。
`cleanup-ready` 後的短暫 sleep 沒有上述 trap 模式；
`realbox_matrix_just.sh` 的事件 fixture 沒有 `touch ready`，且原有 sleep 僅 0.1 秒，
不屬於這次的前景長 sleep 時間窗。
