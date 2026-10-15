#!/usr/bin/env bash
set -euo pipefail
matrix_resident() {
    local deadline=$((SECONDS + ${MATRIX_FIXTURE_TIMEOUT:-10}))
    while ((SECONDS < deadline)); do sleep 0.1; done
    printf 'matrix fixture %s: resident wait deadline exceeded\n' "${phase}" >&2
    return 1
}

phase="${2:-}"
if [[ "${phase}" == assemble ]]; then
    manifest="$(mktemp)"
    cat box/dev.ini >"${manifest}"
    box_home="${*: -1}"
    mkdir -p "${box_home}/.cache/tmux"
    printf '%s\n' "${box_home}" >"${MATRIX_STATE}/home"
    if [[ "${TMPDIR}" == */assemble-INT/* || "${TMPDIR}" == */assemble-TERM/* || "${TMPDIR}" == */assemble-HUP/* ]]; then
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
    fi
    # Publish the observed event only after state and signal handling are ready.
    printf 'dev\n' >"${MATRIX_STATE}/boxes"
    if [[ "${TMPDIR}" == */assemble-INT/* || "${TMPDIR}" == */assemble-TERM/* || "${TMPDIR}" == */assemble-HUP/* ]]; then
        matrix_resident
    fi
elif [[ "${phase}" == bench ]]; then
    trap 'exit 0' INT TERM HUP
    printf '[INFO] psi before enter run 1: /proc/pressure/cpu some avg10=0.00\n' >&2
    matrix_resident
fi
