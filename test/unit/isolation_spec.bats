#!/usr/bin/env bats
# test/unit/isolation_spec.bats - script/test/isolation.sh (issue #835)
#
# WHAT THIS PROVES
#   The tier isolation guard runs the stages of bare `just test` in a
#   random order that a printed seed reproduces, shuffles the spec files of
#   every tier that takes spec paths, and after EACH stage compares the host
#   with the snapshot taken before it: a container or volume left in the
#   host engine, a file left in the checkout (outside .agents/state), or a
#   new entry in $HOME or in the caller's /tmp is a failure that names the
#   residue and the stage. A stage that fails stops the run with its status.
#
# HOW
#   The script runs from a COPY of the checkout whose script/test/test.sh is
#   a fake: it records the stage and spec order and, on request, leaves a
#   file or asks the fake docker to report a new container. HOME and TMPDIR
#   point into BATS_TEST_TMPDIR. No real tier and no engine run.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    COPY="${BATS_TEST_TMPDIR}/repo"
    BIN="${BATS_TEST_TMPDIR}/bin"
    CALLS="${BATS_TEST_TMPDIR}/calls"
    mkdir -p "${COPY}/script/test" "${COPY}/lib" "${BIN}"
    cp "${REPO_ROOT}/script/test/isolation.sh" "${COPY}/script/test/isolation.sh"
    cp "${REPO_ROOT}/lib/log.sh" "${COPY}/lib/log.sh"
    local _tier _i
    for _tier in unit matrix system acceptance integration; do
        mkdir -p "${COPY}/test/${_tier}"
        for _i in 1 2 3 4; do
            : >"${COPY}/test/${_tier}/${_tier}${_i}_spec.bats"
        done
    done
    mkdir -p "${COPY}/test/unit/hook"
    : >"${COPY}/test/unit/hook/deep_spec.bats"
    : >"${COPY}/test/system/real_engine_spec.bats"
    # Fake runner: HOST_STEPS is what isolation.sh reads; a call records
    # its argv and obeys FAKE_RESIDUE_STEP / FAKE_FAIL_STEP.
    cat >"${COPY}/script/test/test.sh" <<'EOF'
#!/usr/bin/env bash
HOST_STEPS=(lint unit matrix integration system acceptance system-real)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf '%s\n' "$*" >>"${CALLS}"
    step="${1#--}"
    if [[ "${step}" == "${FAKE_RESIDUE_STEP:-}" ]]; then
        case "${FAKE_RESIDUE_KIND:-file}" in
            file)      : >"${REPO_DIR}/left-behind.txt" ;;
            container) : >"${FAKE_DOCKER_NEW}" ;;
            home)      : >"${HOME}/.left-behind" ;;
            tmp)       : >"${TMPDIR}/left-behind" ;;
        esac
    fi
    [[ "${step}" != "${FAKE_FAIL_STEP:-}" ]] || exit 7
    exit 0
fi
EOF
    chmod +x "${COPY}/script/test/test.sh"
    # Fake docker: one idle container and volume; FAKE_DOCKER_NEW present
    # = a second container appeared.
    cat >"${BIN}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${SNAPSHOT_FAULT:-}" == "docker-$1" ]] &&
    { [[ "${SNAPSHOT_PHASE:-before}" == before ]] || [[ -s "${CALLS}" ]]; }; then
    printf 'injected inventory failure: docker %s\n' "$1" >&2
    exit 9
fi
case "$1" in
    ps)
        printf 'aaa111\n'
        [[ ! -e "${FAKE_DOCKER_NEW}" ]] || printf 'bbb222\n' ;;
    volume) printf 'vol1\n' ;;
esac
EOF
    chmod +x "${BIN}/docker"
    git -C "${COPY}" init -q
    git -C "${COPY}" add -A
    git -C "${COPY}" -c user.email=t@example.invalid -c user.name=t commit -qm init
    mkdir -p "${BATS_TEST_TMPDIR}/home" "${BATS_TEST_TMPDIR}/tmp"
    export CALLS REPO_DIR="${COPY}" FAKE_DOCKER_NEW="${BATS_TEST_TMPDIR}/docker-new"
}

_iso() {
    HOME="${BATS_TEST_TMPDIR}/home" TMPDIR="${BATS_TEST_TMPDIR}/tmp" PATH="${BIN}:${PATH}" \
        run "${COPY}/script/test/isolation.sh" "$@"
}

@test "a clean run passes, runs every stage exactly once and prints the seed it used" {
    _iso --seed 42
    assert_success
    assert_output --partial 'seed=42'
    run cut -d' ' -f1 "${CALLS}"
    assert_equal "$(printf '%s\n' "${output}" | sort | tr '\n' ' ')" \
        "--acceptance --integration --lint --matrix --system --system-real --unit "
}

@test "the same seed gives the same stage and spec order; another seed a different one" {
    _iso --seed 42
    assert_success
    cp "${CALLS}" "${BATS_TEST_TMPDIR}/first"
    : >"${CALLS}"
    _iso --seed 42
    assert_success
    run cmp "${BATS_TEST_TMPDIR}/first" "${CALLS}"
    assert_success
    : >"${CALLS}"
    _iso --seed 7
    assert_success
    run cmp -s "${BATS_TEST_TMPDIR}/first" "${CALLS}"
    assert_failure
}

@test "without --seed a seed is chosen and printed so the run can be reproduced" {
    _iso
    assert_success
    assert_output --regexp 'seed=[0-9]+'
    assert_output --partial 'reproduce: just test isolation --seed'
}

@test "tiers that take spec paths get every spec file, shuffled, and never the real-engine spec" {
    _iso --seed 42
    assert_success
    run grep '^--unit ' "${CALLS}"
    assert_success
    local _unit="${output}"
    local _f
    for _f in test/unit/unit1_spec.bats test/unit/unit2_spec.bats test/unit/unit3_spec.bats \
        test/unit/unit4_spec.bats test/unit/hook/deep_spec.bats; do
        assert [ "$(grep -o "${_f}" <<<"${_unit}" | wc -l)" -eq 1 ]
    done
    run grep '^--system ' "${CALLS}"
    refute_output --partial real_engine_spec
    # lint, integration and system-real run whole.
    run grep -x -- '--lint' "${CALLS}"
    assert_success
    run grep -x -- '--integration' "${CALLS}"
    assert_success
    run grep -x -- '--system-real' "${CALLS}"
    assert_success
}

@test "a file a stage leaves in the checkout fails the run and names the file and the stage" {
    FAKE_RESIDUE_STEP=matrix FAKE_RESIDUE_KIND=file _iso --seed 42
    assert_failure 1
    assert_output --partial 'left-behind.txt'
    assert_output --partial 'after matrix'
}

@test "a container a stage leaves in the host engine fails the run" {
    FAKE_RESIDUE_STEP=unit FAKE_RESIDUE_KIND=container _iso --seed 42
    assert_failure 1
    assert_output --partial 'bbb222'
    assert_output --partial 'after unit'
}

@test "a new entry in HOME or in TMPDIR fails the run" {
    FAKE_RESIDUE_STEP=system FAKE_RESIDUE_KIND=home _iso --seed 42
    assert_failure 1
    assert_output --partial '.left-behind'
    rm -f "${BATS_TEST_TMPDIR}/home/.left-behind"
    FAKE_RESIDUE_STEP=lint FAKE_RESIDUE_KIND=tmp _iso --seed 42
    assert_failure 1
    assert_output --partial 'left-behind'
}

@test "files under .agents/state (test reports) are not residue" {
    mkdir -p "${COPY}/.agents/state/test-report"
    FAKE_RESIDUE_STEP='' _iso --seed 42
    assert_success
}

@test "a failing stage stops the run with a failure and runs nothing after it" {
    FAKE_FAIL_STEP=unit _iso --seed 42
    assert_failure 1
    assert_output --partial 'unit failed (rc=7)'
    run tail -n 1 "${CALLS}"
    assert_output --regexp '^--unit '
}

@test "--seed takes a non-negative integer; anything else and unknown options exit 2" {
    _iso --seed abc
    assert_failure 2
    _iso --bogus
    assert_failure 2
    assert_output "isolation.sh: unknown option '--bogus' (see --help)"
    _iso --help
    assert_success
}

@test "isolation.sh runs under set -euo pipefail" {
    run grep -c '^set -euo pipefail$' "${REPO_ROOT}/script/test/isolation.sh"
    assert_output 1
}

@test "just test isolation forwards to the script, and the nightly full serial run calls it" {
    run grep -A1 -E '^isolation \*args:$' "${REPO_ROOT}/script/test/justfile.test"
    assert_success
    assert_line '    ./script/test/isolation.sh "$@"'
    run grep -F 'run: just test isolation' "${REPO_ROOT}/.github/workflows/nightly.yml"
    assert_success
}

@test "nightly runs isolation as its own job beside full-serial, and the report fails unless both succeed" {
    local _yml="${REPO_ROOT}/.github/workflows/nightly.yml"
    run awk '/^  isolation:$/,/^  report:$/' "${_yml}"
    assert_line '    needs: decide'
    assert_line "    if: needs.decide.outputs.run == 'true'"
    assert_line '        runner: [ubuntu-latest, ubuntu-24.04-arm]'
    assert_line '        run: just test isolation'
    assert_line "      WORKTOOL_APT_MIRROR: \${{ matrix.runner == 'ubuntu-latest' && 'http://azure.archive.ubuntu.com/ubuntu/' || '' }}"
    run awk '/^  full-serial:$/,/^  isolation:$/' "${_yml}"
    refute_line '        run: just test isolation'
    run awk '/^  report:$/,0' "${_yml}"
    assert_line '    needs: [decide, full-serial, isolation]'
    assert_line "          RESULT: \${{ (needs.full-serial.result == 'success' && needs.isolation.result == 'success') && 'success' || 'failure' }}"
}

_assert_snapshot_failure() {
    local _inventory="$1" _phase
    for _phase in before after; do
        rm -f "${CALLS}"
        SNAPSHOT_FAULT="${_inventory}" SNAPSHOT_PHASE="${_phase}" _iso --seed 42
        assert_failure 1
        assert_output --partial 'injected inventory failure'
        assert_output --partial "cannot take the snapshot ${_phase}"
        refute_output --partial 'isolation: clean'
        if [[ "${_phase}" == before ]]; then
            assert [ ! -e "${CALLS}" ]
        else
            assert_equal "$(wc -l <"${CALLS}" | tr -d ' ')" 1
        fi
    done
}

@test "container inventory failure stops before the first or after the current stage" {
    _assert_snapshot_failure docker-ps
}

@test "volume inventory failure stops before the first or after the current stage" {
    _assert_snapshot_failure docker-volume
}

_fault_inventory_command() {
    local _command="$1"
    export REAL_INVENTORY_COMMAND
    REAL_INVENTORY_COMMAND="$(command -v "${_command}")"
    cat >"${BIN}/${_command}" <<'EOF'
#!/usr/bin/env bash
inventory=git
if [[ "${0##*/}" == find ]]; then
    case "$1" in
        "${HOME}") inventory=home ;;
        "${TMPDIR}") inventory=tmp ;;
        *) inventory=specs ;;
    esac
fi
if [[ "${SNAPSHOT_FAULT:-}" == "${inventory}" ]] &&
    { [[ "${SNAPSHOT_PHASE:-before}" == before ]] || [[ -s "${CALLS}" ]]; }; then
    printf 'injected inventory failure: %s\n' "${inventory}" >&2
    exit 9
fi
exec "${REAL_INVENTORY_COMMAND}" "$@"
EOF
    chmod +x "${BIN}/${_command}"
}

@test "checkout inventory failure stops before the first or after the current stage" {
    _fault_inventory_command git
    _assert_snapshot_failure git
}

@test "HOME inventory failure stops before the first or after the current stage" {
    _fault_inventory_command find
    _assert_snapshot_failure home
}

@test "TMPDIR inventory failure stops before the first or after the current stage" {
    _fault_inventory_command find
    _assert_snapshot_failure tmp
}
