#!/usr/bin/env bats
# test/unit/hook/enforce_milestone_gate_approval_spec.bats -
# .agents/hook/enforce_milestone_gate_approval.sh (issue #190)
#
# The agent-side half of the milestone-gate approval (#187):
#   1. merge gate: `gh pr merge <n>` (any flags, --auto included) and
#      `gh api .../pulls/<n>/merge` are BLOCKED (exit 2, reason on stderr)
#      when the PR carries `milestone-gate` and no comment is a human
#      approval by lib/approval.sh; any lookup failure blocks (fail closed)
#   2. anti-forgery: a comment / review / issue / PR body, or a gh api
#      POST / PATCH to .../comments, holding 允許合併 without a leading
#      [claude] / [codex] marker is BLOCKED; a marked body passes
#   3. everything else passes silently and never calls gh
#
# gh is a PATH stub fed from files in BATS_TEST_TMPDIR: nothing touches
# the network. The stub logs each call to ${GH_STUB_DIR}/calls.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    GH_STUB_DIR="${BATS_TEST_TMPDIR}/gh"
    mkdir -p "${GH_STUB_DIR}/bin"
    export GH_STUB_DIR
    cat >"${GH_STUB_DIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh stub: answers from files in GH_STUB_DIR, logs every call.
d="${GH_STUB_DIR:?}"
printf '%s\n' "$*" >>"${d}/calls"
case " $* " in
    *" repo view "*) [[ -f "${d}/fail_repo" ]] && exit 1
        printf '%s\n' "${GH_STUB_REPO:-stub-owner/stub-repo}" ;;
    *" pr view "*) [[ -f "${d}/fail_view" ]] && exit 1
        printf '%s\n' "${GH_STUB_PR:-7}" ;;
    */labels" "*) [[ -f "${d}/fail_labels" ]] && exit 1
        cat "${d}/labels.json"
        [[ ! -f "${d}/late_fail_labels" ]] || exit 1 ;;
    */comments" "*) [[ -f "${d}/fail_comments" ]] && exit 1
        cat "${d}/comments.json"
        [[ ! -f "${d}/late_fail_comments" ]] || exit 1 ;;
    *) printf 'gh stub: unexpected call: %s\n' "$*" >&2; exit 1 ;;
esac
STUB
    chmod +x "${GH_STUB_DIR}/bin/gh"
    PATH="${GH_STUB_DIR}/bin:${PATH}"
    export PATH
    printf '[]' >"${GH_STUB_DIR}/labels.json"
    printf '[]' >"${GH_STUB_DIR}/comments.json"
    PHRASE='允許合併'
}

_check() { run_hook enforce_milestone_gate_approval "$(hook_json "$1")"; }

# _labels <name>... - the PR's labels, as the REST API returns them.
_labels() {
    jq -n '$ARGS.positional | map({name: .})' --args "$@" >"${GH_STUB_DIR}/labels.json"
}

# _comment <author_association> <body> - append one PR comment.
_comment() {
    local _f="${GH_STUB_DIR}/comments.json"
    jq --arg a "$1" --arg b "$2" '. + [{author_association: $a, body: $b}]' "${_f}" >"${_f}.new"
    mv "${_f}.new" "${_f}"
}

_calls() { cat "${GH_STUB_DIR}/calls" 2>/dev/null; }

# --- required spec / registration ---------------------------------------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/hook/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "the hook sets set -uo pipefail itself, as issue #190 requires" {
    assert [ -f "${HOOK_DIR}/enforce_milestone_gate_approval.sh" ]
    run grep -cx 'set -uo pipefail' "${HOOK_DIR}/enforce_milestone_gate_approval.sh"
    assert_output "1"
}

@test "the hook reuses lib/approval.sh instead of re-implementing the rule" {
    assert [ -f "${HOOK_DIR}/enforce_milestone_gate_approval.sh" ]
    run grep -c 'lib/approval.sh' "${HOOK_DIR}/enforce_milestone_gate_approval.sh"
    refute_output "0"
    run grep -F "${PHRASE}" "${HOOK_DIR}/enforce_milestone_gate_approval.sh"
    assert_failure
}

# --- merge gate ----------------------------------------------------------------

@test "merge of a PR without milestone-gate passes" {
    _labels bug
    _check "gh pr merge 7 --repo ycpss91255/worktool --merge"
    assert_success
    assert_output ""
    run _calls
    assert_line --partial "repos/ycpss91255/worktool/issues/7/labels"
}

@test "merge of a milestone-gate PR without an approval is blocked and says what is missing" {
    _labels milestone-gate
    _check "gh pr merge 7 -R ycpss91255/worktool --merge"
    assert_failure 2
    assert_output --partial "BLOCKED"
    assert_output --partial "milestone-gate"
    assert_output --partial "需要維護者留言:${PHRASE}"
}

@test "merge of a milestone-gate PR with a qualifying OWNER approval passes" {
    _labels enhancement milestone-gate
    _comment OWNER "[claude] 等維護者核准"
    _comment OWNER "驗收看過了,${PHRASE}"
    _check "gh pr merge 7 -R ycpss91255/worktool --merge"
    assert_success
    assert_output ""
}

@test "a [claude] or [codex] comment holding the phrase is not an approval" {
    _labels milestone-gate
    _comment OWNER "[claude] 請維護者留言「${PHRASE}」"
    _comment OWNER "  [codex] ${PHRASE}"
    _check "gh pr merge 7 -R ycpss91255/worktool --merge"
    assert_failure 2
}

@test "a non-OWNER comment holding the phrase is not an approval" {
    _labels milestone-gate
    _comment COLLABORATOR "${PHRASE}"
    _comment NONE "${PHRASE}"
    _check "gh pr merge 7 -R ycpss91255/worktool --merge"
    assert_failure 2
}

@test "gh pr merge --auto is gated the same way" {
    _labels milestone-gate
    _check "gh pr merge --auto --squash 7 --repo ycpss91255/worktool"
    assert_failure 2
    _comment OWNER "${PHRASE}"
    _check "gh pr merge --auto --squash 7 --repo ycpss91255/worktool"
    assert_success
}

@test "gh api .../pulls/<n>/merge is gated, the repo taken from the path" {
    _labels milestone-gate
    _check "gh api -X PUT repos/some-owner/some-repo/pulls/12/merge -f merge_method=merge"
    assert_failure 2
    run _calls
    assert_line --partial "repos/some-owner/some-repo/issues/12/labels"
    _comment OWNER "${PHRASE}"
    _check "gh api --method PUT /repos/some-owner/some-repo/pulls/12/merge"
    assert_success
}

@test "gh api .../pulls/<n>/merge with {owner}/{repo} resolves the repo via gh repo view" {
    _labels milestone-gate
    _check "gh api -X PUT 'repos/{owner}/{repo}/pulls/12/merge'"
    assert_failure 2
    run _calls
    assert_line --partial "repo view"
    assert_line --partial "repos/stub-owner/stub-repo/issues/12/labels"
}

@test "without -R the repo comes from gh repo view" {
    _labels bug
    _check "gh pr merge 7 --merge"
    assert_success
    run _calls
    assert_line --partial "repo view"
    assert_line --partial "repos/stub-owner/stub-repo/issues/7/labels"
}

@test "a PR URL selector gives both repo and number" {
    _labels milestone-gate
    _check "gh pr merge https://github.com/url-owner/url-repo/pull/9 --merge"
    assert_failure 2
    run _calls
    assert_line --partial "repos/url-owner/url-repo/issues/9/labels"
}

@test "a branch selector (or none) is resolved with gh pr view" {
    _labels milestone-gate
    GH_STUB_PR=15 _check "gh pr merge feat/x -R ycpss91255/worktool --merge"
    assert_failure 2
    run _calls
    assert_line --partial "pr view"
    assert_line --partial "repos/ycpss91255/worktool/issues/15/labels"
}

@test "a failed label lookup blocks the merge (fail closed)" {
    touch "${GH_STUB_DIR}/fail_labels"
    _check "gh pr merge 7 -R ycpss91255/worktool --merge"
    assert_failure 2
    assert_output --partial "fail closed"
}

@test "a failed comment lookup blocks the merge (fail closed)" {
    _labels milestone-gate
    touch "${GH_STUB_DIR}/fail_comments"
    _check "gh pr merge 7 -R ycpss91255/worktool --merge"
    assert_failure 2
    assert_output --partial "fail closed"
}

@test "a gh lookup that prints JSON and then fails blocks the merge (fail closed)" {
    _labels milestone-gate
    _comment OWNER "${PHRASE}"
    touch "${GH_STUB_DIR}/late_fail_labels"
    _check "gh pr merge 7 -R ycpss91255/worktool --merge"
    assert_failure 2
    assert_output --partial "cannot read the PR labels"
    rm "${GH_STUB_DIR}/late_fail_labels"
    touch "${GH_STUB_DIR}/late_fail_comments"
    _check "gh pr merge 7 -R ycpss91255/worktool --merge"
    assert_failure 2
    assert_output --partial "cannot read the PR comments"
}

@test "the lookup failure check does not rely on pipefail" {
    assert [ -f "${HOOK_DIR}/enforce_milestone_gate_approval.sh" ]
    run grep -En '^[[:space:]]*\|[[:space:]]*jq' "${HOOK_DIR}/enforce_milestone_gate_approval.sh"
    assert_failure
}

@test "a failed repo or PR resolution blocks the merge (fail closed)" {
    touch "${GH_STUB_DIR}/fail_repo"
    _check "gh pr merge 7 --merge"
    assert_failure 2
    rm "${GH_STUB_DIR}/fail_repo"
    touch "${GH_STUB_DIR}/fail_view"
    _check "gh pr merge -R ycpss91255/worktool --merge"
    assert_failure 2
}

@test "a merge inside a compound command is still gated" {
    _labels milestone-gate
    _check "git fetch origin && timeout 60 gh pr merge 7 -R ycpss91255/worktool --merge; echo done"
    assert_failure 2
}

@test "a timeout(1) with valued options before gh does not hide the merge" {
    _labels milestone-gate
    local _c
    for _c in "timeout -k 5 60 gh pr merge 7 -R ycpss91255/worktool --merge" \
        "timeout --signal TERM 60 gh pr merge 7 -R ycpss91255/worktool --merge" \
        "timeout -s 9 --preserve-status 60 gh pr merge 7 -R ycpss91255/worktool" \
        "gtimeout --kill-after=5 60 gh api -X PUT repos/o/r/pulls/7/merge" \
        "timeout -k 5 60 bash -c 'gh pr merge 7 -R ycpss91255/worktool'"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "milestone-gate"
    done
}

@test "a gh pr merge with any word built by a command substitution is blocked" {
    # A substitution decodes to '_': `gh pr merge "$(printf 7)"` would be
    # resolved as the PR '_' while the shell merges PR 7.
    local _c
    for _c in "gh pr merge \"\$(printf 7)\" -R ycpss91255/worktool --merge" \
        "gh pr merge \`printf 7\` -R ycpss91255/worktool" \
        "gh pr merge 7 -R \"\$(printf ycpss91255/worktool)\"" \
        "gh pr merge 7 --repo=\$(printf ycpss91255/worktool)" \
        "gh pr merge 7 -R ycpss91255/worktool \$(printf -- --admin)" \
        "gh pr merge 7 -R ycpss91255/worktool --body \"\$(printf x)\""; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "command substitution"
    done
    run _calls
    assert_output ""
}

@test "a gh sub-command word built by a command substitution is blocked" {
    local _c
    for _c in "gh pr \"\$(printf merge)\" 7 -R ycpss91255/worktool" \
        "gh \"\$(printf pr)\" merge 7" \
        "gh \$(printf 'pr merge') 7" \
        "gh pr -R ycpss91255/worktool \`printf merge\` 7"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "command substitution"
    done
    run _calls
    assert_output ""
}

# --- anti-forgery ----------------------------------------------------------------

@test "an unmarked inline body with the phrase is blocked on every comment path" {
    local _c
    for _c in "gh pr comment 7 --body '${PHRASE}'" \
        "gh issue comment 7 -b '好,${PHRASE}'" \
        "gh pr review 7 --approve --body=${PHRASE}" \
        "gh pr create --title t --body '${PHRASE}' --base main" \
        "gh issue create -R ycpss91255/worktool --title t -b '${PHRASE}'"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "[claude]"
    done
}

@test "an unmarked body file with the phrase is blocked (--body-file and -F)" {
    local _f="${BATS_TEST_TMPDIR}/body.md"
    printf '驗收完成\n\n%s\n' "${PHRASE}" >"${_f}"
    _check "gh pr comment 7 --body-file ${_f}"
    assert_failure 2
    _check "gh issue comment 7 -F ${_f}"
    assert_failure 2
    _check "gh pr create --title t --body-file=${_f}"
    assert_failure 2
}

@test "a relative body file is read from the payload cwd" {
    printf '%s\n' "${PHRASE}" >"${BATS_TEST_TMPDIR}/rel.md"
    run_hook enforce_milestone_gate_approval \
        "$(jq -n --arg c "gh pr comment 7 --body-file rel.md" --arg d "${BATS_TEST_TMPDIR}" \
            '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
    assert_failure 2
}

@test "an unreadable body file or stdin body is blocked (fail closed)" {
    _check "gh pr comment 7 --body-file ${BATS_TEST_TMPDIR}/missing.md"
    assert_failure 2
    _check "cat b.md | gh pr comment 7 -F -"
    assert_failure 2
}

@test "every repeated body flag is checked, not only the first" {
    local _f="${BATS_TEST_TMPDIR}/body.md" _ok="${BATS_TEST_TMPDIR}/ok.md" _c
    printf '%s\n' "${PHRASE}" >"${_f}"
    printf 'looks good\n' >"${_ok}"
    for _c in "gh pr comment 7 --body safe --body '${PHRASE}'" \
        "gh pr comment 7 -b safe --body=${PHRASE}" \
        "gh issue comment 7 --body-file ${_ok} --body-file ${_f}" \
        "gh pr create --title t -F ${_ok} -F ${_f}" \
        "gh pr comment 7 --body safe --body \"\$(cat ${_f})\"" \
        "gh pr comment 7 -F ${_ok} -F -"; do
        _check "${_c}"
        assert_failure 2
    done
}

@test "a marked body quoting the phrase passes (inline and file)" {
    local _f="${BATS_TEST_TMPDIR}/marked.md"
    printf '[codex] 等維護者留言「%s」\n' "${PHRASE}" >"${_f}"
    _check "gh pr comment 7 --body '[claude] 請維護者留言「${PHRASE}」'"
    assert_success
    assert_output ""
    _check "gh pr comment 7 --body-file ${_f}"
    assert_success
    _check "gh issue create --title t --label bug --body-file ${_f}"
    assert_success
}

@test "gh api POST / PATCH to .../comments with an unmarked phrase body is blocked" {
    local _f="${BATS_TEST_TMPDIR}/api.md" _j="${BATS_TEST_TMPDIR}/api.json"
    printf '%s\n' "${PHRASE}" >"${_f}"
    jq -n --arg b "${PHRASE}" '{body: $b}' >"${_j}"
    local _c
    for _c in "gh api repos/o/r/issues/7/comments -f body=${PHRASE}" \
        "gh api -X POST repos/o/r/issues/7/comments --raw-field 'body=ok ${PHRASE}'" \
        "gh api --method PATCH repos/o/r/issues/comments/99 -F body=@${_f}" \
        "gh api repos/o/r/pulls/7/comments --input ${_j}"; do
        _check "${_c}"
        assert_failure 2
    done
}

@test "gh api --raw-field=body= / --field=body= and attached -f forms are checked" {
    local _f="${BATS_TEST_TMPDIR}/api.md" _c
    printf '%s\n' "${PHRASE}" >"${_f}"
    for _c in "gh api repos/o/r/issues/7/comments --raw-field=body=${PHRASE}" \
        "gh api repos/o/r/issues/7/comments --field=body=${PHRASE}" \
        "gh api repos/o/r/issues/7/comments --field=body=@${_f}" \
        "gh api repos/o/r/issues/7/comments -fbody=${PHRASE}" \
        "gh api repos/o/r/issues/7/comments -F=body=@${_f}" \
        "gh api repos/o/r/issues/7/comments --raw-field=body=\"\$(cat ${_f})\"" \
        "gh api -X GET -X POST repos/o/r/issues/7/comments -f body=${PHRASE}"; do
        _check "${_c}"
        assert_failure 2
    done
}

@test "gh api --input with a command substitution is blocked, even when a '_' file exists" {
    # A substitution decodes to '_': a benign '_' file must not stand in for
    # the file the shell would really submit.
    jq -n '{body: "looks good"}' >"${BATS_TEST_TMPDIR}/_"
    jq -n --arg b "${PHRASE}" '{body: $b}' >"${BATS_TEST_TMPDIR}/evil.json"
    local _c
    for _c in "gh api repos/o/r/issues/7/comments --input \"\$(printf evil.json)\"" \
        "gh api repos/o/r/issues/7/comments --input=\"\$(printf evil.json)\"" \
        "gh api -X PATCH repos/o/r/issues/comments/9 --input \`printf evil.json\`"; do
        run_hook enforce_milestone_gate_approval \
            "$(jq -n --arg c "${_c}" --arg d "${BATS_TEST_TMPDIR}" \
                '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
        assert_failure 2
        assert_output --partial "command substitution"
    done
}

@test "a gh api write to an endpoint built by a command substitution is blocked" {
    _labels milestone-gate
    local _c
    for _c in "gh api \"\$(printf repos/o/r/issues/7/comments)\" -f body=${PHRASE}" \
        "gh api -X PUT \"\$(printf repos/o/r/pulls/7/merge)\"" \
        "gh api --method PUT repos/o/r/pulls/\"\$(echo 7)\"/merge" \
        "gh api \`printf repos/o/r/issues/7/comments\` --input body.json" \
        "gh api --raw-field=body=x \"\$(printf repos/o/r/issues/7/comments)\"" \
        "gh api repos/o/r/pulls/7 \$(echo -X PUT)"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "command substitution"
    done
    run _calls
    assert_output ""
}

@test "an unquoted command substitution in gh api is blocked, even as the first positional" {
    # The shell word-splits an unquoted substitution: it may inject -X PUT
    # or -f body=... the hook never saw, so no read can be assumed.
    _labels milestone-gate
    local _c
    for _c in "gh api \$(printf '%s' '-X PUT') repos/o/r/pulls/7/merge" \
        "gh api \$(printf '%s' '-f body=x') repos/o/r/issues/7/comments" \
        "gh api \`printf repos/o/r/pulls/7/merge\` -X PUT" \
        "gh api repos/\$(printf o/r)/pulls/7" \
        "gh api repos/o/r/pulls -q \$(printf .x)" \
        "gh api repos/o/r/pulls -f per_page=\$(printf 1)"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "command substitution"
    done
    run _calls
    assert_output ""
}

@test "an unquoted command substitution in a gh body command is blocked" {
    local _c
    for _c in "gh pr comment 7 \$(printf -- '--body x')" \
        "gh issue comment 7 \`printf -- '-b x'\`" \
        "gh pr create --title t \$(printf -- '--body-file f')" \
        "gh pr review \$(printf 7) --approve"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "command substitution"
    done
}

@test "a quoted command substitution outside the body of a gh body command passes" {
    _check "gh pr comment \"\$(printf 7)\" --body 'looks good'"
    assert_success
    assert_output ""
}

@test "a gh api read of an endpoint built by a command substitution passes" {
    local _c
    for _c in "gh api \"\$(printf repos/o/r/pulls)\" --paginate" \
        "gh api -X GET \"repos/\$(echo o/r)/issues/7/comments\" -f per_page=100" \
        "gh api \"repos/\$(echo o/r)/pulls/7\" -q .title --jq \"\$(echo .state)\""; do
        _check "${_c}"
        assert_success
        assert_output ""
    done
}

@test "gh api to .../comments with a marked body, or a read, passes" {
    _check "gh api repos/o/r/issues/7/comments -f 'body=[claude] 等「${PHRASE}」'"
    assert_success
    _check "gh api repos/o/r/issues/7/comments --paginate"
    assert_success
    assert_output ""
}

# --- everything else is untouched ----------------------------------------------

@test "unrelated commands pass silently and never call gh" {
    local _c
    for _c in "git status" \
        "gh pr view 7 -R ycpss91255/worktool" \
        "gh pr comment 7 --body 'looks good'" \
        "echo 'gh pr merge 7'" \
        "git commit -m 'docs: ${PHRASE} is the approval phrase'" \
        "gh pr edit 7 --add-label milestone-gate"; do
        _check "${_c}"
        assert_success
        assert_output ""
    done
    run _calls
    assert_output ""
}

@test "an empty payload passes" {
    run_hook enforce_milestone_gate_approval '{}'
    assert_success
    assert_output ""
}
