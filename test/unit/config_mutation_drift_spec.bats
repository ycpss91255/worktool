#!/usr/bin/env bats
# Cheap repository-wide drift guards for config property and owner tables.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/graph"
load "${BATS_TEST_DIRNAME}/../helper/config_mutation_rows"
load "${BATS_TEST_DIRNAME}/../helper/config_mutation_mutants"

setup_file() {
    CLEAN="${BATS_FILE_TMPDIR}/clean"
    mkdir -p "${CLEAN}"
    cp -R "${REPO_ROOT}/lib" "${REPO_ROOT}/script" "${REPO_ROOT}/test" \
        "${REPO_ROOT}/box" "${CLEAN}/"
    export CLEAN
}

# The @prop drift of header file $1 against the table, one line per
# violation: an ID claimed twice, an ID with two rows, an ID claimed but
# not in the table or the other way round. One row per @prop line.
_drift_violations() {
    local _claimed _covered
    _claimed="$(sed -n 's/^#[[:space:]]*@prop[[:space:]]\{1,\}\([a-z-]\{1,\}\).*/\1/p' "$1")"
    _covered="$(_rows | cut -d'|' -f1)"
    [[ -n "${_claimed}" ]] || echo "no @prop line in $1"
    sort <<<"${_claimed}" | uniq -d | sed 's/^/claimed twice: /'
    sort <<<"${_covered}" | uniq -d | sed 's/^/two table rows: /'
    comm -23 <(sort <<<"${_claimed}") <(sort <<<"${_covered}") | sed 's/^/claimed, no row: /'
    comm -13 <(sort <<<"${_claimed}") <(sort <<<"${_covered}") | sed 's/^/row, not claimed: /'
    [[ "$(wc -l <<<"${_claimed}")" -eq "$(wc -l <<<"${_covered}")" ]] \
        || echo "$(wc -l <<<"${_claimed}") @prop lines, $(wc -l <<<"${_covered}") rows"
}

# The owner rows' drift in tree $1: every module of the source graph of
# every script under script/ whose graph reaches lib/config.sh that names a public config_* function or
# XDG_CONFIG_HOME in a non-comment line (graph_touches_config) needs an
# owner row, and every owner row names such a module; other modules are not
# checked. One line per violation.
_owner_module_violations() {
    local _tree="$1" _s _m _mods=""
    for _s in "${_tree}"/script/*/*.sh; do
        _s="${_s#"${_tree}"/}"
        _m="$(graph_modules "${_tree}" "${_s}")" || { echo "unresolved source graph of ${_s}"; continue; }
        grep -qx 'lib/config.sh' <<<"${_m}" || continue
        _mods+="${_m}"$'\n'
    done
    _mods="$(sort -u <<<"${_mods}" | while IFS= read -r _m; do
        [[ -n "${_m}" ]] && graph_touches_config "${_tree}" "${_m}" && printf '%s\n' "${_m}"
    done)"
    comm -23 <(printf '%s\n' "${_mods}" | sort -u) <(_owner_rows | cut -d'|' -f1 | sort -u) \
        | sed 's/^/module names the config API but has no owner row: /'
    comm -13 <(printf '%s\n' "${_mods}" | sort -u) <(_owner_rows | cut -d'|' -f1 | sort -u) \
        | sed 's/^/owner row for a module outside the graph: /'
}

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

