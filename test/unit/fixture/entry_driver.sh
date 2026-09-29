#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/fixture/entry_driver.sh - drive ONE function of
# script/test/system-real-entry.sh in isolation, for
# test/unit/system_real_entry_spec.bats.
#
# Usage:
#   entry_driver.sh <entry.sh> <pidfile> <live|dead|none> <pending-rc> <function> [arg...]
#
# Sources the entry script (its main() is guarded), installs a stand-in
# dockerd in DOCKERD_PID according to $3:
#   live  a background `sleep`; its pid is written to <pidfile> so the spec
#         can reap it after a `_die` path
#   dead  the same, then killed, so the pid is gone (daemon died early)
#   none  DOCKERD_PID stays empty, as when the trap fires before
#         _start_dockerd
# then calls <function> with any remaining [arg...]. Exit status is the
# function's. `_cleanup` is the entry's EXIT trap, so it is driven as one:
# installed with `trap`, then `exit <pending-rc>` - it reads the pending
# status from `$?` exactly as it does in the entry. <pending-rc> is only
# meaningful for `_cleanup`.
#
# Two optional knobs, applied after the stand-in is in place:
#   DRIVER_STOP_TIMEOUT=<s>      overrides DOCKERD_STOP_TIMEOUT (default 20)
#                                so the SIGKILL escalation is reached fast
#   DRIVER_REFUSE_SIGNALS=<...>  space-separated signal names (TERM KILL)
#                                that `kill` refuses (returns 1), as when
#                                the daemon exited between probe and signal
#
# Sourcing the entry turns on its `set -euo pipefail` here too, so every
# expected non-zero below is handled explicitly.

set -euo pipefail

entry="$1"
pidfile="$2"
stand_in="$3"
pending_rc="$4"
fn="$5"
shift 5

# shellcheck source=../../../script/test/system-real-entry.sh
source "${entry}"

if [[ "${stand_in}" != "none" ]]; then
    sleep 300 >/dev/null 2>&1 &
    DOCKERD_PID=$!
    printf '%s\n' "${DOCKERD_PID}" >"${pidfile}"
    if [[ "${stand_in}" == "dead" ]]; then
        kill -KILL "${DOCKERD_PID}"
        # A SIGKILLed child reports 128 + 9: expected, anything else is not.
        wait "${DOCKERD_PID}" 2>/dev/null || [[ $? -eq 137 ]]
    fi
fi

if [[ -n "${DRIVER_STOP_TIMEOUT:-}" ]]; then
    DOCKERD_STOP_TIMEOUT="${DRIVER_STOP_TIMEOUT}"
fi
if [[ -n "${DRIVER_REFUSE_SIGNALS:-}" ]]; then
    kill() {
        local _sig
        for _sig in ${DRIVER_REFUSE_SIGNALS}; do
            [[ "$1" != "-${_sig}" ]] || return 1
        done
        builtin kill "$@"
    }
fi

if [[ "${fn}" == "_cleanup" ]]; then
    trap _cleanup EXIT
    exit "${pending_rc}"
fi
"${fn}" "$@"
