#!/usr/bin/env bash
# Adapt Gemini BeforeTool to the shared Bash comment guard (exit 2 blocks).
set -euo pipefail
_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
jq -c '.tool_name = "Bash"' |
    "${_HERE}/enforce_milestone_gate_approval.sh" gemini
