#!/usr/bin/env bash
# .agents/hook/check_main_fresh_before_worktree.sh - Claude Code PreToolUse
# hook (matcher: Bash), registered in .claude/settings.json.
#
# Fires before `git worktree add ... main` (or `... origin/main`). DENIES
# (permissionDecision "deny") when local main is behind origin/main, so a
# new worktree never starts from a stale base and later needs a rebase
# (worktool: every sub-issue works in its own .worktree/<name>, and `main`
# only moves by merged PRs - see AGENTS.md git conventions). Allows when:
#   - the command does not start a worktree from main / origin/main
#   - the working directory is not a git repo
#   - `git fetch` fails (offline / auth: never false-deny when degraded)
#   - the repo has no origin/main or no local main yet
#   - local main is even with or ahead of origin/main
#
# Output contract: allow = exit 0 with no stdout; deny = exit 0 with the
# permissionDecision JSON on stdout.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "check-main-fresh-before-worktree"

# _from_main <command> - 0 when it is a `git worktree add` from main or
# origin/main (a standalone token).
_from_main() {
    local _re_add='git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?worktree[[:space:]]+add'
    [[ "$1" =~ ${_re_add} ]] || return 1
    [[ "$1" =~ ([[:space:]]|^)(origin/)?main([[:space:]]|$) ]]
}

# _work_dir <command> <cwd> - the directory the command runs git in: its
# `git -C <dir>`, else a leading `cd <dir> &&`, else the hook's cwd.
_work_dir() {
    local _dir=''
    if [[ "$1" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
        _dir="${BASH_REMATCH[1]}"
    elif [[ "$1" =~ cd[[:space:]]+([^[:space:]\&\;]+)[[:space:]]*\&\& ]]; then
        _dir="${BASH_REMATCH[1]}"
    fi
    [[ -z "${_dir}" ]] && _dir="$2"
    [[ "${_dir}" != /* ]] && _dir="$2/${_dir}"
    printf '%s' "${_dir}"
}

# _behind <repo-root> - print how many commits local main lags origin/main
# (after a best-effort fetch); print nothing when it cannot tell.
_behind() {
    local _root="$1"
    git -C "${_root}" fetch --quiet origin main 2>/dev/null || return 0
    git -C "${_root}" rev-parse --verify --quiet origin/main >/dev/null 2>&1 || return 0
    git -C "${_root}" rev-parse --verify --quiet main >/dev/null 2>&1 || return 0
    git -C "${_root}" rev-list --count main..origin/main 2>/dev/null
}

_deny() {
    jq -n --arg m "$1" '{
        systemMessage: $m,
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $m
        }
    }'
}

main() {
    hook_read_input
    local _cmd _cwd _root _n
    _cmd="$(hook_command)"
    _cwd="$(hook_field '.cwd')"
    [[ -z "${_cwd}" ]] && _cwd="${PWD}"
    [[ -n "${_cmd}" ]] || return 0
    _from_main "${_cmd}" || return 0
    _root="$(git -C "$(_work_dir "${_cmd}" "${_cwd}")" rev-parse --show-toplevel 2>/dev/null)"
    [[ -n "${_root}" ]] || return 0
    _n="$(_behind "${_root}")"
    [[ "${_n}" =~ ^[1-9][0-9]*$ ]] || return 0
    _deny "$(printf 'Local main is %d commit(s) behind origin/main in %s.\nA worktree started from a stale base needs a rebase later. Run this first, then retry:\n  git -C %s pull --ff-only origin main' \
        "${_n}" "${_root}" "${_root}")"
    return 0
}

main "$@"
