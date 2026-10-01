#!/usr/bin/env bash
# ui.sh - M3 acceptance, group "ui": the `box` namespace user interface (#21).
#
# WHAT THIS IS
#   The executable form of the "驗收方式" blocks of doc/acceptance.md's M3
#   item 1.1, so the markdown no longer carries shell logic a reader could
#   retype, reflow or truncate. The document keeps the EXPECTED OUTPUT (that
#   is what the human gate reads); the logic that produces it lives here and
#   is covered by test/unit/verify_ui_spec.bats.
#
# ITEMS
#   1.1  `just box` lists the seven box verbs and `just box help` prints the
#        usage of the five box scripts (assemble.sh, bench.sh, setup.sh,
#        status.sh, enter.sh), each exactly once.
#
# WHY IT IS WRITTEN THIS WAY
#   An acceptance check that can read green while its own machinery failed
#   is worse than no check: it certifies the delivery on the strength of a
#   broken pipeline. So every command that produces evidence here is
#   status-checked, every pipeline runs under `set -o pipefail` with its
#   exit status captured, and every count is rejected when it cannot be
#   told apart from its degenerate case:
#
#     - `just` exiting non-zero is a failure even when it printed exactly
#       the lines the document shows (the document says so in prose; here
#       it is code);
#     - output that is empty, or that lacks the `Available recipes:`
#       header, is a failure of its own, never "zero recipes matched";
#     - `grep` finding nothing (status 1) is told apart from `grep` failing
#       (status >= 2) and both are told apart from `grep` succeeding with
#       no output;
#     - the count from `wc -l` is rejected unless it is digits, so a `wc`
#       that prints a word cannot reach the numeric comparison;
#     - a tool that is missing (nothing to run) is reported as UNAVAILABLE
#       and exits non-zero - this script never skips a check silently.
#
#   For the same reason it deliberately does NOT source lib/log.sh: it is
#   the checker of the delivery, so it must not fail (or pass) because of
#   the tree it is checking. Its only dependencies are bash and the tools
#   listed under PRECONDITIONS.
#
# GROUPS
#   Each item belongs to a group that names its preconditions. Item 1.1 is
#   group `ui`: it only runs `just` against this checkout, creates nothing
#   and needs no distrobox, no ghostty, no container engine and no real box.
#   There is therefore no real-machine (realbox) item in this script and no
#   opt-in flag to guard one; a later realbox item would add its own group
#   with its own preconditions and its own opt-in.
#
# USAGE
#   ./script/verify/ui.sh          # every item, in order, stop at the first failure
#   ./script/verify/ui.sh 1.1      # exactly one item
#   ./script/verify/ui.sh --list   # the item ids and their titles
#   ./script/verify/ui.sh --help   # usage
#
#   Stdout carries exactly the lines doc/acceptance.md shows as the expected
#   output, so the maintainer still compares what the document promised.
#   Progress and every diagnostic go to stderr.
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
SCRIPT_NAME="ui.sh"

# Seconds any single `just` invocation may take before it is killed. `just
# box help` runs five scripts, so this is generous; it exists to turn a hang
# into a reported failure instead of a stuck acceptance run.
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-120}"

EXIT_FAIL=1
EXIT_USAGE=2
EXIT_UNAVAILABLE=3

# The seven verbs `just box` must list (doc/acceptance.md M3 item 1.1).
RECIPES_EXPECTED=(assemble bench default enter help setup status)

# The five scripts `just box help` must print a usage line for, once each.
USAGES_EXPECTED=(assemble.sh bench.sh setup.sh status.sh enter.sh)

# --- Paths -------------------------------------------------------------------
# Resolved with parameter expansion and the `cd`/`pwd` builtins only: an
# acceptance checker that needed `dirname` could be broken by a broken
# `dirname`, which is exactly the class of failure it exists to catch.
_self="${BASH_SOURCE[0]}"
[[ "${_self}" == */* ]] || _self="./${_self}"
if ! SCRIPT_DIR="$(cd -- "${_self%/*}" && pwd -P)"; then
    printf '[ERROR] %s: cannot resolve own directory from %s\n' \
        "${SCRIPT_NAME}" "${BASH_SOURCE[0]}" >&2
    exit "${EXIT_UNAVAILABLE}"
fi
if ! REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"; then
    printf '[ERROR] %s: cannot resolve the repo root from %s\n' \
        "${SCRIPT_NAME}" "${SCRIPT_DIR}" >&2
    exit "${EXIT_UNAVAILABLE}"
fi

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
Usage: ui.sh [ITEM...]

Run the M3 acceptance checks of doc/acceptance.md that cover the `box`
namespace user interface. With no ITEM every item runs in order and the run
stops at the first failure. ITEM is an item id as printed by --list, e.g.
1.1.

  -l, --list   List the item ids and their titles, then exit.
  -h, --help   Show this help and exit.

Stdout carries exactly the lines doc/acceptance.md shows as the expected
output; progress and diagnostics go to stderr.

Exit codes: 0 pass, 1 an item failed, 2 usage error, 3 the check cannot run
here (a required tool or file is missing - never a silent skip).

Environment:
  VERIFY_TIMEOUT   seconds allowed per `just` invocation (default: 120).
EOF
}

# --- Item registry -----------------------------------------------------------
# One item per id: its group (= its preconditions), its function and its
# title. Keeping the three in one case per item makes an item that is
# registered but not implemented impossible to dispatch.
ITEM_IDS=(1.1)

_item_group() {
    case "$1" in
        1.1) printf 'ui\n' ;;
        *)   return 1 ;;
    esac
}

_item_fn() {
    case "$1" in
        1.1) printf '_item_1_1\n' ;;
        *)   return 1 ;;
    esac
}

_item_title() {
    case "$1" in
        1.1) printf '%s\n' "just box lists seven verbs; just box help prints five script usages" ;;
        *)   return 1 ;;
    esac
}

_list_items() {
    local _id _title
    for _id in "${ITEM_IDS[@]}"; do
        _title="$(_item_title "${_id}")" || {
            _err "internal: no title for item ${_id}"
            return 1
        }
        printf '%s  %s\n' "${_id}" "${_title}"
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

_preconditions_ui() {
    local _item="$1"
    _require_tool just "${_item}"
    _require_tool timeout "${_item}"
    _require_tool grep "${_item}"
    _require_tool sort "${_item}"
    _require_tool wc "${_item}"
    [[ -f "${REPO_ROOT}/justfile" ]] \
        || _unavailable "no justfile at ${REPO_ROOT} - ${_item} cannot be checked here"
}

# --- Shared guards -----------------------------------------------------------

# Run `just "$@"` under timeout, storing its combined output in the variable
# named by $1. Returns 0 only when just itself exited 0 AND printed
# something: a just that prints the documented lines and then exits
# non-zero is a failure, and so is a just that exits 0 with nothing to show.
_just_capture() {
    local -n _out_ref="$1"
    shift
    local _label="just $*" _rc=0
    _out_ref="$(timeout "${VERIFY_TIMEOUT}" just "$@" 2>&1)" || _rc=$?
    if [[ "${_rc}" -eq 124 ]]; then
        _err "\`${_label}\` did not finish within ${VERIFY_TIMEOUT}s (timeout)"
        return 1
    fi
    if [[ "${_rc}" -ne 0 ]]; then
        _err "\`${_label}\` exited ${_rc} - what it printed does not count"
        return 1
    fi
    if [[ -z "${_out_ref}" ]]; then
        _err "\`${_label}\` exited 0 but printed nothing"
        return 1
    fi
    return 0
}

# Store in the variable named by $1 the lines of $3 that grep pattern $2
# matches. Tells "nothing matched" (grep 1), "grep failed" (grep >= 2) and
# "grep succeeded with empty output" apart, so none of them can become a
# zero that reads like a pass. $4 is the grep mode: `line` or `only`.
_grep_capture() {
    local -n _lines_ref="$1"
    local _pattern="$2" _input="$3" _mode="$4" _rc=0
    case "${_mode}" in
        line) _lines_ref="$(printf '%s\n' "${_input}" | grep -- "${_pattern}")" || _rc=$? ;;
        only) _lines_ref="$(printf '%s\n' "${_input}" | grep -o -- "${_pattern}")" || _rc=$? ;;
        *)
            _err "internal: _grep_capture mode '${_mode}'"
            return 1
            ;;
    esac
    if [[ "${_rc}" -gt 1 ]]; then
        _err "grep '${_pattern}' failed (exit ${_rc}) - the check could not be made"
        return 1
    fi
    if [[ "${_rc}" -eq 1 || -z "${_lines_ref}" ]]; then
        _err "no line matching '${_pattern}' in the output"
        return 1
    fi
    return 0
}

# Store in the variable named by $1 the number of lines of $2. Guards the
# whole pipeline (pipefail + captured status) and rejects a count that is
# not digits, so a `wc` that prints a word cannot reach a numeric test.
# Empty input is refused rather than counted: `printf '%s\n' ""` is one
# line, which is exactly the zero-that-looks-like-one this guards against.
_count_lines() {
    local -n _n_ref="$1"
    local _input="$2" _rc=0
    if [[ -z "${_input}" ]]; then
        _err "internal: refusing to count the lines of empty input"
        return 1
    fi
    _n_ref="$(printf '%s\n' "${_input}" | wc -l)" || _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        _err "wc -l failed (exit ${_rc}) - the count could not be made"
        return 1
    fi
    _n_ref="${_n_ref//[[:space:]]/}"
    if [[ ! "${_n_ref}" =~ ^[0-9]+$ ]]; then
        _err "wc -l printed '${_n_ref}', which is not a count"
        return 1
    fi
    return 0
}

# --- Item 1.1 ----------------------------------------------------------------

# Check the recipe list of `just box` ($1): the `Available recipes:` header
# must be there (its absence is a failure of its own, not "no recipes"), and
# the listed verbs must be exactly RECIPES_EXPECTED.
_check_recipe_list() {
    local _out="$1"
    local _line _name _header=0
    local -A _seen=()
    while IFS= read -r _line; do
        if [[ "${_line}" == "Available recipes:" ]]; then
            _header=1
            continue
        fi
        [[ "${_header}" -eq 1 ]] || continue
        [[ "${_line}" =~ ^[[:blank:]]+([a-z][a-z0-9_-]*)([[:blank:]]|$) ]] || continue
        _seen["${BASH_REMATCH[1]}"]=1
    done <<<"${_out}"

    if [[ "${_header}" -ne 1 ]]; then
        _err "\`just box\` printed no 'Available recipes:' header - there is no recipe list to count"
        return 1
    fi

    local _missing=()
    for _name in "${RECIPES_EXPECTED[@]}"; do
        [[ -n "${_seen[${_name}]:-}" ]] || _missing+=("${_name}")
    done
    if [[ "${#_missing[@]}" -gt 0 ]]; then
        _err "\`just box\` does not list: ${_missing[*]} (expected ${RECIPES_EXPECTED[*]})"
        return 1
    fi
    if [[ "${#_seen[@]}" -ne "${#RECIPES_EXPECTED[@]}" ]]; then
        _err "\`just box\` lists ${#_seen[@]} verb(s) (${!_seen[*]}), expected ${#RECIPES_EXPECTED[@]} (${RECIPES_EXPECTED[*]})"
        return 1
    fi
    return 0
}

# Check the distinct `Usage: <script>.sh` names of `just box help` ($1):
# exactly the five box scripts, once each.
_check_usage_names() {
    local _names="$1"
    local _name _count=0
    local -A _seen=()
    while IFS= read -r _name; do
        [[ -n "${_name}" ]] || continue
        _seen["${_name#Usage: }"]=1
    done <<<"${_names}"

    local _missing=()
    for _name in "${USAGES_EXPECTED[@]}"; do
        [[ -n "${_seen[${_name}]:-}" ]] || _missing+=("${_name}")
    done
    _count="${#_seen[@]}"
    if [[ "${#_missing[@]}" -gt 0 ]]; then
        _err "\`just box help\` prints no usage for: ${_missing[*]} (expected ${USAGES_EXPECTED[*]})"
        return 1
    fi
    if [[ "${_count}" -ne "${#USAGES_EXPECTED[@]}" ]]; then
        _err "\`just box help\` prints usage for ${_count} script(s) (${!_seen[*]}), expected ${#USAGES_EXPECTED[@]} (${USAGES_EXPECTED[*]})"
        return 1
    fi
    return 0
}

# Item 1.1: `just box` lists the seven verbs; `just box help` prints the usage
# of the five box scripts, once each.
_item_1_1() {
    local _box_out="" _help_out="" _usage_lines="" _names="" _n=""

    _just_capture _box_out box || return 1
    printf '%s\n' "${_box_out}"
    _check_recipe_list "${_box_out}" || return 1

    # `just box help` is checked for its own exit status BEFORE its output is
    # counted: a just that prints five Usage lines and then exits 1 is not a
    # pass (doc/acceptance.md M3 item 1.1 says so in prose).
    _just_capture _help_out box help || return 1

    _grep_capture _usage_lines '^Usage:' "${_help_out}" line || return 1
    printf '%s\n' "${_usage_lines}"

    _grep_capture _names '^Usage: [a-z]*\.sh' "${_help_out}" only || return 1
    local _sorted="" _rc=0
    _sorted="$(printf '%s\n' "${_names}" | sort -u)" || _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        _err "sort -u failed (exit ${_rc}) - the distinct usages could not be counted"
        return 1
    fi
    if [[ -z "${_sorted}" ]]; then
        _err "sort -u exited 0 but printed nothing for ${_names//$'\n'/, }"
        return 1
    fi

    _count_lines _n "${_sorted}" || return 1
    if [[ "${_n}" -ne "${#USAGES_EXPECTED[@]}" ]]; then
        _err "\`just box help\` prints ${_n} distinct script usage(s), expected ${#USAGES_EXPECTED[@]}"
        return 1
    fi
    _check_usage_names "${_sorted}" || return 1

    printf 'five-usages\n'
    return 0
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
