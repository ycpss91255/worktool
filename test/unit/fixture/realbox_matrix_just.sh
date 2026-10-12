#!/usr/bin/env bash
set -euo pipefail
phase="${2:-}"
if [[ "${phase}" == assemble ]]; then
    printf 'dev\n' >"${MATRIX_STATE}/boxes"
    home="${@: -1}"
    mkdir -p "${home}/.cache/tmux"
    printf '%s\n' "${home}" >"${MATRIX_STATE}/home"
    if [[ "${TMPDIR}" == *assemble* ]]; then
        trap 'exit 0' INT TERM HUP
        while :; do sleep 0.1; done
    fi
elif [[ "${phase}" == bench ]]; then
    printf '[INFO] psi before enter run 1: /proc/pressure/cpu some avg10=0.00\n' >&2
    trap 'exit 0' INT TERM HUP
    while :; do sleep 0.1; done
fi
