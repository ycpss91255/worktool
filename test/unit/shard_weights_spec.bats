#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# Unit spec for lib/shard_weights.sh (issue #827): merge the junit reports
# of the bats gates into one spec -> milliseconds table, the shard weights,
# plus each spec's longest single case as a longest/ row (#868).

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    # shellcheck source=../../lib/shard_weights.sh
    source "${LIB_DIR}/shard_weights.sh"
    REPORTS="${BATS_TEST_TMPDIR}/reports"
}

# Write a junit report for tier $2 under artifact directory $1; the rest are
# suite:case-seconds,... specs, e.g. 'a_spec.bats:0.5,1.25'.
_report() {
    local _art="$1" _tier="$2" _suite _times _t
    shift 2
    mkdir -p "${REPORTS}/${_art}/${_tier}"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites time="9.9">\n'
        for _suite in "$@"; do
            _times="${_suite#*:}"
            _suite="${_suite%%:*}"
            printf '<testsuite name="%s" tests="2" time="0.001">\n' "${_suite}"
            IFS=',' read -r -a _t <<<"${_times}"
            for _times in "${_t[@]}"; do
                printf '    <testcase classname="%s" name="case &amp; more" time="%s" />\n' \
                    "${_suite}" "${_times}"
            done
            printf '</testsuite>\n'
        done
        printf '</testsuites>\n'
    } >"${REPORTS}/${_art}/${_tier}/report.xml"
}

@test "merged weights sum the case times per spec and keep the slower runner; the longest case of each spec is a longest/ row (#868)" {
    _report test-report-unit-amd unit 'b_spec.bats:0.5,1.25' 'hook/a_spec.bats:2'
    _report test-report-unit-arm unit 'b_spec.bats:1,1' 'hook/a_spec.bats:1.5'
    _report test-report-matrix-amd matrix 'm_spec.bats:10.001'
    run shard_weights_merge "${REPORTS}" unit matrix
    assert_success
    assert_output "$(printf '%s\n' $'longest/matrix/m_spec.bats\t10001' $'longest/unit/b_spec.bats\t1250' \
        $'longest/unit/hook/a_spec.bats\t2000' $'matrix/m_spec.bats\t10001' $'unit/b_spec.bats\t2000' \
        $'unit/hook/a_spec.bats\t2000')"
}

@test "a listed tier without a report, or a report without timed cases, writes no weights" {
    _report test-report-unit-amd unit 'b_spec.bats:1'
    run --separate-stderr shard_weights_merge "${REPORTS}" unit matrix
    assert_failure 1
    assert_output ''
    assert_equal "${stderr:-}" "[ERROR] no junit report for tier matrix under ${REPORTS}"

    mkdir -p "${REPORTS}/test-report-matrix-amd/matrix"
    printf '<testsuites>\n<testsuite name="m_spec.bats">\n</testsuite>\n</testsuites>\n' \
        >"${REPORTS}/test-report-matrix-amd/matrix/report.xml"
    run --separate-stderr shard_weights_merge "${REPORTS}" unit matrix
    assert_failure 1
    assert_output ''
    assert_equal "${stderr:-}" "[ERROR] junit report without readable timed cases: ${REPORTS}/test-report-matrix-amd/matrix/report.xml"
}

@test "shard reports name specs relative to their first spec's directory; merged names are tier-relative" {
    _report test-report-unit-1-amd unit 'c_spec.bats:1' '/source/test/unit/log_spec.bats:2'
    printf 'hook\n' >"${REPORTS}/test-report-unit-1-amd/unit/base"
    _report test-report-unit-2-amd unit 'b_spec.bats:3'
    printf '.\n' >"${REPORTS}/test-report-unit-2-amd/unit/base"
    run shard_weights_merge "${REPORTS}" unit
    assert_success
    assert_output "$(printf '%s\n' $'longest/unit/b_spec.bats\t3000' $'longest/unit/hook/c_spec.bats\t1000' \
        $'longest/unit/log_spec.bats\t2000' $'unit/b_spec.bats\t3000' $'unit/hook/c_spec.bats\t1000' \
        $'unit/log_spec.bats\t2000')"
}
