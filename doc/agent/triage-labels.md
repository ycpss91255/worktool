# Triage 標籤

skills 用五個標準 triage 角色講話。這個檔把角色對應到本 repo issue tracker 實際使用的標籤字串。標籤名、顏色與說明跟 `ycpss91255-research/vendor_kit` 一致。

| mattpocock/skills 的標籤 | 本 tracker 的標籤 | 意思 |
| ------------------------ | ------------------ | ---- |
| `needs-triage`           | `needs-triage`     | 維護者還沒評估這個 issue |
| `needs-info`             | `needs-info`       | 等回報者補資料 |
| `ready-for-agent`        | `ready-for-agent`  | 規格完整，可交給 AFK agent 實作 |
| `ready-for-human`        | `ready-for-human`  | 需要人來實作（判斷、外部存取、手動測試，例如實機驗收） |
| `wontfix`                | `wontfix`          | 不會處理 |
| （無對應）               | `needs-decision`   | 等維護者做設計決定；不是等回報者補資料。agent 遇到要拍板的問題貼這個，不貼 `needs-info`，並在 issue 附上業界慣例研究與建議 |

skill 提到某個角色時（例如「apply the AFK-ready triage label」），就用表中對應的標籤字串。

其他標籤（`bug`、`documentation`、`enhancement` 等）是 GitHub 預設的分類標籤，跟 triage 狀態無關，維持不動。
