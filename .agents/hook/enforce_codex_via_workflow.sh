#!/usr/bin/env bash
# Claude PreToolUse Bash hook. Allow = 0; refuse = 2, diagnostics on stderr.
# Registration is deferred until #364 merges; see doc/workflow.md.
# This is a cooperating-agent guard, not an operating-system sandbox.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-codex-via-workflow"

refuse() {
    hook_block "$1" 'Use pr-loop / milestone-fanout for implementation.'
}

check_command() {
    local sub lead tool path
    local cwd="$2" depth="${3:-0}"
    (( depth < 16 )) || refuse 'Wrapper nesting exceeds the static inspection limit.'
    local -a words
    while IFS= read -r sub; do
        lead="$(hook_timeout_lead "${sub}")"
        read -r -a words <<<"${sub#"${lead}"}"
        tool="$(hook_word "${words[0]:-}")"
        if [[ "${tool}" == cd ]]; then
            path="$(hook_word "${words[1]:-}")"
            [[ "${path}" == /* ]] || path="${cwd}/${path}"
            cwd="${path}"
            continue
        fi
        if [[ "${tool##*/}" == codex ]]; then
            refuse 'Main-loop codex execution must go through a Workflow.'
        fi
        path=""
        case "${tool##*/}" in
            bash|sh|dash|zsh|ksh|fish) path="$(hook_word "${words[1]:-}")" ;;
            *) [[ "${tool}" == */* || "${tool}" == *.sh ]] && path="${tool}" ;;
        esac
        if [[ -n "${path}" ]]; then
            [[ "${path}" == /* ]] || path="${cwd}/${path}"
            [[ -f "${path}" && -r "${path}" ]] || refuse 'Cannot read a wrapper script.'
            check_command "$(cat -- "${path}")" "${cwd}" "$((depth + 1))"
        fi
    done < <(hook_subcommands_raw "$1")
}

hook_read_input
check_command "$(hook_command)" "$(hook_field '.cwd')"
hook_allow
