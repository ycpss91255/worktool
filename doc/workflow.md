# Workflow 範本(`.claude/workflows/`)

worktool 的 sub-issue 都用同一條迴圈交付:**實作(TDD)-> CI -> 另一方複驗 -> 修正 -> 再複驗**。
`mode: "full"` 為預設，codex 實作、Claude 審查；也可切成 Claude 實作、codex 審查。CI 綠且審查方判定可合併後，才由主迴圈合併(一次一個 PR、merge commit、保留各 agent 的 commit)。
這條迴圈寫成兩個可重用的 Claude Code Workflow 腳本,不再每次臨時寫;查資料另有 `research-verify.js`。

| 檔案 | 用途 | 何時用 |
|------|------|--------|
| `pr-loop.js` | 一個 sub-issue -> 一個 PR,推到「CI 綠 + codex 可合併」 | 每一個 sub-issue；機械式小修改用 light |
| `milestone-fanout.js` | 多個**彼此獨立**的 sub-issue 各自跑一遍 `pr-loop`(pipeline,誰先好誰先回報) | milestone 開工、一波獨立的 sub-issue |
| `research-verify.js` | 找資料:agy(gemini)查,codex 逐條開來源核對、claude 抽查與整合,結論留言在 issue | 任何需要查證的設計問題(見下方「research-verify」) |

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
| `branch` | 是 | 從 `origin/main` 開的分支名 |
| `name` | 是 | worktree 名稱(`../worktree/<name>`);各 PR 各自的 worktree,不互相干擾 |
| `task` | 是 | 交給實作 agent 的完整任務描述 |
| `gates` | 否 | 額外 gate；full 預設為推送前執行 `just test lint` 與 `just test changed`，不得用它要求本機跑整個 tier |
| `mode` | 否 | `full`（預設）或 `light`；其他值直接 throw。light 固定由 Claude 修改與另一個 Claude 子代理審查，不呼叫 codex |
| `implementer` | 否 | `codex`(預設)或 `claude`;實作與 Fix 由這一方執行，Review 永遠由另一方執行 |
| `codex` | 否 | 只接受 `on`(預設)/ `off`(配額暫停:改在 PR 留 `[claude]` 註記,不冒充 codex);其他值直接報錯 |
| `maxRounds` | 否 | 允許的 Fix 輪數(非負整數,預設 3;`0` = 只複驗一次、不修);用完就回報 `blockingLeft` 交主迴圈處理 |
| `parent` | 否 | PR 描述的 `Part of` 參照(例如 `#5`) |
| `repoDir` | 是 | 本機 main checkout 路徑(不預設,換機器就換值);worktree 在 `$(dirname <repoDir>)/worktree/<name>`、暫存檔在 `$(dirname <repoDir>)/worktree/.scratch/<name>` |

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
| `items` | 是 | 非空陣列；每項必須有 `issue`、`branch`、`name`、`task`；`gates` 若有指定就原樣轉傳，省略時由 `pr-loop` 依 mode 選擇預設 gate |
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

留言須以自己的 agent 標記開頭，包含 `## 目標對照` 段落與三欄表格：

| 目標 | 測試或驗收項目 | 使用者入口 |
|---|---|---|
| milestone issue 的目標原文 | 對應 spec 或驗收項目 | 使用者實際命令或操作 |

milestone issue 取自 PR 說明第一個 `Closes #N`（也接受 `Fixes`、`Resolves`）參照，
因此驗收 PR 必須把 milestone issue 放在關閉參照的第一筆。
目標來源支援 `目標:`／`目標：` 單行（以分號分隔）及 `## 目標` 的逐行清單。
每個目標各一列，目標欄填原文（可略末尾句號），驗證項目與入口欄都不能空白或只填 `-`。
驗證應從使用者入口出發；表格只能檢查證據是否齊備，不能取代實際驗證。

Claude 與 Codex 的 `enforce_milestone_ready_evidence.sh` 在留言送出前檢查上述條件。
缺 job、未成功、查詢失敗、無法辨識 milestone 或目標、缺表或漏列目標均拒絕。
命令解析共用 approval hook 的封閉規則；shell 展開、間接執行與無法靜態辨識的
API 留言不得繞過檢查。腳本檔與執行期組出的呼叫仍沿用 approval hook 的已知限制。
人類核准與合併仍走既有 milestone gate。
