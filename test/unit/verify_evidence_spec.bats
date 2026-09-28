#!/usr/bin/env bats
# test/unit/verify_evidence_spec.bats - script/verify/evidence.sh: the M3
# acceptance items that read external evidence (6.1 / 6.2 / 6.3).
#
# The document's copy-and-paste blocks could not be tested, so this spec is
# what makes the move out of doc/acceptance.md worth anything. Its subject is
# NOT "does the check find the evidence" - the evidence lives on GitHub and
# no unit test reaches it. Its subject is the one property the document could
# never prove about itself:
#
#   NO FAILURE MAY READ AS A PASS.
#
# So every case here breaks one stage the check depends on - `gh`, `jq`,
# `grep`, the tool lookup - and asserts a non-zero exit. The sharp ones are
# the PLAUSIBLE-OUTPUT cases: the stub still prints exactly what a working
# tool would print and then exits non-zero. That is the bug this work
# removes; a check that reads the output and ignores the status goes green on
# every one of them.
#
# The happy-path cases are the counterweight: they assert the exact lines the
# document shows, so the failure cases cannot be passing for the trivial
# reason that the check never worked at all.
#
# Everything external is stubbed on PATH (no network, no gh, no real jq in
# the test image). The stubs are deliberately dumb: they answer only the
# queries this script makes, and an unexpected query is a loud failure.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    EVIDENCE="${REPO_ROOT}/script/verify/evidence.sh"

    # Resolved BEFORE the stub directory goes on PATH: the grep stub
    # delegates to the real one for everything it is not asked to break.
    FAKE_REAL_GREP="$(command -v grep)"
    export FAKE_REAL_GREP

    BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${BIN}"
    PATH="${BIN}:${PATH}"
    export PATH

    FAKE_GH_LOG="${BATS_TEST_TMPDIR}/gh.log"
    FAKE_DISTROBOX_LOG="${BATS_TEST_TMPDIR}/distrobox.log"
    FAKE_DISTROBOX_STATE="${BATS_TEST_TMPDIR}/boxes"
    export FAKE_GH_LOG FAKE_DISTROBOX_LOG FAKE_DISTROBOX_STATE
    : >"${FAKE_GH_LOG}"
    : >"${FAKE_DISTROBOX_LOG}"
    : >"${FAKE_DISTROBOX_STATE}"

    # Keep the checks quick when a case does let a real `timeout` run.
    export EVIDENCE_GH_TIMEOUT=20
    export EVIDENCE_BOX_TIMEOUT=20
}

# --- Stubs -------------------------------------------------------------------

# A fake `gh` that answers exactly the five queries evidence.sh makes, with
# the evidence M3 actually has. Two environment knobs drive the failures:
#   FAKE_GH_FAIL_MODE   which query fails: checks|view|claude|codex|prlist
#   FAKE_GH_FAIL_QUIET  1 = fail silently; 0 (default) = print the normal,
#                       entirely plausible answer AND THEN exit 1
_stub_gh() {
    cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
# Fake gh for verify_evidence_spec.bats. Answers only what evidence.sh asks.
set -u
printf '%s\n' "$*" >>"${FAKE_GH_LOG}"

_issue_of() {
    case "$1" in
        152) printf '151\n' ;;
        153) printf '149\n' ;;
        154) printf '150\n' ;;
        155) printf '21\n' ;;
        156) printf '23\n' ;;
        165) printf '164\n' ;;
        166) printf '163\n' ;;
        167) printf '160\n' ;;
        168) printf '161\n' ;;
        169) printf '162\n' ;;
        *) return 1 ;;
    esac
}

# #152 predates the arm64 runner: 8 checks, none per-architecture. From #153
# on: 7 amd64 + 7 arm64 + the aggregator = 15, all in the pass bucket.
# FAKE_GH_DUAL_ARCH=1 replaces those with ONE check whose name carries both
# architecture labels - the shape two independent substring tests cannot tell
# from a real two-architecture matrix.
_checks_json() {
    local pr="$1" i out=""
    if [ "$pr" = 152 ]; then
        for i in 1 2 3 4 5 6 7 8; do
            out="${out}{\"name\":\"gate-${i}\",\"bucket\":\"${FAKE_GH_BUCKET:-pass}\"},"
        done
    elif [ "${FAKE_GH_DUAL_ARCH:-0}" = 1 ]; then
        out='{"name":"lint (ubuntu-latest, ubuntu-24.04-arm)","bucket":"pass"},'
        out="${out}{\"name\":\"ci-passed\",\"bucket\":\"${FAKE_GH_BUCKET:-pass}\"},"
    else
        for i in 1 2 3 4 5 6 7; do
            out="${out}{\"name\":\"gate-${i} (ubuntu-latest)\",\"bucket\":\"pass\"},"
            out="${out}{\"name\":\"gate-${i} (ubuntu-24.04-arm)\",\"bucket\":\"pass\"},"
        done
        out="${out}{\"name\":\"ci-passed\",\"bucket\":\"${FAKE_GH_BUCKET:-pass}\"},"
    fi
    printf '[%s]\n' "${out%,}"
}

_body_of() {
    local issue
    issue="${FAKE_GH_CLOSES:-$(_issue_of "$1")}" || return 1
    printf 'What this PR does.\n\nCloses #%s\n' "${issue}"
}

# FAKE_GH_ONE_FOLLOWUP=1 points all four blocked PRs at the SAME follow-up
# issue, so one issue and one fix PR answer for every one of them.
_claude_of() {
    if [ "${FAKE_GH_ONE_FOLLOWUP:-0}" = 1 ]; then
        case "$1" in
            152 | 153 | 154 | 155)
                printf '[claude] blockers recorded in follow-up issue #163\n'
                return 0
                ;;
        esac
    fi
    case "$1" in
        22)  printf '[claude] bench on this host\nshell: median=176.9 ms\n維持 docker + 預設 runc\n' ;;
        148) printf '[claude] runner survey\n只用 LTS\nubuntu-24.04-arm\n' ;;
        21)  printf '[claude] auto-enter decision\n預設 = 直接進盒\n每個決策印 log\n' ;;
        152) printf '[claude] blockers recorded in follow-up issue #163\n' ;;
        153) printf '[claude] blockers recorded in follow-up issue #164\n' ;;
        154) printf '[claude] blockers recorded in follow-up issue #162\n' ;;
        155) printf '[claude] blockers recorded in follow-up issue #161\n' ;;
        *) : ;;
    esac
}

_codex_of() {
    case "$1" in
        156 | 165 | 166 | 167 | 168 | 169) printf '[codex] review round 3\n可合併\n' ;;
        152 | 153 | 154 | 155) printf '[codex] re-review after the quota came back\n不可合併\n' ;;
        *) printf 'null\n' ;;
    esac
}

kind=unknown
out=""
case "$1" in
    pr)
        case "$2" in
            checks)
                kind=checks
                out="$(_checks_json "$3")"
                ;;
            view)
                kind=view
                out="$(_body_of "$3")"
                ;;
            list)
                kind=prlist
                follow=""
                for a in "$@"; do
                    case "$a" in
                        "Closes #"*" in:body")
                            follow="${a#Closes #}"
                            follow="${follow%% in:body}"
                            ;;
                    esac
                done
                case "${follow}" in
                    163) out="166" ;;
                    164) out="165" ;;
                    162) out="169" ;;
                    161) out="168" ;;
                    *) out="" ;;
                esac
                ;;
        esac
        ;;
    api)
        number="${2#*/issues/}"
        number="${number%/comments}"
        if printf '%s\n' "$@" | "${FAKE_REAL_GREP}" -q '\[codex\]'; then
            kind=codex
            out="$(_codex_of "${number}")"
        else
            kind=claude
            out="$(_claude_of "${number}")"
        fi
        ;;
esac

if [ "${kind}" = unknown ]; then
    printf 'fake gh: unexpected query: %s\n' "$*" >&2
    exit 3
fi

# The shape that matters: an answer that looks right, from a call that failed.
if [ "${kind}" = "${FAKE_GH_FAIL_MODE:-none}" ]; then
    [ "${FAKE_GH_FAIL_QUIET:-0}" = 1 ] || { [ -z "${out}" ] || printf '%s\n' "${out}"; }
    exit 1
fi
[ -z "${out}" ] || printf '%s\n' "${out}"
exit 0
STUB
    chmod +x "${BIN}/gh"
}

# A fake `jq` that understands exactly the five filters evidence.sh uses over
# the `gh pr checks` array. Knobs:
#   FAKE_JQ_FAIL        substring of the filter that must fail (or `all`)
#   FAKE_JQ_FAIL_QUIET  1 = fail silently; 0 = print the right answer, exit 1
#   FAKE_JQ_LENGTH      override what `length` answers (to feed a non-number)
_stub_jq() {
    cat >"${BIN}/jq" <<'STUB'
#!/usr/bin/env bash
# Fake jq for verify_evidence_spec.bats (the test image ships no jq).
set -u
filter="${!#}"
input="$(cat)"

_count() { printf '%s' "${input}" | "${FAKE_REAL_GREP}" -o "$1" | wc -l | tr -d ' '; }

# Every check name holding the literal $1, one per line - what
# `.[].name | select(test("<arch>"))` answers now that evidence.sh counts
# distinct NAMES per architecture instead of substring hits.
_names() {
    local _line _n
    while IFS= read -r _line; do
        _n="${_line#\"name\":\"}"
        _n="${_n%\"}"
        case "${_n}" in
            *"$1"*) printf '%s\n' "${_n}" ;;
        esac
    done < <(printf '%s' "${input}" | "${FAKE_REAL_GREP}" -o '"name":"[^"]*"')
}

case "${filter}" in
    type) out="array" ;;
    length) out="${FAKE_JQ_LENGTH:-$(_count '{"name"')}" ;;
    *'.bucket != "pass"'*)
        total="$(_count '{"name"')"
        passed="$(_count '"bucket":"pass"')"
        out="$((total - passed))"
        ;;
    *'ubuntu-24.04-arm'*) out="$(_names 'ubuntu-24.04-arm')" ;;
    *'ubuntu-latest'*) out="$(_names 'ubuntu-latest')" ;;
    *)
        printf 'fake jq: unsupported filter: %s\n' "${filter}" >&2
        exit 3
        ;;
esac

want="${FAKE_JQ_FAIL:-none}"
if [ "${want}" = all ] || { [ "${want}" != none ] && case "${filter}" in *"${want}"*) true ;; *) false ;; esac; }; then
    [ "${FAKE_JQ_FAIL_QUIET:-0}" = 1 ] || printf '%s\n' "${out}"
    exit 1
fi
printf '%s\n' "${out}"
STUB
    chmod +x "${BIN}/jq"
}

# A fake `grep` that is the real grep unless the pattern it is handed
# contains FAKE_GREP_FAIL_PATTERN. Targeting one pattern keeps the other
# greps in the run (and inside the other stubs) honest.
#   FAKE_GREP_FAIL_QUIET  1 = fail silently; 0 = print the real matches,
#                         exit 1 anyway
_stub_grep() {
    cat >"${BIN}/grep" <<'STUB'
#!/usr/bin/env bash
# Fake grep for verify_evidence_spec.bats.
set -u
want="${FAKE_GREP_FAIL_PATTERN:-}"
hit=0
if [ -n "${want}" ]; then
    for a in "$@"; do
        case "$a" in
            *"${want}"*) hit=1 ;;
        esac
    done
fi
if [ "${hit}" = 1 ]; then
    [ "${FAKE_GREP_FAIL_QUIET:-0}" = 1 ] || "${FAKE_REAL_GREP}" "$@"
    exit 1
fi
exec "${FAKE_REAL_GREP}" "$@"
STUB
    chmod +x "${BIN}/grep"
}

# A fake `distrobox` backed by a one-name-per-line state file. Knobs:
#   FAKE_DISTROBOX_LIST_FAIL  1 = `list` exits 1 (cannot tell)
#   FAKE_DISTROBOX_LIST_EMPTY 1 = `list` exits 0 printing nothing
#   FAKE_DISTROBOX_RM_NOOP    1 = `rm` reports success and removes nothing
_stub_distrobox() {
    cat >"${BIN}/distrobox" <<'STUB'
#!/usr/bin/env bash
# Fake distrobox for verify_evidence_spec.bats.
set -u
printf '%s\n' "$*" >>"${FAKE_DISTROBOX_LOG}"
case "$1" in
    list)
        [ "${FAKE_DISTROBOX_LIST_FAIL:-0}" = 1 ] && exit 1
        [ "${FAKE_DISTROBOX_LIST_EMPTY:-0}" = 1 ] && exit 0
        printf 'ID | NAME | STATUS | IMAGE\n'
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            printf '0badc0de | %s | Up 1 minute | docker.io/library/ubuntu\n' "${name}"
        done <"${FAKE_DISTROBOX_STATE}"
        ;;
    create) printf '%s\n' "${2:-dev}" >>"${FAKE_DISTROBOX_STATE}" ;;
    rm)
        [ "${FAKE_DISTROBOX_RM_NOOP:-0}" = 1 ] || : >"${FAKE_DISTROBOX_STATE}"
        ;;
esac
exit 0
STUB
    chmod +x "${BIN}/distrobox"
}

# Every stub, all answering correctly: the baseline the failure cases break.
_stub_all_ok() {
    _stub_gh
    _stub_jq
    _stub_grep
}

# Run one item function with the dispatcher's stderr out of the way, so the
# assertions see exactly the lines the document prints.
_run_evidence_item() {
    run bash -c 'source "$1"; "$2" 2>/dev/null' _ "${EVIDENCE}" "$1"
}

# --- The spec guards itself --------------------------------------------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- CLI contract ------------------------------------------------------------

@test "--help exits 0 and prints the usage" {
    run "${EVIDENCE}" --help
    assert_success
    assert_output --partial "Usage: evidence.sh"
    assert_output --partial "--allow-realbox"
}

@test "-h exits 0 and prints the usage" {
    run "${EVIDENCE}" -h
    assert_success
    assert_output --partial "Usage: evidence.sh"
}

@test "an unknown option exits 2 and names the option" {
    run "${EVIDENCE}" --bogus
    assert_failure 2
    assert_output --partial "evidence.sh: unknown option '--bogus' (see --help)"
}

@test "an unknown item exits 2 and names the item" {
    run "${EVIDENCE}" 9.9
    assert_failure 2
    assert_output --partial "evidence.sh: unknown item '9.9' (see --help)"
}

@test "--list prints the three items and their group" {
    run "${EVIDENCE}" --list
    assert_success
    assert_line "6.1 gh"
    assert_line "6.2 gh"
    assert_line "6.3 gh"
}

@test "no argument runs 6.1, 6.2 and 6.3 in order and exits 0 when all pass" {
    _stub_all_ok
    run "${EVIDENCE}"
    assert_success
    assert_line "#152 total=8 nonpass=0 amd=0 arm=0 both=0 closes=1 issue=#151"
    assert_line "distinct=10"
    assert_line "#22 median-ms:1 runc:1"
    assert_line "#156 mergeable"
}

@test "no argument stops at the first failing item: 6.2 is never queried" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=checks run "${EVIDENCE}"
    assert_failure
    assert_line "#152 gh-failed"
    refute_line --partial "median-ms"
}

@test "one item id runs that item only" {
    _stub_all_ok
    run "${EVIDENCE}" 6.3
    assert_success
    assert_line "#156 mergeable"
    refute_line --partial "distinct="
}

# --- 6.1 the happy path ------------------------------------------------------

@test "6.1: prints the document's lines and exits 0 when every PR checks out" {
    _stub_all_ok
    _run_evidence_item item_6_1
    assert_success
    assert_line --index 0 "#152 total=8 nonpass=0 amd=0 arm=0 both=0 closes=1 issue=#151"
    assert_line --index 1 "#153 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#149"
    assert_line --index 2 "#154 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#150"
    assert_line --index 3 "#155 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#21"
    assert_line --index 4 "#156 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#23"
    assert_line --index 5 "#165 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#164"
    assert_line --index 6 "#166 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#163"
    assert_line --index 7 "#167 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#160"
    assert_line --index 8 "#168 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#161"
    assert_line --index 9 "#169 total=15 nonpass=0 amd=7 arm=7 both=0 closes=1 issue=#162"
    assert_line --index 10 "distinct=10"
    assert_line --index 11 "rc=0"
}

# --- 6.1 cannot false-pass ---------------------------------------------------

@test "6.1: gh missing from PATH fails and says the check cannot run here" {
    run bash -c 'source "$1"; PATH=/nonexistent; item_6_1' _ "${EVIDENCE}"
    assert_failure
    assert_output --partial "gh not found on PATH"
    assert_output --partial "a check that cannot run is a failure, not a skip"
    assert_line "rc=1"
}

@test "6.1: gh pr checks failing silently is gh-failed, not zero checks" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=checks FAKE_GH_FAIL_QUIET=1 _run_evidence_item item_6_1
    assert_failure
    assert_line "#152 gh-failed"
    refute_line --partial "total=0"
    assert_line "rc=1"
}

@test "6.1: gh pr checks printing plausible JSON but exiting 1 is gh-failed (PLAUSIBLE OUTPUT)" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=checks FAKE_GH_FAIL_QUIET=0 _run_evidence_item item_6_1
    assert_failure
    assert_line "#152 gh-failed"
    refute_line --partial "nonpass=0"
    assert_line "rc=1"
}

@test "6.1: gh pr view printing a plausible body but exiting 1 is gh-failed (PLAUSIBLE OUTPUT)" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=view FAKE_GH_FAIL_QUIET=0 _run_evidence_item item_6_1
    assert_failure
    assert_line "#152 gh-failed"
    refute_line --partial "closes=1"
    assert_line "rc=1"
}

@test "6.1: gh exiting 0 with no checks at all is empty-checks, never total=0" {
    _stub_all_ok
    cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${BIN}/gh"
    _run_evidence_item item_6_1
    assert_failure
    assert_line "#152 empty-checks"
    refute_line --partial "total=0"
    assert_line "rc=1"
}

@test "6.1: gh exiting 0 with an empty PR body is empty-body, never closes=0" {
    _stub_all_ok
    cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -u
case "$2" in
    checks) printf '[{"name":"gate-1","bucket":"pass"}]\n' ;;
    view) : ;;
esac
exit 0
STUB
    chmod +x "${BIN}/gh"
    _run_evidence_item item_6_1
    assert_failure
    assert_line "#152 empty-body"
    refute_line --partial "closes=0"
    assert_line "rc=1"
}

@test "6.1: jq printing a plausible count but exiting 1 is jq-failed (PLAUSIBLE OUTPUT)" {
    _stub_all_ok
    FAKE_JQ_FAIL=length FAKE_JQ_FAIL_QUIET=0 _run_evidence_item item_6_1
    assert_failure
    assert_line "#152 jq-failed"
    refute_line --partial "total=8"
    assert_line "rc=1"
}

@test "6.1: jq exiting 0 with a non-numeric count is bad-counts, never a comparison on null" {
    _stub_all_ok
    FAKE_JQ_LENGTH=null _run_evidence_item item_6_1
    assert_failure
    assert_line "#152 bad-counts"
    assert_line "rc=1"
}

@test "6.1: grep printing the Closes lines but exiting 1 is grep-failed (PLAUSIBLE OUTPUT)" {
    _stub_all_ok
    FAKE_GREP_FAIL_PATTERN='^Closes #' FAKE_GREP_FAIL_QUIET=0 _run_evidence_item item_6_1
    assert_failure
    assert_line "#152 grep-failed"
    refute_line --partial "closes=1"
    assert_line "rc=1"
}

@test "6.1: a check outside the pass bucket fails the item (the assertion is not vacuous)" {
    _stub_all_ok
    FAKE_GH_BUCKET=fail _run_evidence_item item_6_1
    assert_failure
    assert_line "#152 total=8 nonpass=8 amd=0 arm=0 both=0 closes=1 issue=#151"
    assert_line "rc=1"
}

@test "6.1: one check named for BOTH architectures does not prove two architectures ran" {
    _stub_all_ok
    # `lint (ubuntu-latest, ubuntu-24.04-arm)` satisfies a substring test for
    # amd64 and a substring test for arm64 at the same time. Counting distinct
    # names per architecture and requiring the two sets to be disjoint is what
    # tells that one job apart from a real matrix.
    FAKE_GH_DUAL_ARCH=1 _run_evidence_item item_6_1
    assert_failure
    assert_line "#153 total=2 nonpass=0 amd=1 arm=1 both=1 closes=1 issue=#149"
    assert_line "rc=1"
}

@test "6.1: ten PRs closing the same issue fail on distinct (the assertion is not vacuous)" {
    _stub_all_ok
    FAKE_GH_CLOSES=151 _run_evidence_item item_6_1
    assert_failure
    assert_line "distinct=1"
    assert_line "rc=1"
}

# --- 6.2 ---------------------------------------------------------------------

@test "6.2: prints the document's lines and exits 0 when every decision is recorded" {
    _stub_all_ok
    _run_evidence_item item_6_2
    assert_success
    assert_line --index 0 "#22 median-ms:1 runc:1"
    assert_line --index 1 "#148 lts-only:1 arm-runner:1"
    assert_line --index 2 "#21 default-enter:1 log:1"
    assert_line --index 3 "rc=0"
}

@test "6.2: gh missing from PATH fails and says the check cannot run here" {
    run bash -c 'source "$1"; PATH=/nonexistent; item_6_2' _ "${EVIDENCE}"
    assert_failure
    assert_output --partial "gh not found on PATH"
    assert_line "rc=1"
}

@test "6.2: a failing comment query is gh-failed in every cell, never 0" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=claude FAKE_GH_FAIL_QUIET=1 _run_evidence_item item_6_2
    assert_failure
    assert_line "#22 median-ms:gh-failed runc:gh-failed"
    refute_line --partial "median-ms:0"
    assert_line "rc=1"
}

@test "6.2: a comment query printing the real comments but exiting 1 is gh-failed (PLAUSIBLE OUTPUT)" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=claude FAKE_GH_FAIL_QUIET=0 _run_evidence_item item_6_2
    assert_failure
    assert_line "#22 median-ms:gh-failed runc:gh-failed"
    refute_line --partial "median-ms:1"
    assert_line "rc=1"
}

@test "6.2: an issue with no [claude] comment at all is no-comments, never 0" {
    _stub_all_ok
    cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${BIN}/gh"
    _run_evidence_item item_6_2
    assert_failure
    assert_line "#22 median-ms:no-comments runc:no-comments"
    refute_line --partial "median-ms:0"
    assert_line "rc=1"
}

@test "6.2: grep printing the matching comment but exiting 1 is grep-failed (PLAUSIBLE OUTPUT)" {
    _stub_all_ok
    FAKE_GREP_FAIL_PATTERN='只用 LTS' FAKE_GREP_FAIL_QUIET=0 _run_evidence_item item_6_2
    assert_failure
    assert_line "#148 lts-only:grep-failed arm-runner:1"
    assert_line "rc=1"
}

@test "6.2: a decision that was never written down is 0 and fails (the assertion is not vacuous)" {
    _stub_all_ok
    cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
printf '[claude] nothing concrete here\n'
exit 0
STUB
    chmod +x "${BIN}/gh"
    _run_evidence_item item_6_2
    assert_failure
    assert_line "#22 median-ms:0 runc:0"
    assert_line "rc=1"
}

# --- 6.3 ---------------------------------------------------------------------

@test "6.3: prints the document's lines and exits 0 when the verdict chain holds" {
    _stub_all_ok
    _run_evidence_item item_6_3
    assert_success
    assert_line --index 0 "#156 mergeable"
    assert_line --index 1 "#165 mergeable"
    assert_line --index 2 "#166 mergeable"
    assert_line --index 3 "#167 mergeable"
    assert_line --index 4 "#168 mergeable"
    assert_line --index 5 "#169 mergeable"
    assert_line --index 6 "#152 blocked -> follow-up #163 fixed-by PR #166 (closes #163, mergeable) ok"
    assert_line --index 7 "#153 blocked -> follow-up #164 fixed-by PR #165 (closes #164, mergeable) ok"
    assert_line --index 8 "#154 blocked -> follow-up #162 fixed-by PR #169 (closes #162, mergeable) ok"
    assert_line --index 9 "#155 blocked -> follow-up #161 fixed-by PR #168 (closes #161, mergeable) ok"
    assert_line --index 10 "distinct-follow-ups=4 distinct-fix-prs=4"
    assert_line --index 11 "rc=0"
}

@test "6.3: one follow-up issue and one fix PR cannot answer for all four blocked PRs" {
    _stub_all_ok
    # Every row is internally consistent - blocked, a follow-up, a merged PR
    # that closes it, a mergeable verdict on that PR - and prints `ok`. It is
    # still the same issue and the same PR four times over, so three of the
    # four sets of blockers were never recorded anywhere.
    FAKE_GH_ONE_FOLLOWUP=1 _run_evidence_item item_6_3
    assert_failure
    assert_line "#152 blocked -> follow-up #163 fixed-by PR #166 (closes #163, mergeable) ok"
    assert_line "#155 blocked -> follow-up #163 fixed-by PR #166 (closes #163, mergeable) ok"
    assert_line "distinct-follow-ups=1 distinct-fix-prs=1"
    assert_line "rc=1"
}

@test "6.3: gh missing from PATH fails and says the check cannot run here" {
    run bash -c 'source "$1"; PATH=/nonexistent; item_6_3' _ "${EVIDENCE}"
    assert_failure
    assert_output --partial "gh not found on PATH"
    assert_line "rc=1"
}

@test "6.3: a failing codex query is gh-failed, never a verdict" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=codex FAKE_GH_FAIL_QUIET=1 _run_evidence_item item_6_3
    assert_failure
    assert_line "#156 gh-failed"
    refute_line "#156 mergeable"
    assert_line "rc=1"
}

@test "6.3: a codex query printing the verdict but exiting 1 is gh-failed (PLAUSIBLE OUTPUT)" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=codex FAKE_GH_FAIL_QUIET=0 _run_evidence_item item_6_3
    assert_failure
    assert_line "#156 gh-failed"
    refute_line "#156 mergeable"
    assert_line "rc=1"
}

@test "6.3: a PR with no [codex] comment is no-codex, never mergeable" {
    _stub_all_ok
    cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
printf 'null\n'
exit 0
STUB
    chmod +x "${BIN}/gh"
    _run_evidence_item item_6_3
    assert_failure
    assert_line "#156 no-codex"
    refute_line "#156 mergeable"
    assert_line "rc=1"
}

@test "6.3: grep printing the verdict line but exiting 1 is gh-failed (PLAUSIBLE OUTPUT)" {
    _stub_all_ok
    FAKE_GREP_FAIL_PATTERN='可合併' FAKE_GREP_FAIL_QUIET=0 _run_evidence_item item_6_3
    assert_failure
    assert_line "#156 gh-failed"
    refute_line "#156 mergeable"
    assert_line "rc=1"
}

@test "6.3: a failing [claude] query on a blocked PR is gh-failed, not a missing follow-up" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=claude FAKE_GH_FAIL_QUIET=0 _run_evidence_item item_6_3
    assert_failure
    assert_line "#152 gh-failed"
    refute_line --partial "#152 blocked"
    assert_line "rc=1"
}

@test "6.3: gh pr list printing the fixing PR but exiting 1 is gh-failed (PLAUSIBLE OUTPUT)" {
    _stub_all_ok
    FAKE_GH_FAIL_MODE=prlist FAKE_GH_FAIL_QUIET=0 _run_evidence_item item_6_3
    assert_failure
    assert_line "#152 gh-failed"
    refute_line --partial "fixed-by PR #166"
    assert_line "rc=1"
}

@test "6.3: no merged PR closing the follow-up issue is no-fix-pr" {
    _stub_all_ok
    cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -u
case "$1:$2" in
    pr:list) exit 0 ;;
esac
if printf '%s\n' "$@" | "${FAKE_REAL_GREP}" -q '\[codex\]'; then
    printf '[codex] review\n不可合併\n'
    exit 0
fi
printf '[claude] blockers recorded in follow-up issue #163\n'
exit 0
STUB
    chmod +x "${BIN}/gh"
    _run_evidence_item item_6_3
    assert_failure
    assert_line "#152 no-fix-pr"
    assert_line "rc=1"
}

@test "6.3: a PR whose last verdict is 不可合併 reads as blocked (the assertion is not vacuous)" {
    _stub_all_ok
    cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
printf '[codex] review\n不可合併\n'
exit 0
STUB
    chmod +x "${BIN}/gh"
    _run_evidence_item item_6_3
    assert_failure
    assert_line "#156 blocked"
    assert_line "rc=1"
}

# --- The realbox group -------------------------------------------------------
# No 6.x item is in this group; these cases pin the guards the dispatcher
# applies to any item that is (M3 5.1 / 5.2), because a guard nobody has run
# is a guard nobody can trust.

# Declare a throwaway realbox item in a sourced copy of the script and run it
# through the dispatcher. $1 is extra shell run before the dispatch.
_dispatch_realbox_item() {
    run bash -c '
        source "$1"
        EVIDENCE_ITEMS+=(9.9)
        EVIDENCE_ITEM_GROUP[9.9]=realbox
        item_9_9() { printf "the realbox item ran\n"; }
        eval "$2"
        _run_item 9.9
    ' _ "${EVIDENCE}" "$1"
}

@test "realbox: an item in that group is refused without --allow-realbox and never runs" {
    _dispatch_realbox_item ':'
    assert_failure 2
    assert_output --partial "item 9.9 is in group realbox"
    assert_output --partial "--allow-realbox"
    refute_line "the realbox item ran"
}

@test "realbox: the opt-in lets the dispatcher run the item" {
    _dispatch_realbox_item 'EVIDENCE_ALLOW_REALBOX=1'
    assert_success
    assert_line "the realbox item ran"
}

@test "realbox: _realbox_begin refuses when a box named dev already exists and deletes nothing" {
    _stub_distrobox
    printf 'dev\n' >"${FAKE_DISTROBOX_STATE}"
    run bash -c '
        source "$1"
        EVIDENCE_ALLOW_REALBOX=1
        _realbox_begin 5.1
    ' _ "${EVIDENCE}"
    assert_failure 2
    assert_output --partial "already exists - refusing"
    refute_output --partial "preexisting-dev=0"
    run cat "${FAKE_DISTROBOX_LOG}"
    refute_line --partial "rm"
    run cat "${FAKE_DISTROBOX_STATE}"
    assert_line "dev"
}

@test "realbox: _realbox_begin refuses when distrobox list fails - it never guesses" {
    _stub_distrobox
    FAKE_DISTROBOX_LIST_FAIL=1 run bash -c '
        source "$1"
        EVIDENCE_ALLOW_REALBOX=1
        _realbox_begin 5.1
    ' _ "${EVIDENCE}"
    assert_failure 2
    assert_output --partial "cannot tell whether 'dev' exists"
    refute_output --partial "preexisting-dev=0"
    run cat "${FAKE_DISTROBOX_LOG}"
    refute_line --partial "rm"
}

@test "realbox: an empty box listing is 'cannot tell', not 'no such box'" {
    _stub_distrobox
    FAKE_DISTROBOX_LIST_EMPTY=1 run bash -c '
        source "$1"
        EVIDENCE_ALLOW_REALBOX=1
        _realbox_begin 5.1
    ' _ "${EVIDENCE}"
    assert_failure 2
    assert_output --partial "cannot tell whether 'dev' exists"
}

@test "realbox: ownership is claimed before anything is created, and EXIT INT TERM HUP are armed" {
    _stub_distrobox
    run bash -c '
        source "$1"
        EVIDENCE_ALLOW_REALBOX=1
        _realbox_begin 5.1 || exit 9
        [ -f "${EVIDENCE_REALBOX_CLAIM}" ] && printf "claim=yes\n"
        [ "${EVIDENCE_REALBOX_OWNED}" -eq 1 ] && printf "owned=1\n"
        trap -p EXIT INT TERM HUP
        trap - EXIT INT TERM HUP
    ' _ "${EVIDENCE}"
    assert_success
    assert_line "preexisting-dev=0"
    assert_line "claim=yes"
    assert_line "owned=1"
    assert_output --partial "_realbox_trap' EXIT"
    assert_output --partial "_realbox_trap' SIGINT"
    assert_output --partial "_realbox_trap' SIGTERM"
    assert_output --partial "_realbox_trap' SIGHUP"
}

@test "realbox: leaving the run removes the box it claimed and reports cleanup-rc=0" {
    _stub_distrobox
    run bash -c '
        source "$1"
        EVIDENCE_ALLOW_REALBOX=1
        _realbox_begin 5.1 || exit 9
        distrobox create dev
    ' _ "${EVIDENCE}"
    assert_success
    assert_line "preexisting-dev=0"
    assert_line "cleanup-rc=0"
    run cat "${FAKE_DISTROBOX_LOG}"
    assert_line "rm -f dev"
    # The state file is now empty, so assert on the whole output: `lines` is
    # unset for an empty capture and refute_line would error instead of pass.
    run cat "${FAKE_DISTROBOX_STATE}"
    refute_output --partial "dev"
}

@test "realbox: a box that survives cleanup fails the run" {
    _stub_distrobox
    FAKE_DISTROBOX_RM_NOOP=1 run bash -c '
        source "$1"
        EVIDENCE_ALLOW_REALBOX=1
        _realbox_begin 5.1 || exit 9
        distrobox create dev
    ' _ "${EVIDENCE}"
    assert_failure
    assert_line "cleanup-rc=1"
    assert_output --partial "survived cleanup - remove it by hand"
}

@test "realbox: a file backed up before the run is restored on the way out" {
    _stub_distrobox
    CONF="${BATS_TEST_TMPDIR}/config"
    printf 'original\n' >"${CONF}"
    run bash -c '
        source "$1"
        EVIDENCE_ALLOW_REALBOX=1
        _realbox_begin 5.1 || exit 9
        _realbox_backup "$2" || exit 8
        printf "clobbered\n" >"$2"
    ' _ "${EVIDENCE}" "${CONF}"
    assert_success
    assert_line "cleanup-rc=0"
    run cat "${CONF}"
    assert_line "original"
    refute_line "clobbered"
}

@test "realbox: a path that did not exist before the run is removed again on the way out" {
    _stub_distrobox
    CONF="${BATS_TEST_TMPDIR}/new-config"
    run bash -c '
        source "$1"
        EVIDENCE_ALLOW_REALBOX=1
        _realbox_begin 5.1 || exit 9
        _realbox_backup "$2" || exit 8
        printf "written by the run\n" >"$2"
    ' _ "${EVIDENCE}" "${CONF}"
    assert_success
    assert_line "cleanup-rc=0"
    assert [ ! -e "${CONF}" ]
}

@test "realbox: a symlink is restored as a symlink, with the file it points at" {
    _stub_distrobox
    TARGET="${BATS_TEST_TMPDIR}/target"
    LINK="${BATS_TEST_TMPDIR}/link"
    printf 'original target\n' >"${TARGET}"
    ln -s "${TARGET}" "${LINK}"
    run bash -c '
        source "$1"
        EVIDENCE_ALLOW_REALBOX=1
        _realbox_begin 5.1 || exit 9
        _realbox_backup "$2" || exit 8
        rm -f "$2"
        printf "a regular file now\n" >"$2"
        printf "clobbered target\n" >"$3"
    ' _ "${EVIDENCE}" "${LINK}" "${TARGET}"
    assert_success
    assert_line "cleanup-rc=0"
    assert [ -L "${LINK}" ]
    run cat "${TARGET}"
    assert_line "original target"
}
