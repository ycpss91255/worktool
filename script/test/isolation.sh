#!/usr/bin/env bash
# isolation.sh - tier isolation guard (issue #835; decision on #824 item 3).
#
# Runs the stages of bare `just test` (HOST_STEPS of script/test/test.sh,
# read by sourcing it - never a second list) in a RANDOM order, and the spec
# files of every tier that takes spec paths (unit, matrix, system,
# acceptance) in a random order too. The seed is printed and `--seed N`
# reproduces the same order exactly. After EACH stage the host is compared
# with the snapshot taken before it; anything new is residue and fails the
# run, named with the stage that left it:
#   - a container or a volume in the host docker engine;
#   - a file in the checkout (`git status --ignored`, untracked included),
#     except under .agents/state/ (test reports and job state);
#   - an entry directly under $HOME;
#   - an entry directly under ${TMPDIR:-/tmp} owned by the caller.
# A stage that fails stops the run (exit 1) and nothing after it runs.
#
# The orders differ from bare `just test`, and a stage given spec paths is
# a narrowed run (test.sh skips its required-spec and plan checks): this
# guard is about order and residue, the normal gates keep those checks.
# The residue check assumes nothing else on the host creates containers or
# files meanwhile, which holds on a CI runner; it runs in the nightly full
# serial run (ADR-0018), not on PRs.
#
# Usage: isolation.sh [--seed N] [--help]
# Exit: 0 clean, 1 a stage failed or left residue, 2 bad arguments.

# shellcheck source-path=SCRIPTDIR/../../lib
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
TEST_SH="${SCRIPT_DIR}/test.sh"
# shellcheck source=log.sh
source "${REPO_ROOT}/lib/log.sh"

SEED=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed)
            if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
                printf 'isolation.sh: --seed requires a non-negative integer (see --help)\n' >&2
                exit 2
            fi
            SEED="$2"; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: just test isolation [--seed N]
Run the bare just test stages and their spec files in a seeded random order
and fail on residue a stage leaves (containers, volumes, checkout files,
HOME and TMPDIR entries). The seed is printed; --seed N reproduces it.
EOF
            exit 0 ;;
        *) printf "isolation.sh: unknown option '%s' (see --help)\n" "$1" >&2; exit 2 ;;
    esac
    shift
done
if [[ -z "${SEED}" ]]; then
    SEED=$(( (RANDOM << 15 | RANDOM) % 1000000 ))
fi

# --- Seeded shuffle ------------------------------------------------------------
# A plain LCG in bash arithmetic, so a seed gives the same order on every
# host (awk's rand differs between implementations).
RNG_STATE="${SEED}"
RNG_OUT=0
# Set RNG_OUT to a number in [0, $1). Runs in the current shell (never in
# a command substitution), so the state carries from one draw to the next.
_rand_below() {
    RNG_STATE=$(( (RNG_STATE * 1103515245 + 12345) % 2147483648 ))
    RNG_OUT=$(( RNG_STATE % $1 ))
}

# Shuffle the lines of stdin (Fisher-Yates) into the array named by $1.
_shuffle_into() {
    local -n _into="$1"
    local _i _tmp
    mapfile -t _into
    for (( _i = ${#_into[@]} - 1; _i > 0; _i-- )); do
        _rand_below $(( _i + 1 ))
        _tmp="${_into[_i]}"
        _into[_i]="${_into[RNG_OUT]}"
        _into[RNG_OUT]="${_tmp}"
    done
}

# --- Residue snapshot ----------------------------------------------------------
_snapshot() {
    local _out="$1" _tmp="${TMPDIR:-/tmp}"
    {
        docker ps -aq --no-trunc | sed 's/^/container /'
        docker volume ls -q | sed 's/^/volume /'
        git -C "${REPO_ROOT}" status --porcelain=v1 --ignored --untracked-files=all \
            | sed -E 's/^.. //' | awk '!/^\.agents\/state\// { print "checkout " $0 }'
        # Plain find + awk (no GNU -printf: the test image is busybox).
        find "${HOME}" -mindepth 1 -maxdepth 1 \
            | awk -v p="${HOME}/" '{ print "home " substr($0, length(p) + 1) }'
        find "${_tmp}" -mindepth 1 -maxdepth 1 -user "$(id -u)" \
            | awk -v p="${_tmp}/" '{ print "tmp " substr($0, length(p) + 1) }'
    } | LC_ALL=C sort -u >"${_out}"
}

# --- Main ------------------------------------------------------------------------
_steps="$(bash -c 'source "$1" && printf "%s\n" "${HOST_STEPS[@]}"' _ "${TEST_SH}")"
[[ -n "${_steps}" ]] || { log_error "isolation: ${TEST_SH} names no stage"; exit 1; }
ORDER=()
_shuffle_into ORDER <<<"${_steps}"

log_info "isolation: seed=${SEED} order: ${ORDER[*]} (reproduce: just test isolation --seed ${SEED})"

WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT

for _step in "${ORDER[@]}"; do
    _args=("--${_step}")
    case "${_step}" in
        unit|matrix|system|acceptance)
            _specs="$(cd -- "${REPO_ROOT}" && find "test/${_step}" -name '*.bats' -type f \
                ! -path 'test/system/real_engine_spec.bats' | LC_ALL=C sort)"
            if [[ -n "${_specs}" ]]; then
                _shuffled=()
                _shuffle_into _shuffled <<<"${_specs}"
                _args+=("${_shuffled[@]}")
            fi ;;
    esac
    _snapshot "${WORK}/before" || { log_error "isolation: cannot take the snapshot before ${_step}"; exit 1; }
    log_info "isolation: running ${_step}"
    _rc=0
    "${TEST_SH}" "${_args[@]}" || _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        log_error "isolation: ${_step} failed (rc=${_rc}); seed=${SEED}"
        exit 1
    fi
    _snapshot "${WORK}/after" || { log_error "isolation: cannot take the snapshot after ${_step}"; exit 1; }
    _new="$(LC_ALL=C comm -13 "${WORK}/before" "${WORK}/after")"
    if [[ -n "${_new}" ]]; then
        log_error "isolation: residue after ${_step} (seed=${SEED}):"
        printf '%s\n' "${_new}" | sed 's/^/  /' >&2
        exit 1
    fi
done
log_info "isolation: clean - ${#ORDER[@]} stages, seed=${SEED}"
