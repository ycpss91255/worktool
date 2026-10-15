#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    bats_require_minimum_version 1.5.0
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config"
    export XDG_CACHE_HOME="" TMPDIR="${BATS_TEST_TMPDIR}" BOX=dev
    mkdir -p "${XDG_CONFIG_HOME}/ghostty"
    # shellcheck source=lib/guard.sh
    source "${LIB_DIR}/guard.sh"
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
}

@test "#589: restore removes the init-log parent chain when cache was absent" {
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    mkdir -p "${HOME}/.cache/worktool"
    printf 'acceptance output\n' >"$(cfgbk_file_of init-log)"

    run cfgbk_restore_all

    assert_success
    assert [ ! -e "${HOME}/.cache" ]
    run cfgbk_report_leftover_dirs
    assert_success
    assert_output 'leftover-dirs=0'
}
