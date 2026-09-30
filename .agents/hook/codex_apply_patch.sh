#!/usr/bin/env bash
# Adapt Codex apply_patch input to the Claude-style file-edit hook interface.

_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "codex-apply-patch"

_run_write_hooks() {
    local _file="$1" _content="$2" _payload _result _rc=0
    _payload="$(printf '%s' "${HOOK_INPUT}" | jq -c \
        --arg file "${_file}" --arg content "${_content}" \
        '.tool_name = "Write" | .tool_input = {file_path:$file, content:$content}')"

    _result="$(printf '%s' "${_payload}" \
        | "${HOOK_REPO_ROOT}/.agents/hook/enforce_shellcheck_disable_approval.sh")" || _rc=$?
    if (( _rc != 0 )); then
        return "${_rc}"
    fi
    if [[ -n "${_result}" ]]; then
        printf '%s\n' "${_result}"
        return 1
    fi
    return 0
}

main() {
    hook_read_input
    [[ "$(hook_field '.tool_name')" == apply_patch ]] || hook_allow

    local _patch _line _file='' _content=''
    _patch="$(hook_field '.tool_input.command')"
    while IFS= read -r _line; do
        case "${_line}" in
            '*** Add File: '*)
                if [[ -n "${_file}" ]]; then
                    _run_write_hooks "${_file}" "${_content}" || hook_allow
                fi
                _file="${_line#'*** Add File: '}"
                _content=''
                ;;
            +*) _content+="${_line#+}"$'\n' ;;
            '*** End Patch')
                if [[ -n "${_file}" ]]; then
                    _run_write_hooks "${_file}" "${_content}" || hook_allow
                fi
                _file=''
                ;;
        esac
    done <<<"${_patch}"
    hook_allow
}

main "$@"
