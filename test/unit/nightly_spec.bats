#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# Unit spec for lib/nightly.sh (issue #836): when the nightly full serial
# run runs, and what it reports, around the open `nightly-failure` issue.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    # shellcheck source=../../lib/nightly.sh
    source "${LIB_DIR}/nightly.sh"
}

@test "a scheduled run skips while a nightly-failure issue is open, and says which" {
    run --separate-stderr nightly_decide schedule 0 $'41\n17'
    assert_success
    assert_output 'skip 17'
    [[ "${stderr:-}" == *'#17'* ]] || fail "the skip does not name the open issue: ${stderr:-}"
}
