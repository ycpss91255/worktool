#!/usr/bin/env bats
# test/unit/verify_all_spec.bats - script/verify/all.sh cannot false-pass (M3, #182)
#
# WHAT THIS PROVES
#   script/verify/all.sh is the one line the maintainer runs to verify every
#   non-real-machine acceptance group of doc/acceptance.md: ui, gate, setup,
#   diagram, evidence, in that order (realbox is excluded - it needs
#   --allow-real-box on a real host). It must:
#
#     - run the five groups in order, with no argument each;
#     - never run realbox;
#     - stop at the first group that fails, even when that group printed
#       plausible output, and exit non-zero (1 for a failure, 3 when the
#       group could not run here - never 0);
#     - print one summary line per group it ran and a final verdict;
#     - treat a group script that is missing from the checkout as a failure,
#       never as a skip.
#
# HOW
#   The degraded-copy method of this branch's verify specs: the REAL all.sh
#   is copied into a throwaway script/verify/ under BATS_TEST_TMPDIR next to
#   six STUB group scripts. Each stub records its name and argument count,
#   prints a plausible expected-output line, and exits the status the case
#   gives it. So every case differs from the control in exactly one way,
#   and no real group (Docker, gh, distrobox) ever runs.

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "acceptance: PR 157 scope includes verification, product support and tests" {
    local _scope _path
    _scope="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    run printf '%s\n' "${_scope}"
    for _path in 'doc/acceptance.md' 'doc/evidence/' 'ADR 0008' '0010' \
        'script/verify/' 'justfile' 'lib/config_backup.sh' 'lib/guard.sh' \
        'script/test/test.sh' 'test/unit/verify_*_spec.bats' \
        'test/unit/justfile_spec.bats' 'test/unit/fixture/' 'test/helper/' \
        'test/system/real_engine_spec.bats'; do
        assert_output --partial "${_path}"
    done
    refute_output --partial '不動產品程式'
    refute_output --partial '要驗的產品程式全在 main'
}

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
