#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

# Schema source: Claude Code hooks reference, checked 2026-10-02:
# https://code.claude.com/docs/en/hooks#common-input-fields
# Documentation-derived fixtures, not captured runtime input. Main calls
# omit agent_id; subagent tool calls add agent_id and agent_type.
_check() {
    run_hook enforce_codex_via_workflow "$(jq -n --arg c "$1" --arg cwd "${BATS_TEST_TMPDIR}" '
        {session_id:"abc123",transcript_path:"/missing/transcript.jsonl",
         cwd:$cwd,permission_mode:"default",hook_event_name:"PreToolUse",
         tool_name:"Bash",tool_input:{command:$c,description:"Run command",
         timeout:120000,run_in_background:false},tool_use_id:"toolu_01ABC123"}')"
}

@test "main loop implementation launches are refused with workflow guidance" {
    for cmd in 'codex exec "implement #366"' '/usr/bin/codex e "fix bug"' 'timeout 60 codex exec "implement"'; do
        _check "${cmd}"
        assert_equal "${status}" 2
        assert_output --partial 'pr-loop / milestone-fanout'
    done
}

@test "documented subagent identity allows implementation without reading transcripts" {
    local payload cmd
    for cmd in 'codex exec --sandbox workspace-write "implement"' 'bash missing.sh' "codex exec \"\$(cat prompt.txt)\""; do
        payload="$(jq -n --arg c "${cmd}" --arg cwd "${BATS_TEST_TMPDIR}" '
            {session_id:"abc123",transcript_path:"/missing/transcript.jsonl",
             cwd:$cwd,permission_mode:"default",hook_event_name:"PreToolUse",
             tool_name:"Bash",tool_input:{command:$c},tool_use_id:"toolu_01ABC123",
             agent_id:"agent-abc123",agent_type:"general-purpose"}')"
        run_hook enforce_codex_via_workflow "${payload}"
        assert_success
    done
    for identity in 'null' '""' 'false' '123' '[]' '{}'; do
        payload="$(jq -n --argjson a "${identity}" '
            {agent_id:$a,tool_name:"Bash",tool_input:{command:"codex exec implement"}}')"
        run_hook enforce_codex_via_workflow "${payload}"
        assert_equal "${status}" 2
    done
    _check 'codex exec "implement"'
    assert_equal "${status}" 2
}

@test "main loop read-only sandbox queries pass without subagent identity" {
    for cmd in 'codex exec --sandbox read-only "research"' 'codex e -s read-only "discuss"' 'codex exec --sandbox=read-only -o answer.md "verify"'; do
        _check "${cmd}"
        assert_success
    done
    _check 'git status --short'
    assert_success
}

@test "everyday command matrix without codex is allowed" {
    local cmd failures=0
    printf '%s\n' '#!/usr/bin/env bash' 'echo ready | awk '\''{print $1}'\''' > "${BATS_TEST_TMPDIR}/daily.sh"
    for cmd in \
        "echo a | awk '{print \$1}'" \
        "jq -r '.name' data.json" \
        "python3 -c 'print(1)'" \
        "gh pr checks 383 --repo ycpss91255/worktool | awk '{print \$1}'" \
        'setsid nohup bash daily.sh' \
        'printf "%s\\n" a | xargs echo' \
        "bash -c 'echo ready'" \
        'just test unit test/unit/agent_config_spec.bats' \
        'docker ps --format "{{.ID}}"'; do
        _check "${cmd}"
        if [[ "${status}" -ne 0 ]]; then
            printf 'Unexpected refusal: %s\n%s\n' "${cmd}" "${output}" >&2
            failures=$((failures + 1))
        fi
    done
    assert_equal "${failures}" 0
}

@test "shell wrappers cannot hide implementation but preserve read-only queries" {
    printf '%s\n' '#!/usr/bin/env bash' 'codex exec "implement"' > "${BATS_TEST_TMPDIR}/run.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'bash run.sh' > "${BATS_TEST_TMPDIR}/outer.sh"
    for cmd in 'bash run.sh' './run.sh' 'bash outer.sh' 'cd . && bash run.sh' 'source run.sh' '. run.sh'; do
        _check "${cmd}"
        assert_equal "${status}" 2
    done
    printf '%s\n' 'codex exec --sandbox read-only "query"' > "${BATS_TEST_TMPDIR}/read.sh"
    _check 'bash read.sh'
    assert_success
}

@test "indirect and opaque launches fail closed despite read-only claims" {
    printf '%s\n' 'codex exec "implement"' > "${BATS_TEST_TMPDIR}/run.sh"
    for cmd in \
        "codex exec --sandbox read-only \"\$PROMPT\"" \
        'codex exec --sandbox read-only --config sandbox_mode="danger-full-access" "query"' \
        'codex exec --sandbox read-only --sandbox workspace-write "query"' \
        'eval codex exec --sandbox read-only query' \
        "bash -c \"\$CMD\" # codex" \
        "\$RUN exec --sandbox read-only query # codex" \
        'xargs codex exec --sandbox read-only' \
        'python3 -c "import os; os.system(\"codex exec --sandbox read-only query\")"' \
        "codex exec --sandbox read-only query; eval \"\$CMD\"" \
        "bash \"\$SCRIPT\" # codex" 'bash missing.sh # codex' 'bash -e run.sh' \
        'setsid bash run.sh' 'busybox sh run.sh' 'nice bash run.sh' 'stdbuf -oL bash run.sh'; do
        _check "${cmd}"
        assert_equal "${status}" 2
    done
}

@test "shell wrapper inspection permits unrelated scripts and opaque paths" {
    local cmd
    printf '%s\n' 'echo ready | awk '\''{print $1}'\''' > "${BATS_TEST_TMPDIR}/daily.sh"
    printf '%s\n' 'bash daily.sh' > "${BATS_TEST_TMPDIR}/outer.sh"
    for cmd in 'bash daily.sh' './daily.sh' 'bash outer.sh' \
        'setsid nohup bash daily.sh' 'nice bash daily.sh' \
        'stdbuf -oL bash daily.sh' 'busybox sh daily.sh' \
        'bash missing.sh' './missing.sh' 'bash "$SCRIPT"' 'bash -c "$CMD"' \
        '$RUN exec --sandbox read-only query'; do
        _check "${cmd}"
        assert_success
    done
    printf '%s\n' 'codex exec "implement"' > "${BATS_TEST_TMPDIR}/daily.sh"
    for cmd in 'bash outer.sh' 'setsid nohup bash daily.sh' 'nice bash daily.sh' \
        'stdbuf -oL bash daily.sh' 'busybox sh daily.sh'; do
        _check "${cmd}"
        assert_equal "${status}" 2
    done
}

@test "launcher chains inspect quoted script paths and bash command strings" {
    local cmd
    printf '%s\n' 'codex exec "implement"' > "${BATS_TEST_TMPDIR}/quoted script.sh"
    for cmd in "setsid nohup bash 'quoted script.sh'" \
        "nice -n 5 bash -c 'bash \"quoted script.sh\"'" \
        "setsid nohup bash -c 'bash \"quoted script.sh\"'" \
        "stdbuf -oL bash 'quoted script.sh'"; do
        _check "${cmd}"
        assert_equal "${status}" 2
    done
    printf '%s\n' 'echo ready' > "${BATS_TEST_TMPDIR}/quoted script.sh"
    _check "setsid nohup bash -c 'bash \"quoted script.sh\"'"
    assert_success
}
