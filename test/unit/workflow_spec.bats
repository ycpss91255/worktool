#!/usr/bin/env bats
# test/unit/workflow_spec.bats
#
# WHY
#   .claude/workflows/pr-loop.js and milestone-fanout.js are the reusable
#   orchestration templates (issue #158): one sub-issue -> one PR driven to
#   "CI green + codex 可合併", and a fan-out over independent sub-issues.
#   They are JavaScript run by the Claude Code Workflow tool, so bats cannot
#   execute or parse them (no JS engine in the test image). This spec is a
#   TEXTUAL guard: it pins the lines that encode the contract so a careless
#   edit trips a test; it does not prove control flow. Behaviour is proven
#   by running the templates (dogfooding on real sub-issues). What it pins:
#   - the file STARTS with the `export const meta = {...}` literal (the
#     Workflow loader requires it first) and the literal is pure (no calls,
#     no spread, no interpolation);
#   - meta.phases names exactly the phases the script uses, whatever quote
#     style is used;
#   - the governance rules are encoded (one issue per PR, structured PR
#     lookup, CI is a gate, codex verdict is structured, codex=off never
#     fakes a [codex] line, bounded fix rounds, the issue's result contract,
#     no merge of any kind inside a template);
#   - the fan-out validates its items and delegates to pr-loop;
#   - research-verify (issue #220: agy researches, claude and codex verify)
#     keeps its four phases, validates its args, never substitutes another
#     model's answer when agy fails, and never writes a [codex] line itself.
#     Unlike the other two templates it is also EXECUTED: the test image
#     carries node, and test/unit/fixture/workflow_run.mjs runs the template
#     with stand-in agents, so arg rejection, shell quoting of repoDir /
#     repo (every shell step is really run against a hostile path) and the
#     fail-closed Verify / Synthesize / Record flow are proven, not grepped.
#   This spec is a REQUIRED unit spec of test.sh, so it cannot be deleted
#   silently.

load ../helper/common

setup() {
    WF_DIR="${REPO_ROOT}/.claude/workflows"
    PR_LOOP="${WF_DIR}/pr-loop.js"
    FANOUT="${WF_DIR}/milestone-fanout.js"
    RESEARCH="${WF_DIR}/research-verify.js"
    WORK="${BATS_TEST_TMPDIR}/work"
}

# The meta block of $1: from the first line to its closing "}" line.
_meta_block() {
    sed -n '1,/^}$/p' "$1"
}

# Phase titles named in meta.phases of $1 (single or double quoted).
_meta_phases() {
    _meta_block "$1" | grep -oE "title: *['\"][^'\"]*['\"]" | sed -E "s/title: *['\"]//; s/['\"]$//"
}

# Phase titles used by phase() calls or {phase: ...} options in $1, any
# quote style; a template literal or a variable there is reported as
# DYNAMIC so the diff fails loudly instead of hiding a phase.
_used_phases() {
    {
        grep -oE "phase\(['\"][^'\"]*['\"]\)" "$1" | sed -E "s/phase\(['\"]//; s/['\"]\)//"
        grep -oE "phase: *['\"][^'\"]*['\"]" "$1" | sed -E "s/phase: *['\"]//; s/['\"]$//"
        grep -oE "phase\([^'\"]" "$1" | sed 's/.*/DYNAMIC/'
        grep -oE "phase: *[^'\" ]" "$1" | sed 's/.*/DYNAMIC/'
    } | sort -u
}

@test "both workflow templates exist under .claude/workflows/" {
    [[ -f "${PR_LOOP}" ]]
    [[ -f "${FANOUT}" ]]
}

@test "each template STARTS with the export const meta literal (loader contract), nothing before it" {
    for f in "${PR_LOOP}" "${FANOUT}"; do
        run head -n1 "$f"
        assert_output "export const meta = {"
    done
}

# The meta block with every quoted string literal blanked out, so that only
# structural characters remain (a "(" left over is a call, "..." a spread).
_meta_skeleton() {
    _meta_block "$1" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g"
}

@test "the meta literal is pure: name, description, phases present; no calls, spread, or interpolation inside" {
    for f in "${PR_LOOP}" "${FANOUT}"; do
        run _meta_block "$f"
        assert_output --partial "name: '"
        assert_output --partial "description: '"
        assert_output --partial "phases: ["
        run _meta_skeleton "$f"
        refute_output --partial "("
        refute_output --partial "..."
        refute_output --partial "\${"
        refute_output --partial "\`"
    done
}

@test "pr-loop: phases used == phases declared in meta (any quote style; dynamic phase names fail)" {
    run bash -c "diff <($(declare -f _meta_block _meta_phases); _meta_phases '${PR_LOOP}' | sort -u) <($(declare -f _used_phases); _used_phases '${PR_LOOP}')"
    assert_success
    assert_output ""
}

@test "milestone-fanout: phases used == phases declared in meta" {
    run bash -c "diff <($(declare -f _meta_block _meta_phases); _meta_phases '${FANOUT}' | sort -u) <($(declare -f _used_phases); _used_phases '${FANOUT}')"
    assert_success
    assert_output ""
}

@test "pr-loop requires repo, repoDir, issue, branch, name and task; codex only on|off; maxRounds a non-negative integer" {
    run grep -c "for (const k of \['repo', 'repoDir', 'issue', 'branch', 'name', 'task'\])" "${PR_LOOP}"
    assert_output "1"
    run grep -c "codexArg !== 'on' && codexArg !== 'off'" "${PR_LOOP}"
    assert_output "1"
    run grep -c "Number.isInteger(MAX) || MAX < 0" "${PR_LOOP}"
    assert_output "1"
}

@test "pr-loop closes exactly one issue and locates the PR by branch with a structured schema, not by parsing prose" {
    run grep -c "Closes #\\\${A.issue}" "${PR_LOOP}"
    assert_output "1"
    run grep -c "schema: LOCATE_SCHEMA" "${PR_LOOP}"
    assert_output "1"
    run grep -c "gh pr list --repo \\\${REPO} --head \\\${A.branch}" "${PR_LOOP}"
    assert_output "1"
}

@test "pr-loop treats CI as a gate: a red result returns ciState red before codex and after every fix" {
    run grep -c "ci.state !== 'green'" "${PR_LOOP}"
    assert_output "2"
    run grep -c "ciState: 'red'" "${PR_LOOP}"
    assert_output "2"
}

@test "pr-loop parses the codex verdict structurally and never lets no-output or unparseable count as a pass" {
    run grep -c "schema: CODEX_SCHEMA" "${PR_LOOP}"
    assert_output "1"
    run grep -c "enum: \['mergeable', 'blocked', 'no-output'\]" "${PR_LOOP}"
    assert_output "1"
    run grep -c "unparseable is not a pass" "${PR_LOOP}"
    assert_output "1"
    run grep -c "verdict === 'no-output'" "${PR_LOOP}"
    assert_output "1"
}

@test "pr-loop codex=off path posts the quota note and never fabricates a [codex] line" {
    run grep -c 'codex 暫停中(配額)' "${PR_LOOP}"
    assert [ "${output}" -ge 1 ]
    run grep -c 'Never write a "\[codex\]" line yourself' "${PR_LOOP}"
    assert_output "1"
}

@test "pr-loop bounds Fix rounds by maxRounds and feeds the prior verdict back to codex" {
    run grep -c "if (fixes >= MAX) break" "${PR_LOOP}"
    assert_output "1"
    run grep -c '你上一輪的判定逐字如下' "${PR_LOOP}"
    assert_output "1"
}

@test "pr-loop codex step pastes the issue's ## 範圍 section verbatim and blocks only on in-scope problems (issue #238)" {
    # the section is cut from the issue body by the shell, not retyped by the agent
    run grep -c "awk '/^## 範圍/{f=1;print;next} f&&/^## /{exit} f' > scope-r" "${PR_LOOP}"
    assert_output "1"
    # an issue without the section says so explicitly in the prompt
    run grep -c "issue 未定範圍" "${PR_LOOP}"
    assert [ "${output}" -ge 1 ]
    # the placeholder is written into the prompt and replaced by the file verbatim
    run grep -cF '逐字如下:\n@@SCOPE@@\n' "${PR_LOOP}"
    assert_output "1"
    run grep -cF "'\$0 == \"@@SCOPE@@\" { while ((getline l < f) > 0) print l; next } 1' draft-r" "${PR_LOOP}"
    assert_output "1"
    run grep -c '只有落在上述範圍內的具體問題才可列為阻擋項' "${PR_LOOP}"
    assert_output "1"
}

# Run pr-loop under node with every shell step played (exec) in a fresh
# work dir, up to the first codex round; gh is a stub that prints
# ${BATS_TEST_TMPDIR}/body.md for `issue view --json body` and fails that
# call when ${BATS_TEST_TMPDIR}/gh.fail exists. The work dir is WORK.
_pl_codex_round() {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${stub}" "${WORK}"
    cat > "${stub}/gh" <<SH
#!/bin/sh
case " \$* " in
    *" issue view "*" --json body "*)
        [ -e "${BATS_TEST_TMPDIR}/gh.fail" ] && exit 1
        cat "${BATS_TEST_TMPDIR}/body.md" ;;
esac
exit 0
SH
    chmod +x "${stub}/gh"
    local replies='{"locate:": {"pr": 7, "sha": "abc"}, "ci:": {"state": "green", "sha": "abc", "detail": ""}}'
    (cd "${WORK}" && PATH="${stub}:${PATH}" node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        "$(jq -cn --arg d "${BATS_TEST_TMPDIR}" '{repo:"o/r",repoDir:$d,issue:238,branch:"b",name:"n",task:"t"}')" \
        "${replies}" exec)
}

# rc of the played step that writes scope-r1.md.
_pl_scope_rc() { jq -r '[.ran[] | select(.cmd | contains("> scope-r1.md")) | .rc] | first' <<<"$1"; }

@test "pr-loop (node): the scope step cuts the issue's ## 範圍 section out verbatim (issue #238)" {
    printf '## 背景\n\nx\n\n## 範圍\n\n- 擋:a\n- 不擋:b\n\n## Acceptance criteria\n\n- z\n' > "${BATS_TEST_TMPDIR}/body.md"
    run _pl_codex_round
    assert_success
    assert_equal "$(_pl_scope_rc "${output}")" "0"
    run cat "${WORK}/scope-r1.md"
    assert_output "$(printf '## 範圍\n\n- 擋:a\n- 不擋:b\n')"
}

@test "pr-loop (node): an issue without ## 範圍 gets the explicit 'issue 未定範圍' note (issue #238)" {
    printf '## 背景\n\nx\n' > "${BATS_TEST_TMPDIR}/body.md"
    run _pl_codex_round
    assert_success
    assert_equal "$(_pl_scope_rc "${output}")" "0"
    run cat "${WORK}/scope-r1.md"
    assert_output --partial "issue 未定範圍"
}

@test "pr-loop (node): a failed gh issue view fails the scope step and never becomes 'issue 未定範圍' (issue #238)" {
    printf '## 範圍\n\n- 擋:a\n' > "${BATS_TEST_TMPDIR}/body.md"
    touch "${BATS_TEST_TMPDIR}/gh.fail"
    run _pl_codex_round
    assert_success
    refute [ "$(_pl_scope_rc "${output}")" = "0" ]
    refute [ -s "${WORK}/scope-r1.md" ]
    # the prompt tells the agent to stop the round instead of reviewing without the scope
    run jq -r '.calls[] | select(.label | startswith("codex:")) | .prompt' <<<"${output}"
    assert_output --partial "讀取 issue #238 失敗,本輪未完成"
}

@test "pr-loop returns the issue #158 result contract: pr, sha, ciState, codexVerdict, rounds" {
    run grep -c "ciState: 'green', codexVerdict: verdict, rounds: fixes" "${PR_LOOP}"
    assert_output "1"
    run grep -cE "return result\(\{ pr, sha" "${PR_LOOP}"
    assert [ "${output}" -ge 2 ]
}

@test "no template contains a known merge command (gh pr merge, REST/GraphQL merge, push to main, auto-merge)" {
    run grep -nE 'gh pr merge|/merge|mergePullRequest|HEAD:main|git push[^\n]* main|--auto' "${PR_LOOP}" "${FANOUT}"
    assert_failure
    run grep -c 'Never merge a PR' "${PR_LOOP}"
    assert_output "1"
}

@test "no template hardcodes a machine path, a session scratchpad or a session URL; repoDir is required" {
    run grep -nE '/tmp/claude-|/home/[a-z]+/|claude.ai/code/session_' "${PR_LOOP}" "${FANOUT}" "${REPO_ROOT}/doc/workflow.md"
    assert_failure
    run grep -c 'REPO_DIR}/.worktree/.scratch/' "${PR_LOOP}"
    assert_output "1"
    run grep -c "const REPO_DIR = A.repoDir$" "${PR_LOOP}" "${FANOUT}"
    assert_output --partial "pr-loop.js:1"
    assert_output --partial "milestone-fanout.js:1"
    run grep -c "A.sessionUrl" "${PR_LOOP}"
    assert [ "${output}" -ge 1 ]
}

@test "milestone-fanout requires repoDir, validates every item, delegates through pipeline to pr-loop, and logs in the per-item stage" {
    run grep -c "!A.repo || !A.repoDir" "${FANOUT}"
    assert_output "1"
    run grep -c "for (const k of \['issue', 'branch', 'name', 'task'\])" "${FANOUT}"
    assert_output "1"
    run grep -c "workflow({ scriptPath: SCRIPT }" "${FANOUT}"
    assert_output "1"
    run grep -c 'REPO_DIR}/.claude/workflows/pr-loop.js' "${FANOUT}"
    assert_output "1"
    run grep -c 'await pipeline(A.items' "${FANOUT}"
    assert_output "1"
    run grep -c 'item.issue} done:' "${FANOUT}"
    assert_output "1"
    run grep -c 'await parallel(' "${FANOUT}"
    assert_output "0"
}

# Run research-verify under node (test/unit/fixture/workflow_run.mjs) with
# args $1 and agent replies $2; $3 = exec plays each agent's shell steps.
_rv_run() {
    node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${RESEARCH}" "$1" "$2" ${3:+"$3"}
}

# Agent replies of a run where every step succeeds.
_rv_ok_replies() {
    cat <<'JSON'
{"agy:": {"status": "ok", "attempts": 1, "detail": "agy.md 10 bytes"},
 "claude-verify:": {"claims": [{"claim": "c1", "verdict": "supported", "basis": "b1"}]},
 "codex-verify:": {"status": "ok", "detail": "codex.md 9 bytes"},
 "synthesize:": {"verified": ["v1"], "refuted": [], "needsExperiment": [], "recommendation": "r1", "parameters": []},
 "record:": {"url": "https://example.invalid/c/1"}}
JSON
}

# $1 with the reply of label prefix $2 replaced by JSON $3.
_rv_with() {
    jq -c --arg k "$2" --argjson v "$3" '.[$k] = $v' <<<"$1"
}

@test "research-verify exists, STARTS with the meta literal, and the literal is pure" {
    [[ -f "${RESEARCH}" ]]
    run head -n1 "${RESEARCH}"
    assert_output "export const meta = {"
    run _meta_block "${RESEARCH}"
    assert_output --partial "name: 'research-verify'"
    assert_output --partial "description: '"
    assert_output --partial "phases: ["
    run _meta_skeleton "${RESEARCH}"
    refute_output --partial "("
    refute_output --partial "..."
    refute_output --partial "\${"
    refute_output --partial "\`"
}

@test "research-verify declares exactly Research, Verify, Synthesize, Record and uses exactly those" {
    run _meta_phases "${RESEARCH}"
    assert_output "$(printf '%s\n' Research Verify Synthesize Record)"
    run bash -c "diff <($(declare -f _meta_block _meta_phases); _meta_phases '${RESEARCH}' | sort -u) <($(declare -f _used_phases); _used_phases '${RESEARCH}')"
    assert_success
    assert_output ""
}

@test "research-verify requires repo, repoDir, issue, question; validates issue, timeoutMin and sources" {
    run grep -c "for (const k of \['repo', 'repoDir', 'issue', 'question'\])" "${RESEARCH}"
    assert_output "1"
    run grep -c "throw new Error(\`research-verify: args.\\\${k} is required\`)" "${RESEARCH}"
    assert_output "1"
    run grep -c "Number.isInteger(A.issue) || A.issue <= 0" "${RESEARCH}"
    assert_output "1"
    run grep -c "Number.isInteger(TMIN) || TMIN <= 0" "${RESEARCH}"
    assert_output "1"
    run grep -c "!Array.isArray(A.sources)" "${RESEARCH}"
    assert_output "1"
}

@test "research-verify (node): rejects a repo that is not owner/name and a repoDir that is not a safe absolute path" {
    local bad
    for bad in '"o/r; touch x"' '"o r/x"' '"o/r/x"' '"-o/r"' '42' '"o/r\n"'; do
        run _rv_run "{\"repo\":${bad},\"repoDir\":\"/w\",\"issue\":7,\"question\":\"q\"}" '{}'
        assert_success
        run jq -r '.error' <<<"${output}"
        assert_output --partial "research-verify: args.repo"
    done
    for bad in '"rel/dir"' '"/w\nx"' '"/w\u0060x"' '123'; do
        run _rv_run "{\"repo\":\"o/r\",\"repoDir\":${bad},\"issue\":7,\"question\":\"q\"}" '{}'
        assert_success
        run jq -r '.error' <<<"${output}"
        assert_output --partial "research-verify: args.repoDir"
    done
}

@test "research-verify runs agy headless with a hard timeout and retries once" {
    run grep -cF "timeout \${TMIN * 60 + 60} agy --sandbox --dangerously-skip-permissions -p" "${RESEARCH}"
    assert_output "1"
    run grep -cF -- "--print-timeout \${TMIN}m" "${RESEARCH}"
    assert_output "1"
    run grep -c 'retry ONCE' "${RESEARCH}"
    assert_output "1"
    run grep -c 'UNVERIFIED' "${RESEARCH}"
    assert [ "${output}" -ge 1 ]
}

@test "research-verify: an agy failure returns a structured failure before Verify and never substitutes another answer" {
    run grep -c "schema: AGY_SCHEMA" "${RESEARCH}"
    assert_output "1"
    run grep -c "enum: \['ok', 'failed'\]" "${RESEARCH}"
    assert_output "1"
    run grep -c "if (!res || res.status !== 'ok') return" "${RESEARCH}"
    assert_output "1"
    run grep -c "status: 'agy-failed'" "${RESEARCH}"
    assert_output "1"
    run grep -c 'Never answer the question yourself' "${RESEARCH}"
    assert_output "1"
    # the failure return comes before the first Verify agent
    fail_line="$(grep -n "if (!res || res.status !== 'ok') return" "${RESEARCH}" | cut -d: -f1)"
    verify_line="$(grep -n "^phase('Verify')" "${RESEARCH}" | cut -d: -f1)"
    assert [ "${fail_line}" -lt "${verify_line}" ]
}

@test "research-verify verifies with a claude agent and codex exec in parallel, codex fed the agy text on stdin" {
    run grep -c 'await parallel(\[' "${RESEARCH}"
    assert_output "1"
    run grep -c "schema: CLAIMS_SCHEMA" "${RESEARCH}"
    assert_output "1"
    run grep -c "enum: \['supported', 'refuted', 'unverifiable'\]" "${RESEARCH}"
    assert_output "1"
    run grep -c 'codex exec --skip-git-repo-check' "${RESEARCH}"
    assert_output "1"
    run grep -cE 'cat agy\.md[^|]*\| *timeout [0-9]+ codex exec' "${RESEARCH}"
    assert_output "1"
}

@test "research-verify never writes a [codex] line itself: codex text is copied from its file by the shell" {
    run grep -c 'Never write a "\[codex\]" line yourself' "${RESEARCH}"
    assert [ "${output}" -ge 2 ]
    run grep -c 'cat codex.md' "${RESEARCH}"
    assert [ "${output}" -ge 1 ]
}

@test "research-verify synthesizes a structured conclusion and records ONE issue comment via --body-file" {
    run grep -c "schema: SYNTH_SCHEMA" "${RESEARCH}"
    assert_output "1"
    for k in verified refuted needsExperiment recommendation parameters; do
        run grep -c "${k}: {" "${RESEARCH}"
        assert_output "1"
    done
    run grep -c 'gh issue comment ' "${RESEARCH}"
    assert_output "1"
    run grep -c '<details><summary>agy 原文</summary>' "${RESEARCH}"
    assert_output "1"
}

@test "research-verify keeps its files under repoDir scratch, hardcodes no machine path, and never merges or pushes" {
    run grep -nE '/tmp/claude-|/home/[a-z]+/|claude.ai/code/session_' "${RESEARCH}"
    assert_failure
    run grep -c "const REPO_DIR = A.repoDir$" "${RESEARCH}"
    assert_output "1"
    run grep -c 'REPO_DIR}/.worktree/.scratch/research-' "${RESEARCH}"
    assert_output "1"
    run grep -nE 'gh pr merge|/merge|mergePullRequest|HEAD:main|git push|--auto' "${RESEARCH}"
    assert_failure
}

@test "research-verify (node): a repoDir with spaces and shell metacharacters is quoted, never executed, and every step runs" {
    local stub="${BATS_TEST_TMPDIR}/bin" dir scratch
    mkdir -p "${stub}"
    printf '#!/bin/sh\necho "1. agy-claim [官方文件 https://x]"\n' > "${stub}/agy"
    printf '#!/bin/sh\ncat >/dev/null\nprintf "banner\\ncodex\\ncodex-verdict-line\\ntokens used\\n5\\n"\n' > "${stub}/codex"
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/gh.args"\necho https://example.invalid/c/1\n' "${BATS_TEST_TMPDIR}" > "${stub}/gh"
    chmod +x "${stub}"/*
    dir="${BATS_TEST_TMPDIR}/dir with space/\$(touch ${BATS_TEST_TMPDIR}/pwned);x'q"
    scratch="${dir}/.worktree/.scratch/research-7"
    PATH="${stub}:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "$(_rv_ok_replies)" exec
    assert_success
    local json="${output}"
    run jq -r '.error, .result.status' <<<"${json}"
    assert_output "$(printf '%s\n' null recorded)"
    # mkdir, agy, codex run, codex extraction, body build, gh: every one ran and passed
    run jq -r '[.ran[].rc] | map(tostring) | join(" ")' <<<"${json}"
    assert_output "0 0 0 0 0 0"
    [[ ! -e "${BATS_TEST_TMPDIR}/pwned" ]]
    [[ -s "${scratch}/agy.md" ]]
    run cat "${scratch}/codex.md"
    assert_output "codex-verdict-line"
    run grep -c '^\[codex\] 逐條驗證(原文)$' "${scratch}/body.md"
    assert_output "1"
    run cat "${BATS_TEST_TMPDIR}/gh.args"
    assert_output "$(printf '%s\n' issue comment 7 --repo o/r --body-file "${scratch}/body.md")"
}

@test "research-verify (node): the claude verifier's schema demands at least one claim" {
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_ok_replies)"
    assert_success
    run jq -r '.calls[] | select(.label | startswith("claude-verify:")) | .schema.properties.claims.minItems' <<<"${output}"
    assert_output "1"
}

@test "research-verify (node): an agy failure stops before Verify with agy-failed" {
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_with "$(_rv_ok_replies)" 'agy:' '{"status":"failed","attempts":2,"detail":"d"}')"
    assert_success
    run jq -r '.result.status, (.calls | length)' <<<"${output}"
    assert_output "$(printf '%s\n' agy-failed 1)"
}

@test "research-verify (node): a missing or empty verification fails closed, nothing is synthesized or posted" {
    local ok key val key_val
    ok="$(_rv_ok_replies)"
    for key_val in 'claude-verify:=null' 'claude-verify:={"claims":[]}' 'claude-verify:={}' \
                   'codex-verify:=null' 'codex-verify:={"status":"no-output","detail":"quota"}'; do
        key="${key_val%%=*}"
        val="${key_val#*=}"
        run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_with "${ok}" "${key}" "${val}")"
        assert_success
        run jq -r '.result.status, .result.comment, ([.calls[].label | select(startswith("synthesize:") or startswith("record:"))] | length)' <<<"${output}"
        assert_output "$(printf '%s\n' verify-failed '' 0)"
    done
}

@test "research-verify (node): a failed or malformed synthesis fails closed, nothing is posted" {
    local ok val
    ok="$(_rv_ok_replies)"
    for val in 'null' '{"verified":[],"refuted":[],"needsExperiment":[],"parameters":[]}' \
               '{"verified":[],"refuted":[],"needsExperiment":[],"recommendation":"","parameters":[]}' \
               '{"verified":"x","refuted":[],"needsExperiment":[],"recommendation":"r","parameters":[]}'; do
        run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_with "${ok}" 'synthesize:' "${val}")"
        assert_success
        run jq -r '.result.status, .result.comment, ([.calls[].label | select(startswith("record:"))] | length)' <<<"${output}"
        assert_output "$(printf '%s\n' synthesize-failed '' 0)"
    done
}

@test "research-verify (node): recorded only with a comment URL, record-failed otherwise" {
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_ok_replies)"
    run jq -r '.result.status, .result.comment' <<<"${output}"
    assert_output "$(printf '%s\n' recorded https://example.invalid/c/1)"
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_with "$(_rv_ok_replies)" 'record:' '{"url":""}')"
    run jq -r '.result.status' <<<"${output}"
    assert_output "record-failed"
}

@test "doc/workflow.md documents research-verify and its args" {
    run grep -c '^## research-verify' "${REPO_ROOT}/doc/workflow.md"
    assert_output "1"
    run grep -c 'repo, repoDir, issue, question, context?, sources?, timeoutMin?' "${REPO_ROOT}/doc/workflow.md"
    assert_output "1"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
