#!/usr/bin/env bash
# lib/shard_weights.sh - shard weights from the bats junit reports (issue #827).
# Source this library; it sets no shell options and prints only its result.
# Public API:
#   shard_weights_merge <root> <tier>...
#       -> read every <root>/<artifact>/<tier>/report.xml of the listed
#          tiers (one per tier and runner, written by test.sh with
#          WORKTOOL_TEST_REPORT_DIR) and print one line per spec,
#          "<tier>/<spec><TAB><milliseconds>", sorted by spec: the case
#          times of the spec summed within a report, the largest sum over
#          the reports kept (the slower runner decides). A listed tier
#          without any report, or a report without a single timed case,
#          returns 1 with the reason on stderr: a partial table is never
#          written as the weights.
# The weights only order and balance work; they never decide what runs.

# shellcheck source-path=SCRIPTDIR
_SHARD_WEIGHTS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_SHARD_WEIGHTS_LIB_DIR}/log.sh"

# Print "<spec><TAB><milliseconds>" per testsuite of junit report $1.
_shard_weights_report() {
    awk '
        function attr(line, key,    m) {
            if (match(line, " " key "=\"[^\"]*\"")) {
                m = substr(line, RSTART + length(key) + 3, RLENGTH - length(key) - 4)
                gsub(/&lt;/, "<", m); gsub(/&gt;/, ">", m); gsub(/&quot;/, "\"", m)
                gsub(/&apos;/, "\047", m); gsub(/&amp;/, "\\&", m)
                return m
            }
            return ""
        }
        /<testsuite / { suite = attr($0, "name"); if (!(suite in ms)) { ms[suite] = 0; order[++n] = suite } }
        /<testcase / {
            t = attr($0, "time")
            if (suite == "" || t !~ /^[0-9]+(\.[0-9]+)?$/) { bad = 1; exit 1 }
            ms[suite] += t * 1000; cases++
        }
        END {
            if (bad || cases == 0) exit 1
            for (i = 1; i <= n; i++) printf "%s\t%d\n", order[i], ms[order[i]] + 0.5
        }
    ' "$1"
}

shard_weights_merge() {
    local _root="$1" _tier _report _rows _found _suites
    shift
    [[ $# -gt 0 ]] || { log_error "shard_weights_merge: no tier given"; return 1; }
    _rows="$(
        for _tier in "$@"; do
            _found=0
            for _report in "${_root}"/*/"${_tier}"/report.xml; do
                [[ -f "${_report}" ]] || continue
                _found=1
                _suites="$(_shard_weights_report "${_report}")" \
                    || { log_error "junit report without readable timed cases: ${_report}"; exit 1; }
                printf '%s\n' "${_suites}" | sed "s|^|${_tier}/|"
            done
            [[ "${_found}" -eq 1 ]] \
                || { log_error "no junit report for tier ${_tier} under ${_root}"; exit 1; }
        done
    )" || return 1
    awk -F '\t' '{ if (!($1 in max) || $2 > max[$1]) max[$1] = $2 }
        END { for (s in max) printf "%s\t%d\n", s, max[s] }' <<<"${_rows}" | LC_ALL=C sort
}
