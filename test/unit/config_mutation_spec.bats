#!/usr/bin/env bats
# test/unit/config_mutation_spec.bats - the byte-preservation specs can SEE
# what they claim (issue #199 round 5).
#
# A spec that passes on a broken implementation proves nothing (round 3's
# EOF cases compared through `run cat`, which cannot see a final newline;
# round 4's setup matrix always appended, so it could not see one either).
# Each case here copies the repo, appends a MUTANT to the copy's
# lib/config.sh (a redefinition of its renderer that breaks exactly one
# promise), runs the named spec cases against the copy with a nested bats,
# and requires them to FAIL. A control run of the same cases on the
# unmutated copy must pass, so a failure is the mutant's doing.
#
# Mutants:
#   newline  re-renders through $(...) and prints one newline: the round-3
#            bug (a missing final newline gains one, trailing blank lines
#            are lost)
#   unknown  drops every line whose key worktool does not know (the
#            round-2 whitelist regeneration that lost link= and would lose
#            any later key)
#
# The setup APPEND matrix is blind to `newline` by construction (an
# appended key always ends the file with one newline); the setup
# REPLACE-ONLY matrix is the case that sees it.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    COPY="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${COPY}"
    cp -R "${REPO_ROOT}/lib" "${REPO_ROOT}/script" "${REPO_ROOT}/test" \
        "${REPO_ROOT}/box" "${COPY}/"
}

# Append mutant $1 to the copy's lib/config.sh (later definitions win).
_mutate() {
    local _cfg="${COPY}/lib/config.sh"
    cat >>"${_cfg}" <<'EOF'

# --- MUTANT (test/unit/config_mutation_spec.bats) ---
eval "$(declare -f _config_render | sed '1s/^_config_render /_config_render_real /')"
EOF
    case "$1" in
        newline)
            cat >>"${_cfg}" <<'EOF'
_config_render() {
    local _c
    _c="$(_config_render_real "$@")" || return 1
    printf '%s\n' "${_c}"
}
EOF
            ;;
        unknown)
            cat >>"${_cfg}" <<'EOF'
_config_render() {
    _config_render_real "$@" \
        | grep -E '^(#|[[:space:]]*$|(auto-enter|terminal|tmux|box|home|link)(\.source)?(=|$))'
}
EOF
            ;;
    esac
}

# Run the cases of spec $1 (relative to test/) whose names match regex $2
# against the copy: bats' TAP output in CASE_OUT, its status in CASE_RC.
_run_cases() {
    CASE_RC=0
    CASE_OUT="$(bats --filter "$2" "${COPY}/test/$1" 2>&1)" || CASE_RC=$?
}

# The cases each mutant must break: `<spec>|<name regex>|<mutants>`.
_cases() {
    printf '%s\n' \
        'unit/config_spec.bats|replace-only keeps every EOF framing|newline unknown' \
        'unit/config_spec.bats|replaces its keys in place|unknown' \
        'unit/setup_spec.bats|r5: .*replace-only|newline unknown' \
        'unit/setup_spec.bats|r4: every setup run|unknown' \
        'integration/assemble_spec.bats|r4: a recorded home|newline unknown'
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "control: every case passes on the unmutated copy" {
    local _spec _re _m
    while IFS='|' read -r _spec _re _m; do
        _run_cases "${_spec}" "${_re}"
        [[ "${CASE_RC}" -eq 0 ]] || fail "control ${_spec} /${_re}/ failed: ${CASE_OUT}"
        [[ "${CASE_OUT}" == *"ok 1 "* ]] || fail "control ${_spec} /${_re}/ ran no case: ${CASE_OUT}"
    done < <(_cases)
}

# Every case listed for mutant $1 must fail on it.
_assert_mutant_caught() {
    local _spec _re _ms
    _mutate "$1"
    while IFS='|' read -r _spec _re _ms; do
        [[ " ${_ms} " == *" $1 "* ]] || continue
        _run_cases "${_spec}" "${_re}"
        [[ "${CASE_RC}" -ne 0 && "${CASE_OUT}" == *"not ok"* ]] \
            || fail "mutant $1 survived ${_spec} /${_re}/: ${CASE_OUT}"
    done < <(_cases)
}

@test "mutant 'newline' (re-render through \$(...)) is caught by every byte-exact case" {
    _assert_mutant_caught newline
}

@test "mutant 'unknown' (drop keys worktool does not know) is caught by every foreign-line case" {
    _assert_mutant_caught unknown
}

# --- purity: a mutant breaks exactly one property (round 6) -----------------
# A mutant that also changes bytes it does not claim to change "kills" cases
# for the wrong reason (a false kill). Each mutant runs config_set on a
# fixture that holds everything EXCEPT the element its property is about;
# the result must be byte-identical to the unmutated library's.

# The neutral fixture of mutant $1 (printf %b): comments, blank and
# whitespace-only lines, a CRLF line, duplicated known foreign lines and a
# last line without a newline - minus the element the mutant targets.
_neutral() {
    case "$1" in
        newline) printf '%s' '# c\n\n  \nlink=.a\nlink=.a\nbox=dev\r\nfuture=x\nhome=/old\nlink=.z\n' ;;
        unknown) printf '%s' '# c\n\n  \nlink=.a\nlink=.a\nbox=dev\r\nhome=/old\nlink=.z' ;;
    esac
}

# config_set home /new on the neutral fixture of $2, with the library of
# copy $1; prints the path of the resulting file.
_render_in() {
    local _home
    _home="${BATS_TEST_TMPDIR}/pure.${1##*/}.$2"
    mkdir -p "${_home}/.config/worktool"
    printf '%b' "$(_neutral "$2")" >"${_home}/.config/worktool/config"
    HOME="${_home}" XDG_CONFIG_HOME="" bash -c \
        'source "$1/lib/log.sh"; source "$1/lib/config.sh"; config_set home /new' _ "$1" \
        || return 1
    printf '%s\n' "${_home}/.config/worktool/config"
}

@test "every mutant is pure: on a fixture without its element it renders like the real library" {
    local _m _real _mut
    local _clean="${BATS_TEST_TMPDIR}/clean"
    cp -R "${COPY}" "${_clean}"
    for _m in newline unknown; do
        rm -rf "${COPY}"
        cp -R "${_clean}" "${COPY}"
        _mutate "${_m}"
        _real="$(_render_in "${_clean}" "${_m}")"
        _mut="$(_render_in "${COPY}" "${_m}")"
        cmp -s -- "${_real}" "${_mut}" \
            || fail "mutant ${_m} is not pure: it changes bytes outside its property"
    done
}
