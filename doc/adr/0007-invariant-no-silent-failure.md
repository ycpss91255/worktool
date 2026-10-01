# 0007 不變量 4：永不靜默失敗

- 狀態：已採納（2026-09-29）
- 討論：#200（不變量十條定案，第 4 條）；本 ADR 的 issue 是 #205
- 索引：`doc/contract.md` 第 6 節「不變量索引」第 4 條連到本 ADR

## 一句話

worktool 不會在沒有說出來的情況下替使用者做決定，也不會在沒有說出來的情況下失敗：每個自動決策都印 log 並可查，失敗必印原因與下一步，退出碼是對外契約。

## 性質

以下三點必須永遠成立：

1. **每個自動決策都印 log 並可查。** worktool 替使用者選了什麼（例如預設值、依偵測結果選出的值），執行當下就要印出來，事後也要查得到；使用者自己指定的值與預設值要分得出來。
2. **失敗必印原因與下一步。** 指令失敗時，除了非零的退出碼，還要說出為什麼失敗，以及使用者接下來可以做什麼。沒有證據時不得宣告成功或失敗（「不知道」也要說成「不知道」）。
3. **退出碼是對外契約。** 每個 `just` 指令的退出碼有固定意義，寫在文件裡；呼叫端只看退出碼就能分辨結果。改變退出碼的意義就是改變契約。

適用範圍：使用者透過 `just` 執行的每一個指令（其背後的 `script/` 腳本與 `lib/` 函式）。log 與診斷寫到 stderr，stdout 留給資料。

本 ADR 只寫性質；達成它的機制由其他 ADR 決定，例如 [0001](0001-scripts-use-errexit.md)（`set -euo pipefail`：沒被檢查到的失敗也會讓腳本停下，而不是帶著錯誤狀態繼續往下跑）與 [0003](0003-latency-gate-inconclusive.md)（量測環境不合格時以 exit 3 說出「未判定」，而不是在沒有證據時回 0 或 1）。

## 為什麼固定

- worktool 的核心承諾是一個指令重建整套環境（#200）。使用者多半是換機、重灌後才跑它，距離上次執行已經很久；一個沒說出來的決策或失敗，要等到很後面才以別的形式冒出來，而那時已經無從追查。
- 沒有印出來的自動決策，使用者無法知道 worktool 替他選了什麼，也就無法判斷該不該改；事後查不到，就無法解釋「為什麼這台機器跟那台不一樣」。
- 只給退出碼、不說原因與下一步的失敗，使用者只能讀原始碼才知道要怎麼辦。
- 退出碼被 CI、其他腳本與 gate 當成判定依據。意義一旦悄悄改變（例如在沒有證據時回 0），呼叫端就會在沒有證據時宣告通過。

## 目前由哪些機制或測試守住

以下只列實際存在、實際檢查這條性質的案例；每一條都是 `spec 檔`「案例名」，可在該檔案中逐字找到（`test/unit/adr_spec.bats` 會檢查每一條引用都存在）。案例檢查的是它所寫的那個指令、那條路徑，不代表其他指令或路徑也被檢查過。

### 機制

- [0001](0001-scripts-use-errexit.md)：`script/` 的可執行腳本一律 `set -euo pipefail`，預期中的非零要明確處理，best effort 的清理失敗要說出來。每支腳本各有一個案例檢查 `set` 那一行：
  - `test/unit/assemble_spec.bats`「assemble.sh runs under set -euo pipefail (one set line, errexit included)」
  - `test/unit/bench_spec.bats`「bench.sh runs under set -euo pipefail (one set line, errexit included)」
  - `test/unit/setup_spec.bats`「setup.sh runs under set -euo pipefail (one set line, errexit included)」
  - `test/unit/status_spec.bats`「status.sh runs under set -euo pipefail (one set line, errexit included)」
  - `test/unit/selfcheck_spec.bats`「selfcheck.sh runs under set -euo pipefail (one set line, errexit included)」
  - `test/unit/test_sh_spec.bats`「test.sh runs under set -euo pipefail (one set line, errexit included)」
- [0003](0003-latency-gate-inconclusive.md)：進盒延遲 gate 在主機不安靜時以 exit 3 回報未判定。
- `lib/log.sh`：`log_info`／`log_warn`／`log_error` 以 `[INFO]`／`[WARN]`／`[ERROR]` 前綴寫到 stderr，不碰 stdout：
  - `test/unit/log_spec.bats`「log_info writes the message with an [INFO] prefix to stderr」
  - `test/unit/log_spec.bats`「log_info writes nothing to stdout」
  - `test/unit/log_spec.bats`「log_warn writes the message with a [WARN] prefix to stderr」
  - `test/unit/log_spec.bats`「log_error writes the message with an [ERROR] prefix to stderr」

### 性質 1：自動決策印 log 並可查

`just box setup` 與 `just box assemble` 把每個決策連同來源（`(default)` 或 `(user)`）印在 log 裡，並寫進狀態檔；`just box status` 把狀態檔裡的決策與來源印出來：

- `test/unit/setup_spec.bats`「defaults (no ghostty dir): yes / none / inside / dev, each logged as (default), state file written with sources」
- `test/unit/setup_spec.bats`「user overrides are logged as (user) and stored with source=user」
- `test/unit/setup_spec.bats`「#175: the config dir alone still selects ghostty when no executable is on PATH, and the log says so」
- `test/unit/setup_spec.bats`「#175: terminal is none only when there is neither an executable nor a config dir, and the log names both」
- `test/unit/setup_spec.bats`「--dry-run logs every decision and what it would write, and writes nothing」
- `test/unit/assemble_spec.bats`「#198: the default box home is ~/<box>-box, logged as (default); stdout keeps the bare command」
- `test/unit/assemble_spec.bats`「#198: --home <path> and --home=<path> are the user's choice, logged as (user)」
- `test/unit/status_spec.bats`「prints every stored decision with its source and the block presence per file」
- `test/unit/status_spec.bats`「#198: the recorded box home is shown with its source, as the last line」

### 性質 2：失敗印原因與下一步

原因與下一步都有檢查的案例：

- 參數錯誤：訊息 `<script>.sh: unknown option '<x>' (see --help)`，以 `(see --help)` 指出下一步：
  - `test/unit/assemble_spec.bats`「an unknown option exits 2 with the documented message on stderr, nothing on stdout, and executes nothing」
  - `test/unit/bench_spec.bats`「an unknown option exits 2 with the documented message on stderr, nothing on stdout, nothing recorded」
  - `test/unit/setup_spec.bats`「an unknown option exits 2 with the documented message on stderr, nothing on stdout, nothing written」
  - `test/unit/status_spec.bats`「an unknown option exits 2 with the documented message on stderr, nothing on stdout」
  - `test/unit/setup_spec.bats`「an invalid value is refused with the expected choices, exit 2, nothing written」
- `just box setup` 找不到 distrobox 時拒絕執行，並指出出路（安裝 distrobox 或傳 `--distrobox <path>`）：
  - `test/unit/setup_spec.bats`「#175r1: with no distrobox on PATH the run is refused, nothing is written, and the error names the way out」
- `just box status` 回報受管區塊記錄的 distrobox 已無法執行，或 PATH 上沒有 distrobox 時，說出要重跑 `just box setup`：
  - `test/unit/status_spec.bats`「#175: a managed block whose distrobox path is gone is reported as NOT RUNNABLE with what to do」
  - `test/unit/status_spec.bats`「#175: with no distrobox on PATH and no managed block the report says so instead of staying silent」
- 進盒延遲 gate 未判定時說出原因（PSI 路徑與數值）與下一步（`re-run when idle`）：
  - `test/unit/bench_spec.bats`「a host busy until --max-wait runs out is inconclusive: exit 3, no distrobox call, nothing on stdout」
  - `test/unit/bench_spec.bats`「a PSI spike mid-run voids the whole batch: exit 3, no metric line, measuring stops there」

只檢查了原因、沒有檢查下一步的案例（訊息本身目前也沒有下一步）：

- `test/unit/bench_spec.bats`「--max-ms below the shell median exits 1, still prints all three metric lines, says why on stderr」
- `test/unit/status_spec.bats`「a corrupt stored value is refused with [ERROR] on stderr and exit 1, whatever its source」
- `test/unit/manifest_spec.bats`「manifest missing image fails with a clear message」

沒有證據時不宣告結果（0003 的核心）：

- `test/unit/bench_spec.bats`「a failing run on a host that turned busy during it is inconclusive (exit 3), not a failure (exit 1)」
- `test/unit/bench_spec.bats`「no readable PSI: a warning says so and the measurement runs unguarded (exit 0, no wait)」

### 性質 3：退出碼是對外契約

退出碼目前只記載了部分指令與部分路徑，而且分散在三份文件：`doc/manifest.md`（`assemble`、`bench`）、`doc/enter.md`（`setup`、`status`）、`doc/structure.md`（`just` 轉發與未知選項 exit 2）；腳本的 `--help` 裡只有 `bench.sh` 列出退出碼。以下案例只把下面列出的碼釘住，不代表每個指令的每條路徑都有文件或測試：

- `test/unit/bench_spec.bats`「--max-ms above the shell median exits 0」（0）
- `test/unit/bench_spec.bats`「a distrobox enter that exits non-zero aborts the measurement: exit 1, no metric line」（1）
- `test/unit/bench_spec.bats`「distrobox missing from PATH exits 127 before measuring」（127）
- `test/unit/bench_spec.bats`「--help documents --max-wait, the quiet-host rule, exit 3 and the test-only BENCH_PSI_FILE」（3 寫進 `--help`）
- `test/unit/justfile_spec.bats`「just box assemble --bogus is refused by assemble.sh itself (exit 2), not by the justfile」
- `test/unit/justfile_spec.bats`「just box setup --bogus and just box status --bogus are refused by the scripts themselves (exit 2)」
- `test/unit/setup_spec.bats`「a corrupt stored value is refused with a clear error, exit 1, nothing rewritten」

### 待補

- **「每個」自動決策都印 log：** 上面的案例只檢查了被列出的決策。沒有全 repo 的檢查能發現一個新加的、沒印 log 的自動決策。
- **「每個」失敗都印下一步：** 沒有通用的檢查；上面「只檢查了原因」的三類失敗（延遲超過 `--max-ms`、狀態檔的值損壞、manifest 缺欄位）目前只說原因、沒說下一步。
- **退出碼契約的單一來源：** 退出碼只記載了部分，分散在 `doc/structure.md`、`doc/manifest.md`、`doc/enter.md` 與 `bench.sh --help`（其他腳本的 `--help` 沒有列出），沒有一份逐指令的表，也沒有檢查文件與實作一致的測試。`doc/contract.md` 第 4 節只寫了通用意義（0 成功、1 功能性失敗、2 參數錯誤，`just box bench` 另有 3 未判定），不是逐指令的契約。
