#!/usr/bin/env bash
# Run an acceptance command with a bounded process group. Preserve command
# status, including 137; only an actual deadline is normalized to 124.
verify_run() {
    local budget="$1" rc=0 monitor state run_id=""
    shift
    state="$(mktemp -d)" || return 1
    if [[ "$1" == just && "${2:-}" == test ]]; then
        run_id="${state##*/}"
    fi
    WORKTOOL_TEST_RUN_ID="${run_id}" state="${state}" timeout -k 1 "${budget}" bash -c "
        mark_deadline() { touch \"\${state}/deadline\"; }
        trap mark_deadline TERM
        \"\$@\" &
        wait \"\$!\"
    " _ "$@" &
    monitor=$!
    wait "${monitor}" || rc=$?
    if [[ "${rc}" -eq 124 || -e "${state}/deadline" ]]; then
        if ! kill -KILL -- "-${monitor}" 2>/dev/null; then
            : # The process group may already have exited.
        fi
        if [[ -n "${run_id}" ]]; then
            verify_cleanup_containers "${run_id}" || rc=$?
        fi
        rc=124
    fi
    rm -rf "${state}"
    return "${rc}"
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
