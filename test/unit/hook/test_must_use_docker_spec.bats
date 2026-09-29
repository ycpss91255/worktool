#!/usr/bin/env bats
# test/unit/hook/test_must_use_docker_spec.bats - .agents/hook/test-must-use-docker.sh
#
# worktool rule (AGENTS.md git conventions): tests run ONLY in Docker, and
# only through the user interface `just test <tier>`. So the hook BLOCKS
# (exit 2) a host-side `bats`, a direct script/test/test.sh run (host step
# or the container-side --ci-* gate), a hand-rolled `docker run ... bats`,
# and a host package install; `just test ...` and commands that merely
# carry the words as text pass (exit 0). Driven as a subprocess with the
# stdin JSON payload, the way Claude Code invokes it.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() { run_hook test-must-use-docker "$(hook_json "$1")"; }

# --- blocked -----------------------------------------------------------------

@test "blocks a bare 'bats' run on the host and points at just test" {
    _check "bats test/unit/log_spec.bats"
    assert_failure 2
    assert_output --partial "BLOCKED"
    assert_output --partial "just test"
}

@test "blocks bats after a cd prefix" {
    _check "cd /repo && bats -r test/unit"
    assert_failure 2
}

@test "blocks bats behind a timeout(1) wrapper" {
    _check "timeout 600 bats test/unit"
    assert_failure 2
}

@test "blocks a quoted bats executable (\"bats\" is still bats)" {
    _check '"bats" test/unit'
    assert_failure 2
    _check "'bats' test/unit"
    assert_failure 2
}

@test "blocks bats behind command with a quoted name" {
    _check 'command "bats" test/unit'
    assert_failure 2
}

@test "blocks bats behind sudo with options (sudo -u root)" {
    _check "sudo -u root bats test/unit"
    assert_failure 2
    _check "sudo -E -- bats test/unit"
    assert_failure 2
}

@test "blocks bats behind env with options (env -i / env -u)" {
    _check "env -i bats test/unit"
    assert_failure 2
    _check "env -u HOME PATH=/usr/bin bats test/unit"
    assert_failure 2
}

@test "blocks bats behind a timeout(1) and a sudo wrapper together" {
    _check "timeout 600 sudo -u root bats test/unit"
    assert_failure 2
}

@test "blocks the container-side gate run on the host (test.sh --ci-unit)" {
    _check "./script/test/test.sh --ci-unit"
    assert_failure 2
    assert_output --partial "just test"
}

@test "blocks a direct test.sh host step instead of just test" {
    _check "./script/test/test.sh --unit"
    assert_failure 2
}

@test "blocks 'bash script/test/test.sh'" {
    _check "bash script/test/test.sh --lint"
    assert_failure 2
}

@test "blocks a hand-rolled docker run of bats" {
    _check "docker run --rm -v /repo:/source -w /source worktool-test:local bats test/unit"
    assert_failure 2
}

@test "blocks host 'sudo apt install'" {
    _check "sudo apt install ripgrep"
    assert_failure 2
    assert_output --partial "apt"
}

@test "blocks bare 'apt-get install' without sudo" {
    _check "apt-get install -y fzf"
    assert_failure 2
}

# --- allowed -----------------------------------------------------------------

@test "allows 'just test unit'" {
    _check "just test unit"
    assert_success
    assert_output ""
}

@test "allows a bare 'just test' (every tier)" {
    _check "just test"
    assert_success
}

@test "allows 'just test lint' after a cd prefix" {
    _check "cd /repo && just test lint"
    assert_success
}

@test "allows a git commit whose message mentions bats and test.sh" {
    _check "git commit -m 'never run bats or ./script/test/test.sh --ci-unit on the host'"
    assert_success
}

@test "allows a quoted message whose separators hide a bats word" {
    _check 'git commit -m "fix; bats test/unit && env -i bats"'
    assert_success
}

@test "allows 'command -v bats' (a lookup, not a launch)" {
    _check "command -v bats"
    assert_success
}

@test "allows reading or grepping the test runner" {
    _check "grep -n bats script/test/test.sh"
    assert_success
    _check "cat script/test/test.sh"
    assert_success
}

@test "allows a heredoc whose body mentions bats" {
    _check "$(printf 'cat > note.md <<%s\nrun bats in docker\n%s' "'EOF'" "EOF")"
    assert_success
}

@test "allows 'apt-get update' (read-only, not a mutation)" {
    _check "sudo apt-get update"
    assert_success
}

@test "allows an empty command" {
    _check ""
    assert_success
}
