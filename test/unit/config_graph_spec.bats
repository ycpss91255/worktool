#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/graph"

@test "source graph resolves a script-relative sibling lib path" {
    local _tree="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_tree}/script/test" "${_tree}/lib"
    printf '%s\n' 'source "${SCRIPT_DIR}/../../lib/config.sh"' >"${_tree}/script/test/read.sh"
    : >"${_tree}/lib/config.sh"

    run graph_modules "${_tree}" script/test/read.sh
    assert_success
    assert_output $'script/test/read.sh\nlib/config.sh'
}
