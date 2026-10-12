#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"
bats_require_minimum_version 1.5.0

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home" TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    export MATRIX_STATE="${BATS_TEST_TMPDIR}/state"
    mkdir -p "${HOME}" "${TMPDIR}" "${MATRIX_STATE}/bin"
    : >"${MATRIX_STATE}/boxes"
    export FAKE_STATE_DIR="${MATRIX_STATE}"
    install -m 755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${MATRIX_STATE}/bin/distrobox"
    install -m 755 "${BATS_TEST_DIRNAME}/fixture/realbox_matrix_just.sh" "${MATRIX_STATE}/bin/just"
    cat >"${MATRIX_STATE}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == 'issue view' ]]; then
    echo '[]'
else
    echo posted >>"${MATRIX_STATE}/comments"
    exit 1
fi
STUB
    chmod +x "${MATRIX_STATE}/bin/gh"
    export PATH="${MATRIX_STATE}/bin:${PATH}"
    unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
    REALBOX="${REPO_ROOT}/script/verify/realbox.sh"
}

@test "5.4: all six event-driven interrupts have pinned passing output" {
    run "${REALBOX}" --allow-real-box 5.4
    assert_success
    local phase signal code expected=''
    for phase in assemble bench; do
        for signal in INT TERM HUP; do
            case "${signal}" in INT) code=130 ;; TERM) code=143 ;; HUP) code=129 ;; esac
            expected+="interrupt ${phase} ${signal}: rc=${code} cleanup-rc=0 box-gone=1 home=0 tmux=0 host-new=0 posted=0 PASS"$'\n'
        done
    done
    expected+='interrupt-matrix: PASS (6/6)'
    assert_output "${expected}"
    [ ! -s "${MATRIX_STATE}/boxes" ]
    [ ! -e "${MATRIX_STATE}/comments" ]
}

@test "5.4: any cell cleanup failure fails the matrix" {
    cat >"${MATRIX_STATE}/bin/distrobox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == rm && "${XDG_DATA_HOME}" == *"${MATRIX_FAIL_CELL}"* ]]; then
    exit 1
fi
exec "${MATRIX_STATE}/original/distrobox" "$@"
STUB
    # Preserve the basename used by the tool fixture to dispatch.
    mkdir -p "${MATRIX_STATE}/original"
    install -m 755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${MATRIX_STATE}/original/distrobox"
    local phase signal
    for phase in assemble bench; do
        for signal in INT TERM HUP; do
            export MATRIX_FAIL_CELL="${phase}-${signal}"
            : >"${MATRIX_STATE}/boxes"
            run "${REALBOX}" --allow-real-box 5.4
            assert_failure 1
            assert_line --partial "interrupt ${phase} ${signal}: FAIL (rc=1; cleanup-rc=1; evidence="
            assert_line 'interrupt-matrix: FAIL'
            refute_output --partial 'interrupt-matrix: PASS'
            [ -s "${MATRIX_STATE}/boxes" ]
        done
    done
}

_copy_matrix_repo() {
    local repo="${MATRIX_STATE}/repo"
    mkdir -p "${repo}"
    cp -a "${REPO_ROOT}/script" "${REPO_ROOT}/lib" "${REPO_ROOT}/box" "${repo}/"
    REALBOX="${repo}/script/verify/realbox.sh"
}

@test "5.4: a copy without signal forwarding turns the interrupt cell red" {
    _copy_matrix_repo
    sed -i "s/verify_stop_group \"\${monitor}\" \"\${interrupted}\"/if [[ \"\${TMPDIR}\" != *\"\${FORWARDING_DEGRADE_CELL}\"* ]]; then verify_stop_group \"\${monitor}\" \"\${interrupted}\"; fi/" "${MATRIX_STATE}/repo/lib/verify_run.sh"
    sed -i 's/TIMEOUT_LONG=1800/TIMEOUT_LONG=8/; s/TIMEOUT_SHORT=180/TIMEOUT_SHORT=3/' "${REALBOX}"
    local phase signal
    for phase in assemble bench; do
        for signal in INT TERM HUP; do
            export FORWARDING_DEGRADE_CELL="${phase}-${signal}"
            run "${REALBOX}" --allow-real-box 5.4
            assert_failure 1
            assert_line --partial "interrupt ${phase} ${signal}: FAIL ("
            assert_line 'interrupt-matrix: FAIL'
            refute_output --partial 'interrupt-matrix: PASS'
        done
    done
}

@test "5.4: a copy without cleanup turns every corresponding cell red" {
    _copy_matrix_repo
    sed -i "/^_51_cleanup() {/a\\    if [[ \"\${TMPDIR}\" == *\"\${CLEANUP_DEGRADE_CELL}\"* ]]; then return 0; fi" "${REALBOX}"
    local phase signal code
    for phase in assemble bench; do
        for signal in INT TERM HUP; do
            export CLEANUP_DEGRADE_CELL="${phase}-${signal}"
            : >"${MATRIX_STATE}/boxes"
            case "${signal}" in INT) code=130 ;; TERM) code=143 ;; HUP) code=129 ;; esac
            run "${REALBOX}" --allow-real-box 5.4
            assert_failure 1
            assert_line --partial "interrupt ${phase} ${signal}: FAIL (rc=${code}; cleanup-rc=missing; evidence="
            assert_line 'interrupt-matrix: FAIL'
            refute_output --partial 'interrupt-matrix: PASS'
            [ -s "${MATRIX_STATE}/boxes" ]
            local box_home
            read -r box_home <"${MATRIX_STATE}/home"
            [ -d "${box_home}/.cache/tmux" ]
        done
    done
}
