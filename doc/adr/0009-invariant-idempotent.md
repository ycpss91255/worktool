# 0009 不變量 6：冪等，同一個指令重跑，結果相同

- 狀態：已採納（2026-09-29）
- 討論：#200（不變量十條定案，第 6 條）、#207（本 ADR）

## 一句話

同一個使用者動作重跑幾次，結果都跟跑一次相同：不重複寫入、不累積副作用；已經是最新狀態時，明確說出 unchanged。

## 性質

1. **重跑不累積**：以相同的輸入（指令、選項、已記錄的選擇）重跑任何使用者動作，host 與盒子最後的狀態與只跑一次相同。寫進檔案的內容不會多出第二份，已建立的東西不會再建一次。
2. **已是最新就說出來**：重跑時如果沒有東西需要改，要明確告訴使用者「沒有改」（unchanged），不能看起來像又做了一次，也不能什麼都不說。
3. **不同的輸入收斂到新的狀態，而不是疊加**：改了選擇後重跑，舊的結果被原地取代或移除，不會與新的並存。
4. **適用範圍**：所有經 `just` 觸發、會改變 host 或盒子狀態的使用者動作（目前是 `just box assemble`、`just box setup`；之後新增的動作一併適用）。只讀取、不寫入的動作（例如 `just box status`、`just box bench`）不改變狀態，天生符合。
5. 本條只規定性質；怎麼做到（受管區塊的標記、狀態檔的寫法、交給上游工具判斷是否已存在）由各機制自己的 ADR 或文件決定。

## 為什麼固定

worktool 的主痛點是重建成本高（#200 定案 2）：換機、重灌、host 升級後，使用者要能放心把同一個指令再跑一次。重跑不安全，這個承諾就不成立：

- **累積副作用會悄悄弄壞環境**：設定檔裡多一份受管區塊、狀態檔多一行重複的鍵、多建一個同名盒子，症狀通常不會立刻出現，而是在之後某次讀取時才以難以追查的方式失效。
- **使用者只好自己判斷該不該重跑**：如果重跑有風險，使用者就得先確認目前狀態、再決定跑哪一步，等於把 worktool 該承擔的判斷推回給人。
- **不說 unchanged 就分不出「沒做」與「做了」**：重跑時沒有任何訊息，使用者無法確認是狀態已經正確，還是指令根本沒生效；這也違反不變量「永不靜默失敗」的精神。

## 目前由哪些機制或測試守住

機制：

- `just box setup` 的受管區塊（`script/box/setup.sh` 的 `_block_write`／`_block_remove`，標記與讀寫在 `lib/enter.sh`）：檔案裡恰好一個、內容相同的受管區塊才算最新，此時不重寫並印出 `unchanged: <檔案> (managed block already up to date)`；否則原地取代，重複的區塊一併收斂成一個。移除時沒有區塊就印出 `nothing to remove`。
- `just box assemble` 的狀態檔（`lib/home.sh` 的 `home_record`）：`home=`／`home.source=` 原地取代，不追加。已存在的盒子交給上游 distrobox-assemble 判斷，由它回報 `dev already exists` 並不重建。

測試（每一條都是可查的檔名與案例名）：

- `test/unit/setup_spec.bats` 的「the ghostty block is written exactly once and a re-run is idempotent (unchanged)」：同樣的選項跑第二次，exit 0、印出 `unchanged:`、檔案內容與第一次逐字相同、受管區塊仍只有一個。
- `test/unit/setup_spec.bats` 的「a changed decision replaces the block in place: user lines before and after it survive」：改變選擇後重跑，區塊原地取代，前後的使用者行都在。
- `test/unit/setup_spec.bats` 的「a file that already holds two managed blocks is collapsed to exactly one, in place of the first」：已經累積兩個區塊的檔案，重跑後收斂成一個。
- `test/unit/setup_spec.bats` 的「a stored user choice persists across runs; a default key is recomputed」：第二次不帶選項重跑，沿用第一次記錄的使用者選擇。
- `test/unit/setup_spec.bats` 的「--auto-enter no with nothing managed says so for both files」：沒有受管區塊時執行移除，兩個檔案都印出 `nothing to remove`，也不建立檔案。這是移除之後再跑一次會落入的狀態，但本案例不是真的連跑兩次。
- `test/integration/assemble_spec.bats` 的「#198: a successful run records home= and home.source= in the state file, keeping the other lines」：狀態檔原本已有 `home=`／`home.source=` 時，改寫後各只有一行，其他行保留。
- `test/integration/assemble_spec.bats` 的「#198: an existing box with the SAME HOME proceeds (distrobox leaves it alone) and records it」：以假的 distrobox 驗證盒子已存在且 HOME 相同時照常執行、不被拒絕。它只證明重跑不被擋，不證明盒子沒有重建；不重建由下一條真實引擎的案例守住。
- `test/system/real_engine_spec.bats` 的「real engine: a second assemble.sh run exits 0 and does not duplicate the dev box」：真實 distrobox 上第二次 assemble exit 0、輸出含上游的 `dev already exists`、不含 `successfully created`、`dev` 盒子仍只有一個且可用。

待補：

- `just box assemble` 重跑時，worktool 自己沒有說 unchanged：盒子已存在的訊息來自上游 distrobox，狀態檔即使內容相同也照樣印 `recorded box home`。待補一個由 worktool 判斷並印出 unchanged 的行為與測試。
- `just box assemble` 沒有「同樣的選項連跑兩次，狀態檔逐字相同」的案例（上面的案例只從預先寫好的檔案改寫一次）。待補。
- `just box setup --tmux host` 的 `~/.tmux.conf` 區塊沒有連跑兩次、印出 unchanged 的案例（上面的 unchanged 案例只涵蓋 ghostty 設定檔）。待補。
- `just box setup` 的狀態檔沒有「連跑兩次內容逐字相同」的案例。待補。
- 尚未落地的使用者動作（M4 的 host install script、#199 的 user config 連結、之後的模組安裝）在實作時各自補上重跑案例。待補。
