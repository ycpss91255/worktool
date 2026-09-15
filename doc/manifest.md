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
additional_packages="ripgrep fzf"
```

### worktool 要求的必要鍵

M2 的 assemble 包裝器(`script/assemble.sh`)在動作前會驗證清單,最少需要:

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
  `image="   "` 這種(引號內只有空白)會被當成空的 image。名稱與 image 值都會
  先去除前後空白再判斷是否為空。

### 常用的 distrobox-assemble 欄位(可用,非必要)

沿用 distrobox 原生語意,常見的還有:

- `additional_packages`:要在盒內安裝的套件(空白分隔、以引號包起)。
- `init_hooks` / `pre_init_hooks`:建立盒子後 / 前執行的指令。
- `additional_flags`:傳給容器管理器的額外旗標。
- `volume`、`exported_apps`、`exported_bins`、`start_now`、`nvidia`、`pull`、
  `root`、`entry` 等。

完整欄位以 distrobox 官方 `distrobox-assemble` 文件為準。M2 的 dev 盒刻意只放
1-2 個工具(ripgrep、fzf)以驗證 assemble 流程;完整工具集在 M5-M10 逐步移植
(見 [`design.md`](design.md) 的 milestone 計畫)。

## assemble 流程

`script/assemble.sh` 是一層薄而穩健的包裝器,行為如下:

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
distrobox,由 distrobox 自己管理容器。

### 用法

```bash
# 試跑:只印出指令,不執行(單元測試就是斷言這個輸出)
./script/assemble.sh --dry-run
# -> distrobox assemble create --file box/dev.ini

# 以環境變數試跑
WORKTOOL_DRY_RUN=1 ./script/assemble.sh

# 指定其他清單
./script/assemble.sh --file box/other.ini

# 實際 assemble(需要 host 上有 distrobox)
./script/assemble.sh
```

## 測試對應

四層測試金字塔見 [`design.md`](design.md)「測試策略」。M2 落地:

- 單元(`test/unit/manifest_spec.bats`、`test/unit/assemble_spec.bats`):清單驗證
  (有效通過;缺 image / 缺名稱 / 檔案不存在 / 純空白名稱 / 引號內純空白 image /
  image 出現在區段之前 / 多區段皆以正確訊息失敗)與指令組裝(dry-run 印出正確的
  `distrobox assemble create --file ...`,且不執行;從 repo 以外執行時輸出解析後的
  絕對路徑;含空白與 shell 特殊字元的路徑經跳脫後可還原成單一參數)。純 bash、
  完全可 mock。
- 整合(`test/integration/assemble_spec.bats`):把一支 **mock `distrobox`** 放到
  PATH(**逐一參數**、每行一個地記錄自己被呼叫的參數),以真實(非 dry-run)模式跑
  包裝器,斷言它確實以 `assemble create --file <解析後的清單>` 呼叫 distrobox;另外
  斷言「從 repo 以外執行會傳入解析後的絕對路徑」以及「清單無效時完全不呼叫
  distrobox 且以非零結束」。證明端到端接線,而不需要真正的 distrobox。
- 系統(`test/system/real_assemble_spec.bats`):在測試映像內執行**真正的、鎖定
  版本的 distrobox**(`dockerfile/Dockerfile.test` 固定 `1.8.2.5`,建置時驗證
  tarball 的 sha256),容器管理器則換成一支**假的 `docker`**
  (`test/system/fixture/fake_container_manager.sh`,以
  `DBX_CONTAINER_MANAGER=docker` 選用、symlink 到 PATH 最前面):它回答 distrobox
  實際會發出的探測(`ps` / `inspect` / `pull` / `create`)、**逐一參數**
  (NUL 分隔,非 `$*`)記錄每一次呼叫、遇到不支援的子指令一律以非零失敗(不是
  一律 exit 0),並可用 `FAKE_CM_FAIL_CREATE=1` 注入 `create` 失敗。**不需要
  docker-in-docker**。
  - **驗證什麼**:以真實(非 dry-run)模式跑包裝器,斷言**真正抵達容器管理器的
    create 請求**帶有容器名 `dev`、映像 `ubuntu:26.04`(緊接在
    `--entrypoint /usr/bin/entrypoint` 之後),且清單的 `additional_packages`
    (`ripgrep fzf`)被 distrobox 交給盒內 entrypoint(distrobox-init)的
    `--additional-packages`(位於映像之後、恰好一次);`pull` 請求的映像同為
    `ubuntu:26.04` 且發生在 create 之前;上游自己的
    `distrobox assemble create --dry-run --file box/dev.ini` 解析出名稱/映像正確
    的 create 指令;管理器 `create` 失敗時包裝器以非零結束、失敗訊息來自上游。
    一句話:**清單被真實 distrobox 1.8.2.5 解析成預期的 create 請求**。
  - **不證明什麼(延後)**:映像真的拉得下來、套件真的裝進盒(distrobox-init 在
    這裡從未執行,沒有任何容器被啟動)、盒子可用
    (`distrobox enter dev -- rg --version`)。這些需要真正的容器管理器(CI 內
    DinD),依 [`design.md`](design.md) 延後到 **M5**。
  - gate:`just -f justfile.ci test-system`(CI `test-system` job,必要)。
    `script/ci/ci.sh` 對每一層 bats gate 都要求「至少跑了一個案例、無失敗、無
    `skip`」,被 skip 或不存在的必要案例**不會**被當成綠燈。

所有測試都在 Docker 內執行(host 不安裝任何套件);執行方式見
[`structure.md`](structure.md)。

## 如何人工驗證(M2,從 clone 到 assemble)

以下是從零開始、端到端親自複驗 M2(盒子清單格式 + 最小 assemble 包裝器)的完整流程。
全程只需要 **docker**:不需要安裝 `just`(`justfile.ci` 只是 `./script/ci/ci.sh` 的薄
包裝),也不需要在 host 裝 `distrobox`(系統測試用的 distrobox 已鎖定版本、烘進測試
映像;真實可用盒的驗證延到 M5)。每個指令都可直接複製貼上。

### 0. 前置

- 已安裝並可用 docker,且**目前使用者**可直接執行(例如 `docker run --rm hello-world`
  能成功),不需要 `sudo`。
- 不需要 root、不需要 `just`、host 上不需要 `distrobox`。

### 1. 取得原始碼

```bash
git clone https://github.com/ycpss91255/worktool.git
cd worktool
git checkout m2-manifest   # 審 M2 PR 用此分支;合併進 main 後改用 main 即可
```

### 2. 自動測試(全部在 Docker 內,不需 just / distrobox)

入口是 `./script/ci/ci.sh`。第一次可先建測試映像,再依序跑四道 gate:

```bash
./script/ci/ci.sh --build              # (選用) 先建 worktool-test:local 測試映像
./script/ci/ci.sh --lint-only          # ShellCheck(*.sh + *.bats)
./script/ci/ci.sh --unit-only          # 單元 bats(test/unit/)
./script/ci/ci.sh --integration-only   # 整合 bats(test/integration/)
./script/ci/ci.sh --system-only        # 系統 bats(test/system/;真實 distrobox + 假容器管理器)
```

- `--build` 是選用的:後面的 gate 若發現映像不存在會自動建。想先暖快取、或快速驗
  Dockerfile 有沒有壞掉,才需要先手動 `--build`。
- 預期輸出:
  - `--lint-only`:結尾出現 `[ci] ShellCheck OK`,沒有任何 ShellCheck 違規。
  - `--unit-only`:所有測項 `ok`(涵蓋缺 image / 缺名稱 / 檔案不存在 / 純空白名稱 /
    引號內純空白 image / image 出現在區段之前 / 多區段等案例),結尾 `[ci] unit bats OK`。
  - `--integration-only`:所有測項 `ok`(含「無效 manifest 絕不呼叫 distrobox」負向
    測試),結尾 `[ci] integration bats OK`。
  - `--system-only`:所有測項 `ok`(真實 distrobox 1.8.2.5 把 `box/dev.ini` 解析成
    帶 `dev` / `ubuntu:26.04` / `ripgrep fzf` 的 create 請求;管理器失敗會傳回非零),
    結尾 `[ci] system bats OK`。
- 任一 gate 失敗會以 `[ci] ERROR: ...` 與非零結束碼結束;bats gate 若有案例被 `skip`
  或根本沒跑到任何案例,同樣視為失敗。

### 3. 手動驗證 assemble 包裝器(不需 distrobox,用 dry-run)

`WORKTOOL_DRY_RUN=1` 會把「將要執行的 distrobox 指令」印到 **STDOUT** 而**不執行**;
診斷訊息一律走 STDERR。指定清單的旗標是 **`--file`**(不是 `--manifest`)。下面每步都
保持在 repo 根目錄執行(除了 3b 特意換到別的目錄)。

**3a. 正常 dry-run(從 repo 根目錄)**

```bash
WORKTOOL_DRY_RUN=1 bash script/assemble.sh
```

預期(從 repo 根目錄執行時,預設清單保留相對路徑,且不呼叫 distrobox):

```text
distrobox assemble create --file box/dev.ini
```

**3b. 從 repo 以外呼叫(驗證路徑一致)**

```bash
cd /tmp
WORKTOOL_DRY_RUN=1 bash /path/to/worktool/script/assemble.sh   # 換成你的 repo 絕對路徑
```

預期:目前目錄找不到 `box/dev.ini`,包裝器會回退到 repo 內的**絕對路徑**,而且驗證與
dry-run 輸出用的是同一條解析後的路徑(三者一致):

```text
distrobox assemble create --file /path/to/worktool/box/dev.ini
```

**3c. 無效清單(缺 image)應被拒,且完全不呼叫 distrobox**

```bash
printf '[dev]\n' > /tmp/bad.ini
bash script/assemble.sh --file /tmp/bad.ini; echo "exit=$?"
```

預期:STDERR 印出
`[ERROR] manifest missing required key 'image' in section [dev]: /tmp/bad.ini`、
STDOUT 為空、`exit=1`,而且完全不呼叫 distrobox。

**3d. 空白繞過應被拒**

```bash
printf '[   ]\nimage=ubuntu:26.04\n' > /tmp/ws-name.ini   # 純空白名稱
printf '[dev]\nimage="   "\n'         > /tmp/ws-img.ini    # 引號內純空白
printf '[dev]\nimage= "   "\n'        > /tmp/ws-img2.ini   # 空格後才是引號
for f in /tmp/ws-name.ini /tmp/ws-img.ini /tmp/ws-img2.ini; do
  bash script/assemble.sh --file "$f"; echo "  ($f) exit=$?"
done
```

預期:三者都以 `exit=1` 被拒。名稱與 image 值都會先去除前後空白再判斷是否為空,因此:
- `[   ]` 判為缺盒子名稱:`[ERROR] manifest missing box name ...`。
- `image="   "` 與 `image= "   "` 判為缺 image:`[ERROR] manifest missing required key 'image' ...`。

**3e. 多區段應被拒(單一盒子規則)**

```bash
printf '[dev]\nimage=ubuntu:26.04\n[other]\nimage=debian:13\n' > /tmp/multi.ini
bash script/assemble.sh --file /tmp/multi.ini; echo "exit=$?"
```

預期:`[ERROR] manifest declares multiple sections; worktool supports a single box: ...`、`exit=1`。

**3f. 含空白/特殊字元的清單路徑(路徑安全)**

dry-run 輸出採逐一參數的 `%q` 跳脫,所以含空白、`;` 或 `$()` 的路徑會被表示成單一安全
參數,可直接複製貼上忠實重跑,不會被再次拆分或解讀。

**3g.(選用)一鍵自檢**

想一次跑完上面的 dry-run 斷言,可在 repo 根目錄執行下列腳本(全綠即通過):

```bash
bash -c '
set -uo pipefail
root="$(pwd -P)"; tmp="$(mktemp -d)"; trap "rm -rf -- \"$tmp\"" EXIT; fail=0

# 3a 正常 dry-run:相對路徑
out="$(WORKTOOL_DRY_RUN=1 bash script/assemble.sh)"
[ "$out" = "distrobox assemble create --file box/dev.ini" ] \
  && echo "PASS 3a" || { echo "FAIL 3a: $out"; fail=1; }

# 3b repo 外呼叫:絕對路徑
out="$(cd "$tmp" && WORKTOOL_DRY_RUN=1 bash "$root/script/assemble.sh")"
[ "$out" = "distrobox assemble create --file $root/box/dev.ini" ] \
  && echo "PASS 3b" || { echo "FAIL 3b: $out"; fail=1; }

# 負向案例:應 exit=1、STDOUT 為空、STDERR 含指定訊息
check() { # <file> <expected-msg>
  local o e rc=0
  o="$(bash script/assemble.sh --file "$1" 2>"$tmp/err")" || rc=$?
  e="$(cat "$tmp/err")"
  { [ "$rc" -eq 1 ] && [ -z "$o" ] && case "$e" in *"$2"*) true;; *) false;; esac; } \
    && echo "PASS $1" || { echo "FAIL $1 (rc=$rc): $e"; fail=1; }
}
printf "[dev]\n"                                   > "$tmp/no-image.ini"
printf "[   ]\nimage=ubuntu:26.04\n"               > "$tmp/blank-name.ini"
printf "[dev]\nimage=\"   \"\n"                    > "$tmp/blank-image.ini"
printf "[dev]\nimage= \"   \"\n"                   > "$tmp/spaced-image.ini"
printf "[dev]\nimage=ubuntu:26.04\n[b]\nimage=x\n" > "$tmp/multi.ini"
check "$tmp/no-image.ini"    "missing required key '"'"'image'"'"'"
check "$tmp/blank-name.ini"  "missing box name"
check "$tmp/blank-image.ini" "missing required key '"'"'image'"'"'"
check "$tmp/spaced-image.ini" "missing required key '"'"'image'"'"'"
check "$tmp/multi.ini"       "multiple sections"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
'
```

### 4. 真實 assemble(選用,M2 非必須)

M2 **不要求**真實建盒:系統測試已證明清單會被真實 distrobox 解析成正確的 create 請求
(見「測試對應」),但「映像拉得下來、套件裝得進去、盒子可用」需要真正的容器管理器
(CI 內 docker-in-docker),依 [`design.md`](design.md) 延到 **M5**。若手邊已有
docker + distrobox,可拿掉 dry-run 實際建出 dev 盒以主觀確認:

```bash
bash script/assemble.sh   # 需要 PATH 上有 distrobox;否則會以 [ERROR] ... 與 exit=127 結束
```
