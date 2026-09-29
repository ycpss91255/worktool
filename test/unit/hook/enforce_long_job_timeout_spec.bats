#!/usr/bin/env bats
# test/unit/hook/enforce_long_job_timeout_spec.bats - .agents/hook/enforce_long_job_timeout.sh
#
# A long FOREGROUND job (a `just test` tier, script/test/test.sh, an image
# build, a compose service run) must be bounded: run_in_background, the Bash
# timeout param, or a self-wrapped timeout(1). Otherwise the hook blocks
# (exit 2) so a hung gate can never wedge the session. Words inside quoted
# text or a heredoc body (commit messages, PR bodies, files being written)
# are data, not launches.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

# _payload <command> [run_in_background] [timeout]  (JSON literals: null = unset)
_payload() {
    jq -n --arg c "$1" --argjson bg "${2:-null}" --argjson to "${3:-null}" \
        '{tool_name:"Bash", tool_input:({command:$c}
            + (if $bg == null then {} else {run_in_background:$bg} end)
            + (if $to == null then {} else {timeout:$to} end))}'
}

_check() { run_hook enforce_long_job_timeout "$(_payload "$@")"; }

# --- blocked -----------------------------------------------------------------

@test "blocks 'just test unit' with no bound" {
    _check "just test unit"
    assert_failure 2
    assert_output --partial "BLOCKED"
    assert_output --partial "timeout"
}

@test "blocks a bare 'just test' (all six tiers)" {
    _check "just test"
    assert_failure 2
}

@test "blocks the test runner script called directly" {
    _check "./script/test/test.sh --system-real"
    assert_failure 2
}

@test "blocks 'docker build' with no bound" {
    _check "docker build -t x ."
    assert_failure 2
}

@test "blocks a docker compose service run with no bound" {
    _check "docker compose -f compose.yaml run --rm x"
    assert_failure 2
}

@test "blocks an env-prefixed long launch" {
    _check "TEST_IMAGE=x just test lint"
    assert_failure 2
}

@test "still blocks a real long launch after a cd prefix" {
    _check "cd /repo && just test system-real"
    assert_failure 2
}

@test "still blocks a long launch that follows a heredoc" {
    _check "$(printf 'cat > a.txt <<%s\nx\nEOF\njust test unit' "'EOF'")"
    assert_failure 2
}

@test "an unrelated timeout text elsewhere does not bound a long launch" {
    _check "echo timeout 1; just test unit"
    assert_failure 2
    _check "printf 'timeout 1'; docker build ."
    assert_failure 2
}

@test "a timeout(1) on another sub-command does not bound the long one" {
    _check "timeout 5 true && just test unit"
    assert_failure 2
}

# --- allowed -----------------------------------------------------------------

@test "allows 'just test unit' when the timeout param is set" {
    _check "just test unit" null 600000
    assert_success
}

@test "allows 'just test unit' when run_in_background is true" {
    _check "just test unit" true
    assert_success
}

@test "allows a self-wrapped timeout(1) command" {
    _check "timeout 600 just test unit"
    assert_success
}

@test "allows a self-wrapped timeout(1) launch after a cd prefix or a wrapper" {
    _check "cd /repo && timeout 600 just test unit"
    assert_success
    _check "sudo timeout --signal KILL 600 docker build ."
    assert_success
}

@test "allows the quick test help" {
    _check "just test help"
    assert_success
}

@test "allows a short box verb" {
    _check "just box status"
    assert_success
}

@test "blocks a real 'just box assemble' with no bound" {
    _check "just box assemble"
    assert_failure 2
}

@test "allows 'just box assemble --dry-run'" {
    _check "just box assemble --dry-run"
    assert_success
}

@test "allows a git commit whose message contains trigger words" {
    _check "git commit -m 'just test unit; docker build wording'"
    assert_success
}

@test "allows a multi-line cd + git commit with trigger words in the body" {
    _check "$(printf 'cd /repo\ngit add x\ngit commit -m "ran just test and docker build"')"
    assert_success
}

@test "allows a heredoc whose body carries trigger words" {
    _check "$(printf 'cat > spec.bats <<%s\n_check \"just test unit\"\ndocker build -t x .\nEOF' "'EOF'")"
    assert_success
}

@test "allows a short ordinary command" {
    _check "git status"
    assert_success
}

# --- nested launches (codex round 1 on #193) ----------------------------------

@test "blocks a long launch inside a command substitution" {
    local d='$'
    _check "x=${d}(just test unit)"
    assert_failure 2
}

@test "blocks a long launch run through bash -c" {
    _check "bash -c 'just test unit'"
    assert_failure 2
}

@test "allows a timeout(1) that wraps bash -c" {
    _check "timeout 600 bash -c 'cd /r && just test unit'"
    assert_success
}
