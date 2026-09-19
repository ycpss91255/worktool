# 終端自動進盒

本文件說明 worktool 的「終端自動進盒」機制:開一個新終端就直接進到共用的
dev 盒。狀態:M3(終端自動進盒 + 效能)。整體設計與治理見
[`design.md`](design.md);盒子清單與 assemble 見 [`manifest.md`](manifest.md);
目錄結構與 `just` 介面見 [`structure.md`](structure.md)。

## 決策:進盒機制不釘死,由 user 選,預設直接進盒,每個決策都印 log

維護者決策(2026-09-19,issue #21):進盒機制**不釘死**,安裝 / 設定時由 user
選擇;預設 = 直接進盒;所有決策都要印 log 並可查。研究依據(#22):**終端
profile** 的邊界最乾淨(不影響 ssh、cron、非互動 shell、scp);host shell rc 裡
`exec distrobox enter` 會讓 ssh / 非互動 shell 全部踩雷,**不採用**。

落地成兩個 `box` 動詞:

| 指令 | 做什麼 |
|------|--------|
| `just box setup [選項]` | 決定「要不要自動進盒、用哪個終端、tmux 放哪、進哪個盒」,寫進**單一設定檔**,並寫入(或移除)終端 profile 的**受管區塊** |
| `just box status` | 印出目前生效的決策、每個決策的來源(`default` / `user`)、以及受管區塊在不在 |

只動 HOME / `XDG_CONFIG_HOME` 底下的檔案;不裝任何東西、不動 host 的 shell rc、
不需要 root。

## 進盒設定(just box setup / status)

### 選項

`just box setup` 的每個決策都是 **選項(user)> 設定檔裡的 user 選擇 > 預設**:

| 選項 | 值 | 預設 | 意義 |
|------|----|------|------|
| `--auto-enter` | `yes` \| `no` | `yes` | 要不要自動進盒。`no` = 還原 host shell:移除兩個受管區塊,並印出移除了什麼 |
| `--terminal` | `ghostty` \| `none` | `$XDG_CONFIG_HOME/ghostty` 或 `~/.config/ghostty` 存在 -> `ghostty`,否則 `none` | 要管理哪個終端的 profile。`none` = 不寫任何終端 profile(log 會告訴你手動進盒的指令) |
| `--tmux` | `inside` \| `host` | `inside` | tmux 跑在盒內(終端直接 `distrobox enter <盒> -- tmux new -A -s main`)或跑在 host(終端跑 `tmux new -A -s main`,tmux 的每個 pane 再進盒:`~/.tmux.conf` 加 `set -g default-command "distrobox enter <盒>"`) |
| `--box` | 容器名(`[A-Za-z0-9][A-Za-z0-9_.-]*`) | `dev` | 要進哪個盒 |
| `--dry-run` | — | — | 印出每個決策與每個會寫 / 會移除的檔案,**什麼都不寫**(連設定檔都不寫) |
| `-h`, `--help` | — | — | usage |

`--key=value` 寫法也接受(`--tmux=host`)。未知選項、無效的值、缺值都由
`setup.sh` 自己拒絕:`setup.sh: unknown option '--bogus' (see --help)` /
`setup.sh: invalid value 'kitty' for --terminal (expected ghostty|none) (see --help)`
/ `setup.sh: --box requires a value (see --help)`,exit 2,什麼都還沒動。
`just box status` 只有 `--help`;未知選項同樣是 `status.sh: unknown option ...`、
exit 2。

### 檔案(全部從 HOME / `XDG_CONFIG_HOME` 推出)

| 檔案 | 內容 |
|------|------|
| `$XDG_CONFIG_HOME/worktool/config`(預設 `~/.config/worktool/config`) | **單一設定檔**:每個決策一行 `key=value` 加一行 `key.source=default\|user`(`auto-enter`、`terminal`、`tmux`、`box`) |
| `$XDG_CONFIG_HOME/ghostty/config` | 受管區塊:`--tmux inside` 時 `command = distrobox enter <盒> -- tmux new -A -s main`;`--tmux host` 時 `command = tmux new -A -s main` |
| `~/.tmux.conf` | 受管區塊(只有 `--tmux host`):`set -g default-command "distrobox enter <盒>"` |

受管區塊以兩行標記包住,**一個檔案最多一個**,重跑時**原地取代**(不會重複、
使用者自己的行原封不動),`--auto-enter no` 時整塊移除:

```text
# BEGIN worktool managed block (just box setup; do not edit)
command = distrobox enter dev -- tmux new -A -s main
# END worktool managed block
```

設定檔裡標 `user` 的選擇會**跨次保留**(`just box setup --box work` 之後,裸
`just box setup` 仍是 `box: work (user)`),要改就再給一次選項;標 `default` 的每次
重算(例如裝了 ghostty 之後,`terminal` 會從 `none (default)` 變成
`ghostty (default)`)。設定檔可以手改;改壞的值(例如 `tmux=sideways`)會被
`[ERROR] <設定檔>: invalid value 'sideways' for tmux (expected inside|host)` 拒絕、
exit 1、不改寫任何檔案。

### 範例 log

預設(有 `~/.config/ghostty`):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] tmux: inside (default)
[INFO] box: dev (default)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] wrote: /home/me/.config/ghostty/config (managed block: command = distrobox enter dev -- tmux new -A -s main)
```

再跑一次是冪等的(區塊已是最新就不重寫):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] tmux: inside (default)
[INFO] box: dev (default)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] unchanged: /home/me/.config/ghostty/config (managed block already up to date)
```

tmux 放 host、進 `work` 盒:

```text
$ just box setup --tmux host --box work
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] tmux: host (user)
[INFO] box: work (user)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] wrote: /home/me/.config/ghostty/config (managed block: command = tmux new -A -s main)
[INFO] wrote: /home/me/.tmux.conf (managed block: set -g default-command "distrobox enter work")
```

沒有支援的終端(`terminal: none`):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: none (default)
[INFO] tmux: inside (default)
[INFO] box: dev (default)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] terminal profile: none (nothing written; enter by hand: distrobox enter dev)
```

還原 host shell(印出還原了什麼):

```text
$ just box setup --auto-enter no
[INFO] auto-enter: no (user)
[INFO] terminal: ghostty (default)
[INFO] tmux: host (user)
[INFO] box: work (user)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] removed: /home/me/.config/ghostty/config (managed block: command = tmux new -A -s main)
[INFO] removed: /home/me/.tmux.conf (managed block: set -g default-command "distrobox enter work")
```

沒東西可還原時兩個檔案都會說明:`[INFO] nothing to remove: /home/me/.config/ghostty/config (no managed block)`。

`--dry-run` 只印不寫:

```text
$ just box setup --dry-run --tmux host
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] tmux: host (user)
[INFO] box: dev (default)
[INFO] dry-run: would write /home/me/.config/worktool/config
[INFO] dry-run: would write /home/me/.config/ghostty/config (managed block: command = tmux new -A -s main)
[INFO] dry-run: would write /home/me/.tmux.conf (managed block: set -g default-command "distrobox enter dev")
```

查目前生效的決策(印到 stdout,沒有 log 標籤,可直接 grep):

```text
$ just box status
config: /home/me/.config/worktool/config
auto-enter: yes (default)
terminal: ghostty (default)
tmux: host (user)
box: work (user)
ghostty: /home/me/.config/ghostty/config (managed block: present)
tmux.conf: /home/me/.tmux.conf (managed block: absent)
```

還沒跑過 `setup` 時第一行會是
`config: /home/me/.config/worktool/config (not found - defaults shown; run: just box setup)`,
後面照樣列出預設值(全部 `(default)`)與兩個檔案的區塊狀態,報告永遠不會是空的。

## 測試對應

四層都在 Docker 內跑、都用**暫時 HOME**(每個案例自己的 `BATS_TEST_TMPDIR`),
絕不讀寫真實 home;不需要 distrobox / ghostty / tmux 執行檔(只管理檔案):

- 單元:`test/unit/setup_spec.bats` —— 預設值與每行 `[INFO]` log、user 覆蓋標
  `(user)`、`--key=value`、user 選擇跨次保留 / default 重算、ghostty 區塊只寫一次且
  重跑冪等、區塊原地取代且前後的使用者行都在、`--tmux host` 寫 `~/.tmux.conf`、
  切回 `inside` 移除並回報、`--auto-enter no` 移除兩個區塊並逐一回報、沒東西可移
  也說明、`--dry-run` 什麼都不寫、`--help` / 未知選項 / 無效值 / 缺值 exit 2、設定檔
  壞值 exit 1;`test/unit/status_spec.bats` —— 無設定檔的預設報告、有設定檔的逐行
  輸出與順序、缺 key 回預設、`XDG_CONFIG_HOME`、只印 stdout、`--help` / 未知選項;
  `test/unit/justfile_spec.bats` —— `just box setup` / `just box status` 原封轉發
  argv、真腳本在暫時 HOME 下的 `--dry-run` / `status`、壞選項由腳本而非 justfile
  拒絕。三個都是 `test.sh` 的**必要 spec**。
- 整合:`test/integration/setup_spec.bats` —— `setup` 之後 `status` 的來回:host
  變體兩個區塊都 present、切回 inside 後 tmux.conf 區塊消失、`--auto-enter no` 後兩個
  都 absent、`--dry-run` 後什麼都沒存、setup 的 log 與 status 的報告逐行一致。
- 系統 / 驗收:進盒延遲量測與達標(< 300ms;#22 / #150)與效能驗收測試(#23)是
  M3 的其他 issue;實機「開新終端主觀順暢」留在 [`acceptance.md`](acceptance.md)
  的人類清單。
