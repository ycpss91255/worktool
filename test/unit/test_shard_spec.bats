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
