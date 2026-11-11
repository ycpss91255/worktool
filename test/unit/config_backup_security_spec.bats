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

@test "an existing backup directory is never overwritten" {
    mkdir "${CFGBK_B}"
    printf 'keep\n' >"${CFGBK_B}/sentinel"
    run --separate-stderr cfgbk_dir_create
    assert_failure 1
    assert_output "backup=${CFGBK_B} ok=0"
    assert_equal "$(cat "${CFGBK_B}/sentinel")" keep
    assert [ ! -e "${CFGBK_B}/manifest" ]
    assert_equal "$(cat "${XDG_CONFIG_HOME}/ghostty/config")" original
}

@test "failed manifest publication leaves no published manifest" {
    cfgbk_dir_create
    mkdir "${BATS_TEST_TMPDIR}/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/mv"
    chmod +x "${BATS_TEST_TMPDIR}/bin/mv"
    run --separate-stderr env PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" bash -c "source \"${LIB_DIR}/guard.sh\"; source \"${LIB_DIR}/config_backup.sh\"; cfgbk_paths; cfgbk_backup_body"
    assert_failure 1
    [[ "${stderr:-}" == *'publishing the manifest failed'* ]]
    assert [ ! -e "${CFGBK_B}/manifest" ]
    assert [ -f "${CFGBK_B}/manifest.partial" ]
    run cfgbk_revalidate
    assert_failure 1
    assert_equal "$(cat "${XDG_CONFIG_HOME}/ghostty/config")" original
}

@test "revalidation rejects a missing or partially published manifest" {
    cfgbk_dir_create
    run --separate-stderr cfgbk_revalidate
    assert_failure 1
    [[ "${stderr:-}" == *'no published manifest'* ]]
    cfgbk_backup_body
    : >"${CFGBK_B}/manifest.partial"
    run --separate-stderr cfgbk_revalidate
    assert_failure 1
    [[ "${stderr:-}" == *'still present'* ]]
    assert_equal "$(cat "${XDG_CONFIG_HOME}/ghostty/config")" original
}

@test "revalidation rejects backup checksum mismatch" {
    _prepare_backup
    printf 'tampered\n' >"${CFGBK_B}/ghostty.config"
    run --separate-stderr cfgbk_revalidate
    assert_failure 1
    [[ "${stderr:-}" == *'backup does not match its manifest checksum'* ]]
    assert_equal "$(cat "${XDG_CONFIG_HOME}/ghostty/config")" original
}

@test "revalidation rejects duplicate or invalid manifest states" {
    _prepare_backup
    printf 'ghostty=regular\n' >>"${CFGBK_B}/manifest"
    run --separate-stderr cfgbk_revalidate
    assert_failure 1
    [[ "${stderr:-}" == *'manifest does not have exactly one state line'* ]]
    sed -i '/^ghostty=/d' "${CFGBK_B}/manifest"
    printf 'ghostty=unexpected\n' >>"${CFGBK_B}/manifest"
    run --separate-stderr cfgbk_revalidate
    assert_failure 1
    [[ "${stderr:-}" == *'manifest does not have exactly one state line'* ]]
    assert_equal "$(cat "${XDG_CONFIG_HOME}/ghostty/config")" original
}

@test "revalidation preserves a live config changed after backup" {
    _prepare_backup
    printf 'user changed this\n' >"${XDG_CONFIG_HOME}/ghostty/config"
    run --separate-stderr cfgbk_revalidate
    assert_failure 1
    [[ "${stderr:-}" == *'live config changed since step 1'* ]]
    assert_equal "$(cat "${XDG_CONFIG_HOME}/ghostty/config")" 'user changed this'
    assert [ -f "${CFGBK_B}/manifest" ]
}

@test "backup paths honor custom roots and default values" {
    export XDG_CONFIG_HOME="${HOME}/config root" TMPDIR="${BATS_TEST_TMPDIR}/temporary"
    cfgbk_paths
    assert_equal "${CFGBK_H}" "${HOME}"
    assert_equal "${CFGBK_C}" "${XDG_CONFIG_HOME}"
    assert_equal "${CFGBK_B}" "${TMPDIR}/worktool-m3-52-backup.$(id -u)"
    unset XDG_CONFIG_HOME TMPDIR
    cfgbk_paths
    assert_equal "${CFGBK_C}" "${HOME}/.config"
    assert_equal "${CFGBK_B}" "/tmp/worktool-m3-52-backup.$(id -u)"
}

@test "backup paths reject missing HOME and failed or invalid uid" {
    run env -u HOME bash -c "source \"${LIB_DIR}/guard.sh\"; source \"${LIB_DIR}/config_backup.sh\"; cfgbk_paths"
    assert_failure 1
    mkdir "${BATS_TEST_TMPDIR}/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/id"
    chmod +x "${BATS_TEST_TMPDIR}/bin/id"
    run env PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" bash -c "source \"${LIB_DIR}/guard.sh\"; source \"${LIB_DIR}/config_backup.sh\"; cfgbk_paths"
    assert_failure 1
    printf '#!/usr/bin/env bash\nprintf invalid\\n\n' >"${BATS_TEST_TMPDIR}/bin/id"
    run env PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" bash -c "source \"${LIB_DIR}/guard.sh\"; source \"${LIB_DIR}/config_backup.sh\"; cfgbk_paths"
    assert_failure 1
}
