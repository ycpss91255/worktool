#!/usr/bin/env bash
# Event-driven supervisor for the real-machine 5.1 interrupt matrix.
_54_W=""
_54_PID=""
_54_REAP_RESULT=""
_54_POLL_FD=""

_54_cleanup() {
    local rc=0 failed=0
    local _54_IN_CLEANUP=1
    if [[ -n "${_54_PID}" ]]; then
        if ! kill -TERM -- "-${_54_PID}" 2>/dev/null; then :; fi
        # Terminating the owned child normally yields a signal exit status.
        # Cleanup judges surviving processes, not the interrupted child's verdict.
        _54_reap cleanup || rc=$?
        [[ "${rc}" -ne 124 ]] || failed=1
        if [[ "${rc}" -ne 0 && "${rc}" -ne 124 ]]; then
            log_info "interrupt cleanup: stopped child rc=${rc} (expected after termination)"
        fi
        _54_stop_session "${_54_PID}" || failed=1
        _54_PID=""
    fi
    if [[ -n "${_54_POLL_FD}" ]]; then exec {_54_POLL_FD}>&-; fi
    if [[ -n "${_54_W}" ]]; then
        rm -rf -- "${_54_W}" || failed=1
    fi
    return "${failed}"
}

# timeout gives commands their own groups within the child's private session.
# A forwarding regression must fail even if the outer shell cleaned its box.
_54_session_groups() {
    local file row status _parent group session rest
    for file in /proc/[0-9]*/stat; do
        if ! IFS= read -r row 2>/dev/null <"${file}"; then continue; fi
        read -r status _parent group session rest <<<"${row##*) }"
        if [[ "${session}" == "$1" && "${status}" != Z && "${status}" != X ]]; then
            printf '%s\n' "${group}"
        fi
    done
}

_54_session_clear() {
    local groups
    groups="$(_54_session_groups "$1")" || return 1
    [[ -z "${groups}" ]]
}

_54_stop_session() {
    local group rc=0
    # Avoid command substitution in EXIT cleanup after an interrupted read.
    _54_session_groups "$1" >"${_54_W}/groups" || return 1
    while IFS= read -r group; do
        [[ -n "${group}" && "${group}" != "$1" ]] || continue
        verify_stop_group "${group}" TERM || rc=1
    done <"${_54_W}/groups"
    verify_stop_group "$1" TERM || rc=1
    return "${rc}"
}

_54_comments() {
    guard_timed "${TIMEOUT_SHORT}" gh issue view "${ISSUE}" --repo "${REPO}" \
        --json comments --jq '[.comments[].id] | sort' >"$1"
}

# A private FIFO provides a bounded observation wait without loading the CPU
# (bench itself waits for a quiet host). Only observed events select a signal.
_54_poll() {
    local line rc=0
    read -r -t 0.05 -u "${_54_POLL_FD}" line || rc=$?
    [[ "${rc}" -eq 0 || "${rc}" -gt 128 ]]
}

# A deadline limits observation; elapsed time alone never triggers a signal.
_54_event() {
    local phase="$1" capture="$2" deadline=$((SECONDS + TIMEOUT_LONG)) rc
    while ((SECONDS < deadline)); do
        kill -0 "${_54_PID}" 2>/dev/null || return 1
        if [[ "${phase}" == assemble ]]; then
            if grep -qFx 'phase=bench' "${capture}"; then return 1; fi
            rc=0
            guard_box_exists "${BOX}" "${TIMEOUT_SHORT}" || rc=$?
            [[ "${rc}" -ne 2 ]] || return 1
            # The box query can outlive assemble; never use its stale phase.
            if grep -qFx 'phase=bench' "${capture}"; then return 1; fi
            [[ "${rc}" -ne 0 ]] || return 0
        else
            rc=0
            grep -qE '^\[INFO\] (psi before enter run |enter: .* done$)' "${capture}" || rc=$?
            [[ "${rc}" -le 1 ]] || return 1
            [[ "${rc}" -ne 0 ]] || return 0
        fi
        _54_poll || return 1
    done
    return 1
}

_54_assert() {
    local capture="$1" dir="$2" rc="$3" expected="$4" check gone=0
    [[ "${rc}" -eq "${expected}" ]] || return 1
    for check in 'cleanup-rc=0' 'box-state after-cleanup: home=0 tmux=0' \
        'host-state after-cleanup: new=0'; do
        grep -qFx "${check}" "${capture}" || return 1
    done
    # Do not accept a success line followed by a failed cleanup report.
    if grep -qE '^cleanup-rc=[1-9]|^posted=' "${capture}"; then return 1; fi
    guard_box_exists "${BOX}" "${TIMEOUT_SHORT}" || gone=$?
    [[ "${gone}" -eq 1 ]] || return 1
    local -a homes=("${dir}"/wt-m3-51.*)
    for check in "${homes[@]}"; do
        [[ ! -e "${check}" && ! -L "${check}" ]] || return 1
    done
    _54_comments "${dir}/comments-after" || return 1
    cmp -s "${dir}/comments-before" "${dir}/comments-after"
}

_54_wait() {
    local deadline=$((SECONDS + TIMEOUT_SHORT))
    while kill -0 "${_54_PID}" 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            guard_fail "interrupt response deadline exceeded; stopping owned session"
            _54_stop_session "${_54_PID}"
            return 1
        fi
        _54_poll || return 1
    done
}

_54_failure_report() {
    local phase="$1" signal="$2" rc="$3" dir="$4" line cleanup=missing
    while IFS= read -r line; do
        case "${line}" in cleanup-rc=*) cleanup="${line#cleanup-rc=}" ;; esac
    done <"${dir}/capture"
    cat "${dir}/capture" >&2
    printf 'interrupt %s %s: FAIL (rc=%s; cleanup-rc=%s; evidence=%s)\n' \
        "${phase}" "${signal}" "${rc}" "${cleanup}" "${dir}"
}

_54_prestart_failure() {
    printf 'interrupt %s %s: FAIL (%s)\n' "$1" "$2" "$3"
    return 1
}

_54_prepare() {
    local phase="$1" signal="$2" dir="$3" capture="$3/capture"
    mkdir -p -- "${dir}" || {
        _54_prestart_failure "${phase}" "${signal}" 'cannot create cell evidence directory'
        return 1
    }
    _refuse_preexisting_box 'Interrupt matrix will not touch an existing box.' || {
        _54_prestart_failure "${phase}" "${signal}" 'preexisting box refused or box query failed'
        return 1
    }
    _54_comments "${dir}/comments-before" || {
        _54_prestart_failure "${phase}" "${signal}" 'cannot snapshot issue comments'
        return 1
    }
    # Prepare evidence before forking so the observer always has a capture.
    : >"${capture}" || {
        guard_fail 'cannot create interrupt capture'
        _54_prestart_failure "${phase}" "${signal}" 'cannot create interrupt capture'
        return 1
    }
}

_54_now_ms() {
    local stamp="${EPOCHREALTIME/,/.}"
    printf '%s\n' "$((10#${stamp%.*} * 1000 + 10#${stamp#*.} / 1000))"
}

_54_record_wait() {
    local child_rc=0
    [[ -n "${_54_REAP_RESULT}" ]] || _54_REAP_RESULT=0
    wait "${_54_PID}" || child_rc=$?
    if [[ "${_54_REAP_RESULT}" -eq 124 ]]; then
        log_info "interrupt $1: killed child rc=${child_rc}"
    else
        _54_REAP_RESULT="${child_rc}"
    fi
}

# EXIT cleanup already ignores signals; keep its trap state untouched.
_54_collect_status() {
    if [[ "${_54_IN_CLEANUP:-0}" == 1 ]]; then
        _54_record_wait "$1"
        return
    fi
    local saved="" line interrupted=""
    trap -p INT TERM HUP >"${_54_W}/signals" || return 1
    while IFS= read -r line; do saved+="${line}"$'\n'; done <"${_54_W}/signals"
    trap 'interrupted=INT' INT
    trap 'interrupted=TERM' TERM
    trap 'interrupted=HUP' HUP
    # The child has exited. Defer signal exits until its wait is recorded.
    _54_record_wait "$1"
    eval "${saved}"
    if [[ -n "${interrupted}" ]]; then
        kill -s "${interrupted}" "${BASHPID}"
    fi
}

# Only reap after observing exit: wait itself has no timeout option.
_54_reap() {
    local context="$1" deadline=$((SECONDS + TIMEOUT_SHORT))
    [[ -z "${_54_REAP_RESULT}" ]] || return "${_54_REAP_RESULT}"
    while kill -0 "${_54_PID}" 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            _54_REAP_RESULT=124
            guard_fail "interrupt ${context}: child reap wait deadline exceeded (pid=${_54_PID})"
            verify_stop_group "${_54_PID}" KILL || return 124
            if ! kill -0 "${_54_PID}" 2>/dev/null; then
                _54_collect_status "${context}" || return 124
            fi
            return 124
        fi
        sleep 0.05
    done
    _54_collect_status "${context}" || return 1
    return "${_54_REAP_RESULT}"
}

_54_signal() {
    local phase="$1" signal="$2" capture="$3" started="$4" signalled rc=0 observed="$1"
    signalled="$(_54_now_ms)" || return 1
    if [[ "${phase}" == assemble ]]; then
        grep -qFx 'phase=bench' "${capture}" || rc=$?
        if [[ "${rc}" -ne 1 ]]; then
            guard_fail "interrupt ${phase} ${signal}: assemble phase no longer confirmed; retry the cell"
            if ! kill -TERM -- "-${_54_PID}" 2>/dev/null; then :; fi
            return 1
        fi
    fi
    kill -s "${signal}" -- "-${_54_PID}" || return 1
    if [[ "${phase}" == assemble ]]; then
        rc=0
        grep -qFx 'phase=bench' "${capture}" || rc=$?
        if [[ "${rc}" -ne 1 ]]; then
            observed=unknown
            guard_fail "interrupt ${phase} ${signal}: phase crossed or became unreadable at signal delivery; retry the cell"
        fi
    fi
    printf 'interrupt %s %s: signal-phase=%s signal-after-ms=%s\n' \
        "${phase}" "${signal}" "${observed}" "$((signalled - started))"
    [[ "${observed}" == "${phase}" ]]
}

_54_finish_cell() {
    local phase="$1" signal="$2" dir="$3" child_rc="$4" expected="$5" rc="$6" missed="$7"
    local inconclusive=0
    if [[ "${phase}" == bench && "${child_rc}" -eq 3 ]]; then
        expected=3
        inconclusive=1
    elif [[ "${missed}" -eq 1 ]]; then
        guard_fail "interrupt ${phase} ${signal}: observable event missed"
        rc=1
    fi
    _54_assert "${dir}/capture" "${dir}" "${child_rc}" "${expected}" || rc=1
    _54_session_clear "${_54_PID}" || rc=1
    if [[ "${rc}" -ne 0 ]]; then
        _54_stop_session "${_54_PID}"
        _54_PID=""
        _54_failure_report "${phase}" "${signal}" "${child_rc}" "${dir}"
        return 1
    fi
    _54_PID=""
    if [[ "${inconclusive}" -eq 1 ]]; then
        cat "${dir}/capture" >&2
        printf 'interrupt %s %s: INCONCLUSIVE (rc=3; cleanup-rc=0; host too busy, re-run when idle)\n' \
            "${phase}" "${signal}"
        return 3
    fi
    printf 'interrupt %s %s: rc=%s cleanup-rc=0 box-gone=1 home=0 tmux=0 host-new=0 posted=0 PASS\n' \
        "${phase}" "${signal}" "${child_rc}"
}

_54_cell() {
    local phase="$1" signal="$2" expected="$3" dir capture rc=0 missed=0
    dir="${_54_W}/${phase}-${signal}"
    capture="${dir}/capture"
    _54_prepare "${phase}" "${signal}" "${dir}" || return 1
    local -a comment_args=()
    [[ -z "${COMMENT_TAG}" ]] || comment_args=(--comment-tag "${COMMENT_TAG}")
    local started
    started="$(_54_now_ms)"
    _54_REAP_RESULT=""
    TMPDIR="${dir}" setsid env --default-signal=INT,TERM,HUP \
        bash "${SCRIPT_DIR}/realbox.sh" --allow-real-box --repo "${REPO}" \
        --issue "${ISSUE}" --box "${BOX}" "${comment_args[@]}" 5.1 >>"${capture}" 2>&1 &
    _54_PID=$!
    if _54_event "${phase}" "${capture}"; then
        _54_signal "${phase}" "${signal}" "${capture}" "${started}" || rc=1
    else
        missed=1
        if ! kill -TERM -- "-${_54_PID}" 2>/dev/null; then :; fi
    fi
    local child_rc=0
    _54_wait || rc=1
    _54_reap "${phase} ${signal}" || child_rc=$?
    [[ "${child_rc}" -ne 124 ]] || rc=1
    _54_finish_cell "${phase}" "${signal}" "${dir}" "${child_rc}" "${expected}" "${rc}" "${missed}"
}

item_54() {
    guard_require setsid env bash distrobox just gh grep cmp mktemp mkdir rm mkfifo || return $?
    _54_W="$(mktemp -d "${TMPDIR:-/tmp}/wt-m3-54.XXXXXXXX")" || return 1
    _cleanup_push 54
    mkfifo "${_54_W}/poll" || return 1
    exec {_54_POLL_FD}<>"${_54_W}/poll"
    local phase signal expected rc=0 cell_rc
    for phase in assemble bench; do
        for signal in INT TERM HUP; do
            case "${signal}" in INT) expected=130 ;; TERM) expected=143 ;; HUP) expected=129 ;; esac
            cell_rc=0
            _54_cell "${phase}" "${signal}" "${expected}" || cell_rc=$?
            case "${cell_rc}" in
                0) ;;
                3) rc=3 ;;
                *) rc=1; break 2 ;;
            esac
        done
    done
    if [[ "${rc}" -ne 1 ]]; then
        _cleanup_pop_run || return 1
        if [[ "${rc}" -eq 0 ]]; then
            printf 'interrupt-matrix: PASS (6/6)\n'
        else
            printf 'interrupt-matrix: INCONCLUSIVE (host too busy, re-run when idle)\n'
        fi
    else
        # Keep failed evidence and any surviving owned HOME for inspection.
        _cleanup_drop
        printf 'interrupt-matrix: FAIL\n'
    fi
    return "${rc}"
}
