# M3 人類驗收清單

此清單供維護者記錄人工審閱；未勾選不代表通過。完整驗收判準與實機輸出見 [驗收文件](acceptance.md)。

- [ ] 在 GitHub README 逐張檢視[架構圖](diagram/architecture.drawio.svg)、[流程圖](diagram/flow.drawio.svg)及 [milestone 圖](diagram/milestone.drawio.svg)：文字可見、沒有「Text is not SVG」；流程圖顯示的階段與連線符合內嵌圖源。
- [ ] 審閱 #152–#156、#165–#169 的 RED／GREEN 證據內容。自動檢查只驗非空區塊、次序及完整集合；#156 的 RED 是事後 mutation，不代表原始 test-first。
- [ ] 在 Ghostty 實機判斷開窗是否主觀順暢，並完成以下流程及記錄結果：
  1. 在原本的 host 終端與同一 checkout、工作目錄執行 `just verify realbox --allow-real-box 5.2.1`，確認成功與 `backup-covers=5/5`，保存備份位置。
  2. 在同一 host 終端、checkout 與工作目錄執行 `just verify realbox --allow-real-box 5.2.2`，確認成功；此步自動檢查新 fish 並清理測試視窗。
  3. host 已有 tmux server 時，自行開啟 Ghostty 新測試視窗，確認 `test -e /run/.containerenv -o -e /.dockerenv` 成立、`echo $FISH_VERSION` 有值，判斷並記錄開窗是否順暢；在盒內執行 `tmux`，確認看不到 host sessions。
  4. 在 host tmux pane 執行 `distrobox enter dev`，在盒內執行 `tmux`，確認看不到 host sessions。只結束自己建立的測試 session 和視窗，不關閉既有 host tmux 或既有視窗。
  5. 回到原本同一 host 終端、checkout 與工作目錄執行 `just verify realbox --allow-real-box 5.2.3`，不要在新進盒測試視窗執行還原。確認 `restore-files-ok=1`、`restore-window-ok=1`、`restore-ok=1`、`dev-gone=1`、`backup-removed=1` 與 `cleanup-rc=0`；失敗時保留備份，依診斷處理後重試。
- [ ] 確認新終端在盒內 fish，且新終端與 host tmux pane 手動進盒兩條路徑的盒內 tmux 都看不到 host sessions。host tmux server 或其他必要條件不足時維持待驗。

實機前提：使用解鎖的圖形桌面與已執行的 Ghostty，具備 distrobox、Ghostty、just 與 realbox help 所列工具。三個命令維持相同 HOME、XDG 設定及工作目錄；確認 manifest 同名盒不存在，兩份 Ghostty 設定均無 worktool 受管區塊，勿並發修改備份或受管設定。此流程會建立並清除本輪盒子，並暫時改動真實設定。退出碼 3 是未判定，不勾選；條件不足時維持待驗。
