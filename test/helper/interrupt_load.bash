#!/usr/bin/env bash
# Run interrupt fixtures under contention on one permitted container CPU.
INTERRUPT_LOAD_PIDS=()
interrupt_load_start() {
    local cpu worker
    cpu=$(awk '/Cpus_allowed_list/ { split($2, parts, /[-,]/); print parts[1] }' /proc/self/status)
    export INTERRUPT_LOAD_CPU="${cpu}"
    INTERRUPT_LOAD_PIDS=()
    for ((worker=0; worker<4; worker++)); do
        taskset -c "${cpu}" yes >/dev/null &
        INTERRUPT_LOAD_PIDS+=("$!")
    done
}

interrupt_load_stop() {
    local pid rc
    for pid in "${INTERRUPT_LOAD_PIDS[@]}"; do
        # Parallel runners may pass an ignored TERM disposition to workers.
        # These disposable CPU workers have no graceful shutdown work.
        if kill -0 "${pid}" 2>/dev/null; then kill -KILL "${pid}"; fi
        rc=0
        wait "${pid}" || rc=$?
        [[ "${rc}" -eq 0 || "${rc}" -eq 137 || "${rc}" -eq 143 ]]
    done
    INTERRUPT_LOAD_PIDS=()
}
