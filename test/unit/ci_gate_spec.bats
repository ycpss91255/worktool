#!/usr/bin/env bats
# test/unit/ci_gate_spec.bats - script/test/test.sh bats-tier gate: required
# specs per tier (M2 review, codex finding: a deleted required spec still
# read as green while another spec in the same tier kept the tier non-empty)
#
# WHAT THIS PROVES
#   Every bats tier of test.sh declares its REQUIRED spec files, and the tier
#   is red - before bats even runs - when any of them is deleted or emptied,
#   even if other specs in the same tier still contribute cases. A normal
#   tree passes, additional (non-required) specs still run on top of the
#   required ones, and a skipped case still fails the tier.
#
# HOW
#   Each case builds an independent COPY of the checkout (script/ lib/ box/
#   test/) under BATS_TEST_TMPDIR, breaks ONE thing in the copy, then runs
#   the copy's own test.sh in its container-side mode (--ci-unit /
#   --ci-integration / ...), exactly as the CI job does. The real tree is
#   never touched. Negative cases die before bats runs, so they need no
#   daemon; the positive cases nest a bats run of a FAST tier of the copy
#   (integration / system shim / acceptance).
#
#   RECURSION GUARD: the copy's test/unit/ci_gate_spec.bats is replaced by a
#   one-case stub of the same name. A nested unit-tier run of the copy
#   (which the unit negative cases DO trigger whenever test.sh regresses and
#   lets a deleted required spec through) therefore terminates instead of
#   running this file inside itself without bound. The real unit tier's
#   positive run is the outer CI job that executes this file.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    TEST_SH="${REPO_ROOT}/script/test/test.sh"
    COPY="${BATS_TEST_TMPDIR}/copy"
    THIS_SPEC="test/unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# Independent checkout copy (script/ lib/ box/ test/) at $COPY. cp -R keeps
# the executable bits, so the copy's test.sh runs exactly like the real one
# and resolves REPO_ROOT to the copy. This spec is stubbed in the copy (see
# RECURSION GUARD above).
_make_repo_copy() {
    mkdir -p "${COPY}"
    cp -R "${REPO_ROOT}/script" "${REPO_ROOT}/lib" "${REPO_ROOT}/box" \
        "${REPO_ROOT}/test" "${COPY}/"
    _write_one_case_spec "${COPY}/${THIS_SPEC}" "ci_gate stub (recursion guard)"
}

# Run the copy's test.sh in container-side mode $1 (e.g. --ci-integration).
_run_copy_gate() {
    run "${COPY}/script/test/test.sh" "$1"
}

# Print the required spec list test.sh declares for tier $1 (test/-relative,
# one per line). Sourced in a throwaway shell: test.sh guards its main().
_declared() {
    bash -c 'source "$1" && _required_specs "$2"' _ "${TEST_SH}" "$1"
}

# Write a one-case spec at $1 whose case is named $2 (a decoy / extra spec).
_write_one_case_spec() {
    {
        printf '#!/usr/bin/env bats\n'
        printf '@test "%s" {\n    true\n}\n' "$2"
    } >"$1"
}

# Write a spec at $1 that is well-formed (loads the helper) but defines no
# case at all - an "emptied" required spec.
_write_header_only_spec() {
    cat >"$1" <<'EOF'
#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"
EOF
}

# --- the declared required lists ---------------------------------------------

@test "test.sh declares the M2 required specs of the unit tier" {
    run _declared unit
    assert_success
    assert_line "unit/log_spec.bats"
    assert_line "unit/manifest_spec.bats"
    assert_line "unit/assemble_spec.bats"
    # The harness specs guard themselves too.
    assert_line "unit/ci_gate_spec.bats"
    assert_line "unit/system_real_entry_spec.bats"
    assert_line "unit/test_sh_spec.bats"
    assert_line "unit/selfcheck_spec.bats"
}

@test "test.sh declares the M2 required specs of the integration tier" {
    run _declared integration
    assert_success
    assert_line "integration/smoke_spec.bats"
    assert_line "integration/assemble_spec.bats"
}

@test "test.sh declares the M2 required specs of both system groups" {
    run _declared system
    assert_success
    assert_line "system/real_assemble_spec.bats"
    refute_line "system/real_engine_spec.bats"

    run _declared system-real
    assert_success
    assert_output "system/real_engine_spec.bats"
}

@test "test.sh declares the M2 required spec of the acceptance tier" {
    run _declared acceptance
    assert_success
    assert_output "acceptance/m2_selfcheck_spec.bats"
}

@test "test.sh declares no required specs for an unknown tier (non-zero)" {
    run _declared no-such-tier
    assert_failure
    assert_output ""
}

@test "every declared required spec exists in the delivered tree and defines cases" {
    local _tier _rel _n
    for _tier in unit integration system system-real acceptance; do
        while IFS= read -r _rel; do
            assert [ -f "${REPO_ROOT}/test/${_rel}" ]
            _n="$(bats --count "${REPO_ROOT}/test/${_rel}")"
            assert [ "${_n}" -gt 0 ]
        done < <(_declared "${_tier}")
    done
}

# --- negative: a deleted required spec fails the tier before bats runs -------

@test "unit: deleting manifest_spec + assemble_spec (log_spec remains) fails the tier" {
    _make_repo_copy
    rm "${COPY}/test/unit/manifest_spec.bats" "${COPY}/test/unit/assemble_spec.bats"

    _run_copy_gate --ci-unit
    assert_failure
    assert_output --partial "[ci] ERROR: unit required spec missing: test/unit/manifest_spec.bats"
    # Died before bats ran: no TAP plan was emitted.
    refute_output --regexp '^1\.\.[0-9]+$'
}

@test "integration: deleting assemble_spec (smoke_spec remains) fails the tier" {
    _make_repo_copy
    rm "${COPY}/test/integration/assemble_spec.bats"

    _run_copy_gate --ci-integration
    assert_failure
    assert_output --partial "[ci] ERROR: integration required spec missing: test/integration/assemble_spec.bats"
    refute_output --regexp '^1\.\.[0-9]+$'
}

@test "system (shim): deleting real_assemble_spec fails the tier even with a decoy spec present" {
    _make_repo_copy
    rm "${COPY}/test/system/real_assemble_spec.bats"
    _write_one_case_spec "${COPY}/test/system/decoy_spec.bats" "decoy"

    _run_copy_gate --ci-system
    assert_failure
    assert_output --partial "[ci] ERROR: system required spec missing: test/system/real_assemble_spec.bats"
    refute_output --regexp '^1\.\.[0-9]+$'
}

@test "system-real: deleting real_engine_spec fails the group" {
    _make_repo_copy
    rm "${COPY}/test/system/real_engine_spec.bats"

    _run_copy_gate --ci-system-real
    assert_failure
    assert_output --partial "[ci] ERROR:"
    assert_output --partial "real_engine_spec.bats"
    assert_output --partial "missing"
    refute_output --regexp '^1\.\.[0-9]+$'
}

@test "acceptance: deleting m2_selfcheck_spec fails the tier even with a decoy spec present" {
    _make_repo_copy
    rm "${COPY}/test/acceptance/m2_selfcheck_spec.bats"
    _write_one_case_spec "${COPY}/test/acceptance/decoy_spec.bats" "decoy"

    _run_copy_gate --ci-acceptance
    assert_failure
    assert_output --partial "[ci] ERROR: acceptance required spec missing: test/acceptance/m2_selfcheck_spec.bats"
    refute_output --regexp '^1\.\.[0-9]+$'
}

# --- negative: an emptied required spec fails the tier before bats runs ------

@test "unit: an emptied assemble_spec (zero bytes) fails the tier" {
    _make_repo_copy
    : >"${COPY}/test/unit/assemble_spec.bats"

    _run_copy_gate --ci-unit
    assert_failure
    assert_output --partial "[ci] ERROR: unit required spec defines zero cases: test/unit/assemble_spec.bats"
    refute_output --regexp '^1\.\.[0-9]+$'
}

@test "integration: a header-only smoke_spec (no @test left) fails the tier" {
    _make_repo_copy
    _write_header_only_spec "${COPY}/test/integration/smoke_spec.bats"

    _run_copy_gate --ci-integration
    assert_failure
    assert_output --partial "[ci] ERROR: integration required spec defines zero cases: test/integration/smoke_spec.bats"
    refute_output --regexp '^1\.\.[0-9]+$'
}

@test "system (shim): a header-only real_assemble_spec (no @test left) fails the tier even with a decoy spec present" {
    _make_repo_copy
    _write_header_only_spec "${COPY}/test/system/real_assemble_spec.bats"
    _write_one_case_spec "${COPY}/test/system/decoy_spec.bats" "decoy"

    _run_copy_gate --ci-system
    assert_failure
    assert_output --partial "[ci] ERROR: system required spec defines zero cases: test/system/real_assemble_spec.bats"
    refute_output --regexp '^1\.\.[0-9]+$'
}

@test "system-real: an emptied real_engine_spec fails the group without needing a daemon" {
    _make_repo_copy
    : >"${COPY}/test/system/real_engine_spec.bats"

    _run_copy_gate --ci-system-real
    assert_failure
    assert_output --partial "[ci] ERROR: system-real required spec defines zero cases: test/system/real_engine_spec.bats"
    refute_output --regexp '^1\.\.[0-9]+$'
}

@test "acceptance: an emptied m2_selfcheck_spec fails the tier" {
    _make_repo_copy
    : >"${COPY}/test/acceptance/m2_selfcheck_spec.bats"

    _run_copy_gate --ci-acceptance
    assert_failure
    assert_output --partial "[ci] ERROR: acceptance required spec defines zero cases: test/acceptance/m2_selfcheck_spec.bats"
    refute_output --regexp '^1\.\.[0-9]+$'
}

# --- positive: a normal tree passes, every case of the tier in the plan -----

@test "integration: a normal tree passes and the plan covers every case" {
    _make_repo_copy
    local _n
    _n="$(bats --count -r "${COPY}/test/integration")"

    _run_copy_gate --ci-integration
    assert_success
    assert_line "1..${_n}"
    assert_line --partial "[ci] integration bats OK"
}

@test "system (shim): a normal tree passes and the plan covers every shim case" {
    _make_repo_copy
    local _n
    _n="$(bats --count "${COPY}/test/system/real_assemble_spec.bats")"

    _run_copy_gate --ci-system
    assert_success
    assert_line "1..${_n}"
    assert_line --partial "[ci] system bats OK"
}

@test "acceptance: a normal tree passes and the plan covers every case" {
    _make_repo_copy
    local _n
    _n="$(bats --count -r "${COPY}/test/acceptance")"

    _run_copy_gate --ci-acceptance
    assert_success
    assert_line "1..${_n}"
    assert_line --partial "[ci] acceptance bats OK"
}

# --- additional specs still run on top of the required ones ------------------

@test "integration: an additional non-required spec still runs and counts in the plan" {
    _make_repo_copy
    local _n
    _n="$(bats --count -r "${COPY}/test/integration")"
    _write_one_case_spec "${COPY}/test/integration/extra_spec.bats" \
        "extra: additional non-required spec still runs"

    _run_copy_gate --ci-integration
    assert_success
    assert_line "1..$(( _n + 1 ))"
    assert_line --regexp '^ok [0-9]+ extra: additional non-required spec still runs$'
    assert_line --partial "[ci] integration bats OK"
}

@test "integration: a skipped case in an additional spec still fails the tier" {
    _make_repo_copy
    {
        printf '#!/usr/bin/env bats\n'
        printf '@test "extra: skipped" {\n    skip "not green"\n}\n'
    } >"${COPY}/test/integration/extra_spec.bats"

    _run_copy_gate --ci-integration
    assert_failure
    assert_output --partial "[ci] ERROR: integration bats has skipped case(s)"
}
