# 0005 不變量 2：一個來源，盒子定義只有一份、tool config 只有一份

- 狀態：已採納（2026-09-29）
- 討論：#200（不變量定案）、#203（本 ADR）

## 一句話

盒子的定義只有 `box/dev.ini` 一份，tool config 只有 repo 內一份；worktool 不維護第二份會漂移的說法。

## 性質

1. **盒子定義只有一份。** dev 盒的名稱、映像與套件只寫在 `box/dev.ini`。建盒直接讀這份檔案，不從它產生、也不另外手寫一份同樣內容的定義（例如另一份清單、腳本裡的套件列表）。
2. **tool config 只有一份。** tool config（盒內工具的設定，例如 tmux、fish、nvim）只在 repo 內放一份；重建之後盒子裡的 tool config 由這一份而來，不另外維護一份會與它分開修改的版本。
3. **適用範圍。** 本條只管「同一個事實有幾份來源」。user config（`~/.ssh`、金鑰、token）不在 repo 內，不屬本條；tool config 怎麼從 repo 放進盒子 HOME、盒子 HOME 放在哪裡，是機制，由其他 ADR 決定（盒子 HOME 見 ADR 0002）。
4. 測試裡寫死的期望值（例如斷言映像是 `ubuntu:26.04`）不算第二份定義：它們與 `box/dev.ini` 不一致時測試會變紅，作用是發現漂移，而不是提供另一個來源。

## 為什麼固定

worktool 的核心承諾是「驅動裝好之後，一個指令建好 worktool 環境」，主痛點是重建成本高（#200）。重建能不能還原出同一個環境，取決於重建讀的那一份是不是使用者以為的那一份。

- 同一個事實有兩份時，改了其中一份、忘了另一份，不會有任何錯誤訊號；要等到換機或重灌時才發現重建出來的盒子少了套件、名稱不對，或 tool config 回到舊版。這正是重建最不能出錯的時候。
- 兩份之間誰才算數沒有答案，讀的人（使用者、維護者、agent）各自挑一份，結論就會分歧。
- tool config 若在盒子裡另有一份被直接修改的版本，重建時那些修改會消失，或反過來蓋掉 repo 內的版本；兩種結果都違反「tool config 隨重建回來」。

## 目前由哪些機制或測試守住

機制：`box/dev.ini` 是原生的 distrobox-assemble 檔案（`doc/manifest.md`），`script/box/assemble.sh` 的預設清單就是它，建盒時原封不動交給 `distrobox assemble create --file`，中間沒有轉換出來的第二份。

測試（只證明「建盒讀的是 `box/dev.ini`」與「一份清單只定義一個盒子」，**不**證明 repo 裡沒有別的定義）：

- `test/unit/assemble_spec.bats`「dry-run with the default manifest emits box/dev.ini」：不給 `--file` 時，建盒指令用的就是 `box/dev.ini`。
- `test/unit/assemble_spec.bats`「#198: the default box home follows the manifest's box name」：預設盒子 HOME 的路徑由清單裡的盒名推出，不另寫一份盒名。
- `test/unit/justfile_spec.bats`「just box assemble --dry-run prints distrobox assemble create --file box/dev.ini via the real script」：經 `just` 進來也是同一份清單。
- `test/unit/manifest_spec.bats`「a multi-section manifest is rejected (single box only)」：一份清單只能定義一個盒子。
- `test/system/real_assemble_spec.bats`「upstream: distrobox assemble --dry-run parses box/dev.ini into a create with name dev / image ubuntu:26.04」：鎖定版的真實 distrobox 直接讀得懂 `box/dev.ini`，不需要轉換出第二份。
- `test/system/real_engine_spec.bats`「real engine: assemble.sh with the delivered box/dev.ini creates the dev box from ubuntu:26.04」：用這份清單真的建出來的盒子，名稱與映像和清單一致。

待補：

- **沒有任何檢查擋住第二份盒子定義。** 目前沒有測試確認 `box/` 底下只有一份清單，或腳本裡沒有另寫套件與映像。
- **盒名 `dev` 目前另有一份。** `lib/enter.sh` 的 `enter_default box` 直接寫死 `dev`（`just box setup --box` 的預設值由此而來），不是從 `box/dev.ini` 讀出；沒有測試確認兩者一致。
- **文件內的抄本沒有檢查。** `doc/manifest.md` 引用了 `box/dev.ini` 的內容（例如 `additional_packages="ripgrep fzf tmux fish"`），`README.md` 寫了映像 `ubuntu:26.04`；`box/dev.ini` 改了，這些文字不會跟著變，也沒有測試發現。
- **tool config 的部分整條待補。** repo 內還沒有任何 tool config（排在 M5），也就沒有機制或測試守住「只有一份」。
