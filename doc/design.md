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
2. bootstrap 順序:host 裝 docker+distrobox -> host install script(驅動/GUI)
   -> assemble 盒子 -> 設定終端自動進盒。
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

## Milestone 計畫(細化;每個結束有人類 gate)

> 草案,供討論。定稿後才進 M1。前半(M1-M4)是基礎框架,依相依順序;後半的
> 移植(M5 起)依「重要順序」排 —— 越常用、越關鍵的越先做。

### 前半:基礎框架(依相依順序)

- M1 repo 骨架:目錄結構、justfile/測試框架、CI 骨架、文件基礎。
  Checkpoint:CI 綠、骨架可跑。Exit:人類審核。
- M2 盒子清單格式 + 最小 assemble:定義盒子套件清單格式,distrobox assemble
  一個含 1-2 個工具的盒 + 冒煙測試。
  Checkpoint:一鍵 assemble 出可用盒。Exit:人類審核。
- M3 終端自動進盒 + 效能:進盒機制 + 量測達標(< 300ms)。
  Checkpoint:開終端即在盒內、達效能目標。Exit:人類審核。
- M4 host bootstrap:install.sh 在 host 裝 docker+distrobox(冪等、可重跑)。
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
