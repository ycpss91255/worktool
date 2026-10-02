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

落地成三個 `box` 動詞:

| 指令 | 做什麼 |
|------|--------|
| `just box setup [選項]` | 決定「要不要自動進盒、用哪個終端、進哪個盒」,寫進**單一設定檔**,並寫入(或移除)終端 profile 的**受管區塊** |
| `just box status` | 印出目前生效的決策、每個決策的來源(`default` / `user`)、受管區塊在不在,以及每一項 user config 連結的狀態(#199) |
| `just box enter [選項]` | 手動進盒;盒子第一次啟動時顯示進度、log 與逾時(見下方「首次啟動的進度」) |

只動 HOME / `XDG_CONFIG_HOME` 底下的檔案;不裝任何東西、不動 host 的 shell rc、
不需要 root。

盒內前提:fish 與 tmux。`box/dev.ini` 自 M3(issue #160)起在 `additional_packages`
裝 `tmux fish`(與 M2 的 `ripgrep fzf` 並列)。M3 只裝套件;它們的設定
(dotfiles、主題、plugin)留 M5。

## 決策:終端不自動開 tmux;盒內的 tmux 用盒子自己的 server(issue #179)

M3 實機驗收(PR #157)出現**假成功**:受管命令原本是
`'<distrobox>' enter dev -- tmux new -A -s main`,而 `distrobox-create` 固定把
host 的 `/tmp` 掛進盒內(`--volume /tmp:/tmp`),tmux 的預設 socket
(`/tmp/tmux-<uid>/default`)因此盒內外共用。host 上已經有 tmux server 時,`-A`
直接附著到 host 的 session:使用者看到 fish prompt、以為進了盒,其實在 host。
CI 沒抓到,因為測試環境沒有既有的 host tmux server。維護者定案(2026-09-29
grilling)的目標行為:

1. **開終端**:`ghostty -> enter.sh wrapper -> '<distrobox>' enter dev -> 盒內 fish`(盒內使用者的登入
   shell)。不自動啟動、不自動附著 tmux;**沒有**任何 tmux 相關的決策或選項
   (`--tmux inside|host` 移除,setup 不再寫 `tmux` 這個 key,舊 key 保留為非受管資料)。
2. **盒內自己開 tmux**:得到**盒子自己的 tmux server**,永遠不連到 host 的 server
   或 session。機制在 distrobox 建立容器時就定好:`box/dev.ini` 以 `additional_flags` 設容器環境
   變數 `TMUX_TMPDIR=${HOME}/dev-box/.cache/tmux`(distrobox 建立容器時展開;在 #196 的盒子 HOME
   底下),盒內**任何方式**啟動的 tmux(互動 shell、`distrobox enter dev -- tmux`)
   都繼承它;`init_hooks` 在每次盒子啟動時以盒內使用者身分建立該目錄(mode
   0700),並在之後明確 `chown` 成盒內使用者、`chmod 0700`(`mkdir -p -m` 不會改正
   已存在目錄的權限與擁有者)——目錄不存在時 tmux 會**無聲**退回 `/tmp`,所以不能
   省。不採用「規定使用
   `tmux -L`」這種靠記憶的做法。依據:不變量「host 與盒子互不干擾」(#200);共用
   `/tmp` 的問題見 distrobox upstream issue #824。
   從 **host 的 tmux pane 裡**進盒也一樣。這個洩漏在**環境**,不在執行檔:
   `distrobox enter` 會把呼叫端的環境變數整批帶進盒內(鎖定版 1.8.2.5 的
   `distrobox-enter` 把 `printenv` 逐一轉成 `docker exec --env=`,只跳過 HOME、
   PATH、PWD 等固定幾個),`TMUX`(指向 host server 的 socket)與 `TMUX_PANE`
   也在其中,而 tmux 先看 `TMUX` 才看 `TMUX_TMPDIR`。任何包在 tmux 執行檔外面的
   wrapper 都能被「直接執行真執行檔」繞過(codex 第 1–4 輪,PR #232:
   `distrobox enter dev -- <真 tmux>` 時盒內沒有任何 shell 介入),所以 worktool
   不包 tmux(盒內的 `/usr/bin/tmux` 就是套件原本的執行檔),而是在環境建立的
   地方把它拿掉,兩道:
   - **第一道,`distrobox-enter` 本身**:`just box setup` 每次執行(不論
     auto-enter / terminal 怎麼選)都在 distrobox 自己的使用者設定
     `$XDG_CONFIG_HOME/distrobox/distrobox.conf` 維護一個受管區塊。
     `distrobox-enter` 在讀參數、組 `exec` 請求**之前**就以 shell source 這個檔,
     區塊裡的一行在這次要進的是 **worktool 管理的那個盒**(`just box setup` 的
     `box` 決策,預設 `dev`)時 `unset TMUX TMUX_PANE`,被 unset 的變數就不會被
     轉成 `--env`;**其他任何盒子**都維持上游行為。「要進哪個盒」照
     `distrobox-enter` 自己的選項文法判定(鎖定版 1.8.2.5),不是「某個參數剛好
     等於盒名」(codex 第 4 輪):`-n` / `--name` 與 `-a` / `--additional-flags`
     帶值,只有 `-n` / `--name` 的值是盒名;其餘選項都不帶值;每個位置參數都會
     設定盒名,所以**最後一個**為準;`--`、`-e`、`--exec` 之後是命令;命令列完全
     沒給盒名時才看 `DBX_CONTAINER_NAME`。該行不動 `distrobox-enter` 的
     `"$@"`,用完的變數也 unset。每次寫入 / 未變都照其他受管檔案的格式記錄
     (`[INFO] wrote: ...` / `[INFO] unchanged: ...`,`--dry-run` 印
     `would write`),這個檔案不會被移除。上游沒有可設定
     的跳過清單、也沒有 `--unset`;`--additional-flags "--env TMUX="` 仍會帶進
     空的 `TMUX`;只在受管命令前面加 `env -u TMUX` 則只顧得到那一條命令——所以
     選 distrobox.conf。
   - **第二道,盒內的登入 shell**:`init_hooks` 把
     [`box/tmux-env.sh`](../box/tmux-env.sh)(`/etc/profile.d`,sh / bash)與
     [`box/tmux-env.fish`](../box/tmux-env.fish)(`/etc/fish/conf.d`,fish)裝進盒內:
     `TMUX` 指向盒子自己 `TMUX_TMPDIR` 底下的 socket(盒子自己 server 的 pane)才
     保留,否則連同 `TMUX_PANE` 丟掉;`TMUX_TMPDIR` 空也丟。給沒讀到第一道的情況
     (另一個 `XDG_CONFIG_HOME`、使用者刪了該區塊)。

   涵蓋的進盒路徑(system-real 以矩陣驗證,見下方「測試」):受管的 ghostty
   命令、`distrobox enter dev`、`distrobox enter dev -- <命令>`、
   `distrobox enter dev -- <真 tmux>`、盒內的登入 shell(`sh -l`、`fish -l`)——前四種
   都經過 `distrobox-enter`(第一道),登入 shell 另有第二道。不涵蓋:不經
   distrobox、自己下 `docker exec -e TMUX=... dev tmux`(`docker exec` 本身不帶
   呼叫端環境,這是刻意把 host 的 socket 傳進去);以及沒跑過 `just box setup`
   (或讀不到該 distrobox.conf)時、`-- <命令>` 不經登入 shell 的路徑。
3. **tmux 設定**:worktool **不讀也不寫** host 的 `~/.tmux.conf`;tmux 設定屬於工具
   設定,放在盒子自己的 HOME(#196,M5)。

舊版留下的東西:設定檔裡的 `tmux=` / `tmux.source=` 行**不再是決策**——不報告、
不當成壞值拒絕,`just box setup` 更新時保留為非受管 key;`~/.tmux.conf` 裡若有
舊版寫的受管區塊,worktool 不會動它,請自行刪除(M3 尚未發布,只有驗收機器上會有)。

## 進盒設定(just box setup / status)

### 選項

`just box setup` 的每個決策都是 **選項(user)> 設定檔裡的 user 選擇 > 預設**:

| 選項 | 值 | 預設 | 意義 |
|------|----|------|------|
| `--auto-enter` | `yes` \| `no` | `yes` | 要不要自動進盒。`no` = 還原 host shell:移除受管區塊,並印出移除了什麼 |
| `--terminal` | `ghostty` \| `none` | PATH 上有 **ghostty 執行檔** -> `ghostty`;否則 `$XDG_CONFIG_HOME/ghostty` 或 `~/.config/ghostty` 存在 -> `ghostty`;都沒有才 `none`(見下方「偵測 ghostty:看執行檔,不是看設定目錄」) | 要管理哪個終端的 profile。`ghostty` = 受管 command `'<repo>/script/box/enter.sh' --distrobox '<distrobox>' --box '<盒>'`,得到盒內的登入 shell(fish),後面不接 tmux;`<distrobox>` 是 setup 當下解析出的**絕對路徑**,且已 quote(見下方「受管 command 寫絕對路徑」與「受管 command 的 shell quoting」)。`none` = 不寫任何終端 profile(決策照樣存進設定檔;log 會告訴你手動進盒的指令) |
| `--box` | 容器名(`[A-Za-z0-9][A-Za-z0-9_.-]*`) | `dev` | 要進哪個盒 |
| `--distrobox` | 絕對路徑的可執行檔 | PATH 上解析到的那一個 | 要寫進受管 command 的 distrobox。PATH 上找不到、又沒給這個選項時,整次執行被拒絕(見下方「受管 command 寫絕對路徑」) |
| `--dry-run` | — | — | 印出每個決策與每個會寫 / 會移除的檔案,**什麼都不寫**(連設定檔都不寫) |
| `-h`, `--help` | — | — | usage |

`--key=value` 寫法也接受(`--box=work`)。未知選項、無效的值、缺值都由
`setup.sh` 自己拒絕:`setup.sh: unknown option '--bogus' (see --help)` /
`setup.sh: invalid value 'kitty' for --terminal (expected ghostty|none) (see --help)`
/ `setup.sh: --box requires a value (see --help)`,exit 2,什麼都還沒動。
`--tmux` 已移除(issue #179),給了就是 `setup.sh: unknown option '--tmux' (see --help)`。
`just box status` 只有 `--help`;未知選項同樣是 `status.sh: unknown option ...`、
exit 2。

### 檔案(全部從 HOME / `XDG_CONFIG_HOME` 推出)

| 檔案 | 內容 |
|------|------|
| `$XDG_CONFIG_HOME/worktool/config`(預設 `~/.config/worktool/config`) | **單一設定檔**:每個決策一行 `key=value` 加一行 `key.source=default\|user`(`auto-enter`、`terminal`、`box`);另有 assemble 寫的 `home` / `home.source` 與使用者的 `link=`。讀寫一律經過 `lib/config.sh`,setup 只就地更新自己的 key,其他行逐位元組保留 |
| `$XDG_CONFIG_HOME/ghostty/config.ghostty`（已存在時），否則 legacy `ghostty/config` | 受管區塊:`command = '<repo>/script/box/enter.sh' --distrobox '<distrobox>' --box '<盒>'` |
| `$XDG_CONFIG_HOME/distrobox/distrobox.conf` | 受管區塊(**每次**都寫,`--auto-enter no` 也保留):進 `<盒>` 時 `unset TMUX TMUX_PANE` 的一行 shell,`distrobox-enter` 組 `exec` 請求前 source 它(issue #179,見上方「決策」第 2 點) |

Ghostty 選檔規則（#173）：`config.ghostty` 已存在就用它，否則用 legacy
`config`；兩檔都不存在時只建立 legacy，永不主動建立 `config.ghostty`。
setup 以 `[INFO] ghostty config: <檔案> (config.ghostty exists)` 或
`(config.ghostty absent; legacy fallback)` 說明選擇。
兩檔都先檢查標記，任一檔標記不完整或兩檔合計超過一個受管區塊就拒絕，
任何檔案都不寫，訊息點名兩檔。只有一個區塊且在非目標檔時，啟用會先組好
兩份內容再依序寫入，只從原檔剝除受管區塊，印出
`[INFO] moved: <原檔> -> <目標檔> (managed block)`；寫入失敗會明確回報，
兩檔不是單一交易，第二次寫入失敗時需檢查兩檔。停用從實際有區塊的檔案移除，
重跑已完成的啟用回報 `unchanged`，已停用則回報 `nothing to remove`。
status 使用相同選檔規則，另列出已存在的另一檔，顯示實際區塊所在位置。
選用 `config.ghostty` 且 host 的 `ghostty +version` 低於 1.3.0 時印出
`[WARN]`，因為舊版不讀此檔；找不到 ghostty 執行檔就跳過版本檢查。

`~/.tmux.conf` 不在清單裡:worktool 不讀也不寫它(issue #179)。

受管區塊以兩行標記包住,**一個檔案恰好一個**,重跑時**原地取代**(不會重複、
使用者自己的行原封不動),`--auto-enter no` 時整塊移除。改寫既有檔案時保留它原本的
權限(mode)。**標記不完整時拒絕改寫**(issue #179,codex 第 4 輪):任何受管檔案
(ghostty 設定、distrobox.conf)的標記只要不是「沒有標記」或「恰好一組完整的
BEGIN ... END」——只有 BEGIN、只有 END、END 在 BEGIN 前、BEGIN 套 BEGIN、兩個
以上區塊、標記行前後多了任何文字——`just box setup` 在**寫任何東西之前**(連設定檔
都不寫、`--dry-run` 亦同)就以 exit 1 拒絕,訊息是
`[ERROR] <檔案>: malformed worktool managed block markers: <問題與行號>; nothing
was written (fix or remove the markers, then re-run: just box setup)`;
`just box status` 那一行顯示 `MALFORMED - <問題與行號>`。原因:區塊的讀寫以標記為準,
舊版遇到孤立的 BEGIN 會把它之後到檔尾的使用者內容一併吃掉。舊版(#161)對兩個以上
區塊的處理是合併成一個,現在一律拒絕,由使用者自己決定留哪一個。正常的區塊長這樣:

```text
# BEGIN worktool managed block (just box setup; do not edit)
command = '/home/me/worktool/script/box/enter.sh' --distrobox '/home/me/.local/bin/distrobox' --box 'dev'
# END worktool managed block
```

設定檔裡標 `user` 的選擇會**跨次保留**(`just box setup --box work` 之後,裸
`just box setup` 仍是 `box: work (user)`),要改就再給一次選項;標 `default` 的每次
重算(例如裝了 ghostty 之後,`terminal` 會從 `none (default)` 變成
`ghostty (default)`)。設定檔可以手改;改壞的值(例如 `terminal=sideways`)**不論該 key 的 `.source` 是
`default` 還是 `user`**、也不論命令列有沒有給選項蓋過它,都會在寫任何東西之前被
`[ERROR] <設定檔>: invalid value 'sideways' for terminal (expected ghostty|none)` 拒絕、
exit 1、不改寫任何檔案;壞的 `.source`(例如 `terminal.source=guess`)同樣拒絕
(`expected default|user`)。檢查是**逐行**的:key 存在但值為空(`terminal=`)是壞值、
不是「沒設定」(`invalid value '' for terminal`);同一 key 重複出現時每一行都檢查,
`terminal=none` 後面藏一行 `terminal=sideways` 一樣被拒絕(讀取時取第一筆,檢查不會)。
`just box status` 做同一個檢查、印同一行 `[ERROR]`、exit 1。

寫入順序:先寫設定檔、再寫 profile(受管區塊)。設定檔在驗證通過後才寫;若之後
profile 寫入失敗,設定檔已經更新、指令 exit 1 --- `just box status` 會把該
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

受管 body 是 **shell 原始碼**,不是 argv:ghostty 的 `command` 沒有 `direct:` 前綴時
交給 `/bin/sh -c`。所以路徑一律寫成**已 quote 的 shell word**,安裝路徑含空白或
shell 特殊字元(`$`、反引號、`"`、`\`、`'`)時才不會被拆成多個 word、也不會改變
命令語意:`command = '<repo>/script/box/enter.sh' --distrobox '<路徑>' --box '<盒>'`——單引號是唯一對任意字元都安全的 POSIX
形式;路徑裡的單引號以 `'\''` 收尾再接回。

### 路徑含換行一律拒絕(issues #175 round 2／#360)

此限制同時適用於 distrobox 路徑與 repo 內 wrapper 路徑；repo 路徑含換行時，
setup 在寫入任何設定前拒絕執行，請先搬到不含換行的路徑。

shell quoting 能把**任何**文字變成一個合法的 word,但受管檔案是**逐行**
格式:ghostty 一行一個 key。所以路徑裡只要有換行(LF)或
歸位字元(CR),受管 body 就會被**切成兩行**——ghostty 讀到第二行不認得的 key,
整份 config 以 `unknown field` 被拒,而 setup 早就寫完並 exit 0 了。這正是
round 1 拿掉的「裸名字 fallback」同一類問題:**已知壞掉的半套寫入**。

沒有任何編碼能解決這件事,所以這種路徑直接拒絕:

- 規則同時適用於 `--distrobox` 給的路徑與 PATH 上自動解析到的路徑——這條限制
  講的是**受管檔案裝得下什麼**,不是使用者從哪裡給的。
- 拒絕發生在**任何檔案被寫之前**(連狀態檔都不寫),exit 1。
- 診斷訊息把控制字元顯示成 `\n` / `\r`,錯誤本身才不會也被切成兩行。

```text
[ERROR] distrobox: /home/me/weird\ndir/distrobox holds a newline or carriage return, which cannot be written into the line-based ghostty config (install distrobox at a path without one); nothing was written
```

### 範例 log

預設（`config.ghostty` 已存在；PATH 上有 `/usr/bin/ghostty`,distrobox 在 `~/.local/bin`):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] box: dev (default)
[INFO] ghostty config: /home/me/.config/ghostty/config.ghostty (config.ghostty exists)
[INFO] distrobox: /home/me/.local/bin/distrobox (absolute path written into the managed command)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] wrote: /home/me/.config/ghostty/config.ghostty (managed block: command = '/home/me/worktool/script/box/enter.sh' --distrobox '/home/me/.local/bin/distrobox' --box 'dev')
```

再跑一次是冪等的(區塊已是最新就不重寫):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] box: dev (default)
[INFO] ghostty config: /home/me/.config/ghostty/config.ghostty (config.ghostty exists)
[INFO] distrobox: /home/me/.local/bin/distrobox (absolute path written into the managed command)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] unchanged: /home/me/.config/ghostty/config.ghostty (managed block already up to date)
```

進 `work` 盒:

```text
$ just box setup --box work
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] box: work (user)
[INFO] distrobox: /home/me/.local/bin/distrobox (absolute path written into the managed command)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] wrote: /home/me/.config/ghostty/config (managed block: command = '/home/me/worktool/script/box/enter.sh' --distrobox '/home/me/.local/bin/distrobox' --box 'work')
```

沒有支援的終端(`terminal: none`):

```text
$ just box setup
[INFO] auto-enter: yes (default)
[INFO] terminal: none (default)
[INFO] terminal detected: none (no ghostty executable on PATH and no ghostty config dir)
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
[INFO] wrote: /home/me/.config/ghostty/config (managed block: command = '/home/me/worktool/script/box/enter.sh' --distrobox '/opt/distrobox/bin/distrobox' --box 'dev')
```

還原 host shell(印出還原了什麼;`--auto-enter no` 不寫受管 command,所以不需要
也不解析 distrobox):

```text
$ just box setup --auto-enter no
[INFO] auto-enter: no (user)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] box: work (user)
[INFO] wrote: /home/me/.config/worktool/config
[INFO] removed: /home/me/.config/ghostty/config (managed block: command = '/home/me/worktool/script/box/enter.sh' --distrobox '/home/me/.local/bin/distrobox' --box 'work')
```

沒東西可還原時也會說明:`[INFO] nothing to remove: /home/me/.config/ghostty/config (no managed block)`。

`--dry-run` 只印不寫:

```text
$ just box setup --dry-run --box work
[INFO] auto-enter: yes (default)
[INFO] terminal: ghostty (default)
[INFO] terminal detected: ghostty (ghostty executable /usr/bin/ghostty)
[INFO] box: work (user)
[INFO] distrobox: /home/me/.local/bin/distrobox (absolute path written into the managed command)
[INFO] dry-run: would write /home/me/.config/worktool/config
[INFO] dry-run: would write /home/me/.config/distrobox/distrobox.conf (managed block: for _worktool_a in "$@"; do ... 'work') unset TMUX TMUX_PANE; ...)
[INFO] dry-run: would write /home/me/.config/ghostty/config (managed block: command = '/home/me/worktool/script/box/enter.sh' --distrobox '/home/me/.local/bin/distrobox' --box 'work')
```

查目前生效的決策(印到 stdout,沒有 log 標籤,可直接 grep):

```text
$ just box status
config: /home/me/.config/worktool/config
auto-enter: yes (default)
terminal: ghostty (default)
box: work (user)
ghostty: /home/me/.config/ghostty/config (managed block: present)
distrobox.conf: /home/me/.config/distrobox/distrobox.conf (managed block: present)
wrapper: /home/me/worktool/script/box/enter.sh (recorded in a managed block: runnable)
distrobox: /home/me/.local/bin/distrobox (recorded in a managed block: runnable)
link: /home/me/dev-box/.ssh -> /home/me/.ssh (linked)
link: /home/me/dev-box/.gitconfig -> /home/me/.gitconfig (linked)
link: /home/me/dev-box/.gnupg -> /home/me/.gnupg (linked)
link: /home/me/dev-box/.config/gh -> /home/me/.config/gh (linked)
home: /home/me/dev-box (default)
```

`home:` 是 `just box assemble` 記下的盒子 HOME 與來源(issue #198);還沒 assemble
過時是 `home: not recorded (run: just box assemble)`。記錄的值不是絕對路徑時,和其他
壞掉的值一樣以 `[ERROR] <設定檔>: invalid value ...` 拒絕、exit 1。

`distrobox:` 那行是 issue #175 的「可讀錯誤」:受管 command 寫的是絕對路徑,所以 distrobox
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

`home:` 前面是 user config 連結(issue #199,由 `just box assemble` 建立,見
[`manifest.md`](manifest.md)「user config 連結」),每一項一行,四種狀態:

```text
link: /home/me/dev-box/.ssh -> /home/me/.ssh (linked)
link: /home/me/dev-box/.gitconfig -> /home/me/.gitconfig (blocked by existing file)
link: /home/me/dev-box/.gnupg -> /home/me/.gnupg (missing source)
link: /home/me/dev-box/.config/gh -> /home/me/.config/gh (not linked yet; run: just box assemble)
```

盒子 HOME 就是 `home:` 那行的值,也就是 `just box assemble` 記下的那一個(#198),
連結報告與 `home:` 讀的是設定檔裡同一個 `home=`。還沒記錄時連結只有一行;記錄的
盒子 HOME 就是 host HOME(`--home ~`)時兩邊共用 HOME、不需要連結,也只有一行:

```text
link: box HOME not recorded - user config not linked yet (run: just box assemble)
link: the box HOME is the host HOME - user config already in place
```

還沒跑過 `setup` 時第一行會是
`config: /home/me/.config/worktool/config (not found - defaults shown; run: just box setup)`,
後面照樣列出預設值(全部 `(default)`)、ghostty 的區塊狀態與 `distrobox:` 那行,
報告永遠不會是空的。

受管命令也記錄 repo 內 wrapper 的絕對路徑。`just box status` 會列出
`wrapper: <路徑> (recorded in a managed block: runnable)`；若 repo 搬走、
wrapper 被刪除或不再可執行，會顯示 `NOT RUNNABLE` 與修復指令
`just box setup`。請在 repo 的新位置重跑 setup，更新受管命令。
wrapper 遺失時需先還原 repo；執行權限遺失時，setup 會恢復執行權限並印 log，
`--dry-run` 只報告、不改權限。無法恢復時，setup 拒絕寫入受管檔案並說明原因與下一步。

## 首次啟動的進度(Ghostty 與 just box enter,issues #180／#360)

盒子第一次 `distrobox enter` 時,distrobox-init 會在盒內安裝基本套件與
`additional_packages`(實機約 3.5 分鐘)。distrobox 本身在這段期間只印兩行靜態
訊息(`Starting container... [ OK ]`、`Installing basic packages...`),apt 的輸出
全部被它的過濾迴圈丟掉,`--verbose` 也不會即時轉送,而且它等待
`container_setup_done` 的迴圈**沒有逾時**。研究與決定見 issue #180。

所以 worktool 在**進盒包裝層** `script/box/enter.sh`(`just box enter`)處理,不改
distrobox。可手動執行 `just box enter`;它最後
`exec <distrobox> enter <盒> [-- <指令>...]`。依 issues #179／#180／#360,
`just box setup` 寫出的終端受管 command 呼叫 repo 內 wrapper 的絕對路徑,明確傳入
已引用的 distrobox 絕對路徑與盒名。wrapper 最後進盒內 fish,不自動開 tmux。
wrapper 仍呼叫 distrobox enter,因此 distrobox.conf 的受管區塊繼續清除
TMUX／TMUX_PANE。首次進度、log 與逾時也適用於 Ghostty 自動進盒。

### 選項

| 選項 | 值 | 預設 | 意義 |
|------|----|------|------|
| `--box` | 容器名(`[A-Za-z0-9][A-Za-z0-9_.-]*`) | `dev` | 要進哪個盒;不合規則(空白、換行、`/` 等)exit 2 |
| `--distrobox` | 絕對路徑的可執行檔 | PATH 上解析到的那一個 | 手動使用 wrapper 時要執行的 distrobox 絕對路徑 |
| `--timeout` | 正整數(秒) | `900`(15 分鐘),或環境變數 `WORKTOOL_INIT_TIMEOUT` | 首次初始化的逾時 |
| `-- <指令>...` | — | 無(進登入 shell) | 在盒內執行的指令,原封交給 `distrobox enter <盒> -- <指令>...` |
| `-h`, `--help` | — | — | usage |

進度行的間隔預設 10 秒,可用環境變數 `WORKTOOL_INIT_INTERVAL` 改(測試用它縮短)。
未知選項、無效的值、缺值都由 `enter.sh` 自己拒絕(`enter.sh: unknown option
'--bogus' (see --help)`,exit 2);整行命令列解析完才處理 `--help`。

### 流程

1. **判斷首次初始化**:`docker inspect --type container -f '{{.State.StartedAt}}' <盒>`
   是零值(`0001-01-01T00:00:00Z`,從沒啟動過)才算首次。不用 `docker exec` 查
   `/.containersetupdone`:容器沒在跑時 exec 會失敗。其他情況(盒子啟動過、沒有這個
   盒、沒有 docker)一律**直接交給** `distrobox enter`,由它自己報錯;平常進盒只多
   一次 `docker inspect`。
2. **首次啟動**:stderr 先印說明、查 log 的指令與 host log 路徑,再
   `docker start <盒>`,並在背景把 `docker logs -f <盒>` 完整寫進
   `${XDG_CACHE_HOME:-~/.cache}/worktool/<盒>-init.log`。之後每 10 秒一行
   「目前階段 + 經過時間 + 最新一行初始化輸出」:階段 = log 裡最後一行
   `distrobox: ...`(distrobox 自己顯示的階段標題),最新一行略過 `+ ` 開頭的 xtrace
   行、截到 60 字元。stderr 是 TTY 時**原地覆寫同一行**,否則逐行印。
3. **完成**:log 出現 `container_setup_done` 就印「初始化完成」,清掉背景行程,
   `exec distrobox enter`。
4. **失敗或逾時**:distrobox-init 印出 `Error:` 行、容器中途停了、`docker start`
   失敗、背景的 `docker logs -f` 提早結束(Docker 錯誤、權限、連線中斷;訊息帶它的
   exit status,不會被誤報成逾時)、或超過逾時,都印原因、log 路徑、log 最後 20 行與復原方式。
   stdin 是終端時，先清理 log follower，再等待 Enter 才 exit 1，讓 Ghostty 視窗保留診斷；
   非互動呼叫直接 exit 1。
   **不停止、不刪除盒子**(刪盒是使用者的決定;逾時時盒子可能還在裝,訊息會給
   `docker logs -f <盒>`)。
5. **清理**:背景的 `docker logs -f` 是唯一的背景行程,成功、失敗、逾時、Ctrl-C
   (exit 130)、SIGTERM(exit 143)時都由 trap 清掉。中斷時盒子繼續在背景初始化,
   訊息會說明並給 `docker logs -f`。

不採用 pre_init_hooks 心跳(在盒內印 `distrobox:` 行讓 distrobox 轉送):會打亂
distrobox 的階段顯示,也有遺留行程的風險。

### 範例

非 TTY(例如接到檔案)時的首次啟動:

```text
$ just box enter
[INFO] first launch of box 'dev': distrobox installs its packages first - this can take several minutes (timeout 15m00s)
[INFO] follow the full output in another terminal: docker logs -f dev
[INFO] full init log: /home/me/.cache/worktool/dev-init.log
[INFO] first launch: Installing basic packages... - 10s elapsed - Get:12 http://archive.ubuntu.com/ubuntu resolute/main amd64
[INFO] first launch: Installing basic packages... - 20s elapsed - Unpacking libfoo (1.2-3) ...
...
[INFO] first launch: Setting up read-only mounts... - 3m30s elapsed - distrobox: Setting up read-only mounts...
[INFO] first launch: initialisation complete after 3m32s - entering the box
```

逾時(盒子保留,由使用者決定是否重建):

```text
[ERROR] first launch of box 'dev' failed: timed out after 15m00s without container_setup_done (the box may still be installing: docker logs -f dev)
[ERROR] init log: /home/me/.cache/worktool/dev-init.log
[ERROR] last 20 lines of the init log:
  | ...
[ERROR] the box was left as it is (not stopped, not removed); to start over: distrobox rm -f dev, then open a new terminal
```

已知限制:ghostty 的受管 command 結束時預設會關掉視窗;
要看完失敗訊息,可以在另一個終端跑 `just box enter`,或查 host log。

## 測試對應

四層都在 Docker 內跑、都用**暫時 HOME**(每個案例自己的 `BATS_TEST_TMPDIR`),
絕不讀寫真實 home。只有「偵測」會碰到執行檔:自 issue #175 起 setup 會
`command -v ghostty` / `command -v distrobox`,所以相關案例在自己的 tmpdir 裡放
一支假的、再把那個目錄接到 PATH 前面(單元與整合層沒有任何測試需要**真的**
distrobox 或 tmux 跑起來;真 ghostty 的部分在 integration 的 ghostty 組,真盒與
host tmux server 的部分在 system-real):

- 單元:`test/unit/setup_spec.bats` —— 預設值與每行 `[INFO]` log、user 覆蓋標
  `(user)`、`--key=value`、user 選擇跨次保留 / default 重算、ghostty 區塊只寫一次且
  重跑冪等、區塊原地取代且前後的使用者行都在、`--auto-enter no` 移除區塊並回報、沒東西可移
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
  command,並斷言 `$(...)` 與反引號的 sentinel 檔沒有被建立)與單引號;issue #179
  一組:受管 command 後面不接任何東西(沒有 tmux)、`--tmux` 是未知選項(exit 2)、
  `~/.tmux.conf` 不論哪種決策都不被讀寫(內容與權限不變)、舊設定檔的 `tmux=` 行被
  忽略並保留為非受管 key;distrobox.conf 受管區塊每次都寫、`--terminal none` /
  `--auto-enter no` 保留且冪等、跟著 `--box` 改、`--dry-run` 不寫;
  `test/unit/managed_block_spec.bats` —— 標記狀態(只有 BEGIN / 只有 END /
  END 在前 / 巢狀 / 兩個區塊 / BEGIN 或 END 多了文字 / 縮排)× 操作(新寫 /
  取代 / 未變 / 移除)× 受管檔案(ghostty 設定 / distrobox.conf)每格 exit 1、檔案
  逐位元組不變、其他檔案(含設定檔)都沒寫,加上錯誤訊息的行號、`--dry-run`、
  `status` 的 MALFORMED;
  `test/unit/box_tmux_env_spec.bats` —— 盒內沒有 tmux wrapper(沒有 guard、沒有
  dpkg-divert)、`TMUX_TMPDIR` hook 明確設擁有者與 mode、distrobox.conf 那一行照
  distrobox-enter 的選項文法判定目標盒(帶值選項 `-n` / `--name` / `-a` /
  `--additional-flags` × 值等於盒名 × 是否進該盒、最後一個位置參數為準、
  分隔符、`DBX_CONTAINER_NAME` 只在沒給盒名時生效)只在進該盒時丟掉 `TMUX` 與
  `TMUX_PANE`、不改呼叫端的參數與選項、`set -u` 下安全;`box/tmux-env.sh` 對 `TMUX` × `TMUX_TMPDIR`
  等價類表的保留 / 丟棄規則(含 `TMUX_PANE`),以及兩個 snippet 與清單 blob
  逐位元組相同;
  `test/unit/status_spec.bats` —— 無設定檔的預設報告、
  有設定檔的逐行輸出與順序、缺 key 回預設、`XDG_CONFIG_HOME`、只印 stdout、
  `--help` / 未知選項,以及 `distrobox:` 那行的四種狀態(runnable / NOT
  RUNNABLE / 裸名字 / PATH 上找不到)與記錄形狀的解碼(單引號、舊版沒有 quote 的
  絕對路徑、舊版後接 `-- tmux new -A -s main` 的形狀);未記錄盒子 HOME 時報告是九行(含
  `distrobox.conf:` 區塊 present / absent)、沒有 tmux 行,
  舊設定檔的 `tmux=` 行與 `~/.tmux.conf` 裡的區塊既不報告也不拒絕;
  `test/unit/justfile_spec.bats` —— `just box setup` / `just box status` 原封轉發
  argv、真腳本在暫時 HOME 下的 `--dry-run` / `status`、壞選項由腳本而非 justfile
  拒絕。三個都是 `test.sh` 的**必要 spec**。
- 整合:`test/integration/setup_spec.bats` —— `setup` 之後 `status` 的來回:ghostty
  區塊 present、沒有 tmux 行也沒有 `~/.tmux.conf`、`--terminal none` 與
  `--auto-enter no` 後 absent、`--dry-run` 後什麼都沒存、setup 的 log 與 status 的
  報告逐行一致;issue #175 再加兩案:setup 真的寫出來的 ghostty command(先從
  **已 quote 的**形狀解回來)在 `env -i
  PATH=/usr/bin:/bin` 下跑得起來(對照案例證明同一環境下裸名字是 127
  `not found`),以及 distrobox 被刪掉之後 `status` 的 `distrobox:` 那行從
  `runnable` 變成 `NOT RUNNABLE`。
  `test/integration/ghostty_config_spec.bats`(ghostty 組)—— 真的 ghostty
  `+show-config` 解析出的生效 `command` 是**絕對路徑**(並 refute 裸名字那一行)、
  後面不接 tmux(issue #179),
  絕對路徑版本仍被 `+validate-config` 接受,PATH 上沒有 distrobox 時整次執行被
  拒絕(不再寫任何檔案),以及安裝路徑含空白 / `$(...)` / 雙引號時,把**真 ghostty
  回報的生效值**丟進 `/bin/sh -c` 仍只會執行那一個執行檔(sentinel 檔不存在)。
- 系統:`test/system/real_assemble_spec.bats` —— 真 distrobox 把 `box/dev.ini` 解成
  的 create 請求帶 `--env TMUX_TMPDIR=${HOME}/dev-box/.cache/tmux`(在 image 之前,
  是 docker 的容器環境)與建立該目錄的 `--init-hooks`;
  `test/system/real_enter_env_spec.bats` —— 真的 distrobox-enter(`--dry-run`,印出
  它會送出的 `exec` 請求):對照案例先證明沒有 distrobox.conf 區塊時請求裡**有**
  host pane 的 `--env=TMUX=` / `--env=TMUX_PANE=`;交付的 setup.sh 寫出區塊後,
  每種進盒形狀(`enter dev`、`-- tmux ...`、`-- /usr/bin/tmux ...`、`-- sh -l`、
  `--name dev`、`-n dev -e ...`)的請求都沒有這兩個,呼叫端其他變數照常帶進;
  其他盒維持上游行為;另以真的 distrobox-enter 當**判定目標盒的 oracle**:同一張
  選項文法表逐列跑 `--dry-run`,請求裡的容器名是 `dev` 時不得帶 `TMUX` /
  `TMUX_PANE`,是其他盒時必須帶;
  `test/system/real_engine_spec.bats`(system-real,真 engine + 真 ghostty)——
  ghostty 鏈的標記檔斷言回答的是盒內 fish、寫檔的程序在 dev 容器的 mount namespace
  (不是 runner 的)、不在 tmux 底下、節點名等於 `docker inspect dev`(runner 自己
  沒有 fish,preflight 先證明;`/run/.containerenv` 是 podman 的檔案,docker 建的
  盒子沒有,所以不拿它當證據);issue #179 兩案:**runner(host 端)先開
  一個 tmux server(session `main`,正是舊命令 `-A` 會附著的名字)**,再以
  setup.sh 實際寫出的受管 command 原樣開窗、由 ghostty `input` 把 payload 打進落地的
  shell,證明仍落在盒內 fish;以及 host 有 tmux server 時盒內 `tmux` 得到的是盒子
  自己的 server(pid 不同、mount namespace 等於 dev 容器、socket 在
  `TMUX_TMPDIR` 底下、`tmux ls` 只列盒內 session);再加 issue #179 的**矩陣**
  (codex 第 4 輪):進盒路徑(受管 ghostty 命令、`distrobox enter dev`、
  `-- <命令>`、`-- <真 tmux>`、`sh -l` / `fish -l` 登入 shell)× host 狀態(沒有
  host tmux / host tmux server 在跑且呼叫端環境帶著它的 `TMUX`、`TMUX_PANE`)×
  tmux 呼叫(`tmux ls`、`tmux new`、`tmux new -A -s main`、`tmux attach`,後兩者
  在 script(1) 給的終端上),每格都要:盒內看不到 `TMUX` / `TMUX_PANE`、盒子
  server 停著時 `tmux ls` 什麼都不列、四種呼叫都到同一個 server——socket 在盒子
  `TMUX_TMPDIR` 底下、行程在 dev 容器的 mount namespace 且根目錄有引擎的容器檔、
  不是 host server 的 pid——且 host server 只列自己的 `main`。每格另驗 issue 的
  目標 1(進盒後、probe 自己的 tmux 之前,盒內 mount namespace 裡沒有任何 tmux
  行程;h1 時 host server 沒有 client、h0 時沒有被啟動任何 host server)與目標 3
  (host 端的 `~/.tmux.conf` sentinel 在 setup.sh 與每格之後逐位元組不變;盒內
  server 以 `#{config_files}` 證明讀的是盒子自己的 `$HOME/.tmux.conf`——#198 給盒子
  獨立 HOME 之前,盒子的 `$HOME` 就是 host HOME,所以同一個檔案;斷言綁的是盒子的
  `$HOME`,#198 之後自動跟著換)。另一案把既有的 `TMUX_TMPDIR` 改成 mode 755、
  擁有者 1:1,重啟盒子後斷言回到 700 與盒內使用者。
- 驗收:進盒延遲量測與達標(< 300ms;#22 / #150)與效能驗收測試(#23)是
  M3 的其他 issue;實機「開新終端主觀順暢」留在 [`acceptance.md`](acceptance.md)
  的人類清單。
