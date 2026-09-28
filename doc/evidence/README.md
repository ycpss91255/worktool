# doc/evidence -- 驗收清單引用的檢查程式

`doc/acceptance.md` 的驗收方式只寫「呼叫哪一支」,判定邏輯放在這裡,受版本控制。

| 檔案 | 用途 |
| --- | --- |
| `tdd.sh` | 2.2:對每個 sub-issue PR 的描述判定「非空 RED 區塊在前、非空 GREEN 區塊在後」 |
| `tdd.awk` | `tdd.sh` 的判定核心,單獨吃一份 PR 描述 |
| `negative/wrong-order.md` | 2.4 的負向 fixture:RED / GREEN 顛倒 |
| `negative/empty-red-block.md` | 2.4 的負向 fixture:RED 區塊是空的 |

## 為什麼 2.2 的邏輯搬到這裡(#176 item 8 的原始問題紀錄)

保留這段是為了不讓當初的問題只剩結論。事實部分:

- 十個 sub-issue PR(#152-#156、#165-#169)的描述都滿足 2.2 的主張。在本 repo 內
  執行 `bash doc/evidence/tdd.sh` 是 10/10 `order=ok`。
- 維護者那一輪回報的是 9/10 `order=BAD`。
- 找不到單一環境差異能重現那個 9/10 的樣態:同一批描述在 gawk、mawk、busybox
  awk、`LC_ALL=C`、以及整份改成 CRLF 之後,結果都還是 10/10 `order=ok`。
- 因此沒有把那一輪歸因到任何已知差異;這裡不推測維護者的執行環境做了什麼。

處置:當時的判定邏輯是文件裡一段九行的 here-string 函式,只要那段文字在貼上、
轉錄或執行器處理途中被改寫,判定就會跟著變,而文件本身無法證明自己沒被改寫。
邏輯移進 `tdd.awk` / `tdd.sh` 之後,驗收清單那一行只剩一次呼叫,`negative/` 兩個
fixture 由 2.4 每次驗收時證明這個判定器真的會咬。
