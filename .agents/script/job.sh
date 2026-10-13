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
    if ! mkdir -p "${ROOT}/.agents/state/job"; then
        log_error "job.sh: cannot create job directory ${DIR}"
        exit 1
    fi
    if ! mkdir "${DIR}"; then
        if [[ -d "${DIR}" ]]; then
            log_error "job.sh: job already exists: ${NAME}"
        else
            log_error "job.sh: cannot create job directory ${DIR}"
        fi
        exit 1
    fi
    nohup setsid bash -c "$(cat <<'WORKER'
        set -euo pipefail
        dir=$1; shift
        rc=0
        "$@" > "$dir/log" 2>&1 || rc=$?
        printf "%s\n" "$rc" > "$dir/rc.tmp"
        mv "$dir/rc.tmp" "$dir/rc"
WORKER
    )" job "${DIR}" "$@" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "${DIR}/pid"
    printf '%s: started\n' "${NAME}"
}
state() {
    [[ -d "${DIR}" ]] || { log_error "job.sh: unknown job: ${NAME}"; exit 1; }
    if [[ -f "${DIR}/rc" ]]; then
        RC="$(cat "${DIR}/rc")"
        if [[ "${RC}" == 0 ]]; then printf '%s: success\n' "${NAME}"; else printf '%s: failed (exit %s)\n' "${NAME}" "${RC}"; return 1; fi
        return 0
    fi
    printf '%s: running\n' "${NAME}"
    return 124
}
wait_job() {
    local deadline=0
    [[ -z "${MAX_SECONDS}" ]] || deadline=$((SECONDS + MAX_SECONDS))
    while [[ ! -f "${DIR}/rc" ]]; do
        if [[ -n "${MAX_SECONDS}" && "${SECONDS}" -ge "${deadline}" ]]; then state; exit 124; fi
        sleep 1
    done
    local state_rc=0
    state || state_rc=$?
    if [[ "${RC}" == 0 ]]; then
        tail -n 40 "${DIR}/log"
    else
        awk '/^(not ok|FAIL|ERROR|Error|error:|In .* line [0-9]+:|\[ERROR\]|\[ci\] ERROR)/ { left=15 } left > 0 { print; left--; found=1; count++; if (count >= 80) exit } END { if (!found) exit 1 }' "${DIR}/log" || tail -n 40 "${DIR}/log"
    fi
    return "${state_rc}"
}
parse_args() {
    HELP=0
    ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --) ARGS+=("$@"); break ;;
            --help|-h) HELP=1 ;;
            --max-seconds)
                [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && ${#2} -le 6 ]] || bad 'invalid max-seconds'
                ARGS+=("$1" "$2"); shift ;;
            -*) bad "unknown option '$1'" ;;
            *) ARGS+=("$1") ;;
        esac
        shift
    done
}
validate_args() {
    VERB="${1:-}"; NAME="${2:-}"
    [[ -z "$NAME" && "$HELP" == 1 ]] || [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || bad 'invalid job name'
    MAX_SECONDS=''
    case "$VERB" in
        start)
            [[ $# -le 2 && "$HELP" == 1 ]] && return 0
            [[ "${3:-}" == -- && $# -ge 4 ]] || bad 'start requires -- <cmd...>' ;;
        wait)
            if [[ "${3:-}" == --max-seconds && $# == 4 ]]; then MAX_SECONDS=$((10#$4))
            elif [[ $# -gt 2 ]]; then bad "unknown option '$3'"; fi ;;
        status) [[ $# -le 2 ]] || bad "unknown option '$3'" ;;
        '') [[ "$HELP" == 1 ]] || bad 'missing command' ;;
        *) bad "unknown option '$VERB'" ;;
    esac
}
main() {
    parse_args "$@"
    validate_args "${ARGS[@]}"
    if [[ "$HELP" == 1 ]]; then usage; exit 0; fi
    DIR="${ROOT}/.agents/state/job/${NAME}"
    case "$VERB" in
        start) start_job "${ARGS[@]:3}" ;;
        wait) [[ -d "${DIR}" ]] || bad 'unknown job'; wait_job ;;
        status) state ;;
    esac
}
main "$@"
