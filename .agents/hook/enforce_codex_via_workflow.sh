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
    local sub lead tool
    local -a words
    while IFS= read -r sub; do
        lead="$(hook_timeout_lead "${sub}")"
        read -r -a words <<<"${sub#"${lead}"}"
        tool="$(hook_word "${words[0]:-}")"
        if [[ "${tool##*/}" == codex ]]; then
            refuse 'Main-loop codex execution must go through a Workflow.'
        fi
    done < <(hook_subcommands_raw "$1")
}

hook_read_input
check_command "$(hook_command)"
hook_allow
