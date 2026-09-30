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
#   hook_is_interpreter <word>   0 when <word> (a path allowed) names a
#     non-shell interpreter that runs inline code (python, perl, ruby, node,
#     php, awk, lua ...); a heredoc fed to one becomes a here-string word of
#     its launch, so a hook can read the program text
#   hook_api_endpoint_urls <text>   one line per URL-like token of <text>
#     that names a GitHub API merge / comments / reviews / graphql endpoint
#     (whatever the method: the caller decides read or write), printed
#     normalised (<host><path>). Every token is normalised the same way
#     before matching: scheme optional (http, https, none, //), host
#     lower-cased with userinfo (user[:pw]@), :port and trailing dots
#     dropped; path lower-cased and percent-decoded, query / fragment
#     dropped, empty, . and .. segments resolved. Rules: host
#     api.github.com with /repos/<o>/<r>/pulls/<n>/merge, /repos/<o>/<r>/
#     (issues|pulls)/[<n>/]comments[/<id>], pulls/<n>/comments/<id>/replies,
#     pulls/<n>/reviews[/<id>[/events|dismissals|comments]] or /graphql;
#     any host with the
#     GHES prefix /api/v3/ of the same repos paths, or /api/graphql
#   hook_http_data_flags <tool>   THE table of data flags, one
#     "<flag> <arity> [<kind>]" per line: arity 1 takes a value (accepted in
#     every spelling: separate `-d V`, `--data=V`, short attached `-dV`), 0
#     is a boolean data flag, "item" is an httpie request-item separator.
#     gh-api lines add the kind (raw / typed field, input). Tools: curl,
#     wget, http (httpie), gh-api. Every reader derives from it: this lib,
#     the milestone-gate hook's gh api check and the spec's matrices
#   hook_http_is_write <tool> <word>...   0 when a curl / wget / httpie
#     call (its words after the tool) is a write by the read / write rule of
#     doc/structure.md (milestone-gate section), 1 when it reads. Sets
#     HOOK_HTTP_BODY to the literal body text ('@' for a body read from a
#     file or stdin: undeterminable)
#   hook_timeout_lead <sub-command>   the leading `timeout|gtimeout
#     [options] <duration> ` of a sub-command (valued options such as
#     -k 5 / --signal TERM included), or nothing when it has none
#   hook_scripts <command>   the command line itself, then every command
#     line it runs (header step 7: bash -c, a script heredoc / here-string,
#     eval; recursively, behind any wrapper or timeout(1)), each ended by a
#     NUL byte and printed as its shell reads it, heredocs kept, so a hook
#     can read the stdin a nested launch is fed. A substitution shows as '_'
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

# _hook_norm_path <path> - a URL path lower-cased, percent-decoded, with
# empty, . and .. segments resolved: /seg/seg (or empty).
_hook_norm_path() {
    local _p="$1" _seg _out=''
    local -a _segs _keep=()
    _p="$(printf '%b' "${_p//%/\\x}")"
    _p="${_p,,}"
    IFS=/ read -r -a _segs <<<"${_p}"
    for _seg in "${_segs[@]}"; do
        case "${_seg}" in
            ''|.) ;;
            ..) [[ "${#_keep[@]}" -gt 0 ]] && unset '_keep[-1]' ;;
            *) _keep+=("${_seg}") ;;
        esac
    done
    for _seg in "${_keep[@]}"; do _out+="/${_seg}"; done
    printf '%s' "${_out}"
}

# hook_api_endpoint_urls <text> - see the header.
hook_api_endpoint_urls() {
    local _tok _h _p _sch _u
    local _rest='repos/[^/]+/[^/]+/(pulls/[0-9]+/merge|(issues|pulls)/([0-9]+/)?comments(/[0-9]+)?|pulls/[0-9]+/comments/[0-9]+/replies|pulls/[0-9]+/reviews(/[0-9]+(/(events|dismissals|comments))?)?)'
    while IFS= read -r _tok; do
        _tok="${_tok,,}"
        [[ "${_tok}" == *api* && "${_tok}" == */* ]] || continue
        _sch=''
        if [[ "${_tok}" =~ ^[a-z][a-z0-9+.-]*:// ]]; then
            _sch=1
            _tok="${_tok#*://}"
        elif [[ "${_tok}" == //* ]]; then
            _sch=1
            _tok="${_tok#//}"
        fi
        _h="${_tok%%[/?#]*}"
        _p="${_tok:${#_h}}"
        _p="${_p%%[?#]*}"
        _h="${_h##*@}"
        [[ "${_h}" =~ ^(.*):[0-9]*$ ]] && _h="${BASH_REMATCH[1]}"
        while [[ "${_h}" == *. ]]; do _h="${_h%.}"; done
        [[ -n "${_h}" && (-n "${_sch}" || "${_h}" == *.*) ]] || continue
        _u="${_h}$(_hook_norm_path "${_p}")"
        if [[ "${_u}" =~ ^api\.github\.com/(${_rest}|graphql)$ || "${_u}" =~ ^[^/]+/api/(v3/${_rest}|graphql)$ ]]; then
            printf '%s\n' "${_u}"
        fi
    done < <(tr -s ' \t\n"'"'"'`<>(){}|;,\\=' '\n' <<<"$1")
    return 0
}

# hook_http_data_flags <tool> - see the header. THE single table of data
# flags: the classifier below, the gh api check of the milestone-gate hook
# and the spec's matrix generator all read it.
hook_http_data_flags() {
    case "$1" in
        curl) printf '%s\n' "-d 1" "--data 1" "--data-raw 1" "--data-binary 1" "--data-urlencode 1" \
            "--data-ascii 1" "--json 1" "-F 1" "--form 1" "--form-string 1" "-T 1" "--upload-file 1" ;;
        wget) printf '%s\n' "--post-data 1" "--post-file 1" "--body-data 1" "--body-file 1" ;;
        http|https|httpie|xh|xhs)
            printf '%s\n' "--raw 1" "--form 0" "-f 0" "--multipart 0" \
                "= item" ":= item" "@ item" "=@ item" ":=@ item" ;;
        gh-api) printf '%s\n' "-f 1 raw" "-F 1 typed" "--field 1 typed" "--raw-field 1 raw" "--input 1 input" ;;
    esac
}

# _hook_data_flag <tool> <word> <next word> - when <word> is a data flag of
# <tool> in any spelling (separate `-d V`, `--data=V`, attached `-dV`), print
# its value and 0; 2 when the value is the next word (separate); 1 when
# <word> is no data flag. A boolean data flag prints nothing and returns 0.
_hook_data_flag() {
    local _f _a _k
    while read -r _f _a _k; do
        [[ "${_a}" == item ]] && continue
        if [[ "$2" == "${_f}" ]]; then
            [[ "${_a}" == 1 ]] && { printf '%s' "$3"; return 2; }
            return 0
        fi
        [[ "${_a}" == 1 ]] || continue
        if [[ "$2" == "${_f}="* ]]; then
            printf '%s' "${2#*=}"
            return 0
        fi
        if [[ "${_f}" == -? && "$2" == "${_f}"?* ]]; then
            printf '%s' "${2:2}"
            return 0
        fi
    done < <(hook_http_data_flags "$1")
    return 1
}

# _hook_http_item <tool> <word> - 0 when <word> is a request item with data
# (a separator of the table: = := @ =@ :=@; not a == query or a : header).
_hook_http_item() {
    local _f _a _k _w="${2//==/}"
    while read -r _f _a _k; do
        [[ "${_a}" == item && "${_w}" == *"${_f}"* ]] && return 0
    done < <(hook_http_data_flags "$1")
    return 1
}

# hook_http_is_write <tool> <word>... - see the header.
HOOK_HTTP_BODY=''
hook_http_is_write() {
    local _tool="$1" _w _m='' _data='' _i _pos=0 _v _rc _short=''
    shift
    local -a _a=("$@")
    HOOK_HTTP_BODY=''
    # curl short data flags, for a cluster that hides one (-sd x).
    _short="$(hook_http_data_flags "${_tool}" | awk '$1 ~ /^-[A-Za-z]$/ && $2 == "1" { printf "%s", substr($1, 2) }')"
    for ((_i = 0; _i < ${#_a[@]}; _i++)); do
        _w="${_a[_i]}"
        _v="$(_hook_data_flag "${_tool}" "${_w}" "${_a[_i + 1]:-}")"
        _rc=$?
        if [[ "${_rc}" -ne 1 ]]; then
            _data=1
            [[ "${_rc}" -eq 2 ]] && _i=$((_i + 1))
            # A body from a file or stdin cannot be read here.
            [[ "${_w}" =~ (file|^-T|upload|^--input) ]] && _v='@'
            HOOK_HTTP_BODY+="${_v}"$'\n'
            continue
        fi
        case "${_tool}" in
            curl)
                case "${_w}" in
                    -X|--request) _i=$((_i + 1)); _m="${_a[_i]:-}" ;;
                    --request=*) _m="${_w#*=}" ;;
                    -X?*) _m="${_w:2}" ;;
                    --*) ;;
                    # A cluster hiding -X or a data flag cannot be read (fail closed).
                    -*)
                        if [[ "${_w:1}" == *[X${_short}]* ]]; then
                            HOOK_HTTP_BODY='@'
                            return 0
                        fi ;;
                esac ;;
            wget)
                case "${_w}" in
                    --method) _i=$((_i + 1)); _m="${_a[_i]:-}" ;;
                    --method=*) _m="${_w#*=}" ;;
                esac ;;
            *)
                # httpie: http [METHOD] URL [ITEMS]
                case "${_w}" in
                    -*) ;;
                    *)
                        _pos=$((_pos + 1))
                        if [[ "${_pos}" -eq 1 && "${_w^^}" =~ ^(GET|HEAD|OPTIONS|POST|PUT|PATCH|DELETE)$ ]]; then
                            _m="${_w}"
                            _pos=0
                        elif [[ "${_pos}" -ge 2 ]] && _hook_http_item "${_tool}" "${_w}"; then
                            _data=1
                            HOOK_HTTP_BODY+="${_w}"$'\n'
                        fi ;;
                esac ;;
        esac
    done
    # Any data flag is a write, whatever the method (-G / -X GET included);
    # a read is no data AND an implicit, GET or HEAD method.
    [[ -n "${_data}" ]] && return 0
    [[ -z "${_m}" || "${_m^^}" =~ ^(GET|HEAD)$ ]] && return 1
    return 0
}

# hook_is_interpreter <word> - see the header.
hook_is_interpreter() {
    [[ "${1##*/}" =~ ^(python[0-9.]*|pypy[0-9.]*|perl[0-9.]*|ruby[0-9.]*|node|nodejs|deno|bun|php[0-9.]*|[gmn]?awk|lua[0-9.]*|luajit|Rscript|tclsh[0-9.]*|osascript)$ ]]
}

# _hook_heredoc_to_shell <text before the heredoc operator> - 0 when the
# heredoc it opens is the script of a shell interpreter (header step 1),
# the stdin of a non-shell interpreter (hook_is_interpreter) or of gh (a
# --body-file - body), which a hook may need to read.
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
    _hook_shell_reads_stdin "${_w[@]}" && return 0
    [[ "${_w[0]:-}" == busybox || "${_w[0]:-}" == */busybox ]] && _w=("${_w[@]:1}")
    # gh reads a heredoc as a body (--body-file -): keep it readable too.
    [[ "${_w[0]:-}" == gh || "${_w[0]:-}" == */gh ]] && return 0
    hook_is_interpreter "${_w[0]:-}"
}

# _hook_herestring <body> <quoted> - the heredoc body as a single-quoted
# here-string word (`<<<'...'`). Unquoted delimiter (<quoted> empty): the
# outer shell expands the body, so each unescaped $ and ` gets the
# expansion escape \001v before it (kept by the quoting pass in any
# quoting; no raw marker byte), and the escapes \$ \` \\ are resolved the
# way the outer shell resolves them.
_hook_herestring() {
    local _b="$1" _o='' _i _c _n _sq="'\\''"
    if [[ -z "$2" ]]; then
        _n="${#_b}"
        for ((_i = 0; _i < _n; _i++)); do
            _c="${_b:_i:1}"
            if [[ "${_c}" == "\\" && "${_b:_i+1:1}" == [\\\$\`] ]]; then
                _i=$((_i + 1))
                _o+="${_b:_i:1}"
            elif [[ "${_c}" == '$' || "${_c}" == '`' ]]; then
                _o+=$'\001'"v${_c}"
            else
                _o+="${_c}"
            fi
        done
        _b="${_o}"
    fi
    printf "<<<'%s'" "${_b//\'/${_sq}}"
}

# _hook_held_line - print the held heredoc line with its operator replaced
# by the here-string of the body (split, not ${x/p/r}: a body holding & must
# not trip patsub_replacement). Reads _held / _op / _body / _quoted of
# _hook_strip_heredocs.
_hook_held_line() {
    printf '%s %s%s\n' "${_held%%"${_op}"*}" "$(_hook_herestring "${_body}" "${_quoted}")" "${_held#*"${_op}"}"
}

# _hook_heredoc_ops <line> - fill the arrays _HOOK_OP_ST / _LEN / _DASH /
# _Q / _W with one entry per heredoc operator of the line (`<<` / `<<-`,
# not `<<<`, not inside quotes or an arithmetic `((`): its start, length,
# dash, quoted flag and delimiter. Out of band (arrays, no separator byte),
# so no input byte can split a record. The delimiter is any shell word
# (END-X, "a.b", 'x y', \EOF, E"O"F): quotes and backslashes go, and any of
# them makes the body literal (quoted).
_HOOK_OP_ST=()
_HOOK_OP_LEN=()
_HOOK_OP_DASH=()
_HOOK_OP_Q=()
_HOOK_OP_W=()
_hook_heredoc_ops() {
    local _l="$1" _i=0 _n=${#1} _q='' _c _st _d _w _qq _pre
    _HOOK_OP_ST=()
    _HOOK_OP_LEN=()
    _HOOK_OP_DASH=()
    _HOOK_OP_Q=()
    _HOOK_OP_W=()
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
                _HOOK_OP_ST+=("${_st}")
                _HOOK_OP_LEN+=("$((_i - _st))")
                _HOOK_OP_DASH+=("${_d}")
                _HOOK_OP_Q+=("${_qq}")
                _HOOK_OP_W+=("${_w}")
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
    local _line _t _held='' _op='' _quoted='' _body=''
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
        _hook_heredoc_ops "${_line}"
        if [[ "${#_HOOK_OP_W[@]}" -gt 0 ]]; then
            _terms+=("${_HOOK_OP_W[@]}")
            _dashes+=("${_HOOK_OP_DASH[@]}")
            if [[ "${#_HOOK_OP_W[@]}" -eq 1 ]] \
                && _hook_heredoc_to_shell "${_line:0:_HOOK_OP_ST[0]}"; then
                _held="${_line}"
                _op="${_line:_HOOK_OP_ST[0]:_HOOK_OP_LEN[0]}"
                _quoted="${_HOOK_OP_Q[0]}"
                _body=''
                continue
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

# _hook_decode_sep <word> - the word with its separator escapes (\001a-k)
# restored; every other escape is kept.
_hook_decode_sep() {
    local _s="$1" _i _seps=$' \t\r\n;&|<>()' _let=abcdefghijk
    for ((_i = 0; _i < ${#_seps}; _i++)); do
        _s="${_s//$'\001'"${_let:_i:1}"/"${_seps:_i:1}"}"
    done
    printf '%s' "${_s}"
}

# _hook_decode <word> - an opaque word as text: separators restored, each
# expansion escape (\001v) dropped, each substitution (\001s quoted, \001u
# unquoted) shown as '_', and the literal-\001 escape (\001z) turned back
# into \001 last, so no decoded byte is read as an escape again.
_hook_decode() {
    local _s
    _s="$(_hook_decode_sep "$1")"
    _s="${_s//$'\001'v/}"
    _s="${_s//$'\001'[su]/_}"
    printf '%s' "${_s//$'\001'z/$'\001'}"
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
        # carry it in as the escape \001v (a substitution as \001v_), which
        # the quoting pass keeps; the literal-\001 escape \001z stays too.
        _script="${_script//$'\001'[su]/$'\001'v_}"
        while IFS= read -r _line; do
            printf '%s%s\n' "${_lead}" "${_line}"
        done < <(_hook_subcommands_enc "$(_hook_decode_sep "${_script}")")
        return 0
    fi
    if [[ -n "${_HOOK_RAW:-}" ]]; then
        printf '%s\n' "$1"
    else
        _t="${1//$'\001'v/}"
        _t="${_t//$'\001'[a-u]/_}"
        printf '%s\n' "${_t//$'\001'z/$'\001'}"
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

# hook_subcommands <command> - see the header. Every \001 of the input is
# first escaped as \001z, so no input byte can pose as a marker.
hook_subcommands() {
    _hook_subcommands_enc "${1//$'\001'/$'\001'z}"
}

# _hook_subcommands_enc <escaped command> - hook_subcommands on a command
# whose \001 bytes are already escapes (\001z literal, \001v expansion).
_hook_subcommands_enc() {
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

# hook_scripts <command> - see the header. Every \001 of the input is
# escaped first (as hook_subcommands does); _hook_decode restores it.
hook_scripts() {
    local _sub _lead _script _text
    printf '%s\0' "$1"
    _text="$(_hook_split "$(_hook_strip_heredocs "${1//$'\001'/$'\001'z}" | _hook_unquote)")"
    while IFS= read -r _sub; do
        _sub="$(_hook_strip_wrappers "${_sub}")"
        _lead="$(hook_timeout_lead "${_sub}")"
        _script="$(_hook_inner_script "$(_hook_strip_wrappers "${_sub#"${_lead}"}")")" || continue
        hook_scripts "$(_hook_decode "${_script}")"
    done <<<"${_text}"
    return 0
}
