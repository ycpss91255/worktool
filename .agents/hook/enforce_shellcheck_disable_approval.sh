#!/usr/bin/env bash
# .agents/hook/enforce_shellcheck_disable_approval.sh - Claude Code
# PreToolUse hook (matcher: Edit|Write|MultiEdit), registered in
# .claude/settings.json.
#
# worktool keeps zero ShellCheck disable directives: the fix
# comes from https://www.shellcheck.net/wiki/SC<code>, and only when no
# proper fix exists may a disable be added - with the maintainer's explicit
# approval. This hook DENIES (permissionDecision "deny") an Edit / Write /
# MultiEdit that introduces a disable code the latest user-typed message of
# the session transcript has not approved with `approve SC<code>`.
#
# Functions (each testable on its own; the file can be sourced, main runs
# only when it is executed):
#   read_latest_user_message <transcript_path>
#       the latest user-typed text message (tool_result entries skipped);
#       missing / unreadable file -> nothing
#   new_shellcheck_disables <new_content> <existing_file_path>
#       each disable code in the new content that the existing file does not
#       already have, one per line (multi-code directives split)
#   is_disable_approved <SC_code> <user_msg>
#       0 when the message matches `\bapprove\b.*\bSC<code>\b` (verb
#       case-insensitive)
#
# Output contract: allow = exit 0, no stdout; deny = exit 0 with the
# permissionDecision JSON on stdout.
# Bypass: WORKTOOL_ALLOW_SHELLCHECK_DISABLE=1 in the environment.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "enforce-shellcheck-disable-approval"

# read_latest_user_message <transcript_path> - scan the JSONL backwards for
# the first user entry whose content is a string or holds a text block.
read_latest_user_message() {
    local _path="${1:-}" _line _text
    [[ -n "${_path}" && -r "${_path}" ]] || return 0
    while IFS= read -r _line; do
        _text="$(printf '%s' "${_line}" | jq -r '
            select(.type == "user") | select(.message.role == "user")
            | .message.content
            | if type == "string" then .
              elif type == "array" then (map(select(.type == "text")) | .[0].text // empty)
              else empty end' 2>/dev/null)"
        if [[ -n "${_text}" ]]; then
            printf '%s\n' "${_text}"
            return 0
        fi
    done < <(tac "${_path}" 2>/dev/null)
    return 0
}

# _extract_disable_codes <content> - each SC code of every disable
# directive, one per line, sorted and unique.
_extract_disable_codes() {
    [[ -n "${1:-}" ]] || return 0
    printf '%s' "$1" \
        | grep -oE '#[[:space:]]*shellcheck[[:space:]]+disable=SC[0-9]+(,SC[0-9]+)*' \
        | grep -oE 'SC[0-9]+' \
        | sort -u
}

# new_shellcheck_disables <new_content> <existing_file_path> - see header.
new_shellcheck_disables() {
    local _new _old=''
    _new="$(_extract_disable_codes "${1:-}")"
    [[ -n "${_new}" ]] || return 0
    if [[ -n "${2:-}" && -f "$2" ]]; then
        _old="$(_extract_disable_codes "$(cat "$2" 2>/dev/null)")"
    fi
    if [[ -z "${_old}" ]]; then
        printf '%s\n' "${_new}"
        return 0
    fi
    comm -23 <(printf '%s\n' "${_new}") <(printf '%s\n' "${_old}")
    return 0
}

# is_disable_approved <SC_code> <user_msg> - see header. PCRE for `\b` and
# a cross-line match; an ERE on the flattened message as the fallback.
is_disable_approved() {
    local _code="${1:-}" _msg="${2:-}" _flat
    [[ -n "${_code}" && -n "${_msg}" ]] || return 1
    _msg="$(printf '%s' "${_msg}" | tr '[:upper:]' '[:lower:]')"
    _code="$(printf '%s' "${_code}" | tr '[:upper:]' '[:lower:]')"
    if printf '%s' "${_msg}" | grep -qP "\\bapprove\\b(?s).*\\b${_code}\\b" 2>/dev/null; then
        return 0
    fi
    _flat="$(printf '%s' "${_msg}" | tr '\n' ' ')"
    printf '%s' "${_flat}" \
        | grep -qE "(^|[^[:alnum:]_])approve([^[:alnum:]_]|\$).*(^|[^[:alnum:]_])${_code}([^[:alnum:]_]|\$)"
}

# _extract_edits <payload> - one `<file_path>\t<base64 new content>` line per
# edit (base64 keeps a multi-line edit on one line).
_extract_edits() {
    local _in="$1"
    case "$(printf '%s' "${_in}" | jq -r '.tool_name // empty' 2>/dev/null)" in
        Write)
            printf '%s' "${_in}" | jq -r \
                '.tool_input.file_path + "\t" + ((.tool_input.content // "") | @base64)' 2>/dev/null ;;
        Edit)
            printf '%s' "${_in}" | jq -r \
                '.tool_input.file_path + "\t" + ((.tool_input.new_string // "") | @base64)' 2>/dev/null ;;
        MultiEdit)
            printf '%s' "${_in}" | jq -r '.tool_input.file_path as $fp
                | .tool_input.edits[] | $fp + "\t" + ((.new_string // "") | @base64)' 2>/dev/null ;;
    esac
    return 0
}

# _unapproved_codes <edits-tsv> <user_msg> - each new, unapproved code once,
# in order of appearance.
_unapproved_codes() {
    local _fp _b64 _code
    local -A _seen=()
    while IFS=$'\t' read -r _fp _b64; do
        [[ -n "${_fp}" ]] || continue
        while IFS= read -r _code; do
            [[ -n "${_code}" && -z "${_seen[${_code}]+x}" ]] || continue
            is_disable_approved "${_code}" "$2" && continue
            _seen[${_code}]=1
            printf '%s\n' "${_code}"
        done < <(new_shellcheck_disables "$(printf '%s' "${_b64}" | base64 -d 2>/dev/null)" "${_fp}")
    done <<<"$1"
}

# _deny_reason <code>... - the deny message for the unapproved codes.
_deny_reason() {
    local _c
    printf 'worktool keeps zero ShellCheck disable directives. These new ones have not been approved in the latest user message:\n'
    for _c in "$@"; do
        printf '  - %s - https://www.shellcheck.net/wiki/%s\n' "${_c}" "${_c}"
    done
    printf '\nWhat to do:\n'
    printf '  1. Read the wiki page(s) above and apply the proper fix.\n'
    printf '  2. Only if no proper fix exists, ask the maintainer to reply "approve SC<code>" (batchable: "approve SC2034 SC1091") and explain why in the PR.\n'
    printf '  3. Emergency bypass: WORKTOOL_ALLOW_SHELLCHECK_DISABLE=1 in the environment.\n'
}

main() {
    [[ "${WORKTOOL_ALLOW_SHELLCHECK_DISABLE:-}" == 1 ]] && return 0
    hook_read_input
    [[ -n "${HOOK_INPUT}" ]] || return 0
    local _edits _msg
    local -a _codes=()
    _edits="$(_extract_edits "${HOOK_INPUT}")"
    [[ -n "${_edits}" ]] || return 0
    _msg="$(read_latest_user_message "$(hook_field '.transcript_path')")"
    mapfile -t _codes < <(_unapproved_codes "${_edits}" "${_msg}")
    (( ${#_codes[@]} > 0 )) || return 0
    jq -n --arg m "$(_deny_reason "${_codes[@]}")" '{
        systemMessage: $m,
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $m
        }
    }'
    return 0
}

# Run main only when executed, so the specs can source the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
