## Agent skills

### Issue tracker
issue 記在 GitHub `ycpss91255/worktool`（`gh` 一律帶 `-R ycpss91255/worktool`，讓指令自己說出目標 repo，不依賴當下目錄的 remote 設定，也不會打到 fork）；外部 PR 不當需求來源。見 `doc/agent/issue-tracker.md`。

### Triage labels
五個標準狀態 = 同名標籤；另有 `needs-decision`（等維護者拍板）。見 `doc/agent/triage-labels.md`。

### Domain docs
單一語境：整體設計與治理見 `doc/design.md`、對外介面見 `doc/structure.md`（`just` 指令表）與 `doc/enter.md`、`doc/manifest.md`、驗收見 `doc/acceptance.md`；名詞見根目錄 `CONTEXT.md`、ADR 見 `doc/adr/`（兩者尚未建立）。見 `doc/agent/domain.md`。

## 決議與文件流程

- 每個設計決議先在 issue 討論（中文）；定案後才寫 ADR。
- ADR 放 `doc/adr/NNNN-<slug>.md`，檔案系統即登錄，不另立索引。
- 架構圖與流程圖（`doc/diagram/*.drawio.svg`）是單一事實來源；決議改動圖面時，同一個 PR 一起更新圖。

## git 慣例

- **一律 push 到分支，進 `main` 只能走 merge。** 不准直接 push main、更不准 force push main。遠端有 branch protection 擋（`ci-passed` 必過、strict、enforce_admins）。
- **一個 issue 一個 PR，一個 PR 只做一件事。** milestone 由多個 sub-issue PR 組成，各自 CI 綠 + codex 確認後合併；只有 milestone 驗收 PR 是人類 gate，不得自動合併。
- **milestone 驗收 PR 要有維護者的核准紀錄才能合併（#187）。** 驗收 PR 貼 `milestone-gate` 標籤；核准＝該 PR 上一則 `author_association` 為 `OWNER`、本文開頭不是 `[claude]`／`[codex]`、內容含「允許合併」的留言。對話裡的同意、agent 對留言的解讀都不算。`.github/workflows/milestone-gate.yml` 以 `lib/approval.sh` 判斷，在 PR head SHA 設 commit status `milestone-gate-approval`（沒貼標籤＝success）。agent 的留言一律以 `[claude]`／`[codex]` 開頭，且絕不寫「允許合併」。已知限制：agent 用維護者的 token 發留言，GitHub 分不出本人與代發，所以這道檢查擋的是「忘了等核准」，擋不住冒名；agent 端的 hook 追蹤於 #190。
- **一個 commit = 一個最小單元或一次完整修復。** 不要把不相干的東西包成一個 commit。
- 語言：issue、PR、設計文件、ADR 用繁體中文；commit message、程式碼與註解用英文。不用 emoji。
- 測試只在 Docker 內跑（`just test ...`）；不在 host 上跑 bats、不在 host 上裝套件。
