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
    WORKTOOL_TEST_RUN_ID="${run_id}" state="${state}" timeout -k 1 "${budget}" bash -c "
        mark_deadline() { touch \"\${state}/deadline\"; }
        trap mark_deadline TERM
        trap ':' INT HUP
        \"\$@\"
    " _ "$@" &
    monitor=$!
    wait "${monitor}" || rc=$?
    if [[ -n "${interrupted}" ]]; then
        trap '' INT TERM HUP
        verify_stop_group "${monitor}" "${interrupted}"
        wait "${monitor}" || rc=$?
    fi
    if [[ -n "${interrupted}" || "${rc}" -eq 124 || -e "${state}/deadline" ]]; then
        if ! kill -KILL -- "-${monitor}" 2>/dev/null; then
            : # The process group may already have exited.
        fi
        if [[ -n "${run_id}" ]]; then
            verify_cleanup_containers "${run_id}" || rc=$?
        fi
        rc=124
    fi
    rm -rf "${state}"
    trap - INT TERM HUP
    eval "${saved_int}"
    eval "${saved_term}"
    eval "${saved_hup}"
    if [[ -n "${interrupted}" ]]; then
        kill -s "${interrupted}" "${BASHPID}"
        case "${interrupted}" in INT) rc=130 ;; TERM) rc=143 ;; HUP) rc=129 ;; esac
    fi
    return "${rc}"
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
