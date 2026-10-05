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
本 PR(#157)相對 main 的改動範圍（`origin/main...m3/5-acceptance`）包含驗收清單與證據（`doc/acceptance.md`、`doc/evidence/`）、300 ms 門檻措辭同步（`doc/design.md`、`doc/enter.md`、`doc/manifest.md`；≤ 300 ms）、ADR 0008／0010 的措辭、驗收程式與入口（`script/verify/`、`justfile`）、建盒預設 fish（`script/box/assemble.sh`；#472）、產品共用程式（`lib/config_backup.sh`、`lib/guard.sh`、`lib/home.sh`、`lib/distrobox_manager.sh`；後者由 `lib/home.sh` 抽出，行為不變）、測試入口與完整歷史 checkout（`script/test/test.sh`、`.github/workflows/ci.yml`）與相關測試（`test/unit/verify_*_spec.bats`、`test/unit/test_sh_spec.bats`、`test/unit/justfile_spec.bats`、`test/unit/enter_spec.bats`、`test/unit/fixture/`、`test/helper/`、`test/system/real_engine_spec.bats`）。**`just verify` namespace 與 `script/verify/` 只在本 PR 分支上**，所以下面直接 clone 本 PR 分支 `m3/5-acceptance`（= main 加上述變更）。clone 成 main 的話，每個區塊都會是 just 自己的 `Justfile does not contain recipe`（rc=1），什麼都不會跑。

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
      ...(每層的 N 由來源掃描取得，1..N 全部 ok,各以 `[ci] <tier> bats OK` 結尾;沒有 not ok、沒有 # skip)
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

- [ ] 5. 實機（需要 host 有 distrobox + ghostty；會以 `--home` 在本輪 scratch／backup 目錄內建 dev 盒的獨立 HOME 與 user config symlink，並改動真實設定）。5.1 以 scratch 內的 `XDG_CONFIG_HOME` 隔離 assemble 狀態寫入，並連結真實 config 目錄中除 `worktool/` 以外的所有頂層項目（含隱藏項目），讓 assemble、bench 與清理沿用相同的容器工具儲存位置、連線設定、container manager、使用者設定與 TMUX 隔離區塊；成功、失敗及中斷都不改動真實狀態檔（原本不存在時仍不存在）。5.1／5.2 先拒絕既有同名盒，清理只刪自己建立的盒。5.2 在建盒前備份 setup 可能寫入的四個檔：Ghostty legacy config、config.ghostty、worktool 狀態檔、distrobox.conf（PR #232、#351）；任何檔備份不了就拒絕。symlink 及其目標一起備份，還原前確認受管檔的使用者內容仍在。清理失敗回非零；host 沒有 Ghostty 時 5.2 保持未勾。
  - [ ] 5.1 進盒延遲 ≤ 300 ms(以 fish 為準);由 `script/verify/realbox.sh` 自己把三行數字發到 #22,再依留言 id 讀回來比對本輪識別碼與三行數字;中斷(Ctrl-C)與正常結束都會清掉自己建立的盒子,清不掉就失敗。中斷仍為失敗：SIGINT 回 130、SIGTERM 回 143、SIGHUP 回 129，不以清理成功當作驗收通過。
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
      `posted=1` 的判準有三個,缺一不可:那則留言在 #22 上、帶本輪 `run` 識別碼、而且**逐字**含本輪量到的三行。舊留言再像也命不中(#176 item 3);上一版用 `?per_page=100` 不翻頁,#22 留言超過 100 則之後會無故變紅,改成依 id 直接取那一則就沒有這個問題。`cleanup-rc=1` 會讓本項 exit 非 0 並要你手動移除盒子。所有權標記在 `just box assemble` **之前**就寫下,意思是「這一輪動過 assemble」而不是「assemble 成功了」,所以 assemble 跑到一半被 Ctrl-C 一樣會清;反過來「標記在、盒子不在」是被接受的,清理只看最後盒子還在不在,`distrobox rm` 沒東西可刪不算失敗(round 10))
    - 驗收方式
      ```bash
      just verify realbox --allow-real-box 5.1; echo rc=$?
      ```
  - [ ] 5.2 開終端即在盒內 fish，主觀無明顯延遲；一次呼叫依序備份、套用、確認新視窗、還原。中斷後單獨跑 5.2.3 還原。
    - 備份集合（PR #157 說明的第 5 節）：`$XDG_CONFIG_HOME/ghostty/config`（Ghostty legacy config）、`$XDG_CONFIG_HOME/ghostty/config.ghostty`、`$XDG_CONFIG_HOME/worktool/config`（狀態檔）、`$XDG_CONFIG_HOME/distrobox/distrobox.conf`；`XDG_CONFIG_HOME` 未設時用 `~/.config`，不包含 `~/.tmux.conf`。集合來源是 [config_backup_paths.sh](../script/verify/config_backup_paths.sh) 的 `CFGBK_NAMES`；3.x 的 `tmux.conf=intact` 是不得改動使用者檔案的判準，不代表它列入 5.2 備份。
    - 預期看到資訊：`backup-covers=4/4`；每個 manifest key（清單以 `script/verify/config_backup_paths.sh` 為來源，守門 spec 與真實 setup 寫檔集合比對）印 `regular`／`symlink`／`absent-file`／`absent-dir` 與對應 checksum／link 明細。其後有 `revalidate=1`、`preexisting-dev=0`、setup／status 輸出及 `setup-rc=0`。
      `user-content after-apply: ghostty=intact config.ghostty=intact distrobox.conf=intact` 在還原前檢查。worktool 狀態由 lib/config.sh 共用，HOME／link 保留由 3.2 驗；host 的 tmux.conf 不再是受管檔或備份對象（PR #228、#232）。
      還原成功依序印 `restore-rc=0`、`restore-ok=1`、`blocks=<執行前的區塊總數>`、`leftover-dirs=0`、`dev-gone=1`、`backup-removed=1`。還原判準是內容與執行前基準逐 byte 相同（含原本不存在的檔案），既有受管區塊不算失敗；`blocks` 只報告區塊數，讀取失敗仍回非零。兩個 Ghostty 檔共用目錄，還原先移掉原本不存在的檔案，再還原目錄，避免 sibling 阻擋移除。還原失敗保留備份。
    - 驗收方式
      ```bash
      just verify realbox --allow-real-box 5.2; echo rc=$?
      # 中斷時的還原手段：
      just verify realbox --allow-real-box 5.2.3; echo rc=$?
      ```
      預期 `rc=0`。5.2 需互動 tty 輸入新視窗的 fish PID；沒有 tty 回非零並仍執行還原。沒有備份時 5.2.3 的 stdout 只印 `no-backup=1`；備份路徑不存在與可能原因的說明以 `[INFO]` 寫到 stderr。備份使用帶 uid 的專屬目錄，既有目錄或 symlink 都拒絕；套用僅信任已發布 manifest，重新校驗 checksum 後才建盒。所有權記錄先於 assemble，清理會判斷盒是否真的消失。
      先讓 Ghostty 保持執行，再由本項套用設定，以涵蓋「Ghostty 已在執行時套用」的情境。套用後先重新載入設定（Linux 預設 `Ctrl+Shift+,`）；重新載入是非同步的，等 Ghostty log 等證據確認已讀入 `config.ghostty` 再開新視窗，也可啟動新的 Ghostty 行程。不得關閉使用者既有視窗。
      新視窗中執行 `echo $fish_pid`，把 PID 輸入驗收提示。腳本從 host 探測 `ps -p <PID> -o comm=` 與 `/proc/<PID>/ns/mnt`，必須是套用前行程清單中不存在的 fish，且 mount namespace 不同於 host、等於本輪 dev 容器的 mount namespace。腳本依 distrobox 使用的容器引擎設定，以 `inspect --type container --format '{{.State.Pid}}' dev` 取得 init 的 host PID，再讀 `/proc/<init PID>/ns/mnt` 建立 dev 身分。成功輸出 `window-evidence: pid=<PID> comm=fish host=mnt:[<host>] window=mnt:[<box>] dev=mnt:[<box>]`；只回答 `yes`、既有行程、host namespace、另一個盒的新 fish、無法解析 dev namespace（含引擎不可用、inspect 失敗、init PID 無效）、讀取失敗（含權限不足或行程已結束）、空值或格式錯誤都回非零並還原。視窗確實來自 Ghostty 與主觀無明顯延遲仍由人觀察，但不能代替客觀進盒證據（#362、#433）。
  - [ ] 5.3 先建同名 dev 盒，證明 5.1 與 5.2 套用都拒絕，既有盒始終不被刪除
    - 預期看到資訊：`preexisting=dev`、`51-rc=1`；備份摘要同 5.2（`backup-covers=4/4`），`revalidate=1` 後套用拒絕，印 `52-rc=1`。接著還原依序印 `restore-rc=0`、`restore-ok=1`、`blocks=<執行前的區塊總數>`、`leftover-dirs=0`、`dev-untouched=1`、`backup-removed=1`，最後確認既有盒仍在，印 `still-there=dev`；本項最後只清除自己建的 decoy。
    - 驗收方式
      ```bash
      just verify realbox --allow-real-box 5.3; echo rc=$?
      ```
      預期 `rc=0`；本項最初就遇到既有 dev 時直接拒絕，不取得所有權。
  PR #228 後盒 HOME 獨立且建盒後固定。5.1 用本輪 scratch 下的 `box-home`；5.2 用備份目錄下的 `box-home`；5.3 的 decoy 也用本輪 scratch 下的 `box-home`。user config 連結只落在該 HOME。realbox 在建盒前記錄 host 預設目錄（`~/<盒名>-box`，dev 為 `~/dev-box`）的既有項目；還原時先刪除本輪建立的盒子，再回報 host 預設目錄的清理前／後新增項目數，僅移除基準清單之外的項目，不跟隨 symlink，保留既有目錄、檔案與 socket。5.2.3 若沒有 `created-box` 所有權標記（本輪未啟動 assemble），stdout 只印 `dev-untouched=1` 與 `host-state untouched: new=<新增項目數>`，不清理 host 預設目錄；本輪未建盒、保留所有盒的說明以 `[INFO]` 寫到 stderr，5.3 的還原也相同；5.2.1 之後由使用者新增的檔案、symlink、目錄與 socket 全部保留，新增項目不視為本輪殘留。自訂盒 HOME（含 `.cache/tmux` 下的 socket 目錄）也回報清理前／後是否存在，清理後必須不存在。刪盒或狀態清理失敗會回非零並保留尚未清除的盒 HOME 與備份供重試；`leftover-dirs=0` 只代表受管設定目錄，不能單獨證明盒內狀態已清乾淨。產品預設 HOME 與 config 的保存／回報由 3.2 驗。

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
