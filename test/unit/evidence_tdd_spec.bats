#!/usr/bin/env bats
# Verify the RED/GREEN evidence ordering predicate independently of the gate.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    predicate="${REPO_ROOT}/doc/evidence/tdd.awk"
    fixtures="${REPO_ROOT}/doc/evidence/negative"
}

@test "accepts a nonempty RED block followed by a nonempty GREEN block" {
    printf 'RED\n\140\140\140text\nnot ok 1\n\140\140\140\nGREEN\n\140\140\140text\nok 1\n\140\140\140\n' > "${BATS_TEST_TMPDIR}/body"
    run awk -f "${predicate}" "${BATS_TEST_TMPDIR}/body"
    assert_success
    assert_output 'order=ok red=2 green=6'
}

@test "rejects the wrong-order evidence fixture" {
    run awk -f "${predicate}" "${fixtures}/wrong-order.md"
    assert_failure 1
    assert_output --partial 'order=BAD'
}

@test "rejects the empty RED evidence fixture" {
    run awk -f "${predicate}" "${fixtures}/empty-red-block.md"
    assert_failure 1
    assert_output --partial 'order=BAD'
}

@test "TDD evidence entry checks requested PRs and fails on query errors" {
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat > "${BATS_TEST_TMPDIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$3" == 2 ]]; then
    exit 1
fi
printf 'RED\n```text\nnot ok 1\n```\nGREEN\n```text\nok 1\n```\n'
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run bash "${REPO_ROOT}/doc/evidence/tdd.sh" 1 2
    assert_failure 1
    assert_line --partial '#1 order=ok'
    assert_line '#2 evidence=gh-failed'
}

@test "TDD evidence entry ignores an overridden repository" {
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat > "${BATS_TEST_TMPDIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${GH_ARGS}"
printf 'RED\n\140\140\140text\nnot ok 1\n\140\140\140\nGREEN\n\140\140\140text\nok 1\n\140\140\140\n'
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
    export GH_ARGS="${BATS_TEST_TMPDIR}/args"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" REPO=other/repo run bash "${REPO_ROOT}/doc/evidence/tdd.sh" 1
    assert_success
    run cat "${GH_ARGS}"
    assert_line 'ycpss91255/worktool'
    refute_line 'other/repo'
}
