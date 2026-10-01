#!/usr/bin/env bash
# .agents/hook/worktree_create.sh - Claude Code WorktreeCreate hook,
# registered in .claude/settings.json.
#
# Replaces Claude Code's default worktree location (.claude/worktrees/<name>)
# with <repo>/../worktree/<name>: the directory beside the main checkout where
# worktool keeps every worktree (the pr-loop workflow uses it too,
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

    local _name _root _worktree_root _dir _branch
    _name="$(hook_field '.name')"
    [[ -n "${_name}" ]] || _fail "missing .name in payload"
    # The name becomes a directory and a branch component: a plain word that
    # starts with a letter or digit (so never '.', '..', a path or an option
    # git would parse) and holds no '..'.
    if [[ ! "${_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "${_name}" == *..* ]]; then
        _fail "unsafe name $(printf '%q' "${_name}")"
    fi

    _root="${CLAUDE_PROJECT_DIR:-}"
    [[ -n "${_root}" ]] || _root="$(git rev-parse --show-toplevel 2>/dev/null)"
    # .git is a directory in the main checkout and a file in a linked worktree.
    [[ -n "${_root}" && -e "${_root}/.git" ]] || _fail "no repo root"

    _worktree_root="$(hook_worktree_root "${_root}")"
    _dir="${_worktree_root}/${_name}"
    _branch="worktree-${_name}"
    mkdir -p "${_worktree_root}" || _fail "mkdir ${_worktree_root} failed"

    # Already present (idempotent): hand the path back - but only when it
    # really is a worktree (.git file), never a plain directory.
    if [[ -e "${_dir}" ]]; then
        [[ -f "${_dir}/.git" ]] || _fail "${_dir} exists but is not a git worktree"
    else
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
