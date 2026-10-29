# #665：PR #673 第 3 輪發布更正

第 3 輪開始時，本機與遠端 `m3/665-stale-rm-note` 同為
`3b99e59684e5374839cd14d054d120b74d209ad6`，無須 merge，未改寫歷史。
本輪只修正發布文件；沒有再改 `doc/acceptance.md`。
依本輪最後指示，不直接編輯既有 PR 描述，也不 push 或合併 PR。
因此第 1 項仍待 workflow 實際替換 PR 描述後才算完成，PR 留言不能替代描述本身。

## PR 描述完整替換稿

以下內容供 workflow 替換描述；保留先前實際 RED／GREEN 與 gate 紀錄，
更正兩次 acceptance.md 改動、完整八個已推送 commit 與發布狀態。

<!-- PR-BODY-START -->
[codex]

移除 box 說明裡過時的 M3 rm 承諾，讓文字符合目前實際提供的子命令。

Closes #665

## 變更

- 保留既有根目錄 justfile 與 doc/structure.md 修正。
- 修正 script/box/justfile.box 標頭，直接列出目前的 assemble、bench、setup、status、enter。
- doc/design.md 的 box 說明快照與目前根目錄 justfile 註解一致。
- 收緊同一個 #665 回歸測例，精確比對 adds rm、再加 rm、later rm、adds enter / rm，並檢查上述四個檔案及 just --list 輸出。
- `45a50ab` 與 `790a279` 已修改 `doc/acceptance.md`，分別補列盒內 justfile 與審查證據檔的路徑及 #665／PR #673 來源註記。這偏離 #665 原訂不改該文件的限制；原因是既有 acceptance scope spec 要求涵蓋相對 main 的每個實際變更路徑。#666 應保留並沿用現有註記，其 5.1 輸出、雙向 spec 與自身來源註記仍由 #666 處理。

## Commits

- fbf04f8b3243b87272ed0ec13c2fcb34b61cae58：既有修正。
- 6074c7bf1ab6fe4d14575270edeae74dc0cebd3a：RED，擴充及收緊同一個回歸測例。
- 64cc2a107c6e9d1a10618732f928fb04109ce80d：GREEN，修正兩處殘留說明。

- 45a50ab705e3f0dfa6893c05e00ae3502f08eeac：補列盒內 justfile 的 acceptance scope 與來源註記。
- ac40a464e19ad23078fa5bd806c686735fc8cb34：記錄第 1 輪更正與 #666 協調草稿。
- 790a279d1e19826187d84f96dacdf9c4eb2db489：補列審查證據檔的 acceptance scope 與來源註記。
- c18b384fe704076217227ca0e71cb4bf2cb25bf8：更正第 2 輪證據與六個已推送 commit 清單。
- 3b99e59684e5374839cd14d054d120b74d209ad6：補齊 #666 協調交接內容。

第 3 輪開始時，上述八個 commit 均已在遠端分支；本輪新增 commit 由 workflow 發布時補列。

## RED

```text
just test unit test/unit/justfile_spec.bats --filter '#665'
not ok 1 #665: box descriptions do not promise rm in M3
```

## RED（續作：兩處殘留承諾）

```text
just test unit test/unit/justfile_spec.bats --filter '#665'
not ok 1 #665: box descriptions do not promise rm in M3
# (from function `assert_failure' in file /usr/lib/bats/bats-assert/src/assert_failure.bash, line 66,
#  in test file test/unit/justfile_spec.bats, line 213)
#   `assert_failure 1' failed
#
# -- command succeeded, but it was expected to fail --
# output (2 lines):
#   /source/script/box/justfile.box:15:# enter (#180) and later rm.
#   /source/doc/design.md:175:mod? box  'script/box/justfile.box'     # Dev box lifecycle: just box assemble [--dry-run] [--file X]  (M3 adds enter / rm)
# --
```

## GREEN

```text
just test unit test/unit/justfile_spec.bats --filter '#665'
1..1
ok 1 #665: box descriptions do not promise rm in M3
[ci] unit bats OK
```

```text
just test unit test/unit/justfile_spec.bats
ok 45 just agent lists the Codex launcher without starting it
[ci] unit bats OK
```

整份 touched spec：45/45 通過，兩次皆透過 just 在 Docker 內執行。

## Gates（先前執行紀錄）

- just test changed --base origin/m3/5-acceptance：以前景 timeout 45 秒執行，exit 124；在 ShellCheck 階段到時中止，未完成。僅清理此執行以專用 label 啟動的容器。未跑整個 tier 或等待 CI。

```text
[ci] running --ci-lint in worktool-test:local
[ci] Running ShellCheck (*.sh + *.bats)
[ci]   found 197 script(s)
error: recipe `changed` was terminated on line 41 by signal 15
```

- just test lint：exit 0，通過。

```text
just test lint
[ci] ShellCheck OK
[ci] Checking script layout and process artifacts
[ci] Script layout OK
```


## RED exemption

Reason: 第 3 輪只更正 PR 發布紀錄、八個已推送 commit 清單與 #666 來源註記協調紀錄；沒有新增或修改產品行為、介面、測試或驗收判準，因此不新增行為測試，也不製造 RED。

<!-- PR-BODY-END -->
