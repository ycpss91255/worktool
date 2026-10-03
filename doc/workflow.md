# Workflow 範本(`.claude/workflows/`)

worktool 的 sub-issue 都用同一條迴圈交付:**實作(TDD)-> CI -> 另一方複驗 -> 修正 -> 再複驗**。
`mode: "full"` 為預設，codex 實作、Claude 審查；也可切成 Claude 實作、codex 審查。CI 綠且審查方判定可合併後，才由主迴圈合併(一次一個 PR、merge commit、保留各 agent 的 commit)。
這條迴圈寫成兩個可重用的 Claude Code Workflow 腳本,不再每次臨時寫;查資料另有 `research-verify.js`。

| 檔案 | 用途 | 何時用 |
|------|------|--------|
| `pr-loop.js` | 一個 sub-issue -> 一個 PR,推到「CI 綠 + codex 可合併」 | 每一個 sub-issue；機械式小修改用 light |
| `milestone-fanout.js` | 多個**彼此獨立**的 sub-issue 各自跑一遍 `pr-loop`(pipeline,誰先好誰先回報) | milestone 開工、一波獨立的 sub-issue |
| `research-verify.js` | 找資料:agy(gemini)查,codex 逐條開來源核對、claude 抽查與整合,結論留言在 issue | 任何需要查證的設計問題(見下方「research-verify」) |

## 主迴圈的 Codex 派工限制（#366）

`enforce_codex_via_workflow.sh` 在 Claude 與 Codex 的 PreToolUse Bash 註冊。
#364（PR #369）已合併，提供 base 分支支援；本 hook 隨設定載入立即啟用。
主 session 直接派 Codex 實作（含 `bash run.sh`、巢狀或 sourced 包裝腳本）會拒絕，
並提示改走 pr-loop／milestone-fanout。

身分依據是 [Claude Code hook 輸入契約](https://code.claude.com/docs/en/hooks#common-input-fields)：
子 agent 的工具呼叫帶 `agent_id`，主 session 沒有。依 PR #372 收尾決議，
任何非空字串 `agent_id` 都放行，包含一般子 agent 與 Workflow agent；
不靠 `agent_type`、環境標記或 transcript 格式判斷。空值或錯誤型別不構成例外。
測試 fixture 依 2026-10-02 查閱的官方文件欄位建立，並非擷取實際執行輸入。

主 session 的唯讀例外只接受字面 `codex exec --sandbox read-only`（含 `e`、`-s` 等形式）。
Codex 呼叫的未知選項與 sandbox 覆寫仍拒絕。
依 #384，指令文字（含 heredoc 與 `bash -c` 字串）提到 codex 時，才對 shell 展開、
eval／xargs、不透明 launcher、非 shell 直譯器與不可讀包裝腳本採封閉拒絕。
未提到 codex 的 awk、jq、python、背景 launcher、xargs、just 與 docker 日常指令放行。
包裝腳本只讀取不執行，仍遞迴檢查 `bash <路徑>`、`./x.sh` 與 launcher 後的腳本；
`bash -c` 檢查字串內容，不把 `-c` 當檔案路徑。靜態遞迴檢查上限為 16 層。
未被結構化檢查核對的 Codex 原始文字會觸發拒絕，單純提到 Codex 也可能被擋。
僅透過 PATH 解析的自訂執行檔、自訂 just recipe、編碼或執行時才組出的呼叫不在靜態檢查範圍；
此 hook 是合作 agent 的規則護欄，不是作業系統 sandbox，也不驗證 agent 身分真偽。

## 呼叫方式

從任何 cwd 以 `scriptPath` 呼叫(不需要把腳本裝進 session 的專案目錄):

```text
Workflow({ scriptPath: "/path/to/worktool/.claude/workflows/pr-loop.js", args: {
  repo: "ycpss91255/worktool",
  repoDir: "/path/to/worktool",
  issue: 150,
  branch: "m3/150-bench",
  name: "bench",
  parent: "#5",
  mode: "full",
  implementer: "codex",
  codex: "on",
  maxRounds: 3,
  task: "<要做什麼、驗收標準、檔案、測試;越具體越好>"
} })
```

## pr-loop 的 args

| 參數 | 必要 | 說明 |
|------|------|------|
| `repo` | 是 | `owner/name`;所有 gh 指令都帶 `--repo` |
| `issue` | 是 | 這個 PR 關閉的**唯一** sub-issue(PR 描述會有 `Closes #N`) |
| `branch` | 是 | 從 `origin/<base>` 開的分支名；本機分支已存在時接續，依工作區、前次實作結果、commit 與 PR 狀態決定是否進入實作 |
| `pr` | 否 | 接續用的既有 PR 正整數編號；實作完成且乾淨時直接進入 CI 與獨立審查；中斷時接續實作並重用 PR |
| `base` | 否 | PR 目標分支，預設 `main` |
| `name` | 是 | worktree 名稱(`../worktree/<name>`);各 PR 各自的 worktree,不互相干擾 |
| `task` | 是 | 交給實作 agent 的完整任務描述 |
| `gates` | 否 | 傳入時完整取代預設推送前 gate，呼叫者須自行包含 `just test lint`；僅省略時採用預設：full 為 `just test lint` 與 `just test changed`，light 為 lint 與改到的 spec；不得用它要求本機跑整個 tier |
| `mode` | 否 | `full`（預設）或 `light`；其他值直接 throw。light 固定由 Claude 修改與另一個 Claude 子代理審查，不呼叫 codex |
| `implementer` | 否 | `codex`(預設)或 `claude`;實作與 Fix 由這一方執行，Review 永遠由另一方執行 |
| `codex` | 否 | 只接受 `on`(預設)/ `off`(配額暫停:改在 PR 留 `[claude]` 註記,不冒充 codex);其他值直接報錯 |
| `maxRounds` | 否 | 允許的 Fix 輪數(非負整數,預設 3;`0` = 只複驗一次、不修);用完就回報 `blockingLeft` 交主迴圈處理 |
| `parent` | 否 | PR 描述的 `Part of` 參照(例如 `#5`) |
| `repoDir` | 是 | 本機 main checkout 路徑(不預設,換機器就換值);worktree 在 `$(dirname <repoDir>)/worktree/<name>`、暫存檔在 `$(dirname <repoDir>)/worktree/.scratch/<name>` |

`pr-loop` 以 `base` 指定 milestone 驗收分支（例如 `m3/5-acceptance`）時，CI 同樣適用。
`ci.yml` 的 PR base 篩選接受 `main` 與 `m*/*-acceptance`，所有既有 CI gates 與
`ci-passed` 彙總照常執行；push 觸發仍限 `main`。`verify-all` 仍依 PR 的
`milestone-gate` 標籤決定是否執行，不因 base 是驗收分支而自動啟用。

## 既有分支接續

本機 `branch` 已存在時自動接續，不需額外 mode 旗標。worktree 不存在時，以 `git worktree add <worktree> <branch>` 重建；若目錄已刪除但登錄仍在，只移除該路徑的殘留登錄再重建，不清理其他 worktree。已存在時確認它屬於此 repo 且位於指定分支，錯誤不覆寫。
Locate 先檢查指定 worktree：工作目錄不乾淨時，一律判為 `implement`，在原 worktree 接續實作。只有 codex 實作路徑額外檢查 `.scratch/<name>/implement.rc` 非 `0` 或 `.scratch/<name>/implement.md` 不存在／為空；這些完成檔由 codex detached wrapper 寫入，light、Claude 實作與 `codex: "off"` 的 Claude 路徑不以它們判斷完成狀態。brief 要求檢查 `git log origin/<base>..HEAD`、`git status --short`、`git diff`、前次報告與 `implement.md.log`，保留既有 commit、未提交修改與 `.agents/state/` 的診斷及測試證據。codex 啟動前以 `.previous` 副本保存前次報告、rc 與 log，供實作方在新輸出覆寫原檔後繼續閱讀。
指定既有 `branch` 與 `pr` 且實作已完成、工作區乾淨時，跳過實作與開 PR，直接進入 CI／審查迴圈；需要接續實作時仍重用指定 PR，不另開 PR。
CI 先確認 worktree 乾淨、分支與開啟中的 PR 相符、目標是 `base`。
本機若有未推送的修正，先跑 `gates`、核對 noreply 與 `Refs`，再推送並等待該 head 的 CI。
未傳 `pr` 且相對 `origin/<base>` 沒有新增 commit 時，以結構化查詢確認是否已有相同分支與 base 的開啟 PR；沒有 PR 就在原 worktree 進入實作，不另建分支或 worktree。保留 `.agents/state/` 的既有診斷，實作 brief 明確指出該目錄，要求先讀診斷並將測試證據留在其中。查詢失敗或回傳格式無效則停止。
有既有 commit、工作區乾淨（codex 實作另須前次 rc 不為非零且有非空實作報告）時，判為 `resume`，接續發布：先查相同分支與 base 的開啟 PR；有就重用。沒有 PR 時必須有本機未推送的 commit，先跑 gates、推送、開 PR，再進入原迴圈；沒有未推送 commit 或查詢失敗則停止。
CI 綠後再以腳本核對工作區乾淨、本機 HEAD、遠端分支與 PR head 相同，未通過就停止，不相信 CI agent 的完成敘述。
接續 light 模式先看工作區；工作區乾淨且有 commit 或 PR 時跳過實作，空分支且無 PR 或工作區不乾淨時先在原 worktree 實作。在發布或 CI 前仍由獨立 Claude 子代理審查完整 diff；只有回報 mergeable 才能繼續，blocked 或無結果就停止。仍不跑 codex 複驗。
同步遠端只用 merge，不改寫已推送歷史；失敗就回報阻擋原因，不合併 PR。

## 實作暫時性錯誤

full 模式的 implement 階段會讀取實作方的結構化完成狀態與失敗原因；codex 非零退出時，原因包含退出碼、報告與 `implement.md.log` 的錯誤輸出。遇到 `at capacity`、rate limit 或 HTTP 5xx（含 HTTP 版本格式）時，初次執行後最多再重試三次，分別在前景等待 30、60、90 秒。每次都使用同一個 worktree、保留既有工作，不再次建立分支或 worktree，並附上接續 brief 與前次輸出。成功後繼續 Locate／CI；耗盡重試、非暫時性錯誤或沒有失敗原因時，停止並在 `blockingLeft` 回報原因，不進入 CI／審查。light 模式維持原有失敗回報，不套用 codex 重試。

## light 模式

機械式、只有幾行且沒有新行為的修改使用 `mode: "light"`；實質改寫使用 `full`。
light 不受 `implementer` 的選擇影響，也不因 `codex: "off"` 留配額暫停註記。

1. 一個 Claude 子代理在獨立 worktree 直接修改並 commit，不叫 codex 實作；有行為改變時仍依 TDD 逐片 RED→GREEN。
2. 另一個 Claude 子代理只看完整 diff，審查並套用必改，追加 commit；修改或審查未成功就停止，不發布。
3. 阻塞執行 `just test lint` 與改到的 spec（`just test <tier> <spec> [--filter REGEX]`），不跑 `just test changed` 或完整 tier；通過後才推送、開 PR。
4. 等 CI 全綠，失敗時在同一 worktree 修正並追加 commit、再推送；不跑 codex 複驗，也不 merge。

仍遵守一個 issue 一個 PR、noreply author 與 committer、無署名、不改寫已推送 commit。
修改失敗的結構化結果須帶 `reason`（失敗步驟與原因），workflow 會把它附在 `blockingLeft`；未提供原因時明確標示。發布並 Locate 後，同樣執行下述 Implement 完成檢查。

回傳沿用 full 的欄位，`codexVerdict: "skipped"`、`rounds: 0`；以 `ciState` 與 `blockingLeft` 判斷是否完成。
例如上述呼叫只需把 `mode` 改為 `"light"`，並以 `gates` 指定此次修改的 lint 與 spec 指令。

## full 迴圈內容

1. **Implement**:agent 在自己的 worktree(`git worktree add -b <branch> <repoDir>/../worktree/<name> origin/main`)依 TDD 做:
   先寫測試看到 RED,再實作到 GREEN;每個 TDD 切片只在 Docker 內跑該 spec（`just test <tier> <spec...> [--filter REGEX]`）；
   push 前阻塞執行 `just test lint` 與 `just test changed`。本機不跑整個 tier；全部 tier 由 CI 執行；
   開 PR(zh-TW 描述:`Closes #N`、`Part of`、「這個 PR 只做一件事」、commit 清單、「測試證據」)。
   Locate 找到 PR 後，以腳本讀取 `git status --porcelain`、本地 HEAD、`git ls-remote` 的遠端分支 HEAD 與 PR head；工作區必須乾淨，三個 HEAD 必須相同。檢查失敗就以 `blockingLeft` 附上狀態與 HEAD 比較，不進入 CI。
2. **Locate**:agent 以 `gh pr list --head <branch>` 結構化回傳 PR 編號與 head SHA(不從自由文字猜)。
3. **CI**:agent 以 `gh pr checks --watch` 等到全綠;紅就讀 log 修正、再推(最多兩輪);仍紅就以 `ciState: red` 結束,不進 codex。
4. **Codex**:agent 把 **PR 描述 + 對應 issue + 完整 diff** 餵給 `codex exec`,逐項確認
   (一件事 / TDD 證據 / 自足 / 正確性與健壯性 / 文件一致 / 新問題),把 codex 原文以 `[codex]`
   貼到 PR,加一行 `[claude] double-check`(上下文是否完整、每項是否引用 diff 位置)與可重現指令。
   issue 本文的「## 範圍」段(擋 / 不擋 / 已知限制)由 shell 切出、逐字貼進 prompt,codex 只把範圍內的具體問題列為阻擋項;
   issue 沒有該段時 prompt 註明「issue 未定範圍」(#238;攔截型 issue 缺範圍段在建立時就會被 `enforce_scope_on_guard_issues` hook 擋下)。
   讀取 issue 失敗(`gh` 非零)不會被當成「未定範圍」:重試一次仍失敗就不跑 codex,以 `no-output` 結束本輪。
   第二輪起會把上一輪判定逐字附在 prompt 裡,要求逐項確認是否已修正。判定是結構化欄位(`mergeable` /
   `blocked` / `no-output`):codex 無輸出或格式不明**不算通過**。
5. **Fix**:codex「不可合併」時,agent 在同一 worktree 針對每個阻擋項先補失敗測試再修,獨立 commit,
   push,PR 留言 `[claude] 採納第 N 輪:`;回到 CI -> Codex;最多 `maxRounds` 輪。
   Fix 結束也以同一腳本確認工作區乾淨、本地 HEAD 已推送且與 PR head 相同，並要求 PR head 與修正前不同；codex 與 Claude 路徑皆適用。任一檢查失敗就回報 `blocked`，`blockingLeft` 附上 git status、修正前後 HEAD 與遠端比較，不進入下一輪 CI／審查。
   已推送的 commit 不得 rebase、amend、reset 或 force push 改寫；只追加新 commit，需要同步 main 時用 merge。
6. 回傳 `{ issue, pr, sha, ciState, codexVerdict, rounds, blockingLeft }`。**不 merge PR**:PR 合併順序與衝突由主迴圈處理。

## milestone-fanout

用途：讓多個彼此獨立的 sub-issue 各跑一遍 `pr-loop`。每批最多 `concurrency` 個 `pr-loop` 子 workflow 並行（預設 10）；一批結束才開始下一批。`concurrency` 限制同時進行的實作工作數；CPU 閘門（#279／#288）另外限制同時執行的測試容器數，上限仍為 2。每個結果完成後都會寫入 log，workflow 本身不 merge。

| 參數 | 必要 | 說明 |
|------|------|------|
| `repo` | 是 | `owner/name`;轉傳給每個 `pr-loop` |
| `repoDir` | 是 | 本機 checkout 的絕對路徑 |
| `items` | 是 | 非空陣列；每項必須有 `issue`、`branch`、`name`、`task`；`pr` 為可選接續 PR 編號，與既有 `branch` 一起轉傳；`gates` 若有指定就原樣轉傳，省略時由 `pr-loop` 依 mode 選擇預設 gate |
| `mode` | 否 | `full`（預設）或 `light`；轉傳給每個 `pr-loop` |
| `implementer` | 否 | `codex`(預設)或 `claude`;轉傳給每個 `pr-loop` |
| `parent` | 否 | 每個 PR 的 `Part of` 參照 |
| `codex` | 否 | `on`(預設)或 `off` |
| `maxRounds` | 否 | 每個 PR 的 Fix 輪數上限，預設 3 |
| `concurrency` | 否 | 每批實作工作數上限，正整數，預設 10；非法值 throw，不啟動子 workflow |

args 範例：

```json
{
  "repo": "ycpss91255/worktool",
  "repoDir": "/path/to/worktool",
  "parent": "#280",
  "implementer": "codex",
  "maxRounds": 3,
  "concurrency": 4,
  "items": [
    { "issue": 281, "branch": "feat/281-a", "name": "impl281", "task": "完成 issue #281。" },
    { "issue": 282, "branch": "feat/282-b", "name": "impl282", "task": "完成 issue #282。" }
  ]
}
```

## milestone 驗收 PR 交出前檢查清單

交給維護者驗收前，agent 必須逐項完成並在 PR 說明附上證據：

- [ ] 驗收 PR 已貼 `milestone-gate`，目前 head 的 CI 全部成功，包含兩種架構的 `verify-all` 與彙總 `ci-passed`；附上成功 run 的連結。CI 的 `verify-all` 實跑 `just verify all`，只涵蓋非實機項目，不含需要 `--allow-real-box` 的第 5 節。普通 PR 不要求這個 job。
- [ ] milestone 每個目標都對應至少一個從使用者實際入口出發的測試或驗收項目；在 PR 說明列出目標對照表，每列填入可查證的測試位置、驗收編號與輸出或 CI 連結。入口應是使用者會啟動的命令或操作，例如 setup 寫出的命令或正在執行的 Ghostty；只驗腳本接線或 stub 成功，不能當作目標已達成的證據。
- [ ] 第 5 節實機項目中，agent 能在 host 上安全執行、有備份與還原流程的項目，交出前先跑一次並貼出輸出與還原結果。無法安全執行的項目，列出原因與待維護者實跑的命令，不宣稱通過。

目標對照表統一使用[交出 milestone 驗收 PR](#交出-milestone-驗收-pr) 的範本；PR 說明與就緒留言使用相同格式。

這份清單是交出前的責任；就緒留言的自動檢查另由 #365 處理。milestone 驗收 PR 的合併仍須維護者在該 PR 留下核准紀錄。

### CI job 驗收追蹤(#363)

`verify-all` 在 amd64 與 arm64 的原生 runner 各自建置 `dockerfile/Dockerfile.ghostty`，再以 `dockerfile/Dockerfile.verify` 補齊 Docker CLI、GitHub CLI、jq、just 與 time，並從該架構的測試映像複用鎖定版 distrobox。CI 先執行 `just test verify-env`，對 bind mount 的 uid 1001 checkout 實跑 `git ls-files` 與必要工具；容器入口只將目前工作目錄加入 Git `safe.directory`，不信任任意 repository。驗收容器內的 Ghostty 是 integration 使用的真實工具；不得以 stub 或略過檢查替代。容器掛載 runner 的 Docker socket，checkout 在容器內外使用相同絕對路徑，讓 `just verify all` 啟動的 Docker gate 讀到同一份程式碼；`GH_TOKEN` 傳入容器供唯讀證據查詢。仍不執行第 5 節，`ci-passed` 仍只在 `milestone-gate` PR 要求兩種架構的 `verify-all` 成功。

#363 的 CI job 驗收需附 GitHub runner 的兩份實跑證據：目前 #157 head 重現 F1 的 RED，以及修正後 head 的 GREEN（兩種架構的 `verify-all` 全部成功）。證據齊全前，CI 變更 PR 使用 `Refs #363`，#363 保持開啟。普通 PR 的 `verify-all` 為 skipped、本機 spec 通過或 workflow 接線正確，都不能代替這兩份證據。

## research-verify

暫存目錄以本次經驗證的 16 位十六進位 nonce 區分；resume 重用本次 nonce。同一 issue 的並行執行各自保存與讀取研究、驗證、log 及留言中間檔，互不覆蓋。

維護者規則:找資料一律用 agy(gemini)查,由 claude 與 codex 做驗證(#220)。`args` = `{ repo, repoDir, issue, question, context?, sources?, timeoutMin? }`:

| 參數 | 必要 | 說明 |
|------|------|------|
| `repo` | 是 | `owner/name`(只允許英數、`.`、`_`、`-`);gh 一律帶 `--repo` |
| `repoDir` | 是 | 本機 main checkout 的絕對路徑(可含空白,不可含控制字元或反引號);prompt 與原始輸出放在 `$(dirname <repoDir>)/worktree/.scratch/research-<issue>-<nonce>/` |
| `issue` | 是 | 正整數;結論與研究明細以一則或多則留言貼到這個 issue |
| `question` | 是 | 研究問題 |
| `context` | 否 | 背景說明,agy 與兩個驗證者都會拿到 |
| `sources` | 否 | 本機一手資料路徑陣列(例如鎖定版原始碼),給 claude 與 codex 驗證時直接讀 |
| `timeoutMin` | 否 | agy `--print-timeout` 分鐘數(正整數,預設 15);外層再包 `timeout` 硬上限 |

args 範例：

```json
{
  "repo": "ycpss91255/worktool",
  "repoDir": "/path/to/worktool",
  "issue": 220,
  "question": "這個設計選項的一手資料與限制是什麼？",
  "context": "只採用官方文件與鎖定版原始碼。",
  "sources": ["/path/to/worktool/doc/design.md"],
  "timeoutMin": 15
}
```

1. **Research**:先由一個 agent 以 `od -An -N8 -tx1 /dev/urandom` 取得本次執行的 nonce(16 位小寫十六進位),
   沒有或格式不對就回傳 `status: 'setup-failed'` 並停在這裡,agy 不會被呼叫;有 `sources` 時先檢查每個路徑都可讀,
   有一個不可讀就回傳 `status: 'sources-invalid'` 並停在這裡,agy 同樣不會被呼叫;接著每次研究呼叫（含重試）前，agent 以字面路徑呼叫
   `.agents/script/research/agy-model.sh`，執行 `agy models` 並解析版本號最高的 Gemini flash-high。
   版本以數字比較（例如 3.10 > 3.9），只接受模型 ID `gemini-<數字版本>-flash-high`；解析規則集中在此共用腳本，
   後續使用 agy 的 workflow 也遵守同一規則。指令失敗或沒有匹配模型時立即回報 `status: 'agy-failed'`，
   不執行該次研究呼叫、不重試解析、不退回舊版或其他模型。使用者可透過薄轉發介面
   `just --justfile .agents/script/research/justfile.research model [--help]` 取得模型 ID；stdout 只輸出 ID，診斷與 help 走 stderr。
   解析成功後 agent 跑 `agy --sandbox --dangerously-skip-permissions -p <prompt> --print-timeout <m>m --model <解析結果>`，
   留言會記錄每次研究呼叫實際使用的模型名稱。
   prompt 要求只用一手來源、每條主張標來源類型、查不到標 `UNVERIFIED`;找前例優先查 Ubuntu／Canonical 與 ROS 生態系，其他大型 repo 作補充；輸出寫進 `agy.md`。
   指令本身以 exit status 表達成敗(agy exit 0 且 `agy.md` 非空才是 0)。
   無輸出或逾時重試一次,仍失敗就回傳 `status: 'agy-failed'` 並停在這裡,**不改用其他模型或自己的知識冒充**;
   agent 回報的 `attempts` 不是 1 或 2 也算失敗。
2. **Verify**:先由 codex 逐條核對；成功後 claude agent 讀取 codex 核對結果，抽查部分一手來源（至少一條，優先分歧、`UNVERIFIED` 與關鍵主張；只有一條主張時可抽查該條），附抽樣理由與成立 / 不成立 / 無法確認的依據，不重做全量核對、不自行大量網路查找。
   codex 的 agent 以 `cat agy.md | codex exec --skip-git-repo-check` 讓 codex 逐條開啟每個主張的一手來源（含 `UNVERIFIED`），記錄來源是否支持主張、實際 URL／檔案:行號、摘錄與依據；不可讀或判定不了就標「無法確認」，不憑記憶或搜尋摘要、不自行大量網路查找。`codex.md` 只存 codex 的**最終回答**:
   優先取 codex 以 `-o`(`--output-last-message`)自己寫出的檔案;沒有才取 transcript 最後一個 `codex` 區塊,
   且該區塊必須緊接內容恰為 `tokens used` 的一行(回合完成的邊界;`tokens used by ...` 之類的文字只是回答內容,不算邊界),不含 commentary、工具執行紀錄與 `tokens used` 之後重複的回答(#223)。
   沒有這個邊界(停在 commentary、工具呼叫中或錯誤)就視為沒有最終回答,`codex.md` 為空,Record 不發(fail closed)。
   codex 非零結束、無輸出或最終回答抽取失敗都以非零結束。
   **兩路都必須有結果**:claude 沒回 claims(空值、空陣列,或任一條缺 claim / verdict / basis)或 codex 無輸出(配額/認證)就回傳
   `status: 'verify-failed'` 並停在這裡,不綜合、不留言(研究原文留在 scratch,可重跑)。
3. **Synthesize**:由 claude 依 agy brief、codex 全量來源核對與自己的抽查結果整合：驗證後成立的事實、被推翻的主張、分歧、仍需實測的點、建議方案、需要維護者拍板的參數（結構化），不自行大量網路查找。
   無法由來源判定（含雙方皆無法確認）或來源無法解決的矛盾只能歸入 `disagreements`，每條必含非空的 `claim`、`codexBasis`、`claudeBasis`，列出雙方依據或缺乏證據的原因；不投票、不偏好某模型、不選邊、不放進成立或推翻，也不在建議方案中假定任一方成立。`needsExperiment` 只列可解除不確定性的實測，不能取代分歧紀錄。
   結果缺欄位、型別不對或建議方案為空就回傳 `status: 'synthesize-failed'`,不留言,**不以替代結論冒充**。
4. **Record**:留言一律以 `--body-file` 發出,每則上限集中為 60,000 bytes(低於 GitHub 的 65,536 字元限制)。
   小型研究仍合併成一則;超過上限時第一則固定是驗證後成立、被推翻、分歧（不選邊）、仍需實測、建議方案與待拍板參數,
   後續依序放 claude 來源抽查明細、引用格式的 codex 原文與 agy 原文,每則標明「第 n／N 則」。單一段落仍放不下時截斷並標記,
   不會讓整次 Record 因該段落失敗。每則都以 `[claude]` 開頭;codex 原文逐行引用,不會出現行首 `[codex]`。
   每頁帶本次 run nonce 組成的 marker;重試先讀 issue 既有留言,已存在的 marker 不再張貼,只補先前未成功的頁。
   `claude.md`、`agy.md` 或 `codex.md` 為空就不發。留言本文先拆分、過濾並驗證完整行數後才發送,
   任一步(讀檔或過濾)失敗都不發出空白或不完整的留言(fail closed)。
   每則留言發出前經過路徑過濾(#223):`sources` 改寫成其目錄名、`repoDir` 改寫成 `.`(只在路徑邊界),
   `$HOME` 與任何 `/home/<user>`、`/Users/<user>` 改成 `~`,Claude session 的 `/tmp` 暫存路徑改成 `<tmp>`;
   其餘絕對路徑一律遮成 `<path>`(預設拒絕,不留例外:`/usr`、`/etc`、`/root`、`/workspace`、`/private/tmp`、`/var/folders`、
   `/mnt/c/Users`、`file:///...` 的路徑、緊跟在非 URL 冒號後的路徑如 `location:/root`、`host:/srv`、`C:\Users\...`、
   UNC 路徑 `\\server\share\...` 等),只保留 `scheme://host` 形式的 URL、單獨的 `/` 與 HTML 結束標籤(如 `</details>`)。
   只有 gh 印出的網址是這個 issue 的留言網址(`https://github.com/<repo>/issues/<issue>#issuecomment-<n>`)才算 `recorded`,
   gh 失敗、沒輸出或輸出不是留言網址都是 `record-failed`。
   留言之後由 `repo-check` agent 再跑一次 `git -C <repoDir> status --porcelain --untracked-files=all`
   (逐檔列出未追蹤檔,不折疊成 `?? dir/`),與 Research 第一步存下的空白 `status-before.txt`
   雙向比對。Research 會先要求完整 status 為空,之後才在 checkout 外 `mkdir`/`rm`/寫檔;
   多出的行記為 `+ <行>`,理論上不應存在的消失行仍記為 `- <行>`;
   任何一行差異、`git`/`grep` 出錯(`grep` exit 2,例如基準檔不可讀)或 agent 沒回結果,都回傳 `status: 'repo-dirty'`,
   `detail` 列出這些行,且不替你清掉(留給維護者判斷)。
5. 回傳 `{ issue, status, codex, claims, comment, synthesis }`,`status` 為
   `recorded` / `setup-failed` / `sources-invalid` / `agy-failed` / `verify-failed` / `synthesize-failed` / `record-failed` / `repo-dirty`;
   只有 `recorded` 代表留言已發出且 repo 未被動過(`repo-dirty` 時留言可能已發出,`comment` 仍帶網址)。

不寫進 repo(#243):`repoDir` 是別的 session 正在用的工作目錄。每個階段的 prompt 都附同一條規定:中間檔
(筆記、草稿、log)只能寫在 `$(dirname <repoDir>)/worktree/.scratch/research-<issue>-<nonce>/`(或系統暫存),不得新增、修改、
刪除 `repoDir` 底下其他任何追蹤或未追蹤路徑,結論寫在回覆裡而不是檔案裡。

shell 安全:所有進入 shell 指令的值(scratch 路徑、`repo`)都以 POSIX 單引號包住,`repoDir` 的空白與
metacharacter 只會是資料。逐字寫檔的區塊以 `===BEGIN-<run>-<n>===` / `===END-<run>-<n>===` 包住:`<run>` 是上述 nonce,
所以 marker 每次執行都不同(#225),同一組 args 的兩次執行也不會共用;`n` 在同一次執行內只增不減,
每個區塊各用一個不同的 `n`,並跳過會出現在區塊內容或 `repoDir` 中的值,問題或結論裡的任何文字都不會提早結束區塊。
Workflow 不能用 `Math.random`(否則無法 resume),所以 nonce 由 agent 從 `/dev/urandom` 讀;
resume 時會重播這個 agent 的快取結果,續跑的執行沿用自己的 marker,resume 的決定性不受影響。

`test/unit/workflow_spec.bats` 在測試映像內以 node 實際執行這個範本(`test/unit/fixture/workflow_run.mjs`,
agent 以替身代打並真的跑每個 shell 步驟,agy / codex / gh 以 stub 代替),驗證參數拒絕、quoting 與 fail-closed 流程。
替身 fail closed:任一 shell 步驟非零結束(或有寫檔目標卻沒有完整區塊)就停下並回傳 null,如同失敗的 agent,
不會回傳預設結果;因此「shell 失敗 → 不進 Record」是實際執行證明,不是文字比對。
測試矩陣涵蓋 Research、claude 驗證、codex 驗證、Synthesize、Record 五個階段 × 非零結束、無輸出、格式錯誤三種失敗
(沒有外部工具的 claude 驗證與 Synthesize,「非零結束」即 agent 本身失敗),每一格都斷言沒有留言被記錄、
Record 之前的失敗 gh 完全沒被呼叫。

## 對應的治理規則

- 一個 issue 一個 PR、一個 PR 只做一件事(`issue` 是單一值;`Closes #N` 只有一個)。
- 每個 agent 獨立 commit,合併不 squash(範本只 push,不 merge)。
- codex 是靜態審查:測試證據一律由本機 gate + CI 提供;codex 暫停時不冒充,留 `[claude]` 註記。
- 可並行的就並行:獨立的 sub-issue 用 `milestone-fanout`;有相依的用 `pr-loop` 依序。
- 守門測試 `test/unit/workflow_spec.bats` 包含**文字層級**的規約檢查與 node 執行的流程測試:
  釘住 meta 在第一行且看起來是純字面量、phase 名稱、參數驗證、結構化 PR/CI/codex、CI gate、Fix 輪數、
  回傳契約、已知的 merge 指令、不寫死機器路徑 / session。文字檢查擋的是「不小心改壞」;
  流程測試以代理替身驗證 light 不呼叫 codex、不同代理分別修改與審查、非法 mode 拒絕及 full 路徑維持原樣；真實 sub-issue 的 gate 與 CI 證據留在該 PR。

## discuss

每次執行沿用經驗證的 16 位十六進位 nonce 建立獨立暫存目錄；resume 重用本次 nonce。同一 issue 可並行討論多題，各次輸出、rc、log、比對與留言只使用本次目錄。

問維護者之前，先讓 Claude 與 codex 各自獨立回答一題。`args` = `{ repo, repoDir, issue, question, context?, premises?, references? }`：

| 參數 | 必要 | 說明 |
|------|------|------|
| `repo` | 是 | `owner/name`；所有留言指令帶 `--repo` |
| `repoDir` | 是 | 供只讀調查的 checkout 絕對路徑；中間檔放在同層 `worktree/.scratch/discuss-<issue>-<nonce>/` |
| `issue` | 是 | 正整數；結論留言記錄到此 issue |
| `question` | 是 | 單一待決題目 |
| `context` | 否 | 背景與現況 |
| `premises` | 否 | 已定案前提；雙方都收到 |
| `references` | 否 | 相關 issue 連結、ADR 與檔案位置 |

```json
{
  "repo": "ycpss91255/worktool",
  "repoDir": "/path/to/worktool",
  "issue": 309,
  "question": "這個設計應採用哪個既有機制？",
  "context": "請先核對現有 workflow。",
  "premises": "不更動已定案的不變量。",
  "references": "doc/contract.md、相關 ADR 與 issue 連結"
}
```

以 `Workflow({ scriptPath: "<repoDir>/.claude/workflows/discuss.js", args: ... })` 呼叫。
首輪互不看對方答案；分歧時把上一輪雙方答案與分歧點交回雙方，最多三輪，一致即停。
結果分成「一致（定案）」、「分歧（交維護者，一次一題）」與「可由不變量／前例推出（自行定案）」。
比對代理不得自行選邊；自行定案必須附已定案 issue、不變量或 repo 前例的依據。
未收斂時 `ask_maintainer` 只有一題，定案時為空陣列。
維護者問題必須為非空單行、只問一件事；「A？還是 B？」的二選一句型視為一題，
也接受兩個問句之間先補一段陳述、再以「還是」等選擇連接詞引出另一選項。

codex 以 `setsid nohup` 脫離執行，寫 rc 檔；每次前景等待上限 540 秒，codex 硬上限 14,400 秒。
完成後清理掛載該 checkout 的測試 container；非零 rc 或空輸出不能當成功。
雙方作答分成 `answer`、`reasons`、`notes` 與 `risks`；判斷放在 `reasons` 並逐條附依據，
說明與執行紀錄放在 `notes`，不需引用、不算判斷、不傳給比對代理或下一輪的前次答案。
每條理由與比對依據接受完整 issue URL、本 repo 的 issue／PR 簡寫 `#<正整數>`（例如 `#212`），
repo 相對路徑的 `檔案:行號`（例如 `doc/contract.md:1`），或搜尋紀錄 `grep:<pattern> in <路徑> -> N 筆`；
`grep:` 搜尋紀錄容忍空白與括號，只要含 `->`、非負整數與 `筆` 即可，例如 `grep:dev 盒 in doc/（不含 *.svg）-> 30 筆`。
`N` 是非負整數，`0 筆` 可引用找不到用法的反面證據（例如 `grep:開發盒|dev 容器 in doc/ -> 0 筆`）。
每條判斷與比對依據都必須含至少一項依據；`notes` 不會豁免 `reasons` 內缺少依據的判斷。
作答與比對各自驗證失敗時，只向原作者重問一次，附未通過條目原文、原始提交與可接受依據格式；只修正格式，不改判斷或捏造依據。
`question` 的多行、空白或多題格式也在每輪比對時走同一個修復重問，附欄位名稱、規則與原文；修復成功才繼續。
作答修復仍不通過才回傳 `answer-failed`，不進入比對或發布；比對修復仍不通過則回傳 `compare-failed`，不發布。修復次數上限由 `FORMAT_REPAIR_LIMIT` 統一設定為 1。
留言以 `[claude]` 開頭，包含結論、每個判斷的依據、分歧與維護者問題；雙方 `notes` 各列「說明與執行紀錄」一節，與判斷分開；
codex 最終輸出由 shell 複製並逐行引用，不由 Claude 重打，發布前過濾本機路徑與署名。
Record 分兩次前景工具呼叫：先刪除舊 `body.md` 並組文；組文成功後才執行獨立的發布指令，
`--body-file` 使用字面絕對路徑，讓 PreToolUse hook 在發布前讀到本次完成的內文。組文失敗就停止發布。
Workflow 腳本不能互相 import，因此各自保留一份與 `pr-loop` 相同措辭的護欄。

回傳 `{ issue, status, rounds, conclusion, basis, disagreements, ask_maintainer, claude, codex, comment }`。
成功的 `status` 是 `agreed`／`derived`／`diverged`；nonce、作答、比對或留言失敗分別為
`setup-failed`／`answer-failed`／`compare-failed`／`record-failed`，失敗不冒充定案。
`answer-failed` 另帶 `failed_reasons`，每項為 `{ agent, reason_index, reason }`：
`agent` 是 `claude` 或 `codex`，`reason_index` 從 1 起算，`reason` 保留未通過依據檢查的理由原文。
`compare-failed` 另帶 `failed_basis`，每項為 `{ basis_index, basis }`；索引從 1 起算，保留修復後仍未通過的比對依據原文。
另帶 `failed_question`，每項為 `{ field: "question", rule, value }`，回報問題欄位、未通過規則與修復後原文；問題格式通過時為空陣列。
作答的 `failed_reasons` 同樣回報修復後內容；若修復代理未回傳內容，則保留原始未通過條目。
雙方的所有未通過理由都會回報；作答失敗時不進入比對或留言。若失敗源於缺少答案等其他格式錯誤，
而沒有可列出的未通過理由，`failed_reasons` 為空陣列。

## 交出 milestone 驗收 PR

宣告「就緒」、「請驗收」或「待維護者驗收」之前，先確認驗收 PR 目前 head 的
`verify-all` job 已完成且結論為 `success`，並在留言附上成功 job 的連結。
一般產品 CI 的綠燈不能取代這個 job；head 更新後要等新 head 的結果。

留言須以自己的 agent 標記開頭，包含 `## 目標對照` 段落與下列四欄表格（唯一範本）：

| 目標 | 使用者實際入口 | 測試或驗收項目 | 證據 |
|---|---|---|---|
| milestone issue 的目標原文 | 使用者實際命令或操作 | 對應 spec 或驗收項目 | 輸出或 CI 連結 |

milestone issue 取自 PR 說明第一個 `Closes #N`（也接受 `Fixes`、`Resolves`）參照，
因此驗收 PR 必須把 milestone issue 放在關閉參照的第一筆。
目標來源支援 `目標:`／`目標：` 單行（以分號分隔）及 `## 目標` 的逐行清單。
每個目標各一列，目標欄須與擷取出的目標文字完全相同（目標來源擷取時略去末尾句號）；四欄都不能空白或只填 `-`。
驗證應從使用者入口出發；表格只能檢查證據是否齊備，不能取代實際驗證。

Claude 與 Codex 的 `enforce_milestone_ready_evidence.sh` 在留言送出前檢查上述條件。
缺 job、未成功、查詢失敗、無法辨識 milestone 或目標、缺表或漏列目標均拒絕。
命令解析共用 approval hook 的封閉規則；shell 展開、間接執行與無法靜態辨識的
API 留言不得繞過檢查。腳本檔與執行期組出的呼叫仍沿用 approval hook 的已知限制。
人類核准與合併仍走既有 milestone gate。

## milestone-handover

每次 milestone 驗收交出前，執行 `.claude/workflows/milestone-handover.js`。
這個 workflow 不合併 PR、不代寫維護者核准，也不自動張貼就緒留言。

| 參數 | 必要 | 說明 |
|---|---|---|
| `repo` | 是 | `owner/name`；每個 gh 指令明寫 `--repo` |
| `repoDir` | 是 | 起始 linked worktree 的絕對路徑；Sync 找到或建立驗收 worktree 後，後續階段都在該 worktree 執行 |
| `base` | 是 | 驗收分支名稱（例如 `m3/5-acceptance`）；拒絕不合法的分支名稱 |
| `pr` | 是 | milestone 驗收 PR 的正整數編號 |
| `milestoneIssue` | 否 | milestone issue 正整數；省略時取 PR 第一筆 Closes/Fixes/Resolves 參照 |
| `safeRun` | 否 | 布林值，預設 `true`；為 `false` 時只列安全分類與待執行命令 |

1. **Sync**：從 `git worktree list --porcelain` 找到 `base` 的 linked worktree，
   沒有時在 repo 同層 `worktree/` 建立；不使用主 checkout。先確認乾淨且 PR head 分支相符，
   fetch `origin/main`。main 已是 HEAD 的祖先時略過 merge、gate、push 和等待，直接進 Head。
   否則以 merge commit 合入，訊息透過 `-F` 檔案提供，末段為 milestone issue 的 `Refs: #N`，
   author 與 committer 使用 GitHub noreply，不加署名、不改寫歷史、不 force push。
   衝突逐處記錄兩邊意圖、解法、理由與驗證；無法安全解決就列出路徑和原因並停止。
   在 Docker 前景依序跑 `just test guards`、合入變更涉及的 spec 和 `just test lint`，
   每次確認最多兩個 worktool-test container；失敗即停止，不推送。
   推送後分輪在前景等待，每輪最多 540 秒，從開始等待起以實際經過時間累計最多 7200 秒；
   最後一輪只使用剩餘時間，單輪到期仍繼續下一輪，超過 1800 秒也不停止。
   每輪開始、結束與每次 poll 都重新確認同一 PR head；除了 `milestone-gate-approval`，
   所有 check（含兩種架構的 `verify-all` 與 `ci-passed`）都須成功。
   每次等待前先判斷失敗；commit status 的 FAILURE／ERROR，以及已完成但非 SUCCESS 的 check
   （含取消、job 逾時與跳過）立即停止，回報 job 名稱、連結與 log 的具體原因；查詢失敗或 head 改變立即停止。
   缺少或仍在執行的 check 跨輪繼續等待；只有累計 7200 秒用盡才判為 CI 逾時。
   上限到期再查一次 head／checks，先判斷失敗或全綠；仍未完成才回報逾時，列出
   已經過時間與所有 pending check 的名稱、狀態、連結，缺少的必要 check 標為 MISSING，
   不列入 milestone-gate-approval，並保存最後一輪證據。
   命令、退出碼、衝突紀錄與 gate／CI 證據留在驗收 worktree 的
   `.agents/state/milestone-handover-<pr>-sync/`；保留 worktree 供後續階段使用。
2. **Head**：確認 full head SHA、`milestone-gate`、所有 head checks 綠燈，
   包括兩種架構的 `verify-all` 與 `ci-passed`；只排除 `milestone-gate-approval`。
   缺少、查詢失敗或未綠即回報並停止。
3. **Scratch**：Head 通過後，在前景統一清除並建立當次 per-head scratch 目錄，僅執行一次；
   初始化失敗即停止，不進入 Findings。
4. **Findings**：分頁讀取全部留言與 review，保留所有 OWNER 且非 agent 標記的歷次
   驗收報告；逐項編為 F1..Fn，附來源、此次重現方法、使用者入口與證據。
   真機限定的 finding 不得以 CI 或靜態閱讀宣稱通過。
5. **Review**：前景執行獨立 codex 對整個 head 複驗，核對 milestone 目標、
   `doc/acceptance.md` 與全部 finding，也逐項比對文件預期輸出和腳本實際輸出。
   codex 子程序以自己的 hook 身分發布原始結果；Claude 只轉交結果，不代貼。
   留言以 `[codex]` 開頭且包含一行
   `交出判定：可交出 head=<full sha>` 或 `交出判定：不可交出 head=<full sha>`，列出阻擋項。
   非零結束、空結果、格式不符或 head 改變均停止。
6. **Machine**：逐項檢查真機項目（M3 第 5 節），只有不發未標記 GitHub 留言、
   修改 live user config 有內建備份與還原、不需人類桌面互動、無同名盒子才安全。
   安全且 `safeRun=true` 才實跑，保留輸出、退出碼與還原結果；最多兩個
   worktool-test container，不停止別人的容器。不安全或停用實跑的項目附理由及維護者命令。
7. **Evidence**：再次確認同 head checks，產生 PR 說明證據段落 `evidence.md` 與
   `ready.md` 草稿，兩者使用發布草稿的 Claude session 身分標記 `[claude]`。
   採用上方唯一四欄目標對照範本，含 CI 連結、每個 finding 與
   第 5 節的輸出／還原／待驗項目。不自動更新 PR 說明或張貼草稿。

中間檔與證據置於 `<repoDir>/.agents/state/milestone-handover-<pr>-<sha>/`，
各階段只能建立或覆寫自己的檔案：Findings 的 `findings.md`、Review 的 `codex*`、
Machine 的 `machine.md` 與 `machine/` 子目錄、Evidence 的 `evidence.md` 與 `ready.md`。
所有階段（含 Review 的 codex 子程序）禁止刪除或重建 scratch 目錄，必須保留前面階段的產物。回傳 `status: prepared` 只代表文件已產生；
負面判定或實跑／還原失敗的草稿明列阻擋，不能宣告就緒。

就緒 hook 另要求同 head 的 `[codex]`「可交出」判定，其時間必須晚於該 SHA
任何「不可交出」判定；查詢失敗、舊 SHA 或後續負面判定都拒絕。
