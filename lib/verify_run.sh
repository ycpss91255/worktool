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
    state="$(mktemp -d)" || return 1
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
        verify_stop_group "${monitor}" "${interrupted}"
        wait "${monitor}" || rc=$?
    fi
    if [[ -n "${interrupted}" || "${rc}" -eq 124 || -e "${state}/deadline" ]]; then
        if [[ -z "${interrupted}" ]]; then
            if ! kill -KILL -- "-${monitor}" 2>/dev/null; then
                : # The process group may already have exited.
            fi
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

verify_restore_signals() {
    local interrupted="$1" saved=""
    trap - INT TERM HUP
    eval "$2"
    eval "$3"
    eval "$4"
    if [[ -n "${interrupted}" ]]; then
        case "${interrupted}" in INT) saved="$2" ;; TERM) saved="$3" ;; HUP) saved="$4" ;; esac
        if [[ -n "${saved}" ]]; then
            kill -s "${interrupted}" "${BASHPID}"
        fi
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
    if ! kill -KILL -- "-${monitor}" 2>/dev/null; then
        : # The process group may already have exited.
    fi
    while verify_group_running "${monitor}"; do
        sleep 0.01
    done
}

# Orphaned zombies cannot run or hold resources; their reaping belongs to init.
verify_group_running() {
    local file row status _parent group rest
    for file in /proc/[0-9]*/stat; do
        if ! IFS= read -r row <"${file}" 2>/dev/null; then
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
