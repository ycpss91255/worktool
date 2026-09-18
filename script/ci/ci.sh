#!/usr/bin/env bash
# ci.sh - worktool CI pipeline entry (ShellCheck + Bats), Docker only.
#
# Two sides of the same script (adapted, minimally, from init_ubuntu's
# script/ci/ci.sh shape):
#
#   Host side  - builds the test image if needed, then runs THIS script
#                back inside a throwaway container with the /source bind
#                mount. Selected by --lint-only / --unit-only /
#                --integration-only / --system-only / --system-real-only /
#                --acceptance-only.
#   Container  - runs the actual gate against the mounted source. Selected
#                by --ci-lint / --ci-unit / --ci-integration / --ci-system /
#                --ci-system-real / --ci-acceptance.
#
# All test execution happens inside the container (doc/design.md: Docker
# only). The host never installs packages.
#
# The system tier has two groups (doc/manifest.md 測試對應):
#   shim        (--system-only)      every test/system/*.bats except the
#               real-engine spec; the real pinned distrobox against the fake
#               container manager, in the plain test image. Fast.
#   real-engine (--system-real-only) test/system/real_engine_spec.bats only;
#               needs a live docker daemon, so it runs in the dedicated
#               docker-in-docker runner image (dockerfile/Dockerfile.system-real)
#               started with `docker run --rm --privileged`, whose entry
#               (script/ci/system-real-entry.sh) starts dockerd and then calls
#               back into --ci-system-real. --privileged is used ONLY here.
#
# A bats tier gate is green ONLY if at least one case ran and none was
# skipped: bats exits 0 on skips, so the TAP stream is scanned and a skipped
# or missing required case fails the gate instead of reading as green. This
# applies to both system groups.
#
# Usage:
#   ./script/ci/ci.sh --lint-only          # host: route lint into container
#   ./script/ci/ci.sh --unit-only          # host: route unit bats
#   ./script/ci/ci.sh --integration-only   # host: route integration bats
#   ./script/ci/ci.sh --system-only        # host: route system bats (shim group)
#   ./script/ci/ci.sh --system-real-only   # host: real-engine group, DinD runner (--privileged)
#   ./script/ci/ci.sh --acceptance-only    # host: route acceptance bats
#   ./script/ci/ci.sh --build              # host: (re)build the test image
#   ./script/ci/ci.sh --ci-lint            # inside container: shellcheck
#   ./script/ci/ci.sh --ci-unit            # inside container: unit bats
#   ./script/ci/ci.sh --ci-integration     # inside container: integration bats
#   ./script/ci/ci.sh --ci-system          # inside container: system bats (shim group)
#   ./script/ci/ci.sh --ci-system-real     # inside the DinD runner: real-engine bats
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

# Docker-in-docker runner for the real-engine system group (built on demand;
# never shared with the other gates, since it is the only --privileged one).
SYSTEM_REAL_IMAGE="${SYSTEM_REAL_IMAGE:-worktool-system-real:local}"
SYSTEM_REAL_DOCKERFILE="${REPO_ROOT}/dockerfile/Dockerfile.system-real"
SYSTEM_REAL_ENTRY="./script/ci/system-real-entry.sh"

# The one system spec that needs a real engine (real-engine group). Every
# other test/system/*.bats is the shim group.
SYSTEM_REAL_SPEC="${REPO_ROOT}/test/system/real_engine_spec.bats"

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

# Build the docker-in-docker runner image (always built here: it is not part
# of the prebuilt test-image artifact and its Dockerfile is self-contained).
_ensure_system_real_image() {
    _info "building system-real runner image ${SYSTEM_REAL_IMAGE}"
    docker build -t "${SYSTEM_REAL_IMAGE}" -f "${SYSTEM_REAL_DOCKERFILE}" "${REPO_ROOT}" \
        || _die "docker build of the system-real runner failed"
}

# Run the real-engine system group in the DinD runner. This is the ONLY
# place --privileged is used: the runner starts its own dockerd, and every
# container / image / volume the test creates lives in that nested daemon
# and is destroyed with the runner (--rm also drops the dind image's
# anonymous /var/lib/docker volume). The host daemon never sees the box.
_run_system_real_in_runner() {
    command -v docker >/dev/null 2>&1 \
        || _die "docker not found on host - required (tests run in Docker only)"
    _ensure_system_real_image
    _info "running --ci-system-real in ${SYSTEM_REAL_IMAGE} (docker-in-docker, --privileged)"
    docker run --rm --privileged \
        -v "${REPO_ROOT}:/source" \
        -w /source \
        "${SYSTEM_REAL_IMAGE}" \
        "${SYSTEM_REAL_ENTRY}"
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

# Run one bats tier as a gate. $1 = tier label; the remaining arguments are
# the spec paths (files or directories, handed to `bats -r`) that make up
# the tier. Omit them to run every test/<tier>/*.bats.
#
# Green requires: specs exist, at least one case ran (no "1..0" plan), no
# case failed, and no case was skipped. The TAP stream is captured (and
# echoed) so skips can be detected - bats itself exits 0 on a skip.
_run_bats_tier() {
    local _tier="$1"
    shift
    local _paths=("$@")
    if [[ "${#_paths[@]}" -eq 0 ]]; then
        local _dir="${REPO_ROOT}/test/${_tier}"
        _info "Running ${_tier} bats (test/${_tier}/)"
        compgen -G "${_dir}/*.bats" >/dev/null \
            || _die "no ${_tier} specs found under ${_dir}"
        _paths=("${_dir}")
    else
        _info "Running ${_tier} bats (${_paths[*]#"${REPO_ROOT}/"})"
        local _p
        for _p in "${_paths[@]}"; do
            [[ -e "${_p}" ]] || _die "no ${_tier} specs found: ${_p} is missing"
        done
    fi

    local _tap
    _tap="$(mktemp)" || _die "mktemp failed"
    if ! bats --formatter tap -r "${_paths[@]}" | tee "${_tap}"; then
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
_run_acceptance()  { _run_bats_tier acceptance; }

# System tier, shim group: every test/system/*.bats except the real-engine
# spec (which needs a live daemon and has its own runner).
_run_system() {
    local _specs=() _f
    for _f in "${REPO_ROOT}"/test/system/*.bats; do
        [[ -f "${_f}" ]] || continue
        [[ "${_f}" == "${SYSTEM_REAL_SPEC}" ]] && continue
        _specs+=("${_f}")
    done
    [[ "${#_specs[@]}" -gt 0 ]] \
        || _die "no system (shim group) specs found under ${REPO_ROOT}/test/system"
    _run_bats_tier system "${_specs[@]}"
}

# System tier, real-engine group: exactly the real-engine spec, run by the
# DinD runner entry once its nested dockerd is up. Same green rules: the spec
# must exist, run at least one case, and skip nothing.
_run_system_real() { _run_bats_tier system-real "${SYSTEM_REAL_SPEC}"; }

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
        --ci-system-real)  _run_system_real ;;
        --ci-acceptance)   _run_acceptance ;;
        # Host-side routes into the container.
        --lint-only)        _run_in_container --ci-lint ;;
        --unit-only)        _run_in_container --ci-unit ;;
        --integration-only) _run_in_container --ci-integration ;;
        --system-only)      _run_in_container --ci-system ;;
        --system-real-only) _run_system_real_in_runner ;;
        --acceptance-only)  _run_in_container --ci-acceptance ;;
        --build)            _ensure_image ;;
        *) _die "unknown mode: ${_mode}" ;;
    esac
}

# Guard: only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
