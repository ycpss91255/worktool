#!/usr/bin/env bash
# ci.sh - worktool CI pipeline entry (ShellCheck + Bats), Docker only.
#
# Two sides of the same script (adapted, minimally, from init_ubuntu's
# script/ci/ci.sh shape):
#
#   Host side  - builds the test image if needed, then runs THIS script
#                back inside a throwaway container with the /source bind
#                mount. Selected by --lint-only / --unit-only /
#                --integration-only / --system-only / --acceptance-only.
#   Container  - runs the actual gate against the mounted source. Selected
#                by --ci-lint / --ci-unit / --ci-integration / --ci-system /
#                --ci-acceptance.
#
# All test execution happens inside the container (doc/design.md: Docker
# only). The host never installs packages.
#
# A bats tier gate is green ONLY if at least one case ran and none was
# skipped: bats exits 0 on skips, so the TAP stream is scanned and a skipped
# or missing required case fails the gate instead of reading as green.
#
# Usage:
#   ./script/ci/ci.sh --lint-only          # host: route lint into container
#   ./script/ci/ci.sh --unit-only          # host: route unit bats
#   ./script/ci/ci.sh --integration-only   # host: route integration bats
#   ./script/ci/ci.sh --system-only        # host: route system bats
#   ./script/ci/ci.sh --acceptance-only    # host: route acceptance bats
#   ./script/ci/ci.sh --build              # host: (re)build the test image
#   ./script/ci/ci.sh --ci-lint            # inside container: shellcheck
#   ./script/ci/ci.sh --ci-unit            # inside container: unit bats
#   ./script/ci/ci.sh --ci-integration     # inside container: integration bats
#   ./script/ci/ci.sh --ci-system          # inside container: system bats
#   ./script/ci/ci.sh --ci-acceptance      # inside container: acceptance bats
#
# Exit-code-contract script: default guards are `set -uo pipefail`
# (no `-e`); failures are surfaced explicitly via _die so a nonzero exit
# is always intentional.

set -uo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"

# Image tag for the test container. Overridable for CI (prebuilt + loaded).
TEST_IMAGE="${TEST_IMAGE:-worktool-test:local}"
DOCKERFILE="${REPO_ROOT}/dockerfile/Dockerfile.test"

# --- Logging -----------------------------------------------------------------
_info() { printf '[ci] %s\n' "$*" >&2; }

_die() {
    printf '[ci] ERROR: %s\n' "$*" >&2
    exit 1
}

# --- Host side: image + container --------------------------------------------

# Build the test image unless CI prebuilt it (TEST_IMAGE_PREBUILT=1).
_ensure_image() {
    if [[ "${TEST_IMAGE_PREBUILT:-}" == "1" ]]; then
        _info "using prebuilt image ${TEST_IMAGE}"
        return 0
    fi
    _info "building test image ${TEST_IMAGE}"
    docker build -t "${TEST_IMAGE}" -f "${DOCKERFILE}" "${REPO_ROOT}" \
        || _die "docker build failed"
}

# Run THIS script inside the test container with the source bind-mounted.
# $1 = in-container flag (e.g. --ci-unit).
_run_in_container() {
    local _flag="$1"
    command -v docker >/dev/null 2>&1 \
        || _die "docker not found on host - required (tests run in Docker only)"
    _ensure_image
    _info "running ${_flag} in ${TEST_IMAGE}"
    docker run --rm \
        -v "${REPO_ROOT}:/source" \
        -w /source \
        "${TEST_IMAGE}" \
        ./script/ci/ci.sh "${_flag}"
}

# --- Container side: gates ----------------------------------------------------

# Emit NUL-delimited lintable shell scripts. -print0 keeps paths with odd
# characters intact.
_find_lintable_sh() {
    find "${REPO_ROOT}" \
        -path "${REPO_ROOT}/.git" -prune -o \
        -type f -name '*.sh' -print0
}

_run_shellcheck() {
    _info "Running ShellCheck (*.sh + *.bats)"
    local _files=()
    while IFS= read -r -d '' _f; do
        _files+=("${_f}")
    done < <(_find_lintable_sh)
    # *.bats are bash under the hood; check them too (info-level findings
    # still fail the gate, matching init_ubuntu's lint policy).
    while IFS= read -r -d '' _f; do
        _files+=("${_f}")
    done < <(find "${REPO_ROOT}" -path "${REPO_ROOT}/.git" -prune -o \
        -type f -name '*.bats' -print0)

    if [[ "${#_files[@]}" -eq 0 ]]; then
        _info "  (no shell scripts to check - skipping)"
        return 0
    fi
    _info "  found ${#_files[@]} script(s)"
    # -x resolves `source`d files from disk. --shell=bash so *.bats parse.
    shellcheck -x --shell=bash "${_files[@]}" \
        || _die "ShellCheck failed - see violations above"
    _info "ShellCheck OK"
}

# Run one bats tier (test/<tier>/*.bats) as a gate. $1 = tier name.
#
# Green requires: specs exist, at least one case ran (no "1..0" plan), no
# case failed, and no case was skipped. The TAP stream is captured (and
# echoed) so skips can be detected - bats itself exits 0 on a skip.
_run_bats_tier() {
    local _tier="$1"
    local _dir="${REPO_ROOT}/test/${_tier}"
    _info "Running ${_tier} bats (test/${_tier}/)"
    if ! compgen -G "${_dir}/*.bats" >/dev/null; then
        _die "no ${_tier} specs found under ${_dir}"
    fi

    local _tap
    _tap="$(mktemp)" || _die "mktemp failed"
    if ! bats --formatter tap -r "${_dir}" | tee "${_tap}"; then
        rm -f "${_tap}"
        _die "${_tier} bats failed"
    fi
    if grep -qE '^1\.\.0$' "${_tap}"; then
        rm -f "${_tap}"
        _die "${_tier} bats ran zero cases - a missing required case is not green"
    fi
    if grep -qE '^ok [0-9]+ .*# skip' "${_tap}"; then
        rm -f "${_tap}"
        _die "${_tier} bats has skipped case(s) - a skipped required case is not green"
    fi
    rm -f "${_tap}"
    _info "${_tier} bats OK"
}

_run_unit()        { _run_bats_tier unit; }
_run_integration() { _run_bats_tier integration; }
_run_system()      { _run_bats_tier system; }
_run_acceptance()  { _run_bats_tier acceptance; }

# --- Dispatch ----------------------------------------------------------------
main() {
    local _mode="${1:-}"
    [[ -n "${_mode}" ]] || _die "no mode given (see header for usage)"
    case "${_mode}" in
        # Inside-container gates.
        --ci-lint)         _run_shellcheck ;;
        --ci-unit)         _run_unit ;;
        --ci-integration)  _run_integration ;;
        --ci-system)       _run_system ;;
        --ci-acceptance)   _run_acceptance ;;
        # Host-side routes into the container.
        --lint-only)        _run_in_container --ci-lint ;;
        --unit-only)        _run_in_container --ci-unit ;;
        --integration-only) _run_in_container --ci-integration ;;
        --system-only)      _run_in_container --ci-system ;;
        --acceptance-only)  _run_in_container --ci-acceptance ;;
        --build)            _ensure_image ;;
        *) _die "unknown mode: ${_mode}" ;;
    esac
}

# Guard: only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
