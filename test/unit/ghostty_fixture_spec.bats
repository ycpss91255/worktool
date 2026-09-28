#!/usr/bin/env bats
# test/unit/ghostty_fixture_spec.bats - the two guards of
# test/system/fixture/ghostty_single_instance.sh (M3, issue #172)
#
# WHAT THIS PROVES
#   The single-instance fixture hands two values to places where a bad
#   one is dangerous rather than merely wrong: the payload path goes into
#   a ghostty `command`, and `date +%s%N` output goes into shell
#   arithmetic. Both are guarded, and the guards are checked HERE - in
#   the fast tier - rather than only implicitly by the slow, privileged
#   run that needs a display and a real ghostty.
#
#   Path guard. A ghostty `command` without the `direct:` prefix is a
#   SHELL command line (ghostty 1.3.0 hands it to `/bin/sh -c`), so the
#   path is single quoted - measured against the runner image's ghostty,
#   `direct:` cannot carry a space at all, double quotes let `$` expand
#   and a backtick RUN, single quotes carry all three. A single quote or
#   a newline in the path would still break out of that quoting, and the
#   remaining shell metacharacters are refused as defence in depth. Each
#   is refused by name; an ordinary path (spaces included) is accepted.
#
#   Timestamp guard. Epoch nanoseconds are 19 digits today and cross
#   2^63-1 in 2262, so a digit count is not a range check: bash
#   arithmetic WRAPS above that bound instead of failing. Values at the
#   bound convert, values past it are refused, and so are the shapes a
#   `date` without `%N` produces.
#
# HOW
#   The fixture's own `--check-workdir` / `--check-epoch-ms` modes run
#   one guard and exit with its verdict, creating nothing and needing no
#   display, session bus or ghostty. Nothing here starts a window.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    FIXTURE="${REPO_ROOT}/test/system/fixture/ghostty_single_instance.sh"
    BASE="${BATS_TEST_TMPDIR}/wd"
}

_check_workdir() { run bash "${FIXTURE}" --check-workdir "$1"; }
_check_epoch() { run bash "${FIXTURE}" --check-epoch-ms "$1"; }

# --- required spec -----------------------------------------------------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- the path guard accepts what the quoting really carries ------------------

@test "check-workdir accepts an ordinary path" {
    _check_workdir "${BASE}/plain"
    assert_success
    assert_output --partial "workdir accepted: ${BASE}/plain"
}

@test "check-workdir accepts a path with spaces (that is what the quoting is for)" {
    _check_workdir "${BASE}/with space/and more"
    assert_success
    assert_output --partial "workdir accepted:"
}

@test "check-workdir accepts the other harmless punctuation a temp dir may carry" {
    local _p
    for _p in "${BASE}/a-b_c.d" "${BASE}/a=b" "${BASE}/a#b" "${BASE}/a*b?c" \
        "${BASE}/a(b)c" "${BASE}/a;b" "${BASE}/a&b" "${BASE}/a|b"; do
        _check_workdir "${_p}"
        assert_success
        assert_output --partial "workdir accepted:"
    done
}

# --- ... and refuses every character that would break out of it --------------

@test "check-workdir refuses a single quote (it would end the quoted run)" {
    _check_workdir "${BASE}/a'b"
    assert_failure 1
    assert_output --partial "must not contain a single quote"
}

@test "check-workdir refuses a newline (it would end the config line)" {
    _check_workdir "${BASE}/a"$'\n'"b"
    assert_failure 1
    assert_output --partial "must not contain a newline"
}

@test "check-workdir refuses a dollar sign (parameter / command substitution)" {
    _check_workdir "${BASE}/a\$HOME"
    assert_failure 1
    assert_output --partial "must not contain a dollar sign"
}

@test "check-workdir refuses a backtick (command substitution)" {
    _check_workdir "${BASE}/a\`printf x\`b"
    assert_failure 1
    assert_output --partial "must not contain a backtick"
}

@test "check-workdir refuses a double quote" {
    _check_workdir "${BASE}/a\"b"
    assert_failure 1
    assert_output --partial "must not contain a double quote"
}

@test "check-workdir refuses a backslash" {
    _check_workdir "${BASE}/a\\b"
    assert_failure 1
    assert_output --partial "must not contain a backslash"
}

@test "a refused workdir leaves nothing behind" {
    _check_workdir "${BASE}/a\$HOME"
    assert_failure 1
    assert [ ! -d "${BASE}" ]
}

# --- the timestamp guard ------------------------------------------------------

@test "check-epoch-ms converts a present-day 19-digit value" {
    _check_epoch 1790000000000000000
    assert_success
    assert_output "1790000000000"
}

@test "check-epoch-ms converts the largest value 64-bit arithmetic can hold" {
    # 2^63-1 exactly: the last value that must still be accepted.
    _check_epoch 9223372036854775807
    assert_success
    assert_output "9223372036854"
}

@test "check-epoch-ms refuses 19-digit values past 2^63-1 (they would WRAP)" {
    # One past the bound, and the largest 19-digit value. A digit-count
    # check alone accepts both; bash arithmetic turns them negative.
    local _v
    for _v in 9223372036854775808 9999999999999999999; do
        _check_epoch "${_v}"
        assert_failure 1
        assert_output --partial "exceed 2^63-1"
        # Refused, not silently converted into a negative millisecond.
        refute_output --regexp '^-?[0-9]+$'
    done
}

@test "check-epoch-ms refuses what a date without %N prints" {
    _check_epoch '1790581325%N'
    assert_failure 1
    assert_output --partial "does this date support %N"
}

@test "check-epoch-ms refuses values that are not 19 digits" {
    local _v
    for _v in 179000000000000000 17900000000000000000 '' 'abc' '-1790000000000000000'; do
        _check_epoch "${_v}"
        assert_failure 1
    done
}
