#!/usr/bin/env bats
# test/unit/script/watch_user_replies_spec.bats - .agents/script/watch-user-replies.sh
#
# The user-REPLY watcher, a Monitor companion. worktool adaptation: the
# default state file lives in the repo, under the gitignored .agents/state/
# (one file per repo + login, so a restart never re-announces old replies;
# WORKTOOL_AGENT_STATE_DIR overrides the directory), and the CLI follows
# the worktool contract (whole command line parsed before --help is served).
#
# Strategy:
#   - `watch_reply_is_user` and `watch_replies_filter` are PURE: they touch no
#     network, so they are sourced and called directly against crafted
#     fixtures (fully deterministic).
#   - Arg-handling cases exit before any fetch, so a trivial `gh` PATH-stub
#     suffices.
#   - The fetch stage runs against a `gh` stub that mimics the real CLI's
#     flags, including a failing list stage and a second comment page (see
#     _fake_gh).
#
# The case that matters most is "quoting an agent tag mid-body": matching the
# tag ANYWHERE instead of at the START swallowed a real acceptance report that
# merely quoted "[codex]" in its prose, and the maintainer's findings went
# unread. That regression must stay dead.

load "${BATS_TEST_DIRNAME}/../../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="${REPO_ROOT}/.agents/script/watch-user-replies.sh"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB_DIR}"
    cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${STUB_DIR}/gh"
    export PATH="${STUB_DIR}:${PATH}"

    STATE="${BATS_TEST_TMPDIR}/seen.txt"
    TSV="${BATS_TEST_TMPDIR}/comments.tsv"
    : > "${STATE}"
    : > "${TSV}"
    export SCRIPT STATE TSV
}

# _row <issue> <id> <login> <body>  -- append one fixture comment line
_row() {
    local _b64
    _b64="$(printf '%s' "$4" | base64 -w0)"
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${_b64}" >> "${TSV}"
}

@test "a plain comment by the watched login is a reply" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    run watch_reply_is_user maintainer maintainer "looks wrong to me"
    assert_success
}

@test "a comment by someone else is not a reply" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    run watch_reply_is_user maintainer somebody-else "looks wrong to me"
    assert_failure
}

@test "a body starting with the claude tag is agent output, not a reply" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    run watch_reply_is_user maintainer maintainer "[claude] round 3 fixed"
    assert_failure
}

@test "a body starting with the codex tag is agent output, not a reply" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    run watch_reply_is_user maintainer maintainer "[codex] 不可合併: ..."
    assert_failure
}

@test "quoting an agent tag mid-body is still a reply (the swallowed-report regression)" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    local _body="# 驗收報告

6.3: #156 的最後一則 [codex] 判定為可合併。"
    run watch_reply_is_user maintainer maintainer "${_body}"
    assert_success
}

@test "filter prints one event per unseen reply and records its id" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    _row 5 111 maintainer "first reply"
    _row 7 222 maintainer "second reply"
    run watch_replies_filter maintainer "${STATE}" "${TSV}"
    assert_success
    assert_line --index 0 "USER REPLY on #5 : first reply"
    assert_line --index 1 "USER REPLY on #7 : second reply"
    run grep -cxF 111 "${STATE}"
    assert_output "1"
    run grep -cxF 222 "${STATE}"
    assert_output "1"
}

@test "filter does not re-announce an id already in the state file" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    printf '111\n' > "${STATE}"
    _row 5 111 maintainer "first reply"
    run watch_replies_filter maintainer "${STATE}" "${TSV}"
    assert_success
    assert_output ""
}

@test "filter skips agent output and does not record it as seen" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    _row 5 111 maintainer "[claude] progress note"
    run watch_replies_filter maintainer "${STATE}" "${TSV}"
    assert_success
    assert_output ""
    run grep -cxF 111 "${STATE}"
    assert_failure
}

@test "a multi-line body is folded onto one event line" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    _row 9 333 maintainer "line one
line two"
    run watch_replies_filter maintainer "${STATE}" "${TSV}"
    assert_success
    assert_output "USER REPLY on #9 : line one line two"
}

@test "a very long body is truncated to a preview" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    local _long
    _long="$(printf 'x%.0s' $(seq 1 400))"
    _row 9 444 maintainer "${_long}"
    run watch_replies_filter maintainer "${STATE}" "${TSV}"
    assert_success
    # "USER REPLY on #9 : " is 19 chars, plus the 200-char preview.
    [ "${#output}" -eq 219 ]
}

# _fake_gh <api-mode> [list-mode] -- replace the trivial stub with one that
# behaves like the real gh CLI: `issue list` yields #5, `pr list` yields
# nothing, and `api` rejects flags gh does not have (gh api has no --arg; the
# real CLI prints "unknown flag: --arg" and exits 1). gh evaluates --jq with a
# built-in jq (not the standalone jq binary), so the stub stands in for that
# step: it requires the issue number as a string literal in the --jq program
# and prints the TSV rows that program yields for a canned comment list
# (id 901 a reply, id 902 agent output).
#   <api-mode>  ok | fail (every `api` call exits 1) | paged (a second page
#               holds reply 903, returned only when --paginate is passed -
#               without it gh stops at the first page)
#   [list-mode] ok (default) | issue-fail | pr-fail (that `list` call prints
#               an HTTP error on stderr and exits 1)
_fake_gh() {
    printf '%s\n' "$1" > "${BATS_TEST_TMPDIR}/api_mode"
    printf '%s\n' "${2:-ok}" > "${BATS_TEST_TMPDIR}/list_mode"
    cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
_dir="$(dirname "$(dirname "$0")")"
_list="$(cat "${_dir}/list_mode")"
case "$1 $2" in
    "issue list")
        [[ "${_list}" == issue-fail ]] && { echo "HTTP 503: issue list down" >&2; exit 1; }
        echo 5; exit 0 ;;
    "pr list")
        [[ "${_list}" == pr-fail ]] && { echo "HTTP 503: pr list down" >&2; exit 1; }
        exit 0 ;;
esac
[[ "$1" == api ]] || exit 0
_mode="$(cat "${_dir}/api_mode")"
[[ "${_mode}" == fail ]] && { echo "HTTP 502" >&2; exit 1; }
shift
_jq=''
_paginate=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jq|-q) _jq="$2"; shift 2 ;;
        --paginate) _paginate=1; shift ;;
        -*) echo "unknown flag: $1" >&2; exit 1 ;;
        *) shift ;;
    esac
done
[[ "${_jq}" == *'["5",'* ]] || { echo "jq program lacks the issue number" >&2; exit 1; }
printf '5\t901\tmaintainer\t%s\n' "$(printf 'please look at #5' | base64 -w0)"
printf '5\t902\tmaintainer\t%s\n' "$(printf '[claude] agent note' | base64 -w0)"
if [[ "${_mode}" == paged && "${_paginate}" -eq 1 ]]; then
    printf '5\t903\tmaintainer\t%s\n' "$(printf 'reply on page two' | base64 -w0)"
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/gh"
}

@test "--once fetches through the real gh api flags and announces a reply" {
    _fake_gh ok
    run --separate-stderr "${SCRIPT}" --repo owner/repo --login maintainer \
        --state-file "${STATE}" --once
    assert_success
    assert_output "USER REPLY on #5 : please look at #5"
    run grep -cxF 901 "${STATE}"
    assert_output "1"
}

@test "--seed through the real gh api flags marks replies seen silently" {
    _fake_gh ok
    run --separate-stderr "${SCRIPT}" --repo owner/repo --login maintainer \
        --state-file "${STATE}" --seed
    assert_success
    assert_output ""
    run grep -cxF 901 "${STATE}"
    assert_output "1"
}

@test "--seed fails loudly when a fetch fails instead of seeding nothing" {
    _fake_gh fail
    run "${SCRIPT}" --repo owner/repo --login maintainer \
        --state-file "${STATE}" --seed
    assert_failure 1
    assert_output --partial "fetch failed for #5"
    assert_output --partial "seed aborted: 1 of 1 thread(s) unreadable"
}

@test "a failed fetch cycle emits a stdout event, so Monitor is not silent" {
    _fake_gh fail
    run --separate-stderr "${SCRIPT}" --repo owner/repo --login maintainer \
        --state-file "${STATE}" --once
    assert_success
    assert_output "WATCH FETCH FAILED: 1 of 1 thread(s) unreadable this cycle"
}

@test "a failed issue list is a stdout event, not silence (gh's error kept on stderr)" {
    _fake_gh ok issue-fail
    run --separate-stderr "${SCRIPT}" --repo owner/repo --login maintainer \
        --state-file "${STATE}" --once
    assert_success
    assert_output "WATCH FETCH FAILED: could not list the open issues/PRs this cycle"
    [[ "${stderr:-}" == *"HTTP 503: issue list down"* ]]
}

@test "a failed pr list is a stdout event too" {
    _fake_gh ok pr-fail
    run --separate-stderr "${SCRIPT}" --repo owner/repo --login maintainer \
        --state-file "${STATE}" --once
    assert_success
    assert_line "WATCH FETCH FAILED: could not list the open issues/PRs this cycle"
    [[ "${stderr:-}" == *"HTTP 503: pr list down"* ]]
}

@test "--seed refuses to seed when a list call fails" {
    _fake_gh ok issue-fail
    run "${SCRIPT}" --repo owner/repo --login maintainer \
        --state-file "${STATE}" --seed
    assert_failure 1
    assert_output --partial "seed aborted"
    run cat "${STATE}"
    assert_output ""
}

@test "comments past the first page are fetched (gh api --paginate)" {
    _fake_gh paged
    run --separate-stderr "${SCRIPT}" --repo owner/repo --login maintainer \
        --state-file "${STATE}" --once
    assert_success
    assert_line "USER REPLY on #5 : please look at #5"
    assert_line "USER REPLY on #5 : reply on page two"
}

@test "--help exits 0 and documents the options" {
    run "${SCRIPT}" --help
    assert_success
    assert_output --partial "--state-file"
    assert_output --partial "--seed"
}

@test "an unknown option exits 2 and names it" {
    run "${SCRIPT}" --bogus
    assert_failure 2
    assert_output --partial "unknown option '--bogus'"
}

@test "a missing --repo exits 2" {
    run "${SCRIPT}" --login maintainer
    assert_failure 2
    assert_output --partial "--repo is required"
}

@test "a missing --login exits 2" {
    run "${SCRIPT}" --repo owner/repo
    assert_failure 2
    assert_output --partial "--login is required"
}

@test "a non-numeric --interval exits 2" {
    run "${SCRIPT}" --repo owner/repo --login maintainer --interval soon
    assert_failure 2
    assert_output --partial "--interval must be a positive integer"
}

@test "a zero --interval exits 2" {
    run "${SCRIPT}" --repo owner/repo --login maintainer --interval 0
    assert_failure 2
    assert_output --partial "--interval must be a positive integer"
}

@test "--help does not hide a later unknown option (whole line parsed first)" {
    run "${SCRIPT}" --help --bogus
    assert_failure 2
    assert_output --partial "unknown option '--bogus'"
}

@test "--help names the default state directory" {
    run "${SCRIPT}" --help
    assert_success
    assert_output --partial ".agents/state/"
}

@test "the default state file is per repo + login under the repo's .agents/state/" {
    # shellcheck source=/dev/null
    source "${SCRIPT}"
    unset WORKTOOL_AGENT_STATE_DIR
    run watch_default_state_file owner/repo maintainer
    assert_success
    assert_output "${REPO_ROOT}/.agents/state/watch-user-replies-owner_repo-maintainer.seen"
}

@test "without --state-file, --once records into the default state file (dir created)" {
    _fake_gh ok
    local _dir="${BATS_TEST_TMPDIR}/agent-state"
    WORKTOOL_AGENT_STATE_DIR="${_dir}" run --separate-stderr "${SCRIPT}" \
        --repo owner/repo --login maintainer --once
    assert_success
    assert_output "USER REPLY on #5 : please look at #5"
    run grep -cxF 901 "${_dir}/watch-user-replies-owner_repo-maintainer.seen"
    assert_output "1"
}

@test "the default state file survives a restart: a second --once announces nothing" {
    _fake_gh ok
    local _dir="${BATS_TEST_TMPDIR}/agent-state"
    WORKTOOL_AGENT_STATE_DIR="${_dir}" run --separate-stderr "${SCRIPT}" \
        --repo owner/repo --login maintainer --once
    assert_success
    WORKTOOL_AGENT_STATE_DIR="${_dir}" run --separate-stderr "${SCRIPT}" \
        --repo owner/repo --login maintainer --once
    assert_success
    assert_output ""
}
