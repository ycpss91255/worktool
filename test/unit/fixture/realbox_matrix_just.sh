#!/usr/bin/env bash
set -euo pipefail
phase="${2:-}"
if [[ "${phase}" == assemble ]]; then
    box_home="${*: -1}"
    mkdir -p "${box_home}/.cache/tmux"
    printf '%s\n' "${box_home}" >"${MATRIX_STATE}/home"
    if [[ "${TMPDIR}" == *assemble* ]]; then
        trap 'exit 0' INT TERM HUP
    fi
    # Publish the observed event only after state and signal handling are ready.
    printf 'dev\n' >"${MATRIX_STATE}/boxes"
    if [[ "${TMPDIR}" == *assemble* ]]; then
        while :; do sleep 0.1; done
    fi
elif [[ "${phase}" == bench ]]; then
    trap 'exit 0' INT TERM HUP
    printf '[INFO] psi before enter run 1: /proc/pressure/cpu some avg10=0.00\n' >&2
    while :; do sleep 0.1; done
fi
