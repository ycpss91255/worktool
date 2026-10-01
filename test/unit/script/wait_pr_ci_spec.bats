#!/usr/bin/env bats
# test/unit/script/wait_pr_ci_spec.bats - .agents/script/wait-pr-ci.sh
#
# The Monitor companion that polls a PR's check rollup until it settles.
# worktool adaptation: the default filter is the one required check,
# `ci-passed`; the script follows the worktool CLI contract (whole command
# line parsed before --help is served, `wait-pr-ci.sh: unknown option '<x>'
# (see --help)` exit 2, `set -uo pipefail`); a conflicting PR fails without
# pointing at scripts this repo does not have. The stale-rollup guards from
# initialization (issue #22 there) are kept.
#
# Strategy: PATH-stub `gh` to print a canned `gh pr view --json` response and
# run the loop exactly once (--max-iterations 1 --interval 0).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    bats_require_minimum_version 1.5.0
    SCRIPT="${REPO_ROOT}/.agents/script/wait-pr-ci.sh"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB_DIR}"
    FIXTURE_JSON="${BATS_TEST_TMPDIR}/gh-response.json"
    cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${GH_FAILURE:-}" ]]; then
    printf '%s\n' "${GH_FAILURE}" >&2
    exit 1
fi
cat "${FIXTURE_JSON}"
EOF
    chmod +x "${STUB_DIR}/gh"
    export PATH="${STUB_DIR}:${PATH}" FIXTURE_JSON
}

# _fixture <check-name> <conclusion> <seconds-before-now> [mergeable]
_fixture() {
    local _at
    _at="$(date -u -d "@$(($(date -u +%s) - $3))" +%Y-%m-%dT%H:%M:%SZ)"
    jq -n --arg n "$1" --arg c "$2" --arg at "${_at}" --arg m "${4:-MERGEABLE}" \
        '{mergeable:$m, headRefOid:"abc1234deadbeef",
          statusCheckRollup:[{name:$n, status:"COMPLETED", conclusion:$c,
                              completedAt:$at, startedAt:$at}]}' >"${FIXTURE_JSON}"
}

_once() { run "${SCRIPT}" --repo owner/repo --prs 21 --max-iterations 1 --interval 0 "$@"; }

# --- polling -----------------------------------------------------------------

@test "a failed PR query reports auth or network errors and stops immediately" {
    local _error
    for _error in 'authentication required' 'network connection refused'; do
        export GH_FAILURE="${_error}"
        run --separate-stderr "${SCRIPT}" --repo owner/repo --prs 21,22 \
            --max-iterations 2 --interval 0
        assert_failure 1
        [[ "${stderr:-}" == *"${_error}"* ]]
        [[ "${stderr:-}" == *"failed to query owner/repo PR21"* ]]
        refute_output --partial "no-checks"
        refute_output --partial "PR22"
        refute_output --partial "ALL_DONE"
        [[ "${stderr:-}" != *"max-iterations"* ]]
    done
}

@test "the default filter is worktool's ci-passed check" {
    _fixture ci-passed SUCCESS 3600
    _once
    assert_success
    assert_output --partial "PR21: checks=all-pass mergeable=MERGEABLE"
    assert_output --partial "ALL_DONE"
}

@test "a rollup without ci-passed is no-checks under the default filter" {
    _fixture test SUCCESS 3600
    _once
    assert_failure 124
    assert_output --partial "PR21: checks=no-checks"
}

@test "a check completed 10s before the watch started stays pending (force-push race guard)" {
    _fixture ci-passed SUCCESS 10
    _once
    assert_failure 124
    assert_output --partial "PR21: checks=pending mergeable=MERGEABLE"
    refute_output --partial "ALL_DONE"
}

@test "a check completed 121s before the watch started is trusted (past the stale window)" {
    _fixture ci-passed SUCCESS 121
    _once
    assert_success
    assert_output --partial "ALL_DONE"
}

@test "a failed ci-passed exits 1 with FAIL <pr>" {
    _fixture ci-passed FAILURE 3600
    _once
    assert_failure 1
    assert_output --partial "FAIL 21"
}

@test "a SKIPPED ci-passed is a failure, not a pass (doc/structure.md CI)" {
    _fixture ci-passed SKIPPED 3600
    _once
    assert_failure 1
    assert_output --partial "PR21: checks=FAIL"
    assert_output --partial "FAIL 21"
    refute_output --partial "ALL_DONE"
}

@test "a CANCELLED or TIMED_OUT ci-passed is a failure" {
    local _c
    for _c in CANCELLED TIMED_OUT; do
        _fixture ci-passed "${_c}" 3600
        _once
        assert_failure 1
        assert_output --partial "FAIL 21"
    done
}

@test "a conflicting PR exits 1 and names no script this repo lacks" {
    _fixture ci-passed SUCCESS 3600 CONFLICTING
    _once
    assert_failure 1
    assert_output --partial "FAIL 21 (mergeable=CONFLICTING)"
    refute_output --partial "rebase-pr"
}

@test "--check-filter still overrides the default" {
    _fixture lint SUCCESS 3600
    _once --check-filter '.name=="lint"'
    assert_success
    assert_output --partial "ALL_DONE"
}

# --- CLI contract ------------------------------------------------------------

@test "--help exits 0 and documents the options" {
    run "${SCRIPT}" --help
    assert_success
    assert_output --partial "Usage: wait-pr-ci.sh"
    assert_output --partial "--check-filter"
}

@test "an unknown option exits 2 in the worktool format" {
    run "${SCRIPT}" --repo owner/repo --prs 1 --bogus
    assert_failure 2
    assert_output "wait-pr-ci.sh: unknown option '--bogus' (see --help)"
}

@test "--help does not hide a later unknown option (whole line parsed first)" {
    run "${SCRIPT}" --help --bogus
    assert_failure 2
    assert_output --partial "unknown option '--bogus'"
}

@test "an option missing its value exits 2" {
    run "${SCRIPT}" --repo owner/repo --prs
    assert_failure 2
    assert_output --partial "--prs needs a value"
}

@test "a missing --repo exits 2" {
    run "${SCRIPT}" --prs 1
    assert_failure 2
    assert_output --partial "--repo is required"
}

@test "a non-numeric --min-checks exits 2" {
    run "${SCRIPT}" --repo owner/repo --prs 1 --min-checks two
    assert_failure 2
    assert_output --partial "--min-checks must be a positive integer"
}

@test "a non-numeric PR number exits 2" {
    run "${SCRIPT}" --repo owner/repo --prs 1,x
    assert_failure 2
    assert_output --partial "--prs"
}
