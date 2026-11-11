#!/usr/bin/env bash
# .agents/script/monitor/full-run.sh - is there a green full serial run of
# this exact commit? (issue #837; decision on #824 item 5)
#
# The Nightly workflow (.github/workflows/nightly.yml), dispatched with a
# `sha` input, runs the full serial suite on exactly that commit and titles
# the run `full-serial <sha>`. A milestone hand-over (.claude/workflows/
# milestone-handover.js) and a release tag require such a run to be green
# for their exact head. This script answers that question, fail closed:
# the NEWEST run with that title decides (a newer failure beats an older
# success), and only verified, complete successful jobs are green.
#
# Usage: full-run.sh --repo OWNER/REPO --sha SHA [--dispatch] [--wait SECONDS]
#                    [--exclude-run ID]
#   --exclude-run  ignore that run id (a run asking about its own sha, #851)
#   --dispatch  when no run of the sha exists or the newest one did not
#               succeed, start one (`gh workflow run nightly.yml --ref main
#               -f sha=SHA`) and report pending
#   --wait N    while the newest run is pending, poll every
#               WORKTOOL_FULL_RUN_POLL seconds (default 30) for at most N
#               seconds
# Stdout: one line `full-run: <sha> <status> <conclusion> run=<id>`, or
#         `full-run: <sha> none` when no run of the sha exists.
# Exit: 0 green, 1 not green (failed, none, or a query failed),
#       2 bad arguments (including a sha that is no commit of the repo,
#       #865), 3 pending (queued / in progress, or just started).

set -euo pipefail

REPO=""
SHA=""
DISPATCH=0
WAIT=0
EXCLUDE=""
POLL="${WORKTOOL_FULL_RUN_POLL:-30}"

_usage() {
    cat <<'EOF'
Usage: full-run.sh --repo OWNER/REPO --sha SHA [--dispatch] [--wait SECONDS]
                   [--exclude-run ID]
       full-run.sh --help
Exit 0 when the newest Nightly run titled `full-serial SHA` completed with
success and both architectures passed full-serial, isolation and checkout SHA
verification; 1 when it did not (or none exists, or a query failed); 2 on bad
arguments, including a SHA that is no commit of the repo; 3 while it is
pending. --dispatch starts a run when none is green or pending; --wait N
polls a pending run for at most N seconds; --exclude-run ID ignores that
run (a run asking about its own sha).
EOF
}

_arg_error() {
    printf 'full-run.sh: %s (see --help)\n' "$1" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || _arg_error "--repo requires OWNER/REPO"; REPO="$2"; shift ;;
        --sha) [[ $# -ge 2 ]] || _arg_error "--sha requires a commit"; SHA="$2"; shift ;;
        --dispatch) DISPATCH=1 ;;
        --exclude-run)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || _arg_error "--exclude-run requires a run id"
            EXCLUDE="$2"; shift ;;
        --wait)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || _arg_error "--wait requires a number of seconds"
            WAIT="$2"; shift ;;
        -h|--help) _usage; exit 0 ;;
        *) printf "full-run.sh: unknown option '%s' (see --help)\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
[[ "${REPO}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || _arg_error "--repo must be OWNER/REPO"
[[ "${SHA}" =~ ^[0-9a-f]{40}$ ]] || _arg_error "--sha must be a full 40-hex commit"
[[ "${POLL}" =~ ^[1-9][0-9]*$ ]] || _arg_error "WORKTOOL_FULL_RUN_POLL must be a positive integer"

# The sha must be a commit of the repo (#865): GitHub answering "no such
# commit" (HTTP 404 / 422) is a bad argument (2), before any run is listed
# or dispatched; a check that fails for any other reason is not green (1).
_commit_err=""
if ! _commit_err="$(gh api "repos/${REPO}/commits/${SHA}" --jq .sha 2>&1 >/dev/null)"; then
    if [[ "${_commit_err}" == *"(HTTP 404)"* || "${_commit_err}" == *"(HTTP 422)"* ]]; then
        _arg_error "${SHA} is not a commit of ${REPO}"
    fi
    printf 'full-run: %s query-failed\n' "${SHA}"
    printf 'full-run.sh: could not check that %s is a commit of %s: %s\n' "${SHA}" "${REPO}" "${_commit_err}" >&2
    exit 1
fi

TITLE="full-serial ${SHA}"

# Print the newest run titled TITLE as `status<TAB>conclusion<TAB>id`, or
# nothing when there is none. Returns 1 when the query fails.
_newest() {
    local _rows
    _rows="$(gh run list -R "${REPO}" --workflow nightly.yml -L 100 \
        --json displayTitle,status,conclusion,databaseId,createdAt \
        --jq '.[] | [.displayTitle, .status, .conclusion, (.databaseId | tostring), .createdAt] | @tsv')" \
        || return 1
    awk -F '\t' -v t="${TITLE}" -v x="${EXCLUDE}" '$1 == t && $4 != x' <<<"${_rows}" \
        | LC_ALL=C sort -t "$(printf '\t')" -k5,5 \
        | tail -n 1 \
        | awk -F '\t' '{ print $2 "\t" ($3 == "" ? "none" : $3) "\t" $4 }'
}

# A workflow success may contain only skipped jobs. Require each actual test
# job exactly once and its explicit checkout proof; dispatch headSha describes
# the workflow ref, so the successful proof step binds its tested input SHA.
_verified_jobs() {
    local _id="$1" _view _rc=0
    _view="$(gh run view "${_id}" -R "${REPO}" \
        --json displayTitle,headSha,event,status,conclusion,jobs)" || return 2
    jq -e --arg sha "${SHA}" --arg title "${TITLE}" '
        .displayTitle == $title and .status == "completed" and .conclusion == "success" and
        ((.event == "workflow_dispatch") or
         ((.event == "push" or .event == "schedule") and .headSha == $sha)) and
        (["full-serial (ubuntu-latest)", "full-serial (ubuntu-24.04-arm)",
          "isolation (ubuntu-latest)", "isolation (ubuntu-24.04-arm)"] as $required |
         .jobs as $jobs |
         all($required[]; . as $name |
             [$jobs[] | select(.name == $name)] as $matching |
             ($matching | length) == 1 and
             all($matching[];
                 .status == "completed" and .conclusion == "success" and
                 ([.steps[] | select(.name == ("Verify checkout " + $sha))] as $proof |
                  ($proof | length) == 1 and
                  all($proof[]; .status == "completed" and .conclusion == "success")))))
    ' <<<"${_view}" >/dev/null || _rc=$?
    [[ "${_rc}" -le 1 ]] || return 2
    return "${_rc}"
}

# Judge the newest run once: print the line, return 0 / 1 / 3.
_judge() {
    local _row _status _concl _id _verified_rc
    if ! _row="$(_newest)"; then
        printf 'full-run: %s query-failed\n' "${SHA}"
        printf 'full-run.sh: could not list the Nightly runs of %s\n' "${REPO}" >&2
        return 1
    fi
    if [[ -z "${_row}" ]]; then
        printf 'full-run: %s none\n' "${SHA}"
        return 1
    fi
    IFS=$'\t' read -r _status _concl _id <<<"${_row}"
    if [[ "${_status}" != completed ]]; then
        printf 'full-run: %s %s run=%s\n' "${SHA}" "${_status}" "${_id}"
        return 3
    fi
    if [[ "${_concl}" == success ]]; then
        _verified_rc=0
        _verified_jobs "${_id}" || _verified_rc=$?
        if [[ "${_verified_rc}" == 2 ]]; then
            printf 'full-run: %s query-failed run=%s\n' "${SHA}" "${_id}"
            printf 'full-run.sh: could not query Nightly jobs for run %s\n' "${_id}" >&2
            return 1
        fi
        if [[ "${_verified_rc}" != 0 ]]; then
            printf 'full-run: %s completed unverified run=%s\n' "${SHA}" "${_id}"
            return 1
        fi
    fi
    printf 'full-run: %s completed %s run=%s\n' "${SHA}" "${_concl:-none}" "${_id}"
    [[ "${_concl}" == success ]] || return 1
    return 0
}

rc=0
line="$(_judge)" || rc=$?
if [[ "${DISPATCH}" == 1 && "${rc}" -eq 1 && "${line}" != *query-failed* ]]; then
    gh workflow run nightly.yml -R "${REPO}" --ref main -f "sha=${SHA}" >&2 \
        || { printf '%s\n' "${line}"; printf 'full-run.sh: could not dispatch Nightly for %s\n' "${SHA}" >&2; exit 1; }
    printf 'full-run: %s dispatched\n' "${SHA}"
    exit 3
fi
deadline=$(( SECONDS + WAIT ))
while [[ "${rc}" -eq 3 ]] && (( SECONDS < deadline )); do
    sleep "${POLL}"
    rc=0
    line="$(_judge)" || rc=$?
done
printf '%s\n' "${line}"
exit "${rc}"
