#!/usr/bin/env bats
# Representative fast coverage for the milestone approval hook. The complete
# products live in test/matrix and run in CI through `just test matrix`.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    MATRIX_SPEC="${REPO_ROOT}/test/matrix/enforce_milestone_gate_approval_spec.bats"
}

@test "this representative spec is required by the unit tier" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/hook/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "unit representative: merge approval behavior crosses the hook interface" {
    run bats --filter '^merge of a milestone-gate PR without an approval is blocked and says what is missing$' "${MATRIX_SPEC}"
    assert_success
}

@test "unit representative: comment body behavior crosses the hook interface" {
    run bats --filter '^an unmarked inline body with the phrase is blocked on every comment path$' "${MATRIX_SPEC}"
    assert_success
}

@test "unit representative: GraphQL behavior crosses the hook interface" {
    run bats --filter '^matrix: tag x GraphQL comment / review mutation x body source - every cell blocks \(these mutations block outright\)$' "${MATRIX_SPEC}"
    assert_success
}

@test "unit representative: direct HTTP behavior crosses the hook interface" {
    run bats --filter '^httpie --raw BODY \(separate value\) is a write even with GET / HEAD$' "${MATRIX_SPEC}"
    assert_success
}

@test "every moved full-product case name exists in the matrix tier" {
    local _name
    local _moved=(
        "matrix: every operation x gh spelling x wrapper is blocked"
        "matrix: a checked literal gh call passes through every shell wrapper and spelling"
        "matrix: every comment-writing operation x body source x tag - untagged blocks, tagged passes"
        "matrix: tag x GraphQL comment / review mutation x body source - every cell blocks (these mutations block outright)"
        "matrix: hook_http_is_write - method x data flag x option spelling x curl -G x tool, full product"
        "matrix: tool x method x data flag x REST endpoint class - reads pass, writes are blocked (full product)"
        "matrix: every REST endpoint path x host is recognised as an API endpoint"
        "matrix: tool x GraphQL body - a query reads, a mutation or an unreadable body is a write"
        "matrix: hook_api_endpoint_urls counts every host x path spelling of an API write URL"
        "matrix: a direct API write through curl / wget / http is blocked for every host spelling"
        "matrix: API reads that are no merge / comment / graphql URL pass for every host spelling"
        "matrix: a control byte in a gh command classifies like the same command without it"
    )
    for _name in "${_moved[@]}"; do
        run grep -Fqx -- "@test \"${_name}\" {" "${MATRIX_SPEC}"
        assert_success
    done
}

@test "approval rejection preserves exit two after evaluation and cleanup" {
    run bats --filter '^merge of a milestone-gate PR without an approval is blocked and says what is missing$' "${MATRIX_SPEC}"
    assert_success
}

@test "a merge without -R or a selector still resolves the PR under errexit" {
    run bats --filter '^(without -R the repo comes from gh repo view|a PR URL selector gives both repo and number|a failed repo or PR resolution blocks the merge \(fail closed\))$' "${MATRIX_SPEC}"
    assert_success
}
