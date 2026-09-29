#!/usr/bin/env bash
# selfcheck.sh - one-shot self-check of the delivered M2 assemble wrapper.
#
# The public entry point a user runs after cloning (doc/manifest.md 3g) to
# confirm the delivered wrapper behaves as documented, without distrobox and
# without touching the host (dry-run only):
#
#   3a  from the repo root, dry-run prints exactly
#       `distrobox assemble create --file box/dev.ini`
#   3b  from outside the repo, dry-run prints the resolved ABSOLUTE manifest
#       path (validation, dry-run output and the real call share one path)
#   3c-3e  every documented invalid manifest (missing image, blank name,
#       blank / space-then-quoted / single-quoted-blank image, an image
#       with an unbalanced quote, multiple sections) is rejected with
#       exit 1, an EMPTY stdout, and the documented [ERROR] message
#
# Output contract (stdout): one `PASS <check>` / `FAIL <check>: <detail>`
# line per check, then `ALL PASS` (exit 0) or `SOME FAILED` (exit 1). Usage
# errors exit 2 with an [ERROR] on stderr. The acceptance tier
# (test/acceptance/) runs this exact script and asserts on that contract.
#
# Usage (the backing script of `just test selfcheck`, which forwards its
# arguments here verbatim; it also runs on its own):
#   ./script/test/selfcheck.sh                 # check the checkout this script lives in
#   ./script/test/selfcheck.sh --root <repo>   # check another checkout
#   ./script/test/selfcheck.sh --help          # usage
#
# This script owns its option validation: an unknown option is refused with
# `selfcheck.sh: unknown option '<x>' (see --help)` on stderr, exit 2,
# before any check runs.
#
# Guards: `set -euo pipefail` (doc/adr/0001-scripts-use-errexit.md): an
# unhandled failure stops the script at once. A non-zero status the script
# EXPECTS is handled explicitly (`if ! cmd`, `cmd || _rc=$?`), never
# swallowed with `|| true`, so every exit code documented here stays the
# script's own.

# shellcheck source-path=SCRIPTDIR/../../lib
set -euo pipefail

# --- Paths -------------------------------------------------------------------
# The repo root is two levels up from script/test/; the wrapper under test
# lives at script/box/assemble.sh relative to whichever root is checked.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
ASSEMBLE_REL="script/box/assemble.sh"

# shellcheck source=log.sh
source "${SELF_ROOT}/lib/log.sh"

# Globals set by selfcheck_run (kept global so the EXIT trap can read them).
SELFCHECK_ROOT=""
SELFCHECK_TMP=""
SELFCHECK_FAILED=0

# --- Helpers -----------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: selfcheck.sh [--root <repo>]

  --root <repo>  worktool checkout to check (default: the one this script
                 lives in).
  -h, --help     Show this help and exit.
EOF
}

# Refuse the command line: one line on stderr (the caller returns 2; no
# check has run yet).
_usage_error() {
    printf 'selfcheck.sh: %s (see --help)\n' "$1" >&2
}

# The EXIT trap: an `if`, not `[[ ... ]] && rm`, so nothing to remove still
# returns 0 - a trap that fails under errexit would replace the run's exit
# status with its own.
_cleanup() {
    if [[ -n "${SELFCHECK_TMP}" ]]; then
        rm -rf -- "${SELFCHECK_TMP}"
    fi
}

# Result reporting. FAIL lines carry the detail that would let a user see
# what went wrong without re-running anything.
_pass() { printf 'PASS %s\n' "$1"; }
_fail() {
    printf 'FAIL %s: %s\n' "$1" "$2"
    SELFCHECK_FAILED=1
}

# Dry-run contract: run the wrapper from directory $2 with the wrapper path
# $3 and compare its stdout to $4. Label is $1.
_check_dry_run() {
    local _label="$1" _cwd="$2" _wrapper="$3" _expected="$4"
    local _out _err _rc=0
    _err="${SELFCHECK_TMP}/${_label}.err"
    _out="$(cd -- "${_cwd}" && WORKTOOL_DRY_RUN=1 bash "${_wrapper}" 2>"${_err}")" \
        || _rc=$?
    if [[ "${_rc}" -eq 0 && "${_out}" == "${_expected}" ]]; then
        _pass "${_label}"
    else
        _fail "${_label}" "rc=${_rc} stdout='${_out}' stderr='$(cat "${_err}")'"
    fi
}

# Rejection contract: the wrapper, run from the repo root against manifest
# $1, must exit 1, print NOTHING on stdout, and mention $2 on stderr.
_check_reject() {
    local _manifest="$1" _expected_msg="$2"
    local _label _out _err _rc=0
    _label="reject $(basename -- "${_manifest}")"
    _err="${SELFCHECK_TMP}/$(basename -- "${_manifest}").err"
    _out="$(cd -- "${SELFCHECK_ROOT}" \
        && bash "${ASSEMBLE_REL}" --file "${_manifest}" 2>"${_err}")" || _rc=$?
    # No stderr file means the wrapper never ran (the cd failed): an empty
    # stderr in the FAIL line, not a failed `cat` that ends the self-check.
    local _errtext=""
    if [[ -f "${_err}" ]]; then
        _errtext="$(cat -- "${_err}")"
    fi
    if [[ "${_rc}" -eq 1 && -z "${_out}" && "${_errtext}" == *"${_expected_msg}"* ]]; then
        _pass "${_label}"
    else
        _fail "${_label}" "rc=${_rc} stdout='${_out}' stderr='${_errtext}'"
    fi
}

# --- Main --------------------------------------------------------------------
# Parse the command line into SELFCHECK_ROOT. The whole line is parsed
# before any check runs, so an unknown option anywhere in it refuses the
# run as a whole. Returns 0 to continue, 3 when --help was served (the
# caller exits 0), 2 on a usage error.
_parse_options() {
    local _help=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)
                shift
                if [[ $# -eq 0 ]]; then
                    _usage_error "--root requires a path argument"
                    return 2
                fi
                SELFCHECK_ROOT="$1"
                ;;
            --root=*) SELFCHECK_ROOT="${1#*=}" ;;
            # Recorded, not served: `--help --bogus` is a usage error.
            -h|--help) _help=1 ;;
            *)
                _usage_error "unknown option '$1'"
                return 2
                ;;
        esac
        shift
    done
    if [[ "${_help}" -eq 1 ]]; then
        _usage
        return 3
    fi
    return 0
}

# The root must be a worktool checkout: a directory holding the wrapper
# under test. Anything else is a usage error (2), not a FAIL. Normalises
# SELFCHECK_ROOT to an absolute path.
_resolve_root() {
    if [[ ! -d "${SELFCHECK_ROOT}" ]]; then
        log_error "--root is not a directory: ${SELFCHECK_ROOT}"
        return 2
    fi
    SELFCHECK_ROOT="$(cd -- "${SELFCHECK_ROOT}" && pwd -P)"
    if [[ ! -f "${SELFCHECK_ROOT}/${ASSEMBLE_REL}" ]]; then
        log_error "not a worktool checkout (missing ${ASSEMBLE_REL}): ${SELFCHECK_ROOT}"
        return 2
    fi
    return 0
}

# 3c-3e: documented invalid manifests are rejected (exit 1, empty stdout,
# documented [ERROR] message), and never reach distrobox. The
# single-quoted blank matters because distrobox-assemble sources each
# value as a shell assignment, where '   ' is as blank as "   "; for the
# same reason an unbalanced outer quote ('ubuntu:26.04") is a shell
# syntax error upstream and must be caught here, with its own message.
_check_documented_rejections() {
    printf '[dev]\n'                                    >"${SELFCHECK_TMP}/no-image.ini"
    printf '[   ]\nimage=ubuntu:26.04\n'                >"${SELFCHECK_TMP}/blank-name.ini"
    printf '[dev]\nimage="   "\n'                       >"${SELFCHECK_TMP}/blank-image.ini"
    printf '[dev]\nimage= "   "\n'                      >"${SELFCHECK_TMP}/spaced-image.ini"
    printf "[dev]\nimage='   '\n"                       >"${SELFCHECK_TMP}/single-quoted-image.ini"
    printf "[dev]\nimage='ubuntu:26.04\"\n"             >"${SELFCHECK_TMP}/unbalanced-quote-image.ini"
    printf '[dev]\nimage=ubuntu:26.04\n[b]\nimage=x\n'  >"${SELFCHECK_TMP}/multi.ini"
    _check_reject "${SELFCHECK_TMP}/no-image.ini"               "missing required key 'image'"
    _check_reject "${SELFCHECK_TMP}/blank-name.ini"             "missing box name"
    _check_reject "${SELFCHECK_TMP}/blank-image.ini"            "missing required key 'image'"
    _check_reject "${SELFCHECK_TMP}/spaced-image.ini"           "missing required key 'image'"
    _check_reject "${SELFCHECK_TMP}/single-quoted-image.ini"    "missing required key 'image'"
    _check_reject "${SELFCHECK_TMP}/unbalanced-quote-image.ini" "unbalanced quote"
    _check_reject "${SELFCHECK_TMP}/multi.ini"                  "multiple sections"
}

selfcheck_run() {
    SELFCHECK_ROOT="${SELF_ROOT}"
    SELFCHECK_FAILED=0

    local _rc=0
    _parse_options "$@" || _rc=$?
    [[ "${_rc}" -ne 3 ]] || return 0
    [[ "${_rc}" -eq 0 ]] || return "${_rc}"
    _resolve_root || return $?

    SELFCHECK_TMP="$(mktemp -d)" || { log_error "mktemp failed"; return 2; }
    trap _cleanup EXIT

    log_info "self-checking ${SELFCHECK_ROOT}"

    # 3a: from the repo root the default manifest stays relative.
    _check_dry_run 3a "${SELFCHECK_ROOT}" "${ASSEMBLE_REL}" \
        "distrobox assemble create --file box/dev.ini"

    # 3b: from outside the repo the wrapper resolves (and emits) the absolute
    # path, shell-escaped per argument exactly as the wrapper prints it.
    local _abs_quoted
    printf -v _abs_quoted '%q' "${SELFCHECK_ROOT}/box/dev.ini"
    _check_dry_run 3b "${SELFCHECK_TMP}" "${SELFCHECK_ROOT}/${ASSEMBLE_REL}" \
        "distrobox assemble create --file ${_abs_quoted}"

    # 3c-3e.
    _check_documented_rejections

    if [[ "${SELFCHECK_FAILED}" -eq 0 ]]; then
        printf 'ALL PASS\n'
        return 0
    fi
    printf 'SOME FAILED\n'
    return 1
}

# Guard: only run when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    selfcheck_run "$@"
fi
