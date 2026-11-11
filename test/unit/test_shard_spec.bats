#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# Unit spec for lib/test_shard.sh (issue #831): split a bats tier into N
# shards by weight, and the union verdict that applies the whole-tier rules
# to the shards' records.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    # shellcheck source=../../lib/test_shard.sh
    source "${LIB_DIR}/test_shard.sh"
    ROOT="${BATS_TEST_TMPDIR}/reports"
    LIST="${BATS_TEST_TMPDIR}/list"
    REQUIRED="${BATS_TEST_TMPDIR}/required"
    printf '%s\n' a_spec.bats b_spec.bats hook/c_spec.bats >"${LIST}"
    printf '%s\n' a_spec.bats hook/c_spec.bats >"${REQUIRED}"
}

# Write the record of shard $1 (i/N) of runner $2: the rest are
# spec:count pairs; the TAP holds one ok line per case unless $TAP is set.
_record() {
    local _shard="$1" _runner="$2" _dir _pair _plan=0 _i
    shift 2
    _dir="${ROOT}/test-report-unit-${_shard%/*}-${_runner}/unit"
    mkdir -p "${_dir}"
    {
        printf 'shard\t%s\n' "${_shard}"
        printf 'weights\t%s\n' "${WEIGHTS:-abc}"
        for _pair in "$@"; do
            printf 'spec\t%s\t%s\n' "${_pair%:*}" "${_pair##*:}"
            _plan=$((_plan + ${_pair##*:}))
        done
        printf 'plan\t%s\n' "${PLAN:-${_plan}}"
    } >"${_dir}/shard.tsv"
    if [[ -n "${TAP:-}" ]]; then
        printf '%s\n' "${TAP}" >"${_dir}/shard.tap"
    else
        {
            printf '1..%s\n' "${_plan}"
            for ((_i = 1; _i <= _plan; _i++)); do
                printf 'ok %d case %d # in 5 ms\n' "${_i}" "${_i}"
            done
        } >"${_dir}/shard.tap"
    fi
}

# Both runners, shards 1/2 and 2/2, every spec once.
_good_union() {
    local _r
    for _r in ubuntu-latest ubuntu-24.04-arm; do
        _record 1/2 "${_r}" a_spec.bats:2 hook/c_spec.bats:1
        _record 2/2 "${_r}" b_spec.bats:3
    done
}

@test "assignment balances by weight, heaviest first, ties by path and lowest shard" {
    run test_shard_assign 3 <<'ROWS'
100	a_spec.bats
900	b_spec.bats
400	hook/c_spec.bats
400	hook/d_spec.bats
300	e_spec.bats
100	f_spec.bats
ROWS
    assert_success
    assert_output "$(printf '%s\n' \
        "1	b_spec.bats" \
        "2	hook/c_spec.bats" \
        "3	hook/d_spec.bats" \
        "2	e_spec.bats" \
        "3	a_spec.bats" \
        "3	f_spec.bats")"
}

@test "with jobs, a shard costs max(load / jobs, its longest case): a long single case gets a shard to itself (#868)" {
    # Plain LPT (no jobs) stacks b_spec onto the shard of long_spec, whose
    # 2000 ms case alone sets that shard's wall time.
    run test_shard_assign 2 <<'ROWS'
2000	a_spec.bats	500
2000	b_spec.bats	500
2000	c_spec.bats	500
2000	long_spec.bats	2000
ROWS
    assert_success
    assert_output "$(printf '%s\n' "1	a_spec.bats" "2	b_spec.bats" "1	c_spec.bats" "2	long_spec.bats")"
    run test_shard_assign 2 4 <<'ROWS'
2000	a_spec.bats	500
2000	b_spec.bats	500
2000	c_spec.bats	500
2000	long_spec.bats	2000
ROWS
    assert_success
    assert_output "$(printf '%s\n' "1	long_spec.bats" "2	a_spec.bats" "2	b_spec.bats" "2	c_spec.bats")"
    run test_shard_assign 2 0 </dev/null
    assert_failure 1
}

@test "assignment rows: weight and longest case from the weights, a serial spec's longest is its weight, unknown specs by case count (#868)" {
    local _tier="${BATS_TEST_TMPDIR}/tier" _w="${BATS_TEST_TMPDIR}/weights.tsv"
    mkdir -p "${_tier}/hook"
    printf '@test "a" { :; }\n@test "b" { :; }\n' >"${_tier}/a_spec.bats"
    printf 'export BATS_NO_PARALLELIZE_WITHIN_FILE=true\n@test "s" { :; }\n' >"${_tier}/serial_spec.bats"
    printf '@test "n1" { :; }\n@test "n2" { :; }\n@test "n3" { :; }\n' >"${_tier}/hook/new_spec.bats"
    printf '%s\n' $'longest/unit/a_spec.bats\t700' $'matrix/a_spec.bats\t9' $'unit/a_spec.bats\t900' \
        $'unit/serial_spec.bats\t400' $'longest/unit/serial_spec.bats\t50' >"${_w}"
    run test_shard_rows unit "${_tier}" "${_w}" <<<"$(printf '%s\n' a_spec.bats hook/new_spec.bats serial_spec.bats)"
    assert_success
    assert_output "$(printf '%s\n' $'900\ta_spec.bats\t700' $'3000\thook/new_spec.bats\t0' $'400\tserial_spec.bats\t400')"
    # Weights written before #868 (no longest rows): longest 0; no weights file at all: case counts.
    printf '%s\n' $'unit/a_spec.bats\t900' >"${_w}"
    run test_shard_rows unit "${_tier}" "${_w}" <<<"a_spec.bats"
    assert_output $'900\ta_spec.bats\t0'
    run test_shard_rows unit "${_tier}" '' <<<"$(printf '%s\n' a_spec.bats serial_spec.bats)"
    assert_output "$(printf '%s\n' $'2000\ta_spec.bats\t0' $'1000\tserial_spec.bats\t1000')"
}

@test "the verdict passes when the shards' union is the whole tier on every runner" {
    _good_union
    run test_shard_verdict "${ROOT}" unit 2 "${LIST}" "${REQUIRED}" ubuntu-latest ubuntu-24.04-arm
    assert_success
    assert_line 'unit (ubuntu-latest): 2 shard(s), 3 spec(s), 6 case(s): the union is the whole tier'
    assert_line 'unit (ubuntu-24.04-arm): 2 shard(s), 3 spec(s), 6 case(s): the union is the whole tier'
}

# Break the good union of ubuntu-24.04-arm in way $1; the verdict must fail
# naming the reason $2 (and still pass the untouched runner).
_broken() {
    local _arm=ubuntu-24.04-arm _d="${ROOT}/test-report-unit-2-ubuntu-24.04-arm/unit"
    rm -rf "${ROOT}"
    _good_union
    case "$1" in
        missing) rm -rf "${ROOT}/test-report-unit-2-${_arm}" ;;
        extra) _record 3/2 "${_arm}" b_spec.bats:3 ;;
        label) sed -i 's|^shard\t2/2$|shard\t1/2|' "${_d}/shard.tsv" ;;
        duplicate) _record 2/2 "${_arm}" b_spec.bats:3 a_spec.bats:2 ;;
        unran) _record 2/2 "${_arm}" ;;
        foreign) _record 2/2 "${_arm}" b_spec.bats:3 x_spec.bats:1 ;;
        required) _record 1/2 "${_arm}" a_spec.bats:2 hook/c_spec.bats:0 ;;
        plan) PLAN=4 _record 2/2 "${_arm}" b_spec.bats:3 ;;
        oks) TAP=$'1..3\nok 1 a\nok 2 b' _record 2/2 "${_arm}" b_spec.bats:3 ;;
        failed) TAP=$'1..3\nok 1 a\nok 2 b\nok 3 c\nnot ok 4 d' _record 2/2 "${_arm}" b_spec.bats:3 ;;
        skipped) TAP=$'1..3\nok 1 a\nok 2 b # skip later\nok 3 c' _record 2/2 "${_arm}" b_spec.bats:3 ;;
        weights) WEIGHTS=other _record 2/2 "${_arm}" b_spec.bats:3 ;;
    esac
    run --separate-stderr test_shard_verdict "${ROOT}" unit 2 "${LIST}" "${REQUIRED}" ubuntu-latest "${_arm}"
    assert_failure 1
    assert_line 'unit (ubuntu-latest): 2 shard(s), 3 spec(s), 6 case(s): the union is the whole tier'
    [[ "${stderr:-}" == *"$2"* ]] || fail "case $1: stderr lacks '$2': ${stderr:-}"
}

@test "the verdict fails closed on every gap in the union of the shards" {
    _broken missing 'shard 2/2 left no record (missing shard fails closed)'
    _broken missing '1 shard record(s) found, 2 expected'
    _broken extra '3 shard record(s) found, 2 expected'
    _broken label "record 2 says shard '1/2', expected 2/2"
    _broken duplicate 'spec(s) in more than one shard: a_spec.bats'
    _broken unran 'spec(s) no shard ran: b_spec.bats'
    _broken foreign 'shard spec(s) not in the tier: x_spec.bats'
    _broken required 'required spec missing or without cases in the union: hook/c_spec.bats'
    _broken plan "shard 2/2 plan '4' is not the sum of its specs' cases (3)"
    _broken oks 'shard 2/2 TAP has 2 ok line(s) for a plan of 3'
    _broken failed 'shard 2/2 TAP has a failed case'
    _broken skipped 'shard 2/2 TAP has a skipped case'
    _broken weights 'shard 2/2 used other weights (other, not abc)'
}

@test "the verdict refuses an empty tier or required list" {
    _good_union
    : >"${LIST}"
    run --separate-stderr test_shard_verdict "${ROOT}" unit 2 "${LIST}" "${REQUIRED}" ubuntu-latest
    assert_failure 1
    assert_equal "${stderr:-}" '[ERROR] test_shard_verdict: empty tier or required list (fail closed).'
}

# Fetch fixture for test_shard_records_await (#890): the Nth call prints
# ${BATS_TEST_TMPDIR}/listing.N (the last one again once they run out), the
# "<id>\t<name>\t<created_at>" rows a run's artifact listing gives; `sleep`
# only counts.
_listing() {
    local _n
    _n=$(($(cat "${BATS_TEST_TMPDIR}/calls" 2>/dev/null || printf 0) + 1))
    printf '%s\n' "${_n}" >"${BATS_TEST_TMPDIR}/calls"
    while [[ "${_n}" -gt 1 && ! -f "${BATS_TEST_TMPDIR}/listing.${_n}" ]]; do _n=$((_n - 1)); done
    cat "${BATS_TEST_TMPDIR}/listing.${_n}"
}
sleep() { printf '%s\n' "$1" >>"${BATS_TEST_TMPDIR}/slept"; }

# The listing of run 42826334664 at the verdict's start: shard 4 of
# ubuntu-latest finalized 8 s earlier but is not listed yet; the image and
# other gates' artifacts are listed too.
_listing_without_4_latest() {
    printf '%s\t%s\t%s\n' \
        13769836167 worktool-test-image-ubuntu-latest 2026-11-10T13:38:36Z \
        13768289029 test-report-unit-1-ubuntu-latest 2026-11-10T13:42:31Z \
        13768593500 test-report-unit-2-ubuntu-latest 2026-11-10T13:41:44Z \
        13769297932 test-report-unit-3-ubuntu-latest 2026-11-10T13:42:43Z \
        13769127749 test-report-unit-1-ubuntu-24.04-arm 2026-11-10T13:41:31Z \
        13768413458 test-report-unit-2-ubuntu-24.04-arm 2026-11-10T13:40:22Z \
        13770275042 test-report-unit-3-ubuntu-24.04-arm 2026-11-10T13:41:23Z \
        13769786745 test-report-unit-4-ubuntu-24.04-arm 2026-11-10T13:42:25Z \
        13768428747 test-report-test-matrix-ubuntu-latest 2026-11-10T13:42:09Z
}

@test "records await: a shard record not listed yet is waited for, then every record is named by id (#890)" {
    _listing_without_4_latest >"${BATS_TEST_TMPDIR}/listing.1"
    { _listing_without_4_latest
      printf '%s\t%s\t%s\n' 13769058252 test-report-unit-4-ubuntu-latest 2026-11-10T13:44:25Z
    } >"${BATS_TEST_TMPDIR}/listing.2"
    run --separate-stderr test_shard_records_await 6 10 unit 4 ubuntu-latest ubuntu-24.04-arm -- _listing
    assert_success
    assert_output "$(printf '%s\t%s\n' \
        13768289029 test-report-unit-1-ubuntu-latest \
        13768593500 test-report-unit-2-ubuntu-latest \
        13769297932 test-report-unit-3-ubuntu-latest \
        13769058252 test-report-unit-4-ubuntu-latest \
        13769127749 test-report-unit-1-ubuntu-24.04-arm \
        13768413458 test-report-unit-2-ubuntu-24.04-arm \
        13770275042 test-report-unit-3-ubuntu-24.04-arm \
        13769786745 test-report-unit-4-ubuntu-24.04-arm)"
    run cat "${BATS_TEST_TMPDIR}/slept"
    assert_output 10
    # Everything listed at once: no wait.
    rm -f "${BATS_TEST_TMPDIR}"/listing.* "${BATS_TEST_TMPDIR}/calls" "${BATS_TEST_TMPDIR}/slept"
    { _listing_without_4_latest
      printf '%s\t%s\t%s\n' 13769058252 test-report-unit-4-ubuntu-latest 2026-11-10T13:44:25Z
    } >"${BATS_TEST_TMPDIR}/listing.1"
    run --separate-stderr test_shard_records_await 6 10 unit 4 ubuntu-latest ubuntu-24.04-arm -- _listing
    assert_success
    assert [ ! -e "${BATS_TEST_TMPDIR}/slept" ]
}

@test "records await: a re-run's record of the same name counts by its newest upload (#890)" {
    printf '%s\t%s\t%s\n' \
        900 test-report-unit-1-ubuntu-latest 2026-11-10T13:42:31Z \
        800 test-report-unit-1-ubuntu-latest 2026-11-10T14:10:00Z \
        901 test-report-unit-2-ubuntu-latest 2026-11-10T13:41:44Z >"${BATS_TEST_TMPDIR}/listing.1"
    run --separate-stderr test_shard_records_await 0 10 unit 2 ubuntu-latest -- _listing
    assert_success
    assert_output "$(printf '%s\t%s\n' 800 test-report-unit-1-ubuntu-latest 901 test-report-unit-2-ubuntu-latest)"
}

@test "records await: a shard that never recorded still fails closed after the bounded wait (#890)" {
    _listing_without_4_latest >"${BATS_TEST_TMPDIR}/listing.1"
    run --separate-stderr test_shard_records_await 3 10 unit 4 ubuntu-latest ubuntu-24.04-arm -- _listing
    assert_failure 1
    # The records that are there are still named, so the verdict can report
    # the whole picture; the missing one is named on stderr.
    assert_line "$(printf '%s\t%s' 13769786745 test-report-unit-4-ubuntu-24.04-arm)"
    refute_output --partial test-report-unit-4-ubuntu-latest
    [[ "${stderr}" == *"test-report-unit-4-ubuntu-latest not listed after 3 waits of 10s (fail closed)"* ]] \
        || fail "stderr: ${stderr}"
    run cat "${BATS_TEST_TMPDIR}/calls"
    assert_output 4
    # The verdict over what was downloaded fails on that shard.
    _record 1/4 ubuntu-latest a_spec.bats:1
    run --separate-stderr test_shard_verdict "${ROOT}" unit 4 "${LIST}" "${REQUIRED}" ubuntu-latest
    assert_failure 1
}

@test "records await: a failed listing or bad arguments fail closed at once (#890)" {
    run --separate-stderr test_shard_records_await 3 10 unit 4 ubuntu-latest -- false
    assert_failure 1
    [[ "${stderr}" == *'listing the artifacts failed (fail closed)'* ]] || fail "stderr: ${stderr}"
    run --separate-stderr test_shard_records_await x 10 unit 4 ubuntu-latest -- _listing
    assert_failure 1
    run --separate-stderr test_shard_records_await 3 10 unit 0 ubuntu-latest -- _listing
    assert_failure 1
    run --separate-stderr test_shard_records_await 3 10 unit 4 -- _listing
    assert_failure 1
    run --separate-stderr test_shard_records_await 3 10 unit 4 ubuntu-latest _listing
    assert_failure 1
    assert [ ! -e "${BATS_TEST_TMPDIR}/slept" ]
}
