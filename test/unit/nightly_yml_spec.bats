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

@test "the full serial run is bare just test plus the 2.3 checks, on both runners, only when decided" {
    run _job full-serial
    assert_success
    assert_line "    if: needs.decide.outputs.run == 'true'"
    assert_line '        runner: [ubuntu-latest, ubuntu-24.04-arm]'
    assert_line '        run: just test'
    assert_line '          just test integration'
    assert_line '          just test system-real'
}

@test "report opens one issue on a failure with nothing open, otherwise comments on the open one" {
    run _job report
    assert_success
    assert_line "    if: always() && needs.decide.outputs.run == 'true'"
    assert_line --partial "nightly_report \"\${RESULT}\" \"\${rc}\" \"\${open}\""
    assert_line --partial "gh issue create -R \"\${REPO}\" --label \"\${NIGHTLY_LABEL}\""
    assert_line --partial "gh issue comment \"\${action#comment }\" -R \"\${REPO}\" --body-file \"\${body}\""
    # The report job itself stays red when the suite was red.
    assert_line "          [ \"\${RESULT}\" = success ]"
}
