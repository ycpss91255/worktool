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
#     there by a marker shown as "_": \001u for an unquoted $(...) or
#     `...` (the shell word-splits its output, so it may become several
#     words, options included), else \001s (inside double quotes, or a
#     <(...) / >(...), which is one path). Inside single quotes none of
#     these is special; $(...) and `...` inside double quotes still run
#   - every other expansion the shell resolves is marked \001v right before
#     its text (kept as is): a $ parameter expansion ($X, ${X}, $1, $'..',
#     outside single quotes; a lone $ is literal) and, unquoted, a glob
#     (* ?, [ with a closing ] in the same word) or a brace expansion ({ with
#     a , or .. and a closing } in the same word)
#   - a \002 (an expansion of an outer shell, carried into a bash -c /
#     eval script by subcommand.sh) becomes \001v in any quoting
BEGIN {
    RS = "\001"; SEP = " \t\r\n;&|<>()"; LET = "abcdefghijk"
    ESC = sprintf("%c", 1); SQ = sprintf("%c", 39); BQ = sprintf("%c", 96)
}
function enc(c,    k) { k = index(SEP, c); return k ? ESC substr(LET, k, 1) : c }
# closes(i, c) - 1 when the unquoted word going on at i holds the
# character c; with brace, only after a , or .. (a brace expansion).
function closes(i, c, brace,    j, d, sep) {
    sep = 0
    for (j = i + 1; j <= n; j++) {
        d = substr($0, j, 1)
        if (index(SEP, d) || d == SQ || d == "\"") return 0
        if (d == "," || (d == "." && substr($0, j + 1, 1) == ".")) sep = 1
        if (d == c) return brace ? sep : 1
    }
    return 0
}
function push(kind) {
    sd++; skind[sd] = kind; sq[sd] = q; sbuf[sd] = buf; spar[sd] = par
    q = ""; buf = ""; par = 0
}
function pop() {
    extra = extra "\n" buf
    q = sq[sd]; par = spar[sd]
    buf = sbuf[sd] ESC ((q == "" && skind[sd] != "<") ? "u" : "s"); sd--
}
{
    n = length($0); q = ""; buf = ""; extra = ""; sd = 0; par = 0
    for (i = 1; i <= n; i++) {
        c = substr($0, i, 1); nx = substr($0, i + 1, 1)
        if (c == "\002") { buf = buf ESC "v"; continue }
        if (q == SQ) { if (c == SQ) q = ""; else buf = buf enc(c); continue }
        if (c == "\\" && i < n) {
            i++; c = substr($0, i, 1)
            if (!(c == "\n" && q == "")) buf = buf enc(c)
            continue
        }
        if (c == "$" && nx == "(") { i++; push("("); continue }
        if (q == "" && (c == "<" || c == ">") && nx == "(") { i++; push("<"); continue }
        if (c == BQ) {
            if (sd > 0 && skind[sd] == BQ && q == "") pop(); else push(BQ)
            continue
        }
        if (q == "" && c == ")" && par == 0 && sd > 0 && skind[sd] != BQ) { pop(); continue }
        if (c == "$" && nx != "" && index(" \t\r\n", nx) == 0 && !(q == "\"" && nx == "\"")) buf = buf ESC "v"
        if (q == "" && (c == "*" || c == "?" || (c == "[" && closes(i, "]", 0)) || (c == "{" && closes(i, "}", 1)))) buf = buf ESC "v"
        if (q == "" && c == "(") par++
        if (q == "" && c == ")" && par > 0) par--
        if (q == "" && (c == SQ || c == "\"")) { q = c; continue }
        if (q == "\"" && c == "\"") { q = ""; continue }
        buf = buf (q == "" ? c : enc(c))
    }
    while (sd > 0) pop()
    printf "%s%s", buf, extra
}
