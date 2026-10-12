#!/usr/bin/env bash
# Detached jobs with bounded, compact result collection.
# shellcheck source-path=SCRIPTDIR/../../lib
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=log.sh
source "${ROOT}/lib/log.sh"
usage() { printf '%s\n' 'Usage: job.sh start <name> -- <cmd...> | wait <name> [--max-seconds N] | status <name>'; }
bad() { log_error "job.sh: $* (see --help)"; exit 2; }
start_job() {
    mkdir -p "${ROOT}/.agents/state/job"
    if ! mkdir "${DIR}"; then log_error "job.sh: job already exists: ${NAME}"; exit 1; fi
    nohup setsid bash -c '
        dir=$1; shift
        rc=0
        "$@" > "$dir/log" 2>&1 || rc=$?
        printf "%s\n" "$rc" > "$dir/rc.tmp"
        mv "$dir/rc.tmp" "$dir/rc"
    ' job "${DIR}" "$@" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "${DIR}/pid"
    printf '%s: started\n' "${NAME}"
}
state() {
    [[ -d "${DIR}" ]] || { log_error "job.sh: unknown job: ${NAME}"; exit 1; }
    if [[ -f "${DIR}/rc" ]]; then
        RC="$(cat "${DIR}/rc")"
        if [[ "${RC}" == 0 ]]; then printf '%s: success\n' "${NAME}"; else printf '%s: failed (exit %s)\n' "${NAME}" "${RC}"; fi
        return 0
    fi
    printf '%s: running\n' "${NAME}"
    return 124
}
wait_job() {
    local deadline=$((SECONDS + MAX_SECONDS))
    while [[ ! -f "${DIR}/rc" ]]; do
        if [[ "${SECONDS}" -ge "${deadline}" ]]; then state; exit 124; fi
        sleep 1
    done
    state
    if [[ "${RC}" == 0 ]]; then
        tail -n 40 "${DIR}/log"
    else
        awk '/^(not ok|FAIL|ERROR|Error|error:|\[ERROR\])/ { left=15 } left > 0 { print; left--; found=1; count++; if (count >= 80) exit } END { if (!found) exit 1 }' "${DIR}/log" || tail -n 40 "${DIR}/log"
    fi
    [[ "${RC}" == 0 ]] || exit 1
}
main() {
    local arg help=0
    local -a args=()
    for arg in "$@"; do
        if [[ "$arg" == -- ]]; then args+=("$arg"); shift; args+=("$@"); break; fi
        case "$arg" in
            --help|-h) help=1 ;;
            --max-seconds) args+=("$arg") ;;
            -*) bad "unknown option '$arg'" ;;
            *) args+=("$arg") ;;
        esac
        shift
    done
    if [[ "$help" == 1 ]]; then usage; exit 0; fi
    set -- "${args[@]}"
    local verb="${1:-}"; [[ $# -gt 0 ]] && shift
    NAME="${1:-}"; [[ $# -gt 0 ]] && shift
    [[ "${NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || bad 'invalid job name'
    DIR="${ROOT}/.agents/state/job/${NAME}"
    case "${verb}" in
        start) [[ "${1:-}" == -- && $# -gt 1 ]] || bad 'start requires -- <cmd...>'; shift; start_job "$@" ;;
        wait)
            MAX_SECONDS=86400
            if [[ "${1:-}" == --max-seconds && $# == 2 ]]; then
                [[ "$2" =~ ^[0-9]+$ && ${#2} -le 6 ]] || bad 'invalid max-seconds'
                MAX_SECONDS=$((10#$2)); shift 2
            fi
            [[ $# == 0 ]] || bad "unknown option '$1'"
            [[ -d "${DIR}" ]] || bad 'unknown job'; wait_job ;;
        status) [[ $# == 0 ]] || bad "unknown option '$1'"; state ;;
        *) bad "unknown option '${verb}'" ;;
    esac
}
main "$@"
