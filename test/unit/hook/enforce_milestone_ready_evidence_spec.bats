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
    *'pr view 7'*'statusCheckRollup'*) jq '{headRefOid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",statusCheckRollup: [.check_runs[] | .status |= ascii_upcase | .conclusion |= ascii_upcase]}' "${READY_FIXTURE}/checks" ;;
    *'pr view 7'*) cat "${READY_FIXTURE}/pr" ;;
    *'/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/check-runs'*) cat "${READY_FIXTURE}/checks" ;;
    *'/comments'*) cat "${READY_FIXTURE}/comments" ;;
    *'repos/ycpss91255/worktool/issues/'*) cat "${READY_FIXTURE}/target" ;;
    *'issue view 5'*) cat "${READY_FIXTURE}/issue" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "${READY_FIXTURE}/bin/gh"
    printf '%s' '[{"id":1,"created_at":"2026-10-03T00:00:00Z","body":"[codex]\n交出判定：可交出 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' >"${READY_FIXTURE}/comments"
    export PATH="${READY_FIXTURE}/bin:${PATH}"
    printf '%s' '{"number":7,"pull_request":{}}' >"${READY_FIXTURE}/target"
    printf '%s' '{"labels":[{"name":"milestone-gate"}],"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"Closes #5"}' >"${READY_FIXTURE}/pr"
    printf '%s' '{"check_runs":[{"name":"verify-all (ubuntu-latest)","status":"completed","conclusion":"failure"},{"name":"verify-all (ubuntu-24.04-arm)","status":"completed","conclusion":"success"}]}' >"${READY_FIXTURE}/checks"
    printf '%s' '{"body":"目標: 開終端即在盒內;量測進盒延遲並達標。"}' >"${READY_FIXTURE}/issue"
    printf '[claude] 就緒，請驗收\n\n## 目標對照\n\n| 目標 | 使用者實際入口 | 測試或驗收項目 | 證據 |\n|---|---|---|---|\n| 開終端即在盒內 | 開啟 Ghostty | setup spec | CI run 123 |\n| 量測進盒延遲並達標 | just box bench | gate 2.3 | bench output |\n' >"${READY_FIXTURE}/body"
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
    printf '%s' '{"check_runs":[{"name":"ci-passed","status":"completed","conclusion":"success"}]}' >"${READY_FIXTURE}/checks"
    check_ready
    assert_failure 2
    assert_output --partial 'verify-all'
}

successful_job() {
    printf '%s' '{"check_runs":[{"name":"verify-all (ubuntu-latest)","status":"completed","conclusion":"success"},{"name":"verify-all (ubuntu-24.04-arm)","status":"completed","conclusion":"success"}]}' >"${READY_FIXTURE}/checks"
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

@test "asking the maintainer to accept a prepared PR also requires evidence" {
    printf '[claude] 已備妥，請維護者驗收\n' >"${READY_FIXTURE}/body"
    check_ready
    assert_failure 2
    assert_output --partial 'verify-all'
}

@test "both real verify-all matrix legs must complete successfully" {
    successful_job
    check_ready
    assert_success
    for runner in ubuntu-latest ubuntu-24.04-arm; do
        successful_job
        jq --arg name "verify-all (${runner})" '.check_runs |= map(select(.name != $name))' \
            "${READY_FIXTURE}/checks" >"${READY_FIXTURE}/next"
        mv "${READY_FIXTURE}/next" "${READY_FIXTURE}/checks"
        check_ready
        assert_failure 2
        successful_job
        jq --arg name "verify-all (${runner})" \
            '(.check_runs[] | select(.name == $name)).conclusion = "failure"' \
            "${READY_FIXTURE}/checks" >"${READY_FIXTURE}/next"
        mv "${READY_FIXTURE}/next" "${READY_FIXTURE}/checks"
        check_ready
        assert_failure 2
        successful_job
        jq --arg name "verify-all (${runner})" \
            '(.check_runs[] | select(.name == $name)).status = "in_progress"' \
            "${READY_FIXTURE}/checks" >"${READY_FIXTURE}/next"
        mv "${READY_FIXTURE}/next" "${READY_FIXTURE}/checks"
        check_ready
        assert_failure 2
    done
}

@test "readiness words in confirmed plain issue comments are allowed" {
    printf '%s' '{"number":365}' >"${READY_FIXTURE}/target"
    printf '[claude] PR #373 尚未就緒\n' >"${READY_FIXTURE}/body"
    run_hook enforce_milestone_ready_evidence "$(hook_json "gh issue comment 365 --repo ycpss91255/worktool --body-file ${READY_FIXTURE}/body")"
    assert_success
    jq -n --rawfile body "${READY_FIXTURE}/body" '{body:$body}' >"${READY_FIXTURE}/input"
    run_hook enforce_milestone_ready_evidence "$(hook_json "gh api repos/ycpss91255/worktool/issues/365/comments --input ${READY_FIXTURE}/input")"
    assert_success
    assert [ "$(awk '/pr view/ {n++} END {print n+0}' "${READY_FIXTURE}/calls")" -eq 0 ]
    touch "${READY_FIXTURE}/fail"
    run_hook enforce_milestone_ready_evidence "$(hook_json "gh issue comment 365 --repo ycpss91255/worktool --body-file ${READY_FIXTURE}/body")"
    assert_failure 2
    assert_output --partial 'query'
}

@test "four-column goal mapping allows complete readiness evidence (#407)" {
    successful_job
    check_ready
    assert_success
}

@test "goal mapping blocks missing columns and the old three-column format (#407)" {
    successful_job
    local valid
    valid="$(cat "${READY_FIXTURE}/body")"
    for row in \
        '| 目標 | 使用者實際入口 | 測試或驗收項目 |' \
        '| 開終端即在盒內 | 開啟 Ghostty | setup spec |' \
        '| 目標 | 測試或驗收項目 | 使用者入口 |'; do
        printf '%s\n' "${valid}" >"${READY_FIXTURE}/body"
        if [[ "${row}" == '| 開終端'* ]]; then
            sed -i "s/^| 開終端.*/${row}/" "${READY_FIXTURE}/body"
        else
            sed -i "s/^| 目標.*/${row}/" "${READY_FIXTURE}/body"
        fi
        check_ready
        assert_failure 2
        assert_output --partial '目標對照'
    done
}

@test "goal cells must equal the extracted goal text exactly (#407)" {
    successful_job
    sed -i 's/| 開終端即在盒內 |/| 開終端即在盒內。 |/' "${READY_FIXTURE}/body"
    check_ready
    assert_failure 2
    assert_output --partial '開終端即在盒內'
}

@test "no goal mapping cell may be empty or a dash (#407)" {
    successful_job
    local valid column value
    valid="$(cat "${READY_FIXTURE}/body")"
    for column in 2 3 4 5; do
        for value in '' '-'; do
            printf '%s\n' "${valid}" | awk -F '|' -v OFS='|' -v column="${column}" -v value="${value}" '
                /^\| 開終端即在盒內 / { $column=" " value " " }
                { print }
            ' >"${READY_FIXTURE}/body"
            check_ready
            assert_failure 2
            assert_output --partial '開終端即在盒內'
        done
    done
}

@test "a dash goal cannot serve as a complete goal mapping cell (#407)" {
    successful_job
    printf '%s' '{"body":"目標: -"}' >"${READY_FIXTURE}/issue"
    sed -i 's/| 開終端即在盒內 |/| - |/' "${READY_FIXTURE}/body"
    check_ready
    assert_failure 2
    assert_output --partial '目標對照'
}

@test "ready evidence blocks without a codex handover verdict on the current head (#412)" {
    successful_job
    printf '[]' >"${READY_FIXTURE}/comments"
    check_ready
    assert_failure 2
    assert_output --partial 'codex'
}

@test "ready evidence blocks codex verdicts for an older head SHA (#412)" {
    successful_job
    sed -i 's/head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' "${READY_FIXTURE}/comments"
    check_ready
    assert_failure 2
    assert_output --partial 'codex'
}
