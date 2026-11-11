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

人類 gate 用的驗收清單(= M2 驗收 PR 的描述;逐項勾選,有差異回 PR 留言):

### 通用指令

前提:host 有 docker(可 `--privileged`)與 just;不需 distrobox / root;所有測試在 Docker 內跑。

```bash
git clone https://github.com/ycpss91255/worktool.git && cd worktool
just --version && docker info >/dev/null && echo prereq-ok
```

```text
just 1.53.0        (版本不限)
prereq-ok
```

### 驗收項目

規則:0-4 是 worktool 動作,一律 `just`;5 用 gh / git 查外部證據;6 用 grep 查文件;7 選做(distrobox 原生指令)。

- [ ] 0. 使用者介面:`just` 是唯一入口
  - [ ] 0.1 裸 `just` 只列 namespaces(test、box),沒有頂層動作
    - 預期看到資訊
      ```text
      Available recipes:
          default  # Default: list the namespaces.
          box ...  # Dev box lifecycle: just box assemble [--dry-run] [--file X]  (M3 adds enter / rm)
          test ... # Self-test: lint + bats tiers in Docker (just test [build|lint|unit|integration|system|system-real|acceptance|selfcheck])
      ```
    - 驗收方式
      ```bash
      just
      ```
  - [ ] 0.2 namespace 清單與 help 都來自底層腳本
    - 預期看到資訊
      ```text
      Available recipes:
          assemble *args # Assemble the dev box from its manifest (args: --dry-run, --file <manifest>, --home <path>, --help; default box/dev.ini, ~/<box>-box).
          default        # List the box verbs.
          help           # Show the box wrapper help (assemble.sh --help). [alias: h]
      ./script/test/test.sh --help
      Usage: test.sh [OPTION...]
      ./script/box/assemble.sh --help
      Usage: assemble.sh [--file <manifest>] [--dry-run]
      ```
    - 驗收方式
      ```bash
      just box
      just test help 2>&1 | head -2
      just box help 2>&1 | head -2
      ```
  - [ ] 0.3 錯誤輸入不跑任何東西:未知動作 just 報錯 exit 1;未知選項腳本報錯 exit 2
    - 預期看到資訊
      ```text
      error: justfile does not contain recipe `test bogus`
      rc=1
      ./script/box/assemble.sh "$@"
      assemble.sh: unknown option '--bogus' (see --help)
      error: recipe `assemble` failed on line 32 with exit code 2
      rc=2
      ```
    - 驗收方式
      ```bash
      just test bogus; echo rc=$?
      just box assemble --bogus; echo rc=$?
      ```

- [ ] 1. 自動測試:四層 gate 全綠
  - [ ] 1.1 lint:ShellCheck 零違規
    - 預期看到資訊
      ```text
      ./script/test/test.sh --lint "$@"
      [ci]   found 21 script(s)
      [ci] ShellCheck OK
      rc=0
      ```
    - 驗收方式
      ```bash
      just test lint; echo rc=$?
      ```
  - [ ] 1.2 單元:8 個必要 spec、135 案例全 ok、無 skip
    - 預期看到資訊
      ```text
      ./script/test/test.sh --unit "$@"
      [ci]   required specs OK (135 case(s) declared by 8 file(s))
      1..135
      ok 1 ...
      ...(135 行全部 ok;沒有 not ok、沒有 # skip)
      [ci] unit bats OK
      rc=0
      ```
    - 驗收方式
      ```bash
      just test unit; echo rc=$?
      ```
  - [ ] 1.3 整合:mock distrobox 逐參數記錄,無效清單絕不呼叫 distrobox
    - 預期看到資訊
      ```text
      ./script/test/test.sh --integration "$@"
      [ci]   required specs OK (10 case(s) declared by 2 file(s))
      1..10
      ...(全部 ok)
      [ci] integration bats OK
      rc=0
      ```
    - 驗收方式
      ```bash
      just test integration; echo rc=$?
      ```
  - [ ] 1.4 系統 shim:真實 distrobox 1.8.2.5 + 假 container manager
    - 預期看到資訊
      ```text
      ./script/test/test.sh --system "$@"
      [ci]   required specs OK (6 case(s) declared by 1 file(s))
      1..6
      ...(全部 ok)
      [ci] system bats OK
      rc=0
      ```
    - 驗收方式
      ```bash
      just test system; echo rc=$?
      ```
  - [ ] 1.5 系統 real-engine(docker-in-docker):真的建出可用 dev 盒;host docker 前後不變
    - 預期看到資訊(約 2-4 分鐘)
      ```text
      ./script/test/test.sh --system-real "$@"
      [system-real] dockerd ready after 1s
      [system-real] engine 29.8.0 driver=overlayfs cgroup=cgroupfs/2
      [ci]   required specs OK (12 case(s) declared by 1 file(s))
      1..12
      ok 1 preflight: a real docker engine is live inside the runner
      ...
      ok 5 real engine: distrobox enter dev -- rg --version prints a ripgrep version (first start runs distrobox-init + apt)
      ok 6 real engine: distrobox enter dev -- fzf --version prints a version
      # tmux: tmux 3.x
      ok 7 real engine: distrobox enter dev -- tmux -V prints a tmux version (auto-enter prerequisite)
      # fish: fish, version 4.x
      ok 8 real engine: distrobox enter dev -- fish --version prints a fish version (auto-enter prerequisite)
      ...
      ok 11 real engine: a second assemble.sh run exits 0 and does not duplicate the dev box
      ok 12 real engine: distrobox rm -f dev removes the box from the engine
      [ci] system-real bats OK
      [system-real] cleanup: containers left in the nested daemon: 0
      rc=0
      host unchanged
      ```
    - 驗收方式
      ```bash
      docker ps -a --format '{{.Names}}' | sort > /tmp/before.txt
      just test system-real; echo rc=$?
      docker ps -a --format '{{.Names}}' | sort | diff /tmp/before.txt - && echo "host unchanged"
      ```
  - [ ] 1.6 交付驗收:直接執行交付的 selfcheck(含負向案例)
    - 預期看到資訊
      ```text
      ./script/test/test.sh --acceptance "$@"
      [ci]   required specs OK (6 case(s) declared by 1 file(s))
      1..6
      ...(全部 ok)
      [ci] acceptance bats OK
      rc=0
      ```
    - 驗收方式
      ```bash
      just test acceptance; echo rc=$?
      ```

- [ ] 2. 交付自檢
  - [ ] 2.1 正常 repo:9 個 PASS、ALL PASS、rc=0
    - 預期看到資訊
      ```text
      ./script/test/selfcheck.sh "$@"
      [INFO] self-checking /<clone 路徑>
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
    - 驗收方式
      ```bash
      just test selfcheck; echo rc=$?
      ```
  - [ ] 2.2 壞掉的 repo:FAIL + SOME FAILED、rc=1(自檢不是空判定)
    - 預期看到資訊
      ```text
      ./script/test/selfcheck.sh "$@"
      [INFO] self-checking /tmp/wt-bad
      FAIL 3a: rc=1 stdout='' stderr='[ERROR] manifest missing required key 'image' in section [dev]: box/dev.ini'
      FAIL 3b: rc=1 stdout='' stderr='[ERROR] manifest missing required key 'image' in section [dev]: /tmp/wt-bad/box/dev.ini'
      PASS reject no-image.ini
      ...(其餘 6 行 PASS reject ...)
      SOME FAILED
      error: recipe `selfcheck` failed on line 61 with exit code 1
      rc=1
      ```
    - 驗收方式
      ```bash
      rm -rf /tmp/wt-bad && cp -r . /tmp/wt-bad && printf '[dev]\n' > /tmp/wt-bad/box/dev.ini
      (cd /tmp/wt-bad && just test selfcheck; echo rc=$?)
      ```

- [ ] 3. assemble 手動抽驗(dry-run 不執行 distrobox;STDOUT 只印指令、診斷走 STDERR)
  - [ ] 3.1 repo 根目錄 dry-run:印出指令、rc=0
    - 預期看到資訊
      ```text
      ./script/box/assemble.sh "$@"
      distrobox assemble create --file box/dev.ini
      rc=0
      ```
    - 驗收方式
      ```bash
      just box assemble --dry-run; echo rc=$?
      ```
  - [ ] 3.2 從子目錄執行:結果與 3.1 相同(recipe 以 repo 根為工作目錄)
    - 預期看到資訊
      ```text
      ./script/box/assemble.sh "$@"
      distrobox assemble create --file box/dev.ini
      rc=0
      ```
    - 驗收方式
      ```bash
      (cd doc && just box assemble --dry-run; echo rc=$?)
      ```
  - [ ] 3.3 缺 image:[ERROR]、rc=1、STDOUT 沒有 distrobox 指令
    - 預期看到資訊
      ```text
      ./script/box/assemble.sh "$@"
      [ERROR] manifest missing required key 'image' in section [dev]: /tmp/a.ini
      error: recipe `assemble` failed on line 32 with exit code 1
      rc=1
      ```
    - 驗收方式
      ```bash
      printf '[dev]\n' > /tmp/a.ini; just box assemble --dry-run --file /tmp/a.ini; echo rc=$?
      ```
  - [ ] 3.4 單引號包空白 `image='   '`:視為空值拒絕
    - 預期看到資訊
      ```text
      ./script/box/assemble.sh "$@"
      [ERROR] manifest missing required key 'image' in section [dev]: /tmp/c.ini
      error: recipe `assemble` failed on line 32 with exit code 1
      rc=1
      ```
    - 驗收方式
      ```bash
      printf "[dev]\nimage='   '\n" > /tmp/c.ini; just box assemble --dry-run --file /tmp/c.ini; echo rc=$?
      ```
  - [ ] 3.5 不成對引號:專屬訊息 unbalanced quote(不是誤報缺 image)
    - 預期看到資訊
      ```text
      ./script/box/assemble.sh "$@"
      [ERROR] manifest image value has an unbalanced quote: 'ubuntu:26.04" (section [dev]): /tmp/b.ini
      error: recipe `assemble` failed on line 32 with exit code 1
      rc=1
      ```
    - 驗收方式
      ```bash
      printf "[dev]\nimage='ubuntu:26.04\"\n" > /tmp/b.ini; just box assemble --dry-run --file /tmp/b.ini; echo rc=$?
      ```
  - [ ] 3.6 多區段:M2 只支援單一盒
    - 預期看到資訊
      ```text
      ./script/box/assemble.sh "$@"
      [ERROR] manifest declares multiple sections; worktool supports a single box: /tmp/d.ini
      error: recipe `assemble` failed on line 32 with exit code 1
      rc=1
      ```
    - 驗收方式
      ```bash
      printf '[dev]\nimage=ubuntu:26.04\n[debug]\nimage=ubuntu:26.04\n' > /tmp/d.ini; just box assemble --dry-run --file /tmp/d.ini; echo rc=$?
      ```
  - [ ] 3.7 image 在區段之前:區段外的 key 不算數
    - 預期看到資訊
      ```text
      ./script/box/assemble.sh "$@"
      [ERROR] manifest missing required key 'image' in section [dev]: /tmp/e.ini
      error: recipe `assemble` failed on line 32 with exit code 1
      rc=1
      ```
    - 驗收方式
      ```bash
      printf 'image=ubuntu:26.04\n[dev]\n' > /tmp/e.ini; just box assemble --dry-run --file /tmp/e.ini; echo rc=$?
      ```

- [ ] 4. gate 防漏(必要 spec 被刪/清空不會因同層還有別的 spec 而綠燈)
  - [ ] 4.1 刪掉必要 spec:該層失敗並指名檔案
    - 預期看到資訊
      ```text
      [ci] ERROR: integration required spec missing: test/integration/assemble_spec.bats
      error: recipe `integration` failed on line 45 with exit code 1
      rc=1
      ```
    - 驗收方式
      ```bash
      rm -rf /tmp/wt-del && cp -r . /tmp/wt-del && rm /tmp/wt-del/test/integration/assemble_spec.bats
      (cd /tmp/wt-del && just test integration 2>&1 | tail -3; echo rc=${PIPESTATUS[0]})
      ```
  - [ ] 4.2 清空必要 spec(0 案例):該層失敗並指名檔案
    - 預期看到資訊
      ```text
      [ci] ERROR: integration required spec defines zero cases: test/integration/assemble_spec.bats
      error: recipe `integration` failed on line 45 with exit code 1
      rc=1
      ```
    - 驗收方式
      ```bash
      rm -rf /tmp/wt-empty && cp -r . /tmp/wt-empty
      printf '#!/usr/bin/env bats\nload ../helper/common\n' > /tmp/wt-empty/test/integration/assemble_spec.bats
      (cd /tmp/wt-empty && just test integration 2>&1 | tail -3; echo rc=${PIPESTATUS[0]})
      ```

- [ ] 5. CI 與流程(gh / git 查外部證據)
  - [ ] 5.1 一個 sub-issue 一個 PR:12 個 PR(#135-#146)各自 CI 全 pass,以 merge commit 合併(不 squash)
    - 預期看到資訊
      ```text
      #135 pass=4
      #136 pass=4
      #137 pass=4
      #138 pass=4
      #139 pass=4
      #140 pass=4
      #141 pass=6
      #142 pass=7
      #143 pass=8
      #144 pass=8
      #145 pass=8
      #146 pass=8
      12d4431 Merge pull request #146 from ycpss91255/m2/134-just-interface
      ...(共 12 個 Merge pull request,#146 到 #135)
      7029917 Merge pull request #135 from ycpss91255/m2/122-manifest-format
      ```
      (每行只有 `pass=N`,沒有 fail / cancel / skipping;N 隨該 PR 當時的 gate 數量遞增:4 -> 6 -> 7 -> 8)
    - 驗收方式
      ```bash
      for n in $(seq 135 146); do printf '#%s ' "$n"; gh pr checks "$n" --repo ycpss91255/worktool --json bucket --jq 'group_by(.bucket) | map("\(.[0].bucket)=\(length)") | join(" ")'; done
      git log --oneline --merges main | head -12
      ```
  - [ ] 5.2 main 最新 commit 的 workflow 成功;`docker run` 只有 system-real 這一處帶 `--privileged`
    - 預期看到資訊
      ```text
      completed success 12d4431 Merge pull request #146 from ycpss91255/m2/134-just-interface
      12d4431
      script/test/test.sh:165:    docker run --rm \
      script/test/test.sh:190:    docker run --rm --privileged \
      ```
      (第一行的 SHA 與第二行 `origin/main` 相同;兩個 `docker run` 中只有 190 行 —— `_run_system_real_in_runner`,即 `just test system-real` —— 帶 `--privileged`;其餘檔案裡的 `--privileged` 都是註解)
    - 驗收方式
      ```bash
      gh run list --repo ycpss91255/worktool --branch main --limit 1 --json status,conclusion,headSha,displayTitle --jq '.[] | "\(.status) \(.conclusion) \(.headSha[0:7]) \(.displayTitle)"'
      git rev-parse --short origin/main
      grep -rn '^ *docker run' script .github justfile dockerfile
      ```
  - [ ] 5.3 codex 協作:每個 PR 都有 [codex] 留言判定可合併(原始四層複審與十一輪複驗在 PR #20)
    - 預期看到資訊
      ```text
      #135 2
      #136 1
      ...(12 行,每行數字 >= 1)
      #146 1
      ```
    - 驗收方式
      ```bash
      for n in $(seq 135 146); do printf '#%s ' "$n"; gh pr view "$n" --repo ycpss91255/worktool --comments | grep -c '\[codex\].*可合併\|最終判定:.*可合併'; done
      ```

- [ ] 6. 文件(grep 查內容)
  - [ ] 6.0 just 介面決策在 design.md(base 模型、ADR 引用)與 README
    - 預期看到資訊
      ```text
      README.md:1
      doc/design.md:11
      ```
    - 驗收方式
      ```bash
      grep -c '通用介面\|ADR-0000001' doc/design.md README.md
      ```
  - [ ] 6.1 manifest.md 有引號規則、驗證邊界、固定版本(1.8.2.5 / 29.8.0)、host 只留 runner 映像
    - 預期看到資訊
      ```text
      17
      ```
    - 驗收方式
      ```bash
      grep -c '引號規則\|驗證邊界\|1.8.2.5\|29.8.0\|runner 映像' doc/manifest.md
      ```
  - [ ] 6.2 manifest.md 的 M2 驗收紀錄表有三列(審核時填 SHA 與結果)
    - 預期看到資訊
      ```text
      | 自動化全綠(lint + u
      | 一鍵自檢 `just test
      | 真實可用盒(`script/
      ```
    - 驗收方式
      ```bash
      grep '^| 自動化全綠\|^| 一鍵自檢\|^| 真實可用盒' doc/manifest.md | cut -c1-20
      ```

- [ ] 7. 選做:真實主機(需 host 有 distrobox;host 沒裝可略過 —— 1.5 已在 Docker 內做等價的真實盒驗證)
  - [ ] 7.1 一鍵 assemble、進盒可用、冪等、可清理
    - 預期看到資訊
      ```text
      ripgrep 15.x.x ...
      0.6x (fzf 版本)
      tmux 3.x
      fish, version 4.x
      (第二次 assemble 不重建;rm 後 docker ps -a 無 dev)
      ```
    - 驗收方式
      ```bash
      just box assemble
      distrobox enter dev -- rg --version && distrobox enter dev -- fzf --version
      distrobox enter dev -- tmux -V && distrobox enter dev -- fish --version
      just box assemble
      distrobox rm -f dev
      ```

## M3 終端自動進盒 + 效能

- 交接前:同步驗收 PR 後取得最新 head SHA,在該 linked worktree 前景執行
  `.agents/script/monitor/full-run.sh --repo <repo> --sha <PR head SHA> --dispatch --wait 540`;
  回 3 時繼續以前景 `--wait 540` 查詢,總上限 10800 秒。只有回 0 才繼續 Scratch 與交接;
  查不到、查詢失敗、SHA 不符、仍 pending 或必要測試未完整成功均拒絕交接(#837、#899)。
  綠燈要求兩架構(`ubuntu-latest`、`ubuntu-24.04-arm`)的 full-serial/isolation 各一個
  completed/success job,各有成功的 `Verify checkout <PR head SHA>` 實際 HEAD 比對步驟。
  workflow success 但 job skipped 不算完整驗證,最新非綠燈也不回退舊綠燈。
  `milestone-handover` 的 Head -> Full run -> Scratch 順序使用同一個檢查。

- 自動:進盒延遲量測腳本回報 < 300ms;**整條「開窗 -> setup 受管 command -> `enter.sh` wrapper -> `distrobox enter dev` -> 盒內
  fish」鏈在 CI 內無頭驗證**(issue #172),分兩層。#374 延遲 gate 讀取隔離暫存設定中 setup
  實際寫出的受管 command,經 wrapper 量測 enter / shell / inbox;setup 準備不計時,
  shell median 仍以 300 ms 判定。終端**不自動開 tmux**(issue #179:
  distrobox 與 host 共用 `/tmp`,舊的 `-- tmux new -A -s main` 會附著到 host 的 tmux
  server,實機因此假成功):
  - 第一層(整合層 ghostty 組,不需顯示器,`just test integration`):
    `just box setup` 寫出的受管區塊交給**真的 ghostty** 讀 ——
    `ghostty +validate-config` 接受該檔,`ghostty +show-config` 解析出的生效
    `command` 恰為 `'<distrobox 絕對路徑>' enter dev`,後面不接 tmux
    (issue #175:受管 command 寫**已 quote 的**絕對路徑,斷言同時 refute 裸名字
    那一行;另有一案以含空白與 `$(...)` 的安裝路徑證明 quoting 真的擋得住);
    `--box <name>` 也照樣傳到 ghostty;並以「`--auto-enter no`
    之後不再有該指令」與「亂鍵設定被 `+validate-config` 拒絕」兩個對照案例證明
    斷言不是恆真。
  - 第二層(system-real 組,`just test system-real`):在 DinD 內用
    `xvfb-run -a` 開一個**真的 ghostty 視窗**,其受管區塊的 command 為
    `distrobox enter dev -- fish <script>`,斷言**盒內**留下的標記檔顯示 fish 版本、
    `tmux=no`、**所用引擎的容器檔存在**(issue #179 寫的 `/run/.containerenv` 是
    podman 的;docker 對應的是 `/.dockerenv`,distrobox 自己也以兩者之一判定在容器
    內——斷言因此 Docker / Podman 通用:要求的是所用引擎的那一個)、寫檔的 fish 所在
    的 **mount namespace 等於引擎回報的 dev 容器 pid 的**(不是 runner 自己的——
    DinD runner 本身也是 docker 容器、自己也有 `/.dockerenv`,光看檔案分不出兩者),
    且節點名等於 `docker inspect dev` 的 hostname(runner 自己沒有 fish,preflight
    先證明,所以回答的只可能是盒內那一個)。判準是盒內標記檔,不是 ghostty 的結束碼。issue #175 再加
    一案:把 ghostty 的 PATH 換成桌面工作階段那種(只放得到容器引擎,**沒有**
    distrobox),先以對照斷言證明該 PATH 下裸 `distrobox` 是 127,再用
    `just box setup` 自己解析寫進受管區塊的**絕對路徑**跑完同一條鏈。
    冷啟動(#434、#472):以 host `SHELL=/bin/bash` 建盒,在尚未初始化時
    執行 setup 實際寫出的 Ghostty 受管命令;送出任何輸入前先觀察預設登入
    行程為 fish、mount namespace 等於 dev,並驗證首次初始化持續輸出不同的
    進度、完成訊息與非空紀錄。unit 測試從同一類 setup 寫出的命令驗證
    失敗及 timeout 有界且顯示診斷和復原方式。
  - host 上已有 tmux server 的情境(issue #179,system-real):runner(host 端)先開
    一個 tmux server,session 名稱就是 `main`(舊命令 `-A` 會附著的那個);(1) 把
    `just box setup` **實際寫出的**受管 command 原樣交給真 ghostty 開窗,由 ghostty 的
    `input` 把 payload 打進落地的 shell,斷言標記檔仍來自盒內 fish(若命令又附著到
    host 的 server,payload 會在沒有 fish 的 runner 上跑、標記檔不會出現);(2) 盒內
    執行 `tmux` 得到盒子自己的 server:`box/dev.ini` 設的 `TMUX_TMPDIR`
    (`~/dev-box/.cache/tmux`)傳到盒內、server pid 與 host 的不同、其 mount
    namespace 等於 dev 容器的(而不是 host server 的)、該行程的根目錄裡有引擎的
    容器檔、socket 在 `TMUX_TMPDIR` 底下,盒內 `tmux ls` 不列 host 的 session、host 的
    `tmux ls` 也不列盒內的;(3) 盒內 tmux 環境的**矩陣**(codex 第 1–4 輪,PR #232):
    洩漏在環境——`distrobox enter` 把呼叫端的 `TMUX` / `TMUX_PANE` 帶進盒內——所以
    修在環境(`just box setup` 寫的 distrobox.conf 受管區塊,加上盒內登入 shell 的
    `box/tmux-env.sh` / `box/tmux-env.fish`;見 [`enter.md`](enter.md)),驗收以等價類
    矩陣斷言:進盒路徑(受管 ghostty 命令、`distrobox enter dev`、
    `distrobox enter dev -- <命令>`、`distrobox enter dev -- <真 tmux>`、`sh -l` /
    `fish -l` 登入 shell)× host 狀態(沒有 host tmux / host tmux server 在跑且呼叫端
    環境帶著它的 `TMUX`、`TMUX_PANE`)× tmux 呼叫(`tmux ls`、`tmux new`、
    `tmux new -A -s main`、`tmux attach`),每格盒內都看不到 `TMUX` / `TMUX_PANE`、
    盒子 server 停著時 `tmux ls` 不列任何 session、四種呼叫到的是同一個盒內 server
    (socket 在 `TMUX_TMPDIR` 底下、行程在 dev 容器的 mount namespace、根目錄有引擎
    的容器檔、不是 host server 的 pid),host 的 `tmux ls` 只列自己的 `main`。
    shim 組另以真的 distrobox-enter `--dry-run` 斷言:沒有區塊時 `exec` 請求帶著
    `--env=TMUX=`(對照),交付的 setup.sh 寫出區塊後每種進盒形狀都不帶。
  - 防卡與假陽性防護各有負向測試:盒內 payload **先寫 ready 標記再**
    `exec sleep infinity`,測試只在 ready 標記出現的前提下接受 `timeout` 的 124
    (否則是「沒進到盒子」這個不同的失敗),並以耗時上下界證明它跑滿預算才被砍;
    另有案例實地**觀測並量測** `gtk-single-instance` 開啟時的假陽性:第二次啟動
    **遠比它要求的指令可能耗費的時間更快就返回 0**(該指令永不結束),而在它
    **返回後隨即取樣**時,那個指令還沒開始;之後才開始 —— 順序以「start 檔 mtime
    嚴格晚於該時間戳」量出來。取樣不是返回瞬間的原子快照,但方向上只會讓案例假紅、
    不會假綠。期間沒有任何指令跑完。因此測試設定一律明寫
    `gtk-single-instance = false` 並以盒內標記檔為證。
- 人類:實機開新終端主觀順暢、開窗到提示字元無明顯延遲;host 上已有 tmux server
  時開新終端仍在盒內(`test -e /run/.containerenv -o -e /.dockerenv` 成立——docker
  建的盒子只有後者——且 `echo $FISH_VERSION` 有值),
  盒內打 `tmux` 看不到 host 的 session;在 host 的 tmux pane 裡手動
  `distrobox enter dev` 後打 `tmux`,同樣看不到 host 的 session。

- [ ] 3. 進盒設定:user 可選、預設直接進盒、每個決策印 log(`script/verify/setup.sh` 每項自建拋棄式 HOME 並在 EXIT / INT / TERM / HUP 清掉,不動你的家目錄)

  受管檔案是**使用者的**,`just box setup` 只是在裡面租一個區塊。所以**每一個**會寫入或移除受管區塊的項目 —— 3.1 / 3.2 / 3.3 / 3.5 / 3.6 / 3.7 / 3.8 / 3.9 / 3.10 / 3.11 / 3.12 / 3.13 —— 都在跑 setup **之前**就先把臨時 HOME 的 ghostty 設定與 `~/.tmux.conf` 種進三行看得出來的使用者內容,並在每一次寫入、改寫、移除之後再查一次:受管區塊以外的內容必須還是那三行、順序不變、一行不多一行不少，連檔尾空白行與最後換行也必須相同。這是 `user-content <時機>: ghostty=intact tmux.conf=intact` 那幾行。少了這個斷言,一個「把整份設定覆寫成受管區塊」的 setup 會讓區塊在、`status` 說 `present`、檔案數與結束碼全對 —— 而使用者的 ghostty 設定已經被刪掉了。3.4 不在名單裡,因為它只驗「被拒絕的輸入」與壞掉的狀態檔,整項從頭到尾不寫也不移除任何受管區塊(它反而要求 HOME 底下一個檔案都沒被建立)。

  PR #232 後不再有 tmux 決策，也不碰 host 的 `~/.tmux.conf`；`tmux.conf=intact` 在所有項目都表示它未被改動。3.7 改驗 distrobox.conf 的隔離區塊；3.8 驗 terminal none 的移除；3.9 改驗 PR #351 的 Ghostty 單區塊搬移。其餘項目保留寫入／移除兩側的使用者內容判準。#178 的五條 setup 路徑單元案例已由 PR #227 交付，新增驗收範圍留在 #231。

  `<repo>` 是 checkout 的絕對路徑；`<D>` 是 distrobox 絕對路徑。受管 command 使用產品的 shell quoting 與預設盒名，來源比對由 `verify_setup_spec.bats` 守住。

  - [ ] 3.1 dry-run 只印決策、不寫檔;受管 command 寫的是**已 quote 的 distrobox 絕對路徑**(#175)
    - 預期看到資訊
      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      ./script/box/setup.sh "$@"
      [INFO] auto-enter: yes (default)
      [INFO] terminal: ghostty (default)
      [INFO] terminal detected: ghostty (ghostty executable <G>)
      [INFO] box: dev (default)
      [INFO] ghostty config: <H>/.config/ghostty/config (config.ghostty absent; legacy fallback)
      [INFO] distrobox: <D> (absolute path written into the managed command)
      [INFO] dry-run: would write <H>/.config/worktool/config
      [INFO] dry-run: would write <H>/.config/distrobox/distrobox.conf (managed block: _worktool_n=; _worktool_v=; for _worktool_a in "$@"; do if [ -n "${_worktool_v}" ]; then [ "${_worktool_v}" = n ] && [ -n "${_worktool_a}" ] && _worktool_n="${_worktool_a}"; _worktool_v=; continue; fi; case "${_worktool_a}" in --|-e|--exec) break ;; -n|--name) _worktool_v=n ;; -a|--additional-flags) _worktool_v=a ;; -*) ;; *) _worktool_n="${_worktool_a}" ;; esac; done; [ "${_worktool_n:-${DBX_CONTAINER_NAME:-}}" != 'dev' ] || unset TMUX TMUX_PANE; unset _worktool_a _worktool_n _worktool_v)
      [INFO] dry-run: would write <H>/.config/ghostty/config (managed block: command = '<repo>/script/box/enter.sh' --distrobox '<D>' --box 'dev')
      rc=0
      files 2->2
      user-content after-dry-run: ghostty=intact tmux.conf=intact
      rc=0
      ```
      (第一個 `rc=` 是 `just box setup` 自己的結束碼,最後一行是本項 `echo rc=$?`。files 是整個臨時 HOME 的檔案總數,不只 worktool 設定檔:那兩個是本項在跑 setup 前種下的 ghostty 設定與 `~/.tmux.conf`,dry-run 不得新增任何檔案,也不得改動它們 —— 檔案數看不出「dry-run 把既有檔案重寫了一遍」,`user-content` 那行看得出來。`terminal detected:` 那行說明 ghostty 是怎麼判出來的;`<G>` 是 `script/verify/setup.sh` 自己用 `command -v ghostty` 算出來、再從輸出換掉的,所以 ghostty 裝在哪都對得起來,PATH 上沒有 ghostty 的機器則在跑 setup 前就報 `[UNAVAILABLE]` 並回非 0。上面每一行**內容**都在判準內、且各只能出現一次 —— 結束碼與檔案數看不出「受管 command 退回裸名字」(#175 的回歸)或「某個決策不再印 log」,只有文字看得出來)
    - 驗收方式
      ```bash
      just verify setup 3.1; echo rc=$?
      ```
  - [ ] 3.2 寫入後由 status 與檔案全文確認直接進盒、distrobox.conf 隔離區塊；狀態檔由共用 config 介面保存，沒有 tmux 決策（PR #232、#228）
    - 寫入後還要出現 Ghostty reload 提示；完整文字以 `script/box/setup.sh` 的 `_ghostty_reload_hint` 為來源，由真實產品 control 與移除提示的負例守住。
    - 預期看到資訊：`command = '<repo>/script/box/enter.sh' --distrobox '<D>' --box 'dev'`；`ghostty: <H>/.config/ghostty/config (managed block: present)`、`distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)`、`distrobox: <D> (recorded in a managed block: runnable)`。暫存 HOME 尚未 assemble，故印 `link: box HOME not recorded - user config not linked yet (run: just box assemble)` 與 `home: not recorded (run: just box assemble)`；`user-content after-write: ghostty=intact tmux.conf=intact`。
    - 驗收方式
      ```bash
      just verify setup 3.2; echo rc=$?
      ```
      預期 `rc=0`。狀態檔全文逐行比對；受管區塊必須放進使用者設定，既有內容必須完整保留。`~/.tmux.conf` 僅作為不得被改動的使用者檔案。
      第二輪透過 `lib/config.sh` 種下 `home=<H>/dev-box`、`home.source=default` 與 `link=.acceptance-user`，並建立 symlink，再跑 setup；原有 home／link 行不變，status 印 `home: <H>/dev-box (default)` 與 `link: <H>/dev-box/.acceptance-user -> <H>/.acceptance-user (linked)`（PR #228）。盒子預設獨立 HOME 是 `~/dev-box`，建立後固定；使用者設定以連結帶入，不靠共用 host HOME。
  - [ ] 3.3 `--auto-enter no` 移除 Ghostty 受管 command，保留 distrobox.conf 的 TMUX／TMUX_PANE 隔離區塊（PR #232）
    - 預期看到資訊：`blocks-before=1`、`blocks=0`、`ghostty: <H>/.config/ghostty/config (managed block: absent)`、`distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)`。`user-content after-write` 與 `after-removal` 都是 `ghostty=intact tmux.conf=intact`；沒有 tmux 決策或 tmux.conf 移除訊息。
    - 驗收方式
      ```bash
      just verify setup 3.3; echo rc=$?
      ```
      預期 `rc=0`；先量區塊確實存在，再判斷移除，並比對使用者內容。
  - [ ] 3.4 錯誤輸入 exit 2、不建檔；壞掉的 terminal 設定不論 default／user 來源都 exit 1；受管標記損壞或多個區塊時 dry-run 與實際 setup 都拒絕、整個 HOME 不變，status 報 MALFORMED（PR #232、#351）
    - 預期看到資訊：unknown option `--bogus`、`rc=2`、`files=0`；兩次 `invalid value 'sideways' for terminal (expected ghostty|none)` 與 `rc=1`。逐檔印 `malformed-refused=distrobox/distrobox.conf unchanged=yes`、`malformed-refused=ghostty/config unchanged=yes`、`malformed-refused=ghostty/config.ghostty unchanged=yes`；各檔 status 是 `managed block: MALFORMED - BEGIN at line 1 has no END; fix or remove the markers, then re-run: just box setup`。
    - 驗收方式
      ```bash
      just verify setup 3.4; echo rc=$?
      ```
      預期 `rc=0`；拒絕後以 HOME 全目錄比對確認沒有部分寫入。
      同檔兩個區塊（distrobox.conf、Ghostty legacy）與 Ghostty 兩檔各一個區塊都必須拒絕，不再折疊成一個；印 `multiple-refused=<檔案> unchanged=yes`。同檔重複區塊 status 報 MALFORMED；跨檔各一個區塊由 setup 的總數驗證拒絕。
  - [ ] 3.5 PATH 上沒有 distrobox 時 setup 直接拒絕、什麼都不寫;`--distrobox <絕對路徑>` 可以指定要寫進受管 command 的執行檔(#175:桌面啟動的終端找不到 `~/.local/bin`,所以受管 command 絕不能是裸名字)
    - 預期看到資訊
      輸出類型：工具版本會影響的輸出（just 診斷行）；其餘為固定判準（替換佔位符後逐字比對）。
      ```text
      ./script/box/setup.sh "$@"
      [INFO] auto-enter: yes (default)
      [INFO] terminal: ghostty (default)
      [INFO] terminal detected: ghostty (ghostty executable <H>/bin/ghostty)
      [INFO] box: dev (default)
      [INFO] ghostty config: <H>/.config/ghostty/config (config.ghostty absent; legacy fallback)
      [ERROR] distrobox: not found on PATH - the managed command must name an absolute path a terminal launched from the desktop can run (install distrobox, or pass --distrobox <path>); nothing was written
      error: Recipe `setup` failed on line 45 with exit code 1
      rc=1
      files 2->2
      user-content after-refusal: ghostty=intact tmux.conf=intact
      rc=0
      command = '<repo>/script/box/enter.sh' --distrobox '<D>' --box 'dev'
      user-content after-write: ghostty=intact tmux.conf=intact
      rc=0
      ```
      (just 診斷屬於**工具版本會影響的輸出**：``error: Recipe `setup` failed on line 45 with exit code 1`` 是示例，大小寫、行號會隨 just 版本與 recipe 位置變動；只比對 recipe 名稱 `setup` 與 `exit code 1`。其餘正規化產品行是固定判準，逐字比對。
      前半是「PATH 上沒有 distrobox」那一輪:`rc=1`、`files 2->2`(什麼都沒寫);後半是 `--distrobox <絕對路徑>` 那一輪:`rc=0` 與它寫出的受管 command。最後一行是本項 `echo rc=$?`。
      `files` 的那兩個數字是本項在跑 setup 前種下的 ghostty 設定與 `~/.tmux.conf`:被拒絕的那一輪不得新增檔案,也不得改動既有的 —— 檔案數看不出「拒絕之前先把設定重寫了一遍」,`user-content after-refusal` 看得出來(round 17)。
      `--distrobox` 那一輪是本項真正寫出受管區塊的地方,所以後面跟著 `user-content after-write`:受管 command 那行寫得再對,也分不出區塊是**放進**使用者的設定裡,還是**取代**了整份設定 —— 把 `enter_block_compose` 退化成「印出區塊、忘掉原檔」後,上面的 `command = ...` 一字不差,而使用者的 `font-size` 已經沒了)
    - 驗收方式
      ```bash
      just verify setup 3.5; echo rc=$?
      ```
  - [ ] 3.6 `status` 的 `distrobox:` 那行:除了 3.2 的 runnable,其餘四種狀態(#177)各印一次,證明「受管 command 還跑不跑得起來」在壞掉的情況下也講得出來
    - 預期看到資訊(四案各兩行,依序:受管絕對路徑被移走、舊版留下的裸名稱、沒有受管紀錄但 PATH 上有、兩者都沒有;每案的第二行是那次 `status` 自己的結束碼與它寫到 stderr 的行數。兩行 `user-content` 夾住本項用來佈置狀態的那一次寫入與那一次移除)
      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      user-content after-write: ghostty=intact tmux.conf=intact
      distrobox: <H>/bin/distrobox (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)
      rc=0 stderr=0
      distrobox: distrobox (recorded in a managed block: a bare name, not an absolute path - a terminal launched from the desktop may not find it; re-run: just box setup)
      rc=0 stderr=0
      user-content after-removal: ghostty=intact tmux.conf=intact
      distrobox: <D> (on PATH; no managed block records one)
      rc=0 stderr=0
      distrobox: not found on PATH (install distrobox, then re-run: just box setup)
      rc=0 stderr=0
      distinct-states=4/4
      rc=0
      ```
      (這行共五種狀態,runnable 由 3.2 驗,其餘四種在這裡。**上面那四行 `distrobox:` 是逐字判準,而且各綁定它所屬的那一個狀態**:本項問的不是「有沒有一行以 `distrobox:` 開頭」,而是「這個狀態有沒有印出本文件為它公佈的那一行」。這是必要的 —— 把 `status.sh` 的三分支改成單分支、一律回 `runnable`,四案仍然各有一行 `distrobox:`、各自 `rc=0 stderr=0`,舊版判準全綠(round 16)。`distinct-states=4/4` 是同一件事的另一半:四案確實給了四個**不同**的答案。**沒有被端到端涵蓋的是裸名稱那一種**:#175 之後的 `setup` 一律拒絕裸名字,本版沒有任何路徑會寫出它,所以這裡只能手寫一個舊格式的受管區塊 —— 驗的是 `status` 讀到舊設定時講不講得清楚,不是本版產得出這種設定。最後一案的受限 PATH 放的是 `status` 這條路徑**真正會用到的**六個工具(`just` / `sh` / `bash` / `dirname` / `awk` / `grep`)、獨缺 distrobox,所以不管你的 distrobox 裝在 `/usr/bin` 還是 `~/.local/bin`,那一輪都一定找不到 —— 而且找不到的是 distrobox,不是 `status` 自己要用的工具。`rc=` / `stderr=` 是這件事的守門:`stderr=0` 表示那次 `status` 除了 just 的回聲之外一個字都沒往 stderr 寫,少放工具的話那些 `command not found` 會被算進去(實測把 `awk` / `grep` 拿掉是 `stderr=18`),案子直接紅,不會被後面的 `grep` 濾掉當成過關;`script/verify/setup.sh` 在這裡不架任何管線,輸出先落到檔案再讀,所以 `rc=` 一定是那次 `status` 自己的結束碼(round 11)。stderr 收在臨時 HOME 底下,跟著 HOME 一起被清掉。
      本項不是只讀 `status`:它用一次真的 `setup --distrobox` 寫出受管區塊、再用一次真的 `setup --auto-enter no` 把它移除,才佈置得出第一案與第三案,所以那兩步的兩側各查一次使用者內容(round 17)。少了這兩行,把 `enter_block_compose` 退化成覆寫整份檔案、或把 `enter_block_strip` 退化成清空整份檔案,上面四個 `distrobox:` 文字、四個 `rc=0 stderr=0` 與 `distinct-states=4/4` 全數照舊 —— 第三案的「沒有受管紀錄」對一份被清空的設定同樣成立 —— 而使用者的 ghostty 設定已經被刪掉了。最後一行是本項 `echo rc=$?`)
    - 驗收方式
      ```bash
      just verify setup 3.6; echo rc=$?
      ```
  - [ ] 3.7 distrobox.conf 受管區塊清掉進入 dev 時繼承的 `TMUX`／`TMUX_PANE`，保留其他盒子的環境與使用者內容（PR #232）
    - 預期看到資訊：`distrobox-blocks=1`、`TMUX=unset TMUX_PANE=unset`、`TMUX=host TMUX_PANE=pane`、`user-content after-write: ghostty=intact tmux.conf=intact`。
    - 驗收方式
      ```bash
      just verify setup 3.7; echo rc=$?
      ```
      預期 `rc=0`；受管 distrobox.conf 在 shell 中以 dev 與 other 參數執行，前者清掉 host tmux 環境、後者保留。設定檔原有內容不變；host 的 `~/.tmux.conf` 完全不改動。
  - [ ] 3.8 `--terminal none` 移除 Ghostty profile，保存 none 決策及 distrobox 隔離區塊（PR #232）
    - 預期看到資訊：`ghostty-blocks-before=1`、`ghostty-blocks=0`、`terminal: none (user)`、`ghostty: <H>/.config/ghostty/config (managed block: absent)`、`distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)`。寫入與移除後的 `user-content` 都是 `ghostty=intact tmux.conf=intact`；沒有 distrobox 執行檔解析或 terminal 偵測決策。
    - 驗收方式
      ```bash
      just verify setup 3.8; echo rc=$?
      ```
      預期 `rc=0`。先量既有區塊，再確認移除及使用者全文不變；不寫終端 command 仍保留 distrobox.conf。
  - [ ] 3.9 `config.ghostty` 存在時成為目標；legacy config 的單一區塊搬過去，兩個檔案的使用者內容保留（PR #351）
    - 預期看到資訊：`[INFO] ghostty config: <H>/.config/ghostty/config.ghostty (config.ghostty exists)`、`[INFO] moved: <H>/.config/ghostty/config -> <H>/.config/ghostty/config.ghostty (managed block)`、`legacy-blocks=0 target-blocks=1`。status 分別報新檔 `present`、舊檔 `absent`；目標 command 是 `command = '<repo>/script/box/enter.sh' --distrobox '<D>' --box 'dev'`。
    - 驗收方式
      ```bash
      just verify setup 3.9; echo rc=$?
      ```
      預期 `rc=0`。先確認 legacy 確實有一個區塊，再建立新檔、搬移並比較兩份檔案的使用者內容。3.1–3.8 沒有新檔時仍使用 legacy fallback；兩檔驗證與損壞／多區塊拒絕由 3.4 檢查。
      host Ghostty 低於 1.3.0 且選用新檔時，必須有 `[WARN] ghostty <版本> does not read <H>/.config/ghostty/config.ghostty (requires 1.3.0 or newer)`；host 沒有執行檔就不查版本（PR #351）。
  - [ ] 3.10 原子寫入失敗不破壞原檔；status 報 absent，重跑補完
    - 驗收方式：`just verify setup 3.10`。只讓 Ghostty profile 的最後 rename 失敗，worktool 狀態檔與 distrobox.conf 仍照實寫入。錯誤必須恰好一次、setup exit 1；原檔逐 byte 相同，沒有 `config.XXXXXX` 殘留。status exit 0 且報 absent，移除故障後 setup exit 0、區塊 present、使用者內容保留。
    - 下列判準取自 Docker 內實際執行輸出；路徑以 `<H>`／`<D>`／`<repo>` 正規化。進度與 just 的 recipe echo 不列入判準；本項最後 exit 0。
      輸出類型：工具版本會影響的輸出（just 診斷行）；其餘為固定判準（替換佔位符後逐字比對）。just 診斷只比對 recipe 名稱 `setup` 與 `exit code 1`，大小寫與行號不列入逐字判準，與 3.5 相同。
      ```text
      [INFO] auto-enter: yes (default)
      [INFO] terminal: ghostty (user)
      [INFO] box: dev (default)
      [INFO] ghostty config: <H>/.config/ghostty/config (config.ghostty absent; legacy fallback)
      [INFO] distrobox: <D> (absolute path written into the managed command)
      [INFO] wrote: <H>/.config/worktool/config
      [INFO] wrote: <H>/.config/distrobox/distrobox.conf (managed block: _worktool_n=; _worktool_v=; for _worktool_a in "$@"; do if [ -n "${_worktool_v}" ]; then [ "${_worktool_v}" = n ] && [ -n "${_worktool_a}" ] && _worktool_n="${_worktool_a}"; _worktool_v=; continue; fi; case "${_worktool_a}" in --|-e|--exec) break ;; -n|--name) _worktool_v=n ;; -a|--additional-flags) _worktool_v=a ;; -*) ;; *) _worktool_n="${_worktool_a}" ;; esac; done; [ "${_worktool_n:-${DBX_CONTAINER_NAME:-}}" != 'dev' ] || unset TMUX TMUX_PANE; unset _worktool_a _worktool_n _worktool_v)
      [ERROR] failed to write <H>/.config/ghostty/config
      error: Recipe `setup` failed on line 45 with exit code 1
      setup-rc=1
      original=intact temp-files=0
      config: <H>/.config/worktool/config
      auto-enter: yes (default)
      terminal: ghostty (user)
      box: dev (default)
      ghostty: <H>/.config/ghostty/config (managed block: absent)
      distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)
      distrobox: <D> (on PATH; no managed block records one)
      link: box HOME not recorded - user config not linked yet (run: just box assemble)
      home: not recorded (run: just box assemble)
      status-rc=0
      [INFO] auto-enter: yes (default)
      [INFO] terminal: ghostty (user)
      [INFO] box: dev (default)
      [INFO] ghostty config: <H>/.config/ghostty/config (config.ghostty absent; legacy fallback)
      [INFO] distrobox: <D> (absolute path written into the managed command)
      [INFO] wrote: <H>/.config/worktool/config
      [INFO] unchanged: <H>/.config/distrobox/distrobox.conf (managed block already up to date)
      [INFO] wrote: <H>/.config/ghostty/config (managed block: command = '<repo>/script/box/enter.sh' --distrobox '<D>' --box 'dev')
      [INFO] Ghostty config changed: a running Ghostty must reload its config (Linux default: Ctrl+Shift+,). Reload is asynchronous; wait until the config takes effect before opening a new window, or start a new Ghostty process first. Keep your existing windows open.
      setup-rc=0
      user-content after-recovery: ghostty=intact tmux.conf=intact
      config: <H>/.config/worktool/config
      auto-enter: yes (default)
      terminal: ghostty (user)
      box: dev (default)
      ghostty: <H>/.config/ghostty/config (managed block: present)
      distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)
      wrapper: <repo>/script/box/enter.sh (recorded in a managed block: runnable)
      distrobox: <D> (recorded in a managed block: runnable)
      link: box HOME not recorded - user config not linked yet (run: just box assemble)
      home: not recorded (run: just box assemble)
      status-rc=0
      ```
  - [ ] 3.11 既有受管檔案的 0644／0600 模式不變
    - 驗收方式：`just verify setup 3.11`。各以 legacy `config` 與 `config.ghostty` 當目標，種下使用者內容及 0644／0600，真的寫入 dev、改寫成 second、再以 `--auto-enter no` 移除 Ghostty 區塊；每步以 `stat -c %a` 比較 Ghostty、distrobox.conf 與 worktool 狀態檔。後兩檔在移除操作中仍保留；host tmux.conf 不受管理，每次寫入、改寫與移除後都檢查 `~/.tmux.conf` 的使用者內容。
    - 下列為 Docker 實跑輸出的判準行（依原順序）；各步 setup／status exit 0，區塊以外的使用者內容保持完整。
      ```text
      setup-rc=0
      mode 644 config after-write: ghostty=644 distrobox=644 state=644
      setup-rc=0
      mode 644 config after-rewrite: ghostty=644 distrobox=644 state=644
      setup-rc=0
      mode 644 config after-removal: ghostty=644 distrobox=644 state=644
      ghostty: <H>/.config/ghostty/config (managed block: absent)
      status-rc=0
      setup-rc=0
      mode 644 config.ghostty after-write: ghostty=644 distrobox=644 state=644
      setup-rc=0
      mode 644 config.ghostty after-rewrite: ghostty=644 distrobox=644 state=644
      setup-rc=0
      mode 644 config.ghostty after-removal: ghostty=644 distrobox=644 state=644
      ghostty: <H>/.config/ghostty/config.ghostty (managed block: absent)
      status-rc=0
      setup-rc=0
      mode 600 config after-write: ghostty=600 distrobox=600 state=600
      setup-rc=0
      mode 600 config after-rewrite: ghostty=600 distrobox=600 state=600
      setup-rc=0
      mode 600 config after-removal: ghostty=600 distrobox=600 state=600
      ghostty: <H>/.config/ghostty/config (managed block: absent)
      status-rc=0
      setup-rc=0
      mode 600 config.ghostty after-write: ghostty=600 distrobox=600 state=600
      setup-rc=0
      mode 600 config.ghostty after-rewrite: ghostty=600 distrobox=600 state=600
      setup-rc=0
      mode 600 config.ghostty after-removal: ghostty=600 distrobox=600 state=600
      ghostty: <H>/.config/ghostty/config.ghostty (managed block: absent)
      status-rc=0
      ```
  - [ ] 3.12 已有區塊的 dry-run 移除不寫檔
    - 驗收方式：`just verify setup 3.12`。先真的寫入一個 Ghostty 區塊，再跑 `--dry-run --auto-enter no`；不是以空檔案的無事可做當作通過。Ghostty、distrobox.conf、worktool 狀態檔均與第一次寫入後逐 byte 相同；status 仍讀到原本的 yes 決策與 present 區塊。host tmux.conf 的使用者內容也不變。
    - 下列判準取自 Docker 實跑的 dry-run 與其後 status；setup／status／本項皆 exit 0。
      ```text
      [INFO] auto-enter: no (user)
      [INFO] terminal: ghostty (user)
      [INFO] box: dev (default)
      [INFO] ghostty config: <H>/.config/ghostty/config (config.ghostty absent; legacy fallback)
      [INFO] dry-run: would write <H>/.config/worktool/config
      [INFO] unchanged: <H>/.config/distrobox/distrobox.conf (managed block already up to date)
      [INFO] dry-run: would remove managed block from <H>/.config/ghostty/config
      setup-rc=0
      ghostty-blocks-before=1 ghostty-blocks-after=1
      dry-run-files=identical
      user-content after-dry-run: ghostty=intact tmux.conf=intact
      config: <H>/.config/worktool/config
      auto-enter: yes (default)
      terminal: ghostty (user)
      box: dev (default)
      ghostty: <H>/.config/ghostty/config (managed block: present)
      distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)
      wrapper: <repo>/script/box/enter.sh (recorded in a managed block: runnable)
      distrobox: <D> (recorded in a managed block: runnable)
      link: box HOME not recorded - user config not linked yet (run: just box assemble)
      home: not recorded (run: just box assemble)
      status-rc=0
      ```
  - [ ] 3.13 同決策連跑兩次，受管區塊 unchanged
    - 驗收方式：`just verify setup 3.13`。兩次真的呼叫同一組 setup 決策，第二次兩個受管區塊都逐行回報 unchanged、各只有一塊，沒有 Ghostty／distrobox.conf 的 wrote 行。比對三份檔案的 bytes 與兩個區塊檔的 inode，證明 unchanged 沒有重新 rename；worktool 狀態檔仍可照正常流程回報 wrote，但內容相同。
    - 下列判準取自 Docker 實跑的第二次 setup 與 status；setup／status／本項皆 exit 0。
      ```text
      [INFO] unchanged: <H>/.config/distrobox/distrobox.conf (managed block already up to date)
      [INFO] unchanged: <H>/.config/ghostty/config (managed block already up to date)
      setup-rc=0
      unchanged-inodes=identical
      unchanged-files=identical ghostty-blocks=1 distrobox-blocks=1
      user-content after-unchanged: ghostty=intact tmux.conf=intact
      config: <H>/.config/worktool/config
      auto-enter: yes (default)
      terminal: ghostty (user)
      box: dev (default)
      ghostty: <H>/.config/ghostty/config (managed block: present)
      distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)
      wrapper: <repo>/script/box/enter.sh (recorded in a managed block: runnable)
      distrobox: <D> (recorded in a managed block: runnable)
      link: box HOME not recorded - user config not linked yet (run: just box assemble)
      home: not recorded (run: just box assemble)
      status-rc=0
      ```

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

- 自動:release 前 CI 全綠;tag 只打在有綠燈完整序列執行的 sha 上(#837、ADR-0019):
  `.agents/script/monitor/full-run.sh --repo <repo> --sha <要打 tag 的 sha> --dispatch`
  回 0 才打 tag。綠燈包含兩架構 full-serial/isolation 各一個成功 job 與實際 checkout
  sha 的成功驗證;workflow success 但必要 job skipped／缺漏／重複或證據查詢失敗均非綠燈(#899)。
  有 release workflow 時,它必須在打 tag 前執行同一個檢查並在非 0 時失敗。
- 人類:全清單通過 + 明確的 RELEASE 同意(唯一需人類同意的 release)。
