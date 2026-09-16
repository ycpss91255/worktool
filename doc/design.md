# worktool 設計文件(討論中)

狀態:設計討論中(M0)。milestone 計畫定稿並經人類核准前,不開始實作。

## 願景

以 distrobox 為基礎的模型,取代 init_ubuntu「apt 直接裝到 host」的 module
系統。開發用 CLI/TUI 工具全部住在一個共用的 distrobox「dev 盒」,使用者直接
活在盒內(終端自動進盒);host 只保留驅動、docker、snapd、桌面 GUI app(以
install script 形式)與容器框架。設定檔留在共用 HOME。

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
  該 milestone 的實作 PR 掛在對應的 Milestone 下,merge 前不自動合併(等人類
  gate)。
- 驗收標準:每個 milestone 與 sub-issue 都有明確驗收標準(自動 + 人類實機),
  累積於 doc/acceptance.md;milestone 的人類 gate 檢查「自動測試綠」與「人類
  實機項目已勾」兩者。這是確保 distrobox UX 最終可驗收的機制。

## 已定共識(2026-09-15)

1. distrobox 作為 base 框架。
2. 一個共用「dev」盒裝所有容器化 CLI/TUI 工具。
3. 活在盒裡:終端自動進盒;fish/tmux/zoxide/fzf/thefuck + 所有編輯器/CLI/TUI/
   監控/AI 工具都在盒內。
4. 設定留共用 HOME(distrobox 共用 HOME):`~/.config/*`、`~/.gitconfig`、
   `~/.ssh`;工具在盒、設定共用,不需同步。
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

### 2026-09-16:just 是使用者的通用介面

**決策**:`just` 是 worktool **使用者的通用介面**。所有使用者可執行的動作都以
`just <動詞> [受詞]` 暴露;腳本(`script/ci/ci.sh`、`script/selfcheck.sh`、
`script/assemble.sh`)是**實作、不是介面**。

**理由**(維護者原話):使用者的通用輸入應該一致(`just test`、`just test unit`),
直接呼叫腳本很麻煩。

**規則**:

1. 所有使用者可執行的動作都以 `just <動詞> [受詞]` 暴露;腳本是實作、不是介面。
   文件與 README 以 `just ...` 為主要用法,腳本形式只作為「沒有 just 時」的
   底層備援(fallback)一併標出。
2. 每個 milestone 新增的使用者動作都要有對應的 recipe,並有 justfile 測試
   (recipe 的存在、參數驗證、對應到正確的腳本旗標)。
3. 單一 `justfile`:`justfile.ci` 移除,不再有 `just -f justfile.ci <recipe>`
   這第二套呼叫方式;CI 跑的與使用者跑的是同一個 `just check`。
4. `just` 在 **M4 host bootstrap** 納入 host 安裝(與 docker、distrobox 一起);
   M4 之前為**前置需求**(host 需自行安裝 docker + just)。腳本在沒有 `just`
   時仍可直接執行,但那是實作細節,不是文件化的主要用法。

**介面文法**(固定):

| 指令 | 作用 |
|------|------|
| `just` | 列出所有 recipe |
| `just build` | 建置測試映像(選用;gate 會按需自動建) |
| `just lint` | ShellCheck gate(Docker 內) |
| `just test [tier]` | tier = `unit` / `integration` / `system` / `system-real` / `acceptance` / `all`(預設 `all`)。`all` 依序跑 unit、integration、system、acceptance、system-real(system-real 最後:docker-in-docker、`--privileged`、慢)。無效的 tier:清楚的錯誤訊息、exit 1、什麼都不跑 |
| `just check` | lint + test all(= CI 跑的內容,一模一樣) |
| `just selfcheck` | `./script/selfcheck.sh`(交付自檢) |
| `just assemble [mode] [file]` | mode = `run`(預設;在 host 上真的呼叫 distrobox)/ `dry-run`(只印出 distrobox 指令、什麼都不執行);file = 清單路徑,預設 `box/dev.ini`(要指定清單就必須明寫 mode,例如 `just assemble dry-run box/other.ini`) |

對應的實作(recipe 呼叫的底層腳本;沒有 `just` 時可直接執行):
`script/ci/ci.sh --lint-only | --unit-only | --integration-only | --system-only |
--acceptance-only | --system-real-only | --build`、`script/selfcheck.sh`、
`script/assemble.sh [--dry-run]`。

**來源**:此做法承襲自 init_ubuntu(該 repo 的 ADR-0022「`just` replaces `make`
as the task runner」),M1 建骨架時直接沿用了 `justfile` + `justfile.ci` 雙檔與
`just -f justfile.ci <recipe>` 的呼叫慣例,但在 worktool 層級一直沒有正式決策;
本條補上,並以「單一 justfile、`just <動詞> [受詞]` 文法」取代沿用的形式。

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
- M3 終端自動進盒 + 效能:進盒機制 + 量測達標(< 300ms)。
  Checkpoint:開終端即在盒內、達效能目標。Exit:人類審核。
- M4 host bootstrap:install.sh 在 host 裝 docker+distrobox+`just`(冪等、
  可重跑;`just` 在此之前為前置需求,見「決策」)。
  Checkpoint:全新機器一鍵到「盒子可 assemble」。Exit:人類審核。

### 後半:移植(依重要順序,最常用先)

盒子工具(由最日常關鍵往下):

- M5 shell 核心:fish + tmux(+ 共用 HOME 設定)。最重要,日常骨幹。
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
