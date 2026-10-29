# #665：PR #673 第 1 輪說明更正

本輪只補齊審查與發布說明，不修改產品程式、測試或 `doc/acceptance.md`。
既有 PR 描述保持原樣；以下更正與協調留言交由 workflow 發布，發布前不視為遠端已修正。
fetch 後本機與遠端 `m3/665-stale-rm-note` 同為
`45a50ab705e3f0dfa6893c05e00ae3502f08eeac`，無須 merge，也未改寫歷史。

## PR #673 更正留言草稿

[codex] 採納第 1 輪：本留言更正既有 PR 描述的變更範圍、commit 清單與發布狀態。

PR 實際有修改 `doc/acceptance.md`，原描述「未修改 doc/acceptance.md；該處由 #666 處理」不正確。
`45a50ab705e3f0dfa6893c05e00ae3502f08eeac` 在該文件「本 PR(#157)」段落加入
「盒內指令說明移除過時的 rm 承諾（`script/box/justfile.box`；#665／PR #673）」。
這偏離 #665 驗收中「本 PR 不改 doc/acceptance.md」的限制：
`test/unit/verify_all_spec.bats:113` 的
`acceptance: PR 157 scope covers every real changed path relative to main`
要求相對 `origin/main` 的每個實際變更路徑均列入該段。
本 PR 修改了 `script/box/justfile.box`，因此前述 commit 補列路徑與來源註記以滿足該檢查。
這是既有偏離的揭露，不代表原 issue 限制沒有被偏離。

截至本輪開始，以下四個 commit 均已推送；原描述「續作兩個 commit … 尚未 push」作廢：

- `fbf04f8b3243b87272ed0ec13c2fcb34b61cae58`：移除根目錄 justfile 與 `doc/structure.md` 的過時承諾，加入回歸測例。
- `6074c7bf1ab6fe4d14575270edeae74dc0cebd3a`：RED，收緊同一個 #665 回歸測例。
- `64cc2a107c6e9d1a10618732f928fb04109ce80d`：GREEN，修正盒內說明與 `doc/design.md` 快照。
- `45a50ab705e3f0dfa6893c05e00ae3502f08eeac`：在 `doc/acceptance.md` 補上盒內 justfile 路徑與 #665／PR #673 註記。

第 1 輪僅新增本說明文件的 commit，發布狀態由 workflow 發布時補充。
既有 PR 的 RED／GREEN 證據仍適用於原本的行為修正；本輪免除 RED 的理由如下，
workflow 應在再次送審前連同更正留言發布；本輪遵照指示不編輯既有 PR 描述。

## RED exemption

Reason: 本輪只補齊 PR #673 的變更範圍、已推送 commit 清單、偏離 #665 文件限制的原因，以及 #666 的來源註記協調說明；沒有新增或修改產品行為、介面、測試或驗收判準，因此不新增行為測試，也不製造 RED。

## #666 協調留言草稿

[codex] #665／PR #673 的來源註記已由
`45a50ab705e3f0dfa6893c05e00ae3502f08eeac` 加入 `doc/acceptance.md` 的「本 PR(#157)」段落：
「盒內指令說明移除過時的 rm 承諾（`script/box/justfile.box`；#665／PR #673）」。
此舉偏離 #665 原訂不改該文件的限制，原因是 `test/unit/verify_all_spec.bats:113`
要求把相對 main 的實際變更路徑列入該段；PR #673 的更正說明已揭露此偏離。
請 #666 沿用現有 #665／PR #673 註記，避免重複新增或覆蓋；
#666 自己的 5.1 輸出區塊修正、雙向 spec、自身來源註記與相關 spec 註記仍由 #666 處理。
PR #673 尚未合併，整合時請核對該註記是否已在目標分支。
