#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/hook/subcommand_spec.bats - .agents/hook/lib/subcommand.sh
#
# hook_subcommands <command> prints the sub-commands a Bash command line
# actually launches, one per line, so a PreToolUse hook can judge each
# launch by its first word instead of pattern-matching the raw text:
#   - heredoc bodies are data (dropped); a here-string is not a heredoc
#   - a quoted span is one opaque word (quotes removed; its whitespace and
#     separators become '_'), so it splits nothing and a quoted executable
#     name is still seen
#   - split on ; && || | and newlines
#   - leading VAR=val assignments and sudo / env / command / time / nohup /
#     exec wrappers (with their options) are stripped; timeout(1) is kept (it is a bound the
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

@test "a quoted span is one opaque word: its separators split nothing" {
    run hook_subcommands "git commit -m 'bats; just test' -m \"x && docker build\""
    assert_success
    assert_output "git commit -m bats__just_test -m x____docker_build"
}

@test "a quoted executable name is unquoted, so it is still seen" {
    run hook_subcommands "\"bats\" t; 'just' test; b\"at\"s u"
    assert_success
    assert_output "$(printf '%s\n' 'bats t' 'just test' 'bats u')"
}

@test "a multi-line quoted argument stays inside its sub-command" {
    run hook_subcommands "$(printf 'git commit -m "a\nbats t"\nls')"
    assert_success
    assert_output "$(printf '%s\n' 'git commit -m a_bats_t' 'ls')"
}

@test "strips wrapper options and their values" {
    run hook_subcommands "sudo -u root -E -- env -i -u HOME -C /tmp A=1 time -p nohup exec -a n bats t"
    assert_success
    assert_output "bats t"
}

@test "strips long wrapper options with and without =" {
    run hook_subcommands "sudo --user root --preserve-env env --unset=HOME bats t"
    assert_success
    assert_output "bats t"
}

@test "command -v is a lookup and is kept as is" {
    run hook_subcommands "command -v bats"
    assert_success
    assert_output "command -v bats"
}

@test "heredoc bodies are dropped, the line after the terminator is kept" {
    run hook_subcommands "$(printf 'cat > f <<%s\nbats test\njust test unit\nEOF\ngit status' "'EOF'")"
    assert_success
    assert_output "$(printf '%s\n' 'cat > f <<EOF' 'git status')"
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
