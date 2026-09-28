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
#   2.3  the "window -> box -> tmux/fish" chain is proven by CI: the
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
# Exit-code-contract script: default guards are `set -uo pipefail` (no `-e`),
# per doc/adr/0007 - every failure below is surfaced explicitly, so a
# non-zero exit is always intentional.

set -uo pipefail

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

# Item 2.3: the lines of each tier the document publishes, and the tier the
# run has to exercise to produce them.
INTEGRATION_PATTERN='^ok .*ghostty|^not ok'
SYSTEM_REAL_PATTERN='^# (chain|chain-host|hang|single-instance)|^ok .*ghostty chain|^not ok'

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
        2.3) printf '%s\n' "CI proves the window -> box -> tmux/fish chain" ;;
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
# document could not carry: tdd.sh's own status is read, its output must be
# non-empty, and EVERY line must be a verdict of the documented shape - so
# a tdd.sh that exits 0 having printed nothing, or printed something else,
# fails instead of reading as "no bad PRs found".
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

    local _verdict='^#[0-9]+[[:space:]]order=ok[[:space:]]red=[0-9]+[[:space:]]green=[0-9]+$'
    local _line _bad=0 _n=0
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] || continue
        _n=$(( _n + 1 ))
        if [[ ! "${_line}" =~ ${_verdict} ]]; then
            _err "not a passing verdict: ${_line}"
            _bad=1
        fi
    done <<<"${_out}"

    if [[ "${_n}" -eq 0 ]]; then
        _err "doc/evidence/tdd.sh printed no verdict line at all"
        return 1
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

# Run one tier and print the lines the document publishes for it. $1 is the
# tier verb, $2 the extended grep pattern, $3 the file to capture into.
# The tier output is captured to a FILE and grepped afterwards, never piped,
# so `just test` failing is never indistinguishable from "grep matched
# nothing". The matched lines are printed BEFORE the verdict, so a red run
# still shows its `not ok` lines.
_run_chain_tier() {
    local _tier="$1" _pattern="$2" _file="$3"
    local _rc=0 _matched="" _notok=""

    _just_test_into "${_file}" _rc "${_tier}" || return 1

    _grep_file_into _matched "${_pattern}" "${_file}" || return 1
    [[ -n "${_matched}" ]] && printf '%s\n' "${_matched}"

    if [[ "${_rc}" -ne 0 ]]; then
        _err "\`just test ${_tier}\` exited ${_rc} - what it printed does not count"
        return 1
    fi
    if [[ -z "${_matched}" ]]; then
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

# Item 2.3: the integration ghostty group asserts what a real ghostty
# resolves out of the managed block; the system-real group opens a real
# window under xvfb and judges by the marker left INSIDE the box.
_item_2_3() {
    local _dir="" _rc=0
    _make_tmpdir _dir || return 1

    _run_chain_tier integration "${INTEGRATION_PATTERN}" "${_dir}/integration.log" || _rc=1
    if [[ "${_rc}" -eq 0 ]]; then
        printf '\n'
        _run_chain_tier system-real "${SYSTEM_REAL_PATTERN}" "${_dir}/system-real.log" || _rc=1
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
