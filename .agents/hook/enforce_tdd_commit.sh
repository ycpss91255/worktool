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
#   BLOCK  tests only, adding more than one @test (one behaviour at a time;
#          a data-driven matrix inside one @test counts as one; an @test
#          line the same commit removes verbatim is a move, not new)
#
#   An --amend is judged as the whole amended commit (its changes since
#   HEAD's parent, which is then the commit that must be RED).
#
#   ALLOW  an --amend with nothing staged (a reword); concluding a merge (MERGE_HEAD exists); docs only (doc/ *.md
#          .agents/memory/ .agents/skills/); anything else
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
    git -C "$1" rev-parse --quiet --verify "$2^{commit}" >/dev/null 2>&1 || return 1
    _k="$(git -C "$1" show --no-renames --name-only --format= "$2" -- 2>/dev/null | _kinds)"
    [[ "${_k}" == *" test "* && "${_k}" != *" product "* ]]
}

# _new_tests <diff> - print how many @test lines the diff adds, not
# counting an added line that the diff also removes verbatim (a move). A
# data-driven matrix inside one @test is one.
_new_tests() {
    awk '
        /^\+\+\+ |^--- / { next }
        /^\+[[:space:]]*@test[[:space:]]/ { add[substr($0, 2)]++ }
        /^-[[:space:]]*@test[[:space:]]/ { del[substr($0, 2)]++ }
        END {
            n = 0
            for (l in add) if (add[l] > del[l]) n += add[l] - del[l]
            print n
        }'
}

# _base <root> <amend> - print the commit the new commit's changes are
# measured from: HEAD, or HEAD's parent for an amend (the empty tree when
# there is none).
_base() {
    local _ref=HEAD
    [[ "$2" -eq 1 ]] && _ref=HEAD~1
    git -C "$1" rev-parse --quiet --verify "${_ref}^{commit}" 2>/dev/null \
        || git -C "$1" hash-object -t tree /dev/null
}

# _judge <root> <amend> - print the block reason for the commit, or nothing.
_judge() {
    local _root="$1" _base _k _n
    # Concluding a merge records work already judged on its own branch.
    git -C "${_root}" rev-parse --quiet --verify MERGE_HEAD >/dev/null && return 0
    # An amend with nothing staged only rewords.
    [[ "$2" -eq 1 ]] && git -C "${_root}" diff --cached --quiet 2>/dev/null && return 0
    _base="$(_base "${_root}" "$2")"
    _k="$(git -C "${_root}" diff --cached --no-renames --name-only "${_base}" | _kinds)"
    if [[ "${_k}" == *" test "* && "${_k}" != *" product "* ]]; then
        _n="$(git -C "${_root}" diff --cached --no-renames "${_base}" -- test/ | _new_tests)"
        [[ "${_n}" -le 1 ]] && return 0
        printf 'this tests-only commit adds %s @test cases; add one behaviour at a time (vertical slices).' "${_n}"
        return 0
    fi
    [[ "${_k}" == *" product "* && "${_k}" != *" test "* ]] || return 0
    _is_red "${_root}" "${_base}" && return 0
    printf '%s' 'this commit touches product code but no test, and its parent is not a RED commit.'
}

# _amends <sub-command> - 0 when the commit launch carries --amend.
_amends() {
    [[ " $1 " == *" --amend "* ]]
}

# _is_commit <sub-command> - 0 when the launch is `git [-C <dir>] commit`.
_is_commit() {
    [[ "$1" =~ ^git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit([[:space:]]|$) ]]
}

main() {
    hook_read_input
    local _cmd _cwd _sub _root _reason _amend
    _cmd="$(hook_command)"
    _cwd="$(hook_field '.cwd')"
    [[ -n "${_cwd}" ]] || _cwd="${PWD}"
    while IFS= read -r _sub; do
        _is_commit "${_sub}" || continue
        _root="$(git -C "${_cwd}" rev-parse --show-toplevel 2>/dev/null)" || continue
        _amend=0
        _amends "${_sub}" && _amend=1
        _reason="$(_judge "${_root}" "${_amend}")"
        [[ -n "${_reason}" ]] && hook_block "${_reason}" \
            "Follow .agents/skills/tdd/SKILL.md: put the test and its implementation in one commit, or commit the failing test alone (RED) and the implementation right after it (GREEN)."
    done < <(hook_subcommands "${_cmd}")
    return 0
}

main "$@"
