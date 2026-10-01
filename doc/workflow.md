# Workflow 範本(`.claude/workflows/`)

worktool 的 sub-issue 都用同一條迴圈交付:**實作(TDD)-> CI -> 另一方複驗 -> 修正 -> 再複驗**。
預設 codex 實作、Claude 審查；也可切成 Claude 實作、codex 審查。CI 綠且審查方判定可合併後，才由主迴圈合併(一次一個 PR、merge commit、保留各 agent 的 commit)。
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
| `branch` | 是 | 從 `origin/main` 開的分支名 |
| `name` | 是 | worktree 名稱(`../worktree/<name>`);各 PR 各自的 worktree,不互相干擾 |
| `task` | 是 | 交給實作 agent 的完整任務描述 |
| `gates` | 否 | 額外 gate；預設為推送前執行 `just test lint` 與 `just test changed`，不得用它要求本機跑整個 tier |
| `implementer` | 否 | `codex`(預設)或 `claude`;實作與 Fix 由這一方執行，Review 永遠由另一方執行 |
| `codex` | 否 | 只接受 `on`(預設)/ `off`(配額暫停:改在 PR 留 `[claude]` 註記,不冒充 codex);其他值直接報錯 |
| `maxRounds` | 否 | 允許的 Fix 輪數(非負整數,預設 3;`0` = 只複驗一次、不修);用完就回報 `blockingLeft` 交主迴圈處理 |
| `parent` | 否 | PR 描述的 `Part of` 參照(例如 `#5`) |
| `repoDir` | 是 | 本機 main checkout 路徑(不預設,換機器就換值);worktree 在 `$(dirname <repoDir>)/worktree/<name>`、暫存檔在 `$(dirname <repoDir>)/worktree/.scratch/<name>` |

## 迴圈內容

1. **Implement**:agent 在自己的 worktree(`git worktree add -b <branch> <repoDir>/../worktree/<name> origin/main`)依 TDD 做:
   先寫測試看到 RED,再實作到 GREEN;每個 TDD 切片只在 Docker 內跑該 spec（`just test <tier> <spec...> [--filter REGEX]`）；
   push 前阻塞執行 `just test lint` 與 `just test changed`。本機不跑整個 tier；全部 tier 由 CI 執行；
   開 PR(zh-TW 描述:`Closes #N`、`Part of`、「這個 PR 只做一件事」、commit 清單、「測試證據」)。
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
   已推送的 commit 不得 rebase、amend、reset 或 force push 改寫；只追加新 commit，需要同步 main 時用 merge。
6. 回傳 `{ issue, pr, sha, ciState, codexVerdict, rounds, blockingLeft }`。**不 merge PR**:PR 合併順序與衝突由主迴圈處理。

## milestone-fanout

用途：讓多個彼此獨立的 sub-issue 各跑一遍 `pr-loop`。每批最多兩個 workflow 並行，因此主機上同時最多兩個測試；一批結束才開始下一批。每個結果完成後都會寫入 log，workflow 本身不 merge。

| 參數 | 必要 | 說明 |
|------|------|------|
| `repo` | 是 | `owner/name`;轉傳給每個 `pr-loop` |
| `repoDir` | 是 | 本機 checkout 的絕對路徑 |
| `items` | 是 | 非空陣列；每項必須有 `issue`、`branch`、`name`、`task`；`gates` 若有指定就原樣轉傳，省略時由 `pr-loop` 使用 lint + changed 預設 |
| `implementer` | 否 | `codex`(預設)或 `claude`;轉傳給每個 `pr-loop` |
| `parent` | 否 | 每個 PR 的 `Part of` 參照 |
| `codex` | 否 | `on`(預設)或 `off` |
| `maxRounds` | 否 | 每個 PR 的 Fix 輪數上限，預設 3 |

args 範例：

```json
{
  "repo": "ycpss91255/worktool",
  "repoDir": "/path/to/worktool",
  "parent": "#280",
  "implementer": "codex",
  "maxRounds": 3,
  "items": [
    { "issue": 281, "branch": "feat/281-a", "name": "impl281", "task": "完成 issue #281。" },
    { "issue": 282, "branch": "feat/282-b", "name": "impl282", "task": "完成 issue #282。" }
  ]
}
```

## research-verify

維護者規則:找資料一律用 agy(gemini)查,由 claude 與 codex 做驗證(#220)。`args` = `{ repo, repoDir, issue, question, context?, sources?, timeoutMin? }`:

| 參數 | 必要 | 說明 |
|------|------|------|
| `repo` | 是 | `owner/name`(只允許英數、`.`、`_`、`-`);gh 一律帶 `--repo` |
| `repoDir` | 是 | 本機 main checkout 的絕對路徑(可含空白,不可含控制字元或反引號);prompt 與原始輸出放在 `$(dirname <repoDir>)/worktree/.scratch/research-<issue>/` |
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
   有一個不可讀就回傳 `status: 'sources-invalid'` 並停在這裡,agy 同樣不會被呼叫;接著 agent 跑 `agy --sandbox --dangerously-skip-permissions -p <prompt> --print-timeout <m>m`,
   prompt 要求只用一手來源、每條主張標來源類型、查不到標 `UNVERIFIED`;輸出寫進 `agy.md`。
   指令本身以 exit status 表達成敗(agy exit 0 且 `agy.md` 非空才是 0)。
   無輸出或逾時重試一次,仍失敗就回傳 `status: 'agy-failed'` 並停在這裡,**不改用其他模型或自己的知識冒充**;
   agent 回報的 `attempts` 不是 1 或 2 也算失敗。
2. **Verify**(並行):claude agent 逐條判定(成立 / 不成立 / 無法確認,附依據,結構化,至少一條);
   另一個 agent 以 `cat agy.md | codex exec --skip-git-repo-check` 讓 codex 逐條驗證,`codex.md` 只存 codex 的**最終回答**:
   優先取 codex 以 `-o`(`--output-last-message`)自己寫出的檔案;沒有才取 transcript 最後一個 `codex` 區塊,
   且該區塊必須緊接內容恰為 `tokens used` 的一行(回合完成的邊界;`tokens used by ...` 之類的文字只是回答內容,不算邊界),不含 commentary、工具執行紀錄與 `tokens used` 之後重複的回答(#223)。
   沒有這個邊界(停在 commentary、工具呼叫中或錯誤)就視為沒有最終回答,`codex.md` 為空,Record 不發(fail closed)。
   codex 非零結束、無輸出或最終回答抽取失敗都以非零結束。
   **兩路都必須有結果**:claude 沒回 claims(空值、空陣列,或任一條缺 claim / verdict / basis)或 codex 無輸出(配額/認證)就回傳
   `status: 'verify-failed'` 並停在這裡,不綜合、不留言(研究原文留在 scratch,可重跑)。
3. **Synthesize**:合併成驗證後成立的事實、被推翻的主張、仍需實測的點、建議方案、需要維護者拍板的參數(結構化)。
   結果缺欄位、型別不對或建議方案為空就回傳 `status: 'synthesize-failed'`,不留言,**不以替代結論冒充**。
4. **Record**:留言一律以 `--body-file` 發出,每則上限集中為 60,000 bytes(低於 GitHub 的 65,536 字元限制)。
   小型研究仍合併成一則;超過上限時第一則固定是驗證後成立、被推翻、仍需實測、建議方案與待拍板參數,
   後續依序放 claude 逐條明細、引用格式的 codex 原文與 agy 原文,每則標明「第 n／N 則」。單一段落仍放不下時截斷並標記,
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
(筆記、草稿、log)只能寫在 `$(dirname <repoDir>)/worktree/.scratch/research-<issue>/`(或系統暫存),不得新增、修改、
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
- 守門測試 `test/unit/workflow_spec.bats` 是**文字層級**的規約檢查(測試映像沒有 JS 引擎,不做 AST 解析):
  釘住 meta 在第一行且看起來是純字面量、phase 名稱、參數驗證、結構化 PR/CI/codex、CI gate、Fix 輪數、
  回傳契約、已知的 merge 指令、不寫死機器路徑 / session。它擋的是「不小心改壞」,不是行為證明;
  行為證明 = 在真實 sub-issue 上跑範本(dogfood),結果留在該 PR。
