#!/usr/bin/env bash
# Claude PreToolUse Bash hook: allow = 0, refuse = 2.
# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "enforce-codex-via-workflow"

refuse() {
    hook_block "$1" 'Use pr-loop / milestone-fanout for implementation.'
}

hook_read_input
if [[ "$(hook_command)" == *codex* ]]; then
    refuse 'Main-loop codex execution must go through a Workflow.'
fi
hook_allow
