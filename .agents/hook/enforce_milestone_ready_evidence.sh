#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Reuse the approval hook's closed command parser and body readers.
set -euo pipefail
_READY_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=enforce_milestone_gate_approval.sh
source "${_READY_HERE}/enforce_milestone_gate_approval.sh"
# shellcheck source=lib/ready_evidence.sh
source "${_READY_HERE}/lib/ready_evidence.sh"
hook_bootstrap enforce-milestone-ready-evidence
_AGENT="${1:-claude}"
case "${_AGENT}" in claude|codex|agy|gemini) ;; *) hook_block "unknown agent '${_AGENT}'" ;; esac

_judge_body() {
    approval_has_agent_marker "${_AGENT}" "$1" || hook_block "comments must start with [${_AGENT}]"
    ready_check_comment "$1"
}

main
