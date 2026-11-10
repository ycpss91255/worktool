#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() { run_hook enforce_local_test_scope "$(hook_json "$1")"; }

@test "#800: a touched spec of any tier except system-real runs locally" {
    local tier
    for tier in unit matrix integration system acceptance; do
        _check "just test ${tier} test/${tier}/example_spec.bats --filter example"
        assert_success
        _check "bash -c 'script/test/test.sh --${tier} test/${tier}/example_spec.bats'"
        assert_success
    done
}

@test "#800: whole tiers and system-real stay with CI, citing ADR 0014 decision 2" {
    local cmd
    for cmd in 'just test matrix' 'just test acceptance --filter example' \
        'just test system-real' 'just test system-real test/system-real/example_spec.bats' \
        'just test system test/system/real_engine_spec.bats' \
        'script/test/test.sh --system test/system/real_engine_spec.bats' \
        'script/test/test.sh --unit test/unit/log_spec.bats --matrix'; do
        _check "${cmd}"
        assert_failure 2
        assert_output --partial 'ci-passed'
        assert_output --partial 'ADR 0014 decision 2'
        refute_output --partial 'changed unit specs'
    done
}

# A spec argument the shell expands (glob, brace, parameter or command
# substitution) can select a whole tier the hook never sees; only literal
# spec paths count as touched specs (#818, ADR 0014 decision 2).
@test "#818: spec arguments the shell expands are blocked in every launcher" {
    local cmd wrapped
    for cmd in 'just test matrix test/matrix/*.bats' \
        'just test unit test/unit/*_spec.bats' \
        'just test unit test/unit/hook/enforce_?ocal_test_scope_spec.bats' \
        'just test unit test/unit/[a-z]*_spec.bats --filter example' \
        'just test matrix test/matrix/{approval,enforce_local_test_scope}_spec.bats' \
        'just test matrix test/matrix/enforce_local_test_scope_spec.bats test/matrix/*.bats' \
        "just test unit \$SPECS" "just test unit \"\${SPECS}\"" \
        "just test unit \$(ls test/unit/*_spec.bats)" "just test unit \`ls test/unit\`" \
        'script/test/test.sh --matrix test/matrix/*.bats' \
        'script/test/test.sh --ci-unit test/unit/*_spec.bats'; do
        for wrapped in "${cmd}" "bash -c $(printf '%q' "${cmd}")" "eval $(printf '%q' "${cmd}")"; do
            _check "${wrapped}"
            assert_failure 2
            assert_output --partial 'ADR 0014 decision 2'
        done
    done
}

@test "#818: literal specs and --filter regexes still run locally" {
    local cmd
    for cmd in "just test unit test/unit/log_spec.bats --filter 'a.*b[0-9]?'" \
        "just test unit test/unit/log_spec.bats --filter '^#(810|804): '" \
        "just test matrix 'test/matrix/enforce_local_test_scope_spec.bats'" \
        'just test acceptance test/acceptance/example_spec.bats'; do
        _check "${cmd}"
        assert_success
    done
}

@test "#800: internal container gates follow the same scope rule" {
    local cmd
    for cmd in 'script/test/test.sh --ci-unit' 'script/test/test.sh --ci-matrix' \
        'script/test/test.sh --ci-system-real' 'script/test/test.sh --ci-integration-ghostty'; do
        _check "${cmd}"
        assert_failure 2
    done
    _check 'script/test/test.sh --ci-unit test/unit/log_spec.bats'
    assert_success
    _check 'script/test/test.sh --ci-lint'
    assert_success
}

@test "bare tests and whole unit tiers are blocked through shell wrappers" {
    _check "bash -c 'just test unit --filter example'"
    assert_failure 2
    _check "eval 'just test'"
    assert_failure 2
}

@test "direct test script heavy flags cannot bypass the local scope guard" {
    _check "eval 'bash script/test/test.sh --system-real test/system-real/example_spec.bats'"
    assert_failure 2
    _check 'script/test/test.sh --unit'
    assert_failure 2
    _check 'script/test/test.sh'
    assert_failure 2
}

@test "light tests selected unit specs and help remain allowed" {
    _check 'just test lint'
    assert_success
    _check 'just test changed'
    assert_success
    _check "bash -c 'just test unit test/unit/log_spec.bats --filter example'"
    assert_success
    _check 'script/test/test.sh --unit test/unit/log_spec.bats'
    assert_success
    _check 'just test matrix --help'
    assert_success
    _check 'script/test/test.sh --help'
    assert_success
    _check "printf '%s' 'just test matrix'"
    assert_success
}

@test "CI requires the full local test scope product matrix" {
    run bash -c 'source "$1"; _required_specs matrix' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line 'matrix/enforce_local_test_scope_spec.bats'
}

@test "a filter value naming a heavy tier is data rather than a tier launch" {
    _check 'just test unit test/unit/log_spec.bats --filter matrix'
    assert_success
    _check 'script/test/test.sh --unit test/unit/log_spec.bats --filter system'
    assert_success
}
