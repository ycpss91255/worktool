#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/hook/disable_diff_spec.bats
#
# Unit tests for `new_shellcheck_disables` in
# .agents/hook/enforce_shellcheck_disable_approval.sh.
#
# Module contract:
#   - Args: $1 = new_content_str, $2 = existing_file_path (may not exist)
#   - Stdout: one SC code per line for each disable in $1 NOT in $2;
#     multi-code directives (`disable=SC2034,SC2317`) split into codes
#   - Exit: 0 always

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    HOOK_SH="${HOOK_DIR}/enforce_shellcheck_disable_approval.sh"
    # shellcheck source=../../../.agents/hook/enforce_shellcheck_disable_approval.sh
    source "${HOOK_SH}"
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/contents"
    mkdir -p "${FIXTURE_DIR}"
}

@test "new_shellcheck_disables: new file, one disable -> that code emitted" {
    run new_shellcheck_disables "$(printf '#!/usr/bin/env bash\n%s\nfoo=bar\n' "$(disable_line SC2034)")" \
        "${FIXTURE_DIR}/new.sh"
    assert_success
    assert_output "SC2034"
}

@test "new_shellcheck_disables: empty content + empty existing -> empty" {
    run new_shellcheck_disables "" "${FIXTURE_DIR}/empty.sh"
    assert_success
    assert_output ""
}

@test "new_shellcheck_disables: content adds SC2034, existing has SC1091 -> only SC2034" {
    local existing="${FIXTURE_DIR}/with-sc1091.sh"
    printf '#!/usr/bin/env bash\n%s\nsource x.sh\n' "$(disable_line SC1091)" >"${existing}"
    run new_shellcheck_disables "$(cat "${existing}")
$(disable_line SC2034)
foo=bar" "${existing}"
    assert_success
    assert_output "SC2034"
}

@test "new_shellcheck_disables: comma-separated SC2034,SC2317 -> both codes" {
    run new_shellcheck_disables "$(disable_line SC2034,SC2317)
foo() { :; }" "${FIXTURE_DIR}/multi.sh"
    assert_success
    assert_line "SC2034"
    assert_line "SC2317"
}

@test "new_shellcheck_disables: re-save with same disables -> empty (additions only)" {
    local existing="${FIXTURE_DIR}/same.sh"
    printf '%s\nfoo=bar\n' "$(disable_line SC2034)" >"${existing}"
    run new_shellcheck_disables "$(cat "${existing}")" "${existing}"
    assert_success
    assert_output ""
}

@test "new_shellcheck_disables: removal of a disable -> empty (additions only)" {
    local existing="${FIXTURE_DIR}/with-two.sh"
    printf '%s\n%s\nfoo=bar\n' "$(disable_line SC2034)" "$(disable_line SC1091)" >"${existing}"
    run new_shellcheck_disables "$(disable_line SC2034)
foo=bar" "${existing}"
    assert_success
    assert_output ""
}

@test "new_shellcheck_disables: mixed add (SC1091) + remove (SC2317) -> only SC1091" {
    local existing="${FIXTURE_DIR}/mixed.sh"
    printf '%s\n%s\nfoo=bar\n' "$(disable_line SC2034)" "$(disable_line SC2317)" >"${existing}"
    run new_shellcheck_disables "$(disable_line SC2034)
$(disable_line SC1091)
foo=bar" "${existing}"
    assert_success
    assert_output "SC1091"
}

@test "new_shellcheck_disables: empty existing-path arg -> treats as no existing" {
    run new_shellcheck_disables "$(disable_line SC2155)
x=foo" ""
    assert_success
    assert_output "SC2155"
}
