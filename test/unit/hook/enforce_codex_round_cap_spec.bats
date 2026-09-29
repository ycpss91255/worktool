#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/hook/enforce_codex_round_cap_spec.bats
#   - .agents/hook/enforce_codex_round_cap.sh
#
# A codex re-verification from round 4 on ("第 N 輪" in the prompt, N >= 4)
# must carry a "## 根因" section whose three items (類別 / 根因 / 修法) are
# all filled in; the agent writes it itself, no maintainer approval is
# involved. Rounds 1-3 pass. Blocked = exit 2 with the reason on stderr
# (lib/hook_bootstrap.sh hook_block). Driven as a subprocess (stdin JSON)
# the way Claude Code invokes it, plus the decision functions on their own.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    HOOK_SH="${HOOK_DIR}/enforce_codex_round_cap.sh"
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/fixtures"
    mkdir -p "${FIXTURE_DIR}"
    # A complete root-cause section, as a round-4+ prompt must carry it.
    RC=$'## 根因\n- 類別: 解析器對 wrapper 形式的覆蓋\n- 根因: 黑名單逐項補洞\n- 修法: 改成正規化後白名單;等價類別測試矩陣'
}

# _bash <command> [cwd] - a PreToolUse Bash payload.
_bash() {
    jq -n --arg c "$1" --arg cwd "${2:-${FIXTURE_DIR}}" \
        '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$c}}'
}

_check() { run_hook enforce_codex_round_cap "$(_bash "$@")"; }

_source_hook() {
    # shellcheck source=../../../.agents/hook/enforce_codex_round_cap.sh
    source "${HOOK_SH}"
}

# _prompt_file <name> <text> - write a prompt file under the fixture dir.
_prompt_file() { printf '%s\n' "$2" >"${FIXTURE_DIR}/$1"; }

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

@test "codex_round_of: several mentions -> the first one (the declaration), not the largest" {
    _source_hook
    run codex_round_of "這是第 3 輪:上一輪判定提到第 4 輪與第 5 輪"
    assert_output "3"
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

# --- codex_root_cause_ok: the "## 根因" section and its three items ----------

@test "codex_root_cause_ok: the three items filled in -> ok" {
    _source_hook
    run codex_root_cause_ok "這是第 4 輪"$'\n\n'"${RC}"
    assert_success
}

@test "codex_root_cause_ok: no '## 根因' section -> refused" {
    _source_hook
    run codex_root_cause_ok "這是第 4 輪:請確認"
    assert_failure
}

@test "codex_root_cause_ok: only the heading, no content -> refused" {
    _source_hook
    run codex_root_cause_ok $'這是第 4 輪\n## 根因\n'
    assert_failure
    run codex_root_cause_ok $'這是第 4 輪\n## 根因\n\n## 請確認\n- 類別: x\n- 根因: y\n- 修法: z'
    assert_failure
}

@test "codex_root_cause_ok: each item missing or left empty -> refused" {
    _source_hook
    local _drop
    for _drop in 類別 根因 修法; do
        run codex_root_cause_ok "$(printf '%s\n' "${RC}" | grep -v "^- ${_drop}:")"
        assert_failure
        run codex_root_cause_ok "$(printf '%s\n' "${RC}" | sed "s/^- ${_drop}:.*/- ${_drop}:   /")"
        assert_failure
    done
}

@test "codex_root_cause_ok: full-width colon, numbered list and CRLF lines are accepted" {
    _source_hook
    run codex_root_cause_ok $'## 根因\n1. 類別：x\n2. 根因：y\n3. 修法：z'
    assert_success
    run codex_root_cause_ok $'## 根因\r\n類別: x\r\n根因: y\r\n修法: z\r\n'
    assert_success
}

@test "codex_root_cause_ok: items outside the section do not count" {
    _source_hook
    run codex_root_cause_ok $'- 類別: x\n- 根因: y\n- 修法: z\n## 根因\n'
    assert_failure
}

@test "codex_root_cause_ok: a '### ' sub-heading stays inside the section" {
    _source_hook
    run codex_root_cause_ok $'## 根因\n- 類別: x\n### 細節\n- 根因: y\n- 修法: z'
    assert_success
}

# --- codex_prompt_allowed: rounds 1-3 free, 4+ need the root cause -----------

@test "codex_prompt_allowed: rounds 1-3 and no round pass without a root cause" {
    _source_hook
    local _p
    for _p in "請確認" "第 1 輪" "第 2 輪" "第 3 輪"; do
        run codex_prompt_allowed "${_p}"
        assert_success
    done
}

@test "codex_prompt_allowed: round 4 and 8 without a root cause -> refused; with it -> ok" {
    _source_hook
    run codex_prompt_allowed "第 4 輪"
    assert_failure
    run codex_prompt_allowed "第 8 輪"
    assert_failure
    run codex_prompt_allowed "第 4 輪"$'\n'"${RC}"
    assert_success
}

@test "codex_prompt_allowed: a round past the 64-bit range still needs the root cause" {
    _source_hook
    run codex_prompt_allowed "第 18446744073709551616 輪"
    assert_failure
    run codex_prompt_allowed "第 9223372036854775808 輪"
    assert_failure
}

# --- the real pr-loop re-verification prompt ---------------------------------
# .claude/workflows/pr-loop.js writes prompt-r<N>.txt as a fixed preamble,
# then (from round 2) "這是第 N 輪:" and the prior verdict verbatim - a
# verdict that quotes the issue ("第 4 輪起須附根因") and names later rounds.

# _pr_loop_prompt <round> <prior verdict> - prompt-r<round>.txt as pr-loop
# writes it (the template on pr-loop.js's prompt line, kept in step by the
# contract test below).
_pr_loop_prompt() {
    local _p="你是 codex。stdin 前半是 PR 描述與對應 issue,後半是完整 diff(以 '=== DIFF ===' 分隔)。"
    [[ -n "$2" ]] && _p+="這是第 $1 輪:你上一輪的判定逐字如下,請逐項確認是否已修正:"$'\n'"$2"$'\n'
    _p+="請靜態逐項確認:(1) 只做一件事且對應 issue 的驗收標準;(2) TDD 證據(RED/GREEN)。最後一行只能是「可合併」或「不可合併:<原因>」。"
    printf '%s\n' "${_p}"
}

# A prior verdict that mentions rounds 4 and 5, as the real round-3 one did.
PRIOR=$'## 阻擋項\n\n- PR 實作了「第 4 輪起須維護者精確核准」;issue 要求第 4 輪起附「## 根因」。\n- 含第 4 輪與第 5 輪的指令只核准第 5 輪不能放行第 4 輪。\n\n不可合併:需求不符'

@test "pr-loop.js still declares the round before quoting the prior verdict" {
    local _js="${REPO_ROOT}/.claude/workflows/pr-loop.js"
    local _decl="這是第 \${round} 輪:你上一輪的判定逐字如下,請逐項確認是否已修正:\\n\${prior}"
    run grep -cF "${_decl}" "${_js}"
    assert_output "1"
}

@test "hook: pr-loop prompts for rounds 1-3 quoting a verdict that names rounds 4 and 5 pass" {
    local _n _cmd
    mkdir -p "${FIXTURE_DIR}/scratch"
    for _n in 1 2 3; do
        if (( _n == 1 )); then _pr_loop_prompt 1 '' >"${FIXTURE_DIR}/scratch/prompt-r1.txt"
        else _pr_loop_prompt "${_n}" "${PRIOR}" >"${FIXTURE_DIR}/scratch/prompt-r${_n}.txt"; fi
        _cmd="cd ${FIXTURE_DIR}/scratch && { cat ctx-r${_n}.md; printf '\\n=== DIFF ===\\n'; cat pr.diff; } | timeout 420 codex exec --skip-git-repo-check \"\$(cat prompt-r${_n}.txt)\" > out-r${_n}.txt 2>&1"
        _check "${_cmd}" /
        assert_success
        assert_output ""
    done
}

@test "hook: pr-loop prompt for round 4 quoting that verdict -> blocked; with the root cause -> pass" {
    mkdir -p "${FIXTURE_DIR}/scratch"
    local _cmd="cd ${FIXTURE_DIR}/scratch && cat pr.diff | timeout 420 codex exec --skip-git-repo-check \"\$(cat prompt-r4.txt)\""
    _pr_loop_prompt 4 "${PRIOR}" >"${FIXTURE_DIR}/scratch/prompt-r4.txt"
    _check "${_cmd}" /
    assert_failure 2
    assert_output --partial "round 4"
    _pr_loop_prompt 4 "${PRIOR}"$'\n'"${RC}" >"${FIXTURE_DIR}/scratch/prompt-r4.txt"
    _check "${_cmd}" /
    assert_success
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

@test "hook: round 4 without '## 根因' -> blocked (exit 2) with the root-cause template, no approval asked" {
    _check 'codex exec --skip-git-repo-check "這是第 4 輪:請確認"'
    assert_failure 2
    assert_output --partial "BLOCKED"
    assert_output --partial "## 根因"
    assert_output --partial "類別:"
    assert_output --partial "修法:"
    refute_output --partial "approve"
}

@test "hook: round 4 with the three items filled in passes" {
    _prompt_file p4.txt "這是第 4 輪"$'\n'"${RC}"
    _check "codex exec --skip-git-repo-check \"\$(cat p4.txt)\""
    assert_success
    assert_output ""
}

@test "hook: round 4 with only the heading -> blocked" {
    _prompt_file p4.txt $'這是第 4 輪\n## 根因\n'
    _check "codex exec \"\$(cat p4.txt)\""
    assert_failure 2
}

@test "hook: prompt read from a file via \$(cat <path>) after cd (pr-loop form) is judged" {
    mkdir -p "${FIXTURE_DIR}/scratch"
    printf '你是 codex。這是第 4 輪:上一輪判定如下\n' >"${FIXTURE_DIR}/scratch/prompt-r4.txt"
    local _cmd="mkdir -p ${FIXTURE_DIR}/scratch && cd ${FIXTURE_DIR}/scratch && { cat ctx-r4.md; cat pr.diff; } | timeout 420 codex exec --skip-git-repo-check \"\$(cat prompt-r4.txt)\" > out-r4.txt 2>&1"
    _check "${_cmd}" /
    assert_failure 2
    assert_output --partial "## 根因"
    printf '這是第 4 輪\n%s\n' "${RC}" >"${FIXTURE_DIR}/scratch/prompt-r4.txt"
    _check "${_cmd}" /
    assert_success
}

@test "hook: prompt file by absolute path, round 3 passes and round 4 with the root cause passes" {
    _prompt_file p3.txt '這是第 3 輪'
    _check "codex exec \"\$(cat ${FIXTURE_DIR}/p3.txt)\""
    assert_success
    _prompt_file p4.txt "這是第 4 輪"$'\n'"${RC}"
    _check "codex exec \"\$(cat ${FIXTURE_DIR}/p4.txt)\""
    assert_success
}

@test "hook: prompt file relative to the payload cwd without the root cause -> blocked" {
    _prompt_file prompt.txt '這是第 6 輪'
    _check "codex exec \"\$(cat prompt.txt)\"" "${FIXTURE_DIR}"
    assert_failure 2
    assert_output --partial "round 6"
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
    assert_output --partial "round 18446744073709551616"
    _check 'codex exec "第 9223372036854775808 輪"'
    assert_failure 2
}

# --- every launch is judged on its own -----------------------------------------

@test "hook: two launches, only the round-5 one carries the root cause -> blocked on round 4" {
    _prompt_file p5.txt "這是第 5 輪"$'\n'"${RC}"
    _check "codex exec \"第 4 輪\" ; codex exec \"\$(cat p5.txt)\""
    assert_failure 2
    assert_output --partial "round 4"
}

@test "hook: two launches both with the root cause -> pass; round 3 beside a bare round 4 -> blocked" {
    _prompt_file p4.txt "這是第 4 輪"$'\n'"${RC}"
    _prompt_file p5.txt "這是第 5 輪"$'\n'"${RC}"
    _check "codex exec \"\$(cat p4.txt)\" && codex exec \"\$(cat p5.txt)\""
    assert_success
    _check 'codex exec "第 3 輪" | codex exec "第 4 輪"'
    assert_failure 2
    assert_output --partial "round 4"
}

# --- a prompt word the hook cannot read literally fails closed ------------------

@test "hook: a substitution other than \$(cat <path>) in the prompt -> blocked" {
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
    assert_output --partial "round 12"
}

@test "hook: a command carrying the placeholder byte (\\002) itself -> blocked" {
    _check "codex exec \"第 "$'\002'"0"$'\002'" 輪\""
    assert_failure 2
}

@test "hook: text around \$(cat <path>) in one word is read with the file spliced in" {
    printf '4\n' >"${FIXTURE_DIR}/n.txt"
    _check "codex exec \"第 \$(cat n.txt) 輪\""
    assert_failure 2
    assert_output --partial "round 4"
    _prompt_file p3.txt '這是第 3 輪'
    _check "codex exec \"prefix \$(cat p3.txt)\""
    assert_success
}

@test "hook: an empty payload passes" {
    run_hook enforce_codex_round_cap ''
    assert_success
}
