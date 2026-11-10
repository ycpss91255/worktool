#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# Unit spec for lib/test_shard.sh (issue #831): split a bats tier into N
# shards by weight, and the union verdict that applies the whole-tier rules
# to the shards' records.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    # shellcheck source=../../lib/test_shard.sh
    source "${LIB_DIR}/test_shard.sh"
}

@test "assignment balances by weight, heaviest first, ties by path and lowest shard" {
    run test_shard_assign 3 <<'ROWS'
100	a_spec.bats
900	b_spec.bats
400	hook/c_spec.bats
400	hook/d_spec.bats
300	e_spec.bats
100	f_spec.bats
ROWS
    assert_success
    assert_output "$(printf '%s\n' \
        "1	b_spec.bats" \
        "2	hook/c_spec.bats" \
        "3	hook/d_spec.bats" \
        "2	e_spec.bats" \
        "3	a_spec.bats" \
        "3	f_spec.bats")"
}
