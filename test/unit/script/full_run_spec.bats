#!/usr/bin/env bats
# test/unit/script/full_run_spec.bats - .agents/script/monitor/full-run.sh
# (issue #837)
#
# WHAT THIS PROVES
#   Hand-over and release need a green full serial run of the EXACT commit.
#   The script finds the newest Nightly run titled `full-serial <sha>` and
#   answers green (0) only when that run completed with success; a newer
#   failure beats an older success, a run of another sha never counts, a
#   run still going is pending (3), and no run at all or a failed query is
#   not green (1). --dispatch starts a run for the sha when none exists or
#   the newest failed; --wait N polls a pending run for at most N seconds.
#
# HOW
#   A fake gh on PATH serves `gh run list` from a TSV fixture (the shape the
#   script asks for with --jq), answers the commit check (`gh api
#   repos/<repo>/commits/<sha>`, #865) and records `gh workflow run`. No
#   network.

load "${BATS_TEST_DIRNAME}/../../helper/common"

SHA=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98

setup() {
    SCRIPT="${REPO_ROOT}/.agents/script/monitor/full-run.sh"
    BIN="${BATS_TEST_TMPDIR}/bin"
    RUNS="${BATS_TEST_TMPDIR}/runs.tsv"
    GH_CALLS="${BATS_TEST_TMPDIR}/gh-calls"
    mkdir -p "${BIN}"
    : >"${RUNS}"
    cat >"${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALLS}"
[[ -z "${FAKE_GH_FAIL:-}" ]] || exit 1
case "$1 $2" in
    "api repos/"*/commits/*)
        if [[ -n "${FAKE_GH_NO_COMMIT:-}" ]]; then
            printf 'gh: No commit found for SHA: %s (HTTP %s)\n' "${2##*/}" "${FAKE_GH_NO_COMMIT}" >&2
            exit 1
        fi
        [[ -z "${FAKE_GH_API_DOWN:-}" ]] || { printf 'error connecting to api.github.com\n' >&2; exit 1; }
        printf '%s\n' "${2##*/}" ;;
    "run list") cat -- "${RUNS}" ;;
    "workflow run") [[ -z "${FAKE_FLIP:-}" ]] || cp -- "${FAKE_FLIP}" "${RUNS}" ;;
    *) exit 99 ;;
esac
EOF
    chmod +x "${BIN}/gh"
    export RUNS GH_CALLS
}

# _run <title> <status> <conclusion> <id> <createdAt>
_run() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"${RUNS}"
}

_fr() {
    PATH="${BIN}:${PATH}" run "${SCRIPT}" --repo owner/repo --sha "${SHA}" "$@"
}

@test "the newest run of the sha completed with success is green (0)" {
    _run "full-serial ${SHA}" completed success 11 2026-11-10T01:00:00Z
    _fr
    assert_success
    assert_output "full-run: ${SHA} completed success run=11"
}

@test "a newer failure beats an older success (not green, 1)" {
    _run "full-serial ${SHA}" completed success 11 2026-11-10T01:00:00Z
    _run "full-serial ${SHA}" completed failure 12 2026-11-10T02:00:00Z
    _fr
    assert_failure 1
    assert_output "full-run: ${SHA} completed failure run=12"
}

@test "a green run of another sha never counts; no run of the sha is not green (1)" {
    _run "full-serial ${OTHER}" completed success 11 2026-11-10T01:00:00Z
    _fr
    assert_failure 1
    assert_output "full-run: ${SHA} none"
}

@test "a run still going is pending (3)" {
    _run "full-serial ${SHA}" in_progress "" 13 2026-11-10T03:00:00Z
    _fr
    assert_failure 3
    assert_output "full-run: ${SHA} in_progress run=13"
}

@test "a failed query is not green (1), never pending or green" {
    _run "full-serial ${SHA}" completed success 11 2026-11-10T01:00:00Z
    FAKE_GH_FAIL=1 _fr
    assert_failure 1
}

@test "--dispatch starts a run for the sha on main when none exists and reports pending (3)" {
    _fr --dispatch
    assert_failure 3
    run grep -x "workflow run nightly.yml -R owner/repo --ref main -f sha=${SHA}" "${GH_CALLS}"
    assert_success
}

@test "--dispatch starts a new run when the newest one failed, but never when one is green or going" {
    _run "full-serial ${SHA}" completed failure 12 2026-11-10T02:00:00Z
    _fr --dispatch
    assert_failure 3
    run grep -c '^workflow run ' "${GH_CALLS}"
    assert_output 1
    : >"${GH_CALLS}"; : >"${RUNS}"
    _run "full-serial ${SHA}" completed success 11 2026-11-10T01:00:00Z
    _fr --dispatch
    assert_success
    run grep -c '^workflow run ' "${GH_CALLS}"
    assert_output 0
    : >"${GH_CALLS}"; : >"${RUNS}"
    _run "full-serial ${SHA}" queued "" 14 2026-11-10T04:00:00Z
    _fr --dispatch
    assert_failure 3
    run grep -c '^workflow run ' "${GH_CALLS}"
    assert_output 0
}

@test "--wait polls a pending run until it settles, bounded by its seconds" {
    _run "full-serial ${SHA}" in_progress "" 13 2026-11-10T03:00:00Z
    printf 'full-serial %s\tcompleted\tsuccess\t13\t2026-11-10T03:00:00Z\n' "${SHA}" >"${BATS_TEST_TMPDIR}/done.tsv"
    # The first poll flips the fixture to done.
    cat >"${BIN}/sleep" <<EOF
#!/usr/bin/env bash
cp -- "${BATS_TEST_TMPDIR}/done.tsv" "${RUNS}"
EOF
    chmod +x "${BIN}/sleep"
    WORKTOOL_FULL_RUN_POLL=1 _fr --wait 30
    assert_success
    assert_output --partial "full-run: ${SHA} completed success run=13"
}

@test "--wait gives up at its deadline and still reports pending (3)" {
    _run "full-serial ${SHA}" in_progress "" 13 2026-11-10T03:00:00Z
    WORKTOOL_FULL_RUN_POLL=1 _fr --wait 2
    assert_failure 3
}

@test "arguments: --repo and a full 40-hex --sha are required; unknown options exit 2" {
    PATH="${BIN}:${PATH}" run "${SCRIPT}" --sha "${SHA}"
    assert_failure 2
    PATH="${BIN}:${PATH}" run "${SCRIPT}" --repo owner/repo --sha main
    assert_failure 2
    PATH="${BIN}:${PATH}" run "${SCRIPT}" --repo owner/repo --sha "${SHA}" --bogus
    assert_failure 2
    assert_output "full-run.sh: unknown option '--bogus' (see --help)"
    PATH="${BIN}:${PATH}" run "${SCRIPT}" --help
    assert_success
}

@test "full-run.sh runs under set -euo pipefail" {
    run grep -c '^set -euo pipefail$' "${SCRIPT}"
    assert_output 1
}

@test "--exclude-run ignores the named run, so a run can ask about its own sha (#851)" {
    _run "full-serial ${SHA}" completed success 11 2026-11-10T01:00:00Z
    _run "full-serial ${SHA}" in_progress "" 13 2026-11-10T03:00:00Z
    _fr --exclude-run 13
    assert_success
    assert_output "full-run: ${SHA} completed success run=11"
    _fr --exclude-run abc
    assert_failure 2
}

@test "the sha must be a commit of the repo: none exits 2 before any run is listed or dispatched, a failed check is not green (1) (#865)" {
    _run "full-serial ${SHA}" completed success 11 2026-11-10T01:00:00Z
    _fr
    assert_success
    run grep -x "api repos/owner/repo/commits/${SHA} --jq .sha" "${GH_CALLS}"
    assert_success
    for code in 422 404; do
        : >"${GH_CALLS}"
        FAKE_GH_NO_COMMIT="${code}" _fr --dispatch
        assert_failure 2
        assert_output --partial "full-run.sh: ${SHA} is not a commit of owner/repo (see --help)"
        run grep -c -e '^run list' -e '^workflow run' "${GH_CALLS}"
        assert_output 0
    done
    : >"${GH_CALLS}"
    FAKE_GH_API_DOWN=1 _fr --dispatch
    assert_failure 1
    run grep -c '^workflow run' "${GH_CALLS}"
    assert_output 0
}
