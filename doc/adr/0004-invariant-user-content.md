# 0004 不變量 1：使用者寫的內容歸使用者

- 狀態：已採納（2026-09-29 定案於 #200）
- 討論：#200（不變量十條的定案）、#202（本 ADR）

## 一句話

使用者寫的內容歸使用者：worktool 可以新建，要改先問，永不刪，永不覆蓋。

## 性質

「使用者寫的內容」是任何不是由 worktool 寫出來的檔案與檔案內容，包括使用者自己加進 worktool 也會寫入的檔案（例如 ghostty config、`~/.tmux.conf`）的那些行，以及 user config（`~/.ssh`、金鑰、token 等；名詞見 #200 定案 4）。這條性質對 host HOME 與盒子 HOME 都成立，不論 worktool 是以哪一個 `just` 指令動到它們。

必須永遠成立的是：

1. **可以新建**：檔案不存在時，worktool 可以建立它；檔案已存在時，worktool 只能在自己標記的受管區塊內寫。受管區塊以固定的起訖標記行界定，標記之外的每一行都是使用者的。
2. **要改先問**：worktool 要改動受管區塊以外的既有內容時，必須先問使用者，得到同意才改。
3. **永不刪**：worktool 移除自己的東西時，只移除自己寫的受管區塊；使用者的檔案與行不刪。
4. **永不覆蓋**：worktool 寫檔時不得以自己的內容取代使用者的內容；使用者的行在改寫後原樣留下，包括順序。

例外：worktool 的狀態檔 `~/.config/worktool/config` 沒有受管區塊，改以狀態鍵劃分歸屬。狀態鍵是 worktool 定義的鍵：`auto-enter`、`terminal`、`tmux`、`box`（各自連同 `<鍵>.source`，由 `just box setup` 寫），以及 `home`、`home.source`（由 `just box assemble` 寫）。這些鍵所在的行歸 worktool，worktool 可以不問就換掉它們；但使用者存進狀態鍵的選擇（`.source` 記為使用者）要沿用，不得被預設值蓋掉。狀態檔裡其他的行（使用者自己加的註解或鍵）是使用者寫的內容，第 1 到 4 條照樣適用。

本 ADR 只寫性質。受管區塊的格式、user config 怎麼帶進盒子等機制，由各自的 ADR 與 issue 決定（例如 `doc/adr/0002-box-owns-its-home.md` 決策 3）。

## 為什麼固定

worktool 的核心承諾是重建（#200 定案 2、3）：換機、重灌、升級後整套重跑。重跑是例行事，不是例外；只要有一次重跑刪掉或蓋掉使用者寫的東西，使用者就不能放心重跑，重建承諾隨之失效。

違反的後果都不會有錯誤訊號：被蓋掉的終端設定、被刪掉的 tmux 設定、被改掉的 user config，要等使用者下次用到才發現，而那時已經不知道是哪一次執行造成的。user config 裡的金鑰與 token 更是 worktool 無法重建的東西（它們不進 repo），一旦刪除或覆蓋就是資料遺失。所以這條性質不能靠「寫的人記得小心」維持，必須由機制與測試守住；守不住的地方要明確標出來。

## 目前由哪些機制或測試守住

目前會寫進使用者檔案的有兩個指令。

`just box setup`（`script/box/setup.sh`）在 ghostty config 與 distrobox.conf 各維護一個受管區塊，標記行定義在 `lib/enter.sh`（`ENTER_BLOCK_BEGIN`／`ENTER_BLOCK_END`），寫入或移除前先以 `enter_block_check` 檢查標記；多個區塊或其他不完整標記一律拒絕，任何檔案都不寫。合法檔案寫入走 `enter_block_compose`（取代唯一區塊並維持原位；沒有區塊時附加在檔尾），移除走 `enter_block_strip`（只剝除受管區塊）。它也透過 `config_set` 原地更新 worktool 自己的狀態檔 `~/.config/worktool/config` 的狀態鍵，保留不屬於自己的行。

`just box assemble`（`script/box/assemble.sh`）在 distrobox 建好盒子後，透過 `lib/home.sh` 的 `home_record` 把盒子 HOME 記進同一個狀態檔 `~/.config/worktool/config`：由 `config_set` 在原位更新 `home=`／`home.source=`，移除重複的鍵行，缺少的鍵才附加在檔尾，其他每一行原樣留下、順序不變；先寫同目錄暫存檔再改名取代；試跑與 distrobox 失敗時不寫。

這些 spec 都把 `HOME` 指到測試暫存目錄，不碰真正的 HOME。

逐條對照：

- 可以新建、只在受管區塊內寫：
  - `test/unit/setup_spec.bats`:「the ghostty block is written exactly once and a re-run is idempotent (unchanged)」：既有的 `theme = dark` 留在第一行，區塊附加在後，重跑內容不變。
  - `test/unit/setup_spec.bats`:「a changed decision replaces the block in place: user lines before and after it survive」：改寫區塊時，區塊前後的使用者行原樣留下、順序不變。
  - `test/unit/setup_spec.bats`:「a file that already holds two managed blocks is refused, not collapsed: exit 1, the file unchanged」：檔內有兩個區塊時拒絕執行、exit 1；原檔不改，區塊前後與中間的使用者行都留下。另由 `test/unit/managed_block_spec.bats`:「malformed markers x operation x managed file: refused, exit 1, the file keeps every byte, nothing else is written」檢查包含雙區塊的各種錯誤標記，檔案逐位元組不變。
- 永不刪（只移除自己寫的）：
  - `test/unit/setup_spec.bats`:「--auto-enter no removes the ghostty managed block, reports it, keeps user content」：移除 ghostty 區塊並回報，使用者原本的那一行留下。
  - `test/unit/setup_spec.bats`:「--auto-enter no refuses a file with two managed blocks the same way」：移除遇到雙區塊時拒絕執行、不回報已移除，原檔及區塊之間的使用者行留下。
  - `test/unit/setup_spec.bats`:「--auto-enter no with nothing managed says so」：ghostty 沒有區塊時回報 nothing to remove，也不建立 ghostty 設定檔。
- 永不覆蓋：
  - `test/unit/setup_spec.bats`:「rewriting an existing profile keeps its file mode」：改寫與移除後，檔案權限維持使用者原本設的值。
  - `test/unit/setup_spec.bats`:「--dry-run logs every decision and what it would write, and writes nothing」與 `test/unit/setup_spec.bats`:「--dry-run --auto-enter no reports what it would remove and removes nothing」：試跑不寫、不刪。
  - worktool 自己的狀態檔（`~/.config/worktool/config`）使用者也可以編輯：`test/unit/setup_spec.bats`:「a stored user choice persists across runs; a default key is recomputed」（使用者選的值不被預設蓋掉）、`test/unit/setup_spec.bats`:「#198: setup keeps the box home lines assemble recorded in the state file」（setup 改寫狀態檔時保留 assemble 記下的 `home`／`home.source` 那一對）、`test/integration/setup_spec.bats`:「a state file setup wrote and a user then corrupted is refused by both scripts, and setup leaves it as is」（使用者改壞的狀態檔被拒絕、原樣留下，不被「修正」）。
  - 狀態檔裡使用者自己加的行：`test/unit/setup_spec.bats`:「#199 r4: every setup run x every EOF framing, appending two keys, keeps every foreign byte」與 `test/unit/setup_spec.bats`:「#199 r5: every setup run x every EOF framing, replace-only (all keys present), keeps every byte」檢查 setup 更新或新增自己的鍵時，註解、空白、外來鍵與順序原樣保留。
  - `just box assemble` 寫同一個狀態檔：`test/integration/assemble_spec.bats`:「#198: a successful run records home= and home.source= in the state file, keeping the other lines」（註解行與 `auto-enter` 等使用者的行原樣留下、順序不變，只換掉 `home` 那一對）、`test/integration/assemble_spec.bats`:「#198: a failed distrobox run records nothing」（失敗不寫）、`test/unit/assemble_spec.bats`:「#198: dry-run records nothing in the state file」（試跑不寫）、`test/unit/assemble_spec.bats`:「#198: a stored user home is used when --home is not given; --home still wins」（使用者存的 home 不被預設蓋掉）。

user config 已由 #199／PR #228 交付：`just box assemble` 以 symlink 從 host HOME 帶進盒子 HOME，不複製、不修改 host 那份；同名既有項目不覆蓋。由 `test/integration/assemble_spec.bats`:「#199: an existing entry in the box HOME survives assemble with a warning」與 `test/unit/link_spec.bats`:「a foreign symlink in the box HOME (even a dangling one) is left as is」守住。

這些測試只證明 `setup.sh` 對 ghostty config、distrobox.conf、狀態檔，以及 `assemble.sh` 對狀態檔與 user config 連結的行為，不能推到其他指令或檔案。以下尚無機制或測試，標為待補：

- 要改先問：待補。目前沒有詢問流程；受管區塊以外會被改動的只有狀態檔的狀態鍵（依上面的例外不需詢問），以及下面待補的情形。之後任何功能需要改既有內容時，要先有詢問機制與測試。
- 使用者寫在受管區塊標記之間的行：待補。標記行寫著 do not edit，改寫時區塊內的內容整段換掉；使用者若違反標記在區塊內寫東西，會被覆蓋，目前沒有偵測也沒有測試。
- profile 或狀態檔是 symlink 時：待補。`setup.sh` 以 `config_write_atomic` 寫入 ghostty config／distrobox.conf、以 `config_set` 寫入狀態鍵，`home_record` 也使用 `config_set`；兩者都透過 `lib/config.sh` 的 `_config_replace` 先寫同目錄暫存檔再改名取代目標；依程式碼，目標若是 symlink，改寫後 symlink 本身會被換成一般檔，連結目標不變但連結消失。目前沒有測試。
- 盒子 HOME 目錄（`just box assemble --home`）裡使用者已有的檔案不被刪除或覆蓋：待補，目前沒有測試。
- 全 repo 層級的守門（例如禁止腳本刪除 HOME 底下非 worktool 建立的檔案）：待補。
