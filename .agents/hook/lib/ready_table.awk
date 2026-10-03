# Only complete rows in the goal trace section can prove coverage.
function trim(text) {
    sub(/^[[:space:]]*/, "", text); sub(/[[:space:]]+$/, "", text)
    return text
}
/^##[[:space:]]+目標對照[[:space:]]*$/ { active=1; next }
/^#+[[:space:]]/ { active=0 }
active && /^\|/ {
    if ($0 == "| 目標 | 使用者實際入口 | 測試或驗收項目 | 證據 |") header=1
    if(header && split($0,cells,"|")==6 && trim(cells[2])==goal &&
       trim(cells[3])!="" && trim(cells[4])!="" && trim(cells[5])!="" &&
       trim(cells[3])!="-" && trim(cells[4])!="-" && trim(cells[5])!="-") found=1
}
END { exit !(header_only ? header : found) }
