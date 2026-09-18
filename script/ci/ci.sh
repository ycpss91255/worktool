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
# A bats tier gate is green ONLY if every REQUIRED spec of the tier exists
# and defines at least one case (see _required_specs: the M2 specs, listed
# per tier), the TAP plan covers at least those cases, at least one case ran
# and none was skipped. bats exits 0 on skips and happily runs a tier whose
# required spec was deleted or emptied as long as some other spec remains,
# so the required list is checked per file BEFORE bats runs and the TAP
# stream is scanned AFTER: a missing, emptied or skipped required case fails
# the gate instead of reading as green. Additional (non-required) specs in a
# tier still run on top. This applies to both system groups.
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
# other test/system/*.bats is the shim group. The test/-relative form is the
# single source for both the exclusion below and the required list.
SYSTEM_REAL_SPEC_REL="system/real_engine_spec.bats"
SYSTEM_REAL_SPEC="${REPO_ROOT}/test/${SYSTEM_REAL_SPEC_REL}"

# --- Logging -----------------------------------------------------------------
_info() { printf '[ci] %s\n' "$*" >&2; }

_err() { printf '[ci] ERROR: %s\n' "$*" >&2; }

_die() {
    _err "$@"
    exit 1
}

# --- Required specs per tier -------------------------------------------------

# Print the REQUIRED spec files of tier $1, test/-relative, one per line.
# This is the M2 contract: a tier is red when any of these is missing or
# defines zero cases, no matter what else runs in the tier. Every other
# *.bats under the tier is additional and still runs. Returns 1 (prints
# nothing) for an unknown tier, so a tier without a declared list can never
# pass by accident.
_required_specs() {
    case "$1" in
        unit)
            printf '%s\n' \
                unit/log_spec.bats \
                unit/manifest_spec.bats \
                unit/assemble_spec.bats \
                unit/ci_gate_spec.bats \
                unit/system_real_entry_spec.bats
            ;;
        integration)
            printf '%s\n' \
                integration/smoke_spec.bats \
                integration/assemble_spec.bats
            ;;
        system)      printf '%s\n' system/real_assemble_spec.bats ;;
        system-real) printf '%s\n' "${SYSTEM_REAL_SPEC_REL}" ;;
        acceptance)  printf '%s\n' acceptance/m2_selfcheck_spec.bats ;;
        *)           return 1 ;;
    esac
}

# Check every required spec of tier $1 BEFORE bats runs: the file must exist
# and define at least one case (`bats --count` parses the file without
# running it, so an emptied file reads as 0). Stores the required case total
# in the variable named by $2, for the TAP plan check after the run.
_check_required_specs() {
    local _tier="$1"
    local -n _total_out="$2"
    local _rel _abs _n _total=0 _seen=0
    while IFS= read -r _rel; do
        [[ -n "${_rel}" ]] || continue
        _seen=1
        _abs="${REPO_ROOT}/test/${_rel}"
        [[ -f "${_abs}" ]] \
            || _die "${_tier} required spec missing: test/${_rel}"
        _n="$(bats --count "${_abs}")"
        if [[ ! "${_n}" =~ ^[0-9]+$ ]]; then
            _die "${_tier} required spec unreadable by bats: test/${_rel}"
        fi
        [[ "${_n}" -gt 0 ]] \
            || _die "${_tier} required spec defines zero cases: test/${_rel}"
        _total=$(( _total + _n ))
    done < <(_required_specs "${_tier}")
    [[ "${_seen}" -eq 1 ]] \
        || _die "${_tier}: no required specs declared (add them to _required_specs)"
    _info "  required specs OK (${_total} case(s) declared by $(_required_specs "${_tier}" | wc -l) file(s))"
    _total_out="${_total}"
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

# Check the captured TAP stream of tier $1 in file $2 after the run: a plan
# was emitted, at least one case ran (no "1..0"), the plan covers at least
# the $3 cases the required specs define, and no case was skipped (bats
# itself exits 0 on a skip). Prints the reason and returns 1 on any miss.
_verify_tap() {
    local _tier="$1" _tap="$2" _min="$3" _plan
    _plan="$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' "${_tap}" | head -n 1)"
    if [[ ! "${_plan}" =~ ^[0-9]+$ ]]; then
        _err "${_tier} bats emitted no TAP plan"
        return 1
    fi
    if [[ "${_plan}" -eq 0 ]]; then
        _err "${_tier} bats ran zero cases - a missing required case is not green"
        return 1
    fi
    if [[ "${_plan}" -lt "${_min}" ]]; then
        _err "${_tier} bats plan (${_plan}) is below the required specs' case total (${_min})"
        return 1
    fi
    if grep -qE '^ok [0-9]+ .*# skip' "${_tap}"; then
        _err "${_tier} bats has skipped case(s) - a skipped required case is not green"
        return 1
    fi
    return 0
}

# Run one bats tier as a gate. $1 = tier label; the remaining arguments are
# the spec paths (files or directories, handed to `bats -r`) that make up
# the tier. Omit them to run every test/<tier>/*.bats.
#
# Green requires: the paths exist, every required spec of the tier exists
# and defines cases (_check_required_specs, before bats runs), no case
# failed, and the TAP stream passes _verify_tap (plan covers the required
# cases, nothing skipped). The stream is captured (and echoed) for that.
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

    local _min
    _check_required_specs "${_tier}" _min

    local _tap
    _tap="$(mktemp)" || _die "mktemp failed"
    if ! bats --formatter tap -r "${_paths[@]}" | tee "${_tap}"; then
        rm -f "${_tap}"
        _die "${_tier} bats failed"
    fi
    local _ok=0
    _verify_tap "${_tier}" "${_tap}" "${_min}" || _ok=1
    rm -f "${_tap}"
    [[ "${_ok}" -eq 0 ]] || exit 1
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
