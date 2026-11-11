#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    bats_require_minimum_version 1.5.0
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config"
    export TMPDIR="${BATS_TEST_TMPDIR}"
    mkdir -p "${XDG_CONFIG_HOME}/ghostty"
    printf 'original\n' >"${XDG_CONFIG_HOME}/ghostty/config"
    # shellcheck source=lib/guard.sh
    source "${LIB_DIR}/guard.sh"
    # shellcheck source=lib/config_backup.sh
    source "${LIB_DIR}/config_backup.sh"
    cfgbk_paths
}

_prepare_backup() {
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
}

@test "restore refuses a corrupted regular backup before changing any live file" {
    local live="${XDG_CONFIG_HOME}/ghostty/config"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'live after setup\n' >"${live}"
    printf 'damaged backup\n' >"${CFGBK_B}/ghostty.config"

    run cfgbk_restore_all

    assert_failure 1
    assert_equal "$(cat "${live}")" 'live after setup'
    assert [ -f "${CFGBK_B}/manifest" ]
}

@test "restore refuses a corrupted symlink target backup before changing live bytes" {
    local live="${XDG_CONFIG_HOME}/ghostty/config" target="${HOME}/user-config"
    rm "${live}"
    printf 'original target\n' >"${target}"
    ln -s "${target}" "${live}"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'live after setup\n' >"${target}"
    printf 'damaged target backup\n' >"${CFGBK_B}/ghostty.target"

    run cfgbk_restore_all

    assert_failure 1
    assert [ -L "${live}" ]
    assert_equal "$(cat "${target}")" 'live after setup'
    assert [ -f "${CFGBK_B}/manifest" ]
}

@test "restore preflight allows live changes but refuses a later corrupted backup before any write" {
    local ghostty="${XDG_CONFIG_HOME}/ghostty/config" state="${XDG_CONFIG_HOME}/worktool/config"
    mkdir -p "${XDG_CONFIG_HOME}/worktool"
    printf 'original state\n' >"${state}"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed ghostty\n' >"${ghostty}"
    printf 'changed state\n' >"${state}"
    run cfgbk_restore_preflight
    assert_success
    printf 'corrupt state backup\n' >"${CFGBK_B}/worktool.config"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${ghostty}")" 'changed ghostty'
    assert_equal "$(cat "${state}")" 'changed state'
}

@test "restore preflight rejects duplicate checksums and incomplete manifests" {
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'ghostty.sha=duplicate\n' >>"${CFGBK_B}/manifest"
    run cfgbk_restore_preflight
    assert_failure 1
    sed -i '$d' "${CFGBK_B}/manifest"
    : >"${CFGBK_B}/manifest.partial"
    run cfgbk_restore_preflight
    assert_failure 1
}

@test "restore rejects a redirected symlink target without touching unrelated files" {
    local live="${XDG_CONFIG_HOME}/ghostty/config" target="${HOME}/user-config" sentinel="${HOME}/sentinel"
    rm "${live}"
    printf 'original\n' >"${target}"
    printf 'unrelated\n' >"${sentinel}"
    ln -s "${target}" "${live}"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${target}"
    sed -i "s|^ghostty.tpath=.*|ghostty.tpath=${sentinel}|" "${CFGBK_B}/manifest"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${target}")" changed
    assert_equal "$(cat "${sentinel}")" unrelated
}

@test "restore rejects malformed and unrelated directory metadata before writing" {
    local live="${XDG_CONFIG_HOME}/ghostty/config" sentinel="${BATS_TEST_TMPDIR}/unrelated"
    mkdir "${sentinel}"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${live}"
    printf '%s\0%s\0' "${sentinel}" '2001-01-01 00:00:00 +0000' >>"${CFGBK_B}/directories"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${live}")" changed
}

@test "restore refuses incomplete or missing directory metadata before changing live files" {
    local live="${XDG_CONFIG_HOME}/ghostty/config"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${live}"
    printf '%s\0%s' "${HOME}" 'invalid' >"${CFGBK_B}/directories"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${live}")" changed
    rm "${CFGBK_B}/directories"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${live}")" changed
}

@test "restore refuses unrelated absent-directory entries before changing live files" {
    local live="${XDG_CONFIG_HOME}/ghostty/config" sentinel="${BATS_TEST_TMPDIR}/unrelated"
    mkdir "${sentinel}"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${live}"
    printf '%s\0' "${sentinel}" >>"${CFGBK_B}/absent-directories"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${live}")" changed
    assert [ -d "${sentinel}" ]
}

@test "restore rejects directory metadata above an external link target parent" {
    local live="${XDG_CONFIG_HOME}/ghostty/config" external="${BATS_TEST_TMPDIR}/outside" target
    mkdir -p "${external}/owned"
    target="${external}/owned/target"
    printf 'original\n' >"${target}"
    rm "${live}"
    ln -s "${target}" "${live}"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${target}"
    printf '%s\0%s\0' "${external}" '2001-01-01 00:00:00 +0000' >>"${CFGBK_B}/directories"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${target}")" changed
}

@test "legacy backup without location metadata is retained without changing live files" {
    local live="${XDG_CONFIG_HOME}/ghostty/config"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${live}"
    sed -i '/^backup.version=/d' "${CFGBK_B}/manifest"
    run --separate-stderr cfgbk_restore_all
    assert_failure 1
    [[ "${stderr:-}" == *'preserve it and inspect or restore manually'* ]]
    assert_equal "$(cat "${live}")" changed
    assert [ -f "${CFGBK_B}/manifest" ]
}

@test "restore rejects parent-first absent directories before changing live files" {
    local live="${XDG_CONFIG_HOME}/ghostty/config" parent="${HOME}/.cache" child="${HOME}/.cache/worktool"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${live}"
    printf '%s\0%s\0' "${parent}" "${child}" >"${CFGBK_B}/absent-directories"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${live}")" changed
}

@test "restore refuses a modified directory inventory before changing live files" {
    local live="${XDG_CONFIG_HOME}/ghostty/config"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${live}"
    printf '%s\0%s\0' "${HOME}" '2001-01-01 00:00:00 +0000' >"${CFGBK_B}/directories"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${live}")" changed
}

@test "restore refuses an added absent directory even when its path is in scope" {
    local live="${XDG_CONFIG_HOME}/ghostty/config" owned="${XDG_CONFIG_HOME}/ghostty"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${live}"
    printf '%s\0' "${owned}" >>"${CFGBK_B}/absent-directories"
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${live}")" changed
    assert [ -d "${owned}" ]
}

@test "restore refuses a changed config root without modifying either location" {
    local old="${XDG_CONFIG_HOME}/ghostty/config" other="${HOME}/other"
    BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    _prepare_backup
    printf 'changed\n' >"${old}"
    mkdir -p "${other}/ghostty"
    printf 'sentinel\n' >"${other}/ghostty/config"
    export XDG_CONFIG_HOME="${other}"
    cfgbk_paths
    run cfgbk_restore_all
    assert_failure 1
    assert_equal "$(cat "${old}")" changed
    assert_equal "$(cat "${other}/ghostty/config")" sentinel
}
