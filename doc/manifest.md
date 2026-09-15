# 盒子清單格式與 assemble 流程

本文件說明 worktool 的「盒子清單」(box manifest)格式,以及如何從清單
assemble 出共用的 dev 盒。狀態:M2(盒子清單格式 + 最小 assemble)。整體設計與
治理見 [`design.md`](design.md);目錄結構與測試 gate 見
[`structure.md`](structure.md)。

## 決策:直接沿用 distrobox-assemble 原生格式

worktool 的盒子清單**就是一個原生的 distrobox-assemble 檔案**(INI 格式),
不另外發明新格式。理由:

- 研究後重用(research-and-reuse)、不重複(DRY):distrobox 已定義好一套成熟
  的 assemble 清單格式,自訂新格式只會增加維護負擔與轉譯層。
- 相容性:清單可直接餵給 `distrobox assemble create --file <清單>`,不需要任何
  轉換;所有 distrobox-assemble 的鍵(key)天生可用。
- 單一事實來源:盒子的定義只有一份,就是這個清單檔。

## 格式

清單是 INI 檔。**區段標頭(section header)`[名稱]` 就是盒子的名稱**;區段內
以 `鍵=值` 宣告 distrobox-assemble 的欄位。worktool 的共用盒清單放在
[`box/dev.ini`](../box/dev.ini):

```ini
[dev]
image=ubuntu:26.04
additional_packages="ripgrep fzf"
```

### worktool 要求的必要鍵

M2 的 assemble 包裝器(`script/assemble.sh`)在動作前會驗證清單,最少需要:

| 欄位 | 說明 | 必要 |
|------|------|------|
| 區段標頭 `[名稱]` | 盒子名稱(distrobox 以標頭當容器名) | 是 |
| `image=` | 盒子的基底映像檔;M2 鎖定 `ubuntu:26.04` | 是(不可為空) |

### 常用的 distrobox-assemble 欄位(可用,非必要)

沿用 distrobox 原生語意,常見的還有:

- `additional_packages`:要在盒內安裝的套件(空白分隔、以引號包起)。
- `init_hooks` / `pre_init_hooks`:建立盒子後 / 前執行的指令。
- `additional_flags`:傳給容器管理器的額外旗標。
- `volume`、`exported_apps`、`exported_bins`、`start_now`、`nvidia`、`pull`、
  `root`、`entry` 等。

完整欄位以 distrobox 官方 `distrobox-assemble` 文件為準。M2 的 dev 盒刻意只放
1-2 個工具(ripgrep、fzf)以驗證 assemble 流程;完整工具集在 M5-M10 逐步移植
(見 [`design.md`](design.md) 的 milestone 計畫)。

## assemble 流程

`script/assemble.sh` 是一層薄而穩健的包裝器,行為如下:

1. **驗證清單**(`lib/manifest.sh` 的 `manifest_validate`):清單檔存在、有盒子
   名稱、有非空的 `image=`;任一不符即以清楚的 `[ERROR]` 訊息快速失敗
   (fail fast)。
2. **組出 distrobox 呼叫**:`distrobox assemble create --file <清單>`。預設清單為
   `box/dev.ini`。
3. **執行或試跑**:
   - 一般模式:呼叫 distrobox(需要 PATH 上有 `distrobox`)。
   - 試跑模式(dry-run):把「將要執行的完整指令」印到 **STDOUT**、**不執行**。
     以 `WORKTOOL_DRY_RUN=1` 環境變數或 `--dry-run` 旗標開啟。診斷訊息一律走
     STDERR(沿用 `lib/log.sh`),讓 STDOUT 保持乾淨、機器可讀。

包裝器**絕不在 host 上安裝任何東西、也不需要 root**;唯一的副作用是呼叫
distrobox,由 distrobox 自己管理容器。

### 用法

```bash
# 試跑:只印出指令,不執行(單元測試就是斷言這個輸出)
./script/assemble.sh --dry-run
# -> distrobox assemble create --file box/dev.ini

# 以環境變數試跑
WORKTOOL_DRY_RUN=1 ./script/assemble.sh

# 指定其他清單
./script/assemble.sh --file box/other.ini

# 實際 assemble(需要 host 上有 distrobox)
./script/assemble.sh
```

## 測試對應

四層測試金字塔見 [`design.md`](design.md)「測試策略」。M2 落地:

- 單元(`test/unit/manifest_spec.bats`、`test/unit/assemble_spec.bats`):清單驗證
  (有效通過;缺 image / 缺名稱 / 檔案不存在皆以正確訊息失敗)與指令組裝
  (dry-run 印出正確的 `distrobox assemble create --file ...`,且不執行)。純
  bash、完全可 mock。
- 整合(`test/integration/assemble_spec.bats`):把一支 **mock `distrobox`** 放到
  PATH(記錄自己被呼叫的參數),以真實(非 dry-run)模式跑包裝器,斷言它確實以
  `assemble create --file box/dev.ini` 呼叫 distrobox。證明端到端接線,而不需要
  真正的 distrobox。
- 系統(`test/system/real_assemble_spec.bats`):真正的 `distrobox assemble` 需要
  在測試容器內同時有 distrobox 與 docker/podman(docker-in-docker)。在 CI 內架起
  DinD 是已知的可行性挑戰,依 [`design.md`](design.md) **延後到 M5**。M2 以一個
  被 `skip` 的佔位測試記錄「真實 assemble 未來如何驗證」,並且不把它接進 CI
  gate,因此不會阻擋 M2 的 CI。

所有測試都在 Docker 內執行(host 不安裝任何套件);執行方式見
[`structure.md`](structure.md)。
