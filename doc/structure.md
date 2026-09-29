# 目錄結構與測試 gate

本文件說明 worktool 的 repo 目錄結構、`just` 使用者介面,以及如何在 Docker 內
執行各項測試 gate。狀態:M2(盒子清單格式 + 最小 assemble)。M1 建立骨架、測試
框架與 CI;M2 加入第一個 distrobox 邏輯:盒子清單格式與 assemble 包裝器(見
[`manifest.md`](manifest.md)),並把 `just` 定為使用者介面(base 模型,見下)。

## 目錄結構

```text
worktool/
├── lib/                 共用 bash helper(被 tool/box/script 腳本 source)
│   ├── log.sh           日誌 helper:log_info / log_warn / log_error(寫入 stderr)
│   ├── manifest.sh      盒子清單 helper:manifest_name / manifest_image / manifest_validate
│   ├── approval.sh      milestone-gate 核准判斷(純函式,不呼叫 GitHub API):approval_evaluate / approval_is_human_approval(#187)
│   ├── commit_email.sh  commit email 判斷(純函式):author 必須是 GitHub noreply,committer 為 noreply 或 noreply@github.com(commit_email_evaluate / commit_email_range,#234)
│   └── enter.sh         自動進盒 helper:路徑(HOME / XDG_CONFIG_HOME)、預設值、執行檔解析與 shell quoting(ghostty / distrobox,issue #175)、設定檔讀取、受管區塊(setup.sh / status.sh 共用)
├── box/                 distrobox 盒子清單
│   └── dev.ini          共用 dev 盒清單(distrobox-assemble 格式;M2 最小工具集)
├── tool/                host 端 GUI/驅動 install script(M11/M12 佔位,.gitkeep)
├── script/              腳本樹,依「動作」命名,每個動作一個目錄 = 一個 just 命名空間
│   ├── test/            自我測試(just test ...)
│   │   ├── justfile.test        `test` 命名空間:薄轉發到 test.sh / selfcheck.sh
│   │   ├── test.sh              測試執行器:host 端旗標 --lint/--unit/.../--system-real
│   │   │                        (無旗標 = 全部依序跑);容器內以 --ci-* 跑真正的 gate
│   │   ├── selfcheck.sh         一鍵自檢(使用者 clone 後執行;dry-run 契約 + 無效清單拒絕)
│   │   └── system-real-entry.sh DinD runner 入口:起巢狀 dockerd、等就緒、跑 real-engine 組、清理
│   └── box/             dev 盒生命週期(just box ...)
│       ├── justfile.box         `box` 命名空間:薄轉發到 assemble.sh / bench.sh / setup.sh / status.sh(M3 再加 enter / rm)
│       ├── assemble.sh          從清單 assemble dev 盒的薄包裝器(--dry-run / --file / --help)
│       ├── setup.sh             終端自動進盒設定:--auto-enter / --terminal / --tmux / --box / --distrobox / --dry-run / --help;寫單一設定檔 + 受管區塊(distrobox 寫已 quote 的絕對路徑;見 enter.md)
│       └── status.sh            印出生效的進盒決策、來源(default / user)、受管區塊是否存在,以及受管 command 裡的 distrobox 還跑不跑得起來(--help)
├── test/
│   ├── unit/            單元測試(bats):個別函式/腳本隔離測試
│   │   ├── log_spec.bats
│   │   ├── manifest_spec.bats    清單驗證與欄位擷取
│   │   ├── assemble_spec.bats    assemble 指令組裝(dry-run)+ CLI(--help / 未知選項 exit 2)
│   │   ├── setup_spec.bats       setup.sh:預設 + 每行 log、user 覆蓋、區塊只寫一次且冪等、tmux host 變體、--auto-enter no 移除並回報、--dry-run 不寫、CLI、ghostty 執行檔偵測與 distrobox 絕對路徑(#175)(暫時 HOME)
│   │   ├── status_spec.bats      status.sh:設定檔與來源、受管區塊 present / absent、distrobox 是否還跑得起來(#175)、無設定檔時的預設報告、CLI(暫時 HOME)
│   │   ├── test_sh_spec.bats     test.sh host 端 CLI:--help、未知選項、無旗標的執行順序與遇錯即停(假 docker 記錄呼叫)
│   │   ├── selfcheck_spec.bats   selfcheck.sh CLI 與新版面下的路徑解析(script/box/assemble.sh)
│   │   ├── ci_gate_spec.bats     test.sh 每層必要 spec 防漏:在 repo 副本上刪檔/空檔必紅、正常樹必綠
│   │   ├── system_real_entry_spec.bats  DinD runner 入口:docker 卡死時等待/清理仍在期限內結束
│   │   ├── justfile_spec.bats    just 文法:根 justfile 只有命名空間、每個 recipe 原封轉發 argv、錯誤來自 just 或腳本本身
│   │   ├── diagram_spec.bats     README 三張 draw.io 圖的單一事實來源守門:存在、是 SVG、無 foreignObject、內嵌 mxfile、README 引用
│   │   ├── ci_yml_spec.bats      ci.yml 兩架構矩陣:每個 job 跑兩種 runner、artifact 依 runner 命名、ci-passed 依賴全部
│   │   ├── approval_spec.bats    lib/approval.sh:未貼標籤、有標籤無核准、非 OWNER、[claude]/[codex] 開頭、正確核准(#187)
│   │   ├── commit_email_spec.bats  lib/commit_email.sh:noreply 通過、一般 email 失敗、noreply@github.com committer 不豁免 author、偽造日期／web-flow committer 不能繞過、範圍輸入狀態矩陣(事件用到的欄位缺值即擋、另一事件的欄位忽略)與實際檢查的 commit 集合、git log 往返(#234)
│   │   ├── milestone_gate_yml_spec.bats  milestone-gate.yml 的觸發事件、權限、只跑 main 的可信 checkout、status context 名稱、job 不與 context 同名(文字層級)
│   │   ├── agent_config_spec.bats  repo 層級 agent 設定(#189):.claude/* symlink、settings.json 只註冊帶進來的 hook 且都從
│   │   │                           ${CLAUDE_PROJECT_DIR} 路徑跑得起來、不依賴 initialization 路徑、memory 全是實體檔且索引齊全、skill 清單、
│   │   │                           skill / memory 已改成 worktool 語境(doc/agent、doc/adr、無不存在的介面、無斷掉的 [[連結]]、無個人或本機資訊)
│   │   ├── hook/                 .agents/hook/ 每支 hook 與 lib 的 spec(以 stdin JSON 驅動,跟 Claude Code 呼叫方式相同)
│   │   ├── script/               .agents/script/ 的 wait-pr-ci.sh / watch-user-replies.sh spec(gh 以 PATH stub 取代)
│   │   └── fixture/
│   │       └── entry_driver.sh   在隔離 shell 內驅動 system-real-entry.sh 的單一函式
│   ├── integration/     整合測試(bats):元件協作,在 Docker 內跑
│   │   ├── smoke_spec.bats
│   │   ├── assemble_spec.bats    以 mock distrobox 驗證 assemble 接線
│   │   └── setup_spec.bats       setup -> status 來回(暫時 HOME):host 變體、切回 inside、--auto-enter no、--dry-run、log 與報告一致、受管 command 在桌面式縮減 PATH 下可執行(#175)
│   ├── system/          系統測試(bats):真實 distrobox 端到端,分兩組
│   │   ├── real_assemble_spec.bats  shim 組:真實 distrobox 1.8.2.5 + 假容器管理器(不需 DinD)
│   │   ├── real_engine_spec.bats    real-engine 組:真實 docker 引擎(DinD)建出可用 dev 盒
│   │   └── fixture/
│   │       └── fake_container_manager.sh  假 docker:逐一參數記錄、可注入失敗
│   ├── acceptance/      交付/驗收測試(bats):跑交付的公開入口
│   │   └── m2_selfcheck_spec.bats   script/test/selfcheck.sh 對交付 repo 印 ALL PASS(含負向)
│   └── helper/          bats 共用 helper
│       ├── common.bash  路徑常數 + bats-support / bats-assert 載入
│       └── hook.bash    hook spec 共用:hook_json / run_hook / disable_line
├── dockerfile/
│   ├── Dockerfile.test  測試映像(bash + bats + shellcheck + just + jq + 鎖定版 distrobox)
│   └── Dockerfile.system-real  DinD runner 映像(docker:29.8.0-dind + bash + bats 1.14.0 + 同一鎖定版 distrobox)
├── doc/
│   ├── design.md        整體設計、治理、milestone 計畫
│   ├── manifest.md      盒子清單格式、assemble 流程、測試對應、人工驗證
│   ├── workflow.md      Workflow 範本說明:pr-loop(一個 sub-issue -> 一個 PR 的實作/CI/codex/修正迴圈)與 milestone-fanout
│   ├── enter.md         終端自動進盒:just box setup / status 的選項、設定檔、受管區塊、範例 log
│   ├── structure.md     本文件
│   ├── acceptance.md    驗收清單(通用指令 + 各 milestone 的人類驗收項目)
│   ├── agent/           給 agent skill 讀的設定:issue-tracker.md / triage-labels.md / domain.md
│   └── diagram/         README 嵌入的 draw.io 圖;`.drawio.svg` 同時是圖與可編輯原始檔(單一事實來源,
│       │                純 SVG 文字、無 foreignObject,GitHub 可直接顯示;以 Docker 內的 drawio 匯出,host 不裝 draw.io)
│       ├── architecture.drawio.svg  架構:host -> distrobox -> dev 盒、盒子 HOME、ghostty -> tmux -> fish
│       ├── flow.drawio.svg          流程:clone -> just test -> just box assemble -> 進盒 -> 日常;CI matrix -> ci-passed
│       └── milestone.drawio.svg     milestone:M1-M17 順序、每段之間的人類 gate、目前位置
├── .agents/             agent 設定的實體檔(repo 層級:不依賴別的 repo、不在使用者層級建立任何東西;#189)
│   ├── hook/            Claude Code hook(test-must-use-docker、enforce_long_job_timeout、check_main_fresh_before_worktree、
│   │   │                remind_main_sync、enforce_gh_body_file、enforce_codex_round_cap、enforce_scope_on_guard_issues、enforce_shellcheck_disable_approval、worktree_create、
│   │   │                remind_workflow_tdd、remind_no_emoji)
│   │   └── lib/         hook 共用 lib(hook_bootstrap.sh、subcommand.sh);hook 以自身位置 source,不碰 repo 的 lib/
│   ├── script/          agent 用的 Monitor 腳本:wait-pr-ci.sh(等 PR 的 ci-passed)、watch-user-replies.sh
│   │                    (state 預設在被 gitignore 的 .agents/state/)
│   ├── skills/          agent skill 的實體檔:i-have-adhd(#191)+ 工程類 skill(tdd、triage、wait-pr-ci ...,#189)
│   └── memory/          agent memory 的實體檔 + MEMORY.md 索引
├── .claude/
│   ├── settings.json    進版控的 hook 註冊,一律 ${CLAUDE_PROJECT_DIR}/.claude/hook/<名稱>.sh
│   ├── hook             -> ../.agents/hook(以下四個都是相對 symlink,真檔在 .agents/)
│   ├── script           -> ../.agents/script
│   ├── skills           -> ../.agents/skills(Claude Code 從專案目錄載入 skill)
│   ├── memory           -> ../.agents/memory
│   └── workflows/       Claude Code Workflow 範本(見 doc/workflow.md)
│       ├── pr-loop.js
│       └── milestone-fanout.js
├── .vscode/
│   └── extensions.json  推薦 `hediet.vscode-drawio`:在 VS Code 內就地編輯 `doc/diagram/*.drawio.svg`
├── AGENTS.md            給 agent 的 repo 約定(Agent skills、決議流程、git 慣例、shell 慣例);CLAUDE.md 是指向它的 symlink
├── justfile             使用者介面入口:只有兩行 `mod?`(test / box)+ `default`(= just --list)
└── .github/workflows/
    ├── ci.yml           GitHub Actions:push / PR 到 main 時以 `just test <tier>` 跑全部 gate + commit-email + ci-passed 彙總
    └── milestone-gate.yml  PR / PR 留言事件時以 lib/approval.sh 判斷,設 commit status `milestone-gate-approval`(#187)
```

命名採全單數(沿用 init_ubuntu 慣例):`test/`、`script/`、`doc/`、`lib/`、
`box/`、`tool/`、`dockerfile/`。`script/` 之下依**動作**分目錄(`test/`、
`box/`),而不是依 ci/cd 之類的流程角色。

## 使用者介面:`just`(base 模型)

`just` 就是 worktool 的使用者介面,介面模型沿用
[ycpss91255-docker/base](https://github.com/ycpss91255-docker/base)
(ADR-00000005/10/11),原則如下:

- **零特例**:根 `justfile` 只有 `mod?` 行(每個動作一個命名空間)加一個
  `default`(= `just --list`);根層沒有任何其他 recipe。
- **動作命名的命名空間**:`test`、`box`(永遠不用 ci / cd 這種流程角色);
  `script/<動作>/` 就是該命名空間的家,`justfile.<動作>` 與它轉發的腳本放在一起。
- **min -> max**:不帶參數的 `just test` 跑**全部**(CI 跑的一切);子 recipe
  與旗標只用來**縮小**範圍。
- **薄轉發**:每個 recipe 只是把 `*args` 原封不動(`set positional-arguments`
  + `"$@"`,argv 邊界保留)交給背後的腳本;**所有**驗證、用法文字、選項清單、
  `--help` 都在腳本裡。justfile 永遠不印用法、不印 `valid: ...` 之類的清單。
- **每個命名空間有自己的 `default` 與 `help`(別名 `h`)**,並以
  `set working-directory := '../..'` 讓 recipe 一律在 repo 根目錄執行,所以
  `just` 可以在 repo 的任何子目錄使用(例如 `cd doc && just box assemble --dry-run`)。

沒有 `just` 的機器上直接呼叫腳本效果完全相同(`./script/test/test.sh --unit`、
`./script/box/assemble.sh --dry-run`),`just` 只是它們的介面。

| 指令 | 實際執行 |
|------|----------|
| `just` | `just --list`(列出命名空間) |
| `just test` | `./script/test/test.sh`(全部:lint、unit、integration、system、acceptance、system-real,依序、遇錯即停) |
| `just test build [args]` | `./script/test/test.sh --build [args]` |
| `just test lint [args]` | `./script/test/test.sh --lint [args]` |
| `just test unit [args]` | `./script/test/test.sh --unit [args]` |
| `just test integration [args]` | `./script/test/test.sh --integration [args]` |
| `just test system [args]` | `./script/test/test.sh --system [args]` |
| `just test system-real [args]` | `./script/test/test.sh --system-real [args]` |
| `just test acceptance [args]` | `./script/test/test.sh --acceptance [args]` |
| `just test selfcheck [args]` | `./script/test/selfcheck.sh [args]`(`--root X` 直接透傳) |
| `just test help` / `just test h` | `./script/test/test.sh --help` |
| `just box` | 列出 box 的動詞(`just --justfile script/box/justfile.box --list`) |
| `just box assemble [args]` | `./script/box/assemble.sh [args]`(`--dry-run`、`--file <清單>`、`--help`) |
| `just box setup [args]` | `./script/box/setup.sh [args]`(`--auto-enter yes\|no`、`--terminal ghostty\|none`、`--tmux inside\|host`、`--box <名稱>`、`--dry-run`、`--help`;見 [`enter.md`](enter.md)) |
| `just box status [args]` | `./script/box/status.sh [args]`(`--help`) |
| `just box help` / `just box h` | 依序 `./script/box/assemble.sh --help`、`./script/box/bench.sh --help`、`./script/box/setup.sh --help`、`./script/box/status.sh --help` |

錯誤來源分兩種,都不是 justfile 印的:`just test bogus` 是 just 自己的
「does not contain recipe」(exit 1),什麼都不會跑;`just box assemble --bogus`
是 `assemble.sh` 自己的 `assemble.sh: unknown option '--bogus' (see --help)`
(exit 2),同樣在任何東西執行之前就拒絕。`test.sh` / `selfcheck.sh` /
`setup.sh` / `status.sh` 的未知選項也是同一形式(`<腳本>: unknown option '<x>'
(see --help)`,exit 2)。

`just box assemble` 的例子:`just box assemble --dry-run` 印出
`distrobox assemble create --file box/dev.ini`;
`just box assemble --dry-run --file /tmp/a.ini` 對 `/tmp/a.ini` 做驗證(壞清單會以
exit 1 印出 `[ERROR] manifest missing required key 'image' ...`);
`just box assemble` 真的建盒。

`just box setup` / `just box status` 的例子與每個決策的 `[INFO]` log 見
[`enter.md`](enter.md)「進盒設定」。

## 測試策略對應

四層測試金字塔見 [`design.md`](design.md)「測試策略」;每一層驗證什麼、延後
什麼,詳見 [`manifest.md`](manifest.md)「測試對應」。M2 落地:

- 單元(unit):`test/unit/*.bats` —— `log_spec.bats` 驗證 `lib/log.sh`;
  `manifest_spec.bats` 驗證清單解析/驗證;`assemble_spec.bats` 驗證 dry-run 的
  指令組裝與 CLI;`test_sh_spec.bats` 以假 `docker` 驗證 `test.sh` 的 host 端
  CLI(無旗標的順序、遇錯即停、`--help`、未知選項);`selfcheck_spec.bats`
  驗證 `selfcheck.sh` 在新版面下仍找得到 `script/box/assemble.sh`;
  `justfile_spec.bats` 以 stub 腳本驗證整套 just 文法的轉發;`diagram_spec.bats`
  守住 README 三張 draw.io 圖的單一事實來源(`doc/diagram/*.drawio.svg` 存在、是
  SVG、不含 `<foreignObject>`、內嵌 `mxfile`、README 以連到 app.diagrams.net 的圖
  嵌入、`.vscode/extensions.json` 推薦 `hediet.vscode-drawio`)。
- 整合(integration):`test/integration/*.bats` —— `smoke_spec.bats` 證明 Docker
  harness 能跑;`assemble_spec.bats` 以 mock `distrobox` 證明 assemble 端到端接線
  (`distrobox assemble create --file box/dev.ini`)。
- 系統(system),兩組:
  - shim 組 `test/system/real_assemble_spec.bats` —— 在測試映像內跑**真正
    的、鎖定版本的 distrobox**(1.8.2.5),容器管理器換成假的 `docker`
    (`test/system/fixture/fake_container_manager.sh`),斷言真正抵達管理器的
    create 請求帶有 `dev` / `ubuntu:26.04` / `ripgrep fzf tmux fish`;不需要 docker-in-docker,
    快。不證明映像可拉、套件可裝、盒子可用。
  - real-engine 組 `test/system/real_engine_spec.bats` —— 在專用的 docker-in-docker
    runner(`dockerfile/Dockerfile.system-real`,`docker run --rm --privileged`,
    入口 `script/test/system-real-entry.sh` 起巢狀 dockerd)內,以同一鎖定版 distrobox
    與**真實 docker 引擎**把交付的 `box/dev.ini` 建成真正的 `dev` 盒
    (`ubuntu:26.04`),斷言 `distrobox enter dev -- rg --version` / `fzf --version`
    / `tmux -V` / `fish --version` 成功(tmux、fish 是 M3 #160 加的 auto-enter 前提,
    設定留 M5)、以 `fish -c exit` 量的進盒延遲 gate 達標、第二次 assemble 冪等、
    `distrobox rm -f dev` 清理乾淨;慢(約 2-3 分鐘)。
    測試建立的容器/映像/volume 都在巢狀 daemon 內、隨 runner 銷毀,host daemon
    只留下 runner 映像 `worktool-system-real:local` 與建置快取(見
    [`manifest.md`](manifest.md)「測試對應」的精確說明)。**這一組證明盒子可用**
    (驗證邊界:套件在第一次 `distrobox enter` 時才初始化,測試證明的是
    「assemble 後 enter 可完成初始化並使用工具」)。
- 交付/驗收(acceptance):`test/acceptance/m2_selfcheck_spec.bats` —— 直接執行
  交付的公開入口 `script/test/selfcheck.sh`,斷言它對交付的 repo 印 `ALL PASS`、
  exit 0;以「清單壞掉」與「包裝器跳過驗證」負向案例證明判定不是空的。仍需要真實
  機器的驗收項目(效能、非 root、GPU)留在 [`manifest.md`](manifest.md)「M2 驗收
  紀錄」與 M3/M5。

## 執行 gate(全部在 Docker 內)

所有測試都在 Docker 容器內執行,host 不安裝任何套件。前置需求:host 需有
`docker` 與 `just`(`just` 是使用者的通用介面,見 design.md「決策」);沒有 `just`
的機器上可直接呼叫底層實作 `./script/test/test.sh --lint` / `--unit` /
`--integration` / `--system` / `--acceptance` / `--system-real`(或不帶旗標跑全部)
效果完全相同;`./script/test/test.sh --help` 列出全部選項。

```bash
# ShellCheck 檢查所有 *.sh 與 *.bats
just test lint

# 單元測試(test/unit/*.bats)
just test unit

# 整合測試(test/integration/*.bats)
just test integration

# 系統測試,shim 組(test/system/*.bats 扣除 real_engine_spec;真實 distrobox + 假容器管理器)
just test system

# 交付/驗收測試(test/acceptance/*.bats;跑交付的 script/test/selfcheck.sh)
just test acceptance

# 系統測試,real-engine 組(test/system/real_engine_spec.bats;docker-in-docker,
# --privileged,慢;唯一需要 --privileged 的 tier)
just test system-real

# 全部(lint、unit、integration、system、acceptance、system-real,依序,遇到第一個
# 失敗就停):與 CI 完全相同
just test

# 跑交付的一鍵自檢(host 直接跑,不進容器)
just test selfcheck
```

首次執行會自動建置測試映像 `worktool-test:local`;之後靠 Docker 快取加速。
可用 `just test build` 預先建置或在 Dockerfile 壞掉時快速失敗。
`just test system-real` 每次都會(以快取)建 DinD runner 映像
`worktool-system-real:local`(`dockerfile/Dockerfile.system-real`)。

底層由 `script/test/test.sh` 驅動(`just test` 只是它的介面):host 端旗標
(`--lint` / `--unit` / `--integration` / `--system` / `--acceptance`)會把對應的
容器內旗標(`--ci-lint` / `--ci-unit` / `--ci-integration` / `--ci-system` /
`--ci-acceptance`)丟進掛載 `/source` 的一次性容器執行;`--system-real`
則以 `docker run --rm --privileged` 啟動 DinD runner,由 runner 入口
`script/test/system-real-entry.sh` 起巢狀 dockerd、等 `docker info` 就緒後再呼叫
`--ci-system-real`,結束時清理盒子並停掉 dockerd(巢狀 daemon 內的一切隨 runner
容器銷毀;host daemon 只留 runner 映像與建置快取;入口對 `docker info` /
`docker ps` / `distrobox rm` / `docker rm` 的每一次呼叫都各自包在 `timeout` 內,
等待迴圈以 `WORKTOOL_DOCKERD_READY_TIMEOUT` 為權威總期限——就緒探測失敗或成功都一樣:
探測成功後的引擎資訊查詢只拿得到**剩餘**的就緒預算,預算用完就直接略過並說明,
整個等待的最壞情況固定為期限 + 5 秒 kill 寬限 + 1 秒,daemon 卡死也不會把本機
執行拖過期限;`WORKTOOL_DOCKERD_READY_TIMEOUT` / `WORKTOOL_DOCKER_CALL_TIMEOUT`
在起 dockerd 之前就先驗證必須是正整數,`0`(等於 `timeout` 無上限)、負數、非數字
一律直接失敗;清理時若查不到剩餘容器數(`docker ps` 失敗或逾時)會如實印出
`unknown (query failed)` 而不是假的 `0`)。`test.sh` 會先把整條命令列解析完才開始
執行,未知選項在任何 docker 呼叫之前就以 exit 2 拒絕。每一層 bats gate(含兩個
系統組)都在 `test.sh` 的 `_required_specs` 明列**必要 spec**(unit:`log_spec`、
`manifest_spec`、`assemble_spec`、`ci_gate_spec`、`system_real_entry_spec`、
`test_sh_spec`、`selfcheck_spec`、`justfile_spec`、`diagram_spec`、`ci_yml_spec`、`bench_spec`、
`setup_spec`、`status_spec`、`workflow_spec`、`approval_spec`、`commit_email_spec`、`milestone_gate_yml_spec`、`agent_config_spec`、`hook/` 與 `script/` 底下每一支
agent spec;integration:`smoke_spec`、`assemble_spec`、`setup_spec`;system shim:
`real_assemble_spec`;system-real:`real_engine_spec`;
acceptance:`m2_selfcheck_spec`),bats 跑之前逐檔確認**存在且至少定義一個案例**
(`bats --count`),跑完再確認 TAP 計畫涵蓋這些案例、至少跑了一個、無失敗、無
`skip`:必要 spec 被刪、被清空、被 `skip` 都不會因為同層還有別的 spec 而被當成
綠燈;非必要的額外 spec 照常一起跑。`test/unit/ci_gate_spec.bats` 在 repo 副本上以
刪檔/空檔負向案例證明這條規則。

## CI

`.github/workflows/ci.yml` 在 push 與對 `main` 的 pull request 時,於 Docker 內
跑 lint、test-unit、test-integration、test-system、test-acceptance(共用測試
映像的 matrix),以及獨立的 `test-system-real` job(自建 DinD runner 映像、
`docker run --rm --privileged`;**唯一**使用 `--privileged` 的 job,上限 40
分鐘),並以 `ci-passed` 彙總 job 收斂:只有映像建置成功**且**每個 matrix gate
**且** `test-system-real` 都 `success` 才綠;被 skip、取消或缺席的 gate 一律視為
失敗。上述每個 job 都以 `runner` matrix 維度同時跑在 `ubuntu-latest`(amd64)與
`ubuntu-24.04-arm`(arm64,GitHub 託管)兩種 runner 上(check 名稱為
`<gate> (<runner>)`,測試映像 artifact 依 runner 分開命名,`ci-passed` 要求兩個架構
的每一條 leg 都綠;#149,`test/unit/ci_yml_spec.bats` 斷言此矩陣)。sub-issue PR
全綠且 codex「可合併」後自主合併;milestone 驗收 PR 全綠後交由人類審核合併。

### commit email 必須是 GitHub noreply(`commit-email`,#234)

- **規則**:repo 已公開,檢查範圍內每個 commit 的 author email 都必須以
  `@users.noreply.github.com` 結尾;committer email 也必須是 noreply,或正好是
  `noreply@github.com`(GitHub 自己的 committer:合併按鈕、網頁編輯)。這個
  committer 例外不洩漏個資,但本機一樣設得出來,所以絕不豁免 author。
  **不以任何日期豁免**:commit 日期由提交者自訂(`GIT_COMMITTER_DATE`),以日期
  放行等於留後門;規則之前的歷史靠檢查範圍排除(main 歷史不改寫、不 force push)。
- **機制**:`ci.yml` 的 `commit-email` job(單一 `ubuntu-latest`,不需 token,
  `fetch-depth: 0`、`persist-credentials: false`)以 `commit_email_range` 取範圍
  (PR:base..head;push:before..after;只有 `before` 為 40 個 0 才算新 ref,查 `after`
  可達、但不在預設分支上的每一個 commit,不只最頂端那個)。只驗證該事件用到的輸入:
  pull_request 驗 base、head 與預設分支 ref,**忽略** before、after(不論值為何);push 驗
  before、after 與預設分支 ref,**忽略** base、head。事件只接受這兩種;sha 必須是 40 位小寫
  hex(GitHub repo 為 SHA-1);預設分支 ref 以 `git check-ref-format` 驗證。用到的輸入缺值、
  空值或格式不對一律失敗,不退回任何預設範圍;通過後
  再用 `git log` 取出 `<sha>\t<author>\t<email>\t<committer>\t<email>`
  紀錄交給 `lib/commit_email.sh` 的 `commit_email_evaluate`,在 stderr 列出每個違規 commit 與
  修正指令後失敗。`ci-passed` 要求它 `success`。`test/unit/commit_email_spec.bats`
  測判斷規則,`test/unit/ci_yml_spec.bats` 釘住 job 接線。
- **修正**:`git config user.email "<id>+<帳號>@users.noreply.github.com"` 後,
  `git rebase -r --exec 'git commit --amend --no-edit --reset-author' origin/main`
  改寫 PR 分支,再 `git push --force-with-lease`。

### milestone 驗收 PR 的核准 gate(`milestone-gate-approval`,#187)

- **規則**:貼了 `milestone-gate` 標籤的 PR(milestone 驗收 PR)合併前,必須有維護者在
  該 PR 上留下核准紀錄;沒貼標籤的 PR 不受影響。
- **核准格式**:一則留言,作者 `author_association` 為 `OWNER`,本文(忽略開頭空白)不以
  `[claude]` 或 `[codex]` 開頭,內容含「允許合併」。
- **機制**:`.github/workflows/milestone-gate.yml` 觸發於 `pull_request_target`(opened、
  synchronize、reopened、labeled、unlabeled)與 `issue_comment`(created、edited、
  deleted;只處理 PR 的留言),以 `gh api` 取標籤與留言,把留言轉成
  `<author_association>\t<body>` 的 NUL 分隔紀錄交給 `lib/approval.sh` 的
  `approval_evaluate`(純函式,不呼叫 GitHub API,之後 agent 端 hook #190 共用),
  再於 PR head SHA 設 commit status `milestone-gate-approval`:未貼標籤或已核准為
  success,否則 failure,description 為「需要維護者留言:允許合併」。權限只有
  `statuses: write`、`pull-requests: read`、`issues: read`,加上 checkout 私有 repo
  需要的 `contents: read`。`ci.yml` 與 `ci-passed` 不變;這個 PR 合併後,
  `milestone-gate-approval` 才另外列入 main 的 required status checks(與
  `ci-passed` 並列),避免合併前就擋住所有 PR。`test/unit/approval_spec.bats`
  測判斷規則,`test/unit/milestone_gate_yml_spec.bats` 以文字層級釘住觸發事件、
  權限與 context 名稱。
- **job 不與必要檢查同名**(#258):job id 為 `evaluate`、名稱為 `evaluate-approval`,
  不得等於 `milestone-gate-approval`,讓必要檢查只對應 workflow 設定的 commit status;
  否則同名 check run 被 `concurrency` 取消時,會被 branch protection 當成必要檢查的結果,
  擋住已核准的 PR。`ci.yml` 的 `ci-passed` 則是刻意以 job 本身當必要檢查,不受此限。
- **已知限制**:agent 用維護者的 token 發留言,GitHub 上無法區分維護者本人與 agent
  代發;這道檢查擋的是「忘了等核准」,擋不住 agent 冒名寫「允許合併」。後者由
  agent 端的 Claude Code PreToolUse hook 擋(#190):agent 發的留言/issue/PR 內文含
  「允許合併」一律拒絕;對貼了 `milestone-gate` 的 PR 執行 `gh pr merge` 時沒有核准
  留言也拒絕。
- **只跑 main 上的可信程式碼**(codex 第 1 輪):workflow 持有 `statuses: write`,PR 能改的
  程式碼一律不執行。觸發用 `pull_request_target` 而非 `pull_request`,與 `issue_comment`
  一樣跑預設分支上的 workflow 檔;checkout 釘在預設分支(`ref` 為 default branch、
  `persist-credentials: false`),不 checkout 也不執行 PR head,所以 source 的
  `lib/approval.sh` 永遠是 main 的版本。PR 只當 API 資料讀:head SHA、標籤、留言都走
  `gh api`。因此改動判斷規則或 workflow 本身的 PR,合併後才生效;
  `milestone_gate_yml_spec.bats` 釘住「沒有 `pull_request` 觸發、checkout 釘在預設分支、
  不取 PR head」。

每個 job 跑的就是使用者打的同一套 `just test <tier>`(matrix 把 job 名稱對應到
tier:`lint` -> `just test lint`、`test-unit` -> `just test unit`、
`test-integration` -> `just test integration`、`test-system` -> `just test system`、
`test-acceptance` -> `just test acceptance`;`test-system-real` ->
`just test system-real`);gate 名稱本身不變(check 名稱只多了 runner 後綴),
branch protection 只要求 `ci-passed`。本機不帶參數的 `just test` = 這六個 gate
依序跑完,與 CI 在本機架構上的那一組 leg 等價。
