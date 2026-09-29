# worktool 設計文件(討論中)

狀態:設計討論中(M0)。milestone 計畫定稿並經人類核准前,不開始實作。

## 願景

以 distrobox 為基礎的模型,取代 init_ubuntu「apt 直接裝到 host」的 module
系統。開發用 CLI/TUI 工具全部住在一個共用的 distrobox「dev 盒」,使用者直接
活在盒內(終端自動進盒);host 只保留驅動、docker、snapd、桌面 GUI app(以
install script 形式)與容器框架。盒子有自己的 HOME(見 `doc/adr/0002-box-owns-its-home.md`)。

## 治理規則

- 討論完整才實作;milestone 計畫核准前不寫程式碼。
- 以 milestone 為單位,每個有明確完成目標與 checkpoint。
- milestone 逐一完成、不可跨越;前一個完整結束才進下一個。
- milestone 之間有人類審核 gate;通過才進下一個 milestone 開發。
- milestone 內部自主開發,以 robustness 與穩定性為第一優先;只有最後
  milestone 的 release 與重大決策需要人類同意。
- 效能是一級非功能需求:shell 進入與工具呼叫都不能緩慢。
- 語言:issue / PR / PRD / ADR / 設計文件以 zh-TW 撰寫;commit message、程式碼
  與註解以英文撰寫。
- milestone 排序:所有 milestone issue 保持開放(全貌可見);逐一、不可跨越的
  順序由 milestone 間的人類審核 gate 落實 —— 前一個 milestone 未通過人類 gate
  前,不開始下一個 milestone 的開發。不使用 issue lock。
- 追蹤:每個 milestone 對應一個 GitHub Milestone 與一個 parent issue(見 epic
  #1),parent 底下有多個 sub-issue(移植 milestone 每工具一個、其餘依任務);
  該 milestone 的實作 PR 掛在對應的 Milestone 下。一個 sub-issue 一個 PR,
  CI 綠且 codex「可合併」後自主合併(merge commit,不 squash);只有 milestone
  驗收 PR(驗收清單 + Closes parent issue)是人類 gate,不自動合併
  (2026-09-19 修訂,見 doc/workflow.md)。
- milestone 驗收 PR 的核准紀錄(2026-09-29,#187):驗收 PR 貼 `milestone-gate`
  標籤,合併前必須有維護者在該 PR 上**留言記錄可以合併**;對話裡的同意、agent
  對留言的解讀都不算。格式:`author_association` 為 `OWNER`、本文(忽略開頭空白)
  不以 `[claude]` 或 `[codex]` 開頭(agent 留言一律以這兩個標記開頭)、內容含
  「允許合併」。機制:`.github/workflows/milestone-gate.yml` 在 PR 事件
  (`pull_request_target`:opened / synchronize / reopened / labeled / unlabeled)與
  PR 留言事件(created / edited / deleted)時,只執行 main 上的可信程式碼(不
  checkout、不執行 PR head),以 `gh api` 取標籤與留言,交給純函式
  `lib/approval.sh` 判斷,在 PR head SHA 設 commit status `milestone-gate-approval`(未貼標籤或已核准 = success,
  否則 failure 並寫明「需要維護者留言:允許合併」);合併後列入 main 的 required
  checks,與 `ci-passed` 並列。已知限制:agent 用維護者的 token 發留言,GitHub
  無法區分本人與 agent 代發,這道檢查擋的是「忘了等核准」,擋不住 agent 冒名寫
  「允許合併」;後者由 agent 端的 Claude Code hook 擋(#190)。
- 驗收標準:每個 milestone 與 sub-issue 都有明確驗收標準(自動 + 人類實機),
  累積於 doc/acceptance.md;milestone 的人類 gate 檢查「自動測試綠」與「人類
  實機項目已勾」兩者。這是確保 distrobox UX 最終可驗收的機制。

## 已定共識(2026-09-15)

1. distrobox 作為 base 框架。
2. 一個共用「dev」盒裝所有容器化 CLI/TUI 工具。
3. 活在盒裡:終端自動進盒;fish/tmux/zoxide/fzf/thefuck + 所有編輯器/CLI/TUI/
   監控/AI 工具都在盒內。
4. ~~設定留共用 HOME~~ 已被取代:盒子使用獨立 HOME,見
   `doc/adr/0002-box-owns-its-home.md`(#197)。
5. host 保留:驅動(nvidia/kvm)、docker、snapd、桌面 GUI app、容器框架、終端
   自動進盒設定。
6. 桌面 GUI app 改做 host install script(放 `tool/`),不進 module 系統。
7. 舊 10-function apt-archetype module 系統溶解為 (a) host install script、
   (b) 盒子套件清單。supersede ADR-0002 等。
8. 過渡:新的大版本(worktool 獨立 repo);init_ubuntu 保持可用直到切換。
9. 前端:setup_ubuntu CLI + fzf TUI 退場,設計全新前端(於 M13/M14)。

## Open 項目(建議預設,待確認 / 修正)

1. 盒子 base image:`ubuntu:26.04`(已定)。
2. bootstrap 順序:host 裝 docker+distrobox(+ `just`,見「決策」)-> host
   install script(驅動/GUI)-> assemble 盒子 -> 設定終端自動進盒。
3. 版本號:`2.0.0`(worktool 首個對外版本)。
4. 效能目標:進盒 prompt 感知延遲 < 約 300ms;工具呼叫額外負擔 < 約 50-100ms。
   300 ms 這條線由系統層 real-engine gate **強制**(`just test system-real`,
   issue #23):`test/system/real_engine_spec.bats` 對 DinD 內建出的真實 dev 盒跑
   `just box bench --max-ms 300`(底層 `script/box/bench.sh --box dev --runs 5
   --warmup 2 --max-ms 300`),shell 中位數(enter + shell 啟動,即使用者拿到提示
   字元的感知延遲)超過即 exit 1、gate 紅;門檻只寫在該 spec 的 `ENTER_MAX_MS`
   一處,另有 `--max-ms 1` 的負向案例證明 gate 會咬。CI 實測(docker 29.8.0 +
   預設 runc、warm 容器):amd64 enter 中位數約 88 ms、arm64 約 87 ms,離目標
   有 3 倍餘裕,故維持 docker + runc、不換 runtime;實機數字由人類清單收集
   (issue #22)。
5. 測試層級(已定):完整測試金字塔 —— 單元 -> 整合 -> 系統 -> 交付/驗收,
   全部都要有。詳見下方「測試策略」。

## 測試策略(完整測試金字塔,已定)

每個 milestone 的 Definition of Done 都包含對應層級的測試(TDD:先寫測試)。
四個層級全部都要有:

- 單元測試(unit):個別函式/腳本隔離測試 —— bash 函式、清單解析、install
  script 的 helper,以 mock 隔離外部。快、量最多。
- 整合測試(integration):元件協作 —— 例如「從清單 assemble 一個盒子並驗證
  套件就位」、「bootstrap 正確裝上 distrobox」。在 Docker / docker-in-docker
  內以真實但受控的方式跑。
- 系統測試(system):端到端全流程 —— 全新環境 -> bootstrap -> 盒子 assemble
  -> 終端自動進盒 -> 工具可用,在受控容器(DinD)內跑。
- 交付/驗收測試(acceptance):驗證交付品達成目標與 UX —— 效能目標達標(進盒
  延遲、工具呼叫負擔)、日常 driver 流程可用、工具從盒內正常運作。可自動化的
  自動化;需真實硬體/顯示的部分(GPU、GUI、顯示器剪貼簿)以人類驗收清單補足
  (比照 init_ubuntu 的 real-hardware 驗收清單)。

測試環境維持 Docker-only(unit/integration/system 走 Docker/DinD);只有需要
真實硬體的驗收項目走人類清單。

決策(2026-09-16,見 issue #129):「真實引擎冒煙」(真 docker 引擎 + 真 distrobox
把 `box/dev.ini` 建成可用的 dev 盒、`rg` / `fzf` 可執行)**從 M5 提前到 M2**,做法
採 docker-in-docker(三種做法 —— DinD / DooD / 容器內 rootless podman —— 的研究與
比較記錄在該 issue;DinD 是唯一同時滿足「distrobox 與 daemon 看到同一套路徑」、
「測試建立的容器/映像/volume 不落在 host daemon 上」(host 只留 runner 映像與建置
快取)、「GitHub Actions 與本機一致」的做法)。系統層因此分成 shim 組
(建立請求正確性,快)與 real-engine 組(可用 dev 盒,DinD、`--privileged`、慢),
兩組皆為 CI 必要 gate;`--privileged` 僅限 real-engine 這一個 job/recipe。M5 保留
更廣的環境矩陣(真實硬體、非 root 使用者、其他映像、效能量測),不再負責「盒子
可用」的基本證明。細節見 [`manifest.md`](manifest.md)「測試對應」。

## 決策

「已定共識」之後、以日期記錄的個別決策。與測試策略直接相關的(2026-09-16
docker-in-docker 提前到 M2)記在上方「測試策略」;其餘集中於此。

### 2026-09-16:just 是使用者的通用介面(命令模型比照 base)

**決策**:`just` 是 worktool **使用者的通用介面**。所有使用者可執行的動作都以
`just <namespace> [recipe] [選項]` 暴露;腳本(`script/test/test.sh`、
`script/test/selfcheck.sh`、`script/box/assemble.sh`)是**實作、不是介面**。命令
模型**完全比照**維護者的 `ycpss91255-docker/base` repo,不另創一套:
ADR-00000005「Adopt `just` over the Makefile wrapper」(`just` 作為唯一的使用者
入口、recipe 是薄轉發器)、ADR-00000010「Layered `just` entry」(`mod?` namespace
是唯一免名稱衝突的機制)、ADR-00000011「`just` command model: zero-special-case
namespaces, generic tooling, min->max coverage」(零特例、以動作命名、min->max、
`--help` 住在腳本、每個 module 有 `help`)。

**理由**(維護者原話):使用者的通用輸入應該一致(`just test`、`just test unit`),
直接呼叫腳本很麻煩。比照 base 的理由:同一位維護者的所有 repo 只需要記一種
文法;base 的模型是三次修正(00000005 -> 00000010 -> 00000011)後收斂的結果,
每一條規則都對應一個踩過的坑,worktool 沒有理由再踩一次。

**模型**(五條規則,全部出自 base ADR-00000011):

1. **零特例:每個動作都是一個 namespace**。root `justfile` 只有 `mod?` 行加一個
   `default`,**沒有任何**頂層動作 recipe;動作一律是 `just <namespace> <recipe>`;
   裸 `just` 就是 `just --list`,列出 namespaces。代價是多打一個字,換來一條沒有
   例外的規則(base ADR-00000011 §1:頂層 docker recipe 這個「特例」正是讓模型難教、
   難擴充的原因;重複 recipe 名在 `just` 是硬錯誤,`mod?` 是唯一免衝突的機制,
   ADR-00000010)。
2. **namespace 以動作命名**:`test`(所有 CI 檢查,**含 lint**)、`box`(盒子
   生命週期)。**不用** `ci` / `cd` 這類描述機制、不描述動作的名字(base
   ADR-00000011 §2:使用者想的是「跑測試」,不是「跑 CI」);lint 不是 `test` 的頂層
   同儕,而是 `just test lint`。
3. **min -> max:裸指令跑最大範圍,子 recipe / 選項只收窄**。`just test` 跑 CI 會跑的
   **全部**(lint、unit、integration、system、acceptance、system-real,依序,遇到第一個
   失敗即停);`just test unit` 只跑單元層;`just box assemble --dry-run` 只印指令、
   不執行(base ADR-00000011 §3)。
4. **justfile 是薄轉發器**:每個 recipe 就是把 `*args` **原樣**傳給對應腳本的一行
   (`just` 不吃 `--flag` 與 `VAR=VALUE`,這正是 base ADR-00000005 捨棄 make 的原因)。
   **所有**參數驗證、usage 文字、選項清單與 `--help` 都住在腳本;justfile **不印**
   任何 usage 或「valid: ...」清單。因此 `just test bogus` 得到的是 `just` 自己的
   「Justfile does not contain recipe `bogus`」(exit 1、什麼都不跑);
   `just box assemble --bogus` 得到的是 `assemble.sh` 自己的
   `assemble.sh: unknown option '--bogus' (see --help)`(exit 2、什麼都不跑)。
5. **每個 module 都有自己的 `default` 與 `help`(alias `h`)**,並以
   `set working-directory := '../..'` 讓 recipe 一律在 repo 根目錄執行(module 檔住在
   `script/<ns>/`,`just` 預設以 module 檔所在目錄為 cwd)。namespace 層級的說明是
   `just <ns>` 或 `just <ns> help`;recipe 層級的 `--help` 由 recipe 原樣轉發給腳本
   (base ADR-00000011 §6:`just <ns> --help` 這種帶橫線的名字不會被 `just` 當成
   recipe,所以 namespace 說明走 `help` recipe)。recipe 上方那一行英文註解就是
   `just --list` 顯示的說明,保持一行。

**root `justfile`**(就是這個形狀,沒有別的 recipe;`justfile.ci` 不存在):

```just
mod? test 'script/test/justfile.test'   # Self-test: lint + bats tiers in Docker (just test [build|lint|unit|integration|system|system-real|acceptance|selfcheck])
mod? box  'script/box/justfile.box'     # Dev box lifecycle: just box assemble [--dry-run] [--file X]  (M3 adds enter / rm)

# Default: list the namespaces.
default:
    @just --list
```

**namespace `test`**(`script/test/justfile.test`,`set working-directory := '../..'`,
`set positional-arguments`:recipe 以 `"$@"` 原樣轉發額外參數 —— 不用 `{{args}}`,因為它會先
把參數以空白接成一個字串再交給 shell 重切,含空白的路徑會被拆開;下表「轉發到」欄就是
recipe 原文,也是 `just` 執行時回顯的那一行):

| 指令 | 轉發到 |
|------|--------|
| `just test` | `./script/test/test.sh`(CI 跑的全部:lint、unit、integration、system、acceptance、system-real,依序,遇到第一個失敗即停) |
| `just test build [args]` | `./script/test/test.sh --build "$@"` |
| `just test lint [args]` | `./script/test/test.sh --lint "$@"` |
| `just test unit [args]` | `./script/test/test.sh --unit "$@"` |
| `just test integration [args]` | `./script/test/test.sh --integration "$@"` |
| `just test system [args]` | `./script/test/test.sh --system "$@"` |
| `just test system-real [args]` | `./script/test/test.sh --system-real "$@"` |
| `just test acceptance [args]` | `./script/test/test.sh --acceptance "$@"` |
| `just test selfcheck [args]` | `./script/test/selfcheck.sh "$@"`(交付自檢;`--root X` 原樣傳入) |
| `just test help` / `just test h` | `./script/test/test.sh --help` |

**namespace `box`**(`script/box/justfile.box`,`set working-directory := '../..'`):

| 指令 | 轉發到 |
|------|--------|
| `just box` | 列出 box 的動詞:`@just --justfile '{{source_file()}}' --list` |
| `just box assemble [args]` | `./script/box/assemble.sh "$@"`(args:`--dry-run`、`--file <manifest>`、`--help`) |
| `just box help` / `just box h` | `./script/box/assemble.sh --help`(M2 只有 assemble 一個動詞) |

**腳本佈局**(module 檔與它轉發的腳本住在同一個 `script/<ns>/`;`script/ci/` 不再
存在,`script/selfcheck.sh` 與 `script/assemble.sh` 搬進 namespace 目錄):

```text
script/
├── test/
│   ├── justfile.test           namespace test
│   ├── test.sh                 Docker-only gate(原 script/ci/ci.sh):host 旗標 --build / --lint / --unit /
│   │                           --integration / --system / --system-real / --acceptance;不帶旗標 = 全部;
│   │                           --help;未知選項 -> `test.sh: unknown option '<x>' (see --help)`、exit 2
│   ├── selfcheck.sh            交付自檢(原 script/selfcheck.sh;--root <repo>、--help)
│   └── system-real-entry.sh    DinD runner 入口(原 script/ci/system-real-entry.sh)
└── box/
    ├── justfile.box            namespace box
    └── assemble.sh             assemble 包裝器(原 script/assemble.sh):--dry-run / --file <manifest> /
                                --help;未知選項 -> `assemble.sh: unknown option '<x>' (see --help)`、exit 2
```

腳本在沒有 `just` 時仍可直接執行(`./script/test/test.sh --unit`),但那是實作細節;
文件與 README 以 `just ...` 為主要用法,腳本形式只作為底層一併標出。

**取代同日稍早的扁平設計**:本條第一版(同日)採扁平的單一 `justfile`:`just build` /
`just lint` / `just test [tier]` / `just check` / `just selfcheck` /
`just assemble [mode] [file]`,tier 與 mode 的驗證(`case` 加「valid: ...」清單)寫在
justfile 裡、以位置參數選模式。對照 base 審視後,同日改為本模型:那一版的頂層
recipe 全是特例(規則 1)、`lint` 與 `check` 是 `test` 的頂層同儕(規則 2)、位置參數
`[mode] [file]` 的意義靠位置記(規則 3;base ADR-00000011 明確拒絕
`just test foo.bats` 這種裸位置參數,改用 `--file`)、驗證與 usage 住在 justfile
(規則 4)。

**來源**:`just` 本身承襲自 init_ubuntu(該 repo 的 ADR-0022「`just` replaces `make`
as the task runner」),M1 建骨架時直接沿用了 `justfile` + `justfile.ci` 雙檔與
`just -f justfile.ci <recipe>` 的呼叫慣例,但在 worktool 層級一直沒有正式決策;
本條補上,命令模型則以 base ADR-00000005/10/11 為準。

**規則(往後每個 milestone)**:

1. 一個新的使用者動作 = **對的 namespace 裡的一個 recipe**(或一個新的 `mod?`
   namespace,附自己的 `justfile.<ns>` 與 `script/<ns>/`)+ **一個 justfile spec
   案例**(`test/unit/justfile_spec.bats`:recipe 存在、`*args` 原樣抵達腳本、壞參數
   由腳本而非 justfile 拒絕)+ **腳本自己擁有 `--help`**(usage、選項驗證、錯誤
   訊息)。三者缺一不可。例如 M3 的 `enter` / `rm` 就是 `box` namespace 的兩個
   recipe 加各自的腳本。
2. 不新增頂層 recipe;不在 justfile 裡驗證參數或印 usage;namespace 以動作命名。
3. CI(`.github/workflows/ci.yml`)跑的與使用者打的是同一套指令:job 名稱不變
   (lint、test-unit、test-integration、test-system、test-acceptance、
   test-system-real、ci-passed),matrix 以 `just test <tier>` 執行(tier 為 lint /
   unit / integration / system / acceptance),real job 以 `just test system-real`
   執行。
4. `just` 在 **M4 host bootstrap** 納入 host 安裝(與 docker、distrobox 一起);
   M4 之前為**前置需求**(host 需自行安裝 docker + just)。

## Milestone 計畫(細化;每個結束有人類 gate)

> 草案,供討論。定稿後才進 M1。前半(M1-M4)是基礎框架,依相依順序;後半的
> 移植(M5 起)依「重要順序」排 —— 越常用、越關鍵的越先做。

### 前半:基礎框架(依相依順序)

- M1 repo 骨架:目錄結構、justfile/測試框架、CI 骨架、文件基礎。
  Checkpoint:CI 綠、骨架可跑。Exit:人類審核。
- M2 盒子清單格式 + 最小 assemble:定義盒子套件清單格式,distrobox assemble
  一個含 1-2 個工具的盒 + 冒煙測試(含 CI 內 docker-in-docker 的真實引擎冒煙,
  2026-09-16 由 M5 提前;見「測試策略」)。
  Checkpoint:一鍵 assemble 出可用盒。Exit:人類審核。
- M3 終端自動進盒 + 效能:進盒機制 + 量測達標(< 300ms)。盒內先裝 tmux、fish
  (issue #160,`box/dev.ini` 的 `additional_packages`):終端 profile 跑的是
  `<distrobox 絕對路徑> enter dev`(issue #175:桌面啟動的終端繼承 systemd user
  manager 的 PATH,裸名字找不到),直接得到盒內 fish;不自動開 tmux(issue #179:
  distrobox 與 host 共用 /tmp,舊的 `-- tmux new -A -s main` 會附著到 host 的 tmux
  server)。盒內自己開的 tmux 由 `box/dev.ini` 設的 `TMUX_TMPDIR` 得到盒子自己的
  server;只裝套件,設定留 M5。
  Checkpoint:開終端即在盒內、達效能目標。Exit:人類審核。
- M4 host bootstrap:install.sh 在 host 裝 docker+distrobox+`just`(冪等、
  可重跑;`just` 在此之前為前置需求,見「決策」)。
  Checkpoint:全新機器一鍵到「盒子可 assemble」。Exit:人類審核。

### 後半:移植(依重要順序,最常用先)

盒子工具(由最日常關鍵往下):

- M5 shell 核心:fish + tmux(+ 盒子 HOME 裡的 tool config)。最重要,日常骨幹。
  套件本身已在 M3 裝進盒(#160);M5 做的是 tool config、主題、plugin(放在盒子
  HOME,見 `doc/adr/0002-box-owns-its-home.md`)。
- M6 導覽/檔案:ripgrep、fd、eza、bat、yazi、zoxide、fzf、tree、ncdu、lnav。
- M7 編輯器 + git:neovim、lazygit、tig、git、git-lfs。
- M8 runtime/pkg + AI CLI:python3、pipx、fnm、jq、curl、wget、gum、glow、
  unzip + claude-code、codex、gemini、notion、claude-monitor、lazydocker。
- M9 監控 TUI:htop、btop、bmon、iftop、iotop、nmon、powertop、powerstat、
  dstat、ifstat、bpytop、gpustat、nmap、gping。
- M10 shell 整合 + 其餘:thefuck + asciidoctor、ag、ansifilter、tealdeer、
  sshfs、net-tools、apt-file、cowsay、cmatrix、figlet、qmk 等。

host 層(依重要性):

- M11 host 驅動:nvidia、kvm install-script(硬體關鍵)。
- M12 host 桌面 GUI install-script:vlc/obs-studio/thunderbird/spotify-client/
  cheese/libreoffice/vscode/ibus-rime/gnome-shell-extension-manager/anydesk
  (依使用頻率分批)。

### 前端與收尾

- M13 新前端 UX 設計:規格 + 原型(design checkpoint)。
- M14 新前端實作:install/remove/list/doctor,效能達標。
- M15 CI/測試完整:完整測試金字塔(unit -> integration -> system ->
  acceptance)全面落地 + conformance + 交付/驗收清單。
  註:各 milestone 已隨附其層級測試;M15 是補齊系統/交付層級與整體 CI 收斂。
- M16 文件/遷移對照:使用文件、與 init_ubuntu 的對照、退場說明。
- M17 release 2.0.0(人類 RELEASE gate,唯一需人類同意的 release)。

## 下一步

先把 open 項目與 milestone 計畫討論定稿(M0)。定稿後依治理規則逐一開發、每個
milestone 間人類審核。
