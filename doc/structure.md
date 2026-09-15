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
│   ├── system/          系統測試(bats):端到端
│   │   └── real_assemble_spec.bats  真實 assemble(skip;延後到 M5)
│   └── helper/          bats 共用 helper
│       └── common.bash  路徑常數 + bats-support / bats-assert 載入
├── script/
│   ├── assemble.sh      從清單 assemble dev 盒的薄包裝器(dry-run / 真跑)
│   └── ci/
│       └── ci.sh        CI 進入點:在容器內跑 lint / unit / integration
├── dockerfile/
│   └── Dockerfile.test  輕量測試映像(bash + bats + shellcheck)
├── doc/
│   ├── design.md        整體設計、治理、milestone 計畫
│   └── structure.md     本文件
├── justfile             使用者面向的 task runner(委派到 justfile.ci)
├── justfile.ci          CI gate 定義(lint / test-unit / test-integration)
└── .github/workflows/
    └── ci.yml           GitHub Actions:push / PR 到 main 時跑三個 gate
```

命名採全單數(沿用 init_ubuntu 慣例):`test/`、`script/`、`doc/`、`lib/`、
`box/`、`tool/`、`dockerfile/`。

## 測試策略對應

四層測試金字塔見 [`design.md`](design.md)「測試策略」。M2 落地前三層(單元 /
整合 / 系統佔位),盒子清單細節見 [`manifest.md`](manifest.md):

- 單元(unit):`test/unit/*.bats` —— `log_spec.bats` 驗證 `lib/log.sh`;
  `manifest_spec.bats` 驗證清單解析/驗證;`assemble_spec.bats` 驗證 dry-run 的
  指令組裝。
- 整合(integration):`test/integration/*.bats` —— `smoke_spec.bats` 證明 Docker
  harness 能跑;`assemble_spec.bats` 以 mock `distrobox` 證明 assemble 端到端接線
  (`distrobox assemble create --file box/dev.ini`)。
- 系統(system):`test/system/real_assemble_spec.bats` —— 真實 assemble 需要
  docker-in-docker,依 [`design.md`](design.md) 延後到 M5;目前以被 `skip` 的佔位
  測試記錄未來驗證方式,且未接進 CI gate。
- 交付/驗收(acceptance):後續 milestone 補齊。

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

# 依序跑三者
just -f justfile.ci test
```

首次執行會自動建置測試映像 `worktool-test:local`;之後靠 Docker 快取加速。
可用 `just -f justfile.ci build` 預先建置或在 Dockerfile 壞掉時快速失敗。

底層由 `script/ci/ci.sh` 驅動:host 端旗標(`--lint-only` /`--unit-only` /
`--integration-only`)會把對應的容器內旗標(`--ci-lint` /`--ci-unit` /
`--ci-integration`)丟進掛載 `/source` 的一次性容器執行。

## CI

`.github/workflows/ci.yml` 在 push 與對 `main` 的 pull request 時,於 Docker 內
依序跑 lint、test-unit、test-integration。三者皆綠才視為 M1 gate 通過,交由人類
審核合併。
