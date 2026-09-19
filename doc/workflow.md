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

`milestone-fanout.js` 的 `args` = `{ repo, parent, codex, maxRounds, items: [ { issue, branch, name, task, gates? }, ... ] }`。

## pr-loop 的 args

| 參數 | 必要 | 說明 |
|------|------|------|
| `repo` | 是 | `owner/name`;所有 gh 指令都帶 `--repo` |
| `issue` | 是 | 這個 PR 關閉的**唯一** sub-issue(PR 描述會有 `Closes #N`) |
| `branch` | 是 | 從 `origin/main` 開的分支名 |
| `name` | 是 | worktree 名稱(`.worktree/<name>`);各 PR 各自的 worktree,不互相干擾 |
| `task` | 是 | 交給實作 agent 的完整任務描述 |
| `gates` | 否 | 預設六道 `just test ...`;純文件可縮成 `just test lint, just test unit` |
| `codex` | 否 | `on`(預設)/ `off`(配額暫停:改在 PR 留 `[claude]` 註記,不冒充 codex) |
| `maxRounds` | 否 | codex 修正迴圈上限(預設 3);超過就回報 `blockingLeft` 交主迴圈處理 |
| `parent` | 否 | PR 描述的 `Part of` 參照(例如 `#5`) |

## 迴圈內容

1. **Implement**:agent 在自己的 worktree(`git worktree add -b <branch> .worktree/<name> origin/main`)依 TDD 做:
   先寫測試看到 RED,再實作到 GREEN;六道 gate 在 Docker 內以 `just test <tier>` 阻塞執行;push;
   開 PR(zh-TW 描述:`Closes #N`、`Part of`、「這個 PR 只做一件事」、commit 清單、「測試證據」)。
2. **CI**:agent 以 `gh pr checks --watch` 等到全綠;紅就讀 log 修正、再推(最多兩輪)。
3. **Codex**:agent 把 **PR 描述 + 對應 issue + 完整 diff** 餵給 `codex exec`,逐項確認
   (一件事 / TDD 證據 / 自足 / 正確性與健壯性 / 文件一致 / 新問題),把 codex 原文以 `[codex]`
   貼到 PR,加一行 `[claude] double-check`(上下文是否完整、每項是否引用 diff 位置)與可重現指令。
   第二輪起會把上一輪判定逐字附在 prompt 裡,要求逐項確認是否已修正。
4. **Fix**:codex「不可合併」時,agent 在同一 worktree 針對每個阻擋項先補失敗測試再修,獨立 commit,
   push,PR 留言 `[claude] 採納第 N 輪:`;回到 CI -> Codex。
5. 回傳 `{ issue, pr, ci, codex, rounds, blockingLeft }`。**不 merge**:合併順序、rebase 衝突由主迴圈處理。

## 對應的治理規則

- 一個 issue 一個 PR、一個 PR 只做一件事(`issue` 是單一值;`Closes #N` 只有一個)。
- 每個 agent 獨立 commit,合併不 squash(範本只 push,不 merge)。
- codex 是靜態審查:測試證據一律由本機 gate + CI 提供;codex 暫停時不冒充,留 `[claude]` 註記。
- 可並行的就並行:獨立的 sub-issue 用 `milestone-fanout`;有相依的用 `pr-loop` 依序。
- 範本本身有守門測試 `test/unit/workflow_spec.bats`(meta 字面量、phase 名稱一致、codex=off 分支、
  不含 merge、fan-out 委派給 pr-loop)。
