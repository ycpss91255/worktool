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
