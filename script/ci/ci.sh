#!/usr/bin/env bash
# ci.sh - worktool CI pipeline entry (ShellCheck + Bats), Docker only.
#
# Two sides of the same script (adapted, minimally, from init_ubuntu's
# script/ci/ci.sh shape):
#
#   Host side  - builds the test image if needed, then runs THIS script
#                back inside a throwaway container with the /source bind
#                mount. Selected by --lint-only / --unit-only /
#                --integration-only.
#   Container  - runs the actual gate against the mounted source. Selected
#                by --ci-lint / --ci-unit / --ci-integration.
#
# All test execution happens inside the container (doc/design.md: Docker
# only). The host never installs packages.
#
# Usage:
#   ./script/ci/ci.sh --lint-only          # host: route lint into container
#   ./script/ci/ci.sh --unit-only          # host: route unit bats
#   ./script/ci/ci.sh --integration-only   # host: route integration bats
#   ./script/ci/ci.sh --build              # host: (re)build the test image
#   ./script/ci/ci.sh --ci-lint            # inside container: shellcheck
#   ./script/ci/ci.sh --ci-unit            # inside container: unit bats
#   ./script/ci/ci.sh --ci-integration     # inside container: integration bats
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

_run_unit() {
    _info "Running unit bats (test/unit/)"
    local _dir="${REPO_ROOT}/test/unit"
    if ! compgen -G "${_dir}/*.bats" >/dev/null; then
        _die "no unit specs found under ${_dir}"
    fi
    bats -r "${_dir}" || _die "unit bats failed"
    _info "unit bats OK"
}

_run_integration() {
    _info "Running integration bats (test/integration/)"
    local _dir="${REPO_ROOT}/test/integration"
    if ! compgen -G "${_dir}/*.bats" >/dev/null; then
        _die "no integration specs found under ${_dir}"
    fi
    bats -r "${_dir}" || _die "integration bats failed"
    _info "integration bats OK"
}

# --- Dispatch ----------------------------------------------------------------
main() {
    local _mode="${1:-}"
    [[ -n "${_mode}" ]] || _die "no mode given (see header for usage)"
    case "${_mode}" in
        # Inside-container gates.
        --ci-lint)         _run_shellcheck ;;
        --ci-unit)         _run_unit ;;
        --ci-integration)  _run_integration ;;
        # Host-side routes into the container.
        --lint-only)        _run_in_container --ci-lint ;;
        --unit-only)        _run_in_container --ci-unit ;;
        --integration-only) _run_in_container --ci-integration ;;
        --build)            _ensure_image ;;
        *) _die "unknown mode: ${_mode}" ;;
    esac
}

# Guard: only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
