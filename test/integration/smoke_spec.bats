#!/usr/bin/env bats
# test/integration/smoke_spec.bats - Docker integration harness smoke test (M1)
#
# Proves the integration gate actually runs inside the test container and
# that lib/log.sh works end-to-end (sourced, then invoked, output captured).
# No distrobox yet - that begins at M2.
#
# Stream separation is asserted via captured files rather than bats' $stderr
# so the spec stays clean under ShellCheck without disable directives.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    OUT="${BATS_TEST_TMPDIR}/out"
    ERR="${BATS_TEST_TMPDIR}/err"
}

@test "bash is available and reports a version" {
    run bash --version
    assert_success
    assert_output --partial "GNU bash"
}

@test "lib/log.sh exists and is a regular file" {
    assert [ -f "${LIB_DIR}/log.sh" ]
}

@test "lib/log.sh sources and log_info works end-to-end" {
    bash -c "source '${LIB_DIR}/log.sh'; log_info 'integration ok'" \
        >"${OUT}" 2>"${ERR}"
    run cat "${OUT}"
    assert_output ""
    run cat "${ERR}"
    assert_output "[INFO] integration ok"
}

@test "log_error round-trips through a sourced subshell and returns 0" {
    bash -c "source '${LIB_DIR}/log.sh'; log_error 'boom'; echo \"rc=\$?\"" \
        >"${OUT}" 2>"${ERR}"
    run cat "${OUT}"
    assert_output "rc=0"
    run cat "${ERR}"
    assert_output "[ERROR] boom"
}
