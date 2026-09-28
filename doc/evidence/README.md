# doc/evidence -- 驗收清單引用的檢查程式

`doc/acceptance.md` 的驗收方式只寫「呼叫哪一支」,判定邏輯放在這裡,受版本控制。

M3 2.2 與 2.4 的入口現在是 `just verify gate 2.2` / `just verify gate 2.4`
(`script/verify/gate.sh`);這裡的檔案仍然是判定本體,`gate.sh` 只是呼叫它們並
守住結束碼(`tdd.sh` 印得出十行卻 exit 1、負向 fixture 被接受成通過,兩種都讀成紅)。

| 檔案 | 用途 |
| --- | --- |
| `tdd.sh` | 2.2:對每個 sub-issue PR 的描述判定「非空 RED 區塊在前、非空 GREEN 區塊在後」 |
| `tdd.awk` | `tdd.sh` 的判定核心,單獨吃一份 PR 描述;2.4 也直接拿它跑負向 fixture |
| `negative/wrong-order.md` | 2.4 的負向 fixture:RED / GREEN 顛倒 |
| `negative/empty-red-block.md` | 2.4 的負向 fixture:RED 區塊是空的 |

## 2.2 的 9/10 `order=BAD`:排除了什麼、根因未解、處置是什麼(#176 item 8)

保留這段是為了不讓當初的問題只剩結論。

### 立論

- 十個 sub-issue PR(#152-#156、#165-#169)的描述都滿足 2.2 的主張:在本 repo 內
  執行 `bash doc/evidence/tdd.sh` 是 10/10 `order=ok`、`rc=0`。
- 維護者那一輪回報的是 9/10 `order=BAD`。

### 已排除的環境差異(逐項實跑)

先把十份描述取回本機,再對同一批輸入換條件重跑判定核心:

```bash
B=$(mktemp -d) || exit 1
for n in 152 153 154 155 156 165 166 167 168 169; do
  gh pr view "$n" --repo ycpss91255/worktool --json body --jq .body >"$B/$n.md" || exit 1
  sed 's/$/\r/' "$B/$n.md" >"$B/$n.crlf"; sed 's/^/  /' "$B/$n.md" >"$B/$n.indent"
done
A=doc/evidence/tdd.awk
chk() { local lbl=$1 sfx=$2; shift 2; local ok=0 n
  for n in 152 153 154 155 156 165 166 167 168 169; do "$@" "$B/$n$sfx" >/dev/null 2>&1 && ok=$((ok + 1)); done
  printf '%-12s order=ok %s/10\n' "$lbl" "$ok"; }
chk gawk     .md     gawk -f "$A"
chk mawk     .md     mawk -f "$A"
chk busybox  .md     busybox awk -f "$A"
chk LC_ALL=C .md     env LC_ALL=C awk -f "$A"
chk zh_TW    .md     env LC_ALL=zh_TW.UTF-8 awk -f "$A"
chk CRLF     .crlf   awk -f "$A"
chk indented .indent awk -f "$A"
printf 'indented-fences=%s\n' "$(cat "$B"/*.md | grep -cE '^[[:space:]]+`{3}')"
rm -rf "$B"
for s in bash dash sh fish; do printf '%s tdd.sh=%s\n' "$s" "$("$s" -c 'bash doc/evidence/tdd.sh' | grep -c 'order=ok')"; done
```

```text
gawk         order=ok 10/10
mawk         order=ok 10/10
busybox      order=ok 10/10
LC_ALL=C     order=ok 10/10
zh_TW        order=ok 10/10
CRLF         order=ok 10/10
indented     order=ok 0/10
indented-fences=0
bash tdd.sh=10
dash tdd.sh=10
sh tdd.sh=10
fish tdd.sh=10
```

讀法:awk 實作(gawk / mawk / busybox awk)、locale、整份改成 CRLF、以及貼上時所在
的 shell(bash / dash / sh / fish),都是 10/10 `order=ok` —— 這四類差異排除。縮排
是唯一會翻盤的輸入(每行前面加兩個空白就變成 0/10),但取回的十份描述一行縮排的
fence 都沒有(`indented-fences=0`),所以「描述本身是縮排的」也排除;那個 0/10 只是
判定器對行首敏感的紀錄,不是那一輪發生過什麼的證據。

### 根因:未解

維護者那一輪的根因**沒有解出來**,而且從這裡重現不了:那一輪是在維護者的指令
執行器裡跑的,那個環境在這裡沒有,當時的原始輸入、改寫後輸入與工具版本也沒有
留存。這裡不推測那個執行器做了什麼。所以現況是「判定器與這十份描述都經得起查,
但 9/10 `order=BAD` 那一輪的成因仍然未知」。

### 處置:結構性的,不是歸因

當時的判定邏輯是文件裡一段九行的 here-string 函式:只要那段文字在貼上、轉錄或
執行器處理途中被改寫,判定就會跟著變,而文件本身無法證明自己沒被改寫。邏輯移進
受版本控制的 `tdd.awk` / `tdd.sh` 之後,驗收清單那一行只剩 `bash doc/evidence/tdd.sh`
一次呼叫,不再帶任何可被改寫的 shell 語法;`negative/` 兩個 fixture 由 2.4 每次驗收
時證明這個判定器真的會咬。根因未解不影響這個處置成立:它針對的是「文件文字即
判定邏輯」這個結構問題本身。
