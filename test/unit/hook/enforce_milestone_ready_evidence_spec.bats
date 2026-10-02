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
    *'pr view 7'*'statusCheckRollup'*) jq '{headRefOid: "head123",statusCheckRollup: [.check_runs[] | .status |= ascii_upcase | .conclusion |= ascii_upcase]}' "${READY_FIXTURE}/checks" ;;
    *'pr view 7'*) cat "${READY_FIXTURE}/pr" ;;
    *'/commits/head123/check-runs'*) cat "${READY_FIXTURE}/checks" ;;
    *'issue view 5'*) cat "${READY_FIXTURE}/issue" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "${READY_FIXTURE}/bin/gh"
    export PATH="${READY_FIXTURE}/bin:${PATH}"
    printf '%s' '{"labels":[{"name":"milestone-gate"}],"headRefOid":"head123","body":"Closes #5"}' >"${READY_FIXTURE}/pr"
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

@test "failed GitHub queries block readiness with exit two" {
    touch "${READY_FIXTURE}/fail"
    check_ready
    assert_failure 2
    assert_output --partial 'query'
}

@test "an absent verify-all job cannot count as successful evidence" {
    printf '%s' '{"check_runs":[{"name":"ci-passed","conclusion":"success"}]}' >"${READY_FIXTURE}/checks"
    check_ready
    assert_failure 2
    assert_output --partial 'verify-all'
}

successful_job() {
    printf '%s' '{"check_runs":[{"name":"verify-all","status":"completed","conclusion":"success"}]}' >"${READY_FIXTURE}/checks"
}

@test "successful verify-all does not replace a goal trace table" {
    successful_job
    printf '[claude] 待維護者驗收\n' >"${READY_FIXTURE}/body"
    check_ready
    assert_failure 2
    assert_output --partial '目標對照'
}

@test "every milestone goal needs its own evidence and user entry row" {
    successful_job
    sed -i '/量測進盒延遲並達標/d' "${READY_FIXTURE}/body"
    check_ready
    assert_failure 2
    assert_output --partial '量測進盒延遲並達標'
}

@test "both registered agent hooks allow complete successful readiness evidence" {
    successful_job
    cat >"${READY_FIXTURE}/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'rev-parse --show-toplevel' ]] || exit 1
printf '%s\n' "${REPO_ROOT}"
STUB
    chmod +x "${READY_FIXTURE}/bin/git"
    local _config _command _agent
    for _agent in claude codex; do
        _config="${REPO_ROOT}/.${_agent}/hooks.json"
        [[ "${_agent}" != claude ]] || _config="${REPO_ROOT}/.claude/settings.json"
        _command="$(jq -r '.hooks.PreToolUse[] | .hooks[] | .command | select(contains("enforce_milestone_ready_evidence.sh"))' "${_config}")"
        assert [ -n "${_command}" ]
        sed -i "s/^\[.*\]/[${_agent}]/" "${READY_FIXTURE}/body"
        run bash -c 'export CLAUDE_PROJECT_DIR="$1"; cd "$1"; printf "%s" "$2" | bash -c "$3"' _ \
            "${REPO_ROOT}" "$(hook_json "gh pr comment 7 --repo ycpss91255/worktool --body-file ${READY_FIXTURE}/body")" "${_command}"
        assert_success
        assert_output ''
    done
}

@test "REST comment writes use the same complete readiness evidence gate" {
    successful_job
    jq -n --rawfile body "${READY_FIXTURE}/body" '{body:$body}' >"${READY_FIXTURE}/input"
    run_hook enforce_milestone_ready_evidence "$(hook_json "gh api repos/ycpss91255/worktool/issues/7/comments --input ${READY_FIXTURE}/input")"
    assert_success
}

@test "readiness hook changes select its public interface spec in CI" {
    run bash -c 'source "$1"; _changed_path_map' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line '.agents/hook/lib/ready_evidence.sh|test/unit/hook/enforce_milestone_ready_evidence_spec.bats'
}

@test "asking the maintainer to accept a prepared PR also requires evidence" {
    printf '[claude] 已備妥，請維護者驗收\n' >"${READY_FIXTURE}/body"
    check_ready
    assert_failure 2
    assert_output --partial 'verify-all'
}
