## Agent skills

### Issue tracker
issue 記在 GitHub `ycpss91255/worktool`（`gh` 一律帶 `-R ycpss91255/worktool`，讓指令自己說出目標 repo，不依賴當下目錄的 remote 設定，也不會打到 fork）；外部 PR 不當需求來源。見 `doc/agent/issue-tracker.md`。

### Triage labels
五個標準狀態 = 同名標籤；另有 `needs-decision`（等維護者拍板）。見 `doc/agent/triage-labels.md`。

### Domain docs
單一語境：整體設計與治理見 `doc/design.md`、對外介面見 `doc/structure.md`（`just` 指令表）與 `doc/enter.md`、`doc/manifest.md`、驗收見 `doc/acceptance.md`；名詞見根目錄 `CONTEXT.md`（尚未建立）、ADR 見 `doc/adr/`。見 `doc/agent/domain.md`。

### Agent 設定版面
所有 agent 設定都在 repo 層級，不依賴別的 repo、不在使用者層級建立任何東西：真檔放 `.agents/`（`hook/` 與其 `lib/`、`script/`、`skills/`、`memory/`），`.claude/{hook,script,skills,memory}` 是指向 `../.agents/*` 的相對 symlink，`.claude/settings.json` 進版控、以 `${CLAUDE_PROJECT_DIR}/.claude/hook/<名稱>.sh` 註冊 hook；`.claude/workflows/` 是 Workflow 範本。watch 腳本的 state 放被 gitignore 的 `.agents/state/`。改 hook 或腳本時同步改 `test/unit/hook/`、`test/unit/script/` 的 spec。見 `doc/structure.md`。

## 決議與文件流程

- 每個設計決議先在 issue 討論（中文）；定案後才寫 ADR。
- ADR 放 `doc/adr/NNNN-<slug>.md`，檔案系統即登錄，不另立索引。
- 架構圖與流程圖（`doc/diagram/*.drawio.svg`）是單一事實來源；決議改動圖面時，同一個 PR 一起更新圖。

## git 慣例

- **一律 push 到分支，進 `main` 只能走 merge。** 不准直接 push main、更不准 force push main。遠端有 branch protection 擋（`ci-passed` 必過、strict、enforce_admins）。
- **一個 issue 一個 PR，一個 PR 只做一件事。** milestone 由多個 sub-issue PR 組成，各自 CI 綠 + codex 確認後合併；只有 milestone 驗收 PR 是人類 gate，不得自動合併。
- **milestone 驗收 PR 要有維護者的核准紀錄才能合併（#187）。** 驗收 PR 貼 `milestone-gate` 標籤；核准＝該 PR 上一則 `author_association` 為 `OWNER`、本文開頭不是 `[claude]`／`[codex]`、內容含「允許合併」的留言。對話裡的同意、agent 對留言的解讀都不算。`.github/workflows/milestone-gate.yml` 以 `lib/approval.sh` 判斷，在 PR head SHA 設 commit status `milestone-gate-approval`（沒貼標籤＝success）。agent 的留言一律以 `[claude]`／`[codex]` 開頭，且絕不寫「允許合併」。已知限制：agent 用維護者的 token 發留言，GitHub 分不出本人與代發，所以這道檢查擋的是「忘了等核准」，擋不住冒名；冒名由 agent 端 hook `.agents/hook/enforce_milestone_gate_approval.sh`（#190）擋：對 `milestone-gate` PR 的 `gh pr merge`／`gh api .../pulls/<n>/merge` 沒有核准就拒絕（查詢失敗也拒絕），agent 送出的每一則留言（`gh pr|issue comment`、有內文的 `gh pr review`、`close|reopen --comment`、`gh api` 對 comments／reviews 端點的寫入、GraphQL 留言／review mutation）開頭（去掉前導空白後）不是 `[claude]`／`[codex]` 一律拒絕，不論是否含「允許合併」（#190 範圍修訂；PR／issue 的 create 內文不算留言）；直連 API 與 `gh api` 只有寫入（依 HTTP 方法判斷）才算；規則共用 `lib/approval.sh`。hook 採封閉規則：相關的 gh 指令（任何 `gh api`、pr/issue 的 merge／comment／review／create／close／reopen）只要有字含 shell 展開（`$VAR`、`$(...)`、反引號、glob 等）、看不出子命令、子命令前有 `-R`／`--repo` 以外的 root 旗標，或經 `eval`／`bash -c "$X"`／`xargs` 等間接執行，一律擋；以字面參數直接執行 gh（內文用 `--body-file <字面路徑>`）。shell 從 stdin 讀的 heredoc／here-string（`sh <<EOF`、`bash <<< ...`）照樣檢查；`--help`／`-h` 只印用法，放行。另有兩道後盾：raw-text tripwire（整段原始指令文字、含 heredoc 內文裡的相關 gh 呼叫、核准片語、`api.github.com` 或 GHES 的 merge／comments／graphql 字面 URL（先正規化：大小寫、結尾點、連接埠、帳密前綴、scheme、路徑寫法），多於結構化解析實際檢查放行的就擋）與 inline-code tripwire（python／perl／ruby／node／php／awk 等的 inline 程式或餵入的 heredoc 同時提到 `gh` 與子命令字、`api.github.com` 或核准片語就擋）；代價是只「提到」它們的純文字（commit 訊息、echo）也會被擋，改用 `-F`／`--file`。已知限制（維護者定案，見 #190「範圍」）：腳本檔（`bash script/x.sh`、`python x.py`、`just ...`）、混淆過的 inline 程式（字串拼接、編碼）、執行時才組出呼叫的程式，以及以 IP 位址、DNS 別名或轉址連到 API 都不檢查，hook 並非能擋住所有直譯器；合併仍由 main 的 required status check `milestone-gate-approval` 在伺服器端擋下，剩下的缺口只有以這些方式發冒名留言；擋下所有腳本執行會擋掉 `just test` 等日常工作。
- **commit 的 author 與 committer email 一律用 GitHub noreply（`<id>+<帳號>@users.noreply.github.com`，#234）。** repo 已公開；CI 的 `commit-email` job 以 `lib/commit_email.sh` 檢查 PR（與 push）新增的每個 commit，列入 `ci-passed`。author 一律須是 noreply；committer 須是 noreply 或 GitHub 自己的 `noreply@github.com`（合併按鈕、網頁編輯；此例外不豁免 author）。不以 commit 日期豁免（日期可偽造）；舊歷史靠檢查範圍（PR base..head、push before..after）排除，main 歷史不改寫。違規時設好 `git config user.email` 後以 `git rebase -r --exec 'git commit --amend --no-edit --reset-author' origin/main` 改寫 PR 分支再 `git push --force-with-lease`。
- **一個 commit = 一個最小單元或一次完整修復。** 不要把不相干的東西包成一個 commit。
- 語言：issue、PR、設計文件、ADR 用繁體中文；commit message、程式碼與註解用英文。不用 emoji。
- 測試只在 Docker 內跑（`just test ...`）；不在 host 上跑 bats、不在 host 上裝套件。

## shell 慣例

- **`lib/` 底下的檔案是被 source 的，不下 `set`。** 它們不該改變呼叫者的 shell 選項；只提供函式。
- **`script/` 底下的可執行腳本一律 `set -euo pipefail`。** 沒被處理的失敗立刻中止，不讓腳本帶著錯往下跑；決議見 `doc/adr/0001-scripts-use-errexit.md`。
- **預期會非零的指令必須明確處理，不可用 `|| true` 吞掉。** 寫成 `if ! cmd; then …; fi`、`cmd || rc=$?` 或 `rc=0; cmd || rc=$?`；`grep` 找不到、探測失敗、要轉成腳本自己退出碼的回傳碼都算。在 `if`／`&&`／`||` 裡呼叫的函式，內部的 `-e` 會失效，依賴這點的寫法必須是刻意的。
- **診斷走 stderr，stdout 留給資料。** 用 `lib/log.sh` 的 `log_info`／`log_warn`／`log_error`，呼叫者才能安全地把 stdout 接進管線或變數。
- **參數錯誤一律 exit 2**，訊息格式 `<script>.sh: unknown option '<x>' (see --help)` 寫到 stderr；`--help` 自己 exit 0。功能性失敗用 exit 1，與參數錯誤分開。
- **`--help` 與參數驗證由腳本負責**，`just` 只轉發：見 `doc/design.md`「決策」2026-09-16「模型」的規則 4。
- **不要新增 `shellcheck disable`。** 目前全 repo 是零；先查 <https://www.shellcheck.net/wiki/SC{code}> 找正解，真的沒有，要維護者在對話中明確核准（寫 `approve SC<code>`）才能加。
