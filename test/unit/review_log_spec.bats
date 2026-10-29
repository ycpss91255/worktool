#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    REPO="${BATS_TEST_TMPDIR}/repo"
    git init -q "$REPO"
    git -C "$REPO" config user.name 'Test User'
    git -C "$REPO" config user.email '12345+test@users.noreply.github.com'
    git -C "$REPO" commit -q --allow-empty -m base
    BASE="$(git -C "$REPO" rev-parse HEAD)"
}

_check() {
    # shellcheck source=../../lib/review_log.sh
    source "${LIB_DIR}/review_log.sh"
    review_log_check_commits "$REPO" "$BASE..HEAD"
}

@test "review-log check rejects newly committed review files even if later deleted (#675)" {
    local path
    for path in doc/evidence/review-notes.md doc/evidence/nested/675-REVIEW.md \
        notes/675-review-round-1.md 675-review-round-2.txt; do
        mkdir -p "$REPO/$(dirname "$path")"
        printf 'notes\n' > "$REPO/$path"
        git -C "$REPO" add .
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
