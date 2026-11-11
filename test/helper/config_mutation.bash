#!/usr/bin/env bash
# test/helper/config_mutation.bash - shared machinery and registration of the
# config mutation specs (issue #199 rounds 5-8; split in issue #839).
#
# Loaded by test/unit/config_mutation_spec.bats (controls and
# the first third of the generated mutant cases) and by
# config_mutation_part2_spec.bats / config_mutation_part3_spec.bats (the
# other thirds), after helper/common and helper/graph. The cases are
# generated from the rows by config_mutation_register; splitting them over
# three files lets the CI unit shards (issue #831) balance a tier whose
# single heaviest file this used to be. Together the three files register
# every case exactly once.


# Every property's element at once: a comment, a blank and a
# whitespace-only line, an own key (home) not in last place and repeated,
# known foreign keys (link, box) with a duplicate and a CRLF line, an
# unknown key, several foreign lines in order, trailing blank lines and a
# final line without a terminator.
ALL='# c\n\n  \nhome=/old\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nhome=/old2\nlink=.z\n\n  '

# Share the property tables and mutants with the repository drift spec.
load "${BATS_TEST_DIRNAME}/../helper/config_mutation_rows"
load "${BATS_TEST_DIRNAME}/../helper/config_mutation_mutants"

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

# Every `<spec>@<regex>` the table names, deduplicated and sorted.
_table_refs() {
    { _rows | cut -d'|' -f6; _owner_rows | cut -d'|' -f3; } | tr ';' '\n' | grep -vx -- '-' | sort -u
}

# The cheap control case of spec file $1 (test/-relative): a case of that
# spec the copy tree must run (issue #860). Every spec file the table names
# needs one; a missing one fails the control.
_control_cheap() {
    case "$1" in
        unit/config_spec.bats) printf '%s\n' "$1@config_set creates a missing file" ;;
        unit/config_owner_spec.bats) printf '%s\n' "$1@owner: every status row" ;;
        unit/config_validate_spec.bats) printf '%s\n' "$1@bare key = empty value: every judged key.*: home.source via home_config_check$" ;;
        unit/setup_spec.bats) printf '%s\n' "$1@r3: setup keeps the state file.s mode" ;;
        integration/assemble_spec.bats) printf '%s\n' "$1@r3: assemble keeps the state file.s mode" ;;
        *) printf 'no cheap control case for %s (add one to _control_cheap)\n' "$1" >&2; return 1 ;;
    esac
}

# The control mode: pr when WORKTOOL_FULL_CHECK is unset or empty, full when
# it is 1; any other value returns 1 (fail closed).
_control_mode() {
    case "${WORKTOOL_FULL_CHECK:-}" in
        '') printf 'pr\n' ;;
        1) printf 'full\n' ;;
        *) return 1 ;;
    esac
}

# The control's cases for mode $1: full = the whole table (_table_refs), pr =
# one cheap case per spec file the table names.
_control_refs() {
    local _s
    case "$1" in
        full) _table_refs ;;
        pr)
            while IFS= read -r _s; do
                _control_cheap "${_s}" || return 1
            done < <(_table_refs | cut -d@ -f1 | sort -u)
            ;;
        *) return 1 ;;
    esac
}

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

# Register generated case number i (counted over every case the rows
# generate, in table order) when i % $2 == $1 - 1: every row is caught,
# renderer rows are also pure, and the owner row expands to one case per
# owner module.
config_mutation_register() {
    local _part="$1" _parts="$2" _i=0 _id _k _m _r _a _cases _mod _om _oc
    while IFS='|' read -r _id _k _m _r _a _cases; do
        if [[ "${_m}" == @owner ]]; then
            while IFS='|' read -r _mod _om _oc; do
                (( _i++ % _parts == _part - 1 )) \
                    && bats_test_function --description "mutant ${_om} (${_id}, ${_mod}) is caught" -- _assert_caught "${_om}"
            done < <(_owner_rows)
            continue
        fi
        (( _i++ % _parts == _part - 1 )) \
            && bats_test_function --description "mutant ${_m} (${_id}) is caught" -- _assert_caught "${_m}"
        if [[ "${_k}" == render ]]; then
            (( _i++ % _parts == _part - 1 )) \
                && bats_test_function --description "purity: renderer mutant ${_m} (${_id}) changes only its own element" -- _assert_pure "${_m}"
        fi
    done < <(_rows)
    return 0
}
