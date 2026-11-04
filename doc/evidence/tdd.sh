#!/usr/bin/env bash
# tdd.sh - prove each listed PR body shows RED evidence before GREEN evidence.
#
# Asset of doc/acceptance.md item 2.2. The checklist line is just
# `bash doc/evidence/tdd.sh`, so the logic lives here under version control
# instead of inside the document: nothing an operator's shell, executor or
# copy/paste does to the checklist text can alter what is checked.
#
# For every PR number given (default: the M3 sub-issue PRs) the body must
# contain a non-empty fenced block whose introducing line (one of the five
# lines above it, outside any fence) says RED, and a LATER non-empty fenced
# block introduced the same way by GREEN. Only presence and ordering are
# proven; the content itself is read by a human.
#
# Exit 0 when every PR passes; 1 when any PR fails or any gh query fails.
# Exit-code-contract script, so `set -uo pipefail` (init_ubuntu ADR-0007):
# a gh failure is reported per PR and does not abort the remaining ones.
set -uo pipefail

REPO=${REPO:-ycpss91255/worktool}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)

PRS=("$@")
if [[ "${#PRS[@]}" -eq 0 ]]; then
    PRS=(152 153 154 155 156 165 166 167 168 169)
fi

rc=0
for n in "${PRS[@]}"; do
    body=$(gh pr view "${n}" --repo "${REPO}" --json body --jq .body) || {
        printf '#%s evidence=gh-failed\n' "${n}"
        rc=1
        continue
    }
    out=$(printf '%s\n' "${body}" | tr -d '\r' | awk -f "${HERE}/tdd.awk") || rc=1
    printf '#%s %s\n' "${n}" "${out}"
done
exit "${rc}"
