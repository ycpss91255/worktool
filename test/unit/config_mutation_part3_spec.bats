#!/usr/bin/env bats
# test/unit/config_mutation_part3_spec.bats - part 3 of 3 of the generated
# config mutant cases (issue #839). The table, mutants and checks live in
# test/helper/config_mutation.bash; config_mutation_spec.bats holds the
# controls and part 1; config_mutation_drift_spec.bats holds drift guards.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/graph"
load "${BATS_TEST_DIRNAME}/../helper/config_mutation"

bats_require_minimum_version 1.5.0

config_mutation_register 3 3

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
