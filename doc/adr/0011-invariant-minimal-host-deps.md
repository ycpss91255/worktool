# 0011 不變量 8：host 依賴最小，除驅動與 GUI app 外，只需 docker 與 just

- 狀態：已採納（2026-09-29）
- 討論：#200（不變量十條定案，第 8 條）、#209（本 ADR）

## 一句話

除了驅動與 GUI app，使用者的 host 只需要裝 `docker` 與 `just`；其餘一切都在盒內。

## 性質

1. **host 只需要 `docker` 與 `just`**：使用 worktool 時，要求使用者在 host 上安裝的東西只有這兩樣。其餘的工具（CLI／TUI 工具、編輯器、shell、測試工具等）一律在盒內或容器內，不要求裝在 host。
2. **例外只有驅動與 GUI app**：驅動（nvidia、kvm）與 GUI app 需要裝在 host，各自是獨立的 host install script，不在「一個指令建好環境」之內（#200 定案 3、5）。例外不擴大：新的 host 依賴不能以「方便」為由加入。
3. **不在 host 用 apt 裝 CLI／TUI 工具**（#200 定案 5）：這是本條在安裝方式上的直接結果。
4. **適用範圍**：所有經 `just` 觸發的使用者動作，以及開發者跑的測試（`just test ...`，測試只在 Docker 內跑）。
5. 本條只規定性質；host 上的 `docker` 與 `just` 怎麼裝、盒子怎麼建由各機制自己的 ADR 或文件決定。對照 vendor_kit 不變量 5。

## 為什麼固定

worktool 的主痛點是重建成本高，host 升級會弄壞裝在 host 上的工具（#200 定案 2）。host 依賴一多，這個痛點就回來了：

- **重建要先重建 host**：換機、重灌時，host 上每多一個依賴，就多一步要在「一個指令」之前手動做對，核心承諾（驅動裝好之後，一個指令建好環境）就不成立。
- **host 升級會弄壞工具**：裝在 host 的工具跟著發行版升級走，版本與相依會在使用者沒動 worktool 的情況下改變；裝在盒內的工具則由盒子清單決定，重建即回到同一個狀態。
- **host 被弄髒、跨機器不一致**：host 上的工具與設定散在各處，每台機器裝出來的都不一樣，也會與盒內同名工具互相干擾（不變量「host 與盒子互不干擾」）。

## 目前由哪些機制或測試守住

機制：

- 測試入口 `just test ...`（`script/test/test.sh`）在 host 端只呼叫 `docker`：每個 gate 以 `docker run` 在測試映像內重新執行 `test.sh --ci-<tier>`，bats、shellcheck 等測試工具都在映像內；host 沒有 `docker` 時以「docker not found on host - required (tests run in Docker only)」停止。真實引擎 gate（`just test system-real`）的 distrobox 與 dockerd 在 docker-in-docker runner 映像內，不在 host。
- 盒內工具由盒子清單（`box/dev.ini`）決定，由 distrobox 在盒內安裝，不在 host 用 apt 安裝。

測試（每一條都是可查的檔名與案例名）：

- `test/unit/test_sh_spec.bats` 的「a host-side gate runs ./script/test/test.sh --ci-<tier> inside the container」：host 端的 gate 以 `docker run` 在容器內執行 `test.sh --ci-<tier>`。
- `test/unit/test_sh_spec.bats` 的「test.sh --system-real builds the runner image, then launches the DinD entry, and nothing else」：真實引擎 gate 在 host 端只建 runner 映像並在其中執行，distrobox 不需裝在 host。
- `test/unit/justfile_spec.bats` 的「just is installed in the test image and reports a semver」：測試映像內有 `just`。它只證明映像內有 `just`，不證明 host 除了 `docker` 與 `just` 不需要別的。

人類驗收：`doc/acceptance.md` M2「通用指令」的前提只列 docker 與 just（「不需 distrobox / root」），並以 `just --version && docker info` 確認；這只涵蓋測試指令，不涵蓋盒子動作。

待補：

- **盒子動作目前仍需要 host 上的 distrobox**：`test/unit/bench_spec.bats` 的「distrobox missing from PATH exits 127 before measuring」驗的正是這個行為：`just box bench` 在 host 的 PATH 上找不到 distrobox 時以結束碼 127 停止；`just box assemble` 也一樣（`script/box/assemble.sh`，這條路徑沒有對應的測試案例）。這與本條「只需 docker 與 just」有落差：`doc/design.md` 已定共識 5 與 Open 項目 2 仍把 distrobox（容器框架）列為 host 要裝的東西。這個落差怎麼處理 #200 沒有定案，待補一個決策與對應的測試。
- 沒有自動檢查「沒有任何腳本在 host 呼叫 apt 或安裝其他套件」的測試。待補。
- 沒有自動檢查「只有 `docker` 與 `just` 的 host 能跑完所有使用者動作」的測試（例如在只裝這兩樣的乾淨環境從公開入口跑一次）。待補。
- 驅動與 GUI app 的 host install script（`tool/`，M11／M12）尚未落地；落地時各自補上「只裝宣告的東西」的測試。待補。
- **不變量索引回填**：`doc/contract.md` 由 #201 建立、尚未進 main，回填本 ADR 連結只能在它合併之後做，跟寫本 ADR 是兩件事。為了一個 issue 一個 PR，這項工作已從 #209 拆出到 #264，#264 在 #201 合併後把 `doc/contract.md` 不變量索引第 8 條改成本 ADR 的連結。待補。
