#!/usr/bin/env bats
# test/unit/hook/enforce_cpu_capacity_spec.bats -
# .agents/hook/enforce_cpu_capacity.sh (issue #244)
#
# Before the main session starts another Workflow or background agent, the
# hook reads the CPU pressure (PSI `some avg60`, plus loadavg and nproc for
# the record) and the number of running worktool test containers; over a
# limit it blocks (exit 2) with the current values, the limits and what to
# do instead. Every input is injected: the PSI and loadavg files and nproc
# through CPU_GATE_* variables, `docker ps` through a PATH stub that prints
# ${DOCKER_STUB_DIR}/ps (one image and state per line).

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    DOCKER_STUB_DIR="${BATS_TEST_TMPDIR}/docker"
    mkdir -p "${DOCKER_STUB_DIR}/bin"
    export DOCKER_STUB_DIR
    cat >"${DOCKER_STUB_DIR}/bin/docker" <<'STUB'
#!/usr/bin/env bash
# docker stub: `docker ps ...` prints the fixture; anything else fails.
[[ "${1:-}" == ps ]] || exit 1
[[ -f "${DOCKER_STUB_DIR}/fail_ps" ]] && exit 1
cat "${DOCKER_STUB_DIR}/ps"
STUB
    chmod +x "${DOCKER_STUB_DIR}/bin/docker"
    PATH="${DOCKER_STUB_DIR}/bin:${PATH}"
    : >"${DOCKER_STUB_DIR}/ps"
    CPU_GATE_PSI_FILE="${BATS_TEST_TMPDIR}/psi"
    CPU_GATE_LOADAVG_FILE="${BATS_TEST_TMPDIR}/loadavg"
    CPU_GATE_NPROC=8
    export PATH CPU_GATE_PSI_FILE CPU_GATE_LOADAVG_FILE CPU_GATE_NPROC
    _psi 10.00
    printf '3.10 2.50 2.00 2/900 12345\n' >"${CPU_GATE_LOADAVG_FILE}"
}

# _psi <some-avg60> - a /proc/pressure/cpu fixture.
_psi() {
    printf 'some avg10=1.00 avg60=%s avg300=1.00 total=100\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' \
        "$1" >"${CPU_GATE_PSI_FILE}"
}

# _containers <n> [image] [state] - n containers of <image> (default the
# test image tag script/test/test.sh builds) in <state> (default running).
_containers() {
    local _i
    for ((_i = 0; _i < $1; _i++)); do
        printf '%s|%s\n' "${2:-worktool-test:local}" "${3:-running}" >>"${DOCKER_STUB_DIR}/ps"
    done
}

# _launch [tool] [run_in_background] - a PreToolUse payload for <tool>.
_launch() {
    run_hook enforce_cpu_capacity "$(jq -n --arg t "${1:-Workflow}" --argjson bg "${2:-null}" \
        '{tool_name:$t, tool_input:({prompt:"x"}
            + (if $bg == null then {} else {run_in_background:$bg} end))}')"
}

# --- allowed -----------------------------------------------------------------

@test "fewer than two running test containers allow a Workflow" {
    local _count
    for _count in 0 1; do
        : >"${DOCKER_STUB_DIR}/ps"
        _containers "${_count}"
        _launch Workflow
        assert_success
        refute_output --partial "BLOCKED"
    done
}

@test "fewer than two running test containers allow a Workflow when test containers are paused" {
    local _count
    for _count in 0 1; do
        : >"${DOCKER_STUB_DIR}/ps"
        _containers "${_count}"
        _containers 2 worktool-test:local paused
        _launch Workflow
        assert_success
        refute_output --partial "BLOCKED"
    done
}

# --- blocked -----------------------------------------------------------------

@test "PSI some avg60 over the limit blocks a Workflow, listing values, limits and advice" {
    _psi 50.01
    _launch Workflow
    assert_failure 2
    assert_output --partial "BLOCKED"
    assert_output --partial "PSI some avg60 50.01 (limit 50)"
    assert_output --partial "loadavg 3.10 2.50 2.00"
    assert_output --partial "nproc 8"
    assert_output --partial "test containers 0 (limit 2)"
    assert_output --partial "fanout"
}

@test "PSI exactly at the limit still passes (the limit is exclusive)" {
    _psi 50.00
    _launch Workflow
    assert_success
}

@test "two or more running test containers block a Workflow even at low PSI" {
    local _count
    for _count in 2 3; do
        : >"${DOCKER_STUB_DIR}/ps"
        _containers "${_count}"
        _launch Workflow
        assert_failure 2
        assert_output --partial "BLOCKED"
        assert_output --partial "at most 2 tests at a time"
        assert_output --partial "test containers ${_count} (limit 2)"
        assert_output --partial "PSI some avg60 10.00 (limit 50)"
    done
}

@test "two or more running test containers block when test containers are paused" {
    local _count
    for _count in 2 3; do
        : >"${DOCKER_STUB_DIR}/ps"
        _containers "${_count}"
        _containers 2 worktool-test:local paused
        _launch Workflow
        assert_failure 2
        assert_output --partial "test containers ${_count} (limit 2)"
    done
}

@test "the container limit stays fixed when nproc changes" {
    CPU_GATE_NPROC=4
    _containers 3
    _launch Workflow
    assert_failure 2
    assert_output --partial "test containers 3 (limit 2)"
    assert_output --partial "nproc 4"
}

@test "every test image test.sh runs counts, any tag; other images do not" {
    _containers 2 worktool-test:ci
    _containers 2 worktool-system-real:local
    _containers 1 worktool-ghostty:local
    _containers 9 ubuntu:24.04
    _containers 9 worktool-dev:latest
    _launch Workflow
    assert_failure 2
    assert_output --partial "test containers 5 (limit 2)"
}

# --- PSI or docker unreadable ------------------------------------------------

@test "PSI unreadable: judged on the test containers only, and the message says so" {
    rm -f "${CPU_GATE_PSI_FILE}"
    _containers 5
    _launch Workflow
    assert_failure 2
    assert_output --partial "PSI unavailable (judged on test containers only)"
    assert_output --partial "test containers 5 (limit 2)"
}

@test "PSI unreadable with few test containers: a Workflow starts" {
    rm -f "${CPU_GATE_PSI_FILE}"
    _containers 1
    _launch Workflow
    assert_success
}

@test "docker ps failing: judged on PSI only, and the message says so" {
    touch "${DOCKER_STUB_DIR}/fail_ps"
    _psi 80.00
    _launch Workflow
    assert_failure 2
    assert_output --partial "test containers unknown (docker ps failed; judged on PSI only)"
}

# --- which tool calls are gated ----------------------------------------------

@test "a background Agent is blocked under saturation" {
    _psi 90.00
    _launch Agent true
    assert_failure 2
    assert_output --partial "BLOCKED"
}

@test "a foreground Agent passes even under saturation" {
    _psi 90.00
    _containers 9
    _launch Agent false
    assert_success
    _launch Agent
    assert_success
}

@test "tools other than Workflow / Agent are not affected" {
    _psi 90.00
    _containers 9
    local _t
    for _t in Bash Edit Write Read; do
        _launch "${_t}"
        assert_success
        refute_output --partial "BLOCKED"
    done
}
