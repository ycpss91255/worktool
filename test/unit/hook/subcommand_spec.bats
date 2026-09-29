#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/hook/subcommand_spec.bats - .agents/hook/lib/subcommand.sh
#
# hook_subcommands <command> prints the sub-commands a Bash command line
# launches, one per line, so a PreToolUse hook can judge each
# launch by its first word instead of pattern-matching the raw text:
#   - heredoc bodies are data (dropped); a here-string is not a heredoc
#   - a quoted span is one opaque word (quotes removed; its whitespace and
#     separators become '_'), so it splits nothing and a quoted executable
#     name is still seen
#   - split on ; && || | newlines, a background & and ( ), and the reserved
#     words of a compound command (if / while / do / { ... ) are stripped,
#     so a subshell, a group or an if / loop body is launched like any other
#     command; an array assignment's list is data
#   - the body of $(...), backticks, <(...) and a bash -c / eval script is
#     launched too
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

# --- nested launches (codex round 1 on #193) ----------------------------------
# '$' and the backtick are assembled at run time so ShellCheck sees no live
# expansion inside single quotes; the runtime strings carry the real syntax.

@test "a \$(...) command substitution is its own sub-command" {
    local d='$'
    run hook_subcommands "x=${d}(bats test/unit)"
    assert_success
    assert_output "bats test/unit"
}

@test "a \$(...) inside double quotes is still launched" {
    local d='$'
    run hook_subcommands "echo \"a ${d}(just test unit) b\""
    assert_success
    assert_output "$(printf '%s\n' 'echo a___b' 'just test unit')"
}

@test "a \$(...) inside single quotes is data" {
    local d='$'
    run hook_subcommands "git commit -m '${d}(bats t)'"
    assert_success
    assert_output "git commit -m ${d}_bats_t_"
}

@test "nested \$(...) and a subshell inside it are seen" {
    local d='$'
    run hook_subcommands "a ${d}(b ${d}(bats t) (c))"
    assert_success
    assert_line "bats t"
    assert_line --partial "b _"
    assert_line "a _"
}

@test "a backtick substitution is its own sub-command" {
    local b=$'\x60'
    run hook_subcommands "x=${b}bats test/unit${b}; ls"
    assert_success
    assert_output "$(printf '%s\n' 'ls' 'bats test/unit')"
}

@test "a process substitution is its own sub-command" {
    run hook_subcommands "diff <(bats t) f"
    assert_success
    assert_output "$(printf '%s\n' 'diff _ f' 'bats t')"
}

@test "bash -c / sh -lc run their script: it is split like a command line" {
    run hook_subcommands "bash -c 'bats test/unit'"
    assert_success
    assert_output "bats test/unit"
    run hook_subcommands "sudo sh -lc \"cd /r && just test unit\" arg0"
    assert_success
    assert_output "$(printf '%s\n' 'cd /r' 'just test unit')"
}

@test "eval runs its words as a command line" {
    run hook_subcommands "eval 'bats t; ls'"
    assert_success
    assert_output "$(printf '%s\n' 'bats t' 'ls')"
}

@test "a timeout(1) before bash -c bounds every launch of its script" {
    run hook_subcommands "timeout 600 bash -c 'cd /r && just test unit'"
    assert_success
    assert_output "$(printf '%s\n' 'timeout 600 cd /r' 'timeout 600 just test unit')"
}

@test "a timeout(1) with valued options before bash -c still bounds its script" {
    local _t
    for _t in "timeout -k 5 60" "timeout --signal TERM 60" "timeout -s 9 60" \
        "gtimeout --kill-after=5 --preserve-status 60"; do
        run hook_subcommands "${_t} bash -c 'cd /r && just test unit'"
        assert_success
        assert_output "$(printf '%s\n' "${_t} cd /r" "${_t} just test unit")"
    done
}

@test "hook_timeout_lead prints a leading timeout(1) with its options and duration" {
    run hook_timeout_lead "timeout -k 5 --signal TERM 60 gh pr merge 7"
    assert_success
    assert_output "timeout -k 5 --signal TERM 60 "
    run hook_timeout_lead "gh pr merge 7"
    assert_success
    assert_output ""
}

@test "bash without -c runs a script file and is kept as is" {
    run hook_subcommands "bash script/x.sh -c y"
    assert_success
    assert_output "bash script/x.sh -c y"
}

# --- compound commands (codex round 2 on #193) ---------------------------------

@test "a subshell ( ... ) launches its body" {
    run hook_subcommands "(bats t)"
    assert_success
    assert_output "bats t"
    run hook_subcommands "ls && (cd /r; bats t)"
    assert_success
    assert_output "$(printf '%s\n' 'ls' 'cd /r' 'bats t')"
}

@test "a group { ...; } launches its body" {
    run hook_subcommands "{ bats t; }"
    assert_success
    assert_output "bats t"
}

@test "if / while / until bodies and conditions are launched" {
    run hook_subcommands "if true; then bats t; elif ls; then just test; else ! bats u; fi"
    assert_success
    assert_output "$(printf '%s\n' 'true' 'bats t' 'ls' 'just test' 'bats u')"
    run hook_subcommands "while x; do bats t; done; until y; do just test; done"
    assert_success
    assert_output "$(printf '%s\n' 'x' 'bats t' 'y' 'just test')"
}

@test "a for loop and a case arm launch their bodies" {
    run hook_subcommands "for f in a b; do bats \"\${f}\"; done"
    assert_success
    assert_line "bats \${f}"
    run hook_subcommands "case x in a) bats t;; esac"
    assert_success
    assert_line "bats t"
}

@test "a background & separates launches, a redirection & does not" {
    run hook_subcommands "bats t & ls"
    assert_success
    assert_output "$(printf '%s\n' 'bats t' 'ls')"
    run hook_subcommands "just test unit 2>&1 >/dev/null &>x"
    assert_success
    assert_output "just test unit 2>&1 >/dev/null &>x"
}

@test "quoted parentheses and braces stay data" {
    run hook_subcommands "git commit -m '(bats t) { bats u; }'"
    assert_success
    assert_output "git commit -m _bats_t__{_bats_u__}"
}

@test "an array assignment's list is data, not a subshell" {
    run hook_subcommands "a=(bats t); ls"
    assert_success
    assert_output "ls"
}

@test "hook_subcommands_raw keeps each opaque word encoded for hook_word" {
    local d='$' w
    run hook_subcommands_raw "ls && gh pr comment 3 --body 'a b;c'"
    assert_success
    assert_line --index 0 "ls"
    read -r -a w <<<"${lines[1]}"
    run hook_word "${w[5]}"
    assert_output "a b;c"
    run hook_subcommands_raw "gh pr comment 3 --body \"x ${d}(cat f)\""
    read -r -a w <<<"${lines[0]}"
    run hook_word_has_subst "${w[5]}"
    assert_success
    run hook_word "${w[5]}"
    assert_output "x _"
}

@test "hook_word_has_bare_subst tells an unquoted substitution from a quoted one" {
    local d='$' b='`' w _i
    run hook_subcommands_raw "gh x ${d}(a) \"${d}(b)\" ${b}c${b} \"${b}d${b}\" p/${d}(e) \"p/${d}(f)\" <(g) '${d}(h)'"
    read -r -a w <<<"${lines[0]}"
    for _i in 2 4 6; do
        run hook_word_has_bare_subst "${w[_i]}"
        assert_success
        run hook_word_has_subst "${w[_i]}"
        assert_success
    done
    for _i in 3 5 7 8; do
        run hook_word_has_bare_subst "${w[_i]}"
        assert_failure
        run hook_word_has_subst "${w[_i]}"
        assert_success
    done
    run hook_word_has_subst "${w[9]}"
    assert_failure
    run hook_word "${w[6]}"
    assert_output "p/_"
    run hook_subcommands "gh x ${d}(a) \"${d}(b)\""
    assert_line --index 0 "gh x _ _"
}
