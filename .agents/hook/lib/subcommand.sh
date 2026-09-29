#!/usr/bin/env bash
# .agents/hook/lib/subcommand.sh - split a Bash command line into the
# sub-commands it actually launches, for the PreToolUse Bash hooks.
#
# A hook that pattern-matches the raw command text blocks commit messages,
# PR bodies and files being written just because they MENTION a trigger
# word. This lib reduces the text to launches, so a hook can judge each
# one by its first word:
#
#   hook_subcommands <command>   one sub-command per line on stdout:
#     1. heredoc bodies are dropped (a here-string `<<<` is not a heredoc)
#     2. each quoted span ('...' and "...", across lines too) becomes ONE
#        opaque word: the quotes go, and inside the span whitespace and the
#        separators ; & | < > ( ) become '_'. So a quoted message splits
#        nothing, while a quoted executable ("bats", b"at"s) is still seen
#        by its real name. A backslash-escaped character outside quotes is
#        taken literally the same way.
#     3. the rest is split on ; && || | and newlines
#     4. leading VAR=val assignments and sudo / env / command / time /
#        nohup / exec wrappers are stripped together with their options
#        (sudo -u root, env -i -u X, exec -a n, --user=x, --); `command -v`
#        / `-V` only looks a name up, so it is kept as is. timeout(1) is
#        kept, since the long-job hook treats it as a bound
#     5. pieces are trimmed and their words single-spaced; empty ones are
#        dropped
#
# Deliberately simple (no full shell parser): $(...) inside double quotes
# and $'...' escapes are not expanded; the calling hooks accept that.
#
# Library: sourced, sets no shell options, only declares functions.

# Library guard: refuse to run as an executable script.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf 'Warn: %s is a library, not an executable script.\n' "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# _hook_strip_heredocs <command> - the command minus every heredoc body. A
# line opening a heredoc (`<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`, not
# `<<<`) is kept; the lines up to the terminator line WORD (leading blanks
# allowed, for <<-) are dropped.
_hook_strip_heredocs() {
    local _line _term='' _trim
    local _re="(^|[^<])<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ -n "${_term}" ]]; then
            _trim="${_line#"${_line%%[![:space:]]*}"}"
            [[ "${_trim}" == "${_term}" ]] && _term=''
            continue
        fi
        printf '%s\n' "${_line}"
        if [[ "${_line}" =~ ${_re} ]]; then
            _term="${BASH_REMATCH[2]}"
        fi
    done <<<"$1"
}

# _hook_unquote - read a command on stdin and print it with every quoted
# span turned into one opaque word (see the header, step 2). The whole
# input is one awk record, so a span may cross lines; index() instead of a
# bracket class keeps it portable to mawk.
_hook_unquote() {
    awk 'BEGIN { RS = "\001"; SEP = " \t\r\n;&|<>()"; SQ = sprintf("%c", 39) }
    {
        n = length($0); q = ""
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (q == "" && (c == SQ || c == "\"")) { q = c; continue }
            if (q != "" && c == q) { q = ""; continue }
            if (c == "\\" && q != SQ && i < n) {
                i++; c = substr($0, i, 1)
                if (c == "\n" && q == "") continue
                if (index(SEP, c) > 0) c = "_"
            } else if (q != "" && index(SEP, c) > 0) {
                c = "_"
            }
            printf "%s", c
        }
    }'
}

# Long wrapper options that take their value as the NEXT word.
_HOOK_LONG_VALUE_OPTS=' --user --group --host --prompt --chdir --close-from --role --type --other-user --command-timeout --unset --split-string '

# _hook_after_opts <index> <value-letters> <word...> - the index of the
# first word after the options of the wrapper at <index>. A short option
# whose letter is in <value-letters> takes the next word as its value when
# it ends the cluster (-u root), else the rest of the cluster (-uroot).
_hook_after_opts() {
    local _j=$(($1 + 1)) _set="$2" _o _k
    shift 2
    local -a _w=("$@")
    while [[ "${_w[_j]:-}" == -* ]]; do
        _o="${_w[_j]}"
        _j=$((_j + 1))
        [[ "${_o}" == -- ]] && break
        if [[ "${_o}" == --* ]]; then
            [[ "${_o}" != *=* && "${_HOOK_LONG_VALUE_OPTS}" == *" ${_o} "* ]] && _j=$((_j + 1))
            continue
        fi
        for ((_k = 1; _k < ${#_o}; _k++)); do
            [[ -n "${_set}" && "${_set}" == *"${_o:_k:1}"* ]] || continue
            [[ "${_k}" -eq $((${#_o} - 1)) ]] && _j=$((_j + 1))
            break
        done
    done
    printf '%s' "${_j}"
}

# _hook_strip_wrappers <sub-command> - drop leading assignments and the
# pass-through wrappers (with their options) until nothing more changes;
# print the remaining words single-spaced.
_hook_strip_wrappers() {
    local -a _w
    local _i=0 _prev=-1
    read -r -a _w <<<"$1"
    while [[ "${_i}" -lt "${#_w[@]}" && "${_i}" -ne "${_prev}" ]]; do
        _prev="${_i}"
        case "${_w[_i]}" in
            sudo) _i="$(_hook_after_opts "${_i}" ughpCDrtTRU "${_w[@]}")" ;;
            env) _i="$(_hook_after_opts "${_i}" uCS "${_w[@]}")" ;;
            exec) _i="$(_hook_after_opts "${_i}" a "${_w[@]}")" ;;
            time) _i="$(_hook_after_opts "${_i}" '' "${_w[@]}")" ;;
            nohup) _i=$((_i + 1)) ;;
            command)
                # command -v / -V looks a name up; it launches nothing.
                [[ "${_w[_i + 1]:-}" == -[vV]* ]] \
                    || _i="$(_hook_after_opts "${_i}" '' "${_w[@]}")" ;;
            *)
                [[ "${_w[_i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && _i=$((_i + 1)) ;;
        esac
    done
    printf '%s' "${_w[*]:_i}"
}

# hook_subcommands <command> - see the header.
hook_subcommands() {
    local _text _sub
    _text="$(_hook_strip_heredocs "$1" | _hook_unquote)"
    _text="${_text//&&/$'\n'}"
    _text="${_text//||/$'\n'}"
    _text="${_text//;/$'\n'}"
    _text="${_text//|/$'\n'}"
    while IFS= read -r _sub; do
        _sub="$(_hook_strip_wrappers "${_sub}")"
        [[ -n "${_sub}" ]] && printf '%s\n' "${_sub}"
    done <<<"${_text}"
    return 0
}
