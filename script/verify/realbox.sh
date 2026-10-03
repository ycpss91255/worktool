#!/usr/bin/env bash
# realbox.sh - the real-machine (group `realbox`) acceptance items of M3:
# 5.1, 5.2 and 5.3 of doc/acceptance.md, as a script instead of as shell logic
# embedded in the document.
#
# WHY THIS EXISTS
#   The M3 checklist carried three long bash blocks the maintainer was told to
#   paste verbatim. A document cannot be linted and cannot be tested, and the
#   blocks had rotted in one specific direction: every `$(...)` whose status
#   nobody read, every pipeline whose first stage could die unnoticed, and
#   every count that could not tell "nothing matched" from "the input was
#   never there" is a way for a FAILURE TO READ AS A PASS. Removing that is
#   the point of this script, so these are rules, not style:
#
#     - every command substitution is assigned first and its status checked
#       before its value is used (an empty string is never evidence);
#     - every pipeline is judged by PIPESTATUS or by `set -o pipefail`, never
#       by its last stage alone;
#     - `distrobox list` is captured before it is parsed, so a broken list
#       cannot become "the box does not exist" - the one answer that would let
#       this script create or destroy something it must not touch;
#     - `grep`'s exit 1 ("matched nothing") is kept apart from its exit >= 2
#       ("could not read the file"), and a count is validated as a number
#       before it is compared;
#     - anything this environment cannot do (a missing tool, no terminal for
#       the one subjective check) is REPORTED and exits non-zero. Nothing is
#       skipped quietly.
#
#   The primitives that enforce this live in lib/guard.sh; the config backup
#   and restore machinery of 5.2 lives in lib/config_backup.sh.
#
# GROUP realbox
#   These items build a real distrobox, rewrite the real ghostty / worktool
#   configs under $XDG_CONFIG_HOME and the real distrobox.conf, and comment on
#   a GitHub issue, so:
#     - the backup set is the WHOLE set of files `just box setup` can write,
#       and 5.2 refuses to start when any of them cannot be backed up: the
#       both Ghostty files and distrobox.conf may be changed by setup;
#     - they refuse to run without the explicit --allow-real-box opt-in;
#     - they refuse when a box named `dev` already exists, and never delete a
#       box this run did not create;
#     - ownership is claimed BEFORE anything can exist (the marker means
#       "assemble was ATTEMPTED", not "assemble returned 0"), so an interrupt
#       mid-create still leaves cleanup able to remove the box;
#     - cleanup and restore run on EXIT INT TERM HUP, and a failed cleanup
#       fails the whole run.
#
# USAGE
#   script/verify/realbox.sh --allow-real-box            # 5.1, 5.2, 5.3
#   script/verify/realbox.sh --allow-real-box 5.1        # one item
#   script/verify/realbox.sh --allow-real-box 5.2.3      # restore only
#   script/verify/realbox.sh --help
#
#   With no item the three items run in order and stop at the first failure.
#   Every check prints the same human-readable lines doc/acceptance.md shows.
#
# This script owns its option validation: an unknown option is refused with
# `realbox.sh: unknown option '<x>' (see --help)` on stderr, exit 2.
#
# Exit codes: 0 pass, 1 a check failed, 2 the command line or the opt-in is
# wrong (nothing ran); 3 a required tool is unavailable.
#
# Expected failures are handled explicitly; checks run in conditionals so
# their own exit codes and diagnostics decide the acceptance verdict.
# shellcheck source-path=.
set -euo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
LIB_DIR="${REPO_ROOT}/lib"

# shellcheck source=lib/guard.sh
source "${LIB_DIR}/guard.sh"
# shellcheck source=lib/manifest.sh
source "${LIB_DIR}/manifest.sh"
# shellcheck source=script/verify/config_backup_paths.sh
source "${SCRIPT_DIR}/config_backup_paths.sh"

# --- Defaults (overridable on the command line) ------------------------------
REPO="ycpss91255/worktool"
ISSUE="22"
BOX="$(manifest_name "${REPO_ROOT}/box/dev.ini")" || exit 1
DECOY_IMAGE="ubuntu:24.04"
OPT_IN=0

# Every external call is wrapped in `timeout`, so a hung distrobox / just / gh
# fails the run instead of stalling it forever.
TIMEOUT_SHORT=180
TIMEOUT_LONG=1800

# The enter-latency budget of M3 5.1, in milliseconds. It is BOTH what `just
# box bench` is handed as --max-ms and what this script compares the measured
# shell median against, so the threshold the document publishes and the
# threshold the run enforces cannot drift apart.
BENCH_MAX_MS=300
BENCH_RUNS=10

# The items `no argument` runs, in order.
ITEMS_ALL=(5.1 5.2 5.3)

# --- Usage -------------------------------------------------------------------
_usage_error() {
    printf 'realbox.sh: %s (see --help)\n' "$1" >&2
}

_usage() {
    cat >&2 <<'EOF'
Usage: realbox.sh --allow-real-box [options] [item ...]

Run the real-machine (realbox) acceptance items of M3 from doc/acceptance.md
on THIS machine. With no item, 5.1, 5.2 and 5.3 run in order and stop at the
first failure.

Items:
  5.1     Real-machine bench: build the box, measure the enter latency,
          publish the three numbers to the issue and read that exact comment
          back. Removes the box it created, on success and on interrupt.
  5.2     Ghostty window chain: back up every config `just box setup` can
          write (Ghostty legacy config, config.ghostty, the worktool state file
          and distrobox.conf), apply the managed blocks, prove the user's own
          content survived, reload an already running Ghostty, then verify
          the new fish mount namespace differs from the host at the terminal,
          then restore everything and remove the box.
  5.2.1   5.2 step 1 only (back up; refuses unless the whole set is coverable).
  5.2.2   5.2 step 2 only (re-validate the published backup, apply, then
          check the user's own content survived).
  5.2.3   5.2 step 3 only (restore). The recovery entry: safe to run alone
          after an interrupt, and a no-op when there is no backup.
  5.3     Negative: with a `dev` box present, prove 5.1 and 5.2 step 2 refuse
          instead of deleting it. Creates and removes its own decoy box.

Options:
  --allow-real-box   Required. Says you accept that this run creates and
                     removes a distrobox, rewrites the ghostty and worktool
                     configs under $XDG_CONFIG_HOME, and comments on an issue.
  --repo OWNER/NAME  GitHub repository for 5.1 (default: ycpss91255/worktool).
  --issue N          Issue number 5.1 posts to (default: 22).
  --box NAME         Box name (default: dev).
  --image REF        Image 5.3 builds its decoy box from (default: ubuntu:24.04).
  -h, --help         Show this help and exit 0.

Exit: 0 pass, 1 a check failed, 2 bad command line or missing --allow-real-box,
3 a required tool is unavailable.
EOF
}

# --- Wrappers around the two long-running tools ------------------------------

# `just` always runs from the repo root, so the root justfile is the one found
# whatever directory the maintainer invoked this script from.
_just() {
    (cd -- "${REPO_ROOT}" && timeout -k 10 "${TIMEOUT_LONG}" just "$@")
}

# Refuse before creating anything: a box we did not make is never ours to
# delete. $1 is the tail of the message (it differs between 5.1 and 5.2).
_refuse_preexisting_box() {
    local _e
    guard_box_exists "${BOX}" "${TIMEOUT_SHORT}"
    _e=$?
    case "${_e}" in
        2)
            guard_fail "cannot tell whether '${BOX}' exists -- distrobox list failed or its output could not be parsed; refusing to create or delete anything"
            return 1
            ;;
        0)
            guard_fail "a distrobox named '${BOX}' already exists -- refusing. $1"
            return 1
            ;;
    esac
    return 0
}

# Remove a box this run claimed, then decide only on the final existence
# check: `distrobox rm` legitimately fails when there is nothing to remove
# (interrupted before the box existed), and "cannot tell" (2) is not "gone" (1).
_drop_owned_box() {
    local _e
    guard_timed "${TIMEOUT_SHORT}" distrobox rm -f "${BOX}" >/dev/null 2>&1
    guard_box_exists "${BOX}" "${TIMEOUT_SHORT}"
    _e=$?
    [[ "${_e}" -eq 1 ]]
}

# Report and remove only the isolated HOME assigned to this run's box.
_box_state_report() {
    local _when="$1" _home="$2" _h=0 _t=0
    [[ ! -e "${_home}" && ! -L "${_home}" ]] || _h=1
    [[ ! -e "${_home}/.cache/tmux" && ! -L "${_home}/.cache/tmux" ]] || _t=1
    printf 'box-state %s: home=%s tmux=%s\n' "${_when}" "${_h}" "${_t}"
    [[ "${_when}" != after-cleanup || "${_h}" -eq 0 ]]
}

_box_state_cleanup() {
    local _home="$1" _rc=0
    _box_state_report before-cleanup "${_home}" || return 1
    if [[ -e "${_home}" || -L "${_home}" ]]; then
        rm -rf -- "${_home}" || _rc=1
    fi
    _box_state_report after-cleanup "${_home}" || _rc=1
    [[ "${_rc}" -eq 0 ]] || guard_fail "box HOME state survived cleanup at ${_home}"
    return "${_rc}"
}

# Keep a NUL-delimited inventory: filenames and sockets need no text parsing.
_host_state_list() {
    local _path="${HOME}/${BOX}-box"
    if [[ -e "${_path}" || -L "${_path}" ]]; then
        find "${_path}" -depth -print0 || return 1
    fi
}

_host_state_snapshot() {
    local _present=0
    guard_require find sort cmp || return $?
    [[ ! -e "${HOME}/${BOX}-box" && ! -L "${HOME}/${BOX}-box" ]] || _present=1
    printf 'host-state baseline: present=%s\n' "${_present}"
    _host_state_list | sort -z >"$1/host-state-baseline" \
        || { guard_fail "cannot inventory host default HOME"; return 1; }
}

_host_state_new() {
    local _dir="$1" _path
    local -A _existing=()
    [[ -f "${_dir}/host-state-baseline" ]] \
        || { guard_fail "no host state baseline; refusing to delete user data"; return 1; }
    while IFS= read -r -d '' _path; do
        _existing["${_path}"]=1
    done <"${_dir}/host-state-baseline"
    _host_state_list >"${_dir}/host-state-current" \
        || { guard_fail "cannot inspect host default HOME"; return 1; }
    : >"${_dir}/host-state-new" || return 1
    while IFS= read -r -d '' _path; do
        [[ -n "${_existing[${_path}]+present}" ]] && continue
        printf '%s\0' "${_path}" >>"${_dir}/host-state-new" || return 1
    done <"${_dir}/host-state-current"
}

_host_state_report() {
    local _dir="$1" _when="$2" _path _n=0
    _host_state_new "${_dir}" || return 1
    while IFS= read -r -d '' _path; do _n=$((_n + 1)); done <"${_dir}/host-state-new"
    printf 'host-state %s: new=%s\n' "${_when}" "${_n}"
    [[ "${_when}" != after-cleanup || "${_n}" -eq 0 ]]
}

_host_state_cleanup() {
    local _dir="$1" _path _rc=0
    _host_state_report "${_dir}" before-cleanup || return 1
    # Depth order removes children first; never recursively remove a directory
    # that could contain pre-existing user data. Symlinks are never followed.
    while IFS= read -r -d '' _path; do
        if [[ -d "${_path}" && ! -L "${_path}" ]]; then
            rmdir -- "${_path}" || _rc=1
        else
            rm -f -- "${_path}" || _rc=1
        fi
    done <"${_dir}/host-state-new"
    _host_state_report "${_dir}" after-cleanup || _rc=1
    sort -z "${_dir}/host-state-current" >"${_dir}/host-state-after" || return 1
    cmp -s "${_dir}/host-state-baseline" "${_dir}/host-state-after" || _rc=1
    [[ "${_rc}" -eq 0 ]] || guard_fail "host default HOME did not return to its baseline"
    return "${_rc}"
}

# --- Cleanup stack -----------------------------------------------------------
# Items push a token; the token is run either explicitly (normal path) or by
# the EXIT / INT / TERM / HUP trap (interrupt path), in reverse order. A
# cleanup that fails makes the whole run non-zero.
CLEANUP_STACK=()

_cleanup_push() { CLEANUP_STACK+=("$1"); }

# Dispatch by token rather than by indirect function name, so every cleanup
# has a visible call site.
_cleanup_run() {
    case "$1" in
        51) _51_cleanup ;;
        52-abort-backup) cfgbk_abort ;;
        52-restore) _52_step3_restore ;;
        53) _53_cleanup ;;
        *) guard_fail "internal: unknown cleanup token '$1'"; return 1 ;;
    esac
}

# Pop the top token and run it; returns its status (0 when the stack is empty).
_cleanup_pop_run() {
    local _n="${#CLEANUP_STACK[@]}" _tok
    [[ "${_n}" -gt 0 ]] || return 0
    _tok="${CLEANUP_STACK[$((_n - 1))]}"
    unset "CLEANUP_STACK[$((_n - 1))]"
    _cleanup_run "${_tok}"
}

# Drop the top token without running it (what it would undo must survive).
_cleanup_drop() {
    local _n="${#CLEANUP_STACK[@]}"
    [[ "${_n}" -gt 0 ]] || return 0
    unset "CLEANUP_STACK[$((_n - 1))]"
}

_on_exit() {
    local _st=$? _crc=0
    trap - EXIT INT TERM HUP
    while [[ "${#CLEANUP_STACK[@]}" -gt 0 ]]; do
        _cleanup_pop_run || _crc=1
    done
    [[ "${_st}" -eq 0 ]] || exit "${_st}"
    exit "${_crc}"
}

# =============================================================================
# 5.1  real-machine bench
# =============================================================================
_51_W=""
_51_CREATED=0

_51_cleanup() {
    local _crc=0
    if [[ "${_51_CREATED}" -eq 1 ]]; then
        _drop_owned_box || _crc=1
    fi
    printf 'cleanup-rc=%s\n' "${_crc}"
    [[ "${_crc}" -eq 0 ]] || guard_fail "box '${BOX}' survived cleanup -- remove it by hand"
    if [[ "${_crc}" -eq 0 && -n "${_51_W}" ]]; then
        _host_state_cleanup "${_51_W}" || return 1
        _box_state_cleanup "${_51_W}/box-home" || return 1
        rm -rf -- "${_51_W}" || _crc=1
    fi
    return "${_crc}"
}

# True when decimal $1 <= decimal $2.
#
# The measurements are milliseconds with a fraction, and the shell has no
# float arithmetic; `awk` would do it, but this spec's own point is that a
# broken external tool must not decide a verdict, and awk is already the tool
# whose failure 5.1 treats as "cannot tell". So the comparison is done here:
# the integer parts as integers, then the fractions padded to a common width
# and compared as integers. `10#` keeps a leading zero from being read as
# octal. Both arguments have already been matched against the strict
# `[0-9]+(\.[0-9]+)?` shape below, so there is nothing else to parse.
_num_le() {
    local _ai="${1%%.*}" _bi="${2%%.*}" _af="" _bf=""
    [[ "$1" == *.* ]] && _af="${1#*.}"
    [[ "$2" == *.* ]] && _bf="${2#*.}"
    ((10#${_ai:-0} < 10#${_bi:-0})) && return 0
    ((10#${_ai:-0} > 10#${_bi:-0})) && return 1
    while [[ "${#_af}" -lt "${#_bf}" ]]; do _af="${_af}0"; done
    while [[ "${#_bf}" -lt "${#_af}" ]]; do _bf="${_bf}0"; done
    ((10#0${_af} <= 10#0${_bf}))
}

# True when decimal $1 < decimal $2.
_num_lt() {
    _num_le "$2" "$1" && return 1
    return 0
}

# The numbers of the three metric lines are internally consistent, and the
# shell median is inside the budget the run actually handed to `bench`.
#
# Shape alone is not an answer: `min=500 median=400 max=1` is three
# well-formed numbers, is not a measurement of anything, and would have
# passed. So min <= median <= max is asserted per metric, and the one
# threshold the document publishes - the enter-latency budget, measured on
# the shell median - is compared against ${BENCH_MAX_MS}, the same value
# `--max-ms` was given.
_51_check_metric_values() {
    local _line _metric _min _med _max _bad=0
    local _re='^(enter|shell|inbox): min=([0-9]+(\.[0-9]+)?) median=([0-9]+(\.[0-9]+)?) max=([0-9]+(\.[0-9]+)?) ms$'
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] || continue
        if [[ ! "${_line}" =~ ${_re} ]]; then
            guard_fail "bench line '${_line}' is not a metric line"
            _bad=1
            continue
        fi
        _metric="${BASH_REMATCH[1]}"
        _min="${BASH_REMATCH[2]}"
        _med="${BASH_REMATCH[4]}"
        _max="${BASH_REMATCH[6]}"
        if ! _num_le "${_min}" "${_med}" || ! _num_le "${_med}" "${_max}"; then
            guard_fail "${_metric}: min=${_min} median=${_med} max=${_max} is not min <= median <= max, so it is not a measurement of ten runs"
            _bad=1
        fi
        if [[ "${_metric}" == shell ]] && ! _num_lt "${_med}" "${BENCH_MAX_MS}"; then
            guard_fail "shell median ${_med} ms is not below the --max-ms ${BENCH_MAX_MS} this run passed to bench"
            _bad=1
        fi
    done <"${_51_W}/three.txt"
    return "${_bad}"
}

# Extract the three metric lines and prove there is exactly one of each.
_51_collect_metrics() {
    local _grc _n _k
    grep -E '^(enter|shell|inbox): min=[0-9]+(\.[0-9]+)? median=[0-9]+(\.[0-9]+)? max=[0-9]+(\.[0-9]+)? ms$' \
        -- "${_51_W}/bench.txt" >"${_51_W}/three.txt"
    _grc=$?
    # 1 = matched nothing (a real answer, caught by the counts below);
    # >= 2 = could not read bench.txt, which must never become a count.
    [[ "${_grc}" -le 1 ]] \
        || { guard_fail "reading ${_51_W}/bench.txt failed (grep exited ${_grc})"; return 1; }
    [[ -f "${_51_W}/three.txt" ]] \
        || { guard_fail "grep produced no ${_51_W}/three.txt -- a count off a missing file is not a zero"; return 1; }
    _n="$(wc -l <"${_51_W}/three.txt")" \
        || { guard_fail "counting the bench lines failed"; return 1; }
    _n="${_n//[[:space:]]/}"
    [[ "${_n}" =~ ^[0-9]+$ ]] \
        || { guard_fail "wc printed '${_n}', which is not a count"; return 1; }
    # pipefail makes a broken `cut` fail the whole substitution instead of
    # letting `sort | wc -l` report a confident 0.
    _k="$(cut -d: -f1 <"${_51_W}/three.txt" | sort -u | wc -l)" \
        || { guard_fail "counting the distinct bench metrics failed"; return 1; }
    _k="${_k//[[:space:]]/}"
    [[ "${_k}" =~ ^[0-9]+$ ]] \
        || { guard_fail "wc printed '${_k}', which is not a count"; return 1; }
    { [[ "${_n}" -eq 3 ]] && [[ "${_k}" -eq 3 ]]; } \
        || { guard_fail "expected one enter/shell/inbox line each, got n=${_n} distinct=${_k}"; return 1; }
    _51_check_metric_values || return 1
    return 0
}

_51_write_body() {
    local _tag="$1" _run_id="$2" _fence='```' _host
    _host="$(uname -sm)" || { guard_fail "uname failed"; return 1; }
    printf '%s (%s, run %s)\n\n%stext\n' "${_tag}" "${_host}" "${_run_id}" "${_fence}" \
        >"${_51_W}/body.md" || { guard_fail "writing the comment body failed"; return 1; }
    cat -- "${_51_W}/three.txt" >>"${_51_W}/body.md" \
        || { guard_fail "appending the measured lines to the comment body failed"; return 1; }
    printf '%s\n' "${_fence}" >>"${_51_W}/body.md" \
        || { guard_fail "closing the comment body failed"; return 1; }
}

# Publish this run's three lines, then verify THAT comment by id. An old
# comment that looks the same must not be able to answer for this run, so the
# body carries a per-run id and all three lines are required verbatim.
_51_publish() {
    local _tag="$1" _run_id="$2" _url _cid _posted
    _51_write_body "${_tag}" "${_run_id}" || return 1
    _url="$(guard_timed "${TIMEOUT_SHORT}" gh issue comment "${ISSUE}" --repo "${REPO}" \
        --body-file "${_51_W}/body.md")" || { guard_fail "gh issue comment failed"; return 1; }
    _cid="${_url##*-}"
    case "${_cid}" in
        '' | *[!0-9]*)
            guard_fail "cannot parse a comment id out of '${_url}'"
            return 1
            ;;
    esac
    guard_timed "${TIMEOUT_SHORT}" gh api "repos/${REPO}/issues/comments/${_cid}" \
        >"${_51_W}/posted.json" || { guard_fail "re-reading comment ${_cid} failed"; return 1; }
    # jq's status is checked separately from its answer: a jq that died
    # half-way must not be read as "posted=0", or as anything else.
    _posted="$(jq -r --arg rid "${_run_id}" --arg tag "${_tag}" --arg iss "${ISSUE}" \
        --rawfile three "${_51_W}/three.txt" '
            ($three | rtrimstr("\n") | split("\n")) as $lines
            | if (.issue_url | endswith("/issues/" + $iss))
                 and (.body | contains($tag)) and (.body | contains($rid))
                 and ([$lines[] as $l | (.body | contains($l))] | all)
              then 1 else 0 end' "${_51_W}/posted.json")" \
        || { guard_fail "judging comment ${_cid} failed"; return 1; }
    case "${_posted}" in
        0 | 1) ;;
        *)
            guard_fail "the verdict on comment ${_cid} is '${_posted}', neither 0 nor 1"
            return 1
            ;;
    esac
    printf 'posted=%s comment=%s run=%s\n' "${_posted}" "${_cid}" "${_run_id}"
    [[ "${_posted}" == "1" ]] \
        || { guard_fail "comment ${_cid} on #${ISSUE} does not carry run id ${_run_id} plus the three lines measured above"; return 1; }
    return 0
}

_51_prepare_config() {
    local _config="${XDG_CONFIG_HOME:-${HOME}/.config}" _entry
    mkdir -p -- "${_51_W}/config" \
        || { guard_fail "creating scratch config failed"; return 1; }
    # Preserve all user config, including the container tool's store and
    # connection settings; only worktool's state writes belong in scratch.
    for _entry in "${_config}"/* "${_config}"/.[!.]* "${_config}"/..?*; do
        [[ -e "${_entry}" || -L "${_entry}" ]] || continue
        [[ "${_entry##*/}" != worktool ]] || continue
        ln -s -- "${_entry}" "${_51_W}/config/${_entry##*/}" \
            || { guard_fail "linking user config '${_entry}' failed"; return 1; }
    done
    return 0
}

_51_body() {
    local _tag='M3 5.1 real-machine bench' _stamp _run_id _brc _trc
    local -a _st
    _stamp="$(date -u +%Y%m%dT%H%M%SZ)" || { guard_fail "date failed"; return 1; }
    _run_id="m3-51-${_stamp}-$$"
    _51_prepare_config || return 1

    # Ownership BEFORE the box can exist: the marker means "assemble was
    # ATTEMPTED", not "assemble returned 0", so an interrupt anywhere inside
    # assemble still hands cleanup the box. A marker with no box is the safe
    # direction, and cleanup tolerates it.
    _51_CREATED=1
    XDG_CONFIG_HOME="${_51_W}/config" _just box assemble --home "${_51_W}/box-home" >/dev/null || { guard_fail "just box assemble failed"; return 1; }
    guard_box_exists "${BOX}" "${TIMEOUT_SHORT}" \
        || { guard_fail "assemble returned 0 but box '${BOX}' is not listed"; return 1; }

    _just box bench --runs "${BENCH_RUNS}" --shell 'fish -c exit' \
        --max-ms "${BENCH_MAX_MS}" | tee "${_51_W}/bench.txt"
    _st=("${PIPESTATUS[@]}")
    _brc="${_st[0]}"
    _trc="${_st[1]}"
    printf 'rc=%s\n' "${_brc}"
    [[ "${_brc}" -eq 0 ]] || { guard_fail "just box bench exited ${_brc}"; return 1; }
    # tee is the only reason bench.txt exists; a failed tee means the file the
    # next checks read is not what bench printed.
    [[ "${_trc}" -eq 0 ]] \
        || { guard_fail "tee into ${_51_W}/bench.txt exited ${_trc} -- the captured bench output is not trustworthy"; return 1; }
    _51_collect_metrics || return 1
    _51_publish "${_tag}" "${_run_id}" || return 1
    return 0
}

item_51() {
    guard_require distrobox just gh jq mktemp timeout awk grep cut sort wc tee date uname mkdir ln \
        || return $?
    _refuse_preexisting_box \
        "This block deletes the box it creates, so rename or remove yours by hand first." \
        || return 1
    printf 'preexisting-dev=0\n'

    _51_W="$(mktemp -d "${TMPDIR:-/tmp}/wt-m3-51.XXXXXXXX")" \
        || { guard_fail "mktemp failed"; return 1; }
    [[ -d "${_51_W}" ]] \
        || { guard_fail "mktemp returned '${_51_W}', which is not a directory"; return 1; }

    _51_CREATED=0
    _host_state_snapshot "${_51_W}" || return $?
    _cleanup_push 51
    local _rc=0
    _51_body || _rc=1
    _cleanup_pop_run || _rc=1
    return "${_rc}"
}

# =============================================================================
# 5.2  ghostty window chain: back up, apply, confirm, restore
# =============================================================================

# --- step 1 ------------------------------------------------------------------
_52_step1_backup() {
    guard_require sha256sum cp mv mkdir rm readlink grep cut id || return $?
    cfgbk_paths || return 1
    # Nothing is applied unless EVERY file `just box setup` can write can be
    # backed up: this item rewrites the maintainer's real configuration, and
    # a file with no backup has no way back (see lib/config_backup.sh).
    cfgbk_preflight || return 1
    cfgbk_dir_create || return 1
    # Until the manifest is published nothing has been applied, so a step 1
    # that fails or is interrupted removes its own half-written backup.
    _cleanup_push 52-abort-backup
    local _rc=0
    if _host_state_snapshot "${CFGBK_B}" && cfgbk_backup_body; then
        _cleanup_drop
    else
        _cleanup_pop_run
        _rc=1
    fi
    return "${_rc}"
}

# --- step 2 ------------------------------------------------------------------
_52_step2_apply() {
    guard_require distrobox just timeout awk sha256sum grep cut readlink id ps || return $?
    cfgbk_paths || return 1
    cfgbk_revalidate || return 1
    printf 'revalidate=1\n'

    _refuse_preexisting_box \
        "Step 3 deletes the box this run creates, so rename or remove yours by hand first." \
        || return 1
    printf 'preexisting-dev=0\n'

    # The marker is written BEFORE assemble and persisted to disk, so step 3
    # works in a fresh shell and an interrupt inside assemble still leaves
    # something that says "this run touched assemble".
    : >"${CFGBK_B}/created-box" \
        || { guard_fail "cannot record box ownership at ${CFGBK_B}/created-box"; return 1; }
    _just box assemble --home "${CFGBK_B}/box-home" >/dev/null || { guard_fail "just box assemble failed"; return 1; }
    guard_box_exists "${BOX}" "${TIMEOUT_SHORT}" \
        || { guard_fail "assemble returned 0 but box '${BOX}' is not listed"; return 1; }
    guard_timed "${TIMEOUT_SHORT}" ps -e -o pid=,comm= >"${CFGBK_B}/processes-before" \
        || { guard_fail "cannot inventory processes before setup"; return 1; }
    _just box setup || { guard_fail "just box setup failed -- run 5.2.3 to restore"; return 1; }
    _just box status || { guard_fail "just box status failed -- run 5.2.3 to restore"; return 1; }
    printf 'setup-rc=0\n'
    # The claim no exit code and no `status` line can make: the maintainer's
    # own lines are still in every file this apply just wrote. Checked HERE,
    # before step 3 restores anything, or the restore would hide the damage
    # it was only supposed to undo.
    cfgbk_report_user_content after-apply \
        || { guard_fail "the apply destroyed user content -- run 5.2.3 to restore it from the backup"; return 1; }
}

# --- objective new-window check ---------------------------------------------
_52_confirm_window() {
    local _pid
    printf 'Ghostty already running when setup applied? Reload config (Linux default Ctrl+Shift+,).\n'
    printf 'Reload is asynchronous: wait for evidence that config.ghostty was read (e.g. Ghostty logs),\n'
    printf 'or start a new Ghostty process with the updated config before opening a new window.\n'
    printf 'Never close your existing windows.\n'
    printf 'Open a NEW ghostty window now and run: echo %s\n' "\$fish_pid"
    [[ -t 0 ]] \
        || { guard_fail "stdin is not a tty; re-run 5.2 from an interactive shell"; return 1; }
    printf 'Enter the fish PID from the new window: '
    IFS= read -r _pid || { guard_fail "reading the fish PID failed"; return 1; }
    [[ "${_pid}" =~ ^[1-9][0-9]*$ ]] \
        || { guard_fail "expected a fish PID; a typed yes is not objective evidence"; return 1; }
    _52_window_evidence "${_pid}"
}

_52_window_evidence() {
    local _pid="$1" _comm _host _window _before _name
    guard_require ps readlink || return $?
    while read -r _before _name; do
        [[ "${_before}" != "${_pid}" ]] \
            || { guard_fail "fish PID ${_pid} existed before setup; open a new window"; return 1; }
    done <"${CFGBK_B}/processes-before"
    _comm="$(guard_timed "${TIMEOUT_SHORT}" ps -p "${_pid}" -o comm=)" \
        || { guard_fail "cannot inspect fish PID ${_pid}"; return 1; }
    [[ "${_comm}" == fish ]] \
        || { guard_fail "PID ${_pid} is not fish"; return 1; }
    _host="$(readlink /proc/self/ns/mnt)" \
        || { guard_fail "cannot read host mount namespace"; return 1; }
    _window="$(readlink "/proc/${_pid}/ns/mnt")" \
        || { guard_fail "cannot read fish mount namespace (permissions or exited process)"; return 1; }
    [[ "${_host}" =~ ^mnt:\[[0-9]+\]$ && "${_window}" =~ ^mnt:\[[0-9]+\]$ ]] \
        || { guard_fail "invalid mount namespace evidence"; return 1; }
    printf 'window-evidence: pid=%s comm=%s host=%s window=%s\n' \
        "${_pid}" "${_comm}" "${_host}" "${_window}"
    [[ "${_window}" != "${_host}" ]] \
        || { guard_fail "fish remains in the host mount namespace"; return 1; }
}

# --- step 3 ------------------------------------------------------------------

# Only a box this run created may be removed. The marker says step 2 STARTED
# assemble, so it can outlive an interrupt that left no box.
_52_remove_owned_box() {
    if [[ ! -e "${CFGBK_B}/created-box" ]]; then
        printf 'dev-untouched=1 (this run never created a box; leaving every box alone)\n'
        return 0
    fi
    if _drop_owned_box; then
        printf 'dev-gone=1\n'
        _box_state_cleanup "${CFGBK_B}/box-home" || return 1
        return 0
    fi
    printf 'dev-gone=0\n'
    guard_fail "box '${BOX}' created by this run is still there (or distrobox list failed) -- remove it by hand"
    return 1
}

_52_cleanup_state() {
    if [[ ! -e "${CFGBK_B}/created-box" ]]; then
        _52_remove_owned_box || return 1
        # Separate invocations allow user-owned state to appear after backup.
        # Without an assemble marker, none of it belongs to this run.
        _host_state_report "${CFGBK_B}" untouched
        return $?
    fi
    _52_remove_owned_box || return 1
    _host_state_cleanup "${CFGBK_B}" || return 1
    # Keep ownership across retries until all owned state is clean.
    rm -f -- "${CFGBK_B}/created-box" \
        || { guard_fail "cannot clear the ownership marker ${CFGBK_B}/created-box"; return 1; }
}

_52_step3_restore() {
    guard_require distrobox just timeout awk sha256sum grep cut readlink cp rm rmdir mkdir id \
        || return $?
    cfgbk_paths || return 1
    local _rc=0 _rrc

    if [[ ! -d "${CFGBK_B}" ]]; then
        printf 'no-backup=1 (%s absent; already restored, or step 1 never ran)\n' "${CFGBK_B}"
        return 0
    fi
    if [[ ! -f "${CFGBK_B}/manifest" ]]; then
        printf 'incomplete-backup=1 (%s has no published manifest, so step 2 never applied anything; inspect it, then: rm -rf %s)\n' \
            "${CFGBK_B}" "${CFGBK_B}"
        return 1
    fi
    if ! cfgbk_states_ok "${CFGBK_B}/manifest"; then
        printf 'manifest-invalid=1 (%s/manifest is not exactly one valid state line per name; restore by hand)\n' \
            "${CFGBK_B}"
        return 1
    fi

    _just box setup --auto-enter no >/dev/null 2>&1
    _rrc=$?
    printf 'restore-rc=%s\n' "${_rrc}"
    [[ "${_rrc}" -eq 0 ]] \
        || { guard_fail "just box setup --auto-enter no exited ${_rrc}"; _rc=1; }

    cfgbk_restore_all || _rc=1
    if [[ "${_rc}" -eq 0 ]]; then printf 'restore-ok=1\n'; else printf 'restore-ok=0\n'; fi

    cfgbk_report_blocks || _rc=1
    cfgbk_report_leftover_dirs || _rc=1
    _52_cleanup_state || _rc=1

    if [[ "${_rc}" -ne 0 ]]; then
        printf 'backup kept at %s -- fix the errors above and re-run 5.2.3\n' "${CFGBK_B}"
        return 1
    fi
    # Only claim the backup is gone once the removal actually succeeded.
    rm -rf -- "${CFGBK_B}" \
        || { guard_fail "removing the backup at ${CFGBK_B} failed"; return 1; }
    [[ ! -e "${CFGBK_B}" ]] \
        || { guard_fail "${CFGBK_B} still present after removal"; return 1; }
    printf 'backup-removed=1\n'
    return 0
}

item_52() {
    cfgbk_paths || return 1
    _52_step1_backup || return $?
    # A published backup exists from here on, and step 3 is the only thing
    # that undoes anything - the config may already be applied by the time we
    # are interrupted, so it must run on EXIT / INT / TERM / HUP too.
    _cleanup_push 52-restore
    local _rc=0
    _52_step2_apply || _rc=$?
    if [[ "${_rc}" -eq 0 ]]; then
        _52_confirm_window || _rc=$?
    fi
    _cleanup_pop_run || {
        local _crc=$?
        printf 'incomplete=1 (run 5.2.3 now: it restores the config and removes the box this run created)\n' >&2
        if [[ "${_crc}" -eq 3 && "${_rc}" -ne 1 ]]; then
            _rc=3
        else
            _rc=1
        fi
    }
    return "${_rc}"
}

# =============================================================================
# 5.3  negative: a pre-existing `dev` box is refused, never deleted
# =============================================================================
_53_CREATED=0
_53_W=""

_53_cleanup() {
    local _crc=0
    if [[ "${_53_CREATED}" -eq 1 ]]; then
        _drop_owned_box || _crc=1
    fi
    printf 'decoy-cleanup-rc=%s\n' "${_crc}"
    [[ "${_crc}" -eq 0 ]] \
        || guard_fail "the decoy box '${BOX}' survived cleanup -- remove it by hand"
    if [[ "${_crc}" -eq 0 && -n "${_53_W}" ]]; then
        _host_state_cleanup "${_53_W}" || return 1
        _box_state_cleanup "${_53_W}/box-home" || return 1
        rm -rf -- "${_53_W}" || _crc=1
    fi
    return "${_crc}"
}

_53_make_decoy() {
    local _e
    guard_timed "${TIMEOUT_LONG}" distrobox create --name "${BOX}" --image "${DECOY_IMAGE}" \
        --home "${_53_W}/box-home" --yes >/dev/null || { guard_fail "distrobox create --name ${BOX} failed"; return 1; }
    # `create` returning 0 is not proof the box is there; ask `list`, whose
    # own failure is tri-stated so "cannot tell" never reads as "created".
    guard_box_exists "${BOX}" "${TIMEOUT_SHORT}"
    _e=$?
    [[ "${_e}" -ne 2 ]] \
        || { guard_fail "distrobox list failed -- cannot tell whether '${BOX}' was created"; return 1; }
    [[ "${_e}" -eq 0 ]] || { guard_fail "no box named '${BOX}' after create"; return 1; }
    printf 'preexisting=%s\n' "${BOX}"
}

_53_still_there() {
    local _e
    guard_box_exists "${BOX}" "${TIMEOUT_SHORT}"
    _e=$?
    [[ "${_e}" -ne 2 ]] \
        || { guard_fail "distrobox list failed -- 'the box was not deleted' must not be concluded from a list nobody could read"; return 1; }
    [[ "${_e}" -eq 0 ]] \
        || { guard_fail "box '${BOX}' is gone -- it should NOT have been removed"; return 1; }
    printf 'still-there=%s\n' "${BOX}"
}

_53_body() {
    local _rc51 _rc52
    _53_make_decoy || return 1

    # 5.1 must refuse BEFORE `just box assemble`, so it prints neither
    # preexisting-dev=0 nor cleanup-rc, and touches no box.
    item_51
    _rc51=$?
    printf '51-rc=%s\n' "${_rc51}"
    [[ "${_rc51}" -ne 3 ]] || return 3
    [[ "${_rc51}" -ne 0 ]] \
        || { guard_fail "5.1 did NOT refuse a pre-existing '${BOX}' box"; return 1; }

    _52_step1_backup || return $?
    _cleanup_push 52-restore
    _52_step2_apply
    _rc52=$?
    printf '52-rc=%s\n' "${_rc52}"
    [[ "${_rc52}" -ne 3 ]] || return 3
    if [[ "${_rc52}" -eq 0 ]]; then
        _cleanup_pop_run
        guard_fail "5.2 step 2 did NOT refuse a pre-existing '${BOX}' box"
        return 1
    fi
    _cleanup_pop_run || { guard_fail "5.2 step 3 failed"; return 1; }

    _53_still_there
}

item_53() {
    guard_require distrobox just gh jq timeout awk grep || return $?
    # The decoy has to be OURS: refuse if a box of that name already exists,
    # so this item can never remove one the maintainer cares about.
    _refuse_preexisting_box \
        "5.3 creates the decoy box itself, so rename or remove yours by hand first." \
        || return 1
    _53_W="$(mktemp -d "${TMPDIR:-/tmp}/wt-m3-53.XXXXXXXX")" \
        || { guard_fail "mktemp failed"; return 1; }
    [[ -d "${_53_W}" ]] || { guard_fail "decoy scratch is not a directory"; return 1; }
    _host_state_snapshot "${_53_W}" || return $?
    _53_CREATED=1
    _cleanup_push 53
    local _rc=0
    _53_body || _rc=$?
    _cleanup_pop_run || _rc=1
    return "${_rc}"
}

# =============================================================================
# Dispatcher and CLI
# =============================================================================
_is_item() {
    case "$1" in
        5.1 | 5.2 | 5.2.1 | 5.2.2 | 5.2.3 | 5.3) return 0 ;;
    esac
    return 1
}

_dispatch_item() {
    case "$1" in
        5.1) item_51 ;;
        5.2) item_52 ;;
        5.2.1) _52_step1_backup ;;
        5.2.2) _52_step2_apply ;;
        5.2.3) _52_step3_restore ;;
        5.3) item_53 ;;
        *) guard_fail "internal: unknown item '$1'"; return 1 ;;
    esac
}

_set_option() {
    case "$1" in
        --repo)
            [[ "$2" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
                || { _usage_error "invalid --repo '$2'"; return 1; }
            REPO="$2"
            ;;
        --issue)
            [[ "$2" =~ ^[0-9]+$ ]] || { _usage_error "invalid --issue '$2'"; return 1; }
            ISSUE="$2"
            ;;
        --box)
            [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || { _usage_error "invalid --box '$2'"; return 1; }
            BOX="$2"
            ;;
        --image)
            if [[ -z "$2" || "$2" == *[[:space:]]* ]]; then
                _usage_error "invalid --image '$2'"
                return 1
            fi
            DECOY_IMAGE="$2"
            ;;
    esac
    return 0
}

realbox_run() {
    local _help=0 _opt _i
    local _items=()
    # The WHOLE command line is parsed before anything runs.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help) _help=1 ;;
            --allow-real-box) OPT_IN=1 ;;
            --repo | --issue | --box | --image)
                _opt="$1"
                shift
                [[ $# -gt 0 ]] || { _usage_error "${_opt} needs a value"; return 2; }
                _set_option "${_opt}" "$1" || return 2
                ;;
            --repo=* | --issue=* | --box=* | --image=*)
                _set_option "${1%%=*}" "${1#*=}" || return 2
                ;;
            -*) _usage_error "unknown option '$1'"; return 2 ;;
            *)
                _is_item "$1" || { _usage_error "unknown item '$1'"; return 2; }
                _items+=("$1")
                ;;
        esac
        shift
    done

    if [[ "${_help}" -eq 1 ]]; then
        _usage
        return 0
    fi
    [[ "${#_items[@]}" -gt 0 ]] || _items=("${ITEMS_ALL[@]}")

    # Group realbox: nothing happens without the explicit opt-in.
    if [[ "${OPT_IN}" -ne 1 ]]; then
        guard_fail "realbox.sh works on THIS machine: it creates and removes a distrobox named '${BOX}', rewrites the ghostty and worktool configs under \$XDG_CONFIG_HOME, and comments on ${REPO}#${ISSUE}. Pass --allow-real-box to say you want that. Refusing to run." || return 2
        return 2
    fi

    _run_requested_items "${_items[@]}"
}

_run_requested_items() {
    trap _on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    local _rc=0 _i
    for _i in "$@"; do
        _dispatch_item "${_i}" || {
            _rc=$?
            if [[ "${_rc}" -ne 3 ]]; then
                guard_fail "item ${_i} failed"
                _rc=1
            fi
            break
        }
    done
    return "${_rc}"
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    realbox_run "$@"
fi
