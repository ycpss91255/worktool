# #607：PR #608 第 1 輪 RED 證據補件

本輪只補上缺漏的實際測試證據，沒有新增或修改產品行為與規格。
以下是審查修正期間的實際重跑，並非原實作階段留下的紀錄；
無法據此證明原實作當時的測試順序。

遠端分支與本機同為 `23785dcf7bb0f95c36b340882d392d27c6c30633`，無須合併。
保留該版本的兩個 #607 規格與 fixture，僅暫時將
`.claude/workflows/pr-loop.js` 換成修正前 `8c4adc8` 的版本。
逐一執行規格取得以下 RED 後，還原原有 workflow，再執行同兩個規格取得 GREEN。
沒有改寫 commit 歷史；沒有修改 PR 說明、推送、建立或合併 PR。

## RED

以下兩次指令均 exit 1；TAP 內容逐字擷取自 Docker 執行輸出。

```text
just test unit test/unit/workflow_spec.bats --filter 'pr-loop blocks missing RED records before codex review'
1..1
not ok 1 pr-loop blocks missing RED records before codex review (#607)
# (from function `assert_success' in file /usr/lib/bats/bats-assert/src/assert_success.bash, line 42,
#  in test file test/unit/workflow_spec.bats, line 4001)
#   `assert_success' failed
#
# -- command failed --
# status : 1
# output : false
# --
#
```

```text
just test unit test/unit/workflow_spec.bats --filter 'pr-loop accepts reasoned no-behaviour exemptions only in PR descriptions'
1..1
not ok 1 pr-loop accepts reasoned no-behaviour exemptions only in PR descriptions (#607)
# (from function `assert_success' in file /usr/lib/bats/bats-assert/src/assert_success.bash, line 42,
#  in test file test/unit/workflow_spec.bats, line 4021)
#   `assert_success' failed
#
# -- command failed --
# status : 1
# output : false
# --
#
```

## GREEN

還原 `23785dc` 的 workflow 後，以下指令 exit 0：

```text
just test unit test/unit/workflow_spec.bats --filter 'pr-loop blocks missing RED records before codex review|pr-loop accepts reasoned no-behaviour exemptions only in PR descriptions'
1..2
ok 1 pr-loop blocks missing RED records before codex review (#607)
ok 2 pr-loop accepts reasoned no-behaviour exemptions only in PR descriptions (#607)
[ci] unit bats OK
```

完整輸出保留於本 worktree 的 `.agents/state/607-{red-block,red-exemption,green,lint}.log`。
發布 workflow 應將本文件的 `## RED` 區段逐字貼入帶有 agent 前綴的 PR 留言。
