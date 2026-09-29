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
# fails on it anyway. Everything else passes silently; quoted text that
# merely mentions `gh issue create` is data (lib/subcommand.sh).
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

# _judge_launch <encoded gh issue create launch> - print the deny reason, or
# nothing.
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
    if [[ -n "${_file}" ]]; then
        _body="$(_read_body_file "${_file}")" || return 0
    fi
    _is_guard_issue "${_title}" "${_body}" || return 0
    _has_scope "${_body}" && return 0
    printf '%s' 'This issue asks for a guard (hook / gate / check / filter / block; 攔截 / 檢查 / 過濾) but its body has no "## 範圍" section. Add the threat model first: 擋 (what it blocks), 不擋 (what it deliberately lets through), 已知限制 (known limits). pr-loop hands that section to codex as the blocking scope (issue #238).'
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
        _reason="$(_judge_launch "${_sub}")"
        [[ -n "${_reason}" ]] && break
    done < <(hook_subcommands_raw "${_cmd}")
    [[ -n "${_reason}" ]] && _deny "${_reason}"
    return 0
}

main "$@"
