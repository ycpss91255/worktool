# .agents/hook/lib/unquote.awk - the quoting pass of subcommand.sh (see its
# header, steps 2 and 3). Portable to mawk: no bracket classes, index().
#
# Input: one command line; the whole input is one record, so a quoted span
# may cross lines. Output: the same line where
#   - every quoted span is one opaque word: the quotes go, and each
#     separator inside it (whitespace ; & | < > ( )) is written as \001 plus
#     a letter (enc), so the caller splits only on real separators and can
#     still decode the span when it is a `bash -c` / `eval` script
#   - a backslash-escaped character outside single quotes is taken
#     literally the same way; an escaped newline outside quotes is dropped
#   - the body of each $(...), `...` and <(...) / >(...) is launched by the
#     shell, so it moves to its own line after the command and is replaced
#     there by the marker \001s (shown as "_"). Inside single quotes none of
#     these is special; $(...) and `...` inside double quotes still run
BEGIN {
    RS = "\001"; SEP = " \t\r\n;&|<>()"; LET = "abcdefghijk"
    ESC = sprintf("%c", 1); SQ = sprintf("%c", 39); BQ = sprintf("%c", 96)
}
function enc(c,    k) { k = index(SEP, c); return k ? ESC substr(LET, k, 1) : c }
function push(kind) {
    sd++; skind[sd] = kind; sq[sd] = q; sbuf[sd] = buf; spar[sd] = par
    q = ""; buf = ""; par = 0
}
function pop() {
    extra = extra "\n" buf
    q = sq[sd]; buf = sbuf[sd] ESC "s"; par = spar[sd]; sd--
}
{
    n = length($0); q = ""; buf = ""; extra = ""; sd = 0; par = 0
    for (i = 1; i <= n; i++) {
        c = substr($0, i, 1); nx = substr($0, i + 1, 1)
        if (q == SQ) { if (c == SQ) q = ""; else buf = buf enc(c); continue }
        if (c == "\\" && i < n) {
            i++; c = substr($0, i, 1)
            if (!(c == "\n" && q == "")) buf = buf enc(c)
            continue
        }
        if (c == "$" && nx == "(") { i++; push("("); continue }
        if (q == "" && (c == "<" || c == ">") && nx == "(") { i++; push("("); continue }
        if (c == BQ) {
            if (sd > 0 && skind[sd] == BQ && q == "") pop(); else push(BQ)
            continue
        }
        if (q == "" && c == ")" && par == 0 && sd > 0 && skind[sd] == "(") { pop(); continue }
        if (q == "" && c == "(") par++
        if (q == "" && c == ")" && par > 0) par--
        if (q == "" && (c == SQ || c == "\"")) { q = c; continue }
        if (q == "\"" && c == "\"") { q = ""; continue }
        buf = buf (q == "" ? c : enc(c))
    }
    while (sd > 0) pop()
    printf "%s%s", buf, extra
}
