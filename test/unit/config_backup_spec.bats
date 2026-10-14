#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    bats_require_minimum_version 1.5.0
    stderr=""
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config"
    export TMPDIR="${BATS_TEST_TMPDIR}"
    mkdir -p "${XDG_CONFIG_HOME}/ghostty"
    # shellcheck source=lib/guard.sh
    source "${LIB_DIR}/guard.sh"
    # shellcheck source=lib/config_backup.sh
    source "${LIB_DIR}/config_backup.sh"
    cfgbk_paths
}

@test "#588: restore removes an init-log target created through an originally dangling link" {
    local BOX=dev log target
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    mkdir -p "${HOME}/.cache/worktool"
    log="$(cfgbk_file_of init-log)"
    target="${HOME}/.cache/new init log"
    ln -s '../new init log' "${log}"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    assert_equal "$(guard_field "${CFGBK_B}" init-log.tpath)" "${target}"
    cfgbk_revalidate
    printf 'acceptance init output\n' >"${log}"

    run cfgbk_restore_all

    assert_success
    assert [ ! -e "${target}" ]
    assert [ ! -L "${target}" ]
    assert [ -L "${log}" ]
    assert [ ! -e "${log}" ]
    assert_equal "$(readlink "${log}")" '../new init log'
}

@test "#588: restore fails closed when removal leaves the init-log target present" {
    local BOX=dev log target removal_rc
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    mkdir -p "${HOME}/.cache/worktool"
    log="$(cfgbk_file_of init-log)"
    target="${HOME}/new-init-log"
    ln -s "${target}" "${log}"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    printf 'acceptance init output\n' >"${log}"
    # A failing remover and a false success must both fail the restore.
    rm() {
        if [[ "${*: -1}" == "${target}" ]]; then return "${removal_rc}"; fi
        command rm "$@"
    }
    for removal_rc in 1 0; do
        run cfgbk_restore_one init-log

        assert_failure 1
        assert [ -e "${target}" ]
        assert [ -L "${log}" ]
    done
}

@test "#576: leftover directory report skips other manifest states under errexit" {
    cfgbk_dir_create
    printf 'ghostty=absent-file\nworktool=absent-dir\n' >"${CFGBK_B}/manifest"

    run bash -c '
        set -euo pipefail
        source "$1/guard.sh"
        source "$1/config_backup.sh"
        cfgbk_paths
        cfgbk_report_leftover_dirs
        printf "returned=%s\n" "$?"
    ' _ "${LIB_DIR}"

    assert_success
    assert_output $'leftover-dirs=0\nreturned=0'
}

@test "#576: restoring an already absent directory succeeds under errexit" {
    cfgbk_dir_create
    printf 'worktool=absent-dir\n' >"${CFGBK_B}/manifest"

    run bash -c '
        set -euo pipefail
        source "$1/guard.sh"
        source "$1/config_backup.sh"
        cfgbk_paths
        cfgbk_restore_one worktool
        printf "returned=%s\n" "$?"
    ' _ "${LIB_DIR}"

    assert_success
    assert_output 'returned=0'
    [[ ! -e "${XDG_CONFIG_HOME}/worktool" ]]
}

@test "#536: external symlink target protects its parent without recording or restoring ancestors" {
    local root="${BATS_TEST_TMPDIR}/opt" target config
    target="${root}/user config/ghostty"
    config="${XDG_CONFIG_HOME}/ghostty/config"
    mkdir -p "${target%/*}"
    printf 'original\n' >"${target}"
    ln -s "${target}" "${config}"
    touch -d '2001-01-01' "${target%/*}" "${root}"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    touch -d '2002-02-02' "${root}"
    # An unrelated writer above the target root cannot invalidate the backup.
    run cfgbk_dirs_ok
    assert_success
    local path _mtime
    while IFS= read -r -d '' path; do
        IFS= read -r -d '' _mtime
        [[ "${path}" == "${HOME}" || "${path}" == "${HOME}/"* || "${path}" == "${target%/*}" ]]
    done <"${CFGBK_B}/directories"
    printf 'changed\n' >"${target}"
    touch -d '2003-03-03' "${target%/*}"
    cfgbk_restore_one ghostty
    cfgbk_restore_dirs
    assert_equal "$(cat "${target}")" original
    assert_equal "$(stat -c %y "${target%/*}")" '2001-01-01 00:00:00.000000000 +0000'
    assert_equal "$(stat -c %y "${root}")" '2002-02-02 00:00:00.000000000 +0000'
}

@test "#526: unchanged regular file, symlink and target keep their inodes on restore" {
    local config="${XDG_CONFIG_HOME}/ghostty/config" target="${HOME}/original"
    printf 'font-size = 13\n' >"${target}"
    chmod 640 "${target}"
    ln -s ../../original "${config}"
    printf 'set -g mouse on\n' >"${HOME}/.tmux.conf"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    local link_inode target_inode regular_inode
    link_inode="$(stat -c %i "${config}")"
    target_inode="$(stat -c %i "${target}")"
    regular_inode="$(stat -c %i "${HOME}/.tmux.conf")"
    # Keep each original inode allocated so delete/recreate cannot reuse it.
    ln -P "${config}" "${BATS_TEST_TMPDIR}/pinned-link"
    ln "${target}" "${BATS_TEST_TMPDIR}/pinned-target"
    ln "${HOME}/.tmux.conf" "${BATS_TEST_TMPDIR}/pinned-regular"

    cfgbk_restore_one ghostty
    cfgbk_restore_one tmux-conf

    assert_equal "$(stat -c %i "${config}")" "${link_inode}"
    assert_equal "$(stat -c %i "${target}")" "${target_inode}"
    assert_equal "$(stat -c %i "${HOME}/.tmux.conf")" "${regular_inode}"
}

@test "#525: removing user trailing blank lines reports LOST and fails" {
    local config="${XDG_CONFIG_HOME}/ghostty/config"
    printf 'font-size = 13\n\n\n' >"${config}"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    printf 'font-size = 13\n' >"${config}"

    run --separate-stderr cfgbk_report_user_content after-apply

    assert_failure 1
    assert_output 'user-content after-apply: ghostty=LOST tmux.conf=intact'
    [[ "${stderr}" == *"lost content the user had before this run"* ]]
    [[ "${stderr}" == *'font-size = 13\n\n\n'* ]]
}

@test "#525: identical user content including trailing blanks remains intact" {
    local config="${XDG_CONFIG_HOME}/ghostty/config"
    printf '%s\n' "${CFGBK_BLOCK_BEGIN}" 'old managed content' \
        "${CFGBK_BLOCK_END}" >"${config}"
    printf 'font-size = 13\n\n\n' >>"${config}"
    printf 'set -g mouse on' >"${HOME}/.tmux.conf"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    printf '%s\n' "${CFGBK_BLOCK_BEGIN}" 'new managed content' \
        "${CFGBK_BLOCK_END}" >"${config}"
    printf 'font-size = 13\n\n\n' >>"${config}"

    run --separate-stderr cfgbk_report_user_content after-apply

    assert_success
    assert_output 'user-content after-apply: ghostty=intact tmux.conf=intact'
    assert_equal "${stderr}" ''
}

@test "#525: changing final-newline presence in either direction reports LOST" {
    local config="${XDG_CONFIG_HOME}/ghostty/config"
    printf 'font-size = 13\n' >"${config}"
    printf 'set -g mouse on' >"${HOME}/.tmux.conf"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    printf 'font-size = 13' >"${config}"
    printf 'set -g mouse on\n' >"${HOME}/.tmux.conf"

    run --separate-stderr cfgbk_report_user_content after-apply

    assert_failure 1
    assert_output 'user-content after-apply: ghostty=LOST tmux.conf=LOST'
    [[ "${stderr}" == *'font-size = 13\n'* ]]
    [[ "${stderr}" == *'font-size\ =\ 13'* ]]
    [[ "${stderr}" == *'set -g mouse on\n'* ]]
    [[ "${stderr}" == *'set\ -g\ mouse\ on'* ]]
}

@test "#525: appending a managed block to user content without a final newline remains intact" {
    # shellcheck source=lib/enter.sh
    source "${LIB_DIR}/enter.sh"
    local config="${XDG_CONFIG_HOME}/ghostty/config" path
    printf 'font-size = 13' >"${config}"
    printf 'set -g mouse on' >"${HOME}/.tmux.conf"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    for path in "${config}" "${HOME}/.tmux.conf"; do
        enter_block_compose "${path}" 'new managed content' >"${path}.new"
        mv "${path}.new" "${path}"
    done

    run --separate-stderr cfgbk_report_user_content after-apply

    assert_success
    assert_output 'user-content after-apply: ghostty=intact tmux.conf=intact'
    assert_equal "${stderr}" ''
}

@test "#525: composing a managed block before the last user line without a final newline remains intact" {
    # shellcheck source=lib/enter.sh
    source "${LIB_DIR}/enter.sh"
    local config="${XDG_CONFIG_HOME}/ghostty/config"
    printf 'A\n%s\nold\n%s\nB' "${CFGBK_BLOCK_BEGIN}" \
        "${CFGBK_BLOCK_END}" >"${config}"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    enter_block_compose "${config}" 'new managed content' >"${config}.new"
    mv "${config}.new" "${config}"

    run --separate-stderr cfgbk_report_user_content after-apply

    assert_success
    assert_output 'user-content after-apply: ghostty=intact tmux.conf=intact'
    assert_equal "${stderr}" ''
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

    run --separate-stderr "${as_user[@]}" "
        source \"\${LIB_DIR}/guard.sh\"
        source \"\${LIB_DIR}/config_backup.sh\"
        CFGBK_C=\"\${CFGBK_TEST_CONFIG}\"
        cfgbk_report_blocks
    "
    chmod 600 "${dir}/target"
    rm -rf "${dir}"

    assert_failure 1
    assert_output 'blocks=-1'
    [[ "${stderr}" == *"[FAIL] cannot read ${dir}/ghostty/config -- blocks= is not trustworthy"* ]]
}

@test "#523: a Ghostty target in an unsearchable directory fails the block report" {
    local dir
    dir="$(mktemp -d /tmp/cfgbk-unsearchable.XXXXXX)"
    chmod 755 "${dir}"
    mkdir "${dir}/ghostty" "${dir}/private"
    printf 'font-size = 12\n' >"${dir}/private/target"
    ln -s ../private/target "${dir}/ghostty/config"
    chmod 000 "${dir}/private"
    export CFGBK_UNSEARCHABLE_CONFIG="${dir}"
    local -a as_user=(bash -c)
    if [[ "$(id -u)" -eq 0 ]]; then as_user=(su nobody -s /bin/bash -c); fi

    run --separate-stderr "${as_user[@]}" "
        source \"\${LIB_DIR}/guard.sh\"
        source \"\${LIB_DIR}/config_backup.sh\"
        CFGBK_C=\"\${CFGBK_UNSEARCHABLE_CONFIG}\"
        cfgbk_report_blocks
    "
    chmod 755 "${dir}/private"
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

@test "#523: dangling Ghostty config with missing target directories reports zero blocks" {
    ln -s ../../dotfiles/ghostty/config "${XDG_CONFIG_HOME}/ghostty/config"

    run --separate-stderr cfgbk_report_blocks

    assert_success
    assert_output 'blocks=0'
    assert_equal "${stderr}" ''
}

@test "#523: dangling Ghostty config has intact empty user content after restore" {
    local config="${XDG_CONFIG_HOME}/ghostty/config"
    ln -s missing-config "${config}"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    rm "${config}"
    printf 'temporary config\n' >"${config}"
    cfgbk_restore_one ghostty

    run --separate-stderr cfgbk_report_user_content after-restore

    assert_success
    assert_output 'user-content after-restore: ghostty=intact tmux.conf=intact'
    assert_equal "${stderr}" ''
    assert [ -L "${config}" ]
    assert [ ! -e "${config}" ]
}

@test "#536: external XDG roots and direct parents are restored without touching ancestors" {
    export XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/opt/config"
    export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/var/cache"
    local BOX=dev
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
    mkdir -p "${XDG_CONFIG_HOME}/ghostty" "${XDG_CACHE_HOME}/worktool"
    printf 'original\n' >"${XDG_CONFIG_HOME}/ghostty/config"
    local dirs=("${XDG_CONFIG_HOME}" "${XDG_CONFIG_HOME}/ghostty"
        "${XDG_CACHE_HOME}" "${XDG_CACHE_HOME}/worktool")
    local dir path _mtime
    for dir in "${dirs[@]}"; do touch -d '2001-01-01' "${dir}"; done
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
    touch -d '2002-02-02' "${XDG_CONFIG_HOME%/*}" "${XDG_CACHE_HOME%/*}"
    run cfgbk_dirs_ok
    assert_success
    while IFS= read -r -d '' path; do
        IFS= read -r -d '' _mtime
        [[ "${path}" == "${XDG_CONFIG_HOME}" || "${path}" == "${XDG_CONFIG_HOME}/"* ||
            "${path}" == "${XDG_CACHE_HOME}" || "${path}" == "${XDG_CACHE_HOME}/"* ]]
    done <"${CFGBK_B}/directories"
    printf 'changed\n' >"${XDG_CONFIG_HOME}/ghostty/config"
    printf 'new log\n' >"${XDG_CACHE_HOME}/worktool/dev-init.log"
    for dir in "${dirs[@]}"; do touch -d '2003-03-03' "${dir}"; done
    cfgbk_restore_all
    assert [ ! -e "${XDG_CACHE_HOME}/worktool/dev-init.log" ]
    for dir in "${dirs[@]}"; do
        assert_equal "$(stat -c %y "${dir}")" '2001-01-01 00:00:00.000000000 +0000'
    done
    for dir in "${XDG_CONFIG_HOME%/*}" "${XDG_CACHE_HOME%/*}"; do
        assert_equal "$(stat -c %y "${dir}")" '2002-02-02 00:00:00.000000000 +0000'
    done
}
