# 0001 可執行腳本改用 `set -euo pipefail`

- 狀態：已採納（2026-09-29）
- 討論：#195（維護者決策）；撤回舊規則的是 #188

## 背景

`script/box/{assemble,bench,setup,status}.sh` 與 `script/test/{test,selfcheck,system-real-entry}.sh` 七支可執行腳本原本都是 `set -uo pipefail`，刻意不開 `-e`，檔頭寫著「Exit-code-contract script ... (no `-e`)」。理由是退出碼是對外契約：`doc/structure.md`、`doc/enter.md`、`doc/manifest.md` 記載的 0／1／2（`bench.sh` 另有 127），而 `-e` 會讓預期中的非零結果（`grep` 找不到、探測失敗、`distrobox` 的回傳碼）直接中止腳本，回報不出正確的狀態。PR #188 一度把這條「不用 `-e`、失敗靠手動檢查」寫進 `AGENTS.md`，後因本決策撤下。

問題在「手動檢查」只保護得了寫的人想到的地方。腳本會呼叫其他腳本與外部指令，沒被檢查到的那一個失敗，會讓腳本帶著錯誤狀態繼續往下跑。

## 決策

1. `script/` 底下的可執行腳本一律 `set -euo pipefail`，檔頭註解同步改寫。
2. 預期會非零的指令一律明確處理：`if ! cmd; then …; fi`、`cmd || rc=$?`、`rc=0; cmd || rc=$?`。不得用 `|| true` 吞掉真正的失敗；盡力而為（best effort）的清理步驟失敗時要說出來（例如 `|| _info "..."`），而不是無聲吞掉。
3. 退出碼契約不變：0／1／2／127 與 `bench.sh` 對受測指令失敗的回報（`exited <rc> ... - measurement aborted`，exit 1）行為一致，既有 spec 案例一個不改照樣綠。
4. `lib/` 仍是被 source 的函式庫，不下 `set`；但它的函式會在呼叫者的 `-e` 下執行，所以同一條規則也適用於 `lib/` 裡的程式碼（例如 `enter_block_count` 的 `grep -c` 沒有命中時回 1，改成明確處理）。

每一條被改寫的「預期非零」路徑都有 bats 案例：先證明開了 `-e` 而不改寫時會錯誤中止（RED），再修正（GREEN）。

## 影響

- 要特別留意的 `-e` 陷阱，寫在 `AGENTS.md` 的 shell 慣例：
  - `x=$(cmd)` 在 `cmd` 失敗時中止；`local x=$(cmd)` 會把失敗藏起來，宣告與賦值要分開。
  - 在 `if`／`&&`／`||` 裡呼叫的函式，內部的 `-e` 失效。刻意依賴這點可以，但要是刻意的；反過來，要讓 `-e` 在函式裡生效，就直接呼叫它（`test.sh` 的 `main` 就是這樣讓第一個失敗的步驟以它自己的退出碼結束整個執行）。
  - 單獨一行的 `(( x++ ))` 在結果為 0 時回 1；`read -r ... <<<` 讀到 EOF 回 1。
  - EXIT trap 裡的函式若以非零結束，會在 `-e` 下把整支腳本的退出碼換成它自己的（`selfcheck.sh` 的 `_cleanup` 因此改寫成 `if`）。
  - 用 `| head` 提早關閉的管線在 `pipefail` 下可能以 SIGPIPE 失敗；`test.sh` 讀 TAP plan 改成單一 `awk`。
- source 可執行腳本的測試替身（`test/unit/fixture/entry_driver.sh`）會一併繼承 `-e`，因此也改成 `set -euo pipefail` 並明確處理它自己的預期非零（被 SIGKILL 的子行程、要交給 `_cleanup` 的待決退出碼）。
- 範圍是 `script/` 下的可執行腳本。`test/` 底下獨立執行的測試替身（`fake_container_manager.sh`、`ghostty_single_instance.sh`）不在本決策內；PR #157 分支上的 `script/verify/*.sh` 在 M3 恢復後另行套用；`.agents/` 的 hook 與腳本（#189）待其 PR 合併後再套用。

## 被否決的方案：維持「不用 `-e`，失敗靠手動檢查」

這是反轉前的規則。它的好處是預期中的非零不需要特別寫法，退出碼契約由每個呼叫點自己維護。否決的理由（維護者原話）：「要用使用 -e，不然如果我們使用其他 script 就會有可能有問題」—— 不開 `-e` 時，呼叫其他腳本或外部指令的失敗只要有一處沒被檢查，腳本就會繼續往下跑，而且沒有任何訊號。開了 `-e` 之後，預設是「失敗就停」，預期中的非零改由明確的寫法表達，意圖反而看得見；退出碼契約靠既有 spec 守住，實作證明兩者可以並存。
