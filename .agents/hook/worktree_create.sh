#!/usr/bin/env bash
# .agents/hook/worktree_create.sh - Claude Code WorktreeCreate hook,
# registered in .claude/settings.json.
#
# Replaces Claude Code's default worktree location (.claude/worktrees/<name>)
# with <repo>/.worktree/<name>: the gitignored directory where worktool
# keeps every worktree (the pr-loop workflow uses .worktree/<name> too,
# see doc/workflow.md), so they are easy to find and never committed.
#
# Contract (Claude Code WorktreeCreate): a JSON object with `.name` arrives
# on stdin; the hook creates the git worktree and prints ONLY its absolute
# path on stdout. A non-zero exit or empty stdout makes Claude Code fall
# back to its default. All git chatter goes to stderr.
#
# A misrouted tool-use payload (it carries `.tool_name`, never `.name`) is
# a no-op: exit 0 with nothing on stdout.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "worktree-create"

_fail() {
    printf 'worktree_create: %s\n' "$1" >&2
    exit 1
}

main() {
    hook_read_input
    [[ -n "$(hook_field '.tool_name')" ]] && exit 0

    local _name _root _dir _branch
    _name="$(hook_field '.name')"
    [[ -n "${_name}" ]] || _fail "missing .name in payload"
    # The name becomes a directory and a branch component: no path trickery.
    case "${_name}" in
        */*|*..*) _fail "unsafe name $(printf '%q' "${_name}")" ;;
    esac

    _root="${CLAUDE_PROJECT_DIR:-}"
    [[ -n "${_root}" ]] || _root="$(git rev-parse --show-toplevel 2>/dev/null)"
    # .git is a directory in the main checkout and a file in a linked worktree.
    [[ -n "${_root}" && -e "${_root}/.git" ]] || _fail "no repo root"

    _dir="${_root}/.worktree/${_name}"
    _branch="worktree-${_name}"
    mkdir -p "${_root}/.worktree" || _fail "mkdir ${_root}/.worktree failed"

    # Already present (idempotent): hand the path back.
    if [[ ! -d "${_dir}" ]]; then
        # A fresh worktree-<name> branch (Claude Code's default name), else an
        # existing branch of that name, else a detached worktree.
        git -C "${_root}" worktree add "${_dir}" -b "${_branch}" >&2 2>&1 \
            || git -C "${_root}" worktree add "${_dir}" "${_branch}" >&2 2>&1 \
            || git -C "${_root}" worktree add "${_dir}" >&2 2>&1 \
            || _fail "git worktree add failed for ${_dir}"
    fi
    printf '%s' "${_dir}"
}

main "$@"
