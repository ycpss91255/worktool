#!/usr/bin/env bash
# lib/test_shard.sh - split a bats tier into weighted shards, and the union
# verdict over the shards' records (issue #831).
# Source this library; it sets no shell options and prints only its results.
#
# A sharded tier must stay exactly as strict as the whole tier: every spec
# runs in exactly one shard, and the whole-tier rules (every required spec
# present and non-empty, the plan covering every case, nothing failed,
# nothing skipped) are applied to the union of the shards. Every gap fails
# closed.
#
# Public API:
#   test_shard_assign <N>                  (rows on stdin)
#       stdin: "<weight><TAB><spec>" per spec of the tier (weight = a
#       non-negative integer, e.g. milliseconds).
#       -> prints "<shard><TAB><spec>" per spec, in assignment order:
#          heaviest first (ties by spec path, C collation), each to the
#          shard with the smallest load so far (ties to the lowest index).
#          Deterministic: depends only on the rows. Returns 1 on a bad N or
#          a malformed row.
#   test_shard_verdict <root> <tier> <N> <list_file> <required_file> <runner>...
#       <root>/test-report-<tier>-<i>-<runner>/<tier>/shard.tsv and
#       shard.tap are the records test.sh --shard writes (see test.sh).
#       <list_file>: every spec of the tier, tier-relative, one per line,
#       taken from the verdict's own checkout; <required_file>: the
#       tier's required specs, tier-relative.
#       -> 0 when, for every runner: exactly N records exist, record i says
#          shard i/N, all carry the same weights hash, their specs are
#          pairwise disjoint and their union is exactly <list_file>, every
#          required spec is in the union with at least one case, and every
#          record's plan equals the sum of its specs' case counts while its
#          TAP holds exactly that many `ok` lines, no `not ok` and no
#          `# skip`. Otherwise 1, every reason on stderr.
#
# Record format (shard.tsv, tab separated):
#   shard   <i>/<N>
#   weights <sha256 of the weights file, or "none">
#   spec    <tier-relative spec>  <case count>     (one per spec)
#   plan    <TAP plan of the shard>

# shellcheck source-path=SCRIPTDIR
_TEST_SHARD_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_TEST_SHARD_LIB_DIR}/log.sh"

test_shard_assign() {
    local _n="${1:-}" _rows
    if [[ ! "${_n}" =~ ^[1-9][0-9]*$ ]]; then
        log_error "test_shard_assign: shard count must be a positive integer, got '${_n}'."
        return 1
    fi
    _rows="$(cat)" || return 1
    if [[ -n "${_rows}" ]] && grep -vqE $'^[0-9]+\t[^\t]+$' <<<"${_rows}"; then
        log_error "test_shard_assign: malformed weight row (expected <weight><TAB><spec>)."
        return 1
    fi
    [[ -n "${_rows}" ]] || return 0
    LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 <<<"${_rows}" | awk -F '\t' -v n="${_n}" '
        BEGIN { for (i = 1; i <= n; i++) load[i] = 0 }
        {
            best = 1
            for (i = 2; i <= n; i++) if (load[i] < load[best]) best = i
            load[best] += $1
            printf "%d\t%s\n", best, $2
        }'
}
