# 0008 不變量 5：使用者介面極少，just 是唯一入口，recipe 語意固定

- 狀態：已採納（2026-09-29）
- 討論：#200（不變量十條定案，第 5 條）；本 ADR 的 issue 是 #206
- 索引：`doc/contract.md` 尚未建立；它的不變量索引連到本 ADR 的連結由 #201 建立該檔時回填。

## 一句話

使用者對 worktool 做的每一個動作都經過 `just <namespace> [<recipe>]`（省略 recipe 時執行該 namespace 的 default recipe）；一個 recipe 的語意一旦發布就不改，要改名時先保留舊名當別名一段時間。

## 性質

以下兩點必須永遠成立：

1. **just 是唯一入口。** 所有使用者動作都以 `just <namespace> [<recipe>]` 暴露；recipe 可以省略，裸 `just <namespace>` 執行該 namespace 的 default recipe（例如裸 `just test`），它也是一個 recipe、同樣受本 ADR 約束。使用者不需要知道、也不需要直接呼叫背後的腳本。腳本是實作、不是介面：它們在沒有 `just` 時仍可直接執行，但那不算對外承諾。
2. **recipe 語意固定。** 一個已發布的 recipe（`just <namespace> [<recipe>]` 這個叫法，包括省略 recipe 時的 default recipe）做的事不改；要改名時，舊名在一段別名期內仍以原本的語意可用，而不是直接消失或改做別的事。

適用範圍：使用者透過 worktool 執行的動作，也就是 root `justfile` 與各 namespace 的 module 檔（目前是 `script/test/justfile.test`、`script/box/justfile.box`）暴露的 recipe。

本 ADR 只寫性質。命令模型（namespace 怎麼分、recipe 怎麼轉發、`--help` 與參數驗證住在哪裡）是機制，已由 [`doc/design.md`「決策」2026-09-16：just 是使用者的通用介面](../design.md#2026-09-16just-是使用者的通用介面命令模型比照-base) 決定，這裡不重述。

## 為什麼固定

- worktool 的主痛點是重建成本高（#200）：使用者多半在換機、重灌時才再跑它，距離上次使用已經很久。入口只有一個、文法只有一種，使用者才記得住；每個動作各有自己的腳本路徑與參數寫法，每次重建都要重新查一次。
- 入口不只一個時，同一個動作會有兩種叫法，而兩種叫法遲早分歧（例如一邊加了驗證、另一邊沒有），使用者、文件與 CI 各自用不同的那一種，看到的結果就不一致。
- recipe 是使用者寫進筆記、腳本與 CI 設定裡的東西。語意悄悄改變時，舊的呼叫不會出錯，卻做了別的事；直接改名則讓舊的呼叫在最需要它的時候（重建時）失敗。別名期讓改名先以可用的方式出現，使用者有時間跟上。

## 目前由哪些機制或測試守住

以下只列實際存在、實際檢查這條性質的案例；每一條都是 `spec 檔`「案例名」，可在該檔案中逐字找到（`test/unit/adr_spec.bats` 會檢查每一條引用都存在）。案例檢查的是它所寫的那個指令、那個檔案，不代表其他地方也被檢查過。

機制：命令模型見上面連結的 `doc/design.md` 決策；`test/unit/justfile_spec.bats` 是 `script/test/test.sh` 的必要 unit spec，不能被悄悄刪掉：

- `test/unit/justfile_spec.bats`「this spec is a required unit spec of test.sh」

### 性質 1：just 是唯一入口

入口的形狀固定：root `justfile` 只有 namespace，列出來的也只有 namespace：

- `test/unit/justfile_spec.bats`「root justfile is exactly two mod? lines (test, box) and one default recipe」
- `test/unit/justfile_spec.bats`「just --list shows the two namespaces and default, nothing else」
- `test/unit/justfile_spec.bats`「bare just is just --list」

recipe 只轉發，參數驗證、使用說明與錯誤訊息由腳本負責，justfile 不自己印 usage、不自己驗證參數。下列案例檢查的只是這種轉發與錯誤歸屬，並沒有比較經 `just` 與直接執行腳本的行為是否等價：

- `test/unit/justfile_spec.bats`「no justfile prints usage or a valid: list of its own」
- `test/unit/justfile_spec.bats`「just box assemble --bogus is refused by assemble.sh itself (exit 2), not by the justfile」
- `test/unit/justfile_spec.bats`「just test bogus fails with just's own recipe error, never reaching test.sh or docker」

CI 也走同一個入口：

- `test/unit/justfile_spec.bats`「ci.yml drives every gate as just test <tier>, job names unchanged」

### 性質 2：recipe 語意固定

現有 recipe 各自轉發到哪一支腳本、帶什麼參數是釘住的；轉發目標或參數一改，下列案例就會變紅：

- `test/unit/justfile_spec.bats`「just test (bare) forwards to test.sh with NO argument: everything CI runs」
- `test/unit/justfile_spec.bats`「just test <verb> forwards exactly --<verb> for every tier verb and build」
- `test/unit/justfile_spec.bats`「just test selfcheck forwards to selfcheck.sh, --root X passing through」
- `test/unit/justfile_spec.bats`「just test help and just test h forward test.sh --help」
- `test/unit/justfile_spec.bats`「just box assemble forwards to assemble.sh with no argument」
- `test/unit/justfile_spec.bats`「just box bench forwards to bench.sh with no argument」
- `test/unit/justfile_spec.bats`「just box setup forwards to setup.sh with no argument」
- `test/unit/justfile_spec.bats`「just box status forwards to status.sh verbatim」
- `test/unit/justfile_spec.bats`「just box help and just box h forward --help to every box script, in order」

`box` namespace 的 recipe 清單是釘住的，刪掉或改名一個 recipe 會變紅：

- `test/unit/justfile_spec.bats`「just box lists assemble, bench, default, help (alias h), setup and status only」

這些案例只證明「recipe 轉發到哪裡」沒變；腳本本身做的事由各腳本自己的 spec 檢查，不在本條的保證內。

### 待補

- **別名期整條待補。** 「發布」目前沒有定義（尚未有 release），別名期多長也沒有定案；沒有任何機制或測試確認改名的 recipe 保留了舊名。上面的案例在改名時只會變紅，要求的是改測試，而不是留別名。
- **經 `just` 與直接執行腳本的行為等價沒有檢查。** 上面的案例只證明 recipe 原封轉發、驗證與說明由腳本負責；沒有任何測試以同一組參數分別經 `just` 與直接執行腳本，比較兩者的輸出、結束碼與副作用。
- **`test` namespace 的 recipe 清單沒有釘住。** `box` 有列出全部 recipe 的案例，`test` 沒有；`test` 的 recipe 被刪掉時，只有轉發案例裡點名的那幾個會變紅。
- **文件以 `just` 為入口沒有全面檢查。** 只有 `just box help` 背後的腳本清單有檢查（`test/unit/justfile_spec.bats`「README.md and doc/structure.md list all four scripts behind just box help, in order」）；沒有測試確認 `README.md` 與 `doc/` 不教使用者直接呼叫腳本。
- **host 端的 install script 未定。** #200 定案驅動與 GUI app 是各自獨立的 host install script，M4 的 host bootstrap 要負責裝好 `just` 本身；這些動作如何經過 `just`，目前沒有定案，也還沒有實作與測試。
