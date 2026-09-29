# 盒子清單格式與 assemble 流程

本文件說明 worktool 的「盒子清單」(box manifest)格式,以及如何從清單
assemble 出共用的 dev 盒。狀態:M2(盒子清單格式 + 最小 assemble)。整體設計與
治理見 [`design.md`](design.md);目錄結構與測試 gate 見
[`structure.md`](structure.md)。

## 決策:直接沿用 distrobox-assemble 原生格式

worktool 的盒子清單**就是一個原生的 distrobox-assemble 檔案**(INI 格式),
不另外發明新格式。理由:

- 研究後重用(research-and-reuse)、不重複(DRY):distrobox 已定義好一套成熟
  的 assemble 清單格式,自訂新格式只會增加維護負擔與轉譯層。
- 相容性:清單可直接餵給 `distrobox assemble create --file <清單>`,不需要任何
  轉換;所有 distrobox-assemble 的鍵(key)天生可用。
- 單一事實來源:盒子的定義只有一份,就是這個清單檔。

## 格式

清單是 INI 檔。**區段標頭(section header)`[名稱]` 就是盒子的名稱**;區段內
以 `鍵=值` 宣告 distrobox-assemble 的欄位。worktool 的共用盒清單放在
[`box/dev.ini`](../box/dev.ini):

```ini
[dev]
image=ubuntu:26.04
additional_packages="ripgrep fzf tmux fish"
additional_flags="--env TMUX_TMPDIR=${HOME}/dev-box/.cache/tmux"
init_hooks=setpriv --reuid="${container_user_uid}" --regid="${container_user_gid}" --clear-groups mkdir -p -m 0700 "${TMUX_TMPDIR}"
init_hooks=echo <box/tmux-guard.sh 的 base64> | base64 -d >/usr/local/bin/tmux && chmod 0755 /usr/local/bin/tmux
```

`additional_packages` 目前四個套件的來歷:`ripgrep fzf` 是 M2 為驗證 assemble 流程
放的最小工具集;`tmux fish` 是 **M3(issue #160)** 加的 —— `just box setup` 預設把
終端指到 `'<distrobox>' enter dev`,#5 的驗收要求「開終端即盒內 fish」,tmux 則是
使用者進盒後自己開的工具。M3 只裝套件;tmux / fish 的**設定**(dotfiles、主題、
plugin)留在 M5。

`additional_flags` 與 `init_hooks` 是 **M3(issue #179)** 加的**盒內 tmux 隔離**:
distrobox 把 host 的 `/tmp` 掛進盒內,tmux 的預設 socket(`/tmp/tmux-<uid>/default`)
因此盒內外共用,盒內打 `tmux` 會連到 host 的 server。`additional_flags` 以
`--env` 設**容器環境變數** `TMUX_TMPDIR`(`${HOME}` 在建盒時展開,目錄在 #196 的
盒子 HOME `~/dev-box` 底下),盒內任何方式啟動的 tmux 都繼承;`init_hooks` 在每次
盒子啟動時以盒內使用者身分(`setpriv` 切到 distrobox-init 收到的 `--user` /
`--group`,即 `container_user_uid` / `container_user_gid`)建立該目錄、mode 0700
—— tmux 不會自己建它,目錄不存在時會**無聲**退回 `/tmp`。第二個 `init_hooks`
(codex 第 1 輪,PR #232)把 [`box/tmux-guard.sh`](../box/tmux-guard.sh) 裝成盒內的
`/usr/local/bin/tmux`:從 host 的 tmux pane 進盒時,`distrobox enter` 帶進來的
`TMUX` 指向 host server 的 socket,而 tmux 先看 `TMUX`;guard 只保留指向盒子自己
`TMUX_TMPDIR` 底下的 `TMUX`,其餘丟掉。清單一行放不下腳本,所以該行放的是
`box/tmux-guard.sh` 的 base64;`test/unit/box_tmux_guard_spec.bats` 斷言兩者逐位元組
相同,可讀的 `box/tmux-guard.sh` 是唯一來源。同一個鍵出現多次時 distrobox-assemble
以 `&&` 串接,依序執行。每個鍵各佔一行:distrobox-assemble 一行讀一個鍵。
見 [`enter.md`](enter.md)。

### worktool 要求的必要鍵

M2 的 assemble 包裝器(`script/box/assemble.sh`)在動作前會驗證清單,最少需要:

| 欄位 | 說明 | 必要 |
|------|------|------|
| 區段標頭 `[名稱]` | 盒子名稱(distrobox 以標頭當容器名) | 是 |
| `image=` | 盒子的基底映像檔;M2 鎖定 `ubuntu:26.04` | 是(不可為空) |

### 驗證規則(嚴格)

除了「有名稱、有 image」之外,驗證還會強制以下規則,任一不符即以清楚的
`[ERROR]` 快速失敗:

- **單一盒子(single box)**:worktool 只出一個共用的 dev 盒,因此清單**只能有
  一個區段**。宣告多個區段(`[a]`、`[b]`…)會被拒絕(否則「哪個區段的 image
  才算數」是模稜兩可的)。
- **image 必須屬於盒子自己的區段**:`image=` 必須寫在該區段標頭**之後**。出現在
  任何區段標頭**之前**的 `image=`,不屬於這個盒子,會被視為「缺少 image」而拒絕。
- **拒絕純空白值**:`[   ]` 這種只有空白的名稱會被當成缺少盒子名稱;
  `image="   "`、`image='   '`、`image=''` 這種(引號內只有空白或什麼都沒有)
  會被當成空的 image。名稱與 image 值都會先去除前後空白再判斷是否為空。
- **引號規則(單/雙引號一視同仁;只認「成對」)**:distrobox-assemble 會把每一行
  `鍵=值` 寫進暫存檔再以 shell 的 `.` source 進來,也就是**值被當成 shell 指派**
  解讀,因此單引號與雙引號在上游都是有效的引號 —— 反過來說,**沒有結尾、或兩端
  種類不一致的引號,在上游就是 shell 語法錯誤**。worktool 的處理是:先去除整個
  值的前後空白(所以 `image= '   '` 這種引號前有空格的寫法也一樣),接著只要
  **第一個或最後一個字元是引號**(`"` 或 `'`),就要求它必須是**成對的**:兩端是
  **同一種**引號、且**長度至少 2**(也就是真的有開有關);符合,就去掉這**一對**
  外層引號(只剝一層)、再去除一次前後空白,結果為空就走上面的「空 image」拒絕。
  其他任何以引號開頭或結尾的寫法都是**格式錯誤**,一律以清楚的訊息
  `[ERROR] manifest image value has an unbalanced quote: <值> ...` 拒絕、exit 1,
  且完全不呼叫 distrobox:單獨一個引號(`image='` / `image="`)、種類不一致
  (`image='ubuntu:26.04"`)、只有一邊有引號(`image="ubuntu:26.04` /
  `image=ubuntu:26.04"`)都屬此類。理由:上游把值當 shell 指派來 source,這些寫法
  到了 distrobox 只會變成一句難懂的 shell 錯誤,由 worktool 的前置檢查提早、明確地
  擋下更穩健。合法寫法 `image=ubuntu:26.04`、`image="ubuntu:26.04"`、
  `image='ubuntu:26.04'` 三者結果都是 `ubuntu:26.04`;**不在兩端**的引號(值中間)
  一律不處理、原樣保留。

### 常用的 distrobox-assemble 欄位(可用,非必要)

沿用 distrobox 原生語意,常見的還有:

- `additional_packages`:要在盒內安裝的套件(空白分隔、以引號包起)。
- `init_hooks` / `pre_init_hooks`:建立盒子後 / 前執行的指令。
- `additional_flags`:傳給容器管理器的額外旗標。
- `volume`、`exported_apps`、`exported_bins`、`start_now`、`nvidia`、`pull`、
  `root`、`entry` 等。

完整欄位以 distrobox 官方 `distrobox-assemble` 文件為準。M2 的 dev 盒刻意只放
1-2 個工具(ripgrep、fzf)以驗證 assemble 流程;M3 加上 tmux、fish 作為自動進盒的
前提(只裝、不設定,見上方「格式」);完整工具集在 M5-M10 逐步移植
(見 [`design.md`](design.md) 的 milestone 計畫)。

## assemble 流程

`script/box/assemble.sh` 是一層薄而穩健的包裝器,行為如下:

1. **解析清單路徑(只解析一次)**:相對路徑先對目前目錄、再對 repo 根目錄嘗試,
   得到一個**確定的路徑**。這條解析後的路徑會**同時**用於驗證、dry-run 輸出與真正
   的 distrobox 呼叫,三者一致。這避免了「驗證對著解析後的路徑通過,distrobox 卻
   收到另一條(可能不存在)的路徑」——特別是從 repo 以外的目錄執行、又用預設相對
   清單時。從 repo 根目錄執行預設清單時仍是 `box/dev.ini`;從其他目錄則是絕對的
   `${REPO_ROOT}/box/dev.ini`。
2. **驗證清單**(`lib/manifest.sh` 的 `manifest_validate`):清單檔存在、有盒子
   名稱、只有單一區段、且該區段內有非空的 `image=`(詳見上面「驗證規則」);任一
   不符即以清楚的 `[ERROR]` 訊息快速失敗(fail fast)。驗證失敗時**完全不會**呼叫
   distrobox。
3. **組出 distrobox 呼叫**:`distrobox assemble create --file <解析後的清單>`。
4. **執行或試跑**:
   - 一般模式:呼叫 distrobox(需要 PATH 上有 `distrobox`)。
   - 試跑模式(dry-run):把「將要執行的完整指令」印到 **STDOUT**、**不執行**。
     以 `WORKTOOL_DRY_RUN=1` 環境變數或 `--dry-run` 旗標開啟。診斷訊息一律走
     STDERR(沿用 `lib/log.sh`),讓 STDOUT 保持乾淨、機器可讀。輸出採**逐一參數的
     shell 跳脫**(`printf '%q'`),因此含有空白、`;` 或 `$()` 的路徑會被表示成
     單一安全參數,直接複製貼上即可忠實重跑,不會被再次拆分或解讀。

包裝器**絕不在 host 上安裝任何東西、也不需要 root**;唯一的副作用是呼叫
distrobox,由 distrobox 自己管理容器。選項:`--dry-run`、`--file <manifest>`、
`--help`(`-h`,印 usage 後 exit 0);未知選項以
`assemble.sh: unknown option '<x>' (see --help)` 拒絕、exit 2、什麼都不跑。

### 用法

使用者介面是 `just box assemble [--dry-run] [--file <manifest>]`(`box` 是盒子
生命週期的 namespace;`just` 是使用者的通用介面,命令模型比照 base
ADR-00000005/10/11,見 [`design.md`](design.md)「決策」)。recipe 只是把參數**原樣**
轉發給 `script/box/assemble.sh`;參數驗證與 `--help` 都在腳本。

```bash
# 試跑:只印出指令,不執行(單元測試就是斷言這個輸出)
just box assemble --dry-run
# -> distrobox assemble create --file box/dev.ini

# 指定其他清單
just box assemble --dry-run --file box/other.ini

# 實際 assemble(需要 host 上有 distrobox)
just box assemble
just box assemble --file box/other.ini

# 說明(由腳本印出)
just box assemble --help
```

底層指令(recipe 呼叫的就是這些;沒有 `just` 時可直接執行):

```bash
./script/box/assemble.sh --dry-run                    # = just box assemble --dry-run
WORKTOOL_DRY_RUN=1 ./script/box/assemble.sh           # 以環境變數試跑,同上
./script/box/assemble.sh                              # = just box assemble
./script/box/assemble.sh --file box/other.ini         # = just box assemble --file box/other.ini
```

## 進盒延遲量測(just box bench)

M3(issue #150;issue #162 補第三個指標 `inbox` 與輸入驗證)加入量測工具
`script/box/bench.sh`,使用者介面是 `just box bench [選項]`(recipe 只是把參數**原樣**
轉發給腳本;參數驗證與 `--help` 都在腳本,與 `just box assemble` 同一個模型)。它用
bash 內建的 `EPOCHREALTIME`(微秒精度的 wall clock)計時,**不依賴 hyperfine**、不需要
在 host 上安裝任何東西。

### 用法

```text
bench.sh [--box NAME] [--runs N] [--warmup N] [--max-ms N] [--json] [--shell CMD] [-h|--help]
```

| 選項 | 說明 | 預設 |
|------|------|------|
| `--box NAME` | 要進的盒子;只允許 `^[A-Za-z0-9._-]+$`(見下方「輸入驗證」) | `dev` |
| `--runs N` | 每個指標**計入統計**的次數(N >= 1) | `10` |
| `--warmup N` | 每個指標量測前**不計入**的暖身次數(N >= 0;第一次 enter 可能要先啟動停著的容器) | `2` |
| `--max-ms N` | 門檻:**shell 指標的中位數**超過 N ms 即 exit 1(供 gate 使用) | 無門檻 |
| `--json` | 改印**一個** JSON 物件,不印三行文字 | 關 |
| `--shell CMD` | shell 與 inbox 指標要跑的指令(以空白拆成參數);不得含控制字元(見下方「輸入驗證」) | `sh -c :` |
| `-h`, `--help` | 印 usage 後 exit 0 | |

```bash
just box bench                          # dev 盒,每個指標 2 次暖身 + 10 次量測
just box bench --runs 3 --warmup 1      # 快一點
just box bench --max-ms 300             # 當 gate:shell 中位數 > 300 ms 即 exit 1
just box bench --json                   # 一個 JSON 物件
just box bench --shell 'fish -c exit'   # 量另一個 shell 的啟動
just box bench --help                   # 說明(由腳本印出)
# 底層:./script/box/bench.sh [同樣的選項]
```

### 指標的意義

三個指標,依序 **enter、shell、inbox**;每個指標先跑 `--warmup` 次(不記錄),再跑
`--runs` 次(記錄),對記錄到的樣本算 min / median / max(偶數個樣本的中位數取中間
兩個的平均):

| 指標 | 實際執行的指令 | 量的是什麼 |
|------|----------------|------------|
| `enter` | `distrobox enter <box> -- true` | distrobox 包裝層 + 容器引擎的一次來回(進盒的固定成本);host 端計時 |
| `shell` | `distrobox enter <box> -- <shell>`(預設 `sh -c :`;system-real gate 用 `fish -c exit`) | 同上再加一個 shell 的啟動,也就是使用者「進盒拿到提示字元」感受到的總延遲;host 端計時 |
| `inbox` | `distrobox enter <box> -- bash -c '<timer>' bench-inbox <shell>` | **只有 shell 的啟動**,在**盒內**計時:`<timer>` 是一行 bash,在盒內讀兩次自己的 `EPOCHREALTIME`、中間跑 `<shell>`(以 `"$@"` 收到、參數邊界不變,stdout 丟棄),把差值(微秒、一個整數)印在 stdout 最後一行、以 `<shell>` 的結束碼結束;bench.sh 解析那個數字,所以 enter 的來回**不在**這個數字裡(shell − inbox 約等於 enter)。timer 印出的不是整數(例如盒內 bash 太舊沒有 `EPOCHREALTIME`)視同量測失敗 |

輸出(STDOUT,機器可讀;診斷一律走 STDERR):

```text
enter: min=<ms> median=<ms> max=<ms> ms
shell: min=<ms> median=<ms> max=<ms> ms
inbox: min=<ms> median=<ms> max=<ms> ms
```

`--json` 時改為恰好一個物件:

```json
{"box":"dev","runs":10,"warmup":2,"shell_cmd":"sh -c :","unit":"ms","enter":{"min":..,"median":..,"max":..},"shell":{"min":..,"median":..,"max":..},"inbox":{"min":..,"median":..,"max":..}}
```

### 輸入驗證(`--json` 永遠是合法 JSON)

物件裡只有兩個字串(`box`、`shell_cmd`),bench.sh 不寫完整的 JSON 跳脫器,而是在
**任何東西執行之前**把會讓物件壞掉的值擋掉(整條指令列先解析完才動作,與未知選項
同一個時機;distrobox 一次都不會被呼叫):

| 選項 | 規則 | 違反時 |
|------|------|--------|
| `--box` | 必須符合 `^[A-Za-z0-9._-]+$`(字母、數字、`.`、`_`、`-`;不可為空) | `bench.sh: invalid --box <值>: only letters, digits, '.', '_' and '-' are allowed (see --help)`,exit 2 |
| `--shell` | 不得含控制字元(換行、tab、ESC 等;不可為空);反斜線與雙引號**合法**,會在 `shell_cmd` 裡跳脫成 `\\` 與 `\"` | `bench.sh: invalid --shell <值>: control characters are not allowed (see --help)`,exit 2 |

訊息裡的 `<值>` 以 `printf %q` 引用,所以就算值裡有換行,錯誤訊息仍是 STDERR 上的
**一行**。

結束碼:`0` 完成(且未超過 `--max-ms`);`1` 量測失敗(任一指標任一次 enter 非零結束,
或 inbox 的 timer 印出的不是整數;失敗的 enter 沒有值得報告的延遲,立即中止、不印統計)
或 shell 中位數超過 `--max-ms`(統計仍會印出,原因印在 STDERR;`--max-ms` **只看
shell**,enter 與 inbox 只報告不判定);`2` 用法錯誤(未知選項以
`bench.sh: unknown option '<x>' (see --help)` 拒絕,整條指令列先解析完才動作,
所以 `--help --bogus` 也是 exit 2、什麼都不跑;`--runs 0`、`--warmup -1`、
`--max-ms abc`、以及上表的 `--box` / `--shell` 違規同樣 exit 2);`127` PATH 上沒有
distrobox。

### 達標由 system-real gate 強制,runtime 決策不在這裡

這支工具**只量測、只在 `--max-ms` 明確給定時才判定**;本工具是 issue #22 從中拆出來
的量測部分,換不換容器 runtime(runc / crun)的決策留在 #22(結論:CI 實測約 88 ms,
維持 docker + 預設 runc)。「進盒 < 300 ms」的達標**由系統層 real-engine 組強制**
(issue #23;見下方「測試對應」):`test/system/real_engine_spec.bats` 對 DinD 內建出
的真實 dev 盒實跑 `bench.sh --box dev --runs 5 --warmup 2 --shell 'fish -c exit'
--max-ms 300`(門檻只寫在該 spec 的 `ENTER_MAX_MS` 一處;shell 指標自 M3 issue #160
起以盒內 **fish** 為準 —— 使用者實際拿到的 shell,而不是 `sh`),斷言 exit 0、三行
指標存在(`inbox` 那行只有 timer 真的在盒內跑過並印出整數才會出現)、且印出
`within --max-ms 300` 的判定行,並把數字印進 TAP log 當證據;另以 `--max-ms 1` 的
負向案例要求 exit 1 與 `exceeds --max-ms 1` 訊息,證明 gate 會咬。實機數字則進人類
清單(#22)。

## 測試對應

四層測試金字塔見 [`design.md`](design.md)「測試策略」。M2 四層**全部落地**,每一
層都是 CI 的必要 gate;下面逐層寫明**驗證什麼**與**延後什麼**。系統層分成**兩組**:
shim 組(建立請求正確性,快)與 real-engine 組(真正可用的 dev 盒,docker-in-docker,
慢);「可用的盒子」由 real-engine 組**真的驗證**(2026-09-16 人類決策採 DinD,見
issue #129),不再延後到 M5。

- 單元(`test/unit/manifest_spec.bats`、`test/unit/assemble_spec.bats`):
  - **驗證什麼**:清單驗證(有效通過,含不加引號 / 雙引號 / 單引號三種合法寫法都
    得到同一個 image 值;缺 image / 缺名稱 / 檔案不存在 / 純空白名稱 /
    雙引號或單引號內純空白或全空的 image(含引號前有空格)/ 引號不成對(單獨一個
    引號、種類不一致、只有一邊)以 `unbalanced quote` 訊息拒絕 / image 出現在
    區段之前 / 多區段,皆以正確訊息失敗)與指令組裝
    (dry-run 印出正確的 `distrobox assemble create --file ...`,且不執行;從 repo
    以外執行時輸出解析後的絕對路徑;含空白與 shell 特殊字元的路徑經跳脫後可還原成
    單一參數)。純 bash、完全可 mock。M3 加 `test/unit/bench_spec.bats`:以一支
    **假 `distrobox`**(記錄每次呼叫的參數、可注入固定或逐次不同的延遲、可分別對
    enter / shell / inbox 注入失敗;對 inbox 的 timer 呼叫不真的跑 timer,而是印出
    被告知要睡的微秒數,或以 `FAKE_DBX_INBOX_OUT` 注入任意輸出)
    驗證 `bench.sh` 的參數形狀(`enter <box> -- true` / `enter <box> -- sh -c :` /
    `enter <box> -- bash -c <timer> bench-inbox sh -c :`,timer 是**一個**參數、讀兩次
    `EPOCHREALTIME`、以 `"$@"` 跑 shell)、暖身與量測次數、min <= median <= max 且暖身
    不計入、inbox 的數字是盒內印出的值而非 host 來回(偶數樣本中位數可**精確**斷言)、
    `--max-ms` 的通過/失敗結束碼且不看 inbox、`--json` 形狀(以文法斷言整個物件、
    反斜線與雙引號的跳脫)、`--box` / `--shell` 的輸入驗證(`a"b`、含換行的 shell 等
    exit 2 且什麼都沒呼叫)、enter 全過之後 shell 或 inbox 失敗、timer 印非整數、
    `--help`、未知選項 exit 2 且什麼都沒呼叫;
    `test/unit/justfile_spec.bats` 另證明 `just box bench --runs 3` 原樣轉發。
  - **不證明什麼**:distrobox 是否真的會被呼叫、以及它如何解讀清單 —— 那是整合層與
    系統層的事;bench 的數字是否真實 —— 那是 real-engine 組的事。
- 整合(`test/integration/assemble_spec.bats`):
  - **驗證什麼**:把一支 **mock `distrobox`** 放到 PATH(**逐一參數**、每行一個地
    記錄自己被呼叫的參數),以真實(非 dry-run)模式跑包裝器,斷言它確實以
    `assemble create --file <解析後的清單>` 呼叫 distrobox;另外斷言「從 repo 以外
    執行會傳入解析後的絕對路徑」以及「清單無效時(缺 image、image 引號不成對)
    完全不呼叫 distrobox 且以非零結束」。證明包裝器到 distrobox 的接線。
  - **不證明什麼**:真正的 distrobox 會怎麼解析清單(mock 不解析),更不證明盒子
    能建出來。
- 整合,**ghostty 組**(`test/integration/ghostty_config_spec.bats`,M3 issue
  #172):ghostty 只在 Ubuntu 26.04(resolute)的官方庫裡,所以這一組跑在自己的
  映像 `dockerfile/Dockerfile.ghostty`(ubuntu:26.04 + ghostty + 同一份 bats);
  `just test integration` 會**兩組都跑**(先預設組、再 ghostty 組),每組各自適用
  同一套 tier 規則(必備 spec 存在且非空、至少跑一個 case、不得 skip)。
  - **驗證什麼**:`just box setup` 寫出的受管區塊交給**真的 ghostty** ——
    `ghostty +validate-config --config-file=<該檔>` 接受它(marker 行對 ghostty
    是 `#` 註解),`ghostty +show-config`(沒有 `--config-file`,只能靠
    `XDG_CONFIG_HOME`)解析出的**生效** `command` 恰為
    `'<distrobox 絕對路徑>' enter dev`(後面不接 tmux,issue #179)、`--box work`
    換成該盒名。另有兩個對照案例證明斷言不是
    恆真:`--auto-enter no` 之後那個 command 不再存在,以及亂鍵設定被
    `+validate-config` 以 `unknown field` 拒絕。
  - **不證明什麼**:視窗真的開得起來、真的進得了盒 —— 那是 real-engine 組的
    ghostty 鏈案例(需要顯示器與真引擎)。
- 系統,**shim 組**(`test/system/real_assemble_spec.bats`):在測試映像內執行
  **真正的、鎖定版本的 distrobox**(`dockerfile/Dockerfile.test` 固定 `1.8.2.5`,
  建置時驗證 tarball 的 sha256),容器管理器則換成一支**假的 `docker`**
  (`test/system/fixture/fake_container_manager.sh`,以
  `DBX_CONTAINER_MANAGER=docker` 選用、symlink 到 PATH 最前面):它回答 distrobox
  實際會發出的探測(`ps` / `inspect` / `pull` / `create`)、**逐一參數**
  (NUL 分隔,非 `$*`)記錄每一次呼叫、遇到不支援的子指令一律以非零失敗(不是
  一律 exit 0),並可用 `FAKE_CM_FAIL_CREATE=1` 注入 `create` 失敗。**不需要
  docker-in-docker**,快。
  - **驗證什麼**:以真實(非 dry-run)模式跑包裝器,斷言**真正抵達容器管理器的
    create 請求**帶有容器名 `dev`、映像 `ubuntu:26.04`(緊接在
    `--entrypoint /usr/bin/entrypoint` 之後),且清單的 `additional_packages`
    (`ripgrep fzf tmux fish`)被 distrobox 交給盒內 entrypoint(distrobox-init)的
    `--additional-packages`(位於映像之後、恰好一次);`pull` 請求的映像同為
    `ubuntu:26.04` 且發生在 create 之前;上游自己的
    `distrobox assemble create --dry-run --file box/dev.ini` 解析出名稱/映像正確
    的 create 指令;管理器 `create` 失敗時包裝器以非零結束、失敗訊息來自上游。
    一句話:**清單被真實 distrobox 1.8.2.5 解析成預期的 create 請求**。
  - **不證明什麼**:映像真的拉得下來、套件真的裝進盒(distrobox-init 在這裡從未
    執行,沒有任何容器被啟動)、盒子可用。這些交給下面的 real-engine 組。
  - gate:`just test system`(CI `test-system` job,必要;底層
    `./script/test/test.sh --system`)。
    `script/test/test.sh` 對每一層 bats gate 都要求「至少跑了一個案例、無失敗、無
    `skip`」,並在 `_required_specs` 明列該層的**必要 spec**,bats 跑之前逐檔確認
    存在且至少一個案例:必要 spec 被刪、被清空、被 skip 都**不會**因同層還有別的
    spec 而被當成綠燈(`test/unit/ci_gate_spec.bats` 以刪檔/空檔負向案例證明)。
- 系統,**real-engine 組**(`test/system/real_engine_spec.bats`):以**真正的
  docker 引擎**證明 M2 的「可用 dev 盒」承諾。做法是 **docker-in-docker**
  (2026-09-16 人類決策;三種做法的研究與比較見 issue #129):一個專用的系統測試
  runner 映像 `dockerfile/Dockerfile.system-real`,基底自 M3 issue #172 起從官方
  `docker:29.8.0-dind`(alpine)**改為 `ubuntu:26.04`**(ghostty 鏈案例需要真的
  ghostty 與無頭 X,而 ghostty 只有 26.04 有)。引擎與 dind 啟動機制**仍來自同一個
  鎖定的 `docker:29.8.0-dind`**:`/usr/local/bin`(dockerd、containerd、runc、
  docker CLI、`dockerd-entrypoint.sh`、`dind`,都是靜態 Go binary 或 POSIX shell)、
  `/usr/local/sbin/.iptables-legacy`(指向 `/usr/sbin` 的符號連結,由 ubuntu 的
  iptables 套件補齊)與 `/usr/local/libexec/docker/cli-plugins`(buildx / compose)
  全部 COPY 進來,所以巢狀 daemon 的**啟動方式沒有改變**;再加上 bash、bats 1.14.0
  (+ bats-support v0.3.0 / bats-assert v2.1.0)、ghostty + Xvfb + xauth + dbus-x11,
  與**同一份**鎖定的 distrobox 1.8.2.5(同一個 tarball、同一個 sha256、同一個上游
  安裝器)。

  **真正鎖定的是哪些**:`docker:29.8.0-dind`(tag)、distrobox 1.8.2.5
  (tarball + sha256 + 上游安裝器)、bats 1.14.0 與 bats-support v0.3.0 /
  bats-assert v2.1.0(git tag)、以及 `alpine:3.24` / `ubuntu:26.04` 這兩個基底的
  **tag**(tag 不是 digest,同一個 tag 的內容會隨上游 rebuild 變動)。
  **沒有鎖定的**:apt 裝進來的一切 —— ghostty、bash、iptables、Xvfb、
  `bsdextrautils` 等,全部拿 archive 當下的版本,沒有寫 `=<version>`。斷言只釘
  形狀(例如 ghostty 的 `major.minor`),所以 archive 更新不會立刻紅,但**這個
  映像不是逐位元可重現的**。

  這是**改基底,不是把整個 dind 映像搬過來**,而且它讓這個 gate 的語意變了,必須
  說清楚:

  - **host 側不再是 Alpine**。real-engine 組跑 worktool / distrobox host 端腳本的
    那一層,從 Alpine + busybox 換成 Ubuntu + GNU userland。**這個 gate 因此不再
    涵蓋 Alpine host 相容性**,而且較完整的 GNU userland可能**掩蓋**「少了某個
    工具」的問題 —— 這次就踩到一個實例:`distrobox-enter` 要用 `rev`,busybox
    內建、Debian/Ubuntu 拆進 `bsdextrautils`,必須點名安裝。換句話說:gate 變**寬**
    了,不是等價替換。worktool 交付的目標平台本來就是 Ubuntu(見 `design.md`),
    所以這個取捨是刻意的,但它不應該被說成「一樣」。
  - **沒有搬過來的東西**:dind 映像的 `dockremap` 使用者/群組與
    `/etc/subuid` / `/etc/subgid`。它們只服務 rootless dockerd 與 userns-remap;
    `script/test/system-real-entry.sh` 的 preflight 本來就要求 root,這裡的巢狀
    daemon 一律 rootful,所以**不在本 runner 的契約內**。真要驗 rootless 是另一
    個 issue 的事。
  - **ghostty(以及其他 apt 套件)沒有釘版本**:見上面「真正鎖定的是哪些」。
    ghostty 拿的是 26.04 archive 當下的版本(撰寫時 `1.3.0~us1-0ubuntu1.1`),
    斷言只釘 `major.minor` 形狀,所以**版本會漂移**;要完全可重現得改成釘
    `=<version>` 並自行承擔套件被移出 archive 的風險。
  - **iptables 的 legacy fallback 沒有獨立測試**:entrypoint 會先試現行
    `iptables`、失敗才退回 legacy。兩架構 CI 的真 dockerd 都成功啟動,證明目前的
    選擇可用,但沒有案例強制走 legacy 那條路。
  runner 以 `docker run --rm --privileged` 啟動(巢狀 dockerd 需要;**這是唯一
  使用 `--privileged` 的地方**),入口 `script/test/system-real-entry.sh` 在容器內
  背景啟動一個獨立的 dockerd(沿用 dind 映像自己的 `dockerd-entrypoint.sh`:
  cgroup v2 巢狀、`mount --make-rshared /`、tmpfs `/tmp`),有界等待 `docker info`
  就緒(逾時即帶著 daemon 日誌大聲失敗),再經 `test.sh --ci-system-real` 跑這支
  spec;結束時盡力 `distrobox rm -f dev` 並停掉 dockerd。測試建立的每個容器/映像/
  volume(`dev` 盒、`ubuntu:26.04`、盒子的 volume)都住在巢狀 daemon 裡(其
  `/var/lib/docker` 是 dind 映像宣告的匿名 volume),隨 runner 一起被 `--rm` 銷毀:
  **host 的 docker daemon 從頭到尾看不到 dev 盒、host 不安裝任何東西**。精確地說,
  host daemon 上**會**留下的只有:建出來的 runner 映像 `worktool-system-real:local`
  (含其基底 `docker:29.8.0-dind` 的層)與 Docker 建置快取 —— 和 `worktool-test:local`
  測試映像同一類、可用 `docker rmi` / `docker builder prune` 清掉;測試在巢狀
  daemon 內建立的東西則一件都不會留在 host 上。
  - **驗證什麼**:(a) 前置:runner 內真的有活著的引擎(`docker info`)、跑的是
    鎖定版 distrobox、巢狀 daemon 起初沒有 `dev`;(b) 以真實(非 dry-run)模式、
    `DBX_CONTAINER_MANAGER=docker`、**交付的** `box/dev.ini` 跑
    `script/box/assemble.sh`:exit 0、印出上游的 `Distrobox 'dev' successfully
    created.`、`docker ps -a` 恰好列出一個 `dev`,且它由 `ubuntu:26.04` 建出、帶
    `manager=distrobox` 標籤;(c) 盒子可用:`distrobox enter dev -- rg --version`
    印出 `ripgrep <版本>`(第一次 enter 會啟動容器並執行 distrobox-init:apt 安裝
    distrobox 依賴與 `ripgrep fzf tmux fish`,約 2 分鐘)、`distrobox enter dev --
    fzf --version` 印出版本,容器狀態為 `running`;M3(issue #160)再加兩個案例:
    `distrobox enter dev -- tmux -V` 印出 `tmux <版本>`、`distrobox enter dev --
    fish --version` 印出 `fish, version <版本>`,兩個版本都印進 TAP log 當證據
    (終端 profile 跑 `'<distrobox>' enter dev` 得到盒內 fish;tmux 是進盒後自己開的);(d) 進盒延遲 **gate**(M3,issues #150 / #23 / #160):對這個已初始化的
    盒子實跑 `script/box/bench.sh --box dev --runs 5 --warmup 2 --shell 'fish -c
    exit' --max-ms 300`(門檻為 spec 內唯一的 `ENTER_MAX_MS` 常數;shell 指標以盒內
    fish 為準),斷言 exit 0(shell 中位數超過 300 ms 即紅)、
    `enter: ...` / `shell: ...` / `inbox: ...` 三行指標存在(`inbox` 那行只有 timer
    真的在盒內跑過並印出整數才會出現)、bench.sh 的兩行 INFO 都釘在 fish:
    `[INFO] shell: ... of 'distrobox enter dev -- fish -c exit' done`
    與
    `[INFO] inbox: ... of 'distrobox enter dev -- bash -c <timer> bench-inbox fish -c exit' done`
    都存在(前者證明 host 端量的是 fish,後者證明盒內 timer 也真的啟動了 fish),且
    不得出現任何 `sh -c :` 的 INFO 行(spec 的 `_assert_fish_timed`;只釘 shell 那行
    證明不了盒內 timer 跑的是什麼)、`[INFO] shell median ... within --max-ms 300`
    判定行存在,並把數字印進 TAP log 當證據;再以 `--runs 1 --warmup 0 --shell
    'fish -c exit' --max-ms 1` 跑一次負向案例,要求 exit 1、三行指標仍在、同樣兩行
    fish INFO 仍在、`[ERROR] shell median ... exceeds --max-ms 1`,證明 gate 會咬
    (見上方「進盒延遲量測」);(e) **ghostty 鏈**(M3,issue #172):在 runner 內
    用 `xvfb-run -a`(`LIBGL_ALWAYS_SOFTWARE=1 GDK_BACKEND=x11`)開一個**真的
    ghostty 視窗**,設定檔由交付的 `lib/enter.sh` 組出**一個**受管區塊、並在區塊外
    釘住 `gtk-single-instance = false`,command 為
    `distrobox enter dev -- fish <盒內腳本>`(issue #179:中間沒有 tmux);判準是
    **盒內**留下的標記檔(內容含 `fish=<版本>`、`ctrenv=<容器檔>`、
    `mntns=<mount namespace>`、`tmux=no`、`host=<節點名>`),而不是 ghostty 的結束碼
    —— runner 本身沒有裝 fish(spec 明確斷言),所以會回答的只可能是盒內那一個;
    容器身分的斷言 Docker / Podman 通用:`ctrenv=` 必須是**所用引擎**寫進每個容器
    的檔案(podman `/run/.containerenv`、docker `/.dockerenv`,distrobox 自己也以
    兩者之一判定「在容器內」),且因為 DinD runner 本身也是 docker 容器、光看檔案
    分不出 runner 與盒子,`mntns=` 還必須等於引擎回報的 dev 容器 pid
    (`inspect --format '{{.State.Pid}}'`,兩個引擎同一個模板)的 mount namespace、
    且不是 runner 自己的;標記裡的 `host=` 還要等於
    `docker inspect dev` 報的 hostname。要講精確:標記檔位於**共享**的 bind-mount
    HOME,不是盒內私有命名空間;撐住「盒內執行」這個結論的是「runner 沒有 fish」
    +「每次啟動前先刪檔」+「整行格式由 fish 語法產生」+「hostname 對得上」這四
    件事,不是路徑本身。issue #179 再加 (e3) 三案,runner 上先開一個 host 端的
    tmux server(session `main`,舊命令 `-A` 會附著的名字;runner 映像因此裝了
    tmux):setup.sh 實際寫出的受管 command 原樣開窗、由 ghostty `input` 把 payload
    打進落地的 shell,標記檔仍須來自盒內 fish;盒內 `tmux` 得到盒子自己的 server
    (`TMUX_TMPDIR` 傳到盒內、pid 與 host server 不同、mount namespace 等於 dev
    容器、該行程的根目錄裡有引擎的容器檔、socket 在 `TMUX_TMPDIR` 底下、兩邊的
    `tmux ls` 互不列出對方的 session);第三案(codex 第 1 輪,PR #232)在 host
    tmux server 的**新視窗(真的 host pane)**裡執行 `distrobox enter dev`,先斷言盒內
    真的繼承了 host pane 的 `TMUX`(回歸情境確實發生),再斷言盒內 `tmux` 仍得到
    盒子自己的 server(同上各項),host 的 `tmux ls` 不列盒內的 session。
    另兩個負向案例:
    - **永不結束的指令**:盒內 payload **先寫一個獨立的 ready 標記**(內含
      `fish=<版本>`),**再** `exec sleep infinity`。案例只有在 ready 標記出現的
      前提下才接受 `timeout` 的 124 —— 否則就是「視窗/`distrobox enter` 在到達
      盒子前就卡住」這個**不同的**失敗,會以可辨識訊息紅掉,而不是被當成通過。
      另外斷言耗時**同時有上下界**(下界 = 預算 - 2s),證明它是跑滿預算才被砍,
      不是一啟動就死。
    - **假陽性示範**:`test/system/fixture/ghostty_single_instance.sh` 在一個
      `xvfb-run` + `dbus-run-session` 裡,讓每個 ghostty 視窗跑同一份 payload
      (寫在檔案裡,所以 payload 裡的 `$` / `(` / `)` 不必跟 ghostty 的設定解析
      搏鬥;設定只需要帶路徑,而那個路徑是**加單引號**的):一開始就把**自己的
      pid 與 starttime** 寫成一個獨一無二的檔(每一步都檢查,寫不出來就不往下
      走)、`sleep infinity`、跑完才會再寫一個 done 檔。

      為什麼是**單**引號:ghostty 1.3.0 的 `command` 若**沒有** `direct:` 前綴,
      存的是一條 **shell 命令列**、交給 `/bin/sh -c`,所以設定層的引用還要撐過
      第二層 shell 解析。拿 runner 映像裡的 ghostty 實測(payload 寫到固定路徑,
      只驗路徑的傳遞):

      | 形式 | 路徑含空白 | 路徑含 `$` | 路徑含反引號 |
      |------|-----------|-----------|-------------|
      | `direct:`(不引用) | 壞 | — | — |
      | shell + 雙引號 | 可 | **壞**(展開) | **壞**(命令替換被執行) |
      | shell + 單引號 | 可 | 可 | 可 |

      `direct:` 會跳過 shell,但它**完全不做引用處理**,所以帶不動含空白的路徑;
      雙引號則讓 `$` 展開、讓反引號**執行** —— 那是路徑形狀的注入。單引號三種
      都帶得動,因此採用它。單引號唯一帶不動的是單引號本身,`_check_workdir`
      拒絕它與換行(會終止設定行),並額外拒絕 `$` / 反引號 / 雙引號 / 反斜線
      作為縱深防禦(單引號內它們本來就是字面字元,但一旦引用形式改變就會變危險),
      每個字元各自給訊息。這個字元矩陣由 `test/unit/ghostty_fixture_spec.bats`
      在**單元層**驗證(fixture 的 `--check-workdir` 模式不需要顯示器或 ghostty),
      不必等慢的 system-real。
      於是實地**觀測**:`gtk-single-instance = true` 時第二次啟動 ghostty
      **遠比它要求的指令可能耗費的時間更快就返回 0**(`SECOND_ELAPSED` 斷言
      0-15 秒;門檻放寬是為了不讓慢 runner 假紅,要證明的是「沒有等那個指令」,
      而那個指令永不結束,不是「一定幾秒內」),而**在它返回後隨即取樣時,它要求
      的工作還沒開始**(`STARTED_AT_RETURN=1`)。

      這個取樣**不是返回瞬間的原子快照**:先取時間戳、再讀計數,中間隔著兩個
      subshell。方向上只會害自己 —— 轉交的指令若快到擠進這個空檔,計數會讀到 2
      而讓案例**紅**,不可能因此變綠。順序則是**量出來的**:第二個 start 檔的
      mtime 嚴格晚於上面那個時間戳(`FORWARDED_AFTER_RETURN=yes`,實測延遲約
      300-400 ms),不是靠「腳本後看才寫後發生」推論;同毫秒不算晚(嚴格 `>`),
      所以精度不足只會假紅。**未檢查**的是 workdir 所在檔案系統的 mtime 粒度:
      若某天落在只有秒級粒度的掛載上,這個比較會大量假紅(仍不會假綠)。

      此時這一輪的兩個視窗指令都還在跑(`RUNNING_COMMANDS=2`):對每個指令**自己
      記下的 pid** 檢查「行程還在 + starttime 與當初相同(排除 pid 被重用)+
      狀態不是 `Z`(排除 zombie)」;只用 `kill -0` 這兩種情況都會誤判成活著,
      而掃行程名或命令列更不行 —— DinD 下巢狀容器與 runner 同一個 PID namespace,
      數 `sleep` 會把 dev 盒裡的殘留算進去(實測 4),`pgrep -f` 則會連引用到該
      字串的 harness 一起算(實測 5)。持有 bus name 的 ghostty 行程也仍在
      (`PRIMARY_WRAPPER_ALIVE=yes` —— 這驗的是**包裝行程**,不是指令自己的
      shell;指令有沒有開始由 `STARTED_AT_RETURN` 說了算)、且**沒有任何視窗指令
      跑完**(`COMMAND_FINISHED=no`,由 done 檔數量觀測而來,不是固定輸出)。
      時間戳一律走 `date +%s%N`(26.04 的 uutils `date` 接受 `%3N` 但**忽略
      寬度**、照印九位,信任格式字串會少算 10^6 倍),並在用之前驗證:必須**恰好
      19 位**數字(不支援 `%N` 的 `date` 會把字母原樣印出來),而且**不得大於
      2^63-1** —— 位數不等於範圍檢查,`9223372036854775808` 到
      `9999999999999999999` 都是 19 位但會讓 bash 算術 **wrap**(實測
      `9223372036854775808` 會變成 `-9223372036854`);epoch 奈秒是 **2262 年**
      越過 2^63-1,不是等變成 20 位。上界比較拆成兩半各自比,所以檢查本身不會
      wrap;毫秒值則直接砍掉末六位取得,不對 19 位數做除法。這兩件事同樣由
      `test/unit/ghostty_fixture_spec.bats`(fixture 的 `--check-epoch-ms` 模式)
      在單元層驗證。
      這就是「拿結束碼當成功判準」的假陽性,也是每個案例都釘
      `gtk-single-instance = false`、都以標記檔為證的原因。
    三層防卡:
    設定不覆寫 `wait-after-command` / `quit-after-last-window-closed`(讓 ghostty
    自己在指令結束後退出)、每個 ghostty 呼叫外層 `timeout -k`、CI job 的
    `timeout-minutes`;(f) 冪等:第二次
    `script/box/assemble.sh` exit 0、印上游的 `dev already exists`、不重建、`dev` 仍
    恰好一個、仍可 `rg --version`;(g) 清理:`distrobox rm -f dev` exit 0 後
    `docker ps -a` 不再有 `dev`。長步驟都包在有界的 `timeout` 裡(assemble 600s、
    第一次 enter 900s、其餘 300s/120s),失敗時印出 dockerd 日誌與盒子的
    `docker logs`。環境隔離同 shim 組:全新的 HOME(因盒子會 bind-mount HOME、
    且要跨案例存活,放在 per-file 的 `BATS_FILE_TMPDIR`)、
    `DBX_CONTAINER_GENERATE_ENTRY=0`。distrobox 在 runner 內以 root 執行(uid 0),
    上游視為「以 root 登入的 rootful」:不會前綴 sudo、盒內使用者即 root、HOME
    為上述全新目錄;這對本證明沒有影響,一般使用者(非 root)的情境留給 M3/M5 與
    人類清單。一句話:**交付的清單經真實 distrobox 1.8.2.5 與真實 docker 引擎,
    建出可用的 dev 盒(ubuntu:26.04 + ripgrep + fzf + tmux + fish)**。
  - **驗證邊界(套件何時裝好)**:distrobox 的 `assemble create` 只負責 `pull` 與
    `create`(建立容器、把 `--additional-packages` 交給盒內 entrypoint);套件
    初始化(apt 安裝 distrobox 依賴與 `ripgrep fzf tmux fish`)是由 distrobox-init
    在**第一次 `distrobox enter`** 啟動容器時執行的。因此這組測試證明的是
    「**assemble 成功後,enter 會完成初始化、工具可用**」,**不是**「assemble 返回時
    套件已安裝完成」—— 只跑 `script/box/assemble.sh` 而不 enter,盒內還沒有 `rg` /
    `fzf` / `tmux` / `fish`。
  - **不證明什麼(延後)**:**實機**的進盒延遲(gate 判定的是 CI runner 上 DinD
    內的盒子;實機數字進人類清單,#22)、終端自動進盒(M3)、更廣的環境矩陣
    (真實硬體、非 root 使用者、GPU 等,M5 與人類清單)。
  - gate:`just test system-real`(CI `test-system-real` job,必要,被
    `ci-passed` 彙總要求;慢,約 2-3 分鐘、CI 上限 40 分鐘;底層
    `./script/test/test.sh --system-real`)。同樣適用
    「至少一個案例、無失敗、無 `skip`、必要 spec 不存在或被清空即失敗」的規則。
- 交付/驗收(`test/acceptance/m2_selfcheck_spec.bats`):
  - **驗證什麼**:以使用者拿到交付品的方式驗證 —— 直接執行交付的公開入口
    **`script/test/selfcheck.sh`**(`just test selfcheck` 呼叫的就是這支,也就是
    下方 3g 要使用者跑的那支;測試**不**在 bats 裡重寫它的檢查),斷言它 exit 0 且印出
    `ALL PASS`(3a/3b 的 dry-run 契約 + 3c-3e
    七個無效清單的拒絕,共 9 個 `PASS`),從 repo 內或 repo 外執行皆然;並以負向
    案例證明它的判定不是空的:清單壞掉(缺 image)時、以及包裝器被換成「跳過驗證、
    永遠印成功指令」的版本時,都必須報 `SOME FAILED` 且 exit 1;`--root` 指到
    不是 worktool checkout 的目錄時給出清楚錯誤。
  - **不證明什麼(延後)**:真實硬體上的盒子(效能目標、非 root 使用者、GPU 等)——
    留在下方「M2 驗收紀錄」的人類清單與 **M3/M5**;「盒子可用」本身已由系統層
    real-engine 組在 CI 內證明。
  - gate:`just test acceptance`(CI `test-acceptance` job,必要;底層
    `./script/test/test.sh --acceptance`)。

所有測試都在 Docker 內執行(host 不安裝任何套件);裸 `just test`(底層
`./script/test/test.sh` 不帶旗標)依序跑 lint 與五個 tier(lint、unit、integration、
system、acceptance、system-real),遇到第一個失敗即停,等同 CI;子 recipe
`just test <tier>` 只收窄到一層。執行方式見 [`structure.md`](structure.md)。

## M2 驗收紀錄(人類清單)

M2 的人類 gate 依此表逐項填寫。「版本(commit)」填當時審核的 commit SHA;「結果」
填 PASS / FAIL / 延後;「證據」填可回溯的連結或指令輸出。**能自動化的已自動化**
(三列全部由 CI、`script/test/selfcheck.sh` 與 CI 內的 docker-in-docker 系統測試產生
證據);仍需要真實機器的部分(效能、非 root、GPU)誠實留給 M3/M5。

| 項目 | 版本(commit) | 環境 | 預期 | 結果 | 證據 |
|------|--------------|------|------|------|------|
| 自動化全綠(lint + unit + integration + system + system-real + acceptance) | main(#146 合併後;審核時填 SHA) | GitHub Actions `ubuntu-latest`;Docker 測試映像 `worktool-test:local`(alpine + bash + bats + shellcheck + distrobox 1.8.2.5)與 DinD runner `worktool-system-real:local`(docker:29.8.0-dind + bash + bats 1.14.0 + distrobox 1.8.2.5) | `ci-passed` 綠:五個 matrix gate 與 `test-system-real` 皆 `success`,無 skip、無零案例 | 待審核填寫 | main 最新 run 的 checks(`ci-passed` job 記錄;`gh pr checks 146`) |
| 一鍵自檢 `just test selfcheck`(= `./script/test/selfcheck.sh`)印出 `ALL PASS` | main(#146 合併後;審核時填 SHA) | 任一有 bash + just 的機器(clone 後於 repo 根目錄執行;不需 distrobox;沒有 just 時直接跑 `./script/test/selfcheck.sh`) | 9 個 `PASS` 行 + `ALL PASS`、exit 0 | 待審核填寫 | 貼上 `just test selfcheck; echo rc=$?` 的輸出 |
| 真實可用盒(`script/box/assemble.sh` 真建盒 -> `distrobox enter dev -- rg --version` / `fzf --version` 可執行、第二次 assemble 冪等、`distrobox rm -f dev` 可清理;M3 #160 起再加 `tmux -V` / `fish --version`) | main(#146 合併後;審核時填 SHA) | CI 內 docker-in-docker(`test-system-real` job;`docker run --rm --privileged` 的 runner,巢狀 dockerd + 真實 distrobox 1.8.2.5 + 真實 `ubuntu:26.04`);本機 `just test system-real` 同一 runner | `test/system/real_engine_spec.bats` 全部案例 `ok`(M2 時 8 案例;M3 加 bench gate 兩案例與 tmux / fish 兩案例後為 12):盒子由 `ubuntu:26.04` 建出、第一次 `distrobox enter` 完成初始化後 `ripgrep` / `fzf`(M3 起再加 `tmux` / `fish`)版本可印出(驗證邊界:套件在第一次 enter 時安裝,不是 assemble 返回時就裝好)、冪等、可清理;巢狀 daemon 內的容器/映像/volume 隨 runner 銷毀,host daemon 只留 runner 映像 `worktool-system-real:local` 與建置快取 | **已由自動化驗證**(不再延後 M5;M5 保留更廣的環境矩陣) | `test-system-real` job 記錄(TAP `1..N` 全 `ok`、結尾 `[ci] system-real bats OK`);本機同指令輸出 |

## 如何人工驗證(M2,從 clone 到 assemble)

以下是從零開始、端到端親自複驗 M2(盒子清單格式 + 最小 assemble 包裝器)的完整流程。
全程只需要 **docker** 與 **just**:`just` 是使用者的通用介面(命令模型比照 base
ADR-00000005/10/11,見 [`design.md`](design.md)「決策」),所有步驟都以 `just ...`
執行;每一步之後以一行 `# 底層:...` 標出 recipe 實際轉發到的腳本(沒有 `just` 時
可直接執行那一行)。不需要在 host 裝 `distrobox`(系統測試用的 distrobox 已鎖定版本、
烘進測試映像與 DinD runner;真實可用盒的驗證也在 Docker 內完成)。每個指令都可直接
複製貼上。

### 0. 前置

- 已安裝並可用 docker,且**目前使用者**可直接執行(例如 `docker run --rm hello-world`
  能成功),不需要 `sudo`。
- 已安裝 `just`(`just --version` 可執行)。M4 host bootstrap 起會由 install script
  一併安裝;在那之前是前置需求,請自行安裝。
- 不需要 root、host 上不需要 `distrobox`。

### 1. 取得原始碼

```bash
git clone https://github.com/ycpss91255/worktool.git
cd worktool
```

### 2. 自動測試(全部在 Docker 內,不需 distrobox)

入口是 `just`:裸 `just` 列出 namespaces(`test`、`box`)與各自的一行說明(`test`
那一行就列了全部子 recipe);裸 `just test` **不是列表**,而是直接跑全部;腳本層的
usage 用 `just test help`。第一次可先建測試映像,再依序跑六道 gate;每一步下一行的
`# 底層:` 標出 recipe 實際轉發到的腳本(沒有 `just` 時可直接執行那一行):

```bash
just test build         # (選用) 先建 worktool-test:local 測試映像
# 底層:./script/test/test.sh --build
just test lint          # ShellCheck(*.sh + *.bats)
# 底層:./script/test/test.sh --lint
just test unit          # 單元 bats(test/unit/)
# 底層:./script/test/test.sh --unit
just test integration   # 整合 bats(test/integration/;兩組:預設組 + ghostty 組,後者在 ubuntu:26.04 的 ghostty 映像內,不需顯示器)
# 底層:./script/test/test.sh --integration
just test system        # 系統 bats,shim 組(test/system/;真實 distrobox + 假容器管理器)
# 底層:./script/test/test.sh --system
just test acceptance    # 驗收 bats(test/acceptance/;跑交付的 script/test/selfcheck.sh)
# 底層:./script/test/test.sh --acceptance
just test system-real   # 系統 bats,real-engine 組(docker-in-docker,--privileged;慢,約 2-3 分鐘)
# 底層:./script/test/test.sh --system-real
```

一次跑完:裸 `just test`(底層 `./script/test/test.sh` 不帶旗標;依序 lint、unit、
integration、system、acceptance、system-real,遇到第一個失敗即停,和 CI 跑的一模一樣)。
子 recipe 只收窄:`just test <tier>` 只跑那一層。打錯 recipe 名(例如 `just test bogus`)
得到的是 `just` 自己的錯誤「Justfile does not contain recipe `bogus`」、exit 1,什麼都
不跑;justfile 本身不印 usage,說明由腳本提供(`just test help`,底層
`./script/test/test.sh --help`)。

- `just test build` 是選用的:後面的 gate 若發現映像不存在會自動建。想先暖快取、或快速驗
  Dockerfile 有沒有壞掉,才需要先手動 `just test build`。`just test system-real` 每次都會
  (以快取)建 `worktool-system-real:local` runner 映像,並以 `docker run --rm
  --privileged` 執行;這是唯一需要 `--privileged` 的 gate。結束後,測試在巢狀 daemon
  內建立的容器、映像與 volume(`dev` 盒、`ubuntu:26.04`)都隨 runner 銷毀、不會出現
  在 host daemon 上;host daemon 上留下的只有 runner 映像 `worktool-system-real:local`
  (含 `docker:29.8.0-dind` 基底層)與 Docker 建置快取,和 `worktool-test:local` 同一類。
- 預期輸出:
  - `just test lint`:結尾出現 `[ci] ShellCheck OK`,沒有任何 ShellCheck 違規。
  - `just test unit`:所有測項 `ok`(涵蓋缺 image / 缺名稱 / 檔案不存在 / 純空白名稱 /
    單或雙引號內純空白 image / 引號不成對的 image / image 出現在區段之前 / 多區段
    等案例),結尾 `[ci] unit bats OK`。
  - `just test integration`:所有測項 `ok`(含「無效 manifest(缺 image、引號不成對)
    絕不呼叫 distrobox」負向測試),結尾 `[ci] integration bats OK`。
  - `just test system`:所有測項 `ok`(真實 distrobox 1.8.2.5 把 `box/dev.ini` 解析成
    帶 `dev` / `ubuntu:26.04` / `ripgrep fzf tmux fish` 的 create 請求;管理器失敗會
    傳回非零),
    結尾 `[ci] system bats OK`。
  - `just test acceptance`:所有測項 `ok`(交付的 `script/test/selfcheck.sh` 對交付的
    repo 印 `ALL PASS`;壞清單 / 跳過驗證的包裝器被判 `SOME FAILED`),結尾
    `[ci] acceptance bats OK`。
  - `just test system-real`:先看到 `[system-real] dockerd ready after Ns` 與
    `[system-real] engine 29.8.0 ...`,接著 `1..12` 且 12 項全 `ok`(建盒、第一次 enter
    完成初始化後 `rg --version`、`fzf --version`、`tmux -V`、`fish --version`、以 fish
    量的進盒延遲 gate 與其負向案例、冪等、`distrobox rm`),結尾
    `[ci] system-real bats OK`、`[system-real] cleanup: containers left in the nested
    daemon: 0`。
- 任一 gate 失敗會以 `[ci] ERROR: ...` 與非零結束碼結束;bats gate 若有案例被 `skip`
  、根本沒跑到任何案例、或該層任一必要 spec 缺檔/零案例(每層先印
  `[ci]   required specs OK (N case(s) declared by M file(s))` 才開始跑),同樣視為失敗。

### 3. 手動驗證 assemble 包裝器(不需 distrobox,用 dry-run)

使用者介面是 `just box assemble --dry-run [--file <manifest>]`(3a 用預設清單;指定
其他清單加 `--file <manifest>`)。recipe 把參數原樣轉發給 `script/box/assemble.sh`,
所以 3b-3f 驗證的雖然是**腳本層本身的行為**(路徑解析、`--file` 旗標、清單驗證),
但都可以經 `just box assemble --dry-run --file <x>` 到達;只有 3b 例外(見該步說明)。
人類驗收清單(`doc/acceptance.md` M2 節)全部以 `just` 形式提供對應步驟。
`WORKTOOL_DRY_RUN=1`(或 `--dry-run`)會把「將要執行的 distrobox 指令」印到
**STDOUT** 而**不執行**;診斷訊息一律走 STDERR。指定清單的旗標是 **`--file`**
(不是 `--manifest`)。下面每步都保持在 repo 根目錄執行(除了 3b 特意換到別的目錄)。

**3a. 正常 dry-run(從 repo 根目錄)**

```bash
just box assemble --dry-run
# 底層:./script/box/assemble.sh --dry-run(或 WORKTOOL_DRY_RUN=1 ./script/box/assemble.sh)
```

預期(從 repo 根目錄執行時,預設清單保留相對路徑,且不呼叫 distrobox):

```text
distrobox assemble create --file box/dev.ini
```

**3b. 從 repo 以外呼叫(驗證路徑一致)**

這一步驗證的是**腳本層**的路徑解析:目前目錄找不到 `box/dev.ini` 時回退到 repo 內的
絕對路徑。經 `just` 執行時 recipe 一律在 repo 根目錄執行(module 的
`set working-directory := '../..'`),看到的永遠是 3a 的相對路徑,所以這一步刻意
直接呼叫腳本(`just test selfcheck` 的 `PASS 3b` 也是這樣驗的):

```bash
cd /tmp
WORKTOOL_DRY_RUN=1 bash /path/to/worktool/script/box/assemble.sh   # 換成你的 repo 絕對路徑
```

預期:目前目錄找不到 `box/dev.ini`,包裝器會回退到 repo 內的**絕對路徑**(repo 根
= 腳本往上兩層),而且驗證與 dry-run 輸出用的是同一條解析後的路徑(三者一致):

```text
distrobox assemble create --file /path/to/worktool/box/dev.ini
```

**3c. 無效清單(缺 image)應被拒,且完全不呼叫 distrobox**

```bash
printf '[dev]\n' > /tmp/bad.ini
just box assemble --dry-run --file /tmp/bad.ini; echo "exit=$?"
# 底層:./script/box/assemble.sh --dry-run --file /tmp/bad.ini
```

預期:STDERR 印出
`[ERROR] manifest missing required key 'image' in section [dev]: /tmp/bad.ini`、
STDOUT 為空、`exit=1`,而且完全不呼叫 distrobox(驗證在 dry-run 之前就失敗,
`--dry-run` 只是再保險一層)。

**3d. 空白繞過與不成對引號應被拒**

```bash
printf '[   ]\nimage=ubuntu:26.04\n'   > /tmp/ws-name.ini    # 純空白名稱
printf '[dev]\nimage="   "\n'           > /tmp/ws-img.ini     # 雙引號內純空白
printf '[dev]\nimage= "   "\n'          > /tmp/ws-img2.ini    # 空格後才是引號
printf "[dev]\nimage='   '\n"           > /tmp/ws-img3.ini    # 單引號內純空白
printf "[dev]\nimage='ubuntu:26.04\"\n" > /tmp/unbalanced.ini # 引號種類不一致
for f in /tmp/ws-name.ini /tmp/ws-img.ini /tmp/ws-img2.ini /tmp/ws-img3.ini /tmp/unbalanced.ini; do
  just box assemble --dry-run --file "$f"; echo "  ($f) exit=$?"
done
# 底層:./script/box/assemble.sh --dry-run --file "$f"
```

預期:五者都以 `exit=1` 被拒,且完全不呼叫 distrobox。名稱與 image 值都會先去除
前後空白再判斷是否為空,成對的單/雙引號一視同仁、不成對的引號是格式錯誤(見
「驗證規則」的引號規則),因此:
- `[   ]` 判為缺盒子名稱:`[ERROR] manifest missing box name ...`。
- `image="   "`、`image= "   "` 與 `image='   '` 都判為缺 image:
  `[ERROR] manifest missing required key 'image' ...`。
- `image='ubuntu:26.04"` 判為引號不成對:
  `[ERROR] manifest image value has an unbalanced quote: 'ubuntu:26.04" (section [dev]): /tmp/unbalanced.ini`。
  單獨一個引號(`image='`)或只有一邊有引號(`image="ubuntu:26.04`)也是同一個訊息。

**3e. 多區段應被拒(單一盒子規則)**

```bash
printf '[dev]\nimage=ubuntu:26.04\n[other]\nimage=debian:13\n' > /tmp/multi.ini
just box assemble --dry-run --file /tmp/multi.ini; echo "exit=$?"
# 底層:./script/box/assemble.sh --dry-run --file /tmp/multi.ini
```

預期:`[ERROR] manifest declares multiple sections; worktool supports a single box: ...`、`exit=1`。

**3f. 含空白/特殊字元的清單路徑(路徑安全)**

dry-run 輸出採逐一參數的 `%q` 跳脫,所以含空白、`;` 或 `$()` 的路徑會被表示成單一安全
參數,可直接複製貼上忠實重跑,不會被再次拆分或解讀。這也是腳本層的行為,經
`just box assemble --dry-run --file '<含空白的路徑>'` 到達(`just` 把整個引號內的值
當一個參數原樣轉發;底層 `./script/box/assemble.sh --dry-run --file '<含空白的路徑>'`)。

**3g. 一鍵自檢(交付的公開入口)**

想一次跑完上面 3a-3e 的斷言,執行 `just test selfcheck`,它呼叫交付的自檢腳本
[`script/test/selfcheck.sh`](../script/test/selfcheck.sh)(只需要 bash;不需要
distrobox、不動 host):

```bash
just test selfcheck; echo "rc=$?"
# 底層:./script/test/selfcheck.sh; echo "rc=$?"
```

預期輸出(每項一行 `PASS`,結尾 `ALL PASS`、`rc=0`):

```text
[INFO] self-checking /path/to/worktool
PASS 3a
PASS 3b
PASS reject no-image.ini
PASS reject blank-name.ini
PASS reject blank-image.ini
PASS reject spaced-image.ini
PASS reject single-quoted-image.ini
PASS reject unbalanced-quote-image.ini
PASS reject multi.ini
ALL PASS
rc=0
```

任一項不符會印 `FAIL <項目>: rc=... stdout='...' stderr='...'`,結尾 `SOME FAILED`、
`rc=1`。腳本預設檢查它自己所在的 checkout,從任何目錄執行都可以;要檢查另一份
checkout 用 `just test selfcheck --root <repo>`(`--root` 原樣傳給腳本;底層
`./script/test/selfcheck.sh --root <repo>`;指到不是 worktool checkout 的目錄會以
`[ERROR]`、`rc=2` 結束)。驗收層測試(`test/acceptance/`)跑的就是這支腳本,
並且以「清單壞掉」與「包裝器跳過驗證」兩個負向案例證明它會誠實地報 `SOME FAILED`。

### 4. 真實 assemble(已自動化;host 上手動為選用)

「映像拉得下來、套件裝得進去、盒子可用」已由系統層 real-engine 組在 Docker 內以真實
docker 引擎證明(`just test system-real`,見「測試對應」),host 不需要 distrobox。
若手邊已有 docker + distrobox、想在 host 上主觀確認,可拿掉 `--dry-run` 實際建出 dev 盒
(這會在 host 的 docker 上留下 `dev` 容器,用 `distrobox rm -f dev` 清掉):

```bash
just box assemble         # 需要 PATH 上有 distrobox;否則會以 [ERROR] ... 與 exit=127 結束
# 底層:./script/box/assemble.sh
distrobox enter dev -- rg --version
distrobox enter dev -- fzf --version
distrobox enter dev -- tmux -V
distrobox enter dev -- fish --version
distrobox rm -f dev
```
