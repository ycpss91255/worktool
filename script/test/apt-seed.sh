#!/usr/bin/env bash
# apt-seed.sh - start and stop the local apt package proxy CI's Ubuntu image
# builds reach through Docker's predefined `http_proxy` build arg (issue
# #892; the proxy and its rules: script/test/apt-seed-proxy.mjs).
#
#   apt-seed.sh start --seed DIR [--record DIR] [--port N] --log FILE
#       starts the proxy in the background (its stderr in FILE, its pid in
#       FILE.pid), waits until it answers its health check (bounded, about
#       10 s) and prints the proxy URL (http://127.0.0.1:N/) on stdout. A
#       proxy that does not come up is a failure (exit 1, the log on
#       stderr): a build never silently goes around it.
#   apt-seed.sh stop --log FILE
#       stops that proxy (SIGTERM; it finishes its pending records first),
#       waits for it to exit (bounded) and prints its final `stats` line on
#       stderr. Exit 1 when it does not exit in time.
#
# The port defaults to 3142. Exit: 0 done, 1 failure, 2 bad arguments.

# shellcheck source-path=SCRIPTDIR/../../lib
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
PROXY="${SCRIPT_DIR}/apt-seed-proxy.mjs"
# shellcheck source=log.sh
source "${REPO_ROOT}/lib/log.sh"

_usage() {
    cat <<'EOF'
Usage: apt-seed.sh start --seed DIR [--record DIR] [--port N] --log FILE
       apt-seed.sh stop --log FILE
Start (or stop) the local apt package proxy for CI image builds; start
prints the proxy URL once it answers its health check.
EOF
}

_bad() {
    printf '%s\n' "apt-seed.sh: $1 (see --help)" >&2
    exit 2
}

CMD=""
SEED=""
RECORD=""
PORT=3142
LOG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        start|stop)
            [[ -z "${CMD}" ]] || _bad "unexpected argument '$1'"
            CMD="$1" ;;
        --seed|--record|--port|--log)
            [[ $# -ge 2 && -n "$2" ]] || _bad "$1 requires a value"
            case "$1" in
                --seed) SEED="$2" ;;
                --record) RECORD="$2" ;;
                --port) PORT="$2" ;;
                --log) LOG="$2" ;;
            esac
            shift ;;
        -h|--help) _usage; exit 0 ;;
        *) _bad "unknown option '$1'" ;;
    esac
    shift
done
[[ -n "${CMD}" ]] || _bad "start or stop required"
[[ -n "${LOG}" ]] || _bad "--log is required"
if [[ ! "${PORT}" =~ ^[1-9][0-9]*$ ]] || ((PORT > 65535)); then
    _bad "--port must be 1-65535, got '${PORT}'"
fi

# 0 when the proxy at 127.0.0.1:PORT answers its health check.
# A subshell, so a refused connection only fails the probe.
_healthy() (
    _line=""
    exec 3<>"/dev/tcp/127.0.0.1/${PORT}" || exit 1
    printf 'GET /__apt_seed/health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n' >&3
    IFS= read -r -t 2 _line <&3 || exit 1
    [[ "${_line}" == "HTTP/1.1 200"* ]]
) 2>/dev/null

if [[ "${CMD}" == start ]]; then
    [[ -n "${SEED}" ]] || _bad "--seed is required"
    _args=(--port "${PORT}" --seed "${SEED}")
    [[ -z "${RECORD}" ]] || _args+=(--record "${RECORD}")
    nohup node "${PROXY}" "${_args[@]}" </dev/null >/dev/null 2>"${LOG}" &
    printf '%s\n' "$!" >"${LOG}.pid"
    for ((_i = 0; _i < 100; _i++)); do
        if _healthy; then
            log_info "apt-seed.sh: proxy up on 127.0.0.1:${PORT} (seed ${SEED}${RECORD:+, record ${RECORD}})"
            printf 'http://127.0.0.1:%s/\n' "${PORT}"
            exit 0
        fi
        if ! kill -0 "$(cat "${LOG}.pid")" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    log_error "apt-seed.sh: the proxy did not come up on 127.0.0.1:${PORT}; its log:"
    cat "${LOG}" >&2
    exit 1
fi

[[ -f "${LOG}.pid" ]] || { log_error "apt-seed.sh: no pid file ${LOG}.pid"; exit 1; }
_pid="$(cat "${LOG}.pid")"
if kill -0 "${_pid}" 2>/dev/null; then
    kill -TERM "${_pid}"
    for ((_i = 0; _i < 100; _i++)); do
        kill -0 "${_pid}" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "${_pid}" 2>/dev/null; then
        log_error "apt-seed.sh: the proxy (pid ${_pid}) did not exit"
        exit 1
    fi
fi
_stats="$(grep '^stats ' "${LOG}")" || _stats="stats (none logged)"
log_info "apt-seed.sh: proxy stopped, ${_stats}"
