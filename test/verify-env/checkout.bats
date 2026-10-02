#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

@test "real GitHub CLI supports every evidence query flag and checks JSON fields" {
    local query flag
    local -a command
    for query in 'pr checks' 'pr view' 'pr list'; do
        read -r -a command <<<"${query}"
        run gh "${command[@]}" --repo ycpss91255/worktool --help
        assert_success
        for flag in --repo --json; do
            assert_output --partial "${flag}"
        done
        if [[ "${query}" == 'pr checks' ]]; then
            assert_output --partial 'bucket'
            assert_output --partial 'name'
        else
            assert_output --partial '--jq'
        fi
        if [[ "${query}" == 'pr list' ]]; then
            assert_output --partial '--state'
            assert_output --partial '--search'
        fi
    done
    # gh api has no --repo flag; evidence scopes it in the endpoint path.
    run gh api --help
    assert_success
    assert_output --partial '--paginate'
    assert_output --partial '--jq'
}

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
