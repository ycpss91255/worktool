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
trap '_cold_pty_cleanup "${child}" "${sid}"' EXIT
if [[ "$1" == early ]]; then
    printf '%s 0\n' "${child}" >"${COLD_READY}"
    while :; do sleep 0.1; done
fi
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
    local _deadline=$((SECONDS + 10))
    until [[ -s "${COLD_READY}" ]]; do
        (( SECONDS < _deadline )) || return 1
        sleep 0.05
    done
    read -r _launcher _sid <"${COLD_READY}"
    if [[ "${_mode}" == early ]]; then
        kill -s TERM "${_supervisor}"
    elif [[ "${_mode}" != failure ]]; then
        kill -s "${_mode}" "${_supervisor}"
    fi
    wait "${_supervisor}" || _rc=$?
    [[ "${_rc}" -ne 0 ]]
    ! kill -0 -- "-${_launcher}" 2>/dev/null
    local _sessions _session
    _sessions="$(ps -eo sid=)"
    if [[ "${_sid}" != 0 ]]; then
        while read -r _session; do [[ "${_session}" != "${_sid}" ]] || return 1; done <<<"${_sessions}"
    fi
}

@test "cold PTY cleanup after failure" { _check_cleanup failure; }
@test "cold PTY cleanup after HUP" { _check_cleanup HUP; }
@test "cold PTY cleanup after TERM" { _check_cleanup TERM; }

@test "cold PTY cleanup after early TERM" { _check_cleanup early; }

@test "session discovery rejects a child before it becomes a session leader" {
    source "${COLD_HELPER}"
    ps() { printf '%s\n' '10 1 10' '11 10 10' '12 11 10'; }
    if _cold_pty_session 10; then return 1; fi
}

@test "session discovery fails closed when ps fails" {
    source "${COLD_HELPER}"
    ps() { return 1; }
    local _rc=0
    _cold_pty_session 10 || _rc=$?
    [[ "${_rc}" -eq 2 ]]
}
