#!/usr/bin/env bash
# .agents/hook/enforce_gh_body_file.sh - Claude Code PreToolUse hook
# (matcher: Bash), registered in .claude/settings.json.
#
# worktool writes issue / PR bodies and long comments (zh-TW, see
# doc/agent/issue-tracker.md) to a file first and hands gh the file. This
# hook DENIES (permissionDecision "deny", exit 0) a gh call that breaks it:
#   1. `gh issue create` / `gh pr create` without `--body-file <path>`
#   2. `gh issue create` without a non-empty `--label` (PRs are exempt:
#      they close an issue that carries the label)
#   3. `gh issue close --comment ...`: comment first, then close
#   4. `gh pr edit --body ...` inline: the file keeps the rewrite reviewable
#   5. `gh issue comment` / `gh pr comment` / `gh pr review` with an inline
#      body that is multi-line or over SHORT_LIMIT (80) characters
#   6. `--body "$(cat ...)"` or `--body-file -` heredocs on any gh call:
#      both trip Claude Code's bash parser
# Everything else (other subcommands, canonical forms, non-gh commands)
# passes silently. Only real gh launches count: lib/subcommand.sh reduces
# the command to its sub-commands, so a commit message, an echo or a
# heredoc body that merely mentions `gh issue create` is data. Flags are
# judged on the parsed launch; an inline body's length and line count on
# the raw text, where its quotes and newlines survive.
#
# Output contract: allow = exit 0, no stdout; deny = exit 0 with the
# permissionDecision JSON on stdout.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-gh-body-file"

readonly SHORT_LIMIT=80

# Print the inline --body / --comment value of the command (quoted or bare).
_extract_body() {
    if [[ "$1" =~ --(body|comment)[[:space:]]+\"([^\"]*)\" ]] \
        || [[ "$1" =~ --(body|comment)[[:space:]]+\'([^\']*)\' ]] \
        || [[ "$1" =~ --(body|comment)=([^[:space:]]+) ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

# 0 when the inline body is one line of at most SHORT_LIMIT characters.
_short_body_ok() {
    [[ "$1" == *$'\n'* ]] && return 1
    (( ${#1} <= SHORT_LIMIT ))
}

# 0 when --body-file names a real path (not `-`).
_has_real_body_file() {
    local _v=''
    if [[ "$1" =~ --body-file(=|[[:space:]]+)([^[:space:]]+) ]]; then
        _v="${BASH_REMATCH[2]}"
    fi
    [[ -n "${_v}" && "${_v}" != "-" ]]
}

# 0 when the command carries a non-empty --label / -l (quoted or bare,
# spaced or `=` form). gh itself rejects a label the repo does not have.
_has_label() {
    [[ "$1" =~ (^|[[:space:]])(--label|-l)[[:space:]]+(\"[^\"]+\"|\'[^\']+\'|[^[:space:]\"\'=-][^[:space:]]*)([[:space:]]|$) ]] \
        || [[ "$1" =~ --label=(\"[^\"]+\"|\'[^\']+\'|[^[:space:]\"\'][^[:space:]]*)([[:space:]]|$) ]]
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

# _check_subcmd <"issue create" | ...> <launch> <raw command> - print the
# deny reason for this gh subcommand, or nothing.
_check_subcmd() {
    local _sub="$1" _cmd="$2" _body
    local _file='Write the body to a file first, then pass --body-file <file>.'
    case "${_sub}" in
        "issue create"|"pr create")
            if ! _has_real_body_file "${_cmd}"; then
                printf 'gh %s needs --body-file <path>. %s' "${_sub}" "${_file}"
            elif [[ "${_sub}" == "issue create" ]] && ! _has_label "${_cmd}"; then
                printf 'gh issue create needs --label <name> (e.g. enhancement, bug, documentation; see doc/agent/triage-labels.md for the triage labels).'
            fi ;;
        "issue close")
            if [[ "${_cmd}" =~ (--comment|-c)([[:space:]]+|=) ]]; then
                printf 'gh issue close --comment is denied. Close in two steps: gh issue comment N --body-file <file> (or a short --body), then gh issue close N.'
            fi ;;
        "pr edit")
            if [[ "${_cmd}" =~ --body([[:space:]]+|=) ]] && ! _has_real_body_file "${_cmd}"; then
                printf 'gh pr edit --body inline is denied (it rewrites the whole body). %s' "${_file}"
            fi ;;
        "issue comment"|"pr comment"|"pr review")
            _body="$(_extract_body "$3")"
            if [[ -n "${_body}" ]] && ! _short_body_ok "${_body}"; then
                printf 'gh %s body is too long for inline (%d chars or multi-line; limit %d, one line). %s' \
                    "${_sub}" "${#_body}" "${SHORT_LIMIT}" "${_file}"
            fi ;;
    esac
}

# _check_launch <gh launch> <raw command> - print the deny reason for this
# gh launch, or nothing.
_check_launch() {
    if [[ "$2" =~ --(body|comment)[[:space:]]+\"?\$\([[:space:]]*cat[[:space:]] ]]; then
        printf '%s' "gh --body \"\$(cat ...)\" trips Claude Code's bash parser. Write the body to a file, then pass --body-file <file>."
    elif [[ "$1" =~ --body-file[[:space:]]+-([[:space:]]|$) ]]; then
        printf '%s' "gh --body-file - with a stdin heredoc trips Claude Code's bash parser. Write the body to a file, then pass --body-file <file>."
    elif [[ "$1" =~ ^gh[[:space:]]+(issue|pr)[[:space:]]+([a-z]+) ]]; then
        _check_subcmd "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" "$1" "$2"
    fi
}

main() {
    hook_read_input
    local _cmd _sub _reason=''
    _cmd="$(hook_command)"
    while IFS= read -r _sub; do
        [[ "${_sub}" =~ ^gh[[:space:]] ]] || continue
        _reason="$(_check_launch "${_sub}" "${_cmd}")"
        [[ -n "${_reason}" ]] && break
    done < <(hook_subcommands "${_cmd}")
    [[ -n "${_reason}" ]] && _deny "${_reason}"
    return 0
}

main "$@"
