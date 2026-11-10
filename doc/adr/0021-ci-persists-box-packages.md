# 0021 CI 保存 box 首次啟動下載的套件

- 狀態：已採納（2026-11-10）
- 討論：#847（#843 之後 amd64 的 apt 仍不穩），parent #824（PR 5-10 分鐘目標）。
- 依據 ADR-0007（永不靜默失敗）與 ADR-0010（黑箱可驗）。

## 背景

#843 把 amd64 腿的 apt 來源改成 runner 旁的 azure 鏡像，但它是 Canonical archive 的 pull-through：未快取的套件仍以上游速度下載。test-system-real（amd64）在 #843 之後的 60 次 run 中，box 首次啟動有多次 11-15 分鐘（run 42789089105：12m37s；42791926190：11m30s），也有撞上 `FIRST_ENTER_TIMEOUT=900` 而失敗的（42793973579，job 1195 秒；42772739783）；鏡像正常時首次啟動約 52 秒、整個 job 約 170-230 秒。首次啟動每次約下載 250 個套件。

## 決策

1. CI 以 actions/cache 保存 box 首次啟動下載的 `.deb`：`test-system-real` 每次還原最新一份（前綴 `apt-box-<runner>-`），只有 main push 修剪（每個套件與架構留最新版本）並以保留集合的 digest 為 key 寫回，集合不變就不重存。
2. 套件經 `Dir::Cache::Archives` 指到 box 透過 `/run/host` 看得到的 runner 目錄（`apt-mirror.sh --archives`）；distrobox-init 照樣執行 `apt-get update` 與完整 `apt-get install`，受測路徑不變。apt 以索引的版本與 hash 核對每個快取檔，過期的檔只會多一次下載，不會裝錯。
3. 索引與 pool 不一致（2026-11-10 的 `perl 5.40.1-7ubuntu0.4`）：不採用 snapshot.ubuntu.com。它的 http 一律 301 轉到 https，而 `ubuntu:26.04` 基底沒有 `ca-certificates`，要先裝套件才讀得到，會改動受測的首次安裝；`Acquire::Retries` 或重跑 `apt-get update` 對持續數小時的不一致也無效。快取讓已在目錄裡的版本不再下載，不一致只在「索引已指向新版、pool 還沒有」的那個套件上才會失敗，且失敗照樣是紅燈（不靜默）。

## 影響與限制

- 映像建置（`Dockerfile.system-real`、`Dockerfile.ghostty`）仍只靠 buildx 的 gha cache；Dockerfile 一改或 main push 建置失敗時 PR 會重新 apt，未納入本決策。
- 本 PR 自己的 CI 還沒有快取（只有 main push 寫入）；效果以合併後的 PR 量測，記在 #847。
- 守住本決策的 spec：`test/unit/apt_mirror_spec.bats`（`--archives`、修剪與 key）、`test/unit/system_real_entry_spec.bats`（box 映像重建）、`test/unit/test_sh_spec.bats`（掛載）、`test/unit/ci_yml_spec.bats`（還原、修剪、寫回的接線）。
