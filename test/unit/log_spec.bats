#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/log_spec.bats - lib/log.sh logging helpers (M1)
#
# First real unit spec: proves the bats-in-Docker harness end-to-end.
# Written test-first (RED) before lib/log.sh exists, then lib/log.sh is
# implemented to pass (GREEN).
#
# Contract under test:
#   - log_info / log_warn / log_error each write to STDERR (not stdout)
#   - each line is prefixed with its level tag ([INFO]/[WARN]/[ERROR])
#     followed by the message
#   - each returns 0
#
# Stream separation is asserted by capturing stdout and stderr into
# separate files (rather than bats' $stderr) so the specs stay clean under
# ShellCheck without disable directives.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    OUT="${BATS_TEST_TMPDIR}/out"
    ERR="${BATS_TEST_TMPDIR}/err"
}

source_log() {
    # shellcheck source=../../lib/log.sh
    source "${LIB_DIR}/log.sh"
}

# --- Library guard -----------------------------------------------------------

@test "log.sh can be sourced without side effects on stdout" {
    run bash -c "source '${LIB_DIR}/log.sh'"
    assert_success
    assert_output ""
}

# --- log_info ----------------------------------------------------------------

@test "log_info writes the message with an [INFO] prefix to stderr" {
    source_log
    log_info "hello world" >"${OUT}" 2>"${ERR}"
    run cat "${ERR}"
    assert_output "[INFO] hello world"
}

@test "log_info writes nothing to stdout" {
    source_log
    log_info "on stderr" >"${OUT}" 2>"${ERR}"
    run cat "${OUT}"
    assert_output ""
}

@test "log_info returns 0" {
    source_log
    run log_info "return code check"
    assert_success
}

# --- log_warn ----------------------------------------------------------------

@test "log_warn writes the message with a [WARN] prefix to stderr" {
    source_log
    log_warn "careful" >"${OUT}" 2>"${ERR}"
    run cat "${OUT}"
    assert_output ""
    run cat "${ERR}"
    assert_output "[WARN] careful"
}

# --- log_error ---------------------------------------------------------------

@test "log_error writes the message with an [ERROR] prefix to stderr" {
    source_log
    log_error "boom" >"${OUT}" 2>"${ERR}"
    run cat "${OUT}"
    assert_output ""
    run cat "${ERR}"
    assert_output "[ERROR] boom"
}

@test "log_error returns 0" {
    source_log
    run log_error "still zero"
    assert_success
}

# --- multi-word / empty messages ---------------------------------------------

@test "log_info preserves a multi-word message verbatim" {
    source_log
    log_info "one two three" 2>"${ERR}"
    run cat "${ERR}"
    assert_output "[INFO] one two three"
}

@test "log_info emits only the prefix for an empty message" {
    source_log
    log_info "" 2>"${ERR}"
    run cat "${ERR}"
    assert_output "[INFO] "
}
