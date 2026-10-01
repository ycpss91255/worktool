#!/usr/bin/env bats
load ../../helper/common

setup() {
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
    export MODEL_LIST="${BATS_TEST_TMPDIR}/models"
    printf '#!/bin/sh\n[ "$1" = models ] || exit 99\ncat "$MODEL_LIST"\n' > "${BATS_TEST_TMPDIR}/bin/agy"
    chmod +x "${BATS_TEST_TMPDIR}/bin/agy"
}

@test "agy model fails closed when no Gemini flash-high model is available" {
    printf '%s\tDisplay name\n' claude-9.0-flash-high gemini-4.0-pro-high > "${MODEL_LIST}"
    _resolve
    assert_failure
    assert_output --partial 'no Gemini flash-high model'
}

_resolve() {
    run just --justfile "${REPO_ROOT}/.agents/script/research/justfile.research" model "$@"
}

@test "agy model rejects a failed models command even with a valid model in stdout" {
    printf '#!/bin/sh\necho gemini-3.10-flash-high\nexit 7\n' > "${BATS_TEST_TMPDIR}/bin/agy"
    _resolve
    assert_failure
    assert_output --partial 'agy models failed'
    refute_line 'gemini-3.10-flash-high'
}

@test "agy model selects the highest numeric Gemini flash-high version" {
    printf '%s\tDisplay name\n' gemini-3.9-flash-high gemini-3.8-flash-high \
        gemini-3.10-flash-high gemini-4.0-pro-high gemini-4.0-flash-low \
        claude-9.0-flash-high gemini-3.10-flash-high-preview > "${MODEL_LIST}"
    _resolve
    assert_success
    assert_line 'gemini-3.10-flash-high'
    refute_line 'gemini-3.9-flash-high'
}
