#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
setup() {
    JOB="${REPO_ROOT}/.agents/script/job.sh"
    NAME="spec-${BATS_TEST_NUMBER}-$$"
}
teardown() { rm -rf "${REPO_ROOT}/.agents/state/job/${NAME}"; }
@test "start detaches a job and wait and status report its successful result" {
    run "$JOB" start "$NAME" -- printf '%s\n' finished
    assert_success
    run "$JOB" wait "$NAME"
    assert_success
    assert_output --partial 'success'
    assert_output --partial 'finished'
    run "$JOB" status "$NAME"
    assert_success
    assert_output --partial 'success'
}
