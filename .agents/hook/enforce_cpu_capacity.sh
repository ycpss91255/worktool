#!/usr/bin/env bash
# .agents/hook/enforce_cpu_capacity.sh - Claude Code PreToolUse hook
# (matcher: Workflow|Agent), registered in .claude/settings.json (#244).
#
# Every pr-loop / agent runs whole test tiers in Docker. Started on a CPU
# that is already saturated, each new one only slows all the others (and
# makes the latency gates undecidable). So before a Workflow, or an Agent
# with run_in_background: true, starts, the hook reads:
#   - the CPU pressure: /proc/pressure/cpu `some avg60` (PSI);
#   - the running worktool test containers: `docker ps` rows whose image is
#     one script/test/test.sh runs (worktool-test, worktool-system-real,
#     worktool-ghostty; any tag);
#   - loadavg and nproc, for the record.
# Over a limit (see the constant block) it BLOCKS (exit 2) with the current
# values, the limits and what to do instead. A foreground Agent and every
# other tool pass untouched; work already running is never interrupted.
#
# PSI unreadable -> judged on the test containers only, and the message
# says so. `docker ps` failing -> judged on PSI only, likewise noted.
#
# Inputs are injectable for the spec: CPU_GATE_PSI_FILE, CPU_GATE_LOADAVG_FILE,
# CPU_GATE_NPROC, and `docker` found on PATH.
#
# Exit codes: 0 = allow, 2 = block.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "cpu-capacity"

# --- Limits (the one place to tune them) --------------------------------------
# Block when PSI some avg60 is ABOVE this percentage.
readonly CPU_GATE_PSI_LIMIT=50
# Block when the test containers are ABOVE nproc * NUM / DEN (2 per 4 CPUs).
readonly CPU_GATE_CONTAINERS_NUM=2
readonly CPU_GATE_CONTAINERS_DEN=4
# Image repositories script/test/test.sh runs its gates in.
readonly CPU_GATE_TEST_IMAGES_RE='^worktool-(test|system-real|ghostty)(:|$)'
# Seconds `docker ps` may take before it counts as failed.
readonly CPU_GATE_DOCKER_TIMEOUT=10

# _psi_some_avg60 - print PSI `some avg60`; 1 when unreadable.
_psi_some_avg60() {
    local _file="${CPU_GATE_PSI_FILE:-/proc/pressure/cpu}" _v
    [[ -r "${_file}" ]] || return 1
    _v="$(awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/^avg60=/, "", $i); print $i } }' \
        "${_file}")"
    [[ "${_v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    printf '%s\n' "${_v}"
}

# _loadavg - print the three load averages, or "unknown".
_loadavg() {
    local _file="${CPU_GATE_LOADAVG_FILE:-/proc/loadavg}" _a _b _c
    if [[ -r "${_file}" ]] && read -r _a _b _c _ <"${_file}"; then
        printf '%s %s %s\n' "${_a}" "${_b}" "${_c}"
    else
        printf 'unknown\n'
    fi
}

# _nproc - print the CPU count (at least 1).
_nproc() {
    local _n="${CPU_GATE_NPROC:-}"
    [[ -n "${_n}" ]] || _n="$(nproc 2>/dev/null)"
    [[ "${_n}" =~ ^[1-9][0-9]*$ ]] || _n=1
    printf '%s\n' "${_n}"
}

# _test_containers - print how many running containers use a test image;
# 1 when `docker ps` is missing or fails.
_test_containers() {
    local _out
    command -v docker >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then
        _out="$(timeout "${CPU_GATE_DOCKER_TIMEOUT}" docker ps --format '{{.Image}}' 2>/dev/null)" || return 1
    else
        _out="$(docker ps --format '{{.Image}}' 2>/dev/null)" || return 1
    fi
    printf '%s\n' "${_out}" | awk -v re="${CPU_GATE_TEST_IMAGES_RE}" '$1 ~ re { n++ } END { print n + 0 }'
}

# _gated - 0 when this tool call starts new parallel work.
_gated() {
    case "$(hook_field '.tool_name')" in
        Workflow) return 0 ;;
        Agent) [[ "$(hook_field '.tool_input.run_in_background')" == true ]] ;;
        *) return 1 ;;
    esac
}

main() {
    hook_read_input
    _gated || hook_allow
    local _psi _cnt _nproc _climit _over=0 _psi_txt _cnt_txt
    _nproc="$(_nproc)"
    _climit=$((_nproc * CPU_GATE_CONTAINERS_NUM / CPU_GATE_CONTAINERS_DEN))
    if _psi="$(_psi_some_avg60)"; then
        _psi_txt="PSI some avg60 ${_psi} (limit ${CPU_GATE_PSI_LIMIT})"
        awk -v v="${_psi}" -v l="${CPU_GATE_PSI_LIMIT}" 'BEGIN { exit !(v > l) }' && _over=1
    else
        _psi_txt="PSI unavailable (judged on test containers only)"
    fi
    if _cnt="$(_test_containers)"; then
        _cnt_txt="test containers ${_cnt} (limit ${_climit})"
        ((_cnt > _climit)) && _over=1
    else
        _cnt_txt="test containers unknown (docker ps failed; judged on PSI only)"
    fi
    ((_over)) || hook_allow
    hook_block "the CPU is saturated; starting more parallel work now slows everything down." \
        "${_psi_txt}; loadavg $(_loadavg); nproc ${_nproc}; ${_cnt_txt}" \
        "Wait for the running work to finish before starting another, or merge the items into one fanout."
}

main "$@"
