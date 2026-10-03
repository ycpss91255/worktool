# Only complete rows in the goal trace section can prove coverage.
function trim(text) {
    sub(/^[[:space:]]*/, "", text); sub(/[[:space:]。]+$/, "", text)
    return text
}
/^##[[:space:]]+目標對照[[:space:]]*$/ { active=1; next }
/^#+[[:space:]]/ { active=0 }
active && /^\|/ {
    if(split($0,cells,"|")==6 && trim(cells[2])==goal &&
       trim(cells[3])!="" && trim(cells[4])!="" && trim(cells[5])!="" &&
       trim(cells[3])!="-" && trim(cells[4])!="-" && trim(cells[5])!="-") found=1
}
END { exit !found }
