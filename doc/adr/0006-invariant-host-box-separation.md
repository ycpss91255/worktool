# 0006 不變量 3：host 與盒子互不干擾

- 狀態：已採納（2026-09-29）；性質第 3 點對 `--tmux host` 尚未生效：目前 `just box setup --tmux host` 會寫 host 的 `~/.tmux.conf`，待 #179 移除 tmux 決策消除衝突後才生效
- 討論：#200（不變量定案，第 3 條）、#204（本 ADR）
- 機制：[ADR 0002](0002-box-owns-its-home.md)（盒子使用獨立 HOME）

## 一句話

worktool 只改盒子，不改 host：不是從 ghostty 開的終端拿到的是 worktool 沒碰過的 host shell，tool config 只在盒內生效。

## 性質

以下三點是 worktool 必須守住的性質。已知的例外只有一個：第 3 點對 `--tmux host` 尚未生效：`just box setup --tmux host` 目前會在 host 的 `~/.tmux.conf` 寫受管區塊，違反第 3 點，待 #179 移除 tmux 決策後才生效。除此之外三點都必須永遠成立：

1. 用 ghostty 以外的方式開終端，拿到的是 host 自己的 shell，行為與沒有裝 worktool 時相同；進盒只經由 worktool 寫進 ghostty 設定的受管區塊，不經由 host 的 shell。
2. worktool 不寫 host 的 shell 設定檔（例如 `~/.bashrc`、`~/.profile`、`~/.config/fish/`），不論是建盒、設定終端或之後任何一個 `just` 指令。
3. tool config（盒內工具的設定，例如 tmux、fish、nvim）只對盒內生效：盒內工具讀寫的是盒子自己的那一份，host 上同名的工具看不到、也改不到它；反過來，host 上的同名工具的設定也不會被盒內工具讀到。盒內工具的執行期狀態（例如 tmux 的 socket）也不得與 host 共用。

適用範圍是 worktool 自己做的事。以下不在本性質內：

- user config（`~/.ssh`、金鑰、token）：worktool 不管理它，host 那份是唯一一份（#200 定案 4）。
- 驅動與 GUI app 的 host install script：它們本來就裝在 host，是一個指令之外的例外（#200 定案 3）。
- 檔案系統或權限的隔離：盒內仍能以絕對路徑讀寫 host HOME，本性質說的是「預設不會讀到、改到對方」，不是「做不到」（見 ADR 0002「影響」第一點）。

怎麼做到（獨立 HOME、tmux 的專屬 socket）由其他 ADR 與 issue 決定，本 ADR 只寫性質。

## 為什麼固定

worktool 的主痛點是重建成本（#200 定案 2）：換機、重灌、host 升級後，要能一個指令把環境建回來。這只有在 host 保持乾淨時才成立。違反本性質的後果：

- host 被 worktool 改過之後，重建不再是「在乾淨的 host 上跑一個指令」，而是要先還原 host 被改掉的部分；host 升級弄壞工具的老問題也會回來。
- 盒內外讀同一份設定時，盒內改的設定會悄悄改到 host 的工具，host 的設定也會帶進盒子；用錯方式開終端時，使用者拿到的是讀著盒子設定的 host shell，看不出自己在哪一邊（ADR 0002「背景」）。這類干擾沒有任何錯誤訊號。
- 盒內外共用執行期狀態時，盒內指令會連到 host 的行程：tmux 連錯 server 就是實例（#179 的實機假成功）。
- 非 ghostty 的終端是使用者脫離 worktool 的退路；worktool 一旦寫進 host shell，任何終端都會被帶進盒子，盒子壞掉時連退路都沒有。

## 目前由哪些機制或測試守住

機制：

- 獨立 HOME：[ADR 0002](0002-box-owns-its-home.md) 決策 1、2。`just box assemble` 以 `--home`（預設 `~/<盒名>-box`）建盒，已由 #198 實作。
- 進盒只經由 ghostty 設定的受管區塊：`script/box/setup.sh` 只寫 `$XDG_CONFIG_HOME/worktool/config`（狀態檔）、ghostty 設定的受管區塊，以及 `--tmux host` 時 `~/.tmux.conf` 的受管區塊（見下方待補最後一點），不寫 host shell 設定檔。
- tmux 使用盒子自己的 server：ADR 0002 決策 4，尚未實作，將由 #179 實作。

測試（逐條列出檔名與案例名，只寫它實際檢查的事）：

- 盒內 `$HOME` 是盒子 HOME、`DISTROBOX_HOST_HOME` 指回 host HOME：`test/system/real_engine_spec.bats` 的「real engine (#198): $HOME inside the box is the path assemble --home asked for」。
- 已存在的盒子不會被換成另一個 HOME：`test/system/real_engine_spec.bats` 的「real engine (#198): assemble with a DIFFERENT --home is refused (exit 1) and the box keeps its HOME」；`test/integration/assemble_spec.bats` 的「#198: an existing box with a different HOME is refused: exit 1, the recreate commands, nothing changed」。
- 預設 HOME 是 `~/<盒名>-box`，並以 `DBX_CONTAINER_CUSTOM_HOME` 交給 distrobox：`test/unit/assemble_spec.bats` 的「#198: the default box home is ~/<box>-box, logged as (default); stdout keeps the bare command」；`test/integration/assemble_spec.bats` 的「#198: the default box home reaches distrobox as DBX_CONTAINER_CUSTOM_HOME; argv is unchanged」。
- 清單不得以 distrobox 自己的 `home=` 蓋掉盒子 HOME：`test/unit/assemble_spec.bats` 的「#198: a manifest that sets distrobox's own home= key is refused (exit 1): --home owns the box HOME」。
- 真的 ghostty 視窗執行受管區塊的命令後，標記檔落在盒內：`test/system/real_engine_spec.bats` 的「ghostty chain: a real window runs the managed block's command and leaves a marker INSIDE the box (fish under tmux)」。這條證明 ghostty 會進盒，不證明其他終端不會。

待補（目前沒有測試檢查，不得當作已守住）：

- 待補：沒有測試檢查 worktool 的任何指令不寫 host shell 設定檔（`~/.bashrc`、`~/.profile`、`~/.config/fish/` 等）。`test/unit/setup_spec.bats` 只檢查 `setup.sh` 寫了哪些檔，沒有斷言其他檔未被改動。
- 待補：沒有測試開一個非 ghostty 的終端，確認拿到的是 host shell。
- 待補：沒有測試在盒內寫入 tool config 後，確認 host HOME 的同名檔不變、host 的設定盒內讀不到。#196 的 demo 驗證過這件事，但只是一次性的留言證據，不在 CI 裡。
- 待補：tmux 使用盒子自己的 socket（`TMUX_TMPDIR`），由 #179 實作並補測。
- 已知衝突（不只是缺測試）：目前 `just box setup --tmux host` 會在 host 的 `~/.tmux.conf` 寫受管區塊（`test/unit/setup_spec.bats` 的「--tmux host: ghostty runs tmux on the host and ~/.tmux.conf gets the default-command block」檢查的就是這個行為）。這是 host 上 tmux 的設定，與本性質第 3 點衝突；#179 移除 tmux 決策後才會消失，在那之前本性質第 3 點對 `--tmux host` 尚未生效（見「狀態」與「性質」）。
