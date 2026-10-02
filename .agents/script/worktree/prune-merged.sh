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
git -C "${MAIN}" fetch origin >&2
merged_head() {
    local head="$1" ref
    while IFS= read -r ref; do
        case "${ref}" in
            refs/remotes/origin/main) ;;
            refs/remotes/origin/m[0-9]*/[0-9]*-acceptance)
                [[ "${ref}" =~ ^refs/remotes/origin/m[0-9]+/[0-9]+-acceptance$ ]] || continue ;;
            *) continue ;;
        esac
        if git -C "${MAIN}" merge-base --is-ancestor "${head}" "${ref}"; then
            return 0
        fi
    done <<< "${REMOTE_REFS}"
    return 1
}

tree_clean() {
    local status line
    status="$(git -C "$1" status --porcelain --ignored --untracked-files=all)" || return 1
    while IFS= read -r line; do
        case "${line}" in
            ''|'!! .agents/state/'*) ;;
            *) return 1 ;;
        esac
    done <<< "${status}"
}

REMOTE_REFS="$(git -C "${MAIN}" for-each-ref --format='%(refname)' refs/remotes/origin)"
prune_tree() {
    local tree="$1" branch
    if ! merged_head "$(git -C "${tree}" rev-parse HEAD)"; then
        if [[ -z "$(git -C "${MAIN}" for-each-ref --contains="$(git -C "${tree}" rev-parse HEAD)" --format='%(refname)' refs/remotes/origin)" ]]; then
            log_info "kept ${tree}: unpushed commits; not merged"
        else
            log_info "kept ${tree}: not merged"
        fi
        return 0
    fi
    if ! tree_clean "${tree}"; then
        log_info "kept ${tree}: uncommitted changes"
        return 0
    fi
    if [[ "${APPLY}" == 0 ]]; then
        printf '%s\n' "${tree}"
        return 0
    fi
    branch="$(git -C "${tree}" symbolic-ref -q --short HEAD)" || branch=''
    if ! git -C "${MAIN}" worktree remove -- "${tree}" >&2; then
        log_warn "kept ${tree}: git worktree remove refused"
        return 0
    fi
    log_info "removed worktree: ${tree}"
    if [[ -n "${branch}" ]]; then
        if git -C "${MAIN}" branch -d -- "${branch}" >&2; then
            log_info "removed branch: ${branch}"
        else
            log_warn "kept branch ${branch}: git -C "${MAIN}" branch -d refused"
        fi
    fi
}

consider_tree() {
    if [[ "${TREE}" == "${MAIN}" ]]; then
        log_info "kept ${TREE}: main checkout"
    elif [[ "${TREE}" != "${WORKTREE_ROOT}/"* ]]; then
        log_info "kept ${TREE}: outside sibling worktree/"
    elif [[ "${LOCKED}" == 1 ]]; then
        log_info "kept ${TREE}: locked"
    elif [[ ! -d "${TREE}" ]]; then
        log_info "kept ${TREE}: missing worktree directory"
    else
        prune_tree "${TREE}"
    fi
}

TREE='' LOCKED=0
LIST="$(mktemp)"
trap 'rm -f -- "${LIST}"' EXIT
git -C "${MAIN}" worktree list --porcelain -z > "${LIST}"
while IFS= read -r -d '' FIELD; do
    case "${FIELD}" in
        worktree\ *) TREE="${FIELD#worktree }"; LOCKED=0 ;;
        locked|locked\ *) LOCKED=1 ;;
        '') consider_tree ;;
    esac
done < "${LIST}"
