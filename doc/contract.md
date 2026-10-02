# worktool 對外契約

本文件是 worktool 對使用者的契約：要解決什麼、做什麼、不做什麼、承諾什麼。內容全部來自 #200 的定案，以及之後已採納的 ADR（[`adr/0002-box-owns-its-home.md`](adr/0002-box-owns-its-home.md)、[`adr/0003-latency-gate-inconclusive.md`](adr/0003-latency-gate-inconclusive.md)）；未定案的事不寫進來。

- 契約放在 `doc/contract.md`，是本 repo 文件結構唯一偏離 skill 慣例之處：契約要與程式在同一個 PR 審查，避免兩者悄悄脫鉤（#200 第 8 點）。
- 名詞：**tool config** 是盒內工具的設定（例如 tmux、fish、nvim）；**user config** 是使用者自己的設定與憑證（例如 `~/.ssh`、金鑰、token）。避免說「dotfiles」：它同時指這兩種，而 worktool 對兩者的承諾正好相反。
- 每條承諾都附「驗證：」一行，寫明由哪個測試或哪個人類驗收項目檢查；還沒有檢查的標「待驗」（不變量 7：對外承諾必須黑箱可驗）。「待驗」不是豁免，是還沒兌現的檢查。

## 1. 要解決的痛點

- 主痛點：**重建成本高**。換機、重灌要把整套環境重跑一遍；host 升級會弄壞裝在 host 上的工具。
- worktool 的 module 系統（盒子清單、`just` 命名空間、分開的 host install script）看起來重，是為了服務主痛點：讓「重建」變成可重複、可驗證的一個動作。
- 次要痛點：host 被弄髒（工具與設定散在 host 上）；跨機器不一致（每台機器裝出來的不一樣）。

## 2. worktool 做的事

- **核心承諾：驅動裝好之後，一個指令建好 worktool 環境。** 建好的意思是：開終端即在盒內、盒內工具可用、tool config 就位。驅動與 GUI app 是例外，各自是獨立的 host install script，不在那一個指令內（見第 3 節）。目前建盒（`just box assemble`）與終端進盒設定（`just box setup`）還是兩個指令，tool config 要到 M5 才開始放進盒子 HOME。
  - 驗證：待驗（整條承諾尚無從公開入口一次跑完的測試）。已有的部分檢查：`test/system/real_engine_spec.bats` 以真實 docker 引擎從 `box/dev.ini` 建出 dev 盒並在盒內執行 `rg`／`fzf`／`tmux`／`fish`，並以真的 ghostty 視窗證明受管區塊的指令會在盒內跑起 fish（ghostty chain 案例）。
- **tool config 隨重建回來。** tool config 在 repo 內只有一份（不變量 2），重建時就位在盒子自己的 HOME。盒子使用獨立 HOME（[ADR 0002](adr/0002-box-owns-its-home.md)，預設 `~/<盒名>-box`，dev 盒為 `~/dev-box`，可用 `just box assemble --home <路徑>` 指定），tool config 只放在盒子 HOME。
  - 驗證：待驗（tool config 從 M5 起才放進盒子 HOME，尚無「重建後 tool config 仍在」的測試）。盒子 HOME 本身已有檢查：`test/system/real_engine_spec.bats` 的 #198 案例（盒內 `$HOME` 就是 `--home` 指定的路徑；已存在的盒子給了不同的 `--home` 以結束碼 1 拒絕且盒子 HOME 不變）；`test/unit/assemble_spec.bats` 的 #198 案例（預設路徑、`--home` 的驗證與紀錄）。

## 3. worktool 不做的事

- **不管 user config。** `~/.ssh`、金鑰、token 等 worktool 不寫、不進 repo。依 ADR 0002 決策 3，user config 之後會以 symlink 從 host HOME 帶進盒子 HOME（不複製、不修改，host 那份是唯一一份），尚未實作，將由 #199 實作。
  - 驗證：待驗（#199 落地時補測試）。
- **不在 host 用 apt 裝 CLI／TUI 工具。** CLI／TUI 工具一律裝在盒內，盒子清單只有 `box/dev.ini` 一份。
  - 驗證：待驗（尚無檢查「沒有任何腳本在 host 呼叫 apt」的測試）。盒內安裝的部分由 `test/system/real_assemble_spec.bats` 檢查：真實 distrobox 送到容器管理器的建盒請求帶有清單裡的套件。
- **不寫 host shell 設定。** host 與盒子互不干擾：用非 ghostty 開的終端拿到的是 worktool 沒碰過的 host shell。`just box setup` 只寫 worktool 自己的狀態檔與終端設定裡標記的受管區塊（見 [`enter.md`](enter.md)）。盒子使用獨立 HOME 是這條的機制（#196、[ADR 0002](adr/0002-box-owns-its-home.md)）；ADR 0002 也寫明 `--home` 不是隔離，盒內仍能以絕對路徑讀寫 host HOME。
  - 驗證：待驗（尚無檢查「host 的 shell 設定檔沒有被寫」的測試）。受管區塊只寫在宣告的檔案由 `test/unit/setup_spec.bats` 檢查。
- **驅動與 GUI app 不在那一個指令內。** 驅動（nvidia、kvm）與 GUI app 各自是獨立的 host install script（`tool/`，M11／M12）。
  - 驗證：待驗（`tool/` 目前只有佔位，M11／M12 落地時補）。
- **目前只有單一 dev 盒。** 所有 CLI／TUI 工具在同一個 `dev` 盒；之後有需要再切分。
  - 驗證：`test/system/real_engine_spec.bats` 以真實 docker 引擎從交付的 `box/dev.ini` 建出 `dev` 盒；`test/unit/manifest_spec.bats` 檢查清單格式。「之後切分」不是承諾，不驗。
- **以 Ubuntu 26.04 為主。** 盒子 base image 是 `ubuntu:26.04`；24.04 之後追加（#148），在那之前不承諾。
  - 驗證：`test/system/real_engine_spec.bats` 以 `ubuntu:26.04` 建出 dev 盒。24.04：待驗（#148）。

## 4. 對使用者的承諾

承諾對象只有一種角色：**使用者 = 在自己機器上用 worktool 的人**。開發 worktool 的約定（git、測試、agent 流程）留在 [`AGENTS.md`](../AGENTS.md)，不是本契約的一部分。

以下每條對應第 6 節的一條不變量；性質的完整定義在該不變量的 ADR。

- **使用者寫的內容歸使用者。** worktool 可以新建檔案；在既有檔案只在自己標記的受管區塊內寫；移除時只移除自己寫的；使用者的內容不刪、不覆蓋，要改既有內容先問（不變量 1）。例外是 worktool 自己的狀態檔 `~/.config/worktool/config`：它沒有受管區塊，改以狀態鍵劃分歸屬，狀態鍵所在的行歸 worktool、可以不問就換掉，但使用者存進狀態鍵的選擇要沿用；檔內其他的行照樣歸使用者（[ADR 0004](adr/0004-invariant-user-content.md)）。
  - 驗證：`test/unit/setup_spec.bats`（受管區塊前後的使用者內容保留；`--auto-enter no` 只移除受管區塊並回報、保留使用者內容；`--dry-run` 不寫；使用者存進狀態鍵的選擇沿用）；`test/integration/assemble_spec.bats`（assemble 只換掉狀態檔的 `home` 那一對，其他行原樣留下）。「要改先問」：待驗。狀態檔裡使用者自己加的行：待驗，目前 `just box setup` 重寫狀態檔時會刪掉它們，違反本條（見 ADR 0004 的待補）。
- **一個來源。** 盒子定義只有 `box/dev.ini` 一份；tool config 在 repo 內只有一份（不變量 2）。
  - 驗證：待驗（tool config 從 M5 起才進 repo）。盒子定義的單一來源由 `test/integration/assemble_spec.bats` 部分檢查：assemble 預設就是用 `box/dev.ini`。
- **host 與盒子互不干擾。** 見第 3 節「不寫 host shell 設定」（不變量 3）。
  - 驗證：待驗（同第 3 節）。盒子 HOME 與 host HOME 分開由 `test/system/real_engine_spec.bats` 的 #198 案例檢查。
- **永不靜默失敗。** 每個自動決策都印 log 且可查（`[INFO] <key>: <value> (default|user)`，事後以 `just box status` 讀回）；失敗必印原因與下一步；結束碼是對外契約：`0` 成功、`1` 功能性失敗、`2` 參數錯誤（`<腳本>: unknown option '<x>' (see --help)`）；進盒延遲量測（`just box bench`）多一個結束碼 `3` 表示主機不夠安靜、**未判定**，既不算通過也不算退化（[ADR 0003](adr/0003-latency-gate-inconclusive.md)）（不變量 4）。
  - 驗證：`test/unit/justfile_spec.bats`（未知選項由腳本本身以結束碼 2 拒絕）；`test/unit/assemble_spec.bats`、`test/unit/setup_spec.bats`（結束碼 2 與訊息格式、決策 log）；`test/unit/status_spec.bats`（決策與來源讀回）；`test/unit/bench_spec.bats`（主機忙時結束碼 3、不印量測值）。
- **使用者介面極少。** 所有使用者動作都經 `just <命名空間> <recipe>`；recipe 的語意一旦發布就不改，改名走別名期（不變量 5）。
  - 驗證：`test/unit/justfile_spec.bats`（根 justfile 只有命名空間、每個 recipe 原封轉發給腳本）；人類驗收見 `doc/acceptance.md` M2 第 0 項。「發布後語意不改」：待驗（尚未發布）。
- **冪等。** 同一個指令重跑，結果相同：不重複寫入、不累積副作用；已是最新狀態時明確說明 unchanged（不變量 6）。
  - 驗證：`test/unit/setup_spec.bats`（受管區塊只寫一次，重跑回報 unchanged）；`test/system/real_engine_spec.bats`（第二次 assemble 以結束碼 0 結束且不重複建盒）。
- **對外承諾黑箱可驗，開發與正式使用走同一個入口。** 目標是讓本節所有承諾都能從公開入口（`just`）以自動或人類驗收檢查，測試不走後門；CI 跑的就是使用者打的 `just test <tier>`（不變量 7）。目前尚未兌現：上面標「待驗」的承諾還沒有檢查。
  - 驗證：`test/unit/justfile_spec.bats`（ci.yml 的每個 gate 都以 `just test <tier>` 執行）；本文件的「驗證：」行由 `test/unit/contract_spec.bats` 檢查存在且引用的測試檔存在。「每條承諾都從 `just` 驗」：待驗（見上方各條的「待驗」）；`test/acceptance/m2_selfcheck_spec.bats` 直接執行 `script/test/selfcheck.sh`、不經 `just`，所以不算這條的檢查。
- **host 依賴最小。** 除了驅動與 GUI app，host 只需要 `docker` 與 `just`；其餘一切在盒內（不變量 8）。
  - 驗證：人類驗收見 `doc/acceptance.md` M2「通用指令」前提（只檢查 `just` 與 `docker`）。自動檢查：待驗。
- **正確性不綁單一平台。** 同一版 repo 在每個支援平台（amd64、arm64；Ubuntu 26.04，之後追加 24.04）得到等價結果（不變量 9）。
  - 驗證：`test/unit/ci_yml_spec.bats`（CI 每個 gate 都同時跑 amd64 與 arm64 兩種 runner，`ci-passed` 要求兩者都綠）。24.04：待驗（#148）。

## 5. 相容性承諾

- **同一個大版號內不破壞原本的用法。** 版本號為 X.Y.Z：同一個 X 內，原本的用法持續可用、設定檔格式只加不改；只有 X 變動才可能不相容，且先公告升級步驟（不變量 10）。
  - 驗證：待驗（尚未發布任何版本；第一個 release 是 M17）。

## 6. 不變量索引

十條不變量必須永遠成立；每條的性質、理由與守住它的機制由各自的 ADR 定義。已寫好的 ADR 直接連結；尚未寫的，後面列的是負責寫它的 issue，ADR 合併時同一個 PR 改成連結。每條都保留負責的 issue 編號。

1. 使用者寫的內容歸使用者：可以新建、要改先問、永不刪、永不覆蓋（[ADR 0004](adr/0004-invariant-user-content.md)，#202）
2. 一個來源：盒子定義只有一份、tool config 只有一份（[ADR 0005](adr/0005-invariant-single-source.md)，#203）
3. host 與盒子互不干擾（[ADR 0006](adr/0006-invariant-host-box-separation.md)，#204）
4. 永不靜默失敗（[ADR 0007](adr/0007-invariant-no-silent-failure.md)，#205）
5. 使用者介面極少：just 是唯一入口，recipe 語意固定（[ADR 0008](adr/0008-invariant-minimal-interface.md)，#206）
6. 冪等：同一個指令重跑，結果相同（[ADR 0009](adr/0009-invariant-idempotent.md)：#207）
7. 對外承諾必須黑箱可驗；開發與正式使用走同一個入口（[ADR 0010](adr/0010-invariant-black-box-verifiable.md)，#208）
8. host 依賴最小：除驅動與 GUI app 外，只需 docker 與 just（[ADR 0011](adr/0011-invariant-minimal-host-deps.md)，#209）
9. 正確性不綁單一平台（[ADR 0012](adr/0012-invariant-platform-neutral.md)，#210）
10. 相容性：同一個大版號內不破壞原本的用法（[ADR 0013](adr/0013-invariant-compatibility.md)，#211）

#200 定案時，第 11 條「進盒 < 300 ms」待 #181 定案，本索引不列入；是否補列另行決定。
