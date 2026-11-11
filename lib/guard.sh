#!/usr/bin/env bash
# Shared acceptance guards. Sourced libraries do not alter shell options.

guard_fail() {
    printf '[FAIL] %s\n' "$*" >&2
    return 1
}

guard_timed() {
    local _secs="$1"
    shift
    timeout -k 10 "${_secs}" "$@"
}

guard_require() {
    local _c _missing=0
    for _c in "$@"; do
        command -v -- "${_c}" >/dev/null 2>&1 \
            || { printf '[UNAVAILABLE] %s: %s not found on PATH\n' "${0##*/}" "${_c}" >&2; _missing=3; }
    done
    return "${_missing}"
}
