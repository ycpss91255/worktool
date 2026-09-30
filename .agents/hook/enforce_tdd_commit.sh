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
#   What the commit records is read from a scratch copy of the index, with
#   every tracked change added for -a / --all, or for a pathspec commit
#   HEAD's tree (the index too with -i / --include) plus the named paths
#   from the work tree (the real index is never touched).
#   An --amend is judged as the whole amended commit (its changes since
#   HEAD's parent, which is then the commit that must be RED).
#
#   ALLOW  an --amend with nothing staged (a reword); concluding a merge
#          (MERGE_HEAD exists); docs only (doc/ *.md .agents/memory/
#          .agents/skills/); anything else
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

# _parse <words...> - read the words after `commit`; set _AMEND, _ALL and
# _INCLUDE (0 / 1) and the pathspec array _PATHS. Options that take a value
# skip it (-m <msg>, -am <msg>, --author <x>; --file=<f> carries its own).
_parse() {
    local _w _k _skip=0 _rest=0
    _AMEND=0 _ALL=0 _INCLUDE=0 _PATHS=()
    for _w in "$@"; do
        if [[ "${_rest}" -eq 1 ]]; then _PATHS+=("${_w}"); continue; fi
        if [[ "${_skip}" -eq 1 ]]; then _skip=0; continue; fi
        case "${_w}" in
            --) _rest=1 ;;
            --amend) _AMEND=1 ;;
            --all) _ALL=1 ;;
            --include) _INCLUDE=1 ;;
            --message|--file|--reuse-message|--reedit-message|--author|--date|--template|--fixup|--squash|--trailer|--cleanup|--pathspec-from-file) _skip=1 ;;
            --*) ;;
            -?*)
                for ((_k = 1; _k < ${#_w}; _k++)); do
                    case "${_w:_k:1}" in
                        a) _ALL=1 ;;
                        i) _INCLUDE=1 ;;
                        [mFCct]) [[ "${_k}" -eq $((${#_w} - 1)) ]] && _skip=1; break ;;
                    esac
                done ;;
            *) _PATHS+=("${_w}") ;;
        esac
    done
}

# _index <dir> <index file> - fill <index file> with the index the commit
# would record: a copy of the real one, plus every tracked change for -a;
# with a pathspec, HEAD's tree (the real index for -i) plus the named paths
# as they are in the work tree.
_index() {
    local _real
    _real="$(git -C "$1" rev-parse --path-format=absolute --git-path index 2>/dev/null)" || return 1
    cp -- "${_real}" "$2" 2>/dev/null || return 1
    if [[ "${#_PATHS[@]}" -gt 0 ]]; then
        if [[ "${_INCLUDE}" -eq 0 ]] && git -C "$1" rev-parse --quiet --verify HEAD >/dev/null 2>&1; then
            GIT_INDEX_FILE="$2" git -C "$1" read-tree HEAD 2>/dev/null || return 1
        fi
        GIT_INDEX_FILE="$2" git -C "$1" add -- "${_PATHS[@]}" 2>/dev/null
        return 0
    fi
    [[ "${_ALL}" -eq 1 ]] || return 0
    GIT_INDEX_FILE="$2" git -C "$1" add -u 2>/dev/null
}

# _words <encoded launch> - print the launch's words after `commit`, decoded,
# one per line.
_words() {
    local -a _w
    local _i
    read -r -a _w <<<"$1"
    for ((_i = 2; _i < ${#_w[@]}; _i++)); do
        hook_word "${_w[_i]}"
        printf '\n'
    done
}

# _check_launch <encoded launch> <cwd> - print the block reason, or nothing.
_check_launch() {
    local _root _idx _reason='' _line
    local -a _args=()
    while IFS= read -r _line; do _args+=("${_line}"); done < <(_words "$1")
    _parse "${_args[@]}"
    _root="$(git -C "$2" rev-parse --show-toplevel 2>/dev/null)" || return 0
    _idx="$(mktemp)" || return 0
    if _index "$2" "${_idx}"; then
        _reason="$(GIT_INDEX_FILE="${_idx}" _judge "${_root}" "${_AMEND}")"
    fi
    rm -f -- "${_idx}"
    printf '%s' "${_reason}"
}

main() {
    hook_read_input
    local _cmd _cwd _sub _reason
    _cmd="$(hook_command)"
    _cwd="$(hook_field '.cwd')"
    [[ -n "${_cwd}" ]] || _cwd="${PWD}"
    while IFS= read -r _sub; do
        [[ "${_sub}" =~ ^git[[:space:]]+commit([[:space:]]|$) ]] || continue
        _reason="$(_check_launch "${_sub}" "${_cwd}")"
        [[ -n "${_reason}" ]] && hook_block "${_reason}" \
            "Follow .agents/skills/tdd/SKILL.md: put the test and its implementation in one commit, or commit the failing test alone (RED) and the implementation right after it (GREEN)."
    done < <(hook_subcommands_raw "${_cmd}")
    return 0
}

main "$@"
