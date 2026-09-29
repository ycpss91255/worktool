## Agent skills

### Issue tracker
issue 記在 GitHub `ycpss91255/worktool`（`gh` 一律帶 `-R ycpss91255/worktool`，讓指令自己說出目標 repo，不依賴當下目錄的 remote 設定，也不會打到 fork）；外部 PR 不當需求來源。見 `doc/agent/issue-tracker.md`。

### Triage labels
五個標準狀態 = 同名標籤；另有 `needs-decision`（等維護者拍板）。見 `doc/agent/triage-labels.md`。

### Domain docs
單一語境：整體設計與治理見 `doc/design.md`、對外介面見 `doc/structure.md`（`just` 指令表）與 `doc/enter.md`、`doc/manifest.md`、驗收見 `doc/acceptance.md`；名詞見根目錄 `CONTEXT.md`、ADR 見 `doc/adr/`（兩者尚未建立）。見 `doc/agent/domain.md`。

### Agent 設定版面
所有 agent 設定都在 repo 層級，不依賴別的 repo、不在使用者層級建立任何東西：真檔放 `.agents/`（`hook/` 與其 `lib/`、`script/`、`skills/`、`memory/`），`.claude/{hook,script,skills,memory}` 是指向 `../.agents/*` 的相對 symlink，`.claude/settings.json` 進版控、以 `${CLAUDE_PROJECT_DIR}/.claude/hook/<名稱>.sh` 註冊 hook；`.claude/workflows/` 是 Workflow 範本。watch 腳本的 state 放被 gitignore 的 `.agents/state/`。改 hook 或腳本時同步改 `test/unit/hook/`、`test/unit/script/` 的 spec。見 `doc/structure.md`。

## 決議與文件流程

- 每個設計決議先在 issue 討論（中文）；定案後才寫 ADR。
- ADR 放 `doc/adr/NNNN-<slug>.md`，檔案系統即登錄，不另立索引。
- 架構圖與流程圖（`doc/diagram/*.drawio.svg`）是單一事實來源；決議改動圖面時，同一個 PR 一起更新圖。

## git 慣例

- **一律 push 到分支，進 `main` 只能走 merge。** 不准直接 push main、更不准 force push main。遠端有 branch protection 擋（`ci-passed` 必過、strict、enforce_admins）。
- **一個 issue 一個 PR，一個 PR 只做一件事。** milestone 由多個 sub-issue PR 組成，各自 CI 綠 + codex 確認後合併；只有 milestone 驗收 PR 是人類 gate，不得自動合併。
- **milestone 驗收 PR 要有維護者的核准紀錄才能合併（#187）。** 驗收 PR 貼 `milestone-gate` 標籤；核准＝該 PR 上一則 `author_association` 為 `OWNER`、本文開頭不是 `[claude]`／`[codex]`、內容含「允許合併」的留言。對話裡的同意、agent 對留言的解讀都不算。`.github/workflows/milestone-gate.yml` 以 `lib/approval.sh` 判斷，在 PR head SHA 設 commit status `milestone-gate-approval`（沒貼標籤＝success）。agent 的留言一律以 `[claude]`／`[codex]` 開頭，且絕不寫「允許合併」。已知限制：agent 用維護者的 token 發留言，GitHub 分不出本人與代發，所以這道檢查擋的是「忘了等核准」，擋不住冒名；冒名由 agent 端 hook `.agents/hook/enforce_milestone_gate_approval.sh`（#190）擋：對 `milestone-gate` PR 的 `gh pr merge`／`gh api .../pulls/<n>/merge` 沒有核准就拒絕（查詢失敗也拒絕），未標記 `[claude]`／`[codex]` 卻含「允許合併」的留言、review、issue/PR 內文一律拒絕；規則共用 `lib/approval.sh`。hook 採封閉規則：相關的 gh 指令（任何 `gh api`、pr/issue 的 merge／comment／review／create／close／reopen）只要有字含 shell 展開（`$VAR`、`$(...)`、反引號、glob 等）、看不出子命令、子命令前有 `-R`／`--repo` 以外的 root 旗標，或經 `eval`／`bash -c "$X"`／`xargs` 等間接執行，一律擋；以字面參數直接執行 gh（內文用 `--body-file <字面路徑>`）。shell 從 stdin 讀的 heredoc／here-string（`sh <<EOF`、`bash <<< ...`）照樣檢查；`--help`／`-h` 只印用法，放行。已知限制（維護者定案）：直譯器執行的腳本檔（`bash script/x.sh`、`python x.py`、`just ...`）不檢查——未核准的合併仍會被 main 的 required status check `milestone-gate-approval` 擋下，剩下的缺口只有預先寫好的腳本檔發冒名留言；擋下所有腳本執行會擋掉 `just test` 等日常工作。
- **一個 commit = 一個最小單元或一次完整修復。** 不要把不相干的東西包成一個 commit。
- 語言：issue、PR、設計文件、ADR 用繁體中文；commit message、程式碼與註解用英文。不用 emoji。
- 測試只在 Docker 內跑（`just test ...`）；不在 host 上跑 bats、不在 host 上裝套件。

## shell 慣例

- **`lib/` 底下的檔案是被 source 的，不下 `set`。** 它們不該改變呼叫者的 shell 選項；只提供函式。
- **診斷走 stderr，stdout 留給資料。** 用 `lib/log.sh` 的 `log_info`／`log_warn`／`log_error`，呼叫者才能安全地把 stdout 接進管線或變數。
- **參數錯誤一律 exit 2**，訊息格式 `<script>.sh: unknown option '<x>' (see --help)` 寫到 stderr；`--help` 自己 exit 0。功能性失敗用 exit 1，與參數錯誤分開。
- **`--help` 與參數驗證由腳本負責**，`just` 只轉發：見 `doc/design.md`「決策」2026-09-16「模型」的規則 4。
- **不要新增 `shellcheck disable`。** 目前全 repo 是零；先查 <https://www.shellcheck.net/wiki/SC{code}> 找正解，真的沒有，要維護者在對話中明確核准（寫 `approve SC<code>`）才能加。
