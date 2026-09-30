#!/usr/bin/env bash
# .agents/hook/enforce_no_local_paths.sh - Claude Code PreToolUse hook
# (matcher: Bash), registered in .claude/settings.json (issue #233).
#
# The repo is public: a comment, PR or issue body an agent posts must not
# carry a machine-local absolute path (a home directory, a Claude
# scratchpad, /root/). This hook BLOCKS (exit 2, reason on stderr) a gh
# launch whose body holds one; the body is read wherever gh reads it:
#   - inline: --body / -b (every form: -b x, -bx, --body=x) and the
#     --comment / -c of gh pr|issue close / reopen
#   - a file: --body-file / -F of gh pr|issue, gh api -F body=@<file> and
#     gh api --input <file> (relative paths resolve against the payload's
#     cwd, or a `cd` earlier in the same command)
#   - gh api field values (-f / --raw-field / -F / --field)
#   - a heredoc redirected into such a gh launch
# The judged gh launches: gh pr|issue create / new / comment / edit /
# review / close / reopen, and every gh api call. The path patterns live
# only in LOCAL_PATH_ERE below; LOCAL_PATH_ALLOWED lists the generic
# example (/home/me/) that doc and test fixtures use on purpose.
#
# The closed rule of #190: a body the hook cannot read literally blocks -
# an inline body or a file path holding a shell expansion ($VAR, $(...),
# a backtick, a glob, a leading ~), a missing or unreadable file, a stdin
# body (-) not fed by a heredoc on that same gh launch (a pipe, or a heredoc
# of another command), and an unquoted heredoc to gh holding '$' or '`'.
# Every heredoc opened on a line whose gh launch takes one is judged; its
# delimiter is read as bash reads it (any word, quoted or not: <<'END-MARK',
# <<123, <<EOF.foo), and one left unterminated runs to the end.
#
# Only real launches count (lib/subcommand.sh): a path in a commit message,
# an echo, a cd or a redirection is not a gh body. Everything else passes
# silently.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-no-local-paths"

# A local path starts at a word boundary (so src/root/ or a URL path does
# not count) and is a home directory (Linux or macOS), a Claude
# scratchpad or /root/.
readonly LOCAL_PATH_ERE='(^|[^[:alnum:]_.~-])(/home/[^/[:space:]]+/|/Users/[^/[:space:]]+/|/tmp/claude-[0-9]+/|/root/)'
readonly LOCAL_PATH_ALLOWED=' /home/me/ '

# The launch under judgement: encoded words (_E) and the directory its
# relative files resolve against (_CWD). _STDIN is set when the launch
# reads a body from stdin; _REL when any relevant gh launch was seen.
_E=()
_CWD=''
_STDIN=0
_REL=0

# _local_paths <text> - print each distinct local path prefix in <text>,
# the allowed examples left out.
_local_paths() {
    local _p
    while IFS= read -r _p; do
        _p="/${_p#*/}"
        [[ "${LOCAL_PATH_ALLOWED}" == *" ${_p} "* ]] || printf '%s\n' "${_p}"
    done < <(grep -oE -- "${LOCAL_PATH_ERE}" <<<"$1" | sort -u)
}

# _judge <text> <source> - block when <text> holds a local path.
_judge() {
    local _found
    _found="$(_local_paths "$1")"
    [[ -z "${_found}" ]] && return 0
    hook_block "$2 holds a machine-local absolute path: ${_found//$'\n'/, }" \
        "The repo is public: rewrite it as a repo-relative path (lib/log.sh:12) or a placeholder such as <scratch>/ or <worktree>/ before posting." \
        "The generic example /home/me/ is allowed."
}

# _block_literal <what> - the closed rule.
_block_literal() {
    hook_block "$1 cannot be read literally (a shell expansion or stdin; fail closed)." \
        "Re-run gh with literal arguments: write the body to a file first, then pass --body-file <literal path>."
}

# _expands <encoded word> - 0 when the shell would expand the word.
_expands() {
    local _w
    hook_word_has_subst "$1" && return 0
    _w="$(hook_word "$1")"
    [[ "${_w}" == *'$'* || "${_w}" == *'`'* ]]
}

# _resolve <path> - <path> against the launch's directory.
_resolve() {
    if [[ "$1" == /* || -z "${_CWD}" ]]; then
        printf '%s' "$1"
    else
        printf '%s/%s' "${_CWD}" "$1"
    fi
}

# _judge_file <path> <source> - judge a body file's content; `-` is stdin.
_judge_file() {
    local _f="$1" _text
    if [[ "${_f}" == - ]]; then
        _STDIN=1
        return 0
    fi
    if [[ "${_f}" == *['$`*?[']* || "${_f}" == '~'* ]]; then
        _block_literal "$2 path '${_f}'"
    fi
    _f="$(_resolve "${_f}")"
    [[ -f "${_f}" && -r "${_f}" ]] \
        || hook_block "$2: cannot read the body file '$1' to check it (fail closed)." \
            "Write the body file in a separate step first, then pass it with a literal path."
    _text="$(cat -- "${_f}")"
    _judge "${_text}" "$2 file '$1'"
}

# _opt_values <name>... - every value of the given options in _E (from
# index 2 on), still encoded, NUL-terminated: -n x, -nx, -n=x, --name=x.
_opt_values() {
    local _i _n _w
    for ((_i = 2; _i < ${#_E[@]}; _i++)); do
        _w="${_E[_i]}"
        for _n in "$@"; do
            if [[ "${_w}" == "${_n}" ]]; then
                _i=$((_i + 1))
                printf '%s\0' "${_E[_i]:-}"
                break
            elif [[ "${_n}" == --* && "${_w}" == "${_n}="* ]]; then
                printf '%s\0' "${_w#*=}"
                break
            elif [[ "${_n}" == -? && "${_w}" == "${_n}"?* ]]; then
                _w="${_w#"${_n}"}"
                printf '%s\0' "${_w#=}"
                break
            fi
        done
    done
}

# _check_inline <source> <name>... - judge every inline value of the options.
_check_inline() {
    local _src="$1" _v
    shift
    while IFS= read -r -d '' _v; do
        _expands "${_v}" && _block_literal "${_src}"
        _judge "$(hook_word "${_v}")" "${_src}"
    done < <(_opt_values "$@")
    return 0
}

# _check_files <source> <name>... - judge every file the options name.
_check_files() {
    local _src="$1" _v
    shift
    while IFS= read -r -d '' _v; do
        hook_word_has_subst "${_v}" && _block_literal "${_src} path"
        _judge_file "$(hook_word "${_v}")" "${_src}"
    done < <(_opt_values "$@")
    return 0
}

# _check_api_fields - gh api -F / --field values: key=@file reads a file.
_check_api_fields() {
    local _v _w
    while IFS= read -r -d '' _v; do
        _expands "${_v}" && _block_literal "gh api field"
        _w="$(hook_word "${_v}")"
        if [[ "${_w}" == *=@* ]]; then
            _judge_file "${_w#*=@}" "gh api field"
        else
            _judge "${_w}" "gh api field"
        fi
    done < <(_opt_values -F --field)
    return 0
}

# _check_gh - judge the gh launch in _E (gh <group> <sub> ...).
_check_gh() {
    local _grp _sub
    _grp="$(hook_word "${_E[1]:-}")"
    _sub="$(hook_word "${_E[2]:-}")"
    if [[ "${_grp}" == api ]]; then
        _REL=1
        _check_inline "gh api field" -f --raw-field
        _check_api_fields
        _check_files "gh api --input" --input
        return 0
    fi
    [[ "${_grp}" == pr || "${_grp}" == issue ]] || return 0
    case "${_sub}" in
        create|new|comment|edit|review) ;;
        close|reopen) _REL=1; _check_inline "gh ${_grp} ${_sub} comment" --comment -c; return 0 ;;
        *) return 0 ;;
    esac
    _REL=1
    _check_inline "gh ${_grp} ${_sub} body" --body -b
    _check_files "gh ${_grp} ${_sub} body" --body-file -F
}

# _heredoc_word <encoded word>... - 0 when a word carries heredoc input. The
# shared subcommand parser represents a heredoc body as a literal here-string,
# so both its original << form and that normalized <<< form count here.
_heredoc_word() {
    local _w
    for _w in "$@"; do
        _w="$(hook_word "${_w}")"
        [[ "${_w}" == '<<'* ]] && return 0
    done
    return 1
}

# _stdin_fed - a stdin body of the launch in _E must come from a heredoc
# redirected into that same gh launch, not from a pipe or another command.
_stdin_fed() {
    [[ "${_STDIN}" -eq 1 ]] || return 0
    _heredoc_word "${_E[@]}" || _block_literal "a gh body read from stdin"
}

# _line_feeds_gh <line> - 0 when a gh launch on <line> takes a heredoc. Every
# heredoc opened on such a line is then judged as a gh body: one line can
# open several (cat <<A; gh ... <<B, or gh ... <<A <<B), and judging them all
# fails closed rather than guess which one gh reads.
_line_feeds_gh() {
    local _s _w
    local -a _ws
    while IFS= read -r _s; do
        read -r -a _ws <<<"${_s}"
        _w="$(hook_word "${_ws[0]:-}")"
        [[ "${_w}" == gh || "${_w}" == */gh ]] || continue
        _heredoc_word "${_ws[@]}" && return 0
    done < <(hook_subcommands_raw "$1")
    return 1
}

# _heredoc_delim <text> - read the heredoc delimiter word at the start of
# <text> as bash does: blanks skipped, then up to an unquoted metacharacter,
# with quote removal. Sets _HD_WORD, _HD_RAW (1 when any part was quoted, so
# the body is literal) and _HD_LEN (characters consumed).
_heredoc_delim() {
    local _t="$1" _i=0 _c _q='' _ansi=0 _meta=$' \t;&|<>()'
    _HD_WORD=''; _HD_RAW=0
    while [[ "${_t:_i:1}" == [[:blank:]] ]]; do _i=$((_i + 1)); done
    for ((; _i < ${#_t}; _i++)); do
        _c="${_t:_i:1}"
        if [[ -n "${_q}" ]]; then
            [[ "${_c}" == "${_q}" ]] && { _q=''; continue; }
            if [[ "${_ansi}" -eq 1 && "${_c}" == "\\" ]]; then
                _HD_WORD=''; _HD_LEN="${#_t}"
                return 0
            fi
            if [[ "${_q}" == '"' && "${_c}" == "\\" && "${_t:_i+1:1}" == [\"\\\$\`] ]]; then
                _i=$((_i + 1)); _c="${_t:_i:1}"
            fi
            _HD_WORD+="${_c}"
            continue
        fi
        [[ "${_meta}" == *"${_c}"* ]] && break
        case "${_c}" in
            '$')
                if [[ "${_t:_i+1:1}" == "'" || "${_t:_i+1:1}" == '"' ]]; then
                    _q="${_t:_i+1:1}"; _HD_RAW=1; _i=$((_i + 1))
                    [[ "${_q}" == "'" ]] && _ansi=1
                else
                    _HD_WORD+="${_c}"
                fi ;;
            \'|\") _q="${_c}"; _HD_RAW=1 ;;
            \\) _HD_RAW=1; _i=$((_i + 1)); _HD_WORD+="${_t:_i:1}" ;;
            *) _HD_WORD+="${_c}" ;;
        esac
    done
    _HD_LEN="${_i}"
}

# _heredoc_openers <line> - print "<raw> <strip> <delimiter>" for every
# heredoc the line opens, in order, skipping quoted text and here-strings;
# <raw> is 1 for a quoted delimiter (a literal body), <strip> 1 for <<-.
# An opener without a delimiter word prints an empty <delimiter>.
_heredoc_openers() {
    local _l="$1" _i=0 _c _q='' _ansi=0 _strip
    while ((_i < ${#_l})); do
        _c="${_l:_i:1}"
        if [[ -n "${_q}" ]]; then
            [[ ( "${_q}" == '"' || "${_ansi}" -eq 1 ) && "${_c}" == "\\" ]] \
                && { _i=$((_i + 2)); continue; }
            [[ "${_c}" == "${_q}" ]] && { _q=''; _ansi=0; }
            _i=$((_i + 1))
            continue
        fi
        case "${_c}" in
            \\) _i=$((_i + 2)); continue ;;
            '$')
                if [[ "${_l:_i+1:1}" == "'" ]]; then
                    _q="'"; _ansi=1; _i=$((_i + 2)); continue
                fi ;;
            \'|\") _q="${_c}"; _i=$((_i + 1)); continue ;;
        esac
        if [[ "${_l:_i:3}" == '<<<' ]]; then _i=$((_i + 3)); continue; fi
        if [[ "${_l:_i:2}" != '<<' ]]; then _i=$((_i + 1)); continue; fi
        _i=$((_i + 2)); _strip=0
        [[ "${_l:_i:1}" == - ]] && { _strip=1; _i=$((_i + 1)); }
        _heredoc_delim "${_l:_i}"
        printf '%s %s %s\n' "${_HD_RAW}" "${_strip}" "${_HD_WORD}"
        _i=$((_i + _HD_LEN))
    done
}

# _heredoc_done <raw> <body> - a finished heredoc body fed to gh: an unquoted
# one holding '$' or a backtick blocks (fail closed), else it is printed.
_heredoc_done() {
    [[ "$1" -eq 0 && ( "$2" == *'$'* || "$2" == *'`'* ) ]] \
        && _block_literal "an unquoted heredoc fed to gh"
    printf '%s' "$2"
}

# _heredoc_end <strip> <line> - 0 when <line> is the pending delimiter
# (_terms[0]): an exact match, or after leading tabs for <<-.
_heredoc_end() {
    local _l="$2"
    [[ "$1" -eq 1 ]] && _l="${_l#"${_l%%[!$'\t']*}"}"
    [[ "${_l}" == "${_terms[0]}" ]]
}

# _heredoc_open <line> - queue the heredocs <line> opens and set _fed when a
# gh launch on it takes one; an opener without a delimiter feeding gh blocks.
_heredoc_open() {
    local _o _r
    while IFS= read -r _o; do
        _raws+=("${_o%% *}"); _r="${_o#* }"
        _strips+=("${_r%% *}"); _terms+=("${_r#* }")
    done < <(_heredoc_openers "$1")
    [[ "${#_terms[@]}" -gt 0 ]] || return 0
    _fed=0; _line_feeds_gh "$1" && _fed=1
    [[ "${_fed}" -eq 1 ]] || return 0
    for _r in "${_terms[@]}"; do
        [[ -n "${_r}" ]] || _block_literal "a heredoc to gh without a delimiter word"
    done
    return 0
}

# _gh_heredocs <command> - print the lines of every heredoc body fed to a gh
# launch (the complement of lib/subcommand.sh's heredoc stripping). The
# heredocs a line opens are read in order, each up to its own delimiter; one
# left open at the end of the command runs to the end, as bash reads it.
_gh_heredocs() {
    local _line _fed=0 _body=''
    local -a _raws=() _strips=() _terms=()
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ "${#_terms[@]}" -eq 0 ]]; then
            _heredoc_open "${_line}"
            continue
        fi
        if ! _heredoc_end "${_strips[0]}" "${_line}"; then
            [[ "${_fed}" -eq 1 ]] && _body+="${_line}"$'\n'
            continue
        fi
        [[ "${_fed}" -eq 1 ]] && _heredoc_done "${_raws[0]}" "${_body}"
        _body=''
        _raws=("${_raws[@]:1}"); _strips=("${_strips[@]:1}"); _terms=("${_terms[@]:1}")
    done <<<"$1"
    [[ "${#_terms[@]}" -gt 0 && "${_fed}" -eq 1 ]] && _heredoc_done "${_raws[0]}" "${_body}"
    return 0
}

# _track_cd - follow a literal `cd <dir>` launch in _E for relative files.
_track_cd() {
    local _d
    _d="$(hook_word "${_E[1]:-}")"
    if [[ -z "${_d}" || "${_d}" == - ]] || _expands "${_E[1]}"; then
        _CWD=''
        return 0
    fi
    _CWD="$(_resolve "${_d}")"
}

main() {
    hook_read_input
    local _cmd _sub _here _w0
    _cmd="$(hook_command)"
    [[ -n "${_cmd}" ]] || hook_allow
    _CWD="$(hook_field '.cwd')"
    while IFS= read -r _sub; do
        read -r -a _E <<<"${_sub}"
        _w0="$(hook_word "${_E[0]:-}")"
        case "${_w0}" in
            cd) _track_cd ;;
            gh|*/gh) _STDIN=0; _check_gh; _stdin_fed ;;
        esac
    done < <(hook_subcommands_raw "${_cmd}")
    [[ "${_REL}" -eq 1 ]] || hook_allow
    _here="$(_gh_heredocs "${_cmd}")" || exit 2
    _judge "${_here}" "a heredoc fed to gh"
    hook_allow
}

main "$@"
