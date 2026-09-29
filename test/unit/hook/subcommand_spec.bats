#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/hook/subcommand_spec.bats - .agents/hook/lib/subcommand.sh
#
# hook_subcommands <command> prints the sub-commands a Bash command line
# actually launches, one per line, so a PreToolUse hook can judge each
# launch by its first word instead of pattern-matching the raw text:
#   - heredoc bodies are data (dropped); a here-string is not a heredoc
#   - quoted spans are data (dropped)
#   - split on ; && || | and newlines
#   - leading VAR=val assignments and sudo / env / command / time / nohup /
#     exec wrappers are stripped; timeout(1) is kept (it is a bound the
#     long-job hook must see)
#   - empty pieces are dropped

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    # shellcheck source=../../../.agents/hook/lib/subcommand.sh
    source "${REPO_ROOT}/.agents/hook/lib/subcommand.sh"
}

@test "a single command is one sub-command" {
    run hook_subcommands "just test unit"
    assert_success
    assert_output "just test unit"
}

@test "splits on && || ; | and newlines" {
    run hook_subcommands "$(printf 'cd /repo && a || b; c | d\ne')"
    assert_success
    assert_output "$(printf '%s\n' 'cd /repo' a b c d e)"
}

@test "quoted spans are dropped" {
    run hook_subcommands "git commit -m 'bats; just test' -m \"x && docker build\""
    assert_success
    assert_output "git commit -m  -m"
}

@test "heredoc bodies are dropped, the line after the terminator is kept" {
    run hook_subcommands "$(printf 'cat > f <<%s\nbats test\njust test unit\nEOF\ngit status' "'EOF'")"
    assert_success
    assert_output "$(printf '%s\n' 'cat > f <<' 'git status')"
}

@test "an indented terminator of <<- ends the heredoc" {
    run hook_subcommands "$(printf 'cat <<-END\n\tbats\n\tEND\nls')"
    assert_success
    assert_line --index 1 "ls"
    refute_output --partial "bats"
}

@test "a here-string is not a heredoc" {
    run hook_subcommands "$(printf 'jq . <<<x\nbats t')"
    assert_success
    assert_line --index 1 "bats t"
}

@test "strips env assignments and sudo / env / command / time / nohup / exec" {
    run hook_subcommands "A=1 B=2 sudo env command time nohup exec apt-get install x"
    assert_success
    assert_output "apt-get install x"
}

@test "keeps a timeout(1) wrapper" {
    run hook_subcommands "timeout 600 bats t"
    assert_success
    assert_output "timeout 600 bats t"
}

@test "an empty command prints nothing" {
    run hook_subcommands ""
    assert_success
    assert_output ""
}
