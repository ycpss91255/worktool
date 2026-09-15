# worktool

以 distrobox 為基礎的開發環境。開發用的 CLI/TUI 工具全部住在一個共用的
distrobox「dev 盒」裡,使用者直接活在盒子內(終端自動進盒);host 只保留
驅動、docker、snapd、桌面 GUI app(以 install script 形式)與容器框架。設定檔
留在共用的 HOME。

這是 `init_ubuntu`(ycpss91255/initialization)的重設計繼任者,為新的大版本。

狀態:設計討論中(M0)。尚未進入實作。設計與 milestone 計畫見
[`doc/design.md`](doc/design.md)。

文件語言:設計文件(PRD / ADR / 計畫等 user 會看到的)以 zh-TW 撰寫;commit
message、PR 內文、程式碼與註解以英文撰寫。
