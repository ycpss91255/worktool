# Helpers for supervising the two sessions created by timeout and script.
_cold_pty_session() {
    local _launcher="$1" _pid _parent _sid _script='' _snapshot
    _snapshot="$(ps -eo pid=,ppid=,sid=)" || return 2
    while read -r _pid _parent _sid; do
        if [[ "${_parent}" == "${_launcher}" ]]; then _script="${_pid}"; break; fi
    done <<<"${_snapshot}"
    [[ -n "${_script}" ]] || return 1
    while read -r _pid _parent _sid; do
        if [[ "${_parent}" == "${_script}" && "${_pid}" == "${_sid}" ]]; then
            printf '%s\n' "${_sid}"
            return 0
        fi
    done <<<"${_snapshot}"
    return 1
}

_cold_pty_cleanup() {
    local _launcher="$1" _sid="$2" _pid _parent _member_sid _snapshot _state _alive
    local _deadline=$((SECONDS + 5)) _script='' _error=0
    _snapshot="$(ps -eo pid=,ppid=,sid=)" || {
        printf 'cannot inspect cold PTY processes\n' >&2
        _snapshot=''
        _error=1
    }
    while read -r _pid _parent _member_sid; do
        if [[ "${_parent}" == "${_launcher}" ]]; then _script="${_pid}"; break; fi
    done <<<"${_snapshot}"
    if [[ -n "${_script}" ]]; then
        while read -r _pid _parent _member_sid; do
            [[ "${_parent}" == "${_script}" ]] || continue
            if [[ "${_pid}" == "${_member_sid}" ]]; then _sid="${_member_sid}"; fi
            if kill -KILL "${_pid}" 2>/dev/null; then :; fi
        done <<<"${_snapshot}"
    fi
    while [[ -n "${_sid}" ]]; do
        _snapshot="$(ps -eo pid=,sid=)" || {
            printf 'cannot inspect cold PTY session\n' >&2
            _error=1
            break
        }
        _alive=0
        while read -r _pid _member_sid; do
            [[ "${_member_sid}" == "${_sid}" ]] || continue
            _alive=1
            if kill -KILL "${_pid}" 2>/dev/null; then :; fi
        done <<<"${_snapshot}"
        [[ "${_alive}" -ne 0 ]] || break
        if (( SECONDS >= _deadline )); then
            printf 'cold PTY session %s did not stop\n' "${_sid}" >&2
            return 1
        fi
        sleep 0.1
    done
    if [[ "${_error}" -ne 0 && -n "${_sid}" ]]; then
        if kill -KILL -- "-${_sid}" 2>/dev/null; then :; fi
    fi
    if kill -KILL -- "-${_launcher}" 2>/dev/null; then :; fi
    while kill -0 "${_launcher}" 2>/dev/null; do
        if [[ -r "/proc/${_launcher}/stat" ]]; then
            read -r _pid _state _state _ <"/proc/${_launcher}/stat"
            [[ "${_state}" != Z ]] || break
        fi
        if (( SECONDS >= _deadline )); then
            printf 'cold launcher %s did not stop\n' "${_launcher}" >&2
            return 1
        fi
        sleep 0.1
    done
    if wait "${_launcher}" 2>/dev/null; then :; fi
    if kill -0 -- "-${_launcher}" 2>/dev/null; then
        printf 'cold launcher group %s did not stop\n' "${_launcher}" >&2
        return 1
    fi
    return "${_error}"
}
