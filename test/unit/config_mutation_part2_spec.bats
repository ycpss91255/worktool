#!/usr/bin/env bats
# test/unit/config_mutation_part2_spec.bats - the second third of the
# generated config mutants (issue #839). The table, mutants and checks live
# in test/helper/config_mutation.bash; config_mutation_spec.bats holds the
# drift guards, controls and the first third.

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
