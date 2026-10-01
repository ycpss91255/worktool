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
#   The REAL script/test/test.sh runs with a FAKE `docker` first on PATH
#   that records every call (one line per call) and answers as told:
#   exit 0, or exit 1 when the call mentions $FAKE_DOCKER_FAIL_ON. Every
#   host-side route ends in a docker call (a `docker run` of the in-container
#   flag, or the DinD runner's `docker build` + `docker run --privileged`), so
#   the recorded sequence IS the order the runner dispatched. No container
#   is ever started. TEST_IMAGE_PREBUILT=1 skips the test-image build, as CI
#   does, so the record holds only the gate calls (plus the runner image
#   build that --system-real always does).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    TEST_SH="${REPO_ROOT}/script/test/test.sh"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    export FAKE_DOCKER_CALLS="${BATS_TEST_TMPDIR}/docker.calls"
    unset FAKE_DOCKER_FAIL_ON
    mkdir -p "${FAKE_BIN}"
    cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"${FAKE_DOCKER_CALLS}"
if [[ -n "${FAKE_DOCKER_FAIL_ON:-}" && "$*" == *"${FAKE_DOCKER_FAIL_ON}"* ]]; then
    exit 1
fi
exit 0
EOF
    chmod +x "${FAKE_BIN}/docker"
    export PATH="${FAKE_BIN}:${PATH}"
    export TEST_IMAGE_PREBUILT=1
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
        --acceptance --help; do
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

@test "test.sh with no flag stops at the first failing step" {
    FAKE_DOCKER_FAIL_ON=--ci-system run "${TEST_SH}"
    assert_failure
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint --ci-unit --ci-matrix \
        --ci-integration build --ci-integration-ghostty \
        --ci-system)"
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
@test "test.sh --system-real passes CI through to the DinD runner (-e CI)" {
    CI=true run "${TEST_SH}" --system-real
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp '^docker run --rm --privileged -e CI .* \./script/test/system-real-entry\.sh$'
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
    assert_line --regexp '^docker run --rm -e WORKTOOL_TEST_JOBS -v .*:/source -w /source .* \./script/test/test\.sh --ci-unit$'
}

@test "test.sh --unit forwards one spec path to the container gate" {
    run "${TEST_SH}" --unit test/unit/test_sh_spec.bats
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp 'test\.sh --ci-unit test/unit/test_sh_spec\.bats$'
}

@test "test.sh --unit forwards multiple spec paths in order" {
    run "${TEST_SH}" --unit test/unit/test_sh_spec.bats test/unit/ci_gate_spec.bats
    assert_success
    run cat "${FAKE_DOCKER_CALLS}"
    assert_line --regexp 'test\.sh --ci-unit test/unit/test_sh_spec\.bats test/unit/ci_gate_spec\.bats$'
}

# --- errexit (issue #195) ----------------------------------------------------

@test "test.sh runs under set -euo pipefail (one set line, errexit included)" {
    run grep -E '^set -[a-z]+( pipefail)?$' "${TEST_SH}"
    assert_success
    assert_output 'set -euo pipefail'
}
