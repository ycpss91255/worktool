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
#     The stand-in agent fails closed (a failing shell step returns null,
#     never the canned reply), and a matrix of failing stages x failure
#     kinds (non-zero exit, empty, malformed) proves nothing is recorded
#     (issue #225).
#     Issue #223: the Record carries only codex's final answer (a matrix of
#     real transcript shapes) and no local absolute path in any form.
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

@test "workflows keep worktrees and scratch outside the repo checkout" {
    run _pl_run
    assert_success
    run jq -cr '[
        (.calls[] | select(.label | startswith("implement:")) | .prompt | contains("/work/../worktree/n")),
        (.calls[] | select(.label | startswith("implement:")) | .prompt | contains("/work/../worktree/.scratch/n"))
    ]' <<<"${output}"
    assert_output '[true,true]'

    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_ok_replies)"
    assert_success
    run jq -cr '[
        (.calls[] | select(.label | startswith("agy:")) | .prompt | contains("/w/../worktree/.scratch/research-7")),
        (.calls[] | select(.label | startswith("agy:")) | .prompt | contains("[ -z \"$before\" ] && mkdir -p")),
        (.calls[-1].prompt | contains("git -C '\''/w'\'' status --porcelain --untracked-files=all -- .")),
        (.calls[-1].prompt | contains(":(exclude)") | not)
    ]' <<<"${output}"
    assert_output '[true,true,true,true]'
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
    local mode
    for mode in full light; do
        run _pl_run "{\"mode\":\"${mode}\"}"
        assert_success
        run jq -cr '[(.calls | map(select(.label | startswith("locate:"))) | length), (.calls[] | select(.label | startswith("locate:")) | .schema.required), ([.calls[].prompt | scan("Closes #283")] | length)]' <<<"${output}"
        assert_output '[1,["pr","sha"],1]'
    done
}

@test "pr-loop treats CI as a gate: a red result returns ciState red before codex and after every fix" {
    run grep -c "ci.state !== 'green'" "${PR_LOOP}"
    assert_output "2"
    run grep -c "ciState: 'red'" "${PR_LOOP}"
    assert_output "2"
}

@test "pr-loop (node): explicit full preserves the default structured review contract (#310)" {
    local default
    default="$(_pl_run '{}')"
    run _pl_run '{"mode":"full"}'
    assert_success
    assert_output "${default}"
    run jq -cr '[.error, .result.codexVerdict, (.calls[] | select(.label | startswith("review:")) | .schema.properties.verdict.enum)]' <<<"${output}"
    assert_output '[null,"mergeable",["mergeable","blocked","no-output"]]'
}

@test "pr-loop (node): full stops without fixes when review returns no-output (#310)" {
    local mode implementer
    for mode in '{}' '{"mode":"full"}'; do
        for implementer in codex claude; do
            run _pl_run "$(jq -cn --argjson mode "${mode}" --arg i "${implementer}" '$mode + {implementer:$i}')" \
                '{"verdict":"no-output","blocking":[],"nonBlocking":[],"answer":""}'
            assert_success
            run jq -cr '[.error, (.result.codexVerdict != "mergeable"), (.result.blockingLeft | length > 0), ([.calls[] | select(.label | test("^(fix:|codex-fix:)"))] | length), .result.rounds]' <<<"${output}"
            assert_output '[null,true,true,0,0]'
        done
    done
}

@test "pr-loop (node): full stops without fixes when review returns null (#310)" {
    local mode implementer
    for mode in '{}' '{"mode":"full"}'; do
        for implementer in codex claude; do
            run _pl_run "$(jq -cn --argjson mode "${mode}" --arg i "${implementer}" '$mode + {implementer:$i}')" 'null'
            assert_success
            run jq -cr '[.error, (.result.codexVerdict != "mergeable"), (.result.blockingLeft | length > 0), ([.calls[] | select(.label | test("^(fix:|codex-fix:)"))] | length), .result.rounds]' <<<"${output}"
            assert_output '[null,true,true,0,0]'
        done
    done
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
    mkdir -p "${stub}" "${WORK}" "${BATS_TEST_TMPDIR}/repo" "${BATS_TEST_TMPDIR}/worktree/n"
    cat > "${stub}/gh" <<SH
#!/bin/sh
case " \$* " in
    *" issue view "*" --json body "*)
        [ -e "${BATS_TEST_TMPDIR}/gh.fail" ] && exit 1
        cat "${BATS_TEST_TMPDIR}/body.md" ;;
    *" pr view "*) echo abc ;;
esac
exit 0
SH
    cat > "${stub}/git" <<'SH'
#!/bin/sh
case "$1" in
    rev-parse) echo abc ;;
    ls-remote) printf 'abc\trefs/heads/b\n' ;;
esac
SH
    chmod +x "${stub}/gh" "${stub}/git"
    local replies='{"stage-check:Implement": {"evidence":"{\"status\":\"\",\"localHead\":\"abc\",\"remoteHead\":\"abc\",\"prHead\":\"abc\",\"errors\":\"\"}"}, "stage-check:Fix": {"evidence":"{\"status\":\"\",\"localHead\":\"def\",\"remoteHead\":\"def\",\"prHead\":\"def\",\"errors\":\"\"}"}, "locate:": {"pr": 7, "sha": "abc"}, "ci:": {"state": "green", "sha": "abc", "detail": ""}}'
    (cd "${WORK}" && PATH="${stub}:${PATH}" node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        "$(jq -cn --arg d "${BATS_TEST_TMPDIR}/repo" '{repo:"o/r",repoDir:$d,issue:238,branch:"b",name:"n",task:"t",implementer:"claude"}')" \
        "${replies}" exec)
}

# rc of the played step that writes scope-r1.md.
_pl_scope_rc() { jq -r '[.ran[] | select(.cmd | contains("> scope-r1.md")) | .rc] | first' <<<"$1"; }

_pl_run() {
    local extra="${1:-}"
    [[ -n "${extra}" ]] || extra='{}'
    local replies='{"implement:": {"status":"ready"}, "stage-check:Implement": {"evidence":"{\"status\":\"\",\"localHead\":\"abc\",\"remoteHead\":\"abc\",\"prHead\":\"abc\",\"errors\":\"\"}"}, "locate:": {"pr": 7, "sha": "abc"}, "ci:": {"state": "green", "sha": "abc", "detail": ""}, "review:": {"verdict": "mergeable", "blocking": [], "nonBlocking": [], "answer": "可合併"}}'
    if [[ $# -ge 2 ]]; then
        replies="$(jq -c --argjson review "$2" '.["review:"] = $review' <<<"${replies}")"
    fi
    node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        "$(jq -cn --argjson extra "${extra}" '{repo:"o/r",repoDir:"/work",issue:283,branch:"b",name:"n",task:"t"} + $extra')" \
        "${replies}"
}

_pl_blocked_run() {
    local implementer="$1"
    local replies='{"stage-check:Implement": {"evidence":"{\"status\":\"\",\"localHead\":\"abc\",\"remoteHead\":\"abc\",\"prHead\":\"abc\",\"errors\":\"\"}"}, "stage-check:Fix": {"evidence":"{\"status\":\"\",\"localHead\":\"def\",\"remoteHead\":\"def\",\"prHead\":\"def\",\"errors\":\"\"}"}, "locate:": {"pr": 7, "sha": "abc"}, "ci:": {"state": "green", "sha": "abc", "detail": ""}, "review:": {"verdict": "blocked", "blocking": ["broken"], "nonBlocking": [], "answer": "不可合併"}}'
    node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        "$(jq -cn --arg implementer "${implementer}" '{repo:"o/r",repoDir:"/work",issue:283,branch:"b",name:"n",task:"t",maxRounds:1,implementer:$implementer}')" \
        "${replies}"
}

@test "pr-loop (node): neither implementer path produces attribution instructions" {
    local implementer
    for implementer in codex claude; do
        run _pl_run "{\"implementer\":\"${implementer}\",\"sessionUrl\":\"https://example.invalid/session\"}"
        assert_success
        run jq -e '[.calls[].prompt | test("Co-Authored-By|Claude-Session|Generated with")] | any | not' <<<"${output}"
        assert_success
        assert_output "true"
    done
}

@test "pr-loop (node): codex is the default implementer and Claude reviews with shared guardrails" {
    run _pl_run
    assert_success
    run jq -cr '[.error, (.calls[] | select(.label | startswith("implement:")) | .prompt | contains("codex exec --skip-git-repo-check -C /work/../worktree/n -o /work/../worktree/.scratch/n/implement.md \"$(cat <暫存檔>)\" < /dev/null")), (.calls[] | select(.label | startswith("implement:")) | .prompt | contains("Work ONLY inside /work/../worktree/n")), (.calls[] | select(.label | startswith("review:")) | .prompt | contains("Run ONE codex re-verification") | not)]' <<<"${output}"
    assert_output '[null,true,true,true]'
}

@test "pr-loop (node): codex wrapper creates the worktree before exec and omits setup from the brief" {
    run _pl_run
    assert_success
    run jq -cr '(.calls[] | select(.label | startswith("implement:")) | .prompt) as $p | (($p | index("git worktree add -b b /work/../worktree/n origin/main")) < ($p | index("codex exec --skip-git-repo-check -C /work/../worktree/n"))) and (($p | split("brief:\n")[1]) | contains("git worktree add") | not)' <<<"${output}"
    assert_output 'true'
}

@test "pr-loop (node): implementer claude keeps the existing Claude implement and codex review tracks" {
    run _pl_run '{"implementer":"claude"}'
    assert_success
    run jq -cr '[.error, (.calls[] | select(.label | startswith("implement:")) | .prompt | contains("codex exec --skip-git-repo-check -C") | not), (.calls[] | select(.label | startswith("implement:")) | .prompt | contains("Setup: cd /work && git fetch origin")), (.calls[] | select(.label | startswith("review:")) | .prompt | contains("Run ONE codex re-verification"))]' <<<"${output}"
    assert_output '[null,true,true,true]'
}

@test "pr-loop (node): Fix rounds return to the selected implementer" {
    run _pl_blocked_run codex
    assert_success
    run jq -r '.calls[] | select(.label | startswith("fix:")) | .prompt | contains("codex exec --skip-git-repo-check -C /work/../worktree/n")' <<<"${output}"
    assert_output 'true'

    run _pl_blocked_run claude
    assert_success
    run jq -r '.calls[] | select(.label | startswith("fix:")) | .prompt | contains("codex exec --skip-git-repo-check -C")' <<<"${output}"
    assert_output 'false'
}

@test "pr-loop (node): each implementer loads its TDD instructions for Implement and Fix" {
    run _pl_run
    assert_success
    run jq -cr '.calls[] | select(.label | startswith("implement:")) | (.prompt | split("brief:\n")[1]) | [contains("read .agents/skills/tdd/SKILL.md first and follow it"), contains("issue 驗收 section as the approved behaviour list"), contains("do not ask the maintainer"), contains("each behaviour one test+implementation commit, or an adjacent RED commit then GREEN commit"), contains("Never put a batch of tests in one commit")]' <<<"${output}"
    assert_output '[true,true,true,true,true]'

    run _pl_blocked_run codex
    assert_success
    run jq -cr '.calls[] | select(.label | startswith("fix:")) | (.prompt | split("brief:\n")[1]) | [contains("read .agents/skills/tdd/SKILL.md first and follow it"), contains("issue 驗收 section as the approved behaviour list"), contains("do not ask the maintainer"), contains("each behaviour one test+implementation commit, or an adjacent RED commit then GREEN commit"), contains("Never put a batch of tests in one commit")]' <<<"${output}"
    assert_output '[true,true,true,true,true]'

    run _pl_run '{"implementer":"claude"}'
    assert_success
    run jq -cr '.calls[] | select(.label | startswith("implement:")) | .prompt | [contains("use the Skill tool to load the tdd skill first and follow it"), contains("issue 驗收 section as the approved behaviour list"), contains("do not ask the maintainer"), contains("each behaviour one test+implementation commit, or an adjacent RED commit then GREEN commit"), contains("Never put a batch of tests in one commit")]' <<<"${output}"
    assert_output '[true,true,true,true,true]'

    run _pl_blocked_run claude
    assert_success
    run jq -cr '.calls[] | select(.label | startswith("fix:")) | .prompt | [contains("use the Skill tool to load the tdd skill first and follow it"), contains("issue 驗收 section as the approved behaviour list"), contains("do not ask the maintainer"), contains("each behaviour one test+implementation commit, or an adjacent RED commit then GREEN commit"), contains("Never put a batch of tests in one commit")]' <<<"${output}"
    assert_output '[true,true,true,true,true]'
}

@test "pr-loop (node): Implement and Fix run only slice specs locally, then lint and changed before push" {
    local implementer
    for implementer in codex claude; do
        run _pl_run "{\"implementer\":\"${implementer}\"}"
        assert_success
        run jq -e '[.calls[] | select(.label | startswith("implement:")) | .prompt |
            contains("just test <tier> <spec> [--filter]"),
            contains("before pushing run just test lint and just test changed"),
            contains("Never run a whole tier locally; CI runs every tier"),
            (contains("just test unit, just test integration") | not)] | all' <<<"${output}"
        assert_success
        assert_output "true"

        run _pl_blocked_run "${implementer}"
        assert_success
        run jq -e '[.calls[] | select(.label | startswith("fix:")) | .prompt |
            contains("just test <tier> <spec> [--filter]"),
            contains("before pushing run just test lint and just test changed"),
            contains("Never run a whole tier locally; CI runs every tier"),
            (contains("just test unit, just test integration") | not)] | all' <<<"${output}"
        assert_success
        assert_output "true"
    done
}

@test "pr-loop (node): Implement and Fix preserve pushed history except for the commit-email remedy" {
    local implementer
    for implementer in codex claude; do
        run _pl_run "{\"implementer\":\"${implementer}\"}"
        assert_success
        run jq -e '[.calls[] | select(.label | startswith("implement:")) | .prompt |
            contains("Never rewrite pushed commits: no rebase, amend, reset, or force push of pushed history"),
            contains("The only exception is the commit-email remedy from #234: rewrite pushed commits only to fix a non-noreply author, then push with --force-with-lease"),
            contains("Only add new commits; sync with main by merging")] | all' <<<"${output}"
        assert_success
        assert_output "true"

        run _pl_blocked_run "${implementer}"
        assert_success
        run jq -e '[.calls[] | select(.label | startswith("fix:")) | .prompt |
            contains("Never rewrite pushed commits: no rebase, amend, reset, or force push of pushed history"),
            contains("The only exception is the commit-email remedy from #234: rewrite pushed commits only to fix a non-noreply author, then push with --force-with-lease"),
            contains("Only add new commits; sync with main by merging")] | all' <<<"${output}"
        assert_success
        assert_output "true"
    done
}

@test "pr-loop (node): both reviewers block horizontal history and non-behaviour tests" {
    local implementer
    for implementer in codex claude; do
        run _pl_run "{\"implementer\":\"${implementer}\"}"
        assert_success
        run jq -cr '.calls[] | select(.label | startswith("review:")) | .prompt | [contains("commit history is vertical slices"), contains("tests verify behaviour through the public interface"), contains("Structure- or implementation-detail tests are blocking")]' <<<"${output}"
        assert_output '[true,true,true]'
    done
}

@test "pr-loop (node): codex implement and fix detach, wait in bounded chunks, clean containers, and fail on rc" {
    run _pl_run
    assert_success
    run jq -cr '.calls[] | select(.label | startswith("implement:")) | [(.prompt | contains("setsid nohup")), (.prompt | contains("implement.rc")), (.prompt | contains("timeout 540 bash -c")), (.prompt | contains("docker ps") and contains("/work/../worktree/n") and contains("docker stop")), (.prompt | contains("tail") and contains("implement.md")), (.prompt | contains("run this exact command shape in the foreground") | not)]' <<<"${output}"
    assert_output '[true,true,true,true,true,true]'

    run _pl_blocked_run codex
    assert_success
    run jq -cr '.calls[] | select(.label | startswith("fix:")) | [(.prompt | contains("setsid nohup")), (.prompt | contains("fix-r1.rc")), (.prompt | contains("timeout 540 bash -c")), (.prompt | contains("docker ps") and contains("/work/../worktree/n") and contains("docker stop")), (.prompt | contains("tail") and contains("fix-r1.md")), (.prompt | contains("run this exact command shape in the foreground") | not)]' <<<"${output}"
    assert_output '[true,true,true,true,true,true]'
}

@test "pr-loop (node): codex implement and fix prompts use codex identity without attribution" {
    run _pl_run
    assert_success
    run jq -cr '.calls[] | select(.label | startswith("implement:")) | [(.prompt | contains("Co-Authored-By") | not), (.prompt | contains("Generated with") | not), (.prompt | contains("[claude] 採納") | not), (.prompt | contains("beyond the task") | not), (.prompt | contains("[codex]"))]' <<<"${output}"
    assert_output '[true,true,true,true,true]'

    run _pl_blocked_run codex
    assert_success
    run jq -cr '.calls[] | select(.label | startswith("fix:")) | [(.prompt | contains("Co-Authored-By") | not), (.prompt | contains("Generated with") | not), (.prompt | contains("[claude] 採納") | not), (.prompt | contains("beyond the task") | not), (.prompt | contains("[codex] 採納第 1 輪:"))]' <<<"${output}"
    assert_output '[true,true,true,true,true]'
}

@test "pr-loop (node): an invalid implementer value throws a clear error" {
    run _pl_run '{"implementer":"other"}'
    assert_success
    run jq -r '.error' <<<"${output}"
    assert_output 'pr-loop: args.implementer must be "codex" or "claude", got "other"'
}

@test "pr-loop (node): codex quota off rejects codex implementation and does not gate Claude review" {
    run _pl_run '{"implementer":"codex","codex":"off"}'
    assert_success
    run jq -r '.error' <<<"${output}"
    assert_output 'pr-loop: args.codex "off" cannot use implementer "codex"; use implementer: "claude"'

    run _pl_run '{"implementer":"codex","codex":"on"}'
    assert_success
    run jq -cr '[.error, (.calls[] | select(.label | startswith("review:")) | .prompt | contains("Review PR #7") and (contains("Run ONE codex re-verification") | not)), ([.calls[] | select(.label | startswith("nocodex:"))] | length)]' <<<"${output}"
    assert_output '[null,true,0]'
}

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
    run jq -r '.calls[] | select(.label | startswith("review:")) | .prompt' <<<"${output}"
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
    run grep -cF "const WORKTREE_ROOT = \`\${REPO_DIR}/../worktree\`" "${PR_LOOP}"
    assert_output "1"
    run grep -c "const REPO_DIR = A.repoDir$" "${PR_LOOP}" "${FANOUT}"
    assert_output --partial "pr-loop.js:1"
    assert_output --partial "milestone-fanout.js:1"
    run grep -n 'sessionUrl' "${PR_LOOP}" "${FANOUT}" "${REPO_ROOT}/doc/workflow.md"
    assert_failure 1
    assert_output ""
}

@test "milestone-fanout (node): neither implementer path forwards sessionUrl or produces attribution instructions" {
    local implementer replies
    replies='{"locate:":{"pr":7,"sha":"abc"},"ci:":{"state":"green","sha":"abc","detail":""},"review:":{"verdict":"mergeable","blocking":[],"nonBlocking":[],"answer":"可合併"}}'
    for implementer in codex claude; do
        run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${FANOUT}" \
            "{\"repo\":\"o/r\",\"repoDir\":\"${REPO_ROOT}\",\"implementer\":\"${implementer}\",\"sessionUrl\":\"legacy\",\"items\":[{\"issue\":269,\"branch\":\"b\",\"name\":\"n\",\"task\":\"t\"}]}" "${replies}"
        assert_success
        run jq -e '.error == null and (.workflowCalls | length == 1) and (.workflowCalls[0].args | has("sessionUrl") | not) and ([.calls[].prompt | test("Co-Authored-By|Claude-Session|Generated with")] | any | not)' <<<"${output}"
        assert_success
        assert_output "true"
    done
}

@test "milestone-fanout requires repoDir, validates every item, delegates to pr-loop, and logs each result" {
    run grep -c "!A.repo || !A.repoDir" "${FANOUT}"
    assert_output "1"
    run grep -c "for (const k of \['issue', 'branch', 'name', 'task'\])" "${FANOUT}"
    assert_output "1"
    run grep -c "workflow({ scriptPath: SCRIPT }" "${FANOUT}"
    assert_output "1"
    run grep -c 'REPO_DIR}/.claude/workflows/pr-loop.js' "${FANOUT}"
    assert_output "1"
    run grep -c 'item.issue} done:' "${FANOUT}"
    assert_output "1"
}

# Execute the fanout template at the Workflow tool seam, recording child batches.
_fanout_batches() {
    node --input-type=module - "${FANOUT}" "$1" <<'JS'
import { readFileSync } from 'node:fs'
const [path, options] = process.argv.slice(2)
const items = Array.from({ length: 23 }, (_, i) => ({ issue: i + 1, branch: `b${i}`, name: `n${i}`, task: 't' }))
const args = { repo: 'o/r', repoDir: '/work', items, ...JSON.parse(options) }
const batches = [], children = [], logs = []
const parallel = async fns => {
  batches.push(fns.length)
  return Promise.all(fns.map(fn => fn()))
}
const workflow = async (options, args) => {
  children.push({ options, args })
  await Promise.resolve()
  return { issue: args.issue, pr: args.issue, ciState: 'green', codexVerdict: 'mergeable', rounds: 0 }
}
const body = readFileSync(path, 'utf8').replace(/^export const meta/m, 'const meta')
const run = new (async () => {}).constructor('args', 'parallel', 'workflow', 'phase', 'log', body)
try {
  const result = await run(args, parallel, workflow, () => {}, message => logs.push(message))
  console.log(JSON.stringify({ result, batches, children, logs, error: null }))
} catch (error) {
  console.log(JSON.stringify({ error: error.message, batches, children }))
}
JS
}

@test "milestone-fanout (node): defaults to ten children per batch and returns every result" {
    run _fanout_batches '{}'
    assert_success
    run jq -e '.error == null and .batches == [10,10,3] and [.result[].issue] == [range(1;24)] and (.children | length == 23) and ([.children[].args.implementer] | all(. == "codex")) and ([.logs[] | select(contains(" done:"))] | length == 23)' <<<"${output}"
    assert_success
    assert_output "true"
}

@test "milestone-fanout (node): honors custom positive concurrency and forwards implementer" {
    local config expected
    for config in 1 4 30; do
        expected=$(jq -cn --argjson n "${config}" '[range(0;23;$n) | [($n), (23 - .)] | min]')
        run _fanout_batches "{\"concurrency\":${config},\"implementer\":\"claude\"}"
        assert_success
        run jq -e --argjson expected "${expected}" '.error == null and .batches == $expected and [.result[].issue] == [range(1;24)] and ([.children[].args.implementer] | all(. == "claude"))' <<<"${output}"
        assert_success
        assert_output "true"
    done
}

@test "milestone-fanout (node): rejects invalid concurrency before starting children" {
    local value
    for value in 1.5 0 -1 '"4"' null true false '[]' '{}' '1e400'; do
        run _fanout_batches "{\"concurrency\":${value}}"
        assert_success
        run jq -e '.error == "milestone-fanout: args.concurrency must be a positive integer" and .batches == [] and .children == []' <<<"${output}"
        assert_success
        assert_output "true"
    done
}

@test "milestone-fanout (node): forwards configured gates and leaves omitted gates unset" {
    local replies
    replies='{"locate:":{"pr":7,"sha":"abc"},"ci:":{"state":"green","sha":"abc","detail":""},"review:":{"verdict":"mergeable","blocking":[],"nonBlocking":[],"answer":"可合併"}}'
    run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${FANOUT}" \
        "{\"repo\":\"o/r\",\"repoDir\":\"${REPO_ROOT}\",\"items\":[{\"issue\":300,\"branch\":\"with-gates\",\"name\":\"with\",\"task\":\"t\",\"gates\":\"just test lint\"},{\"issue\":301,\"branch\":\"without-gates\",\"name\":\"without\",\"task\":\"t\"}]}" "${replies}"
    assert_success
    run jq -e '.error == null and (.workflowCalls | length == 2) and .workflowCalls[0].args.gates == "just test lint" and (.workflowCalls[1].args | has("gates") | not)' <<<"${output}"
    assert_success
    assert_output "true"
}

# Run research-verify under node (test/unit/fixture/workflow_run.mjs) with
# args $1 and agent replies $2; $3 = exec plays each agent's shell steps.
_rv_run() {
    if [[ "${3:-}" == exec ]]; then
        _rv_model_fixture "$1"
    fi
    node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${RESEARCH}" "$1" "$2" ${3:+"$3"}
}

# Install the real resolver in a throwaway checkout and let old agy stubs
# keep modelling research, while discovery has its own configurable output.
_rv_model_fixture() {
    local dir stub="${BATS_TEST_TMPDIR}/bin"
    dir="$(jq -r '.repoDir' <<<"$1")"
    [[ "${dir}" == "${BATS_TEST_TMPDIR}/"* && -d "${dir}/.git" ]] || return 1
    mkdir -p "${dir}/.agents/script/research" "${dir}/lib"
    cp "${REPO_ROOT}/.agents/script/research/agy-model.sh" "${dir}/.agents/script/research/"
    cp "${REPO_ROOT}/lib/log.sh" "${dir}/lib/"
    printf '\n/.agents/\n/lib/\n' >> "${dir}/.git/info/exclude"
    [[ -f "${stub}/agy" ]] || return 0
    if grep -qF 'RV_MODEL_LIST' "${stub}/agy"; then
        return 0
    fi
    mv "${stub}/agy" "${stub}/agy-research"
    cat > "${stub}/agy" <<'SH'
#!/bin/sh
if [ "$1" = models ]; then
    if [ -n "${RV_MODEL_LIST:-}" ]; then
        cat "$RV_MODEL_LIST"
        exit "${RV_MODELS_RC:-0}"
    fi
    printf 'gemini-3.10-flash-high\tGemini 3.10 Flash (High)\n'
    exit 0
fi
exec "$(dirname "$0")/agy-research" "$@"
SH
    chmod +x "${stub}/agy"
}

@test "research-verify resolves a fresh model before each agy research call" {
    local dir="${BATS_TEST_TMPDIR}/repo" json cmd
    local newest_list="${BATS_TEST_TMPDIR}/models"
    _rv_stubs
    _rv_stub agy 'printf "%s\n" "$@" > agy.args; echo "1. claim [official https://x]"'
    git init -q "${dir}"
    printf 'gemini-3.10-flash-high\tGemini 3.10 Flash (High)\n' > "${newest_list}"
    RV_MODEL_LIST="${newest_list}" PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "$(_rv_ok_replies)" exec
    assert_success
    json="${output}"
    run jq -r '.result.status' <<<"${json}"
    assert_output recorded
    run grep -A1 -x -- --model "${dir}/../worktree/.scratch/research-7/agy.args"
    assert_output "$(printf '%s\n' --model gemini-3.10-flash-high)"
    printf 'gemini-3.11-flash-high\tGemini 3.11 Flash (High)\n' > "${newest_list}"
    cmd="$(jq -r '.ran[].cmd | select(contains("timeout 960 agy"))' <<<"${json}")"
    RV_MODEL_LIST="${newest_list}" PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run bash -c "${cmd}"
    assert_success
    run grep -A1 -x -- --model "${dir}/../worktree/.scratch/research-7/agy.args"
    assert_output "$(printf '%s\n' --model gemini-3.11-flash-high)"
}

@test "research-verify reports discovery failure without invoking agy research" {
    local dir="${BATS_TEST_TMPDIR}/repo"
    local failed_list="${BATS_TEST_TMPDIR}/models"
    _rv_stubs
    _rv_stub agy 'echo called > agy-called; echo "1. claim [official https://x]"'
    git init -q "${dir}"
    printf 'gemini-3.10-flash-high\tGemini 3.10 Flash (High)\n' > "${failed_list}"
    RV_MODEL_LIST="${failed_list}" RV_MODELS_RC=7 PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "$(_rv_ok_replies)" exec
    assert_success
    run jq -r '.result.status, (.calls | length)' <<<"${output}"
    assert_output "$(printf '%s\n' agy-failed 2)"
    assert [ ! -e "${dir}/../worktree/.scratch/research-7/agy-called" ]
    assert [ ! -e "${BATS_TEST_TMPDIR}/gh.calls" ]
}

@test "research-verify records the resolved model in the research comment" {
    local dir="${BATS_TEST_TMPDIR}/repo"
    _rv_stubs
    git init -q "${dir}"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "$(_rv_ok_replies)" exec
    assert_success
    run jq -r '.result.status' <<<"${output}"
    assert_output recorded
    run grep -A1 -x 'agy 實際使用模型:' "${dir}/../worktree/.scratch/research-7/body-1.md"
    assert_output "$(printf '%s\n' 'agy 實際使用模型:' gemini-3.10-flash-high)"
}

# Agent replies of a run where every step succeeds.
_rv_ok_replies() {
    cat <<'JSON'
{"nonce:": {"nonce": "0123456789abcdef"},
 "agy:": {"status": "ok", "attempts": 1, "detail": "agy.md 10 bytes"},
 "claude-verify:": {"claims": [{"claim": "c1", "verdict": "supported", "basis": "b1"}]},
 "codex-verify:": {"status": "ok", "detail": "codex.md 9 bytes"},
 "synthesize:": {"verified": ["v1"], "refuted": [], "needsExperiment": [], "recommendation": "r1", "parameters": []},
 "record:": {"url": "https://github.com/o/r/issues/7#issuecomment-1"},
 "repo-check:": {"extra": []}}
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
    # one fail-closed validator per free-form input
    local fn
    for fn in checkQuestion checkContext checkSources checkCommentUrl; do
        run grep -c "^const ${fn} = " "${RESEARCH}"
        assert_output "1"
    done
}

# Run research-verify with the base args plus jq assignment $1; print .error.
_rv_err() {
    _rv_run "$(jq -cn "{repo:\"o/r\",repoDir:\"/w\",issue:7,question:\"q\"} | ${1}")" "$(_rv_ok_replies)" | jq -r '.error'
}

@test "research-verify (node): question must be a non-blank string (missing, object, array, number, empty, whitespace)" {
    local set
    for set in 'del(.question)' '.question = ""'; do
        run _rv_err "${set}"
        assert_output "research-verify: args.question is required"
    done
    for set in '.question = {"a":1}' '.question = ["q"]' '.question = 5' '.question = " \t\n"'; do
        run _rv_err "${set}"
        assert_output --partial "research-verify: args.question must be a non-blank string"
    done
    run _rv_err '.question = "why?"'
    assert_output "null"
}

@test "research-verify (node): context, when given, must be a non-blank string" {
    local set
    for set in '.context = {"a":1}' '.context = ["c"]' '.context = 5' '.context = ""' '.context = "  "' '.context = null'; do
        run _rv_err "${set}"
        assert_output --partial "research-verify: args.context must be a non-blank string when given"
    done
    run _rv_err '.'
    assert_output "null"
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q","context":"ctx-9"}' "$(_rv_ok_replies)"
    run jq -r '.error, ((.calls[] | select(.label | startswith("agy:")) | .prompt) | contains("背景:ctx-9"))' <<<"${output}"
    assert_output "$(printf '%s\n' null true)"
}

@test "research-verify (node): sources must be an array of safe absolute paths (type, empty, relative, control chars)" {
    local set
    for set in '.sources = "/a"' '.sources = {"a":1}' '.sources = 5' '.sources = null'; do
        run _rv_err "${set}"
        assert_output --partial "research-verify: args.sources must be an array of absolute paths"
    done
    for set in '.sources = [5]' '.sources = [""]' '.sources = ["  "]' '.sources = ["rel/x"]' \
               '.sources = ["/ok", "./x"]' '.sources = ["/a\nb"]' '.sources = ["/a`b"]'; do
        run _rv_err "${set}"
        assert_output --partial "must be an absolute path without control characters or backticks"
    done
    run _rv_err '.sources = ["/ok", "./x"]'
    assert_output --partial "research-verify: args.sources[1] "
    run _rv_err '.sources = []'
    assert_output "null"
    run _rv_err '.sources = ["/abs/path with space"]'
    assert_output "null"
}

# The source check command the Research prompt tells the agent to run first.
_rv_src_check() {
    _rv_run "$(jq -cn --args '{repo:"o/r",repoDir:"/w",issue:7,question:"q",sources:$ARGS.positional}' "$@")" "$(_rv_ok_replies)" \
        | jq -r '.calls[] | select(.label | startswith("agy:")) | .prompt' | grep -o 'cd / && for f in [^`]*'
}

@test "research-verify (node): Research checks every source exists and is readable before agy, and says bad-source" {
    local d="${BATS_TEST_TMPDIR}/src" cmd
    mkdir -p "${d}/a dir"
    printf 'x\n' > "${d}/f 1"
    cmd="$(_rv_src_check "${d}/f 1" "${d}/a dir")"
    run bash -c "${cmd}"
    assert_success
    cmd="$(_rv_src_check "${d}/f 1" "${d}/missing")"
    run bash -c "${cmd}"
    assert_failure 3
    assert_output "research-verify: args.sources: not readable: ${d}/missing"
    run _rv_run "$(jq -cn --arg s "${d}/f 1" '{repo:"o/r",repoDir:"/w",issue:7,question:"q",sources:[$s]}')" "$(_rv_ok_replies)"
    run jq -r '.calls[] | select(.label | startswith("agy:")) | .prompt' <<<"${output}"
    assert_output --partial 'return status "bad-source"'
    # no sources: no check step
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_ok_replies)"
    run jq -r '.calls[] | select(.label | startswith("agy:")) | .prompt | contains("cd / && for f in")' <<<"${output}"
    assert_output "false"
}

@test "research-verify (node): an unreadable source fails the source check (checked as an unprivileged user)" {
    local d cmd
    d="$(mktemp -d /tmp/rv-src.XXXXXX)"
    chmod 755 "${d}"
    printf 'x\n' > "${d}/ok"
    printf 'x\n' > "${d}/locked"
    chmod 644 "${d}/ok"
    chmod 000 "${d}/locked"
    local -a as_user=(bash -c)
    if [[ "$(id -u)" -eq 0 ]]; then as_user=(su nobody -s /bin/bash -c); fi
    cmd="$(_rv_src_check "${d}/ok")"
    run "${as_user[@]}" "${cmd}"
    assert_success
    cmd="$(_rv_src_check "${d}/ok" "${d}/locked")"
    run "${as_user[@]}" "${cmd}"
    rm -rf "${d}"
    assert_failure 3
    assert_output --partial "not readable: ${d}/locked"
}

@test "research-verify (node): a bad-source reply stops before agy output is used, with sources-invalid" {
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q","sources":["/x"]}' \
        "$(_rv_with "$(_rv_ok_replies)" 'agy:' '{"status":"bad-source","attempts":0,"detail":"not readable: /x"}')"
    assert_success
    run jq -r '.result.status, .result.detail, (.calls | length)' <<<"${output}"
    assert_output "$(printf '%s\n' sources-invalid 'not readable: /x' 2)"
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
    run grep -c "enum: \['ok', 'failed', 'bad-source'\]" "${RESEARCH}"
    assert_output "1"
    run grep -c "if (!agyOk(res)) return" "${RESEARCH}"
    assert_output "1"
    run grep -c "status: 'agy-failed'" "${RESEARCH}"
    assert_output "1"
    run grep -c 'Never answer the question yourself' "${RESEARCH}"
    assert_output "1"
    # the failure return comes before the first Verify agent
    fail_line="$(grep -n "if (!agyOk(res)) return" "${RESEARCH}" | cut -d: -f1)"
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
}

@test "research-verify synthesizes a structured conclusion and records comments via --body-file" {
    run grep -c "schema: SYNTH_SCHEMA" "${RESEARCH}"
    assert_output "1"
    for k in verified refuted needsExperiment recommendation parameters; do
        run grep -c "${k}: {" "${RESEARCH}"
        assert_output "1"
    done
    run grep -c 'gh issue comment ' "${RESEARCH}"
    assert [ "${output}" -ge 1 ]
    run grep -c 'COMMENT_LIMIT = 60000' "${RESEARCH}"
    assert_output "1"
}

@test "research-verify keeps its files outside repoDir, hardcodes no machine path, and never merges or pushes" {
    run grep -nE '/tmp/claude-|/home/[a-z]+/|claude.ai/code/session_' "${RESEARCH}"
    assert_failure
    run grep -c "const REPO_DIR = A.repoDir$" "${RESEARCH}"
    assert_output "1"
    run grep -cF "const WORKTREE_ROOT = \`\${REPO_DIR}/../worktree\`" "${RESEARCH}"
    assert_output "1"
    run grep -nE 'gh pr merge|/merge|mergePullRequest|HEAD:main|git push|--auto' "${RESEARCH}"
    assert_failure
}

@test "research-verify (node): a repoDir with spaces and shell metacharacters is quoted, never executed, and every step runs" {
    local stub="${BATS_TEST_TMPDIR}/bin" dir scratch
    mkdir -p "${stub}"
    printf '#!/bin/sh\necho "1. agy-claim [官方文件 https://x]"\n' > "${stub}/agy"
    printf '#!/bin/sh\ncat >/dev/null\nprintf "banner\\ncodex\\ncodex-verdict-line\\ntokens used\\n5\\n"\n' > "${stub}/codex"
    cat > "${stub}/gh" <<'SH'
#!/bin/sh
[ "$1 $2" = "issue view" ] && { echo '{"comments":[]}'; exit; }
printf '%s\n' "$@" > "${BATS_TEST_TMPDIR}/gh.args"
echo "https://github.com/o/r/issues/7#issuecomment-1"
SH
    chmod +x "${stub}"/*
    dir="${BATS_TEST_TMPDIR}/dir with space/\$(touch ${BATS_TEST_TMPDIR}/pwned);x'q"
    scratch="${dir}/../worktree/.scratch/research-7"
    git init -q "${dir}"
    PATH="${stub}:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "$(_rv_ok_replies)" exec
    assert_success
    local json="${output}"
    run jq -r '.error, .result.status' <<<"${json}"
    assert_output "$(printf '%s\n' null recorded)"
    # repo status before + mkdir (one step), agy, codex run, codex extraction,
    # body build, gh, repo status after: every one ran and passed
    run jq -r '[.ran[].rc] | map(tostring) | join(" ")' <<<"${json}"
    assert_output "0 0 0 0 0 0 0 0"
    [[ -f "${scratch}/status-before.txt" ]]
    [[ -f "${scratch}/repo-extra.txt" && ! -s "${scratch}/repo-extra.txt" ]]
    [[ ! -e "${BATS_TEST_TMPDIR}/pwned" ]]
    [[ -s "${scratch}/agy.md" ]]
    run cat "${scratch}/codex.md"
    assert_output "codex-verdict-line"
    run grep -c '^\[claude\] codex 逐條驗證(原文)$' "${scratch}/body-1.md"
    assert_output "1"
    run cat "${BATS_TEST_TMPDIR}/gh.args"
    assert_output "$(printf '%s\n' issue comment 7 --repo o/r --body-file body-1.md)"
}

# The [codex] section of the Record body $1: the lines between the
# codex header and the agy header, blank edges dropped.
_rv_codex_section() {
    awk '/^\[claude\] codex /{f=1;next} /^\[claude\] agy /{f=0} f' "$1" | sed '/./,$!d; s/^> //'
}

# Run research-verify with every step played (exec) under repoDir $1 and
# args $2 (merged into the base args); codex is a stub that prints
# ${SHAPE}/raw (stdout + stderr of a real run) and, when ${SHAPE}/last
# exists, writes it to the -o (--output-last-message) file. A dir in
# ${RV_OVERRIDE} comes before these stubs in PATH. Leaves the scratch dir
# of issue 7 under $1.
_rv_run_shape() {
    local stub="${BATS_TEST_TMPDIR}/bin"
    git init -q "$1"
    mkdir -p "${stub}"
    printf '#!/bin/sh\necho "1. agy-claim [原始碼 %s/agy-src]"\n' "$1" > "${stub}/agy"
    cat > "${stub}/codex" <<'SH'
#!/bin/sh
cat >/dev/null
o=
while [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done
[ -f "${SHAPE}/last" ] && [ -n "${o}" ] && cp "${SHAPE}/last" "${o}"
cat "${SHAPE}/raw"
SH
    cat > "${stub}/gh" <<'SH'
#!/bin/sh
[ "$1 $2" = "issue view" ] && { echo '{"comments":[]}'; exit; }
echo https://github.com/o/r/issues/7#issuecomment-1
SH
    chmod +x "${stub}"/*
    PATH="${RV_OVERRIDE:+${RV_OVERRIDE}:}${stub}:${PATH}" _rv_run "$(jq -cn --arg d "$1" --argjson a "$2" '{repo:"o/r",repoDir:$d,issue:7,question:"q"} + $a')" "$(_rv_ok_replies)" exec
}

@test "research-verify (node): the Record keeps only codex's final answer, whatever shape codex printed" {
    local dir="${BATS_TEST_TMPDIR}/w" name expected
    SHAPE="${BATS_TEST_TMPDIR}/shape"
    export SHAPE
    # name | raw output (printf format) | -o file ('-' = codex wrote none) | expected answer
    while IFS='|' read -r name raw last expected; do
        echo "shape: ${name}"   # names the failing row in the bats report
        rm -rf "${SHAPE}" "${dir}"
        mkdir -p "${SHAPE}" "${dir}/../worktree/.scratch/research-7"
        # a stale -o file of an earlier run must never be reused
        echo STALE > "${dir}/../worktree/.scratch/research-7/codex-last.md"
        printf '%b' "${raw}" > "${SHAPE}/raw"
        [[ "${last}" == - ]] || printf '%b' "${last}" > "${SHAPE}/last"
        run _rv_run_shape "${dir}" '{}'
        assert_success
        run jq -r '.result.status' <<<"${output}"
        assert_output recorded
        run _rv_codex_section "${dir}/../worktree/.scratch/research-7/body-1.md"
        assert_output "$(printf '%b' "${expected}")"
    done <<'EOF'
single|banner\ncodex\nA1\ntokens used\n5\n|-|A1
duplicated|codex\nA1\nA2\ntokens used\n5\nA1\nA2\n|-|A1\nA2
transcript|OpenAI Codex v0\nuser\nthe prompt\ncodex\ncommentary line\nexec\n/usr/bin/bash -lc pwd in /x\n succeeded in 0ms:\n/x\n\ncodex\nA1\nA2\ntokens used\n1,716\nA1\nA2\n|-|A1\nA2
answer first|A1\nReading additional input from stdin...\nuser\np\ncodex\nA1\ntokens used\n9\n|-|A1
tool logs|thinking\nplan\ncodex\nnote\nexec\nls in /x\n succeeded in 0ms:\nf\nexec\ncat f in /x\n exited 1 in 1ms:\nerr\ncodex\nA1\ntokens used\n9\n|-|A1
last message file|codex\njunk\nexec\nls\ncodex\nnot this\ntokens used\n9\nnot this\n|L1\nL2\n|L1\nL2
prose about tokens|codex\nA1\ntokens used by the build\nA2\ntokens used\n9\n|-|A1\ntokens used by the build\nA2
EOF
}

@test "research-verify (node): a codex run with no final answer records nothing (fail closed)" {
    local dir="${BATS_TEST_TMPDIR}/w" name raw scratch
    SHAPE="${BATS_TEST_TMPDIR}/shape"
    export SHAPE
    scratch="${dir}/../worktree/.scratch/research-7"
    # name | raw output (printf format); codex writes no -o file in any row
    while IFS='|' read -r name raw; do
        echo "shape: ${name}"   # names the failing row in the bats report
        rm -rf "${SHAPE}" "${dir}"
        mkdir -p "${SHAPE}" "${scratch}"
        echo STALE > "${scratch}/codex-last.md"
        printf '%b' "${raw}" > "${SHAPE}/raw"
        run _rv_run_shape "${dir}" '{}'
        assert_success
        # codex.md stays empty, so the body is never built
        [[ -e "${scratch}/codex.md" && ! -s "${scratch}/codex.md" ]]
        [[ ! -e "${scratch}/body.md" ]]
    done <<'EOF'
commentary at EOF|user\np\ncodex\nI will read the files first\n
aborted in a tool call|codex\nlet me check\nexec\nls in /x\n succeeded in 0ms:\nf\n
aborted with an error|codex\nnote\nERROR: stream disconnected before completion\n
boundary after a tool log|codex\nlet me check\nexec\nls in /x\n succeeded in 0ms:\nf\ntokens used\n9\n
answer then aborted commentary|codex\nA1\ntokens used\n9\ncodex\nmore commentary\n
fake boundary in commentary|codex\nnote\ntokens used by the build are listed below\n
fake boundary with a count|codex\nnote\ntokens used: see below\nmore\n
EOF
}

@test "research-verify (node): a failing Record producer or filter leaves no body to post (fail closed)" {
    local dir="${BATS_TEST_TMPDIR}/w" fail="${BATS_TEST_TMPDIR}/fail" name scratch
    local cat_fail scrub_mode raw inputs posted="${BATS_TEST_TMPDIR}/posted"
    SHAPE="${BATS_TEST_TMPDIR}/shape"
    export SHAPE
    scratch="${dir}/../worktree/.scratch/research-7"
    mkdir -p "${fail}"
    # cat fails on the file named by FAIL_CAT; awk run as the path filter
    # (RV_N set) then misbehaves per SCRUB_MODE: fail = full output, exit 1;
    # empty = no output, exit 0; truncate = first line only, exit 0
    REAL_CAT="$(command -v cat)" REAL_AWK="$(command -v awk)" REAL_HEAD="$(command -v head)"
    export REAL_CAT REAL_AWK REAL_HEAD
    cat > "${fail}/cat" <<'SH'
#!/bin/sh
for a; do [ "$a" = "${FAIL_CAT}" ] && exit 1; done
exec "${REAL_CAT}" "$@"
SH
    cat > "${fail}/awk" <<'SH'
#!/bin/sh
[ -n "${RV_N}" ] || exec "${REAL_AWK}" "$@"
case "${SCRUB_MODE}" in
    fail) "${REAL_AWK}" "$@"; exit 1 ;;
    empty) "${REAL_CAT}" >/dev/null; exit 0 ;;
    truncate) "${REAL_AWK}" "$@" | "${REAL_HEAD}" -n 1; exit 0 ;;
esac
exec "${REAL_AWK}" "$@"
SH
    # codex runs in the scratch dir after the Research reset: it leaves the
    # body.md of an earlier successful build there, as a Record retry in the
    # same scratch dir would find it, then plays the recorded shape
    cat > "${fail}/codex" <<SH
#!/bin/sh
echo STALE-BODY > body.md
touch "${BATS_TEST_TMPDIR}/stale-placed"
exec "${BATS_TEST_TMPDIR}/bin/codex" "\$@"
SH
    # gh posts (records) the --body-file only when that file exists
    cat > "${fail}/gh" <<SH
#!/bin/sh
f=
while [ \$# -gt 0 ]; do [ "\$1" = --body-file ] && f=\$2; shift; done
[ -f "\${f}" ] || exit 1
"${REAL_CAT}" "\${f}" > "${posted}"
echo https://example.invalid/c/1
SH
    chmod +x "${fail}"/*
    # name | FAIL_CAT | SCRUB_MODE | codex raw output (printf format) | inputs all there
    while IFS='|' read -r name cat_fail scrub_mode raw inputs; do
        echo "failure: ${name}"   # names the failing row in the bats report
        rm -rf "${SHAPE}" "${dir}" "${posted}" "${BATS_TEST_TMPDIR}/stale-placed"
        mkdir -p "${SHAPE}" "${scratch}"
        printf '%b' "${raw}" > "${SHAPE}/raw"
        FAIL_CAT="${cat_fail}" SCRUB_MODE="${scrub_mode}" RV_OVERRIDE="${fail}" run _rv_run_shape "${dir}" '{}'
        assert_success
        # the stale body really was there before the Record
        [[ -e "${BATS_TEST_TMPDIR}/stale-placed" ]]
        # either every input was there (only the producer or the filter
        # failed) or codex left no final answer
        if [[ "${inputs}" == y ]]; then
            [[ -s "${scratch}/agy.md" && -s "${scratch}/codex.md" && -s "${scratch}/claude.md" ]]
        else
            [[ ! -s "${scratch}/codex.md" ]]
        fi
        # The body build fails even though the later repo-check may still run.
        run jq -r '[.ran[].rc] | any(. != 0)' <<<"${output}"
        assert_output "true"
        # ... leaves no body.md, stale or partial, for gh to post ...
        [[ ! -e "${scratch}/body.md" ]]
        # ... and gh posts nothing
        [[ ! -e "${posted}" ]]
    done <<'EOF'
path filter fails (non-zero exit)|-|fail|codex\nA1\ntokens used\n9\n|y
path filter prints nothing (empty output)|-|empty|codex\nA1\ntokens used\n9\n|y
codex printed nothing (empty output)|-||\n|n
path filter truncates the body (malformed output)|-|truncate|codex\nA1\ntokens used\n9\n|y
codex stopped before its answer (malformed output)|-||codex\nI will read the files first\n|n
EOF
}

@test "research-verify (node): no local absolute path reaches the Record, in any form" {
    local dir="${BATS_TEST_TMPDIR}/w" src="${BATS_TEST_TMPDIR}/pinned src/distrobox-1.8" ref="${BATS_TEST_TMPDIR}/ref/" body
    SHAPE="${BATS_TEST_TMPDIR}/shape"
    export SHAPE
    mkdir -p "${SHAPE}" "${dir}" "${src}" "${ref}"
    printf 'codex\nignored\ntokens used\n1\n' > "${SHAPE}/raw"
    {
        printf 'repo file %s/script/x.sh:3\n' "${dir}"
        printf 'repo root %s\n' "${dir}"
        printf 'not the repo %s2/k\n' "${dir}"
        printf 'source %s/lib/a.c:10\n' "${src}"
        printf 'slash-ended source %sb.md\n' "${ref}"
        printf 'home /home/alice/.config/x\n'
        printf 'other home /home/bob/proj/y and /Users/carol/z\n'
        printf 'uri file:///home/dave/w\n'
        printf 'session /tmp/claude-1000/-home-eve-ws/scratchpad/q.txt end\n'
        printf 'system /usr/bin/distrobox and /etc/passwd and /dev/null\n'
        printf 'no scheme location:/root/private and host:/srv/x and C:/Temp/y\n'
        printf 'unc \\\\server\\share\\c.txt and \\\\?\\D:\\e\n'
        printf 'mac /private/tmp/x and /var/folders/ab/T/y\n'
        printf 'root /root/.codex/log and ws /workspace/proj\n'
        printf 'wsl /mnt/c/Users/frank/a.txt\n'
        printf 'win C:\\Users\\gina\\b.txt\n'
        printf 'opt [原始碼 /opt/tool/x.c] and uri file:///srv/h\n'
        printf 'kept https://example.com/a/b and a/b and ./c and 1/2 and /\n'
    } > "${SHAPE}/last"
    HOME=/home/alice run _rv_run_shape "${dir}" "$(jq -cn --arg s "${src}" --arg r "${ref}" '{sources:[$s,$r]}')"
    assert_success
    body="${dir}/../worktree/.scratch/research-7/body-1.md"
    run _rv_codex_section "${body}"
    assert_output "$(printf '%s\n' \
        'repo file script/x.sh:3' \
        'repo root .' \
        'not the repo <path>' \
        'source distrobox-1.8/lib/a.c:10' \
        'slash-ended source ref/b.md' \
        'home ~/.config/x' \
        'other home ~/proj/y and ~/z' \
        'uri file://~/w' \
        'session <tmp> end' \
        'system <path> and <path> and <path>' \
        'no scheme location:<path> and host:<path> and C:<path>' \
        'unc <path> and <path>' \
        'mac <path> and <path>' \
        'root <path> and ws <path>' \
        'wsl <path>' \
        'win <path>' \
        'opt [原始碼 <path>] and uri file://<path>' \
        'kept https://example.com/a/b and a/b and ./c and 1/2 and /')"
    # agy's original is scrubbed the same way
    run grep -c '^1\. agy-claim \[原始碼 \./agy-src\]$' "${body}"
    assert_output "1"
    run grep -cE "/home/|/Users/|/tmp/|/private/|/var/|/root/|/workspace|/mnt/|/opt/|/srv/|/usr/|/etc/|/dev/|server|\\\\Users|${src}|${ref}" "${body}"
    assert_output "0"
    run grep -c 'comment:1/1 -->$' "${body}"
    assert_output "1"
    run grep -c '^\[claude\] agy 原文$' "${body}"
    assert_output "1"
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
    assert_output "$(printf '%s\n' agy-failed 2)"
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
    assert_output "$(printf '%s\n' recorded 'https://github.com/o/r/issues/7#issuecomment-1')"
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_with "$(_rv_ok_replies)" 'record:' '{"url":""}')"
    run jq -r '.result.status' <<<"${output}"
    assert_output "record-failed"
}

# --- codex output: local paths rewritten before posting (#233) ----------------

# Raw codex output citing the repo through every local prefix a run sees:
# $1 = repoDir, $2 = the template's scratch dir, $3 = the worktree (or '').
_codex_raw_with_paths() {
    printf 'banner\ncodex\n'
    printf -- '- %s/tree/lib/log.sh:12\n' "$2"
    [[ -n "$3" ]] && printf -- '- %s/script/x.sh:3\n' "$3"
    printf -- '- %s/doc/a.md:1\n' "$1"
    printf -- '- %s/prompt.txt\n' "$2"
    printf -- '- /elsewhere/scratchpad/tree/lib/y.sh:4\n'
    printf '可合併\ntokens used\n5\n'
}

# The answer _codex_raw_with_paths should become: repo-relative paths.
_codex_rel_answer() {
    printf -- '- lib/log.sh:12\n'
    [[ -n "$1" ]] && printf -- '- script/x.sh:3\n'
    printf -- '- doc/a.md:1\n- <scratch>/prompt.txt\n- lib/y.sh:4\n可合併\n'
}

@test "pr-loop (node): the codex answer is extracted with local paths rewritten repo-relative, and that file is posted" {
    local dir="${BATS_TEST_TMPDIR}/repo dir/\$(touch ${BATS_TEST_TMPDIR}/pwned);x'q" span
    local scratch="${dir}/../worktree/.scratch/n1" wt="${dir}/../worktree/n1"
    local replies='{"stage-check:Implement": {"evidence":"{\"status\":\"\",\"localHead\":\"abc\",\"remoteHead\":\"abc\",\"prHead\":\"abc\",\"errors\":\"\"}"}, "locate:": {"pr": 9, "sha": "abc"}, "ci:": {"state": "green", "sha": "abc", "detail": ""},
        "review:": {"verdict": "mergeable", "blocking": [], "nonBlocking": [], "answer": ""}}'
    run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,branch:"b",name:"n1",task:"t",implementer:"claude"}')" "${replies}"
    assert_success
    local prompt
    prompt="$(jq -r '.calls[] | select(.label | startswith("review:")) | .prompt' <<<"${output}")"
    span="$(jq -rn --arg p "${prompt}" '$p | [match("`(cd [^`]*> answer-r1\\.md)`").captures[0].string][0]')"
    assert [ -n "${span}" ]
    mkdir -p "${scratch}"
    _codex_raw_with_paths "${dir}" "${scratch}" "${wt}" > "${scratch}/out-r1.txt"
    run bash -c "${span}"
    assert_success
    [[ ! -e "${BATS_TEST_TMPDIR}/pwned" ]]
    run cat "${scratch}/answer-r1.md"
    assert_output "$(_codex_rel_answer wt)"
    # The comment posts that file, never the raw output.
    run grep -c 'cat answer-r1.md' <<<"${prompt}"
    assert_output "1"
}

@test "research-verify (node): codex.md has local paths rewritten repo-relative before it is posted" {
    local stub="${BATS_TEST_TMPDIR}/bin" dir scratch
    mkdir -p "${stub}"
    dir="${BATS_TEST_TMPDIR}/dir with space/\$(touch ${BATS_TEST_TMPDIR}/pwned);x'q"
    scratch="${dir}/../worktree/.scratch/research-7"
    git init -q "${dir}"
    mkdir -p "${BATS_TEST_TMPDIR}/raw"
    _codex_raw_with_paths "${dir}" "${scratch}" '' > "${BATS_TEST_TMPDIR}/raw/codex.txt"
    printf '#!/bin/sh\necho "1. agy-claim"\n' > "${stub}/agy"
    printf '#!/bin/sh\ncat >/dev/null\ncat "%s/raw/codex.txt"\n' "${BATS_TEST_TMPDIR}" > "${stub}/codex"
    printf '#!/bin/sh\necho https://example.invalid/c/1\n' > "${stub}/gh"
    chmod +x "${stub}"/*
    PATH="${stub}:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "$(_rv_ok_replies)" exec
    assert_success
    [[ ! -e "${BATS_TEST_TMPDIR}/pwned" ]]
    run cat "${scratch}/codex.md"
    assert_output "$(_codex_rel_answer '')"
    run grep -c -- "- lib/log.sh:12" "${scratch}/body-1.md"
    assert_output "1"
}

# Write stand-in $1 into the stub bin with shell body $2.
_rv_stub() {
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    printf '#!/bin/sh\n%s\n' "$2" > "${BATS_TEST_TMPDIR}/bin/$1"
    chmod +x "${BATS_TEST_TMPDIR}/bin/$1"
}

# Stand-in agy / codex / gh that succeed; gh logs its args to gh.args and
# appends one line per call to gh.calls, so a repeated call is visible.
_rv_stubs() {
    _rv_stub agy 'echo "1. agy-claim [官方文件 https://x]"'
    _rv_stub codex 'cat >/dev/null; printf "banner\ncodex\ncodex-verdict-line\ntokens used\n5\n"'
    _rv_stub gh "[ \"\$1 \$2\" = 'issue view' ] && { echo '{\"comments\":[]}'; exit; }; printf '%s\n' \"\$*\" >> '${BATS_TEST_TMPDIR}/gh.calls'; printf '%s\n' \"\$@\" > '${BATS_TEST_TMPDIR}/gh.args'; echo 'https://github.com/o/r/issues/7#issuecomment-1'"
}

# Run research-verify (exec, stub tools) with args question $3 (default q),
# where stage $1 fails as kind $2: nonzero = its tool exits non-zero (a
# stage without a tool: the agent itself fails), empty = no output,
# malformed = output of the wrong shape. The record agent returns what gh
# printed. Every other stage succeeds.
_rv_fail_case() {
    local replies dir="${BATS_TEST_TMPDIR}/$1-$2"
    _rv_stubs
    git init -q "${dir}"
    rm -f "${BATS_TEST_TMPDIR}/gh.args" "${BATS_TEST_TMPDIR}/gh.calls"
    replies="$(_rv_with "$(_rv_with "$(_rv_ok_replies)" 'record:' '{"url":"<stdout>"}')" 'nonce:' '{"nonce":"<stdout>"}')"
    case "$1:$2" in
        research:nonzero) _rv_stub agy 'echo "1. c"; exit 3' ;;
        research:empty) _rv_stub agy 'true' ;;
        research:malformed) replies="$(_rv_with "${replies}" 'agy:' '{"status":"ok"}')" ;;
        claude-verify:nonzero) replies="$(_rv_with "${replies}" 'claude-verify:' 'null')" ;;
        claude-verify:empty) replies="$(_rv_with "${replies}" 'claude-verify:' '{"claims":[]}')" ;;
        claude-verify:malformed) replies="$(_rv_with "${replies}" 'claude-verify:' '{"claims":[{"claim":"c1"}]}')" ;;
        codex-verify:nonzero) _rv_stub codex 'cat >/dev/null; printf "codex\nv\n"; exit 1' ;;
        codex-verify:empty) _rv_stub codex 'cat >/dev/null' ;;
        codex-verify:malformed) _rv_stub codex 'cat >/dev/null; echo "no answer marker"' ;;
        synthesize:nonzero) replies="$(_rv_with "${replies}" 'synthesize:' 'null')" ;;
        synthesize:empty) replies="$(_rv_with "${replies}" 'synthesize:' '{}')" ;;
        synthesize:malformed) replies="$(_rv_with "${replies}" 'synthesize:' '{"verified":"x","refuted":[],"needsExperiment":[],"recommendation":"r","parameters":[]}')" ;;
        record:nonzero) _rv_stub gh "printf x > '${BATS_TEST_TMPDIR}/gh.args'; exit 1" ;;
        record:empty) _rv_stub gh "printf x > '${BATS_TEST_TMPDIR}/gh.args'" ;;
        record:malformed) _rv_stub gh "printf x > '${BATS_TEST_TMPDIR}/gh.args'; echo 'unexpected output'" ;;
        ok:ok) ;;
        *) return 99 ;;
    esac
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" _rv_run "$(jq -cn --arg d "${dir}" --arg q "${3:-q}" '{repo:"o/r",repoDir:$d,issue:7,question:$q}')" "${replies}" exec
}

# Stage $1 failing as each kind ends in status $2 with nothing recorded:
# no comment, and gh never runs before the Record stage.
_rv_assert_fails_closed() {
    local kind json
    for kind in nonzero empty malformed; do
        echo "case: $1/${kind}"
        json="$(_rv_fail_case "$1" "${kind}")"
        run jq -r '.error, .result.status, .result.comment' <<<"${json}"
        assert_output "$(printf '%s\n' null "$2" '')"
        if [[ "$1" != record ]]; then
            assert [ ! -e "${BATS_TEST_TMPDIR}/gh.args" ]
        fi
    done
}

@test "research-verify (node, exec): a small research records exactly one unnumbered comment" {
    local body="${BATS_TEST_TMPDIR}/ok-ok/../worktree/.scratch/research-7/body-1.md"
    run _rv_fail_case ok ok
    assert_success
    run jq -r '.error, .result.status, .result.comment' <<<"${output}"
    assert_output "$(printf '%s\n' null recorded 'https://github.com/o/r/issues/7#issuecomment-1')"
    run grep -c '^issue comment 7 ' "${BATS_TEST_TMPDIR}/gh.calls"
    assert_output "1"
    run wc -l < "${BATS_TEST_TMPDIR}/gh.calls"
    assert_output "1"
    run grep -c '^第 [0-9].*則$' "${body}"
    assert_output "0"
    run grep -c 'comment:1/1 -->$' "${body}"
    assert_output "1"
}

@test "research-verify (node, exec): an over-limit research records bounded comments in conclusion, claims, codex, agy order" {
    local dir="${BATS_TEST_TMPDIR}/long-record" replies json comments
    comments="${BATS_TEST_TMPDIR}/comments"
    _rv_stubs
    _rv_stub agy 'awk '\''BEGIN { printf "1. "; for (i = 0; i < 70000; i++) printf "a"; print " [official https://x]" }'\'''
    _rv_stub codex 'cat >/dev/null; awk '\''BEGIN { print "codex"; for (i = 0; i < 70000; i++) printf "c"; print ""; print "tokens used"; print "5" }'\'''
    _rv_stub gh "if [ \"\$1 \$2\" = 'issue view' ]; then mkdir -p '${comments}'; for f in '${comments}'/*; do [ -f \"\$f\" ] || continue; n=\${f##*/}; jq -Rs --arg url 'https://github.com/o/r/issues/7#issuecomment-'\"\$n\" '{body:.,url:\$url}' < \"\$f\"; done | jq -s '{comments:.}'; exit; fi; mkdir -p '${comments}'; n=\$(find '${comments}' -type f | wc -l); cp \"\$7\" '${comments}/'\$((n + 1)); echo 'https://github.com/o/r/issues/7#issuecomment-'\$((n + 1))"
    git init -q "${dir}"
    replies="$(_rv_with "$(_rv_ok_replies)" 'record:' '{"url":"<stdout>"}')"
    replies="$(_rv_with "${replies}" 'claude-verify:' "$(jq -cn --arg basis "$(printf '%070000d' 0)" '{claims:[{claim:"c1",verdict:"supported",basis:$basis}]}')")"

    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "${replies}" exec
    assert_success
    json="${output}"
    run jq -r '.error, .result.status' <<<"${json}"
    assert_output "$(printf '%s\n' null recorded)"
    run bash -c 'find "$1" -type f | wc -l' _ "${comments}"
    assert_output "4"
    run bash -c 'for f in "$1"/*; do [ "$(wc -c < "$f")" -lt 65536 ] || exit 1; done' _ "${comments}"
    assert_success
    run bash -c 'for f in "$1"/*; do case "$(head -n 1 "$f")" in "[claude]"*) ;; *) exit 1 ;; esac; done' _ "${comments}"
    assert_success
    run bash -c 'head -n 1 "$1/1"; grep -m1 "第 1／4 則" "$1/1"; grep -m1 "claude 逐條驗證" "$1/2"; grep -m1 "codex 逐條驗證" "$1/3"; grep -m1 "agy 原文" "$1/4"' _ "${comments}"
    assert_output "$(printf '%s\n' '[claude] 研究結論(research-verify:agy 查資料,claude 與 codex 驗證)' '第 1／4 則' '[claude] claude 逐條驗證' '[claude] codex 逐條驗證(原文)' '[claude] agy 原文')"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "${replies}" exec
    assert_success
    run bash -c 'find "$1" -type f | wc -l' _ "${comments}"
    assert_output "4"
}

@test "research-verify (node, exec): a Record retry skips existing parts and posts only the remaining parts in order" {
    local dir="${BATS_TEST_TMPDIR}/partial-retry" replies existing posted
    existing="${BATS_TEST_TMPDIR}/existing.json"
    posted="${BATS_TEST_TMPDIR}/posted"
    _rv_stubs
    _rv_stub agy 'awk '\''BEGIN { printf "1. "; for (i = 0; i < 70000; i++) printf "a"; print " [official https://x]" }'\'''
    _rv_stub codex 'cat >/dev/null; awk '\''BEGIN { print "codex"; for (i = 0; i < 70000; i++) printf "c"; print ""; print "tokens used"; print "5" }'\'''
    jq -cn '{comments:[
        {body:"<!-- research-verify:0123456789abcdef:comment:1/4 -->",url:"https://github.com/o/r/issues/7#issuecomment-1"},
        {body:"<!-- research-verify:0123456789abcdef:comment:2/4 -->",url:"https://github.com/o/r/issues/7#issuecomment-2"}
    ]}' > "${existing}"
    _rv_stub gh "if [ \"\$1 \$2\" = 'issue view' ]; then cat '${existing}'; exit; fi; mkdir -p '${posted}'; n=\$(find '${posted}' -type f | wc -l); cp \"\$7\" '${posted}/'\$((n + 1)); echo 'https://github.com/o/r/issues/7#issuecomment-'\$((n + 3))"
    git init -q "${dir}"
    replies="$(_rv_with "$(_rv_ok_replies)" 'record:' '{"url":"<stdout>"}')"
    replies="$(_rv_with "${replies}" 'claude-verify:' "$(jq -cn --arg basis "$(printf '%070000d' 0)" '{claims:[{claim:"c1",verdict:"supported",basis:$basis}]}')")"

    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "${replies}" exec
    assert_success
    run bash -c 'for f in "$1"/*; do grep -m1 "<!-- research-verify:" "$f"; done' _ "${posted}"
    assert_output "$(printf '%s\n' \
        '<!-- research-verify:0123456789abcdef:comment:3/4 -->' \
        '<!-- research-verify:0123456789abcdef:comment:4/4 -->')"
    run bash -c 'find "$1" -type f | wc -l' _ "${posted}"
    assert_output "2"
}

@test "research-verify (node, exec): recorded comments contain no attribution lines" {
    local dir="${BATS_TEST_TMPDIR}/no-attribution" replies posted="${BATS_TEST_TMPDIR}/posted"
    _rv_stubs
    _rv_stub agy 'printf "1. claim [official https://x]\nGenerated with Claude Code\n"'
    _rv_stub codex 'cat >/dev/null; printf "codex\nverdict\nCo-Authored-By: Claude <bot@example.test>\ntokens used\n5\n"'
    _rv_stub gh "[ \"\$1 \$2\" = 'issue view' ] && { echo '{\"comments\":[]}'; exit; }; cp \"\$7\" '${posted}'; echo 'https://github.com/o/r/issues/7#issuecomment-1'"
    git init -q "${dir}"
    replies="$(_rv_with "$(_rv_ok_replies)" 'record:' '{"url":"<stdout>"}')"
    replies="$(_rv_with "${replies}" 'claude-verify:' '{"claims":[{"claim":"c1","verdict":"supported","basis":"Claude-Session: secret"}]}')"

    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "${replies}" exec
    assert_success
    run grep -E '^(Co-Authored-By:|Claude-Session:|Generated with Claude Code)' "${posted}"
    assert_failure
}

@test "research-verify (node, exec): an over-limit conclusion paragraph is truncated with a note" {
    local dir="${BATS_TEST_TMPDIR}/long-conclusion" replies posted="${BATS_TEST_TMPDIR}/posted"
    _rv_stubs
    _rv_stub gh "[ \"\$1 \$2\" = 'issue view' ] && { echo '{\"comments\":[]}'; exit; }; mkdir -p '${posted}'; n=\$(find '${posted}' -type f | wc -l); cp \"\$7\" '${posted}/'\$((n + 1)); echo 'https://github.com/o/r/issues/7#issuecomment-1'"
    git init -q "${dir}"
    replies="$(_rv_with "$(_rv_ok_replies)" 'record:' '{"url":"<stdout>"}')"
    replies="$(_rv_with "${replies}" 'synthesize:' "$(jq -cn --arg recommendation "$(printf '%070000d' 0)" '{verified:[],refuted:[],needsExperiment:[],recommendation:$recommendation,parameters:[]}')")"

    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "${replies}" exec
    assert_success
    run bash -c '[ "$(wc -c < "$1/1")" -lt 65536 ] && grep -q "\[內容過長，已截斷\]" "$1/1"' _ "${posted}"
    assert_success
}

@test "research-verify (node, exec): a failing Research records nothing (non-zero exit, empty, malformed)" {
    _rv_assert_fails_closed research agy-failed
}

@test "research-verify (node, exec): a failing claude verifier records nothing (non-zero exit, empty, malformed)" {
    _rv_assert_fails_closed claude-verify verify-failed
}

@test "research-verify (node, exec): a failing codex verifier records nothing (non-zero exit, empty, malformed)" {
    _rv_assert_fails_closed codex-verify verify-failed
}

@test "research-verify (node, exec): a failing Synthesize records nothing (non-zero exit, empty, malformed)" {
    _rv_assert_fails_closed synthesize synthesize-failed
}

@test "research-verify (node, exec): a failing Record is record-failed, never recorded (non-zero exit, empty, malformed)" {
    _rv_assert_fails_closed record record-failed
}

@test "research-verify (node, exec): block markers never collide with the text they fence" {
    local q scratch="${BATS_TEST_TMPDIR}/ok-ok/../worktree/.scratch/research-7"
    q='q ===END=== ===BEGIN-1=== ===END-1=== ===END-2=== end'
    run _rv_fail_case ok ok "${q}"
    assert_success
    run jq -r '.error, .result.status' <<<"${output}"
    assert_output "$(printf '%s\n' null recorded)"
    run grep -cF "${q}" "${scratch}/agy-prompt.txt" "${scratch}/codex-prompt.txt" "${scratch}/claude.md"
    assert_output "$(printf '%s\n' "${scratch}/agy-prompt.txt:1" "${scratch}/codex-prompt.txt:1" "${scratch}/claude.md:1")"
}

@test "research-verify (node, exec): every fenced block in a run gets its own marker" {
    run _rv_fail_case ok ok
    assert_success
    run jq -r '[.calls[].prompt | scan("===BEGIN-([^=]+)===") | .[0]] | (length | tostring) + " " + (unique | length | tostring)' <<<"${output}"
    assert_output "3 3"
}

@test "research-verify (node, exec): two runs with the same args never share a block marker (issue #225)" {
    local first second
    first="$(_rv_fail_case ok ok)"
    second="$(_rv_fail_case ok ok)"
    run jq -rn --argjson a "${first}" --argjson b "${second}" \
        '[$a, $b] | map([.calls[].prompt | scan("===BEGIN-([^=]+)===") | .[0]]) | "\(.[0] | length) \(.[1] | length) \(add | unique | length)"'
    assert_output "3 3 6"
    run jq -rn --argjson a "${first}" --argjson b "${second}" '$a.result.status, $b.result.status'
    assert_output "$(printf '%s\n' recorded recorded)"
}

@test "research-verify (node): a missing or malformed run nonce stops before Research with setup-failed" {
    local val
    for val in null '{}' '{"nonce":""}' '{"nonce":"12"}' '{"nonce":"0123456789abcdeg"}' '{"nonce":"===END-1==="}'; do
        echo "nonce reply: ${val}"
        run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_with "$(_rv_ok_replies)" 'nonce:' "${val}")"
        assert_success
        run jq -r '.result.status, .result.comment, (.calls | length)' <<<"${output}"
        assert_output "$(printf '%s\n' setup-failed '' 1)"
    done
}

@test "research-verify (node): only a comment URL on THIS repo's issue counts as recorded" {
    local val
    for val in 'null' '{}' '{"url":5}' '{"url":""}' '{"url":"not a url"}' \
               '{"url":"https://example.invalid/c/1"}' \
               '{"url":"https://github.com/o/x/issues/7#issuecomment-1"}' \
               '{"url":"https://github.com/o/r/issues/8#issuecomment-1"}' \
               '{"url":"https://github.com/o/r/issues/7"}' \
               '{"url":"https://github.com/o/r/issues/7#issuecomment-"}' \
               '{"url":"https://github.com/o/r/issues/7#issuecomment-1 extra"}' \
               '{"url":"https://github.com/oxr/issues/7#issuecomment-1"}' \
               '{"url":"https://github.com/o/r/issues/71#issuecomment-1"}'; do
        run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_with "$(_rv_ok_replies)" 'record:' "${val}")"
        assert_success
        run jq -r '.result.status, .result.comment, (.result.detail | test("record URL is not a comment on o/r#7"))' <<<"${output}"
        assert_output "$(printf '%s\n' record-failed '' true)"
    done
    run _rv_run '{"repo":"O/R","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_ok_replies)"
    run jq -r '.result.status' <<<"${output}"
    assert_output "recorded"
}

@test "research-verify: every phase prompt confines intermediate files to the run's scratch dir (#243)" {
    run grep -c '^const SCRATCH_ONLY = ' "${RESEARCH}"
    assert_output "1"
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_ok_replies)"
    assert_success
    local json="${output}"
    run jq -r '[.calls[] | select(.label | startswith("nonce:") | not) | .label | sub(":.*"; ":")] | join(" ")' <<<"${json}"
    assert_output "agy: claude-verify: codex-verify: synthesize: record: repo-check:"
    run jq -r '[.calls[] | select(.label | startswith("nonce:") | not) | select(.prompt | contains("Intermediate files (notes, drafts, logs) go ONLY under \"/w/../worktree/.scratch/research-7/\"") | not) | .label] | length' <<<"${json}"
    assert_output "0"
    run jq -r '[.calls[] | select(.label | startswith("nonce:") | not) | select(.prompt | contains("never create, edit or delete any other path under \"/w\"") | not) | .label] | length' <<<"${json}"
    assert_output "0"
}

@test "research-verify: requires a clean repo before Research and checks it after Record (#243)" {
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_ok_replies)"
    assert_success
    local json="${output}"
    # The first shell step captures the status BEFORE any write (mkdir, rm,
    # redirect): nothing but a cd precedes the git status call.
    run jq -r '.calls[1].prompt | [match("`([^`]*)`"; "g").captures[0].string][0]' <<<"${json}"
    assert_output --regexp "^cd '/w' && before=\\\$\\(git -C '/w' status --porcelain --untracked-files=all -- \\.\\) && \\[ -z \"\\\$before\" \\] && mkdir -p "
    assert_output --partial '> status-before.txt'
    run jq -r '.calls[-1].label, .calls[-1].prompt' <<<"${json}"
    assert_output --partial "repo-check:#7"
    assert_output --partial "git -C '/w' status --porcelain --untracked-files=all -- . > status-after.txt"
    run grep -c "schema: REPO_CHECK_SCHEMA" "${RESEARCH}"
    assert_output "1"
}

@test "research-verify (node): extra repo paths after Record fail the run with repo-dirty and list the paths (#243)" {
    local ok
    ok="$(_rv_ok_replies)"
    run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_with "${ok}" 'repo-check:' '{"extra":["?? doc/research/x.md"," M README.md"]}')"
    assert_success
    run jq -r '.result.status, .result.comment, .result.detail' <<<"${output}"
    assert_output --partial "repo-dirty"
    assert_output --partial "https://github.com/o/r/issues/7#issuecomment-1"
    assert_output --partial "?? doc/research/x.md"
    assert_output --partial " M README.md"
    for val in 'null' '{}' '{"extra":"x"}'; do
        run _rv_run '{"repo":"o/r","repoDir":"/w","issue":7,"question":"q"}' "$(_rv_with "${ok}" 'repo-check:' "${val}")"
        run jq -r '.result.status' <<<"${output}"
        assert_output "repo-dirty"
    done
}

@test "research-verify (node): the repo-check shell step really lists a path a phase left in repoDir (#243)" {
    local stub="${BATS_TEST_TMPDIR}/bin" dir="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${stub}"
    # agy misbehaves: leaves a note in the checkout (scratch is outside repoDir)
    printf '#!/bin/sh\ntouch "%s/stray-note.md"\necho "1. claim [x]"\n' "${dir}" > "${stub}/agy"
    printf '#!/bin/sh\ncat >/dev/null\nprintf "codex\\nok\\ntokens used\\n1\\n"\n' > "${stub}/codex"
    printf '#!/bin/sh\necho https://example.invalid/c/1\n' > "${stub}/gh"
    chmod +x "${stub}"/*
    git init -q "${dir}"
    PATH="${stub}:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "$(_rv_ok_replies)" exec
    assert_success
    [[ -e "${dir}/stray-note.md" ]]
    run cat "${dir}/../worktree/.scratch/research-7/repo-extra.txt"
    assert_output "+ ?? stray-note.md"
}

@test "research-verify (node): a dirty repo stops before scratch creation and research (#301)" {
    local dir="${BATS_TEST_TMPDIR}/dirty/repo"
    git init -q "${dir}"
    touch "${dir}/old-note.md"
    run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "$(_rv_ok_replies)" exec
    assert_success
    run jq -r '.result.status, (.ran | length)' <<<"${output}"
    assert_output "$(printf '%s\n' agy-failed 2)"
}

@test "research-verify (node): the repo-check shell step fails closed when grep errors, e.g. an unreadable status-before.txt (#243)" {
    local stub="${BATS_TEST_TMPDIR}/bin" dir="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${stub}"
    # agy misbehaves: removes the pre-run capture from the scratch dir (its cwd)
    printf '#!/bin/sh\nrm -f status-before.txt\necho "1. claim [x]"\n' > "${stub}/agy"
    printf '#!/bin/sh\ncat >/dev/null\nprintf "codex\\nok\\ntokens used\\n1\\n"\n' > "${stub}/codex"
    printf '#!/bin/sh\necho https://example.invalid/c/1\n' > "${stub}/gh"
    chmod +x "${stub}"/*
    git init -q "${dir}"
    PATH="${stub}:${PATH}" run _rv_run "$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:7,question:"q"}')" "$(_rv_ok_replies)" exec
    assert_success
    run jq -r '.ran[-1].rc' <<<"${output}"
    refute_output "0"
    run cat "${dir}/../worktree/.scratch/research-7/repo-extra.txt"
    assert_output --partial "repo-check failed"
}

@test "doc/workflow.md documents research-verify and its args" {
    run grep -c '^## research-verify' "${REPO_ROOT}/doc/workflow.md"
    assert_output "1"
    run grep -c 'repo, repoDir, issue, question, context?, sources?, timeoutMin?' "${REPO_ROOT}/doc/workflow.md"
    assert_output "1"
    run grep -c 'repo-dirty' "${REPO_ROOT}/doc/workflow.md"
    assert [ "${output}" -ge 1 ]
    run grep -c 'git -C <repoDir> status --porcelain' "${REPO_ROOT}/doc/workflow.md"
    assert [ "${output}" -ge 1 ]
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "pr-loop (node): invalid mode fails before any agent (#310)" {
    run _pl_run '{"mode":"other"}'
    assert_success
    run jq -cr '[(.error | contains("args.mode")), (.calls | length)]' <<<"${output}"
    assert_output '[true,0]'
}

@test "pr-loop (node): light uses separate Claude editors and reviewers without codex (#310)" {
    run _pl_run '{"mode":"light","codex":"off"}'
    assert_success
    run jq -cr '[.error, [.calls[].label], ([.calls[].prompt | contains("codex exec")] | any)]' <<<"${output}"
    assert_output '[null,["implement:#283","review:#283:light","publish:#283","locate:b","stage-check:Implement:#7","ci:#7"],false]'
}

@test "milestone-fanout (node): forwards light mode to each child (#310)" {
    run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${FANOUT}" \
        "{\"repo\":\"o/r\",\"repoDir\":\"${REPO_ROOT}\",\"mode\":\"light\",\"items\":[{\"issue\":310,\"branch\":\"b\",\"name\":\"n\",\"task\":\"t\"}]}" '{}'
    assert_success
    run jq -cr '[.error, .workflowCalls[0].args.mode]' <<<"${output}"
    assert_output '[null,"light"]'
}

# Stage checks execute against a real repository and bare remote in Docker.
_pl_stage_setup() {
    local root="${BATS_TEST_TMPDIR}"
    mkdir -p "${root}/worktree/n" "${root}/src" "${root}/bin"
    git init -q --bare "${root}/remote"
    git init -q "${root}/worktree/n"
    git -C "${root}/worktree/n" config user.name Tester
    git -C "${root}/worktree/n" config user.email '1+tester@users.noreply.github.com'
    git -C "${root}/worktree/n" commit -qm initial --allow-empty
    git -C "${root}/worktree/n" branch -M b
    git -C "${root}/worktree/n" remote add origin "${root}/remote"
    git -C "${root}/worktree/n" push -q origin b
    PL_BEFORE="$(git -C "${root}/worktree/n" rev-parse HEAD)"
    cat > "${root}/bin/gh" <<SH
#!/bin/sh
exec git --git-dir='${root}/remote' rev-parse refs/heads/b
SH
    chmod +x "${root}/bin/gh"
}

_pl_stage_run() {
    local implementer="$1" action="${2:-dirty}" root="${BATS_TEST_TMPDIR}"
    # The first review creates the requested Fix result, before the check runs.
    local replies
    replies="$(jq -cn --arg sha "${PL_BEFORE}" '{"locate:":{pr:7,sha:$sha},"ci:":{state:"green",sha:$sha,detail:""},
        "review:":{verdict:"blocked",blocking:["broken"],nonBlocking:[],answer:"blocked"},
        "stage-check:":{evidence:"<stdout>"}}')"
    # Simulate a Fix after Implement has passed its check.
    PL_ACTION="${action}" PATH="${root}/bin:${PATH}" node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        "$(jq -cn --arg d "${root}/src" --arg impl "${implementer}" '{repo:"o/r",repoDir:$d,issue:331,branch:"b",name:"n",task:"t",implementer:$impl,maxRounds:1}')" \
        "${replies}" exec-stage-checks
}

@test "pr-loop (node): Fix rejects uncommitted changes before CI or another review (#331)" {
    local impl
    for impl in codex claude; do
        _pl_stage_setup
        run _pl_stage_run "${impl}"
        assert_success
        local json="${output}"
        run jq -cr '[.result.codexVerdict, .result.rounds, ([.calls[].label | select(startswith("review:"))] | length), ([.calls[].label | select(startswith("ci:"))] | length)]' <<<"${json}"
        assert_output '["blocked",1,1,1]'
        run jq -r '.result.blockingLeft | join("\n")' <<<"${json}"
        assert_output --partial 'git status: ?? pending.txt'
        assert_output --partial "local HEAD: ${PL_BEFORE}"
        rm -rf "${BATS_TEST_TMPDIR}/worktree/n" "${BATS_TEST_TMPDIR}/remote"
    done
}

@test "pr-loop (node): Fix rejects a committed but unpushed HEAD (#331)" {
    local impl
    for impl in codex claude; do
        _pl_stage_setup
        run _pl_stage_run "${impl}" unpushed
        assert_success
        local json="${output}"
        run jq -cr '[.result.codexVerdict, ([.calls[].label | select(startswith("review:"))] | length), ([.calls[].label | select(startswith("ci:"))] | length)]' <<<"${json}"
        assert_output '["blocked",1,1]'
        run jq -r '.result.blockingLeft | join("\n")' <<<"${json}"
        assert_output --partial 'git status: (clean)'
        assert_output --partial "remote HEAD: ${PL_BEFORE}"
        assert_output --partial "PR head: ${PL_BEFORE}"
        refute_output --partial "local HEAD: ${PL_BEFORE}"
        rm -rf "${BATS_TEST_TMPDIR}/worktree/n" "${BATS_TEST_TMPDIR}/remote"
    done
}

@test "pr-loop (node): Fix rejects an unchanged PR head (#331)" {
    local impl
    for impl in codex claude; do
        _pl_stage_setup
        run _pl_stage_run "${impl}" unchanged
        assert_success
        local json="${output}"
        run jq -cr '[.result.codexVerdict, ([.calls[].label | select(startswith("review:"))] | length), ([.calls[].label | select(startswith("ci:"))] | length)]' <<<"${json}"
        assert_output '["blocked",1,1]'
        run jq -r '.result.blockingLeft | join("\n")' <<<"${json}"
        assert_output --partial "PR head: ${PL_BEFORE}; before: ${PL_BEFORE}"
        rm -rf "${BATS_TEST_TMPDIR}/worktree/n" "${BATS_TEST_TMPDIR}/remote"
    done
}

@test "pr-loop (node): Implement checks cleanliness and pushed PR before CI (#331)" {
    local impl
    for impl in codex claude light; do
        _pl_stage_setup
        local root="${BATS_TEST_TMPDIR}" replies json
        replies="$(jq -cn --arg sha "${PL_BEFORE}" '{"implement:":{status:"ready",reason:""},"locate:":{pr:7,sha:$sha},
            "review:":{verdict:"mergeable",blocking:[],nonBlocking:[],answer:"ok"},
            "ci:":{state:"green",sha:$sha,detail:""},"stage-check:":{evidence:"<stdout>"}}')"
        PL_STAGE=Implement PL_ACTION=dirty PATH="${root}/bin:${PATH}" run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
            "$(jq -cn --arg d "${root}/src" --arg impl "${impl}" '{repo:"o/r",repoDir:$d,issue:331,branch:"b",name:"n",task:"t"} + (if $impl == "light" then {mode:"light"} else {implementer:$impl} end)')" \
            "${replies}" exec-stage-checks
        assert_success
        json="${output}"
        run jq -cr '[.result.ciState, ([.calls[].label | select(startswith("ci:"))] | length)]' <<<"${json}"
        assert_output '["none",0]'
        run jq -r '.result.blockingLeft | join("\n")' <<<"${json}"
        assert_output --partial 'Implement check failed:'
        assert_output --partial 'git status: ?? pending.txt'
        rm -rf "${root}/worktree/n" "${root}/remote"
    done
}

@test "pr-loop (node): invalid stage evidence fails closed with a reason (#331)" {
    run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        '{"repo":"o/r","repoDir":"/work","issue":331,"branch":"b","name":"n","task":"t"}' \
        '{"locate:":{"pr":7,"sha":"abc"},"stage-check:":{"evidence":"null"}}'
    assert_success
    run jq -cr '[.error, .result.codexVerdict, .result.blockingLeft]' <<<"${output}"
    assert_output '[null,"blocked",["Implement check failed: no valid script evidence; git status and HEAD comparison unavailable"]]'
}

@test "pr-loop (node): clean pushed fixes resume CI and review (#331)" {
    local impl
    for impl in codex claude; do
        _pl_stage_setup
        run _pl_stage_run "${impl}" pushed
        assert_success
        run jq -cr '[.error, .result.ciState, .result.rounds, .result.blockingLeft,
            ([.calls[].label | select(startswith("review:"))] | length),
            ([.calls[].label | select(startswith("ci:"))] | length), [.ran[].rc]]' <<<"${output}"
        assert_output '[null,"green",1,["broken"],2,2,[0,0]]'
        rm -rf "${BATS_TEST_TMPDIR}/worktree/n" "${BATS_TEST_TMPDIR}/remote"
    done
}

@test "pr-loop (node): a missing worktree stops the stage script (#331)" {
    run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        "$(jq -cn --arg d "${BATS_TEST_TMPDIR}/missing" '{repo:"o/r",repoDir:$d,issue:331,branch:"b",name:"n",task:"t"}')" \
        '{"locate:":{"pr":7,"sha":"abc"},"stage-check:":{"evidence":"<stdout>"}}' exec-stage-checks
    assert_success
    run jq -cr '[.error, .result.codexVerdict, (.ran[0].rc != 0), .result.blockingLeft]' <<<"${output}"
    assert_output '[null,"blocked",true,["Implement check failed: no valid script evidence; git status and HEAD comparison unavailable"]]'
}

@test "pr-loop (node): light failed editing includes the step and reason (#331)" {
    run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        '{"repo":"o/r","repoDir":"/work","issue":331,"branch":"b","name":"n","task":"t","mode":"light"}' \
        '{"implement:":{"status":"failed","reason":"commit: noreply identity is missing"}}'
    assert_success
    run jq -cr '[.result.blockingLeft, [.calls[].label], (.calls[0].schema.required | index("reason") != null)]' <<<"${output}"
    assert_output '[["light editing did not complete: commit: noreply identity is missing"],["implement:#331"],true]'
}

@test "pr-loop (node): light stops before review when editing fails (#310)" {
    run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${PR_LOOP}" \
        '{"repo":"o/r","repoDir":"/work","issue":310,"branch":"b","name":"n","task":"t","mode":"light"}' '{}'
    assert_success
    run jq -cr '[.error, [.calls[].label], .result.pr, (.result.blockingLeft | length)]' <<<"${output}"
    assert_output '[null,["implement:#310"],0,1]'
}

_discuss_run() {
    local replies="${1}" mode="${2:-}"
    local workflow_args='{"repo":"o/r","repoDir":"/w","issue":309,"question":"Choose a design","context":"Approved premise"}'
    workflow_args="${DISCUSS_ARGS:-${workflow_args}}"
    run node "${REPO_ROOT}/test/unit/fixture/workflow_run.mjs" "${WF_DIR}/discuss.js" \
        "${workflow_args}" "${replies}" "${mode}"
    assert_success
}

_discuss_replies() {
    jq -cn '{"nonce:":{nonce:"0123456789abcdef"},"claude:":{answer:"Claude private answer",reasons:["doc/contract.md:1"],notes:[],risks:[]},
        "codex:":{answer:"Codex private answer",reasons:["https://github.com/o/r/issues/1"],notes:[],risks:[]},
        "compare:":{status:"agreed",conclusion:"Use A",basis:["doc/contract.md:1"],disagreements:[],question:""},
        "record:":{url:"https://github.com/o/r/issues/309#issuecomment-1"}}'
}

@test "discuss: first answers are independent and receive the approved context" {
    _discuss_run "$(_discuss_replies)"
    local json="${output}"
    run jq -cr '[.error, [.calls[] | select(.label | test("^(claude|codex):")) |
        [(.prompt | contains("Approved premise")), (.prompt | contains("private answer"))]]]' <<<"${json}"
    assert_output '[null,[[true,false],[true,false]]]'
}

@test "discuss: agreement stops after one round" {
    _discuss_run "$(_discuss_replies)"
    run jq -cr '[.result.status, .result.rounds, ([.calls[] | select(.label | startswith("compare:"))] | length)]' <<<"${output}"
    assert_output '["agreed",1,1]'
}

@test "discuss: accepts the dev box answer citing local issues and PR shorthand (#335)" {
    local replies
    replies="$(_discuss_replies | jq '."codex:".reasons=["Codex cited #212 and #319 to say this is only a summary of existing usage"] |
        ."claude:".reasons=["The existing workflow is documented in doc/workflow.md:224"] |
        ."compare:".basis=["Existing usage follows #212, #319 and PR #311"]')"
    _discuss_run "${replies}"
    run jq -cr '[.error,.result.status,.result.rounds,.result.comment,
        ([.calls[] | select(.label == "record:")] | length)]' <<<"${output}"
    assert_output '[null,"agreed",1,"https://github.com/o/r/issues/309#issuecomment-1",1]'
}

@test "discuss: accepts the real parenthesized dev box search basis (#342)" {
    local replies
    replies="$(_discuss_replies | jq '."compare:".basis=["grep:dev 盒 in doc/（不含 *.svg）-> 30 筆"]')"
    _discuss_run "${replies}"
    run jq -cr '[.result.status,.result.comment]' <<<"${output}"
    assert_output '["agreed","https://github.com/o/r/issues/309#issuecomment-1"]'
}

@test "discuss: real dev box notes need no citations and both answer prompts separate them (#340)" {
    local replies json
    replies="$(_discuss_replies | jq '."claude:".notes=["`開發盒`、`dev 容器` 目前找不到用法（grep 無結果）"] |
        ."codex:".notes=["Avoid 清單是自己的建議，不是文件規則", "rc=0、輸出檔路徑、沒有要停的容器"]')"
    _discuss_run "${replies}"
    json="${output}"
    run jq -cr '[.result.status, .result.claude.notes, .result.codex.notes,
        ([.calls[] | select(.label | test("^(claude|codex):")) |
            (.schema.required | index("notes") != null) and (.schema.properties.notes.items.type == "string") and
            (.prompt | contains("Put judgments in reasons with evidence; put explanations and execution records in notes"))] | all)]' <<<"${json}"
    assert_output "[\"agreed\",[\"\`開發盒\`、\`dev 容器\` 目前找不到用法（grep 無結果）\"],[\"Avoid 清單是自己的建議，不是文件規則\",\"rc=0、輸出檔路徑、沒有要停的容器\"],true]"
}

@test "discuss: real notes stay out of comparison and appear in separate comment sections (#340)" {
    local replies
    replies="$(_discuss_replies | jq '."claude:".notes=["`開發盒`、`dev 容器` 目前找不到用法（grep 無結果）"] |
        ."codex:".notes=["Avoid 清單是自己的建議，不是文件規則", "rc=0、輸出檔路徑、沒有要停的容器"] |
        ."compare:"={status:"diverged",conclusion:"A versus B",basis:["doc/contract.md:1"],disagreements:["Choose storage"],question:"Choose A or B?"}')"
    _discuss_run "${replies}"
    run jq -cr '[.result.status,
        ([.calls[] | select(.label | test("^(compare|claude|codex):")) |
            (.prompt | test("grep 無結果|Avoid 清單|rc=0、輸出檔路徑") | not)] | all),
        (.calls[] | select(.label == "record:") | .prompt |
            contains("## Claude 說明與執行紀錄\n- `開發盒`、`dev 容器` 目前找不到用法（grep 無結果）") and
            contains("## codex 說明與執行紀錄\n- Avoid 清單是自己的建議，不是文件規則\n- rc=0、輸出檔路徑、沒有要停的容器"))]' <<<"${output}"
    assert_output '["diverged",true,true]'
}

@test "discuss: search records cite negative evidence while uncited judgments still fail (#340)" {
    local replies
    replies="$(_discuss_replies | jq '."claude:".reasons=["`開發盒`、`dev 容器` 目前找不到用法（grep 無結果）；grep:開發盒|dev 容器 in doc/ -> 0 筆"] |
        ."codex:".reasons=["grep:dev box in doc/ -> 2 筆"] |
        ."compare:".basis=["grep:開發盒|dev 容器 in doc/ -> 0 筆"]')"
    _discuss_run "${replies}"
    local json="${output}"
    run jq -cr '[.result.status, .result.failed_reasons,
        ([.calls[] | select(.label | test("^(claude|codex|compare):")) |
            (.prompt | contains("grep:<pattern> in <path> -> N 筆"))] | all)]' <<<"${json}"
    assert_output '["agreed",null,true]'
    _discuss_run "$(jq '."codex:".reasons=["Avoid 清單是自己的建議，不是文件規則"] |
        ."codex:".notes=["rc=0、輸出檔路徑、沒有要停的容器"]' <<<"${replies}")"
    run jq -cr '[.result.status, .result.failed_reasons,
        ([.calls[] | select(.label | test("^(compare|record):"))] | length)]' <<<"${output}"
    assert_output '["answer-failed",[{"agent":"codex","reason_index":1,"reason":"Avoid 清單是自己的建議，不是文件規則"}],0]'
}

@test "discuss: uncited reasons fail with the side, one-based position and original text (#335)" {
    local replies
    replies="$(_discuss_replies | jq '."claude:".reasons += ["Trust Claude"] |
        ."codex:".reasons += ["Trust Codex", "No supporting evidence"]')"
    _discuss_run "${replies}"
    run jq -cr '[.result.status,.result.rounds,.result.failed_reasons,
        ([.calls[] | select(.label | test("^(compare|record):"))] | length)]' <<<"${output}"
    assert_output '["answer-failed",1,[{"agent":"claude","reason_index":2,"reason":"Trust Claude"},{"agent":"codex","reason_index":2,"reason":"Trust Codex"},{"agent":"codex","reason_index":3,"reason":"No supporting evidence"}],0]'
}

@test "discuss: disagreement feeds back to both sides and stops at three rounds" {
    local replies
    replies="$(_discuss_replies | jq '."compare:"={status:"diverged",conclusion:"A versus B",basis:["doc/contract.md:1"],disagreements:["Choose storage"],question:"Choose A or B?"}')"
    _discuss_run "${replies}"
    run jq -cr '[.result.status,.result.rounds,([.calls[] | select(.label | test("^(claude|codex):"))] | length),
        ([.calls[] | select(.label | test("^(claude|codex):r[23]")) | (.prompt | contains("Choose storage"))] | all)]' <<<"${output}"
    assert_output '["diverged",3,6,true]'
}

@test "discuss: unresolved disagreement exposes exactly one maintainer question" {
    local replies
    replies="$(_discuss_replies | jq '."compare:"={status:"diverged",conclusion:"A versus B",basis:["doc/contract.md:1"],disagreements:["storage","latency"],question:"Choose A or B?"}')"
    _discuss_run "${replies}"
    run jq -cr '[.result.ask_maintainer, .result.conclusion]' <<<"${output}"
    assert_output '[["Choose A or B?"],"A versus B"]'
}

@test "discuss: records conclusion and cited basis with shell copied codex text" {
    local dir="${BATS_TEST_TMPDIR}/record/repo" scratch posted="${BATS_TEST_TMPDIR}/posted"
    scratch="${dir}/../worktree/.scratch/discuss-309"
    mkdir -p "${scratch}" "${BATS_TEST_TMPDIR}/bin" "${dir}"
    printf 'Unique codex text\ndoc/contract.md:9\n/home/private/secret\nCo-Authored-By: Claude\n' > "${scratch}/codex-r1.md"
    printf "#!/bin/sh\ncp \"\$7\" \"%s\"\necho https://github.com/o/r/issues/309#issuecomment-1\n" "${posted}" > "${BATS_TEST_TMPDIR}/bin/gh"
    chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
    DISCUSS_ARGS="$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:309,question:"q"}')"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" _discuss_run "$(_discuss_replies | jq '."nonce:"={nonce:"0123456789abcdef"} | ."record:".url="<stdout>"')" exec
    run jq -cr '[.result.status,.result.comment]' <<<"${output}"
    assert_output '["agreed","https://github.com/o/r/issues/309#issuecomment-1"]'
    run cat "${posted}"
    assert_output --partial '[claude]'
    assert_output --partial '一致（定案）'
    assert_output --partial '依據'
    assert_output --partial 'doc/contract.md:1'
    assert_output --partial '> Unique codex text'
    refute_output --partial 'Codex private answer'
    refute_output --partial '/home/private'
    refute_output --partial 'Co-Authored-By:'
}

@test "discuss: Record builds before a separate hook checked publication and removes stale bodies" {
    local dir="${BATS_TEST_TMPDIR}/record/repo" scratch posted="${BATS_TEST_TMPDIR}/posted" json replies
    scratch="${dir}/../worktree/.scratch/discuss-309"
    mkdir -p "${scratch}" "${BATS_TEST_TMPDIR}/bin" "${dir}"
    printf 'Unique codex text\ndoc/contract.md:9\n' > "${scratch}/codex-r1.md"
    printf "#!/bin/sh\ncp \"\$7\" \"%s\"\necho https://github.com/o/r/issues/309#issuecomment-1\n" "${posted}" > "${BATS_TEST_TMPDIR}/bin/gh"
    chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
    DISCUSS_ARGS="$(jq -cn --arg d "${dir}" '{repo:"o/r",repoDir:$d,issue:309,question:"q"}')"
    replies="$(_discuss_replies | jq '."record:".url="<stdout>"')"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" _discuss_run "${replies}" exec-hooks
    json="${output}"
    run jq -cr '[.result.status,.result.comment]' <<<"${json}"
    assert_output '["agreed","https://github.com/o/r/issues/309#issuecomment-1"]'
    run jq -cr --arg body "${scratch}/body.md" '[
        (.ran | length == 2), (.ran[0].rc == 0), (.ran[1].rc == 0),
        (.ran[0].cmd | contains("gh issue comment") | not),
        (.ran[1].cmd == ("gh issue comment 309 --repo '\''o/r'\'' --body-file '\''" + $body + "'\''"))
    ]' <<<"${json}"
    assert_output '[true,true,true,true,true]'
    run cat "${posted}"
    assert_output --partial '> Unique codex text'
    # A failed rebuild must delete the old body and never attempt publication.
    rm "${scratch}/codex-r1.md" "${posted}"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" _discuss_run "${replies}" exec-hooks
    run jq -cr '[.result.status, (.ran | length), (.ran[0].rc != 0)]' <<<"${output}"
    assert_output '["record-failed",1,true]'
    [ ! -e "${scratch}/body.md" ]
    [ ! -e "${posted}" ]
}

@test "discuss: deriving a decision requires cited evidence and records no maintainer question" {
    local replies
    replies="$(_discuss_replies | jq '."compare:".status="derived"')"
    _discuss_run "${replies}"
    run jq -cr '[.result.status,.result.rounds,.result.ask_maintainer]' <<<"${output}"
    assert_output '["derived",1,[]]'
    _discuss_run "$(jq '."compare:".basis=["Trust me"]' <<<"${replies}")"
    run jq -cr '[.result.status,([.calls[] | select(.label == "record:")] | length)]' <<<"${output}"
    assert_output '["compare-failed",0]'
}

@test "pr-loop CI fixes explicitly run only changed unit specs locally (#326)" {
    run _pl_run
    assert_success
    run jq -r '.calls[] | select(.label == "ci:#7") | .prompt' <<<"${output}"
    assert_output --partial 'Locally run only just test lint and changed unit specs'
    assert_output --partial 'Never run matrix, integration, system, system-real, acceptance or a whole unit tier locally'
}
