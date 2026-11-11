#!/usr/bin/env bats

setup() {
    export COLD_HELPER="${BATS_TEST_DIRNAME}/../helper/cold_pty.bash"
    export COLD_READY="${BATS_TEST_TMPDIR}/ready"
    cat >"${BATS_TEST_TMPDIR}/supervisor.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
source "${COLD_HELPER}"
setsid timeout 30 script -qec 'sleep 30' /dev/null </dev/null >/dev/null 2>&1 &
child=$!
sid=
trap 'exit 1' HUP TERM
trap 'if [[ -n "${sid}" ]]; then _cold_pty_cleanup "${child}" "${sid}"; fi' EXIT
until sid="$(_cold_pty_session "${child}")"; do sleep 0.1; done
printf '%s %s\n' "${child}" "${sid}" >"${COLD_READY}"
if [[ "$1" == failure ]]; then exit 1; fi
while :; do sleep 0.1; done
SCRIPT
}

_check_cleanup() {
    local _mode="$1" _supervisor _launcher _sid _rc=0
    bash "${BATS_TEST_TMPDIR}/supervisor.sh" "${_mode}" &
    _supervisor=$!
    timeout 10 bash -c 'until [[ -s "$1" ]]; do sleep 0.05; done' _ "${COLD_READY}"
    read -r _launcher _sid <"${COLD_READY}"
    if [[ "${_mode}" != failure ]]; then kill -s "${_mode}" "${_supervisor}"; fi
    wait "${_supervisor}" || _rc=$?
    [[ "${_rc}" -ne 0 ]]
    ! kill -0 -- "-${_launcher}" 2>/dev/null
    ! ps -eo sid= | grep -qx "[[:space:]]*${_sid}"
}

@test "cold PTY cleanup after failure" { _check_cleanup failure; }
@test "cold PTY cleanup after HUP" { _check_cleanup HUP; }
@test "cold PTY cleanup after TERM" { _check_cleanup TERM; }
