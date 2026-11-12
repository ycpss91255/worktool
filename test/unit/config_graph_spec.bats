#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/graph"

bats_require_minimum_version 1.5.0

@test "source graph resolves literal script-directory sibling and rejects dynamic paths" {
    local _tree="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_tree}/script/verify"
    cat >"${_tree}/script/verify/read.sh" <<'EOF'
source "${SCRIPT_DIR}/paths.sh"
EOF
    cat >"${_tree}/script/verify/paths.sh" <<'EOF'
source "${SCRIPT_DIR}/leaf.sh"
EOF
    : >"${_tree}/script/verify/leaf.sh"
    run graph_modules "${_tree}" script/verify/read.sh
    assert_success
    assert_output $'script/verify/read.sh\nscript/verify/paths.sh\nscript/verify/leaf.sh'
    cat >"${_tree}/script/verify/read.sh" <<'EOF'
source "${SCRIPT_DIR}/${NAME}.sh"
EOF
    run graph_modules "${_tree}" script/verify/read.sh
    assert_failure
    assert_output --partial 'unresolved source line'
    cat >"${_tree}/script/verify/read.sh" <<'EOF'
source "${SCRIPT_DIR}/../outside.sh"
EOF
    run graph_modules "${_tree}" script/verify/read.sh
    assert_failure
    assert_output --partial 'unresolved source line'
    cat >"${_tree}/script/verify/read.sh" <<'EOF'
source "${SCRIPT_DIR}/../../lib/${NAME}.sh"
EOF
    run graph_modules "${_tree}" script/verify/read.sh
    assert_failure
    assert_output --partial 'unresolved source line'
    cat >"${_tree}/script/verify/read.sh" <<'EOF'
source "${SCRIPT_DIR}/../../lib/../outside.sh"
EOF
    run graph_modules "${_tree}" script/verify/read.sh
    assert_failure
    assert_output --partial 'unresolved source line'
}

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

@test "a missing source fails the graph and emits no partial judge list" {
    local _tree="${BATS_TEST_TMPDIR}/repo" stderr=""
    mkdir -p "${_tree}/script/a" "${_tree}/script/z"
    printf '%s\n' 'judge_run() { config_get home; }' >"${_tree}/script/a/judge.sh"
    cat >"${_tree}/script/z/broken.sh" <<'EOF'
source "${SCRIPT_DIR}/missing.sh"
EOF

    run --separate-stderr graph_modules "${_tree}" script/z/broken.sh
    assert_failure
    [[ "${stderr}" == *'missing.sh'* ]] || fail "missing file diagnostic: ${stderr}"
    run --separate-stderr graph_judges "${_tree}" config_get
    assert_failure
    assert_output ""
    [[ "${stderr}" == *'missing.sh'* ]] || fail "missing file diagnostic: ${stderr}"
}

@test "function extraction failures do not emit a partial judge list" {
    local _tree="${BATS_TEST_TMPDIR}/repo" _calls="${BATS_TEST_TMPDIR}/calls" stderr=""
    mkdir -p "${_tree}/script/a" "${_tree}/script/z"
    printf '%s\n' 'judge_run() { config_get home; }' >"${_tree}/script/a/judge.sh"
    printf '%s\n' 'other_run() { :; }' >"${_tree}/script/z/other.sh"
    _graph_functions() {
        if [[ "$2" == script/z/other.sh ]]; then
            printf 'call\n' >>"${_calls}"
            [[ "$(wc -l <"${_calls}")" != "${FAIL_CALL}" ]] || return 1
        fi
        awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn = $0; sub(/\(.*/, "", fn); print fn "\t" $0 }' "$1/$2"
    }
    local FAIL_CALL=1
    run --separate-stderr graph_judges "${_tree}" config_get
    assert_failure
    assert_output ""
    rm "${_calls}"
    FAIL_CALL=2
    run --separate-stderr graph_judges "${_tree}" config_get
    assert_failure
    assert_output ""
}

@test "source graph follows the manager library through home" {
    run graph_modules "${REPO_ROOT}" script/box/assemble.sh
    assert_success
    assert_line "lib/home.sh"
    assert_line "lib/distrobox_manager.sh"
}
