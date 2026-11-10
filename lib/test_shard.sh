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

# Check the records of runner $5 (see test_shard_verdict); $1 root, $2 tier,
# $3 N, $4 a scratch directory. Prints the summary line, returns 1 with
# every reason on stderr.
_test_shard_verdict_runner() {
    local _root="$1" _tier="$2" _n="$3" _scratch="$4" _runner="$5"
    local _i _dir _rec _tap _bad=0 _hash='' _line _key _a _b _plan _sum _oks _tplan _found
    local _specs="${_scratch}/specs.${_runner}"
    : >"${_specs}"
    _found=0
    for _dir in "${_root}/test-report-${_tier}-"*"-${_runner}"; do
        [[ -d "${_dir}" ]] && _found=$((_found + 1))
    done
    if [[ "${_found}" -ne "${_n}" ]]; then
        log_error "${_tier} (${_runner}): ${_found} shard record(s) found, ${_n} expected"
        _bad=1
    fi
    for ((_i = 1; _i <= _n; _i++)); do
        _rec="${_root}/test-report-${_tier}-${_i}-${_runner}/${_tier}/shard.tsv"
        _tap="${_rec%.tsv}.tap"
        if [[ ! -f "${_rec}" || ! -f "${_tap}" ]]; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} left no record (missing shard fails closed)"
            _bad=1
            continue
        fi
        _plan='' _sum=0
        local _shard_seen='' _weights_seen=''
        while IFS=$'\t' read -r _key _a _b; do
            case "${_key}" in
                shard) _shard_seen="${_a}" ;;
                weights) _weights_seen="${_a}" ;;
                spec)
                    if [[ -z "${_a}" || ! "${_b}" =~ ^[0-9]+$ ]]; then
                        log_error "${_tier} (${_runner}): shard ${_i}/${_n}: malformed spec row"
                        _bad=1
                        continue
                    fi
                    printf '%s\t%s\t%s\n' "${_a}" "${_b}" "${_i}" >>"${_specs}"
                    _sum=$((_sum + _b))
                    ;;
                plan) _plan="${_a}" ;;
                *)
                    log_error "${_tier} (${_runner}): shard ${_i}/${_n}: unknown record row '${_key}'"
                    _bad=1
                    ;;
            esac
        done <"${_rec}"
        if [[ "${_shard_seen}" != "${_i}/${_n}" ]]; then
            log_error "${_tier} (${_runner}): record ${_i} says shard '${_shard_seen}', expected ${_i}/${_n}"
            _bad=1
        fi
        if [[ -z "${_weights_seen}" ]]; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} records no weights hash"
            _bad=1
        elif [[ -z "${_hash}" ]]; then
            _hash="${_weights_seen}"
        elif [[ "${_weights_seen}" != "${_hash}" ]]; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} used other weights (${_weights_seen}, not ${_hash})"
            _bad=1
        fi
        if [[ ! "${_plan}" =~ ^[0-9]+$ || "${_plan}" -ne "${_sum}" ]]; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} plan '${_plan}' is not the sum of its specs' cases (${_sum})"
            _bad=1
        fi
        _tplan="$(awk '/^1\.\.[0-9]+$/ { sub(/^1\.\./, ""); print; exit }' "${_tap}")" || _tplan=''
        if [[ "${_tplan}" != "${_plan}" ]]; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} TAP plan '${_tplan}' differs from its record (${_plan})"
            _bad=1
        fi
        _oks="$(grep -cE '^ok [0-9]+ ' "${_tap}")" || _oks=0
        if [[ "${_oks}" != "${_plan}" ]]; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} TAP has ${_oks} ok line(s) for a plan of ${_plan}"
            _bad=1
        fi
        if grep -qE '^not ok ' "${_tap}"; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} TAP has a failed case"
            _bad=1
        fi
        if grep -qE '^ok [0-9]+ .*# skip' "${_tap}"; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} TAP has a skipped case - a skipped case is not green"
            _bad=1
        fi
    done
    # Pairwise disjoint, union = the tier list.
    _line="$(cut -f1 "${_specs}" | LC_ALL=C sort | uniq -d)"
    if [[ -n "${_line}" ]]; then
        log_error "${_tier} (${_runner}): spec(s) in more than one shard: $(tr '\n' ' ' <<<"${_line}")"
        _bad=1
    fi
    _line="$(LC_ALL=C comm -23 <(LC_ALL=C sort -u "${_scratch}/list") <(cut -f1 "${_specs}" | LC_ALL=C sort -u))"
    if [[ -n "${_line}" ]]; then
        log_error "${_tier} (${_runner}): spec(s) no shard ran: $(tr '\n' ' ' <<<"${_line}")"
        _bad=1
    fi
    _line="$(LC_ALL=C comm -13 <(LC_ALL=C sort -u "${_scratch}/list") <(cut -f1 "${_specs}" | LC_ALL=C sort -u))"
    if [[ -n "${_line}" ]]; then
        log_error "${_tier} (${_runner}): shard spec(s) not in the tier: $(tr '\n' ' ' <<<"${_line}")"
        _bad=1
    fi
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] || continue
        if ! awk -F '\t' -v s="${_line}" '$1 == s && $2 > 0 { f = 1 } END { exit !f }' "${_specs}"; then
            log_error "${_tier} (${_runner}) required spec missing or without cases in the union: ${_line}"
            _bad=1
        fi
    done <"${_scratch}/required"
    [[ "${_bad}" -eq 0 ]] || return 1
    printf '%s (%s): %d shard(s), %d spec(s), %d case(s): the union is the whole tier\n' \
        "${_tier}" "${_runner}" "${_n}" "$(wc -l <"${_specs}")" \
        "$(awk -F '\t' '{ t += $2 } END { print t + 0 }' "${_specs}")"
}

test_shard_verdict() {
    local _root="$1" _tier="$2" _n="$3" _list="$4" _required="$5" _scratch _runner _bad=0
    if (($# < 6)); then
        log_error "test_shard_verdict: expected <root> <tier> <N> <list_file> <required_file> <runner>..."
        return 1
    fi
    shift 5
    if [[ ! "${_n}" =~ ^[1-9][0-9]*$ ]]; then
        log_error "test_shard_verdict: shard count must be a positive integer, got '${_n}'."
        return 1
    fi
    if [[ ! -s "${_list}" || ! -s "${_required}" ]]; then
        log_error "test_shard_verdict: empty tier or required list (fail closed)."
        return 1
    fi
    _scratch="$(mktemp -d)" || return 1
    if ! cp -- "${_list}" "${_scratch}/list" || ! cp -- "${_required}" "${_scratch}/required"; then
        rm -rf -- "${_scratch}"
        return 1
    fi
    for _runner in "$@"; do
        _test_shard_verdict_runner "${_root}" "${_tier}" "${_n}" "${_scratch}" "${_runner}" || _bad=1
    done
    rm -rf -- "${_scratch}"
    return "${_bad}"
}
