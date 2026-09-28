# Prove: a non-empty fenced block introduced by a RED line, then a later
# non-empty fenced block introduced by a GREEN line.
{ sub(/\r$/, ""); line[NR] = $0; outside[NR] = (infence == 0) }
/^```/ {
  if (infence == 0) { infence = 1; open = NR; filled = 0; next }
  infence = 0
  tag = ""
  for (i = open - 5; i < open; i++) {
    if (i < 1 || outside[i] != 1) continue
    if (line[i] ~ /RED/ && line[i] !~ /GREEN/) tag = "RED"
    else if (line[i] ~ /GREEN/ && line[i] !~ /RED/) tag = "GREEN"
  }
  if (filled == 0) next
  if (tag == "RED" && red == 0) red = open
  if (tag == "GREEN" && green == 0 && red > 0) green = open
  next
}
infence == 1 && /[^ \t]/ { filled = 1 }
END {
  if (red > 0 && green > red) printf "order=ok red=%d green=%d\n", red, green
  else { printf "order=BAD red=%d green=%d\n", red, green; exit 1 }
}
