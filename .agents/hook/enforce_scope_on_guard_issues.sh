#!/usr/bin/env bash
# .agents/hook/enforce_scope_on_guard_issues.sh - Claude Code PreToolUse
# hook (matcher: Bash), registered in .claude/settings.json.
#
# Issue #238: PR #219 needed eight codex rounds because its issue never
# said what the guard blocks and what it does not, so every round found a
# new spelling of the same action. A guard-type issue therefore states its
# threat model (擋 / 不擋 / 已知限制) in a "## 範圍" section up front, and
# pr-loop hands that section to codex as the blocking scope.
#
# This hook DENIES (permissionDecision "deny", exit 0) a real `gh issue
# create` launch when the issue is guard-type (_is_guard_issue, the one
# place the rule lives) and its body has no "## 範圍" heading. The title
# comes from --title / -t, the body from --body / -b (inline) or
# --body-file / -F (read from disk; a relative path is resolved against the
# tool call's cwd). A body file that cannot be read is left to gh, which
# fails on it anyway. A body read from stdin (-F - / --body-file -) is read
# only from a heredoc opened on the gh launch line itself (`gh issue create
# ... -F - <<'EOF'`), found with quotes masked and a # comment cut off, so a
# header spelled in a comment, a quoted <<, another command's heredoc or a
# pipe cannot stand in for the real stdin. Any other stdin body (a printf or
# cat pipe, 2<<, a later < file, two stdin launches) is not seen and a guard
# issue sent that way is denied: use a heredoc or --body-file instead.
# Everything else passes silently; quoted text that merely mentions
# `gh issue create` is data (lib/subcommand.sh).
#
# Output contract: allow = exit 0, no stdout; deny = exit 0 with the
# permissionDecision JSON on stdout.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-scope-on-guard-issues"

# _is_guard_issue <title> <body> - 0 when the issue asks for interception
# work: a guard word in the title (whole word, any case), or a new hook /
# gate asked for under "## What needs to be done".
_is_guard_issue() {
    local _title="${1,,}" _todo
    local _words='(^|[^a-z0-9_])(hook|gate|check|filter|block|guard)s?([^a-z0-9_]|$)'
    [[ "${_title}" =~ ${_words} || "${_title}" =~ (攔截|檢查|過濾) ]] && return 0
    _todo="$(awk '/^## What needs to be done/{f=1;next} f&&/^## /{exit} f' <<<"${2//$'\r'/}")"
    [[ "${_todo,,}" =~ (new|新增?)[[:space:]]*(hook|gate) ]]
}

# _has_scope <body> - 0 when the body carries a "## 範圍" heading.
_has_scope() {
    grep -qE '^##[[:space:]]+範圍' <<<"${1//$'\r'/}"
}

# _read_body_file <path> - print the file, relative to the tool call's cwd.
_read_body_file() {
    local _p="$1" _cwd
    if [[ "${_p}" != /* ]]; then
        _cwd="$(hook_field '.cwd')"
        _p="${_cwd:-${PWD}}/${_p}"
    fi
    [[ -r "${_p}" ]] || return 1
    cat -- "${_p}"
}

# _mask_line <line> - the line with every quoted character (and the escaped
# character after a backslash) replaced by '_' and an unquoted # comment cut
# off, so offsets still line up with the line. Exit 1 when the line ends
# inside an open quote.
_mask_line() {
    local _l="$1" _m='' _q='' _c _i _p=' ' _sep=$' \t;&|()'
    for ((_i = 0; _i < ${#_l}; _i++)); do
        _c="${_l:_i:1}"
        if [[ "${_c}" == "\\" && "${_q}" != "'" ]]; then
            _m+='__'
            _i=$((_i + 1))
            _p='_'
            continue
        fi
        if [[ -n "${_q}" ]]; then
            if [[ "${_c}" == "${_q}" ]]; then _q='' _m+="${_c}"; else _m+='_'; fi
        elif [[ "${_c}" == "'" || "${_c}" == '"' ]]; then
            _q="${_c}" _m+="${_c}"
        elif [[ "${_c}" == '#' && "${_sep}" == *"${_p}"* ]]; then
            break
        else
            _m+="${_c}"
        fi
        _p="${_c}"
    done
    printf '%s' "${_m:0:${#_l}}"
    [[ -z "${_q}" ]]
}

# _heredoc_op <line> <mask> - "<offset> <dash> <word>" of the first heredoc
# the line opens (<<WORD, <<-WORD, <<'WORD', <<"WORD"; not <<<), located on
# the mask, the word read from the line; nothing when it opens none.
_heredoc_op() {
    local _pre="${2%%<<*}"
    [[ "${_pre}" != "$2" && "${2:${#_pre}:3}" != '<<<' ]] || return 0
    [[ "${1:${#_pre}}" =~ ^\<\<(-?)[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*) ]] || return 0
    printf '%s %s %s' "${#_pre}" "${BASH_REMATCH[1]:-+}" "${BASH_REMATCH[2]}"
}

# _gh_heredoc <mask> <op offset> - 0 when the heredoc at <op offset> is the
# stdin of the gh issue create launch on the line: it follows the launch,
# sits on fd 0, and no other < redirect on the launch replaces it.
_gh_heredoc() {
    local _re='(^|[[:space:];&|(])gh[[:space:]]+issue[[:space:]]+create([[:space:]].*)$'
    [[ "$1" =~ ${_re} ]] || return 1
    local _at=$((${#1} - ${#BASH_REMATCH[2]})) _rest="${BASH_REMATCH[2]/<</}"
    [[ "$2" -gt "${_at}" && "${_rest}" != *'<'* ]] || return 1
    [[ "${1:$2-1:1}" == [[:space:]] || "${1:$2-2:2}" =~ ^[[:space:]]0$ ]]
}

# _stdin_body <command> - the heredoc body fed to the one gh issue create
# launch of the command (see the header); nothing when it cannot be seen.
_stdin_body() {
    local _line _mask _op _term='' _dash='' _mine=0 _hits=0 _body=''
    local _gh='(^|[[:space:];&|(])gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$)'
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ -n "${_term}" ]]; then
            [[ "${_dash}" == '-' ]] && _line="${_line#"${_line%%[!$'\t']*}"}"
            if [[ "${_line}" == "${_term}" ]]; then _term=''; continue; fi
            [[ "${_mine}" -eq 1 ]] && _body+="${_line}"$'\n'
            continue
        fi
        _mask="$(_mask_line "${_line}")" || return 0
        _mine=0
        _op="$(_heredoc_op "${_line}" "${_mask}")"
        if [[ "${_mask}" =~ ${_gh} ]]; then
            _hits=$((_hits + 1))
            [[ -n "${_op}" ]] && _gh_heredoc "${_mask}" "${_op%% *}" && _mine=1
        fi
        [[ -n "${_op}" ]] && read -r _ _dash _term <<<"${_op}"
    done <<<"${1//\\$'\n'/}"
    [[ "${_hits}" -eq 1 ]] && printf '%s' "${_body}"
    return 0
}

# _judge_launch <encoded gh issue create launch> <whole command> - print the
# deny reason, or nothing.
_judge_launch() {
    local -a _w
    local _i _title='' _body='' _file=''
    read -r -a _w <<<"$1"
    for ((_i = 0; _i < ${#_w[@]}; _i++)); do
        case "${_w[_i]}" in
            --title|-t) _title="$(hook_word "${_w[_i + 1]:-}")" ;;
            --title=*) _title="$(hook_word "${_w[_i]#*=}")" ;;
            --body|-b) _body="$(hook_word "${_w[_i + 1]:-}")" ;;
            --body=*) _body="$(hook_word "${_w[_i]#*=}")" ;;
            --body-file|-F) _file="$(hook_word "${_w[_i + 1]:-}")" ;;
            --body-file=*) _file="$(hook_word "${_w[_i]#*=}")" ;;
        esac
    done
    if [[ "${_file}" == "-" ]]; then
        _body="$(_stdin_body "$2")"
    elif [[ -n "${_file}" ]]; then
        _body="$(_read_body_file "${_file}")" || return 0
    fi
    _is_guard_issue "${_title}" "${_body}" || return 0
    _has_scope "${_body}" && return 0
    printf '%s' 'This issue asks for a guard (hook / gate / check / filter / block; 攔截 / 檢查 / 過濾) but its body has no "## 範圍" section. Add the threat model first: 擋 (what it blocks), 不擋 (what it deliberately lets through), 已知限制 (known limits). pr-loop hands that section to codex as the blocking scope (issue #238).'
    [[ "${_file}" == "-" ]] && printf '%s' ' A stdin body (-F -) is read only from a heredoc opened on the gh issue create line itself; a pipe, a comment or another command cannot supply it, so use such a heredoc or --body-file.'
    return 0
}

_deny() {
    jq -n --arg m "$1" '{
        systemMessage: $m,
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $m
        }
    }'
}

main() {
    hook_read_input
    local _cmd _sub _reason=''
    _cmd="$(hook_command)"
    while IFS= read -r _sub; do
        [[ "${_sub}" =~ ^gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$) ]] || continue
        _reason="$(_judge_launch "${_sub}" "${_cmd}")"
        [[ -n "${_reason}" ]] && break
    done < <(hook_subcommands_raw "${_cmd}")
    [[ -n "${_reason}" ]] && _deny "${_reason}"
    return 0
}

main "$@"
