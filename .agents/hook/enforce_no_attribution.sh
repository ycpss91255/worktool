#!/usr/bin/env bash
# .agents/hook/enforce_no_attribution.sh - Claude Code PreToolUse hook
# (matcher: Bash), registered in .claude/settings.json (issue #270).
#
# Maintainer rule: commit messages, PR / issue bodies and comments carry no
# attribution line. What counts as one is defined ONLY by the table of
# lib/attribution.sh (attribution_find), shared with the CI check (#271).
# This hook blocks (exit 2, reason on stderr) a launch that would send one:
#   - git [root options] commit: every -m / --message value and every
#     -F / --file content (a path is read from the session's cwd, or from
#     the -C directory; `-F -` reads a literal here-string / heredoc stdin)
#   - gh [-R <repo>] pr create|new|edit|comment|review and gh issue
#     create|new|edit|comment: every --body / -b value and every
#     --body-file / -F content (`-` as above)
# lib/subcommand.sh reduces the command to its launches first, so the same
# rules apply inside `bash -c` and `eval`, and text that merely mentions
# such a call (an echo, a file being written) is data.
#
# Fail closed: a message / body the hook cannot read - a value or path
# holding a shell expansion, `-` with a stdin that is no literal
# here-string, a file that is not readable - blocks too. Everything else
# passes silently (exit 0).

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-no-attribution"
# shellcheck source=../../../lib/attribution.sh
source "${HOOK_REPO_ROOT}/lib/attribution.sh"

# The launch under judgement: its encoded words, and its stdin when that
# is a literal here-string.
_E=()
_STDIN=''
_STDIN_OK=''
# The session's working directory, from the payload, and the directory
# the current launch resolves relative paths against.
_CWD=''
_DIR=''
# The encoded message values and file paths the launch passes, and the
# option set _collect reads them by (short message / file / value-taking
# letters, long message / file options).
_MSGS=()
_FILES=()
_ML=''
_FL=''
_VL=''
_LM=''
_LF=''

_FIX='Remove the attribution line and retry; write the text to a file and pass it as a literal path (git commit -F <file>, gh ... --body-file <file>).'

# _judge <text> <source> - block when <text> holds an attribution line.
_judge() {
    local _found
    _found="$(attribution_find "$1")" || return 0
    hook_block "$2 holds an attribution line (Co-Authored-By / Claude-Session / Generated with Claude Code); the maintainer rule forbids it." \
        "Line: ${_found%%$'\n'*}" "${_FIX}"
}

# _unreadable <source> - fail closed on a message the hook cannot read.
_unreadable() {
    hook_block "$1 cannot be read to check it for an attribution line (fail closed)." \
        "Pass the text as a literal word, or write it to a file first and pass the literal path (git commit -F <file>, gh ... --body-file <file>)."
}

# _path <file> - <file> resolved against _DIR.
_path() {
    if [[ "$1" == /* || -z "${_DIR}" ]]; then
        printf '%s' "$1"
    else
        printf '%s/%s' "${_DIR}" "$1"
    fi
}

# _judge_all <what> - judge every collected value and file of the launch.
_judge_all() {
    local _v _f _src
    for _v in "${_MSGS[@]}"; do
        if hook_word_has_expansion "${_v}"; then
            _unreadable "$1 (a value holding a shell expansion)"
        fi
        _judge "$(hook_word "${_v}")" "$1"
    done
    for _v in "${_FILES[@]}"; do
        if hook_word_has_expansion "${_v}"; then
            _unreadable "$1 (a file path holding a shell expansion)"
        fi
        _f="$(hook_word "${_v}")"
        _src="$1 file '${_f}'"
        if [[ "${_f}" == - ]]; then
            if [[ -z "${_STDIN_OK}" ]]; then
                _unreadable "${_src} (stdin that is no literal here-string)"
            fi
            _judge "${_STDIN}" "${_src}"
        else
            _f="$(_path "${_f}")"
            if [[ ! -f "${_f}" || ! -r "${_f}" ]]; then
                _unreadable "${_src}"
            fi
            _judge "$(cat -- "${_f}")" "${_src}"
        fi
    done
}

# _redirect_span <encoded word> - how many words a redirection spans: 2 for
# an operator standing alone (its target is the next word), 1 for one with
# its target attached (2>&1, >f, <<<body), 0 for no redirection. Encoded, so
# a quoted < or > (data) is never taken for an operator.
_redirect_span() {
    local _w="${1#"${1%%[!0-9]*}"}"
    case "${_w}" in
        '<<<'|'<<'|'<<-'|'<>'|'>>'|'>|'|'<&'|'>&'|'&>>'|'&>'|'<'|'>') printf 2 ;;
        '<'*|'>'*|'&>'*) printf 1 ;;
        *) printf 0 ;;
    esac
}

# _scan_stdin - fill _STDIN / _STDIN_OK from the launch's stdin: readable
# only when the last stdin redirection is a literal here-string (a heredoc
# gh reads arrives as one, lib/subcommand.sh); any other source is not.
_scan_stdin() {
    local _i _w _body
    _STDIN=''
    _STDIN_OK=''
    for ((_i = 0; _i < ${#_E[@]}; _i++)); do
        _w="${_E[_i]}"
        case "${_w}" in
            '<<<') _body="${_E[_i + 1]:-}" ;;
            '<<<'*) _body="${_E[_i]#<<<}" ;;
            '<'*|[0-9]'<'*) _STDIN_OK=''; continue ;;
            *) continue ;;
        esac
        if hook_word_has_expansion "${_body}"; then
            _STDIN_OK=''
        else
            _STDIN="$(hook_word "${_body}")"
            _STDIN_OK=1
        fi
    done
}

# _cluster <encoded word> - a short-option cluster (-am, -mMSG, -F f): the
# first letter of _VL takes the rest of the cluster as its value, or the
# next word when it ends the cluster (_i advances). A value of the message
# letter _ML goes to _MSGS, of the file letter _FL to _FILES.
_cluster() {
    local _k _c _v
    for ((_k = 1; _k < ${#1}; _k++)); do
        _c="${1:_k:1}"
        [[ "${_VL}" == *"${_c}"* ]] || continue
        _v="${1:_k+1}"
        if [[ -z "${_v}" ]]; then
            _i=$((_i + 1))
            _v="${_E[_i]:-}"
        fi
        if [[ "${_c}" == "${_ML}" ]]; then
            _MSGS+=("${_v}")
        elif [[ "${_c}" == "${_FL}" ]]; then
            _FILES+=("${_v}")
        fi
        return 0
    done
}

# _collect <from> - fill _MSGS / _FILES from the words _E[from..] by the
# option set in _ML / _FL / _VL (short letters) and _LM / _LF (long
# options); redirections are skipped, `--` ends the options.
_collect() {
    local _i _e _w _n
    _MSGS=()
    _FILES=()
    for ((_i = $1; _i < ${#_E[@]}; _i++)); do
        _e="${_E[_i]}"
        _w="$(hook_word "${_e}")"
        _n="$(_redirect_span "${_e}")"
        if [[ "${_n}" -gt 0 ]]; then
            _i=$((_i + _n - 1))
            continue
        fi
        case "${_w}" in
            --) break ;;
            "${_LM}="*) _MSGS+=("${_e#*=}") ;;
            "${_LF}="*) _FILES+=("${_e#*=}") ;;
            "${_LM}") _i=$((_i + 1)); _MSGS+=("${_E[_i]:-}") ;;
            "${_LF}") _i=$((_i + 1)); _FILES+=("${_E[_i]:-}") ;;
            --*) ;;
            -?*) _cluster "${_e}" ;;
        esac
    done
}

# _check_git - git [root options] commit: judge its messages. The root -C
# moves the directory a relative -F path resolves against.
_check_git() {
    local _i=1 _w=''
    _DIR="${_CWD}"
    while [[ "${_i}" -lt "${#_E[@]}" ]]; do
        _w="$(hook_word "${_E[_i]}")"
        case "${_w}" in
            -C) _DIR="$(_path "$(hook_word "${_E[_i + 1]:-}")")"; _i=$((_i + 2)) ;;
            -c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) _i=$((_i + 2)) ;;
            -*) _i=$((_i + 1)) ;;
            *) break ;;
        esac
    done
    [[ "${_w}" == commit ]] || return 0
    _ML=m _FL=F _VL=mFcCt _LM=--message _LF=--file
    _collect $((_i + 1))
    _judge_all "git commit message"
}

# _check_gh - gh [-R <repo>] pr|issue <writing sub-command>: judge its
# bodies.
_check_gh() {
    local _i=1 _w
    while [[ "${_i}" -lt "${#_E[@]}" ]]; do
        _w="$(hook_word "${_E[_i]}")"
        case "${_w}" in
            -R|--repo) _i=$((_i + 2)) ;;
            -*) _i=$((_i + 1)) ;;
            *) break ;;
        esac
    done
    _w="$(hook_word "${_E[_i]:-}") $(hook_word "${_E[_i + 1]:-}")"
    case "${_w}" in
        "pr create"|"pr new"|"pr edit"|"pr comment"|"pr review") ;;
        "issue create"|"issue new"|"issue edit"|"issue comment") ;;
        *) return 0 ;;
    esac
    _DIR="${_CWD}"
    _ML=b _FL=F _VL=RbFtBHalmprTAe _LM=--body _LF=--body-file
    _collect $((_i + 2))
    _judge_all "gh ${_w} body"
}

main() {
    hook_read_input
    local _cmd _sub _lead _w0
    _cmd="$(hook_command)"
    _CWD="$(hook_field '.cwd')"
    [[ -n "${_cmd}" ]] || hook_allow
    while IFS= read -r _sub; do
        _lead="$(hook_timeout_lead "${_sub}")"
        read -r -a _E <<<"${_sub#"${_lead}"}"
        [[ "${#_E[@]}" -gt 0 ]] || continue
        _scan_stdin
        _w0="$(hook_word "${_E[0]}")"
        case "${_w0##*/}" in
            git) _check_git ;;
            gh) _check_gh ;;
        esac
    done < <(hook_subcommands_raw "${_cmd}")
    hook_allow
}

main "$@"
