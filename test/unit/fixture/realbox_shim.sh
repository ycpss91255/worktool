#!/usr/bin/env bash
# test/unit/fixture/realbox_shim.sh - a shim that makes ONE real tool fail on
# demand, for test/unit/verify_realbox_spec.bats.
#
# Installed under the name of the tool it stands in for (grep, cut, wc,
# sha256sum, readlink, tee, sort, mktemp, id, date, uname, cp, mv, rm, awk)
# in a stub directory placed first on PATH. Unless it is told to act, it
# hands the call straight to the REAL tool, whose path the spec recorded in
# $FAKE_STATE_DIR/real/<name> BEFORE it touched PATH - so the script under
# test keeps working and only the one stage under examination breaks.
#
# Env knobs, per tool (<NAME> = the installed name, upper-cased):
#   SHIM_<NAME>_RC   exit with this status instead of delegating
#   SHIM_<NAME>_OUT  print this on stdout first - the PLAUSIBLE output that,
#                    paired with a non-zero status, is exactly the shape a
#                    guard-less check would swallow
#   SHIM_<NAME>_ON   act only when the argv CONTAINS this literal substring;
#                    the script calls grep, cut and rm for several different
#                    purposes and a test usually wants to break just one
#
# Exit-code-contract fixture: `set -uo pipefail`, no `-e` (doc/adr/0007).

set -uo pipefail

_ME="${0##*/}"
_KEY="${_ME^^}"
_DIR="${FAKE_STATE_DIR:?FAKE_STATE_DIR must be set}"

_v="SHIM_${_KEY}_ON"
_ON="${!_v-}"
_v="SHIM_${_KEY}_RC"
_RC="${!_v-}"
_v="SHIM_${_KEY}_OUT"
_OUT="${!_v-}"

# A literal substring test (both sides quoted): the knob selects a call site,
# it is not a pattern language, so nothing here can glob by accident.
_MATCH=1
if [[ -n "${_ON}" ]]; then
    _MATCH=0
    [[ "$*" == *"${_ON}"* ]] && _MATCH=1
fi

if [[ -n "${_RC}" && "${_MATCH}" -eq 1 ]]; then
    # Stream readers must drain stdin before injecting output or failure,
    # so pipefail observes this stage's status without SIGPIPE upstream.
    case "${_ME}" in
        cut | sort | wc | tee) cat >/dev/null ;;
    esac
    [[ -n "${_OUT}" ]] && printf '%s\n' "${_OUT}"
    exit "${_RC}"
fi

_REAL_FILE="${_DIR}/real/${_ME}"
if [[ ! -r "${_REAL_FILE}" ]]; then
    printf 'realbox_shim.sh: no real %s was recorded at %s\n' "${_ME}" "${_REAL_FILE}" >&2
    exit 127
fi
IFS= read -r _REAL <"${_REAL_FILE}" || {
    printf 'realbox_shim.sh: cannot read %s\n' "${_REAL_FILE}" >&2
    exit 127
}
exec "${_REAL}" "$@"
