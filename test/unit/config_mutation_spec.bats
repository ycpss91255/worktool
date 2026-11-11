#!/usr/bin/env bats
# Mutation controls and the first of three generated case partitions.
# Property and owner drift checks live in config_mutation_drift_spec.bats.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/graph"
load "${BATS_TEST_DIRNAME}/../helper/config_mutation"

bats_require_minimum_version 1.5.0

# The generated cases, first of three parts (issue #839); the table,
# mutants and checks live in test/helper/config_mutation.bash.
config_mutation_register 1 3

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "control: every case of the table passes on the unmutated copy" {
    local _mode _refs _c _oks _want _ran=0 _total=0
    _mode="$(_control_mode)" || fail "invalid WORKTOOL_FULL_CHECK '${WORKTOOL_FULL_CHECK:-}' (unset or 1)"
    # Listed in this shell first: a failed listing fails the case instead of
    # ending the loop early in a process substitution.
    _refs="$(_control_refs "${_mode}")" || fail "control (${_mode}): cannot list its cases"
    [[ -n "${_refs}" ]] || fail "control (${_mode}): no case listed"
    while IFS= read -r _c; do
        _run_case "${_c}" "${CLEAN}"
        [[ "${CASE_RC}" -eq 0 ]] || fail "control ${_c} failed: ${CASE_OUT}"
        _oks="$(grep -cE '^ok [0-9]+ ' <<<"${CASE_OUT}")" || fail "control ${_c} ran no case: ${CASE_OUT}"
        _want="$(bats --count --filter "${_c#*@}" "${CLEAN}/test/${_c%%@*}")" \
            || fail "control ${_c}: bats cannot count it"
        [[ "${_oks}" -eq "${_want}" ]] || fail "control ${_c}: ${_oks} case(s) ran, ${_want} selected"
        _ran=$(( _ran + _oks ))
        _total=$(( _total + _want ))
    done <<<"${_refs}"
    [[ "${_ran}" -gt 0 && "${_ran}" -eq "${_total}" ]] \
        || fail "control (${_mode}): ${_ran} case(s) ran, ${_total} selected"
    echo "# control (${_mode}): ${_ran} case(s) ran" >&3
}

@test "control selection: full is the whole table, pr runs one selecting case per spec file, other modes fail" {
    local _full _specs _c _n
    _full="$(_table_refs)"
    [[ -n "${_full}" ]] || fail "the table names no case"
    run _control_refs full
    assert_success
    assert_output "${_full}"
    # pr: every spec file the table names, exactly once, each with a filter
    # that selects at least one case of that spec.
    _specs="$(cut -d@ -f1 <<<"${_full}" | sort -u)"
    run _control_refs pr
    assert_success
    assert_equal "$(cut -d@ -f1 <<<"${output}" | sort)" "${_specs}"
    while IFS= read -r _c; do
        _n="$(bats --count --filter "${_c#*@}" "${REPO_ROOT}/test/${_c%%@*}")"
        [[ "${_n}" -ge 1 ]] || fail "pr control ${_c} selects no case"
    done <<<"${output}"
    run _control_refs other
    assert_failure
    # The mode: unset or empty is pr, 1 is full, anything else fails.
    WORKTOOL_FULL_CHECK='' run _control_mode
    assert_output pr
    WORKTOOL_FULL_CHECK=1 run _control_mode
    assert_output full
    WORKTOOL_FULL_CHECK=yes run _control_mode
    assert_failure
    unset WORKTOOL_FULL_CHECK
    run _control_mode
    assert_output pr
}

@test "purity: the check rejects round 5's grep mutant and round 7's eof mutant" {
    run _pure legacy_grep "$(_row unknown | cut -d'|' -f4)" "$(_row unknown | cut -d'|' -f5)"
    assert_failure
    rm -rf "${COPY}"; cp -R "${CLEAN}" "${COPY}"
    run _pure legacy_eof "$(_row eof | cut -d'|' -f4)" "$(_row eof | cut -d'|' -f5)"
    assert_failure
}

@test "the location mutant changes only where the state file resolves" {
    _mutate location
    # Other XDG files (the terminal profile) still follow XDG_CONFIG_HOME ...
    XDG_CONFIG_HOME=/xdg run bash -c 'source "$1/lib/log.sh"; source "$1/lib/config.sh"; config_xdg_dir' _ "${COPY}"
    assert_output "/xdg"
    # ... and the messages still name the file config.sh uses.
    _run_case 'unit/config_spec.bats@config_log / config_say / config_fill' "${COPY}"
    [[ "${CASE_RC}" -eq 0 ]] || fail "the location mutant also broke the messages: ${CASE_OUT}"
}
