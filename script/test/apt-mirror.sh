#!/usr/bin/env bash
# apt-mirror.sh - point an Ubuntu root's apt at ONE mirror (issue #843).
#
# CI's pass/fail must not hang on the state of an external mirror: on
# 2026-11-10 the amd64 runners got ~130 kB/s from archive.ubuntu.com and a
# 404 from a half-synced security.ubuntu.com. CI therefore names the mirror
# its runners sit next to, and this script applies it wherever Ubuntu
# packages are installed for a gate:
#   - dockerfile/Dockerfile.ghostty and dockerfile/Dockerfile.system-real
#     run it (bind-mounted) before their first `apt-get update`, with the
#     APT_MIRROR build arg;
#   - script/test/system-real-entry.sh runs it inside the nested daemon's
#     copy of the box image (box/dev.ini `image=`), so the box's first
#     launch still installs everything, only from that mirror.
#
# With a mirror, every `URIs:` line of <root>/etc/apt/sources.list.d/
# ubuntu.sources (the archive pockets AND the security pocket) becomes that
# mirror, and apt's retries are turned on. Without one (absent or empty)
# nothing is changed, so a local build is exactly what it was. A sources
# file that cannot be rewritten is a failure, never a silent fall back.
#
# Usage: apt-mirror.sh [--root DIR] [MIRROR]
#        apt-mirror.sh --check MIRROR
# Exit: 0 done (or nothing to do), 1 the sources file cannot be rewritten,
#       2 bad arguments or a MIRROR that is not a plain http(s) URL.
#
# Self-contained on purpose (plain printf to stderr, no lib/log.sh): the
# image builds bind-mount this one file, without the rest of the repo.

set -euo pipefail

ROOT=""
CHECK=0
MIRROR=""
HAVE_MIRROR=0
RETRIES=5

_usage() {
    cat <<'EOF'
Usage: apt-mirror.sh [--root DIR] [MIRROR]
       apt-mirror.sh --check MIRROR
Point every URIs line of <root>/etc/apt/sources.list.d/ubuntu.sources at
MIRROR and turn on apt retries; no MIRROR (or an empty one) changes nothing.
--check only validates MIRROR (a plain http(s) URL).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            if [[ $# -lt 2 || -z "$2" ]]; then
                printf 'apt-mirror.sh: --root requires a path (see --help)\n' >&2
                exit 2
            fi
            ROOT="$2"; shift ;;
        --check) CHECK=1 ;;
        -h|--help) _usage; exit 0 ;;
        -*) printf "apt-mirror.sh: unknown option '%s' (see --help)\n" "$1" >&2; exit 2 ;;
        *)
            if [[ "${HAVE_MIRROR}" == 1 ]]; then
                printf "apt-mirror.sh: unexpected argument '%s' (see --help)\n" "$1" >&2
                exit 2
            fi
            MIRROR="$1"; HAVE_MIRROR=1 ;;
    esac
    shift
done

# The value lands in a Dockerfile line and a sed replacement: allow only a
# scheme, a host and a path without spaces, quotes, `|`, `\`, `&` or `$`.
_valid_mirror() {
    [[ "$1" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/%+-]*)?$ ]]
}

if [[ "${CHECK}" == 1 ]]; then
    if [[ -z "${MIRROR}" ]] || ! _valid_mirror "${MIRROR}"; then
        printf "apt-mirror.sh: not a plain http(s) mirror URL: '%s'\n" "${MIRROR}" >&2
        exit 2
    fi
    exit 0
fi

[[ -n "${MIRROR}" ]] || exit 0

if ! _valid_mirror "${MIRROR}"; then
    printf "apt-mirror.sh: not a plain http(s) mirror URL: '%s'\n" "${MIRROR}" >&2
    exit 2
fi

SOURCES="${ROOT}/etc/apt/sources.list.d/ubuntu.sources"
CONF="${ROOT}/etc/apt/apt.conf.d/80worktool-ci"

if [[ ! -f "${SOURCES}" ]]; then
    printf 'apt-mirror.sh: %s not found (not an Ubuntu deb822 root?)\n' "${SOURCES}" >&2
    exit 1
fi
if ! grep -q '^URIs:' "${SOURCES}"; then
    printf 'apt-mirror.sh: %s has no URIs line to rewrite\n' "${SOURCES}" >&2
    exit 1
fi

sed -i "s|^URIs:.*|URIs: ${MIRROR}|" "${SOURCES}"
# Every URIs line must now name the mirror and nothing else.
if ! awk -v want="URIs: ${MIRROR}" '/^URIs:/ && $0 != want { bad = 1 } END { exit bad }' "${SOURCES}"; then
    printf 'apt-mirror.sh: %s still names another source after the rewrite\n' "${SOURCES}" >&2
    exit 1
fi
mkdir -p "$(dirname -- "${CONF}")"
printf 'Acquire::Retries "%s";\n' "${RETRIES}" >"${CONF}"
printf 'apt-mirror.sh: apt sources -> %s (retries %s)\n' "${MIRROR}" "${RETRIES}" >&2
