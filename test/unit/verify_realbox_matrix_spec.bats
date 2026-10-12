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
