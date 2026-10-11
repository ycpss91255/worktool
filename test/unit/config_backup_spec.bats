#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    bats_require_minimum_version 1.5.0
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config"
    export TMPDIR="${BATS_TEST_TMPDIR}"
    mkdir -p "${XDG_CONFIG_HOME}/ghostty"
    source "${LIB_DIR}/guard.sh"
    source "${LIB_DIR}/config_backup.sh"
    cfgbk_paths
}

@test "#523: an existing unreadable Ghostty target still fails the block report" {
    local dir
    dir="$(mktemp -d /tmp/cfgbk-unreadable.XXXXXX)"
    chmod 755 "${dir}"
    mkdir "${dir}/ghostty"
    printf 'font-size = 12\n' >"${dir}/target"
    chmod 000 "${dir}/target"
    ln -s ../target "${dir}/ghostty/config"
    export CFGBK_TEST_CONFIG="${dir}"
    local -a as_user=(bash -c)
    if [[ "$(id -u)" -eq 0 ]]; then as_user=(su nobody -s /bin/bash -c); fi

    run --separate-stderr "${as_user[@]}" '
        source "${LIB_DIR}/guard.sh"
        source "${LIB_DIR}/config_backup.sh"
        CFGBK_C="${CFGBK_TEST_CONFIG}"
        cfgbk_report_blocks
    '
    chmod 600 "${dir}/target"
    rm -rf "${dir}"

    assert_failure 1
    assert_output 'blocks=-1'
    [[ "${stderr}" == *"[FAIL] cannot read ${dir}/ghostty/config -- blocks= is not trustworthy"* ]]
}

@test "#523: dangling Ghostty config reports zero managed blocks successfully" {
    ln -s missing-config "${XDG_CONFIG_HOME}/ghostty/config"

    run --separate-stderr cfgbk_report_blocks

    assert_success
    assert_output 'blocks=0'
    assert_equal "${stderr}" ''
}
