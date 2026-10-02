#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
HELP=0
for ARG in "$@"; do
    case "${ARG}" in
        --help|-h) HELP=1 ;;
        *) printf "verify-env.sh: unknown option '%s' (see --help)\n" "${ARG}" >&2; exit 2 ;;
    esac
done
if [[ "${HELP}" == 1 ]]; then
    printf 'Usage: just test verify-env [--help]\nBuild and test the real acceptance environment against a uid-1001 checkout.\n'
    exit 0
fi
cd "${REPO_ROOT}"
just test build
docker build -t worktool-ghostty:local -f dockerfile/Dockerfile.ghostty .
docker build -t worktool-verify:local -f dockerfile/Dockerfile.verify .
mkdir -p .agents/state
FIXTURE="$(mktemp -d "${REPO_ROOT}/.agents/state/verify-env.XXXXXX")"
cleanup() {
    docker run --rm -v "${FIXTURE}:/checkout" worktool-verify:local -c \
        'find /checkout -mindepth 1 -delete'
    rmdir "${FIXTURE}"
}
trap cleanup EXIT
# A standalone Git checkout models actions/checkout without depending on
# linked-worktree metadata outside the bind mount. Match the runner's uid.
docker run --rm -v "${FIXTURE}:/checkout" worktool-verify:local -c \
    'chown 0:0 /checkout && git init -q /checkout && printf "tracked\n" > /checkout/tracked &&
     git -C /checkout add tracked && chown -R 1001:1001 /checkout'
docker run --rm -v "${FIXTURE}:/checkout" -v "${REPO_ROOT}:/source:ro" \
    -w /checkout worktool-verify:local -c 'bats /source/test/verify-env/checkout.bats'
