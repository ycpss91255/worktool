# #665：PR #673 第 1、2 輪說明更正

本文件依第 2 輪審查更新，修正第 1 輪記錄未涵蓋後續 commit 的問題。
本輪只修正審查與發布文件，不改產品行為、測試或 `doc/acceptance.md`；
先前的 `45a50ab` 與 `790a279` 均已修改 `doc/acceptance.md`，詳見下文。
既有 PR 描述依本輪指示保持原樣；以下更正交由 workflow 發布，發布前不視為遠端已修正。
本輪 fetch 後，本機與遠端 `m3/665-stale-rm-note` 同為
`790a279d1e19826187d84f96dacdf9c4eb2db489`，無須 merge，也未改寫歷史。

## PR #673 更正內容（供 workflow 更新發布說明）

[codex] 採納第 2 輪：本內容取代第 1 輪不完整的更正，補齊變更範圍、六個已推送 commit 與發布狀態。

PR 實際有兩次修改 `doc/acceptance.md`，原描述「未修改 doc/acceptance.md；該處由 #666 處理」不正確：

- `45a50ab705e3f0dfa6893c05e00ae3502f08eeac` 在「本 PR(#157)」段落加入
  「盒內指令說明移除過時的 rm 承諾（`script/box/justfile.box`；#665／PR #673）」。
- `790a279d1e19826187d84f96dacdf9c4eb2db489` 在同一段補列
  `doc/evidence/665-review-round-1.md`（#665／PR #673 的審查紀錄），
  因為 `ac40a46` 新增此檔後，CI 的範圍檢查再次失敗。

這兩處都偏離 #665 驗收中「本 PR 不改 doc/acceptance.md」的限制。
原因是 `test/unit/verify_all_spec.bats:113` 的
`acceptance: PR 157 scope covers every real changed path relative to main`
要求相對 main 的每個實際變更路徑均列入 PR #157 範圍段。
兩次補列分別涵蓋盒內 justfile 與新增證據檔；這是既有偏離的揭露，不代表原 issue 限制沒有被偏離。
第 1 輪文件原先寫「不修改 doc/acceptance.md」，僅描述 `ac40a46` 當時的變更，
沒有涵蓋隨後 `790a279` 的第二次修改；本文件現已補正。

### Commits

截至第 2 輪開始，以下六個 commit 均已推送至遠端分支，原描述的「尚未 push」作廢：

- `fbf04f8b3243b87272ed0ec13c2fcb34b61cae58`：移除根目錄 justfile 與 `doc/structure.md` 的過時承諾，加入回歸測例。
- `6074c7bf1ab6fe4d14575270edeae74dc0cebd3a`：RED，收緊同一個 #665 回歸測例。
- `64cc2a107c6e9d1a10618732f928fb04109ce80d`：GREEN，修正盒內說明與 `doc/design.md` 快照。
- `45a50ab705e3f0dfa6893c05e00ae3502f08eeac`：在 `doc/acceptance.md` 補上盒內 justfile 路徑與 #665／PR #673 註記。
- `ac40a464e19ad23078fa5bd806c686735fc8cb34`：新增本證據檔，記錄第 1 輪更正與協調草稿。
- `790a279d1e19826187d84f96dacdf9c4eb2db489`：第二次修改 `doc/acceptance.md`，補列本證據檔的路徑與來源。

本輪新增的本機 commit 由 workflow 發布時另行附上，不混入上述六個已推送 commit。
workflow 應在再次送審前發布本更正與以下豁免；本輪不直接編輯既有 PR 描述。

## RED exemption

Reason: 第 2 輪只修正審查證據、六個已推送 commit 清單、兩次 acceptance.md 改動的原因與來源註記協調內容；沒有新增或修改產品行為、介面、測試或驗收判準，因此不新增行為測試，也不製造 RED。

## #666 協調留言草稿

[codex] #665／PR #673 的來源註記已由
`45a50ab705e3f0dfa6893c05e00ae3502f08eeac` 加入 `doc/acceptance.md` 的「本 PR(#157)」段落：
「盒內指令說明移除過時的 rm 承諾（`script/box/justfile.box`；#665／PR #673）」。
此舉偏離 #665 原訂不改該文件的限制，原因是 `test/unit/verify_all_spec.bats:113`
要求把相對 main 的實際變更路徑列入該段；PR #673 的更正說明已揭露此偏離。
請 #666 沿用現有 #665／PR #673 註記，避免重複新增或覆蓋；
#666 自己的 5.1 輸出區塊修正、雙向 spec、自身來源註記與相關 spec 註記仍由 #666 處理。
PR #673 尚未合併，整合時請核對該註記是否已在目標分支。
