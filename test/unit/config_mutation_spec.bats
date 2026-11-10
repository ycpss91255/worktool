#!/usr/bin/env bats
# test/unit/config_mutation_spec.bats - every @prop of lib/config.sh has a
# mutant its spec cases catch (issue #199 rounds 5-8).
#
# What is checked, and nothing more:
#   - one table (_rows), one row per `@prop` line of lib/config.sh: a drift
#     guard requires every @prop ID exactly once in the header and exactly
#     once in the table (a multiset, not a set);
#   - every row's mutant, appended to a copy of the repo, makes each case
#     the row names FAIL, and every named case passes on the clean copy
#     (control);
#   - renderer rows (kind `render`: the mutant only changes what config_set
#     writes) are also PURE: on ALL, a fixture holding every renderer
#     property's element at once, the mutant writes exactly the bytes the
#     row states - the real bytes with only its own element changed. The
#     check is shown to reject round 5's and round 7's impure mutants.
#     Behavioural rows (kind `behave`) claim "caught", nothing more;
#   - the `owner` row expands to _owner_rows, one rogue path-builder per
#     module of a source graph reaching lib/config.sh (scripts under script/, followed
#     through `source` lines by test/helper/graph.bash) that names a public
#     config_* function or XDG_CONFIG_HOME in a non-comment line; a guard
#     fails on such a module without a row. Modules that name neither are
#     not checked.
# The tests are generated from the rows (bats_test_function).
#
# eof is only the final line's terminator (LF, CRLF, none); blank is blank
# and whitespace-only lines anywhere, trailing ones included. The eof mutant
# deletes no line; the blank mutant keeps the file's final terminator.

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

@test "drift guard: every @prop line of lib/config.sh has exactly one row, every ID exactly once" {
    run _drift_violations "${REPO_ROOT}/lib/config.sh"
    assert_output ""
}

@test "drift guard: a second @prop line with an existing ID is caught" {
    local _h="${BATS_TEST_TMPDIR}/config.sh"
    cp "${REPO_ROOT}/lib/config.sh" "${_h}"
    printf '#   @prop eof           a second promise under an existing ID\n' >>"${_h}"
    run _drift_violations "${_h}"
    assert_line "claimed twice: eof"
}

@test "drift guard: every row's mutant exists and every mutant has a row" {
    local _m _fns
    while IFS= read -r _m; do
        declare -F "_mut_${_m}" >/dev/null || fail "row names a missing mutant: _mut_${_m}"
    done < <({ _rows | cut -d'|' -f3 | grep -v '^@'; _owner_rows | cut -d'|' -f2; })
    _fns="$(declare -F | awk '{print $3}' | sed -n 's/^_mut_//p' | grep -v '^legacy_' | sort)"
    run diff <(printf '%s\n' "${_fns}") <({ _rows | cut -d'|' -f3 | grep -v '^@'; _owner_rows | cut -d'|' -f2; } | sort)
    [[ "${status}" -eq 0 ]] || fail "mutants without a row (<) / rows without a mutant (>): ${output}"
}

@test "drift guard: every module of the source graph that names a public config_* function or XDG_CONFIG_HOME in a non-comment line has an owner row" {
    run _owner_module_violations "${REPO_ROOT}"
    assert_output ""
}

@test "owner module guard ignores isolated XDG environments but catches reachable path builders" {
    local _tree="${BATS_TEST_TMPDIR}/tree"
    cp -R "${CLEAN}" "${_tree}"
    printf '%s\n' 'env XDG_CONFIG_HOME=/isolated external-command' \
        >"${_tree}/script/test/isolated.sh"
    run _owner_module_violations "${_tree}"
    assert_output ""

    cat >"${_tree}/script/test/isolated.sh" <<'EOF'
source "${LIB_DIR}/config.sh"
audit_path() { printf "%s/worktool/config\n" "${XDG_CONFIG_HOME}"; }
EOF
    run _owner_module_violations "${_tree}"
    assert_line 'module names the config API but has no owner row: script/test/isolated.sh'
}

@test "drift guard: a module reached only through another library is found" {
    local _t="${BATS_TEST_TMPDIR}/tree"
    cp -R "${CLEAN}" "${_t}"
    cat >"${_t}/lib/audit.sh" <<'EOF'
audit_path() { printf '%s/x\n' "$(config_xdg_dir)"; }
EOF
    # lib/enter.sh (reached from setup and status) sources it, the way the
    # libraries source each other.
    cat >>"${_t}/lib/enter.sh" <<'EOF'
source "${_ENTER_LIB_DIR}/audit.sh"
EOF
    run _owner_module_violations "${_t}"
    assert_line "module names the config API but has no owner row: lib/audit.sh"
}

# The control runs in one of two modes (issue #860), chosen by
# WORKTOOL_FULL_CHECK (_control_mode):
#   pr    (unset or empty: PR runs and local runs) - one cheap case per spec
#         file the table names (_control_cheap): proves the copy tree runs
#         every spec the mutants are judged by, so a broken copy cannot read
#         every mutant as caught. The table's cases themselves pass on the
#         same tree in their own tiers in the same CI run.
#   full  (1: the complete check after a merge into main) - every case the
#         table names, and the number of cases that ran must equal the
#         number the table's filters select.
# Any other value fails the control (fail closed).
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
