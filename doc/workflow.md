# Workflow 範本(`.claude/workflows/`)

worktool 的 sub-issue 都用同一條迴圈交付:**實作(TDD)-> CI -> codex 複驗 -> 修正 -> 再複驗**,
CI 綠且 codex「可合併」才由主迴圈合併(一次一個 PR、merge commit、保留各 agent 的 commit)。
這條迴圈寫成兩個可重用的 Claude Code Workflow 腳本,不再每次臨時寫。

| 檔案 | 用途 | 何時用 |
|------|------|--------|
| `pr-loop.js` | 一個 sub-issue -> 一個 PR,推到「CI 綠 + codex 可合併」 | 每一個 sub-issue |
| `milestone-fanout.js` | 多個**彼此獨立**的 sub-issue 各自跑一遍 `pr-loop`(pipeline,誰先好誰先回報) | milestone 開工、一波獨立的 sub-issue |

## 呼叫方式

從任何 cwd 以 `scriptPath` 呼叫(不需要把腳本裝進 session 的專案目錄):

```text
Workflow({ scriptPath: "/home/cyc/Desktop/worktool/.claude/workflows/pr-loop.js", args: {
  repo: "ycpss91255/worktool",
  issue: 150,
  branch: "m3/150-bench",
  name: "bench",
  parent: "#5",
  codex: "on",
  maxRounds: 3,
  task: "<要做什麼、驗收標準、檔案、測試;越具體越好>"
} })
```

`milestone-fanout.js` 的 `args` = `{ repo, parent, codex, maxRounds, repoDir?, items: [ { issue, branch, name, task, gates? }, ... ] }`;每個 item 一結束就 `log` 一行結果(誰先好誰先看到)。

## pr-loop 的 args

| 參數 | 必要 | 說明 |
|------|------|------|
| `repo` | 是 | `owner/name`;所有 gh 指令都帶 `--repo` |
| `issue` | 是 | 這個 PR 關閉的**唯一** sub-issue(PR 描述會有 `Closes #N`) |
| `branch` | 是 | 從 `origin/main` 開的分支名 |
| `name` | 是 | worktree 名稱(`.worktree/<name>`);各 PR 各自的 worktree,不互相干擾 |
| `task` | 是 | 交給實作 agent 的完整任務描述 |
| `gates` | 否 | 預設六道 `just test ...`;純文件可縮成 `just test lint, just test unit` |
| `codex` | 否 | 只接受 `on`(預設)/ `off`(配額暫停:改在 PR 留 `[claude]` 註記,不冒充 codex);其他值直接報錯 |
| `maxRounds` | 否 | 允許的 Fix 輪數(非負整數,預設 3;`0` = 只複驗一次、不修);用完就回報 `blockingLeft` 交主迴圈處理 |
| `parent` | 否 | PR 描述的 `Part of` 參照(例如 `#5`) |
| `repoDir` | 否 | 本機 checkout 路徑(預設 `/home/cyc/Desktop/worktool`);worktree 在 `<repoDir>/.worktree/<name>`、暫存檔在 `<repoDir>/.worktree/.scratch/<name>`(皆 gitignored) |

## 迴圈內容

1. **Implement**:agent 在自己的 worktree(`git worktree add -b <branch> .worktree/<name> origin/main`)依 TDD 做:
   先寫測試看到 RED,再實作到 GREEN;六道 gate 在 Docker 內以 `just test <tier>` 阻塞執行;push;
   開 PR(zh-TW 描述:`Closes #N`、`Part of`、「這個 PR 只做一件事」、commit 清單、「測試證據」)。
2. **Locate**:agent 以 `gh pr list --head <branch>` 結構化回傳 PR 編號與 head SHA(不從自由文字猜)。
3. **CI**:agent 以 `gh pr checks --watch` 等到全綠;紅就讀 log 修正、再推(最多兩輪);仍紅就以 `ciState: red` 結束,不進 codex。
4. **Codex**:agent 把 **PR 描述 + 對應 issue + 完整 diff** 餵給 `codex exec`,逐項確認
   (一件事 / TDD 證據 / 自足 / 正確性與健壯性 / 文件一致 / 新問題),把 codex 原文以 `[codex]`
   貼到 PR,加一行 `[claude] double-check`(上下文是否完整、每項是否引用 diff 位置)與可重現指令。
   第二輪起會把上一輪判定逐字附在 prompt 裡,要求逐項確認是否已修正。判定是結構化欄位(`mergeable` /
   `blocked` / `no-output`):codex 無輸出或格式不明**不算通過**。
5. **Fix**:codex「不可合併」時,agent 在同一 worktree 針對每個阻擋項先補失敗測試再修,獨立 commit,
   push,PR 留言 `[claude] 採納第 N 輪:`;回到 CI -> Codex;最多 `maxRounds` 輪。
6. 回傳 `{ issue, pr, sha, ciState, codexVerdict, rounds, blockingLeft }`。**不 merge**:合併順序、rebase 衝突由主迴圈處理。

## 對應的治理規則

- 一個 issue 一個 PR、一個 PR 只做一件事(`issue` 是單一值;`Closes #N` 只有一個)。
- 每個 agent 獨立 commit,合併不 squash(範本只 push,不 merge)。
- codex 是靜態審查:測試證據一律由本機 gate + CI 提供;codex 暫停時不冒充,留 `[claude]` 註記。
- 可並行的就並行:獨立的 sub-issue 用 `milestone-fanout`;有相依的用 `pr-loop` 依序。
- 範本本身有守門測試 `test/unit/workflow_spec.bats`:meta 字面量必須是檔案第一行且純字面量、phase 名稱
  雙向一致(任何引號寫法)、參數驗證、PR 以分支結構化定位、CI 是 gate、codex 判定結構化且無輸出不算過、
  codex=off 不冒充、Fix 輪數受限、回傳契約、不含任何 merge 手段、不寫死 session 暫存路徑、fan-out 驗證 item 並委派。
