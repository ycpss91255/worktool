#!/usr/bin/env bats
# test/unit/nightly_yml_spec.bats - .github/workflows/nightly.yml wiring
# (issue #836): schedule + manual trigger, the skip decision from
# lib/nightly.sh before the suite, the full serial run on both runners,
# and the report that opens or updates the one nightly-failure issue.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    YML="${REPO_ROOT}/.github/workflows/nightly.yml"
}

# Print the non-comment lines of job $1.
_job() {
    awk -v id="$1" '
        /^jobs:$/ { injobs = 1; next }
        injobs && /^  [a-z-]+:$/ { inblock = ($0 == "  " id ":") }
        inblock && !/^ *#/ { print }
    ' "${YML}"
}

@test "nightly runs at 03:00 Asia/Taipei and on demand, never cancelling a run in progress" {
    run cat "${YML}"
    assert_success
    assert_line "    - cron: '0 19 * * *'  # 03:00 Asia/Taipei"
    assert_line '  workflow_dispatch:'
    assert_line '  cancel-in-progress: false'
    refute_line --partial 'pull_request'
}

@test "decide asks lib/nightly.sh whether to run, after listing the open nightly-failure issues" {
    run _job decide
    assert_success
    assert_line '          source lib/nightly.sh'
    assert_line --partial "gh label create \"\${NIGHTLY_LABEL}\""
    assert_line --partial "gh issue list -R \"\${REPO}\" --label \"\${NIGHTLY_LABEL}\" --state open"
    assert_line --partial "nightly_decide \"\${EVENT}\" \"\${rc}\" \"\${open}\""
    assert_line '      issues: write'
}

@test "the full serial run is bare just test (which holds the 2.3 checks), on both runners, only when decided" {
    run _job full-serial
    assert_success
    assert_line "    if: needs.decide.outputs.run == 'true'"
    assert_line '        runner: [ubuntu-latest, ubuntu-24.04-arm]'
    assert_line '        run: just test'
}

@test "no nightly job runs a tier twice: a bare just test counts as every HOST_STEPS tier (#888)" {
    local _steps _jobs _j _tiers
    _steps="$(bash -c 'source "$1" && printf "%s\n" "${HOST_STEPS[@]}"' _ "${REPO_ROOT}/script/test/test.sh")"
    assert [ -n "${_steps}" ]
    _jobs="$(awk '/^jobs:$/ { on = 1; next } on && /^  [a-z-]+:$/ { sub(/:$/, ""); print $1 }' "${YML}")"
    assert [ -n "${_jobs}" ]
    for _j in ${_jobs}; do
        _tiers="$(_job "${_j}" | sed -nE 's/^ *(run: )?just test( ([a-z-]+))?$/\3/p' \
            | while IFS= read -r _t; do
                if [[ -z "${_t}" ]]; then printf '%s\n' "${_steps}"; else printf '%s\n' "${_t}"; fi
            done)"
        run bash -c 'LC_ALL=C sort <<<"$1" | uniq -d' _ "${_tiers}"
        assert_success
        assert_output ''
    done
}

@test "report opens one issue on a failure with nothing open, otherwise comments on the open one" {
    run _job report
    assert_success
    # A run for a requested sha (#837) leaves the issue alone.
    assert_line "    if: always() && needs.decide.outputs.run == 'true' && inputs.sha == ''"
    assert_line --partial "nightly_report \"\${RESULT}\" \"\${rc}\" \"\${open}\""
    assert_line --partial "gh issue create -R \"\${REPO}\" --label \"\${NIGHTLY_LABEL}\""
    assert_line --partial "gh issue comment \"\${action#comment }\" -R \"\${REPO}\" --body-file \"\${body}\""
    # The report job itself stays red when the suite was red.
    assert_line "          [ \"\${RESULT}\" = success ]"
}

# --- exact-commit full serial run (issue #837) --------------------------------

@test "a manual run takes a sha and runs the full serial suite on exactly that commit, titled by it" {
    run cat "${YML}"
    assert_line "run-name: full-serial \${{ inputs.sha || github.sha }}"
    assert_line '      sha:'
    run _job full-serial
    assert_line "          ref: \${{ inputs.sha || github.sha }}"
    # The isolation job (#835) tests the same commit.
    run _job isolation
    assert_line "          ref: \${{ inputs.sha || github.sha }}"
}

@test "decide refuses a malformed sha before anything runs" {
    run _job decide
    assert_line "          SHA_INPUT: \${{ inputs.sha }}"
    assert_line --partial "nightly_check_sha \"\${SHA_INPUT}\""
}

@test "a run for a requested sha never opens or comments on the nightly-failure issue" {
    run _job report
    assert_line "    if: always() && needs.decide.outputs.run == 'true' && inputs.sha == ''"
}

@test "two requested shas never replace each other in the concurrency queue" {
    run cat "${YML}"
    assert_line "  group: nightly-\${{ inputs.sha || github.sha }}"
}

@test "the full serial run takes Ubuntu packages from the same mirror as ci.yml (#843)" {
    run _job full-serial
    assert_line '    env:'
    assert_line "      WORKTOOL_APT_MIRROR: \${{ matrix.runner == 'ubuntu-latest' && 'http://azure.archive.ubuntu.com/ubuntu/' || '' }}"
}

# --- main push runs the full check (issue #851) -------------------------------

@test "every push to main runs the full check on that sha" {
    run cat "${YML}"
    assert_line '  push:'
    assert_line '    branches: [main]'
}

@test "a scheduled run asks full-run.sh whether main's HEAD already has a green full run, excluding itself" {
    run _job decide
    assert_line --partial "./.agents/script/monitor/full-run.sh --repo \"\${REPO}\" --sha \"\${GITHUB_SHA}\" --exclude-run \"\${GITHUB_RUN_ID}\""
    assert_line --partial "nightly_decide \"\${EVENT}\" \"\${rc}\" \"\${open}\" \"\${head_rc}\""
    assert_line '      actions: read'
}

# --- the complete check runs in full-check mode (issue #870) ------------------

@test "the bare just test of the full serial run sets WORKTOOL_FULL_CHECK=1; no pull_request run (ci.yml) sets it" {
    run _job full-serial
    assert_success
    assert_line '      - name: Bare just test (seven tiers in order, serial)'
    assert_line "          WORKTOOL_FULL_CHECK: '1'"
    run awk '/- name: Bare just test/ { on = 1; next } on && /- name:/ { exit } on' "${YML}"
    assert_line "          WORKTOOL_FULL_CHECK: '1'"
    run grep -c 'WORKTOOL_FULL_CHECK' "${REPO_ROOT}/.github/workflows/ci.yml"
    assert_output 0
}

# --- the box's persisted packages (issue #878, after #847) --------------------

@test "full-serial's bare just test and isolation read the box packages ci.yml's main push saves, and nightly never saves them" {
    local _job
    for _job in full-serial isolation; do
        run _job "${_job}"
        assert_success
        assert_line '      - name: Restore box packages'
        assert_line '        uses: actions/cache/restore@v4'
        assert_line "          path: \${{ runner.temp }}/apt-box/*.deb"
        assert_line "          restore-keys: apt-box-\${{ matrix.runner }}-"
        assert_line "          WORKTOOL_APT_CACHE_DIR: \${{ runner.temp }}/apt-box"
    done
    run awk '/- name: Bare just test/ { on = 1; next } on && /- name:/ { exit } on' "${YML}"
    assert_line "          WORKTOOL_APT_CACHE_DIR: \${{ runner.temp }}/apt-box"
    run grep -c 'actions/cache/save' "${YML}"
    assert_output 0
}

# --- isolation reuses ci.yml's image caches (issue #885) ----------------------

@test "isolation builds the ghostty and system-real images from ci.yml's buildx cache, read-only, and hands them to its stages (#885)" {
    local _img _df
    run _job isolation
    assert_success
    assert_line '        uses: docker/setup-buildx-action@v3'
    for _img in ghostty system-real; do
        _df="dockerfile/Dockerfile.${_img}"
        assert_line "          file: ${_df}"
        assert_line "          tags: worktool-${_img}:local"
        assert_line "          cache-from: type=gha,scope=${_img}-\${{ matrix.runner }}"
        # Same scope and build arg as ci.yml (its main push is the writer).
        run grep -cF "          cache-from: type=gha,scope=${_img}-\${{ matrix.runner }}" "${REPO_ROOT}/.github/workflows/ci.yml"
        assert_output 1
        run _job isolation
    done
    assert_line "          build-args: APT_MIRROR=\${{ env.WORKTOOL_APT_MIRROR }}"
    assert_line '          load: true'
    run awk '/- name: Tier isolation/ { on = 1; next } on && /- name:/ { exit } on' "${YML}"
    assert_line "          GHOSTTY_IMAGE_PREBUILT: '1'"
    assert_line "          SYSTEM_REAL_IMAGE_PREBUILT: '1'"
    assert_line '        run: just test isolation'
    # Nightly never writes the image cache, and full-serial keeps building
    # its images the way a user's bare `just test` does.
    run grep -c 'cache-to' "${YML}"
    assert_output 0
    run _job full-serial
    refute_line --partial 'PREBUILT'
    refute_line --partial 'docker/build-push-action'
}

@test "each required test job proves its actual checkout matches the target SHA" {
    local job
    for job in full-serial isolation; do
        run _job "${job}"
        assert_line "      - name: Verify checkout \${{ inputs.sha || github.sha }}"
        assert_line "          EXPECTED_SHA: \${{ inputs.sha || github.sha }}"
        assert_line "        run: test \"\$(git rev-parse HEAD)\" = \"\${EXPECTED_SHA}\""
    done
}
