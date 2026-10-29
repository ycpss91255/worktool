#!/usr/bin/env bash
# Reject review logs in committed history; acceptance evidence remains allowed.
# Public interface: review_log_check_commits <repo> <git revision>...
# Diagnostics go to stderr; invalid revisions and review logs return 1.
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
    if ! git -C "$repo" diff-tree --root --first-parent -m -r --no-renames \
        --no-commit-id --name-only -z "$sha" > "$files"; then
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

review_log_check_commits() {
    local repo="$1" commits sha bad=0
    shift
    commits="$(git -C "$repo" rev-list "$@" --)" || return 1
    while IFS= read -r sha; do
        [[ -n "$sha" ]] || continue
        _review_log_check_commit "$repo" "$sha" || bad=1
    done <<< "$commits"
    return "$bad"
}
