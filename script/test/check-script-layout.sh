#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/../../lib
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=log.sh
source "${SCRIPT_DIR}/../../lib/log.sh"
ROOT="${SCRIPT_DIR}/../.."
HELP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                printf 'check-script-layout.sh: --root requires a path (see --help)\n' >&2
                exit 2
            fi
            ROOT="$2"; shift ;;
        -h|--help) HELP=1 ;;
        *) printf "check-script-layout.sh: unknown option '%s' (see --help)\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
if [[ "${HELP}" == 1 ]]; then
    printf 'Usage: check-script-layout.sh [--root <repo>] [--help]\n' >&2
    exit 0
fi
if [[ ! -d "${ROOT}" ]]; then
    log_error "repository not found: ${ROOT}"
    exit 1
fi
if ! git -C "${ROOT}" rev-parse --show-toplevel >/dev/null 2>&1; then
    log_error "not a Git repository: ${ROOT}"
    exit 1
fi
FAILED=0
for TREE in script .agents/script; do
    [[ -d "${ROOT}/${TREE}" ]] || continue
    while IFS= read -r -d '' FILE; do
        log_error "top-level script: ${FILE#"${ROOT}/"}"
        FAILED=1
    done < <(find "${ROOT}/${TREE}" -maxdepth 1 -type f -executable -print0)
done
# The artifact pattern table lives here; match every path component.
ARTIFACT_PATTERNS=('*.bak' '*.orig' '*.rej' '*.log' '_backup' 'review_log')
check_artifact() {
    local path="$1" component pattern
    local components=()
    IFS=/ read -r -a components <<< "${path}"
    for component in "${components[@]}"; do
        for pattern in "${ARTIFACT_PATTERNS[@]}"; do
            if [[ "${component}" == ${pattern} ]]; then
                log_error "process artifact: ${path}"
                FAILED=1
                return 0
            fi
        done
    done
}
PATH_LIST="$(mktemp)"
trap 'rm -f "${PATH_LIST}"' EXIT
if ! git -C "${ROOT}" ls-files --cached --others --exclude-standard -z > "${PATH_LIST}"; then
    log_error "could not enumerate repository paths: ${ROOT}"
    exit 1
fi
while IFS= read -r -d '' FILE; do
    check_artifact "${FILE}"
done < "${PATH_LIST}"
exit "${FAILED}"
