# Helpers for supervising the two sessions created by timeout and script.
_cold_pty_session() {
    local _launcher="$1" _pid _parent _sid _script=
    while read -r _pid _parent _sid; do
        if [[ "${_parent}" == "${_launcher}" ]]; then _script="${_pid}"; break; fi
    done < <(ps -eo pid=,ppid=,sid=)
    [[ -n "${_script}" ]] || return 1
    while read -r _pid _parent _sid; do
        if [[ "${_parent}" == "${_script}" ]]; then
            printf '%s\n' "${_sid}"
            return 0
        fi
    done < <(ps -eo pid=,ppid=,sid=)
    return 1
}

_cold_pty_cleanup() {
    local _launcher="$1" _sid="$2" _pid _member_sid _deadline=$((SECONDS + 5)) _alive
    # Leave script alive while its PTY child exits so it can reap the child.
    while :; do
        _alive=0
        while read -r _pid _member_sid; do
            [[ "${_member_sid}" == "${_sid}" ]] || continue
            _alive=1
            if kill -KILL "${_pid}" 2>/dev/null; then :; fi
        done < <(ps -eo pid=,sid=)
        if [[ "${_alive}" -eq 0 ]]; then break; fi
        if (( SECONDS >= _deadline )); then
            printf 'cold PTY session %s did not stop\n' "${_sid}" >&2
            return 1
        fi
        sleep 0.1
    done
    if kill -KILL -- "-${_launcher}" 2>/dev/null; then :; fi
    if wait "${_launcher}" 2>/dev/null; then :; fi
    if kill -0 -- "-${_launcher}" 2>/dev/null; then
        printf 'cold launcher group %s did not stop\n' "${_launcher}" >&2
        return 1
    fi
}
