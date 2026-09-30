#!/usr/bin/env bats
# test/unit/milestone_gate_yml_spec.bats - .github/workflows/milestone-gate.yml
# wiring (issue #187)
#
# WHAT THIS PROVES
#   The workflow that turns lib/approval.sh into the `milestone-gate-approval`
#   commit status is wired as issue #187 specifies:
#
#   - it triggers on pull_request_target (opened, synchronize, reopened,
#     labeled, unlabeled) and on issue_comment (created, edited, deleted),
#     never on pull_request, and the job runs for an issue_comment only when
#     the issue is a PR;
#   - it runs only trusted code: both triggers execute the workflow file of
#     the default branch, and the checkout is pinned to the default branch
#     without persisted credentials, so a PR's own lib/approval.sh (or any
#     other file it changes) never runs while the token holds statuses:
#     write; PR data (head SHA, labels, comments) is read through gh api;
#   - permissions are exactly statuses: write, pull-requests: read,
#     issues: read, plus contents: read (checkout of this private repo);
#   - it sources lib/approval.sh and calls approval_evaluate (the rule is
#     not re-implemented in YAML);
#   - it posts a commit status with context `milestone-gate-approval` on
#     the PR head SHA, success or failure;
#   - ci.yml is untouched by it: ci.yml does not mention the context;
#   - no job id or job `name:` equals the status context (issue #258): a job
#     named `milestone-gate-approval` creates a check run of that name, and
#     when concurrency cancels an older run the cancelled check run is taken
#     as the required check's result and blocks an approved PR. The required
#     check must map only to the commit status this workflow sets. (ci.yml's
#     `ci-passed` is the opposite on purpose: there the job itself IS the
#     required check, so its job name equals the check name.)
#
# HOW
#   Textual assertions on the checked-in YAML (the test image has no YAML
#   parser), comment lines dropped. It guards against accidental breakage;
#   the behaviour proof is the status on a real PR.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    GATE_YML="${REPO_ROOT}/.github/workflows/milestone-gate.yml"
    CI_YML="${REPO_ROOT}/.github/workflows/ci.yml"
}

# Print the non-comment lines of the workflow.
_body() {
    grep -vE '^ *#' "${GATE_YML}"
}

# Print the items of the `types: [...]` flow list directly under trigger
# $1 (the first `types:` line after `  $1:`), one per line, sorted.
_types() {
    _body | awk -v ev="  $1:" '
        $0 == ev { on = 1; next }
        on && /^    types: \[/ { print; exit }
        on && /^  [a-z_]+:/ { exit }
    ' \
        | sed -E 's/^ +types: \[(.*)\]$/\1/' \
        | tr ',' '\n' \
        | sed -E 's/^ +//; s/ +$//' \
        | sort
}

# Print every job id and every job-level `name:` value under `jobs:`,
# one per line.
_job_ids_and_names() {
    _body | awk '
        /^jobs:$/ { on = 1; next }
        on && /^[^ ]/ { exit }
        on && /^  [A-Za-z0-9_-]+:$/ { id = $0; sub(/^  /, "", id); sub(/:$/, "", id); print id; next }
        on && /^    name: / { n = $0; sub(/^    name: /, "", n); print n }
    '
}

# Print the top-level `permissions:` block entries, sorted.
_permissions() {
    _body | awk '
        /^permissions:$/ { on = 1; next }
        on && /^  [a-z-]+: / { sub(/^  /, ""); print; next }
        on { exit }
    ' | sort
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "milestone-gate.yml exists" {
    assert [ -f "${GATE_YML}" ]
}

@test "pull_request_target triggers are exactly opened, synchronize, reopened, labeled, unlabeled" {
    run _types pull_request_target
    assert_output "$(printf '%s\n' labeled opened reopened synchronize unlabeled)"
}

@test "there is no pull_request trigger (it would run the PR's own code)" {
    run _body
    refute_line --regexp '^  pull_request:'
}

@test "the job runs for pull_request_target events" {
    run _body
    assert_line --regexp "^    if: .*github\.event_name == 'pull_request_target'"
}

@test "the checkout is pinned to the default branch without persisted credentials" {
    run _body
    assert_line --regexp '^          ref: \$\{\{ github\.event\.repository\.default_branch \}\}$'
    assert_line --regexp '^          persist-credentials: false$'
}

@test "nothing checks out or fetches the PR head" {
    run _body
    refute_line --regexp 'ref: .*pull_request\.head'
    refute_line --partial 'refs/pull/'
    refute_line --regexp 'git (fetch|checkout|switch)'
}

@test "issue_comment triggers are exactly created, edited, deleted" {
    run _types issue_comment
    assert_output "$(printf '%s\n' created deleted edited)"
}

@test "an issue_comment runs the job only when the issue is a PR" {
    run _body
    assert_line --regexp '^    if: .*github\.event\.issue\.pull_request'
}

@test "permissions are exactly statuses write, pull-requests read, issues read, contents read" {
    run _permissions
    assert_output "$(printf '%s\n' 'contents: read' 'issues: read' 'pull-requests: read' 'statuses: write')"
}

@test "the job sources lib/approval.sh and calls approval_evaluate" {
    run _body
    assert_line --partial 'source lib/approval.sh'
    assert_line --partial 'approval_evaluate'
}

@test "the status context is milestone-gate-approval on the PR head SHA" {
    run _body
    assert_line --partial 'context=milestone-gate-approval'
    assert_line --partial '/statuses/'
    assert_line --partial '.head.sha'
}

@test "the status state is success or failure only" {
    run _body
    assert_line --partial 'state=success'
    assert_line --partial 'state=failure'
    refute_line --partial 'state=pending'
    refute_line --partial 'state=error'
}

@test "ci.yml does not carry the milestone-gate-approval context" {
    run grep -c 'milestone-gate-approval' "${CI_YML}"
    assert_output 0
}

@test "the workflow has at least one job id and one job name" {
    run _job_ids_and_names
    assert_success
    assert [ "${#lines[@]}" -ge 2 ]
}

@test "no job id or job name equals the status context milestone-gate-approval" {
    run _job_ids_and_names
    assert_success
    refute_line 'milestone-gate-approval'
    refute_line "'milestone-gate-approval'"
    refute_line '"milestone-gate-approval"'
}
