#!/usr/bin/env bash
# .agents/hook/check_main_fresh_before_worktree.sh - Claude Code PreToolUse
# hook (matcher: Bash), registered in .claude/settings.json.
#
# Fires before `git worktree add <path> main` (or `... origin/main`): a
# worktree whose commit-ish is main, not a new branch named main. DENIES
# (permissionDecision "deny") when local main is behind origin/main, so a
# new worktree never starts from a stale base and later needs a rebase
# (worktool: every sub-issue works in ../worktree/<name>, and `main`
# only moves by merged PRs - see AGENTS.md git conventions). Allows when:
#   - the command launches no worktree from main / origin/main (quoted
#     text and heredoc bodies that mention one are data: lib/subcommand.sh)
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
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "check-main-fresh-before-worktree"

# _from_main <sub-command> - 0 when this launch is a `git [-C <dir>]
# worktree add` whose commit-ish (the positional after <path>) is main or
# origin/main. Options may sit before or after the positionals; -b / -B
# <new-branch> and --reason <string> take the next word, so the NAME of a
# new branch (`-b main`) or a path called main is not the base.
_from_main() {
    local -a _w _pos=()
    local _i=1 _o
    read -r -a _w <<<"$1"
    [[ "${_w[0]:-}" == git ]] || return 1
    [[ "${_w[1]:-}" == -C ]] && _i=3
    [[ "${_w[_i]:-}" == worktree && "${_w[_i + 1]:-}" == add ]] || return 1
    for ((_i = _i + 2; _i < ${#_w[@]}; _i++)); do
        _o="${_w[_i]}"
        case "${_o}" in
            --) _pos+=("${_w[@]:_i + 1}"); break ;;
            -b|-B|--reason) _i=$((_i + 1)) ;;
            -*) ;;
            *) _pos+=("${_o}") ;;
        esac
    done
    [[ "${_pos[1]:-}" =~ ^(origin/)?main$ ]]
}

# _resolve <base> <dir> - <dir>, taken relative to <base> unless absolute.
_resolve() {
    if [[ "$2" == /* ]]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi
}

# _worktree_dir <command> <cwd> - print the directory the first
# worktree-from-main launch runs git in (its `git -C <dir>`, else the last
# `cd <dir>` before it, else <cwd>); fail when the command launches none.
# Only real launches count (lib/subcommand.sh), so quoted text or a heredoc
# body that mentions such a command is data.
_worktree_dir() {
    local _sub _dir="$2"
    while IFS= read -r _sub; do
        if [[ "${_sub}" =~ ^cd[[:space:]]+([^[:space:]]+)$ ]]; then
            _dir="$(_resolve "${_dir}" "${BASH_REMATCH[1]}")"
            continue
        fi
        _from_main "${_sub}" || continue
        if [[ "${_sub}" =~ ^git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
            _dir="$(_resolve "${_dir}" "${BASH_REMATCH[1]}")"
        fi
        printf '%s' "${_dir}"
        return 0
    done < <(hook_subcommands "$1")
    return 1
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
    local _cmd _cwd _dir _root _n
    _cmd="$(hook_command)"
    _cwd="$(hook_field '.cwd')"
    [[ -z "${_cwd}" ]] && _cwd="${PWD}"
    [[ -n "${_cmd}" ]] || return 0
    _dir="$(_worktree_dir "${_cmd}" "${_cwd}")" || return 0
    _root="$(git -C "${_dir}" rev-parse --show-toplevel 2>/dev/null)"
    [[ -n "${_root}" ]] || return 0
    _n="$(_behind "${_root}")"
    [[ "${_n}" =~ ^[1-9][0-9]*$ ]] || return 0
    _deny "$(printf 'Local main is %d commit(s) behind origin/main in %s.\nA worktree started from a stale base needs a rebase later. Run this first, then retry:\n  git -C %s pull --ff-only origin main' \
        "${_n}" "${_root}" "${_root}")"
    return 0
}

main "$@"
