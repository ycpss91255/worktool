#!/usr/bin/env bash
# test/helper/common.bash - shared bats test helpers for worktool
#
# Loaded by each spec via:
#   load "${BATS_TEST_DIRNAME}/../helper/common"
#
# Provides:
#   - REPO_ROOT / LIB_DIR path exports
#   - bats-support / bats-assert loaders (baked into the test image at
#     /usr/lib/bats, see dockerfile/Dockerfile.test)

# built-in bats `load` needs paths without the .bash suffix.

# --- Path constants (resolved once at load time) ----------------------------
COMMON_HELPER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export COMMON_HELPER_DIR

REPO_ROOT="$(cd -- "${COMMON_HELPER_DIR}/../.." && pwd -P)"
export REPO_ROOT

export LIB_DIR="${REPO_ROOT}/lib"
export TEST_DIR="${REPO_ROOT}/test"

# --- Load bats-* extensions --------------------------------------------------
# The test image bakes these at /usr/lib/bats/{bats-support,bats-assert}.
# Each ships a load.bash that wires up the helper functions when sourced.
_BATS_LIB="/usr/lib/bats"
if [[ -f "${_BATS_LIB}/bats-support/load.bash" ]]; then
    # shellcheck source=/dev/null  # baked into the test image at /usr/lib
    load "${_BATS_LIB}/bats-support/load"
fi
if [[ -f "${_BATS_LIB}/bats-assert/load.bash" ]]; then
    # shellcheck source=/dev/null  # baked into the test image at /usr/lib
    load "${_BATS_LIB}/bats-assert/load"
fi
