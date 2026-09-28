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
  - [ ] 7.1 一鍵建盒、進盒可用、冪等、可清理(**跑之前先確認你沒有同名 `dev` 盒**:這段結尾會無條件 `distrobox rm -f dev`;先斷言不存在、只刪自己建的那種寫法見 M3 的 5.1 與 5.3)
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

## M3 終端自動進盒 + 效能達標(審核中)

- 自動:進盒延遲量測腳本回報 < 300ms;**整條「開窗 -> 進盒 -> tmux/fish」鏈在 CI
  內無頭驗證**(issue #172),分兩層:
  - 第一層(整合層 ghostty 組,不需顯示器,`just test integration`):
    `just box setup` 寫出的受管區塊交給**真的 ghostty** 讀 ——
    `ghostty +validate-config` 接受該檔,`ghostty +show-config` 解析出的生效
    `command` 恰為 `'<distrobox 絕對路徑>' enter dev -- tmux new -A -s main`
    (issue #175:受管 command 寫**已 quote 的**絕對路徑,斷言同時 refute 裸名字
    那一行;另有一案以含空白與 `$(...)` 的安裝路徑證明 quoting 真的擋得住);
    `--tmux host` / `--box <name>` 也照樣傳到 ghostty;並以「`--auto-enter no`
    之後不再有該指令」與「亂鍵設定被 `+validate-config` 拒絕」兩個對照案例證明
    斷言不是恆真。
  - 第二層(system-real 組,`just test system-real`):在 DinD 內用
    `xvfb-run -a` 開一個**真的 ghostty 視窗**,其受管區塊的 command 為
    `distrobox enter dev -- tmux new -A -s chain fish <script>`,斷言**盒內**留下
    的標記檔顯示 fish 版本與 `tmux=yes`(runner 自己沒有 fish,所以回答的只可能
    是盒內那一個)。判準是盒內標記檔,不是 ghostty 的結束碼。issue #175 再加
    一案:把 ghostty 的 PATH 換成桌面工作階段那種(只放得到容器引擎,**沒有**
    distrobox),先以對照斷言證明該 PATH 下裸 `distrobox` 是 127,再用
    `just box setup` 自己解析寫進受管區塊的**絕對路徑**跑完同一條鏈。
  - 防卡與假陽性防護各有負向測試:盒內 payload **先寫 ready 標記再**
    `exec sleep infinity`,測試只在 ready 標記出現的前提下接受 `timeout` 的 124
    (否則是「沒進到盒子」這個不同的失敗),並以耗時上下界證明它跑滿預算才被砍;
    另有案例實地**觀測並量測** `gtk-single-instance` 開啟時的假陽性:第二次啟動
    **遠比它要求的指令可能耗費的時間更快就返回 0**(該指令永不結束),而在它
    **返回後隨即取樣**時,那個指令還沒開始;之後才開始 —— 順序以「start 檔 mtime
    嚴格晚於該時間戳」量出來。取樣不是返回瞬間的原子快照,但方向上只會讓案例假紅、
    不會假綠。期間沒有任何指令跑完。因此測試設定一律明寫
    `gtk-single-instance = false` 並以盒內標記檔為證。
- 人類:實機開新終端主觀順暢、開窗到提示字元無明顯延遲。

人類 gate 用的驗收清單(= M3 驗收 PR 的描述;逐項勾選,有差異回 PR 留言):

### 通用指令

依賴分兩組(repo 本身不需要驗收工具):

- repo 使用依賴:`docker`(可 `--privileged`)、`just`;clone 需要 `git`。
- 驗收工具:`gh`(已登入,2.2 / 5.1 / 6.1-6.3 用)、`jq`(5.1 / 6.1 用)、`awk` / `grep` / `sed` / `cut` / `find` / `mktemp` / `sha256sum`(coreutils + awk);3 需要 host 的 PATH 上有 `distrobox` 與 `ghostty`(setup 解析這兩個絕對路徑寫進決策 log 與受管 command,少一個就沒得驗);5(實機)另需真的建得起盒、開得起 ghostty 視窗。1-2、4、6 不需 distrobox / ghostty。

每個「驗收方式」區塊以 **bash** 執行(fish 使用者先打 `bash`),可單獨複製執行,自己建立並清理臨時目錄 / 暫存檔;**請原樣貼上,不要改寫**,改寫過的區塊不算數。為了不再依賴文件文字的完整性,2.2 的判定邏輯已經移進 repo 檔案 `doc/evidence/tdd.awk` / `tdd.sh`,文件那一行只剩一次呼叫;當初為什麼搬(十份 PR 描述都滿足 2.2 的主張、而且找不到任何單一環境差異能重現維護者那一輪的 9/10 `order=BAD`)照實記在 `doc/evidence/README.md`,#176 item 8。
本 PR(#157)只改 `doc/acceptance.md` 與它的檢查程式 `doc/evidence/`(不動產品程式);**要驗的產品程式全在 main,但 2.2 與 2.4 呼叫的 `doc/evidence/` 只在本 PR 分支上**,所以下面直接 clone 本 PR 分支 `m3/5-acceptance`(= main 加這兩份文件變更)。clone 成 main 的話,2.2 會是 `No such file or directory`(rc=127)、2.4 會是 `awk: fatal: cannot open source file`。

```bash
git clone --branch m3/5-acceptance https://github.com/ycpss91255/worktool.git && cd worktool   # 該分支已 merge main,含 M3 全部 sub-issue PR(#152-#156、#165-#169)與 #177
just --version && docker info >/dev/null && echo repo-dep-ok
gh auth status >/dev/null 2>&1 && jq --version >/dev/null && echo verify-tool-ok
```

```text
just 1.53.0        (版本不限)
repo-dep-ok
verify-tool-ok
```

(`git clone` 自己會往 stderr 印 `Cloning into 'worktool'...` 之類的進度,不列在上面;判準是後面三行。`gh` 沒登入時只會少掉 `verify-tool-ok` 且整段 rc=1)

3 與 5 的輸出含機器相關路徑,下面以 `<H>`(臨時 HOME)、`<D>`(host 上 distrobox 執行檔的絕對路徑,例如 `/usr/local/bin/distrobox`)、`<G>`(host 上 ghostty 執行檔的絕對路徑,`command -v ghostty` 的結果)代表。3 的每個區塊自己算出這幾個路徑,再用 `sed` 把輸出裡的它們換成佔位符,所以 3 的預期輸出在任何安裝位置都逐字相符(round 10:上一版把 ghostty 路徑寫死成 `/usr/bin/ghostty`,裝在別處的機器會無故變紅);5 的輸出沒有這層轉換,請自己對照。

### 驗收項目

規則:功能入口一律 `just`(1-4 操作 repo 的部分);5 是實機(distrobox 原生 + 開終端主觀);文件與外部證據用上面列出的驗收工具(gh / jq / awk / grep / sed / find)查。

- [ ] 1. 使用者介面:box namespace 多了 bench / setup / status
  - [ ] 1.1 `just box` 列出六個動作;`just box help` 依序印四支腳本的 usage
    - 預期看到資訊
      ```text
      Available recipes:
          assemble *args # Assemble the dev box from its manifest (args: --dry-run, --file <manifest>, --help; default box/dev.ini).
          bench *args    # Measure the enter latency of the dev box: enter, shell and in-box shell start-up (args: --box NAME, --runs N, --warmup N, --max-ms N, --json, --shell CMD, --help; the script validates --box / --shell).
          default        # List the box verbs.
          help           # Show every box script's help (assemble.sh, bench.sh, setup.sh, status.sh --help). [alias: h]
          setup *args    # Choose how a new terminal enters the box (args: --auto-enter yes|no, --terminal ghostty|none, --tmux inside|host, --box <name>, --dry-run, --help).
          status *args   # Show the auto-enter decisions in force, their sources and the managed blocks (args: --help).
      Usage: assemble.sh [--file <manifest>] [--dry-run]
      Usage: bench.sh [--box NAME] [--runs N] [--warmup N] [--max-ms N] [--json]
      Usage: setup.sh [--auto-enter yes|no] [--terminal ghostty|none]
      Usage: status.sh
      four-usages
      ```
      (usage 第一行可能因終端寬度換行只顯示前半;最後一行 four-usages = 斷言四支不同腳本各有 usage)
    - 驗收方式
      ```bash
      just box
      just box help 2>&1 | grep '^Usage:'
      test "$(just box help 2>&1 | grep -o '^Usage: [a-z]*\.sh' | sort -u | wc -l)" -eq 4 && echo four-usages
      ```

- [ ] 2. 自動測試:六道 gate 全綠(含 300 ms 進盒延遲 gate)
  - [ ] 2.1 裸 `just test` 跑完六層;system-real 內盒有 tmux + fish,bench 以 `fish -c exit` 通過 `--max-ms 300`,負向 `--max-ms 1` 會咬
    - 預期看到資訊(約 5-8 分鐘;每層 `required specs OK` 後全部 ok,案例數隨版本增加不釘死)
      ```text
      ./script/test/test.sh
      [ci] ShellCheck OK
      [ci]   required specs OK (331 case(s) declared by 15 file(s))
      ...(unit 331 / integration 20 / integration-ghostty 12 / system 6 / acceptance 6 / system-real 18,每層 1..N 全部 ok,各以 `[ci] <tier> bats OK` 結尾;沒有 not ok、沒有 # skip)
      ok 7 real engine: distrobox enter dev -- tmux -V prints a tmux version (auto-enter prerequisite)
      ok 8 real engine: distrobox enter dev -- fish --version prints a fish version (auto-enter prerequisite)
      # bench: enter: min=91.1 median=93.8 max=102.0 ms
      # bench: shell: min=95.2 median=99.7 max=100.3 ms
      # bench: inbox: min=4.7 median=5.1 max=5.9 ms
      # bench: [INFO] shell median 99.7 ms within --max-ms 300
      ok 9 real engine: bench.sh --box dev --runs 5 --warmup 2 --shell 'fish -c exit' --max-ms ENTER_MAX_MS exits 0 (enter-latency gate on fish) and prints the enter, shell and inbox metric lines
      # bench-gate: [ERROR] shell median 98.4 ms exceeds --max-ms 1
      ok 10 real engine: bench.sh --box dev --runs 1 --warmup 0 --shell 'fish -c exit' --max-ms 1 exits 1 with the threshold message (the gate bites on a real box)
      [ci] system-real bats OK
      [system-real] cleanup: containers left in the nested daemon: 0
      rc=0
      ```
      (數字是你機器的實測;判準 = shell median < 300 且三行指標都在。自動測試只證明「盒內有 tmux + fish、進盒 + 起 fish < 300 ms」;「ghostty 開窗 -> 受管 command -> 盒內 tmux/fish」整條鏈由 2.3 在 CI 內驗證,實機主觀感受由 5.2 驗)
    - 驗收方式
      ```bash
      just test; echo rc=$?
      ```
  - [ ] 2.2 TDD 證據:每個 sub-issue PR 的描述都有一個非空的 RED 程式碼區塊,且其後另有一個非空的 GREEN 程式碼區塊(只證明「有貼輸出且順序正確」,不判讀內容語意;`red=` / `green=` 是該區塊開頭的行號)
    - 預期看到資訊(10 行,每行 order=ok;行號依 PR 內容而異)
      ```text
      #152 order=ok red=31 green=51
      #153 order=ok red=21 green=40
      #154 order=ok red=27 green=41
      #155 order=ok red=31 green=49
      #156 order=ok red=29 green=49
      #165 order=ok red=25 green=72
      #166 order=ok red=21 green=58
      #167 order=ok red=20 green=56
      #168 order=ok red=25 green=44
      #169 order=ok red=22 green=47
      rc=0
      ```
      (失敗時的樣子:缺段、區塊是空的或順序錯是 `#N order=BAD ...`,查詢失敗是 `#N evidence=gh-failed`,兩者最後都 `rc=1`)
    - 驗收方式
      ```bash
      bash doc/evidence/tdd.sh; echo rc=$?
      ```
  - [ ] 2.3 「開窗 -> 進盒 -> tmux/fish」整條鏈由 CI 自動驗證(#172):整合層用真的 ghostty 斷言受管區塊解析出的 command;system-real 用 `xvfb-run` 開真視窗,判準是**盒內**留下的標記檔(runner 自己沒有 fish);並有防卡與假陽性兩個負向測試
    - 預期看到資訊(`just test` 的 integration 與 system-real 兩段;兩條 pipeline 都以 `set -o pipefail` 保護,所以 rc 反映上游 `just test` 的結果)
      ```text
      ok 8 setup --tmux inside after host: status shows the tmux.conf block gone, ghostty still present
      ok 1 preflight: a real ghostty is on PATH and reports its version
      ok 2 setup.sh writes a ghostty config that +validate-config accepts
      ok 5 +show-config follows setup.sh --box work (the box name reaches ghostty)
      ok 6 #175: the effective command ghostty resolves is an ABSOLUTE distrobox path, not the bare name
      ok 9 #175r2: a distrobox path holding a newline is refused, because ghostty could not parse what it would write
      ok 10 #175r1: a distrobox path with spaces and metacharacters survives ghostty and the shell it hands the command to
      ok 11 after setup.sh --auto-enter no there is no enter command left for ghostty to run
      ok 12 +validate-config refuses a config ghostty cannot parse (the check bites)
      rc=0
      ```

      ```text
      ok 12 ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive)
      # chain: inbox-ok fish=4.2.1 tmux=yes host=ca83e9d035cd
      # chain-host: marker host=ca83e9d035cd == docker inspect dev hostname
      ok 13 ghostty chain: a real window runs the managed block's command and leaves a marker INSIDE the box (fish under tmux)
      # hang-ready: hang-ready fish=4.2.1 host=ca83e9d035cd
      # hang: in-box command started, then timed out after 45s (budget 45s, status 124)
      ok 14 ghostty chain: a command that has STARTED inside the box and never ends FAILS within its budget instead of hanging
      # single-instance: PRIMARY=up
      # single-instance: SECOND_RC=0
      # single-instance: SECOND_ELAPSED=1
      # single-instance: STARTED_AT_RETURN=1
      # single-instance: FORWARDED_STARTED=yes
      # single-instance: FORWARDED_AFTER_RETURN=yes
      # single-instance: FORWARDED_DELAY_MS=319
      # single-instance: RUNNING_COMMANDS=2
      # single-instance: PRIMARY_WRAPPER_ALIVE=yes
      # single-instance: COMMAND_FINISHED=no
      ok 15 ghostty chain: with gtk-single-instance on, a forwarded launch exits 0 while the command it asked for has not begun yet (the false positive the guard prevents)
      # chain-desktop-path: inbox-ok fish=4.2.1 tmux=yes host=ca83e9d035cd
      ok 16 ghostty chain (#175): the absolute distrobox path just box setup writes enters the box from a desktop session's PATH
      rc=0
      ```
      (`host=` 是那一輪盒子的容器 id、`fish=`、`FORWARDED_DELAY_MS=` 與 `SECOND_ELAPSED=` 是實測值,每次都不一樣,不要照字面比 —— 尤其 `SECOND_ELAPSED` 是「第二次啟動花了幾秒」,測試接受的是 0-15,上面印 `1` 只是某一輪的實測(round 11:一輪量到 `0`,照字面比會無故變紅);判準是這些 `ok` 行都在、沒有 `not ok`、`FORWARDED_STARTED` / `FORWARDED_AFTER_RETURN` 是 `yes`、`COMMAND_FINISHED` 是 `no`、兩段都 `rc=0`。hang 案例只在盒內 ready 標記出現後才接受 `timeout` 的 124,否則算「沒進到盒子」這個不同的失敗;single-instance 案例證明為什麼所有測試設定都明寫 `gtk-single-instance = false`)
    - 驗收方式
      ```bash
      ( set -o pipefail; just test integration 2>&1 | grep -E '^ok .*ghostty|^not ok' ); echo rc=$?
      ( set -o pipefail; just test system-real 2>&1 | grep -E '^# (chain|chain-host|hang|single-instance)|^ok .*ghostty chain|^not ok' ); echo rc=$?
      ```
  - [ ] 2.4 驗收程式本身的負向:2.2 的檢查程式會咬錯誤的證據;2.3 的 pipeline 沒有 `pipefail` 時會漏掉上游失敗(#176 item 7 / item 8 的回歸守門)
    - 預期看到資訊(前四行 = 檢查程式咬住順序顛倒與空的 RED 區塊;後兩行 = 同一條 pipeline 有無 `pipefail` 的差別)
      ```text
      order=BAD red=6 green=0
      wrong-order rc=1
      order=BAD red=0 green=0
      empty-red-block rc=1
      pipefail-rc=7
      documented-style-rc=0
      ```
    - 驗收方式
      ```bash
      awk -f doc/evidence/tdd.awk doc/evidence/negative/wrong-order.md; echo "wrong-order rc=$?"
      awk -f doc/evidence/tdd.awk doc/evidence/negative/empty-red-block.md; echo "empty-red-block rc=$?"
      ( set -o pipefail; { echo 'ok 1 ghostty chain: x'; exit 7; } | grep -E '^ok .*ghostty' >/dev/null ); echo pipefail-rc=$?
      ( { echo 'ok 1 ghostty chain: x'; exit 7; } | grep -E '^ok .*ghostty' >/dev/null ); echo documented-style-rc=$?
      ```

- [ ] 3. 進盒設定:user 可選、預設直接進盒、每個決策印 log(每個區塊自建拋棄式 HOME,不動你的家目錄)
  - [ ] 3.1 dry-run 只印決策、不寫檔;受管 command 寫的是**已 quote 的 distrobox 絕對路徑**(#175)
    - 預期看到資訊
      ```text
      ./script/box/setup.sh "$@"
      [INFO] auto-enter: yes (default)
      [INFO] terminal: ghostty (default)
      [INFO] terminal detected: ghostty (ghostty executable <G>)
      [INFO] tmux: inside (default)
      [INFO] box: dev (default)
      [INFO] distrobox: <D> (absolute path written into the managed command)
      [INFO] dry-run: would write <H>/.config/worktool/config
      [INFO] dry-run: would write <H>/.config/ghostty/config (managed block: command = '<D>' enter dev -- tmux new -A -s main)
      rc=0
      files 0->0
      ```
      (files 是整個臨時 HOME 的檔案總數,不只 worktool 設定檔:dry-run 不得新增任何檔案。`terminal detected:` 那行說明 ghostty 是怎麼判出來的;`<G>` 是區塊自己用 `command -v ghostty` 算出來、再從輸出換掉的,所以 ghostty 裝在哪都對得起來,PATH 上沒有 ghostty 的機器則在跑 setup 前就 `exit 1`)
    - 驗收方式
      ```bash
      ( H=$(mktemp -d) || exit 1; trap 'find "$H" -depth -delete' EXIT; mkdir -p "$H/.config/ghostty"
        G=$(command -v ghostty) && D=$(command -v distrobox) || exit 1   # 預期輸出比對的是這兩個路徑,不是寫死的
        norm() { sed -e "s|$G|<G>|g" -e "s|$D|<D>|g" -e "s|$H|<H>|g"; }
        before=$(find "$H" -type f | wc -l)
        HOME=$H XDG_CONFIG_HOME=$H/.config just box setup --dry-run 2>&1 | norm; echo rc=${PIPESTATUS[0]}
        printf 'files %s->%s\n' "$before" "$(find "$H" -type f | wc -l)" )
      ```
  - [ ] 3.2 真的寫入:設定檔 + ghostty 受管區塊;status 的報告有八行,最後一行說受管區塊裡的 distrobox 還跑不跑得起來
    - 預期看到資訊
      ```text
      ./script/box/setup.sh "$@"
      [INFO] auto-enter: yes (default)
      [INFO] terminal: ghostty (default)
      [INFO] terminal detected: ghostty (ghostty executable <G>)
      [INFO] tmux: inside (default)
      [INFO] box: dev (default)
      [INFO] distrobox: <D> (absolute path written into the managed command)
      [INFO] wrote: <H>/.config/worktool/config
      [INFO] wrote: <H>/.config/ghostty/config (managed block: command = '<D>' enter dev -- tmux new -A -s main)
      rc=0
      ./script/box/status.sh "$@"
      config: <H>/.config/worktool/config
      auto-enter: yes (default)
      terminal: ghostty (default)
      tmux: inside (default)
      box: dev (default)
      ghostty: <H>/.config/ghostty/config (managed block: present)
      tmux.conf: <H>/.tmux.conf (managed block: absent)
      distrobox: <D> (recorded in a managed block: runnable)
      rc=0
      # BEGIN worktool managed block (just box setup; do not edit)
      command = '<D>' enter dev -- tmux new -A -s main
      # END worktool managed block
      ```
    - 驗收方式
      ```bash
      ( H=$(mktemp -d) || exit 1; trap 'find "$H" -depth -delete' EXIT; mkdir -p "$H/.config/ghostty"
        G=$(command -v ghostty) && D=$(command -v distrobox) || exit 1
        norm() { sed -e "s|$G|<G>|g" -e "s|$D|<D>|g" -e "s|$H|<H>|g"; }
        HOME=$H XDG_CONFIG_HOME=$H/.config just box setup 2>&1 | norm; echo rc=${PIPESTATUS[0]}
        HOME=$H XDG_CONFIG_HOME=$H/.config just box status 2>&1 | norm; echo rc=${PIPESTATUS[0]}
        norm <"$H/.config/ghostty/config" )
      ```
  - [ ] 3.3 改回 host shell:先 setup(輸出略,同 3.2)再 `--auto-enter no`:移除區塊並逐一回報(user 來源標記);受管區塊只剩零個
    - 預期看到資訊(第二次 setup 起)
      ```text
      ./script/box/setup.sh "$@"
      [INFO] auto-enter: no (user)
      [INFO] terminal: ghostty (default)
      [INFO] terminal detected: ghostty (ghostty executable <G>)
      [INFO] tmux: inside (default)
      [INFO] box: dev (default)
      [INFO] wrote: <H>/.config/worktool/config
      [INFO] removed: <H>/.config/ghostty/config (managed block: command = '<D>' enter dev -- tmux new -A -s main)
      [INFO] nothing to remove: <H>/.tmux.conf (no managed block)
      rc=0
      blocks=0
      ```
      (`--auto-enter no` 只移除,不需要解析 distrobox,所以沒有 `[INFO] distrobox:` 那行)
    - 驗收方式
      ```bash
      ( H=$(mktemp -d) || exit 1; trap 'find "$H" -depth -delete' EXIT; mkdir -p "$H/.config/ghostty"
        G=$(command -v ghostty) && D=$(command -v distrobox) || exit 1
        norm() { sed -e "s|$G|<G>|g" -e "s|$D|<D>|g" -e "s|$H|<H>|g"; }
        HOME=$H XDG_CONFIG_HOME=$H/.config just box setup >/dev/null 2>&1
        HOME=$H XDG_CONFIG_HOME=$H/.config just box setup --auto-enter no 2>&1 | norm; echo rc=${PIPESTATUS[0]}
        printf 'blocks=%s\n' "$(grep -c 'BEGIN worktool managed block' "$H/.config/ghostty/config")" )
      ```
  - [ ] 3.4 錯誤輸入由腳本拒絕且 HOME 內沒有任何檔案被建立;壞掉的設定檔不論來源(default / user)都被拒(exit 1)
    - 預期看到資訊
      ```text
      ./script/box/setup.sh "$@"
      setup.sh: unknown option '--bogus' (see --help)
      error: recipe `setup` failed on line 44 with exit code 2
      rc=2
      files=0
      ./script/box/status.sh "$@"
      [ERROR] <H>/.config/worktool/config: invalid value 'sideways' for tmux (expected inside|host)
      error: recipe `status` failed on line 48 with exit code 1
      rc=1
      ./script/box/status.sh "$@"
      [ERROR] <H>/.config/worktool/config: invalid value 'sideways' for tmux (expected inside|host)
      error: recipe `status` failed on line 48 with exit code 1
      rc=1
      ```
    - 驗收方式
      ```bash
      ( H=$(mktemp -d) || exit 1; trap 'find "$H" -depth -delete' EXIT
        norm() { sed -e "s|$H|<H>|g"; }
        HOME=$H XDG_CONFIG_HOME=$H/.config just box setup --bogus 2>&1 | norm; echo rc=${PIPESTATUS[0]}
        printf 'files=%s\n' "$(find "$H" -type f | wc -l)"
        mkdir -p "$H/.config/worktool"
        for src in default user; do printf 'tmux=sideways\ntmux.source=%s\n' "$src" > "$H/.config/worktool/config"; HOME=$H XDG_CONFIG_HOME=$H/.config just box status 2>&1 | norm; echo rc=${PIPESTATUS[0]}; done )
      ```
  - [ ] 3.5 PATH 上沒有 distrobox 時 setup 直接拒絕、什麼都不寫;`--distrobox <絕對路徑>` 可以指定要寫進受管 command 的執行檔(#175:桌面啟動的終端找不到 `~/.local/bin`,所以受管 command 絕不能是裸名字)
    - 預期看到資訊
      ```text
      ./script/box/setup.sh "$@"
      [INFO] auto-enter: yes (default)
      [INFO] terminal: ghostty (default)
      [INFO] terminal detected: ghostty (ghostty executable <H>/bin/ghostty)
      [INFO] tmux: inside (default)
      [INFO] box: dev (default)
      [ERROR] distrobox: not found on PATH - the managed command must name an absolute path a terminal launched from the desktop can run (install distrobox, or pass --distrobox <path>); nothing was written
      error: recipe `setup` failed on line 44 with exit code 1
      rc=1
      files=0
      rc=0
      command = '<D>' enter dev -- tmux new -A -s main
      ```
    - 驗收方式
      ```bash
      ( H=$(mktemp -d) || exit 1; trap 'find "$H" -depth -delete' EXIT; mkdir -p "$H/.config/ghostty" "$H/bin"
        D=$(command -v distrobox) && command -v ghostty >/dev/null || exit 1
        norm() { sed -e "s|$D|<D>|g" -e "s|$H|<H>|g"; }
        # ghostty 一起連進 $H/bin:受限 PATH 下的偵測結果就不再取決於它裝在哪
        for t in just ghostty; do ln -s "$(command -v "$t")" "$H/bin/$t"; done; P=$H/bin:/usr/bin:/bin
        HOME=$H XDG_CONFIG_HOME=$H/.config PATH=$P just box setup 2>&1 | norm; echo rc=${PIPESTATUS[0]}
        printf 'files=%s\n' "$(find "$H" -type f | wc -l)"
        HOME=$H XDG_CONFIG_HOME=$H/.config PATH=$P just box setup --distrobox "$D" >/dev/null 2>&1; echo rc=$?
        grep '^command' "$H/.config/ghostty/config" | norm )
      ```
  - [ ] 3.6 `status` 的 `distrobox:` 那行:除了 3.2 的 runnable,其餘四種狀態(#177)各印一次,證明「受管 command 還跑不跑得起來」在壞掉的情況下也講得出來
    - 預期看到資訊(四行,依序:受管絕對路徑被移走、舊版留下的裸名稱、沒有受管紀錄但 PATH 上有、兩者都沒有)
      ```text
      distrobox: <H>/bin/distrobox (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)
      distrobox: distrobox (recorded in a managed block: a bare name, not an absolute path - a terminal launched from the desktop may not find it; re-run: just box setup)
      distrobox: <D> (on PATH; no managed block records one)
      distrobox: not found on PATH (install distrobox, then re-run: just box setup)
      ```
      (這行共五種狀態,runnable 由 3.2 驗,其餘四種在這裡。**沒有被端到端涵蓋的是裸名稱那一種**:#175 之後的 `setup` 一律拒絕裸名字,本版沒有任何路徑會寫出它,所以這裡只能手寫一個舊格式的受管區塊 —— 驗的是 `status` 讀到舊設定時講不講得清楚,不是本版產得出這種設定。最後一行的受限 PATH 只放 `just` / `sh` / `bash` / `dirname` 四個連結,所以不管你的 distrobox 裝在 `/usr/bin` 還是 `~/.local/bin`,那一輪都一定找不到)
    - 驗收方式
      ```bash
      ( H=$(mktemp -d) || exit 1; trap 'find "$H" -depth -delete' EXIT; mkdir -p "$H/.config/ghostty" "$H/bin"
        D=$(command -v distrobox) || exit 1
        norm() { sed -e "s|$D|<D>|g" -e "s|$H|<H>|g"; }
        st() { HOME=$H XDG_CONFIG_HOME=$H/.config "$@" just box status 2>&1 | grep '^distrobox:' | norm; }
        printf '#!/bin/sh\nexit 0\n' >"$H/bin/distrobox"; chmod +x "$H/bin/distrobox"
        HOME=$H XDG_CONFIG_HOME=$H/.config just box setup --distrobox "$H/bin/distrobox" >/dev/null 2>&1
        rm -f "$H/bin/distrobox"; st                      # 記錄當時跑得動,之後被移走
        sed -i "s|^command = .*|command = 'distrobox' enter dev -- tmux new -A -s main|" "$H/.config/ghostty/config"; st
        HOME=$H XDG_CONFIG_HOME=$H/.config just box setup --auto-enter no >/dev/null 2>&1; st
        for t in just sh bash dirname; do ln -s "$(command -v "$t")" "$H/bin/$t"; done
        st env PATH="$H/bin" )
      ```

- [ ] 4. README 圖(draw.io,可編輯)
  - [ ] 4.1 `doc/diagram/` 恰好三張 `.drawio.svg`、都無 foreignObject、都內嵌 mxfile;README 引用三張圖(3 個圖片 + 1 個編輯連結說明 = 4 處);流程圖測試節點寫「host 只需 docker + just」
    - 預期看到資訊(依序:svg 總數、含 foreignObject 的、含 mxfile 的、README 引用、流程圖措辭)
      ```text
      svg=3
      foreignobject=0
      mxfile=3
      readme=4
      flow-wording=1
      ```
    - 驗收方式
      ```bash
      printf 'svg=%s\n' "$(find doc/diagram -maxdepth 1 -name '*.drawio.svg' | wc -l)"
      printf 'foreignobject=%s\n' "$(grep -l '<foreignObject' doc/diagram/*.drawio.svg | wc -l)"
      printf 'mxfile=%s\n' "$(grep -l 'content="&lt;mxfile' doc/diagram/*.drawio.svg | wc -l)"
      printf 'readme=%s\n' "$(grep -c 'doc/diagram/.*\.drawio\.svg' README.md)"
      printf 'flow-wording=%s\n' "$(grep -c 'host 只需 docker + just' doc/diagram/flow.drawio.svg)"
      ```
  - [ ] 4.2 GitHub 上看得到圖(人類):開 https://github.com/ycpss91255/worktool#架構與流程,三張圖有文字、無 "Text is not SVG"

- [ ] 5. 實機(需要 host 有 distrobox + ghostty;會建 `dev` 盒、並動到你真實 HOME 的 ghostty / worktool 設定。**安全約定**:5.1 與 5.2 都先斷言同名 `dev` 盒不存在,存在就拒絕而不刪(#176 item 1),並且只刪除自己建立的盒子 —— 所有權標記在 `just box assemble` **之前**就寫下,標記的意思是「這一輪動過 assemble」,所以建盒與記錄之間被中斷不會留下無主的盒子(round 10);5.2 備份用 `cp -a`,symlink 連同它指到的檔案一起備份、一起還原(#176 item 2);清理失敗一律讓整段回非 0(#176 item 4)。host 沒有 ghostty 就無法完成 5.2,該項保持未勾)
  - [ ] 5.1 進盒延遲 < 300 ms(以 fish 為準);由本區塊自己把三行數字發到 #22,再依留言 id 讀回來比對本輪識別碼與三行數字;中斷(Ctrl-C)與正常結束都會清掉自己建立的盒子,清不掉就失敗
    - 預期看到資訊(assemble 的輸出略;數字是你機器的實測,`run` 每次不同)
      ````text
      preexisting-dev=0
      enter: min=136.1 median=171.1 max=197.0 ms
      shell: min=143.8 median=176.9 max=215.5 ms
      inbox: min=14.9 median=17.5 max=25.4 ms
      [INFO] shell median 176.9 ms within --max-ms 300
      rc=0
      posted=1 comment=<id> run=m3-51-20260928T112604Z-<pid>
      cleanup-rc=0
      ````
      (`posted=1` 的判準有三個,缺一不可:那則留言在 #22 上、帶本輪 `run` 識別碼、而且**逐字**含本輪量到的三行。舊留言再像也命不中(#176 item 3);上一版用 `?per_page=100` 不翻頁,#22 留言超過 100 則之後會無故變紅,改成依 id 直接取那一則就沒有這個問題。`cleanup-rc=1` 會讓整段 exit 非 0 並要你手動移除盒子。所有權標記在 `just box assemble` **之前**就寫下,意思是「這一輪動過 assemble」而不是「assemble 成功了」,所以 assemble 跑到一半被 Ctrl-C 一樣會清;反過來「標記在、盒子不在」是被接受的,清理只看最後盒子還在不在,`distrobox rm` 沒東西可刪不算失敗(round 10))
    - 驗收方式
      ````bash
      (
        set -u
        REPO=ycpss91255/worktool; ISSUE=22; BOX=dev
        TAG='M3 5.1 實機 bench'
        RUN_ID="m3-51-$(date -u +%Y%m%dT%H%M%SZ)-$$"
        fence='```'

        fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
        for c in distrobox just gh jq mktemp; do
          command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
        done

        # 0 = box exists, 1 = box does not exist, 2 = cannot tell (never guess)
        box_exists() {
          local out
          out=$(distrobox list 2>/dev/null) || return 2
          printf '%s\n' "$out" | awk -F'|' -v want="$1" '
            NR > 1 { n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n); if (n == want) f = 1 }
            END { exit(f ? 0 : 1) }'
        }

        # refuse before creating; never delete a box this run did not create
        box_exists "$BOX"; e=$?
        [ "$e" -eq 2 ] && fail "distrobox list failed -- cannot tell whether '$BOX' exists; refusing to create or delete anything"
        [ "$e" -eq 0 ] && fail "a distrobox named '$BOX' already exists -- refusing. This block deletes the box it creates, so rename or remove yours by hand first."
        printf 'preexisting-dev=0\n'

        W=$(mktemp -d "${TMPDIR:-/tmp}/wt-m3-51.XXXXXXXX") || fail "mktemp failed"
        [ -d "$W" ] || fail "mktemp returned '$W', which is not a directory"

        # CREATED means "assemble was ATTEMPTED", not "assemble returned 0":
        # it is set before the call, so an interrupt anywhere inside assemble
        # still hands cleanup the box. The price is a marker with no box,
        # which is the safe direction and which cleanup tolerates below.
        CREATED=0; CLEAN_RC=0
        cleanup() {
          st=$?
          trap - EXIT INT TERM HUP
          if [ "$CREATED" -eq 1 ]; then
            # rm legitimately fails when there is nothing to remove (interrupted
            # before the box existed), so only the final state decides
            distrobox rm -f "$BOX" >/dev/null 2>&1
            box_exists "$BOX"; ge=$?
            [ "$ge" -eq 1 ] || CLEAN_RC=1
          fi
          printf 'cleanup-rc=%s\n' "$CLEAN_RC"
          [ "$CLEAN_RC" -eq 0 ] || printf "[FAIL] box '%s' survived cleanup -- remove it by hand\n" "$BOX" >&2
          rm -rf "$W"
          # a failed cleanup fails the whole block
          [ "$st" -eq 0 ] || exit "$st"
          exit "$CLEAN_RC"
        }
        trap cleanup EXIT INT TERM HUP   # Ctrl-C also cleans up

        CREATED=1                       # claim ownership BEFORE the box can exist
        just box assemble >/dev/null || fail "just box assemble failed"
        box_exists "$BOX" || fail "assemble returned 0 but box '$BOX' is not listed"

        just box bench --runs 10 --shell 'fish -c exit' --max-ms 300 | tee "$W/bench.txt"
        brc=${PIPESTATUS[0]}
        printf 'rc=%s\n' "$brc"
        [ "$brc" -eq 0 ] || fail "just box bench exited $brc"

        grep -E '^(enter|shell|inbox): min=[0-9.]+ median=[0-9.]+ max=[0-9.]+ ms$' \
          "$W/bench.txt" >"$W/three.txt" || true
        n=$(wc -l <"$W/three.txt"); k=$(cut -d: -f1 "$W/three.txt" | sort -u | wc -l)
        { [ "$n" -eq 3 ] && [ "$k" -eq 3 ]; } || fail "expected one enter/shell/inbox line each, got n=$n distinct=$k"

        # publish from this run, then verify that exact comment by id
        { printf '%s (%s, run %s)\n\n' "$TAG" "$(uname -sm)" "$RUN_ID"
          printf '%stext\n' "$fence"; cat "$W/three.txt"; printf '%s\n' "$fence"; } >"$W/body.md"
        url=$(gh issue comment "$ISSUE" --repo "$REPO" --body-file "$W/body.md") || fail "gh issue comment failed"
        cid=${url##*-}
        case "$cid" in '' | *[!0-9]*) fail "cannot parse a comment id out of '$url'" ;; esac
        gh api "repos/$REPO/issues/comments/$cid" >"$W/posted.json" || fail "re-reading comment $cid failed"
        posted=$(jq -r --arg rid "$RUN_ID" --arg tag "$TAG" --arg iss "$ISSUE" --rawfile three "$W/three.txt" '
            ($three | rtrimstr("\n") | split("\n")) as $lines
            | if (.issue_url | endswith("/issues/" + $iss))
                 and (.body | contains($tag)) and (.body | contains($rid))
                 and ([$lines[] as $l | (.body | contains($l))] | all)
              then 1 else 0 end' "$W/posted.json")
        printf 'posted=%s comment=%s run=%s\n' "$posted" "$cid" "$RUN_ID"
        [ "$posted" = 1 ] || fail "comment $cid on #$ISSUE does not carry run id $RUN_ID plus the three lines measured above"
      )
      ````
  - [ ] 5.2 開終端即在盒內的 fish(**只剩主觀感受**:整條鏈已由 2.3 在 CI 內自動驗證;這裡只確認你自己的機器上開窗順不順):三步驟依序貼上,步驟 3 可在任何 shell 單獨貼、也是中斷後的還原手段
    - 預期看到資訊(步驟 1 備份摘要;步驟 2 套用;新視窗內三行;步驟 3 還原)
      ```text
      ghostty=regular
      ghostty.sha=<sha256>
      worktool=absent-dir
      backup=/tmp/worktool-m3-52-backup.1000 ok=1
      revalidate=1
      preexisting-dev=0
      (just box setup / just box status 的輸出,格式同 3.2,只是對象是你真實的 HOME)
      setup-rc=0
      /run/.containerenv
      fish
      main
      restore-rc=0
      restore-ok=1
      blocks=0
      leftover-dirs=0
      dev-gone=1
      backup-removed=1
      ```
      (每個名字先印一行狀態:`regular` = 原本就有那個普通檔、`symlink` = 原本是連結(連同它指到的檔案一起備份)、`absent-file` = 目錄在但沒有檔、`absent-dir` = 連目錄都沒有;狀態行後面還有幾行明細,行數隨狀態而異 —— `regular` 多一行 `<名字>.sha=`(上面就是這種),`symlink` 多三行 `<名字>.link=` / `<名字>.tpath=` / `<名字>.tsha=`(連結指到的檔也備份了),兩種 `absent` 則沒有明細行。所以你的 HOME 是連結時,步驟 1 會比上面多印兩行,那是對的(round 11)。步驟 2 只信任**已發布到磁碟的 manifest**,不信任步驟 1 留下的 shell 變數(#176 item 6),而且會重新比對 sha256:步驟 1 之後檔案被動過就拒絕套用。備份路徑帶 uid,多人共用主機不會互撞;`mkdir -m 700` 遇到既有目錄或預埋的 symlink 直接拒絕。`restore-ok=1` 才刪備份;失敗會保留備份讓你修好再貼一次步驟 3;還原成功後再貼一次只會印 `no-backup=1`。`dev-gone` 只在**這一輪動過 assemble** 時才出現,沒動過是 `dev-untouched=1`;`dev-gone=0` 讓整段回非 0。所有權標記 `created-box` 寫在 `just box assemble` **之前**,所以 assemble 跑到一半被中斷、盒子沒建起來,步驟 3 一樣認得這一輪、一樣印 `dev-gone=1`(`distrobox rm` 沒東西可刪不算失敗,只看盒子最後在不在);步驟 2 從宣告所有權那一刻起也有 trap,中斷時會多印一行 `incomplete=1 (run step 3 now: ...)` 到 stderr,提醒你立刻貼步驟 3 —— 真正還原的一律是步驟 3,因為那時設定可能已經套用,只拆盒子只還原了一半(round 10))
    - 驗收方式
      ```bash
      # 步驟 1) 備份真實設定。備份目錄已存在、或備份中途失敗,都完全不動任何檔案
      (
        set -u
        C=${XDG_CONFIG_HOME:-$HOME/.config}
        B=${TMPDIR:-/tmp}/worktool-m3-52-backup.$(id -u)
        NAMES='ghostty worktool'

        wt_type() { # regular | symlink | absent | other   (-L first: a dangling link is still a link)
          if [ -L "$1" ]; then echo symlink
          elif [ ! -e "$1" ]; then echo absent
          elif [ -f "$1" ]; then echo regular
          else echo other; fi
        }
        wt_sha() { sha256sum "$1" | cut -d' ' -f1; }

        # refuse if a previous run left a backup; never write into a dir we did not create
        if ! mkdir -m 700 "$B" 2>/dev/null; then
          printf 'backup=%s ok=0\n' "$B"
          printf '[FAIL] backup dir already exists: %s -- run step 3 to restore from it, confirm clean, then re-run step 1\n' "$B" >&2
          exit 1
        fi
        if ! { [ -d "$B" ] && [ ! -L "$B" ] && [ -O "$B" ]; }; then
          printf '[FAIL] %s is not a directory we own\n' "$B" >&2
          exit 1
        fi
        # until the manifest is published nothing has been applied, so a failed step 1 self-cleans
        trap 'rm -rf "$B"; printf "backup=%s ok=0\n" "$B"' EXIT INT TERM HUP

        : >"$B/manifest.partial"
        for n in $NAMES; do
          p="$C/$n/config"
          case "$(wt_type "$p")" in
          regular)
            # cp -a = -dR --preserve=all, so mode/mtime survive and links are NOT dereferenced
            cp -a "$p" "$B/$n.config" || { printf '[FAIL] %s: backup copy failed\n' "$n" >&2; exit 1; }
            printf '%s=regular\n%s.sha=%s\n' "$n" "$n" "$(wt_sha "$B/$n.config")" >>"$B/manifest.partial"
            ;;
          symlink)
            cp -a "$p" "$B/$n.config" || { printf '[FAIL] %s: backup copy failed\n' "$n" >&2; exit 1; }
            [ "$(wt_type "$B/$n.config")" = symlink ] ||
              { printf '[FAIL] %s: the backup is not a symlink -- refusing to continue\n' "$n" >&2; exit 1; }
            [ "$(readlink "$B/$n.config")" = "$(readlink "$p")" ] ||
              { printf '[FAIL] %s: backup link target differs from the original\n' "$n" >&2; exit 1; }
            printf '%s=symlink\n%s.link=%s\n' "$n" "$n" "$(readlink "$p")" >>"$B/manifest.partial"
            # today setup REPLACES the link with a regular file, but a future one
            # could write through it, so back the pointed-to file up either way
            if [ -e "$p" ]; then
              tp=$(readlink -f "$p") || { printf '[FAIL] %s: cannot resolve the link target\n' "$n" >&2; exit 1; }
              [ -f "$tp" ] || { printf '[FAIL] %s: link target %s is not a regular file -- handle it by hand\n' "$n" "$tp" >&2; exit 1; }
              cp -a "$tp" "$B/$n.target" || { printf '[FAIL] %s: backing up the link target failed\n' "$n" >&2; exit 1; }
              printf '%s.tpath=%s\n%s.tsha=%s\n' "$n" "$tp" "$n" "$(wt_sha "$B/$n.target")" >>"$B/manifest.partial"
            else
              printf '%s.tpath=\n' "$n" >>"$B/manifest.partial"   # dangling link: nothing behind it
            fi
            ;;
          absent)
            if [ -d "$C/$n" ]; then printf '%s=absent-file\n' "$n" >>"$B/manifest.partial"
            else printf '%s=absent-dir\n' "$n" >>"$B/manifest.partial"; fi
            ;;
          other)
            printf '[FAIL] %s: %s is neither a regular file nor a symlink -- handle it by hand\n' "$n" "$p" >&2
            exit 1
            ;;
          esac
        done

        for n in $NAMES; do
          [ "$(grep -cE "^$n=(regular|symlink|absent-file|absent-dir)\$" "$B/manifest.partial")" -eq 1 ] ||
            { printf '[FAIL] %s: manifest does not have exactly one state line\n' "$n" >&2; exit 1; }
        done
        mv "$B/manifest.partial" "$B/manifest" || { printf '[FAIL] publishing the manifest failed\n' >&2; exit 1; }
        trap - EXIT INT TERM HUP

        cat "$B/manifest"
        printf 'backup=%s ok=1\n' "$B"
      )
      ```

      ```bash
      # 步驟 2) 重新驗證磁碟上的 manifest,再套用;之後開一個新的 ghostty 視窗
      (
        set -u
        C=${XDG_CONFIG_HOME:-$HOME/.config}
        B=${TMPDIR:-/tmp}/worktool-m3-52-backup.$(id -u)
        NAMES='ghostty worktool'
        BOX=dev

        wt_type() {
          if [ -L "$1" ]; then echo symlink
          elif [ ! -e "$1" ]; then echo absent
          elif [ -f "$1" ]; then echo regular
          else echo other; fi
        }
        wt_sha() { sha256sum "$1" | cut -d' ' -f1; }
        wt_field() { grep -E "^$2=" "$1/manifest" | head -1 | cut -d= -f2-; }
        wt_bad() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

        # trust the published manifest on disk, never the $ok variable from step 1
        [ -f "$B/manifest" ] || wt_bad "no published manifest at $B/manifest -- step 1 did not finish; nothing applied"
        [ -e "$B/manifest.partial" ] && wt_bad "$B/manifest.partial still present -- step 1 is half-done"
        for n in $NAMES; do
          [ "$(grep -cE "^$n=(regular|symlink|absent-file|absent-dir)\$" "$B/manifest")" -eq 1 ] ||
            wt_bad "$n: manifest does not have exactly one state line"
        done
        for n in $NAMES; do
          p="$C/$n/config"; bp="$B/$n.config"; s=$(wt_field "$B" "$n")
          case "$s" in
          regular)
            [ "$(wt_type "$bp")" = regular ] || wt_bad "$n: the backup is not a regular file"
            [ "$(wt_type "$p")" = regular ] || wt_bad "$n: live config is no longer a regular file"
            [ "$(wt_sha "$bp")" = "$(wt_field "$B" "$n.sha")" ] || wt_bad "$n: backup does not match its manifest checksum"
            [ "$(wt_sha "$bp")" = "$(wt_sha "$p")" ] || wt_bad "$n: live config changed since step 1 -- re-run step 3 then step 1"
            ;;
          symlink)
            [ "$(wt_type "$bp")" = symlink ] || wt_bad "$n: the backup did not preserve the symlink"
            [ "$(wt_type "$p")" = symlink ] || wt_bad "$n: live config is no longer a symlink"
            [ "$(readlink "$bp")" = "$(wt_field "$B" "$n.link")" ] || wt_bad "$n: backup link target differs from the manifest"
            [ "$(readlink "$p")" = "$(wt_field "$B" "$n.link")" ] || wt_bad "$n: live link target changed since step 1"
            tp=$(wt_field "$B" "$n.tpath")
            if [ -n "$tp" ]; then
              [ "$(wt_type "$B/$n.target")" = regular ] || wt_bad "$n: the link target was not backed up"
              [ "$(wt_sha "$B/$n.target")" = "$(wt_field "$B" "$n.tsha")" ] || wt_bad "$n: target backup does not match its manifest checksum"
              [ -f "$tp" ] || wt_bad "$n: link target $tp disappeared since step 1"
              [ "$(wt_sha "$tp")" = "$(wt_field "$B" "$n.tsha")" ] || wt_bad "$n: link target $tp changed since step 1"
            else
              [ ! -e "$p" ] || wt_bad "$n: manifest recorded a dangling link but it resolves now"
            fi
            ;;
          absent-file)
            { [ ! -e "$bp" ] && [ ! -L "$bp" ]; } || wt_bad "$n: manifest says absent-file but a backup file exists"
            [ -d "$C/$n" ] || wt_bad "$n: config dir vanished since step 1"
            [ "$(wt_type "$p")" = absent ] || wt_bad "$n: a config appeared since step 1"
            ;;
          absent-dir)
            { [ ! -e "$bp" ] && [ ! -L "$bp" ]; } || wt_bad "$n: manifest says absent-dir but a backup file exists"
            [ ! -e "$C/$n" ] || wt_bad "$n: config dir appeared since step 1"
            ;;
          *) wt_bad "$n: unknown manifest state '$s'" ;;
          esac
        done
        printf 'revalidate=1\n'

        # refuse a box this run did not create; record what we do create so step 3 can undo exactly that
        box_exists() {
          local out
          out=$(distrobox list 2>/dev/null) || return 2
          printf '%s\n' "$out" | awk -F'|' -v want="$1" '
            NR > 1 { n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n); if (n == want) f = 1 }
            END { exit(f ? 0 : 1) }'
        }
        box_exists "$BOX"; e=$?
        [ "$e" -eq 2 ] && wt_bad "distrobox list failed -- cannot tell whether '$BOX' exists"
        [ "$e" -eq 0 ] && wt_bad "a distrobox named '$BOX' already exists -- refusing. Step 3 deletes the box this run creates, so rename or remove yours by hand first."
        printf 'preexisting-dev=0\n'

        # From here on this run owns a box, so an interrupt has to be
        # survivable. Two halves: the marker on disk (step 3 reads it in a
        # fresh shell) and this trap (it tells a human at the terminal).
        # Step 3 remains the only thing that undoes anything -- the config
        # may already be applied by then, and it restores both.
        CREATED=0
        interrupted() {
          st=$?
          trap - EXIT INT TERM HUP
          { [ "$CREATED" -eq 1 ] && [ "$st" -ne 0 ]; } &&
            printf 'incomplete=1 (run step 3 now: it restores the config and removes the box this run created)\n' >&2
          exit "$st"
        }
        trap interrupted EXIT INT TERM HUP

        # marker BEFORE assemble: it means "assemble was attempted", so an
        # interrupt inside assemble still leaves step 3 able to clean up
        CREATED=1; : >"$B/created-box"            # persisted so step 3 works in a fresh shell
        just box assemble >/dev/null || wt_bad "just box assemble failed"
        box_exists "$BOX" || wt_bad "assemble returned 0 but box '$BOX' is not listed"
        just box setup || wt_bad "just box setup failed -- run step 3 to restore"
        just box status || wt_bad "just box status failed -- run step 3 to restore"
        printf 'setup-rc=0\n'
      )
      ```

      ```bash
      # 新的 ghostty 視窗裡跑這三行(主觀:開窗到提示字元無明顯延遲)
      ls /run/.containerenv; ps -p $fish_pid -o comm=; tmux display -p '#S'
      ```

      ```bash
      # 步驟 3) 還原 -- 可在任何 shell 單獨執行,中斷後也用這段;沒有備份時什麼都不動
      (
        set -u
        C=${XDG_CONFIG_HOME:-$HOME/.config}
        B=${TMPDIR:-/tmp}/worktool-m3-52-backup.$(id -u)
        NAMES='ghostty worktool'
        BOX=dev
        rc=0
        note() { printf '%s\n' "$*"; }
        bad() { printf '[FAIL] %s\n' "$*" >&2; rc=1; }

        wt_type() {
          if [ -L "$1" ]; then echo symlink
          elif [ ! -e "$1" ]; then echo absent
          elif [ -f "$1" ]; then echo regular
          else echo other; fi
        }
        wt_sha() { sha256sum "$1" | cut -d' ' -f1; }
        wt_field() { grep -E "^$2=" "$1/manifest" | head -1 | cut -d= -f2-; }

        if [ ! -d "$B" ]; then
          note "no-backup=1 ($B absent; already restored, or step 1 never ran)"
          exit 0
        fi
        if [ ! -f "$B/manifest" ]; then
          note "incomplete-backup=1 ($B has no published manifest, so step 2 never applied anything; inspect it, then: rm -rf '$B')"
          exit 1
        fi
        mv_ok=1
        for n in $NAMES; do
          [ "$(grep -cE "^$n=(regular|symlink|absent-file|absent-dir)\$" "$B/manifest")" -eq 1 ] || mv_ok=0
        done
        if [ "$mv_ok" != 1 ]; then
          note "manifest-invalid=1 ($B/manifest is not exactly one valid state line per name; restore by hand)"
          exit 1
        fi

        just box setup --auto-enter no >/dev/null 2>&1; rrc=$?
        note "restore-rc=$rrc"
        [ "$rrc" -eq 0 ] || bad "just box setup --auto-enter no exited $rrc"

        for n in $NAMES; do
          p="$C/$n/config"; bp="$B/$n.config"; s=$(wt_field "$B" "$n")
          case "$s" in
          regular | symlink)
            mkdir -p "$C/$n" || { bad "$n: cannot recreate $C/$n"; continue; }
            rm -f "$p" || { bad "$n: cannot clear $p"; continue; }   # never write through a symlink
            cp -a "$bp" "$p" || { bad "$n: restore copy failed"; continue; }
            [ "$(wt_type "$p")" = "$s" ] || bad "$n: restored as $(wt_type "$p"), expected $s"
            if [ "$s" = symlink ]; then
              [ "$(readlink "$p")" = "$(wt_field "$B" "$n.link")" ] || bad "$n: restored link points at $(readlink "$p")"
              tp=$(wt_field "$B" "$n.tpath")
              if [ -n "$tp" ]; then
                # put the pointed-to file back byte for byte, whether setup wrote
                # through the link or replaced it (cp -a on an untouched file is a no-op)
                cp -a "$B/$n.target" "$tp" || { bad "$n: restoring link target $tp failed"; continue; }
                [ "$(wt_sha "$tp")" = "$(wt_field "$B" "$n.tsha")" ] || bad "$n: link target $tp not restored byte for byte"
              fi
            else
              [ "$(wt_sha "$p")" = "$(wt_field "$B" "$n.sha")" ] || bad "$n: restored content checksum mismatch"
            fi
            ;;
          absent-file)
            rm -f "$p" || bad "$n: cannot remove $p"
            [ "$(wt_type "$p")" = absent ] || bad "$n: $p still present"
            ;;
          absent-dir)
            rm -f "$p" || bad "$n: cannot remove $p"
            rmdir "$C/$n" 2>/dev/null
            [ ! -e "$C/$n" ] || bad "$n: $C/$n still present (not empty?)"
            ;;
          esac
        done
        if [ "$rc" -eq 0 ]; then note "restore-ok=1"; else note "restore-ok=0"; fi

        b=0
        if [ "$(wt_type "$C/ghostty/config")" != absent ]; then
          b=$(grep -c 'BEGIN worktool managed block' "$C/ghostty/config" 2>/dev/null) || b=0
        fi
        note "blocks=$b"
        [ "$b" -eq 0 ] || bad "worktool managed block still present in $C/ghostty/config"

        lo=0
        for n in $NAMES; do grep -qx "$n=absent-dir" "$B/manifest" && [ -e "$C/$n" ] && lo=$((lo + 1)); done
        note "leftover-dirs=$lo"
        [ "$lo" -eq 0 ] || bad "directories that did not exist before are still there"

        # Only remove a box this run created, and a failed removal fails the
        # block. The marker says step 2 STARTED assemble, so it can outlive an
        # interrupt that left no box: `distrobox rm` failing is expected then,
        # and only the existence check below decides (round 10).
        box_exists() {
          local out
          out=$(distrobox list 2>/dev/null) || return 2
          printf '%s\n' "$out" | awk -F'|' -v want="$1" '
            NR > 1 { n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n); if (n == want) f = 1 }
            END { exit(f ? 0 : 1) }'
        }
        if [ -e "$B/created-box" ]; then
          distrobox rm -f "$BOX" >/dev/null 2>&1
          box_exists "$BOX"; e=$?
          if [ "$e" -eq 1 ]; then note "dev-gone=1"; rm -f "$B/created-box"
          else note "dev-gone=0"; bad "box '$BOX' created by this run is still there (or distrobox list failed) -- remove it by hand"; fi
        else
          note "dev-untouched=1 (this run never created a box; leaving every box alone)"
        fi

        if [ "$rc" -eq 0 ]; then rm -rf "$B"; note "backup-removed=1"
        else note "backup kept at $B -- fix the errors above and re-run step 3"; fi
        exit "$rc"
      )
      ```
  - [ ] 5.3 負向:**先建一個同名 `dev` 盒**,證明 5.1 與 5.2 步驟 2 拒絕而不是刪掉它(#176 item 1 的負向測試;最後自己手動移除那個盒)
    - 預期看到資訊(兩段各自拒絕,盒子從頭到尾都在)
      ```text
      preexisting=dev
      [FAIL] a distrobox named 'dev' already exists -- refusing. This block deletes the box it creates, so rename or remove yours by hand first.
      51-rc=1
      ghostty=regular
      ghostty.sha=<sha256>
      worktool=absent-dir
      backup=/tmp/worktool-m3-52-backup.1000 ok=1
      revalidate=1
      [FAIL] a distrobox named 'dev' already exists -- refusing. Step 3 deletes the box this run creates, so rename or remove yours by hand first.
      52-rc=1
      restore-rc=0
      restore-ok=1
      blocks=0
      leftover-dirs=0
      dev-untouched=1 (this run never created a box; leaving every box alone)
      backup-removed=1
      still-there=dev
      ```
      (5.1 在 `just box assemble` 之前就拒絕,所以沒有 `preexisting-dev=0`、也沒有 `cleanup-rc`;`51-rc=1` 與 `revalidate=1` 中間那四行是 5.2 步驟 1 自己的備份摘要(它照樣跑完、照樣印),形狀跟 5.2 一樣隨你的 HOME 而異 —— 上面示範的是 `regular` + `absent-dir`,round 11 之前漏列了這四行;5.2 步驟 2 在 `revalidate=1` 之後、`just box assemble` 之前拒絕,你的設定沒被動過。步驟 3 仍然跑完整條還原流程 —— 六行和 5.2 正常路徑一樣,只是 `dev-gone=1` 換成 `dev-untouched=1`,因為這一輪沒有建過盒。全程沒有任何 `distrobox rm`)
    - 驗收方式
      ```bash
      distrobox create --name dev --image ubuntu:24.04 --yes >/dev/null
      distrobox list | awk -F'|' 'NR>1 { n=$2; gsub(/^[ \t]+|[ \t]+$/,"",n); if (n=="dev") print "preexisting=" n }'
      ```
      ```bash
      # 原樣貼上 5.1 的整段,緊接著貼這一行
      echo 51-rc=$?
      ```
      ```bash
      # 原樣貼上 5.2 的步驟 1、再貼步驟 2,緊接著貼這一行
      echo 52-rc=$?
      ```
      ```bash
      # 再貼一次 5.2 的步驟 3 把備份收掉(它印 dev-untouched=1,不動任何盒子),然後確認盒子還在並手動移除
      distrobox list | awk -F'|' 'NR>1 { n=$2; gsub(/^[ \t]+|[ \t]+$/,"",n); if (n=="dev") print "still-there=" n }'
      distrobox rm -f dev
      ```

- [ ] 6. CI 與流程(gh / grep 查外部證據)
  - [ ] 6.1 一個 sub-issue 一個 PR、兩架構 CI:10 個 PR 各恰好一行 `Closes #`(互不相同);每個 PR 有 checks 且全 pass;#153 起每個 PR 同時有 amd64(ubuntu-latest)與 arm64(ubuntu-24.04-arm)的 check 且數量相等
    - 預期看到資訊
      ```text
      #152 total=8 nonpass=0 amd=0 arm=0 closes=1 issue=#151
      #153 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#149
      #154 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#150
      #155 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#21
      #156 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#23
      #165 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#164
      #166 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#163
      #167 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#160
      #168 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#161
      #169 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#162
      distinct=10
      rc=0
      ```
      (任何一次 gh 查詢失敗、或任何欄位不符 —— total=0 / nonpass>0 / closes!=1 / #153 起 amd 與 arm 不相等 —— rc 都是 1)
    - 驗收方式
      ```bash
      (
        fail=0; seen=""
        for n in 152 153 154 155 156 165 166 167 168 169; do
          c=$(gh pr checks "$n" --repo ycpss91255/worktool --json name,bucket) &&
          b=$(gh pr view "$n" --repo ycpss91255/worktool --json body --jq .body) || { echo "#$n gh-failed"; fail=1; continue; }
          t=$(jq 'length' <<<"$c"); np=$(jq '[.[] | select(.bucket != "pass")] | length' <<<"$c")
          amd=$(jq '[.[].name | select(test("ubuntu-latest"))] | length' <<<"$c")
          arm=$(jq '[.[].name | select(test("ubuntu-24.04-arm"))] | length' <<<"$c")
          cl=$(grep -c '^Closes #' <<<"$b"); is=$(grep -o '^Closes #[0-9]*' <<<"$b" | cut -d' ' -f2 | tr '\n' ',' | sed 's/,$//')
          printf '#%s total=%s nonpass=%s amd=%s arm=%s closes=%s issue=%s\n' "$n" "$t" "$np" "$amd" "$arm" "$cl" "$is"
          seen="$seen $is"
          { [ "$t" -gt 0 ] && [ "$np" -eq 0 ] && [ "$cl" -eq 1 ] && [ -n "$is" ]; } || fail=1
          [ "$n" = 152 ] || { [ "$amd" -gt 0 ] && [ "$amd" -eq "$arm" ]; } || fail=1
        done
        d=$(tr ' ' '\n' <<<"$seen" | grep '^#[0-9]' | sort -u | grep -c .); printf 'distinct=%s\n' "$d"
        [ "$fail" -eq 0 ] && [ "$d" -eq 10 ] || exit 1
      ); echo rc=$?
      ```
  - [ ] 6.2 決策與研究都在 issue 上,且是具體結論:#22 的 [claude] 留言有實測 `median=.. ms` 與「維持 docker + 預設 runc」;#148 有「只用 LTS」與「ubuntu-24.04-arm」;#21 有「預設 = 直接進盒」與「印 log」
    - 預期看到資訊(每行數字 >= 1)
      ```text
      #22 median-ms:1 runc:1
      #148 lts-only:1 arm-runner:1
      #21 default-enter:1 log:1
      rc=0
      ```
      (查詢用 `--paginate`:留言超過 100 則之後才不會因為只看第一頁而漏掉。任何一格不是 `1`、或任何一次 `gh` 查詢失敗(該格印 `gh-failed`)都讓整段 `rc=1` —— 舊版把 `gh` 的失敗當成「找不到」而印 `0` 卻仍 rc=0,和 2.2 / 6.1 / 6.3 的 fail-closed 不一致)
    - 驗收方式
      ```bash
      (
        # 1 = 找到、0 = 沒找到、gh-failed = 查詢本身失敗;三者只有 1 算過
        c() {
          local body n
          body=$(gh api "repos/ycpss91255/worktool/issues/$1/comments" --paginate \
                   --jq '.[].body | select(startswith("[claude]"))') || { echo gh-failed; return; }
          n=$(printf '%s\n' "$body" | grep -c "$2")
          [ "$n" -ge 1 ] && echo 1 || echo 0
        }
        a=$(c 22 'median=[0-9][0-9]*\(\.[0-9][0-9]*\)\? ms'); b=$(c 22 '維持 docker + 預設 runc')
        d=$(c 148 '只用 LTS'); e=$(c 148 'ubuntu-24.04-arm')
        f=$(c 21 '預設 = 直接進盒'); g=$(c 21 '印 log')
        echo "#22 median-ms:$a runc:$b"
        echo "#148 lts-only:$d arm-runner:$e"
        echo "#21 default-enter:$f log:$g"
        for v in "$a" "$b" "$d" "$e" "$f" "$g"; do [ "$v" = 1 ] || exit 1; done
      ); echo rc=$?
      ```
  - [ ] 6.3 codex:#156、#165-#169 的最後一則 [codex] 留言判定行是「可合併」;#152-#155 是配額恢復後的補複驗,最後一則 [codex] 判定「不可合併」,各自的阻擋項記錄在 follow-up issue(#163 / #164 / #162 / #161,由原 PR 上的 [claude] 留言指向),而修正該 issue 的 PR(#166 / #165 / #169 / #168)必須 Closes 正是那個 issue,且該 PR 自己的最後 [codex] 判定「可合併」
    - 預期看到資訊
      ```text
      #156 mergeable
      #165 mergeable
      #166 mergeable
      #167 mergeable
      #168 mergeable
      #169 mergeable
      #152 blocked -> follow-up #163 fixed-by PR #166 (closes #163, mergeable) ok
      #153 blocked -> follow-up #164 fixed-by PR #165 (closes #164, mergeable) ok
      #154 blocked -> follow-up #162 fixed-by PR #169 (closes #162, mergeable) ok
      #155 blocked -> follow-up #161 fixed-by PR #168 (closes #161, mergeable) ok
      rc=0
      ```
      (失敗時的樣子:判定不符是 `NOT` 或行尾 `BAD`,查不到對應關係是 `#N no-follow-up` / `#N no-fix-pr`,最後都 `rc=1`)
    - 驗收方式
      ```bash
      v() { gh api "repos/ycpss91255/worktool/issues/$1/comments" --paginate --jq '[.[].body | select(startswith("[codex]"))] | last' | grep -E '^(可合併|不可合併|mergeable|blocked)' | tail -1; }
      (
        fail=0
        for n in 156 165 166 167 168 169; do printf '#%s ' "$n"; v "$n" | grep -q '^可合併\|^mergeable' && echo mergeable || { echo NOT; fail=1; }; done
        for n in 152 153 154 155; do
          fus=$(gh api "repos/ycpss91255/worktool/issues/$n/comments" --paginate --jq '.[].body | select(startswith("[claude]"))' | grep -o 'follow-up issue #[0-9]*' | grep -o '[0-9]*' | sort -u)
          fu=$(head -1 <<<"$fus"); [ -n "$fu" ] || { printf '#%s no-follow-up\n' "$n"; fail=1; continue; }
          prs=$(gh pr list --repo ycpss91255/worktool --state merged --search "Closes #$fu in:body" --json number,body --jq ".[] | select(.body | test(\"^Closes #$fu\\\\b\"; \"m\")) | .number")
          pr=$(head -1 <<<"$prs"); [ -n "$pr" ] || { printf '#%s no-fix-pr\n' "$n"; fail=1; continue; }
          orig=$(v "$n" | grep -q '^不可合併' && echo blocked || echo UNEXPECTED)
          fix=$(v "$pr" | grep -q '^可合併\|^mergeable' && echo mergeable || echo NOT)
          ok=BAD
          { [ "$orig" = blocked ] && [ "$fix" = mergeable ] && [ "$(grep -c '[0-9]' <<<"$fus")" -eq 1 ] && [ "$(grep -c '[0-9]' <<<"$prs")" -eq 1 ]; } && ok=ok || fail=1
          printf '#%s %s -> follow-up #%s fixed-by PR #%s (closes #%s, %s) %s\n' "$n" "$orig" "$fu" "$pr" "$fu" "$fix" "$ok"
        done
        exit "$fail"
      ); echo rc=$?
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

- 自動:release 前 CI 全綠。
- 人類:全清單通過 + 明確的 RELEASE 同意(唯一需人類同意的 release)。
