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

@test "#626: backup and real setup restore an absent config root and preserve its ancestor" {
    rmdir "${XDG_CONFIG_HOME}/ghostty" "${XDG_CONFIG_HOME}"
    export XDG_CONFIG_HOME="${HOME}/missing/config"
    cfgbk_paths
    touch -d '2001-01-01' "${HOME}"
    local ancestor_inode ancestor_mtime
    ancestor_inode="$(stat -c %i "${HOME}")"
    ancestor_mtime="$(stat -c %y "${HOME}")"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    run just box setup --terminal ghostty
    assert_success
    : >"${XDG_CONFIG_HOME}/ghostty/config.ghostty"
    run just box setup --terminal ghostty
    assert_success
    mkdir -p "${HOME}/.cache/worktool"
    printf 'acceptance output\n' >"$(cfgbk_file_of init-log)"

    run bash -euo pipefail -c '
        source "$REPO_ROOT/lib/guard.sh"
        source "$REPO_ROOT/script/verify/config_backup_paths.sh"
        cfgbk_paths
        cfgbk_restore_all
        cfgbk_report_leftover_dirs
    '

    assert_success
    assert_output 'leftover-dirs=0'
    assert [ ! -e "${HOME}/missing" ]
    assert [ ! -e "${HOME}/.cache" ]
    assert_equal "$(stat -c %i "${HOME}")" "${ancestor_inode}"
    assert_equal "$(stat -c %y "${HOME}")" "${ancestor_mtime}"
}

@test "#626: non-empty config parents fail restore and count each leftover directory once" {
    rmdir "${XDG_CONFIG_HOME}/ghostty" "${XDG_CONFIG_HOME}"
    export XDG_CONFIG_HOME="${HOME}/missing/config"
    cfgbk_paths
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    run just box setup --terminal ghostty
    assert_success
    printf 'user content\n' >"${XDG_CONFIG_HOME}/ghostty/keep"

    run cfgbk_restore_all

    assert_failure 1
    assert_equal "$(cat "${XDG_CONFIG_HOME}/ghostty/keep")" 'user content'
    assert [ ! -e "$(cfgbk_file_of ghostty)" ]
    run cfgbk_report_leftover_dirs
    assert_failure 1
    assert_line 'leftover-dirs=3'

    rm "${XDG_CONFIG_HOME}/ghostty/keep"
    run cfgbk_restore_all
    assert_success
    assert [ ! -e "${HOME}/missing" ]
    run cfgbk_report_leftover_dirs
    assert_success
    assert_output 'leftover-dirs=0'
}

@test "#626: overlapping config and cache chains restore children before shared parents" {
    rmdir "${XDG_CONFIG_HOME}/ghostty" "${XDG_CONFIG_HOME}"
    export XDG_CACHE_HOME="${XDG_CONFIG_HOME}/nested/cache"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    run just box setup --terminal ghostty
    assert_success
    mkdir -p "${XDG_CACHE_HOME}/worktool"
    printf 'acceptance output\n' >"$(cfgbk_file_of init-log)"

    run cfgbk_restore_all

    assert_success
    assert [ ! -e "${XDG_CONFIG_HOME}" ]
    run cfgbk_report_leftover_dirs
    assert_success
    assert_output 'leftover-dirs=0'
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

@test "#589: missing relative cache parents restore from a different working directory" {
    # Bound a regressed backup loop's runtime and journal size.
    run bash -euo pipefail -c '
        export XDG_CACHE_HOME=relcache
        ulimit -f 128
        timeout 5 bash -euo pipefail -c '\''
            source "$REPO_ROOT/lib/guard.sh"
            source "$REPO_ROOT/script/verify/config_backup_paths.sh"
            cd "$HOME"
            cfgbk_paths
            cfgbk_preflight
            cfgbk_dir_create
            cfgbk_backup_body
            mkdir -p "$XDG_CACHE_HOME/worktool"
            cd "$TMPDIR"
            cfgbk_restore_all
            cfgbk_report_leftover_dirs
        '\''
    '

    assert_success
    assert_line "backup=${CFGBK_B} ok=1"
    assert_line 'leftover-dirs=0'
    assert [ ! -e "${HOME}/relcache" ]
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

@test "#589: a fresh shell restores a missing external XDG cache chain through its existing ancestor" {
    local ancestor="${BATS_TEST_TMPDIR}/external cache"
    export XDG_CACHE_HOME="${ancestor}/nested/cache"
    mkdir "${ancestor}"
    printf 'user content\n' >"${ancestor}/keep"
    touch -d '2001-01-01' "${ancestor}"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    mkdir -p "${XDG_CACHE_HOME}/worktool"
    printf 'acceptance output\n' >"$(cfgbk_file_of init-log)"

    run bash -euo pipefail -c '
        source "$REPO_ROOT/lib/guard.sh"
        source "$REPO_ROOT/script/verify/config_backup_paths.sh"
        cfgbk_paths
        cfgbk_restore_all
        cfgbk_report_leftover_dirs
    '

    assert_success
    assert_output 'leftover-dirs=0'
    assert [ ! -e "${ancestor}/nested" ]
    assert_equal "$(cat "${ancestor}/keep")" 'user content'
    assert_equal "$(stat -c %y "${ancestor}")" '2001-01-01 00:00:00.000000000 +0000'
}
