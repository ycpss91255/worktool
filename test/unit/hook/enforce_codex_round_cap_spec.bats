#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/hook/enforce_codex_round_cap_spec.bats
#   - .agents/hook/enforce_codex_round_cap.sh
#
# A codex re-verification from round 4 on ("第 N 輪" in the prompt, N >= 4)
# must stop and look for the root cause of the repeated finding class first;
# it runs only when the maintainer's latest message says
# `approve codex round N` (exact N). Rounds 1-3 pass. Blocked = exit 2 with
# the reason on stderr (lib/hook_bootstrap.sh hook_block). Driven as a
# subprocess (stdin JSON) the way Claude Code invokes it, plus the decision
# functions on their own.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    HOOK_SH="${HOOK_DIR}/enforce_codex_round_cap.sh"
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/fixtures"
    mkdir -p "${FIXTURE_DIR}"
    TRANSCRIPT="${FIXTURE_DIR}/transcript.jsonl"
    _say "please continue"
}

# _say <text> - the maintainer's latest message in the fake transcript.
_say() {
    jq -cn --arg t "$1" '{type:"assistant",message:{role:"assistant",content:"asking"}},
        {type:"user",message:{role:"user",content:$t}}' >"${TRANSCRIPT}"
}

# _bash <command> [cwd] - a PreToolUse Bash payload with the transcript.
_bash() {
    jq -n --arg c "$1" --arg tp "${TRANSCRIPT}" --arg cwd "${2:-${FIXTURE_DIR}}" \
        '{tool_name:"Bash", transcript_path:$tp, cwd:$cwd, tool_input:{command:$c}}'
}

_check() { run_hook enforce_codex_round_cap "$(_bash "$@")"; }

_source_hook() {
    # shellcheck source=../../../.agents/hook/enforce_codex_round_cap.sh
    source "${HOOK_SH}"
}

# --- codex_round_of: the round number of a prompt ----------------------------

@test "codex_round_of: '這是第 4 輪' -> 4" {
    _source_hook
    run codex_round_of $'你是 codex。這是第 4 輪:你上一輪的判定如下'
    assert_success
    assert_output "4"
}

@test "codex_round_of: no space and two digits ('第12輪') -> 12" {
    _source_hook
    run codex_round_of "第12輪複驗"
    assert_output "12"
}

@test "codex_round_of: several mentions -> the largest round" {
    _source_hook
    run codex_round_of "這是第 5 輪:第 4 輪的判定逐字如下"
    assert_output "5"
}

@test "codex_round_of: a prompt without a round -> nothing" {
    _source_hook
    run codex_round_of "你是 codex。請靜態逐項確認"
    assert_success
    assert_output ""
}

@test "codex_round_of: leading zeros are dropped ('第 004 輪') -> 4" {
    _source_hook
    run codex_round_of "第 004 輪"
    assert_output "4"
}

@test "codex_round_of: a round past the 64-bit range is kept as digits, no arithmetic" {
    _source_hook
    run codex_round_of "第 18446744073709551616 輪"
    assert_success
    assert_output "18446744073709551616"
    run codex_round_of "第 9223372036854775808 輪; 第 5 輪"
    assert_output "9223372036854775808"
}

# --- codex_round_allowed: rounds 1-3 free, 4+ need the exact approval --------

@test "codex_round_allowed: rounds 1-3 and no round pass without approval" {
    _source_hook
    local _n
    for _n in "" 1 2 3; do
        run codex_round_allowed "${_n}" "please continue"
        assert_success
    done
}

@test "codex_round_allowed: round 4 and 8 without approval -> refused" {
    _source_hook
    run codex_round_allowed 4 "please continue"
    assert_failure
    run codex_round_allowed 8 ""
    assert_failure
}

@test "codex_round_allowed: 'approve codex round 4' allows round 4 (verb case-insensitive)" {
    _source_hook
    run codex_round_allowed 4 "approve codex round 4"
    assert_success
    run codex_round_allowed 4 $'root cause fixed.\nApprove codex round 4, go.'
    assert_success
}

@test "codex_round_allowed: a round past the 64-bit range needs its own exact approval" {
    _source_hook
    local _big=18446744073709551616
    run codex_round_allowed "${_big}" "please continue"
    assert_failure
    run codex_round_allowed 9223372036854775808 "approve codex round 0"
    assert_failure
    run codex_round_allowed "${_big}" "approve codex round ${_big}"
    assert_success
}

@test "codex_round_allowed: approval for another round -> refused" {
    _source_hook
    run codex_round_allowed 4 "approve codex round 5"
    assert_failure
    run codex_round_allowed 4 "approve codex round 40"
    assert_failure
    run codex_round_allowed 5 "approve codex round 4"
    assert_failure
    run codex_round_allowed 4 "approve SC2034 round 4"
    assert_failure
}

# --- the hook end to end ------------------------------------------------------

@test "hook: inline prompt rounds 1-3 pass silently" {
    local _n
    for _n in 1 2 3; do
        _check "codex exec --skip-git-repo-check \"這是第 ${_n} 輪:請確認\""
        assert_success
        assert_output ""
    done
}

@test "hook: inline prompt round 4 without approval -> blocked (exit 2) with the root-cause steps" {
    _check 'codex exec --skip-git-repo-check "這是第 4 輪:請確認"'
    assert_failure 2
    assert_output --partial "BLOCKED"
    assert_output --partial "approve codex round 4"
    assert_output --partial "allow-list"
    assert_output --partial "equivalence-class"
    assert_output --partial "## 範圍"
}

@test "hook: round 4 with 'approve codex round 4' passes" {
    _say "approve codex round 4"
    _check 'codex exec --skip-git-repo-check "這是第 4 輪:請確認"'
    assert_success
    assert_output ""
}

@test "hook: round 4 with approval for round 5 -> blocked" {
    _say "approve codex round 5"
    _check 'codex exec --skip-git-repo-check "這是第 4 輪:請確認"'
    assert_failure 2
}

@test "hook: prompt read from a file via \$(cat <path>) after cd (pr-loop form) -> blocked" {
    mkdir -p "${FIXTURE_DIR}/scratch"
    printf '你是 codex。這是第 4 輪:上一輪判定如下\n' >"${FIXTURE_DIR}/scratch/prompt-r4.txt"
    _check "mkdir -p ${FIXTURE_DIR}/scratch && cd ${FIXTURE_DIR}/scratch && { cat ctx-r4.md; cat pr.diff; } | timeout 420 codex exec --skip-git-repo-check \"\$(cat prompt-r4.txt)\" > out-r4.txt 2>&1" /
    assert_failure 2
    assert_output --partial "approve codex round 4"
}

@test "hook: prompt file by absolute path, round 3 passes and round 4 with approval passes" {
    printf '這是第 3 輪\n' >"${FIXTURE_DIR}/p3.txt"
    _check "codex exec \"\$(cat ${FIXTURE_DIR}/p3.txt)\""
    assert_success
    printf '這是第 4 輪\n' >"${FIXTURE_DIR}/p4.txt"
    _say "approve codex round 4"
    _check "codex exec \"\$(cat ${FIXTURE_DIR}/p4.txt)\""
    assert_success
}

@test "hook: prompt file relative to the payload cwd -> blocked" {
    printf '這是第 6 輪\n' >"${FIXTURE_DIR}/prompt.txt"
    _check "codex exec \"\$(cat prompt.txt)\"" "${FIXTURE_DIR}"
    assert_failure 2
    assert_output --partial "approve codex round 6"
}

@test "hook: wrapper forms the subcommand parser strips are judged (bash -c, env, timeout)" {
    _check "bash -c 'codex exec \"第 4 輪\"'"
    assert_failure 2
    _check 'env FOO=1 timeout 60 codex exec "第 4 輪"'
    assert_failure 2
}

@test "hook: text that only mentions codex exec and 第 4 輪 is data -> pass" {
    _check 'git commit -m "run codex exec for 第 4 輪"'
    assert_success
    _check 'echo "codex exec 第 4 輪"'
    assert_success
}

@test "hook: a round that wraps the 64-bit range (2^64 -> 0, 2^63 -> negative) -> blocked" {
    _check 'codex exec "第 18446744073709551616 輪"'
    assert_failure 2
    assert_output --partial "approve codex round 18446744073709551616"
    _check 'codex exec "第 9223372036854775808 輪"'
    assert_failure 2
}

# --- every launch is judged on its own -----------------------------------------

@test "hook: two launches (round 4; round 5), only round 5 approved -> blocked on round 4" {
    _say "approve codex round 5"
    _check 'codex exec "第 4 輪" ; codex exec "第 5 輪"'
    assert_failure 2
    assert_output --partial "approve codex round 4"
}

@test "hook: two launches, both rounds approved -> pass; one launch of round 3 beside round 4 still needs round 4" {
    _say "approve codex round 4; approve codex round 5"
    _check 'codex exec "第 4 輪" && codex exec "第 5 輪"'
    assert_success
    _say "please continue"
    _check 'codex exec "第 3 輪" | codex exec "第 4 輪"'
    assert_failure 2
    assert_output --partial "approve codex round 4"
}

# --- a prompt word the hook cannot read literally fails closed ------------------

@test "hook: a substitution other than \$(cat <path>) in the prompt -> blocked, no approval helps" {
    _say "approve codex round 4"
    _check "codex exec \"\$(printf 第%s輪 4)\""
    assert_failure 2
    assert_output --partial "cannot be read"
    _check "codex exec \"\`printf 第4輪\`\""
    assert_failure 2
    _check "codex exec \"\$(cat p.txt | tr 3 4)\""
    assert_failure 2
}

@test "hook: a variable or \$'...' in the prompt -> blocked" {
    _check "codex exec \"\$PROMPT\""
    assert_failure 2
    assert_output --partial "cannot be read"
    _check "codex exec \$'\\u7b2c 4 \\u8f2a'"
    assert_failure 2
}

@test "hook: \$(cat <path>) of a missing file -> blocked" {
    _check "codex exec \"\$(cat missing.txt)\""
    assert_failure 2
    assert_output --partial "cannot be read"
}

@test "hook: two \$(cat <path>) in one word are both spliced in place (1 and 2 -> round 12)" {
    printf '1\n' >"${FIXTURE_DIR}/a.txt"
    printf '2\n' >"${FIXTURE_DIR}/b.txt"
    _check "codex exec \"第 \$(cat a.txt)\$(cat b.txt) 輪\""
    assert_failure 2
    assert_output --partial "approve codex round 12"
}

@test "hook: a command carrying the placeholder byte (\\002) itself -> blocked" {
    _check "codex exec \"第 "$'\002'"0"$'\002'" 輪\""
    assert_failure 2
}

@test "hook: text around \$(cat <path>) in one word is read with the file spliced in" {
    printf '4\n' >"${FIXTURE_DIR}/n.txt"
    _check "codex exec \"第 \$(cat n.txt) 輪\""
    assert_failure 2
    assert_output --partial "approve codex round 4"
    printf '這是第 3 輪\n' >"${FIXTURE_DIR}/p3.txt"
    _check "codex exec \"prefix \$(cat p3.txt)\""
    assert_success
}

@test "hook: an empty payload passes" {
    run_hook enforce_codex_round_cap ''
    assert_success
}
