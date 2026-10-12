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
@test "wait times out with 124 while status remains nonblocking" {
    run "$JOB" start "$NAME" -- sleep 2
    assert_success
    run "$JOB" wait "$NAME" --max-seconds 0
    assert_failure 124
    assert_output --partial 'running'
    run "$JOB" status "$NAME"
    assert_failure 124
    run "$JOB" wait "$NAME" --max-seconds 5
    assert_success
}
@test "failed jobs return one and retain the failure section instead of the whole log" {
    run "$JOB" start "$NAME" -- bash -c 'echo secret-prefix; for i in {1..100}; do echo filler; done; echo "not ok 1 gate failed"; for i in {1..100}; do echo trailing; done; exit 7'
    assert_success
    run "$JOB" wait "$NAME"
    assert_failure 1
    assert_output --partial 'failed (exit 7)'
    assert_output --partial 'not ok 1 gate failed'
    refute_output --partial 'secret-prefix'
}
@test "arguments are validated before help and names cannot escape state" {
    run "$JOB" --help
    assert_success
    assert_output --partial 'Usage:'
    run "$JOB" --help --bogus
    assert_failure 2
    assert_output --partial "unknown option '--bogus' (see --help)"
    run "$JOB" start ../escape -- true
    assert_failure 2
    run "$JOB" wait "$NAME" --max-seconds -1
    assert_failure 2
    run "$JOB" status "$NAME" --help --bogus
    assert_failure 2
}
