#!/usr/bin/env bash
# .agents/hook/lib/transcript.sh - read the session transcript for the
# approval hooks (a hook that lets an action through only when the
# maintainer's latest message approves it).
#
#   read_latest_user_message <transcript_path>
#       the latest user-typed text message of the JSONL transcript
#       (tool_result entries skipped); missing / unreadable file -> nothing.
#       Always exit 0.
#
# Library: sourced, sets no shell options, only declares functions.

# Library guard: refuse to run as an executable script.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf 'Warn: %s is a library, not an executable script.\n' "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

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
