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

# Identity contract: Claude Code supplies agent_id on subagent tool calls.
# Source checked 2026-10-02: https://code.claude.com/docs/en/hooks#common-input-fields
# Accept any subagent (including Workflow agents), as decided in PR #372.
# No transcript or environment markers are consulted. Empty/invalid IDs
# grant no exception; this cooperating-agent guard cannot authenticate input.
subagent_call() {
    jq -e '.agent_id | type == "string" and length > 0'         <<<"${HOOK_INPUT}" >/dev/null 2>&1
}

hook_read_input
subagent_call && hook_allow
if [[ "$(hook_command)" == *codex* ]]; then
    refuse 'Main-loop codex execution must go through a Workflow.'
fi
hook_allow
