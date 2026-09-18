# 目錄結構與測試 gate

本文件說明 worktool 的 repo 目錄結構,以及如何在 Docker 內執行各項測試
gate。狀態:M2(盒子清單格式 + 最小 assemble)。M1 建立骨架、測試框架與 CI;
M2 加入第一個 distrobox 邏輯:盒子清單格式與 assemble 包裝器(見
[`manifest.md`](manifest.md))。

## 目錄結構

```text
worktool/
├── lib/                 共用 bash helper(被 tool/box/script 腳本 source)
│   ├── log.sh           日誌 helper:log_info / log_warn / log_error(寫入 stderr)
│   └── manifest.sh      盒子清單 helper:manifest_name / manifest_image / manifest_validate
├── box/                 distrobox 盒子清單
│   └── dev.ini          共用 dev 盒清單(distrobox-assemble 格式;M2 最小工具集)
├── tool/                host 端 GUI/驅動 install script(M11/M12 佔位,.gitkeep)
├── test/
│   ├── unit/            單元測試(bats):個別函式/腳本隔離測試
│   │   ├── log_spec.bats
│   │   ├── manifest_spec.bats    清單驗證與欄位擷取
│   │   └── assemble_spec.bats    assemble 指令組裝(dry-run)
│   ├── integration/     整合測試(bats):元件協作,在 Docker 內跑
│   │   ├── smoke_spec.bats
│   │   └── assemble_spec.bats    以 mock distrobox 驗證 assemble 接線
│   ├── system/          系統測試(bats):真實 distrobox 端到端(不需 DinD)
│   │   ├── real_assemble_spec.bats  真實 distrobox 1.8.2.5 + 假容器管理器
│   │   └── fixture/
│   │       └── fake_container_manager.sh  假 docker:逐一參數記錄、可注入失敗
│   └── helper/          bats 共用 helper
│       └── common.bash  路徑常數 + bats-support / bats-assert 載入
├── script/
│   ├── assemble.sh      從清單 assemble dev 盒的薄包裝器(dry-run / 真跑)
│   └── ci/
│       └── ci.sh        CI 進入點:在容器內跑 lint / unit / integration / system
├── dockerfile/
│   └── Dockerfile.test  測試映像(bash + bats + shellcheck + 鎖定版 distrobox)
├── doc/
│   ├── design.md        整體設計、治理、milestone 計畫
│   ├── manifest.md      盒子清單格式、assemble 流程、測試對應、人工驗證
│   └── structure.md     本文件
├── justfile             使用者面向的 task runner(委派到 justfile.ci)
├── justfile.ci          CI gate 定義(lint / test-unit / test-integration / test-system)
└── .github/workflows/
    └── ci.yml           GitHub Actions:push / PR 到 main 時跑全部 gate + ci-passed 彙總
```

命名採全單數(沿用 init_ubuntu 慣例):`test/`、`script/`、`doc/`、`lib/`、
`box/`、`tool/`、`dockerfile/`。

## 測試策略對應

四層測試金字塔見 [`design.md`](design.md)「測試策略」;每一層驗證什麼、延後
什麼,詳見 [`manifest.md`](manifest.md)「測試對應」。M2 落地:

- 單元(unit):`test/unit/*.bats` —— `log_spec.bats` 驗證 `lib/log.sh`;
  `manifest_spec.bats` 驗證清單解析/驗證;`assemble_spec.bats` 驗證 dry-run 的
  指令組裝。
- 整合(integration):`test/integration/*.bats` —— `smoke_spec.bats` 證明 Docker
  harness 能跑;`assemble_spec.bats` 以 mock `distrobox` 證明 assemble 端到端接線
  (`distrobox assemble create --file box/dev.ini`)。
- 系統(system):`test/system/real_assemble_spec.bats` —— 在測試映像內跑**真正
  的、鎖定版本的 distrobox**(1.8.2.5),容器管理器換成假的 `docker`
  (`test/system/fixture/fake_container_manager.sh`),斷言真正抵達管理器的
  create 請求帶有 `dev` / `ubuntu:26.04` / `ripgrep fzf`;不需要 docker-in-docker。
  不證明映像可拉、套件可裝、盒子可用(延後到 M5)。
- 交付/驗收(acceptance):後續 commit 補齊。

## 執行 gate(全部在 Docker 內)

所有測試都在 Docker 容器內執行,host 不安裝任何套件。前置需求:host 需有
`docker` 與 `just`。

```bash
# ShellCheck 檢查所有 *.sh 與 *.bats
just -f justfile.ci lint

# 單元測試(test/unit/*.bats)
just -f justfile.ci test-unit

# 整合測試(test/integration/*.bats)
just -f justfile.ci test-integration

# 系統測試(test/system/*.bats;真實 distrobox + 假容器管理器)
just -f justfile.ci test-system

# 依序跑全部
just -f justfile.ci test
```

首次執行會自動建置測試映像 `worktool-test:local`;之後靠 Docker 快取加速。
可用 `just -f justfile.ci build` 預先建置或在 Dockerfile 壞掉時快速失敗。

底層由 `script/ci/ci.sh` 驅動:host 端旗標(`--lint-only` /`--unit-only` /
`--integration-only` /`--system-only`)會把對應的容器內旗標(`--ci-lint` /
`--ci-unit` /`--ci-integration` /`--ci-system`)丟進掛載 `/source` 的一次性容器
執行。每一層 bats gate 都要求「至少跑了一個案例、無失敗、無 `skip`」:被
`skip` 或不存在的必要案例不會被當成綠燈。

## CI

`.github/workflows/ci.yml` 在 push 與對 `main` 的 pull request 時,於 Docker 內
跑 lint、test-unit、test-integration、test-system,並以 `ci-passed` 彙總
job 收斂:只有映像建置成功**且**每個 gate 都 `success` 才綠;被 skip、取消或
缺席的 gate 一律視為失敗。全綠才視為 milestone gate 通過,交由人類審核合併。
