#!/usr/bin/env bash
# Adapt Codex apply_patch input to the Claude-style file-edit hook interface.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "codex-apply-patch"

_run_edit_hooks() {
    local _tool="$1" _file="$2" _content="$3" _payload _command _hook _result _reason _rc
    _payload="$(printf '%s' "${HOOK_INPUT}" | jq -c \
        --arg tool "${_tool}" --arg file "${_file}" --arg content "${_content}" '
        .tool_name = $tool
        | .tool_input = if $tool == "Write"
            then {file_path:$file, content:$content}
            else {file_path:$file, new_string:$content}
          end')"

    while IFS= read -r _command; do
        _hook="${HOOK_REPO_ROOT}/.agents/hook/${_command##*/}"
        _rc=0
        _result="$(printf '%s' "${_payload}" | "${_hook}")" || _rc=$?
        if (( _rc != 0 )); then
            return "${_rc}"
        fi
        if [[ -n "${_result}" ]] \
            && jq -e '.hookSpecificOutput.permissionDecision == "deny"' \
                <<<"${_result}" >/dev/null 2>&1; then
            _reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' \
                <<<"${_result}")"
            [[ -n "${_reason}" ]] || _reason="${_result}"
            printf '%s\n' "${_reason}" >&2
            return 2
        fi
    done < <(jq -r '.hooks.PreToolUse[] | .matcher as $matcher
        | select(("Edit" | test($matcher)) or ("Write" | test($matcher)))
        | .hooks[].command' "${HOOK_REPO_ROOT}/.claude/settings.json")
    return 0
}

_dispatch_file() {
    local _tool="$1" _file="$2" _content="$3" _rc=0
    _run_edit_hooks "${_tool}" "${_file}" "${_content}" || _rc=$?
    (( _rc == 0 )) || exit "${_rc}"
}

_dispatch_section() {
    local _tool="$1" _file="$2" _move_to="$3" _content="$4"
    [[ -n "${_file}" ]] || return 0
    if [[ -n "${_move_to}" ]]; then
        _dispatch_file Edit "${_file}" ''
        _dispatch_file Write "${_move_to}" "${_content}"
    else
        _dispatch_file "${_tool}" "${_file}" "${_content}"
    fi
}

main() {
    hook_read_input
    [[ "$(hook_field '.tool_name')" == apply_patch ]] || hook_allow

    local _patch _line _tool='' _file='' _move_to='' _content=''
    _patch="$(hook_field '.tool_input.command')"
    while IFS= read -r _line; do
        case "${_line}" in
            '*** Add File: '*)
                _dispatch_section "${_tool}" "${_file}" "${_move_to}" "${_content}"
                _tool=Write
                _file="${_line#'*** Add File: '}"
                _move_to=''
                _content=''
                ;;
            '*** Update File: '*)
                _dispatch_section "${_tool}" "${_file}" "${_move_to}" "${_content}"
                _tool=Edit
                _file="${_line#'*** Update File: '}"
                _move_to=''
                _content=''
                ;;
            '*** Delete File: '*)
                _dispatch_section "${_tool}" "${_file}" "${_move_to}" "${_content}"
                _tool=Edit
                _file="${_line#'*** Delete File: '}"
                _move_to=''
                _content=''
                ;;
            '*** Move to: '*) _move_to="${_line#'*** Move to: '}" ;;
            +*) _content+="${_line#+}"$'\n' ;;
            '*** End Patch')
                _dispatch_section "${_tool}" "${_file}" "${_move_to}" "${_content}"
                _file=''
                ;;
        esac
    done <<<"${_patch}"
    hook_allow
}

main "$@"
