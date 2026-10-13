#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
setup() {
    JOB_ROOT="$(mktemp -d)"
    chmod 755 "${JOB_ROOT}"
    mkdir -p "${JOB_ROOT}/.agents/script" "${JOB_ROOT}/lib"
    cp "${REPO_ROOT}/.agents/script/job.sh" "${JOB_ROOT}/.agents/script/"
    cp "${REPO_ROOT}/lib/log.sh" "${JOB_ROOT}/lib/"
    JOB="${JOB_ROOT}/.agents/script/job.sh"
    NAME="spec-${BATS_TEST_NUMBER}-$$"
}
teardown() {
    chmod -R u+w "${JOB_ROOT}"
    rm -rf "${JOB_ROOT}"
}
@test "start reports permission denial when the state or job directory cannot be created" {
    local blocked
    local as_user=()
    if [[ "$(id -u)" -eq 0 ]]; then
        as_user=(setpriv --reuid=65534 --regid=65534 --clear-groups)
    fi
    for blocked in "${JOB_ROOT}/.agents/state/job" "${JOB_ROOT}/.agents/state"; do
        mkdir -p "${blocked}"
        chmod 555 "${blocked}"
        run "${as_user[@]}" "$JOB" start "$NAME" -- true
        assert_failure 1
        assert_output --partial 'Permission denied'
        assert_output --partial 'cannot create job directory'
        refute_output --partial 'job already exists'
        assert [ ! -d "${JOB_ROOT}/.agents/state/job/${NAME}" ]
        chmod 755 "${blocked}"
        rm -rf "${JOB_ROOT}/.agents/state"
    done
}
@test "start reports already exists only when the job path is a directory" {
    mkdir -p "${JOB_ROOT}/.agents/state/job/${NAME}"
    run "$JOB" start "$NAME" -- true
    assert_failure 1
    assert_output --partial "job already exists: ${NAME}"
    refute_output --partial 'cannot create job directory'

    rmdir "${JOB_ROOT}/.agents/state/job/${NAME}"
    touch "${JOB_ROOT}/.agents/state/job/${NAME}"
    run "$JOB" start "$NAME" -- true
    assert_failure 1
    assert_output --partial 'cannot create job directory'
    refute_output --partial 'job already exists'
}
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
@test "help cannot hide invalid wait values or extra status arguments" {
    run "$JOB" wait "$NAME" --max-seconds banana --help
    assert_failure 2
    run "$JOB" wait "$NAME" --max-seconds --help
    assert_failure 2
    run "$JOB" status "$NAME" extra --help
    assert_failure 2
    run "$JOB" wait "$NAME" --max-seconds 0 --help
    assert_success
}
@test "status of a failed job reports failure without blocking" {
    run "$JOB" start "$NAME" -- false
    assert_success
    run "$JOB" wait "$NAME"
    assert_failure 1
    run "$JOB" status "$NAME"
    assert_failure 1
    assert_output --partial 'failed (exit 1)'
}
@test "bare just job lists the shared runner actions" {
    run just -f "${REPO_ROOT}/justfile" job
    assert_success
    assert_output --partial 'start'
    assert_output --partial 'wait'
    assert_output --partial 'status'
}
@test "failure summaries preserve ShellCheck diagnostics before the recipe error" {
    run "$JOB" start "$NAME" -- bash -c 'echo secret-prefix; for i in {1..100}; do echo filler; done; echo "In /source/example.sh line 13:"; echo "SC2016: invalid quoting"; echo "[ci] ERROR: ShellCheck failed"; echo "error: recipe lint failed"; for i in {1..100}; do echo trailing; done; exit 1'
    assert_success
    run "$JOB" wait "$NAME"
    assert_failure 1
    assert_output --partial 'SC2016: invalid quoting'
    refute_output --partial 'secret-prefix'
}

@test "wait reports a vanished worker without an rc as a failure (#552)" {
    mkdir -p "${JOB_ROOT}/.agents/state/job/${NAME}"
    printf '%s\n' 2147483647 > "${JOB_ROOT}/.agents/state/job/${NAME}/pid"
    run timeout 3 "$JOB" wait "$NAME"
    assert_failure 1
    assert_output --partial 'worker 異常結束'
}
