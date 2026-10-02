# #363：verify 映像的工具相容性盤點

盤點來源是驗收 PR #157 的 head `5997f18ed8bcb40544826585b195bf9399e21499`，涵蓋 `script/verify/*.sh` 及 gate 呼叫的 `doc/evidence/tdd.sh`。本修正只更新驗收執行環境，不改驗收條件或略過 evidence 6.1。

| 腳本 | 工具或版本假設 | 映像供應與檢查 |
| --- | --- | --- |
| `evidence.sh` | Bash 關聯陣列與 nameref；GNU timeout；gh checks 的 `--json name,bucket`；pr view 的 `--json body --jq`；pr list 的 `--state merged --search --json number,body --jq`；api 的 `--paginate --jq`；jq 的陣列、字串與正規表示式操作；grep 的 ERE | Ubuntu Bash、coreutils、grep；jq 套件；gh 改由官方 apt repository 安裝現行版本。建置檢查 checks 的 JSON 能力，真實工具 spec 檢查全部 gh 查詢旗標。api 沒有 `--repo`，原腳本以 endpoint 明確指定 repository。 |
| `gate.sh`、`doc/evidence/tdd.sh` | Docker CLI 可連 runner daemon；just module 與參數轉發；GNU timeout；Bash；awk、grep；gh pr view 的 JSON/JQ | Docker、just 由 verify image 安裝；Ubuntu 提供其餘工具。gh pr view 納入上述 spec。daemon socket 與相同絕對 checkout 路徑由 CI 掛載。完整 tier 僅由 CI 執行。 |
| `setup.sh`、`config_backup_paths.sh` | 真實 Ghostty 在 PATH；1.3 起使用新版設定位置；真實 distrobox 可解析絕對路徑與執行 list；GNU sed、find、wc、readlink；env、mktemp、cp、diff、ln、chmod、sh | 沿用 Ubuntu 26.04 的真實 Ghostty image 與 test image checksum 驗證的 distrobox 1.8.2.5。其餘為 Ubuntu 工具；前一輪 #157 的 setup 已通過，本次未發現額外版本缺口。 |
| `ui.sh` | just recipe/help 輸出；GNU timeout、grep、sort、wc | 沿用 verify image 的 just 與 Ubuntu 工具；前一輪 ui 已通過。 |
| `diagram.sh` | grep 的 ERE 與檔案讀取 | Ubuntu grep；前一輪 diagram 已通過。 |
| `all.sh` | Bash dispatcher 可執行各組腳本，失敗須中止 | Ubuntu Bash；保持原 dispatcher 與失敗行為。 |
| `realbox.sh` | 真實 distrobox/容器/桌面與使用者設定；gh issue comment 的 `--body-file`、api 讀取；jq `--rawfile`；GNU find/sort 的 NUL 分隔；time、awk、sha256sum 等 | 此組需要明確實機 opt-in，本來不屬於 CI 的 `verify all`。映像供應 gh/jq/GNU 工具不代表能取代實機驗收；本次不新增實機執行或留言。 |

官方 apt 設定依 [GitHub CLI 安裝文件](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)，使用獨立 keyring、`signed-by` 與 `dpkg --print-architecture`，不寫死 amd64。既有 verify-all matrix 在 amd64 與 arm64 原生 runner 都執行 `just test verify-env`，因此兩邊都會建置映像並執行真實 gh spec。版本號只作診斷，所需命令能力才是驗證條件。

本機 RED/GREEN 與推送前 gates 的完整輸出保存在被 gitignore 的 `.agents/state/363-*.log`；PR 說明附其尾段。#363 保持開啟，待修正納入 #157 且其 verify-all 兩架構 GREEN 才完成該 issue 的驗收。
