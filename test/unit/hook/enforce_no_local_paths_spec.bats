#!/usr/bin/env bats
# test/unit/hook/enforce_no_local_paths_spec.bats - .agents/hook/enforce_no_local_paths.sh
#
# The repo is public (issue #233): a comment / PR / issue body an agent
# posts through gh must not carry a machine-local absolute path (a home
# directory, a Claude scratchpad, /root/). The hook BLOCKS (exit 2, reason
# on stderr) such a body, whether it is inline (--body / -b / --comment),
# read from a file (--body-file / -F, gh api -F body=@file / --input) or fed
# by a heredoc. The generic example /home/me/ and repo-relative paths pass.
# The closed rule of #190 applies: a body or body file the hook cannot read
# literally (a shell expansion, stdin without a heredoc, a missing file)
# blocks. A command that launches no relevant gh passes silently.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() { run_hook enforce_no_local_paths "$(hook_json "$1")"; }

# _check_cwd <cwd> <command> - the payload carries the session's cwd.
_check_cwd() {
    run_hook enforce_no_local_paths "$(jq -n --arg c "$2" --arg d "$1" \
        '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
}

_blocked() {
    assert_failure 2
    assert_output --partial "BLOCKED"
}

# A '$' kept out of the literal so ShellCheck sees no live expansion.
D='$'

# --- inline bodies -------------------------------------------------------------

@test "blocks a home directory path in an inline --body" {
    _check "gh pr comment 3 -R ycpss91255/worktool --body 'see /home/alice/proj/lib/log.sh:12'"
    _blocked
    assert_output --partial "/home/alice/"
    assert_output --partial "repo-relative"
}

@test "blocks a macOS home path in -b" {
    _check "gh issue comment 5 -R ycpss91255/worktool -b 'at /Users/bob/x.sh'"
    _blocked
    assert_output --partial "/Users/bob/"
}

@test "blocks a Claude scratchpad path in --body=" {
    _check "gh pr comment 3 --body='/tmp/claude-1000/abc/scratchpad/tree/lib/x.sh:4'"
    _blocked
    assert_output --partial "/tmp/claude-1000/"
}

@test "blocks /root/ in an attached -b value" {
    _check "gh pr review 3 --comment -b'check /root/.bashrc'"
    _blocked
    assert_output --partial "/root/"
}

@test "blocks a local path in the --comment of gh pr close" {
    _check "gh pr close 3 --comment 'moved to /home/alice/x'"
    _blocked
}

@test "blocks a local path in a gh api -f body= field" {
    _check "gh api repos/ycpss91255/worktool/issues/1/comments -f 'body=see /home/alice/x'"
    _blocked
}

# --- allowed -------------------------------------------------------------------

@test "allows the generic example /home/me/" {
    _check "gh pr comment 3 --body 'e.g. /home/me/.config/worktool'"
    assert_success
    assert_output ""
}

@test "allows repo-relative paths and paths that merely end in root/ or home/" {
    _check "gh pr comment 3 --body 'lib/log.sh:12 and src/root/x and https://e.x/home/alice/'"
    assert_success
    assert_output ""
}

@test "allows a local path outside any gh body (cd, redirect, git, echo)" {
    _check "cd /home/alice/w && git commit -m 'x /home/alice/y' && gh pr diff 3 > /home/alice/p.diff"
    assert_success
    assert_output ""
}

@test "allows a gh subcommand that posts nothing" {
    _check "gh pr view 3 --json body --jq '/home/alice/'"
    assert_success
}

# --- body files ----------------------------------------------------------------

@test "blocks a local path inside a --body-file" {
    printf 'line\nsee /home/alice/proj/x.sh\n' > "${BATS_TEST_TMPDIR}/b.md"
    _check "gh pr create --repo ycpss91255/worktool --title t --body-file ${BATS_TEST_TMPDIR}/b.md"
    _blocked
    assert_output --partial "b.md"
}

@test "blocks a local path inside an issue -F body file" {
    printf '/tmp/claude-1000/s/tree/x\n' > "${BATS_TEST_TMPDIR}/b.md"
    _check "gh issue create -R ycpss91255/worktool -t x -l bug -F '${BATS_TEST_TMPDIR}/b.md'"
    _blocked
}

@test "allows a clean body file, even when its own path is local" {
    printf 'lib/log.sh:12 and /home/me/\n' > "${BATS_TEST_TMPDIR}/b.md"
    _check "gh pr comment 3 --body-file ${BATS_TEST_TMPDIR}/b.md"
    assert_success
    assert_output ""
}

@test "reads a relative body file from the payload cwd" {
    printf 'see /home/alice/x\n' > "${BATS_TEST_TMPDIR}/b.md"
    _check_cwd "${BATS_TEST_TMPDIR}" "gh pr comment 3 --body-file b.md"
    _blocked
}

@test "reads a relative body file from a preceding cd" {
    mkdir -p "${BATS_TEST_TMPDIR}/sub"
    printf 'see /Users/bob/x\n' > "${BATS_TEST_TMPDIR}/sub/b.md"
    _check_cwd "/" "cd ${BATS_TEST_TMPDIR}/sub && gh pr comment 3 --body-file b.md"
    _blocked
}

@test "blocks a gh api -F body=@file carrying a local path" {
    printf 'see /home/alice/x\n' > "${BATS_TEST_TMPDIR}/b.md"
    _check "gh api repos/ycpss91255/worktool/issues/1/comments -F body=@${BATS_TEST_TMPDIR}/b.md"
    _blocked
}

@test "blocks a gh api --input file carrying a local path" {
    printf '{"body":"see /home/alice/x"}\n' > "${BATS_TEST_TMPDIR}/b.json"
    _check "gh api repos/ycpss91255/worktool/issues/1/comments --input ${BATS_TEST_TMPDIR}/b.json"
    _blocked
}

# --- heredocs ------------------------------------------------------------------

@test "blocks a local path in a heredoc fed to a gh body" {
    _check "$(printf "gh api repos/o/r/issues/1/comments --input - <<'EOF'\n{\"body\":\"/home/alice/x\"}\nEOF")"
    _blocked
}

@test "allows a clean heredoc fed to a gh body" {
    _check "$(printf "gh api repos/o/r/issues/1/comments --input - <<'EOF'\n{\"body\":\"lib/x.sh\"}\nEOF")"
    assert_success
}

# --- closed rule ---------------------------------------------------------------

@test "blocks an inline body holding a variable (cannot be read statically)" {
    _check "gh pr comment 3 --body \"${D}MSG\""
    _blocked
    assert_output --partial "literal"
}

@test "blocks an inline body holding a command substitution" {
    _check "gh pr comment 3 --body \"${D}(cat /tmp/b.md)\""
    _blocked
}

@test "blocks a body file path holding a variable" {
    _check "gh pr comment 3 --body-file \"${D}F\""
    _blocked
}

@test "blocks a body file the hook cannot read" {
    _check "gh pr comment 3 --body-file ${BATS_TEST_TMPDIR}/missing.md"
    _blocked
    assert_output --partial "cannot read"
}

@test "blocks a stdin body without a heredoc" {
    _check "printf x | gh pr comment 3 --body-file -"
    _blocked
}

@test "blocks a stdin body when the heredoc feeds another command" {
    _check "$(printf '%s\n' 'cat <<EOF >/dev/null' lib/x EOF "printf \"${D}BODY\" | gh pr comment 3 --body-file -")"
    _blocked
    assert_output --partial "literal"
}

@test "blocks a stdin gh call without a heredoc next to one that has it" {
    _check "$(printf "gh api repos/o/r/issues/1/comments --input - <<'EOF'\n{}\nEOF\nprintf x | gh pr comment 3 --body-file -")"
    _blocked
}

@test "blocks an unquoted heredoc to gh holding a variable" {
    _check "$(printf '%s\n' 'gh api repos/o/r/issues/1/comments --input - <<EOF' "{\"body\":\"${D}BODY\"}" EOF)"
    _blocked
    assert_output --partial "literal"
}

@test "blocks an unquoted heredoc to gh holding a command substitution" {
    _check "$(printf '%s\n' 'gh api repos/o/r/issues/1/comments --input - << EOF' "{\"body\":\"${D}(cat b.md)\"}" EOF)"
    _blocked
}

@test "blocks an unquoted heredoc to gh holding a backtick" {
    _check "$(printf "gh pr comment 3 --body-file - <<-EOF\n\`cat b.md\`\nEOF")"
    _blocked
}

@test "allows a quoted heredoc to gh holding a literal dollar" {
    _check "$(printf '%s\n' 'gh pr comment 3 --body-file - <<"EOF"' "costs ${D}5 and ${D}(x)" EOF)"
    assert_success
    assert_output ""
}

@test "allows an unquoted heredoc to gh with no expansion" {
    _check "$(printf "gh pr comment 3 --body-file - <<EOF\nlib/x.sh:12\nEOF")"
    assert_success
}

@test "ignores a heredoc with a variable that feeds another command" {
    _check "$(printf '%s\n' 'cat <<EOF >/dev/null' "${D}X" EOF "gh pr comment 3 --body 'lib/x'")"
    assert_success
}

@test "the local path patterns are defined in one place" {
    run grep -c 'tmp/claude-' "${HOOK_DIR}/enforce_no_local_paths.sh"
    assert_output "1"
}
