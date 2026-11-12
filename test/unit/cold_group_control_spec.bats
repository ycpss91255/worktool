#!/usr/bin/env bats
load ../helper/common
setup() {
    source "${REPO_ROOT}/test/helper/cold_pty.bash"
    export PROBE_MARK="${BATS_TEST_TMPDIR}/probe" STOP_MARK="${BATS_TEST_TMPDIR}/stopped"
    # Bash job control puts both pipeline children in one process group,
    # while this test shell remains their parent and can reap both.
    set -m
    sleep 30 | { cat >/dev/null; exec sleep 30; } 2>/dev/null &
    child=$!
    set +m
    local deadline=$((SECONDS + 3)) row state pgid
    while :; do
        if [[ -r "/proc/${child}/stat" ]]; then
            read -r row <"/proc/${child}/stat"
            read -r state _ pgid _ _ <<<"${row##*) }"
            if [[ "${pgid}" =~ ^[1-9][0-9]*$ && "${pgid}" != "${BASHPID}" && "${state}" != Z ]]; then
                launcher="${pgid}"
                break
            fi
        fi
        (( SECONDS < deadline )) || return 1
        sleep 0.02
    done
}
teardown() {
    builtin kill -KILL -- "-${launcher}" 2>/dev/null || :
    wait "${launcher}" 2>/dev/null || :
}
_record_probe() {
    [[ ! -e "${PROBE_MARK}" ]] || return 0
    local row state pgid
    [[ -r "/proc/${child}/stat" ]] || return 1
    read -r row <"/proc/${child}/stat"
    read -r state _ pgid _ _ <<<"${row##*) }"
    [[ "${pgid}" == "${launcher}" && "${state}" != Z ]] || return 1
    printf '%s %s %s\n' "${child}" "${pgid}" "${state}" >"${PROBE_MARK}"
}
kill() {
    if [[ "$1" == -KILL && "${2:-}" == -- && "$3" == "-${launcher}" ]]; then
        builtin kill -KILL "${launcher}" 2>/dev/null || :
        return 0
    fi
    if [[ "$1" == -0 && "${2:-}" == -- && "$3" == "-${launcher}" ]]; then
        _record_probe || return 2
    fi
    builtin kill "$@"
}
_install_group_probe() {
    if declare -F _cold_pty_group_present >/dev/null; then
        eval "$(declare -f _cold_pty_group_present | sed '1s/_cold_pty_group_present/_real_group_probe/')"
        # The helper calls this override indirectly.
        eval '_cold_pty_group_present() { _record_probe || return 2; _real_group_probe "$@"; }'
    fi
}
@test "cleanup waits for a verified live group member to stop" {
    _install_group_probe
    (
        deadline=$((SECONDS + 3))
        while [[ ! -s "${PROBE_MARK}" ]]; do (( SECONDS < deadline )) || exit 1; sleep 0.02; done
        sleep 0.3
        builtin kill -KILL "${child}" 2>/dev/null || exit 1
        deadline=$((SECONDS + 3))
        while builtin kill -0 -- "-${launcher}" 2>/dev/null; do (( SECONDS < deadline )) || exit 1; sleep 0.02; done
        : >"${STOP_MARK}"
    ) >/dev/null 2>&1 &
    local helper=$!
    run _cold_pty_cleanup "${launcher}" ''
    local result="${status}"
    printf '# delayed status=%s output=%q\n' "${status}" "${output}" >&3
    wait "${helper}"
    [[ -s "${PROBE_MARK}" && -e "${STOP_MARK}" ]]
    [[ "${result}" -eq 0 ]]
}
@test "cleanup refuses a verified group member that stays alive" {
    _install_group_probe
    run _cold_pty_cleanup "${launcher}" ''
    printf '# persistent status=%s output=%q\n' "${status}" "${output}" >&3
    [[ -s "${PROBE_MARK}" ]]
    [[ "${status}" -ne 0 ]]
}
@test "cleanup refuses an indeterminate group listing" {
    eval '_cold_pty_group_present() { return 2; }'
    run _cold_pty_cleanup "${launcher}" ''
    printf '# unknown status=%s output=%q\n' "${status}" "${output}" >&3
    [[ "${status}" -ne 0 ]]
}

@test "group observation fails closed on failed, malformed and stalled listings" {
    local bin="${BATS_TEST_TMPDIR}/ps-bin" mode started
    mkdir -p "${bin}"
    cat >"${bin}/ps" <<'STUB'
#!/usr/bin/env bash
case "${PS_MODE}" in
    failed) exit 1 ;;
    malformed) printf 'malformed\n' ;;
    stalled) exec sleep 30 ;;
esac
STUB
    chmod +x "${bin}/ps"
    for mode in failed malformed stalled; do
        started="${SECONDS}"
        PATH="${bin}:${PATH}" PS_MODE="${mode}" run _cold_pty_group_present "${launcher}" 1
        [[ "${status}" -eq 2 ]]
        (( SECONDS - started < 5 ))
    done
}

@test "cleanup refuses an absent result observed after the deadline" {
    eval '_cold_pty_group_present() { SECONDS=999999; return 1; }'
    run _cold_pty_cleanup "${launcher}" ''
    [[ "${status}" -ne 0 ]]
    [[ "${output}" == *'did not stop before deadline'* ]]
}
