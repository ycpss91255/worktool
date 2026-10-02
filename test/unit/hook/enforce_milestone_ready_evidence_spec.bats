#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    export READY_FIXTURE="${BATS_TEST_TMPDIR}/ready"
    mkdir -p "${READY_FIXTURE}/bin"
    cat >"${READY_FIXTURE}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${READY_FIXTURE}/calls"
[[ ! -f "${READY_FIXTURE}/fail" ]] || exit 1
case "$*" in
    *'/pulls/7'*) cat "${READY_FIXTURE}/pr" ;;
    *'/commits/head123/check-runs'*) cat "${READY_FIXTURE}/checks" ;;
    *'/issues/5'*) cat "${READY_FIXTURE}/issue" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "${READY_FIXTURE}/bin/gh"
    export PATH="${READY_FIXTURE}/bin:${PATH}"
    printf '%s' '{"labels":[{"name":"milestone-gate"}],"head":{"sha":"head123"},"body":"Closes #5"}' >"${READY_FIXTURE}/pr"
    printf '%s' '{"check_runs":[{"name":"verify-all","status":"completed","conclusion":"failure"}]}' >"${READY_FIXTURE}/checks"
    printf '%s' '{"body":"目標: 開終端即在盒內;量測進盒延遲並達標。"}' >"${READY_FIXTURE}/issue"
    printf '[claude] 就緒，請驗收\n\n## 目標對照\n\n| 目標 | 測試或驗收項目 | 使用者入口 |\n|---|---|---|\n| 開終端即在盒內 | setup spec | 開啟 Ghostty |\n| 量測進盒延遲並達標 | gate 2.3 | just box bench |\n' >"${READY_FIXTURE}/body"
}

check_ready() {
    run_hook enforce_milestone_ready_evidence "$(hook_json "gh pr comment 7 --repo ycpss91255/worktool --body-file ${READY_FIXTURE}/body")"
}

@test "verify-all on the current head must succeed before declaring ready" {
    check_ready
    assert_failure 2
    assert_output --partial 'verify-all'
}
