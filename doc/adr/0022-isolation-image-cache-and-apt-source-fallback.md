# 0022 isolation 重用映像快取，鏡像缺檔時依序換來源

- 狀態：已採納（2026-11-10）
- 討論：#885（#874 的 nightly 失敗），parent #824（完整檢查不得因網路抖動失敗、也不得少測）。
- 依據 ADR-0007（永不靜默失敗）、ADR-0018（isolation 守門）、ADR-0021（box 套件快取）。

## 背景

nightly 的 `isolation (ubuntu-latest)` 在多數 main push 失敗（#874）。它以 test.sh 自己的 `docker build` 建 ghostty 與 system-real 映像，沒有 ci.yml 用的 buildx gha cache，每次都向 `azure.archive.ubuntu.com` 下載整份套件：慢（run 42809978056：`Fetched 123 MB in 19min 30s (105 kB/s)`），且索引已指向新版、pool 還沒有的時候直接失敗（`perl`、`libperl5.40` `5.40.1-7ubuntu0.4` 回 404，ghostty 映像建置失敗，isolation 停在 integration）。ADR-0021 決策 3 拒絕 snapshot.ubuntu.com 的理由仍成立，但「不一致就紅燈」對沒有快取的建置來說等於每次都可能紅。

## 決策

1. isolation job 先以 buildx 建兩個 Ubuntu 映像，參數與 ci.yml 相同（同 Dockerfile、tag、`APT_MIRROR` build arg、`cache-from: type=gha,scope=<image>-<runner>`），只讀不寫（沒有 `cache-to`，寫入者維持 ci.yml 的 main push），再以 `GHOSTTY_IMAGE_PREBUILT=1`、`SYSTEM_REAL_IMAGE_PREBUILT=1` 交給各階段。快取命中時映像建置不碰鏡像。隨機順序與殘留檢查（ADR-0018）不變；映像不在殘留快照內。
2. `script/test/apt-mirror.sh` 給了鏡像時，把每行 `URIs:` 改成 apt 的 `mirror+file:/etc/apt/worktool-mirrors.list`：鏡像 `priority:1`，接著是 sources 檔原本的 URIs（依檔內順序，去重；amd64 為 archive.ubuntu.com 再 security.ubuntu.com，arm 為 ports.ubuntu.com）。鏡像取不到某個檔（404 或其他失敗）時，apt 對該檔改向下一個來源取，log 是 `Ign:N <鏡像> <套件>` 接著 `Get:N <下一個來源> <套件>`；每個檔照樣以索引的 hash 核對；全部來源都失敗時仍是 `E: Failed to fetch` 紅燈。這是固定順序的來源切換，不是盲目重試；腳本開頭印出鏡像與完整的備援順序。它套用在兩個映像建置與 box 首次啟動（三處都經由 apt-mirror.sh），所以 full-serial 與 ci.yml 也受保護。
3. 必須帶 `priority:`：本機以 ubuntu:26.04（apt 3.2.0）實測，沒有 priority 的清單會把下載分散到各項（`libonig5` 走第二項、其餘走第一項），會把部分套件送到慢的上游、抵銷 #843；有 priority 時兩種順序各 37/37 個檔都從 priority 1 下載。priority 1 換成會 404 的路徑時每個檔都是 `Ign` 後由 priority 2 取得；全部 404 時 `apt-get` exit 100。
4. 不另做映像建置的 deb 快取：BuildKit 的 `type=cache` mount 不會匯出到 `type=gha`，跨 runner 不保留；把 `apt-box` 以 build context 餵進建置會讓該 RUN 層的 cache key 隨 deb 集合變動，反而讓層快取失效；`apt-box` 保存的是 box 的套件，不是映像的。這兩種做法仍不採用；映像建置的套件快取改由 ADR-0023 以 runner 本機代理（`http_proxy` build arg，不進層快取 key）提供（#892）。
5. full-serial 不預先建映像：它跑的是使用者打的裸 `just test`，含 test.sh 自己的 `docker build`；決策 2 同樣保護它。

## 影響與限制

- gha 快取冷的時候（Dockerfile 或它 bind mount 的 `apt-mirror.sh` 改了、ci.yml 的 main push 還沒寫完），isolation 照樣從鏡像完整下載，慢但不再因單一套件的不一致失敗；本 ADR 引入的 PR 自己改了 apt-mirror.sh，合併後第一次 main push 就是冷的。
- 備援來源也有同一個不一致（上游本身 pool 缺檔）時仍會紅燈，這是 ADR-0007 要的結果。
- 守住本決策的 spec：`test/unit/apt_mirror_spec.bats`（清單、順序、priority、去重、log）、`test/unit/nightly_yml_spec.bats`（isolation 的 buildx 建置、只讀快取、PREBUILT env，full-serial 不預先建）。
