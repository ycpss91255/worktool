#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/apt_seed_proxy_spec.bats - script/test/apt-seed-proxy.mjs, the
# local proxy CI's image builds reach through the predefined `http_proxy`
# build arg (issue #892). It runs for real here, against a fixture origin
# (test/unit/fixture/apt_origin.mjs).
#
# Contract under test:
#   - a pool .deb present in --seed is served from it, the origin untouched,
#     and copied to --record;
#   - a pool .deb not in the seed comes from the origin the client named,
#     and is recorded only when it arrived complete;
#   - indexes (InRelease, Packages, by-hash) always go to the origin, even
#     with a same-named file in the seed; a 404 comes back as 404 and is not
#     recorded; an origin that cannot be reached is a 502;
#   - health and stats endpoints; bad arguments exit 2.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

PROXY="${REPO_ROOT}/script/test/apt-seed-proxy.mjs"
FIXTURE="${REPO_ROOT}/test/unit/fixture/apt_origin.mjs"

# Wait (bounded) until file $1 exists and is non-empty.
_wait_file() {
    local _i
    for ((_i = 0; _i < 100; _i++)); do
        [[ -s "$1" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for $1"
}

setup() {
    SEED="${BATS_TEST_TMPDIR}/seed"
    REC="${BATS_TEST_TMPDIR}/record"
    ORIGIN_DIR="${BATS_TEST_TMPDIR}/origin"
    ORIGIN_LOG="${BATS_TEST_TMPDIR}/origin.log"
    OUT="${BATS_TEST_TMPDIR}/out"
    mkdir -p "${SEED}" "${REC}" "${ORIGIN_DIR}/ubuntu/pool/main/a" "${ORIGIN_DIR}/ubuntu/dists/resolute"
    : >"${ORIGIN_LOG}"
    printf 'origin-a\n' >"${ORIGIN_DIR}/ubuntu/pool/main/a/a_1.0-1_amd64.deb"
    printf 'origin-index\n' >"${ORIGIN_DIR}/ubuntu/dists/resolute/InRelease"
    printf 'seed-b\n' >"${SEED}/b_2.0-1_amd64.deb"
    printf 'seed-index\n' >"${SEED}/InRelease"
    node "${FIXTURE}" origin "${ORIGIN_DIR}" "${ORIGIN_LOG}" "${BATS_TEST_TMPDIR}/origin.port" 3>&- &
    ORIGIN_PID=$!
    _wait_file "${BATS_TEST_TMPDIR}/origin.port"
    ORIGIN="http://127.0.0.1:$(cat "${BATS_TEST_TMPDIR}/origin.port")"
    node "${PROXY}" --port 0 --port-file "${BATS_TEST_TMPDIR}/proxy.port" --seed "${SEED}" --record "${REC}" \
        2>"${BATS_TEST_TMPDIR}/proxy.log" 3>&- &
    PROXY_PID=$!
    _wait_file "${BATS_TEST_TMPDIR}/proxy.port"
    PORT="$(cat "${BATS_TEST_TMPDIR}/proxy.port")"
}

# Stop whatever of the two servers is still running.
_stop() {
    local _pid _rc
    for _pid in "$@"; do
        if [[ -n "${_pid}" ]] && kill -0 "${_pid}" 2>/dev/null; then
            kill "${_pid}"
            _rc=0
            wait "${_pid}" 2>/dev/null || _rc=$?
        fi
    done
}

teardown() {
    _stop "${PROXY_PID:-}" "${ORIGIN_PID:-}"
}

# GET $1 through the proxy; prints the status, the body lands in ${OUT}.
_get() {
    node "${FIXTURE}" get "${PORT}" "$1" "${OUT}" "${2:-}"
}

@test "a seeded pool .deb is served from the seed without the origin, and recorded" {
    run _get "${ORIGIN}/ubuntu/pool/main/b/b_2.0-1_amd64.deb"
    assert_output 200
    run cat "${OUT}"
    assert_output seed-b
    run cat "${ORIGIN_LOG}"
    assert_output ''
    _wait_file "${REC}/b_2.0-1_amd64.deb"
    run cat "${REC}/b_2.0-1_amd64.deb"
    assert_output seed-b
    run grep -c '^seed b_2.0-1_amd64.deb$' "${BATS_TEST_TMPDIR}/proxy.log"
    assert_output 1
}

@test "a pool .deb not in the seed comes from the origin and is recorded complete" {
    run _get "${ORIGIN}/ubuntu/pool/main/a/a_1.0-1_amd64.deb"
    assert_output 200
    run cat "${OUT}"
    assert_output origin-a
    run cat "${ORIGIN_LOG}"
    assert_output /ubuntu/pool/main/a/a_1.0-1_amd64.deb
    _wait_file "${REC}/a_1.0-1_amd64.deb"
    run cat "${REC}/a_1.0-1_amd64.deb"
    assert_output origin-a
    # A download cut short is never recorded, not even as a part file.
    run _get "${ORIGIN}/ubuntu/pool/main/t/truncated_1_amd64.deb"
    refute_output 200
    sleep 0.3
    run find "${REC}" -name '*truncated*'
    assert_output ''
}

@test "indexes always go to the origin, a 404 stays a 404 and nothing of either is recorded" {
    run _get "${ORIGIN}/ubuntu/dists/resolute/InRelease"
    assert_output 200
    run cat "${OUT}"
    assert_output origin-index
    run _get "${ORIGIN}/ubuntu/dists/resolute/main/by-hash/SHA256/b_2.0-1_amd64.deb"
    assert_output 404
    run _get "${ORIGIN}/ubuntu/pool/main/z/z_9_amd64.deb"
    assert_output 404
    run cat "${ORIGIN_LOG}"
    assert_output "$(printf '%s\n' /ubuntu/dists/resolute/InRelease \
        /ubuntu/dists/resolute/main/by-hash/SHA256/b_2.0-1_amd64.deb /ubuntu/pool/main/z/z_9_amd64.deb)"
    run ls -A "${REC}"
    assert_output ''
}

@test "an origin that cannot be reached is a 502; a non-proxy target is refused" {
    _stop "${ORIGIN_PID}"
    run _get "${ORIGIN}/ubuntu/pool/main/a/a_1.0-1_amd64.deb"
    assert_output 502
    run node "${FIXTURE}" get "${PORT}" /ubuntu/pool/main/b/b_2.0-1_amd64.deb "${OUT}"
    assert_output 400
}

@test "health and stats answer; bad arguments exit 2" {
    run node "${FIXTURE}" get "${PORT}" /__apt_seed/health "${OUT}"
    assert_output 200
    _get "${ORIGIN}/ubuntu/pool/main/b/b_2.0-1_amd64.deb" >/dev/null
    run node "${FIXTURE}" get "${PORT}" /__apt_seed/stats "${OUT}"
    assert_output 200
    run cat "${OUT}"
    assert_output --partial '"seed":1'
    run -2 node "${PROXY}" --port 0
    run -2 node "${PROXY}" --port 0 --seed relative/dir
    run -2 node "${PROXY}" --port 70000 --seed "${SEED}"
    run -2 node "${PROXY}" --port 0 --seed "${SEED}" --bogus x
    assert_output --partial "unknown option '--bogus' (see --help)"
    run -0 node "${PROXY}" --help
}

@test "a package recorded earlier in the run is served again without the origin" {
    run _get "${ORIGIN}/ubuntu/pool/main/a/a_1.0-1_amd64.deb"
    assert_output 200
    _wait_file "${REC}/a_1.0-1_amd64.deb"
    run _get "${ORIGIN}/ubuntu/pool/main/a/a_1.0-1_amd64.deb"
    assert_output 200
    run cat "${OUT}"
    assert_output origin-a
    run cat "${ORIGIN_LOG}"
    assert_output /ubuntu/pool/main/a/a_1.0-1_amd64.deb
}

@test "apt-seed.sh starts the proxy, waits for its health check, prints its URL and stops it" {
    local _port _log="${BATS_TEST_TMPDIR}/seed.log"
    _port=$((20000 + RANDOM % 20000))
    run --separate-stderr "${REPO_ROOT}/script/test/apt-seed.sh" start --seed "${SEED}" --record "${REC}" --port "${_port}" --log "${_log}"
    assert_success
    assert_output "http://127.0.0.1:${_port}/"
    [[ "${stderr:-}" == *"proxy up on 127.0.0.1:${_port}"* ]] || fail "stderr: ${stderr:-}"
    PORT="${_port}" run _get "${ORIGIN}/ubuntu/pool/main/b/b_2.0-1_amd64.deb"
    assert_output 200
    run --separate-stderr "${REPO_ROOT}/script/test/apt-seed.sh" stop --log "${_log}"
    assert_success
    [[ "${stderr:-}" == *'proxy stopped, stats {"seed":1,'* ]] || fail "stderr: ${stderr:-}"
    run kill -0 "$(cat "${_log}.pid")"
    assert_failure
}

@test "apt-seed.sh fails when the proxy does not come up, and rejects bad arguments" {
    local _log="${BATS_TEST_TMPDIR}/seed.log"
    # The proxy exits at once (its seed dir is missing): no health, exit 1.
    run --separate-stderr "${REPO_ROOT}/script/test/apt-seed.sh" start --seed "${BATS_TEST_TMPDIR}/missing" \
        --port $((20000 + RANDOM % 20000)) --log "${_log}"
    assert_failure 1
    [[ "${stderr:-}" == *'did not come up'* && "${stderr:-}" == *'--seed is not a directory'* ]] || fail "stderr: ${stderr:-}"
    run -2 "${REPO_ROOT}/script/test/apt-seed.sh" start --port 3142 --log "${_log}"
    run -2 "${REPO_ROOT}/script/test/apt-seed.sh" stop
    run -2 "${REPO_ROOT}/script/test/apt-seed.sh" start --seed "${SEED}" --port x --log "${_log}"
    run -2 "${REPO_ROOT}/script/test/apt-seed.sh" --bogus
    assert_output "apt-seed.sh: unknown option '--bogus' (see --help)"
    run -0 "${REPO_ROOT}/script/test/apt-seed.sh" --help
}
