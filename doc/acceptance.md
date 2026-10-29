# worktool 驗收清單(distrobox UX 累積驗收)

預期輸出依區塊標示為「固定判準」、「工具版本會影響的輸出」或「動態示例」。未展開為 text 區塊的行內預期輸出屬固定判準，`<...>` 佔位符先以本輪值替換；5.x 的 PID／namespace／路徑與實測延遲是動態示例，只比對各項指定的形狀與條件。固定判準只比對列出的行，不要求沒有其他診斷行。

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

輸出類型：工具版本會影響的輸出；版本／recipe 清單依現行工具，成功標記與 Usage 行依文中判準。
```text
just 1.53.0        (版本不限)
prereq-ok
```

### 驗收項目

recipe 名稱與說明以根目錄 `justfile`、`script/box/justfile.box`、`script/test/justfile.test` 為唯一來源；執行各項的 `just` 指令讀取現行清單。help 範例由 `verify_ui_spec.bats` 與真實 help 逐行比對。

規則:0-4 是 worktool 動作,一律 `just`;5 用 gh / git 查外部證據;6 用 grep 查文件;7 選做(distrobox 原生指令)。

- [ ] 0. 使用者介面:`just` 是唯一入口
  - [ ] 0.1 裸 `just` 只列 namespaces(test、box),沒有頂層動作
    - 預期看到資訊
      輸出類型：工具版本會影響的輸出；版本／recipe 清單依現行工具，成功標記與 Usage 行依文中判準。
      ```text
      （recipe 清單直接由 justfile 顯示，不另維護說明文字副本）
      ```
    - 驗收方式
      ```bash
      just
      ```
  - [ ] 0.2 namespace 清單與 help 都來自底層腳本
    - 預期看到資訊
      輸出類型：工具版本會影響的輸出；版本／recipe 清單依現行工具，成功標記與 Usage 行依文中判準。
      ```text
      （recipe 清單直接由 justfile 顯示，不另維護說明文字副本）
      ./script/test/test.sh --help
      Usage: test.sh [OPTION...]
      ./script/box/assemble.sh --help
      Usage: assemble.sh [--file <manifest>] [--home <path>] [--dry-run]
      ```
    - 驗收方式
      ```bash
      just box
      just test help 2>&1 | head -2
      just box help 2>&1 | head -2
      ```
  - [ ] 0.3 錯誤輸入不跑任何東西:未知動作 just 報錯 exit 1;未知選項腳本報錯 exit 2
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/box/assemble.sh](../script/box/assemble.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=1
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
      輸出格式與清單直接讀取 [script/test/test.sh](../script/test/test.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=0
      ```
    - 驗收方式
      ```bash
      just test lint; echo rc=$?
      ```
  - [ ] 1.2 單元:現行必要 spec 與案例全 ok、無 skip
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/test/test.sh](../script/test/test.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
      ```text
      ok 1 ...
      rc=0
      ```
    - 驗收方式
      ```bash
      just test unit; echo rc=$?
      ```
  - [ ] 1.3 整合:mock distrobox 逐參數記錄,無效清單絕不呼叫 distrobox
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/test/test.sh](../script/test/test.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=0
      ```
    - 驗收方式
      ```bash
      just test integration; echo rc=$?
      ```
  - [ ] 1.4 系統 shim:真實 distrobox 1.8.2.5 + 假 container manager
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/test/test.sh](../script/test/test.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=0
      ```
    - 驗收方式
      ```bash
      just test system; echo rc=$?
      ```
  - [ ] 1.5 系統 real-engine(docker-in-docker):真的建出可用 dev 盒;host docker 前後不變
    - 預期看到資訊(約 2-4 分鐘)
      輸出格式與清單直接讀取 [script/test/system-real-entry.sh](../script/test/system-real-entry.sh)、[test/system/real_engine_spec.bats](../test/system/real_engine_spec.bats)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：動態示例（TAP 案例編號會隨案例增減位移）；固定判準為列出的案例敘述皆通過及 `rc=0`。
      ```text
      ok 1 preflight: a real docker engine is live inside the runner
      ok 5 real engine: enter.sh --box dev -- rg --version prints a ripgrep version after cold init
      ok 6 real engine: distrobox enter dev -- fzf --version prints a version
      ok 7 real engine: distrobox enter dev -- tmux -V prints a tmux version (auto-enter prerequisite)
      ok 8 real engine: distrobox enter dev -- fish --version prints a fish version (auto-enter prerequisite)
      ok 11 real engine: a second assemble.sh run exits 0 and does not duplicate the dev box
      ok 12 real engine: distrobox rm -f dev removes the box from the engine
      rc=0
      ```
    - 驗收方式
      ```bash
      docker ps -a --format '{{.Names}}' | sort > /tmp/before.txt
      just test system-real; echo rc=$?
      docker ps -a --format '{{.Names}}' | sort | diff /tmp/before.txt - && echo "host unchanged"
      ```
  - [ ] 1.6 交付驗收:直接執行交付的 selfcheck(含負向案例)
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/test/test.sh](../script/test/test.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=0
      ```
    - 驗收方式
      ```bash
      just test acceptance; echo rc=$?
      ```

- [ ] 2. 交付自檢
  - [ ] 2.1 正常 repo:所有檢查 PASS、ALL PASS、rc=0
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/test/selfcheck.sh](../script/test/selfcheck.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=0
      ```
    - 驗收方式
      ```bash
      just test selfcheck; echo rc=$?
      ```
  - [ ] 2.2 壞掉的 repo:FAIL + SOME FAILED、rc=1(自檢不是空判定)
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/test/selfcheck.sh](../script/test/selfcheck.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
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
      輸出格式與清單直接讀取 [script/box/assemble.sh](../script/box/assemble.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=0
      ```
    - 驗收方式
      ```bash
      just box assemble --dry-run; echo rc=$?
      ```
  - [ ] 3.2 從子目錄執行:結果與 3.1 相同(recipe 以 repo 根為工作目錄)
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/box/assemble.sh](../script/box/assemble.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=0
      ```
    - 驗收方式
      ```bash
      (cd doc && just box assemble --dry-run; echo rc=$?)
      ```
  - [ ] 3.3 缺 image:[ERROR]、rc=1、STDOUT 沒有 distrobox 指令
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/box/assemble.sh](../script/box/assemble.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=1
      ```
    - 驗收方式
      ```bash
      printf '[dev]\n' > /tmp/a.ini; just box assemble --dry-run --file /tmp/a.ini; echo rc=$?
      ```
  - [ ] 3.4 單引號包空白 `image='   '`:視為空值拒絕
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/box/assemble.sh](../script/box/assemble.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=1
      ```
    - 驗收方式
      ```bash
      printf "[dev]\nimage='   '\n" > /tmp/c.ini; just box assemble --dry-run --file /tmp/c.ini; echo rc=$?
      ```
  - [ ] 3.5 不成對引號:專屬訊息 unbalanced quote(不是誤報缺 image)
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/box/assemble.sh](../script/box/assemble.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=1
      ```
    - 驗收方式
      ```bash
      printf "[dev]\nimage='ubuntu:26.04\"\n" > /tmp/b.ini; just box assemble --dry-run --file /tmp/b.ini; echo rc=$?
      ```
  - [ ] 3.6 多區段:M2 只支援單一盒
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/box/assemble.sh](../script/box/assemble.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=1
      ```
    - 驗收方式
      ```bash
      printf '[dev]\nimage=ubuntu:26.04\n[debug]\nimage=ubuntu:26.04\n' > /tmp/d.ini; just box assemble --dry-run --file /tmp/d.ini; echo rc=$?
      ```
  - [ ] 3.7 image 在區段之前:區段外的 key 不算數
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/box/assemble.sh](../script/box/assemble.sh)、[lib/manifest.sh](../lib/manifest.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=1
      ```
    - 驗收方式
      ```bash
      printf 'image=ubuntu:26.04\n[dev]\n' > /tmp/e.ini; just box assemble --dry-run --file /tmp/e.ini; echo rc=$?
      ```

- [ ] 4. gate 防漏(必要 spec 被刪/清空不會因同層還有別的 spec 而綠燈)
  - [ ] 4.1 刪掉必要 spec:該層失敗並指名檔案
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/test/test.sh](../script/test/test.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      rc=1
      ```
    - 驗收方式
      ```bash
      rm -rf /tmp/wt-del && cp -r . /tmp/wt-del && rm /tmp/wt-del/test/integration/assemble_spec.bats
      (cd /tmp/wt-del && just test integration 2>&1 | tail -3; echo rc=${PIPESTATUS[0]})
      ```
  - [ ] 4.2 清空必要 spec(0 案例):該層失敗並指名檔案
    - 預期看到資訊
      輸出格式與清單直接讀取 [script/test/test.sh](../script/test/test.sh)，不保存會漂移的 transcript 副本；以本項的行為與結束碼判準驗收。

      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
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
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
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
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
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
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
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
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
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
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
      ```text
      17
      ```
    - 驗收方式
      ```bash
      grep -c '引號規則\|驗證邊界\|1.8.2.5\|29.8.0\|runner 映像' doc/manifest.md
      ```
  - [ ] 6.2 manifest.md 的 M2 驗收紀錄表有三列(審核時填 SHA 與結果)
    - 預期看到資訊
      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
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
  - [ ] 7.1 一鍵 assemble、進盒可用、冪等、可清理(**跑之前先確認你沒有同名 `dev` 盒**:這段結尾會無條件 `distrobox rm -f dev`;先斷言不存在、只刪自己建的那種寫法見 M3 的 5.1 與 5.3)
    - 預期看到資訊
      輸出類型：工具版本會影響的輸出；版本／recipe 清單依現行工具，成功標記與 Usage 行依文中判準。
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

- 自動:進盒延遲量測腳本回報 ≤ 300ms;**整條「開窗 -> setup 受管 command -> `enter.sh` wrapper -> `distrobox enter dev` -> 盒內
  fish」鏈在 CI 內無頭驗證**(issue #172),分兩層。#374 延遲 gate 讀取隔離暫存設定中 setup
  實際寫出的受管 command,經 wrapper 量測 enter / shell / inbox;setup 準備不計時,
  shell median 仍以 300 ms 判定。終端**不自動開 tmux**(issue #179:
  distrobox 與 host 共用 `/tmp`,舊的 `-- tmux new -A -s main` 會附著到 host 的 tmux
  server,實機因此假成功):
  - 第一層(整合層 ghostty 組,不需顯示器,`just test integration`):
    `just box setup` 寫出的受管區塊交給**真的 ghostty** 讀 ——
    `ghostty +validate-config` 接受該檔,`ghostty +show-config` 解析出的生效
    `command` 恰為 `'<repo>/script/box/enter.sh' --distrobox '<D>' --box 'dev'`,
    由 enter.sh wrapper 呼叫 distrobox，後面不接 tmux
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
    執行 `tmux` 得到盒子自己的 server:`script/box/assemble.sh` 依 `BOX_HOME` 決定的 `TMUX_TMPDIR`
    (`${BOX_HOME}/.cache/tmux`，預設為 `~/dev-box/.cache/tmux`)，由
    `box/dev.ini` 的 `additional_flags="--env TMUX_TMPDIR"` 轉交到盒內、server pid 與 host 的不同、其 mount
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

人類 gate 用的驗收清單(= M3 驗收 PR 的描述;逐項勾選,有差異回 PR 留言):

### 通用指令

依賴分兩組(repo 本身不需要驗收工具):

- repo 使用依賴:`docker`(可 `--privileged`)、`just`;clone 需要 `git`。
- 驗收工具:`gh`(已登入,2.2 / 5.1 / 6.1-6.3 用)、`jq`(5.1 / 6.1 用)、`awk` / `grep` / `sed` / `cut` / `find` / `mktemp` / `sha256sum`(coreutils + awk);3 需要 host 的 PATH 上有 `distrobox` 與 `ghostty`(setup 解析這兩個絕對路徑寫進決策 log 與受管 command,少一個就沒得驗);5(實機)另需真的建得起盒、開得起 ghostty 視窗。1-2、4、6 不需 distrobox / ghostty。少任何一項時,對應的 `just verify ...` 會印 `[UNAVAILABLE] <腳本>: <工具> not found on PATH` 並回非 0(退出碼 3),絕不會靜默跳過而讀成通過。

每個「驗收方式」區塊都是**一行 `just verify <動作> [ITEM]` 加上 `echo rc=$?`**,以 **bash** 執行(fish 使用者先打 `bash`);**請原樣貼上,不要改寫**,改寫過的區塊不算數。文件本身已經不帶任何 shell 邏輯 —— 判準全部搬進 repo 的 `script/verify/`(`ui.sh` / `gate.sh` / `setup.sh` / `diagram.sh` / `realbox.sh` / `evidence.sh`),由 `just verify` namespace 轉發。每支腳本自己建立並清理臨時目錄 / 暫存檔,自己守住每條管線與每個計數(先判外部指令自己的結束碼再用它的輸出、每個計數都與它的退化情況分得開),跑不動的環境一律明講並回非 0,不會靜默跳過;`test/unit/verify_*_spec.bats` 再以「印得出像樣輸出、結束碼卻非 0」的 stub 證明它們咬得動。**裸 `just verify` 只列出動作、什麼都不驗**(它自己會印一行 `NOTE: this only lists the verify groups - nothing has been verified. ...` 並回 0,那個 rc=0 不代表通過;#182);**一次跑完全部非實機驗收的是 `just verify all`**(依序 ui、gate、setup、diagram、evidence,遇第一個失敗即停,每組一行摘要加一行總判決,任一組失敗就回非 0;5 是實機,需 `--allow-real-box`,不在內)。`just verify <動作> --help` 是該腳本自己的說明,`just verify <動作> --list` 列出它涵蓋的項目。

搬出文件的原因是 #176 item 8:維護者那一輪跑 2.2 得到 9/10 `order=BAD`,但十份 PR 描述其實都滿足 2.2 的主張(同一份判定邏輯實測 10/10),awk 實作、locale、CRLF、貼上時的 shell 與縮排都已逐項排除,**根因未解** —— 那一輪跑在維護者的指令執行器裡,那個環境在這裡沒有、重現不了;處置因此是結構性的(把邏輯搬出文件),不是找出成因。逐項排除的指令與輸出見 `doc/evidence/README.md`。
本 PR(#157)相對 main 的改動範圍（`origin/main...m3/5-acceptance`）包含七階段措辭與流程圖同步（`README.md`（含 #628／PR #632 的狀態列更新）、`doc/structure.md`（含 #628／PR #632 的狀態列更新）、`doc/diagram/flow.drawio.svg`、`test/unit/diagram_spec.bats`、`test/unit/ci_yml_spec.bats`、`doc/adr/0012-invariant-platform-neutral.md`）、驗收清單與證據（含 2.1 CPU 負載重現 skip 豁免與 runner 清單一致性 spec；`doc/acceptance.md`（#600／PR #605 的 5.3 所有權判準、#601／PR #604 的 5.4 階段競態限制、#602／PR #609 的 5.4 未判定語意、#626／PR #631 的備份集合、目錄 mtime 與還原殘留目錄說明、#625／PR #635 的「行程群組未確認停止時拒絕設定還原」說明、#641／PR #644 的 5.1 首次初始化與 5.4 階段判定說明、#628／PR #632 在本段補上的 `doc/structure.md` 條目、#637／PR #638 的本段來源註記補齊、#645／PR #646 的本段來源註記補齊、#651／PR #652 的本段來源註記補齊、#653／PR #654 的本段來源註記補齊、#655／PR #656 的本段來源註記補齊、#659／PR #662 的 3.5 產品行補齊、3.10 工具版本診斷分類與 #657／PR #661、#658／PR #660 本段來源註記補齊）、`doc/evidence/README.md`、`doc/evidence/tdd.sh`、`doc/evidence/tdd.awk`、`doc/evidence/negative/`）、300 ms 門檻措辭同步（`doc/design.md`（另含 #629／PR #634：M3 段落的受管命令改寫為實際寫入的 `enter.sh` wrapper 形態（`'<repo>/script/box/enter.sh' --distrobox '<D>' --box 'dev'`））、`doc/enter.md`、`doc/manifest.md`（另含 #628／PR #632 的狀態列更新）；≤ 300 ms）、ADR 0008／0010 的措辭、驗收程式與入口（`script/verify/`，含 #574 的 `realbox.sh` 5.1／5.3 最終清理診斷修正、#582 的 assemble 逾時診斷競態修正、#586 的 assemble 階段失敗診斷區分、#588 的 dangling init-log symlink 目標還原、#589 的 init-log 缺失上層目錄鏈清理與殘留計數、#598／PR #599 的外層中斷 wait 與清理順序修正、#600／PR #605 的 5.3 容器 ID 所有權確認、#602／PR #609 的 5.4 內層 bench rc=3 未判定分類、#616／PR #617、PR #618 的 5.4 外層收尾 wait 修正、#626／PR #631 讓 `config_backup_paths.sh` 為每個受管檔案記錄完整的缺失上層目錄鏈並如實回報 `leftover-dirs`、#627／PR #633 讓單獨執行的 `realbox.sh` 5.2.3 還原印出 `cleanup-rc`、#625／PR #635 讓 `realbox.sh` 在行程群組未確認停止時拒絕設定還原並保留備份與診斷、#641／PR #644 讓 `realbox.sh` 5.1 在 bench 前執行首次啟動暖機、#658／PR #660 讓 `evidence.sh` 6.1 檢查固定的 PR 與 issue 配對、#648／PR #650 讓 `evidence.sh` 6.3 先彙整所有留言頁再取最後一則審查留言判定；逾時清理共用程式 `lib/verify_run.sh`（含 #596／PR #597 的有界等待、#625／PR #635：停止行程群組失敗或群組仍有存活成員時回報 `configuration restore refused` 並 fail closed，不進入還原、#647／PR #649 的逾時分支在 KILL 無法確認停止群組時保留 guard 並 fail closed）、中斷矩陣共用程式 `lib/realbox_interrupt.sh`（含 #596／PR #597 的有界等待、#598／PR #599 的外層中斷 wait 與清理順序、#601／PR #604 的 assemble／bench 階段競態修正、#602／PR #609 的內層 bench rc=3 未判定分類、#616／PR #617 的外層收尾回收競態、#641／PR #644 的首次初始化階段判定、#657／PR #661 的 5.4 cell 在停止失敗時保留 `_54_PID` 並於失敗清理重試停止）、`justfile`）、建盒預設 fish（`script/box/assemble.sh`；#472）、盒內指令說明移除過時的 rm 承諾（`script/box/justfile.box`；#665／PR #673）、延遲 gate 補讀盒子 cgroup PSI（`script/box/bench.sh`、`doc/adr/0003-latency-gate-inconclusive.md`；#491／PR #492、#494／PR #496 的冷啟動後重新解析）、產品共用程式（`lib/config_backup.sh`（含 #626／PR #631 的每個受管檔案完整缺失上層目錄鏈）、`lib/guard.sh`、`lib/home.sh`、`lib/distrobox_manager.sh`；後者由 `lib/home.sh` 抽出，行為不變）、測試入口與完整歷史 checkout（`script/test/test.sh`（含 #655／PR #656 的檔案系統列舉失敗處理）、`.github/workflows/ci.yml`）與相關測試（`test/unit/bench_spec.bats`、`test/unit/verify_*_spec.bats`（含 `verify_realbox_matrix_spec.bats` 的 #596／PR #597、#598／PR #599、#601／PR #604、#602／PR #609、#616／PR #617、PR #618、#625／PR #635、#641／PR #644、#657／PR #661 修正，`verify_realbox_spec.bats` 的 #600／PR #605、#627／PR #633、#625／PR #635、#641／PR #644 修正，`verify_config_backup_cache_spec.bats` 的 #626／PR #631 修正，`verify_run_signal_spec.bats` 的 #596／PR #597、#647／PR #649 修正，`verify_evidence_spec.bats` 的 #648／PR #650、#658／PR #660 修正，以及 `verify_setup_spec.bats` 的 #659／PR #662 逐字區塊雙向比對）、`test/unit/test_sh_spec.bats`（含 #655／PR #656 的無 git 列舉失敗測試）、`test/unit/ci_gate_spec.bats`、`test/unit/justfile_spec.bats`、`test/unit/enter_spec.bats`、`test/unit/config_backup_spec.bats`、`test/unit/config_backup_dangling_spec.bats`、`test/unit/guard_spec.bats`、`test/unit/config_spec.bats`（含 #583 的讀寫同步點與有期限並行 fixture：`test/unit/fixture/config_race.sh`）、`test/unit/acceptance_doc_spec.bats`（含 #626／PR #631、#651／PR #652、#653／PR #654、#655／PR #656、#659／PR #662 的修正）、`test/unit/assemble_spec.bats`、`test/unit/fixture/`（含 `realbox_matrix_just.sh` 的 #596／PR #597、#602／PR #609、#641／PR #644 修正，以及 #641／PR #644 新增的 `realbox_cold_tool.sh`）、`test/helper/`、`test/system/real_engine_spec.bats`、`test/system/real_assemble_spec.bats`）。**`just verify` namespace 與 `script/verify/` 只在本 PR 分支上**，所以下面直接 clone 本 PR 分支 `m3/5-acceptance`（= main 加上述變更）。clone 成 main 的話，每個區塊都會是 just 自己的 `Justfile does not contain recipe`（rc=1），什麼都不會跑。

```bash
git clone --branch m3/5-acceptance https://github.com/ycpss91255/worktool.git && cd worktool   # 該分支已 merge main,含 M3 全部 sub-issue PR(#152-#156、#165-#169)與 #177
just --version && docker info >/dev/null && echo repo-dep-ok
gh auth status >/dev/null 2>&1 && jq --version >/dev/null && echo verify-tool-ok
```

輸出類型：工具版本會影響的輸出；版本／recipe 清單依現行工具，成功標記與 Usage 行依文中判準。
```text
just 1.53.0        (版本不限)
repo-dep-ok
verify-tool-ok
```

(`git clone` 自己會往 stderr 印 `Cloning into 'worktool'...` 之類的進度,不列在上面;判準是後面三行。`gh` 沒登入時只會少掉 `verify-tool-ok` 且整段 rc=1)

完整入口依目前案例規模請預留至少一小時；維護者 2026-10-02 實跑約 65 分鐘（當時主機另有負載），耗時會隨建置快取、案例數與主機負載改變，這不是進盒延遲指標。

驗收指令(維護者跑這一行;不是裸 `just verify` —— 那只會列出動作):

```bash
just verify all; echo rc=$?
```

輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
```text
verify all: ui PASS
verify all: gate PASS
verify all: setup PASS
verify all: diagram PASS
verify all: evidence PASS
verify all: VERDICT PASS (5/5 groups: ui gate setup diagram evidence; realbox not run - it needs --allow-real-box on a real host)
rc=0
```

(每組自己的預期輸出照常穿插在它的摘要行之前,逐項對照見下面各項;上面只列 `all.sh` 自己印的摘要與判決。任一組失敗時,那一組印 `verify all: <組> FAIL (rc=N)`(跑不動則 `UNAVAILABLE (rc=3)`),接著 `verify all: VERDICT FAIL at <組> (rc=N); passed: ...; not run: ...`,後面的組不再跑,整段 rc 非 0。5 另外以 `just verify realbox --allow-real-box ...` 在實機上跑。)

3 與 5 的輸出含機器相關路徑,下面以 `<H>`(臨時 HOME)、`<D>`(host 上 distrobox 執行檔的絕對路徑,例如 `/usr/local/bin/distrobox`)、`<G>`(host 上 ghostty 執行檔的絕對路徑,`command -v ghostty` 的結果)代表。3 的每一項由 `script/verify/setup.sh` 自己算出這幾個路徑、再把輸出裡的它們換成佔位符,所以 3 的預期輸出在任何安裝位置都逐字相符(round 10:更早的版本把 ghostty 路徑寫死成 `/usr/bin/ghostty`,裝在別處的機器會無故變紅);5 的輸出沒有這層轉換,請自己對照。

### 威脅模型:這些檢查程式擋得住什麼、擋不住什麼

`script/verify/` 擋的是**誠實的回歸**與**環境真的壞掉**:產品改壞了、某個決策不再印 log、
受管 command 退回裸名字、CI 少跑一個架構、`gh` 印得出像樣的輸出卻 exit 1、量測數字自相
矛盾 —— 這些都會被指名並回非 0。它擋不住的是**操作者偽造它正在檢查的那份證據**:把 `just`
換成一個什麼都不印就 exit 0 的殼、把十份 PR 描述的程式碼區塊填成一個字元、手寫一份看起來
對的 bench 輸出,這類做法本檢查程式不處理。這不是漏洞而是邊界:在那個情境下整套測試同樣
全部失效(誰都可以把 `bats` 換成 `exit 0`),所以防線只能是「誰能改這個 repo 與這台機器」,
不是驗收腳本裡再多一層斷言。

### 驗收項目

規則:入口一律 `just` —— 產品功能是 `just box` / `just test`,驗收本身是 `just verify`;5 是實機(distrobox 原生 + 開終端主觀);文件與外部證據由 `just verify evidence` 用上面列出的驗收工具(gh / jq / awk / grep / sed / find)查。

- [ ] 1. 使用者介面:box namespace 多了 bench / setup / status
  - [ ] 1.1 `just box` 列出七個動作;`just box help` 依序印五支腳本的 usage
    - 預期看到資訊
      輸出類型：工具版本會影響的輸出；版本／recipe 清單依現行工具，成功標記與 Usage 行依文中判準。
      ```text
      （recipe 清單直接由 justfile 顯示，不另維護說明文字副本）
      Usage: assemble.sh [--file <manifest>] [--home <path>] [--dry-run]
      Usage: bench.sh [--box NAME] [--runs N] [--warmup N] [--max-ms N] [--json]
      Usage: setup.sh [--auto-enter yes|no] [--terminal ghostty|none]
      Usage: status.sh
      Usage: enter.sh [--box <name>] [--distrobox <path>] [--timeout <seconds>]
      five-usages
      rc=0
      ```
      (usage 第一行可能因終端寬度換行只顯示前半;`five-usages` = 斷言五支不同腳本各有 usage。腳本的進度與失敗原因走 stderr,上面只列 stdout 加最後一行 `echo rc=$?`)
    - 驗收方式
      ```bash
      just verify ui 1.1; echo rc=$?
      ```

- [ ] 2. 自動測試:七個階段全綠(含 300 ms 進盒延遲 gate)
  - [ ] 2.1 裸 `just test` 跑完七個階段(依序為 lint、unit、matrix、integration、system、acceptance、system-real);system-real 內盒有 tmux + fish,bench 以 `fish -c exit` 通過 `--max-ms 300`,負向 `--max-ms 1` 會咬
    - 預期看到資訊(完整入口請預留至少一小時，負載下實測約 65 分鐘（見上方說明）;每層 `required specs OK` 後全部 ok,案例數隨版本增加不釘死)
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
      ```text
      ./script/verify/gate.sh "$@"
      ./script/test/test.sh
      [ci] ShellCheck OK
      （required specs OK 的案例與檔案數直接由 script/test/test.sh 掃描現行 declarations）
      ...(每層的 N 由來源掃描取得，1..N 全部 ok,各以 `[ci] <tier> bats OK` 結尾;沒有 not ok，skip 僅允許下列 unit 負載重現例外)
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
      (本項把整條 `just test` 的輸出原樣串到你的終端 —— `[ci]` 那些行是 stderr,上面一起列出。數字是你機器的實測;判準 = `just test` **自己**回 0,加上 shell median ≤ 300 且三行指標都在。自動測試只證明「盒內有 tmux + fish、進盒 + 起 fish ≤ 300 ms」;「ghostty 開窗 -> 受管 command -> 盒內 fish」整條鏈由 2.3 在 CI 內驗證,實機主觀感受由 5.2 驗)
    - 唯一 skip 例外：未設 `WORKTOOL_STRESS=1`（未設定或值不是 `1`）時，unit 層只允許以下三個 CPU 負載重現案例以列出的訊息 skip。除此之外，每層都不得有任何 skip；設 `WORKTOOL_STRESS=1` 時，這三個案例也不得 skip。案例名稱與訊息必須完全符合 `script/test/test.sh` 的豁免清單。

      | 案例名稱 | skip 訊息（TAP 後綴） |
      | --- | --- |
      | `verify_run: HUP under CPU load always finishes before cleanup` | `# skip set WORKTOOL_STRESS=1 to run CPU repro` |
      | `5.1: group HUP under CPU load finishes before cleanup during assemble and bench` | `# skip set WORKTOOL_STRESS=1 to run CPU repro` |
      | `timeout cleanup: TERM-ignoring just descendant under CPU load` | `# skip set WORKTOOL_STRESS=1 to run CPU repro` |

      另跑這三個案例時，設定 `WORKTOOL_STRESS=1`，透過 `just` 在 Docker 內執行各自的切片：
      ```bash
      WORKTOOL_STRESS=1 just test unit test/unit/verify_run_signal_spec.bats --filter '^verify_run: HUP under CPU load always finishes before cleanup$'
      WORKTOOL_STRESS=1 just test unit test/unit/verify_realbox_spec.bats --filter '^5\.1: group HUP under CPU load finishes before cleanup during assemble and bench$'
      WORKTOOL_STRESS=1 just test unit test/unit/verify_realbox_spec.bats --filter '^timeout cleanup: TERM-ignoring just descendant under CPU load$'
      ```
      #582 的 Docker amd64 重現：四個 CPU worker 與 assemble shell 固定在同一個允許的 CPU，timeout 監督程序不固定 CPU；沿用 0.2 秒 stub，各跑 30 次。修正前漏印診斷 17/30，修正後 0/30；兩輪 descendant 的 PID 就緒標記皆為 30/30，且沒有存活的 descendant 或延遲寫入。原因是逾時監督程序退出後立即清除 process group，內層 shell 未必來得及印診斷；改由存活的外層在取得監督結果後印出 assemble 失敗訊息。這是產品程式競態，未改逾時長度或清理順序。
    - 驗收方式
      ```bash
      just verify gate 2.1; echo rc=$?
      ```
  - [ ] 2.2 TDD 證據:每個 sub-issue PR 的描述都有一個非空的 RED 程式碼區塊,且其後另有一個非空的 GREEN 程式碼區塊(只證明「有貼輸出且順序正確」,不判讀內容語意;`red=` / `green=` 是該區塊開頭的行號)
    - 預期看到資訊(10 行,每行 order=ok;行號依 PR 內容而異)
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
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
      (失敗時的樣子:缺段、區塊是空的或順序錯是 `#N order=BAD ...`,查詢失敗是 `#N evidence=gh-failed`,兩者最後都 `rc=1`。
      判準是「上面這十個 PR 各有一行、各只有一行 `order=ok`,且 `green` 大於 `red`」,不是「有看到某一行 order=ok」——
      `script/verify/gate.sh` 就是照這個集合判的:少一個、多一個、重複一個都會被指名並回 `rc=1`。
      **行的順序也在判準內**:十行全對但其中兩行對調,代表檢查程式跑的是另一份清單,
      `gate.sh` 會印出實測順序與本文件公佈的順序並回 `rc=1`)
    - 驗收方式
      ```bash
      just verify gate 2.2; echo rc=$?
      ```
  - [ ] 2.3 「開窗 -> 進盒 -> fish」整條鏈由 CI 自動驗證(#172):整合層用真的 ghostty 斷言受管區塊解析出的 command;system-real 用 `xvfb-run` 開真視窗,判準是**盒內**留下的標記檔(runner 自己沒有 fish);另有 #434 冷啟動：在尚未啟動的乾淨盒上執行 setup，讀回並在 PTY 終端原樣執行受管命令，以至少兩次變動的進度更新、初始化完成與盒內 fish 輸出判定成功；失敗與 timeout 則由 unit 的 setup 命令入口驗證有界非零結果、原因與復原訊息。並有防卡與假陽性兩個負向測試
    - 預期看到資訊(`just test` 的 integration 與 system-real 兩段,中間空一行;每段的 tier 輸出先整份收進檔案再 grep,所以「`just test` 失敗」和「grep 一行都沒對到」分得開,rc 反映的是上游 `just test` 的結果)
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
      ```text
      ok 38 the ghostty command just box setup writes enters the box directly without starting tmux
      ok 39 setup then status: status reports the stored decisions, sources and the ghostty block present, no tmux line
      ok 1 preflight: a real ghostty is on PATH and reports its version
      ok 2 setup.sh writes a ghostty config that +validate-config accepts
      ok 5 +show-config follows setup.sh --box work (the box name reaches ghostty)
      ok 6 #175: the effective command ghostty resolves is an ABSOLUTE distrobox path, not the bare name
      ok 9 #175r2: a distrobox path holding a newline is refused, because ghostty could not parse what it would write
      ok 10 #175r1: a distrobox path with spaces and metacharacters survives ghostty and the shell it hands the command to
      ok 11 after setup.sh --auto-enter no there is no enter command left for ghostty to run
      ok 12 +validate-config refuses a config ghostty cannot parse (the check bites)

      # chain-cold: changing progress updates=42; setup command entered fish in dev
      ok 5 ghostty chain cold start (#434): setup-written command reports continuous first-init progress and enters fish
      ok 12 ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive)
      # chain: inbox-ok fish=4.2.1 ctrenv=/run/.containerenv mntns=mnt:[1234] tmux=no host=ca83e9d035cd
      # chain-in-box: marker mntns=mnt:[1234] == dev container; host=ca83e9d035cd == docker inspect dev hostname
      ok 13 ghostty chain: a real window runs the managed block's command and leaves a marker INSIDE the box (fish, the box's mount namespace, no tmux)
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
      # chain-desktop-path: inbox-ok fish=4.2.1 ctrenv=/run/.containerenv mntns=mnt:[1234] tmux=no host=ca83e9d035cd
      ok 16 ghostty chain (#175): the absolute distrobox path just box setup writes enters the box from a desktop session's PATH
      rc=0
      ```
      (`host=` 是那一輪盒子的容器 id、`fish=`、`FORWARDED_DELAY_MS=` 與 `SECOND_ELAPSED=` 是實測值,每次都不一樣,不要照字面比 —— 尤其 `SECOND_ELAPSED` 是「第二次啟動花了幾秒」,測試接受的是 0-15,上面印 `1` 只是某一輪的實測(round 11:一輪量到 `0`,照字面比會無故變紅);判準是這些 `ok` 行都在、沒有 `not ok`、`FORWARDED_STARTED` / `FORWARDED_AFTER_RETURN` 是 `yes`、`COMMAND_FINISHED` 是 `no`、整段 `rc=0`。任何一層出現 `not ok`,即使該層 `just test` 回 0 也算失敗;integration 紅掉時不會再跑 system-real。hang 案例只在盒內 ready 標記出現後才接受 `timeout` 的 124,否則算「沒進到盒子」這個不同的失敗;single-instance 案例證明為什麼所有測試設定都明寫 `gtk-single-instance = false`。
      `script/verify/gate.sh` 判的就是上面這整組,不是「有某一行對到就算數」:integration 與 system-real 的 `ok` 案例分別以 `INTEGRATION_CASES` 與 `SYSTEM_REAL_CASES` 清單為準(以案例敘述比對,不比 `ok` 後面的編號,編號會隨新增案例位移)，清單中的每個案例各出現一次、不能多也不能少;`tmux=no`、`PRIMARY=up`、`SECOND_RC=0`、`STARTED_AT_RETURN=1`、`FORWARDED_STARTED=yes`、`FORWARDED_AFTER_RETURN=yes`、`RUNNING_COMMANDS=2`、`PRIMARY_WRAPPER_ALIVE=yes`、`COMMAND_FINISHED=no` 這些判定值逐字比對,`ctrenv=` 必須是 `/run/.containerenv` 或 `/.dockerenv`，`mntns=` 必須是盒子的 mount namespace；`host=` / `fish=` / `FORWARDED_DELAY_MS=` / budget 秒數這些實測值只比形狀;`SECOND_ELAPSED=` 也是實測值,但本文件公佈了它的範圍(0-15),所以 `gate.sh` 就照 `0-15` 比 —— 只比 `[0-9]+` 的話,`SECOND_ELAPSED=999`(第二次啟動花了十六分鐘才返回,正好是本案例要否證的那件事)也會過;`# hang-ready:` 必須排在 `# hang:` 與 hang 案例之前。新增一個 ghostty 鏈案例時,這份文件的區塊與 `gate.sh` 的清單要一起改)
    - 驗收方式
      ```bash
      just verify gate 2.3; echo rc=$?
      ```
  - [ ] 2.4 驗收程式本身的負向:2.2 的檢查程式會咬錯誤的證據;沒有 `pipefail` 的 pipeline 會漏掉上游失敗(#176 item 7 / item 8 的回歸守門)
    - 預期看到資訊(前四行 = 檢查程式咬住順序顛倒與空的 RED 區塊;後兩行 = 同一條 pipeline 有無 `pipefail` 的差別)
      輸出類型：固定判準（佔位符以本輪路徑替換後逐字比對；省略號只表示省略內容）。
      ```text
      order=BAD red=6 green=0
      wrong-order rc=1
      order=BAD red=0 green=0
      empty-red-block rc=1
      guarded-rc=7
      unguarded-rc=0
      rc=0
      ```
      (前四行是 `script/verify/gate.sh` 拿 2.2 的檢查程式去跑兩份壞掉的證據:兩次都必須
      **先** exit 1(拒絕),印出來的判定行才拿去比對。`unguarded-rc=0` 是**刻意留下的
      反例**,不是本清單還在用的寫法 —— 它就是這一項要示範的那個缺陷:上游 exit 7,
      整條 pipeline 仍然回 0。`script/verify/` 的每支腳本都不用這種寫法:外部指令的輸出
      先收進變數或檔案、先判它自己的結束碼再用)
    - 驗收方式
      ```bash
      just verify gate 2.4; echo rc=$?
      ```

- [ ] 3. 進盒設定:user 可選、預設直接進盒、每個決策印 log(`script/verify/setup.sh` 每項自建拋棄式 HOME 並在 EXIT / INT / TERM / HUP 清掉,不動你的家目錄)

  受管檔案是**使用者的**,`just box setup` 只是在裡面租一個區塊。所以**每一個**會寫入或移除受管區塊的項目 —— 3.1 / 3.2 / 3.3 / 3.5 / 3.6 / 3.7 / 3.8 / 3.9 —— 都在跑 setup **之前**就先把臨時 HOME 的 ghostty 設定與 `~/.tmux.conf` 種進三行看得出來的使用者內容,並在每一次寫入、改寫、移除之後再查一次:受管區塊以外的內容必須還是那三行、順序不變、一行不多一行不少。這是 `user-content <時機>: ghostty=intact tmux.conf=intact` 那幾行。少了這個斷言,一個「把整份設定覆寫成受管區塊」的 setup 會讓區塊在、`status` 說 `present`、檔案數與結束碼全對 —— 而使用者的 ghostty 設定已經被刪掉了。3.4 不在名單裡,因為它只驗「被拒絕的輸入」與壞掉的狀態檔,整項從頭到尾不寫也不移除任何受管區塊(它反而要求 HOME 底下一個檔案都沒被建立)。

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
    - 驗收方式：`just verify setup 3.11`。各以 legacy `config` 與 `config.ghostty` 當目標，種下使用者內容及 0644／0600，真的寫入 dev、改寫成 second、再以 `--auto-enter no` 移除 Ghostty 區塊；每步以 `stat -c %a` 比較 Ghostty、distrobox.conf 與 worktool 狀態檔。後兩檔在移除操作中仍保留；host tmux.conf 不受管理。
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
- [ ] 4. README 圖(draw.io,可編輯)
  - [ ] 4.1 `doc/diagram/` 恰好三張 `.drawio.svg`、都無 foreignObject、都內嵌 mxfile;README 引用三張圖(3 個圖片 + 1 個編輯連結說明 = 4 處);流程圖測試節點寫「host 只需 docker + just」
    - 預期看到資訊(依序:svg 總數、含 foreignObject 的、含 mxfile 的、README 引用、流程圖措辭)
      輸出類型：固定判準（逐字比對）。
      ```text
      svg=3
      foreignobject=0/3
      mxfile=3/3
      readme=4
      flow-wording=1
      rc=0
      ```
      (round 12:`foreignobject` 與 `mxfile` 印的是 `相符/掃過` 兩個數字。更早的版本全部是
      `$(cmd | wc -l)`,`foreignobject=0` 因此有兩種意思 —— 三張圖都乾淨,或是**一張圖
      都沒讀到**(目錄不在、glob 沒展開、grep 讀不到檔),而後者才是真的壞掉。現在分母
      就是那一輪實際掃過的檔數,`0/3` 和 `0/0` 一眼分得出來;而且 `script/verify/diagram.sh`
      先斷言每個檔存在、是普通檔、讀得到而且非空,再逐檔以一個必中與一個必不中的探針證明
      grep 本身可信,任何一關過不了就非 0 結束,根本印不出那五行)
    - 驗收方式
      ```bash
      just verify diagram 4.1; echo rc=$?
      ```
  - [ ] 4.2 GitHub 上看得到圖(人類):開 https://github.com/ycpss91255/worktool#架構與流程,三張圖有文字、無 "Text is not SVG"

- [ ] 5. 實機（需要 host 有 distrobox + ghostty；會以 `--home` 在本輪 scratch／backup 目錄內建 dev 盒的獨立 HOME 與 user config symlink，並改動真實設定）。5.1 以 scratch 內的 `XDG_CONFIG_HOME` 隔離 assemble 狀態寫入，並連結真實 config 目錄中除 `worktool/` 以外的所有頂層項目（含隱藏項目），讓 assemble、bench 與清理沿用相同的容器工具儲存位置、連線設定、container manager、使用者設定與 TMUX 隔離區塊；成功、失敗及中斷都不改動真實狀態檔（原本不存在時仍不存在）。5.1／5.2 先拒絕既有同名盒，清理只刪自己建立的盒。5.2 在建盒前備份 setup 可能寫入的五個檔：Ghostty legacy config、config.ghostty、worktool 狀態檔、distrobox.conf、初始化 log（init-log）（PR #232、#351）；任何檔備份不了就拒絕。symlink 及其目標一起備份，還原前確認受管檔的使用者內容仍在。清理失敗回非零；host 沒有 Ghostty 時 5.2 保持未勾。
  - 快取隔離（#511）：5.1 的 assemble、首次初始化與 bench 都將 `XDG_CACHE_HOME` 指向本輪 scratch 的 `cache/`；5.2 由 realbox 執行的 assemble 指向本輪備份目錄的 `cache/`；5.3 decoy 的 create 指向本輪 scratch 的 `cache/`。5.2 的 setup、status 與還原時的 setup 不呼叫產品 enter.sh，不寫初始化 log。這些隔離呼叫及其子行程寫入的初始化 log 都落在本輪目錄，成功清理時隨 scratch／備份一起移除；清理失敗則沿用保留目錄供檢查與重試的規則。realbox 自己的這些呼叫不改動真實 `${XDG_CACHE_HOME:-~/.cache}/worktool`（預設 `~/.cache/worktool`）：原本不存在時仍不存在，既有內容與 mtime 不變，也不以備份後覆寫再還原代替隔離。
  - 盒名由交付的 `box/dev.ini` manifest 決定（目前為 `[dev]`），不支援自訂 manifest。省略 `--box` 時沿用該盒名；`--box <name>` 只能指定相同名稱。若不一致（例如 `--box work`），在任何副作用前以 exit 2 拒絕，stderr 的 `realbox.sh: ...` 訊息會說明 manifest 決定盒名；不呼叫 assemble、distrobox 或 gh。5.3 的 decoy 仍使用 manifest 的盒名。
  - [ ] 5.1 進盒延遲 ≤ 300 ms(以 fish 為準);由 `script/verify/realbox.sh` 自己把三行數字發到 #22,再依留言 id 讀回來比對本輪識別碼與三行數字;中斷(Ctrl-C)與正常結束都會清掉自己建立的盒子,清不掉就失敗。中斷仍為失敗：SIGINT 回 130、SIGTERM 回 143、SIGHUP 回 129，不以清理成功當作驗收通過。assemble、首次初始化或 bench 中斷時，腳本先停止本輪子行程群組，再自行清理並印出 `cleanup-rc=<n>`、`box-state` 與 `host-state` 清理報告；清理失敗優先，以 exit 1 結束。
    - assemble 完成後先以 `just box enter --box dev -- true` 完成首次啟動與初始化（沿用本輪 data／cache／config 隔離，stdin 關閉以避免失敗等待互動確認），再呼叫 bench，讓既有 quiet-wait 等待主機安靜後才量測。stderr 依序印 `phase=first-start`、產品首次初始化進度、`phase=bench` 與 bench 診斷；初始化失敗回 1、清理且不執行 bench、不發留言。ADR 0003 的 2.00 門檻、連續 5 秒、warmup 檢查、300 ms 與 exit 3 語意不變。
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
      rc=0
      ````
      (三行數字本身也在判準內,不只是形狀:每個指標都要 `min <= median <= max`,而且 `shell` 的 median 要小於或等於這一輪真的傳給 `bench` 的 `--max-ms`(300;剛好等於門檻算通過,與 `bench` 及 #181 一致)。只比形狀的話,`min=500 median=400 max=1` 是三個合法的數字、卻不是任何東西的量測,而且 median 還超過它自己的門檻,照樣會過。
      `posted=1` 的判準有三個,缺一不可:那則留言在 #22 上、帶本輪 `run` 識別碼、而且**逐字**含本輪量到的三行。舊留言再像也命不中(#176 item 3);上一版用 `?per_page=100` 不翻頁,#22 留言超過 100 則之後會無故變紅,改成依 id 直接取那一則就沒有這個問題。`cleanup-rc` 在盒子、獨立 HOME、host 狀態與 scratch 清理結果都確定後只印一次；任何一步失敗都印 `cleanup-rc=1` 並讓本項 exit 非 0。盒子仍在時需手動移除；HOME 或 host 狀態清理失敗時保留 scratch 與未知資料供檢查，scratch 刪除失敗時也回報 1，不能將盒子已移除讀成整體清理成功。所有權須以 assemble 前確認盒子不存在、執行後合法列表確認盒子存在為證據，才把該盒的 container ID 寫入 `created-box`。清理前必須以合法列表比對本輪記錄的 ID；ID 不同或取不到時拒絕刪盒、回非零並保留證據。ID 相符的盒子照常清理；空表仍代表盒子不存在。`assemble-started` 只記錄已確認不存在後的 assemble 嘗試，不授予所有權；正常成功另記 `assemble-success`，仍須再次查到盒子。中斷後 assemble 回非零時，先停止本輪子行程群組，再於本次 realbox 執行內以合法列表確認盒子存在並記下 ID（assemble 子 shell 被中斷時，由已停止子行程的父行程在還原與互動前完成最後一次確認，隨即取消補記權限），才取得清理所有權；因此 Ctrl-C 跑到一半仍可清掉本輪已確認 ID 的盒。若本次執行結束時仍未記下 ID，後續獨立執行 5.2.3 不得只憑名稱補取得所有權。失敗且確認盒子不存在時不取得所有權、不呼叫刪盒，並清除嘗試紀錄，避免日後還原誤認使用者新建的同名盒；列表失敗或無法解析時拒絕刪盒、回非零並保留證據；assemble 失敗且確認列表無法解析（列表狀態 2）時，必須保留 `assemble-started`、印 `cleanup-rc=1`，且不呼叫 `distrobox rm`。取得所有權後清理只看最後盒子是否確定不存在，`distrobox rm` 沒東西可刪不算失敗。)
    - assemble 的暫存檔以本輪 scratch 下的 `assemble-tmp` 為 TMPDIR。distrobox 1.8.2.5 的 `distrobox-assemble` 在解析前以 `expanded_file=$(mktemp -u)` 建立展開的 manifest，卻未將它列入 EXIT trap；realbox 因此將建立步驟的暫存目錄納入本輪所有權，成功、失敗與 INT／TERM／HUP 後均隨 scratch 清除，不刪外層 TMPDIR 的其他檔案。5.4 每格也核對本輪 scratch 已不存在。
    - 主機忙碌時，bench 依 ADR 0003 回 3，代表未判定。本項仍清理本輪建立的盒子，不發 #22 留言；清理成功時不印 `[FAIL]`，整項 exit 3。預期輸出包含以下各行（清理的狀態行照常穿插，最後一行為 `echo rc=$?`）：
      ```text
      rc=3
      [INCONCLUSIVE] item 5.1: host too busy (bench exit 3), re-run when idle
      cleanup-rc=0
      rc=3
      ```
      清理失敗優先：即使 bench 未判定，仍印清理失敗診斷並以 exit 1 結束；bench 回 1（有效量測超標或量測失敗）也維持功能失敗、exit 1。300 ms 判準、PSI 門檻 2.00、不重試與不刪樣本均不變；未判定須等主機閒置後另行重跑，不算通過或退化。
    - 驗收方式：維護者本人執行可省略標記；agent 必須加 `--comment-tag '[codex]'`（換成自己的名稱標記，例如 `[claude]`）。標記須符合 `^\[[a-z]+\]$`，否則 exit 2。指定時留言第一行以 `<標記> ` 接原本的 `M3 5.1 real-machine bench` 開頭；省略時本文維持原樣。讀回判準也必須確認本文以指定標記開頭。
      ```bash
      just verify realbox --allow-real-box 5.1; echo rc=$?
      ```
  - [ ] 5.2 開終端即在盒內 fish，主觀無明顯延遲；一次呼叫依序備份、套用、確認新視窗、還原。套用期間收到 SIGINT／SIGTERM／SIGHUP 時先停止本輪子行程群組，再自行還原、清理並印出 `cleanup-rc=<n>`、`box-state` 與 `host-state` 清理報告；清理成功時回 130／143／129，還原或清理失敗時回 1、保留備份，單獨跑 5.2.3 重試還原。
    - 完整的 `just verify realbox --allow-real-box 5.2` 在建盒、備份與 setup 套用前先檢查桌面（#529）：以 `loginctl show-session "${XDG_SESSION_ID:-self}" --property=LockedHint --value` 查詢呼叫者的 session，查詢有 timeout。成功回 `yes` 時，stderr 印 `[INCONCLUSIVE] item 5.2: session is locked; an unlocked desktop is needed, unlock and re-run`，exit 3；不建盒、不建立備份、不改設定。成功回 `no` 時維持原流程；有呼叫者 session 時，loginctl 缺少、查詢失敗（即使 stdout 是 `yes`）、空值或非 yes/no 時，stderr 印 `[WARN] item 5.2: cannot determine session lock state; proceeding` 並繼續，但仍須通過 display 檢查。此方法只偵測 logind 的 LockedHint；未向 logind 回報的鎖定方式無法偵測，也無法保證檢查後桌面不再鎖定。
    - 沒有 `XDG_SESSION_ID` 且 `self` 查不到 yes/no 時（#545），改以有 timeout 的 `loginctl list-sessions --no-legend --no-pager` 列出 session，只查 `id -u` 對應使用者的 session，再以 `show-session` 取得 `User`、`Type`、`Active`、`LockedHint`。所有查詢成功且至少一個 session 的 User 是目前 uid、Type 是 wayland／x11、Active=yes、LockedHint=no，才繼續；其他使用者的 session 不算。列表或任一同使用者 session 查詢失敗（即使有看似有效的 stdout）、找不到合格 session、鎖定或未知狀態都印 `[INCONCLUSIVE] item 5.2: cannot confirm an unlocked graphical session for this user; unlock the desktop and re-run`，exit 3，不建盒、不備份、不改設定。有一個合格 session 即可，不判斷使用者實際看的是哪個；LockedHint 仍依桌面回報，沒有回報鎖定時無法偵測。
    - assemble 暫存目錄（#562）：5.2 以 `TMPDIR=<本輪 5.2 備份目錄>/assemble-tmp` 執行 assemble，展開後的 manifest 留在該目錄；成功清理時隨備份目錄一起移除，清理失敗時隨備份目錄保留，供 5.2.3 重試。
    - display 檢查：`WAYLAND_DISPLAY` 的絕對路徑或 `${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}` 必須是可讀寫 Unix socket；若不可用，再檢查 X11。本機 `DISPLAY`（`:N[.screen]`、`unix:N[.screen]`、`unix/:N[.screen]`）須有 `/tmp/.X11-unix/XN` socket；非本機 X11 若有 `xdpyinfo`，以 timeout 包住 `xdpyinfo -display "$DISPLAY"`，回非零即不可用。沒有 xdpyinfo 時無法確認非本機 X11，印 warning 後繼續。兩種 display 都不可用時，stderr 印 `[INCONCLUSIVE] item 5.2: no usable Wayland/X11 display; an unlocked desktop is needed, re-run from its graphical session`，exit 3，同樣不建盒、不備份、不改設定。本機 socket 檢查不驗證協定握手或 X11 授權；後續原有視窗證據仍須通過。exit 3 代表未判定，須回到解鎖的圖形桌面重跑，不算通過或產品失敗。獨立 5.2.1／5.2.2／5.2.3 與 5.3 維持原入口行為，尤其還原入口不因鎖定而受阻。
    - 中斷後的還原確認會等待新視窗 shell PID；清理期間忽略 SIGINT／SIGTERM／SIGHUP，因此 Ctrl-C 不會中止提示。可照提示輸入 PID，或按 Ctrl-D（EOF）略過確認。略過時磁碟檔案仍還原、本輪建立的盒子仍清理，但新視窗 reload 證據未通過，印 `restore-window-ok=0`、`restore-ok=0`、`cleanup-rc=1`，回 1 並保留備份；之後用 `just verify realbox --allow-real-box 5.2.3` 互動重試確認。提示也會在 stderr 說明 Ctrl-D 可略過確認。
    - 真實 Ghostty 新視窗的快取是產品行為，與上述 realbox 呼叫分開：setup 寫入的受管 `command` 只帶 `enter.sh`、distrobox 路徑及盒名，不帶 `XDG_CACHE_HOME`。從已執行的 Ghostty 開新視窗時，wrapper 沿用 Ghostty 的環境，不會繼承 realbox 對 assemble 的暫時環境。依 [enter.sh](../script/box/enter.sh) 的 `_first_launch`／`_init_notice`／`_first_init`，若 Docker 的 `State.StartedAt` 顯示盒子從未啟動，就建立或截斷 Ghostty 環境下 `${XDG_CACHE_HOME:-~/.cache}/worktool/<盒名>-init.log`，再寫入啟動及初始化輸出；預設盒名的路徑是 `~/.cache/worktool/dev-init.log`。盒子已啟動過則不走這段初始化 log 寫入。此真實新視窗可能改動真實 init log；5.2.1 將此檔納入備份，5.2.3 逐 byte 還原，原本不存在時刪除，並納入 `restore-files-ok` 核對。產品行為不變；執行驗收時的 `XDG_CACHE_HOME` 必須與 Ghostty 的環境一致。
    - 備份集合（PR #157 說明的第 5 節）：`$XDG_CONFIG_HOME/ghostty/config`（Ghostty legacy config）、`$XDG_CONFIG_HOME/ghostty/config.ghostty`、`$XDG_CONFIG_HOME/worktool/config`（狀態檔）、`$XDG_CONFIG_HOME/distrobox/distrobox.conf`、`${XDG_CACHE_HOME:-~/.cache}/worktool/<盒名>-init.log`（manifest 預設盒名為 dev）；init log 原本不存在時記為 `absent-file`；另以 `absent-directories` 記錄五個受管檔案各自原本不存在的完整上層目錄鏈，例如 `~/missing/config/ghostty` 與 `${XDG_CACHE_HOME:-~/.cache}/worktool`，各自一路記錄到第一個既有祖先前的所有缺失目錄（#589、#626）。`XDG_CONFIG_HOME` 未設時用 `~/.config`，不包含 `~/.tmux.conf`。集合來源是 [config_backup_paths.sh](../script/verify/config_backup_paths.sh) 的 `CFGBK_NAMES`；3.x 的 `tmux.conf=intact` 是不得改動使用者檔案的判準，不代表它列入 5.2 備份。
    - init-log 若是 dangling symlink，備份保留連結本身，manifest 的 `.tpath` 記錄解析後的絕對目標路徑，以空的 `.tsha` 記錄目標原本不存在；無法確定目標是否不存在時拒絕備份，不發布 manifest。套用前重新校驗連結仍相同且目標仍不存在；5.2.3 還原連結，並刪除原本不存在、驗收期間才建立的目標檔，最後核對連結仍為 dangling 且該目標路徑不存在（含不得殘留 symlink）。刪除或核對失敗均回非零並保留備份，不以「連結文字相同」當作還原成功（#588）。
    - cache 路徑：`XDG_CACHE_HOME` 未設或為空時用 `~/.cache`。非絕對路徑的 `XDG_CACHE_HOME` 不會單憑此條件拒絕備份；缺失父目錄鏈以備份當時工作目錄為基準，經 `readlink -m` 正規化為絕對路徑後記錄，因此該目錄鏈可從其他工作目錄還原。這不會將 `cfgbk_file_of` 的 init-log 路徑改為絕對路徑，檔案操作仍依呼叫時的環境與工作目錄解析；驗收與重試應維持相同環境及工作目錄，不應解讀成所有相對路徑檔案均可跨工作目錄還原。正規化、目錄記錄或 mtime 讀取失敗時備份回非零，不發布 manifest（#589）。
    - 目錄 mtime（#526）：5.2.1 同時記錄備份集合內各檔案（含原本不存在的檔案）及 symlink 目標的既有上層目錄 mtime，HOME 內的路徑一路記錄至 HOME（含 HOME），保留 #526 的既有保證。HOME 外的受管路徑只記錄至其 `XDG_CONFIG_HOME` 或 `XDG_CACHE_HOME` 根目錄（含根目錄）；HOME 外的 symlink 目標只記錄解析後目標的直接父目錄，不向上延伸。根目錄與父目錄以正規化後的路徑判定；備份集合中原本存在的直接父目錄仍受保護，一般路徑依 #536 不記錄、不核對，也不恢復設定根目錄以上的系統目錄 mtime；但五個受管檔案的缺失父目錄鏈各自另記錄第一個既有祖先的 mtime，移除目錄鏈後還原並核對。第一個既有祖先可能高於 config 或 cache 根目錄，例如 HOME，或 HOME 外 config／cache 路徑的既有祖先；例如 `XDG_CONFIG_HOME=/x/missing/config` 且 `/x` 是第一個既有祖先時，記錄並還原 /x 的 mtime，這是 #589 引入、#626 擴及五個受管檔案的 #536 範圍例外。5.2.3 還原時，live 檔案與備份的類型、內容、mode 與連結目標均相同就略過，不刪除、不重建，inode 不變；symlink 及其目標各自比對。需要重建或刪除檔案時，所有檔案、本輪新增設定目錄與五個受管檔案的缺失父目錄鏈處理完後才恢復既有目錄 mtime，最後核對全部記錄。判準包含 `~/.config`、`~/.config/ghostty`、`~/.cache/worktool` 與集合內其他檔案的既有上層目錄 mtime 回到備份值；本輪建立後刪除的目錄不在判準內。目錄 mtime 不一致時 `restore-files-ok=0`、`restore-ok=0`，回非零並保留備份。已知限制：除上述五個受管檔案缺失父目錄鏈的第一個既有祖先外，設定根目錄以上的目錄 mtime 不受保護；執行期間其他程式若改動記錄範圍內的目錄，mtime 可能被恢復成備份值，或在核對時被誤判為還原失敗。
    - 5.2.1 備份前先檢查兩份 Ghostty 設定檔（legacy `config` 與 `config.ghostty`）：任一份含 worktool 受管區塊就拒絕，stdout 只印 `baseline-managed-ghostty=1`，回非零；不建立任何備份、不套用、不改動任何設定檔。stderr 說明此基準還原後可能正確進入原本的盒子，無法符合 host 新視窗判準，並指示先移除受管區塊（例如執行 `just box setup --terminal none`），再重跑 5.2。5.2 套用時明確執行 `just box setup --terminal ghostty --auto-enter yes --box <manifest 盒名>`，啟用 Ghostty 自動進入 manifest 的盒子，不沿用已保存的 terminal、auto-enter 或盒名選擇；結束後由既有五檔備份還原原本的設定與使用者選擇，狀態檔仍須與備份前逐 byte 相同。受管區塊以外的內容與其他設定檔的既有內容仍照原規則保留、備份與還原。
    - 預期看到資訊（無 Ghostty 受管區塊的基準）：`backup-covers=5/5`；每個 manifest key（清單以 `script/verify/config_backup_paths.sh` 為來源，守門 spec 與真實 setup 寫檔集合比對，另加真實新視窗的 init log）印 `regular`／`symlink`／`absent-file`／`absent-dir` 與對應 checksum／link 明細。其後有 `revalidate=1`、`preexisting-dev=0`、setup／status 輸出及 `setup-rc=0`。
      `user-content after-apply: ghostty=intact config.ghostty=intact distrobox.conf=intact` 在還原前檢查。worktool 狀態由 lib/config.sh 共用，HOME／link 保留由 3.2 驗；host 的 tmux.conf 不再是受管檔或備份對象（PR #228、#232）。
      還原先印 `restore-rc=0`、`restore-files-ok=1`，接著在 stdout 提示重新載入還原後的 Ghostty 設定（Linux 預設 `Ctrl+Shift+,`），等待使用者確認 reload 後新視窗的 shell PID。成功依序印 `restore-window-evidence: pid=<PID> comm=<shell> host=mnt:[<host>] window=mnt:[<host>] enter=absent`、`restore-window-ok=1`、`restore-ok=1`、`blocks=<執行前的區塊總數>`、`leftover-dirs=0`、`dev-gone=1`、`backup-removed=1`、`cleanup-rc=0`。還原判準是內容與執行前基準逐 byte 相同（含原本不存在的檔案），Ghostty 的既有受管區塊已在 5.2.1 拒絕，其他設定檔的既有受管區塊不算失敗；`blocks` 只報告區塊數，讀取失敗仍回非零。兩個 Ghostty 檔共用目錄，還原先移掉原本不存在的檔案，再還原目錄，避免 sibling 阻擋移除。所有受管檔案還原後，五個受管檔案原本不存在的上層目錄鏈依正規化路徑反向排序（`LC_ALL=C sort -zru`）去重，由最深層往上以 `rmdir` 移除；只移除空目錄，非空目錄保留，還原 fail closed，回非零並保留備份供重試（#589、#626）。`leftover-dirs=N` 計算這些記錄與舊版 manifest 的原本不存在受管設定目錄中仍存在的路徑（含被換成 symlink 的路徑），共用路徑只計一次，N 非零就失敗。還原失敗保留備份。`restore-files-ok=1` 只代表磁碟檔案已還原；reload 證據未通過時印 `restore-window-ok=0`、`restore-ok=0`，回非零，不印 `backup-removed=1`。
    - 驗收方式
      ```bash
      just verify realbox --allow-real-box 5.2; echo rc=$?
      # 中斷時的還原手段：
      just verify realbox --allow-real-box 5.2.3; echo rc=$?
      ```
      預期 `rc=0`。5.2 套用與 5.2.3 還原都需互動 tty 輸入新視窗 PID；沒有 tty 回非零，仍還原磁碟檔案並清理本輪擁有的盒子，但保留備份供互動重試。沒有備份時 5.2.3 的 stdout 只印 `no-backup=1`；備份路徑不存在與可能原因的說明以 `[INFO]` 寫到 stderr。備份使用帶 uid 的專屬目錄，既有目錄或 symlink 都拒絕；套用僅信任已發布 manifest，重新校驗 checksum 後才建盒。所有權沿用 5.1 的「assemble 前確認不存在、執行後確認存在」證據；assemble 嘗試紀錄不代表所有權，中斷也須在子行程停止後確認，清理會判斷盒是否真的消失。
      先讓 Ghostty 保持執行，再由本項套用設定，以涵蓋「Ghostty 已在執行時套用」的情境。套用後先重新載入設定（Linux 預設 `Ctrl+Shift+,`）；重新載入是非同步的，等 Ghostty log 等證據確認已讀入 `config.ghostty` 再開新視窗，也可啟動新的 Ghostty 行程。不得關閉使用者既有視窗。
      新視窗中執行 `echo $fish_pid`，把 PID 輸入驗收提示。腳本從 host 探測 `ps -p <PID> -o comm=` 與 `/proc/<PID>/ns/mnt`，必須是套用前行程清單中不存在的 fish，且 mount namespace 不同於 host、等於本輪 dev 容器的 mount namespace。腳本依 distrobox 使用的容器引擎設定解析引擎，以 `<engine> exec <box> readlink /proc/self/ns/mnt` 在本輪 dev 盒內讀取 mount namespace，建立 dev 身分；一般使用者搭配 rootful Docker 時，無法從 host 讀取 root 行程的 namespace，因此改由引擎在盒內讀取。成功輸出 `window-evidence: pid=<PID> comm=fish host=mnt:[<host>] window=mnt:[<box>] dev=mnt:[<box>]`；只回答 `yes`、既有行程、host namespace、另一個盒的新 fish、無法解析引擎、engine exec 失敗、dev namespace 輸出不是 `mnt:[<數字>]`、與視窗 fish 的 namespace 不一致、讀取失敗（含權限不足或行程已結束）、空值或格式錯誤都回非零並還原。視窗確實來自 Ghostty 與主觀無明顯延遲仍由人觀察，但不能代替客觀進盒證據（#362、#433）。
      還原後也必須 reload：等 Ghostty log 等證據確認已讀入還原後設定，再從執行中的 Ghostty 開新視窗。fish 執行 `echo $fish_pid`，POSIX shell 執行 `echo $$`，將 PID 輸入還原提示；輸入 PID 同時確認已完成 reload 與開新視窗，僅回答 `yes` 不算證據。腳本要求 PID 不在還原提示前的行程清單中、mount namespace 等於 host，並以 `ps -p <PID> -o ppid=,args=` 逐層追查至 Ghostty；祖先鏈含 `script/box/enter.sh`、仍在盒內、既有 PID 或無法讀取證據均 FAIL。這裡不以 process list 猜測 Ghostty PID 發送訊號，也不關閉或改動既有視窗或行程；沒有套用紀錄的備份還原（例如 5.3 拒絕套用）無須 reload 新視窗驗證。
  - [ ] 5.3 先建同名 dev 盒，證明 5.1 與 5.2 套用都拒絕，既有盒始終不被刪除。最後清理本輪建立的 decoy，`decoy-cleanup-rc` 與 5.1 相同，納入盒子、獨立 HOME、host 狀態與 scratch 的最終結果後只印一次；任何一步失敗都印 1、回非零，HOME 或 host 狀態失敗時保留 scratch 與未知資料。
    - decoy create 失敗（包含檢查後發生的同名衝突）時，不取得刪盒權、不呼叫 `distrobox rm`；印出所有權未確認的診斷與 `decoy-cleanup-rc=1`，保留盒子與 scratch 供人工檢查。
    - create 成功後，沿用 5.1／5.2 的 `guard_box_id` 所有權確認路徑，將容器 ID 記入 scratch 的 `created-box` 才取得刪盒權。清理前重新查詢 ID；ID 不同、盒子不存在、查詢失敗或輸出無法解析時，不呼叫 `distrobox rm`，印出原因與 `decoy-cleanup-rc=1`，保留 scratch 與所有權證據供人工檢查。仍有「確認 ID 相同」到「按名稱執行 `distrobox rm -f dev`」之間的競態窗口；distrobox 此入口無法按 ID 刪除，執行驗收時應避免其他操作同時建立或替換同名盒。
    - 拒絕套用後的還原也遵守 5.2 的目錄 mtime 與 inode 判準：所有既有上層目錄 mtime 不變；與備份相同的檔案、symlink 及其目標保持原 inode。`restore-files-ok=1`／`restore-ok=1` 包含目錄 mtime 核對，不能只以內容相同判定成功；其他程式同時改動目錄的已知限制同 5.2。
    - 預期看到資訊：`preexisting=dev`、`51-rc=1`；備份摘要同 5.2（`backup-covers=5/5`），`revalidate=1` 後套用拒絕，印 `52-rc=1`。接著還原依序印 `restore-rc=0`、`restore-files-ok=1`、`restore-ok=1`、`blocks=<執行前的區塊總數>`、`leftover-dirs=0`、`dev-untouched=1`、`backup-removed=1`、`cleanup-rc=0`，最後確認既有盒仍在，印 `still-there=dev`；本項最後只清除自己建的 decoy。
    - 驗收方式
      ```bash
      just verify realbox --allow-real-box 5.3; echo rc=$?
      ```
      預期 `rc=0`；本項最初就遇到既有 dev 時直接拒絕，不取得所有權。
  - [ ] 5.4 自動完成 assemble／bench × SIGINT／SIGTERM／SIGHUP 實機中斷矩陣，不需要人按鍵。每格在獨立 session／行程群組啟動原有 5.1；指定 `--comment-tag` 時原樣轉發給內層 5.1，省略時不帶此參數。assemble 以 distrobox list 觀察盒子出現，查詢返回後及送訊號前都再次確認 capture 尚無 `phase=first-start` 或 `phase=bench`（若已進入首次初始化或 bench 或送訊號前無法讀取 phase 證據就判失敗，不送該格指定的訊號，改以 TERM 收尾），bench 格先完成首次初始化與既有 quiet-wait，初始化進度與 `phase=first-start` 不算 bench 事件；bench 以實際 `[INFO] psi before enter run ...` 或 `[INFO] enter: ... done` 診斷行決定時點。觀察 deadline 為 1800 秒，中斷後須在 180 秒內完成，逾時即失敗並停止本輪 session；deadline 只限制等待，絕不依 sleep 或經過時間送出訊號。每格先拒絕既有同名盒，5.1 保持只刪本輪盒與 #511／#516 的 XDG 隔離。
    - 通過的格必須回 130／143／129，捕捉到 `cleanup-rc=0`、`box-state after-cleanup: home=0 tmux=0`、`host-state after-cleanup: new=0`，再次查詢確認盒已移除、獨立 HOME 不存在，並確認該 session 無仍能執行的子行程。訊號前後以 `gh issue view --json comments` 比對完整留言 ID 集合，集合不變且沒有 `posted=` 回報才算沒有發出 #22 留言；若其他使用者同時留言也會失敗，須重跑。查詢失敗不能當作集合為空。
    - bench 格的內層 5.1 因主機忙碌回 3 時（含尚未出現可中斷事件就結束），依 ADR 0003 分類為未判定；仍須通過上述全部清理、盒子／HOME／session 與留言檢查。該格印 `interrupt bench <signal>: INCONCLUSIVE (rc=3; cleanup-rc=0; host too busy, re-run when idle)`，原始 5.1 輸出送到 stderr，不印該格 FAIL 或 PASS，繼續其餘格。任何格或清理真正失敗仍優先 exit 1；沒有失敗但至少一格未判定時，移除本輪證據目錄後印 `interrupt-matrix: INCONCLUSIVE (host too busy, re-run when idle)`、exit 3，代表「未判定、請在閒置時重跑」。只有六格全部通過才印 `interrupt-matrix: PASS (6/6)`、exit 0。
      `just verify realbox --allow-real-box 5.4` 與 5.1 相同，保留 exit 3、不加印 `[FAIL] item 5.4 failed`；無項目或指定多項目的 realbox 遇到未判定即停止後續項目。`just verify all` 不執行或彙整 realbox（須在實機明確 opt-in），其 PASS 只涵蓋非實機組，不能代替 5.4 的結果；5.4 未判定須另行重跑實機入口。
    - 剩餘非原子窗口：外部 5.1 的 phase marker 寫入與 supervisor 的檢查、送訊號無法原子化。assemble 在送訊號後立即再讀 capture；若此時出現 `phase=first-start`、`phase=bench` 或讀取失敗，無法確定切換與訊號的先後，保守回報 `signal-phase=unknown` 並判該格失敗，絕不列為 assemble PASS；這也可能拒絕實際仍打在 assemble 的訊號，須重跑。送訊號前已看到 bench 時不印指定訊號的 `signal-phase`。`signal-phase=assemble` 只代表前後觀察均未見首次初始化或 bench，不是原子同步的保證；marker 尚未寫入或在訊號後檢查完成才變更的窗口仍存在。bench 格的事件判定與內層 rc=3 分類不變。
    - stdout 成功輸出如下（每格逐行比對；`<ms>` 是實測的非負整數）。每格送訊號後印出 `signal-phase`（訊號前後觀察一致的 assemble／bench 階段）與 `signal-after-ms`（從子行程啟動到送訊號的毫秒數，以 Bash `EPOCHREALTIME` wall clock 計算），緊鄰結果行；成功刪除證據目錄後仍保留這些 stdout 欄位。任一格失敗即停止、回 1，印該格 `FAIL (rc=...; cleanup-rc=...; evidence=...)` 與 `interrupt-matrix: FAIL`；子行程啟動前失敗（既有同名盒被拒或盒狀態查詢失敗、留言快照查詢失敗、證據目錄或 capture 建立失敗）也印 `interrupt <phase> <signal>: FAIL (<reason>)` 與 `interrupt-matrix: FAIL`，不啟動 5.1。原始 5.1 輸出送到 stderr，本輪證據與尚存的盒／HOME 保留供檢查。不宣稱涵蓋每行指令間的中斷，也不替代人類 Ctrl-C 主觀體驗。
      ```text
      interrupt assemble INT: signal-phase=assemble signal-after-ms=<ms>
      interrupt assemble INT: rc=130 cleanup-rc=0 box-gone=1 home=0 tmux=0 host-new=0 posted=0 PASS
      interrupt assemble TERM: signal-phase=assemble signal-after-ms=<ms>
      interrupt assemble TERM: rc=143 cleanup-rc=0 box-gone=1 home=0 tmux=0 host-new=0 posted=0 PASS
      interrupt assemble HUP: signal-phase=assemble signal-after-ms=<ms>
      interrupt assemble HUP: rc=129 cleanup-rc=0 box-gone=1 home=0 tmux=0 host-new=0 posted=0 PASS
      interrupt bench INT: signal-phase=bench signal-after-ms=<ms>
      interrupt bench INT: rc=130 cleanup-rc=0 box-gone=1 home=0 tmux=0 host-new=0 posted=0 PASS
      interrupt bench TERM: signal-phase=bench signal-after-ms=<ms>
      interrupt bench TERM: rc=143 cleanup-rc=0 box-gone=1 home=0 tmux=0 host-new=0 posted=0 PASS
      interrupt bench HUP: signal-phase=bench signal-after-ms=<ms>
      interrupt bench HUP: rc=129 cleanup-rc=0 box-gone=1 home=0 tmux=0 host-new=0 posted=0 PASS
      interrupt-matrix: PASS (6/6)
      ```
    - 驗收方式：
      ```bash
      just verify realbox --allow-real-box 5.4; echo rc=$?
      ```
      預期 `rc=0`。無參數的 realbox 現在依序執行 5.1–5.4；5.4 本身不發留言。

  realbox 監督的命令收到中斷後，若停止行程群組失敗，或停止函式回報成功但群組仍有存活成員，會回報 `configuration restore refused`、exit 1，並嘗試以 KILL 清除存活成員；即使補救成功，也不會進入會改動設定的還原或清理。保留本輪備份、scratch 與診斷中的 `wt-verify-guard.*` 目錄，供人工確認行程已停止後再復原。停止成功時，原有訊號退出碼、容器清理與還原流程維持不變。驗證：`test/unit/verify_realbox_spec.bats` 的 `5.2: failed group stop after real TERM refuses config restore and kills survivors`，`5.2: surviving group after successful stop report refuses config restore`，以及既有 realbox／verify_run 中斷案例。

  realbox 自己的 5.1 assemble／首次初始化／bench、5.2 assemble 與 5.3 decoy create 將 `XDG_DATA_HOME` 指到本輪 scratch／備份目錄的 `data`，刪盒也使用同一路徑。Docker 中固定 distrobox 1.8.2.5 的真實 create／generate-entry 驗證 desktop entry 與 Ubuntu 圖示落在該目錄，清理後隨本輪目錄移除。host `${XDG_DATA_HOME:-~/.local/share}/applications` 與 `icons/distrobox` 保持執行前的內容與 mtime，原本不存在時仍不存在；不以刪除 host 匯出檔案補救。
  PR #228 後盒 HOME 獨立且建盒後固定。5.1 用本輪 scratch 下的 `box-home`；5.2 用備份目錄下的 `box-home`；5.3 的 decoy 也用本輪 scratch 下的 `box-home`。user config 連結只落在該 HOME。realbox 在建盒前記錄 host 預設目錄（`~/<盒名>-box`，dev 為 `~/dev-box`）的既有項目；還原時先刪除本輪建立的盒子，再回報 host 預設目錄的清理前／後新增項目數，所有權僅限本輪明確指定的獨立 `box-home`；基準差異與 `created-box` 都不能證明 host 預設目錄內路徑的歸屬。該目錄的所有新增項目（含目錄、檔案、symlink 與 socket）一律保留，stdout 印 `host-state kept-unknown=<新增項目數>`（正常為 `0`），stderr 逐項列出路徑；若數量非零，清理後仍印 `host-state after-cleanup: new=<新增項目數>` 並回非零，保留備份供檢查與重試。5.1、5.2、5.3 共用此規則，本輪獨立 HOME 仍會先清除。5.2.3 缺少 `created-box` 代表本輪未確認盒子所有權（未執行 assemble、失敗且未建出盒子，或尚未確認列表；有嘗試紀錄但沒有本輪記錄的 ID 時，不得因同名盒存在而取得所有權；拒絕刪盒、保留嘗試紀錄並回非零，留給使用者手動處理）；確認仍無所有權時，stdout 只印 `dev-untouched=1` 與 `host-state untouched: new=<新增項目數>`，不清理 host 預設目錄；本輪未確認所有權、保留所有盒的說明以 `[INFO]` 寫到 stderr，5.3 的還原也相同；5.2.1 之後由使用者新增的檔案、symlink、目錄與 socket 全部保留，新增項目不視為本輪殘留。自訂盒 HOME（含 `.cache/tmux` 下的 socket 目錄）也回報清理前／後是否存在，清理後必須不存在。刪盒或狀態清理失敗會回非零並保留尚未清除的盒 HOME 與備份供重試；`leftover-dirs=0` 代表五個受管檔案原本不存在的完整上層目錄鏈均無殘留，不能單獨證明盒內狀態已清乾淨。產品預設 HOME 與 config 的保存／回報由 3.2 驗。

- [ ] 6. CI 與流程(gh / grep 查外部證據)
  - [ ] 6.1 一個 sub-issue 一個 PR、兩架構 CI:10 個 PR 各恰好一行 `Closes #`(互不相同);每個 PR 有 checks 且全 pass;#153 起每個 PR 同時有 amd64(ubuntu-latest)與 arm64(ubuntu-24.04-arm)的 check,兩邊的 check 名稱數量相等且完全不重疊
    - 預期看到資訊（動態示例：`total`、`amd`、`arm` 隨查詢當時的 check 集合變動，不逐字比對示例數字）
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
      ```text
      #152 total=8 nonpass=0 amd=0 arm=0 both=0 closes=1 issue=#151
      #153 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#149
      #154 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#150
      #155 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#21
      #156 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#23
      #165 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#164
      #166 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#163
      #167 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#160
      #168 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#161
      #169 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#162
      distinct=10
      rc=0
      rc=0
      ```
      (固定判準：`total>0`、`nonpass=0`、`closes=1`、issue 對應與 `distinct=10`；#153 起 `amd=arm>0` 且 `both=0`。上列 8／15 是舊輪次示例，issue #427 記錄的 CI 證據為 #152=9，#153／#156／#167=16；均不是固定總數。
      6 的三項各有兩行 `rc=`:第一行是 `script/verify/evidence.sh` 自己印的彙總判定,第二行是本項 `echo rc=$?`,兩者必須相同。任何一次 gh 查詢失敗、或任何欄位不符 —— total=0 / nonpass>0 / closes!=1 / #153 起 amd 與 arm 不相等或 both>0 —— 兩行就都是 1。
      `amd` / `arm` 數的是**相異的 check 名稱**,`both` 是同時算進兩邊的名稱數:「兩個架構」講的是兩組互斥的 check,不是「有字串對到 ubuntu-latest」加上「有字串對到 ubuntu-24.04-arm」—— 只用兩個各自獨立的子字串判斷的話,一個叫 `lint (ubuntu-latest, ubuntu-24.04-arm)` 的 check 會同時滿足兩邊,只跑了一個 job 的 PR 照樣印出 `amd=1 arm=1` 過關)
    - 驗收方式
      ```bash
      just verify evidence 6.1; echo rc=$?
      ```
  - [ ] 6.2 決策與研究都在 issue 上,且是具體結論:#22 的 [claude] 留言有實測 `median=.. ms` 與「維持 docker + 預設 runc」;#148 有「只用 LTS」與「ubuntu-24.04-arm」;#21 有「預設 = 直接進盒」與「印 log」
    - 預期看到資訊(每行數字 >= 1)
      輸出類型：動態示例；編號、數量、SHA、行號與實測值不逐字比對，固定判準依本項說明。
      ```text
      #22 median-ms:1 runc:1
      #148 lts-only:1 arm-runner:1
      #21 default-enter:1 log:1
      rc=0
      rc=0
      ```
      (查詢用 `--paginate`:留言超過 100 則之後才不會因為只看第一頁而漏掉。任何一格不是 `1`、或任何一次 `gh` 查詢失敗(該格印 `gh-failed`)都讓整段 `rc=1` —— 舊版把 `gh` 的失敗當成「找不到」而印 `0` 卻仍 rc=0,和 2.2 / 6.1 / 6.3 的 fail-closed 不一致)
    - 驗收方式
      ```bash
      just verify evidence 6.2; echo rc=$?
      ```
  - [ ] 6.3 codex:#156、#165-#169 的最後一則 [codex] 留言判定行是「可合併」;#152-#155 是配額恢復後的補複驗,最後一則 [codex] 判定「不可合併」,各自的阻擋項記錄在 follow-up issue(#163 / #164 / #162 / #161,由原 PR 上的 [claude] 留言指向),而修正該 issue 的 PR(#166 / #165 / #169 / #168)必須 Closes 正是那個 issue,且該 PR 自己的最後 [codex] 判定「可合併」
    - 預期看到資訊
      輸出類型：固定判準（逐字比對）。
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
      distinct-follow-ups=4 distinct-fix-prs=4
      rc=0
      rc=0
      ```
      (失敗時的樣子:判定是「不可合併」印 `blocked`、沒有判定行印 `NOT`、`gh` 查詢本身失敗印 `gh-failed`,配對不成立是行尾 `BAD`,查不到對應關係是 `#N no-follow-up` / `#N no-fix-pr`,最後都 `rc=1`。
      `distinct-follow-ups` / `distinct-fix-prs` 必須都是 4:四個被擋的 PR 各要有**自己的** follow-up issue 與修正 PR。這兩個計數跨整個項目累計,不是每個 PR 重新算一次 —— 每個 PR 重算的話,同一個 issue 加同一個 PR 可以把四行都餵飽,四行各自看起來都自洽、也都印 `ok`,但其中三個阻擋項其實哪裡都沒記錄。round 12:舊版的 `v()` 是 `gh ... | grep ... | tail -1`,結束碼來自 `tail`,所以「印得出判定行卻 exit 1 的 gh」會讓六個 PR 全部讀成 mergeable —— 現在 gh 的輸出先收進變數、先判它自己的結束碼,`gh-failed` 因此和「判定不是可合併」分得開)
    - 驗收方式
      ```bash
      just verify evidence 6.3; echo rc=$?
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
