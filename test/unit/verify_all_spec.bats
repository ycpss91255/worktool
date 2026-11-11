#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    COPY="${BATS_TEST_TMPDIR}/copy"
    mkdir -p "${COPY}/script/verify"
    cp "${REPO_ROOT}/script/verify/all.sh" "${COPY}/script/verify/all.sh"
    ALL_SH="${COPY}/script/verify/all.sh"
    export STUB_CALLS="${BATS_TEST_TMPDIR}/stub.calls"
    : >"${STUB_CALLS}"
    local _g
    for _g in ui gate setup diagram realbox evidence; do
        _stub_group "${_g}" 0
    done
}

# _stub_group <group> <rc>: the copy's <group>.sh records `<group>.sh <argc>`
# to $STUB_CALLS, prints a plausible expected-output line on stdout and a
# progress line on stderr, and exits <rc>.
_stub_group() {
    local _g="$1" _rc="$2"
    cat >"${COPY}/script/verify/${_g}.sh" <<EOF
#!/usr/bin/env bash
printf '%s.sh %s\n' "${_g}" "\$#" >>"\${STUB_CALLS}"
printf '[INFO] item of ${_g} PASSED\n' >&2
printf '${_g}-output-ok\n'
exit ${_rc}
EOF
    chmod +x "${COPY}/script/verify/${_g}.sh"
}

_stub_calls() {
    cat "${STUB_CALLS}"
}

# --- Control -----------------------------------------------------------------

@test "control: every group passes -> exit 0, groups run in order with no argument, realbox never" {
    run "${ALL_SH}"
    assert_success
    assert_equal "$(_stub_calls)" "$(printf '%s\n' 'ui.sh 0' 'gate.sh 0' 'setup.sh 0' \
        'diagram.sh 0' 'evidence.sh 0')"
    assert_line 'ui-output-ok'
    assert_line 'evidence-output-ok'
}

@test "control: one summary line per group and a PASS verdict naming realbox as not run" {
    run "${ALL_SH}"
    assert_success
    assert_line 'verify all: ui PASS'
    assert_line 'verify all: gate PASS'
    assert_line 'verify all: setup PASS'
    assert_line 'verify all: diagram PASS'
    assert_line 'verify all: evidence PASS'
    assert_line 'verify all: VERDICT PASS (5/5 groups: ui gate setup diagram evidence; realbox not run - it needs --allow-real-box on a real host)'
    refute_output --partial 'FAIL'
}

# --- Failures: plausible output, non-zero exit ------------------------------

@test "errexit: a failed group probe preserves stdout and maps its status to FAIL" {
    _stub_group ui 7
    run bash -c '"$1" 2>/dev/null' _ "${ALL_SH}"
    assert_failure 1
    assert_output $'ui-output-ok\nverify all: ui FAIL (rc=7)\nverify all: VERDICT FAIL at ui (rc=7); passed: none; not run: gate setup diagram evidence'
    assert_equal "$(_stub_calls)" 'ui.sh 0'
}

@test "gate exits 1 after printing plausible output -> exit 1, stops there, FAIL verdict" {
    _stub_group gate 1
    run "${ALL_SH}"
    assert_failure 1
    assert_equal "$(_stub_calls)" "$(printf '%s\n' 'ui.sh 0' 'gate.sh 0')"
    assert_line 'gate-output-ok'
    assert_line 'verify all: ui PASS'
    assert_line 'verify all: gate FAIL (rc=1)'
    refute_line --partial 'verify all: setup'
    assert_line 'verify all: VERDICT FAIL at gate (rc=1); passed: ui; not run: setup diagram evidence'
}

@test "the first group failing stops everything after it" {
    _stub_group ui 1
    run "${ALL_SH}"
    assert_failure 1
    assert_equal "$(_stub_calls)" "ui.sh 0"
    assert_line 'verify all: VERDICT FAIL at ui (rc=1); passed: none; not run: gate setup diagram evidence'
}

@test "the last group failing still fails the run" {
    _stub_group evidence 1
    run "${ALL_SH}"
    assert_failure 1
    assert_line 'verify all: evidence FAIL (rc=1)'
    assert_line 'verify all: VERDICT FAIL at evidence (rc=1); passed: ui gate setup diagram; not run: none'
    refute_line --partial 'VERDICT PASS'
}

@test "a group that cannot run here (rc 3, UNAVAILABLE) exits 3, never 0" {
    _stub_group setup 3
    run "${ALL_SH}"
    assert_failure 3
    assert_line 'verify all: setup UNAVAILABLE (rc=3)'
    assert_line 'verify all: VERDICT FAIL at setup (rc=3); passed: ui gate; not run: diagram evidence'
}

@test "an inconclusive gate stops the aggregate as unavailable" {
    _stub_group gate 3
    run "${ALL_SH}"
    assert_failure 3
    assert_line 'verify all: gate UNAVAILABLE (rc=3)'
    assert_line 'verify all: VERDICT FAIL at gate (rc=3); passed: ui; not run: setup diagram evidence'
    refute_line --partial 'gate PASS'
}

@test "any other non-zero group status (2, 124) is a failure with exit 1" {
    local _rc
    for _rc in 2 124; do
        : >"${STUB_CALLS}"
        _stub_group diagram "${_rc}"
        run "${ALL_SH}"
        assert_failure 1
        assert_line "verify all: diagram FAIL (rc=${_rc})"
    done
}

@test "a group script missing from the checkout is a failure, not a skip" {
    rm "${COPY}/script/verify/gate.sh"
    run "${ALL_SH}"
    assert_failure 1
    assert_equal "$(_stub_calls)" "ui.sh 0"
    assert_output --partial 'gate.sh'
    assert_line --partial 'verify all: VERDICT FAIL at gate'
}

@test "a group script that is not executable is a failure, not a skip" {
    chmod -x "${COPY}/script/verify/setup.sh"
    run "${ALL_SH}"
    assert_failure 1
    assert_line --partial 'verify all: VERDICT FAIL at setup'
    refute_line --partial 'VERDICT PASS'
}

@test "a failing realbox is irrelevant: it is never run" {
    _stub_group realbox 1
    run "${ALL_SH}"
    assert_success
    refute_output --partial 'realbox.sh'
    run grep -c realbox "${STUB_CALLS}"
    assert_output 0
}

# --- CLI contract ------------------------------------------------------------

@test "CLI: help and list validate a trailing unknown option before serving output" {
    local _option
    for _option in --help --list; do
        run "${ALL_SH}" "${_option}" --bogus
        assert_failure 2
        assert_output "all.sh: unknown option '--bogus' (see --help)"
        assert_equal "$(_stub_calls)" ''
    done
}

@test "--help exits 0, names the five groups and the realbox exclusion, runs nothing" {
    run "${ALL_SH}" --help
    assert_success
    assert_output --partial 'Usage: all.sh'
    assert_output --partial 'ui gate setup diagram evidence'
    assert_output --partial 'realbox'
    assert_equal "$(_stub_calls)" ""
}

@test "--list prints the five groups in order, runs nothing" {
    run "${ALL_SH}" --list
    assert_success
    assert_equal "${output}" "$(printf '%s\n' ui gate setup diagram evidence)"
    assert_equal "$(_stub_calls)" ""
}

@test "an unknown option exits 2 naming it, runs nothing" {
    run "${ALL_SH}" --bogus
    assert_failure 2
    assert_line "all.sh: unknown option '--bogus' (see --help)"
    assert_equal "$(_stub_calls)" ""
}

@test "a positional argument exits 2, runs nothing (all takes no ITEM)" {
    run "${ALL_SH}" 1.1
    assert_failure 2
    assert_line "all.sh: unexpected argument '1.1' (see --help)"
    assert_equal "$(_stub_calls)" ""
}
@test "real diagram and evidence missing tools aggregate as UNAVAILABLE with exit 3" {
    local _group _tool _bash _stripped="${BATS_TEST_TMPDIR}/minimal-path"
    _bash="$(command -v bash)"
    mkdir -p "${_stripped}" "${COPY}/lib"
    for _tool in bash dirname; do
        ln -s "$(command -v "${_tool}")" "${_stripped}/${_tool}"
    done
    mkdir -p "${COPY}/box"
    cp "${REPO_ROOT}/box/dev.ini" "${COPY}/box/dev.ini"
    for _tool in guard log manifest; do
        cp "${REPO_ROOT}/lib/${_tool}.sh" "${COPY}/lib/"
    done
    for _group in diagram evidence; do
        cp "${REPO_ROOT}/script/verify/${_group}.sh" "${COPY}/script/verify/"
        PATH="${_stripped}" run "${_bash}" "${ALL_SH}"
        assert_failure 3
        assert_line "verify all: ${_group} UNAVAILABLE (rc=3)"
        refute_line "verify all: ${_group} FAIL (rc=1)"
        refute_output --partial 'VERDICT PASS'
        _stub_group "${_group}" 0
    done
}
