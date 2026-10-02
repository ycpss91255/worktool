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
