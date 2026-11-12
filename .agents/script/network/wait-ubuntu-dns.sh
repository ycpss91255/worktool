#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: wait-ubuntu-dns.sh [--attempts N] [--interval SECONDS] [--timeout SECONDS] -- COMMAND [ARG...]

Resolve all three Ubuntu archive hosts with the host resolver before executing
COMMAND with its original arguments. This does not check container DNS or service
reachability. Do not wrap cleanup or restoration commands with this tool. Each attempt checks every host. Defaults: 5 attempts, 10 seconds
between attempts, 5 seconds per lookup. Numeric values are whole seconds;
attempts and timeout must be positive, while interval may be zero.
HELP
}

error() {
  printf 'wait-ubuntu-dns.sh: %s (see --help)\n' "$1" >&2
  exit 2
}

attempts=5
interval=10
lookup_timeout=5
while (($#)); do
  case "$1" in
    --help) usage; exit 0 ;;
    --attempts|--interval|--timeout)
      option=$1
      (($# >= 2)) || error "missing value for '$option'"
      value=$2
      [[ $value =~ ^[0-9]{1,6}$ ]] || error "invalid value '$value' for '$option'"
      value=$((10#$value))
      case "$option" in
        --attempts) ((value > 0)) || error "'$option' must be positive"; attempts=$value ;;
        --interval) interval=$value ;;
        --timeout) ((value > 0)) || error "'$option' must be positive"; lookup_timeout=$value ;;
      esac
      shift 2 ;;
    --) shift; break ;;
    *) error "unknown option '$1'" ;;
  esac
done
(($# > 0)) || error 'missing command after --'

for ((attempt = 1; attempt <= attempts; attempt++)); do
  failed=0
  for host in archive.ubuntu.com security.ubuntu.com ports.ubuntu.com; do
    if timeout --kill-after=1 "${lookup_timeout}s" getent ahosts "$host" >/dev/null 2>&1; then
      printf 'wait-ubuntu-dns.sh: resolved %s (attempt %s/%s)\n' "$host" "$attempt" "$attempts" >&2
    else
      printf 'wait-ubuntu-dns.sh: failed to resolve %s (attempt %s/%s)\n' "$host" "$attempt" "$attempts" >&2
      failed=1
    fi
  done
  if ((failed == 0)); then
    exec "$@"
  fi
  if ((attempt < attempts)); then
    sleep "$interval"
  fi
done
printf 'wait-ubuntu-dns.sh: DNS checks failed after %s attempts; command not run\n' "$attempts" >&2
exit 1
