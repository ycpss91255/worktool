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
          assemble *args # Assemble the dev box from its manifest (args: --dry-run, --file <manifest>, --help; default box/dev.ini).
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
  - [ ] 7.1 一鍵建盒、進盒可用、冪等、可清理
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

- 自動:進盒延遲量測腳本回報 < 300ms;**整條「開窗 -> `distrobox enter dev` -> 盒內
  fish」鏈在 CI 內無頭驗證**(issue #172),分兩層。終端**不自動開 tmux**(issue #179:
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
  - host 上已有 tmux server 的情境(issue #179,system-real):runner(host 端)先開
    一個 tmux server,session 名稱就是 `main`(舊命令 `-A` 會附著的那個);(1) 把
    `just box setup` **實際寫出的**受管 command 原樣交給真 ghostty 開窗,由 ghostty 的
    `input` 把 payload 打進落地的 shell,斷言標記檔仍來自盒內 fish(若命令又附著到
    host 的 server,payload 會在沒有 fish 的 runner 上跑、標記檔不會出現);(2) 盒內
    執行 `tmux` 得到盒子自己的 server:`box/dev.ini` 設的 `TMUX_TMPDIR`
    (`~/dev-box/.cache/tmux`)傳到盒內、server pid 與 host 的不同、其 mount
    namespace 等於 dev 容器的(而不是 host server 的)、該行程的根目錄裡有引擎的
    容器檔、socket 在 `TMUX_TMPDIR` 底下,盒內 `tmux ls` 不列 host 的 session、host 的
    `tmux ls` 也不列盒內的;(3) 從 **host tmux pane 裡**進盒(codex 第 1 輪,PR #232):
    在 host server 開新視窗執行 `distrobox enter dev`,先斷言盒內繼承到 host pane 的
    `TMUX`,再斷言盒內 `tmux` 仍得到盒子自己的 server(同 (2) 各項)——由
    `box/tmux-guard.sh` 丟掉指向 host socket 的 `TMUX`;同一個 pane 再以絕對路徑
    `/usr/bin/tmux` 開 session(codex 第 2 輪),斷言它落在同一個盒內 server、
    host 的 `tmux ls` 不列它——guard 裝在 `/usr/bin/tmux` 本身,不靠 PATH 順序。
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
