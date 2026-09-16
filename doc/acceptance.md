# worktool 驗收清單(distrobox UX 累積驗收)

每個 milestone 都有明確驗收標準,分兩類:

- 自動:Docker / docker-in-docker 內可跑的具體測試或指令,必須綠。
- 人類實機:UX / 硬體 / 顯示只能在真實機器驗證的項目,列成勾選清單。

本清單累積成長:每個 milestone 貢獻自己的項目;在 M15(測試完整)與 M17
(release)整份跑一遍,作為 distrobox UX 的最終驗收。milestone 間的人類 gate
會同時檢查「自動綠」與「人類項目已勾」。

---

## M1 repo 骨架(已完成)

- 自動:`just test lint` / `just test unit` / `just test integration` 全綠(M1 當時為 `just -f justfile.ci ...`,M2 改為 base 模型的 namespace 指令);
  log.sh 單元測試證明 harness 可用。

## M2 盒子清單 + 最小 assemble(審核中)

人類 gate 用的完整驗收清單(與 PR #20 的總結 commit / PR 描述同內容;審核時逐項勾選,
有差異就回 PR 留言):

### 通用指令

前提:host 已裝 docker(可 `docker run --privileged`)與 just(https://github.com/casey/just#installation;`just --version` 可執行即可);不需 distrobox / root。
所有測試都在 Docker 內跑,host 不會被安裝任何東西。`just` 是使用者介面(base 模型:`just <namespace> [動作] [參數]`;裸 `just` 列 namespaces;每個 recipe 只是薄轉發,驗證與 `--help` 都在底層腳本);沒有 just 的機器可直接呼叫底層 `script/test/test.sh` / `script/box/assemble.sh`。

```bash
git clone https://github.com/ycpss91255/worktool.git && cd worktool
git checkout m2-manifest     # 合併後改用 main
```

### 驗收項目

「驗收方式」的規則:worktool 的每個動作一律用 `just`(0-4 全部是);5 是對 GitHub / git 的外部證據查核(`gh`、`git`),6 是對文件內容的查核(`grep`),7 的 enter / rm 是 distrobox 原生指令(M3 才會有 `just box enter` / `just box rm`)。`printf` 建測試清單、複製副本、`echo rc=$?`、`docker ps` 前後比對都只是準備與觀測步驟。

- [ ] 0. 使用者介面:`just` 是唯一入口(base 模型:零特例 namespace、薄轉發、help 在腳本)
  - [ ] 0.1 裸 `just` 只列 namespaces,驗收標準:只有 `test`、`box` 兩個 namespace(加 default),沒有任何頂層動作
    - 預期看到資訊:`Available recipes:` 之後三行:`default  # Default: list the namespaces.`、`box ...  # Dev box lifecycle: just box assemble [--dry-run] [--file X]  (M3 adds enter / rm)`、`test ... # Self-test: lint + bats tiers in Docker (just test [build|lint|unit|integration|system|system-real|acceptance|selfcheck])`;`rc=0`
    - 驗收方式
      ```bash
      just
      ```
  - [ ] 0.2 namespace 內的動作清單與 help,驗收標準:`just box` 列出 box 的動作;`just test help` / `just box help` 印的是底層腳本的 usage(不是 justfile 自己印的)
    - 預期看到資訊:`just box` 印 `Available recipes:` 之後三行:`assemble *args # Assemble the dev box from its manifest (args: --dry-run, --file <manifest>, --help; default box/dev.ini).`、`default # List the box verbs.`、`help # Show the box wrapper help (assemble.sh --help). [alias: h]`;`just test help` 回顯 `./script/test/test.sh --help` 後印 usage(含 --build --lint --unit --integration --system --system-real --acceptance);`just box help` 回顯 `./script/box/assemble.sh --help` 後印 usage(含 --dry-run --file)
    - 驗收方式
      ```bash
      just box
      just test help
      just box help
      ```
  - [ ] 0.3 錯誤輸入不會跑任何東西,驗收標準:未知動作由 just 自己報錯(exit 1);未知選項由腳本報錯(exit 2);都不呼叫 docker / distrobox
    - 預期看到資訊:`error: justfile does not contain recipe `test bogus``、`rc=1`(just 自己的訊息,沒有任何回顯行 = 沒跑任何腳本);`./script/box/assemble.sh "$@"` 回顯後 `assemble.sh: unknown option '--bogus' (see --help)`、`error: recipe `assemble` failed on line 32 with exit code 2`、`rc=2`(STDOUT 空)
    - 驗收方式
      ```bash
      just test bogus; echo rc=$?
      just box assemble --bogus; echo rc=$?
      ```

- [ ] 1. 自動測試:四層 gate 全綠(每層都真實存在、無 skip、無佔位)
  - [ ] 1.1 lint,驗收標準:全部 *.sh / *.bats 通過 ShellCheck、零違規
    - 預期看到資訊:第一行回顯 `./script/test/test.sh --lint "$@"`(recipe 原文;`"$@"` 是 just 把額外參數原樣轉發的寫法),接著 `[ci]   found 21 script(s)`、`[ci] ShellCheck OK`、`rc=0`
    - 驗收方式
      ```bash
      just test lint; echo rc=$?
      ```
  - [ ] 1.2 單元測試,驗收標準:8 個必要 spec 都存在、135 案例全 ok(manifest 解析/驗證 33、assemble CLI 11、log 9、test.sh 必要 spec 防漏 21、test.sh CLI 14、DinD 入口 15、selfcheck CLI 7、justfile 介面 25)
    - 預期看到資訊:第一行回顯 `./script/test/test.sh --unit "$@"`,接著 `[ci]   required specs OK (135 case(s) declared by 8 file(s))`、`1..135`、沒有任何 `not ok` / `# skip`、`[ci] unit bats OK`、`rc=0`
    - 驗收方式
      ```bash
      just test unit; echo rc=$?
      ```
  - [ ] 1.3 整合測試,驗收標準:mock distrobox 逐參數記錄,真實包裝器呼叫 `assemble create --file <解析後路徑>`;無效清單(缺 image、不成對引號)絕不呼叫 distrobox
    - 預期看到資訊:回顯 `./script/test/test.sh --integration "$@"`,接著 `required specs OK (10 case(s) declared by 2 file(s))`、`1..10` 全 ok、`[ci] integration bats OK`、`rc=0`
    - 驗收方式
      ```bash
      just test integration; echo rc=$?
      ```
  - [ ] 1.4 系統測試 shim 組,驗收標準:真實 distrobox 1.8.2.5 + 假 container manager,交付的 `box/dev.ini` 到達 manager 的 create 請求含 name=dev、image ubuntu:26.04、`--additional-packages "ripgrep fzf"`,pull 先於 create,manager 失敗傳回非零
    - 預期看到資訊:回顯 `./script/test/test.sh --system "$@"`,接著 `required specs OK (6 case(s) declared by 1 file(s))`、`1..6` 全 ok、`[ci] system bats OK`、`rc=0`
    - 驗收方式
      ```bash
      just test system; echo rc=$?
      ```
  - [ ] 1.5 系統測試 real-engine 組(docker-in-docker),驗收標準:真實 docker 引擎 + 真實 distrobox 從 `ubuntu:26.04` 建出 `dev` 盒;`distrobox enter dev -- rg --version` / `-- fzf --version` 成功;第二次 assemble 冪等;`distrobox rm -f dev` 後 0 殘留;host 的 docker 前後不變(只多 runner 映像 `worktool-system-real:local`)
    - 預期看到資訊:回顯 `./script/test/test.sh --system-real "$@"`,接著 `[system-real] dockerd ready after Ns`、`[system-real] engine 29.8.0 ...`、`required specs OK (8 case(s) declared by 1 file(s))`、`1..8` 全 ok(含 `ok 5 ... rg --version ...`、`ok 6 ... fzf --version ...`、`ok 7 ... second assemble ...`、`ok 8 ... distrobox rm -f dev ...`)、`[ci] system-real bats OK`、`[system-real] cleanup: containers left in the nested daemon: 0`、`rc=0`;約 2-4 分鐘;前後兩次 `docker ps -a` 輸出相同
    - 驗收方式
      ```bash
      docker ps -a --format '{{.Names}}' | sort > /tmp/before.txt
      just test system-real; echo rc=$?
      docker ps -a --format '{{.Names}}' | sort | diff /tmp/before.txt - && echo "host unchanged"
      ```
  - [ ] 1.6 交付驗收測試,驗收標準:直接執行交付的公開入口 `script/test/selfcheck.sh`,對交付 repo 印 ALL PASS;壞清單被判 SOME FAILED;跳過驗證的包裝器被抓出;不可用的 `--root` 明確報錯
    - 預期看到資訊:回顯 `./script/test/test.sh --acceptance "$@"`,接著 `required specs OK (6 case(s) declared by 1 file(s))`、`1..6` 全 ok、`[ci] acceptance bats OK`、`rc=0`
    - 驗收方式
      ```bash
      just test acceptance; echo rc=$?
      ```

- [ ] 2. 交付自檢(使用者一鍵入口)
  - [ ] 2.1 正常 repo,驗收標準:9 項全 PASS(dry-run 契約 2 項 + 7 個無效清單被拒)、exit 0
    - 預期看到資訊:回顯 `./script/test/selfcheck.sh "$@"`、`[INFO] self-checking /<clone 路徑>`,接著 `PASS 3a`、`PASS 3b`、`PASS reject no-image.ini`、`PASS reject blank-name.ini`、`PASS reject blank-image.ini`、`PASS reject spaced-image.ini`、`PASS reject single-quoted-image.ini`、`PASS reject unbalanced-quote-image.ini`、`PASS reject multi.ini`、`ALL PASS`、`rc=0`
    - 驗收方式
      ```bash
      just test selfcheck; echo rc=$?
      ```
  - [ ] 2.2 壞掉的 repo,驗收標準:自檢不是空判定,交付清單壞掉時報 FAIL + SOME FAILED、exit 1
    - 預期看到資訊:`FAIL 3a: rc=1 ... missing required key 'image'`、`FAIL 3b: ...`、其餘 7 行仍 `PASS reject ...`、`SOME FAILED`、just 自己的一行 `error: recipe `selfcheck` failed on line N with exit code 1`(實測 N=61;大小寫與行號隨 just 版本略有不同,只看「selfcheck failed … exit code 1」)、`rc=1`
    - 驗收方式
      ```bash
      rm -rf /tmp/wt-bad && cp -r . /tmp/wt-bad && printf '[dev]\n' > /tmp/wt-bad/box/dev.ini
      (cd /tmp/wt-bad && just test selfcheck; echo rc=$?)
      ```

- [ ] 3. assemble 手動抽驗(`just box assemble [--dry-run] [--file <清單>]`,參數原樣交給 script/box/assemble.sh;dry-run 不執行 distrobox,STDOUT 只印將執行的指令、診斷走 STDERR)
  - [ ] 3.1 repo 根目錄 dry-run,驗收標準:印出正確的 distrobox 指令、不執行、exit 0
    - 預期看到資訊:回顯 `./script/box/assemble.sh "$@"`,接著 `distrobox assemble create --file box/dev.ini`、`rc=0`
    - 驗收方式
      ```bash
      just box assemble --dry-run; echo rc=$?
      ```
  - [ ] 3.2 從 repo 子目錄執行,驗收標準:`just` 在任何子目錄都找得到 justfile,recipe 以 repo 根目錄為工作目錄,結果與 3.1 相同
    - 預期看到資訊:與 3.1 完全相同的兩行、`rc=0`
    - 驗收方式
      ```bash
      (cd doc && just box assemble --dry-run; echo rc=$?)
      ```
  - [ ] 3.3 缺 image,驗收標準:明確 `[ERROR]`、exit 1、不呼叫 distrobox(STDOUT 為空)
    - 預期看到資訊:回顯 `./script/box/assemble.sh "$@"`,接著 `[ERROR] manifest missing required key 'image' in section [dev]: /tmp/a.ini`、just 的 `error: recipe `assemble` failed on line 32 with exit code 1`、`rc=1`(STDOUT 沒有 distrobox 指令;3.4-3.7 同樣多這一行 just 訊息)
    - 驗收方式
      ```bash
      printf '[dev]\n' > /tmp/a.ini; just box assemble --dry-run --file /tmp/a.ini; echo rc=$?
      ```
  - [ ] 3.4 引號包空白繞過(單引號),驗收標準:`image='   '` 被視為空值拒絕(雙引號 `image="   "`、引號前有空白 `image= '   '` 同樣拒絕)
    - 預期看到資訊:回顯 `./script/box/assemble.sh "$@"`,接著 `[ERROR] manifest missing required key 'image' in section [dev]: /tmp/c.ini`、`rc=1`
    - 驗收方式
      ```bash
      printf "[dev]\nimage='   '\n" > /tmp/c.ini; just box assemble --dry-run --file /tmp/c.ini; echo rc=$?
      ```
  - [ ] 3.5 不成對引號,驗收標準:首/尾引號非同種成對(長度 >= 2)即格式錯誤,專屬訊息(不是誤報缺 image)
    - 預期看到資訊:回顯 `./script/box/assemble.sh "$@"`,接著 `[ERROR] manifest image value has an unbalanced quote: 'ubuntu:26.04" (section [dev]): /tmp/b.ini`、`rc=1`
    - 驗收方式
      ```bash
      printf "[dev]\nimage='ubuntu:26.04\"\n" > /tmp/b.ini; just box assemble --dry-run --file /tmp/b.ini; echo rc=$?
      ```
  - [ ] 3.6 多區段,驗收標準:M2 只支援單一盒,兩個區段被拒
    - 預期看到資訊:回顯 `./script/box/assemble.sh "$@"`,接著 `[ERROR] manifest declares multiple sections; worktool supports a single box: /tmp/d.ini`、`rc=1`
    - 驗收方式
      ```bash
      printf '[dev]\nimage=ubuntu:26.04\n[debug]\nimage=ubuntu:26.04\n' > /tmp/d.ini; just box assemble --dry-run --file /tmp/d.ini; echo rc=$?
      ```
  - [ ] 3.7 image 在區段之前,驗收標準:區段外的 key 不算數,仍判缺 image
    - 預期看到資訊:回顯 `./script/box/assemble.sh "$@"`,接著 `[ERROR] manifest missing required key 'image' in section [dev]: /tmp/e.ini`、`rc=1`
    - 驗收方式
      ```bash
      printf 'image=ubuntu:26.04\n[dev]\n' > /tmp/e.ini; just box assemble --dry-run --file /tmp/e.ini; echo rc=$?
      ```

- [ ] 4. gate 防漏(必要 spec 被刪/清空不會因同層還有別的 spec 而綠燈)
  - [ ] 4.1 刪掉必要 spec,驗收標準:該層立即失敗並指名缺的檔案、exit 1(在 repo 副本上做,不動原 clone)
    - 預期看到資訊:`[ci] ERROR: integration required spec missing: test/integration/assemble_spec.bats`、just 的 `error: recipe `integration` failed on line 45 with exit code 1`、`rc=1`
    - 驗收方式
      ```bash
      rm -rf /tmp/wt-del && cp -r . /tmp/wt-del && rm /tmp/wt-del/test/integration/assemble_spec.bats
      (cd /tmp/wt-del && just test integration; echo rc=$?)
      ```
  - [ ] 4.2 清空必要 spec(只剩檔頭、0 案例),驗收標準:該層失敗並指名零案例的檔案、exit 1
    - 預期看到資訊:`[ci] ERROR: integration required spec defines zero cases: test/integration/assemble_spec.bats`、just 的 `error: recipe `integration` failed on line 45 with exit code 1`、`rc=1`
    - 驗收方式
      ```bash
      rm -rf /tmp/wt-empty && cp -r . /tmp/wt-empty
      printf '#!/usr/bin/env bats\nload ../helper/common\n' > /tmp/wt-empty/test/integration/assemble_spec.bats
      (cd /tmp/wt-empty && just test integration; echo rc=$?)
      ```

- [ ] 5. CI 與流程(外部證據查核:gh / git,不是 worktool 動作)
  - [ ] 5.1 遠端 CI,驗收標準:PR #20 最終 head 的 8 個 check 全 pass(Build test image、lint、test-unit、test-integration、test-system、test-acceptance、test-system-real、ci-passed);`--privileged` 只出現在 test-system-real
    - 預期看到資訊:8 行皆 `pass`
    - 驗收方式
      ```bash
      gh pr checks 20 --repo ycpss91255/worktool
      ```
  - [ ] 5.2 每個 agent 獨立 commit,驗收標準:分支上每個修正/測試層各為獨立 commit(不混合),總結為最後一個 commit;合併時保留(不 squash)
    - 預期看到資訊:23 個 commit,最後一個為 `M2 總結:驗收清單(通用指令 + 驗收項目)`,之前依序為 feat / fix x2 / docs x2 / test(system shim) / test(acceptance) / test(DinD) / ci / fix / ci / fix / ci / test / feat(ux: 第一版 just 介面) / docs / fix / refactor(layout: script/test + script/box) / feat(ux: just namespaces test/box) / docs(base 模型決策) / fix(cli: --help 先驗證整條命令列) / fix(cli: 旗標組合規則先於 help)
    - 驗收方式
      ```bash
      git log --oneline origin/main..HEAD
      ```
  - [ ] 5.3 codex 協作,驗收標準:PR #20 留言有四層逐項複審 + 多輪逐項複驗(含 base 模型改版後的複驗),每則標記 [claude]/[codex],附可重現指令,最終判定「M2 可合併」
    - 預期看到資訊:留言最後一則 [codex] 含 `可合併`
    - 驗收方式
      ```bash
      gh pr view 20 --repo ycpss91255/worktool --comments | grep -n 'codex' | tail -5
      ```

- [ ] 6. 文件(zh-TW;文件內容查核:grep)
  - [ ] 6.0 just 介面決策,驗收標準:`doc/design.md` 決策節有「just 是使用者的通用介面」(2026-09-16)並採 base 模型(引用 base ADR-00000005/10/11,含 test / box 兩個 namespace 表);`README.md` 有前置需求(docker、just)與 namespace 一覽
    - 預期看到資訊:兩個檔案各有命中
    - 驗收方式
      ```bash
      grep -n '通用介面\|ADR-0000001' doc/design.md README.md
      ```
  - [ ] 6.1 清單格式與規則,驗收標準:`doc/manifest.md` 說明採用 distrobox-assemble 原生 INI、單一區段、`image=` 必要、引號規則(只去一層成對同種引號,其餘首/尾引號 = 格式錯誤)、固定版本(distrobox 1.8.2.5 sha256、dind 29.8.0、bats 1.14.0)、驗證邊界(套件在第一次 enter 初始化)、host 只留 runner 映像與快取
    - 預期看到資訊:上述每點都能在文件中找到對應段落
    - 驗收方式
      ```bash
      grep -n '引號規則\|驗證邊界\|1.8.2.5\|29.8.0\|runner 映像' doc/manifest.md
      ```
  - [ ] 6.2 驗收紀錄表,驗收標準:`doc/manifest.md` 的「M2 驗收紀錄」表格有 自動化全綠 / selfcheck / 真實可用盒 三列,欄位為 項目/版本/環境/預期/結果/證據;審核時填入 head SHA 與你的實測結果
    - 預期看到資訊:三列表格,「結果」欄可填
    - 驗收方式
      ```bash
      grep -n '^| ' doc/manifest.md | tail -4
      ```

- [ ] 7. 選做:真實主機實機驗證(需要 host 有 distrobox 與 docker;會在 host 的 docker 建一個 `dev` 容器,驗完可 `distrobox rm -f dev` 清掉)
  - [ ] 7.1 一鍵建盒並使用,驗收標準:M2 承諾「一鍵 assemble 出可用 dev 盒」在真實主機成立
    - 預期看到資訊:assemble 成功;`rg --version` 印 ripgrep 版本、`fzf --version` 印 fzf 版本;再跑一次 assemble 不重複建盒;rm 後 `docker ps -a` 無 `dev`
    - 驗收方式
      ```bash
      just box assemble
      distrobox enter dev -- rg --version && distrobox enter dev -- fzf --version
      just box assemble
      distrobox rm -f dev
      ```

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
