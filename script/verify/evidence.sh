#!/usr/bin/env bash
# evidence.sh - run the M3 acceptance items that query external evidence.
#
# Items 6.1 / 6.2 / 6.3 of the M3 section of doc/acceptance.md used to live
# in the document as copy-and-paste bash blocks. A block in a document is
# only as good as the last person who pasted it: it cannot be linted, it
# cannot be tested, and a subtly broken one reads as a pass. This script is
# where that logic lives now - the same move doc/evidence/tdd.sh made for
# item 2.2 - so the document keeps the prose and the expected output while
# the shell logic is linted by `just test lint` and pinned by
# test/unit/verify_evidence_spec.bats.
#
# The output is unchanged on purpose: every check prints, on STDOUT, exactly
# the lines the document shows (including the trailing `rc=<n>`), so the
# maintainer compares what they always compared. Diagnostics go to STDERR.
#
#   script/verify/evidence.sh            # every default-group item, in order
#   script/verify/evidence.sh 6.1        # one item
#   script/verify/evidence.sh 6.1 6.3    # several, in the order given
#   script/verify/evidence.sh --list     # the item table
#   script/verify/evidence.sh --help     # usage
#
# THE CONTRACT: no failure may read as a pass.
#   - Every external command's own exit status is read BEFORE its output is
#     used. A `gh` that prints plausible JSON and exits 1, a `jq` that
#     prints `7` and exits 1, a `grep` that prints matches and exits 1 - all
#     of them are failures here, never data (_gh_capture / _jq_capture /
#     _grep_capture).
#   - No counter is read out of a pipeline. Under `pipefail` a pipeline
#     reports the RIGHTMOST non-zero status, so a broken first stage is
#     indistinguishable from `grep -c` reporting zero matches. Counting
#     therefore happens in the shell, over text that was already captured
#     and status-checked (_lines_into).
#   - Every count is distinguished from its degenerate case: an empty answer
#     from a command that exited 0 is reported as `empty-checks` /
#     `empty-body` / `no-comments` / `no-codex`, never as the number 0.
#   - A check that cannot run here (a missing tool) says so and fails. There
#     is no skip: `_require_tools` turns a missing `gh` / `jq` / `grep` /
#     `timeout` into an error and a non-zero exit.
#   - Every network-facing command runs under `timeout`, so a hung query
#     fails (124) instead of hanging the acceptance run.
#
# GROUPS. Each item declares a group in EVIDENCE_ITEM_GROUP:
#   gh       reads external evidence through `gh`; safe to run anywhere.
#   realbox  touches THIS machine: it creates and removes a real distrobox
#            and edits the caller's real config files. Refused unless
#            --allow-realbox is given, refused when a box of that name
#            already exists, ownership claimed before anything is created,
#            and restored plus cleaned up on EXIT INT TERM HUP
#            (_realbox_begin / _realbox_backup / _realbox_trap). Items 6.1 -
#            6.3 are all group `gh`; the realbox guards are the contract the
#            real-machine items (M3 5.1 / 5.2) plug into, and the dispatcher
#            enforces them for any item declared realbox.
#
# EXIT CODES.
#   0  every selected item passed
#   1  an item failed, or it could not run here (missing tool, unusable
#      environment) - a check that cannot run is a failure, not a skip
#   2  the caller was refused before any check ran: unknown option, unknown
#      item, a realbox item without --allow-realbox, or a pre-existing box
#
# Exit-code-contract script: default guards are `set -uo pipefail` (no `-e`),
# per doc/adr/0007 - every status is read and acted on explicitly below.

# shellcheck source-path=SCRIPTDIR/../../lib
set -uo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
LIB_DIR="${REPO_ROOT}/lib"

# shellcheck source=log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=manifest.sh
source "${LIB_DIR}/manifest.sh"

# --- Constants ---------------------------------------------------------------
# The repository every query is scoped to. Not overridable: an acceptance
# run that reads another repository's evidence proves nothing about this one.
EVIDENCE_REPO="ycpss91255/worktool"

# Seconds any single network-facing query may take before it is killed.
EVIDENCE_GH_TIMEOUT="${EVIDENCE_GH_TIMEOUT:-120}"
# Seconds any single local box query may take.
EVIDENCE_BOX_TIMEOUT="${EVIDENCE_BOX_TIMEOUT:-60}"

# The items this script implements, in the order a bare run executes them.
EVIDENCE_ITEMS=(6.1 6.2 6.3)

# item id -> group. The dispatcher refuses an id that is not in this table,
# so a typo can never run "nothing" and report success.
declare -A EVIDENCE_ITEM_GROUP=(
    [6.1]=gh
    [6.2]=gh
    [6.3]=gh
)

# --- Usage -------------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: evidence.sh [--allow-realbox] [--list] [ITEM...]

Run the M3 acceptance items that check external evidence (doc/acceptance.md).
With no ITEM, every default-group item runs in order and the run stops at the
first failure. Each item prints exactly the lines the document shows, ending
with `rc=<n>`.

Items:
  6.1   one sub-issue one PR, two-architecture CI: every PR has checks, all
        pass, exactly one distinct `Closes #`
  6.2   decisions and research recorded on the issues, as concrete findings
  6.3   codex verdict chain: mergeable PRs, blocked PRs, their follow-up
        issues and the PRs that close them

Options:
  --allow-realbox  Permit items in group `realbox`, which create and remove a
                   real box on this machine and edit real config files. They
                   refuse to run without this flag, refuse when a box of that
                   name already exists, and clean up on EXIT INT TERM HUP.
  --list           List the items and their groups, then exit.
  -h, --help       Show this help and exit.

Environment:
  EVIDENCE_GH_TIMEOUT   seconds per gh query (default 120)
  EVIDENCE_BOX_TIMEOUT  seconds per local box query (default 60)

Exit: 0 all selected items passed; 1 an item failed or could not run here
(missing tool, unusable environment - never a silent skip); 2 the caller was
refused before any check ran.
EOF
}

_usage_error() {
    printf 'evidence.sh: %s (see --help)\n' "$1" >&2
}

# --- Guarded capture helpers -------------------------------------------------
# The three helpers below exist for one reason: a command's exit status must
# be read BEFORE its output is used. Every false pass this script was written
# to remove has the same shape - output that looks plausible coming out of a
# command that failed.

# True when $1 is a plain non-negative integer. Anything a counter is
# compared against goes through this first: `[ "$t" -gt 0 ]` on the word
# `null` is a shell error, not a verdict.
_is_count() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Refuse - never skip - when a tool an item needs is missing. Returns 1 and
# names every missing tool.
_require_tools() {
    local _tool _missing=0
    for _tool in "$@"; do
        command -v "${_tool}" >/dev/null 2>&1 && continue
        log_error "evidence.sh: ${_tool} not found on PATH - this check cannot run here (a check that cannot run is a failure, not a skip)"
        _missing=1
    done
    return "${_missing}"
}

# Split text $2 into the array named by $1, dropping empty lines. Pure shell:
# counting `${#array[@]}` afterwards cannot be confused by a pipeline stage
# that failed, and it tells the empty string apart from a single blank line
# (`wc -l` over a here-string cannot).
_lines_into() {
    local -n _lines_ref="$1"
    local _text="$2" _line
    _lines_ref=()
    [[ -n "${_text}" ]] || return 0
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] || continue
        _lines_ref+=("${_line}")
    done <<<"${_text}"
    return 0
}

# Run `gh "$@"` under a timeout, storing stdout in the variable named by $1.
# Returns 0 only when gh itself exited 0; a non-zero gh (expired token, API
# error, or timeout's 124) returns 1 no matter how plausible its stdout was.
# gh's stderr is left alone so the maintainer sees the reason.
_gh_capture() {
    local -n _gh_ref="$1"
    shift
    local _stdout _rc
    _stdout="$(timeout "${EVIDENCE_GH_TIMEOUT}" gh "$@")"
    _rc=$?
    _gh_ref="${_stdout}"
    [[ "${_rc}" -eq 0 ]] || return 1
    return 0
}

# Run `jq "${@:3}"` over the JSON in $2, storing stdout in the variable named
# by $1. Returns 0 only when jq itself exited 0.
_jq_capture() {
    local -n _jq_ref="$1"
    local _json="$2"
    shift 2
    local _stdout _rc
    _stdout="$(jq "$@" <<<"${_json}")"
    _rc=$?
    _jq_ref="${_stdout}"
    [[ "${_rc}" -eq 0 ]] || return 1
    return 0
}

# Run `grep "${@:3}"` over the text in $2, storing the matching lines in the
# variable named by $1. Three outcomes, deliberately kept apart:
#   0  grep matched
#   1  grep matched nothing AND printed nothing - the honest empty result
#   2  grep failed, or contradicted itself by printing lines while exiting
#      non-zero: the false-pass shape this script exists to remove
# Never used with -c: `grep -c` prints 0 and exits 1 on no match, which is
# exactly the ambiguity the callers must not inherit. Counting is done by
# _lines_into over the captured matches instead.
_grep_capture() {
    local -n _grep_ref="$1"
    local _text="$2"
    shift 2
    local _stdout _rc
    _stdout="$(grep "$@" <<<"${_text}")"
    _rc=$?
    _grep_ref="${_stdout}"
    [[ "${_rc}" -eq 0 ]] && return 0
    [[ "${_rc}" -eq 1 && -z "${_stdout}" ]] && return 1
    return 2
}

# --- Item 6.1 ----------------------------------------------------------------
# One sub-issue one PR, two-architecture CI: each PR has checks, none of them
# outside the pass bucket, exactly one `Closes #` line, and - from #153 on -
# an equal, non-zero number of amd64 and arm64 checks. The ten issue
# references must be ten distinct ones.
#
# "Two architectures" is a claim about two DISJOINT SETS of checks, so that is
# what is counted. Two independent substring tests over the same array do not
# make it: one check named `lint (ubuntu-latest, ubuntu-24.04-arm)` satisfies
# both of them, and a PR with that single check would report `amd=1 arm=1` and
# pass while only one job ever ran. The names are therefore collected per
# architecture, de-duplicated, and required to be equal in number AND to share
# no name at all (`both=0`).

_ITEM_6_1_PRS=(152 153 154 155 156 165 166 167 168 169)
# The one PR that predates the arm64 runner; from #153 on both architectures
# must be present in equal numbers.
_ITEM_6_1_NO_ARM_PR=152
_ITEM_6_1_EXPECT_DISTINCT=10

item_6_1() {
    if ! _require_tools timeout gh jq grep; then
        printf 'rc=1\n'
        return 1
    fi
    local _fail=0 _pr _checks _body _type _total _nonpass _amd _arm _both
    local _matches _rc _closes _issue _match _number _amd_names _arm_names _name
    local -a _match_lines=() _amd_lines=() _arm_lines=()
    declare -A _distinct=() _amd_set=() _arm_set=()

    for _pr in "${_ITEM_6_1_PRS[@]}"; do
        if ! _gh_capture _checks pr checks "${_pr}" --repo "${EVIDENCE_REPO}" \
            --json name,bucket; then
            printf '#%s gh-failed\n' "${_pr}"
            _fail=1
            continue
        fi
        # gh exited 0 and said nothing. That is not "zero checks", it is no
        # answer at all, and `length` over it would read as a plain 0.
        if [[ -z "${_checks}" ]]; then
            printf '#%s empty-checks\n' "${_pr}"
            _fail=1
            continue
        fi
        if ! _jq_capture _type "${_checks}" -r 'type'; then
            printf '#%s jq-failed\n' "${_pr}"
            _fail=1
            continue
        fi
        if [[ "${_type}" != "array" ]]; then
            printf '#%s not-a-check-list\n' "${_pr}"
            _fail=1
            continue
        fi
        if ! _gh_capture _body pr view "${_pr}" --repo "${EVIDENCE_REPO}" \
            --json body --jq .body; then
            printf '#%s gh-failed\n' "${_pr}"
            _fail=1
            continue
        fi
        # A body that never arrived must not be counted as a body with zero
        # `Closes #` lines: both would print closes=0 otherwise.
        if [[ -z "${_body}" ]]; then
            printf '#%s empty-body\n' "${_pr}"
            _fail=1
            continue
        fi

        if ! _jq_capture _total "${_checks}" 'length' \
            || ! _jq_capture _nonpass "${_checks}" '[.[] | select(.bucket != "pass")] | length' \
            || ! _jq_capture _amd_names "${_checks}" -r '.[].name | select(test("ubuntu-latest"))' \
            || ! _jq_capture _arm_names "${_checks}" -r '.[].name | select(test("ubuntu-24.04-arm"))'; then
            printf '#%s jq-failed\n' "${_pr}"
            _fail=1
            continue
        fi
        if ! _is_count "${_total}" || ! _is_count "${_nonpass}"; then
            printf '#%s bad-counts\n' "${_pr}"
            _fail=1
            continue
        fi

        # Distinct NAMES per architecture, and the overlap between the two
        # sets. `amd` and `arm` are the sizes of two sets; `both` is how many
        # names are in each of them, which a genuine two-architecture matrix
        # answers with 0.
        _lines_into _amd_lines "${_amd_names}"
        _lines_into _arm_lines "${_arm_names}"
        _amd_set=()
        _arm_set=()
        if [[ "${#_amd_lines[@]}" -gt 0 ]]; then
            for _name in "${_amd_lines[@]}"; do _amd_set["${_name}"]=1; done
        fi
        if [[ "${#_arm_lines[@]}" -gt 0 ]]; then
            for _name in "${_arm_lines[@]}"; do _arm_set["${_name}"]=1; done
        fi
        _amd="${#_amd_set[@]}"
        _arm="${#_arm_set[@]}"
        _both=0
        if [[ "${_amd}" -gt 0 ]]; then
            for _name in "${!_amd_set[@]}"; do
                [[ -n "${_arm_set["${_name}"]:-}" ]] && _both=$((_both + 1))
            done
        fi

        _grep_capture _matches "${_body}" -o '^Closes #[0-9][0-9]*'
        _rc=$?
        if [[ "${_rc}" -eq 2 ]]; then
            printf '#%s grep-failed\n' "${_pr}"
            _fail=1
            continue
        fi
        _lines_into _match_lines "${_matches}"
        _closes="${#_match_lines[@]}"
        _issue=""
        for _match in "${_match_lines[@]}"; do
            _number="${_match##*#}"
            if ! _is_count "${_number}"; then
                _issue=""
                break
            fi
            _issue="${_issue:+${_issue},}#${_number}"
        done

        printf '#%s total=%s nonpass=%s amd=%s arm=%s both=%s closes=%s issue=%s\n' \
            "${_pr}" "${_total}" "${_nonpass}" "${_amd}" "${_arm}" "${_both}" \
            "${_closes}" "${_issue}"

        [[ -z "${_issue}" ]] || _distinct["${_issue}"]=1
        [[ "${_total}" -gt 0 && "${_nonpass}" -eq 0 \
            && "${_closes}" -eq 1 && -n "${_issue}" ]] || _fail=1
        if [[ "${_pr}" != "${_ITEM_6_1_NO_ARM_PR}" ]]; then
            [[ "${_amd}" -gt 0 && "${_amd}" -eq "${_arm}" && "${_both}" -eq 0 ]] || _fail=1
        fi
    done

    printf 'distinct=%s\n' "${#_distinct[@]}"
    [[ "${#_distinct[@]}" -eq "${_ITEM_6_1_EXPECT_DISTINCT}" ]] || _fail=1
    printf 'rc=%s\n' "${_fail}"
    return "${_fail}"
}

# --- Item 6.2 ----------------------------------------------------------------
# Decisions and research live on the issues and are concrete: each [claude]
# comment thread must carry the stated conclusion. A cell is 1 (found), 0
# (the thread exists but does not say it), `no-comments` (there is no
# [claude] comment at all) or `gh-failed` (the query itself failed). Only 1
# passes, and the three failure words stay apart so a broken query can never
# be read as "the conclusion is missing".

_ITEM_6_2_ISSUES=(22 148 21)

# `<label>|<BRE pattern>` per issue, in print order. An unknown issue returns
# 1 and prints nothing, so a typo cannot silently produce an empty - and
# therefore vacuously passing - row set.
_item_6_2_patterns() {
    case "$1" in
        22)
            printf '%s\n' \
                'median-ms|median=[0-9][0-9]*\(\.[0-9][0-9]*\)\? ms' \
                'runc|維持 docker + 預設 runc'
            ;;
        148)
            printf '%s\n' \
                'lts-only|只用 LTS' \
                'arm-runner|ubuntu-24.04-arm'
            ;;
        21)
            printf '%s\n' \
                'default-enter|預設 = 直接進盒' \
                'log|印 log'
            ;;
        *) return 1 ;;
    esac
}

item_6_2() {
    if ! _require_tools timeout gh grep; then
        printf 'rc=1\n'
        return 1
    fi
    local _fail=0 _issue _comments _rows _status _row _label _pattern _cell
    local _line _hits _rc
    local -a _row_lines=()

    for _issue in "${_ITEM_6_2_ISSUES[@]}"; do
        if ! _rows="$(_item_6_2_patterns "${_issue}")"; then
            log_error "evidence.sh: no patterns declared for issue #${_issue}"
            printf 'rc=1\n'
            return 1
        fi
        _lines_into _row_lines "${_rows}"
        if [[ "${#_row_lines[@]}" -eq 0 ]]; then
            log_error "evidence.sh: issue #${_issue} declares zero patterns"
            printf 'rc=1\n'
            return 1
        fi

        if ! _gh_capture _comments api \
            "repos/${EVIDENCE_REPO}/issues/${_issue}/comments" --paginate \
            --jq '.[].body | select(startswith("[claude]"))'; then
            _status=gh-failed
        elif [[ -z "${_comments}" ]]; then
            # No [claude] comment at all. Reporting 0 here would say "the
            # decision is not recorded"; this says "there is nothing to read".
            _status=no-comments
        else
            _status=ok
        fi

        _line=""
        for _row in "${_row_lines[@]}"; do
            _label="${_row%%|*}"
            _pattern="${_row#*|}"
            if [[ "${_status}" != ok ]]; then
                _cell="${_status}"
                _fail=1
            else
                _grep_capture _hits "${_comments}" -e "${_pattern}"
                _rc=$?
                case "${_rc}" in
                    0) _cell=1 ;;
                    1)
                        _cell=0
                        _fail=1
                        ;;
                    *)
                        _cell=grep-failed
                        _fail=1
                        ;;
                esac
            fi
            _line="${_line} ${_label}:${_cell}"
        done
        printf '#%s%s\n' "${_issue}" "${_line}"
    done

    printf 'rc=%s\n' "${_fail}"
    return "${_fail}"
}

# --- Item 6.3 ----------------------------------------------------------------
# The codex verdict chain. Six PRs must end on a "mergeable" verdict; the
# four that were re-reviewed after the quota came back must end on "blocked",
# each pointing at exactly one follow-up issue, which exactly one merged PR
# closes, and that PR must itself end on "mergeable".
#
# "Each" is a claim about FOUR follow-ups and FOUR fix PRs, so the tracking is
# kept across the whole item, not reset per blocked PR. Reset per PR, one
# issue and one PR could answer for all four: four identical rows, each
# internally consistent, would print `ok` four times while three of the four
# blockers were never recorded anywhere. The two sets are therefore collected
# over the whole item and their sizes printed and compared.

_ITEM_6_3_MERGEABLE_PRS=(156 165 166 167 168 169)
_ITEM_6_3_BLOCKED_PRS=(152 153 154 155)

# Last [codex] verdict line of issue/PR $1 into the variable named by $2.
# Return codes are kept apart on purpose:
#   0  a verdict line was read
#   1  there are [codex] comments but none carries a verdict line
#   2  the query itself failed (or grep contradicted itself)
#   3  there is no [codex] comment at all
_item_6_3_verdict() {
    local -n _verdict_ref="$2"
    local _body _line _rc
    _verdict_ref=""
    if ! _gh_capture _body api \
        "repos/${EVIDENCE_REPO}/issues/$1/comments" --paginate \
        --jq '[.[].body | select(startswith("[codex]"))] | last'; then
        return 2
    fi
    # `last` over an empty array is the four characters `null`, which is not
    # a review: a PR nobody reviewed must not read like one whose review says
    # nothing.
    if [[ -z "${_body}" || "${_body}" == "null" ]]; then
        return 3
    fi
    _grep_capture _line "${_body}" -E '^(可合併|不可合併|mergeable|blocked)'
    _rc=$?
    [[ "${_rc}" -eq 2 ]] && return 2
    [[ "${_rc}" -eq 1 ]] && return 1
    # The verdict is the LAST such line (a comment may quote earlier ones).
    # Taken in the shell, so no `tail` can swallow an upstream failure.
    _verdict_ref="${_line##*$'\n'}"
    return 0
}

# Translate a verdict line ($1) plus the status _item_6_3_verdict returned
# ($2) into the one word the report prints. Every non-mergeable outcome has
# its own word, so a failed query is never read as a verdict.
_item_6_3_word() {
    case "$2:$1" in
        0:可合併* | 0:mergeable*) printf 'mergeable\n' ;;
        0:不可合併* | 0:blocked*) printf 'blocked\n' ;;
        2:*) printf 'gh-failed\n' ;;
        3:*) printf 'no-codex\n' ;;
        *) printf 'NOT\n' ;;
    esac
}

item_6_3() {
    if ! _require_tools timeout gh grep; then
        printf 'rc=1\n'
        return 1
    fi
    local _fail=0 _pr _verdict _rc _word _claude _follow _matches _match
    local _number _issue _prs _fix_pr _orig _fixed _ok
    local -a _match_lines=() _pr_lines=()
    declare -A _follow_seen=() _follow_all=() _fix_all=()

    for _pr in "${_ITEM_6_3_MERGEABLE_PRS[@]}"; do
        _item_6_3_verdict "${_pr}" _verdict
        _rc=$?
        _word="$(_item_6_3_word "${_verdict}" "${_rc}")"
        printf '#%s %s\n' "${_pr}" "${_word}"
        [[ "${_word}" == mergeable ]] || _fail=1
    done

    for _pr in "${_ITEM_6_3_BLOCKED_PRS[@]}"; do
        if ! _gh_capture _claude api \
            "repos/${EVIDENCE_REPO}/issues/${_pr}/comments" --paginate \
            --jq '.[].body | select(startswith("[claude]"))'; then
            printf '#%s gh-failed\n' "${_pr}"
            _fail=1
            continue
        fi
        if [[ -z "${_claude}" ]]; then
            printf '#%s no-claude-comment\n' "${_pr}"
            _fail=1
            continue
        fi
        _grep_capture _matches "${_claude}" -o 'follow-up issue #[0-9][0-9]*'
        _rc=$?
        if [[ "${_rc}" -eq 2 ]]; then
            printf '#%s grep-failed\n' "${_pr}"
            _fail=1
            continue
        fi
        _lines_into _match_lines "${_matches}"
        _follow_seen=()
        _follow=""
        for _match in "${_match_lines[@]}"; do
            _number="${_match##*#}"
            _is_count "${_number}" || continue
            _follow_seen["${_number}"]=1
            [[ -n "${_follow}" ]] || _follow="${_number}"
        done
        if [[ "${#_follow_seen[@]}" -eq 0 ]]; then
            printf '#%s no-follow-up\n' "${_pr}"
            _fail=1
            continue
        fi

        if ! _gh_capture _prs pr list --repo "${EVIDENCE_REPO}" \
            --state merged --search "Closes #${_follow} in:body" \
            --json number,body \
            --jq ".[] | select(.body | test(\"^Closes #${_follow}\\\\b\"; \"m\")) | .number"; then
            printf '#%s gh-failed\n' "${_pr}"
            _fail=1
            continue
        fi
        _lines_into _pr_lines "${_prs}"
        if [[ "${#_pr_lines[@]}" -eq 0 ]]; then
            printf '#%s no-fix-pr\n' "${_pr}"
            _fail=1
            continue
        fi
        _fix_pr="${_pr_lines[0]}"
        if ! _is_count "${_fix_pr}"; then
            printf '#%s bad-fix-pr\n' "${_pr}"
            _fail=1
            continue
        fi

        _item_6_3_verdict "${_pr}" _verdict
        _rc=$?
        _orig="$(_item_6_3_word "${_verdict}" "${_rc}")"
        _item_6_3_verdict "${_fix_pr}" _verdict
        _rc=$?
        _fixed="$(_item_6_3_word "${_verdict}" "${_rc}")"

        _issue="${_follow}"
        _follow_all["${_follow}"]=1
        _fix_all["${_fix_pr}"]=1
        _ok=BAD
        if [[ "${_orig}" == blocked && "${_fixed}" == mergeable \
            && "${#_follow_seen[@]}" -eq 1 && "${#_pr_lines[@]}" -eq 1 ]]; then
            _ok=ok
        else
            _fail=1
        fi
        printf '#%s %s -> follow-up #%s fixed-by PR #%s (closes #%s, %s) %s\n' \
            "${_pr}" "${_orig}" "${_issue}" "${_fix_pr}" "${_issue}" \
            "${_fixed}" "${_ok}"
    done

    # One follow-up issue and one fix PR cannot answer for four blocked PRs.
    printf 'distinct-follow-ups=%s distinct-fix-prs=%s\n' \
        "${#_follow_all[@]}" "${#_fix_all[@]}"
    if [[ "${#_follow_all[@]}" -ne "${#_ITEM_6_3_BLOCKED_PRS[@]}" \
        || "${#_fix_all[@]}" -ne "${#_ITEM_6_3_BLOCKED_PRS[@]}" ]]; then
        log_error "evidence.sh: the ${#_ITEM_6_3_BLOCKED_PRS[@]} blocked PR(s) name ${#_follow_all[@]} distinct follow-up issue(s) and ${#_fix_all[@]} distinct fix PR(s); each blocked PR must have its own"
        _fail=1
    fi

    printf 'rc=%s\n' "${_fail}"
    return "${_fail}"
}

# --- Real-machine (realbox) group --------------------------------------------
# Guards every item that creates or removes a real box on the caller's
# machine. Items 6.1 - 6.3 do not, but the dispatcher routes any item
# declared `realbox` through _realbox_require_optin, and such an item calls
# _realbox_begin before it creates anything.

EVIDENCE_ALLOW_REALBOX=0
EVIDENCE_REALBOX_BOX="$(manifest_name "${REPO_ROOT}/box/dev.ini")" || exit 1
EVIDENCE_REALBOX_OWNED=0
EVIDENCE_REALBOX_WORKDIR=""
EVIDENCE_REALBOX_CLAIM=""
# Records of backed-up paths, one per entry, fields separated by US (0x1f)
# because a path may legitimately contain any printable character:
#   <type>US<path>US<slot>US<link target>US<target slot>
EVIDENCE_REALBOX_BACKUPS=()
EVIDENCE_REALBOX_US=$'\x1f'

_realbox_require_optin() {
    [[ "${EVIDENCE_ALLOW_REALBOX}" -eq 1 ]] && return 0
    log_error "evidence.sh: item $1 is in group realbox: it creates and removes a real '${EVIDENCE_REALBOX_BOX}' box on this machine and edits real config files. Re-run with --allow-realbox to permit that."
    return 2
}

# 0 = a box named $1 exists, 1 = it does not, 2 = cannot tell. Never guesses:
# a failed or empty listing is "cannot tell", and the caller refuses to
# create or delete anything on a 2.
_realbox_box_exists() {
    local _out _rc
    _out="$(timeout "${EVIDENCE_BOX_TIMEOUT}" distrobox list 2>/dev/null)"
    _rc=$?
    [[ "${_rc}" -eq 0 ]] || return 2
    # `distrobox list` always prints its header row, so no output at all
    # means the command did not do what it says, not "no boxes".
    [[ -n "${_out}" ]] || return 2
    awk -F'|' -v want="$1" '
        NR > 1 { n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n); if (n == want) f = 1 }
        END { exit(f ? 0 : 1) }' <<<"${_out}"
    _rc=$?
    case "${_rc}" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# Everything a realbox item must do BEFORE it can create anything: opt-in,
# tools, refuse a pre-existing box, a private work directory, the ownership
# claim, and the cleanup trap. Returns 2 when the caller is refused, 1 when
# the environment cannot support the item, 0 when the item may proceed.
_realbox_begin() {
    local _item="$1" _rc
    _realbox_require_optin "${_item}" || return 2
    _require_tools timeout distrobox awk mktemp cp rm || return 1

    _realbox_box_exists "${EVIDENCE_REALBOX_BOX}"
    _rc=$?
    case "${_rc}" in
        0)
            log_error "evidence.sh: a distrobox named '${EVIDENCE_REALBOX_BOX}' already exists - refusing. This item deletes the box it creates, so rename or remove yours by hand first."
            return 2
            ;;
        2)
            log_error "evidence.sh: distrobox list failed - cannot tell whether '${EVIDENCE_REALBOX_BOX}' exists; refusing to create or delete anything."
            return 2
            ;;
    esac
    printf 'preexisting-dev=0\n'

    EVIDENCE_REALBOX_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/wt-evidence.XXXXXXXX")"
    _rc=$?
    if [[ "${_rc}" -ne 0 || ! -d "${EVIDENCE_REALBOX_WORKDIR}" ]]; then
        EVIDENCE_REALBOX_WORKDIR=""
        log_error "evidence.sh: mktemp -d failed - refusing to touch this machine without a place to keep the backups"
        return 1
    fi
    EVIDENCE_REALBOX_BACKUPS=()
    EVIDENCE_REALBOX_CLAIM="${EVIDENCE_REALBOX_WORKDIR}/owned"
    # Ownership is claimed BEFORE anything can exist. The claim means "this
    # run reached the point where it may create the box", NOT "the box was
    # created": an interrupt inside the creation still hands cleanup the box.
    # A claim with no box is the safe direction, and cleanup tolerates it.
    EVIDENCE_REALBOX_OWNED=1
    if ! : >"${EVIDENCE_REALBOX_CLAIM}"; then
        log_error "evidence.sh: cannot write the ownership claim ${EVIDENCE_REALBOX_CLAIM}"
        return 1
    fi
    trap '_realbox_trap' EXIT INT TERM HUP
    return 0
}

# Back path $1 up so cleanup can put it back. `cp -a` (never -L) keeps a
# symlink a symlink; when $1 is one, the file it points at is backed up as
# well and restored with it (M3 5.2, issue #176 item 2). A path that does not
# exist is recorded too: cleanup then removes whatever the run created there.
_realbox_backup() {
    local _path="$1" _slot _target="" _target_slot="" _type _index
    if [[ -z "${EVIDENCE_REALBOX_WORKDIR}" ]]; then
        log_error "evidence.sh: _realbox_backup called with no realbox run in progress"
        return 1
    fi
    _index="${#EVIDENCE_REALBOX_BACKUPS[@]}"
    _slot="${EVIDENCE_REALBOX_WORKDIR}/backup.${_index}"
    if [[ -L "${_path}" ]]; then
        _type=symlink
    elif [[ -e "${_path}" ]]; then
        _type=regular
    else
        _type=absent
    fi
    if [[ "${_type}" != absent ]]; then
        if ! cp -a "${_path}" "${_slot}"; then
            log_error "evidence.sh: backing up ${_path} failed"
            return 1
        fi
    fi
    if [[ "${_type}" == symlink && -e "${_path}" ]]; then
        if ! _target="$(readlink -f "${_path}")"; then
            log_error "evidence.sh: cannot resolve the link target of ${_path}"
            return 1
        fi
        _target_slot="${EVIDENCE_REALBOX_WORKDIR}/target.${_index}"
        if ! cp -a "${_target}" "${_target_slot}"; then
            log_error "evidence.sh: backing up the link target ${_target} failed"
            return 1
        fi
    fi
    EVIDENCE_REALBOX_BACKUPS+=("${_type}${EVIDENCE_REALBOX_US}${_path}${EVIDENCE_REALBOX_US}${_slot}${EVIDENCE_REALBOX_US}${_target}${EVIDENCE_REALBOX_US}${_target_slot}")
    return 0
}

# Put every backed-up path back, newest first. Returns 1 if any restore
# failed; every entry is still attempted, so one bad path does not strand the
# rest.
_realbox_restore() {
    local _index _entry _rc=0
    local _type _path _slot _target _target_slot
    for ((_index = ${#EVIDENCE_REALBOX_BACKUPS[@]} - 1; _index >= 0; _index--)); do
        _entry="${EVIDENCE_REALBOX_BACKUPS[${_index}]}"
        # The IFS prefix applies to this `read` only (a regular builtin), so
        # the shell's own IFS is untouched.
        IFS="${EVIDENCE_REALBOX_US}" read -r _type _path _slot _target _target_slot \
            <<<"${_entry}"
        # Never write through a link: clear the path first, then put the
        # recorded shape back.
        rm -rf "${_path}" || _rc=1
        if [[ "${_type}" != absent ]]; then
            mkdir -p "$(dirname -- "${_path}")" || _rc=1
            cp -a "${_slot}" "${_path}" || _rc=1
        fi
        if [[ "${_type}" == symlink && -n "${_target_slot}" ]]; then
            cp -a "${_target_slot}" "${_target}" || _rc=1
        fi
    done
    return "${_rc}"
}

# Restore, then remove the box this run claimed, then report. `distrobox rm`
# legitimately fails when there is nothing to remove (interrupted before the
# box existed), so only the FINAL state decides. Prints `cleanup-rc=<n>` the
# way M3 5.1 does, and returns non-zero when anything was left behind.
_realbox_cleanup() {
    local _rc=0 _state
    _realbox_restore || _rc=1
    if [[ "${EVIDENCE_REALBOX_OWNED}" -eq 1 ]]; then
        timeout "${EVIDENCE_BOX_TIMEOUT}" distrobox rm -f "${EVIDENCE_REALBOX_BOX}" \
            >/dev/null 2>&1
        _realbox_box_exists "${EVIDENCE_REALBOX_BOX}"
        _state=$?
        [[ "${_state}" -eq 1 ]] || _rc=1
    fi
    printf 'cleanup-rc=%s\n' "${_rc}"
    [[ "${_rc}" -eq 0 ]] \
        || log_error "evidence.sh: box '${EVIDENCE_REALBOX_BOX}' survived cleanup - remove it by hand"
    if [[ -n "${EVIDENCE_REALBOX_WORKDIR}" ]]; then
        rm -rf "${EVIDENCE_REALBOX_WORKDIR}"
    fi
    return "${_rc}"
}

# The EXIT INT TERM HUP handler. A failed cleanup fails the run even when the
# item itself passed; an item that already failed keeps its own status.
_realbox_trap() {
    local _status=$?
    local _clean=0
    trap - EXIT INT TERM HUP
    _realbox_cleanup || _clean=1
    [[ "${_status}" -eq 0 ]] || exit "${_status}"
    exit "${_clean}"
}

# --- Dispatch ----------------------------------------------------------------

# Print the item table (id, group) one per line.
_list_items() {
    local _id
    for _id in "${EVIDENCE_ITEMS[@]}"; do
        printf '%s %s\n' "${_id}" "${EVIDENCE_ITEM_GROUP[${_id}]}"
    done
}

# Run one item by id. Refuses (2) an unknown id, an id whose function is
# missing, and a realbox item without the opt-in.
_run_item() {
    local _id="$1" _group _fn
    _group="${EVIDENCE_ITEM_GROUP[${_id}]:-}"
    if [[ -z "${_group}" ]]; then
        _usage_error "unknown item '${_id}'"
        return 2
    fi
    _fn="item_${_id//./_}"
    if ! declare -F "${_fn}" >/dev/null; then
        log_error "evidence.sh: item ${_id} is declared in the group table but ${_fn} is not defined"
        return 2
    fi
    if [[ "${_group}" == realbox ]]; then
        _realbox_require_optin "${_id}" || return 2
    fi
    log_info "M3 item ${_id} (group ${_group})"
    "${_fn}"
}

main() {
    local _help=0 _list=0 _id _rc
    local -a _ids=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help) _help=1 ;;
            --list) _list=1 ;;
            --allow-realbox) EVIDENCE_ALLOW_REALBOX=1 ;;
            -*)
                _usage_error "unknown option '$1'"
                return 2
                ;;
            *) _ids+=("$1") ;;
        esac
        shift
    done
    # The whole command line is validated before anything runs.
    if [[ "${_help}" -eq 1 ]]; then
        _usage
        return 0
    fi
    if [[ "${_list}" -eq 1 ]]; then
        _list_items
        return 0
    fi

    if [[ "${#_ids[@]}" -eq 0 ]]; then
        # A bare run selects the default groups. realbox items are opt-in,
        # and saying which ones were left out on stderr is not a silent skip.
        for _id in "${EVIDENCE_ITEMS[@]}"; do
            if [[ "${EVIDENCE_ITEM_GROUP[${_id}]}" == realbox \
                && "${EVIDENCE_ALLOW_REALBOX}" -ne 1 ]]; then
                log_info "item ${_id} not selected: group realbox needs --allow-realbox"
                continue
            fi
            _ids+=("${_id}")
        done
    fi
    if [[ "${#_ids[@]}" -eq 0 ]]; then
        log_error "evidence.sh: no item selected - a run that checks nothing is not a pass"
        return 1
    fi

    for _id in "${_ids[@]}"; do
        _run_item "${_id}"
        _rc=$?
        [[ "${_rc}" -eq 0 ]] || return "${_rc}"
    done
    return 0
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
