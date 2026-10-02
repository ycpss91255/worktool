# 0010 不變量 7：對外承諾必須黑箱可驗，開發與正式使用走同一個入口

- 狀態：已採納（2026-09-29）
- 討論：#200（不變量十條定案，第 7 條；對照 vendor_kit 不變量 9）、#208（本 ADR）

## 一句話

每一條對外承諾，都有一個從公開入口 `just` 執行的驗收（自動或人類實機）；測試不走後門，開發、CI 與使用者跑的是同一組 `just` 指令。

## 性質

1. **每條對外承諾都可以從外面驗**：使用者看得到的每一條承諾（例如「一個指令建好環境」、選項錯誤回 exit 2），都要有一個驗收，只看公開入口的輸出、退出碼與它留下的狀態就能判定成立與否。驗收可以是自動測試，也可以是人類實機清單；兩種都從 `just` 執行。
2. **測試不走後門**：驗收一條承諾時，走的是使用者會走的同一條路：同一個 `just` 指令、交付的原檔、交付的設定。不為了讓測試通過而改寫交付物，也不另開只有測試才用得到的 worktool 入口。為了造出情境而替換 worktool 以外的依賴（例如以假的 distrobox 或 container manager 取代真的）不算後門，被驗的 worktool 部分仍必須是交付的原檔。
3. **開發與正式使用走同一個入口**：維護者開發時、CI 跑 gate 時、使用者正式使用時，呼叫的都是同一組 `just` 指令；沒有另一套 CI 專用或開發專用的入口。
4. **適用範圍**：對外承諾，也就是使用者可觀察的行為。直接呼叫內部函式的單元測試可以存在，但它們不算任何一條對外承諾的驗收。
5. 本條只規定性質；`just` 的形狀（namespace、薄轉發器、腳本負責 `--help` 與參數驗證）由 `doc/design.md` 的模型與各機制自己的 ADR 決定。

## 為什麼固定

- **後門測試會假綠**：測試如果繞過使用者的入口（直接呼叫內部函式、改寫交付的腳本、用只有測試才有的旗標），它證明的是後門可用，不是使用者那條路可用。入口本身壞掉（`just` recipe 沒把參數原樣轉發、腳本的參數驗證被跳過）時，測試照樣綠，使用者拿到的卻是壞的。
- **兩套入口會悄悄脫鉤**：開發或 CI 用一套、使用者用另一套時，兩邊的差異沒有任何測試盯著；CI 綠只代表 CI 那一套能用。只有一個入口，CI 綠的意義才等於「使用者照文件跑會得到同樣的結果」。
- **不能從外面驗的承諾等於沒有承諾**：一條承諾如果只能靠讀程式碼或看內部狀態確認，使用者與維護者都沒辦法在自己的機器上重現驗收；承諾有沒有被破壞，只能等使用者踩到。

## 目前由哪些機制或測試守住

機制：

- `just` 是唯一的使用者入口：root `justfile` 只有 `mod?` 行與 `default`，每個 recipe 是把參數原樣交給腳本的薄轉發器，`--help` 與參數驗證都在腳本裡（`doc/design.md`「決策」2026-09-16「just 是使用者的通用介面」的模型規則 1 與 4）。
- CI 的測試 gate（lint、unit、integration、system、acceptance、system-real）都以 `just test <tier>` 或 `just test system-real` 執行（`.github/workflows/ci.yml`），與維護者在本機跑的是同一個指令。建 image 的 `build-image` job 不在此列：它直接執行 `docker build`，不經 `just test build`（見待補）。
- agent 端的 hook（`.agents/hook/test-must-use-docker.sh`）擋下在 host 直接跑 bats 或直接呼叫 `script/test/test.sh`，要求改用 `just test`。
- 人類實機驗收清單（`doc/acceptance.md`）規定清單上的 worktool 動作一律以 `just` 執行。

測試（每一條都是可查的檔名與案例名）：

- `test/unit/justfile_spec.bats` 的「root justfile is four mod? lines (test, box, agent, verify) and one default recipe」：root `justfile` 沒有 namespace 以外的頂層動作。
- `test/unit/justfile_spec.bats` 的「no justfile prints usage or a valid: list of its own」：justfile 不自己印 usage 或選項清單，這些只能來自腳本。
- `test/unit/justfile_spec.bats` 的「just test <verb> forwards exactly --<verb> for every tier verb and build」：每個 `just test` 動詞原樣轉發到 `test.sh`（以替身腳本記錄收到的參數）。
- `test/unit/justfile_spec.bats` 的「just box assemble --dry-run prints distrobox assemble create --file box/dev.ini via the real script」：經 `just` 呼叫交付的 `assemble.sh`，看到的是使用者會看到的輸出。
- `test/unit/justfile_spec.bats` 的「just box assemble --bogus is refused by assemble.sh itself (exit 2), not by the justfile」：經 `just` 給錯選項，拒絕與訊息來自腳本本身。
- `test/unit/justfile_spec.bats` 的「just box setup --dry-run logs the decisions via the real script and writes nothing」：經 `just` 呼叫交付的 `setup.sh`。
- `test/unit/justfile_spec.bats` 的「just box status via the real script reports the defaults under a throwaway HOME」：經 `just` 呼叫交付的 `status.sh`。
- `test/unit/justfile_spec.bats` 的「ci.yml drives every gate as just test <tier>, job names unchanged」：`ci.yml` 裡以 `just` 執行的步驟恰好是 `just test ${{ matrix.tier }}` 與 `just test system-real` 兩個。它只檢查 `run: just` 開頭的步驟，不證明 CI 沒有其他不經 `just` 的步驟（見待補）。
- `test/unit/hook/test_must_use_docker_spec.bats` 的「blocks a bare 'bats' run on the host and points at just test」：host 上直接跑 bats 會被擋。
- `test/unit/hook/test_must_use_docker_spec.bats` 的「blocks a direct test.sh host step instead of just test」：host 上直接呼叫 `test.sh` 會被擋。
- `test/acceptance/m2_selfcheck_spec.bats` 的「selfcheck catches a wrapper that skips validation」：交付的 self-check 會抓到跳過參數驗證的包裝腳本，驗的是黑箱的判定結果。它直接呼叫 `script/test/selfcheck.sh`，不經 `just test selfcheck`（見待補）。

待補：

- 系統層與 integration 層的案例（test/system/real_engine_spec.bats、test/integration/assemble_spec.bats、test/integration/setup_spec.bats）直接呼叫交付的 `script/box/*.sh`，不經 `just box ...`。被驗的是交付原檔，但入口不是使用者的入口；待補一條從 `just box assemble` 在真實引擎上 assemble 盒子的案例。
- 驗收層 test/acceptance/m2_selfcheck_spec.bats 直接呼叫 `selfcheck.sh`，不經 `just test selfcheck`。待補。
- CI 的建 image 步驟（`build-image` job）直接執行 `docker build`，不經 `just test build`；兩邊目前是同一個 Dockerfile，但沒有測試盯著它們一致。待補。
- 對外承諾的清單（`doc/contract.md`，#201）尚未進 main；也還沒有機械檢查確認「每一條承諾都對應到至少一個從 `just` 執行的驗收」。待補。
- 人類驗收的總入口 `just verify all`（#182）目前只合進 M3 里程碑分支、尚未進 main，不列為目前的守護。待補。
