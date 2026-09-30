#!/usr/bin/env bats
# test/unit/hook/enforce_no_attribution_spec.bats -
# .agents/hook/enforce_no_attribution.sh (issue #270)
#
# Commit messages, PR / issue bodies and comments carry no attribution
# line (the table in lib/attribution.sh). The hook reads the PreToolUse
# Bash payload on stdin and blocks (exit 2, reason on stderr) a
# `git commit` whose -m / -F message, or a `gh pr create|edit|comment|
# review` / `gh issue create|edit|comment` whose --body / --body-file
# content, holds one; direct, inside `bash -c` and inside `eval`. A
# message source the hook cannot read (a shell expansion, stdin that is no
# literal here-string, an unreadable file) blocks too (fail closed).
# Everything else, including a message that merely mentions claude, passes
# silently (exit 0).

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "${WORK}"
}

# _check <command> - run the hook on a Bash payload whose cwd is WORK, fed
# on stdin the way Claude Code does. The hook prints nothing on stdout, so
# $output is its stderr.
_check() {
    jq -n --arg c "$1" --arg d "${WORK}" \
        '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' >"${WORK}/payload.json"
    run "${HOOK_DIR}/enforce_no_attribution.sh" <"${WORK}/payload.json"
}

# The three attribution lines (issue #270), and a message body carrying
# one at the given place: first, middle, last, or padded with blanks.
_ATTR=(
    'Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>'
    'Claude-Session: https://claude.ai/code/session_0123'
    'Generated with [Claude Code](https://claude.com/claude-code)'
)
_PLACES=(first middle last padded)

_message() {
    case "$2" in
        first) printf '%s\n\nfix: subject' "$1" ;;
        middle) printf 'fix: subject\n\n%s\n\nmore body' "$1" ;;
        last) printf 'fix: subject\n\nbody\n\n%s' "$1" ;;
        padded) printf 'fix: subject\n\n   %s   \n' "$1" ;;
    esac
}

# _sq <text> - <text> as one single-quoted shell word.
_sq() {
    local _q="'\\''"
    printf "'%s'" "${1//\'/${_q}}"
}

# The launches, each built from a message; the file forms write it first.
_launch() {
    local _form="$1" _msg="$2"
    printf '%s' "${_msg}" >"${WORK}/msg.txt"
    case "${_form}" in
        commit-m) printf 'git commit -m %s' "$(_sq "${_msg}")" ;;
        commit-F) printf 'git commit -F msg.txt' ;;
        gh-body) printf 'gh pr create -R ycpss91255/worktool --title t --body %s' "$(_sq "${_msg}")" ;;
        gh-body-file) printf 'gh issue comment 5 -R ycpss91255/worktool --body-file msg.txt' ;;
    esac
}

_wrap() {
    case "$1" in
        direct) printf '%s' "$2" ;;
        bash-c) printf 'bash -c %s' "$(_sq "$2")" ;;
        eval) printf 'eval %s' "$(_sq "$2")" ;;
    esac
}

# --- representative matrix cases -------------------------------------------

@test "blocks representative attribution lines across every place, source and wrapper" {
    local _case _a _p _f _w _cmd
    for _case in \
        '0 first commit-m direct' \
        '1 middle commit-F bash-c' \
        '2 last gh-body eval' \
        '0 padded gh-body-file direct'; do
        read -r _a _p _f _w <<<"${_case}"
        _cmd="$(_wrap "${_w}" "$(_launch "${_f}" "$(_message "${_ATTR[_a]}" "${_p}")")")"
        _check "${_cmd}"
        assert_equal "${status}" 2
        [[ "${output}" == *'attribution'* ]]
    done
}

@test "lets a message that only mentions claude through, every source and wrapper" {
    local _f _w _cmd _msg
    _msg="$(printf 'fix(hook): let claude read the co-authored-by rule\n\nThe Claude Code session keeps generated files.')"
    for _f in commit-m commit-F gh-body gh-body-file; do
        for _w in direct bash-c eval; do
            _cmd="$(_wrap "${_w}" "$(_launch "${_f}" "${_msg}")")"
            _check "${_cmd}"
            if [[ "${status}" -ne 0 ]]; then
                printf 'blocked (%s): %s\n%s\n' "${status}" "${_cmd}" "${output}" >&3
                return 1
            fi
        done
    done
}

# --- fail closed -------------------------------------------------------------

@test "blocks a message the hook cannot read (fail closed)" {
    local _d='$' _cmd
    for _cmd in \
        "git commit -m \"${_d}(cat msg.txt)\"" \
        "git commit -m \"${_d}MSG\"" \
        "git commit -F ${_d}F" \
        'git commit -F -' \
        'git commit -F missing.txt' \
        "gh pr comment 3 --body \"${_d}B\"" \
        'gh issue create --title t --label bug --body-file missing.txt' \
        'gh pr create --title t --body-file - < msg.txt'; do
        _check "${_cmd}"
        if [[ "${status}" -ne 2 || "${output}" != *'fail closed'* ]]; then
            printf 'not blocked (%s): %s\n' "${status}" "${_cmd}" >&3
            return 1
        fi
    done
}

# --- other launches ----------------------------------------------------------

@test "reads a literal here-string / heredoc stdin for -F - and --body-file -" {
    local _a="${_ATTR[0]}"
    _check "git commit -F - <<< $(_sq "$(printf 'fix: x\n\n%s' "${_a}")")"
    assert_equal "${status}" 2
    _check "$(printf 'gh pr comment 3 --body-file - <<%s\nfix\n\n%s\n%s' "'EOF'" "${_a}" EOF)"
    assert_equal "${status}" 2
    _check "git commit -F - <<< 'fix: clean'"
    assert_equal "${status}" 0
}

@test "reads every spelling: -mMSG, -am, --message=, -F with -C dir, gh -R before the group" {
    local _a="${_ATTR[1]}" _cmd
    mkdir -p "${WORK}/sub"
    printf 'x\n%s\n' "${_a}" >"${WORK}/sub/m.txt"
    for _cmd in \
        "git commit $(_sq "-m${_a}")" \
        "git commit -am $(_sq "${_a}")" \
        "git commit $(_sq "--message=${_a}")" \
        "git commit -m ok -m $(_sq "${_a}")" \
        'git -C sub commit -F m.txt' \
        'git commit --file=sub/m.txt' \
        "gh -R ycpss91255/worktool issue edit 5 $(_sq "--body=${_a}")" \
        "gh pr review 3 --comment -b $(_sq "${_a}")" \
        'gh issue comment 5 -F sub/m.txt' \
        "timeout 60 gh pr edit 3 --body $(_sq "${_a}")"; do
        _check "${_cmd}"
        if [[ "${status}" -ne 2 ]]; then
            printf 'not blocked (%s): %s\n' "${status}" "${_cmd}" >&3
            return 1
        fi
    done
}

@test "lets unrelated launches and text that only mentions an attribution through" {
    local _a="${_ATTR[0]}" _cmd
    for _cmd in \
        "echo $(_sq "${_a}")" \
        "grep -n $(_sq "${_a}") README.md" \
        'gh pr view 3 --json body' \
        'gh issue close 5' \
        'git log --format=%B -n 1' \
        'git commit --amend --no-edit' \
        'git commit' \
        ''; do
        _check "${_cmd}"
        if [[ "${status}" -ne 0 ]]; then
            printf 'blocked (%s): %s\n%s\n' "${status}" "${_cmd}" "${output}" >&3
            return 1
        fi
    done
}
