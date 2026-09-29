# Workflow 範本(`.claude/workflows/`)

worktool 的 sub-issue 都用同一條迴圈交付:**實作(TDD)-> CI -> codex 複驗 -> 修正 -> 再複驗**,
CI 綠且 codex「可合併」才由主迴圈合併(一次一個 PR、merge commit、保留各 agent 的 commit)。
這條迴圈寫成兩個可重用的 Claude Code Workflow 腳本,不再每次臨時寫;查資料另有 `research-verify.js`。

| 檔案 | 用途 | 何時用 |
|------|------|--------|
| `pr-loop.js` | 一個 sub-issue -> 一個 PR,推到「CI 綠 + codex 可合併」 | 每一個 sub-issue |
| `milestone-fanout.js` | 多個**彼此獨立**的 sub-issue 各自跑一遍 `pr-loop`(pipeline,誰先好誰先回報) | milestone 開工、一波獨立的 sub-issue |
| `research-verify.js` | 找資料:agy(gemini)查,claude 與 codex 並行逐條驗證,結論留言在 issue | 任何需要查證的設計問題(見下方「research-verify」) |

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
  codex: "on",
  maxRounds: 3,
  task: "<要做什麼、驗收標準、檔案、測試;越具體越好>"
} })
```

`milestone-fanout.js` 的 `args` = `{ repo, repoDir, parent, codex, maxRounds, sessionUrl?, items: [ { issue, branch, name, task, gates? }, ... ] }`;每個 item 一結束就 `log` 一行結果(誰先好誰先看到)。

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
| `repoDir` | 是 | 本機 checkout 路徑(不預設,換機器就換值);worktree 在 `<repoDir>/.worktree/<name>`、暫存檔在 `<repoDir>/.worktree/.scratch/<name>`(皆 gitignored) |
| `sessionUrl` | 否 | 要寫進 commit 的 `Claude-Session:` trailer;不給就不寫 |

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

## research-verify

維護者規則:找資料一律用 agy(gemini)查,由 claude 與 codex 做驗證(#220)。`args` = `{ repo, repoDir, issue, question, context?, sources?, timeoutMin? }`:

| 參數 | 必要 | 說明 |
|------|------|------|
| `repo` | 是 | `owner/name`(只允許英數、`.`、`_`、`-`);gh 一律帶 `--repo` |
| `repoDir` | 是 | 本機 checkout 的絕對路徑(可含空白,不可含控制字元或反引號);prompt 與原始輸出放在 `<repoDir>/.worktree/.scratch/research-<issue>/`(gitignored) |
| `issue` | 是 | 正整數;結論以**一則**留言貼到這個 issue |
| `question` | 是 | 研究問題 |
| `context` | 否 | 背景說明,agy 與兩個驗證者都會拿到 |
| `sources` | 否 | 本機一手資料路徑陣列(例如鎖定版原始碼),給 claude 與 codex 驗證時直接讀 |
| `timeoutMin` | 否 | agy `--print-timeout` 分鐘數(正整數,預設 15);外層再包 `timeout` 硬上限 |

1. **Research**:agent 跑 `agy --sandbox --dangerously-skip-permissions -p <prompt> --print-timeout <m>m`,
   prompt 要求只用一手來源、每條主張標來源類型、查不到標 `UNVERIFIED`;輸出寫進 `agy.md`。
   無輸出或逾時重試一次,仍失敗就回傳 `status: 'agy-failed'` 並停在這裡,**不改用其他模型或自己的知識冒充**。
2. **Verify**(並行):claude agent 逐條判定(成立 / 不成立 / 無法確認,附依據,結構化,至少一條);
   另一個 agent 以 `cat agy.md | codex exec --skip-git-repo-check` 讓 codex 逐條驗證,原文存成 `codex.md`。
   **兩路都必須有結果**:claude 沒回 claims(空值或空陣列)或 codex 無輸出(配額/認證)就回傳
   `status: 'verify-failed'` 並停在這裡,不綜合、不留言(研究原文留在 scratch,可重跑)。
3. **Synthesize**:合併成驗證後成立的事實、被推翻的主張、仍需實測的點、建議方案、需要維護者拍板的參數(結構化)。
   結果缺欄位、型別不對或建議方案為空就回傳 `status: 'synthesize-failed'`,不留言,**不以替代結論冒充**。
4. **Record**:一則 issue 留言(`--body-file`):`[claude]` 結論 + codex 原文(由 shell 從 `codex.md` 複製,
   agent 不自己寫 `[codex]` 行)+ agy 原文放在 `<details>` 摺疊區塊;`agy.md` 或 `codex.md` 為空就不發。
5. 回傳 `{ issue, status, codex, claims, comment, synthesis }`,`status` 為
   `recorded` / `agy-failed` / `verify-failed` / `synthesize-failed` / `record-failed`;只有 `recorded` 代表留言已發出。

shell 安全:所有進入 shell 指令的值(scratch 路徑、`repo`)都以 POSIX 單引號包住,`repoDir` 的空白與
metacharacter 只會是資料。`test/unit/workflow_spec.bats` 在測試映像內以 node 實際執行這個範本
(`test/unit/fixture/workflow_run.mjs`,agent 以替身代打並真的跑每個 shell 步驟),驗證參數拒絕、quoting 與 fail-closed 流程。

## 對應的治理規則

- 一個 issue 一個 PR、一個 PR 只做一件事(`issue` 是單一值;`Closes #N` 只有一個)。
- 每個 agent 獨立 commit,合併不 squash(範本只 push,不 merge)。
- codex 是靜態審查:測試證據一律由本機 gate + CI 提供;codex 暫停時不冒充,留 `[claude]` 註記。
- 可並行的就並行:獨立的 sub-issue 用 `milestone-fanout`;有相依的用 `pr-loop` 依序。
- 守門測試 `test/unit/workflow_spec.bats` 是**文字層級**的規約檢查(測試映像沒有 JS 引擎,不做 AST 解析):
  釘住 meta 在第一行且看起來是純字面量、phase 名稱、參數驗證、結構化 PR/CI/codex、CI gate、Fix 輪數、
  回傳契約、已知的 merge 指令、不寫死機器路徑 / session。它擋的是「不小心改壞」,不是行為證明;
  行為證明 = 在真實 sub-issue 上跑範本(dogfood),結果留在該 PR。
