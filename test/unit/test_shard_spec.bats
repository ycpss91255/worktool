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

@test "the verdict passes when the shards' union is the whole tier on every runner" {
    _good_union
    run test_shard_verdict "${ROOT}" unit 2 "${LIST}" "${REQUIRED}" ubuntu-latest ubuntu-24.04-arm
    assert_success
    assert_line 'unit (ubuntu-latest): 2 shard(s), 3 spec(s), 6 case(s): the union is the whole tier'
    assert_line 'unit (ubuntu-24.04-arm): 2 shard(s), 3 spec(s), 6 case(s): the union is the whole tier'
}
