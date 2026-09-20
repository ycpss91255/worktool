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

## M3 終端自動進盒 + 效能達標(審核中)

人類 gate 用的驗收清單(= M3 驗收 PR 的描述;逐項勾選,有差異回 PR 留言):

### 通用指令

前提:host 有 docker(可 `--privileged`)與 just;1-4、6 不需 distrobox;5(實機)需要 host 有 distrobox 與 ghostty。
本 PR 只改 `doc/acceptance.md`;要驗的程式全在 main。想順便看本 PR 的清單差異就 checkout 本 PR 分支。

```bash
git clone https://github.com/ycpss91255/worktool.git && cd worktool   # main 已含 M3 全部 sub-issue PR(#152-#156、#165-#169)
just --version && docker info >/dev/null && echo prereq-ok
```

```text
just 1.53.0        (版本不限)
prereq-ok
```

### 驗收項目

規則:1-4 全部 `just`;5 是實機(distrobox 原生 + 開終端主觀);6 用 gh / grep 查外部證據。每個「驗收方式」區塊都可單獨複製執行(自己建立 / 清理臨時目錄)。

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
      [ci]   required specs OK (N case(s) declared by M file(s))
      ...(unit / integration / system / acceptance 各層 1..N 全部 ok,各以 `[ci] <tier> bats OK` 結尾)
      ok N real engine: distrobox enter dev -- tmux -V prints a tmux version (auto-enter prerequisite)
      ok N real engine: distrobox enter dev -- fish --version prints a fish version (auto-enter prerequisite)
      # bench: enter: min=.. median=.. max=.. ms
      # bench: shell: min=.. median=.. max=.. ms
      # bench: inbox: min=.. median=.. max=.. ms
      # bench: [INFO] shell median .. ms within --max-ms 300
      ok N real engine: bench.sh --box dev --runs 5 --warmup 2 --shell 'fish -c exit' --max-ms ENTER_MAX_MS exits 0 (enter-latency gate on fish) and prints the enter, shell and inbox metric lines
      # bench-gate: [ERROR] shell median .. ms exceeds --max-ms 1
      ok N real engine: bench.sh --box dev --runs 1 --warmup 0 --shell 'fish -c exit' --max-ms 1 exits 1 with the threshold message (the gate bites on a real box)
      [ci] system-real bats OK
      [system-real] cleanup: containers left in the nested daemon: 0
      rc=0
      ```
      (數字是你機器的實測;判準 = shell median < 300 且三行指標都在;本機實測 enter 88 / shell(fish) 101 / inbox 4.9 ms。自動測試只證明「盒內有 tmux + fish、進盒 + 起 fish < 300 ms」;「ghostty 開窗 -> 受管 command -> 盒內 tmux/fish」整條鏈需要終端模擬器,由 5.2 實機驗證)
    - 驗收方式
      ```bash
      just test; echo rc=$?
      ```
  - [ ] 2.2 TDD 證據:每個 sub-issue PR 的描述都有 RED 證據段與 GREEN 證據段 —— 一行含 RED(不含 GREEN)或 GREEN(不含 RED)的標記,且該行不在程式碼區塊內(前面的圍欄數為偶數),其後 5 行內有一個**開頭** ``` 圍欄(實際輸出),且 RED 段在 GREEN 段之前(先失敗後通過)
    - 預期看到資訊(10 行,每行 order=ok)
      ```text
      #152 order=ok
      ...
      #169 order=ok
      ```
    - 驗收方式
      ```bash
      ev() { grep -n "$2" <<<"$1" | grep -v "$3" | cut -d: -f1 | while read -r l; do nf=$(sed -n "1,${l}p" <<<"$1" | grep -c '^```'); [ $((nf % 2)) -eq 0 ] && sed -n "$((l+1)),$((l+5))p" <<<"$1" | grep -q '^```' && { echo "$l"; break; }; done | head -1; }
      for n in 152 153 154 155 156 165 166 167 168 169; do b=$(gh pr view "$n" --repo ycpss91255/worktool --json body --jq .body); r=$(ev "$b" RED GREEN); g=$(ev "$b" GREEN RED); printf '#%s order=%s\n' "$n" "$([ -n "$r" ] && [ -n "$g" ] && [ "$r" -lt "$g" ] && echo ok || echo BAD)"; done
      ```

- [ ] 3. 進盒設定:user 可選、預設直接進盒、每個決策印 log(每個區塊自建拋棄式 HOME,不動你的家目錄)
  - [ ] 3.1 dry-run 只印決策、不寫檔
    - 預期看到資訊
      ```text
      ./script/box/setup.sh "$@"
      [INFO] auto-enter: yes (default)
      [INFO] terminal: ghostty (default)
      [INFO] tmux: inside (default)
      [INFO] box: dev (default)
      [INFO] dry-run: would write <H>/.config/worktool/config
      [INFO] dry-run: would write <H>/.config/ghostty/config (managed block: command = distrobox enter dev -- tmux new -A -s main)
      rc=0
      absent
      ```
    - 驗收方式
      ```bash
      H=$(mktemp -d); mkdir -p "$H/.config/ghostty"; HOME=$H XDG_CONFIG_HOME=$H/.config just box setup --dry-run; echo rc=$?; [ -e "$H/.config/worktool/config" ] && echo written || echo absent; rm -rf "$H"
      ```
  - [ ] 3.2 真的寫入:設定檔 + ghostty 受管區塊;status 顯示來源與區塊
    - 預期看到資訊
      ```text
      ./script/box/setup.sh "$@"
      [INFO] auto-enter: yes (default)
      [INFO] terminal: ghostty (default)
      [INFO] tmux: inside (default)
      [INFO] box: dev (default)
      [INFO] wrote: <H>/.config/worktool/config
      [INFO] wrote: <H>/.config/ghostty/config (managed block: command = distrobox enter dev -- tmux new -A -s main)
      rc=0
      ./script/box/status.sh "$@"
      config: <H>/.config/worktool/config
      auto-enter: yes (default)
      terminal: ghostty (default)
      tmux: inside (default)
      box: dev (default)
      ghostty: <H>/.config/ghostty/config (managed block: present)
      tmux.conf: <H>/.tmux.conf (managed block: absent)
      rc=0
      # BEGIN worktool managed block (just box setup; do not edit)
      command = distrobox enter dev -- tmux new -A -s main
      # END worktool managed block
      ```
    - 驗收方式
      ```bash
      H=$(mktemp -d); mkdir -p "$H/.config/ghostty"; HOME=$H XDG_CONFIG_HOME=$H/.config just box setup; echo rc=$?; HOME=$H XDG_CONFIG_HOME=$H/.config just box status; echo rc=$?; cat "$H/.config/ghostty/config"; rm -rf "$H"
      ```
  - [ ] 3.3 改回 host shell:先 setup(輸出略,同 3.2)再 `--auto-enter no`:移除區塊並逐一回報(user 來源標記);受管區塊只剩零個
    - 預期看到資訊(第二次 setup 起)
      ```text
      ./script/box/setup.sh "$@"
      [INFO] auto-enter: no (user)
      [INFO] terminal: ghostty (default)
      [INFO] tmux: inside (default)
      [INFO] box: dev (default)
      [INFO] wrote: <H>/.config/worktool/config
      [INFO] removed: <H>/.config/ghostty/config (managed block: command = distrobox enter dev -- tmux new -A -s main)
      [INFO] nothing to remove: <H>/.tmux.conf (no managed block)
      rc=0
      blocks=0
      ```
    - 驗收方式
      ```bash
      H=$(mktemp -d); mkdir -p "$H/.config/ghostty"; HOME=$H XDG_CONFIG_HOME=$H/.config just box setup >/dev/null 2>&1; HOME=$H XDG_CONFIG_HOME=$H/.config just box setup --auto-enter no; echo rc=$?; printf 'blocks=%s\n' "$(grep -c 'BEGIN worktool managed block' "$H/.config/ghostty/config")"; rm -rf "$H"
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
      H=$(mktemp -d); HOME=$H XDG_CONFIG_HOME=$H/.config just box setup --bogus; echo rc=$?; printf 'files=%s\n' "$(find "$H" -type f | wc -l)"; mkdir -p "$H/.config/worktool"; for src in default user; do printf 'tmux=sideways\ntmux.source=%s\n' "$src" > "$H/.config/worktool/config"; HOME=$H XDG_CONFIG_HOME=$H/.config just box status; echo rc=$?; done; rm -rf "$H"
      ```

- [ ] 4. README 圖(draw.io,可編輯)
  - [ ] 4.1 三張 `.drawio.svg` 無 foreignObject、內嵌 mxfile;README 引用三張圖(3 個圖片 + 1 個編輯連結說明 = 4 處);流程圖測試節點寫「host 只需 docker + just」
    - 預期看到資訊
      ```text
      0
      3
      4
      1
      ```
    - 驗收方式
      ```bash
      grep -l '<foreignObject' doc/diagram/*.drawio.svg | wc -l
      grep -l 'content="&lt;mxfile' doc/diagram/*.drawio.svg | wc -l
      grep -c 'doc/diagram/.*\.drawio\.svg' README.md
      grep -c 'host 只需 docker + just' doc/diagram/flow.drawio.svg
      ```
  - [ ] 4.2 GitHub 上看得到圖(人類):開 https://github.com/ycpss91255/worktool#架構與流程,三張圖有文字、無 "Text is not SVG"

- [ ] 5. 實機(host 有 distrobox + ghostty;會建 dev 盒並改你的 ghostty 設定,可用 3.3 的方式還原)
  - [ ] 5.1 進盒延遲 < 300 ms(以 fish 為準;實機數字貼到 #22)
    - 預期看到資訊(assemble 的輸出略;最後幾行)
      ```text
      enter: min=.. median=.. max=.. ms
      shell: min=.. median=.. max=.. ms
      inbox: min=.. median=.. max=.. ms
      [INFO] shell median .. ms within --max-ms 300
      rc=0
      ```
    - 驗收方式
      ```bash
      just box assemble && just box bench --runs 10 --shell 'fish -c exit' --max-ms 300; echo rc=$?
      ```
  - [ ] 5.2 開終端即在盒內的 fish(人類主觀):`just box setup` 後開新 ghostty 視窗,在新視窗裡執行下列指令
    - 預期看到資訊(新視窗內)
      ```text
      /run/.containerenv
      fish
      main
      ```
    - 驗收方式
      ```bash
      just box setup && just box status
      # 開一個新的 ghostty 視窗,在裡面執行(三行輸出如上;主觀:開窗到提示字元無明顯延遲):
      ls /run/.containerenv; ps -p $fish_pid -o comm=; tmux display -p '#S'
      ```

- [ ] 6. CI 與流程(gh / grep 查外部證據)
  - [ ] 6.1 一個 sub-issue 一個 PR、兩架構 CI:10 個 PR 各恰好一行 `Closes #`(互不相同);每個 PR 有 checks 且全 pass;#153 起每個 PR 同時有 amd64(ubuntu-latest)與 arm64(ubuntu-24.04-arm)的 check 且數量相等
    - 預期看到資訊
      ```text
      #152 total=8 nonpass=0 amd=0 arm=0 closes=1 issue=#151
      #153 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#149
      ...(10 行;#153 起 amd=arm>0;nonpass 全 0;closes 全 1;total>0)
      #169 total=15 nonpass=0 amd=7 arm=7 closes=1 issue=#162
      distinct=10
      ```
    - 驗收方式
      ```bash
      set -o pipefail; for n in 152 153 154 155 156 165 166 167 168 169; do c=$(gh pr checks "$n" --repo ycpss91255/worktool --json name,bucket) || { echo "#$n gh-failed"; continue; }; b=$(gh pr view "$n" --repo ycpss91255/worktool --json body --jq .body) || { echo "#$n gh-failed"; continue; }; printf '#%s total=%s nonpass=%s amd=%s arm=%s closes=%s issue=%s\n' "$n" "$(jq 'length' <<<"$c")" "$(jq '[.[] | select(.bucket != "pass")] | length' <<<"$c")" "$(jq '[.[].name | select(test("ubuntu-latest"))] | length' <<<"$c")" "$(jq '[.[].name | select(test("ubuntu-24.04-arm"))] | length' <<<"$c")" "$(grep -c '^Closes #' <<<"$b")" "$(grep -o '^Closes #[0-9]*' <<<"$b" | cut -d' ' -f2 | tr '\n' ',' | sed 's/,$//')"; done | tee /tmp/m3-61.txt
      printf 'distinct=%s\n' "$(grep -o 'issue=#[0-9]*' /tmp/m3-61.txt | sort -u | wc -l)"
      ```
  - [ ] 6.2 決策與研究都在 issue 上,且是具體結論:#22 的 [claude] 留言有實測 `median=.. ms` 與「維持 docker + 預設 runc」;#148 有「只用 LTS」與「ubuntu-24.04-arm」;#21 有「預設 = 直接進盒」與「印 log」
    - 預期看到資訊(每行數字 >= 1)
      ```text
      #22 median-ms:1 runc:1
      #148 lts-only:1 arm-runner:1
      #21 default-enter:1 log:1
      ```
    - 驗收方式
      ```bash
      c() { gh api "repos/ycpss91255/worktool/issues/$1/comments?per_page=100" --jq '.[].body | select(startswith("[claude]"))' | grep -c "$2" | awk '{print ($1>=1)?1:0}'; }
      echo "#22 median-ms:$(c 22 'median=[0-9][0-9]*\(\.[0-9][0-9]*\)\? ms') runc:$(c 22 '維持 docker + 預設 runc')"
      echo "#148 lts-only:$(c 148 '只用 LTS') arm-runner:$(c 148 'ubuntu-24.04-arm')"
      echo "#21 default-enter:$(c 21 '預設 = 直接進盒') log:$(c 21 '印 log')"
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
      ```
    - 驗收方式
      ```bash
      v() { gh api "repos/ycpss91255/worktool/issues/$1/comments?per_page=100" --jq '[.[].body | select(startswith("[codex]"))] | last' | grep -E '^(可合併|不可合併|mergeable|blocked)' | tail -1; }
      for n in 156 165 166 167 168 169; do printf '#%s ' "$n"; v "$n" | grep -q '^可合併\|^mergeable' && echo mergeable || echo NOT; done
      for n in 152 153 154 155; do fus=$(gh api "repos/ycpss91255/worktool/issues/$n/comments?per_page=100" --jq '.[].body | select(startswith("[claude]"))' | grep -o 'follow-up issue #[0-9]*' | grep -o '[0-9]*' | sort -u); fu=$(head -1 <<<"$fus"); prs=$(gh pr list --repo ycpss91255/worktool --state merged --search "Closes #$fu in:body" --json number,body --jq ".[] | select(.body | test(\"^Closes #$fu\\\\b\"; \"m\")) | .number"); pr=$(head -1 <<<"$prs"); orig=$(v "$n" | grep -q '^不可合併' && echo blocked || echo UNEXPECTED); fix=$(v "$pr" | grep -q '^可合併\|^mergeable' && echo mergeable || echo NOT); ok=BAD; [ "$orig" = blocked ] && [ "$fix" = mergeable ] && [ "$(wc -l <<<"$fus")" -eq 1 ] && [ "$(wc -l <<<"$prs")" -eq 1 ] && ok=ok; printf '#%s %s -> follow-up #%s fixed-by PR #%s (closes #%s, %s) %s\n' "$n" "$orig" "$fu" "$pr" "$fu" "$fix" "$ok"; done
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
