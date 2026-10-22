#!/usr/bin/env bash
# Run an acceptance command with a bounded process group. Preserve command
# status, including 137; only an actual deadline is normalized to 124.
verify_run() {
    local budget="$1" rc=0 monitor state run_id="" interrupted=""
    local saved_int saved_term saved_hup
    saved_int="$(trap -p INT)"
    saved_term="$(trap -p TERM)"
    saved_hup="$(trap -p HUP)"
    shift
    state="$(mktemp -d "${VERIFY_RUN_GUARD_DIR:-${TMPDIR:-/tmp}}/verify-run.XXXXXXXX")" || return 1
    if [[ "$1" == just && "${2:-}" == test ]]; then
        run_id="${state##*/}"
    fi
    trap 'interrupted=INT' INT
    trap 'interrupted=TERM' TERM
    trap 'interrupted=HUP' HUP
    WORKTOOL_TEST_RUN_ID="${run_id}" state="${state}" timeout -k 1 "${budget}" bash -c "
        mark_deadline() { touch \"\${state}/deadline\"; }
        trap mark_deadline TERM
        trap ':' INT HUP
        # Background jobs inherit ignored INT; restore command signal defaults.
        env --default-signal=INT,TERM,HUP \"\$@\" &
        child=\$!
        wait \"\${child}\"
    " _ "$@" &
    monitor=$!
    wait "${monitor}" || rc=$?
    if [[ -n "${interrupted}" ]]; then
        trap '' INT TERM HUP
        if ! verify_interrupt_group "${monitor}" "${interrupted}"; then
            if ! verify_group_running "${monitor}"; then wait "${monitor}" || rc=$?; fi
            verify_restore_signals "" "${saved_int}" "${saved_term}" "${saved_hup}"
            return 1
        fi
        wait "${monitor}" || rc=$?
    fi
    if [[ -n "${interrupted}" || "${rc}" -eq 124 || -e "${state}/deadline" ]]; then
        if [[ -z "${interrupted}" ]] && ! verify_kill_group "${monitor}"; then
            log_error "verify_run: group stop unconfirmed (pgid=${monitor}); configuration restore refused; inspect retained verification state before recovery"
            verify_restore_signals "" "${saved_int}" "${saved_term}" "${saved_hup}"
            return 1
        fi
        if [[ -n "${run_id}" ]]; then
            verify_cleanup_containers "${run_id}" || rc=$?
        fi
        [[ -n "${interrupted}" ]] || rc=124
    fi
    rm -rf "${state}"
    verify_restore_signals "${interrupted}" "${saved_int}" "${saved_term}" "${saved_hup}" || rc=$?
    return "${rc}"
}

# Treat a failed stop as unsafe even if the emergency KILL succeeds.
verify_interrupt_group() {
    local monitor="$1" signal="$2" rc=0
    verify_stop_group "${monitor}" "${signal}" || rc=1
    if [[ "${rc}" -ne 0 ]] || verify_group_running "${monitor}"; then
        log_error "verify_run: group stop unconfirmed (pgid=${monitor}); configuration restore refused; inspect retained verification state before recovery"
        verify_kill_group "${monitor}" || rc=1
        return 1
    fi
}

# Subshell supervisors retain their state directory on an unsafe interruption.
# The owning realbox shell must check this before any configuration restore.
verify_restore_allowed() {
    [[ -n "${VERIFY_RUN_GUARD_DIR:-}" ]] || return 0
    local pending=("${VERIFY_RUN_GUARD_DIR}"/verify-run.*)
    if [[ -e "${pending[0]}" ]]; then
        log_error "configuration restore refused: unconfirmed verification stop; inspect ${VERIFY_RUN_GUARD_DIR} and stop surviving processes before manual recovery"
        return 1
    fi
}

verify_restore_signals() {
    local interrupted="$1"
    trap - INT TERM HUP
    eval "$2"
    eval "$3"
    eval "$4"
    if [[ -n "${interrupted}" ]]; then
        kill -s "${interrupted}" "${BASHPID}"
        case "${interrupted}" in INT) return 130 ;; TERM) return 143 ;; HUP) return 129 ;; esac
    fi
}

# timeout owns this group; its leader may exit before its descendants do.
verify_stop_group() {
    local monitor="$1" signal="$2" attempt
    if ! kill -s "${signal}" -- "-${monitor}" 2>/dev/null; then
        return 0
    fi
    for ((attempt=0; attempt<20; attempt++)); do
        if ! kill -0 -- "-${monitor}" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    verify_kill_group "${monitor}"
}

verify_kill_group() {
    local monitor="$1"
    if ! kill -KILL -- "-${monitor}" 2>/dev/null; then
        : # Confirm disappearance below even when signalling fails.
    fi
    local deadline=$((SECONDS + 1))
    while verify_group_running "${monitor}"; do
        if ((SECONDS >= deadline)); then
            log_error "verify_stop_group: post-KILL wait deadline exceeded (pgid=${monitor})"
            return 1
        fi
        sleep 0.01
    done
}

# Orphaned zombies cannot run or hold resources; their reaping belongs to init.
verify_group_running() {
    local file row status _parent group rest
    for file in /proc/[0-9]*/stat; do
        if ! IFS= read -r row 2>/dev/null <"${file}"; then
            continue
        fi
        read -r status _parent group rest <<<"${row##*) }"
        if [[ "${group}" == "$1" && "${status}" != Z && "${status}" != X ]]; then
            return 0
        fi
    done
    return 1
}

# The daemon owns container lifetimes independently of the killed client.
# Never select by image or a shared prefix: other runs may use the same image.
verify_cleanup_containers() {
    local ids
    local -a containers=()
    if ! ids="$(docker ps -aq --filter "label=worktool.verify-run=$1")"; then
        log_error "cannot list verification containers for run $1"
        return 1
    fi
    [[ -n "${ids}" ]] || return 0
    mapfile -t containers <<<"${ids}"
    if ! docker rm -f -v "${containers[@]}" >/dev/null; then
        log_error "cannot remove verification containers for run $1"
        return 1
    fi
}
