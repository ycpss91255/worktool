#!/usr/bin/env bash
# Run an acceptance command with a bounded process group. Preserve command
# status, including 137; only an actual deadline is normalized to 124.
verify_run() {
    local budget="$1" rc=0 monitor state
    shift
    state="$(mktemp -d)" || return 1
    state="${state}" timeout -k 1 "${budget}" bash -c '
        trap '\''touch "$state/deadline"'\'' TERM
        "$@" &
        wait "$!"
    ' _ "$@" &
    monitor=$!
    wait "${monitor}" || rc=$?
    if [[ "${rc}" -eq 124 || -e "${state}/deadline" ]]; then
        if ! kill -KILL -- "-${monitor}" 2>/dev/null; then
            : # The process group may already have exited.
        fi
        rc=124
    fi
    rm -rf "${state}"
    return "${rc}"
}
