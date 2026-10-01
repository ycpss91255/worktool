#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/attribution_spec.bats - lib/attribution.sh attribution-line
# detector (issue #270; reused by the CI check of #271)
#
# Contract under test:
#   - attribution_find <text> prints every attribution line of <text>,
#     trimmed, one per line, and exits 0; with none it prints nothing and
#     exits 1;
#   - the three attribution lines count wherever they sit (first, middle,
#     last line, padded with blanks) and whatever their letter case;
#   - prose that merely mentions claude, a co-author or generated files is
#     no attribution line;
#   - attribution_patterns prints the one table, one ERE per line;
#   - the library sets no shell option and prints nothing when sourced.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    # shellcheck source=../../lib/attribution.sh
    source "${LIB_DIR}/attribution.sh"
}

@test "finds each attribution line, prints it trimmed and exits 0" {
    local _l
    for _l in \
        'Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>' \
        'co-authored-by: claude <noreply@anthropic.com>' \
        'Co-authored-by: Someone <bot@anthropic.com>' \
        'Claude-Session: https://claude.ai/code/session_0123' \
        'Generated with [Claude Code](https://claude.com/claude-code)' \
        'generated with claude code'; do
        run attribution_find "$(printf 'fix: x\n\n  %s  \n\nmore' "${_l}")"
        assert_success
        assert_output "${_l}"
    done
}

@test "lists every attribution line of a message, in order" {
    run attribution_find "$(printf '%s\n' 'Claude-Session: s' 'fix: x' 'Co-Authored-By: Claude <c@anthropic.com>')"
    assert_success
    assert_output "$(printf '%s\n' 'Claude-Session: s' 'Co-Authored-By: Claude <c@anthropic.com>')"
}

@test "prose that only mentions claude is no attribution line (exit 1, no output)" {
    local _t
    for _t in \
        'fix(hook): let claude read the co-authored-by rule' \
        'The Claude Code session keeps generated files.' \
        'Co-Authored-By: Some One <12345+someone@users.noreply.github.com>' \
        'see claude-session docs' \
        'Generated with care' \
        ''; do
        run attribution_find "${_t}"
        assert_failure 1
        assert_output ''
    done
}

@test "attribution_patterns prints the table, one ERE per line" {
    run attribution_patterns
    assert_success
    assert_line --partial 'co-authored-by'
    assert_line --partial 'claude-session'
    assert_line --partial 'generated with'
}

@test "sourcing the library prints nothing and sets no shell option" {
    run bash -c 'before="$-"; source "$1"; [[ "$-" == "${before}" ]]' _ "${LIB_DIR}/attribution.sh"
    assert_success
    assert_output ''
}
