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

盒內前提:tmux 與 fish。`box/dev.ini` 自 M3(issue #160)起在 `additional_packages`
裝 `tmux fish`(與 M2 的 `ripgrep fzf` 並列);沒有這兩個套件,終端 profile 的
`distrobox enter dev -- tmux new -A -s main` 會直接失敗。M3 只裝套件;它們的設定
(dotfiles、主題、plugin)留 M5。

## 進盒設定(just box setup / status)

### 選項

`just box setup` 的每個決策都是 **選項(user)> 設定檔裡的 user 選擇 > 預設**:

| 選項 | 值 | 預設 | 意義 |
|------|----|------|------|
| `--auto-enter` | `yes` \| `no` | `yes` | 要不要自動進盒。`no` = 還原 host shell:移除兩個受管區塊,並印出移除了什麼 |
| `--terminal` | `ghostty` \| `none` | PATH 上有 **ghostty 執行檔** -> `ghostty`;否則 `$XDG_CONFIG_HOME/ghostty` 或 `~/.config/ghostty` 存在 -> `ghostty`;都沒有才 `none`(見下方「偵測 ghostty:看執行檔,不是看設定目錄」) | 要管理哪個終端的 profile。`none` = 不寫任何終端 profile,**連 `~/.tmux.conf` 也不寫**(`--tmux host` 的決策照樣存進設定檔,只是 tmux.conf 區塊只服務 ghostty + host 這組;log 會告訴你手動進盒的指令) |
| `--tmux` | `inside` \| `host` | `inside` | tmux 跑在盒內(終端直接 `<distrobox> enter <盒> -- tmux new -A -s main`)或跑在 host(終端跑 `tmux new -A -s main`,tmux 的每個 pane 再進盒:`~/.tmux.conf` 加 `set -g default-command '"<distrobox>" enter <盒>'`)。`<distrobox>` 是 setup 當下解析出的**絕對路徑**,且已 quote(見下方「受管 command 寫絕對路徑」與「受管 command 的 shell quoting」) |
| `--box` | 容器名(`[A-Za-z0-9][A-Za-z0-9_.-]*`) | `dev` | 要進哪個盒 |
| `--distrobox` | 絕對路徑的可執行檔 | PATH 上解析到的那一個 | 要寫進受管 command 的 distrobox。PATH 上找不到、又沒給這個選項時,整次執行被拒絕(見下方「受管 command 寫絕對路徑」) |
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
| `$XDG_CONFIG_HOME/ghostty/config` | 受管區塊:`--tmux inside` 時 `command = '<distrobox>' enter <盒> -- tmux new -A -s main`;`--tmux host` 時 `command = tmux new -A -s main` |
| `~/.tmux.conf` | 受管區塊(只有 `--terminal ghostty` + `--tmux host`):`set -g default-command '"<distrobox>" enter <盒>'` |

受管區塊以兩行標記包住,**一個檔案恰好一個**,重跑時**原地取代**(不會重複、
使用者自己的行原封不動;檔案若不知怎地已有兩個以上區塊,重寫時會先全部移除、
再在第一個區塊的位置寫回恰好一個),`--auto-enter no` 時整塊移除。改寫既有檔案
時保留它原本的權限(mode):

```text
# BEGIN worktool managed block (just box setup; do not edit)
command = '/home/me/.local/bin/distrobox' enter dev -- tmux new -A -s main
# END worktool managed block
```

設定檔裡標 `user` 的選擇會**跨次保留**(`just box setup --box work` 之後,裸
`just box setup` 仍是 `box: work (user)`),要改就再給一次選項;標 `default` 的每次
重算(例如裝了 ghostty 之後,`terminal` 會從 `none (default)` 變成
`ghostty (default)`)。設定檔可以手改;改壞的值(例如 `tmux=sideways`)**不論該 key 的 `.source` 是
`default` 還是 `user`**、也不論命令列有沒有給選項蓋過它,都會在寫任何東西之前被
`[ERROR] <設定檔>: invalid value 'sideways' for tmux (expected inside|host)` 拒絕、
exit 1、不改寫任何檔案;壞的 `.source`(例如 `tmux.source=guess`)同樣拒絕
(`expected default|user`)。檢查是**逐行**的:key 存在但值為空(`tmux=`)是壞值、
不是「沒設定」(`invalid value '' for tmux`);同一 key 重複出現時每一行都檢查,
`tmux=host` 後面藏一行 `tmux=sideways` 一樣被拒絕(讀取時取第一筆,檢查不會)。
`just box status` 做同一個檢查、印同一行 `[ERROR]`、exit 1。

寫入順序:先寫設定檔、再寫 profile(受管區塊)。設定檔在驗證通過後才寫;若之後
某個 profile 寫入失敗,設定檔已經更新、指令 exit 1 --- `just box status` 會把該
區塊報成 `absent`,重跑 `just box setup`(冪等)即可補齊。

### 偵測 ghostty:看執行檔,不是看設定目錄(issue #175)

`terminal` 的預設**先看 `command -v ghostty`**(PATH 上有沒有 ghostty 執行檔),
設定目錄只是**次要訊號**(給「裝了 ghostty 但這條 PATH 看不到」的情況,例如
flatpak)。原因是乾淨機器:剛用 PPA 裝好 `/usr/bin/ghostty`、還沒開過 ghostty,
所以 `~/.config/ghostty` 不存在 —— 舊的「只看設定目錄」規則會判成 `none`、什麼
都不寫,M3 實機驗收 5.2 就卡在這裡。

判斷依據會印出來,而且只在 `terminal` 來自 **default** 時印(使用者用
`--terminal` 指定時不印,因為那不是偵測的結果):

```text
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] terminal detected: ghostty (no ghostty executable on PATH; config dir /home/me/.config/ghostty)
[INFO] terminal detected: none (no ghostty executable on PATH and no ghostty config dir)
```

### 受管 command 寫絕對路徑(issue #175)

受管區塊裡的 distrobox 一律寫 **setup 當下解析到的絕對路徑**,不寫裸
`distrobox`。原因:從桌面啟動的終端繼承的是 **systemd user manager** 的環境,
不是你互動 shell 的 PATH,而 `~/.local/bin`(distrobox 官方安裝腳本的預設位置)
常常不在裡面 —— 裸名字在那裡會直接死在
`/bin/sh: 1: distrobox: not found`。

規則:

- **解析方式**:`command -v distrobox`;只接受**絕對路徑的真實可執行檔**
  (shell function / alias / 相對路徑一律不算,它們寫進 profile 也沒有意義)。
- **symlink 不解參照**:`~/.local/bin/distrobox` 是使用者(或套件管理員)裝上去
  的名字,升級時是**換掉 symlink 後面的目標**;解成目標反而會釘死一個之後可能
  消失的路徑。distrobox 自己的 dispatcher 會對 `$0` 做 realpath 再去找
  `distrobox-*` 兄弟腳本,所以透過 symlink 執行是安全的。
- **解析失敗就拒絕整次執行**:PATH 上找不到 distrobox、又沒給 `--distrobox`
  時,setup 以 `[ERROR]` + exit 1 拒絕,**什麼都不寫**(連設定檔都不寫):

  ```text
  [ERROR] distrobox: not found on PATH - the managed command must name an absolute path a terminal launched from the desktop can run (install distrobox, or pass --distrobox <path>); nothing was written
  ```

  這裡刻意不退回裸名字:那正是實機故障的那份設定,寫下去等於把 bug 交給使用者,
  而「開窗閃一下就關」不會把人導去跑 `just box status`。「先設定、後安裝」的流程
  改用 `--distrobox <絕對路徑>` 明確指定(值必須是絕對路徑的可執行檔,否則
  exit 2)。`--terminal none` 與 `--auto-enter no` 不寫受管 command,因此在沒有
  distrobox 的機器上照樣可用。
- **路徑之後失效**:distrobox 被移走 / 移除後,`just box status` 的
  `distrobox:` 那行會直接說出來(見下方範例)。

### 受管 command 的 shell quoting(issue #175)

兩個受管 body 都是 **shell 原始碼**,不是 argv:ghostty 的 `command` 沒有
`direct:` 前綴時交給 `/bin/sh -c`,tmux 的 `default-command` 同樣是丟給 shell。
所以路徑一律寫成**已 quote 的 shell word**,安裝路徑含空白或 shell 特殊字元
(`$`、反引號、`"`、`\`)時才不會被拆成多個 word、也不會改變命令語意:

| 檔案 | 形狀 | 為什麼 |
|------|------|--------|
| ghostty config | `command = '<路徑>' enter <盒> -- tmux new -A -s main` | 單引號是唯一對任意字元都安全的 POSIX 形式;路徑裡的單引號以 `'\''` 收尾再接回 |
| `~/.tmux.conf` | `set -g default-command '"<路徑>" enter <盒>'` | 外層由 **tmux** 的單引號擁有(tmux 的單引號字串完全字面、沒有跳脫也沒有展開),內層才是 shell 的雙引號,只需跳脫 `\` `` ` `` `$` `"` 四個字元 |

代價是 tmux 的單引號沒有任何跳脫,所以**路徑本身含單引號時無法安全寫進
`~/.tmux.conf`**;這種情況只在 `--tmux host` 下發生,setup 會拒絕而不是寫出一份
讀起來與實際不符的檔案:

```text
[ERROR] distrobox: /home/me/it's here/distrobox holds a single quote, which cannot be encoded safely in the ~/.tmux.conf managed block (use --tmux inside, or install distrobox at a path without one); nothing was written
```

`--tmux inside` 只寫 ghostty 那一塊,單引號可以正常編碼,不受此限。

### 路徑含換行一律拒絕(issue #175 round 2)

shell quoting 能把**任何**文字變成一個合法的 word,但兩個受管檔案都是**逐行**
格式:ghostty 一行一個 key,tmux.conf 也一樣。所以路徑裡只要有換行(LF)或
歸位字元(CR),受管 body 就會被**切成兩行**——ghostty 讀到第二行不認得的 key,
整份 config 以 `unknown field` 被拒,而 setup 早就寫完並 exit 0 了。這正是
round 1 拿掉的「裸名字 fallback」同一類問題:**已知壞掉的半套寫入**。

沒有任何編碼能同時滿足兩邊,所以這種路徑直接拒絕:

- 規則同時適用於 `--distrobox` 給的路徑與 PATH 上自動解析到的路徑——這條限制
  講的是**受管檔案裝得下什麼**,不是使用者從哪裡給的。
- 拒絕發生在**任何檔案被寫之前**(連狀態檔都不寫),exit 1。
- 診斷訊息把控制字元顯示成 `\n` / `\r`,錯誤本身才不會也被切成兩行。

```text
[ERROR] distrobox: /home/me/weird\ndir/distrobox holds a newline or carriage return, which cannot be written into the line-based ghostty config or ~/.tmux.conf (install distrobox at a path without one); nothing was written
```

### 範例 log

預設(PATH 上有 `/usr/bin/ghostty`,distrobox 在 `~/.local/bin`):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] tmux: inside (default)
[INFO] box: dev (default)
[INFO] distrobox: /home/me/.local/bin/distrobox (absolute path written into the managed command)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] wrote: /home/me/.config/ghostty/config (managed block: command = '/home/me/.local/bin/distrobox' enter dev -- tmux new -A -s main)
```

再跑一次是冪等的(區塊已是最新就不重寫):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] tmux: inside (default)
[INFO] box: dev (default)
[INFO] distrobox: /home/me/.local/bin/distrobox (absolute path written into the managed command)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] unchanged: /home/me/.config/ghostty/config (managed block already up to date)
```

tmux 放 host、進 `work` 盒:

```text
$ just box setup --tmux host --box work
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] tmux: host (user)
[INFO] box: work (user)
[INFO] distrobox: /home/me/.local/bin/distrobox (absolute path written into the managed command)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] wrote: /home/me/.config/ghostty/config (managed block: command = tmux new -A -s main)
[INFO] wrote: /home/me/.tmux.conf (managed block: set -g default-command '"/home/me/.local/bin/distrobox" enter work')
```

沒有支援的終端(`terminal: none`):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: none (default)
[INFO] terminal detected: none (no ghostty executable on PATH and no ghostty config dir)
[INFO] tmux: inside (default)
[INFO] box: dev (default)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] terminal profile: none (nothing written; enter by hand: distrobox enter dev)
```

(這行手動指令刻意用裸名字:它是給你在自己的互動 shell 裡打的,那條 PATH 找得到。)

PATH 上沒有 distrobox 時(拒絕,什麼都不寫):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] tmux: inside (default)
[INFO] box: dev (default)
[ERROR] distrobox: not found on PATH - the managed command must name an absolute path a terminal launched from the desktop can run (install distrobox, or pass --distrobox <path>); nothing was written
$ echo $?
1
```

先設定、後安裝時明確指定:

```text
$ just box setup --distrobox /opt/distrobox/bin/distrobox
...
[INFO] distrobox: /opt/distrobox/bin/distrobox (--distrobox; absolute path written into the managed command)
[INFO] wrote: /home/me/.config/ghostty/config (managed block: command = '/opt/distrobox/bin/distrobox' enter dev -- tmux new -A -s main)
```

還原 host shell(印出還原了什麼;`--auto-enter no` 不寫受管 command,所以不需要
也不解析 distrobox):

```text
$ just box setup --auto-enter no
[INFO] auto-enter: no (user)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] tmux: host (user)
[INFO] box: work (user)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] removed: /home/me/.config/ghostty/config (managed block: command = tmux new -A -s main)
[INFO] removed: /home/me/.tmux.conf (managed block: set -g default-command '"/home/me/.local/bin/distrobox" enter work')
```

沒東西可還原時兩個檔案都會說明:`[INFO] nothing to remove: /home/me/.config/ghostty/config (no managed block)`。

`--dry-run` 只印不寫:

```text
$ just box setup --dry-run --tmux host
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] tmux: host (user)
[INFO] box: dev (default)
[INFO] distrobox: /home/me/.local/bin/distrobox (absolute path written into the managed command)
[INFO] dry-run: would write /home/me/.config/worktool/config
[INFO] dry-run: would write /home/me/.config/ghostty/config (managed block: command = tmux new -A -s main)
[INFO] dry-run: would write /home/me/.tmux.conf (managed block: set -g default-command '"/home/me/.local/bin/distrobox" enter dev')
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
distrobox: /home/me/.local/bin/distrobox (recorded in a managed block: runnable)
```

最後一行是 issue #175 的「可讀錯誤」:受管 command 寫的是絕對路徑,所以 distrobox
之後被移走 / 移除 / 升級掉時,這裡會直接講清楚,而不是讓你開窗看到一閃而過的
`not found`:

```text
distrobox: /home/me/.local/bin/distrobox (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)
distrobox: distrobox (recorded in a managed block: a bare name, not an absolute path - a terminal launched from the desktop may not find it; re-run: just box setup)
distrobox: /usr/bin/distrobox (on PATH; no managed block records one)
distrobox: not found on PATH (install distrobox, then re-run: just box setup)
```

第二行是**舊版**留下來的形狀:現在的 setup 不會再寫裸名字(解析不到就拒絕),
但使用者機器上可能還有先前寫入的區塊,所以報告仍然認得並指出它。

還沒跑過 `setup` 時第一行會是
`config: /home/me/.config/worktool/config (not found - defaults shown; run: just box setup)`,
後面照樣列出預設值(全部 `(default)`)、兩個檔案的區塊狀態與 `distrobox:` 那行,
報告永遠不會是空的。

## 測試對應

四層都在 Docker 內跑、都用**暫時 HOME**(每個案例自己的 `BATS_TEST_TMPDIR`),
絕不讀寫真實 home。只有「偵測」會碰到執行檔:自 issue #175 起 setup 會
`command -v ghostty` / `command -v distrobox`,所以相關案例在自己的 tmpdir 裡放
一支假的、再把那個目錄接到 PATH 前面(沒有任何測試需要**真的** distrobox 或
tmux 跑起來;真 ghostty 的部分仍然只在 integration 的 ghostty 組):

- 單元:`test/unit/setup_spec.bats` —— 預設值與每行 `[INFO]` log、user 覆蓋標
  `(user)`、`--key=value`、user 選擇跨次保留 / default 重算、ghostty 區塊只寫一次且
  重跑冪等、區塊原地取代且前後的使用者行都在、`--tmux host` 寫 `~/.tmux.conf`、
  切回 `inside` 移除並回報、`--auto-enter no` 移除兩個區塊並逐一回報、沒東西可移
  也說明、`--dry-run` 什麼都不寫、`--help` / 未知選項 / 無效值 / 缺值 exit 2、設定檔
  壞值 exit 1;另有 issue #175 的兩組:ghostty 執行檔在 PATH 上但沒有設定目錄時
  預設 `ghostty`、設定目錄單獨存在時的次要訊號、兩者皆無時 `none`(三種
  `terminal detected:` 依據各一案)、受管 command 寫絕對路徑、symlink 保留連結
  路徑而非目標、以及把寫出來的
  command 丟進 `env -i PATH=/usr/bin:/bin /bin/sh -c` 真的執行(對照案例先證明
  該環境用裸名字必定 127);再加 issue #175 round 1 的一組:PATH 上沒有 distrobox
  時整次執行被拒絕且什麼都沒寫(`--dry-run` 亦同)、`--distrobox` 補位與它的三種
  無效值、`--terminal none` / `--auto-enter no` 在沒有 distrobox 的機器上照常可用、
  安裝路徑含空白 / `$` 與反引號 / 雙引號三種 quoting 案例(都實際執行寫出來的
  command,並斷言 `$(...)` 與反引號的 sentinel 檔沒有被建立)、tmux `default-command`
  的雙層引用,以及路徑含單引號時 `--tmux host` 被拒絕、`--tmux inside` 仍可用;
  `test/unit/status_spec.bats` —— 無設定檔的預設報告、
  有設定檔的逐行輸出與順序、缺 key 回預設、`XDG_CONFIG_HOME`、只印 stdout、
  `--help` / 未知選項,以及 `distrobox:` 那行的四種狀態(runnable / NOT
  RUNNABLE / 裸名字 / PATH 上找不到)與三種記錄形狀的解碼(單引號、tmux 雙層
  引用、以及舊版沒有 quote 的絕對路徑);
  `test/unit/justfile_spec.bats` —— `just box setup` / `just box status` 原封轉發
  argv、真腳本在暫時 HOME 下的 `--dry-run` / `status`、壞選項由腳本而非 justfile
  拒絕。三個都是 `test.sh` 的**必要 spec**。
- 整合:`test/integration/setup_spec.bats` —— `setup` 之後 `status` 的來回:host
  變體兩個區塊都 present、切回 inside 後 tmux.conf 區塊消失、`--auto-enter no` 後兩個
  都 absent、`--dry-run` 後什麼都沒存、setup 的 log 與 status 的報告逐行一致;
  issue #175 再加三案:setup 真的寫出來的 ghostty command 與 tmux
  `default-command`(各自先從**已 quote 的**形狀解回來)在 `env -i
  PATH=/usr/bin:/bin` 下跑得起來(對照案例證明同一環境下裸名字是 127
  `not found`),以及 distrobox 被刪掉之後 `status` 的 `distrobox:` 那行從
  `runnable` 變成 `NOT RUNNABLE`。
  `test/integration/ghostty_config_spec.bats`(ghostty 組)—— 真的 ghostty
  `+show-config` 解析出的生效 `command` 是**絕對路徑**(並 refute 裸名字那一行),
  絕對路徑版本仍被 `+validate-config` 接受,PATH 上沒有 distrobox 時整次執行被
  拒絕(不再寫任何檔案),以及安裝路徑含空白 / `$(...)` / 雙引號時,把**真 ghostty
  回報的生效值**丟進 `/bin/sh -c` 仍只會執行那一個執行檔(sentinel 檔不存在)。
- 系統 / 驗收:進盒延遲量測與達標(< 300ms;#22 / #150)與效能驗收測試(#23)是
  M3 的其他 issue;實機「開新終端主觀順暢」留在 [`acceptance.md`](acceptance.md)
  的人類清單。
