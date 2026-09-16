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

使用者介面是 `just assemble [mode]`(`just` 是使用者的通用介面,見
[`design.md`](design.md)「決策」);`script/assemble.sh` 是 recipe 底下的實作。

```bash
# 試跑:只印出指令,不執行(單元測試就是斷言這個輸出)
just assemble dry-run
# -> distrobox assemble create --file box/dev.ini

# 實際 assemble(mode 預設 run;需要 host 上有 distrobox)
just assemble
```

底層指令(recipe 呼叫的就是這些;沒有 `just` 時可直接執行):

```bash
./script/assemble.sh --dry-run             # = just assemble dry-run
WORKTOOL_DRY_RUN=1 ./script/assemble.sh    # 以環境變數試跑,同上
./script/assemble.sh                       # = just assemble
./script/assemble.sh --file box/other.ini  # 指定其他清單(只有腳本形式提供)
```

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
    單一參數)。純 bash、完全可 mock。
  - **不證明什麼**:distrobox 是否真的會被呼叫、以及它如何解讀清單 —— 那是整合層與
    系統層的事。
- 整合(`test/integration/assemble_spec.bats`):
  - **驗證什麼**:把一支 **mock `distrobox`** 放到 PATH(**逐一參數**、每行一個地
    記錄自己被呼叫的參數),以真實(非 dry-run)模式跑包裝器,斷言它確實以
    `assemble create --file <解析後的清單>` 呼叫 distrobox;另外斷言「從 repo 以外
    執行會傳入解析後的絕對路徑」以及「清單無效時(缺 image、image 引號不成對)
    完全不呼叫 distrobox 且以非零結束」。證明包裝器到 distrobox 的接線。
  - **不證明什麼**:真正的 distrobox 會怎麼解析清單(mock 不解析),更不證明盒子
    能建出來。
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
    (`ripgrep fzf`)被 distrobox 交給盒內 entrypoint(distrobox-init)的
    `--additional-packages`(位於映像之後、恰好一次);`pull` 請求的映像同為
    `ubuntu:26.04` 且發生在 create 之前;上游自己的
    `distrobox assemble create --dry-run --file box/dev.ini` 解析出名稱/映像正確
    的 create 指令;管理器 `create` 失敗時包裝器以非零結束、失敗訊息來自上游。
    一句話:**清單被真實 distrobox 1.8.2.5 解析成預期的 create 請求**。
  - **不證明什麼**:映像真的拉得下來、套件真的裝進盒(distrobox-init 在這裡從未
    執行,沒有任何容器被啟動)、盒子可用。這些交給下面的 real-engine 組。
  - gate:`just test system`(CI `test-system` job,必要;底層
    `./script/ci/ci.sh --system-only`)。
    `script/ci/ci.sh` 對每一層 bats gate 都要求「至少跑了一個案例、無失敗、無
    `skip`」,被 skip 或不存在的必要案例**不會**被當成綠燈。
- 系統,**real-engine 組**(`test/system/real_engine_spec.bats`):以**真正的
  docker 引擎**證明 M2 的「可用 dev 盒」承諾。做法是 **docker-in-docker**
  (2026-09-16 人類決策;三種做法的研究與比較見 issue #129):一個專用的系統測試
  runner 映像 `dockerfile/Dockerfile.system-real`,以官方 `docker:29.8.0-dind`
  為基底(內含 dockerd、containerd、runc、docker CLI),加上 bash、bats 1.14.0
  (+ bats-support v0.3.0 / bats-assert v2.1.0)與**同一份**鎖定的 distrobox
  1.8.2.5(同一個 tarball、同一個 sha256、同一個上游安裝器);所有版本皆鎖定。
  runner 以 `docker run --rm --privileged` 啟動(巢狀 dockerd 需要;**這是唯一
  使用 `--privileged` 的地方**),入口 `script/ci/system-real-entry.sh` 在容器內
  背景啟動一個獨立的 dockerd(沿用 dind 映像自己的 `dockerd-entrypoint.sh`:
  cgroup v2 巢狀、`mount --make-rshared /`、tmpfs `/tmp`),有界等待 `docker info`
  就緒(逾時即帶著 daemon 日誌大聲失敗),再經 `ci.sh --ci-system-real` 跑這支
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
    `script/assemble.sh`:exit 0、印出上游的 `Distrobox 'dev' successfully
    created.`、`docker ps -a` 恰好列出一個 `dev`,且它由 `ubuntu:26.04` 建出、帶
    `manager=distrobox` 標籤;(c) 盒子可用:`distrobox enter dev -- rg --version`
    印出 `ripgrep <版本>`(第一次 enter 會啟動容器並執行 distrobox-init:apt 安裝
    distrobox 依賴與 `ripgrep fzf`,約 2 分鐘)、`distrobox enter dev -- fzf
    --version` 印出版本,容器狀態為 `running`;(d) 冪等:第二次
    `script/assemble.sh` exit 0、印上游的 `dev already exists`、不重建、`dev` 仍
    恰好一個、仍可 `rg --version`;(e) 清理:`distrobox rm -f dev` exit 0 後
    `docker ps -a` 不再有 `dev`。長步驟都包在有界的 `timeout` 裡(assemble 600s、
    第一次 enter 900s、其餘 300s/120s),失敗時印出 dockerd 日誌與盒子的
    `docker logs`。環境隔離同 shim 組:全新的 HOME(因盒子會 bind-mount HOME、
    且要跨案例存活,放在 per-file 的 `BATS_FILE_TMPDIR`)、
    `DBX_CONTAINER_GENERATE_ENTRY=0`。distrobox 在 runner 內以 root 執行(uid 0),
    上游視為「以 root 登入的 rootful」:不會前綴 sudo、盒內使用者即 root、HOME
    為上述全新目錄;這對本證明沒有影響,一般使用者(非 root)的情境留給 M3/M5 與
    人類清單。一句話:**交付的清單經真實 distrobox 1.8.2.5 與真實 docker 引擎,
    建出可用的 dev 盒(ubuntu:26.04 + ripgrep + fzf)**。
  - **驗證邊界(套件何時裝好)**:distrobox 的 `assemble create` 只負責 `pull` 與
    `create`(建立容器、把 `--additional-packages` 交給盒內 entrypoint);套件
    初始化(apt 安裝 distrobox 依賴與 `ripgrep fzf`)是由 distrobox-init 在**第一次
    `distrobox enter`** 啟動容器時執行的。因此這組測試證明的是「**assemble 成功後,
    enter 會完成初始化、工具可用**」,**不是**「assemble 返回時套件已安裝完成」——
    只跑 `script/assemble.sh` 而不 enter,盒內還沒有 `rg` / `fzf`。
  - **不證明什麼(延後)**:效能目標(進盒延遲,M3)、終端自動進盒(M3)、更廣的
    環境矩陣(真實硬體、非 root 使用者、GPU 等,M5 與人類清單)。
  - gate:`just test system-real`(CI `test-system-real` job,必要,被
    `ci-passed` 彙總要求;慢,約 2-3 分鐘、CI 上限 40 分鐘;底層
    `./script/ci/ci.sh --system-real-only`)。同樣適用
    「至少一個案例、無失敗、無 `skip`、spec 不存在即失敗」的規則。
- 交付/驗收(`test/acceptance/m2_selfcheck_spec.bats`):
  - **驗證什麼**:以使用者拿到交付品的方式驗證 —— 直接執行交付的公開入口
    **`script/selfcheck.sh`**(`just selfcheck` 呼叫的就是這支,也就是下方 3g 要
    使用者跑的那支;測試**不**在 bats 裡重寫它的檢查),斷言它 exit 0 且印出
    `ALL PASS`(3a/3b 的 dry-run 契約 + 3c-3e
    七個無效清單的拒絕,共 9 個 `PASS`),從 repo 內或 repo 外執行皆然;並以負向
    案例證明它的判定不是空的:清單壞掉(缺 image)時、以及包裝器被換成「跳過驗證、
    永遠印成功指令」的版本時,都必須報 `SOME FAILED` 且 exit 1;`--root` 指到
    不是 worktool checkout 的目錄時給出清楚錯誤。
  - **不證明什麼(延後)**:真實硬體上的盒子(效能目標、非 root 使用者、GPU 等)——
    留在下方「M2 驗收紀錄」的人類清單與 **M3/M5**;「盒子可用」本身已由系統層
    real-engine 組在 CI 內證明。
  - gate:`just test acceptance`(CI `test-acceptance` job,必要;底層
    `./script/ci/ci.sh --acceptance-only`)。

所有測試都在 Docker 內執行(host 不安裝任何套件);`just test`(= `just test all`)
依序跑完五個 tier,`just check` 再加上 lint、等同 CI。執行方式見
[`structure.md`](structure.md)。

## M2 驗收紀錄(人類清單)

M2 的人類 gate 依此表逐項填寫。「版本(commit)」填當時審核的 commit SHA;「結果」
填 PASS / FAIL / 延後;「證據」填可回溯的連結或指令輸出。**能自動化的已自動化**
(三列全部由 CI、`script/selfcheck.sh` 與 CI 內的 docker-in-docker 系統測試產生
證據);仍需要真實機器的部分(效能、非 root、GPU)誠實留給 M3/M5。

| 項目 | 版本(commit) | 環境 | 預期 | 結果 | 證據 |
|------|--------------|------|------|------|------|
| 自動化全綠(lint + unit + integration + system + system-real + acceptance) | PR #20 head(審核時填 SHA) | GitHub Actions `ubuntu-latest`;Docker 測試映像 `worktool-test:local`(alpine + bash + bats + shellcheck + distrobox 1.8.2.5)與 DinD runner `worktool-system-real:local`(docker:29.8.0-dind + bash + bats 1.14.0 + distrobox 1.8.2.5) | `ci-passed` 綠:五個 matrix gate 與 `test-system-real` 皆 `success`,無 skip、無零案例 | 待審核填寫 | PR #20 的 checks 頁面(`ci-passed` job 記錄) |
| 一鍵自檢 `just selfcheck`(= `./script/selfcheck.sh`)印出 `ALL PASS` | PR #20 head(審核時填 SHA) | 任一有 bash + just 的機器(clone 後於 repo 根目錄執行;不需 distrobox;沒有 just 時直接跑 `./script/selfcheck.sh`) | 9 個 `PASS` 行 + `ALL PASS`、exit 0 | 待審核填寫 | 貼上 `just selfcheck; echo rc=$?` 的輸出 |
| 真實可用盒(`script/assemble.sh` 真建盒 -> `distrobox enter dev -- rg --version` / `fzf --version` 可執行、第二次 assemble 冪等、`distrobox rm -f dev` 可清理) | PR #20 head(審核時填 SHA) | CI 內 docker-in-docker(`test-system-real` job;`docker run --rm --privileged` 的 runner,巢狀 dockerd + 真實 distrobox 1.8.2.5 + 真實 `ubuntu:26.04`);本機 `just test system-real` 同一 runner | `test/system/real_engine_spec.bats` 8 案例全 `ok`:盒子由 `ubuntu:26.04` 建出、第一次 `distrobox enter` 完成初始化後 `ripgrep` / `fzf` 版本可印出(驗證邊界:套件在第一次 enter 時安裝,不是 assemble 返回時就裝好)、冪等、可清理;巢狀 daemon 內的容器/映像/volume 隨 runner 銷毀,host daemon 只留 runner 映像 `worktool-system-real:local` 與建置快取 | **已由自動化驗證**(不再延後 M5;M5 保留更廣的環境矩陣) | `test-system-real` job 記錄(TAP `1..8` 全 `ok`、結尾 `[ci] system-real bats OK`);本機同指令輸出 |

## 如何人工驗證(M2,從 clone 到 assemble)

以下是從零開始、端到端親自複驗 M2(盒子清單格式 + 最小 assemble 包裝器)的完整流程。
全程只需要 **docker** 與 **just**:`just` 是使用者的通用介面(見
[`design.md`](design.md)「決策」),所有 gate 都以 `just ...` 執行;每個 gate 同一行
也標出沒有 `just` 時的底層備援 `./script/ci/ci.sh --xxx-only`。不需要在 host 裝
`distrobox`(系統測試用的 distrobox 已鎖定版本、烘進測試映像與 DinD runner;真實
可用盒的驗證也在 Docker 內完成)。每個指令都可直接複製貼上。

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
git checkout m2-manifest   # 審 M2 PR 用此分支;合併進 main 後改用 main 即可
```

### 2. 自動測試(全部在 Docker 內,不需 distrobox)

入口是 `just`(`just` 不帶參數會列出所有 recipe)。第一次可先建測試映像,再依序跑
六道 gate;每行 `#` 後面標出沒有 `just` 時的底層備援(recipe 呼叫的就是它):

```bash
just build              # (選用) 先建 worktool-test:local 測試映像                         | 無 just:./script/ci/ci.sh --build
just lint               # ShellCheck(*.sh + *.bats)                                        | 無 just:./script/ci/ci.sh --lint-only
just test unit          # 單元 bats(test/unit/)                                             | 無 just:./script/ci/ci.sh --unit-only
just test integration   # 整合 bats(test/integration/)                                      | 無 just:./script/ci/ci.sh --integration-only
just test system        # 系統 bats,shim 組(test/system/;真實 distrobox + 假容器管理器)   | 無 just:./script/ci/ci.sh --system-only
just test acceptance    # 驗收 bats(test/acceptance/;跑交付的 script/selfcheck.sh)         | 無 just:./script/ci/ci.sh --acceptance-only
just test system-real   # 系統 bats,real-engine 組(docker-in-docker,--privileged;慢,約 2-3 分鐘) | 無 just:./script/ci/ci.sh --system-real-only
```

一次跑完:`just test`(= `just test all`,依序 unit、integration、system、acceptance、
system-real)或 `just check`(lint + test all,和 CI 跑的一模一樣)。`just test <tier>`
給了無效的 tier 會以清楚的錯誤訊息、exit 1 結束,什麼都不跑。

- `just build` 是選用的:後面的 gate 若發現映像不存在會自動建。想先暖快取、或快速驗
  Dockerfile 有沒有壞掉,才需要先手動 `just build`。`just test system-real` 每次都會
  (以快取)建 `worktool-system-real:local` runner 映像,並以 `docker run --rm
  --privileged` 執行;這是唯一需要 `--privileged` 的 gate。結束後,測試在巢狀 daemon
  內建立的容器、映像與 volume(`dev` 盒、`ubuntu:26.04`)都隨 runner 銷毀、不會出現
  在 host daemon 上;host daemon 上留下的只有 runner 映像 `worktool-system-real:local`
  (含 `docker:29.8.0-dind` 基底層)與 Docker 建置快取,和 `worktool-test:local` 同一類。
- 預期輸出:
  - `just lint`:結尾出現 `[ci] ShellCheck OK`,沒有任何 ShellCheck 違規。
  - `just test unit`:所有測項 `ok`(涵蓋缺 image / 缺名稱 / 檔案不存在 / 純空白名稱 /
    單或雙引號內純空白 image / 引號不成對的 image / image 出現在區段之前 / 多區段
    等案例),結尾 `[ci] unit bats OK`。
  - `just test integration`:所有測項 `ok`(含「無效 manifest(缺 image、引號不成對)
    絕不呼叫 distrobox」負向測試),結尾 `[ci] integration bats OK`。
  - `just test system`:所有測項 `ok`(真實 distrobox 1.8.2.5 把 `box/dev.ini` 解析成
    帶 `dev` / `ubuntu:26.04` / `ripgrep fzf` 的 create 請求;管理器失敗會傳回非零),
    結尾 `[ci] system bats OK`。
  - `just test acceptance`:所有測項 `ok`(交付的 `script/selfcheck.sh` 對交付的 repo
    印 `ALL PASS`;壞清單 / 跳過驗證的包裝器被判 `SOME FAILED`),結尾
    `[ci] acceptance bats OK`。
  - `just test system-real`:先看到 `[system-real] dockerd ready after Ns` 與
    `[system-real] engine 29.8.0 ...`,接著 `1..8` 且 8 項全 `ok`(建盒、第一次 enter
    完成初始化後 `rg --version`、`fzf --version`、冪等、`distrobox rm`),結尾
    `[ci] system-real bats OK`、`[system-real] cleanup: containers left in the nested
    daemon: 0`。
- 任一 gate 失敗會以 `[ci] ERROR: ...` 與非零結束碼結束;bats gate 若有案例被 `skip`
  或根本沒跑到任何案例,同樣視為失敗。

### 3. 手動驗證 assemble 包裝器(不需 distrobox,用 dry-run)

使用者介面是 `just assemble dry-run`(3a)。3b-3f 刻意直接呼叫底層的
`script/assemble.sh`:它們驗證的是腳本層的行為(從 repo 以外執行的路徑解析、
`--file` 指定其他清單),而 `just assemble [mode]` 只暴露 mode,不暴露這些選項。
`WORKTOOL_DRY_RUN=1`(或 `--dry-run`)會把「將要執行的 distrobox 指令」印到
**STDOUT** 而**不執行**;診斷訊息一律走 STDERR。指定清單的旗標是 **`--file`**
(不是 `--manifest`)。下面每步都保持在 repo 根目錄執行(除了 3b 特意換到別的目錄)。

**3a. 正常 dry-run(從 repo 根目錄)**

```bash
just assemble dry-run                     # 底層:WORKTOOL_DRY_RUN=1 bash script/assemble.sh
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

**3d. 空白繞過與不成對引號應被拒**

```bash
printf '[   ]\nimage=ubuntu:26.04\n'   > /tmp/ws-name.ini    # 純空白名稱
printf '[dev]\nimage="   "\n'           > /tmp/ws-img.ini     # 雙引號內純空白
printf '[dev]\nimage= "   "\n'          > /tmp/ws-img2.ini    # 空格後才是引號
printf "[dev]\nimage='   '\n"           > /tmp/ws-img3.ini    # 單引號內純空白
printf "[dev]\nimage='ubuntu:26.04\"\n" > /tmp/unbalanced.ini # 引號種類不一致
for f in /tmp/ws-name.ini /tmp/ws-img.ini /tmp/ws-img2.ini /tmp/ws-img3.ini /tmp/unbalanced.ini; do
  bash script/assemble.sh --file "$f"; echo "  ($f) exit=$?"
done
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
bash script/assemble.sh --file /tmp/multi.ini; echo "exit=$?"
```

預期:`[ERROR] manifest declares multiple sections; worktool supports a single box: ...`、`exit=1`。

**3f. 含空白/特殊字元的清單路徑(路徑安全)**

dry-run 輸出採逐一參數的 `%q` 跳脫,所以含空白、`;` 或 `$()` 的路徑會被表示成單一安全
參數,可直接複製貼上忠實重跑,不會被再次拆分或解讀。

**3g. 一鍵自檢(交付的公開入口)**

想一次跑完上面 3a-3e 的斷言,執行 `just selfcheck`,它呼叫交付的自檢腳本
[`script/selfcheck.sh`](../script/selfcheck.sh)(只需要 bash;不需要 distrobox、
不動 host):

```bash
just selfcheck; echo "rc=$?"              # 無 just:./script/selfcheck.sh; echo "rc=$?"
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
checkout 用 `./script/selfcheck.sh --root <repo>`(指到不是 worktool checkout 的目錄
會以 `[ERROR]`、`rc=2` 結束)。驗收層測試(`test/acceptance/`)跑的就是這支腳本,
並且以「清單壞掉」與「包裝器跳過驗證」兩個負向案例證明它會誠實地報 `SOME FAILED`。

### 4. 真實 assemble(已自動化;host 上手動為選用)

「映像拉得下來、套件裝得進去、盒子可用」已由系統層 real-engine 組在 Docker 內以真實
docker 引擎證明(`just test system-real`,見「測試對應」),host 不需要 distrobox。
若手邊已有 docker + distrobox、想在 host 上主觀確認,可拿掉 dry-run 實際建出 dev 盒
(這會在 host 的 docker 上留下 `dev` 容器,用 `distrobox rm -f dev` 清掉):

```bash
just assemble             # mode 預設 run;底層 bash script/assemble.sh。需要 PATH 上有 distrobox;否則會以 [ERROR] ... 與 exit=127 結束
distrobox enter dev -- rg --version
distrobox enter dev -- fzf --version
distrobox rm -f dev
```
