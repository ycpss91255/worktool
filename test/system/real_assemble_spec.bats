#!/usr/bin/env bats
# test/system/real_assemble_spec.bats - real end-to-end assemble (DEFERRED M5)
#
# The system tier verifies a REAL `distrobox assemble create` end-to-end:
# distrobox + docker/podman running inside the test container
# (docker-in-docker), producing a usable "dev" box whose tools actually run.
#
# Standing up docker-in-docker in CI is the known feasibility challenge that
# doc/design.md defers to M5. This spec documents the intended check and is
# SKIPPED so it never blocks M2 CI (the ci.sh gates run unit + integration
# only; the system tier is not wired into a CI gate yet).

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "real distrobox assemble builds a usable dev box (DEFERRED to M5)" {
    skip "needs docker-in-docker + distrobox; deferred to M5 (see doc/design.md)"

    # Intended shape once docker-in-docker is available in the test image:
    #   cd "${REPO_ROOT}"
    #   run "${REPO_ROOT}/script/assemble.sh"
    #   assert_success
    #   run distrobox enter dev -- rg --version
    #   assert_success
    #   run distrobox enter dev -- fzf --version
    #   assert_success
}
