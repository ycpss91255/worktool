#!/usr/bin/env bash
# Adapt agy run_command to the shared Bash comment guard.
set -euo pipefail
_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
jq -c '.tool_name = "Bash" | .tool_input.command = (.tool_input.CommandLine // .tool_input.command)' |
    "${_HERE}/enforce_milestone_gate_approval.sh" agy
