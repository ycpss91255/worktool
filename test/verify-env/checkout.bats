#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

@test "real acceptance tools can enumerate a bind-mounted runner-owned checkout" {
    [[ "$(stat -c %u /checkout)" == 1001 ]]
    [[ "$(id -u)" != 1001 ]]
    run git -C /checkout ls-files
    assert_success
    assert_output 'tracked'
    local tool
    for tool in docker gh jq just distrobox; do
        run "${tool}" --version
        assert_success
    done
    run /usr/bin/time --version
    assert_success
    run ghostty +version
    assert_success
    # Trust must be limited to the mounted checkout, not every repository.
    local other="${BATS_TEST_TMPDIR}/other"
    git init -q "${other}"
    chown -R 1001:1001 "${other}"
    run git -C "${other}" ls-files
    assert_failure
    assert_output --partial 'detected dubious ownership'
}
