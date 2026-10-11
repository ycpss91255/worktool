#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=script/verify/realbox.sh
source "$1"
shift
# INT is handled while _just's stdout is redirected; preserve cleanup evidence.
exec 3>&1
eval "$(declare -f _51_cleanup | sed '1s/_51_cleanup/_cleanup_with_output/')"
_51_cleanup() { _cleanup_with_output >&3; }
realbox_run "$@"
