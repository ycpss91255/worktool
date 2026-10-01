#!/usr/bin/env bash
# Adapt agy input and serialize a shared guard rejection as its deny JSON.
set -euo pipefail
_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_rc=0
_result="$(jq -c '{tool_name:"Bash", cwd:.toolCall.args.Cwd,
    tool_input:{command:.toolCall.args.CommandLine}}' |
    "${_HERE}/enforce_milestone_gate_approval.sh" agy 2>&1)" || _rc=$?
if [[ "${_rc}" -ne 0 ]]; then
    jq -n --arg reason "${_result:-agent comment guard could not read this payload}" \
        '{decision:"deny", reason:$reason}'
fi
# Silence on pass preserves agy's existing permission checks.
