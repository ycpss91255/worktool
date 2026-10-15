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

@test "#589: restore preserves existing cache and removes only the new worktool directory" {
    mkdir "${HOME}/.cache"
    touch -d '2001-01-01' "${HOME}/.cache"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    mkdir "${HOME}/.cache/worktool"
    printf 'acceptance output\n' >"$(cfgbk_file_of init-log)"

    run cfgbk_restore_all

    assert_success
    assert [ -d "${HOME}/.cache" ]
    assert [ ! -e "${HOME}/.cache/worktool" ]
    assert_equal "$(stat -c %y "${HOME}/.cache")" '2001-01-01 00:00:00.000000000 +0000'
    run cfgbk_report_leftover_dirs
    assert_success
    assert_output 'leftover-dirs=0'
}

@test "#589: non-empty created parents survive and fail closed with truthful leftover counts" {
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    mkdir -p "${HOME}/.cache/worktool"
    printf 'acceptance output\n' >"$(cfgbk_file_of init-log)"
    printf 'user content\n' >"${HOME}/.cache/worktool/keep"

    run cfgbk_restore_all

    assert_failure 1
    assert_equal "$(cat "${HOME}/.cache/worktool/keep")" 'user content'
    assert [ ! -e "$(cfgbk_file_of init-log)" ]
    run cfgbk_report_leftover_dirs
    assert_failure 1
    assert_line 'leftover-dirs=2'

    rm "${HOME}/.cache/worktool/keep"
    run cfgbk_restore_all
    assert_success
    assert [ ! -e "${HOME}/.cache" ]
    run cfgbk_report_leftover_dirs
    assert_success
    assert_output 'leftover-dirs=0'
}
