# worktool 驗收清單(distrobox UX 累積驗收)

每個 milestone 都有明確驗收標準,分兩類:

- 自動:Docker / docker-in-docker 內可跑的具體測試或指令,必須綠。
- 人類實機:UX / 硬體 / 顯示只能在真實機器驗證的項目,列成勾選清單。

本清單累積成長:每個 milestone 貢獻自己的項目;在 M15(測試完整)與 M17
(release)整份跑一遍,作為 distrobox UX 的最終驗收。milestone 間的人類 gate
會同時檢查「自動綠」與「人類項目已勾」。

---

## M1 repo 骨架(已完成)

- 自動:`just -f justfile.ci lint / test-unit / test-integration` 全綠;
  log.sh 單元測試證明 harness 可用。

## M2 盒子清單 + 最小 assemble(審核中)

- 自動:manifest_validate 對合法清單通過、對缺 name/image 失敗;
  `assemble --dry-run` 輸出正確的 `distrobox assemble create --file ...`;
  單元 + 整合(mock distrobox)測試綠。

## M3 終端自動進盒 + 效能

- 自動:進盒延遲量測腳本回報 < 300ms;開啟終端後 shell 為盒內 fish 的自動測試。
- 人類:實機開新終端主觀順暢、無明顯延遲。

## M4 host bootstrap

- 自動:乾淨環境跑 install.sh 後 docker 與 distrobox 皆存在;再跑一次為 no-op
  (冪等測試)。
- 人類:全新機器一鍵到「盒子可 assemble」。

## M5 shell 核心(fish + tmux)

- 自動:盒內 fish 為互動 shell、tmux 可開 session;設定取自共用 HOME 的測試。
- 人類:實機 shell 操作、tmux 綁定正常。

## M6-M10 盒內工具(每工具一項)

- 自動:每個工具在盒內可呼叫且基本功能正常的 smoke 測試(例如 rg 能搜尋、
  yazi 能開、lazygit 能起)。
- 人類:抽驗數個 TUI 工具在實機顯示/互動正常。

## M11 host 驅動

- 自動:install-script 冪等 + 移除的可測部分。
- 人類(實機):`nvidia-smi` 有輸出、`virsh list` 可用。

## M12 host 桌面 GUI

- 自動:install-script 冪等 + repo/key 加入與移除對稱的可測部分。
- 人類(實機/顯示):每個 GUI app 可啟動。

## M13 新前端 UX 設計

- 人類:互動原型涵蓋 install / remove / list / doctor 流程;design checkpoint
  通過。

## M14 新前端實作

- 自動:前端四動作(install/remove/list/doctor)端到端 e2e 測試;效能達標量測。
- 人類:實機操作前端主觀順暢。

## M15 CI / 測試完整

- 自動:完整測試金字塔(單元 / 整合 / 系統 / 交付驗收)全綠;conformance 綠。
- 人類:本 acceptance.md 的所有人類項目重跑一遍並全數勾選。

## M16 文件 + 遷移對照

- 人類:依使用文件可完成安裝;與 init_ubuntu 的對照可依循。

## M17 release 2.0.0

- 自動:release 前 CI 全綠。
- 人類:全清單通過 + 明確的 RELEASE 同意(唯一需人類同意的 release)。
