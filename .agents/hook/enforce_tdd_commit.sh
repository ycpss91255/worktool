#!/usr/bin/env bash
# .agents/hook/enforce_tdd_commit.sh - Claude Code PreToolUse hook (matcher:
# Bash), registered in .claude/settings.json.
#
# Issue #268: every implementation follows the tdd skill
# (.agents/skills/tdd/SKILL.md). A hook cannot see whether the skill was
# loaded, but its core rules land in what each `git commit` records, so a
# real `git commit` launch (also inside bash -c / eval; lib/subcommand.sh)
# is judged by the files the commit would record:
#
#   BLOCK  product code (lib/ script/ .agents/hook/ .agents/script/
#          .claude/workflows/ dockerfile/ justfile*) without any test (test/),
#          unless HEAD is a RED commit (it touches tests and no product code)
#
# Output contract: allow = exit 0, silent; block = exit 2, reason on stderr.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-tdd-commit"

# _kind <path> - print doc, test, product or other for a repo path.
_kind() {
    case "$1" in
        *.md|doc/*|.agents/memory/*|.agents/skills/*) printf doc ;;
        test/*) printf test ;;
        lib/*|script/*|.agents/hook/*|.agents/script/*|.claude/workflows/*|dockerfile/*|justfile*) printf product ;;
        *) printf other ;;
    esac
}

# _kinds - read repo paths on stdin; print " <kind> <kind> ... " (each
# kind of _kind that occurs, space-delimited on both ends).
_kinds() {
    local _f _out=' '
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] || continue
        _f="$(_kind "${_f}")"
        [[ "${_out}" == *" ${_f} "* ]] || _out+="${_f} "
    done
    printf '%s' "${_out}"
}

# _is_red <root> <commit> - 0 when <commit> touches tests and no product code.
_is_red() {
    local _k
    _k="$(git -C "$1" show --no-renames --name-only --format= "$2" -- 2>/dev/null | _kinds)"
    [[ "${_k}" == *" test "* && "${_k}" != *" product "* ]]
}

# _judge <root> - print the block reason for committing the index, or nothing.
_judge() {
    local _root="$1" _k
    _k="$(git -C "${_root}" diff --cached --no-renames --name-only | _kinds)"
    [[ "${_k}" == *" product "* && "${_k}" != *" test "* ]] || return 0
    _is_red "${_root}" HEAD && return 0
    printf '%s' 'this commit touches product code but no test, and HEAD is not a RED commit.'
}

# _is_commit <sub-command> - 0 when the launch is `git [-C <dir>] commit`.
_is_commit() {
    [[ "$1" =~ ^git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit([[:space:]]|$) ]]
}

main() {
    hook_read_input
    local _cmd _cwd _sub _root _reason
    _cmd="$(hook_command)"
    _cwd="$(hook_field '.cwd')"
    [[ -n "${_cwd}" ]] || _cwd="${PWD}"
    while IFS= read -r _sub; do
        _is_commit "${_sub}" || continue
        _root="$(git -C "${_cwd}" rev-parse --show-toplevel 2>/dev/null)" || continue
        _reason="$(_judge "${_root}")"
        [[ -n "${_reason}" ]] && hook_block "${_reason}" \
            "Follow .agents/skills/tdd/SKILL.md: put the test and its implementation in one commit, or commit the failing test alone (RED) and the implementation right after it (GREEN)."
    done < <(hook_subcommands "${_cmd}")
    return 0
}

main "$@"
