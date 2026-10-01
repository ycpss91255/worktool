#!/usr/bin/env bash
# Adapt the measured agy run_command payload to the shared Bash guard.
set -euo pipefail
_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
jq -c '{tool_name:"Bash", cwd:.toolCall.args.Cwd,
    tool_input:{command:.toolCall.args.CommandLine}}' |
    "${_HERE}/enforce_milestone_gate_approval.sh" agy
