#!/usr/bin/env bats

setup() {
    local root
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    judge="${root}/lib/verify_busy_latency.awk"
    runner="${BATS_TEST_TMPDIR}/runner.log"
    tap="${BATS_TEST_TMPDIR}/result.tap"
    cat >"${runner}" <<'RUNNER'
[ci] acceptance bats OK
[ci] Running system-real bats on fixture
[ci] ERROR: system-real bats failed
RUNNER
    cat >"${tap}" <<'TAP'
1..1
not ok 1 real engine: bench.sh --box dev --runs 1 --warmup 0 --shell 'fish -c exit' --max-ms 1 exits 1 with the threshold message (the gate bites on a real box)
# status : 3
# [ERROR] host too busy to measure (inconclusive): load; re-run when idle
TAP
}

judge_streams() {
    awk -f "${judge}" "${runner}" "${tap}"
}

@test "accepts complete busy-only latency evidence" {
    run judge_streams
    [ "${status}" -eq 0 ]
}

@test "rejects missing or unrelated runner failure" {
    sed -i '/ERROR/d' "${runner}"
    run judge_streams
    [ "${status}" -eq 1 ]
    printf '%s\n' '[ci] ERROR: another step failed' >>"${runner}"
    run judge_streams
    [ "${status}" -eq 1 ]
}

@test "rejects missing busy evidence or non-latency failures" {
    sed -i '/host too busy/d' "${tap}"
    run judge_streams
    [ "${status}" -eq 1 ]
    printf '%s\n' '# [ERROR] host too busy mid-run (inconclusive): load; re-run when idle' >>"${tap}"
    sed -i 's/real engine: bench.sh/other case: bench.sh/' "${tap}"
    run judge_streams
    [ "${status}" -eq 1 ]
}

@test "rejects incomplete, skipped, and mixed TAP results" {
    sed -i 's/1\.\.1/1..2/' "${tap}"
    run judge_streams
    [ "${status}" -eq 1 ]
    printf '%s\n' 'not ok 2 unrelated failure' >>"${tap}"
    run judge_streams
    [ "${status}" -eq 1 ]
    sed -i 's/not ok 2 unrelated failure/ok 2 unrelated case # skip/' "${tap}"
    run judge_streams
    [ "${status}" -eq 1 ]
}

@test "rejects a skipped case in an earlier TAP plan" {
    local previous="${BATS_TEST_TMPDIR}/previous.tap"
    printf '%s\n' '1..1' 'ok 1 unavailable case # skip' >"${previous}"
    cat "${tap}" >>"${previous}"
    mv "${previous}" "${tap}"
    run judge_streams
    [ "${status}" -eq 1 ]
}

@test "rejects an empty earlier TAP plan" {
    local previous="${BATS_TEST_TMPDIR}/previous.tap"
    printf '%s\n' '1..0' >"${previous}"
    cat "${tap}" >>"${previous}"
    mv "${previous}" "${tap}"
    run judge_streams
    [ "${status}" -eq 1 ]
}
