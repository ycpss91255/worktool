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
│   ├── system/          系統測試(bats):真實 distrobox 端到端,分兩組
│   │   ├── real_assemble_spec.bats  shim 組:真實 distrobox 1.8.2.5 + 假容器管理器(不需 DinD)
│   │   ├── real_engine_spec.bats    real-engine 組:真實 docker 引擎(DinD)建出可用 dev 盒
│   │   └── fixture/
│   │       └── fake_container_manager.sh  假 docker:逐一參數記錄、可注入失敗
│   ├── acceptance/      交付/驗收測試(bats):跑交付的公開入口
│   │   └── m2_selfcheck_spec.bats   script/selfcheck.sh 對交付 repo 印 ALL PASS(含負向)
│   └── helper/          bats 共用 helper
│       └── common.bash  路徑常數 + bats-support / bats-assert 載入
├── script/
│   ├── assemble.sh      從清單 assemble dev 盒的薄包裝器(dry-run / 真跑)
│   ├── selfcheck.sh     一鍵自檢(使用者 clone 後執行;dry-run 契約 + 無效清單拒絕)
│   └── ci/
│       ├── ci.sh        CI 進入點:在容器內跑 lint / unit / integration / system / system-real / acceptance
│       └── system-real-entry.sh  DinD runner 入口:起巢狀 dockerd、等就緒、跑 real-engine 組、清理
├── dockerfile/
│   ├── Dockerfile.test  測試映像(bash + bats + shellcheck + 鎖定版 distrobox)
│   └── Dockerfile.system-real  DinD runner 映像(docker:29.8.0-dind + bash + bats 1.14.0 + 同一鎖定版 distrobox)
├── doc/
│   ├── design.md        整體設計、治理、milestone 計畫
│   ├── manifest.md      盒子清單格式、assemble 流程、測試對應、人工驗證
│   └── structure.md     本文件
├── justfile             使用者面向的 task runner(委派到 justfile.ci)
├── justfile.ci          CI gate 定義(lint / test-unit / test-integration / test-system / test-system-real / test-acceptance)
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
- 系統(system),兩組:
  - shim 組 `test/system/real_assemble_spec.bats` —— 在測試映像內跑**真正
    的、鎖定版本的 distrobox**(1.8.2.5),容器管理器換成假的 `docker`
    (`test/system/fixture/fake_container_manager.sh`),斷言真正抵達管理器的
    create 請求帶有 `dev` / `ubuntu:26.04` / `ripgrep fzf`;不需要 docker-in-docker,
    快。不證明映像可拉、套件可裝、盒子可用。
  - real-engine 組 `test/system/real_engine_spec.bats` —— 在專用的 docker-in-docker
    runner(`dockerfile/Dockerfile.system-real`,`docker run --rm --privileged`,
    入口 `script/ci/system-real-entry.sh` 起巢狀 dockerd)內,以同一鎖定版 distrobox
    與**真實 docker 引擎**把交付的 `box/dev.ini` 建成真正的 `dev` 盒
    (`ubuntu:26.04`),斷言 `distrobox enter dev -- rg --version` / `fzf --version`
    成功、第二次 assemble 冪等、`distrobox rm -f dev` 清理乾淨;慢(約 2-3 分鐘),
    host daemon 零殘留。**這一組證明盒子可用**。
- 交付/驗收(acceptance):`test/acceptance/m2_selfcheck_spec.bats` —— 直接執行
  交付的公開入口 `script/selfcheck.sh`,斷言它對交付的 repo 印 `ALL PASS`、
  exit 0;以「清單壞掉」與「包裝器跳過驗證」負向案例證明判定不是空的。仍需要真實
  機器的驗收項目(效能、非 root、GPU)留在 [`manifest.md`](manifest.md)「M2 驗收
  紀錄」與 M3/M5。

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

# 系統測試,shim 組(test/system/*.bats 扣除 real_engine_spec;真實 distrobox + 假容器管理器)
just -f justfile.ci test-system

# 交付/驗收測試(test/acceptance/*.bats;跑交付的 script/selfcheck.sh)
just -f justfile.ci test-acceptance

# 系統測試,real-engine 組(test/system/real_engine_spec.bats;docker-in-docker,
# --privileged,慢;唯一需要 --privileged 的 recipe)
just -f justfile.ci test-system-real

# 依序跑全部(test-system-real 最後)
just -f justfile.ci test
```

首次執行會自動建置測試映像 `worktool-test:local`;之後靠 Docker 快取加速。
可用 `just -f justfile.ci build` 預先建置或在 Dockerfile 壞掉時快速失敗。
`test-system-real` 每次都會(以快取)建 DinD runner 映像
`worktool-system-real:local`(`dockerfile/Dockerfile.system-real`)。

底層由 `script/ci/ci.sh` 驅動:host 端旗標(`--lint-only` /`--unit-only` /
`--integration-only` /`--system-only` /`--acceptance-only`)會把對應的容器內
旗標(`--ci-lint` /`--ci-unit` /`--ci-integration` /`--ci-system` /
`--ci-acceptance`)丟進掛載 `/source` 的一次性容器執行;`--system-real-only`
則以 `docker run --rm --privileged` 啟動 DinD runner,由 runner 入口
`script/ci/system-real-entry.sh` 起巢狀 dockerd、等 `docker info` 就緒後再呼叫
`--ci-system-real`,結束時清理盒子並停掉 dockerd(全部隨 runner 容器銷毀,host
daemon 零殘留)。每一層 bats gate(含兩個系統組)都要求「至少跑了一個案例、無
失敗、無 `skip`、spec 存在」:被 `skip` 或不存在的必要案例不會被當成綠燈。

## CI

`.github/workflows/ci.yml` 在 push 與對 `main` 的 pull request 時,於 Docker 內
跑 lint、test-unit、test-integration、test-system、test-acceptance(共用測試
映像的 matrix),以及獨立的 `test-system-real` job(自建 DinD runner 映像、
`docker run --rm --privileged`;**唯一**使用 `--privileged` 的 job,上限 40
分鐘),並以 `ci-passed` 彙總 job 收斂:只有映像建置成功**且**每個 matrix gate
**且** `test-system-real` 都 `success` 才綠;被 skip、取消或缺席的 gate 一律視為
失敗。全綠才視為 milestone gate 通過,交由人類審核合併。
