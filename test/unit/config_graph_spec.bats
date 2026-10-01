#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/graph"

bats_require_minimum_version 1.5.0

@test "source graph resolves a script-relative sibling lib path" {
    local _tree="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_tree}/script/test" "${_tree}/lib"
    cat >"${_tree}/script/test/read.sh" <<'EOF'
source "${SCRIPT_DIR}/../../lib/config.sh"
EOF
    : >"${_tree}/lib/config.sh"

    run graph_modules "${_tree}" script/test/read.sh
    assert_success
    assert_output $'script/test/read.sh\nlib/config.sh'
}

@test "judge derivation emits no partial list when a later source graph cannot resolve" {
    local _tree="${BATS_TEST_TMPDIR}/repo" stderr=""
    mkdir -p "${_tree}/script/a" "${_tree}/script/z"
    printf '%s\n' 'judge_run() { config_get home; }' >"${_tree}/script/a/judge.sh"
    cat >"${_tree}/script/z/unknown.sh" <<'EOF'
source "$UNKNOWN/audit.sh"
EOF

    run --separate-stderr graph_judges "${_tree}" config_get
    assert_failure
    assert_output ""
    [[ "${stderr}" == *'unresolved source line'* ]] || fail "missing graph diagnostic: ${stderr}"
}
