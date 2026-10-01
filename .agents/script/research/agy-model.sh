#!/usr/bin/env bash
# Resolve an agy model ID; stdout is reserved for the result.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR/../../../lib
# shellcheck source=log.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)/lib/log.sh"

main() {
    local help=0 arg
    for arg in "$@"; do
        case "${arg}" in
            -h|--help) help=1 ;;
            *)
                printf "agy-model.sh: unknown option '%s' (see --help)\n" "${arg}" >&2
                return 2
                ;;
        esac
    done
    if [[ "${help}" -eq 1 ]]; then
        printf 'Usage: agy-model.sh [--help]\nResolve the latest Gemini flash-high model from agy models.\n' >&2
        return 0
    fi
    local model
    model="$(agy models | awk '$1 ~ /^gemini-[0-9]+([.][0-9]+)*-flash-high$/ { print $1 }' | sort -V | tail -n 1)"
    if [[ -z "${model}" ]]; then
        log_error 'agy-model.sh: no Gemini flash-high model available'
        return 1
    fi
    printf '%s\n' "${model}"
}

main "$@"
