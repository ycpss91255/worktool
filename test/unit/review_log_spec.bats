#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    REPO="${BATS_TEST_TMPDIR}/repo"
    git init -q "$REPO"
    git -C "$REPO" config user.name 'Test User'
    git -C "$REPO" config user.email '12345+test@users.noreply.github.com'
    git -C "$REPO" commit -q --allow-empty -m base
    PRE_RULE="$(git -C "$REPO" rev-parse HEAD)"
    _introduce_rule
    BASE="$(git -C "$REPO" rev-parse HEAD)"
}

_introduce_rule() {
    mkdir -p "$REPO/lib"
    cp "${LIB_DIR}/review_log.sh" "$REPO/lib/review_log.sh"
    git -C "$REPO" add lib/review_log.sh
    git -C "$REPO" commit -q -m 'Introduce review log check'
}

_check() {
    # shellcheck source=../../lib/review_log.sh
    source "${LIB_DIR}/review_log.sh"
    review_log_check_commits "$REPO" "$BASE..HEAD"
}

@test "review-log check fails closed when the introduction point is missing (#684)" {
    git -C "$REPO" checkout -q -b old-topic "$PRE_RULE"
    git -C "$REPO" commit -q --allow-empty -m 'Old topic work'
    BASE="$PRE_RULE"

    run _check
    assert_failure 1
    assert_output --partial 'Cannot find enforcing commit for lib/review_log.sh'
    assert_output --partial 'fetch full history (fail closed)'
}

@test "review-log check fails closed with shallow history (#684)" {
    local shallow="${BATS_TEST_TMPDIR}/shallow"
    git -C "$REPO" commit -q --allow-empty -m 'Work after the rule'
    git clone -q --depth 1 "file://$REPO" "$shallow"
    # Check HEAD directly: even an apparently discoverable addition is unreliable.
    # shellcheck source=../../lib/review_log.sh
    source "${LIB_DIR}/review_log.sh"
    run review_log_check_commits "$shallow" HEAD
    assert_failure 1
    assert_output --partial 'shallow history'
    assert_output --partial 'fetch full history (fail closed)'
}

@test "review-log check skips pre-rule additions with notes in a PR 157 shaped history (#684)" {
    local enforcing old
    enforcing="$(git -C "$REPO" rev-parse HEAD)"
    git -C "$REPO" branch -m main
    git -C "$REPO" checkout -q -b old-topic "$PRE_RULE"
    mkdir -p "$REPO/doc/evidence"
    printf 'old notes\n' > "$REPO/doc/evidence/663-review-round-2.md"
    git -C "$REPO" add .
    # A future date cannot make an old-branch commit subject to the rule.
    GIT_AUTHOR_DATE='2099-01-01T00:00:00Z' GIT_COMMITTER_DATE='2099-01-01T00:00:00Z' \
        git -C "$REPO" commit -q -m 'Old review notes'
    old="$(git -C "$REPO" rev-parse HEAD)"
    git -C "$REPO" rm -q doc/evidence/663-review-round-2.md
    git -C "$REPO" commit -q -m 'Remove old review notes'
    git -C "$REPO" merge -q --no-ff main -m 'Sync main with the rule'

    run _check
    assert_success
    assert_output --partial "$old skipped: does not descend from enforcing commit $enforcing"
}

@test "review-log check rejects newly committed review files even if later deleted (#675)" {
    local path
    for path in doc/evidence/review-notes.md doc/evidence/nested/675-REVIEW.md \
        notes/675-review-round-1.md 675-review-round-2.txt; do
        mkdir -p "$REPO/$(dirname "$path")"
        printf 'notes\n' > "$REPO/$path"
        git -C "$REPO" add .
        # Backdating cannot exempt a descendant of the enforcing commit.
        GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
            git -C "$REPO" commit -q -m 'Add notes'
        git -C "$REPO" rm -q "$path"
        git -C "$REPO" commit -q -m 'Remove notes'
        run _check
        assert_failure 1
        assert_output --partial "$path"
        assert_output --partial 'PR comment'
        BASE="$(git -C "$REPO" rev-parse HEAD)"
    done
}

@test "review-log check allows existing review files and acceptance evidence (#675)" {
    local path
    mkdir -p "$REPO/doc/evidence"
    printf 'old notes\n' > "$REPO/doc/evidence/old-review.md"
    git -C "$REPO" add .
    git -C "$REPO" commit -q -m 'Existing evidence'
    BASE="$(git -C "$REPO" rev-parse HEAD)"
    printf 'updated\n' >> "$REPO/doc/evidence/old-review.md"
    for path in README.md tdd.sh negative/example.txt; do
        mkdir -p "$REPO/doc/evidence/$(dirname "$path")"
        printf 'acceptance\n' > "$REPO/doc/evidence/$path"
    done
    git -C "$REPO" add .
    git -C "$REPO" commit -q -m 'Update acceptance evidence'
    run _check
    assert_success
    assert_output ''
    git -C "$REPO" rm -q doc/evidence/old-review.md
    git -C "$REPO" commit -q -m 'Remove old review'
    run _check
    assert_success
}

@test "review-log check allows existing review files brought in by merging main (#675)" {
    git -C "$REPO" branch -m main
    git -C "$REPO" branch topic
    mkdir -p "$REPO/doc/evidence"
    printf 'old notes\n' > "$REPO/doc/evidence/363-review-round-1.md"
    printf 'old notes\n' > "$REPO/doc/evidence/607-review-round-1.md"
    git -C "$REPO" add .
    git -C "$REPO" commit -q -m 'Existing review evidence on main'
    BASE="$(git -C "$REPO" rev-parse HEAD)"
    git -C "$REPO" checkout -q topic
    git -C "$REPO" commit -q --allow-empty -m 'Topic work'
    git -C "$REPO" merge -q --no-ff main -m 'Sync main'

    run _check
    assert_success
    assert_output ''
}

@test "review-log check rejects a review file added by the merge itself (#675)" {
    git -C "$REPO" branch -m main
    git -C "$REPO" branch topic
    git -C "$REPO" commit -q --allow-empty -m 'Main work'
    BASE="$(git -C "$REPO" rev-parse HEAD)"
    git -C "$REPO" checkout -q topic
    git -C "$REPO" commit -q --allow-empty -m 'Topic work'
    git -C "$REPO" merge -q --no-ff --no-commit main
    mkdir -p "$REPO/doc/evidence"
    printf 'new notes\n' > "$REPO/doc/evidence/675-review-round-1.md"
    git -C "$REPO" add .
    git -C "$REPO" commit -q -m 'Add review notes during merge'

    run _check
    assert_failure 1
    assert_output --partial 'doc/evidence/675-review-round-1.md'
    assert_output --partial 'PR comment'
}
