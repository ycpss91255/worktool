# Extract literal goal text from inline goals or a Markdown goals section.
function emit(text, parts, count, i) {
    count=split(text,parts,/[;；]/)
    for(i=1;i<=count;i++) {
        sub(/^[[:space:]]*([-*+] |[0-9]+[.)] |\[[ xX]\] )*/,"",parts[i])
        sub(/[[:space:]。；;]+$/, "", parts[i])
        if(parts[i]!="") print parts[i]
    }
}
/^[[:space:]]*目標[：:]/ {
    sub(/^[[:space:]]*目標[：:][[:space:]]*/, ""); emit($0); next
}
/^#+[[:space:]]+(目標|Goals)[[:space:]]*$/ { active=1; next }
/^#+[[:space:]]/ { active=0 }
active && /[^[:space:]]/ { emit($0) }
