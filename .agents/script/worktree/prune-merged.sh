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
prune_tree() {
    local tree="$1" branch
    if ! git merge-base --is-ancestor "$(git -C "${tree}" rev-parse HEAD)" origin/main; then
        log_info "kept ${tree}: not merged"
        return 0
    fi
    if [[ "${APPLY}" == 0 ]]; then
        printf '%s\n' "${tree}"
        return 0
    fi
    branch="$(git -C "${tree}" symbolic-ref -q --short HEAD)" || branch=''
    git worktree remove -- "${tree}"
    log_info "removed worktree: ${tree}"
    if [[ -n "${branch}" ]]; then
        if git branch -d -- "${branch}" >&2; then
            log_info "removed branch: ${branch}"
        else
            log_warn "kept branch ${branch}: git branch -d refused"
        fi
    fi
}

while IFS= read -r -d '' FIELD; do
    case "${FIELD}" in
        worktree\ *)
            TREE="${FIELD#worktree }"
            if [[ "${TREE}" == "${WORKTREE_ROOT}/"* ]]; then
                prune_tree "${TREE}"
            fi
            ;;
    esac
done < <(git worktree list --porcelain -z)
