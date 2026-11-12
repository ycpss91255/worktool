#!/usr/bin/env bash
# tdd.sh - prove each listed PR body shows RED evidence before GREEN evidence.
#
# Asset of doc/acceptance.md item 2.2. The acceptance entry is
# `just verify gate 2.2`, which calls this script and checks the complete
# ordered result set. The checker lives here under version control rather
# than inside the document. Direct invocation also accepts selected PRs.
#
# For every PR number given (default: the M3 sub-issue PRs) the body must
# contain a non-empty fenced block whose introducing line (one of the five
# lines above it, outside any fence) says RED, and a LATER non-empty fenced
# block introduced the same way by GREEN. Only presence and ordering are
# proven; the content itself is read by a human.
#
# Exit 0 when every PR passes; 1 when any PR fails or any gh query fails.
# A gh failure is reported per PR and does not abort the remaining ones.
set -euo pipefail

readonly REPO=ycpss91255/worktool
HERE=$(cd -- "$(dirname -- "$0")" && pwd)

PRS=("$@")
if [[ "${#PRS[@]}" -eq 0 ]]; then
    PRS=(152 153 154 155 156 165 166 167 168 169)
fi

rc=0
for n in "${PRS[@]}"; do
    body=$(gh pr view "${n}" -R "${REPO}" --json body --jq .body) || {
        printf '#%s evidence=gh-failed\n' "${n}"
        rc=1
        continue
    }
    out=$(printf '%s\n' "${body}" | tr -d '\r' | awk -f "${HERE}/tdd.awk") || rc=1
    printf '#%s %s\n' "${n}" "${out}"
done
exit "${rc}"
