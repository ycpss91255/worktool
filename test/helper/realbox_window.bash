# Shared external-tool adapters for realbox window and documentation specs.
REALBOX_FAKED_TOOLS=(distrobox just gh jq loginctl)
REALBOX_SHIMMED_TOOLS=(mkdir grep cut wc sort sha256sum readlink tee mktemp id date uname cp mv rm awk)

_prepare_realbox_tools() {
    REALBOX="${REPO_ROOT}/script/verify/realbox.sh"
    STATE="${BATS_TEST_TMPDIR}/state"
    STUBS="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STATE}/real" "${STUBS}" "${BATS_TEST_TMPDIR}/tmp" \
        "${BATS_TEST_TMPDIR}/home/.config/ghostty"

    : >"${STATE}/boxes"
    : >"${STATE}/calls.log"
    : >"${STATE}/list-calls"

    local _t
    # Resolve the real tools BEFORE PATH changes; the shim execs these.
    for _t in just jq "${REALBOX_SHIMMED_TOOLS[@]}"; do
        command -v -- "${_t}" >"${STATE}/real/${_t}"
    done
    for _t in "${REALBOX_FAKED_TOOLS[@]}"; do
        install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${STUBS}/${_t}"
    done
    for _t in "${REALBOX_SHIMMED_TOOLS[@]}"; do
        install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_shim.sh" "${STUBS}/${_t}"
    done
    ln -s "$(type -P true)" "${STUBS}/ghostty"
    cp "$(type -P true)" "${STUBS}/gapplication"

    printf 'font-size = 12\n' >"${BATS_TEST_TMPDIR}/home/.config/ghostty/config"

    export FAKE_WORKTOOL_LIB_DIR="${REPO_ROOT}/lib"
    export FAKE_STATE_DIR="${STATE}"
    export HOME="${BATS_TEST_TMPDIR}/home"
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
    export XDG_SESSION_ID=graphical-test
    export XDG_RUNTIME_DIR="${STATE}/runtime" WAYLAND_DISPLAY=wayland-test
    unset DISPLAY
    mkdir -p "${XDG_RUNTIME_DIR}"
    node -e 'require("net").createServer().listen(process.argv[1], () => process.exit(0))' \
        "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
    PATH="${STUBS}:${PATH}"
    export PATH
}


_install_restore_window_tools() {
    [[ ! -f "${STATE}/restore-apply/ps" ]] || return 0
    mkdir -p "${STATE}/restore-apply"
    if [[ -f "${STUBS}/ps" ]]; then
        cp "${STUBS}/ps" "${STATE}/restore-apply/ps"
    else
        export REAL_WINDOW_PS
        REAL_WINDOW_PS="$(command -v ps)"
        cat >"${STATE}/restore-apply/ps" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exec "${REAL_WINDOW_PS}" "$@"
STUB
        chmod +x "${STATE}/restore-apply/ps"
    fi
    cp "${STUBS}/readlink" "${STATE}/restore-apply/readlink"
    cat >"${STUBS}/ps" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    '-p 4344 -o comm=') printf 'fish\n' ;;
    '-p 4344 -o ppid=,args=') printf '900 /usr/bin/fish\n' ;;
    '-p 900 -o ppid=,args=') printf '1 /usr/bin/ghostty\n' ;;
    *) exec "${FAKE_STATE_DIR}/restore-apply/ps" "$@" ;;
esac
STUB
    cat >"${STUBS}/readlink" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == /proc/4344/ns/mnt ]]; then
    exec "${FAKE_STATE_DIR}/restore-apply/readlink" /proc/self/ns/mnt
fi
exec "${FAKE_STATE_DIR}/restore-apply/readlink" "$@"
STUB
    chmod +x "${STUBS}/ps" "${STUBS}/readlink"
}


_fake_window_process() {
    cat >"${STUBS}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "exec ${FAKE_BOX_NAME:-dev} readlink /proc/self/ns/mnt" ]] || exit 2
printf '%s\n' "${FAKE_DEV_NS-mnt:[200]}"
exit "${FAKE_DEV_NS_RC:-0}"
STUB
    chmod +x "${STUBS}/docker"
    export DBX_CONTAINER_MANAGER=docker
    cat >"${STUBS}/ps" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == '-e -o pid=,comm=' ]]; then
    printf '%s\n' "${FAKE_WINDOW_BASELINE:-1 init}"
    exit "${FAKE_WINDOW_BASELINE_RC:-0}"
fi
printf '%s\n' "${FAKE_WINDOW_COMM:-fish}"
exit "${FAKE_WINDOW_PS_RC:-0}"
STUB
    mv "${STUBS}/readlink" "${STATE}/readlink"
    cat >"${STUBS}/readlink" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    /proc/self/ns/mnt) printf 'mnt:[100]\n' ;;
    /proc/4343/ns/mnt)
        printf '%s\n' "${FAKE_DEV_NS-mnt:[200]}"
        exit "${FAKE_DEV_NS_RC:-0}" ;;
    /proc/4242/ns/mnt)
        printf '%s\n' "${FAKE_WINDOW_NS-mnt:[200]}"
        exit "${FAKE_WINDOW_NS_RC:-0}" ;;
    *) exec "${FAKE_STATE_DIR}/readlink" "$@" ;;
esac
STUB
    chmod +x "${STUBS}/ps" "${STUBS}/readlink"
    export REALBOX
}


_auto_window_tools() {
    _fake_window_process
    _install_restore_window_tools
    _auto_window_ipc
}


_auto_window_ipc() {
    cp "${STUBS}/ps" "${STATE}/auto-ps"
    cp "${STUBS}/readlink" "${STATE}/auto-readlink"
    rm -f "${STUBS}/ghostty"
    : >"${STATE}/auto-ready"
    _auto_window_commands
    _auto_window_processes
}


_auto_window_commands() {
    cat >"${STUBS}/ghostty" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_STATE_DIR}/windows"
printf '%s\n' "${2#--working-directory=}" >"${FAKE_STATE_DIR}/window-directory"
[[ "$1" == +new-window && "$#" -eq 2 && "$2" == --working-directory=* ]] || exit 2
if [[ -f "${2#--working-directory=}/../processes-before-restore-window" || "${FAKE_AUTO_RESTORE:-0}" == 1 ]]; then
    printf restore >"${FAKE_STATE_DIR}/window-mode"
else
    printf apply >"${FAKE_STATE_DIR}/window-mode"
fi
STUB
    cat >"${STUBS}/gapplication" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_STATE_DIR}/reloads"
STUB
    cat >"${STUBS}/kill" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_STATE_DIR}/closed"
rm -f "${FAKE_STATE_DIR}/window-directory"
STUB
    chmod +x "${STUBS}/"{ghostty,gapplication,kill}
}


_auto_window_snapshot_stub() {
    cat >"${STATE}/auto-snapshot" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
        printf '1 0 init\n900 1 ghostty\n6000 1 conmon\n'
        if [[ -f "${FAKE_STATE_DIR}/window-directory" && "${FAKE_NO_WINDOW:-0}" == 0
            && -d "$(cat "${FAKE_STATE_DIR}/window-directory")" ]]; then
            printf '4240 900 distrobox\n5556 900 fish\n'
            if [[ $(cat "${FAKE_STATE_DIR}/window-mode") == apply ]]; then
                printf '4242 6000 %s\n' "${FAKE_WINDOW_COMM:-fish}"
            else
                parent="${FAKE_RESTORE_PARENT:-4240 fish}"
                printf '%s %s fish\n' "${FAKE_AUTO_RESTORE_PID:-4344}" "${parent%% *}"
                printf '800 4240 sh\n'
            fi
        fi
exit "${FAKE_WINDOW_BASELINE_RC:-0}"
STUB
}


_auto_window_processes() {
    _auto_window_snapshot_stub
    cat >"${STUBS}/ps" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    '-e -o pid=,ppid=,comm=') exec bash "${FAKE_STATE_DIR}/auto-snapshot" ;;
    '-e -o pid=,comm=')
        printf '%s\n' "${FAKE_WINDOW_BASELINE:-1 init}"
        if [[ -f "${FAKE_STATE_DIR}/window-directory" && "${FAKE_NO_WINDOW:-0}" == 0
            && -d "$(cat "${FAKE_STATE_DIR}/window-directory")" ]]; then
            printf '4240 distrobox\n5556 fish\n'
            if [[ $(cat "${FAKE_STATE_DIR}/window-mode") == apply ]]; then
                printf '4242 %s\n' "${FAKE_WINDOW_COMM:-fish}"
            else
                printf '%s fish\n' "${FAKE_AUTO_RESTORE_PID:-4344}"
            fi
        fi
        exit "${FAKE_WINDOW_BASELINE_RC:-0}" ;;
    '-p 900 -o comm=') printf 'ghostty\n' ;;
    '-p 4240 -o ppid=,args=') printf '900 /bin/sh\n' ;;
    '-p 4242 -o ppid=,args=')
        parent='6000 fish'
        if [[ $(cat "${FAKE_STATE_DIR}/window-mode") == restore ]]; then
            parent='4240 fish'
        fi
        printf '%s\n' "${FAKE_RESTORE_PARENT:-${FAKE_APPLY_PARENT:-${parent}}}" ;;
    '-p 6000 -o ppid=,args=') printf '1 conmon\n' ;;
    '-p 5556 -o ppid=,args=') printf '900 fish\n' ;;
    '-p 800 -o ppid=,args=') printf '4240 /repo/script/box/enter.sh\n' ;;
    '-p 4344 -o ppid=,args=') printf '4240 fish\n' ;;
    '-p 4240 -o pgid=,sid=') printf '4240 4240\n' ;;
    *) exec "${FAKE_STATE_DIR}/auto-ps" "$@" ;;
esac
STUB
    cat >"${STUBS}/readlink" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    /proc/4240/cwd) cat "${FAKE_STATE_DIR}/window-directory" ;;
    /proc/4242/cwd) printf '/run/host%s\n' "$(cat "${FAKE_STATE_DIR}/window-directory")" ;;
    /proc/5556/cwd) printf '/unrelated/window\n' ;;
    *) exec "${FAKE_STATE_DIR}/auto-readlink" "$@" ;;
esac
STUB
    chmod +x "${STUBS}/"{ps,readlink}
}

