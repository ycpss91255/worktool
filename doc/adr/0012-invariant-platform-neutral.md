# 0012 不變量 9：正確性不綁單一平台

- 狀態：已採納（2026-09-30）
- 討論：#200（不變量十條定案，第 9 條）；本 ADR 由 #210 落地。支援矩陣與 CI 策略見 #148、#149。
- 索引：`doc/contract.md` 尚未進 main，其不變量索引連到本 ADR 的連結由 #201 回填。

## 一句話

同一版 repo 在每個支援平台上得到等價結果；只在某一個平台上成立的正確性不算正確。

## 性質

- 支援平台是「架構 × 盒子的 Ubuntu 版本」：架構為 amd64 與 arm64；Ubuntu 目前只有 26.04，24.04 之後追加（#148），追加之前不承諾 24.04。
- 等價結果的意思：同一個 commit、同一個 `just` 指令、同樣的輸入，在每個支援平台上的判定相同 —— 成功或失敗、結束碼、對外可觀察的結果（例如建出的盒子、盒內可用的工具）都一樣。
- 一個平台的通過不能替另一個平台背書；在任何一個支援平台上結果不同，就是缺陷，不是「該平台的特性」。
- 本 ADR 只寫性質。怎麼在每個平台上檢查（CI 的 runner matrix、測試 image 的建置方式）屬於機制，由 #148、#149 與其後續決策負責。

## 為什麼固定

- worktool 的主痛點是重建成本高、次要痛點是跨機器不一致（#200 定案 2）。使用者本身就跨平台使用（x86_64 桌機，與 rpi4、rpi5、jetson 等 arm64 機器）；若正確性只在一個平台上成立，換到另一種機器重建就可能壞掉，正好重現 worktool 要消除的痛點。
- 只在開發者手上那個平台驗證過的行為，會讓其他平台的使用者成為第一個發現錯誤的人，而且錯誤要到換機或重灌那一刻才浮現，是最貴的時間點。
- 平台差異（套件名稱、二進位架構、base image 內容）大多不會在語法或 lint 層面露出，只有在該平台上實際跑過才看得到；所以這條必須是不變量，而不是有空再測。

## 目前由哪些機制或測試守住

- 機制（建 image）：`.github/workflows/ci.yml` 的 `build-image` 在 `ubuntu-latest`（amd64）與 `ubuntu-24.04-arm`（arm64）兩種 GitHub-hosted runner 上各自以原生方式 `docker build` 測試 image、存檔並上傳成該架構專屬的 artifact；這個 job 只建 image，本身不跑任何測試。
- 機制（跑測試）：承載測試的 job 是 `gate`（五個 gate）與 `test-system-real`，都在同樣兩種 runner 上以原生方式執行同一個 `just test <tier>`，不經模擬；main 的 branch protection 要求 `ci-passed`。
- `test/unit/ci_yml_spec.bats`：「build-image, gate and test-system-real run on the matrix runner」「build-image, gate and test-system-real name both runners in their runner dimension」「the runner dimension of every leg-carrying job is EXACTLY the two runners (a third turns red)」—— 建 image 的 job 與承載測試的 job 都跑在兩種架構上，沒有 job 寫死單一架構。
- `test/unit/ci_yml_spec.bats`：「gate runs every one of the five gates on the runner dimension」「the gate dimension is EXACTLY the five gates (a sixth turns red)」—— 兩種架構跑的是同一組 gate。
- `test/unit/ci_yml_spec.bats`：「build-image uploads the test image under an arch-specific artifact name」「gate downloads the same arch-specific artifact it runs on」「every test-image artifact name carries the runner (no cross-arch collision)」—— 每個架構的 gate 用的是自己架構建出的測試 image，不會拿另一個架構的 image 過關。
- `test/unit/ci_yml_spec.bats`：「ci-passed needs every other job and runs even when one failed」「ci-passed verifies every needed job's result is success」—— 任何一個架構的任何一個 leg 不是 `success`，`ci-passed` 就是紅。
- `test/system/real_engine_spec.bats`：「real engine: assemble.sh with the delivered box/dev.ini creates the dev box from ubuntu:26.04」—— 由 `test-system-real` 在兩種架構上各跑一次，證明兩個架構都能從交付的 `box/dev.ini` 以真實引擎建出 Ubuntu 26.04 的 dev 盒（同一檔其餘真實引擎案例亦同）。

以下尚未守住，不宣稱：

- 等價目前是以「兩個架構各自通過同一套斷言」來近似；沒有把兩個架構的實際輸出互相比對的檢查。跨架構直接比對：待補。
- CI 的 arm64 是 GitHub-hosted 的 `ubuntu-24.04-arm` runner，不是 rpi4、rpi5、jetson 實機；實機上的等價：待補。
- Ubuntu 24.04 盒子：待補（#148）。目前所有檢查都只用 `ubuntu:26.04` 當盒子的 base image；runner 名稱裡的 24.04 是 CI 主機的版本，不代表 24.04 盒子被檢查過。
