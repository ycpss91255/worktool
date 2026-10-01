# 0002 盒子使用獨立 HOME，取代共用 HOME

- 狀態：已採納（2026-09-29）；取代 `doc/design.md` 已定共識 4（共用 HOME）
- 討論：#196（維護者決策與 demo 證據）、#197（本 ADR）
- 依據：不變量「host 與盒子互不干擾」（#200，ADR 待補編號）

## 背景

`doc/design.md` 已定共識 4 原本是「設定留共用 HOME」：盒子沿用 distrobox 的預設，與 host 共用同一個 HOME，`~/.config/*`、`~/.gitconfig`、`~/.ssh` 盒內外看到的是同一份，工具在盒、設定共用，不需同步。

問題在「同一份」。盒內外只要有同名工具（例如 init_ubuntu 遺留在 host 的 fish），兩邊就讀寫同一份 `~/.config/fish`：盒內改的設定會改到 host 的工具，host 的設定也會帶進盒子。用錯方式開終端（例如不是從 ghostty 開、落在 host）時，使用者拿到的是一個讀著盒子設定的 host shell，看不出自己在哪一邊。共用 HOME 下，兩邊分開只能靠「工具只裝盒內」的紀律維持，而紀律擋不住遺留的工具、也擋不住之後誰在 host 多裝一個。

維護者 2026-09-29 決定改用 distrobox 的 `--home`，並以 demo 驗證（鎖定版 1.8.2.5，DinD runner 內執行，腳本與輸出見 #196 留言）：

- 盒內 `$HOME` 指到盒子自己的 HOME，`DISTROBOX_HOST_HOME` 指回 host HOME。
- 盒內寫的 tool config 只落在盒子 HOME，host 那份不變；host 的 tool config 盒內看不到。
- host HOME 仍以原路徑掛在盒內，以絕對路徑讀得到。
- user config（例如 `~/.ssh`）在盒子 HOME 裡不存在，要另外帶進去。

## 決策

1. 盒子使用獨立 HOME：建盒時以 distrobox `--home` 指定（`box/` 清單的 `home=` 欄位，見上游 [distrobox-assemble.md 第 126 行](https://github.com/89luca89/distrobox/blob/1.8.2.5/docs/usage/distrobox-assemble.md)）。tool config（tmux、fish、nvim 等盒內工具的設定）只放在盒子 HOME。
2. 路徑可指定：預設 `~/<盒名>-box`（dev 盒 = `~/dev-box`），以 `just box assemble --home <路徑>` 覆寫。distrobox 只在建盒時決定 HOME，建盒後要換只能刪盒重建；已存在的盒子給了不同的 `--home` 一律拒絕，不自動重建。以上尚未實作（目前 `just box assemble` 只有 `--dry-run`、`--file`、`--help`），將由 #198 實作，細節與驗收見該 issue。
3. user config（`~/.ssh`、`~/.gitconfig`、`~/.gnupg`、`~/.config/gh` 等）以 symlink 從 host HOME 帶進盒子 HOME：不複製、不修改，host 那份是唯一一份；盒子 HOME 已有同名檔時不覆蓋。以上尚未實作，將由 #199 實作，細節與驗收見該 issue。
4. `/tmp` 仍是盒內外共用，所以 tmux 要有盒子自己的 socket：建盒時在盒子設定 `TMUX_TMPDIR`，指到盒子 HOME 底下的專用目錄，盒內任何方式啟動的 tmux 都不會連到 host 的 server。以上尚未實作，將由 #179 實作，細節與驗收見該 issue。
   - 補記（#179 實作，PR #232）：光有 `TMUX_TMPDIR` 不夠。`distrobox enter` 會把呼叫端的環境整批帶進盒內，從 host 的 tmux pane 進盒時盒內會繼承指向 host socket 的 `TMUX`（與 `TMUX_PANE`），而 tmux 先看 `TMUX`。洩漏在環境、不在執行檔，所以不包 tmux，改在環境建立處拿掉：`just box setup` 在 distrobox 自己的 `distrobox.conf` 維護受管區塊（`distrobox-enter` 組 `exec` 請求前 source，進該盒時 `unset TMUX TMUX_PANE`），盒內登入 shell 的 profile.d / fish conf.d 是第二道。機制、涵蓋的進盒路徑與邊界見 `doc/enter.md`「決策：終端不自動開 tmux」第 2 點。

## 影響

- `--home` **不是隔離**。上游文件明說它不會阻止 host HOME 掛進盒子，只保證設定檔不會散落到 host HOME（[distrobox-create.md 第 209-211 行](https://github.com/89luca89/distrobox/blob/1.8.2.5/docs/usage/distrobox-create.md)：「Note that this will NOT prevent the mount of the host's home directory, but will ensure that configs and dotfiles will not litter it.」）。盒內仍能以絕對路徑（`$DISTROBOX_HOST_HOME/...`）讀寫 host HOME 的任何檔案，專案目錄也因此不需要連結。本決策解決的是「兩邊的工具預設讀到同一份設定」，不是權限或檔案系統的隔離；任何需要真正隔離的需求，不能拿本決策當依據。
- 除了 HOME，盒內外還共用 distrobox 預設掛入的其他路徑，其中 `/tmp` 會造成 tmux 連錯 server（上游 [issue #824](https://github.com/89luca89/distrobox/issues/824)，#179 的實機假成功）。以後新增盒內工具時，要檢查它是否把 socket 或狀態放在共用路徑，比照 tmux 以環境變數指回盒子 HOME。
- 盒子 HOME 是 host 檔案系統上的一個目錄（預設 `~/dev-box`），`distrobox rm` 預設不刪它（上游 1.8.2.5 只有加 `--rm-home` 才會詢問是否刪除）；盒子重建後 tool config 仍在，要從乾淨狀態重來須自行刪除該目錄。
- 盒子 HOME 初次啟動時由 distrobox-init 以 `/etc/skel` 填入預設檔（demo 第 7 步）。
- 既有以共用 HOME 為前提的文件與測試（`doc/enter.md`、`doc/manifest.md`、`doc/acceptance.md` 的 M5 項目）在 #198、#199、#179 實作時各自改寫；在那之前，實際行為仍是共用 HOME。
- 架構圖（`doc/diagram/architecture.drawio.svg`）與描述它的 `README.md`、`doc/structure.md` 在本 ADR 的同一個 PR 改為盒子 HOME：圖面表達的是採納後的架構，與 `doc/design.md` 一致。

## 被否決的方案：維持共用 HOME，加上「工具只裝盒內」的紀律

這是共識 4 的做法。它的好處是零設定：user config 與 tool config 盒內外都直接可用，不需要連結、不需要選路徑，host 上的 GUI app 與盒內工具讀同一份設定也不需同步。

否決的理由是「機制優先於紀律」：互不干擾要靠機制保證，不能靠使用者或維護者記得不在 host 裝同名工具。共用 HOME 下，干擾是否發生取決於 host 上裝了什麼，而 host 的狀態不在 worktool 的控制範圍內（遺留的 init_ubuntu 工具、發行版預裝、之後的手動安裝都算）；紀律一旦破功，症狀是設定被悄悄改掉或在 host 拿到盒子的設定，沒有任何錯誤訊號。獨立 HOME 讓「兩邊讀不同的設定」成為預設，代價（user config 要連結、HOME 路徑建盒後不可改）是一次性的，而且由 #198、#199 的腳本承擔，不落在使用者身上。
