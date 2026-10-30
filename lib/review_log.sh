#!/usr/bin/env bash
# Reject review logs in committed history; acceptance evidence remains allowed.
# Public interface: review_log_check_commits <repo> <git revision>...
# Only descendants of the first addition of this library in HEAD history are
# checked, including that addition itself; other commits are skipped by ancestry.
# Diagnostics go to stderr; invalid revisions, shallow or missing enforcing
# history, ancestry errors and review logs return 1.
# shellcheck source-path=SCRIPTDIR
_REVIEW_LOG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_REVIEW_LOG_DIR}/log.sh"

_review_log_path() {
    local path="${1,,}" name
    name="${path##*/}"
    [[ "$path" == doc/evidence/* && "$name" == *review* ]] ||
        [[ "$name" =~ ^[0-9]+-review-round-[0-9]+(\..*)?$ ]]
}

_review_log_check_commit() {
    local repo="$1" sha="$2" files path bad=0
    files="$(mktemp)" || return 1
    if ! git -C "$repo" diff-tree --root -c -r --no-renames \
        --diff-filter=A --no-commit-id --name-only -z "$sha" > "$files"; then
        rm -f "$files"
        return 1
    fi
    while IFS= read -r -d '' path; do
        if _review_log_path "$path"; then
            log_error "$sha adds review log '$path'; post it as a PR comment instead."
            bad=1
        fi
    done < "$files"
    rm -f "$files"
    return "$bad"
}

_review_log_enforcing_commit() {
    local repo="$1" enforcing shallow
    shallow="$(git -C "$repo" rev-parse --is-shallow-repository)" || return 1
    if [[ "$shallow" == true ]]; then
        log_error 'Cannot find enforcing commit reliably in shallow history; fetch full history (fail closed).'
        return 1
    fi
    enforcing="$(git -C "$repo" log --format=%H --reverse --diff-filter=A -- lib/review_log.sh)" || return 1
    enforcing="${enforcing%%$'\n'*}"
    if [[ -z "$enforcing" ]]; then
        log_error 'Cannot find enforcing commit for lib/review_log.sh; fetch full history (fail closed).'
        return 1
    fi
    printf '%s\n' "$enforcing"
}

review_log_check_commits() {
    local repo="$1" commits sha enforcing rc bad=0
    shift
    enforcing="$(_review_log_enforcing_commit "$repo")" || return 1
    commits="$(git -C "$repo" rev-list "$@" --)" || return 1
    while IFS= read -r sha; do
        [[ -n "$sha" ]] || continue
        rc=0
        git -C "$repo" merge-base --is-ancestor "$enforcing" "$sha" || rc=$?
        if ((rc == 1)); then
            log_info "$sha skipped: does not descend from enforcing commit $enforcing."
            continue
        elif ((rc != 0)); then
            log_error "Cannot establish ancestry for $sha (fail closed)."
            return 1
        fi
        _review_log_check_commit "$repo" "$sha" || bad=1
    done <<< "$commits"
    return "$bad"
}
