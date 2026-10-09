#!/usr/bin/env bash
# all.sh - M3 acceptance, every non-real-machine group in one run (#182).
#
# WHAT THIS IS
#   The one line the maintainer runs to verify doc/acceptance.md: it runs
#   the verify groups ui, gate, setup, diagram and evidence, in that order,
#   each with no argument (= every item of that group), through the group
#   scripts next to this file. realbox is NOT run: it needs
#   --allow-real-box on a real host, so it stays a separate, explicit call
#   (`just verify realbox --allow-real-box ...`).
#
#   Bare `just verify` only LISTS the groups and exits 0; before #182 that
#   rc=0 could be read as "verified". This script is the command that
#   actually verifies, and its exit status is the verdict.
#
# BEHAVIOUR
#   - Each group's own stdout / stderr passes through untouched, so the
#     maintainer still compares the expected output the document shows.
#   - After each group one summary line goes to stdout:
#       verify all: <group> PASS
#       verify all: <group> FAIL (rc=N)
#       verify all: <group> UNAVAILABLE (rc=3)
#   - The run stops at the first group that does not exit 0, and a final
#     `verify all: VERDICT ...` line names the failing group, the groups
#     that passed and the groups that were not run.
#   - A group script that is missing or not executable is a failure of that
#     group, never a skip.
#
# EXIT CODES
#   0  every group passed
#   1  a group failed (any non-zero status other than 3, or its script is
#      missing / not executable)
#   2  usage error (unknown option, unexpected argument)
#   3  a group could not run here (it exited 3, UNAVAILABLE)
#
# Use errexit per doc/adr/0001-scripts-use-errexit.md. Expected non-zero
# statuses are captured explicitly to preserve the exit-code contract.

set -euo pipefail

# --- Constants ---------------------------------------------------------------
SCRIPT_NAME="all.sh"

EXIT_FAIL=1
EXIT_USAGE=2
EXIT_UNAVAILABLE=3

# The non-real-machine groups, in the order doc/acceptance.md lists them.
VERIFY_GROUPS=(ui gate setup diagram evidence)

# --- Paths -------------------------------------------------------------------
# Parameter expansion and the cd/pwd builtins only, like the group scripts.
_self="${BASH_SOURCE[0]}"
[[ "${_self}" == */* ]] || _self="./${_self}"
if ! SCRIPT_DIR="$(cd -- "${_self%/*}" && pwd -P)"; then
    printf '[ERROR] %s: cannot resolve own directory from %s\n' \
        "${SCRIPT_NAME}" "${BASH_SOURCE[0]}" >&2
    exit "${EXIT_UNAVAILABLE}"
fi

# --- Diagnostics -------------------------------------------------------------
_info() { printf '[INFO] %s\n' "$*" >&2; }

_err() { printf '[ERROR] %s: %s\n' "${SCRIPT_NAME}" "$*" >&2; }

_usage_error() {
    printf '%s: %s (see --help)\n' "${SCRIPT_NAME}" "$1" >&2
    exit "${EXIT_USAGE}"
}

# --- Usage -------------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: all.sh

Run every non-real-machine acceptance group of doc/acceptance.md, in order:
ui gate setup diagram evidence. Each group runs all of its items; the run
stops at the first group that fails. realbox is not run - it needs
--allow-real-box on a real host (just verify realbox --allow-real-box ...).

  -l, --list   List the groups this runs, in order, then exit.
  -h, --help   Show this help and exit.

Each group's own output passes through. After each group a summary line
`verify all: <group> PASS|FAIL (rc=N)|UNAVAILABLE (rc=3)` is printed, and
the run ends with one `verify all: VERDICT ...` line.

Exit codes: 0 every group passed, 1 a group failed, 2 usage error, 3 a
group could not run here (UNAVAILABLE - never a silent skip).
EOF
}

# --- Runner ------------------------------------------------------------------

# Join the words of "$@" with spaces, or print `none` when there are none.
_words_or_none() {
    if [[ "$#" -eq 0 ]]; then
        printf 'none'
    else
        printf '%s' "$*"
    fi
}

# Run group $1's script with no argument; store its exit status in the
# variable named by $2. A script that is missing or not executable is
# status 1 with the reason on stderr - never a skip.
_run_group() {
    local _group="$1"
    local -n _rc_ref="$2"
    local _script="${SCRIPT_DIR}/${_group}.sh"
    _rc_ref=0
    if [[ ! -f "${_script}" ]]; then
        _err "group ${_group}: ${_script} does not exist - the group cannot be verified"
        _rc_ref="${EXIT_FAIL}"
        return 0
    fi
    if [[ ! -x "${_script}" ]]; then
        _err "group ${_group}: ${_script} is not executable - the group cannot be verified"
        _rc_ref="${EXIT_FAIL}"
        return 0
    fi
    _info "verify all: group ${_group} (${_script})"
    "${_script}" || _rc_ref=$?
    return 0
}

main() {
    local _arg _help=0 _list=0
    while [[ "$#" -gt 0 ]]; do
        _arg="$1"
        case "${_arg}" in
            -h | --help)
                _help=1
                ;;
            -l | --list)
                _list=1
                ;;
            -*)
                _usage_error "unknown option '${_arg}'"
                ;;
            *)
                _usage_error "unexpected argument '${_arg}'"
                ;;
        esac
        shift
    done

    if [[ "${_help}" -eq 1 ]]; then
        _usage
        return 0
    fi
    if [[ "${_list}" -eq 1 ]]; then
        printf '%s\n' "${VERIFY_GROUPS[@]}"
        return 0
    fi
    _run_groups
}

_run_groups() {
    local _i _group _rc _passed=() _rest=()
    for _i in "${!VERIFY_GROUPS[@]}"; do
        _group="${VERIFY_GROUPS[${_i}]}"
        _run_group "${_group}" _rc
        if [[ "${_rc}" -eq 0 ]]; then
            printf 'verify all: %s PASS\n' "${_group}"
            _passed+=("${_group}")
            continue
        fi

        _rest=("${VERIFY_GROUPS[@]:$((_i + 1))}")
        if [[ "${_rc}" -eq "${EXIT_UNAVAILABLE}" ]]; then
            printf 'verify all: %s UNAVAILABLE (rc=%s)\n' "${_group}" "${_rc}"
        else
            printf 'verify all: %s FAIL (rc=%s)\n' "${_group}" "${_rc}"
        fi
        printf 'verify all: VERDICT FAIL at %s (rc=%s); passed: %s; not run: %s\n' \
            "${_group}" "${_rc}" "$(_words_or_none "${_passed[@]}")" \
            "$(_words_or_none "${_rest[@]}")"
        if [[ "${_rc}" -eq "${EXIT_UNAVAILABLE}" ]]; then
            exit "${EXIT_UNAVAILABLE}"
        fi
        exit "${EXIT_FAIL}"
    done

    printf 'verify all: VERDICT PASS (%s/%s groups: %s; realbox not run - it needs --allow-real-box on a real host)\n' \
        "${#_passed[@]}" "${#VERIFY_GROUPS[@]}" "${VERIFY_GROUPS[*]}"
    return 0
}

main "$@"
