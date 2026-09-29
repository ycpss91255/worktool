#!/usr/bin/env bash
# .agents/hook/lib/subcommand.sh - split a Bash command line into the
# sub-commands it launches, for the PreToolUse Bash hooks.
#
# A hook that pattern-matches the raw command text blocks commit messages,
# PR bodies and files being written just because they MENTION a trigger
# word. This lib reduces the text to launches, so a hook can judge each
# one by its first word:
#
#   hook_subcommands <command>   one sub-command per line on stdout:
#     1. heredoc bodies are dropped (a here-string `<<<` is not a heredoc),
#        except the body of a heredoc a shell interpreter reads as its
#        script (`sh <<EOF`, `env bash -s <<'EOF'`; bash sh dash zsh ksh
#        fish, no -c, no script file): that heredoc becomes a here-string
#        of its body, which step 7 runs. With an unquoted delimiter the
#        outer shell expands the body first, so each $ and ` in it stays
#        marked as an expansion (hook_word_has_expansion); a quoted
#        delimiter ('EOF', "EOF", \EOF) keeps it literal
#     2. each quoted span ('...' and "...", across lines too) becomes ONE
#        opaque word: the quotes go, and inside the span whitespace and the
#        separators ; & | < > ( ) become '_'. So a quoted message splits
#        nothing, while a quoted executable ("bats", b"at"s) is still seen
#        by its real name. A backslash-escaped character outside quotes is
#        taken literally the same way (lib/unquote.awk)
#     3. the body of every $(...), `...` and <(...) / >(...) is launched
#        too, so it becomes its own sub-command(s) after the command that
#        holds it, where it is replaced by the word '_'. $(...) and `...`
#        run inside double quotes as well; inside single quotes nothing is
#        special
#     4. an array assignment's list (`a=(x y)`) is data and becomes '_'
#     5. the rest is split on ; && || | and newlines, on a background & (not
#        the & of a redirection: 2>&1, &>f), and on ( and ), so the body of
#        a subshell ( ... ) is launched like any other command
#     6. leading VAR=val assignments, the reserved words that open or close
#        a compound command (if then elif else fi while until do done
#        esac ! { }), and sudo / env / command / time / nohup / exec
#        wrappers are stripped, the wrappers together with their options
#        (sudo -u root, env -i -u X, exec -a n, --user=x, --); `command -v`
#        / `-V` only looks a name up, so it is kept as is. timeout(1) is
#        kept, since the long-job hook treats it as a bound. So the body and
#        the condition of if / while / until / for / case / { ...; } are
#        judged as launches; a `for x in ...` or `case x in` header is kept
#        as is and launches nothing
#     7. `bash|sh|dash|zsh|ksh|fish [opts] -c <script>`, the same shells
#        reading a here-string as their script (`bash <<< '<script>'`,
#        `sh -s <<<...`, no script file) and `eval <words>` run a
#        command line: it is split by these same rules in place of the
#        wrapper. A timeout(1) leading the wrapper leads each of them, since
#        it bounds the whole script
#     8. pieces are trimmed and their words single-spaced; empty ones are
#        dropped
#
#   hook_subcommands_raw <command>   the same sub-commands, but each opaque
#     word stays encoded (no whitespace inside it), so a hook can split one
#     launch into words and read a word's own text with hook_word
#   hook_word <encoded word>         the word's text, separators restored; a
#     command substitution in it shows as '_'
#   hook_word_has_subst <encoded word>   0 when the word holds a $(...) /
#     `...` / <(...) substitution
#   hook_word_has_expansion <encoded word>   0 when the word holds any
#     expansion the shell resolves before running the command: a command
#     substitution (above), a $ parameter expansion ($X, "${X}", $1,
#     $'..'), an unquoted glob (* ? [..]) or brace expansion ({a,b} {1..3}).
#     Quoted or escaped text ('$X', \$X, "*") and a lone $ are literal.
#     An expansion of the outer shell stays marked inside the bash -c /
#     eval script it builds (bash -c "gh ... '$B'")
#   hook_word_has_bare_subst <encoded word>   0 when the word holds an
#     UNQUOTED $(...) / `...`: the shell word-splits its output, so the one
#     word seen here may launch as several (options included)
#   hook_timeout_lead <sub-command>   the leading `timeout|gtimeout
#     [options] <duration> ` of a sub-command (valued options such as
#     -k 5 / --signal TERM included), or nothing when it has none
#
# Deliberately simple (no full shell parser): $'...' escapes are not
# expanded, a `#` comment is not recognised, and a script FILE run by name
# (`bash x.sh`, `python x.py`, `just ...`) or a function body run later is
# not read.
#
# Library: sourced, sets no shell options, only declares functions.

# Library guard: refuse to run as an executable script.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf 'Warn: %s is a library, not an executable script.\n' "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# _hook_is_shell <word> - 0 when <word> names a shell interpreter.
_hook_is_shell() {
    case "$1" in
        bash|sh|dash|zsh|ksh|fish|*/bash|*/sh|*/dash|*/zsh|*/ksh|*/fish) return 0 ;;
    esac
    return 1
}

# _hook_shell_reads_stdin <word>... - 0 when the words (wrappers already
# stripped) run a shell interpreter (also as `busybox <shell>`) whose
# script is its stdin: options only (no -c; fish's valued options such as
# -C <cmd> included), redirections, or arguments after -s; no script file.
_hook_shell_reads_stdin() {
    local _s='' _fish=''
    [[ "${1:-}" == busybox || "${1:-}" == */busybox ]] && shift
    _hook_is_shell "${1:-}" || return 1
    [[ "${1##*/}" == fish ]] && _fish=1
    shift
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -[oO]|+[oO]|--rcfile|--init-file) shift ;;
            -C|--init-command|-d|--debug|-f|--features|-p|--profile|--profile-startup)
                # fish options that take the next word as their value.
                [[ -n "${_fish}" ]] && shift ;;
            --*) ;;
            [-+]*c*) [[ "$1" =~ ^[-+][A-Za-z]*c ]] && return 1 ;;
            -*s*) _s=1 ;;
            -*|+*) ;;
            [0-9]*[\<\>]*|[\<\>]*) ;;
            *) [[ -n "${_s}" ]] || return 1 ;;
        esac
        shift
    done
    return 0
}

# _hook_heredoc_to_shell <text before the heredoc operator> - 0 when the
# heredoc it opens is the script of a shell interpreter (header step 1).
_hook_heredoc_to_shell() {
    local _seg="$1" _re='[0-9]*[<>]&[0-9-]*' _lead
    local -a _w
    while [[ "${_seg}" =~ ${_re} ]]; do
        _seg="${_seg/"${BASH_REMATCH[0]}"/ }"
    done
    _seg="${_seg##*[;&|(]}"
    _seg="$(_hook_strip_wrappers "${_seg}")"
    _lead="$(hook_timeout_lead "${_seg} ")"
    _seg="${_seg#"${_lead}"}"
    read -r -a _w <<<"${_seg}"
    _hook_shell_reads_stdin "${_w[@]}"
}

# _hook_herestring <body> <quoted> - the heredoc body as a single-quoted
# here-string word (`<<<'...'`). Unquoted delimiter (<quoted> empty): the
# outer shell expands the body, so each unescaped $ and ` is prefixed with
# \002 (marked as an expansion by the quoting pass in any quoting) and the
# escapes \$ \` \\ are resolved the way the outer shell resolves them.
_hook_herestring() {
    local _b="$1" _q="'" _sq="'\\''"
    if [[ -z "$2" ]]; then
        _b="${_b//\\\\/$'\004'}"
        _b="${_b//\\\$/$'\003'}"
        _b="${_b//\\\`/$'\005'}"
        _b="${_b//\$/$'\002'\$}"
        _b="${_b//\`/$'\002'\`}"
        _b="${_b//$'\003'/\$}"
        _b="${_b//$'\005'/\`}"
        _b="${_b//$'\004'/\\}"
    fi
    printf '<<<%s%s%s' "${_q}" "${_b//\'/${_sq}}" "${_q}"
}

# _hook_held_line - print the held heredoc line with its operator replaced
# by the here-string of the body (split, not ${x/p/r}: a body holding & must
# not trip patsub_replacement). Reads _held / _op / _body / _quoted of
# _hook_strip_heredocs.
_hook_held_line() {
    printf '%s %s%s\n' "${_held%%"${_op}"*}" "$(_hook_herestring "${_body}" "${_quoted}")" "${_held#*"${_op}"}"
}

# _hook_heredoc_ops <line> - one record per heredoc operator of the line
# (`<<` / `<<-`, not `<<<`, not inside quotes or an arithmetic `((`):
# <start> US <length> US <dash> US <quoted> US <delimiter>, US = \037. The
# delimiter is any shell word (END-X, "a.b", 'x y', \EOF, E"O"F): quotes
# and backslashes go, and any of them makes the body literal (<quoted>).
_hook_heredoc_ops() {
    local _l="$1" _i=0 _n=${#1} _q='' _c _st _d _w _qq _pre _us=$'\037'
    while [[ "${_i}" -lt "${_n}" ]]; do
        _c="${_l:_i:1}"
        if [[ -n "${_q}" ]]; then
            if [[ "${_c}" == "${_q}" ]]; then
                _q=''
            elif [[ "${_q}" == '"' && "${_c}" == "\\" ]]; then
                _i=$((_i + 1))
            fi
            _i=$((_i + 1))
            continue
        fi
        case "${_c}" in
            "\\") _i=$((_i + 2)); continue ;;
            "'"|'"') _q="${_c}"; _i=$((_i + 1)); continue ;;
        esac
        if [[ "${_l:_i:3}" == '<<<' ]]; then
            _i=$((_i + 3))
            continue
        fi
        if [[ "${_l:_i:2}" == '<<' ]]; then
            _st="${_i}"
            _pre="${_l:0:_i}"
            _i=$((_i + 2))
            _d=''
            [[ "${_l:_i:1}" == - ]] && { _d=1; _i=$((_i + 1)); }
            while [[ "${_l:_i:1}" == [[:blank:]] ]]; do _i=$((_i + 1)); done
            _w=''
            _qq=''
            while [[ "${_i}" -lt "${_n}" ]]; do
                _c="${_l:_i:1}"
                case "${_c}" in
                    [[:space:]]|';'|'&'|'|'|'<'|'>'|'('|')') break ;;
                    "\\") _qq=1; _w+="${_l:_i+1:1}"; _i=$((_i + 2)) ;;
                    "'"|'"')
                        _qq=1
                        _i=$((_i + 1))
                        while [[ "${_i}" -lt "${_n}" && "${_l:_i:1}" != "${_c}" ]]; do
                            _w+="${_l:_i:1}"
                            _i=$((_i + 1))
                        done
                        _i=$((_i + 1)) ;;
                    *) _w+="${_c}"; _i=$((_i + 1)) ;;
                esac
            done
            # An arithmetic shift ($(( 1 << 2 ))) is no heredoc.
            local _open="${_pre//[^(]/}" _close="${_pre//[^)]/}"
            if [[ -n "${_w}" ]] && { [[ "${_pre}" != *'(('* ]] || [[ "${#_open}" -le "${#_close}" ]]; }; then
                printf '%s%s%s%s%s%s%s%s%s\n' "${_st}" "${_us}" "$((_i - _st))" "${_us}" "${_d}" "${_us}" "${_qq}" "${_us}" "${_w}"
            fi
            continue
        fi
        _i=$((_i + 1))
    done
    return 0
}

# _hook_strip_heredocs <command> - the command minus every heredoc body. A
# line opening heredocs (see _hook_heredoc_ops) is kept; the bodies that
# follow, each up to the line that is exactly its delimiter (leading tabs
# stripped for <<-), are dropped in order. A line with a single heredoc a
# shell reads as its script has it turned into a here-string of its body
# instead (header step 1).
_hook_strip_heredocs() {
    local _line _t _held='' _op='' _quoted='' _body='' _ops _s _len _d _qq _w _n
    local -a _terms=() _dashes=()
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ "${#_terms[@]}" -gt 0 ]]; then
            _t="${_line}"
            [[ -n "${_dashes[0]}" ]] && _t="${_t#"${_t%%[!$'\t']*}"}"
            if [[ "${_t}" == "${_terms[0]}" ]]; then
                _terms=("${_terms[@]:1}")
                _dashes=("${_dashes[@]:1}")
                if [[ -n "${_held}" && "${#_terms[@]}" -eq 0 ]]; then
                    _hook_held_line
                    _held=''
                fi
            elif [[ -n "${_held}" ]]; then
                _body+="${_t}"$'\n'
            fi
            continue
        fi
        _ops="$(_hook_heredoc_ops "${_line}")"
        if [[ -n "${_ops}" ]]; then
            _n=0
            while IFS=$'\037' read -r _s _len _d _qq _w; do
                _terms+=("${_w}")
                _dashes+=("${_d}")
                _n=$((_n + 1))
            done <<<"${_ops}"
            if [[ "${_n}" -eq 1 ]]; then
                IFS=$'\037' read -r _s _len _d _qq _w <<<"${_ops}"
                if _hook_heredoc_to_shell "${_line:0:_s}"; then
                    _held="${_line}"
                    _op="${_line:_s:_len}"
                    _quoted="${_qq}"
                    _body=''
                    continue
                fi
            fi
        fi
        printf '%s\n' "${_line}"
    done <<<"$1"
    # An unterminated heredoc still runs its body as the script.
    [[ -n "${_held}" ]] && _hook_held_line
    return 0
}

# The quoting pass (header steps 2 and 3), next to this file.
_HOOK_UNQUOTE_AWK="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/unquote.awk"

# _hook_unquote - read a command on stdin and print it through the quoting
# pass: opaque words carry each separator as \001 plus a letter.
_hook_unquote() {
    awk -f "${_HOOK_UNQUOTE_AWK}"
}

# _hook_decode <word> - an opaque word with its separators restored, each
# expansion marker (\001v) dropped and each substitution marker (\001s
# quoted, \001u unquoted) shown as '_'.
_hook_decode() {
    local _s="$1" _i _seps=$' \t\r\n;&|<>()' _let=abcdefghijk
    for ((_i = 0; _i < ${#_seps}; _i++)); do
        _s="${_s//$'\001'"${_let:_i:1}"/"${_seps:_i:1}"}"
    done
    _s="${_s//$'\001'v/}"
    printf '%s' "${_s//$'\001'[su]/_}"
}

# hook_word <encoded word> - see the header.
hook_word() {
    _hook_decode "$1"
}

# hook_word_has_subst <encoded word> - see the header.
hook_word_has_subst() {
    [[ "$1" == *$'\001'[su]* ]]
}

# hook_word_has_expansion <encoded word> - see the header.
hook_word_has_expansion() {
    [[ "$1" == *$'\001'[suv]* ]]
}

# hook_word_has_bare_subst <encoded word> - see the header.
hook_word_has_bare_subst() {
    [[ "$1" == *$'\001'u* ]]
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
            nohup|'if'|'then'|'elif'|'else'|'fi'|'while'|'until'|'do'|'done'|'esac'|'!'|'{'|'}') _i=$((_i + 1)) ;;
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

# _hook_inner_script <words> - print the (still encoded) command line that
# `bash|sh|dash|zsh|ksh [opts] -c <script>` or `eval <words>` runs; fail
# when the words run no such command line.
_hook_inner_script() {
    local -a _w
    local _i
    read -r -a _w <<<"$1"
    if [[ "${_w[0]:-}" == busybox || "${_w[0]:-}" == */busybox ]] && _hook_is_shell "${_w[1]:-}"; then
        _w=("${_w[@]:1}")
    fi
    case "${_w[0]:-}" in
        eval)
            [[ "${#_w[@]}" -gt 1 ]] || return 1
            printf '%s' "${_w[*]:1}"
            return 0 ;;
        *) _hook_is_shell "${_w[0]:-}" || return 1 ;;
    esac
    # A here-string the shell reads as its script (no -c, no script file).
    for ((_i = 1; _i < ${#_w[@]}; _i++)); do
        [[ "${_w[_i]}" == '<<<'* ]] || continue
        _hook_shell_reads_stdin "${_w[@]:0:_i}" || break
        if [[ "${_w[_i]}" == '<<<' ]]; then
            printf '%s' "${_w[_i + 1]:-}"
        else
            printf '%s' "${_w[_i]#<<<}"
        fi
        return 0
    done
    for ((_i = 1; _i < ${#_w[@]}; _i++)); do
        case "${_w[_i]}" in
            -[oO]|+[oO]|--rcfile|--init-file) _i=$((_i + 1)) ;;
            --*) ;;
            -*c*|+*c*)
                [[ "${_w[_i]}" =~ ^[-+][A-Za-z]*c[A-Za-z]*$ && -n "${_w[_i + 1]:-}" ]] || return 1
                printf '%s' "${_w[_i + 1]}"
                return 0 ;;
            -*|+*) ;;
            *) return 1 ;;
        esac
    done
    return 1
}

# timeout(1) options that take the NEXT word as their value.
_HOOK_TIMEOUT_VALUE_OPTS='-k|-s|--kill-after|--signal'

# hook_timeout_lead <sub-command> - see the header.
hook_timeout_lead() {
    local _o='[[:space:]]+(('"${_HOOK_TIMEOUT_VALUE_OPTS}"')[[:space:]]+[^[:space:]]+|-[^[:space:]]*)'
    local _re='^g?timeout('"${_o}"')*[[:space:]]+[^-[:space:]][^[:space:]]*[[:space:]]+'
    [[ "$1" =~ ${_re} ]] && printf '%s' "${BASH_REMATCH[0]}"
    return 0
}

# _hook_emit <sub-command> - print the sub-command with its opaque words
# shown as '_' (kept encoded under hook_subcommands_raw), or, when it runs a
# command line (header step 7), that command line's own sub-commands behind
# any leading timeout(1).
_hook_emit() {
    local _lead _script _line _t
    _lead="$(hook_timeout_lead "$1")"
    if _script="$(_hook_inner_script "$(_hook_strip_wrappers "${1#"${_lead}"}")")"; then
        # An expansion of this shell is unknown to the script it builds:
        # carry it in as \002, which the quoting pass marks again.
        _script="${_script//$'\001'v/$'\002'}"
        _script="${_script//$'\001'[su]/$'\002'_}"
        while IFS= read -r _line; do
            printf '%s%s\n' "${_lead}" "${_line}"
        done < <(hook_subcommands "$(_hook_decode "${_script}")")
        return 0
    fi
    if [[ -n "${_HOOK_RAW:-}" ]]; then
        printf '%s\n' "$1"
    else
        _t="${1//$'\001'v/}"
        printf '%s\n' "${_t//$'\001'?/_}"
    fi
}

# _hook_split <unquoted command> - the command with every separator of
# header steps 4 and 5 turned into a newline.
_hook_split() {
    local _t="$1" _re_arr='=\(([^()]*)\)' _re_bg='(^|[^<>])&([^>]|$)'
    while [[ "${_t}" =~ ${_re_arr} ]]; do
        _t="${_t/"${BASH_REMATCH[0]}"/=_}"
    done
    _t="${_t//&&/$'\n'}"
    _t="${_t//||/$'\n'}"
    _t="${_t//|/$'\n'}"
    while [[ "${_t}" =~ ${_re_bg} ]]; do
        _t="${_t/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}"$'\n'"${BASH_REMATCH[2]}"}"
    done
    _t="${_t//;/$'\n'}"
    _t="${_t//(/$'\n'}"
    printf '%s' "${_t//)/$'\n'}"
}

# hook_subcommands <command> - see the header.
hook_subcommands() {
    local _text _sub
    _text="$(_hook_split "$(_hook_strip_heredocs "$1" | _hook_unquote)")"
    while IFS= read -r _sub; do
        _sub="$(_hook_strip_wrappers "${_sub}")"
        [[ -n "${_sub}" ]] && _hook_emit "${_sub}"
    done <<<"${_text}"
    return 0
}

# hook_subcommands_raw <command> - see the header.
hook_subcommands_raw() {
    local _HOOK_RAW=1
    hook_subcommands "$1"
}
