#!/usr/bin/env bats
# Full approved command x shell-wrapper product; CI only (#326).
load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/hook"

_commands() {
    local tier entry
    for tier in matrix integration system system-real acceptance; do
        printf '2|just test %s\n2|just test %s test/%s/example_spec.bats\n' "${tier}" "${tier}" "${tier}"
        printf '2|script/test/test.sh --%s\n2|script/test/test.sh --%s test/%s/example_spec.bats\n' "${tier}" "${tier}" "${tier}"
    done
    for entry in 'just test' 'just test unit' 'just test unit --filter example' \
        'script/test/test.sh' 'script/test/test.sh --unit' 'script/test/test.sh --unit --filter example'; do
        printf '2|%s\n' "${entry}"
    done
    for entry in 'just test lint' 'just test changed' 'just test --help' \
        'just test unit test/unit/log_spec.bats' \
        'just test unit test/unit/log_spec.bats test/unit/manifest_spec.bats --filter example' \
        'script/test/test.sh --lint' 'script/test/test.sh --changed' 'script/test/test.sh --help' \
        'script/test/test.sh --unit test/unit/log_spec.bats' \
        'script/test/test.sh --unit test/unit/log_spec.bats test/unit/manifest_spec.bats --filter example'; do
        printf '0|%s\n' "${entry}"
    done
    for tier in matrix integration system system-real acceptance unit; do
        printf '0|just test %s --help\n0|script/test/test.sh --%s --help\n' "${tier}" "${tier}"
    done
}

_wrapped() {
    case "$1" in
        direct) printf '%s\n' "$2" ;;
        bash-c) printf 'bash -c %q\n' "$2" ;;
        eval) printf 'eval %q\n' "$2" ;;
    esac
}

@test "matrix: every approved blocked and allowed command x direct bash-c eval" {
    local expected command wrapper
    while IFS='|' read -r expected command; do
        for wrapper in direct bash-c eval; do
            echo "${wrapper}: ${command} (expected ${expected})"
            run_hook enforce_local_test_scope "$(hook_json "$(_wrapped "${wrapper}" "${command}")")"
            if [[ "${expected}" == 2 ]]; then
                assert_failure 2
                assert_output --partial 'ci-passed'
            else
                assert_success
            fi
        done
    done < <(_commands)
}
