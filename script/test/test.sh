#!/usr/bin/env bash
# test.sh - worktool self-test runner (ShellCheck + Bats), Docker only.
#
# The backing script of the `just test` namespace (script/test/justfile.test
# forwards every `just test ...` here verbatim); it also runs on its own.
# Two sides of the same script (adapted, minimally, from init_ubuntu's
# script/ci/ci.sh shape):
#
#   Host side  - builds the test image if needed, then runs THIS script
#                back inside a throwaway container with the /source bind
#                mount. Selected by --lint / --unit / --integration /
#                --system / --system-real / --acceptance; NO option runs
#                all of them, in that order, stopping at the first failure.
#   Container  - runs the actual gate against the mounted source. Selected
#                by --ci-lint / --ci-unit / --ci-integration /
#                --ci-integration-ghostty / --ci-system / --ci-system-real /
#                --ci-acceptance (internal).
#
# All test execution happens inside the container (doc/design.md: Docker
# only). The host never installs packages.
#
# The system tier has two groups (doc/manifest.md 測試對應):
#   shim        (--system)      every test/system/*.bats except the
#               real-engine spec; the real pinned distrobox against the fake
#               container manager, in the plain test image. Fast.
#   real-engine (--system-real) test/system/real_engine_spec.bats only;
#               needs a live docker daemon, so it runs in the dedicated
#               docker-in-docker runner image (dockerfile/Dockerfile.system-real)
#               started with `docker run --rm --privileged`, whose entry
#               (script/test/system-real-entry.sh) starts dockerd and then
#               calls back into --ci-system-real. --privileged is used ONLY
#               here.
#
# The integration tier has two groups for the same reason (M3, issue #172):
#   default (--integration)  every test/integration/*.bats except the
#               ghostty spec, in the plain test image. Fast.
#   ghostty (--integration)  test/integration/ghostty_config_spec.bats only;
#               needs a REAL ghostty, which only Ubuntu 26.04 packages, so
#               it runs in dockerfile/Dockerfile.ghostty. No display, no
#               daemon, no --privileged. `--integration` runs BOTH groups
#               (default first), so `just test integration` stays the one
#               command a user types; each group is a gate of its own with
#               the same tier rules (required spec present and non-empty,
#               at least one case, no failure, no skip).
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
# Usage: `./script/test/test.sh --help` (see _usage). This script owns its
# option validation: an unknown option is refused with exit 2 before
# anything runs, so the justfile in front of it never has to.
#
# Guards: `set -euo pipefail` (doc/adr/0001-scripts-use-errexit.md): an
# unhandled failure stops the script at once. A non-zero status the script
# EXPECTS is handled explicitly (`if ! cmd`, `cmd || _rc=$?`), never
# swallowed with `|| true`, so every exit code documented here stays the
# script's own.

set -euo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"

# Image tag for the test container. Overridable for CI (prebuilt + loaded).
TEST_IMAGE="${TEST_IMAGE:-worktool-test:local}"
DOCKERFILE="${REPO_ROOT}/dockerfile/Dockerfile.test"
WORKTOOL_TEST_JOBS="${WORKTOOL_TEST_JOBS:-4}"

# Docker-in-docker runner for the real-engine system group (built on demand;
# never shared with the other gates, since it is the only --privileged one).
SYSTEM_REAL_IMAGE="${SYSTEM_REAL_IMAGE:-worktool-system-real:local}"
SYSTEM_REAL_DOCKERFILE="${REPO_ROOT}/dockerfile/Dockerfile.system-real"
SYSTEM_REAL_ENTRY="./script/test/system-real-entry.sh"

# Ubuntu 26.04 image for the ghostty group of the integration tier (built
# on demand, like the DinD runner: it is not part of the prebuilt
# test-image artifact). It carries a REAL ghostty; no display, no daemon
# and no --privileged are involved.
GHOSTTY_IMAGE="${GHOSTTY_IMAGE:-worktool-ghostty:local}"
GHOSTTY_DOCKERFILE="${REPO_ROOT}/dockerfile/Dockerfile.ghostty"

# The one integration spec that needs a real ghostty (ghostty group).
# Every other test/integration/*.bats is the default group. The
# test/-relative form is the single source for both the exclusion below
# and the required list.
INTEGRATION_GHOSTTY_SPEC_REL="integration/ghostty_config_spec.bats"
INTEGRATION_GHOSTTY_SPEC="${REPO_ROOT}/test/${INTEGRATION_GHOSTTY_SPEC_REL}"

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
                unit/system_real_entry_spec.bats \
                unit/test_sh_spec.bats \
                unit/selfcheck_spec.bats \
                unit/justfile_spec.bats \
                unit/diagram_spec.bats \
                unit/ci_yml_spec.bats \
                unit/bench_spec.bats \
                unit/ghostty_fixture_spec.bats \
                unit/setup_spec.bats \
                unit/status_spec.bats \
                unit/enter_spec.bats \
                unit/workflow_spec.bats \
                unit/approval_spec.bats \
                unit/commit_attribution_spec.bats \
                unit/commit_email_spec.bats \
                unit/attribution_spec.bats \
                unit/milestone_gate_yml_spec.bats \
                unit/agent_config_spec.bats \
                unit/adr_spec.bats \
                unit/adr/0005_spec.bats \
                unit/adr/0006_spec.bats \
                unit/adr/0010_spec.bats \
                unit/contract_spec.bats \
                unit/hook/hook_bootstrap_spec.bats \
                unit/hook/subcommand_spec.bats \
                unit/hook/test_must_use_docker_spec.bats \
                unit/hook/enforce_long_job_timeout_spec.bats \
                unit/hook/check_main_fresh_before_worktree_spec.bats \
                unit/hook/remind_main_sync_spec.bats \
                unit/hook/enforce_gh_body_file_spec.bats \
                unit/hook/enforce_no_local_paths_spec.bats \
                unit/hook/enforce_milestone_gate_approval_representative_spec.bats \
                unit/hook/enforce_scope_on_guard_issues_spec.bats \
                unit/hook/enforce_issue_milestone_spec.bats \
                unit/hook/enforce_no_attribution_spec.bats \
                unit/hook/enforce_shellcheck_disable_approval_spec.bats \
                unit/hook/enforce_codex_round_cap_spec.bats \
                unit/hook/enforce_cpu_capacity_spec.bats \
                unit/hook/enforce_tdd_commit_representative_spec.bats \
                unit/hook/approval_check_spec.bats \
                unit/hook/disable_diff_spec.bats \
                unit/hook/transcript_reader_spec.bats \
                unit/hook/worktree_create_spec.bats \
                unit/hook/remind_workflow_tdd_spec.bats \
                unit/hook/remind_no_emoji_spec.bats \
                unit/hook/enforce_reply_language_spec.bats \
                unit/script/wait_pr_ci_spec.bats \
                unit/script/watch_user_replies_spec.bats
            ;;
        matrix)
            printf '%s\n' \
                matrix/enforce_milestone_gate_approval_spec.bats \
                matrix/enforce_no_attribution_spec.bats \
                matrix/enforce_tdd_commit_spec.bats
            ;;
        integration)
            printf '%s\n' \
                integration/smoke_spec.bats \
                integration/assemble_spec.bats \
                integration/setup_spec.bats \
                integration/enter_spec.bats
            ;;
        integration-ghostty) printf '%s\n' "${INTEGRATION_GHOSTTY_SPEC_REL}" ;;
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
        # A count bats cannot produce is the gate's own failure, not bats'
        # exit status: handled here, never left to errexit.
        if ! _n="$(bats --count "${_abs}")" || [[ ! "${_n}" =~ ^[0-9]+$ ]]; then
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
    shift
    command -v docker >/dev/null 2>&1 \
        || _die "docker not found on host - required (tests run in Docker only)"
    _ensure_image
    _info "running ${_flag} in ${TEST_IMAGE}"
    docker run --rm -e WORKTOOL_TEST_JOBS \
        -v "${REPO_ROOT}:/source" \
        -w /source \
        "${TEST_IMAGE}" \
        ./script/test/test.sh "${_flag}" "$@"
}

# Build the ubuntu image that carries a real ghostty (always built here:
# like the DinD runner it is not part of the prebuilt test-image artifact
# and its Dockerfile is self-contained).
_ensure_ghostty_image() {
    _info "building ghostty image ${GHOSTTY_IMAGE}"
    docker build -t "${GHOSTTY_IMAGE}" -f "${GHOSTTY_DOCKERFILE}" "${REPO_ROOT}" \
        || _die "docker build of the ghostty image failed"
}

# Run the ghostty group of the integration tier in that image. Plain
# `docker run --rm`: the cases are CLI-only ghostty actions, so no
# display, no daemon and no extra privilege are needed.
_run_ghostty_in_container() {
    command -v docker >/dev/null 2>&1 \
        || _die "docker not found on host - required (tests run in Docker only)"
    _ensure_ghostty_image
    _info "running --ci-integration-ghostty in ${GHOSTTY_IMAGE}"
    docker run --rm \
        -v "${REPO_ROOT}:/source" \
        -w /source \
        "${GHOSTTY_IMAGE}" \
        ./script/test/test.sh --ci-integration-ghostty
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
# `-e CI` passes the host's CI through (only when it is set): bench.sh's
# quiet-host wait is 120 s instead of 60 s on CI (issue #181).
_run_system_real_in_runner() {
    command -v docker >/dev/null 2>&1 \
        || _die "docker not found on host - required (tests run in Docker only)"
    _ensure_system_real_image
    _info "running --ci-system-real in ${SYSTEM_REAL_IMAGE} (docker-in-docker, --privileged)"
    docker run --rm --privileged -e CI \
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
    # One awk, no `| head`: an unreadable stream is a missing plan (return
    # 1 below), and there is no early-closed pipe to fail under pipefail.
    if ! _plan="$(awk '/^1\.\.[0-9]+$/ { sub(/^1\.\./, ""); print; exit }' "${_tap}")" \
        || [[ ! "${_plan}" =~ ^[0-9]+$ ]]; then
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
    local _tier="$1" _filter="$2"
    shift 2
    local _paths=("$@") _partial=0
    [[ "${#_paths[@]}" -gt 0 || -n "${_filter}" ]] && _partial=1
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

    local _min=0
    if [[ "${_partial}" -eq 1 ]]; then
        _info "partial ${_tier} run; this does not stand for the whole tier"
    else
        _check_required_specs "${_tier}" _min
    fi

    local _tap
    _tap="$(mktemp)" || _die "mktemp failed"
    local _bats_args=(--formatter tap --jobs "${WORKTOOL_TEST_JOBS}"
        --no-parallelize-within-files -r)
    [[ -z "${_filter}" ]] || _bats_args+=(-f "${_filter}")
    if ! bats "${_bats_args[@]}" "${_paths[@]}" | tee "${_tap}"; then
        rm -f "${_tap}"
        _die "${_tier} bats failed"
    fi
    local _ok=0
    if [[ "${_partial}" -eq 0 ]]; then
        _verify_tap "${_tier}" "${_tap}" "${_min}" || _ok=1
    fi
    rm -f "${_tap}"
    [[ "${_ok}" -eq 0 ]] || exit 1
    _info "${_tier} bats OK"
}

_run_unit()        { _run_bats_tier unit "$@"; }
_run_matrix()      { _run_bats_tier matrix "$@"; }
_run_acceptance()  { _run_bats_tier acceptance "$@"; }

# Integration tier, default group: every test/integration/*.bats except
# the ghostty spec (which needs a real ghostty and has its own image).
_run_integration() {
    if [[ $# -gt 1 || -n "${1:-}" ]]; then
        _run_bats_tier integration "$@"
        return 0
    fi
    local _specs=() _f
    for _f in "${REPO_ROOT}"/test/integration/*.bats; do
        [[ -f "${_f}" ]] || continue
        [[ "${_f}" == "${INTEGRATION_GHOSTTY_SPEC}" ]] && continue
        _specs+=("${_f}")
    done
    [[ "${#_specs[@]}" -gt 0 ]] \
        || _die "no integration (default group) specs found under ${REPO_ROOT}/test/integration"
    _run_bats_tier integration "" "${_specs[@]}"
}

# Integration tier, ghostty group: exactly the ghostty spec, run in the
# ubuntu image that carries ghostty. Same green rules as every tier.
_run_integration_ghostty() {
    _run_bats_tier integration-ghostty "" "${INTEGRATION_GHOSTTY_SPEC}"
}

# System tier, shim group: every test/system/*.bats except the real-engine
# spec (which needs a live daemon and has its own runner).
_run_system() {
    if [[ $# -gt 1 || -n "${1:-}" ]]; then
        _run_bats_tier system "$@"
        return 0
    fi
    local _specs=() _f
    for _f in "${REPO_ROOT}"/test/system/*.bats; do
        [[ -f "${_f}" ]] || continue
        [[ "${_f}" == "${SYSTEM_REAL_SPEC}" ]] && continue
        _specs+=("${_f}")
    done
    [[ "${#_specs[@]}" -gt 0 ]] \
        || _die "no system (shim group) specs found under ${REPO_ROOT}/test/system"
    _run_bats_tier system "" "${_specs[@]}"
}

# System tier, real-engine group: exactly the real-engine spec, run by the
# DinD runner entry once its nested dockerd is up. Same green rules: the spec
# must exist, run at least one case, and skip nothing.
_run_system_real() { _run_bats_tier system-real "" "${SYSTEM_REAL_SPEC}"; }

# --- Usage -------------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: test.sh [OPTION...]

Run the worktool self-test. Everything runs inside Docker; the host only
needs docker. With no option, every step below runs in this order and the
run stops at the first failure:

  lint, unit, matrix, integration, system, acceptance, system-real

Options (each selects one step; several may be given and run in the order
given):
  --build         (Re)build the test image (worktool-test:local).
  --lint          ShellCheck over every *.sh and *.bats, in the container.
  --unit          Unit bats (test/unit/).
  --matrix        Full-product matrix bats (test/matrix/); slow, CI-required.
  --integration   Integration bats (test/integration/), BOTH groups: the
                  default one in the test image, then the ghostty one
                  (test/integration/ghostty_config_spec.bats) in the ubuntu
                  image that carries a real ghostty. No display needed.
  --system        System bats, shim group (test/system/ minus the real-engine
                  spec; real distrobox + fake container manager).
  --system-real   System bats, real-engine group (test/system/real_engine_spec
                  .bats) in the docker-in-docker runner - the ONLY step that
                  uses --privileged; slow.
  --acceptance    Acceptance bats (test/acceptance/).
  -h, --help      Show this help and exit.

Internal (what the steps above run inside the container; not for hosts):
  --ci-lint --ci-unit --ci-matrix --ci-integration --ci-integration-ghostty --ci-system
  --ci-system-real --ci-acceptance

Environment:
  TEST_IMAGE             test image tag (default worktool-test:local)
  TEST_IMAGE_PREBUILT=1  skip the test image build (CI loads a prebuilt one)
  WORKTOOL_TEST_JOBS     bats files to run in parallel (default 4)
  SYSTEM_REAL_IMAGE      DinD runner image tag (default worktool-system-real:local)
  GHOSTTY_IMAGE          ghostty image tag (default worktool-ghostty:local)
EOF
}

# Refuse the command line: one line on stderr, exit 2, nothing has run.
_usage_error() {
    printf 'test.sh: %s (see --help)\n' "$1" >&2
    exit 2
}

_tier_for_step() {
    case "$1" in
        unit|matrix|integration|system|acceptance) printf '%s\n' "$1" ;;
        --ci-unit|--ci-matrix|--ci-integration|--ci-system|--ci-acceptance)
            printf '%s\n' "${1#--ci-}" ;;
        *) return 1 ;;
    esac
}

_validate_spec_paths() {
    local _tier="$1"
    shift
    local _path _absolute _root="${REPO_ROOT}/test/${_tier}/"
    for _path in "$@"; do
        [[ "${_path}" != /* ]] || _usage_error "spec path '${_path}' must be relative to the repo root"
        [[ -e "${REPO_ROOT}/${_path}" ]] || _usage_error "spec path '${_path}' does not exist"
        [[ "${_path}" == *.bats ]] || _usage_error "spec path '${_path}' must end in .bats"
        [[ -f "${REPO_ROOT}/${_path}" ]] || _usage_error "spec path '${_path}' is not a file"
        _absolute="$(realpath "${REPO_ROOT}/${_path}")"
        [[ "${_absolute}" == "${_root}"* ]] \
            || _usage_error "spec path '${_path}' is outside test/${_tier}/"
    done
}

# --- Dispatch ----------------------------------------------------------------

# The host-side steps a bare `test.sh` runs, in this order (system-real
# last: it is the slow, privileged one).
HOST_STEPS=(lint unit matrix integration system acceptance system-real)

# Run the in-container gate selected by internal flag $1.
_run_ci_gate() {
    local _flag="$1"
    shift
    case "${_flag}" in
        --ci-lint)         _run_shellcheck ;;
        --ci-unit)         _run_unit "$@" ;;
        --ci-matrix)       _run_matrix "$@" ;;
        --ci-integration)  _run_integration "$@" ;;
        --ci-integration-ghostty) _run_integration_ghostty ;;
        --ci-system)       _run_system "$@" ;;
        --ci-system-real)  _run_system_real ;;
        --ci-acceptance)   _run_acceptance "$@" ;;
    esac
}

# Run host-side step $1 (a HOST_STEPS entry, or `build`). Returns the step's
# own exit status so the caller can stop at the first failure.
_run_host_step() {
    local _step="$1"
    local _filter="$2"
    shift 2
    local _selectors=("$@")
    [[ -z "${_filter}" ]] || _selectors+=(--filter "${_filter}")
    case "${_step}" in
        build)       _ensure_image ;;
        lint)        _run_in_container --ci-lint ;;
        unit)        _run_in_container --ci-unit "${_selectors[@]}" ;;
        matrix)      _run_in_container --ci-matrix "${_selectors[@]}" ;;
        # Both groups, default first; the ghostty one only runs when the
        # default one passed, so a plain integration break is reported
        # before the slower image build.
        integration)
            _run_in_container --ci-integration "${_selectors[@]}"
            [[ "${#_selectors[@]}" -gt 0 ]] || _run_ghostty_in_container
            ;;
        system)      _run_in_container --ci-system "${_selectors[@]}" ;;
        acceptance)  _run_in_container --ci-acceptance "${_selectors[@]}" ;;
        system-real) _run_system_real_in_runner ;;
    esac
}

# Parse the WHOLE command line before running anything, so an unknown option
# anywhere in it refuses the run as a whole. Host steps accumulate in the
# order given (none = HOST_STEPS); an internal --ci-* flag selects the
# container gate instead and stands alone.
main() {
    local _steps=() _paths=() _ci="" _step _help=0 _filter="" _tier=""
    [[ "${WORKTOOL_TEST_JOBS}" =~ ^[1-9][0-9]*$ ]] \
        || _usage_error "invalid WORKTOOL_TEST_JOBS '${WORKTOOL_TEST_JOBS}'"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            # Recorded, not served: the rest of the line is still validated
            # (`--help --bogus` is a usage error, not help).
            -h|--help) _help=1 ;;
            --ci-lint|--ci-unit|--ci-matrix|--ci-integration|--ci-integration-ghostty|--ci-system|--ci-system-real|--ci-acceptance)
                _ci="$1" ;;
            --build|--lint|--unit|--matrix|--integration|--system|--system-real|--acceptance)
                _steps+=("${1#--}") ;;
            --filter)
                [[ $# -gt 1 ]] || _usage_error "option '--filter' requires a value"
                shift
                _filter="$1"
                ;;
            --*) _usage_error "unknown option '$1'" ;;
            *) _paths+=("$1") ;;
        esac
        shift
    done
    # Every rule about the command line runs before help is served.
    if [[ -n "${_ci}" && "${#_steps[@]}" -gt 0 ]]; then
        _usage_error "internal flag ${_ci} takes no other option"
    fi
    if [[ "${#_paths[@]}" -gt 0 || -n "${_filter}" ]]; then
        [[ "${#_steps[@]}" -le 1 ]] \
            || _usage_error "spec paths and --filter require exactly one bats tier"
        _step="${_ci:-${_steps[0]:-}}"
        _tier="$(_tier_for_step "${_step}")" \
            || _usage_error "spec paths and --filter require a bats tier"
        _validate_spec_paths "${_tier}" "${_paths[@]}"
    fi
    if [[ "${_help}" -eq 1 ]]; then
        _usage
        return 0
    fi
    # A failing gate or step ends the script right there with its own exit
    # status: errexit is what stops the run at the first failure, so the
    # steps are called plainly (never in an `if` / `||`, which would turn
    # errexit off inside them).
    if [[ -n "${_ci}" ]]; then
        _run_ci_gate "${_ci}" "${_filter}" "${_paths[@]/#/${REPO_ROOT}/}"
        return 0
    fi
    [[ "${#_steps[@]}" -gt 0 ]] || _steps=("${HOST_STEPS[@]}")
    for _step in "${_steps[@]}"; do
        _run_host_step "${_step}" "${_filter}" "${_paths[@]}"
    done
    return 0
}

# Guard: only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
