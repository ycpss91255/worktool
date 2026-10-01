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

@test "hook_word_has_expansion marks every expansion the shell resolves, not quoted text" {
    local d='$' b='`' w _i
    run hook_subcommands_raw "gh x ${d}A \"${d}A\" ${d}{A} p/${d}1 *.md f? [ab] {a,b} {1..3} ${d}'z' ${d}(a) \"${b}c${b}\""
    read -r -a w <<<"${lines[0]}"
    for _i in 2 3 4 5 6 7 8 9 10 11 12 13; do
        run hook_word_has_expansion "${w[_i]}"
        assert_success
    done
    run hook_subcommands_raw "gh x '${d}A' \\${d}A \"*\" [ ]] {owner}/{repo} \"${d}\" ${d}"
    read -r -a w <<<"${lines[0]}"
    for _i in 2 3 4 5 6 7 8 9; do
        run hook_word_has_expansion "${w[_i]}"
        assert_failure
    done
}

@test "an expansion keeps its text in hook_word and hook_subcommands" {
    local d='$'
    run hook_subcommands_raw "gh x \"${d}A\" *.md"
    read -r -a w <<<"${lines[0]}"
    run hook_word "${w[2]}"
    assert_output "${d}A"
    run hook_word "${w[3]}"
    assert_output "*.md"
    run hook_subcommands "echo ${d}A *.md"
    assert_output "echo ${d}A *.md"
}

@test "an expansion of the outer shell stays marked inside a bash -c / eval script" {
    local d='$' w
    run hook_subcommands_raw "bash -c \"gh pr comment 7 --body '${d}B'\""
    read -r -a w <<<"${lines[0]}"
    run hook_word_has_expansion "${w[5]}"
    assert_success
    run hook_word "${w[5]}"
    assert_output "${d}B"
    run hook_subcommands_raw "eval \"${d}CMD\""
    read -r -a w <<<"${lines[0]}"
    run hook_word_has_expansion "${w[0]}"
    assert_success
    run hook_subcommands_raw "bash -c 'gh pr view \"${d}(printf 7)\"'"
    assert_line --index 0 --partial "gh pr view"
}

@test "a heredoc a shell reads as its script is launched; one fed to a non-shell stays data" {
    run hook_subcommands "$(printf "sh <<'EOF'\ngh pr merge 7\nEOF\ngit status")"
    assert_success
    assert_output "$(printf '%s\n' 'gh pr merge 7' 'git status')"
    run hook_subcommands "$(printf "env bash -s <<-END\n\tbats t\n\tEND")"
    assert_output "bats t"
    run hook_subcommands "$(printf "bash <<< 'bats t'")"
    assert_output "bats t"
    run hook_subcommands "$(printf "cat <<EOF\nbats t\nEOF")"
    assert_output "cat <<EOF"
    run hook_subcommands "$(printf "bash x.sh <<EOF\nbats t\nEOF")"
    assert_output "bash x.sh <<EOF"
}

@test "an unquoted heredoc delimiter marks the body's expansions; a quoted one does not" {
    local d='$' w
    run hook_subcommands_raw "$(printf "bash <<EOF\ngh x '%sB'\nEOF" "${d}")"
    read -r -a w <<<"${lines[0]}"
    run hook_word_has_expansion "${w[2]}"
    assert_success
    run hook_word "${w[2]}"
    assert_output "${d}B"
    run hook_subcommands_raw "$(printf "bash <<'EOF'\ngh x '%sB'\nEOF" "${d}")"
    read -r -a w <<<"${lines[0]}"
    run hook_word_has_expansion "${w[2]}"
    assert_failure
    run hook_subcommands_raw "$(printf 'bash <<EOF\ngh x \\%sB\nEOF' "${d}")"
    read -r -a w <<<"${lines[0]}"
    run hook_word_has_expansion "${w[2]}"
    assert_success
}

@test "a heredoc delimiter may be any shell word; the terminator is the exact line" {
    run hook_subcommands "$(printf "cat <<'END-X'\nbats a\nEND-X\nls")"
    assert_line --index 1 "ls"
    refute_output --partial "bats"
    run hook_subcommands "$(printf 'cat <<"a.b"\nbats a\na.b\nls')"
    assert_line --index 1 "ls"
    refute_output --partial "bats"
    run hook_subcommands "$(printf 'cat <<EOF\n EOF\nbats a\nEOF\nls')"
    assert_output "$(printf '%s\n' 'cat <<EOF' 'ls')"
}

@test "fish with valued options and busybox sh read their heredoc / -c script" {
    run hook_subcommands "$(printf "fish -C true <<'EOF'\nbats t\nEOF")"
    assert_output "bats t"
    run hook_subcommands "$(printf "fish --init-command true <<'EOF'\nbats t\nEOF")"
    assert_output "bats t"
    run hook_subcommands "$(printf "busybox sh <<'EOF'\nbats t\nEOF")"
    assert_output "bats t"
    run hook_subcommands "busybox sh -c 'bats t'"
    assert_output "bats t"
}

@test "hook_is_interpreter names the non-shell interpreters" {
    local _w
    for _w in python3 python3.12 /usr/bin/python perl ruby node nodejs php gawk awk lua Rscript; do
        run hook_is_interpreter "${_w}"
        assert_success
    done
    for _w in bash gh git cat python-config; do
        run hook_is_interpreter "${_w}"
        assert_failure
    done
}

@test "a heredoc fed to a non-shell interpreter becomes a here-string word of its launch" {
    run hook_subcommands "$(printf "python3 - <<'EOF'\nprint(1)\nEOF\nls")"
    assert_line --index 0 --partial "python3 - <<<print"
    assert_line --index 1 "ls"
}

@test "matrix: every control byte round-trips exactly in single quotes, double quotes and unquoted" {
    # No in-band sentinel: no input byte may be taken for a marker. 0x09 and
    # 0x0a are shell syntax when unquoted (IFS, command separator).
    local _b _c _ctx _cmd _out _MISS=''
    local -a w
    for _b in $(seq 1 31) 127; do
        printf -v _c '%b' "\\0$(printf '%03o' "${_b}")"
        for _ctx in single double bare; do
            case "${_ctx}" in
                single) _cmd="echo 'a${_c}b'" ;;
                double) _cmd="echo \"a${_c}b\"" ;;
                bare)
                    [[ "${_b}" -eq 9 || "${_b}" -eq 10 ]] && continue
                    _cmd="echo a${_c}b" ;;
            esac
            _out="$(hook_subcommands_raw "${_cmd}")"
            read -r -a w <<<"${_out%%$'\n'*}"
            if [[ "$(hook_word "${w[1]:-}")" != "a${_c}b" ]] || hook_word_has_expansion "${w[1]:-}" \
                || [[ "${#w[@]}" -ne 2 ]]; then
                _MISS+="byte=$(printf '0x%02x' "${_b}") context=${_ctx}"$'\n'
            fi
        done
    done
    [[ -z "${_MISS}" ]] || fail "$(printf 'control bytes that did not round-trip:\n%s' "${_MISS}")"
}

# _scripts <command> - hook_scripts output, NUL ends turned into "<END>"
# lines so bats can compare it.
_scripts() {
    local _script
    while IFS= read -r -d '' _script; do
        printf '%s<END>' "${_script}"
    done < <(hook_scripts "$1")
}

@test "hook_scripts prints the command itself when it runs no nested script" {
    run _scripts "gh issue create --title x"
    assert_success
    assert_output "gh issue create --title x<END>"
}

@test "hook_scripts prints the script of bash -c / eval with its heredoc kept" {
    run _scripts "$(printf "bash -c \"gh issue create -F - <<'EOF'\nmilestone: x\nEOF\"")"
    assert_success
    assert_output "$(printf "bash -c \"gh issue create -F - <<'EOF'\nmilestone: x\nEOF\"<END>gh issue create -F - <<'EOF'\nmilestone: x\nEOF<END>")"
    run _scripts "eval 'cat b.md | gh issue create -F -'"
    assert_output "eval 'cat b.md | gh issue create -F -'<END>cat b.md | gh issue create -F -<END>"
}

@test "hook_scripts follows nesting and a leading timeout / wrapper" {
    run _scripts "timeout 5 sudo bash -c \"eval 'gh issue create'\""
    assert_success
    assert_output "timeout 5 sudo bash -c \"eval 'gh issue create'\"<END>eval 'gh issue create'<END>gh issue create<END>"
}

@test "hook_scripts prints the script a shell reads from a heredoc" {
    run _scripts "$(printf "bash <<'X'\ngh issue create -F - <<'EOF'\nmilestone: x\nEOF\nX")"
    assert_success
    assert_output "$(printf "bash <<'X'\ngh issue create -F - <<'EOF'\nmilestone: x\nEOF\nX<END>gh issue create -F - <<'EOF'\nmilestone: x\nEOF<END>")"
}

@test "case patterns do not launch alternatives but arm bodies still launch" {
    run hook_subcommands "case \"\$x\" in foo|bats) echo ok;; (bats|bar) bats t;; esac; ls"
    assert_success
    assert_output "$(printf '%s\n' "case \$x in _" 'echo ok' 'bats t' 'ls')"
}

@test "arithmetic commands do not launch expressions but following commands still launch" {
    run hook_subcommands '(( bats = 1 )); (( x = (bats | 2) && 3 )); bats t'
    assert_success
    assert_output 'bats t'
}

@test "a case word in command arguments does not hide a pipeline launch" {
    run hook_subcommands 'echo case x in foo | bats t'
    assert_success
    assert_output "$(printf '%s\n' 'echo case x in foo' 'bats t')"
}
