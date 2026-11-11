# 0023 映像建置經 runner 本機套件代理，從套件快取供檔

- 狀態：已採納（2026-11-10）
- 討論：#892（PR #887 冷建置 17-26 分鐘），parent #824（每個 PR 5-10 分鐘；main 的完整檢查時間不設限）。
- 依據 ADR-0007（永不靜默失敗）、ADR-0021（box 套件快取）、ADR-0022（映像快取與來源切換）。

## 背景

改到 `Dockerfile.ghostty`、`Dockerfile.system-real` 或它們 bind mount 的 `apt-mirror.sh` 的 PR，映像的 apt RUN 層在 gha layer cache 冷掉，整份套件要從鏡像重抓。PR #887 run 42819549766 共 25m56s，其中 `test-system-real (ubuntu-latest)` 的映像建置 `Fetched 129 MB in 21min 50s (98.2 kB/s)`；run 42823630051 共 16m57s。同時間 arm 腿從 ports.ubuntu.com 冷建置 126 MB 只要 9 秒：慢的是 amd64 鏡像對未快取套件的速度，不是建置本身。ADR-0022 決策 4 已排除 BuildKit cache mount（不匯出到 gha）與 build context 餵 deb（RUN 層的 cache key 隨 deb 集合變動）；`apt-box`（ADR-0021）存的是 box 的套件，不是映像的。

## 決策

1. **代理接在 build arg `http_proxy` 上。** Docker 預先定義的 proxy ARG 不進 build cache key，也不寫進映像的 history 或 config（本機 buildx 實測：同一個 RUN 加上 `--build-arg http_proxy=...` 仍是 `CACHED`；`--no-cache` 時 RUN 看得到 `$http_proxy`，`docker history` 沒有它）。所以 Dockerfile 位元組不變、gha 層快取照常命中、映像內容不變。builder 以 `driver-opts: network=host` 建立，RUN 連得到 runner 的 `127.0.0.1`。
2. **代理只快取 pool 的 `.deb`，以檔名為 key**（`script/test/apt-seed-proxy.mjs`）。Debian 檔名含版本，換版就是另一個檔名；索引（`InRelease`、`Packages*`、`by-hash/`）一律直通上游。miss 直通 client 指定的來源，上游的 404 或 5xx 原樣回給 apt、連不上回 502，所以 ADR-0022 的鏡像清單切換與 apt 的 hash 核對不變，全部來源失敗仍是紅燈。`script/test/apt-seed.sh start` 在建置前做健康檢查，代理起不來就讓該步驟失敗，不會默默直連。代理以 Node.js 寫：test image 與兩種 runner 都有 node，unit spec 實際跑它。
3. **映像套件快取 `apt-image-<runner>-<digest>`。** PR 與 main 的映像建置都還原最新一份（唯讀）並經代理建置。main push 的建置命中層快取時沒有任何 `.deb` 經過代理，快取永遠填不起來，所以 main push 另跑 `image-seed`：代理以記錄模式（seed 命中與 miss 都記，第二個映像可沿用第一個記下的）對兩個映像做 `no-cache` 建置，不輸出、不讀也不寫層快取；記下的集合就是「這個 sha 冷建置需要的全部 `.deb`」，以 `apt_cache_key` 的 digest 為 key 寫回，集合不變就不重存。main push 的 `ci-passed` 要求它成功。
4. **PR 路徑只讀。** 只有 main push 寫 `apt-image-`，與 gha 層快取、`apt-box` 相同。

## 影響與限制

- 穩定狀態下 `image-seed` 幾乎全由快取供檔；第一次（快取空）與套件換版時從鏡像下載，在 main 上不限時間。
- PR 的 Dockerfile 新增套件時，新的那幾個仍從鏡像下載。
- nightly 的 isolation（ADR-0022 決策 1）與 full-serial 不經代理：它們在 main 上，時間不設限，full-serial 也要照使用者的裸 `just test` 建置。
- 守住本決策的 spec：`test/unit/apt_seed_proxy_spec.bats`（代理的命中、miss、索引直通、404、502、記錄、`apt-seed.sh` 的啟停與健康檢查）、`test/unit/ci_yml_spec.bats`（三個 job 的接線、`image-seed` 只在 main push、`no-cache`、不寫層快取、digest key、`ci-passed`）。
