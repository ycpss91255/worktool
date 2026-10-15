#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    bats_require_minimum_version 1.5.0
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config"
    export TMPDIR="${BATS_TEST_TMPDIR}" BOX=dev
    mkdir -p "${XDG_CONFIG_HOME}/ghostty" "${HOME}/.cache/worktool"
    # shellcheck source=lib/guard.sh
    source "${LIB_DIR}/guard.sh"
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    cfgbk_paths
}

@test "#588: restore removes an init-log target created through an originally dangling link" {
    local log target
    log="$(cfgbk_file_of init-log)"
    target="${HOME}/.cache/new init log"
    ln -s '../new init log' "${log}"
    cfgbk_preflight
    cfgbk_dir_create
    cfgbk_backup_body
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
    local log target removal_rc
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

@test "#588: backup refuses an indeterminate dangling init-log target path" {
    local log
    log="$(cfgbk_file_of init-log)"
    ln -s missing-init-log "${log}"
    cfgbk_dir_create
    # A resolver that succeeds without a path has not proved absence.
    export CFGBK_TEST_LOG="${log}" CFGBK_REAL_READLINK
    CFGBK_REAL_READLINK="$(type -P readlink)"
    mkdir "${BATS_TEST_TMPDIR}/bin"
    cat >"${BATS_TEST_TMPDIR}/bin/readlink" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -m && "${*: -1}" == "${CFGBK_TEST_LOG}" ]]; then exit 0; fi
exec "${CFGBK_REAL_READLINK}" "$@"
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/readlink"
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

    run cfgbk_backup_body

    assert_failure 1
    assert [ ! -e "${CFGBK_B}/manifest" ]
    assert [ -L "${log}" ]
}

