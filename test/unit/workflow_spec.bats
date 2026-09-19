#!/usr/bin/env bats
# test/unit/workflow_spec.bats
#
# WHY
#   .claude/workflows/pr-loop.js and milestone-fanout.js are the reusable
#   orchestration templates (issue #158): one sub-issue -> one PR driven to
#   "CI green + codex 可合併", and a fan-out over independent sub-issues.
#   They are JavaScript run by the Claude Code Workflow tool, so bats cannot
#   execute them; this spec guards the contract that keeps them usable:
#   - the required `export const meta = {...}` literal is present and names
#     every phase() the script calls;
#   - the governance rules are encoded (one issue per PR, codex on/off path,
#     never merges from inside the workflow);
#   - the fan-out delegates to pr-loop instead of duplicating it.
#   This spec is a REQUIRED unit spec of test.sh, so it cannot be deleted
#   silently.

load ../helper/common

setup() {
    WF_DIR="${REPO_ROOT}/.claude/workflows"
    PR_LOOP="${WF_DIR}/pr-loop.js"
    FANOUT="${WF_DIR}/milestone-fanout.js"
}

# Phase titles named in meta.phases of $1.
_meta_phases() {
    sed -n '/^export const meta = {/,/^}/p' "$1" | grep -o "title: '[^']*'" | sed "s/title: '//; s/'//"
}

# Phase titles used by phase() calls or {phase: ...} options in $1.
_used_phases() {
    { grep -o "phase('[^']*')" "$1" | sed "s/phase('//; s/')//"
      grep -o "phase: '[^']*'" "$1" | sed "s/phase: '//; s/'//"; } | sort -u
}

@test "both workflow templates exist under .claude/workflows/" {
    [[ -f "${PR_LOOP}" ]]
    [[ -f "${FANOUT}" ]]
}

@test "each template starts with the required export const meta literal (name, description, phases)" {
    for f in "${PR_LOOP}" "${FANOUT}"; do
        run grep -c '^export const meta = {' "$f"
        assert_output "1"
        run sed -n '/^export const meta = {/,/^}/p' "$f"
        assert_output --partial "name: '"
        assert_output --partial "description: '"
        assert_output --partial "phases: ["
        # pure literal: no interpolation or calls inside the meta block
        refute_output --partial "\${"  # no template interpolation inside meta
        refute_output --partial '(...'
    done
}

@test "every phase used by pr-loop is declared in its meta.phases, and vice versa" {
    run bash -c "diff <($(declare -f _meta_phases); _meta_phases '${PR_LOOP}' | sort -u) <($(declare -f _used_phases); _used_phases '${PR_LOOP}')"
    assert_success
    assert_output ""
}

@test "every phase used by milestone-fanout is declared in its meta.phases" {
    run bash -c "diff <($(declare -f _meta_phases); _meta_phases '${FANOUT}' | sort -u) <($(declare -f _used_phases); _used_phases '${FANOUT}')"
    assert_success
    assert_output ""
}

@test "pr-loop requires repo, issue, branch, name and task (one issue = one PR)" {
    run grep -c "for (const k of \['repo', 'issue', 'branch', 'name', 'task'\])" "${PR_LOOP}"
    assert_output "1"
    run grep -c "Closes #\\\${A.issue}" "${PR_LOOP}"
    assert_output "1"
}

@test "pr-loop has an explicit codex=off path that posts the quota note instead of a [codex] line" {
    run grep -c "const CODEX = (A.codex || 'on') === 'on'" "${PR_LOOP}"
    assert_output "1"
    run grep -c '暫停中(配額)' "${PR_LOOP}"
    assert [ "${output}" -ge 1 ]
    run grep -c 'Never write a "\[codex\]" line yourself' "${PR_LOOP}"
    assert_output "1"
}

@test "pr-loop bounds the fix loop by maxRounds and feeds the prior verdict back to codex" {
    run grep -c 'while (rounds < MAX)' "${PR_LOOP}"
    assert_output "1"
    run grep -c '你上一輪的判定逐字如下' "${PR_LOOP}"
    assert_output "1"
}

@test "no template ever merges a PR (merge stays with the main loop)" {
    run grep -n 'gh pr merge' "${PR_LOOP}" "${FANOUT}"
    assert_failure
    run grep -c 'Do NOT merge\|never merges\|Never merge' "${PR_LOOP}"
    assert [ "${output}" -ge 2 ]
}

@test "milestone-fanout delegates each item to pr-loop through pipeline (no barrier)" {
    run grep -c "workflow({ scriptPath: SCRIPT }" "${FANOUT}"
    assert_output "1"
    run grep -c "pr-loop.js" "${FANOUT}"
    assert [ "${output}" -ge 1 ]
    run grep -c 'await pipeline(A.items' "${FANOUT}"
    assert_output "1"
    run grep -c 'await parallel(' "${FANOUT}"
    assert_output "0"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c "source '${REPO_ROOT}/script/test/test.sh' >/dev/null 2>&1; _required_specs unit"
    assert_success
    assert_line "unit/workflow_spec.bats"
}
