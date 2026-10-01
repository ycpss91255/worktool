#!/usr/bin/env bash
# gate.sh - M3 acceptance, the automated-gate items 2.1-2.4 of
# doc/acceptance.md, as a script instead of as shell logic in the document.
#
# WHAT THIS IS
#   Items 2.1-2.4 were the last M3 blocks that still carried shell logic a
#   reader could retype, reflow or truncate: two guarded pipelines over
#   `just test`, an `awk` invocation per negative fixture, and a
#   deliberately unguarded pipeline used as a counter-example. A document
#   cannot be linted and cannot be tested, so the logic lives here and is
#   pinned by test/unit/verify_gate_spec.bats. The document keeps the prose
#   and the EXPECTED OUTPUT, which is what the human gate reads.
#
# ITEMS
#   2.1  the bare six-tier `just test` run is green
#   2.2  every M3 sub-issue PR body shows RED evidence before GREEN
#        evidence (the check itself is doc/evidence/tdd.sh, kept where it
#        is: it is the implementation this item has always used)
#   2.3  the "window -> box -> fish" chain is proven by CI: the
#        integration ghostty group and the system-real chain cases
#   2.4  the acceptance machinery's own negative: the 2.2 checker bites
#        bad evidence, and a pipeline without `pipefail` loses an upstream
#        failure
#
# WHY IT IS WRITTEN THIS WAY: A FAILURE MUST NEVER READ AS A PASS
#   - `just` is judged by its OWN exit status before anything it printed is
#     counted, and every run is wrapped in `timeout` so a hang fails
#     instead of stalling the acceptance run.
#   - No pipeline stands between a command and the status this script
#     judges: 2.3 captures the whole tier output to a file first and greps
#     the file afterwards, so a broken first stage can never be mistaken
#     for "grep matched nothing".
#   - grep's three answers are kept apart everywhere: 0 matched, 1 matched
#     nothing, >= 2 grep itself failed. Only the first two are answers.
#   - Every count and every rc is compared with what the document promises,
#     so a plausible-looking but different number fails and is named.
#   - Where the document publishes a SET, this script compares the set, not
#     its non-emptiness: item 2.2 wants the ten named PRs, each judged once,
#     and item 2.3 wants the cases and the named criteria each tier's block
#     lists. "At least one line looked right" is not an answer to either
#     question - one verdict line, or two placeholder `ok` lines, would
#     otherwise certify evidence that is almost entirely absent. What is
#     missing, extra or repeated is named on stderr.
#   - A criterion the document states as a VALUE (`tmux=no`,
#     `FORWARDED_STARTED=yes`, `COMMAND_FINISHED=no`) is pinned literally; a
#     MEASUREMENT (a container id, a fish version, an elapsed time, a delay
#     in ms) is matched by shape only, because the document says in so many
#     words not to compare those literally.
#   - A check that cannot run here (no docker, no gh, no awk) is reported
#     as UNAVAILABLE and exits non-zero. Nothing is ever skipped silently.
#
#   Like the other verify scripts it deliberately does NOT source
#   lib/log.sh: it is the checker of the delivery, so it must not fail (or
#   pass) because of the tree it is checking.
#
# GROUPS
#   Each item declares a group that names its preconditions:
#     ci   runs the repo's own gates through `just test`; needs just,
#          docker and time. Creates nothing outside Docker.
#     gh   reads external evidence through doc/evidence/tdd.sh (`gh`).
#     doc  reads only files in this checkout (awk over the negative
#          fixtures). No network, no Docker.
#   No item here is a real-machine (realbox) item: nothing on this host is
#   created or modified, so there is no opt-in flag and no box-name
#   collision check. The real-machine items live in script/verify/realbox.sh.
#
# USAGE
#   ./script/verify/gate.sh          # every item, in order, stop at the first failure
#   ./script/verify/gate.sh 2.4      # exactly one item
#   ./script/verify/gate.sh --list   # the item ids and their titles
#   ./script/verify/gate.sh --help   # usage
#
#   Stdout carries exactly the lines doc/acceptance.md shows as the expected
#   output; progress and every diagnostic go to stderr.
#
# EXIT CODES
#   0  every requested item passed
#   1  an item failed (the reason is on stderr)
#   2  usage error (unknown option, unknown item)
#   3  the check cannot run here (a required tool or file is missing)
#
# Expected failures are handled explicitly; checks run in conditionals so
# their own exit codes and diagnostics decide the acceptance verdict.
set -euo pipefail

# --- Constants ---------------------------------------------------------------
SCRIPT_NAME="gate.sh"

# Seconds a single `just test ...` run may take before it is killed. The
# six-tier run builds images and drives docker-in-docker, so this is
# deliberately generous; it exists to turn a hang into a reported failure.
GATE_TIMEOUT="${GATE_TIMEOUT:-5400}"

# Seconds any other single command (gh query, awk over a fixture) may take.
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-300}"

EXIT_FAIL=1
EXIT_USAGE=2
EXIT_UNAVAILABLE=3

# Item 2.2: the PRs doc/acceptance.md publishes a verdict line for, in the
# order the document prints them. The item's claim is "these ten PR bodies
# were each judged once", so the set is pinned here and compared exactly: a
# run that prints one verdict and exits 0 has not made that claim, and a
# verdict for a PR this item does not cover has not made it either.
#
# The ORDER is pinned too, because the document publishes an ordered block and
# a reader compares it line by line. Ten correct verdicts with two of them
# swapped is a checker iterating over a different list from the one this item
# names, which is the same defect as a missing verdict wearing better clothes.
TDD_PRS=(152 153 154 155 156 165 166 167 168 169)

# Item 2.3: the lines of each tier the document publishes, and the tier the
# run has to exercise to produce them. The pattern SELECTS the block the
# document prints; the arrays below are what that block has to CONTAIN.
INTEGRATION_PATTERN='^ok .*ghostty|^not ok'
SYSTEM_REAL_PATTERN='^# (chain|chain-host|hang|single-instance)|^ok .*ghostty chain|^not ok'

# The `ok` cases doc/acceptance.md lists for each tier, keyed by the case
# DESCRIPTION rather than by `ok <n>`: bats numbers shift whenever a case is
# added anywhere earlier in the tier, and a number is not evidence. Each
# description must appear exactly once, and nothing else may appear - which
# also pins the case count per tier (9 and 5). Adding a chain case means
# adding it to the document's block and to the list here; that is the point.
INTEGRATION_CASES=(
    "setup then status: status reports the stored decisions, sources and the ghostty block present, no tmux line"
    "preflight: a real ghostty is on PATH and reports its version"
    "setup.sh writes a ghostty config that +validate-config accepts"
    "+show-config follows setup.sh --box work (the box name reaches ghostty)"
    "#175: the effective command ghostty resolves is an ABSOLUTE distrobox path, not the bare name"
    "#175r2: a distrobox path holding a newline is refused, because ghostty could not parse what it would write"
    "#175r1: a distrobox path with spaces and metacharacters survives ghostty and the shell it hands the command to"
    "after setup.sh --auto-enter no there is no enter command left for ghostty to run"
    "+validate-config refuses a config ghostty cannot parse (the check bites)"
)
SYSTEM_REAL_CASES=(
    "ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive)"
    "ghostty chain: a real window runs the managed block's command and leaves a marker INSIDE the box (fish, the box's mount namespace, no tmux)"
    "ghostty chain: a command that has STARTED inside the box and never ends FAILS within its budget instead of hanging"
    "ghostty chain: with gtk-single-instance on, a forwarded launch exits 0 while the command it asked for has not begun yet (the false positive the guard prevents)"
    "ghostty chain (#175): the absolute distrobox path just box setup writes enters the box from a desktop session's PATH"
)

# The diagnostic criteria doc/acceptance.md publishes for each tier, as
# anchored extended regexes; each must be matched by exactly one line of the
# tier's block. The values the document names as judgements (`tmux=no`,
# `FORWARDED_STARTED=yes`, `FORWARDED_AFTER_RETURN=yes`,
# `COMMAND_FINISHED=no`, and the 124 the hang case is cut by) are literal;
# the values the document explicitly calls per-run measurements (`host=`,
# `fish=`, `SECOND_ELAPSED=`, `FORWARDED_DELAY_MS=`, the budget in seconds)
# are matched by shape, so a slower or faster runner cannot go red for it.
#
# Where the document publishes a BOUND on a measurement, the bound is part of
# the shape. `SECOND_ELAPSED` is the one such value here: the document says
# the case accepts 0-15 seconds, so `[0-9]+` is the wrong pattern - a
# forwarded launch that took 999 seconds to return is not the fast return the
# case exists to observe, and it would have matched. The other measurements
# (`host=`, `fish=`, `FORWARDED_DELAY_MS=`, the budget in seconds) are
# published without a bound and stay shape-only.
INTEGRATION_CRITERIA=()
SYSTEM_REAL_CRITERIA=(
    '^# chain: inbox-ok fish=[0-9]+(\.[0-9]+)+ ctrenv=(/run/\.containerenv|/\.dockerenv) mntns=mnt:\[[0-9]+\] tmux=no host=[^[:space:]]+$'
    '^# chain-in-box: marker mntns=mnt:\[[0-9]+\] == dev container; host=[^[:space:]]+ == docker inspect dev hostname$'
    '^# hang-ready: hang-ready fish=[0-9]+(\.[0-9]+)+ host=[^[:space:]]+$'
    '^# hang: in-box command started, then timed out after [0-9]+s \(budget [0-9]+s, status 124\)$'
    '^# single-instance: PRIMARY=up$'
    '^# single-instance: SECOND_RC=0$'
    '^# single-instance: SECOND_ELAPSED=([0-9]|1[0-5])$'
    '^# single-instance: STARTED_AT_RETURN=1$'
    '^# single-instance: FORWARDED_STARTED=yes$'
    '^# single-instance: FORWARDED_AFTER_RETURN=yes$'
    '^# single-instance: FORWARDED_DELAY_MS=[0-9]+$'
    '^# single-instance: RUNNING_COMMANDS=2$'
    '^# single-instance: PRIMARY_WRAPPER_ALIVE=yes$'
    '^# single-instance: COMMAND_FINISHED=no$'
    '^# chain-desktop-path: inbox-ok fish=[0-9]+(\.[0-9]+)+ ctrenv=(/run/\.containerenv|/\.dockerenv) mntns=mnt:\[[0-9]+\] tmux=no host=[^[:space:]]+$'
)

# Lines whose ORDER the document turns into a judgement. The hang case only
# counts as "a command that had STARTED inside the box was cut" when the
# in-box ready marker came first; a 124 printed before any ready marker is
# the different failure "the window never reached the box", which the
# document says must not read as this case passing.
INTEGRATION_ORDER=()
SYSTEM_REAL_ORDER=(
    '^# hang-ready: '
    '^# hang: '
    '^ok [0-9]+ ghostty chain: a command that has STARTED inside the box and never ends FAILS within its budget instead of hanging$'
)

# Item 2.4: the negative fixtures of the 2.2 checker and the line each one
# must produce. A fixture that starts passing is as much a regression as a
# check that stops biting.
NEGATIVE_FIXTURES=(wrong-order empty-red-block)
NEGATIVE_EXPECTED_wrong_order='order=BAD red=6 green=0'
NEGATIVE_EXPECTED_empty_red_block='order=BAD red=0 green=0'

# --- Paths -------------------------------------------------------------------
# Resolved with parameter expansion and the `cd`/`pwd` builtins only: an
# acceptance checker that needed `dirname` could be broken by a broken
# `dirname`, which is exactly the class of failure it exists to catch.
_self="${BASH_SOURCE[0]}"
[[ "${_self}" == */* ]] || _self="./${_self}"
if ! SCRIPT_DIR="$(cd -- "${_self%/*}" && pwd -P)"; then
    printf '[ERROR] %s: cannot resolve own directory from %s\n' \
        "${SCRIPT_NAME}" "${BASH_SOURCE[0]}" >&2
    exit 3
fi
if ! REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"; then
    printf '[ERROR] %s: cannot resolve the repo root from %s\n' \
        "${SCRIPT_NAME}" "${SCRIPT_DIR}" >&2
    exit 3
fi

TDD_SH="${REPO_ROOT}/doc/evidence/tdd.sh"
TDD_AWK="${REPO_ROOT}/doc/evidence/tdd.awk"
NEGATIVE_DIR="${REPO_ROOT}/doc/evidence/negative"

# --- Diagnostics -------------------------------------------------------------
# Everything here goes to stderr: stdout is reserved for the lines
# doc/acceptance.md publishes as the expected output.
_info() { printf '[INFO] %s\n' "$*" >&2; }

_err() { printf '[ERROR] %s: %s\n' "${SCRIPT_NAME}" "$*" >&2; }

_usage_error() {
    printf '%s: %s (see --help)\n' "${SCRIPT_NAME}" "$1" >&2
    exit "${EXIT_USAGE}"
}

# A check that cannot run here is not a pass and not a skip.
_unavailable() {
    printf '[UNAVAILABLE] %s: %s\n' "${SCRIPT_NAME}" "$*" >&2
    exit "${EXIT_UNAVAILABLE}"
}

# --- Usage -------------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: gate.sh [ITEM...]

Run the M3 acceptance checks of doc/acceptance.md that read the repo's own
automated gates. With no ITEM every item runs in order and the run stops at
the first failure. ITEM is an item id as printed by --list, e.g. 2.4.

  -l, --list   List the item ids and their titles, then exit.
  -h, --help   Show this help and exit.

Items 2.1 and 2.3 drive `just test`, so they need docker and take minutes;
2.2 queries GitHub through `gh`; 2.4 only reads files in this checkout.

Stdout carries exactly the lines doc/acceptance.md shows as the expected
output; progress and diagnostics go to stderr.

Exit codes: 0 pass, 1 an item failed, 2 usage error, 3 the check cannot run
here (a required tool or file is missing - never a silent skip).

Environment:
  GATE_TIMEOUT     seconds allowed per `just test` run (default: 5400).
  VERIFY_TIMEOUT   seconds allowed per other command (default: 300).
EOF
}

# --- Item registry -----------------------------------------------------------
# One item per id: its group (= its preconditions), its function and its
# title. Keeping the three in one case per item makes an item that is
# registered but not implemented impossible to dispatch.
ITEM_IDS=(2.1 2.2 2.3 2.4)

_item_group() {
    case "$1" in
        2.1) printf 'ci\n' ;;
        2.2) printf 'gh\n' ;;
        2.3) printf 'ci\n' ;;
        2.4) printf 'doc\n' ;;
        *)   return 1 ;;
    esac
}

_item_fn() {
    case "$1" in
        2.1) printf '_item_2_1\n' ;;
        2.2) printf '_item_2_2\n' ;;
        2.3) printf '_item_2_3\n' ;;
        2.4) printf '_item_2_4\n' ;;
        *)   return 1 ;;
    esac
}

_item_title() {
    case "$1" in
        2.1) printf '%s\n' "the bare six-tier just test run is green" ;;
        2.2) printf '%s\n' "every sub-issue PR body shows RED evidence before GREEN" ;;
        2.3) printf '%s\n' "CI proves the window -> box -> fish chain" ;;
        2.4) printf '%s\n' "the acceptance machinery's own negative bites" ;;
        *)   return 1 ;;
    esac
}

_list_items() {
    local _id _title _group
    for _id in "${ITEM_IDS[@]}"; do
        _title="$(_item_title "${_id}")" || {
            _err "internal: no title for item ${_id}"
            return 1
        }
        _group="$(_item_group "${_id}")" || {
            _err "internal: no group for item ${_id}"
            return 1
        }
        printf '%s  %-4s  %s\n' "${_id}" "${_group}" "${_title}"
    done
}

# --- Preconditions -----------------------------------------------------------
# One function per group, named _preconditions_<group>. Each exits
# EXIT_UNAVAILABLE (3) with a message naming what is missing, so "cannot
# check" can never be mistaken for "checked and fine".
_require_tool() {
    command -v "$1" >/dev/null 2>&1 \
        || _unavailable "$1 not found on PATH - $2 cannot be checked here"
}

_require_file() {
    [[ -f "$1" ]] \
        || _unavailable "$1 is missing - $2 cannot be checked here"
}

_preconditions_ci() {
    local _item="$1"
    _require_tool just "${_item}"
    _require_tool docker "${_item}"
    _require_tool timeout "${_item}"
    _require_tool grep "${_item}"
    _require_tool mktemp "${_item}"
    _require_file "${REPO_ROOT}/justfile" "${_item}"
}

_preconditions_gh() {
    local _item="$1"
    _require_tool bash "${_item}"
    _require_tool gh "${_item}"
    _require_tool timeout "${_item}"
    _require_file "${TDD_SH}" "${_item}"
}

_preconditions_doc() {
    local _item="$1"
    _require_tool awk "${_item}"
    _require_tool grep "${_item}"
    _require_tool timeout "${_item}"
    _require_file "${TDD_AWK}" "${_item}"
    local _fixture
    for _fixture in "${NEGATIVE_FIXTURES[@]}"; do
        _require_file "${NEGATIVE_DIR}/${_fixture}.md" "${_item}"
    done
}

# --- Shared guards -----------------------------------------------------------

# Run `just test "$@"` under timeout with its combined output going to the
# file named by $1, and store its exit status in the variable named by $2.
# The output is NEVER piped: it lands in a file and is read afterwards, so a
# broken reader can never be mistaken for "the tier printed nothing".
# Returns 1 only when the run could not be made at all (timeout).
_just_test_into() {
    local _file="$1"
    local -n _rc_ref="$2"
    shift 2
    local _label="just test $*"
    _rc_ref=0
    timeout "${GATE_TIMEOUT}" just test "$@" >"${_file}" 2>&1 || _rc_ref=$?
    if [[ "${_rc_ref}" -eq 124 ]]; then
        _err "\`${_label}\` did not finish within ${GATE_TIMEOUT}s (timeout)"
        return 1
    fi
    return 0
}

# Store in the variable named by $1 the lines of file $3 that extended grep
# pattern $2 matches. Tells "nothing matched" (grep 1) from "grep failed"
# (grep >= 2); the caller decides whether an empty answer is acceptable.
# Returns 1 only when grep itself failed.
_grep_file_into() {
    local -n _lines_ref="$1"
    local _pattern="$2" _file="$3" _rc=0
    _lines_ref="$(grep -E -- "${_pattern}" "${_file}")" || _rc=$?
    if [[ "${_rc}" -gt 1 ]]; then
        _err "grep -E '${_pattern}' failed (exit ${_rc}) - the check could not be made"
        return 1
    fi
    if [[ "${_rc}" -eq 1 ]]; then
        _lines_ref=""
    fi
    return 0
}

# Make a temporary directory for one item, storing its path in the variable
# named by $1. A mktemp that prints a plausible path while exiting non-zero
# is a failure, not a directory.
_make_tmpdir() {
    local -n _dir_ref="$1"
    local _rc=0
    _dir_ref="$(mktemp -d)" || _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        _err "mktemp -d failed (exit ${_rc})"
        return 1
    fi
    if [[ ! -d "${_dir_ref}" ]]; then
        _err "mktemp -d printed '${_dir_ref}', which is not a directory"
        return 1
    fi
    return 0
}

# True iff $1 is one of the remaining arguments. Taking the elements as
# arguments rather than the array by name keeps every list below visibly
# USED at its call site, which is also what lets shellcheck see it.
_array_has() {
    local _needle="$1" _e
    shift
    for _e in "$@"; do
        [[ "${_e}" == "${_needle}" ]] && return 0
    done
    return 1
}

# --- Exact-set assertions ----------------------------------------------------
# The document publishes SETS of lines, not "some output". These three
# helpers are the difference between reading that promise and reading only
# that the stream was non-empty.

# Every documented case of a tier appeared exactly once, and nothing else
# did. $1 is the tier label used in messages, $2 the tier's captured block,
# and the remaining arguments are the documented case descriptions.
_check_tier_cases() {
    local _tier="$1" _block="$2"
    shift 2
    local _expected_cases=("$@")
    local -A _count=()
    local _line _desc _bad=0
    local _missing=() _extra=() _repeated=()

    while IFS= read -r _line; do
        [[ "${_line}" =~ ^ok[[:space:]]+[0-9]+[[:space:]](.*)$ ]] || continue
        _desc="${BASH_REMATCH[1]}"
        _count["${_desc}"]=$(( ${_count["${_desc}"]:-0} + 1 ))
    done <<<"${_block}"

    for _desc in "${_expected_cases[@]}"; do
        case "${_count["${_desc}"]:-0}" in
            0) _missing+=("${_desc}") ;;
            1) ;;
            *) _repeated+=("${_desc}") ;;
        esac
    done
    if [[ "${#_count[@]}" -gt 0 ]]; then
        for _desc in "${!_count[@]}"; do
            _array_has "${_desc}" "${_expected_cases[@]}" || _extra+=("${_desc}")
        done
    fi

    if [[ "${#_missing[@]}" -gt 0 ]]; then
        _err "\`just test ${_tier}\` is missing ${#_missing[@]} of the ${#_expected_cases[@]} case(s) doc/acceptance.md lists for it:"
        for _desc in "${_missing[@]}"; do
            _err "  missing case: ${_desc}"
        done
        _bad=1
    fi
    if [[ "${#_repeated[@]}" -gt 0 ]]; then
        _err "\`just test ${_tier}\` reported ${#_repeated[@]} documented case(s) more than once:"
        for _desc in "${_repeated[@]}"; do
            _err "  repeated ${_count["${_desc}"]}x: ${_desc}"
        done
        _bad=1
    fi
    if [[ "${#_extra[@]}" -gt 0 ]]; then
        _err "\`just test ${_tier}\` reported ${#_extra[@]} case(s) doc/acceptance.md does not list (update the document and this script together):"
        for _desc in "${_extra[@]}"; do
            _err "  unexpected case: ${_desc}"
        done
        _bad=1
    fi
    return "${_bad}"
}

# Every documented criterion of a tier was printed exactly once. $1 is the
# tier label, $2 the tier's captured block, and the remaining arguments are
# the documented criteria as anchored extended regexes.
_check_tier_criteria() {
    local _tier="$1" _block="$2"
    shift 2
    local _pat _line _n _bad=0

    for _pat in "$@"; do
        _n=0
        while IFS= read -r _line; do
            [[ "${_line}" =~ ${_pat} ]] && _n=$(( _n + 1 ))
        done <<<"${_block}"
        if [[ "${_n}" -eq 0 ]]; then
            _err "\`just test ${_tier}\` printed no line meeting the documented criterion ${_pat}"
            _bad=1
        elif [[ "${_n}" -gt 1 ]]; then
            _err "\`just test ${_tier}\` printed ${_n} lines meeting the documented criterion ${_pat} (expected exactly 1)"
            _bad=1
        fi
    done
    return "${_bad}"
}

# The documented lines appeared in the documented order. $1 is the tier
# label, $2 the tier's captured block, and the remaining arguments are the
# anchored extended regexes in the order they must occur. A pattern that
# never matched is reported as such rather than as an ordering failure.
_check_tier_order() {
    local _tier="$1" _block="$2"
    shift 2
    local _pat _line _i=0 _prev=-1 _at=-1 _prev_pat="" _bad=0

    for _pat in "$@"; do
        _i=0
        _at=-1
        while IFS= read -r _line; do
            if [[ "${_at}" -lt 0 && "${_line}" =~ ${_pat} ]]; then
                _at="${_i}"
            fi
            _i=$(( _i + 1 ))
        done <<<"${_block}"
        if [[ "${_at}" -lt 0 ]]; then
            _err "\`just test ${_tier}\` printed no line matching ${_pat}, so the documented order cannot hold"
            _bad=1
            continue
        fi
        if [[ "${_at}" -le "${_prev}" ]]; then
            _err "\`just test ${_tier}\` printed ${_pat} before ${_prev_pat}, which the document requires to come first"
            _bad=1
        fi
        _prev="${_at}"
        _prev_pat="${_pat}"
    done
    return "${_bad}"
}

# --- Item 2.1 ----------------------------------------------------------------

# The bare `just test` run: all six tiers, in order, stop at the first
# failure. The run streams to the caller's terminal exactly as it does when
# typed by hand - this item adds the one judgement the document could only
# ask for in prose, namely that `just test`'s OWN exit status is what
# decides, not the last line it happened to print.
_item_2_1() {
    local _rc=0
    timeout "${GATE_TIMEOUT}" just test || _rc=$?
    if [[ "${_rc}" -eq 124 ]]; then
        _err "\`just test\` did not finish within ${GATE_TIMEOUT}s (timeout)"
        return 1
    fi
    if [[ "${_rc}" -ne 0 ]]; then
        _err "\`just test\` exited ${_rc} - the six-tier gate is not green"
        return 1
    fi
    return 0
}

# --- Item 2.2 ----------------------------------------------------------------

# Every listed PR body shows a non-empty RED block before a non-empty GREEN
# block. The check itself is doc/evidence/tdd.sh (unchanged: it is the
# implementation this item has always used, and #176 item 8 is the reason
# it lives outside the document). What this item adds is the guard the
# document could not carry:
#   - tdd.sh's own status is read, so a gh that prints a plausible body and
#     then fails cannot be counted as evidence;
#   - EVERY line must be a verdict of the documented shape, so a tdd.sh that
#     exits 0 having printed nothing (or printed something else) fails
#     instead of reading as "no bad PRs found";
#   - and the verdicts must be EXACTLY the ten PRs TDD_PRS names, once each.
#     "At least one line looked like a verdict" was the hole: a single
#     `#152 order=ok red=1 green=2` plus exit 0 used to certify all ten.
#     Missing, extra and repeated PR numbers are each named.
#   - green must be a LATER line than red, which is the whole claim of the
#     item; `red=51 green=31` is a shape tdd.awk cannot produce, so it is a
#     forged verdict, not a passing one.
_item_2_2() {
    local _out="" _rc=0
    _out="$(timeout "${VERIFY_TIMEOUT}" bash "${TDD_SH}" 2>&1)" || _rc=$?

    # Print what it found before judging it: a failing run still shows the
    # familiar block plus the reason.
    [[ -n "${_out}" ]] && printf '%s\n' "${_out}"

    if [[ "${_rc}" -eq 124 ]]; then
        _err "doc/evidence/tdd.sh did not finish within ${VERIFY_TIMEOUT}s (timeout)"
        return 1
    fi
    if [[ -z "${_out}" ]]; then
        _err "doc/evidence/tdd.sh printed nothing - that is not 'every PR passed'"
        return 1
    fi

    local _verdict='^#([0-9]+)[[:space:]]order=ok[[:space:]]red=([0-9]+)[[:space:]]green=([0-9]+)$'
    local -A _count=()
    local -a _order=()
    local _line _pr _red _green _bad=0 _n=0
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] || continue
        _n=$(( _n + 1 ))
        if [[ ! "${_line}" =~ ${_verdict} ]]; then
            _err "not a passing verdict: ${_line}"
            _bad=1
            continue
        fi
        _pr="${BASH_REMATCH[1]}"
        _red="${BASH_REMATCH[2]}"
        _green="${BASH_REMATCH[3]}"
        if [[ "${_red}" -lt 1 || "${_green}" -le "${_red}" ]]; then
            _err "not a passing verdict (GREEN must open after RED): ${_line}"
            _bad=1
            continue
        fi
        _count["${_pr}"]=$(( ${_count["${_pr}"]:-0} + 1 ))
        _order+=("${_pr}")
    done <<<"${_out}"

    if [[ "${_n}" -eq 0 ]]; then
        _err "doc/evidence/tdd.sh printed no verdict line at all"
        return 1
    fi

    # The exact set, not its non-emptiness.
    local _missing=() _extra=() _repeated=()
    for _pr in "${TDD_PRS[@]}"; do
        case "${_count["${_pr}"]:-0}" in
            0) _missing+=("#${_pr}") ;;
            1) ;;
            *) _repeated+=("#${_pr} (${_count["${_pr}"]}x)") ;;
        esac
    done
    if [[ "${#_count[@]}" -gt 0 ]]; then
        for _pr in "${!_count[@]}"; do
            _array_has "${_pr}" "${TDD_PRS[@]}" || _extra+=("#${_pr}")
        done
    fi

    if [[ "${#_missing[@]}" -gt 0 ]]; then
        _err "doc/evidence/tdd.sh printed no passing verdict for ${#_missing[@]} of the ${#TDD_PRS[@]} documented PR(s): ${_missing[*]}"
        _bad=1
    fi
    if [[ "${#_repeated[@]}" -gt 0 ]]; then
        _err "doc/evidence/tdd.sh printed more than one verdict for: ${_repeated[*]}"
        _bad=1
    fi
    if [[ "${#_extra[@]}" -gt 0 ]]; then
        _err "doc/evidence/tdd.sh printed a verdict for PR(s) this item does not cover: ${_extra[*]} (expected exactly ${TDD_PRS[*]/#/#})"
        _bad=1
    fi

    # The ORDER, once the set is known to be right. Comparing it earlier would
    # only restate a missing or repeated verdict in a second, less useful way;
    # comparing it at all is what catches ten correct verdicts in the wrong
    # sequence, which the set comparison alone accepts.
    if [[ "${_bad}" -eq 0 && "${_order[*]}" != "${TDD_PRS[*]}" ]]; then
        _err "doc/evidence/tdd.sh printed the ten verdicts in the order ${_order[*]/#/#}, but doc/acceptance.md publishes ${TDD_PRS[*]/#/#}"
        _bad=1
    fi

    if [[ "${_bad}" -ne 0 ]]; then
        return 1
    fi
    if [[ "${_rc}" -ne 0 ]]; then
        _err "doc/evidence/tdd.sh exited ${_rc} - what it printed does not count"
        return 1
    fi
    return 0
}

# --- Item 2.3 ----------------------------------------------------------------

# Run one tier, print the lines the document publishes for it and store
# them in the variable named by $4. $1 is the tier verb, $2 the extended
# grep pattern, $3 the file to capture into.
# The tier output is captured to a FILE and grepped afterwards, never piped,
# so `just test` failing is never indistinguishable from "grep matched
# nothing". The matched lines are printed BEFORE the verdict, so a red run
# still shows its `not ok` lines.
# This function answers only "the tier ran, exited 0 and printed a block
# with no `not ok` in it". WHAT that block has to contain is the caller's
# question, because it is the one the document answers per tier.
_run_chain_tier() {
    local _tier="$1" _pattern="$2" _file="$3"
    local -n _block_ref="$4"
    local _rc=0 _notok=""

    _block_ref=""
    _just_test_into "${_file}" _rc "${_tier}" || return 1

    _grep_file_into _block_ref "${_pattern}" "${_file}" || return 1
    [[ -n "${_block_ref}" ]] && printf '%s\n' "${_block_ref}"

    if [[ "${_rc}" -ne 0 ]]; then
        _err "\`just test ${_tier}\` exited ${_rc} - what it printed does not count"
        return 1
    fi
    if [[ -z "${_block_ref}" ]]; then
        _err "\`just test ${_tier}\` exited 0 but printed no line matching '${_pattern}'"
        return 1
    fi

    _grep_file_into _notok '^not ok' "${_file}" || return 1
    if [[ -n "${_notok}" ]]; then
        _err "\`just test ${_tier}\` reported failing cases: ${_notok//$'\n'/ | }"
        return 1
    fi
    return 0
}

# Judge one tier's block against everything the document publishes for it:
# the case set, the named criteria and the required order. All three run
# even when the first one fails - one report naming everything that is
# missing beats three runs each naming one thing.
_check_integration_block() {
    local _block="$1" _bad=0
    _check_tier_cases integration "${_block}" "${INTEGRATION_CASES[@]}" || _bad=1
    _check_tier_criteria integration "${_block}" "${INTEGRATION_CRITERIA[@]}" || _bad=1
    _check_tier_order integration "${_block}" "${INTEGRATION_ORDER[@]}" || _bad=1
    return "${_bad}"
}

_check_system_real_block() {
    local _block="$1" _bad=0
    _check_tier_cases system-real "${_block}" "${SYSTEM_REAL_CASES[@]}" || _bad=1
    _check_tier_criteria system-real "${_block}" "${SYSTEM_REAL_CRITERIA[@]}" || _bad=1
    _check_tier_order system-real "${_block}" "${SYSTEM_REAL_ORDER[@]}" || _bad=1
    return "${_bad}"
}

# Item 2.3: the integration ghostty group asserts what a real ghostty
# resolves out of the managed block; the system-real group opens a real
# window under xvfb and judges by the marker left INSIDE the box.
_item_2_3() {
    local _dir="" _rc=0 _block=""
    _make_tmpdir _dir || return 1

    if _run_chain_tier integration "${INTEGRATION_PATTERN}" "${_dir}/integration.log" _block; then
        _check_integration_block "${_block}" || _rc=1
    else
        _rc=1
    fi
    if [[ "${_rc}" -eq 0 ]]; then
        printf '\n'
        if _run_chain_tier system-real "${SYSTEM_REAL_PATTERN}" "${_dir}/system-real.log" _block; then
            _check_system_real_block "${_block}" || _rc=1
        else
            _rc=1
        fi
    fi

    rm -rf -- "${_dir}" || {
        _err "could not remove the temporary directory ${_dir}"
        _rc=1
    }
    return "${_rc}"
}

# --- Item 2.4 ----------------------------------------------------------------

# Run the 2.2 checker over one negative fixture: it must print exactly the
# documented verdict AND exit 1. Both halves matter - a checker that prints
# `order=BAD` and exits 0 would let a bad PR body through.
_negative_fixture() {
    local _name="$1" _expected="$2"
    local _out="" _rc=0
    _out="$(timeout "${VERIFY_TIMEOUT}" awk -f "${TDD_AWK}" "${NEGATIVE_DIR}/${_name}.md" 2>&1)" || _rc=$?

    # The observed lines, exactly as the document shows them.
    [[ -n "${_out}" ]] && printf '%s\n' "${_out}"
    printf '%s rc=%s\n' "${_name}" "${_rc}"

    if [[ "${_rc}" -eq 124 ]]; then
        _err "awk over ${_name}.md did not finish within ${VERIFY_TIMEOUT}s (timeout)"
        return 1
    fi
    # The status comes first: "the fixture was accepted" is the more
    # fundamental regression, and it is the one that would let a bad PR body
    # through. Only then is the verdict text compared.
    if [[ "${_rc}" -ne 1 ]]; then
        _err "${_name}.md: the checker exited ${_rc}, expected 1 (a bad fixture must be refused)"
        return 1
    fi
    if [[ "${_out}" != "${_expected}" ]]; then
        _err "${_name}.md: expected '${_expected}', got '${_out}'"
        return 1
    fi
    return 0
}

# The counter-example this checklist exists to keep out of itself: the same
# pipeline with and without `pipefail`. The guarded form reports the
# upstream 7; the unguarded one reports grep's 0 and loses the failure.
# `set +o pipefail` is explicit because this script runs under `pipefail`,
# so without it the "unguarded" half would not be unguarded at all.
_pipefail_demo() {
    local _guarded=0 _unguarded=0

    ( set -o pipefail; { printf 'ok 1 ghostty chain: x\n'; exit 7; } | grep -E '^ok .*ghostty' >/dev/null ) || _guarded=$?
    printf 'guarded-rc=%s\n' "${_guarded}"

    ( set +o pipefail; { printf 'ok 1 ghostty chain: x\n'; exit 7; } | grep -E '^ok .*ghostty' >/dev/null ) || _unguarded=$?
    printf 'unguarded-rc=%s\n' "${_unguarded}"

    if [[ "${_guarded}" -ne 7 ]]; then
        _err "the guarded pipeline reported ${_guarded}, expected the upstream 7"
        return 1
    fi
    if [[ "${_unguarded}" -ne 0 ]]; then
        _err "the unguarded pipeline reported ${_unguarded}, expected 0 (it is the counter-example)"
        return 1
    fi
    return 0
}

_item_2_4() {
    local _rc=0
    _negative_fixture wrong-order "${NEGATIVE_EXPECTED_wrong_order}" || _rc=1
    _negative_fixture empty-red-block "${NEGATIVE_EXPECTED_empty_red_block}" || _rc=1
    _pipefail_demo || _rc=1
    return "${_rc}"
}

# --- Dispatcher --------------------------------------------------------------
_run_item() {
    local _id="$1" _group _fn _title
    _group="$(_item_group "${_id}")" || {
        _err "internal: no group for item ${_id}"
        return 1
    }
    _fn="$(_item_fn "${_id}")" || {
        _err "internal: no function for item ${_id}"
        return 1
    }
    _title="$(_item_title "${_id}")" || {
        _err "internal: no title for item ${_id}"
        return 1
    }
    declare -F "${_fn}" >/dev/null || {
        _err "internal: item ${_id} is registered but ${_fn} is not defined"
        return 1
    }
    declare -F "_preconditions_${_group}" >/dev/null || {
        _err "internal: item ${_id} is in group ${_group}, which has no preconditions"
        return 1
    }
    _info "item ${_id}: ${_title}"
    # Exits EXIT_UNAVAILABLE when the item cannot be checked here.
    "_preconditions_${_group}" "item ${_id}"
    if ! "${_fn}"; then
        _err "item ${_id} FAILED"
        return 1
    fi
    _info "item ${_id} PASSED"
    return 0
}

main() {
    local _items=() _arg _id
    while [[ "$#" -gt 0 ]]; do
        _arg="$1"
        case "${_arg}" in
            -h | --help)
                _usage
                exit 0
                ;;
            -l | --list)
                _list_items || exit "${EXIT_FAIL}"
                exit 0
                ;;
            -*)
                _usage_error "unknown option '${_arg}'"
                ;;
            *)
                _item_fn "${_arg}" >/dev/null \
                    || _usage_error "unknown item '${_arg}'"
                _items+=("${_arg}")
                ;;
        esac
        shift
    done

    if [[ "${#_items[@]}" -eq 0 ]]; then
        _items=("${ITEM_IDS[@]}")
    fi

    cd -- "${REPO_ROOT}" \
        || _unavailable "cannot enter the repo root ${REPO_ROOT}"

    for _id in "${_items[@]}"; do
        _run_item "${_id}" || exit "${EXIT_FAIL}"
    done
    return 0
}

main "$@"
