#!/usr/bin/env bats
# test/unit/test_sh_spec.bats - script/test/test.sh host-side CLI (M2)
#
# WHAT THIS PROVES
#   The test runner owns its own usage and validation (the justfiles are
#   thin forwarders and print nothing of their own):
#
#     --help / -h    usage on its own, exit 0, every host flag named, no
#                    docker call
#     --bogus        `test.sh: unknown option '--bogus' (see --help)` on
#                    stderr, exit 2, nothing on stdout, no docker call -
#                    validation happens BEFORE anything runs
#     (no flag)      everything CI runs, in this order: lint, unit,
#                    integration, system, acceptance, system-real; the
#                    run stops at the first failing step
#     --<tier>       exactly that one gate, nothing else
#     --integration  BOTH groups of the tier (M3, issue #172): the default
#                    one in the test image, then the ghostty one in the
#                    ubuntu ghostty image it builds first - and nothing at
#                    all after the default group failed
#     --build        the test image build only
#
# HOW
#   A per-case repo copies the REAL script/test/test.sh and justfiles so
#   host dispatch state stays private. A FAKE `docker` first on PATH
#   records every call (one line per call) and answers as told:
#   exit 0, or exit 1 when the call mentions $FAKE_DOCKER_FAIL_ON. Every
#   host-side route ends in a docker call (a `docker run` of the in-container
#   flag, or the DinD runner's `docker build` + `docker run --privileged`), so
#   the recorded sequence IS the order the runner dispatched. No container
#   is ever started. TEST_IMAGE_PREBUILT=1 skips the test-image build, as CI
#   does, so the record holds only the gate calls (plus the runner image
#   build that --system-real always does).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    # Host dispatch creates state before entering the fake container. Keep
    # that state in a per-case checkout, away from parallel spec guards.
    RUNNER_REPO="${BATS_TEST_TMPDIR}/runner"
    mkdir -p "${RUNNER_REPO}/script/test" "${RUNNER_REPO}/test/helper" \
        "${RUNNER_REPO}/test/unit" "${RUNNER_REPO}/test/integration" "${RUNNER_REPO}/test/system"
    cp "${REPO_ROOT}/script/test/test.sh" "${REPO_ROOT}/script/test/justfile.test" \
        "${RUNNER_REPO}/script/test/"
    cp "${REPO_ROOT}/justfile" "${RUNNER_REPO}/justfile"
    cp -R "${REPO_ROOT}/lib" "${RUNNER_REPO}/lib"
    cp "${REPO_ROOT}/test/helper/common.bash" "${RUNNER_REPO}/test/helper/"
    cp "${REPO_ROOT}/test/unit/test_sh_spec.bats" "${REPO_ROOT}/test/unit/ci_gate_spec.bats" \
        "${RUNNER_REPO}/test/unit/"
    cp "${REPO_ROOT}/test/integration/ghostty_config_spec.bats" \
        "${REPO_ROOT}/test/integration/smoke_spec.bats" "${RUNNER_REPO}/test/integration/"
    cp "${REPO_ROOT}/test/system/real_engine_spec.bats" "${RUNNER_REPO}/test/system/"
    TEST_SH="${RUNNER_REPO}/script/test/test.sh"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    export FAKE_DOCKER_CALLS="${BATS_TEST_TMPDIR}/docker.calls"
    export FAKE_GIT_ROOT="${RUNNER_REPO}"
    unset FAKE_DOCKER_FAIL_ON
    mkdir -p "${FAKE_BIN}"
    _write_fake_docker
    # The copied host fixture has no Git metadata. Stub only its host
    # listing; commands against dedicated Git fixtures still use real git.
    cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -C && "$2" == "${FAKE_GIT_ROOT}" && "$3" == ls-files ]]; then
    printf 'script/test/test.sh\0'
else
    exec /usr/bin/git "$@"
fi
EOF
    chmod +x "${FAKE_BIN}/docker" "${FAKE_BIN}/git"
    export PATH="${FAKE_BIN}:${PATH}"
    export TEST_IMAGE_PREBUILT=1
    if [[ "${FAKE_KEEP_LAYOUT_SNAPSHOT:-}" == 1 ]]; then
        cat >"${FAKE_BIN}/rm" <<'EOF'
#!/usr/bin/env bash
# Cleanup mutant: report success without deleting this fixture's snapshot.
if [[ "$*" == *"${FAKE_GIT_ROOT}/.agents/state/layout-paths."* ]]; then
    exit 0
fi
exec /bin/rm "$@"
EOF
        chmod +x "${FAKE_BIN}/rm"
    fi
}

teardown() {
    # Isolation must not hide a broken cleanup behind Bats' tmpdir removal.
    if [[ -d "${RUNNER_REPO}/.agents/state" ]]; then
        run find "${RUNNER_REPO}/.agents/state" -type f
        assert_success
        assert_output ''
    fi
}

_write_fake_docker() {
    cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"${FAKE_DOCKER_CALLS}"
if [[ -n "${FAKE_DOCKER_SNAPSHOT:-}" ]]; then
    args=("$@")
    mounts=() values=()
    while (( $# )); do
        case "$1" in
            -v) mounts+=("$2"); shift ;;
            -e) values+=("${2#*=}"); shift ;;
        esac
        shift
    done
    printf '%s\n' "${mounts[@]}" >"${FAKE_DOCKER_SNAPSHOT}.mounts"
    for mount in "${mounts[@]}"; do
        host="${mount%%:*}" container="${mount#*:}"
        for value in "${values[@]}"; do
            if [[ "$value" == "${container}/"* ]]; then
                file="${host}/${value#"${container}/"}"
                if [[ -f "$file" ]]; then
                    printf '%s\n' "$file" >"${FAKE_DOCKER_SNAPSHOT}.path"
                    tr '\0' '\n' <"$file" >"${FAKE_DOCKER_SNAPSHOT}.contents"
                fi
            fi
        done
    done
    set -- "${args[@]}"
fi
if [[ -n "${FAKE_DOCKER_FAIL_ON:-}" && "$*" == *"${FAKE_DOCKER_FAIL_ON}"* ]]; then
    exit 1
fi
if [[ -n "${FAKE_DOCKER_OBSERVER:-}" ]]; then
    bats --formatter tap "${FAKE_DOCKER_OBSERVER}"
    exit "$?"
fi
exit 0
EOF
}

# Print the gate each recorded docker call dispatched, in order: the
# in-container flag of a `docker run`, or `system-real-entry.sh` for the
# DinD runner launch, or `build` for an image build.
_dispatched() {
    [[ -f "${FAKE_DOCKER_CALLS}" ]] || return 0
    sed -nE \
        -e 's/^docker run .* (--ci-[a-z-]+)$/\1/p' \
        -e 's/^docker run .*(system-real-entry\.sh)$/\1/p' \
        -e 's/^docker build .*$/build/p' \
        "${FAKE_DOCKER_CALLS}"
}

# The integration step is TWO containers (M3, issue #172): the default
# group in the test image, then - after a `docker build` of the ubuntu
# ghostty image - the ghostty group.
EVERYTHING_IN_ORDER="$(printf '%s\n' \
    --ci-lint --ci-unit --ci-matrix \
    --ci-integration build --ci-integration-ghostty \
    --ci-system --ci-acceptance \
    build system-real-entry.sh)"

# --- --help ------------------------------------------------------------------

@test "test.sh --help exits 0, names every host flag, and calls nothing" {
    run "${TEST_SH}" --help
    assert_success
    local _flag
    for _flag in --build --lint --unit --matrix --integration --system --system-real \
        --acceptance --changed --base --filter --help; do
        assert_output --partial "${_flag}"
    done
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "test.sh -h is the same as --help" {
    run "${TEST_SH}" --help
    local _long="${output}"
    run "${TEST_SH}" -h
    assert_success
    assert_output "${_long}"
}

# --- unknown option: refused before anything runs ---------------------------

@test "test.sh --bogus exits 2 with the documented message on stderr, nothing on stdout, no docker call" {
    local _out="${BATS_TEST_TMPDIR}/out" _err="${BATS_TEST_TMPDIR}/err"
    run bash -c '"$1" --bogus >"$2" 2>"$3"' _ "${TEST_SH}" "${_out}" "${_err}"
    assert_failure 2
    run cat "${_out}"
    assert_output ""
    run cat "${_err}"
    assert_output "test.sh: unknown option '--bogus' (see --help)"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "test.sh --help --bogus is refused as a whole: exit 2, no usage, no docker call" {
    run "${TEST_SH}" --help --bogus
    assert_failure 2
    assert_output "test.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "Usage:"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "test.sh --help --ci-unit --unit is refused as a whole: the flag-combination rule wins over help" {
    run "${TEST_SH}" --help --ci-unit --unit
    assert_failure 2
    assert_output "test.sh: internal flag --ci-unit takes no other option (see --help)"
    refute_output --partial "Usage:"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "test.sh --unit --bogus is refused as a whole: the unit gate never runs" {
    run "${TEST_SH}" --unit --bogus
    assert_failure 2
    assert_output "test.sh: unknown option '--bogus' (see --help)"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "the old --<tier>-only spellings are gone" {
    run "${TEST_SH}" --unit-only
    assert_failure 2
    assert_output "test.sh: unknown option '--unit-only' (see --help)"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

# --- no flag: everything, in order, stop at the first failure --------------

@test "test.sh with no flag runs lint, unit, matrix, integration, system, acceptance, system-real in that order" {
    run "${TEST_SH}"
    assert_success
    assert_equal "$(_dispatched)" "${EVERYTHING_IN_ORDER}"
}

@test "test.sh labels every verification-owned container and leaves ordinary runs unlabelled" {
    WORKTOOL_TEST_RUN_ID=fixture-run run "${TEST_SH}"
    assert_success
    local calls
    calls="$(grep '^docker run ' "${FAKE_DOCKER_CALLS}")"
    assert_equal "$(wc -l <<<"${calls}")" 8
    run grep -vF -- '--label worktool.verify-run=fixture-run' <<<"${calls}"
    assert_failure 1

    rm -f "${FAKE_DOCKER_CALLS}"
    WORKTOOL_TEST_RUN_ID='' run "${TEST_SH}" --integration
    assert_success
    run grep -F -- '--label worktool.verify-run=' "${FAKE_DOCKER_CALLS}"
    assert_failure 1
}

@test "test.sh with no flag stops at the first failing step" {
    FAKE_DOCKER_FAIL_ON=--ci-system run "${TEST_SH}"
    assert_failure
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint --ci-unit --ci-matrix \
        --ci-integration build --ci-integration-ghostty \
        --ci-system)"
}

@test "bare just test, through the real justfiles, runs the seven tiers in order and stops at the first failure (#834)" {
    local _tier _expected
    run just --justfile "${RUNNER_REPO}/justfile" --working-directory "${RUNNER_REPO}" test
    assert_success
    assert_equal "$(_dispatched)" "${EVERYTHING_IN_ORDER}"
    # Fail each tier in turn: every tier before it ran, none after it did,
    # and the failure reaches the caller as a non-zero exit.
    for _tier in --ci-lint --ci-unit --ci-matrix --ci-integration --ci-system --ci-acceptance system-real-entry.sh; do
        rm -f "${FAKE_DOCKER_CALLS}"
        _expected="$(sed "/^${_tier}\$/q" <<<"${EVERYTHING_IN_ORDER}")"
        FAKE_DOCKER_FAIL_ON="${_tier}" run just --justfile "${RUNNER_REPO}/justfile" \
            --working-directory "${RUNNER_REPO}" test
        assert_failure 1
        assert_equal "$(_dispatched)" "${_expected}"
    done
}

@test "test.sh with no flag stops when lint fails: no tier runs" {
    FAKE_DOCKER_FAIL_ON=--ci-lint run "${TEST_SH}"
    assert_failure
    assert_equal "$(_dispatched)" "--ci-lint"
}

# --- one flag: exactly that gate ---------------------------------------------

@test "test.sh --<tier> routes exactly that in-container gate and nothing else" {
    local _tier
    for _tier in lint unit matrix system acceptance; do
        rm -f "${FAKE_DOCKER_CALLS}"
        run "${TEST_SH}" "--${_tier}"
        assert_success
        assert_equal "$(_dispatched)" "--ci-${_tier}"
    done
}

# --- the integration tier's two groups (M3, issue #172) ---------------------

@test "test.sh --integration runs the default group, then builds the ghostty image and runs the ghostty group" {
    run "${TEST_SH}" --integration
    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-integration build --ci-integration-ghostty)"
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp '^docker build .*Dockerfile\.ghostty'
    # The ghostty group is a plain container: no daemon, no extra privilege.
    assert_line --regexp '^docker run --rm -v .*:/source -w /source worktool-ghostty:local \./script/test/test\.sh --ci-integration-ghostty$'
    refute_line --partial '--privileged'
}

@test "test.sh --integration stops when the default group fails: the ghostty image is never built" {
    FAKE_DOCKER_FAIL_ON=--ci-integration run "${TEST_SH}" --integration
    assert_failure
    assert_equal "$(_dispatched)" "--ci-integration"
}

@test "test.sh --system-real builds the runner image, then launches the DinD entry, and nothing else" {
    run "${TEST_SH}" --system-real
    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' build system-real-entry.sh)"
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp '^docker build .*Dockerfile\.system-real'
    assert_line --regexp '^docker run --rm --privileged .* \./script/test/system-real-entry\.sh$'
}

@test "every bats runner image installs GNU parallel" {
    local _dockerfile
    for _dockerfile in \
        dockerfile/Dockerfile.test \
        dockerfile/Dockerfile.ghostty \
        dockerfile/Dockerfile.system-real; do
        run grep -E '^[[:space:]]*parallel([[:space:]]*\\)?$' \
            "${REPO_ROOT}/${_dockerfile}"
        assert_success "${_dockerfile} must install GNU parallel for bats --jobs"
    done
}

# issue #181: bench.sh waits up to 120 s (not 60 s) for a quiet host when
# CI is set; the real-engine gate runs INSIDE the runner, so CI must reach
# it. `-e CI` without a value passes the host's CI through only when set.
@test "prebuilt system-real and ghostty images are used as loaded, never rebuilt" {
    SYSTEM_REAL_IMAGE_PREBUILT=1 GHOSTTY_IMAGE_PREBUILT=1 run "${TEST_SH}" --integration --system-real
    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' --ci-integration --ci-integration-ghostty system-real-entry.sh)"
    run cat "${FAKE_DOCKER_CALLS}"
    refute_line --regexp '^docker build '
}

@test "test.sh --system-real passes CI through to the DinD runner (-e CI)" {
    CI=true run "${TEST_SH}" --system-real
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp '^docker run --rm --privileged -e CI .* \./script/test/system-real-entry\.sh$'
}

# issue #843: CI picks the box's apt mirror (WORKTOOL_APT_MIRROR); the
# entry inside the runner applies it, so it must reach the runner. `-e`
# without a value passes it only when the host has it set.
@test "test.sh --system-real passes WORKTOOL_APT_MIRROR through to the DinD runner" {
    WORKTOOL_APT_MIRROR=http://azure.archive.ubuntu.com/ubuntu/ run "${TEST_SH}" --system-real
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp '^docker run --rm --privileged -e CI -e WORKTOOL_APT_MIRROR .* \./script/test/system-real-entry\.sh$'
}

# issue #847: CI persists the box's downloaded packages in a host dir
# (WORKTOOL_APT_CACHE_DIR); it is mounted at a fixed runner path the entry
# is told about. Unset: no mount, no variable; not absolute: refused.
@test "test.sh --system-real mounts WORKTOOL_APT_CACHE_DIR into the DinD runner for the box's apt" {
    local _dir="${BATS_TEST_TMPDIR}/apt-box"
    mkdir -p "${_dir}"
    WORKTOOL_APT_CACHE_DIR="${_dir}" run "${TEST_SH}" --system-real
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp "^docker run --rm --privileged -e CI -e WORKTOOL_APT_MIRROR -e WORKTOOL_APT_ARCHIVES=/var/cache/worktool-apt -v ${_dir}:/var/cache/worktool-apt -v .*:/source .* \./script/test/system-real-entry\.sh\$"
    : >"${FAKE_DOCKER_CALLS}"
    run "${TEST_SH}" --system-real
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    refute_output --partial 'worktool-apt'
    WORKTOOL_APT_CACHE_DIR=relative/dir run "${TEST_SH}" --system-real
    assert_failure 2
}

# issue #843 follow-up: a run that builds the Ubuntu images itself (the
# nightly full serial run, a local run) passes the same mirror knob as the
# CI image builds; empty = the images' own sources.
@test "test.sh passes WORKTOOL_APT_MIRROR to the ghostty and system-real image builds" {
    unset SYSTEM_REAL_IMAGE_PREBUILT GHOSTTY_IMAGE_PREBUILT
    WORKTOOL_APT_MIRROR=http://azure.archive.ubuntu.com/ubuntu/ run "${TEST_SH}" --integration --system-real
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp '^docker build --build-arg APT_MIRROR=http://azure\.archive\.ubuntu\.com/ubuntu/ .*Dockerfile\.ghostty'
    assert_line --regexp '^docker build --build-arg APT_MIRROR=http://azure\.archive\.ubuntu\.com/ubuntu/ .*Dockerfile\.system-real'
    unset WORKTOOL_APT_MIRROR
    : >"${FAKE_DOCKER_CALLS}"
    run "${TEST_SH}" --system-real
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp '^docker build --build-arg APT_MIRROR= .*Dockerfile\.system-real'
}

# issue #853: a tier container (root) must never be the one that creates
# .agents/state, or a later host-side step (lint's path snapshot) cannot
# write there. Found by the isolation guard (#835) running unit before lint.
@test "every container launch is preceded by the host creating .agents/state (#853)" {
    local _fn _body
    for _fn in _run_in_container _run_ghostty_in_container _run_system_real_in_runner; do
        _body="$(bash -c 'source "$1"; declare -f "$2"' _ "${TEST_SH}" "${_fn}")"
        assert [ -n "${_body}" ]
        run awk '
            /_host_state_dir/ && !seen_run { ok = 1 }
            /docker run --rm/ { seen_run = 1; if (!ok) bad = 1 }
            END { exit (ok && !bad) ? 0 : 1 }' <<<"${_body}"
        assert_success "${_fn}: _host_state_dir must run before docker run"
    done
    run bash -c 'source "$1"; declare -f _host_state_dir' _ "${TEST_SH}"
    assert_output --partial "mkdir -p \"\${REPO_ROOT}/.agents/state\""
}

@test "test.sh --build builds the test image and runs no gate" {
    unset TEST_IMAGE_PREBUILT
    run "${TEST_SH}" --build
    assert_success
    assert_equal "$(_dispatched)" "build"
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp '^docker build .*Dockerfile\.test '
}

# --- the in-container path is wired to the NEW location ---------------------

@test "a host-side gate runs ./script/test/test.sh --ci-<tier> inside the container" {
    run "${TEST_SH}" --unit
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp '^docker run --rm -e WORKTOOL_TEST_JOBS -e WORKTOOL_STRESS -e WORKTOOL_TEST_REPORT_DIR -e WORKTOOL_SHARD_WEIGHTS -e WORKTOOL_FULL_CHECK -v .*:/source -w /source .* \./script/test/test\.sh --ci-unit$'
}

@test "test.sh --unit forwards one spec path to the container gate" {
    run "${TEST_SH}" --unit test/unit/test_sh_spec.bats
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp 'test\.sh --ci-unit test/unit/test_sh_spec\.bats$'
}

_prepare_git_mount_repo() {
    MOUNT_ROOT="${BATS_TEST_TMPDIR}/mount repo"
    mkdir -p "${MOUNT_ROOT}/script/test"
    cp "${TEST_SH}" "${MOUNT_ROOT}/script/test/test.sh"
    git -C "${MOUNT_ROOT}" init -q
    git -C "${MOUNT_ROOT}" add .
    git -C "${MOUNT_ROOT}" -c user.name=Fixture \
        -c user.email=1+fixture@users.noreply.github.com commit -qm fixture
}

@test "test.sh mounts linked-worktree common Git metadata read-only for bats gates" {
    _prepare_git_mount_repo
    local linked="${BATS_TEST_TMPDIR}/linked repo" tier
    git -C "${MOUNT_ROOT}" worktree add -q -b linked "${linked}"
    for tier in unit matrix integration system acceptance; do
        : >"${FAKE_DOCKER_CALLS}"
        run "${linked}/script/test/test.sh" "--${tier}"
        assert_success
        run cat "${FAKE_DOCKER_CALLS}"
        assert_output --partial "-v ${MOUNT_ROOT}/.git:${MOUNT_ROOT}/.git:ro"
    done
}

@test "test.sh keeps plain-clone bats gates free of extra Git mounts" {
    _prepare_git_mount_repo
    local tier
    for tier in unit matrix integration system acceptance; do
        : >"${FAKE_DOCKER_CALLS}"
        run "${MOUNT_ROOT}/script/test/test.sh" "--${tier}"
        assert_success
        run cat "${FAKE_DOCKER_CALLS}"
        refute_output --partial "-v ${MOUNT_ROOT}/.git:"
    done
}

@test "test.sh --unit forwards multiple spec paths in order" {
    run "${TEST_SH}" --unit test/unit/test_sh_spec.bats test/unit/ci_gate_spec.bats
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp 'test\.sh --ci-unit test/unit/test_sh_spec\.bats test/unit/ci_gate_spec\.bats$'
}

@test "test.sh --filter runs only matching cases" {
    run env WORKTOOL_TEST_JOBS=2 "${TEST_SH}" --ci-unit \
        test/unit/test_sh_spec.bats --filter '^test.sh -h is the same as --help$'
    assert_success
    assert_line '1..1'
    assert_line --regexp '^ok 1 test\.sh -h is the same as --help$'
    refute_output --partial 'test.sh --help exits 0'
}

@test "test.sh --shard I/N forwards to the unit or matrix container and refuses anything else" {
    run "${TEST_SH}" --unit --shard 2/4
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp 'test\.sh --ci-unit --shard 2/4$'
    local _args _msg _argv
    while IFS='|' read -r _args _msg; do
        read -r -a _argv <<<"${_args}"
        run "${TEST_SH}" "${_argv[@]}"
        assert_failure 2
        assert_output "test.sh: ${_msg} (see --help)"
    done <<'CASES'
--unit --shard 0/4|invalid shard '0/4' (expected I/N with 1 <= I <= N)
--unit --shard 5/4|invalid shard '5/4' (expected I/N with 1 <= I <= N)
--unit --shard 1of4|invalid shard '1of4' (expected I/N with 1 <= I <= N)
--unit --shard|option '--shard' requires a value
--integration --shard 1/2|option '--shard' requires exactly one of --unit or --matrix
--unit --matrix --shard 1/2|option '--shard' requires exactly one of --unit or --matrix
--shard 1/2|option '--shard' requires exactly one of --unit or --matrix
--unit --shard 1/2 test/unit/log_spec.bats|option '--shard' takes no spec path or --filter
--unit --shard 1/2 --filter x|option '--shard' takes no spec path or --filter
CASES
}

@test "test.sh rejects a spec path from another tier" {
    run "${TEST_SH}" --unit test/integration/smoke_spec.bats
    assert_failure 2
    assert_output "test.sh: spec path 'test/integration/smoke_spec.bats' is outside test/unit/ (see --help)"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "test.sh rejects a missing spec path" {
    run "${TEST_SH}" --unit test/unit/missing_spec.bats
    assert_failure 2
    assert_output "test.sh: spec path 'test/unit/missing_spec.bats' does not exist (see --help)"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "test.sh rejects a path that is not a bats spec" {
    run "${TEST_SH}" --unit test/unit
    assert_failure 2
    assert_output "test.sh: spec path 'test/unit' must end in .bats (see --help)"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "test.sh rejects specs that require a dedicated tier runner" {
    run "${TEST_SH}" --integration test/integration/ghostty_config_spec.bats
    assert_failure 2
    assert_output "test.sh: spec path 'test/integration/ghostty_config_spec.bats' requires its dedicated runner (see --help)"

    run "${TEST_SH}" --system test/system/real_engine_spec.bats
    assert_failure 2
    assert_output "test.sh: spec path 'test/system/real_engine_spec.bats' requires its dedicated runner (see --help)"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

# --- errexit (issue #195) ----------------------------------------------------

@test "test.sh runs under set -euo pipefail (one set line, errexit included)" {
    run grep -E '^set -[a-z]+( pipefail)?$' "${TEST_SH}"
    assert_success
    assert_output 'set -euo pipefail'
}

@test "host lint snapshots linked-worktree paths without extra mounts and cleans up after either exit" {
    local root="${BATS_TEST_TMPDIR}/repo" linked="${BATS_TEST_TMPDIR}/linked"
    export FAKE_DOCKER_SNAPSHOT="${BATS_TEST_TMPDIR}/snapshot"
    mkdir -p "${root}/script/test"
    cp "${TEST_SH}" "${root}/script/test/test.sh"
    git -C "${root}" init -q
    git -C "${root}" add .
    git -C "${root}" -c user.name=Fixture \
        -c user.email=test@example.invalid commit -qm fixture
    run git -C "${root}" log -1 --format=%ae
    assert_success
    assert_output 'test@example.invalid'
    git -C "${root}" worktree add -q -b fixture "${linked}"
    mkdir -p "${linked}/script/box"
    touch "${linked}/script/box/planted-artifact.sh"
    local failure snapshot
    for failure in '' --ci-lint; do
        FAKE_DOCKER_FAIL_ON="${failure}" run bash "${linked}/script/test/test.sh" --lint
        if [[ -n "${failure}" ]]; then
            assert_failure 1
        else
            assert_success
        fi
        assert [ -f "${FAKE_DOCKER_SNAPSHOT}.contents" ]
        run cat "${FAKE_DOCKER_SNAPSHOT}.contents"
        assert_line 'script/box/planted-artifact.sh'
        run cut -d : -f 1 "${FAKE_DOCKER_SNAPSHOT}.mounts"
        assert_output "${linked}"
        snapshot="$(cat "${FAKE_DOCKER_SNAPSHOT}.path")"
        assert [ ! -e "${snapshot}" ]
        rm -f "${FAKE_DOCKER_SNAPSHOT}".*
    done
}

# issue #861: the bats version every runner image ships is pinned and the
# same. bats before 1.14 prints `1..0` and exits 0 when --filter selects no
# case, so an unpinned `latest` can turn a filtered run vacuous.
@test "every bats runner image pins the same bats release, never latest" {
    local _dockerfile _tags=''
    for _dockerfile in \
        dockerfile/Dockerfile.test \
        dockerfile/Dockerfile.ghostty \
        dockerfile/Dockerfile.system-real; do
        run grep -E '^FROM bats/bats:' "${REPO_ROOT}/${_dockerfile}"
        assert_success
        assert_output "FROM bats/bats:\${BATS_TAG} AS bats-src"
        run grep -E '^ARG BATS_TAG=' "${REPO_ROOT}/${_dockerfile}"
        assert_success
        assert_output --regexp '^ARG BATS_TAG=[0-9]+\.[0-9]+\.[0-9]+$'
        _tags+="${output}"$'\n'
    done
    assert_equal "$(sort -u <<<"${_tags%$'\n'}" | wc -l)" 1
}

# Prints file:line of every `run bats ... --filter ...` call (an env prefix,
# `run` flags and `\` continuation lines allowed) that is followed by
# assert_success but not by an `assert_line --regexp '^ok ...'` before the
# next `run` or the end of its @test: such a case reads green when the
# filter selects nothing. A `bats --count` call is skipped: it prints a
# number its case asserts. The last line is `scanned <n>`: how many
# filtered calls it saw.
_unproved_filters() {
    awk '
        BEGIN {
            q = "\047"
            env = "[A-Za-z_][A-Za-z_0-9]*=(\"[^\"]*\"|" q "[^" q "]*" q "|[^[:space:]]*)[[:space:]]+"
            runcmd = "^[[:space:]]*(" env ")*run[[:space:]]"
            runbats = "^[[:space:]]*(" env ")*run([[:space:]]+-[^[:space:]]+)*[[:space:]]+bats([[:space:]]|$)"
        }
        function flush() {
            if (pending && success && !ok) print where
            pending = 0; success = 0; ok = 0
        }
        FNR == 1 { flush(); cont = 0 }
        cont {
            if ($0 ~ /--filter/) filtered = 1
            if ($0 ~ /--count/) counted = 1
            if ($0 ~ /\\$/) next
            cont = 0
            if (filtered && !counted) { pending = 1; scanned++ }
            next
        }
        /^@test / || /^}/ { flush(); next }
        $0 ~ runbats {
            flush()
            where = FILENAME ":" FNR
            filtered = ($0 ~ /--filter/)
            counted = ($0 ~ /--count/)
            if ($0 ~ /\\$/) { cont = 1; next }
            if (filtered && !counted) { pending = 1; scanned++ }
            next
        }
        $0 ~ runcmd { flush(); next }
        /^[[:space:]]*assert_success([[:space:]]|$)/ { success = 1; next }
        /^[[:space:]]*assert_line --regexp .\^ok / { ok = 1; next }
        END { flush(); print "scanned " scanned + 0 }
    ' "$@"
}

@test "the filtered-run scanner flags a filter that may select nothing and passes a proved one" {
    local _f="${BATS_TEST_TMPDIR}/x_spec.bats"
    # Each fixture line starts with `|` so this file itself does not hold
    # the fixture calls (the sweep below scans it too).
    sed 's/^|//' >"${_f}" <<'SPEC'
|@test "vacuous" {
|    run bats --filter '^a$' x.bats
|    assert_success
|}
|
|@test "vacuous across lines, quoted env prefix" {
|    A="b c" run bats \
|        --filter '^a$' \
|        x.bats
|    assert_success
|}
|
|@test "proved" {
|    run -0 bats --filter '^a$' x.bats
|    assert_success
|    assert_line --regexp '^ok [0-9]+ a$'
|}
|
|@test "a failure is not vacuous" {
|    run bats --filter '^a$' x.bats
|    assert_failure
|}
|
|@test "no filter" {
|    run bats x.bats
|    assert_success
|}
|
|@test "a count is no filtered run" {
|    run bats --count --filter '^a$' x.bats
|    assert_success
|    assert_output 1
|}
|
|@test "a later run ends the filtered call" {
|    run bats --filter '^a$' x.bats
|    run true
|    assert_success
|}
SPEC
    run _unproved_filters "${_f}"
    assert_success
    assert_output "$(printf '%s\n' "${_f}:2" "${_f}:7" 'scanned 5')"
}

# issue #861: every spec that runs bats with --filter directly and expects
# success also proves at least one case ran (`^ok `). Filters run through
# test.sh are judged by its gate (zero cases fail there).
@test "every filtered bats run that expects success proves a case ran" {
    local -a _specs
    mapfile -t _specs < <(find "${REPO_ROOT}/test" -path "${REPO_ROOT}/test/fixture" -prune -o -name '*.bats' -print)
    (( ${#_specs[@]} > 0 )) || fail "no spec found"
    run _unproved_filters "${_specs[@]}"
    assert_success
    [[ "${lines[-1]}" =~ ^scanned\ ([0-9]+)$ ]] || fail "scanner: ${output}"
    (( BASH_REMATCH[1] >= 5 )) || fail "only ${BASH_REMATCH[1]} filtered bats run(s) found"
    # Everything above the count line is an unproved filtered run.
    assert_equal "$(printf '%s\n' "${lines[@]:0:${#lines[@]}-1}")" ''
}

@test "host dispatch state stays isolated while another spec checks checkout residue" {
    local guard="${BATS_TEST_TMPDIR}/guard"
    mkdir -p "${guard}"
    source "${REPO_ROOT}/test/helper/hook_state.bash"
    BATS_FILE_TMPDIR="${guard}" hook_state_guard_begin
    export STATE_GUARD_DIR="${guard}" SOURCE_REPO="${REPO_ROOT}"
    export FAKE_DOCKER_OBSERVER="${BATS_TEST_TMPDIR}/observer.bats"
    cat >"${FAKE_DOCKER_OBSERVER}" <<'OBSERVER'
#!/usr/bin/env bats
load "/usr/lib/bats/bats-support/load"
load "/usr/lib/bats/bats-assert/load"
@test "another spec sees no dispatch state in the checkout" {
    REPO_ROOT="${SOURCE_REPO}"
    source "${REPO_ROOT}/test/helper/hook_state.bash"
    BATS_FILE_TMPDIR="${STATE_GUARD_DIR}"
    hook_state_guard_end
}
OBSERVER
    # The fake container observes the checkout while lint's real snapshot
    # is live, before test.sh gets a chance to clean it up. No timing race.
    run "${TEST_SH}" --lint
    assert_success
    assert_output --partial 'ok 1 another spec sees no dispatch state'
    BATS_FILE_TMPDIR="${guard}" hook_state_guard_end
}

@test "isolated dispatch fixture still rejects a snapshot cleanup leak" {
    run env FAKE_KEEP_LAYOUT_SNAPSHOT=1 bats --formatter tap \
        "${REPO_ROOT}/test/unit/test_sh_spec.bats" \
        --filter '^test.sh with no flag stops when lint fails: no tier runs$'
    assert_failure
    assert_output --partial 'from function `teardown'
    assert_output --partial '/runner/.agents/state/layout-paths.'
}

_prepare_lint_worktree() {
    LINT_ROOT="${BATS_TEST_TMPDIR}/lint repo"
    mkdir -p "${LINT_ROOT}/script/test" "${LINT_ROOT}/.agents/state"
    cp "${TEST_SH}" "${LINT_ROOT}/script/test/test.sh"
    cp "${REPO_ROOT}/script/test/check-script-layout.sh" "${LINT_ROOT}/script/test/"
    mkdir -p "${LINT_ROOT}/lib"
    cp "${REPO_ROOT}/lib/log.sh" "${REPO_ROOT}/lib/test_shard.sh" "${LINT_ROOT}/lib/"
    printf '.agents/state/\n' >"${LINT_ROOT}/.gitignore"
    git -C "${LINT_ROOT}" init -q
    git -C "${LINT_ROOT}" add .
}

@test "lint ignores a gitignored ShellCheck violation in .agents/state" {
    _prepare_lint_worktree
    printf '#!/bin/bash\ncd /missing\n' >"${LINT_ROOT}/.agents/state/scratch.sh"
    run "${LINT_ROOT}/script/test/test.sh" --ci-lint
    assert_success
    assert_output --partial 'ShellCheck OK'
    refute_output --partial 'scratch.sh'
    assert [ -f "${LINT_ROOT}/.agents/state/scratch.sh" ]
}

@test "lint rejects an untracked non-ignored ShellCheck violation" {
    _prepare_lint_worktree
    printf '#!/bin/bash\ncd /missing\n' >"${LINT_ROOT}/new script.sh"
    run "${LINT_ROOT}/script/test/test.sh" --ci-lint
    assert_failure 1
    assert_output --partial 'new script.sh'
    assert_output --partial 'SC2164'
    assert_output --partial 'ShellCheck failed'
}

@test "lint falls back outside a Git work tree and explains why on stderr" {
    bats_require_minimum_version 1.5.0
    local stderr=""
    _prepare_lint_worktree
    mv "${LINT_ROOT}/.git" "${BATS_TEST_TMPDIR}/git-metadata"
    printf '#!/bin/bash\ncd /missing\n' >"${LINT_ROOT}/.agents/state/scratch.sh"
    run --separate-stderr "${LINT_ROOT}/script/test/test.sh" --ci-lint
    assert_failure 1
    assert_output --partial 'scratch.sh'
    assert_output --partial 'SC2164'
    assert [ "${stderr}" != "${stderr#*not an accessible work tree}" ]
    assert [ "${stderr}" != "${stderr#*falling back to filesystem lint discovery}" ]
}

@test "lint falls back without git and explains why on stderr" {
    bats_require_minimum_version 1.5.0
    local stderr=""
    _prepare_lint_worktree
    local bin="${BATS_TEST_TMPDIR}/no-git-bin" tool
    mkdir -p "${bin}"
    for tool in bash dirname find mktemp rm shellcheck; do
        ln -s "$(command -v "${tool}")" "${bin}/${tool}"
    done
    printf '#!/bin/bash\ncd /missing\n' >"${LINT_ROOT}/.agents/state/scratch.sh"
    PATH="${bin}" run --separate-stderr "${LINT_ROOT}/script/test/test.sh" --ci-lint
    assert_failure 1
    assert_output --partial 'scratch.sh'
    assert_output --partial 'SC2164'
    assert [ "${stderr}" != "${stderr#*git unavailable}" ]
    assert [ "${stderr}" != "${stderr#*falling back to filesystem lint discovery}" ]
}

@test "lint rejects failed filesystem discovery without git even after partial output" {
    bats_require_minimum_version 1.5.0
    local stderr=""
    _prepare_lint_worktree
    local bin="${BATS_TEST_TMPDIR}/no-git-bin" tool
    mkdir -p "${bin}"
    for tool in bash dirname mktemp rm shellcheck; do
        ln -s "$(command -v "${tool}")" "${bin}/${tool}"
    done
    ln -s "$(command -v find)" "${bin}/real-find"
    cat >"${bin}/find" <<'EOF'
#!/usr/bin/env bash
if [[ "$2" != -path ]]; then
    exec real-find "$@"
fi
printf '%s\0' "$1/lib/log.sh"
printf 'find: unreadable subdirectory\n' >&2
exit 1
EOF
    chmod +x "${bin}/find"
    PATH="${bin}" run --separate-stderr "${LINT_ROOT}/script/test/test.sh" --ci-lint
    assert_failure 1
    assert [ "${stderr}" != "${stderr#*git unavailable}" ]
    assert [ "${stderr}" != "${stderr#*find: unreadable subdirectory}" ]
    assert [ "${stderr}" != "${stderr#*filesystem lint discovery failed}" ]
    refute_output --partial 'ShellCheck OK'
}

@test "lint ignores an executable top-level script excluded by Git" {
    _prepare_lint_worktree
    printf 'script/scratch\n' >>"${LINT_ROOT}/.gitignore"
    printf '#!/bin/bash\n' >"${LINT_ROOT}/script/scratch"
    chmod +x "${LINT_ROOT}/script/scratch"
    run "${LINT_ROOT}/script/test/test.sh" --ci-lint
    assert_success
    assert_output --partial 'Script layout OK'
}

@test "lint fails when fallback snapshot cannot be written" {
    _prepare_lint_worktree
    local bin="${BATS_TEST_TMPDIR}/no-git-bin" tool
    mkdir -p "${bin}"
    for tool in bash dirname find mktemp rm; do
        ln -s "$(command -v "${tool}")" "${bin}/${tool}"
    done
    cat >"${BATS_TEST_TMPDIR}/write-snapshot.sh" <<'SCRIPT'
source "$1"
if _write_lint_paths /dev/full; then exit 0; else exit 1; fi
SCRIPT
    PATH="${bin}" run bash "${BATS_TEST_TMPDIR}/write-snapshot.sh" "${LINT_ROOT}/script/test/test.sh"
    assert_failure 1
    assert_output --partial 'cannot write filesystem lint discovery snapshot'
}
