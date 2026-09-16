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
# then sets the pending exit status to <pending-rc> (what `_cleanup` reads
# from `$?`) and calls <function> with any remaining [arg...]. Exit status
# is the function's.

set -uo pipefail

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
        wait "${DOCKERD_PID}" 2>/dev/null
    fi
fi

(exit "${pending_rc}")
"${fn}" "$@"
