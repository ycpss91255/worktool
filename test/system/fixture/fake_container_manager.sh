#!/usr/bin/env bash
# test/system/fixture/fake_container_manager.sh - fake container manager for
# the system tier.
#
# The system test runs the REAL, pinned distrobox (baked into the test image)
# and points it at this shim via DBX_CONTAINER_MANAGER=docker, with the shim
# symlinked onto PATH as `docker` (first). No docker daemon, no
# docker-in-docker: distrobox believes it is talking to docker, and every
# request it makes is recorded here for the spec to assert on.
#
# Recording (FAKE_CM_LOG_DIR, required):
#   <dir>/NNNN.argv   the full argv of invocation NNNN, NUL-delimited, one
#                     entry per argument (empty arguments are preserved) -
#                     never "$*", so spaces inside one argument stay inside
#                     that argument.
#   <dir>/calls.log   one line per invocation: "NNNN <subcommand>", the
#                     sequence in which requests reached the manager.
#
# Answered probes (what distrobox-assemble / -list / -create 1.8.2.5 actually
# call on the manager; read from the upstream sources):
#   version, --version         plausible "Docker version ..." line, exit 0
#   ps ...                     no containers (empty list), exit 0
#   inspect ...                object does not exist: "[]" + error, exit 1
#                              (so distrobox proceeds to pull + create)
#   pull <image>               succeeds, exit 0
#   create ...                 prints a fake 64-hex container id, exit 0
#
# Failure injection:
#   FAKE_CM_FAIL_CREATE=1      `create` fails like a daemon error (exit 125)
#
# Anything else FAILS LOUDLY (exit 2 on stderr) instead of a blanket exit 0,
# so an unexpected request from distrobox surfaces as a red test, not as a
# silently-green one.
#
# Exit-code-contract script: `set -uo pipefail` (no -e); every exit is
# explicit.

set -uo pipefail

_fail() {
    printf 'fake-container-manager: %s\n' "$*" >&2
    exit 2
}

_record() {
    local _dir="${FAKE_CM_LOG_DIR:-}"
    [[ -n "${_dir}" ]] || _fail "FAKE_CM_LOG_DIR is not set (harness misconfigured)"
    [[ -d "${_dir}" ]] || _fail "FAKE_CM_LOG_DIR is not a directory: ${_dir}"

    local _index="${_dir}/calls.log"
    local _n=0
    if [[ -f "${_index}" ]]; then
        _n="$(wc -l <"${_index}")"
    fi
    local _seq
    printf -v _seq '%04d' "$((_n + 1))"

    printf '%s\0' "$@" >"${_dir}/${_seq}.argv"
    printf '%s %s\n' "${_seq}" "${1:-}" >>"${_index}"
}

_record "$@"

case "${1:-}" in
    version|--version)
        printf 'Docker version 0.0.0-fake, build 0000000\n'
        exit 0
        ;;
    ps)
        # distrobox-list: `ps -a --no-trunc --format ...` -> no containers.
        exit 0
        ;;
    inspect)
        # distrobox-create probes `inspect --type container <name>` and
        # `inspect --type image <image>`; "not found" makes it create + pull.
        printf '[]\n'
        printf 'Error: No such object: %s\n' "${*: -1}" >&2
        exit 1
        ;;
    pull)
        [[ $# -ge 2 ]] || _fail "pull: missing image argument"
        printf 'Status: Downloaded newer image for %s\n' "${*: -1}"
        exit 0
        ;;
    create)
        if [[ "${FAKE_CM_FAIL_CREATE:-0}" == "1" ]]; then
            printf 'docker: Error response from daemon: injected create failure.\n' >&2
            exit 125
        fi
        printf '%064d\n' 1
        exit 0
        ;;
    *)
        _fail "unsupported subcommand '${1:-<none>}' (argv: $*)"
        ;;
esac
