#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/../../../lib
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=log.sh
source "${SCRIPT_DIR}/../../../lib/log.sh"

APPLY=0 HELP=0
for ARG in "$@"; do
    case "${ARG}" in
        --apply) APPLY=1 ;;
        -h|--help) HELP=1 ;;
        *) printf "prune-merged.sh: unknown option '%s' (see --help)\n" "${ARG}" >&2; exit 2 ;;
    esac
done
if [[ "${HELP}" == 1 ]]; then
    printf 'Usage: prune-merged.sh [--apply] [--help]\nDry-run by default; --apply removes merged, clean linked worktrees.\n' >&2
    exit 0
fi
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname -- "${COMMON}")"
WORKTREE_ROOT="$(dirname -- "${MAIN}")/worktree"
git fetch origin >&2
while IFS= read -r -d '' FIELD; do
    case "${FIELD}" in
        worktree\ *)
            TREE="${FIELD#worktree }"
            if [[ "${TREE}" == "${WORKTREE_ROOT}/"* ]]; then
                printf '%s\n' "${TREE}"
            fi
            ;;
    esac
done < <(git worktree list --porcelain -z)
