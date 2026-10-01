#!/usr/bin/env bats
# test/unit/ci_yml_spec.bats - .github/workflows/ci.yml runs every gate on
# BOTH architectures (M3, issue #149: amd64 + arm64 runner matrix)
#
# WHAT THIS PROVES
#   The workflow has a runner dimension on every leg-carrying job:
#
#   - build-image, gate (lint / test-unit / test-integration / test-system /
#     test-acceptance) and test-system-real each `runs-on` the matrix runner
#     and their `runner:` dimension is EXACTLY the set {ubuntu-latest
#     (amd64), ubuntu-24.04-arm (arm64)} - no job hardcodes one
#     architecture, and a third runner (in the flow list or smuggled in
#     through `include:`) turns this spec red (issue #164);
#   - the `gate:` dimension is EXACTLY the set {lint, test-unit,
#     test-integration, test-system, test-acceptance}, and the `include:`
#     that maps each gate to its `just test` tier names exactly those five
#     - a sixth gate anywhere turns this spec red (issue #164);
#   - the matrix `include:` is EXACTLY five entries and each entry is
#     EXACTLY one `gate` plus one `tier`, the entry set being {lint=lint,
#     test-unit=unit, test-integration=integration, test-system=system,
#     test-acceptance=acceptance}: a swapped or wrong tier, an entry
#     without a tier or with two, an extra key inside an entry, or an
#     extra entry that names no gate at all (`- experimental: true`) turns
#     this spec red (codex rounds 1 and 2 on issue #164);
#   - the prebuilt test-image artifact is per-arch: the upload name in
#     build-image and the download name in gate are the SAME string and
#     carry the runner, so the two build legs cannot collide and every gate
#     loads its own arch's image;
#   - job names carry the runner so a check reads "lint (ubuntu-24.04-arm)";
#   - ci-passed `needs` every other job (so every matrix leg of each) and
#     verifies each one's result is `success`, under `if: always()`;
#   - `--privileged` is mentioned by the test-system-real job only;
#   - the commit-email job (issue #234) checks out the full history,
#     sources lib/commit_email.sh, picks the range with commit_email_range
#     (event data plus the default branch ref; one revision per line, each
#     a separate git log argument), feeds `git log` records to
#     commit_email_evaluate, and ci-passed requires it like every other job.
#   - commit-attribution uses the same event range, checks commit messages
#     and pull request bodies through lib/commit_attribution.sh, and joins
#     ci-passed.
#
#   This spec is a REQUIRED unit spec of test.sh, so it cannot be deleted
#   silently.
#
# HOW
#   Textual assertions on the checked-in ci.yml (the test image has no YAML
#   parser): a job block is the lines from `  <id>:` under `jobs:` up to
#   the next two-space-indented key, with comment lines dropped so a runner
#   name in a comment never satisfies an assertion. Flow lists
#   (`key: [a, b]`) are split into their items and compared as SORTED SETS
#   against the expected set (order-insensitive, but any extra or missing
#   item fails). Nothing runs and nothing is copied.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    CI_YML="${REPO_ROOT}/.github/workflows/ci.yml"
    RUNNERS=(ubuntu-latest ubuntu-24.04-arm)
    LEG_JOBS=(build-image gate test-system-real)
    GATES=(lint test-unit test-matrix test-integration test-system test-acceptance)
    # gate=tier: the `just test <tier>` each gate runs (the include map).
    TIERS=(lint=lint test-unit=unit test-matrix=matrix test-integration=integration
        test-system=system test-acceptance=acceptance)
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

# Print the items of the flow list line `<indent><key>: [a, b, ...]` of
# job $1, one per line, sorted. $2 = indent, $3 = key. Every matching line
# contributes, so a duplicated key shows up as extra items; no matching
# line prints nothing (which never equals a non-empty expected set).
_flow_items() {
    _job_block "$1" \
        | sed -nE "s/^$2$3: \\[(.*)\\]\$/\\1/p" \
        | tr ',' '\n' \
        | sed -E 's/^ +//; s/ +$//' \
        | sort
}

# Print every non-comment line INSIDE job $1 (indented deeper than the
# job id, so the `  gate:` id line itself never counts) that sets key $2,
# whether as a mapping key (`key:`) or as a sequence item (`- key:`).
_key_lines() {
    _job_block "$1" | grep -E "^ {4,}(- )?$2:"
}

# Print the value of every `- <key>:` sequence item of job $1 (the entries
# of the matrix `include:`), one per line, sorted. $2 = key.
_include_values() {
    _job_block "$1" \
        | sed -nE "s/^ +- $2: (.*)\$/\\1/p" \
        | sort
}

# Print one line per entry of the matrix `include:` of job $1, sorted: the
# entry's `key=value` pairs, sorted and joined by `,`. The include block is
# the lines indented deeper than `        include:` up to the first that
# is not (a `- key:` anywhere else in the job never counts); an entry is a
# `- key: value` line plus the deeper-indented `key: value` lines up to
# the next `- `. So the good entry `- gate: lint` / `tier: lint` prints
# `gate=lint,tier=lint`; one with no tier prints `gate=lint`, one with two
# `gate=lint,tier=a,tier=b`, one with a stray key
# `experimental=true,gate=lint,tier=lint`, and an extra entry naming no
# gate prints its own line (`experimental=true`) - none of which equals the
# expected entry set, and the line count IS the entry count.
_include_entries() {
    _job_block "$1" | awk '
        /^        include:$/ { inc = 1; next }
        inc && /^ *$/ { next }
        inc && !/^ {9}/ { inc = 0 }
        inc && /^ +- / { n++ }
        inc && n { sub(/^ +(- )?/, ""); sub(/: /, "="); print n "\t" $0 }
    ' \
        | sort -t "$(printf '\t')" -k1,1n -k2,2 \
        | awk -F '\t' '
            $1 != n { if (n) print out; n = $1; out = $2; next }
            { out = out "," $2 }
            END { if (n) print out }
        ' \
        | sort
}

# Print the expected set $@ one per line, sorted (the shape _flow_items,
# _include_values and _include_entries print, for assert_output).
_sorted_set() {
    printf '%s\n' "$@" | sort
}

# Print the pull_request trigger types, one per line, sorted.
_pull_request_types() {
    sed -nE '/^  pull_request:$/,/^permissions:$/ s/^    types: \[(.*)\]$/\1/p' "${CI_YML}" \
        | tr ',' '\n' \
        | sed -E 's/^ +//; s/ +$//' \
        | sort
}

# --- required spec -----------------------------------------------------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "pull_request reruns CI when the PR body is edited" {
    run _pull_request_types
    assert_output "$(_sorted_set opened synchronize reopened edited)"
}

# --- every leg-carrying job runs on both runners -----------------------------

@test "ci.yml declares exactly the expected jobs" {
    run _job_ids
    assert_success
    assert_line "build-image"
    assert_line "gate"
    assert_line "test-system-real"
    assert_line "commit-email"
    assert_line "commit-attribution"
    assert_line "commit-refs"
    assert_line "ci-passed"
    assert_equal "${#lines[@]}" 7
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

@test "the runner dimension of every leg-carrying job is EXACTLY the two runners (a third turns red)" {
    local _job
    for _job in "${LEG_JOBS[@]}"; do
        # The flow list, as a sorted set: nothing extra, nothing missing.
        run _flow_items "${_job}" '        ' runner
        assert_output "$(_sorted_set "${RUNNERS[@]}")"
        # And that flow list is the ONLY place the job sets `runner`: no
        # second list and no `- runner:` include entry adding a leg.
        run _key_lines "${_job}" runner
        assert_success
        assert_equal "${#lines[@]}" 1
        assert_line --regexp '^        runner: \['
    done
}

@test "gate runs every one of the six gates on the runner dimension" {
    local _gate
    run _job_block gate
    assert_success
    assert_line --regexp '^        gate: \['
    for _gate in "${GATES[@]}"; do
        assert_line --regexp "$(_flow_has '        ' gate "${_gate}")"
    done
    assert_line --regexp '^    name: .*\$\{\{ matrix\.gate \}\}.*\$\{\{ matrix\.runner \}\}'
}

@test "the gate dimension is EXACTLY the six gates (a seventh turns red)" {
    # The flow list, as a sorted set: nothing extra, nothing missing.
    run _flow_items gate '        ' gate
    assert_output "$(_sorted_set "${GATES[@]}")"
    # `gate` is set by exactly the flow list plus one include entry per
    # gate: a second list or a stray include entry is one line too many.
    run _key_lines gate gate
    assert_success
    assert_equal "${#lines[@]}" $(( 1 + ${#GATES[@]} ))
}

@test "gate's matrix include maps EXACTLY the six gates to a tier and adds no runner" {
    # One `- gate: <name>` include entry per gate, no more, no less.
    run _include_values gate gate
    assert_output "$(_sorted_set "${GATES[@]}")"
    # Every include entry carries its tier (the `just test <tier>` it runs),
    # and no include entry names a runner (that would add a third leg).
    run _job_block gate
    assert_success
    refute_line --regexp '^ +- runner:'
    run _key_lines gate tier
    assert_success
    assert_equal "${#lines[@]}" "${#GATES[@]}"
}

@test "the include is EXACTLY six entries, each EXACTLY one gate plus its tier (an extra entry, key or tier turns red)" {
    local _pair _entries=()
    for _pair in "${TIERS[@]}"; do
        _entries+=("gate=${_pair%%=*},tier=${_pair#*=}")
    done
    # Every include entry, key by key, as a sorted set: the set-of-gates
    # and count-of-tiers checks above cannot tell `lint: unit` from
    # `lint: lint`, nor one entry missing its tier while another has two,
    # nor see an entry that names no gate at all (`- experimental: true`)
    # or a stray key riding along inside a gate's entry.
    run _include_entries gate
    assert_output "$(_sorted_set "${_entries[@]}")"
    assert_equal "${#lines[@]}" "${#GATES[@]}"
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
    for _job in build-image gate commit-email commit-attribution commit-refs ci-passed; do
        run _job_block "${_job}"
        refute_output --partial '--privileged'
    done
    run _job_block test-system-real
    assert_output --partial '--privileged'
}

# --- commit-email: author and committer email are noreply (#234) -------------

@test "commit-email checks out the full history without persisted credentials" {
    run _job_block commit-email
    assert_success
    assert_line '    name: commit-email'
    assert_line --partial 'uses: actions/checkout@'
    assert_line '          fetch-depth: 0'
    assert_line '          persist-credentials: false'
}

@test "commit-email delegates the rule to lib/commit_email.sh (not re-implemented in YAML)" {
    run _job_block commit-email
    assert_success
    assert_line --regexp '^ +source lib/commit_email\.sh$'
    assert_line --partial "commit_email_range \"\${EVENT}\" \"\${PR_BASE}\" \"\${PR_HEAD}\" \"\${PUSH_BEFORE}\" \"\${PUSH_AFTER}\" \"\${DEFAULT_REF}\")\" || exit 1"
    # One revision per line, each its own git log argument (a new ref is
    # `<after>` plus `^<default ref>`, not a single string).
    assert_line --regexp '^ +mapfile -t revs <<< "\$\{range\}"$'
    assert_line --partial "git log --format=\"\$(commit_email_log_format)\" \"\${revs[@]}\" -- "
    refute_output --partial "\"\${range}\" >"
    refute_output --partial '--date='
    refute_output --partial 'cutoff'
    assert_line --regexp '^ +commit_email_evaluate < '
    refute_output --partial 'users.noreply.github.com'
}

@test "commit-email feeds the PR and push event data to the range" {
    run _job_block commit-email
    assert_success
    assert_line "          EVENT: \${{ github.event_name }}"
    assert_line "          PR_BASE: \${{ github.event.pull_request.base.sha }}"
    assert_line "          PR_HEAD: \${{ github.event.pull_request.head.sha }}"
    assert_line "          PUSH_BEFORE: \${{ github.event.before }}"
    assert_line "          PUSH_AFTER: \${{ github.event.after }}"
    assert_line "          DEFAULT_REF: refs/remotes/origin/\${{ github.event.repository.default_branch }}"
}

# --- commit-attribution: commit messages and PR body (#271) -----------------

@test "commit-attribution checks full history without persisted credentials" {
    run _job_block commit-attribution
    assert_success
    assert_line '    name: commit-attribution'
    assert_line --partial 'uses: actions/checkout@'
    assert_line '          fetch-depth: 0'
    assert_line '          persist-credentials: false'
}

@test "commit-attribution delegates range, commit, and PR body checks to its library" {
    run _job_block commit-attribution
    assert_success
    assert_line --regexp '^ +source lib/commit_attribution\.sh$'
    assert_line --partial "commit_attribution_range \"\${EVENT}\" \"\${PR_BASE}\" \"\${PR_HEAD}\" \"\${PUSH_BEFORE}\" \"\${PUSH_AFTER}\" \"\${DEFAULT_REF}\")\" || exit 1"
    assert_line --regexp '^ +mapfile -t revs <<< "\$\{range\}"$'
    assert_line --regexp '^ +commit_attribution_check_commits '
    assert_line "          PR_BODY: \${{ github.event.pull_request.body }}"
    assert_line --regexp '^ +commit_attribution_check_pr_body "\$\{EVENT\}" "\$\{PR_BODY\}"$'
    refute_output --partial 'Co-Authored-By:'
    refute_output --partial 'Claude-Session:'
}

@test "commit-refs checks new commits and is required by ci-passed (#312)" {
    run _job_block commit-refs
    assert_success
    assert_output --partial 'fetch-depth: 0'
    assert_output --partial 'persist-credentials: false'
    assert_output --partial 'source lib/commit_refs.sh'
    assert_output --partial 'commit_refs_range "${EVENT}" "${PR_BASE}" "${PR_HEAD}" "${PUSH_BEFORE}" "${PUSH_AFTER}" "${DEFAULT_REF}"'
    assert_output --partial 'commit_refs_check_commits . "${revs[@]}"'
    assert_output --partial 'EVENT: ${{ github.event_name }}'
    assert_output --partial 'PR_BASE: ${{ github.event.pull_request.base.sha }}'
    assert_output --partial 'PR_HEAD: ${{ github.event.pull_request.head.sha }}'
    assert_output --partial 'PUSH_BEFORE: ${{ github.event.before }}'
    assert_output --partial 'PUSH_AFTER: ${{ github.event.after }}'
    assert_output --partial 'DEFAULT_REF: refs/remotes/origin/${{ github.event.repository.default_branch }}'
    run _job_block ci-passed
    assert_output --partial 'commit-refs]'
    assert_output --partial 'REFS_RESULT: ${{ needs.commit-refs.result }}'
    assert_output --partial '[ "${REFS_RESULT}" = "success" ] || exit 1'
}
