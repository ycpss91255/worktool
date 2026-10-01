#!/usr/bin/env bats
# test/matrix/enforce_no_attribution_spec.bats - issue #270's complete
# {attribution x position x source x wrapper} acceptance matrix.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/hook"

setup() {
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "${WORK}"
}

_check() {
    jq -n --arg c "$1" --arg d "${WORK}" \
        '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' >"${WORK}/payload.json"
    run "${HOOK_DIR}/enforce_no_attribution.sh" <"${WORK}/payload.json"
}

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

_sq() {
    local _q="'\\''"
    printf "'%s'" "${1//\'/${_q}}"
}

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

@test "blocks every attribution line, place, source and wrapper" {
    local _a _p _f _w _cmd
    for _a in "${_ATTR[@]}"; do
        for _p in "${_PLACES[@]}"; do
            for _f in commit-m commit-F gh-body gh-body-file; do
                for _w in direct bash-c eval; do
                    _cmd="$(_wrap "${_w}" "$(_launch "${_f}" "$(_message "${_a}" "${_p}")")")"
                    _check "${_cmd}"
                    if [[ "${status}" -ne 2 ]]; then
                        printf 'not blocked (%s): %s\n' "${status}" "${_cmd}" >&3
                        return 1
                    fi
                    [[ "${output}" == *'attribution'* ]] || return 1
                done
            done
        done
    done
}
