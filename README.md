# worktool

以 distrobox 為基礎的開發環境。開發用的 CLI/TUI 工具全部住在一個共用的
distrobox「dev 盒」裡,使用者直接活在盒子內(終端自動進盒);host 只保留
驅動、docker、snapd、桌面 GUI app(以 install script 形式)與容器框架。設定檔
留在共用的 HOME。

這是 `init_ubuntu`(ycpss91255/initialization)的重設計繼任者,為新的大版本。

狀態:M2(盒子清單格式 + 最小 assemble)。設計與 milestone 計畫見
[`doc/design.md`](doc/design.md);清單格式、assemble 流程與從 clone 到 assemble
的完整驗證步驟見 [`doc/manifest.md`](doc/manifest.md);目錄結構見
[`doc/structure.md`](doc/structure.md)。

## 前置需求

- **docker**:目前使用者可直接執行(`docker run --rm hello-world` 能成功),
  不需要 `sudo`。
- **just**:使用者介面(下方)。M4 host bootstrap 起由 install script 一併安裝;
  在那之前請自行安裝。
- host **不需要** distrobox:測試用的 distrobox 已鎖定版本、烘進 Docker 測試映像;
  只有 `just assemble` 在 host 上真的建盒時才需要。

## 使用方式

`just` 是 worktool 的使用者通用介面:所有可執行的動作都是 `just <動詞> [受詞]`,
腳本是實作、不是介面(決策見 [`doc/design.md`](doc/design.md)「決策」)。

| 指令 | 說明 |
|------|------|
| `just` | 列出所有 recipe |
| `just build` | 建置測試映像(選用;gate 會按需自動建) |
| `just lint` | ShellCheck gate(Docker 內) |
| `just test [tier]` | 跑測試;tier = `unit` / `integration` / `system` / `system-real` / `acceptance` / `all`(預設 `all`;`system-real` 最後跑:docker-in-docker、`--privileged`、慢)。無效的 tier 會清楚報錯、exit 1、什麼都不跑 |
| `just check` | lint + test all(= CI 跑的內容) |
| `just selfcheck` | 交付自檢(`script/selfcheck.sh`) |
| `just assemble [mode] [file]` | 從清單 assemble dev 盒;mode = `run`(預設,在 host 上真的呼叫 distrobox)/ `dry-run`(只印出 distrobox 指令、不執行);file 預設 `box/dev.ini`(例:`just assemble dry-run box/other.ini`) |

所有測試都在 Docker 內執行,host 不安裝任何套件。每個 gate 的預期輸出與
沒有 `just` 時的底層備援指令,見 [`doc/manifest.md`](doc/manifest.md)
「如何人工驗證」。

文件語言:設計文件(PRD / ADR / 計畫等 user 會看到的)以 zh-TW 撰寫;commit
message、PR 內文、程式碼與註解以英文撰寫。
