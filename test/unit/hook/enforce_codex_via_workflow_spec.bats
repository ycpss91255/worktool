#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() {
    run_hook enforce_codex_via_workflow "$(jq -n --arg c "$1" --arg cwd "${BATS_TEST_TMPDIR}" --arg t "${TRANSCRIPT:-}" \
        '{tool_name:"Bash",cwd:$cwd,transcript_path:$t,tool_input:{command:$c}}')"
}

@test "main loop implementation launches are refused with workflow guidance" {
    for cmd in 'codex exec "implement #366"' '/usr/bin/codex e "fix bug"' 'timeout 60 codex exec "implement"'; do
        _check "${cmd}"
        assert_equal "${status}" 2
        assert_output --partial 'pr-loop / milestone-fanout'
    done
}

@test "shell wrapper scripts cannot hide main-loop implementation" {
    printf '%s\n' '#!/usr/bin/env bash' 'codex exec "implement"' > "${BATS_TEST_TMPDIR}/run.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'bash run.sh' > "${BATS_TEST_TMPDIR}/outer.sh"
    for cmd in 'bash run.sh' './run.sh' 'bash outer.sh' 'cd . && bash run.sh'; do
        _check "${cmd}"
        assert_equal "${status}" 2
    done
}

@test "only workflow-marked subagent transcripts allow implementation" {
    mkdir -p "${BATS_TEST_TMPDIR}/subagents"
    TRANSCRIPT="${BATS_TEST_TMPDIR}/subagents/agent-abc.jsonl"
    for workflow in pr-loop discuss research-verify; do
        jq -n -c --arg p "WORKTOOL_WORKFLOW_AGENT: ${workflow}" \
            '{type:"user",message:{role:"user",content:$p}}' > "${TRANSCRIPT}"
        _check 'bash run.sh'
        assert_success
        _check 'codex exec "implement"'
        assert_success
    done
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"ordinary Agent"}}' > "${TRANSCRIPT}"
    _check 'codex exec "implement"'
    assert_equal "${status}" 2
    jq -n -c '{type:"user",message:{role:"user",content:"WORKTOOL_WORKFLOW_AGENT: pr-loop"}}' > "${TRANSCRIPT}"
    TRANSCRIPT="${BATS_TEST_TMPDIR}/main.jsonl"
    cp "${BATS_TEST_TMPDIR}/subagents/agent-abc.jsonl" "${TRANSCRIPT}"
    _check 'codex exec "implement"'
    assert_equal "${status}" 2
}

@test "main loop read-only sandbox queries pass without workflow identity" {
    for cmd in 'codex exec --sandbox read-only "research"' 'codex e -s read-only "discuss"' 'codex exec --sandbox=read-only -o answer.md "verify"'; do
        _check "${cmd}"
        assert_success
    done
    _check 'git status --short'
    assert_success
}

@test "indirect and uncheckable launches fail closed even with a read-only claim" {
    for cmd in \
        'codex exec --sandbox read-only "$PROMPT"' \
        'codex exec --sandbox read-only --config sandbox_mode="danger-full-access" "query"' \
        'codex exec --sandbox read-only --sandbox workspace-write "query"' \
        'eval codex exec --sandbox read-only query' \
        'bash -c "$CMD"' \
        '$RUN exec --sandbox read-only query' \
        'xargs codex exec --sandbox read-only' \
        'python3 -c "import os; os.system(\"codex exec --sandbox read-only query\")"' \
        'codex exec --sandbox read-only "query"; eval "$CMD"'; do
        _check "${cmd}"
        assert_equal "${status}" 2
    done
}
