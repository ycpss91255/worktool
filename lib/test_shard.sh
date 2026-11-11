#!/usr/bin/env bash
# lib/test_shard.sh - split a bats tier into weighted shards, and the union
# verdict over the shards' records (issue #831).
# Source this library; it sets no shell options and prints only its results.
#
# A sharded tier must stay exactly as strict as the whole tier: every spec
# runs in exactly one shard, and the whole-tier rules (every required spec
# present and non-empty, the plan covering every case, nothing failed,
# no unexpected skips) are applied to the union of the shards. Every gap fails
# closed.
#
# Public API:
#   test_shard_assign <N> [<jobs>]         (rows on stdin)
#       stdin: "<weight><TAB><spec>[<TAB><longest>]" per spec of the tier
#       (weight = a non-negative integer, e.g. milliseconds; longest = its
#       longest single case, default 0). jobs = the cases bats runs at
#       once (default 1).
#       -> prints "<shard><TAB><spec>" per spec, in assignment order:
#          by max(weight, jobs x longest) descending (ties by spec path, C
#          collation), each to the shard whose estimated wall time
#          max(load / jobs, longest case in it) is smallest with it (ties:
#          smaller load, then the lowest index; #868). With jobs 1 and no
#          longest column this is plain LPT by weight. Deterministic:
#          depends only on the rows and jobs. Returns 1 on a bad N or jobs,
#          or a malformed row.
#   test_shard_rows <tier> <tier_dir> <weights_file or "">  (specs on stdin)
#       stdin: tier-relative specs, one per line.
#       -> prints the "<weight><TAB><spec><TAB><longest>" row
#          test_shard_assign reads, per spec: weight and longest from the
#          weights file's "<tier>/<spec>" and "longest/<tier>/<spec>" rows
#          (shard_weights_merge); a spec without a weight weighs its @test
#          count x 1000, without a longest row 0. A spec that sets
#          BATS_NO_PARALLELIZE_WITHIN_FILE runs case by case, so its
#          longest is its whole weight (#868).
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
#   test_shard_records_await <max_polls> <poll_seconds> <tier> <N> <runner>... -- <fetch...>
#       runs <fetch...>, which prints the run's artifact listing as
#       "<id><TAB><name><TAB><created_at>" rows, until every record
#       test-report-<tier>-<i>-<runner> (i = 1..N, each runner) is listed;
#       while one is not, it sleeps <poll_seconds> and fetches again, at
#       most <max_polls> times (#890: a record finalized seconds before the
#       verdict starts may not be listed yet). A name listed more than once
#       (a re-run) counts by its newest created_at.
#       -> prints "<id><TAB><name>" per listed record, runner by runner and
#          i ascending, and returns 0 when all are listed; 1 when one is
#          still missing after the last wait (the listed ones are still
#          printed, each missing name on stderr), when a fetch fails or on
#          bad arguments. The library never calls the GitHub API: the
#          caller passes the fetch.
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

test_shard_rows() {
    local _tier="$1" _dir="$2" _file="$3" _rel _w _l _n _key
    local -A _weight=() _longest=()
    if [[ -n "${_file}" ]]; then
        while IFS=$'\t' read -r _key _w; do
            [[ "${_w}" =~ ^[0-9]+$ ]] || continue
            case "${_key}" in
                "${_tier}/"*) _weight["${_key#"${_tier}/"}"]="${_w}" ;;
                "longest/${_tier}/"*) _longest["${_key#"longest/${_tier}/"}"]="${_w}" ;;
            esac
        done <"${_file}"
    fi
    while IFS= read -r _rel; do
        if [[ -n "${_weight[${_rel}]+set}" ]]; then
            _w="${_weight[${_rel}]}"
        else
            _n="$(grep -c '^@test ' "${_dir}/${_rel}")" || _n=0
            _w="$((_n * 1000))"
        fi
        _l="${_longest[${_rel}]:-0}"
        if grep -qE '^[[:space:]]*export BATS_NO_PARALLELIZE_WITHIN_FILE=true' "${_dir}/${_rel}"; then
            _l="${_w}"
        fi
        printf '%s\t%s\t%s\n' "${_w}" "${_rel}" "${_l}"
    done
}

test_shard_assign() {
    local _n="${1:-}" _j="${2:-1}" _rows
    if [[ ! "${_n}" =~ ^[1-9][0-9]*$ ]]; then
        log_error "test_shard_assign: shard count must be a positive integer, got '${_n}'."
        return 1
    fi
    if [[ ! "${_j}" =~ ^[1-9][0-9]*$ ]]; then
        log_error "test_shard_assign: jobs must be a positive integer, got '${_j}'."
        return 1
    fi
    _rows="$(cat)" || return 1
    if [[ -n "${_rows}" ]] && grep -vqE $'^[0-9]+\t[^\t]+(\t[0-9]+)?$' <<<"${_rows}"; then
        log_error "test_shard_assign: malformed weight row (expected <weight><TAB><spec>[<TAB><longest case>])."
        return 1
    fi
    [[ -n "${_rows}" ]] || return 0
    # key = max(weight, jobs x longest case): a spec whose one case outlasts
    # its share of the slots is placed first. A shard's estimated wall time
    # is max(load / jobs, its longest case); each spec goes to the shard
    # whose estimate stays smallest with it (ties: smaller load, then the
    # lowest index). With jobs 1 and no longest case this is plain LPT.
    awk -F '\t' -v OFS='\t' -v j="${_j}" '
        { l = ($3 == "" ? 0 : $3); k = (j * l > $1 ? j * l : $1); print k, $2, $1, l }' <<<"${_rows}" \
        | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 \
        | awk -F '\t' -v n="${_n}" -v j="${_j}" '
        BEGIN { for (i = 1; i <= n; i++) { load[i] = 0; top[i] = 0 } }
        {
            best = 0
            for (i = 1; i <= n; i++) {
                e = (load[i] + $3) / j
                m = (top[i] > $4 ? top[i] : $4)
                if (m > e) e = m
                if (best == 0 || e < be || (e == be && load[i] < load[best])) { best = i; be = e }
            }
            load[best] += $3
            if ($4 > top[best]) top[best] = $4
            printf "%d\t%s\n", best, $2
        }'
}

# Shared whole-tier and shard-union policy: only the named unit CPU
# repro cases may skip while their stress opt-in is disabled.
test_shard_has_unexpected_skip() {
    awk -v tier="$1" -v stress="${WORKTOOL_STRESS:-}" '
        /^ok [0-9]+ .*# skip/ {
            sub(/^ok [0-9]+ /, "")
            reason = " # skip set WORKTOOL_STRESS=1 to run CPU repro"
            # Exempt names come from test/unit/verify_run_signal_spec.bats and
            # test/unit/verify_realbox_spec.bats.
            if (tier == "unit" && stress != "1" &&
                ($0 == "verify_run: HUP under CPU load always finishes before cleanup" reason ||
                 $0 == "5.1: group HUP under CPU load finishes before cleanup during assemble and bench" reason ||
                 $0 == "timeout cleanup: TERM-ignoring just descendant under CPU load" reason)) next
            unexpected = 1
        }
        END { exit !unexpected }
    ' "$2"
}

# Check the records of runner $5 (see test_shard_verdict); $1 root, $2 tier,
# $3 N, $4 a scratch directory. Prints the summary line, returns 1 with
# every reason on stderr.
_test_shard_verdict_runner() {
    local _root="$1" _tier="$2" _n="$3" _scratch="$4" _runner="$5"
    local _i _dir _rec _tap _bad=0 _hash='' _line _key _a _b _plan _sum _oks _tplan _found _skip_rc
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
        _skip_rc=0
        test_shard_has_unexpected_skip "${_tier}" "${_tap}" || _skip_rc=$?
        if [[ "${_skip_rc}" -eq 0 ]]; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} TAP has a skipped case - a skipped case is not green"
            _bad=1
        elif [[ "${_skip_rc}" -ne 1 ]]; then
            log_error "${_tier} (${_runner}): shard ${_i}/${_n} TAP skip check failed (exit ${_skip_rc})"
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

# Print "<id>\t<name>" for every expected record name (one per line in the
# file $1) the listing on stdin holds, newest created_at first wins; return
# 1 when one is missing, its name in the file $2.
_test_shard_records_pick() {
    awk -F '\t' -v missing="$2" '
        NR == FNR { want[$1] = 1; order[++n] = $1; next }
        ($2 in want) && (!($2 in at) || $3 > at[$2]) { at[$2] = $3; id[$2] = $1 }
        END {
            bad = 0
            printf "" > missing
            for (i = 1; i <= n; i++) {
                if (order[i] in id) printf "%s\t%s\n", id[order[i]], order[i]
                else { print order[i] >> missing; bad = 1 }
            }
            exit bad
        }' "$1" -
}

test_shard_records_await() {
    local _polls="${1:-}" _secs="${2:-}" _tier="${3:-}" _n="${4:-}" _runners=() _scratch _listing _picked _i _j _rc
    if (($# >= 4)); then
        shift 4
        while (($# > 0)) && [[ "$1" != -- ]]; do
            _runners+=("$1")
            shift
        done
    fi
    if [[ ! "${_polls}" =~ ^[0-9]+$ || ! "${_secs}" =~ ^[1-9][0-9]*$ || -z "${_tier}" \
        || ! "${_n}" =~ ^[1-9][0-9]*$ || ${#_runners[@]} -eq 0 || "${1:-}" != -- || $# -lt 2 ]]; then
        log_error 'test_shard_records_await: expected <max_polls> <poll_seconds> <tier> <N> <runner>... -- <fetch...> (fail closed).'
        return 1
    fi
    shift
    _scratch="$(mktemp -d)" || return 1
    for _j in "${_runners[@]}"; do
        for ((_i = 1; _i <= _n; _i++)); do
            printf 'test-report-%s-%s-%s\n' "${_tier}" "${_i}" "${_j}"
        done
    done >"${_scratch}/want"
    for ((_i = 0; ; _i++)); do
        if ! _listing="$("$@")"; then
            log_error 'test_shard_records_await: listing the artifacts failed (fail closed).'
            rm -rf -- "${_scratch}"
            return 1
        fi
        _rc=0
        _picked="$(_test_shard_records_pick "${_scratch}/want" "${_scratch}/missing" <<<"${_listing}")" || _rc=$?
        if ((_rc == 0)); then
            printf '%s\n' "${_picked}"
            rm -rf -- "${_scratch}"
            return 0
        fi
        if ((_i >= _polls)); then
            [[ -z "${_picked}" ]] || printf '%s\n' "${_picked}"
            while IFS= read -r _j; do
                log_error "test_shard_records_await: ${_j} not listed after ${_polls} waits of ${_secs}s (fail closed)."
            done <"${_scratch}/missing"
            rm -rf -- "${_scratch}"
            return 1
        fi
        log_info "test_shard_records_await: $(wc -l <"${_scratch}/missing") record(s) not listed yet, waiting ${_secs}s (${_i}/${_polls})."
        sleep "${_secs}"
    done
}
