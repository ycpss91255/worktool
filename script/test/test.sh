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
                unit/link_spec.bats \
                unit/config_spec.bats \
                unit/config_mutation_spec.bats \
                unit/config_owner_spec.bats \
                unit/config_validate_spec.bats \
                unit/enter_spec.bats \
                unit/workflow_spec.bats \
                unit/approval_spec.bats \
                unit/commit_attribution_spec.bats \
                unit/commit_email_spec.bats \
                unit/attribution_spec.bats \
                unit/milestone_gate_yml_spec.bats \
                unit/agent_config_spec.bats \
                unit/adr_spec.bats \
                unit/box_tmux_env_spec.bats \
                unit/managed_block_spec.bats \
                unit/adr/0004_spec.bats \
                unit/adr/0005_spec.bats \
                unit/adr/0006_spec.bats \
                unit/adr/0007_spec.bats \
                unit/adr/0008_spec.bats \
                unit/adr/0009_spec.bats \
                unit/adr/0010_spec.bats \
                unit/adr/0011_spec.bats \
                unit/adr/0012_spec.bats \
                unit/adr/0013_spec.bats \
                unit/contract_spec.bats \
                unit/hook/hook_bootstrap_spec.bats \
                unit/hook/subcommand_spec.bats \
                unit/hook/test_must_use_docker_spec.bats \
                unit/hook/enforce_local_test_scope_spec.bats \
                unit/hook/enforce_long_job_timeout_spec.bats \
                unit/hook/check_main_fresh_before_worktree_spec.bats \
                unit/hook/remind_main_sync_spec.bats \
                unit/hook/enforce_gh_body_file_spec.bats \
                unit/hook/enforce_no_local_paths_spec.bats \
                unit/hook/enforce_milestone_gate_approval_representative_spec.bats \
                unit/hook/enforce_milestone_ready_evidence_spec.bats \
                unit/hook/enforce_main_checkout_readonly_representative_spec.bats \
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
                matrix/enforce_main_checkout_readonly_spec.bats \
                matrix/enforce_no_attribution_spec.bats \
                matrix/enforce_tdd_commit_spec.bats \
                matrix/enforce_local_test_scope_spec.bats
            ;;
        integration)
            printf '%s\n' \
                integration/smoke_spec.bats \
                integration/assemble_spec.bats \
                integration/setup_spec.bats \
                integration/enter_spec.bats
            ;;
        integration-ghostty) printf '%s\n' "${INTEGRATION_GHOSTTY_SPEC_REL}" ;;
        system)
            printf '%s\n' \
                system/real_assemble_spec.bats \
                system/real_enter_env_spec.bats
            ;;
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
    local _layout_paths="" _rc=0
    local _layout_env=() _git_mount=()
    if [[ "${_flag}" == --ci-lint ]]; then
        mkdir -p "${REPO_ROOT}/.agents/state"
        _layout_paths="$(mktemp "${REPO_ROOT}/.agents/state/layout-paths.XXXXXX")"
        _write_lint_paths "${_layout_paths}"
        _layout_env=(-e "WORKTOOL_LAYOUT_PATHS=/source/.agents/state/${_layout_paths##*/}")
    elif [[ -f "${REPO_ROOT}/.git" ]]; then
        local _git_common_dir
        _git_common_dir="$(git -c "safe.directory=${REPO_ROOT}" -C "${REPO_ROOT}" \
            rev-parse --path-format=absolute --git-common-dir)" \
            || _die "cannot resolve Git common directory"
        _git_mount=(-v "${_git_common_dir}:${_git_common_dir}:ro")
    fi
    docker run --rm -e WORKTOOL_TEST_JOBS "${_layout_env[@]}" \
        -v "${REPO_ROOT}:/source" "${_git_mount[@]}" \
        -w /source \
        "${TEST_IMAGE}" \
        ./script/test/test.sh "${_flag}" "$@" || _rc=$?
    if [[ -n "${_layout_paths}" ]]; then
        rm -f "${_layout_paths}"
    fi
    return "${_rc}"
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

# Write repository-relative paths, NUL-delimited to preserve odd characters.
# A per-command safe.directory permits root to inspect the mounted checkout.
_write_lint_paths() {
    local _destination="$1" _path
    if ! command -v git >/dev/null 2>&1; then
        _info "git unavailable; falling back to filesystem lint discovery"
    elif git -c "safe.directory=${REPO_ROOT}" -C "${REPO_ROOT}" \
        ls-files --cached --others --exclude-standard -z >"${_destination}" 2>/dev/null; then
        return 0
    else
        _info "Git path listing failed (not an accessible work tree); falling back to filesystem lint discovery"
    fi
    while IFS= read -r -d '' _path; do
        printf '%s\0' "${_path#"${REPO_ROOT}/"}"
    done < <(find "${REPO_ROOT}" -path "${REPO_ROOT}/.git" -prune -o \
        -type f -print0) >"${_destination}"
}

# Emit existing regular shell scripts from the selected path snapshot.
_find_lintable_sh() {
    local _path
    while IFS= read -r -d '' _path; do
        case "${_path}" in
            *.sh|*.bats)
                if [[ -f "${REPO_ROOT}/${_path}" && ! -L "${REPO_ROOT}/${_path}" ]]; then
                    printf '%s\0' "${REPO_ROOT}/${_path}"
                fi ;;
        esac
    done <"${WORKTOOL_LAYOUT_PATHS}"
}

_run_shellcheck() {
    _info "Running ShellCheck (*.sh + *.bats)"
    local _files=()
    while IFS= read -r -d '' _f; do
        _files+=("${_f}")
    done < <(_find_lintable_sh)

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

# Host lint supplies a snapshot when linked-worktree metadata is outside
# /source. Direct container callers create their own, with filesystem fallback.
_run_lint() (
    if [[ -z "${WORKTOOL_LAYOUT_PATHS:-}" ]]; then
        WORKTOOL_LAYOUT_PATHS="$(mktemp)"
        trap 'rm -f "${WORKTOOL_LAYOUT_PATHS}"' EXIT
        _write_lint_paths "${WORKTOOL_LAYOUT_PATHS}"
    fi
    [[ -r "${WORKTOOL_LAYOUT_PATHS}" ]] || _die "lint path snapshot unreadable"
    export WORKTOOL_LAYOUT_PATHS
    _run_shellcheck
    _info "Checking script layout and process artifacts"
    "${REPO_ROOT}/script/test/check-script-layout.sh" --root "${REPO_ROOT}" \
        || _die "Script layout check failed"
    _info "Script layout OK"
)

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

# Exit for a bats run of tier $1 that returned non-zero; $2 = its captured
# TAP stream (removed here). Newer bats exits non-zero on an empty (filtered)
# suite after printing "1..0"; that is named as the zero-case miss.
_die_bats_failed() {
    local _tier="$1" _tap="$2" _empty=0
    if grep -qx '1\.\.0' "${_tap}"; then
        _empty=1
    fi
    rm -f "${_tap}"
    if [[ "${_empty}" -eq 1 ]]; then
        _die "${_tier} bats ran zero cases - a missing required case is not green"
    fi
    _die "${_tier} bats failed"
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
    local _partial=0
    if [[ "${1:-}" == -- ]]; then
        shift
    elif [[ $# -gt 0 || -n "${_filter}" ]]; then
        _partial=1
    fi
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
        _die_bats_failed "${_tier}" "${_tap}"
    fi
    local _ok=0
    _verify_tap "${_tier}" "${_tap}" "${_min}" || _ok=1
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
    if [[ $# -gt 1 ]]; then
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
    if [[ -n "${1:-}" ]]; then
        _run_bats_tier integration "$1" "${_specs[@]}"
    else
        _run_bats_tier integration "" -- "${_specs[@]}"
    fi
}

# Integration tier, ghostty group: exactly the ghostty spec, run in the
# ubuntu image that carries ghostty. Same green rules as every tier.
_run_integration_ghostty() {
    _run_bats_tier integration-ghostty "" -- "${INTEGRATION_GHOSTTY_SPEC}"
}

# System tier, shim group: every test/system/*.bats except the real-engine
# spec (which needs a live daemon and has its own runner).
_run_system() {
    if [[ $# -gt 1 ]]; then
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
    if [[ -n "${1:-}" ]]; then
        _run_bats_tier system "$1" "${_specs[@]}"
    else
        _run_bats_tier system "" -- "${_specs[@]}"
    fi
}

# System tier, real-engine group: exactly the real-engine spec, run by the
# DinD runner entry once its nested dockerd is up. Same green rules: the spec
# must exist, run at least one case, and skip nothing.
_run_system_real() { _run_bats_tier system-real "" -- "${SYSTEM_REAL_SPEC}"; }

# --- Usage -------------------------------------------------------------------
_usage_environment() {
    cat >&2 <<'EOF'
Environment:
  TEST_IMAGE             test image tag (default worktool-test:local)
  TEST_IMAGE_PREBUILT=1  skip the test image build (CI loads a prebuilt one)
  WORKTOOL_TEST_JOBS     bats files to run in parallel (default 4)
  SYSTEM_REAL_IMAGE      DinD runner image tag (default worktool-system-real:local)
  GHOSTTY_IMAGE          ghostty image tag (default worktool-ghostty:local)
EOF
}

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
  --guards        Run the shared repository-wide unit guard specs.
  --changed [--base REF]
                  Always run lint, then select specs from committed,
                  uncommitted, and untracked changes since REF (default:
                  origin/main). Source/ADR changes also run all guards;
                  runs selected unit and matrix specs only;
                  heavier tiers are reported for CI. Unknown impact and an
                  unreadable diff are also reported for CI verification.
  --unit [SPEC...] [--filter REGEX]
                  Unit bats (test/unit/), optionally narrowed by spec and name.
  --matrix [SPEC...] [--filter REGEX]
                  Matrix bats (test/matrix/), optionally narrowed; slow in full.
  --integration [SPEC...] [--filter REGEX]
                  Integration bats (test/integration/), optionally narrowed.
                  With no selector, runs BOTH groups: the
                  default one in the test image, then the ghostty one
                  (test/integration/ghostty_config_spec.bats) in the ubuntu
                  image that carries a real ghostty. No display needed.
  --system [SPEC...] [--filter REGEX]
                  System bats, optionally narrowed within test/system/. With
                  no selector, runs the shim group minus the real-engine spec.
  --system-real   System bats, real-engine group (test/system/real_engine_spec
                  .bats) in the docker-in-docker runner - the ONLY step that
                  uses --privileged; slow.
  --acceptance [SPEC...] [--filter REGEX]
                  Acceptance bats, optionally narrowed within test/acceptance/.
  -h, --help      Show this help and exit.

SPEC paths are relative to the repo root and must be .bats files under the
  selected tier. A narrowed run is partial: it skips the required-spec and TAP
  plan-minimum gate checks and does not stand for the whole tier.
Internal (what the steps above run inside the container; not for hosts):
  --ci-lint --ci-unit --ci-matrix --ci-integration --ci-integration-ghostty --ci-system
  --ci-system-real --ci-acceptance
EOF
    printf '\n' >&2
    _usage_environment
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
        if [[ "${_absolute}" == "${INTEGRATION_GHOSTTY_SPEC}" \
            || "${_absolute}" == "${SYSTEM_REAL_SPEC}" ]]; then
            _usage_error "spec path '${_path}' requires its dedicated runner"
        fi
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
        --ci-lint)
            _run_lint
            ;;
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

_changed_files() {
    local _base="$1" _out="$2"
    : >"${_out}"
    if ! git -C "${REPO_ROOT}" diff --name-only "${_base}...HEAD" >>"${_out}"; then
        return 1
    fi
    git -C "${REPO_ROOT}" diff --name-only >>"${_out}" || return 1
    git -C "${REPO_ROOT}" diff --cached --name-only >>"${_out}" || return 1
    git -C "${REPO_ROOT}" ls-files --others --exclude-standard >>"${_out}" \
        || return 1
    sort -u -o "${_out}" "${_out}"
}

# One mapping table for production paths and the specs that observe them.
# Format: shell pattern|repo-relative spec path.
_changed_path_map() {
    cat <<'MAP'
lib/log.sh|test/unit/log_spec.bats
lib/manifest.sh|test/unit/manifest_spec.bats
lib/home.sh|test/unit/assemble_spec.bats
lib/home.sh|test/unit/setup_spec.bats
lib/home.sh|test/unit/status_spec.bats
lib/enter.sh|test/unit/enter_spec.bats
lib/approval.sh|test/unit/approval_spec.bats
lib/approval.sh|test/unit/hook/enforce_milestone_gate_approval_representative_spec.bats
lib/approval.sh|test/unit/hook/approval_check_spec.bats
lib/attribution.sh|test/unit/attribution_spec.bats
lib/commit_attribution.sh|test/unit/commit_attribution_spec.bats
lib/commit_email.sh|test/unit/commit_email_spec.bats
script/box/assemble.sh|test/unit/assemble_spec.bats
script/box/assemble.sh|test/integration/assemble_spec.bats
script/box/assemble.sh|test/system/real_assemble_spec.bats
script/box/bench.sh|test/unit/bench_spec.bats
script/box/enter.sh|test/unit/enter_spec.bats
script/box/enter.sh|test/integration/enter_spec.bats
script/box/setup.sh|test/unit/setup_spec.bats
script/box/setup.sh|test/integration/setup_spec.bats
script/box/status.sh|test/unit/status_spec.bats
script/box/justfile.box|test/unit/justfile_spec.bats
MAP
    _changed_hook_path_map
    _changed_doc_path_map
}

_changed_doc_path_map() {
    cat <<'MAP'
README*|test/unit/diagram_spec.bats
README*|test/unit/justfile_spec.bats
doc/diagram/*|test/unit/diagram_spec.bats
doc/adr/*.md|test/unit/adr_spec.bats
doc/adr/*.md|test/unit/adr/0004_spec.bats
doc/adr/*.md|test/unit/adr/0005_spec.bats
doc/adr/*.md|test/unit/adr/0006_spec.bats
doc/adr/*.md|test/unit/adr/0007_spec.bats
doc/adr/*.md|test/unit/adr/0008_spec.bats
doc/adr/*.md|test/unit/adr/0009_spec.bats
doc/adr/*.md|test/unit/adr/0010_spec.bats
doc/adr/*.md|test/unit/adr/0011_spec.bats
doc/adr/*.md|test/unit/adr/0012_spec.bats
doc/adr/*.md|test/unit/adr/0013_spec.bats
doc/*.md|test/unit/contract_spec.bats
doc/*.md|test/unit/diagram_spec.bats
doc/*.md|test/unit/justfile_spec.bats
doc/structure.md|test/unit/adr/0007_spec.bats
doc/manifest.md|test/unit/bench_spec.bats
doc/manifest.md|test/unit/adr/0007_spec.bats
doc/enter.md|test/unit/adr/0007_spec.bats
doc/design.md|test/unit/adr/0008_spec.bats
doc/workflow.md|test/unit/workflow_spec.bats
doc/contract.md|test/unit/adr/0004_spec.bats
doc/contract.md|test/unit/adr/0007_spec.bats
doc/contract.md|test/unit/adr/0009_spec.bats
MAP
}

_changed_hook_path_map() {
    cat <<'MAP'
.agents/hook/check_main_fresh_before_worktree.sh|test/unit/hook/check_main_fresh_before_worktree_spec.bats
.agents/hook/enforce_codex_round_cap.sh|test/unit/hook/enforce_codex_round_cap_spec.bats
.agents/hook/enforce_cpu_capacity.sh|test/unit/hook/enforce_cpu_capacity_spec.bats
.agents/hook/enforce_gh_body_file.sh|test/unit/hook/enforce_gh_body_file_spec.bats
.agents/hook/enforce_issue_milestone.sh|test/unit/hook/enforce_issue_milestone_spec.bats
.agents/hook/enforce_long_job_timeout.sh|test/unit/hook/enforce_long_job_timeout_spec.bats
.agents/hook/enforce_milestone_gate_approval.sh|test/matrix/enforce_milestone_gate_approval_spec.bats
.agents/hook/enforce_milestone_gate_approval.sh|test/unit/hook/enforce_milestone_gate_approval_representative_spec.bats
.agents/hook/enforce_milestone_gate_approval.sh|test/unit/hook/approval_check_spec.bats
.agents/hook/enforce_no_attribution.sh|test/matrix/enforce_no_attribution_spec.bats
.agents/hook/enforce_no_attribution.sh|test/unit/hook/enforce_no_attribution_spec.bats
.agents/hook/enforce_no_local_paths.sh|test/unit/hook/enforce_no_local_paths_spec.bats
.agents/hook/enforce_reply_language.sh|test/unit/hook/enforce_reply_language_spec.bats
.agents/hook/enforce_scope_on_guard_issues.sh|test/unit/hook/enforce_scope_on_guard_issues_spec.bats
.agents/hook/enforce_shellcheck_disable_approval.sh|test/unit/hook/enforce_shellcheck_disable_approval_spec.bats
.agents/hook/enforce_tdd_commit.sh|test/matrix/enforce_tdd_commit_spec.bats
.agents/hook/enforce_tdd_commit.sh|test/unit/hook/enforce_tdd_commit_representative_spec.bats
.agents/hook/remind_main_sync.sh|test/unit/hook/remind_main_sync_spec.bats
.agents/hook/remind_no_emoji.sh|test/unit/hook/remind_no_emoji_spec.bats
.agents/hook/remind_workflow_tdd.sh|test/unit/hook/remind_workflow_tdd_spec.bats
.agents/hook/enforce_local_test_scope.sh|test/unit/hook/enforce_local_test_scope_spec.bats
.agents/hook/enforce_local_test_scope.sh|test/matrix/enforce_local_test_scope_spec.bats
.agents/hook/test-must-use-docker.sh|test/unit/hook/test_must_use_docker_spec.bats
.agents/hook/worktree_create.sh|test/unit/hook/worktree_create_spec.bats
.agents/hook/lib/hook_bootstrap.sh|test/unit/hook/hook_bootstrap_spec.bats
.agents/hook/lib/subcommand.sh|test/unit/hook/subcommand_spec.bats
.agents/hook/enforce_milestone_ready_evidence.sh|test/unit/hook/enforce_milestone_ready_evidence_spec.bats
.agents/hook/lib/ready_evidence.sh|test/unit/hook/enforce_milestone_ready_evidence_spec.bats
.agents/hook/lib/ready_goals.awk|test/unit/hook/enforce_milestone_ready_evidence_spec.bats
.agents/hook/lib/ready_table.awk|test/unit/hook/enforce_milestone_ready_evidence_spec.bats
.agents/hook/enforce_milestone_gate_approval.sh|test/unit/hook/enforce_milestone_ready_evidence_spec.bats
.agents/script/monitor/wait-pr-ci.sh|test/unit/script/wait_pr_ci_spec.bats
.agents/script/monitor/watch-user-replies.sh|test/unit/script/watch_user_replies_spec.bats
MAP
}

_mapped_specs() {
    local _path="$1" _pattern _spec
    while IFS='|' read -r _pattern _spec; do
        # Root documentation guards do not apply to nested ADRs or diagrams.
        if [[ "${_pattern}" == 'doc/*.md' && "${_path%/*}" != doc ]]; then
            continue
        fi
        if [[ "${_path}" == @(${_pattern}) ]]; then
            printf '%s\n' "${_spec}"
        fi
    done < <(_changed_path_map)
}

_add_changed_spec() {
    local _path="$1" _mapped="${2:-0}" _source="${3:-$1}" _tier
    [[ "${_path}" =~ ^test/(unit|matrix|integration|system|acceptance)/.+\.bats$ ]] \
        || return 1
    _tier="${BASH_REMATCH[1]}"
    if [[ ! -f "${REPO_ROOT}/${_path}" ]]; then
        if [[ "${_mapped}" -eq 1 ]]; then
            _info "此改動由 CI 的 ${_tier} 驗證：${_source}（對應 spec 不存在：${_path}）"
            local -n _full_tier="_full_${_tier}"
            _full_tier=1
            unset -n _full_tier
        fi
        return 0
    fi
    case "${_path}" in
        "test/${INTEGRATION_GHOSTTY_SPEC_REL}") _ghostty=1; return 0 ;;
        "test/${SYSTEM_REAL_SPEC_REL}") _system_real=1; return 0 ;;
    esac
    local -n _tier_specs="_${_tier}"
    local _selected
    for _selected in "${_tier_specs[@]}"; do
        if [[ "${_selected}" == "${_path}" ]]; then
            unset -n _tier_specs
            return 0
        fi
    done
    _tier_specs+=("${_path}")
    unset -n _tier_specs
}

# Single source for repository-wide guards; optional files follow the checkout.
_guard_specs() {
    local _spec
    for _spec in config_owner config_mutation config_validate config_graph \
        adr ci_gate justfile test_changed test_sh contract diagram agent_config script_layout \
        verify_ui; do
        [[ ! -f "${REPO_ROOT}/test/unit/${_spec}_spec.bats" ]] \
            || printf 'test/unit/%s_spec.bats\n' "${_spec}"
    done
    for _spec in "${REPO_ROOT}"/test/unit/adr/*_spec.bats; do
        [[ ! -f "${_spec}" ]] || printf '%s\n' "${_spec#"${REPO_ROOT}"/}"
    done
}

# Conservative scan signatures: tracked-file enumeration, source globs, or
# recursive/search commands over source directories (including continuations).
_spec_scans_repository() {
    awk '{ line = line $0; if (sub(/\\$/, "", line)) next; print line; line = "" }
         END { if (line != "") print line }' "$1" |
        grep -E 'ls-files|(^|[/"[:space:]])(script|lib)/[^[:space:]]*\*|(^|[[:space:]])(find|grep|rg)([[:space:]].*)?[/"[:space:]](script|lib)/?(["[:space:]]|$)' >/dev/null
}

_validate_guard_specs() {
    local _spec _relative _guards _missing=0
    _guards="$(_guard_specs)"
    while IFS= read -r -d '' _spec; do
        _spec_scans_repository "${_spec}" || continue
        _relative="${_spec#"${REPO_ROOT}"/}"
        if ! grep -qxF "${_relative}" <<<"${_guards}"; then
            _err "repository-scanning spec missing from guard list: ${_relative}"
            _missing=1
        fi
    done < <(find "${REPO_ROOT}/test" -type f -name '*_spec.bats' -print0)
    [[ "${_missing}" -eq 0 ]]
}

_add_changed_guards() {
    case "$1" in
        script/*|lib/*|box/*|justfile*|doc/adr/*)
            _guards_selected=1
            local _spec
            while IFS= read -r _spec; do
                _add_changed_spec "${_spec}"
            done < <(_guard_specs)
            ;;
    esac
}

_is_test_infrastructure() {
    case "$1" in
        script/test/*|dockerfile/Dockerfile.*|Dockerfile|Dockerfile.*|justfile*|test/helper/*) return 0 ;;
        *) return 1 ;;
    esac
}

_run_changed_tiers() {
    local _tier
    if [[ "${_guards_selected}" -eq 1 ]]; then
        _validate_guard_specs || _die "guard list incomplete"
    fi
    _run_host_step lint ""
    for _tier in unit matrix integration system acceptance; do
        local -n _selected_specs="_${_tier}"
        local -n _full_tier="_full_${_tier}"
        if [[ "${_full_fallback}" -eq 1 || "${_full_tier}" -eq 1 ]]; then
            _info "此改動由 CI 的 ${_tier} 驗證"
        fi
        if [[ "${#_selected_specs[@]}" -gt 0 ]]; then
            if [[ "${_tier}" == unit || "${_tier}" == matrix ]]; then
                _run_host_step "${_tier}" "" "${_selected_specs[@]}"
            else
                _info "此改動由 CI 的 ${_tier} 驗證"
            fi
        fi
        unset -n _selected_specs
        unset -n _full_tier
    done
    if [[ "${_ghostty}" -eq 1 ]]; then
        _info "此改動由 CI 的 integration 驗證"
    fi
    if [[ "${_system_real}" -eq 1 || "${_full_fallback}" -eq 1 ]]; then
        _info "此改動由 CI 的 system-real 驗證"
    fi
}

_run_changed() {
    local _base="$1" _list _path _spec _mapped _full_fallback=0
    local _full_unit=0 _full_matrix=0 _full_integration=0
    local _full_system=0 _full_acceptance=0
    local _ghostty=0 _system_real=0 _guards_selected=0
    local -a _unit=() _matrix=() _integration=() _system=() _acceptance=()
    _list="$(mktemp)" || _die "mktemp failed"
    if ! _changed_files "${_base}" "${_list}"; then
        _info "changed-file diff unreadable; verification left to CI"
        _full_fallback=1
    fi
    while IFS= read -r _path; do
        _add_changed_guards "${_path}"
        if [[ "${_path}" == dockerfile/Dockerfile.ghostty ]]; then
            _info "此改動由 CI 的 integration 驗證：${_path}（測試基礎設施變更；專用 runner）"
            continue
        fi
        if [[ "${_path}" == dockerfile/Dockerfile.system-real \
            || "${_path}" == script/test/system-real-entry.sh ]]; then
            _info "此改動由 CI 的 system-real 驗證：${_path}（測試基礎設施變更；專用 runner）"
            continue
        fi
        if _is_test_infrastructure "${_path}"; then
            _info "此改動由 CI 的 unit 驗證：${_path}（測試基礎設施變更；全部 tier 交給 CI）"
            _full_fallback=1
            continue
        fi
        if _add_changed_spec "${_path}"; then
            continue
        fi
        _mapped="$(_mapped_specs "${_path}")"
        if [[ -z "${_mapped}" ]]; then
            _info "此改動由 CI 的 unit 驗證：${_path}（沒有對應 spec）"
            _full_unit=1
            continue
        fi
        while IFS= read -r _spec; do
            [[ -n "${_spec}" ]] || continue
            _add_changed_spec "${_spec}" 1 "${_path}"
        done <<<"${_mapped}"
    done <"${_list}"
    rm -f "${_list}"
    _run_changed_tiers
}

_run_guards() {
    _validate_guard_specs || _die "guard list incomplete"
    local -a _specs=()
    mapfile -t _specs < <(_guard_specs)
    [[ "${#_specs[@]}" -gt 0 ]] || _die "no guard specs found"
    _run_host_step unit "" "${_specs[@]}"
}

# Parse the WHOLE command line before running anything, so an unknown option
# anywhere in it refuses the run as a whole. Host steps accumulate in the
# order given (none = HOST_STEPS); an internal --ci-* flag selects the
# container gate instead and stands alone.
_parse_test_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) _help=1 ;;
            --ci-lint|--ci-unit|--ci-matrix|--ci-integration|--ci-integration-ghostty|--ci-system|--ci-system-real|--ci-acceptance)
                _ci="$1" ;;
            --build|--lint|--guards|--unit|--matrix|--integration|--system|--system-real|--acceptance)
                _steps+=("${1#--}") ;;
            --changed) _changed=1 ;;
            --base)
                [[ $# -gt 1 ]] || _usage_error "option '--base' requires a value"
                shift
                _base="$1"
                _base_set=1
                ;;
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
}

main() {
    _steps=() _paths=() _ci="" _step="" _help=0 _filter="" _tier=""
    _changed=0 _base="origin/main" _base_set=0
    [[ "${WORKTOOL_TEST_JOBS}" =~ ^[1-9][0-9]*$ ]] \
        || _usage_error "invalid WORKTOOL_TEST_JOBS '${WORKTOOL_TEST_JOBS}'"
    _parse_test_args "$@"
    if [[ -n "${_ci}" && "${#_steps[@]}" -gt 0 ]]; then
        _usage_error "internal flag ${_ci} takes no other option"
    fi
    if [[ "${_changed}" -eq 1 && ( -n "${_ci}" || "${#_steps[@]}" -gt 0 ) ]]; then
        _usage_error "option '--changed' takes no other test step"
    fi
    if [[ "${_base_set}" -eq 1 && "${_changed}" -eq 0 ]]; then
        _usage_error "option '--base' requires --changed"
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
    if [[ "${_changed}" -eq 1 ]]; then
        _run_changed "${_base}"
        return 0
    fi
    if [[ -n "${_ci}" ]]; then
        _run_ci_gate "${_ci}" "${_filter}" "${_paths[@]/#/${REPO_ROOT}/}"
        return 0
    fi
    [[ "${#_steps[@]}" -gt 0 ]] || _steps=("${HOST_STEPS[@]}")
    for _step in "${_steps[@]}"; do
        if [[ "${_step}" == guards ]]; then
            _run_guards
        else
            _run_host_step "${_step}" "${_filter}" "${_paths[@]}"
        fi
    done
    return 0
}

# Guard: only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
