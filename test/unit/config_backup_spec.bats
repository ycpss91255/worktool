#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config"
    export TMPDIR="${BATS_TEST_TMPDIR}"
    mkdir -p "${XDG_CONFIG_HOME}/ghostty"
    source "${LIB_DIR}/guard.sh"
    source "${LIB_DIR}/config_backup.sh"
    cfgbk_paths
}

@test "#523: dangling Ghostty config reports zero managed blocks successfully" {
    ln -s missing-config "${XDG_CONFIG_HOME}/ghostty/config"

    run --separate-stderr cfgbk_report_blocks

    assert_success
    assert_output 'blocks=0'
    assert_equal "${stderr}" ''
}
