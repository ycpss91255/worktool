#!/usr/bin/env bats
# test/unit/ci_yml_spec.bats - .github/workflows/ci.yml runs every gate on
# BOTH architectures (M3, issue #149: amd64 + arm64 runner matrix)
#
# WHAT THIS PROVES
#   The workflow has a runner dimension on every leg-carrying job:
#
#   - build-image, gate (lint / test-unit / test-integration / test-system /
#     test-acceptance) and test-system-real each `runs-on` the matrix runner
#     and their `runner:` dimension names both ubuntu-latest (amd64) and
#     ubuntu-24.04-arm (arm64) - no job hardcodes one architecture;
#   - the prebuilt test-image artifact is per-arch: the upload name in
#     build-image and the download name in gate are the SAME string and
#     carry the runner, so the two build legs cannot collide and every gate
#     loads its own arch's image;
#   - job names carry the runner so a check reads "lint (ubuntu-24.04-arm)";
#   - ci-passed `needs` every other job (so every matrix leg of each) and
#     verifies each one's result is `success`, under `if: always()`;
#   - `--privileged` is mentioned by the test-system-real job only.
#
#   This spec is a REQUIRED unit spec of test.sh, so it cannot be deleted
#   silently.
#
# HOW
#   Textual assertions on the checked-in ci.yml (the test image has no YAML
#   parser): a job block is the lines from `  <id>:` under `jobs:` up to
#   the next two-space-indented key, with comment lines dropped so a runner
#   name in a comment never satisfies an assertion. Flow lists
#   (`key: [a, b]`) are matched item by item. Nothing runs and nothing is
#   copied.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    CI_YML="${REPO_ROOT}/.github/workflows/ci.yml"
    RUNNERS=(ubuntu-latest ubuntu-24.04-arm)
    LEG_JOBS=(build-image gate test-system-real)
    GATES=(lint test-unit test-integration test-system test-acceptance)
    # The literal GitHub expression as it appears in ci.yml.
    ARTIFACT="worktool-test-image-\${{ matrix.runner }}"
}

# Print the non-comment lines of job $1 (from `  <id>:` under `jobs:` up to
# the next job key).
_job_block() {
    awk -v id="$1" '
        /^jobs:$/ { injobs = 1; next }
        injobs && /^  [a-z-]+:$/ { inblock = ($0 == "  " id ":") }
        inblock && !/^ *#/ { print }
    ' "${CI_YML}"
}

# Print every job id declared under `jobs:`, one per line.
_job_ids() {
    awk '
        /^jobs:$/ { injobs = 1; next }
        injobs && /^  [a-z-]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }
    ' "${CI_YML}"
}

# Print every job id except the aggregator: the jobs that carry legs.
_needed_ids() {
    _job_ids | grep -v '^ci-passed$'
}

# Regex for a flow list line `<indent><key>: [...]` that contains item $3
# as a whole element. $1 = indent, $2 = key.
_flow_has() {
    printf '^%s%s: \\[(.*, )?%s(,|\\])' "$1" "$2" "$3"
}

# --- required spec -----------------------------------------------------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- every leg-carrying job runs on both runners -----------------------------

@test "ci.yml declares exactly the expected jobs" {
    run _job_ids
    assert_success
    assert_line "build-image"
    assert_line "gate"
    assert_line "test-system-real"
    assert_line "ci-passed"
    assert_equal "${#lines[@]}" 4
}

@test "build-image, gate and test-system-real run on the matrix runner" {
    local _job
    for _job in "${LEG_JOBS[@]}"; do
        run _job_block "${_job}"
        assert_success
        assert_line --regexp '^    runs-on: \$\{\{ matrix\.runner \}\}$'
        refute_line --regexp '^    runs-on: ubuntu-'
    done
}

@test "build-image, gate and test-system-real name both runners in their runner dimension" {
    local _job _runner
    for _job in "${LEG_JOBS[@]}"; do
        run _job_block "${_job}"
        assert_success
        assert_line --regexp '^        runner: \['
        for _runner in "${RUNNERS[@]}"; do
            assert_line --regexp "$(_flow_has '        ' runner "${_runner}")"
        done
    done
}

@test "gate runs every one of the five gates on the runner dimension" {
    local _gate
    run _job_block gate
    assert_success
    assert_line --regexp '^        gate: \['
    for _gate in "${GATES[@]}"; do
        assert_line --regexp "$(_flow_has '        ' gate "${_gate}")"
    done
    assert_line --regexp '^    name: .*\$\{\{ matrix\.gate \}\}.*\$\{\{ matrix\.runner \}\}'
}

@test "job names carry the runner so a check reads '<gate> (<runner>)'" {
    local _job
    for _job in "${LEG_JOBS[@]}"; do
        run _job_block "${_job}"
        assert_success
        assert_line --regexp '^    name: .*\(\$\{\{ matrix\.runner \}\}\)$'
    done
}

# --- the prebuilt test image artifact is per-arch ----------------------------

@test "build-image uploads the test image under an arch-specific artifact name" {
    run _job_block build-image
    assert_success
    assert_line --partial 'uses: actions/upload-artifact@'
    assert_line "          name: ${ARTIFACT}"
}

@test "gate downloads the same arch-specific artifact it runs on" {
    run _job_block gate
    assert_success
    assert_line --partial 'uses: actions/download-artifact@'
    assert_line "          name: ${ARTIFACT}"
}

@test "every test-image artifact name carries the runner (no cross-arch collision)" {
    local _line
    run grep -E '^ +name: worktool-test-image' "${CI_YML}"
    assert_success
    assert_equal "${#lines[@]}" 2
    for _line in "${lines[@]}"; do
        assert_equal "${_line}" "          name: ${ARTIFACT}"
    done
}

# --- ci-passed depends on every leg ------------------------------------------

@test "ci-passed needs every other job and runs even when one failed" {
    local _job
    run _job_block ci-passed
    assert_success
    assert_line '    if: always()'
    while IFS= read -r _job; do
        assert_line --regexp "$(_flow_has '    ' needs "${_job}")"
    done < <(_needed_ids)
}

@test "ci-passed verifies every needed job's result is success" {
    local _job _n
    _n="$(_needed_ids | wc -l)"
    run _job_block ci-passed
    assert_success
    while IFS= read -r _job; do
        assert_line --regexp "needs\.${_job}\.result"
    done < <(_needed_ids)
    # One `= "success" || exit 1` check per needed job: nothing else is
    # accepted as green.
    run grep -cE '^ +\[ "\$\{[A-Z_]+\}" = "success" \] \|\| exit 1$' "${CI_YML}"
    assert_output "${_n}"
}

# --- --privileged stays with test-system-real --------------------------------

@test "--privileged is named by the test-system-real job only" {
    local _job
    for _job in build-image gate ci-passed; do
        run _job_block "${_job}"
        refute_output --partial '--privileged'
    done
    run _job_block test-system-real
    assert_output --partial '--privileged'
}
