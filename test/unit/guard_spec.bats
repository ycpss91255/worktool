#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "#576: zero matching lines returns zero without aborting an errexit caller" {
    printf 'other\n' >"${BATS_TEST_TMPDIR}/input"

    run bash -c '
        set -euo pipefail
        source "$1/guard.sh"
        guard_count_lines "$2" "^missing$"
        printf "returned=%s\n" "$?"
    ' _ "${LIB_DIR}" "${BATS_TEST_TMPDIR}/input"

    assert_success
    assert_output $'0\nreturned=0'
}
