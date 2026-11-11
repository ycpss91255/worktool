# Shared system evidence interface. Formats are also embedded in the fish
# payloads; consumers supply observations, never shell source to evaluate.
CHAIN_MARKER_FORMAT='inbox-ok fish=%s ctrenv=%s mntns=%s tmux=%s host=%s\n'
HANG_READY_FORMAT='hang-ready fish=%s host=%s\n'

diagnostic_chain_marker() {
    awk -v fmt="${CHAIN_MARKER_FORMAT}" -v fish="$1" -v ctrenv="$2" \
        -v mntns="$3" -v tmux="$4" -v host="$5" \
        'BEGIN {printf fmt, fish, ctrenv, mntns, tmux, host}'
}

diagnostic_ready_marker() {
    awk -v fmt="${HANG_READY_FORMAT}" -v fish="$1" -v host="$2" \
        'BEGIN {printf fmt, fish, host}'
}

# Write TAP diagnostics to fd 3 and readable case output to stdout.
diagnostic_lines() {
    local _tag="$1" _line
    shift
    for _line in "$@"; do
        printf '# %s: %s\n' "${_tag}" "${_line}" >&3
        printf '%s: %s\n' "${_tag}" "${_line}"
    done
}

diagnostic_in_box() {
    diagnostic_lines "$1-in-box" "marker mntns=$2 == dev container; host=$3 == docker inspect dev hostname"
}

diagnostic_hang() {
    diagnostic_lines hang "in-box command started, then timed out after $1s (budget $2s, status $3)"
}
