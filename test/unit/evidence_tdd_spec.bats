#!/usr/bin/env bats
# Verify the RED/GREEN evidence ordering predicate independently of the gate.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    predicate="${REPO_ROOT}/doc/evidence/tdd.awk"
    fixtures="${REPO_ROOT}/doc/evidence/negative"
}

@test "accepts a nonempty RED block followed by a nonempty GREEN block" {
    printf 'RED\n```text\nnot ok 1\n```\nGREEN\n```text\nok 1\n```\n' > "${BATS_TEST_TMPDIR}/body"
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
