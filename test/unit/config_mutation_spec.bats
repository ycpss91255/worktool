#!/usr/bin/env bats
# Mutation, control and renderer purity cases generated from the shared tables.
# Repository drift checks live in config_mutation_drift_spec.bats.
# Every row's mutant must fail each named case; the control runs each case
# on a clean copy. Renderer mutants must also change only their own element
# on ALL, with the exact expected bytes recorded in the shared rows.
# Behavioural mutants claim only that they are caught.
# eof is only the final line's terminator; blank includes whitespace-only lines.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/config_mutation_rows"
load "${BATS_TEST_DIRNAME}/../helper/config_mutation_mutants"

bats_require_minimum_version 1.5.0

# Every property's element at once: a comment, a blank and a
# whitespace-only line, an own key (home) not in last place and repeated,
# known foreign keys (link, box) with a duplicate and a CRLF line, an
# unknown key, several foreign lines in order, trailing blank lines and a
# final line without a terminator.
ALL='# c\n\n  \nhome=/old\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nhome=/old2\nlink=.z\n\n  '

# --- machinery ---------------------------------------------------------------

setup_file() {
    CLEAN="${BATS_FILE_TMPDIR}/clean"
    mkdir -p "${CLEAN}"
    cp -R "${REPO_ROOT}/lib" "${REPO_ROOT}/script" "${REPO_ROOT}/test" \
        "${REPO_ROOT}/box" "${CLEAN}/"
    export CLEAN
}

setup() {
    COPY="${BATS_TEST_TMPDIR}/repo"
    cp -R "${CLEAN}" "${COPY}"
}

# Add mutant $1 (a _mut_ suffix) to the copy.
_mutate() {
    local _code _head _target
    _code="$("_mut_$1")"
    _head="${_code%%$'\n'*}"
    _code="${_code#*$'\n'}"
    _target="${COPY}/${_head#?? }"
    case "${_head}" in
        '#> '*) printf '\n%s\n' "${_code}" >>"${_target}" ;;
        '#^ '*)
            # Before the run guard: `if [[ "${BASH_SOURCE[0]:-}" == ...`.
            awk -v c="${_code}" \
                '/^if \[\[/ && index($0, "BASH_SOURCE[0]") && !done { print c; done = 1 } { print }' \
                "${_target}" >"${_target}.new"
            grep -qF -- "${_code%%$'\n'*}" "${_target}.new" || return 1
            cat "${_target}.new" >"${_target}"
            rm -f "${_target}.new"
            ;;
    esac
}

# Run the cases of `<spec>@<regex>` $1 against tree $2: TAP in CASE_OUT,
# status in CASE_RC.
_run_case() {
    CASE_RC=0
    CASE_OUT="$(bats --filter "${1#*@}" "$2/test/${1%%@*}" 2>&1)" || CASE_RC=$?
}

# The row of mutant $1.
# The row of mutant $1, from the property table.
_row() { _rows | awk -F'|' -v m="$1" '$3 == m'; }

# The cases of mutant $1: its property row's, or its owner row's.
_cases_of() {
    local _c
    _c="$(_row "$1" | cut -d'|' -f6)"
    [[ -n "${_c}" ]] || _c="$(_owner_rows | awk -F'|' -v m="$1" '$2 == m' | cut -d'|' -f3)"
    printf '%s\n' "${_c}"
}

_assert_caught() {
    local _cases _c
    _cases="$(_cases_of "$1")"
    [[ -n "${_cases}" && "${_cases}" != - ]] || fail "mutant $1 has no cases"
    _mutate "$1"
    IFS=';' read -r -a _c <<<"${_cases}"
    for _c in "${_c[@]}"; do
        _run_case "${_c}" "${COPY}"
        grep -qE '^not ok [0-9]+ ' <<<"${CASE_OUT}" \
            || fail "mutant $1 was not caught by ${_c}: ${CASE_OUT}"
        ! grep -qE '^ok [0-9]+ ' <<<"${CASE_OUT}" \
            || fail "mutant $1 survived a case of ${_c}: ${CASE_OUT}"
    done
}

# Render ALL with the library of tree $1 and config_set args $2..; prints
# the resulting file's path.
_render_all() {
    local _tree="$1" _f
    shift
    _f="$(mktemp -d "${BATS_TEST_TMPDIR}/all.XXXXXX")/state"
    printf '%b' "${ALL}" >"${_f}"
    WORKTOOL_CONFIG_FILE="${_f}" bash -c \
        'source "$1/lib/log.sh"; source "$1/lib/config.sh"; shift; config_set "$@"' _ "${_tree}" "$@" \
        || return 1
    printf '%s\n' "${_f}"
}

# 0 when mutant $1 writes exactly expected bytes $2 (replace) and $3
# (append) on ALL; `=` means the real library's bytes.
_pure() {
    local _m="$1" _er="$2" _ea="$3" _got _want
    _mutate "${_m}" || return 1
    _got="$(_render_all "${COPY}" home /new)" || return 1
    if [[ "${_er}" == = ]]; then _want="$(_render_all "${CLEAN}" home /new)"
    else _want="${BATS_TEST_TMPDIR}/want.r"; printf '%b' "${_er}" >"${_want}"; fi
    cmp -s -- "${_want}" "${_got}" || return 1
    _got="$(_render_all "${COPY}" home /new zz 1 yy 2)" || return 1
    if [[ "${_ea}" == = ]]; then _want="$(_render_all "${CLEAN}" home /new zz 1 yy 2)"
    else _want="${BATS_TEST_TMPDIR}/want.a"; printf '%b' "${_ea}" >"${_want}"; fi
    cmp -s -- "${_want}" "${_got}"
}

_assert_pure() {
    local _id _k _m _r _a _cases
    IFS='|' read -r _id _k _m _r _a _cases <<<"$(_row "$1")"
    _pure "$1" "${_r}" "${_a}" \
        || fail "renderer mutant $1 (${_id}) is not pure: on ALL it changes bytes outside its own element"
}

# Generated tests: every row is caught; renderer rows are also pure; the
# owner row expands to one caught-test per owner module.
while IFS='|' read -r _id _k _m _r _a _cases; do
    if [[ "${_m}" == @owner ]]; then
        while IFS='|' read -r _mod _om _oc; do
            bats_test_function --description "mutant ${_om} (${_id}, ${_mod}) is caught" -- _assert_caught "${_om}"
        done < <(_owner_rows)
        continue
    fi
    bats_test_function --description "mutant ${_m} (${_id}) is caught" -- _assert_caught "${_m}"
    [[ "${_k}" != render ]] \
        || bats_test_function --description "purity: renderer mutant ${_m} (${_id}) changes only its own element" -- _assert_pure "${_m}"
done < <(_rows)

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "control: every case of the table passes on the unmutated copy" {
    local _c
    while IFS= read -r _c; do
        _run_case "${_c}" "${CLEAN}"
        [[ "${CASE_RC}" -eq 0 ]] || fail "control ${_c} failed: ${CASE_OUT}"
        grep -qE '^ok [0-9]+ ' <<<"${CASE_OUT}" || fail "control ${_c} ran no case: ${CASE_OUT}"
    done < <({ _rows | cut -d'|' -f6; _owner_rows | cut -d'|' -f3; } | tr ';' '\n' | grep -vx -- '-' | sort -u)
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
