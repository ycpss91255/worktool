## Agent skills

### Issue tracker
issue 記在 GitHub `ycpss91255/worktool`（`gh` 一律帶 `-R ycpss91255/worktool`，讓指令自己說出目標 repo，不依賴當下目錄的 remote 設定，也不會打到 fork）；外部 PR 不當需求來源。見 `doc/agent/issue-tracker.md`。

### Triage labels
五個標準狀態 = 同名標籤；另有 `needs-decision`（等維護者拍板）。見 `doc/agent/triage-labels.md`。

### Domain docs
單一語境：整體設計與治理見 `doc/design.md`、對外介面見 `doc/structure.md`（`just` 指令表）與 `doc/enter.md`、`doc/manifest.md`、驗收見 `doc/acceptance.md`；名詞見根目錄 `CONTEXT.md`（尚未建立）、ADR 見 `doc/adr/`。見 `doc/agent/domain.md`。

## 決議與文件流程

- 每個設計決議先在 issue 討論（中文）；定案後才寫 ADR。
- ADR 放 `doc/adr/NNNN-<slug>.md`，檔案系統即登錄，不另立索引。
- 架構圖與流程圖（`doc/diagram/*.drawio.svg`）是單一事實來源；決議改動圖面時，同一個 PR 一起更新圖。

## git 慣例

- **一律 push 到分支，進 `main` 只能走 merge。** 不准直接 push main、更不准 force push main。遠端有 branch protection 擋（`ci-passed` 必過、strict、enforce_admins）。
- **一個 issue 一個 PR，一個 PR 只做一件事。** milestone 由多個 sub-issue PR 組成，各自 CI 綠 + codex 確認後合併；只有 milestone 驗收 PR 是人類 gate，不得自動合併。
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
