#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/hook/enforce_milestone_gate_approval_spec.bats -
# .agents/hook/enforce_milestone_gate_approval.sh (issue #190)
#
# The agent-side half of the milestone-gate approval (#187), per the
# "## 範圍" and "## 範圍修訂" sections of issue #190:
#   1. merge gate: `gh pr merge <n>` (any flags, --auto included) and a gh api
#      WRITE to .../pulls/<n>/merge are BLOCKED (exit 2, reason on stderr)
#      when the PR carries `milestone-gate` and no comment is a human
#      approval by lib/approval.sh; any lookup failure blocks (fail closed)
#   2. tag rule: every comment-like body an agent sends (gh pr|issue
#      comment, gh pr review with a body, close|reopen --comment, gh api
#      writes to comments / reviews endpoints, from --body / -b / --body-file
#      / -F / a literal heredoc / body= / message= / --input) must start,
#      after leading whitespace, with [claude] or [codex] - phrase or not.
#      PR / issue create bodies are no comments. An unreadable body, and a
#      GraphQL comment / review mutation, block
#   3. method-aware writes: a direct API call (curl, wget, httpie, gh api)
#      counts only when it writes - ANY data flag, or a method other than an
#      implicit GET / HEAD; a GraphQL body is a write when it is a mutation
#      or cannot be read. API URLs are normalised before matching (scheme,
#      host case, userinfo, port, trailing dot, path spelling)
#   4. the closed rule: a relevant gh command with a word the shell expands,
#      a sub-command the hook cannot tell, an unknown root flag, combined
#      short options, or gh run through eval / bash -c "$X" / xargs blocks;
#      the raw-text and inline-code tripwires catch what the parser missed
#   5. everything else passes silently and never calls gh
#
# The matrices below generate every variant as a product of explicit
# dimensions (operation x spelling x wrapper; method x data flag x tool x
# endpoint; GraphQL body x tool x host; tag x operation x body source, GraphQL
# included; host x path URL forms); a new bypass class is a new dimension
# value, and a failure names the variant.
#
# gh is a PATH stub fed from files in BATS_TEST_TMPDIR: nothing touches
# the network. The stub logs each call to ${GH_STUB_DIR}/calls.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    # The single tables and classifiers the matrices read (hook_http_data_flags,
    # hook_http_is_write, hook_api_endpoint_urls).
    # shellcheck source=../../../.agents/hook/lib/subcommand.sh
    source "${HOOK_DIR}/lib/subcommand.sh"
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
        "gh pr close 7 -R ycpss91255/worktool --comment '${PHRASE}'"; do
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
    _check "gh pr review 7 --comment --body-file=${_f}"
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
    printf '[claude] looks good\n' >"${_ok}"
    for _c in "gh pr comment 7 --body '[claude] safe' --body '${PHRASE}'" \
        "gh pr comment 7 -b '[claude] safe' --body=${PHRASE}" \
        "gh issue comment 7 --body-file ${_ok} --body-file ${_f}" \
        "gh pr review 7 --comment -F ${_ok} -F ${_f}" \
        "gh pr comment 7 --body '[claude] safe' --body \"\$(cat ${_f})\"" \
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

@test "a quoted command substitution anywhere in a gh body command is blocked (closed rule)" {
    # Quoted, it is still one word the hook cannot read: it may expand to
    # an option (--body) that turns the next word into the body.
    local _c
    for _c in "gh pr comment \"\$(printf 7)\" --body 'looks good'" \
        "gh pr comment \"\$(printf -- '--body')\" '${PHRASE}'" \
        "gh pr comment 7 \"\$(printf -- '--body')\" '${PHRASE}'"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "literal"
    done
    run _calls
    assert_output ""
}

@test "a gh api call with an endpoint built by a command substitution is blocked, read or not" {
    local _c
    for _c in "gh api \"\$(printf repos/o/r/pulls)\" --paginate" \
        "gh api -X GET \"repos/\$(echo o/r)/issues/7/comments\" -f per_page=100" \
        "gh api \"repos/\$(echo o/r)/pulls/7\" -q .title --jq \"\$(echo .state)\"" \
        "gh api \"\$(printf -- '-X')\" PUT repos/o/r/pulls/7/merge"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "literal"
    done
    run _calls
    assert_output ""
}

@test "gh api to .../comments with a marked body, or a read, passes" {
    _check "gh api repos/o/r/issues/7/comments -f 'body=[claude] 等「${PHRASE}」'"
    assert_success
    _check "gh api repos/o/r/issues/7/comments --paginate"
    assert_success
    assert_output ""
}

# --- closed rule: root flags, expansions, wrappers ------------------------------

@test "gh root-level repo flags before the sub-command do not hide a merge" {
    _labels milestone-gate
    local _c
    for _c in "gh -R ycpss91255/worktool pr merge 7" \
        "gh --repo=ycpss91255/worktool pr merge 7 --merge" \
        "gh --repo ycpss91255/worktool pr merge 7" \
        "gh -Rycpss91255/worktool pr merge 7" \
        "gh pr -R ycpss91255/worktool merge 7" \
        "gh -R ycpss91255/worktool pr comment 7 --body '${PHRASE}'"; do
        _check "${_c}"
        assert_failure 2
    done
    run _calls
    assert_line --partial "repos/ycpss91255/worktool/issues/7/labels"
    refute_line --partial "repo view"
}

@test "a root-level -R merge with the maintainer's approval passes" {
    _labels milestone-gate
    _comment OWNER "${PHRASE}"
    _check "gh -R ycpss91255/worktool pr merge 7 --merge"
    assert_success
    assert_output ""
    run _calls
    assert_line --partial "repos/ycpss91255/worktool/issues/7/comments"
}

@test "an unknown gh root flag before a relevant sub-command is blocked" {
    local _c
    for _c in "gh --foo x pr merge 7" \
        "gh --hostname example.com api -X PUT repos/o/r/pulls/7/merge" \
        "gh -z pr comment 7 --body ok"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "root flag"
    done
    run _calls
    assert_output ""
}

@test "a gh alias or extension (an unknown top-level word) is blocked" {
    _check "gh pm 7"
    assert_failure 2
    assert_output --partial "alias"
}

@test "a parameter expansion in a relevant gh command is blocked (closed rule)" {
    _labels milestone-gate
    local _c
    for _c in "gh pr merge \$PR -R ycpss91255/worktool" \
        "gh pr merge \"\$PR\" -R ycpss91255/worktool" \
        "gh pr merge 7 -R \"\${REPO}\"" \
        "gh api -X PUT \"\$EP\"" \
        "gh api -X PUT repos/o/r/pulls/\${N}/merge" \
        "gh pr comment 7 --body \"\$BODY\"" \
        "gh issue comment 7 -b \$BODY" \
        "gh pr comment 7 --body-file \"\$F\"" \
        "gh api repos/o/r/issues/7/comments -f body=\"\$B\"" \
        "gh pr comment 7 --body-file *.md" \
        "gh pr merge 7 -R ycpss91255/worktool --{merge,admin}" \
        "gh pr comment 7 --body \$'\\x41'"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "literal"
    done
    run _calls
    assert_output ""
}

@test "a gh command the hook cannot see literally (eval, bash -c, dynamic name) is blocked" {
    local _c
    for _c in "eval \"\$CMD\"" \
        "bash -c \"\$CMD\"" \
        "bash -c \"gh pr comment 7 --body '\$B'\"" \
        "bash -c \"gh pr merge '\$(printf 7)'\"" \
        "\$GH pr merge 7" \
        "\"\$(command -v gh)\" pr merge 7" \
        "gh \$SUB 7" \
        "gh pr \"\$SUB\" 7"; do
        _check "${_c}"
        assert_failure 2
    done
    run _calls
    assert_output ""
}

@test "gh run through another command (nice, xargs) is blocked when relevant" {
    local _c
    for _c in "nice -n 5 gh pr merge 7 -R ycpss91255/worktool" \
        "echo 7 | xargs gh pr merge" \
        "xargs gh pr comment 7 --body ok"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "directly"
    done
    run _calls
    assert_output ""
}

@test "combined short options in a relevant gh command are blocked" {
    local _c
    for _c in "gh pr comment 7 -eb '${PHRASE}'" \
        "gh api -iX PUT repos/o/r/pulls/7/merge" \
        "gh pr merge 7 -dR other/repo"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "short option"
    done
    run _calls
    assert_output ""
}

@test "close / reopen --comment and odd merge endpoints are covered; a pr new body is no comment" {
    _labels milestone-gate
    local _c
    for _c in "gh pr close 7 --comment '${PHRASE}'" \
        "gh issue reopen 7 -c '${PHRASE}'" \
        "gh api -X PUT 'repos/o/r/pulls/7/merge?x=1'" \
        "gh api -X PUT https://api.github.com/repos/o/r/pulls/7/merge" \
        "gh api -X PUT repos/o/r/pulls/7/%6derge" \
        "gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'" \
        "gh api graphql -f query='mutation{addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}'"; do
        _check "${_c}"
        assert_failure 2
    done
    _check "gh pr close 7 --comment '[claude] ${PHRASE} 前先關閉'"
    assert_success
    _check "gh pr new --title t --body 'untagged create body'"
    assert_success
    _check "gh api graphql -f query='query{viewer{login}}'"
    assert_success
    assert_output ""
}

@test "variables outside a relevant gh command are not blocked" {
    local _c
    for _c in "echo \$X" \
        "git commit -m \"\$MSG\"" \
        "gh pr view \$N" \
        "gh pr view \"\$N\" --json title -R ycpss91255/worktool" \
        "gh run watch \$ID" \
        "for f in *.sh; do shellcheck \"\$f\"; done" \
        "[ -f x ] && echo y" \
        "\$HOME/bin/tool --flag" \
        "grep -rn gh src/" \
        "echo '\$PR gh pr view'"; do
        _check "${_c}"
        assert_success
        assert_output ""
    done
    run _calls
    assert_output ""
}

# --- heredoc / here-string scripts, --help --------------------------------------

@test "a heredoc a shell reads as its script is judged: a merge in it is gated" {
    _labels milestone-gate
    local _c
    for _c in "$(printf "sh <<'EOF'\ngh pr merge 7 -R ycpss91255/worktool\nEOF")" \
        "$(printf "env bash -s <<EOF\necho start\ngh pr merge 7 -R ycpss91255/worktool --merge\nEOF\necho after")" \
        "bash <<< 'gh pr merge 7 -R ycpss91255/worktool'"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "milestone-gate"
    done
}

@test "a forged approval comment in a heredoc fed to bash is blocked" {
    local _c
    for _c in "$(printf "bash <<'EOF'\ngh pr comment 7 -R ycpss91255/worktool --body '%s'\nEOF" "${PHRASE}")" \
        "$(printf "zsh <<-END\n\tgh issue comment 7 -b '%s'\n\tEND" "${PHRASE}")"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "[claude]"
    done
    run _calls
    assert_output ""
}

@test "an unquoted heredoc delimiter expands the body; a quoted one keeps it literal" {
    _check "$(printf "bash <<EOF\ngh pr comment 7 --body '\$B'\nEOF")"
    assert_failure 2
    assert_output --partial "literal"
    _check "$(printf "bash <<EOF\ngh pr comment 7 --body \"\\\\\$B\"\nEOF")"
    assert_failure 2
    _check "$(printf "bash <<'EOF'\ngh pr comment 7 --body '[claude] \$B'\nEOF")"
    assert_success
    assert_output ""
    run _calls
    assert_output ""
}

@test "a heredoc fed to a non-shell is data and a script file is not read, but the tripwire sees their text" {
    # The structured pass treats them as data; the raw-text tripwire (round
    # 5) still blocks a relevant gh call or the phrase in the text.
    local _c
    for _c in "$(printf "cat <<EOF\ngh pr merge 7\n%s\nEOF" "${PHRASE}")" \
        "$(printf "tee notes.md <<'EOF' >/dev/null\ngh pr comment 7 --body '%s'\nEOF" "${PHRASE}")" \
        "bash script/x.sh <<< 'gh pr merge 7'" \
        "$(printf "bash -c 'cat' <<EOF\ngh pr merge 7\nEOF")"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "cannot verify"
    done
    for _c in "bash script/x.sh" \
        "$(printf "cat <<'EOF' >notes.md\nplain notes, gh pr view 7\nEOF")"; do
        _check "${_c}"
        assert_success
        assert_output ""
    done
    run _calls
    assert_output ""
}

@test "--help / -h on a relevant gh command passes without calling gh" {
    _labels milestone-gate
    local _c
    for _c in "gh pr merge --help" \
        "gh -h pr merge 7" \
        "gh api --help" \
        "gh pr merge 7 -R ycpss91255/worktool --help" \
        "gh pr comment 7 --body x -h" \
        "gh --help pr comment"; do
        _check "${_c}"
        assert_success
        assert_output ""
    done
    run _calls
    assert_output ""
}

@test "a -h / --help that is an option's value or follows -- does not pass a merge" {
    _labels milestone-gate
    local _c
    for _c in "gh pr merge 7 -R ycpss91255/worktool --subject --help" \
        "gh pr merge 7 -R ycpss91255/worktool -t -h" \
        "gh pr merge 7 -R ycpss91255/worktool -- --help"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "milestone-gate"
    done
}

# --- round 5: heredoc delimiters, fish / busybox, raw-text tripwire -------------

@test "a heredoc delimiter that is not a plain identifier ends where the shell ends it" {
    _labels milestone-gate
    local _c
    for _c in "$(printf "cat <<'END-X'\nhello\nEND-X\ngh pr merge 7 -R ycpss91255/worktool")" \
        "$(printf 'cat <<"a.b"\nhello\na.b\ngh pr merge 7 -R ycpss91255/worktool')" \
        "$(printf 'cat <<2EOF\nhello\n2EOF\ngh pr merge 7 -R ycpss91255/worktool')"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "milestone-gate"
    done
}

@test "fish with valued options and busybox sh read a heredoc as their script" {
    _labels milestone-gate
    local _c
    for _c in "$(printf "fish -C true <<'EOF'\ngh pr merge 7 -R ycpss91255/worktool\nEOF")" \
        "$(printf "fish --init-command true <<'EOF'\ngh pr merge 7 -R ycpss91255/worktool\nEOF")" \
        "$(printf "busybox sh <<'EOF'\ngh pr merge 7 -R ycpss91255/worktool\nEOF")" \
        "busybox sh -c 'gh pr merge 7 -R ycpss91255/worktool'"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "milestone-gate"
    done
}

@test "the raw-text tripwire blocks a relevant gh call or the phrase the structured pass did not check" {
    local _c
    for _c in "$(printf "foo-shell <<'EOF'\ngh pr merge 7 -R ycpss91255/worktool\nEOF")" \
        "$(printf "foo-shell <<'EOF'\ngh -R o/r issue comment 7 --body ok\nEOF")" \
        "$(printf "foo-shell <<'EOF'\ngh api -X PUT repos/o/r/pulls/7/merge\nEOF")" \
        "perl -e 'system(\"gh pr merge 7\")'" \
        "echo 'gh pr merge 7'" \
        "git commit -m 'docs: ${PHRASE} is the approval phrase'" \
        "gh pr comment 7 --body '[claude] next: gh pr merge 7'"; do
        _check "${_c}"
        assert_failure 2
        # perl -e is caught first by the inline-code tripwire (round 6).
        assert_output --regexp "cannot verify|inline program"
        assert_output --partial "--body-file"
    done
    run _calls
    assert_output ""
}

@test "the tripwire does not double-block a gh call the structured pass checked" {
    _labels milestone-gate
    _comment OWNER "${PHRASE}"
    local _c
    for _c in "gh pr merge 7 -R ycpss91255/worktool --merge" \
        "gh -R ycpss91255/worktool pr merge 7 && gh pr view 7" \
        "gh pr comment 7 --body '[claude] 請維護者留言「${PHRASE}」'" \
        "gh api repos/o/r/issues/7/comments -f 'body=[codex] 等「${PHRASE}」'" \
        "$(printf "bash <<'EOF'\ngh pr comment 7 --body '[claude] ok'\ngh pr merge 7 -R ycpss91255/worktool\nEOF")" \
        "timeout 60 bash -c 'gh issue comment 7 --body \"[claude] ok\"'"; do
        _check "${_c}"
        assert_success
        assert_output ""
    done
}

# --- round 6: inline code of other interpreters, direct API URLs ---------------

@test "inline code of a non-shell interpreter that names gh and a sub-command is blocked" {
    local _c
    for _c in "python3 -c 'import os; os.execlp(\"gh\",\"gh\",\"pr\",\"merge\",\"7\")'" \
        "perl -e 'exec \"gh\", \"pr\", \"merge\", \"7\"'" \
        "node -e 'require(\"child_process\").execFileSync(\"gh\", [\"pr\", \"merge\", \"7\"])'" \
        "env python3 -c 'import subprocess as s; s.run([\"gh\", \"api\", \"-X\", \"PUT\", u])'" \
        "ruby -e 'system(\"gh\", \"issue\", \"comment\", \"7\")'" \
        "php -r 'passthru(\"gh\".\" \".\"pr\");'" \
        "awk 'BEGIN { system(\"gh\" \" pr view\") }'" \
        "python3 -c 'import urllib.request as u; u.urlopen(\"https://api.github.com/x\")'" \
        "$(printf "python3 - <<'EOF'\nimport subprocess\nsubprocess.run([\"gh\", \"pr\", \"merge\", \"7\"])\nEOF")"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "inline program"
    done
    run _calls
    assert_output ""
}

# --- equivalence-class matrices (round 8) ---------------------------------------
# Each dimension lists every spelling of one choice; a variant is the product
# of one value per dimension. A new bypass class is a new dimension VALUE here,
# not a new example test.

# _q <text> - <text> single-quoted for a shell ('\'' for a quote inside).
_q() {
    local _s="$1"
    printf "'%s'" "${_s//\'/\'\\\'\'}"
}

# _argv <gh command> - its argv as a JSON array (valid Python / JS / Perl).
_argv() {
    eval "set -- $1"
    printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]'
}

# The relevant operations: <group>|<sub>|<arguments>.
# Every in-scope operation of issue #190 (## 範圍).
_ops() {
    printf '%s\n' "pr|merge|7" \
        "pr|comment|7 --body '${PHRASE}'" \
        "pr|review|7 --comment --body '${PHRASE}'" \
        "pr|close|7 --comment '${PHRASE}'" \
        "pr|reopen|7 --comment '${PHRASE}'" \
        "issue|comment|7 --body '${PHRASE}'" \
        "issue|close|7 --comment '${PHRASE}'" \
        "issue|reopen|7 --comment '${PHRASE}'" \
        "api||-X PUT repos/o/r/pulls/7/merge" \
        "api||-X POST repos/o/r/issues/7/comments -f body=${PHRASE}" \
        "api||-X PATCH repos/o/r/issues/comments/9 -f body=${PHRASE}" \
        "api||graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'" \
        "api||graphql -f query='mutation{addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}'"
}
_SPELLINGS=(plain R-before repo-eq-before repo-between R-after)
_SHELL_WRAPPERS=(none bash-c sh-c eval env timeout busybox-sh heredoc-sh herestring-bash)
_CODE_WRAPPERS=(python3-c perl-e node-e)

# _gh_cmd <op> <spelling> - the gh command line of <op> spelled that way.
_gh_cmd() {
    local _g _s _a
    IFS='|' read -r _g _s _a <<<"$1"
    case "$2" in
        plain) printf 'gh %s %s%s' "${_g}" "${_s:+${_s} }" "${_a}" ;;
        R-before) printf 'gh -R o/r %s %s%s' "${_g}" "${_s:+${_s} }" "${_a}" ;;
        repo-eq-before) printf 'gh --repo=o/r %s %s%s' "${_g}" "${_s:+${_s} }" "${_a}" ;;
        repo-between) printf 'gh %s --repo o/r %s%s' "${_g}" "${_s:+${_s} }" "${_a}" ;;
        R-after) printf 'gh %s %s%s -R o/r' "${_g}" "${_s:+${_s} }" "${_a}" ;;
    esac
}

# _wrap <wrapper> <command> - <command> run through <wrapper>.
_wrap() {
    local _a
    case "$1" in
        none) printf '%s' "$2" ;;
        bash-c) printf 'bash -c %s' "$(_q "$2")" ;;
        sh-c) printf 'sh -c %s' "$(_q "$2")" ;;
        eval) printf 'eval %s' "$(_q "$2")" ;;
        env) printf 'env %s' "$2" ;;
        timeout) printf 'timeout 60 %s' "$2" ;;
        busybox-sh) printf 'busybox sh -c %s' "$(_q "$2")" ;;
        heredoc-sh) printf "sh <<'EOF'\n%s\nEOF" "$2" ;;
        herestring-bash) printf 'bash <<< %s' "$(_q "$2")" ;;
        python3-c)
            _a="$(_argv "$2")"
            printf 'python3 -c %s' "$(_q "import subprocess; subprocess.run(${_a})")" ;;
        perl-e)
            _a="$(_argv "$2")"
            printf 'perl -e %s' "$(_q "system(${_a:1:${#_a}-2})")" ;;
        node-e)
            _a="$(_argv "$2")"
            printf 'node -e %s' "$(_q "const a=${_a}; require(\"child_process\").execFileSync(a[0], a.slice(1))")" ;;
    esac
}

# _expect <want status> <label> <command> - run the hook; on a mismatch,
# append the variant to _MISS.
_expect() {
    local _rc=0
    printf '%s' "$(hook_json "$3")" | "${HOOK_DIR}/enforce_milestone_gate_approval.sh" >/dev/null 2>&1 || _rc=$?
    [[ "${_rc}" -eq "$1" ]] || _MISS+="$2 -> status ${_rc}, want $1: $3"$'\n'
}

# _report - fail naming every variant that missed.
_report() {
    [[ -z "${_MISS}" ]] || fail "$(printf 'variants that missed:\n%s' "${_MISS}")"
}

@test "matrix: every operation x gh spelling x wrapper is blocked" {
    _labels milestone-gate
    local _oper _sp _wr _MISS=''
    local -a _all
    mapfile -t _all < <(_ops)
    for _oper in "${_all[@]}"; do
        for _sp in "${_SPELLINGS[@]}"; do
            for _wr in "${_SHELL_WRAPPERS[@]}" "${_CODE_WRAPPERS[@]}"; do
                _expect 2 "op=${_oper%%|*}:${_oper#*|} spelling=${_sp} wrapper=${_wr}" \
                    "$(_wrap "${_wr}" "$(_gh_cmd "${_oper}" "${_sp}")")"
            done
        done
    done
    _report
}

@test "matrix: a checked literal gh call passes through every shell wrapper and spelling" {
    _labels milestone-gate
    _comment OWNER "${PHRASE}"
    local _o _sp _wr _MISS=''
    local -a _sps
    for _o in "pr|merge|7" "pr|comment|7 --body '[claude] ok'" "pr|view|7" "pr|view|7 --comments" \
        "pr|create|--title t --body 'untagged create body'" \
        "api||repos/o/r/issues/7/comments" "api||repos/o/r/issues/comments/123 --jq .body" \
        "api||graphql -f query='query{viewer{login}}'"; do
        # gh api has no -R / --repo: only its plain spelling is a real call.
        _sps=("${_SPELLINGS[@]}")
        [[ "${_o}" == api* ]] && _sps=(plain)
        for _sp in "${_sps[@]}"; do
            for _wr in "${_SHELL_WRAPPERS[@]}"; do
                _expect 0 "op=${_o%%|*}:${_o#*|} spelling=${_sp} wrapper=${_wr}" \
                    "$(_wrap "${_wr}" "$(_gh_cmd "${_o}" "${_sp}")")"
            done
        done
    done
    _report
}

# --- tag rule (scope revision): every agent comment starts with [claude]/[codex] --

# The tag dimension: <label>|<body>|<want status>.
_tags() {
    printf '%s\n' "claude|[claude] ok|0" "codex|[codex] ok|0" "space-then-tag|  \t[claude] ok|0" \
        "untagged|looks good|2" "tag-not-at-start|ok [claude]|2" "empty||2"
}

# _body_cmd <op> <source> <body> - a comment-writing call with <body> from
# <source>; files go to BATS_TEST_TMPDIR. <op> is gh words up to the body.
_body_cmd() {
    local _f="${BATS_TEST_TMPDIR}/body.md" _j="${BATS_TEST_TMPDIR}/body.json"
    printf '%s' "$3" >"${_f}"
    jq -n --arg b "$3" '{body: $b}' >"${_j}"
    case "$2" in
        body) printf "%s --body %s" "$1" "$(_q "$3")" ;;
        b) printf "%s -b %s" "$1" "$(_q "$3")" ;;
        body-eq) printf "%s --body=%s" "$1" "$(_q "$3")" ;;
        body-file) printf '%s --body-file %s' "$1" "${_f}" ;;
        F) printf '%s -F %s' "$1" "${_f}" ;;
        herestring) printf '%s --body-file - <<< %s' "$1" "$(_q "$3")" ;;
        heredoc) printf "%s --body-file - <<'EOF'\n%s\nEOF" "$1" "$3" ;;
        comment) printf "%s --comment %s" "$1" "$(_q "$3")" ;;
        c) printf "%s -c %s" "$1" "$(_q "$3")" ;;
        comment-eq) printf "%s --comment=%s" "$1" "$(_q "$3")" ;;
        f) printf '%s -f %s' "$1" "$(_q "body=$3")" ;;
        raw-field) printf '%s --raw-field %s' "$1" "$(_q "body=$3")" ;;
        F-at) printf '%s -F body=@%s' "$1" "${_f}" ;;
        field-at) printf '%s --field body=@%s' "$1" "${_f}" ;;
        input) printf '%s --input %s' "$1" "${_j}" ;;
    esac
}

@test "matrix: every comment-writing operation x body source x tag - untagged blocks, tagged passes" {
    local _cop _src _t _lab _bod _want _MISS=''
    local -a _cases=()
    local _s
    for _cop in "gh pr comment 7" "gh issue comment 7" "gh pr review 7 --comment"; do
        for _s in body b body-eq body-file F herestring heredoc; do _cases+=("${_cop}|${_s}"); done
    done
    for _cop in "gh pr close 7" "gh pr reopen 7" "gh issue close 7" "gh issue reopen 7"; do
        for _s in comment c comment-eq; do _cases+=("${_cop}|${_s}"); done
    done
    for _cop in "gh api -X POST repos/o/r/issues/7/comments" "gh api -X PATCH repos/o/r/issues/comments/9" \
        "gh api -X POST repos/o/r/pulls/7/comments" "gh api -X PATCH repos/o/r/pulls/comments/9" \
        "gh api -X POST repos/o/r/pulls/7/reviews" "gh api -X PUT repos/o/r/pulls/7/reviews/5" \
        "gh api -X POST repos/o/r/pulls/7/reviews/5/events" "gh api repos/o/r/issues/7/comments"; do
        for _s in f raw-field F-at field-at input; do _cases+=("${_cop}|${_s}"); done
    done
    for _cop in "${_cases[@]}"; do
        _src="${_cop##*|}"
        while IFS='|' read -r _lab _bod _want; do
            _bod="$(printf '%b' "${_bod}")"
            _expect "${_want}" "op=${_cop%|*} source=${_src} tag=${_lab}" \
                "$(_body_cmd "${_cop%|*}" "${_src}" "${_bod}")"
        done < <(_tags)
    done
    _report
}

@test "the tag rule message names the rule and #187" {
    _check "gh pr comment 7 --body 'looks good'"
    assert_failure 2
    assert_output --partial "must start with [claude] or [codex]"
    assert_output --partial "#187"
}

@test "a comment call whose body the hook cannot read is blocked; no-body reviews and closes pass" {
    local _c
    for _c in "gh pr comment 7" "gh issue comment 7 --editor" "gh pr comment 7 --web" \
        "gh pr comment 7 --body-file - < notes.md" "cat notes.md | gh issue comment 7 -F -"; do
        _check "${_c}"
        assert_failure 2
    done
    for _c in "gh pr review 7 --approve" "gh pr close 7" "gh issue reopen 7" \
        "gh pr create --title t --body 'untagged create body'" \
        "gh issue create --title t --label bug --body-file /dev/null"; do
        _check "${_c}"
        assert_success
        assert_output ""
    done
}

@test "matrix: tag x GraphQL comment / review mutation x body source - every cell blocks (these mutations block outright)" {
    local _m _src _lab _bod _want _q _f="${BATS_TEST_TMPDIR}/q.graphql" _j="${BATS_TEST_TMPDIR}/q.json" _c _MISS=''
    for _m in addComment updateIssueComment addPullRequestReview addPullRequestReviewComment \
        addPullRequestReviewThread addPullRequestReviewThreadReply submitPullRequestReview \
        updatePullRequestReview updatePullRequestReviewComment; do
        while IFS='|' read -r _lab _bod _want; do
            _bod="$(printf '%b' "${_bod}")"
            _q="mutation{${_m}(input:{body:$(jq -n --arg b "${_bod}" '$b')}){clientMutationId}}"
            printf '%s' "${_q}" >"${_f}"
            jq -n --arg q "${_q}" '{query: $q}' >"${_j}"
            for _src in f F-at input raw-field; do
                case "${_src}" in
                    f) _c="gh api graphql -f $(_q "query=${_q}")" ;;
                    F-at) _c="gh api graphql -F query=@${_f}" ;;
                    input) _c="gh api graphql --input ${_j}" ;;
                    raw-field) _c="gh api graphql --raw-field $(_q "query=${_q}")" ;;
                esac
                _expect 2 "mutation=${_m} tag=${_lab} source=${_src}" "${_c}"
            done
        done < <(_tags)
    done
    _report
}

# --- HTTP method dimension (round 9): reads pass, writes are blocked -------------

# Every REST path of the scope: <class> <path>. Comments are the full
# (issues|pulls) x (collection|member) product; replies and every reviews
# path are included.
_rest_paths() {
    printf '%s\n' "merge pulls/7/merge" \
        "comment issues/7/comments" "comment issues/comments/9" \
        "comment pulls/7/comments" "comment pulls/comments/9" \
        "reply pulls/7/comments/9/replies" \
        "review pulls/7/reviews" "review pulls/7/reviews/5" "review pulls/7/reviews/5/events" \
        "review pulls/7/reviews/5/dismissals" "review pulls/7/reviews/5/comments"
}
# ... on both hosts: <class> <url>.
_api_endpoints() {
    local _b _c _p
    for _b in https://api.github.com/repos/o/r https://ghe.example.com/api/v3/repos/o/r; do
        while read -r _c _p; do
            printf '%s %s/%s\n' "${_c}" "${_b}" "${_p}"
        done < <(_rest_paths)
    done
}
_METHODS=(implicit GET HEAD POST PUT PATCH DELETE)
_TOOLS=(curl wget http gh-api)

# _data_flags <tool> [all] - one "<spelling>|<words>" per data variant of
# <tool>, GENERATED from the single table hook_http_data_flags of
# lib/subcommand.sh (never repeated here); "none|none" first. A value flag
# yields its separate spelling, and with "all" also --flag=V and, for a
# short flag, -xV; a boolean flag yields itself; a request item (httpie)
# yields x<separator><value>.
_data_flags() {
    local _f _a _k _v='body=x'
    printf 'none|none\n'
    while read -r _f _a _k; do
        case "${_a}" in
            0) printf 'flag|%s\n' "${_f}" ;;
            item) [[ "${_f}" == *@ ]] && printf 'item|x%sf\n' "${_f}" || printf 'item|x%s1\n' "${_f}" ;;
            1)
                printf 'separate|%s %s\n' "${_f}" "${_v}"
                [[ -n "${2:-}" ]] || continue
                printf 'eq|%s=%s\n' "${_f}" "${_v}"
                [[ "${_f}" == -? ]] && printf 'attached|%s%s\n' "${_f}" "${_v}" ;;
        esac
    done < <(hook_http_data_flags "$1")
}

# _http_cmd <tool> <method> <data flag> <url> - the call spelled for <tool>.
_http_cmd() {
    local _d="$3"
    [[ "${_d}" == none ]] && _d=''
    case "$1:$2" in
        curl:implicit) printf 'curl -s %s %s' "${_d}" "$4" ;;
        curl:*) printf 'curl -X %s %s %s' "$2" "${_d}" "$4" ;;
        wget:implicit) printf 'wget -qO- %s %s' "${_d}" "$4" ;;
        wget:*) printf 'wget --method=%s %s %s' "$2" "${_d}" "$4" ;;
        http:implicit) printf 'http %s %s' "$4" "${_d}" ;;
        http:*) printf 'http %s %s %s' "$2" "$4" "${_d}" ;;
        gh-api:implicit) printf 'gh api %s %s' "$4" "${_d}" ;;
        gh-api:*) printf 'gh api -X %s %s %s' "$2" "$4" "${_d}" ;;
    esac
}

# _want_rw <method> <data flag> - 0 for a read, 2 for a write: a read is no
# data flag AND an implicit, GET or HEAD method (issue #190, round 10).
_want_rw() {
    [[ "$2" == none && "$1" =~ ^(implicit|GET|HEAD)$ ]] && printf 0 || printf 2
}

@test "the data-flag table is the single source and holds every data flag the scope names" {
    run hook_http_data_flags http
    assert_line "--raw 1"
    assert_line "--form 0"
    assert_line "-f 0"
    assert_line "= item"
    assert_line ":= item"
    assert_line "@ item"
    run hook_http_data_flags curl
    assert_line "-d 1"
    assert_line "--upload-file 1"
    run hook_http_data_flags wget
    assert_line "--post-file 1"
    run hook_http_data_flags gh-api
    assert_line "--input 1"
    # The spec generates its data dimension from the table, never a list.
    run declare -f _data_flags
    assert_success
    refute_output --regexp '(--data|--post|--body|--raw|--form|--field|--input|--json|--upload)'
    refute_output --regexp "'-[dFTf] "
}

@test "matrix: hook_http_is_write - method x data flag x option spelling x curl -G x tool, full product" {
    # A missing table must not collapse the data dimension to "none".
    local _tt
    for _tt in "${_TOOLS[@]}"; do
        [[ "$(_data_flags "${_tt}" | wc -l)" -gt 1 ]] || fail "empty data-flag dimension for ${_tt}"
    done
    local _t _m _v _sp _d _g _want _got _MISS=''
    local -a _w
    for _t in curl wget http; do
        for _m in "${_METHODS[@]}"; do
            while IFS='|' read -r _sp _d; do
                for _g in none -G; do
                    [[ "${_g}" == -G && "${_t}" != curl ]] && continue
                    _v="${_d}"
                    [[ "${_g}" == -G ]] && _v="-G ${_d/#none/}"
                    [[ -z "${_v// /}" ]] && _v=none
                    read -r -a _w <<<"$(_http_cmd "${_t}" "${_m}" "${_v}" https://api.github.com/repos/o/r/issues/7/comments)"
                    _got=0
                    hook_http_is_write "${_t}" "${_w[@]:1}" && _got=2
                    _want="$(_want_rw "${_m}" "${_d}")"
                    [[ "${_got}" == "${_want}" ]] \
                        || _MISS+="tool=${_t} method=${_m} spelling=${_sp} data=${_d} curl-G=${_g}: got ${_got}, want ${_want}"$'\n'
                done
            done < <(_data_flags "${_t}" all)
        done
    done
    _report
}

@test "matrix: tool x method x data flag x REST endpoint class - reads pass, writes are blocked (full product)" {
    # A missing table must not collapse the data dimension to "none".
    local _tt
    for _tt in "${_TOOLS[@]}"; do
        [[ "$(_data_flags "${_tt}" | wc -l)" -gt 1 ]] || fail "empty data-flag dimension for ${_tt}"
    done
    # One path per endpoint class through the whole hook; every path of a
    # class (both hosts, every spelling) is proven the same endpoint by the
    # hook_api_endpoint_urls matrix below. curl / wget / httpie take the
    # separate spelling here (every spelling runs through hook_http_is_write
    # above); gh api, judged inside the hook, takes every spelling.
    _labels milestone-gate
    local _t _m _sp _d _cl _u _all _MISS=''
    local -a _reps=("merge pulls/7/merge" "comment issues/7/comments" "reply pulls/7/comments/9/replies" "review pulls/7/reviews/5/events")
    for _t in "${_TOOLS[@]}"; do
        _all=''
        [[ "${_t}" == gh-api ]] && _all=all
        for _m in "${_METHODS[@]}"; do
            while IFS='|' read -r _sp _d; do
                for _cl in "${_reps[@]}"; do
                    _u="https://api.github.com/repos/o/r/${_cl#* }"
                    _expect "$(_want_rw "${_m}" "${_d}")" "tool=${_t} method=${_m} spelling=${_sp} data=${_d} endpoint=${_cl%% *}" \
                        "$(_http_cmd "${_t}" "${_m}" "${_d}" "${_u}")"
                done
            done < <(_data_flags "${_t}" "${_all}")
        done
    done
    _report
}

@test "httpie --raw BODY (separate value) is a write even with GET / HEAD" {
    local _c
    for _c in "http GET https://api.github.com/repos/o/r/issues/7/comments --raw untagged" \
        "http HEAD https://api.github.com/repos/o/r/issues/7/comments --raw untagged" \
        "http https://api.github.com/repos/o/r/issues/7/comments --raw=untagged"; do
        _check "${_c}"
        assert_failure 2
    done
}

@test "matrix: every REST endpoint path x host is recognised as an API endpoint" {
    local _cl _MISS=''
    while IFS= read -r _cl; do
        [[ "$(hook_api_endpoint_urls "curl ${_cl#* }" | wc -l)" -eq 1 ]] || _MISS+="endpoint=${_cl}"$'\n'
    done < <(_api_endpoints)
    _report
}

@test "matrix: tool x GraphQL body - a query reads, a mutation or an unreadable body is a write" {
    printf 'mutation{mergePullRequest(input:{pullRequestId:"x"}){clientMutationId}}' \
        >"${BATS_TEST_TMPDIR}/q.graphql"
    local _u _b _t _want _c _MISS=''
    local _read='query{viewer{login}}' _merge='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'
    local _comment='mutation{addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}'
    for _u in https://api.github.com/graphql https://ghe.example.com/api/graphql; do
        for _b in none read merge comment file; do
            for _t in "${_TOOLS[@]}"; do
                case "${_b}" in none|read) _want=0 ;; *) _want=2 ;; esac
                local _q=''
                case "${_b}" in read) _q="${_read}" ;; merge) _q="${_merge}" ;; comment) _q="${_comment}" ;; esac
                case "${_t}:${_b}" in
                    *:none) _c="$(_http_cmd "${_t}" implicit none "${_u}")" ;;
                    curl:file) _c="curl -d @${BATS_TEST_TMPDIR}/q.graphql ${_u}" ;;
                    wget:file) _c="wget --post-file=${BATS_TEST_TMPDIR}/q.graphql ${_u}" ;;
                    http:file) _c="http POST ${_u} query=@${BATS_TEST_TMPDIR}/q.graphql" ;;
                    gh-api:file) _c="gh api ${_u} -F query=@${BATS_TEST_TMPDIR}/q.graphql" ;;
                    curl:*) _c="curl -d '{\"query\":\"${_q}\"}' ${_u}" ;;
                    wget:*) _c="wget --post-data='{\"query\":\"${_q}\"}' ${_u}" ;;
                    http:*) _c="http POST ${_u} query='${_q//\\/}'" ;;
                    gh-api:*) _c="gh api ${_u} -f query='${_q//\\/}'" ;;
                esac
                _expect "${_want}" "tool=${_t} body=${_b} url=${_u}" "${_c}"
            done
        done
    done
    _report
}

@test "an API URL behind an unknown tool or a shell expansion is still a write (fail closed)" {
    local _c
    for _c in "fetchit https://api.github.com/repos/o/r/issues/7/comments" \
        "curl -X \"\$M\" https://api.github.com/repos/o/r/issues/7/comments" \
        "curl -sX POST https://api.github.com/repos/o/r/pulls/7/merge"; do
        _check "${_c}"
        assert_failure 2
    done
}

# The host dimension of a direct API URL: _url <form> <host> <path>.
_HOST_FORMS=(plain upper trailing-dot port trailing-dot-port userinfo http no-scheme)
_url() {
    case "$1" in
        plain) printf 'https://%s%s' "$2" "$3" ;;
        upper) printf 'https://%s%s' "${2^^}" "$3" ;;
        trailing-dot) printf 'https://%s.%s' "$2" "$3" ;;
        port) printf 'https://%s:443%s' "$2" "$3" ;;
        trailing-dot-port) printf 'https://%s.:443%s' "$2" "$3" ;;
        userinfo) printf 'https://user:tok@%s%s' "$2" "$3" ;;
        http) printf 'http://%s%s' "$2" "$3" ;;
        no-scheme) printf '%s%s' "$2" "$3" ;;
    esac
}
# The path dimension: _path_form <form> <path>.
_PATH_FORMS=(plain dot-segment dot-dot double-slash percent trailing-slash query upper)
_path_form() {
    local _last="${2##*/}"
    case "$1" in
        plain) printf '%s' "$2" ;;
        dot-segment) printf '%s/./%s' "${2%/*}" "${_last}" ;;
        dot-dot) printf '%s/x/../%s' "${2%/*}" "${_last}" ;;
        double-slash) printf '/%s' "$2" ;;
        percent) printf '%s/%%%02x%s' "${2%/*}" "'${_last:0:1}" "${_last:1}" ;;
        trailing-slash) printf '%s/' "$2" ;;
        query) printf '%s?a=1' "$2" ;;
        upper) printf '%s' "${2^^}" ;;
    esac
}
# The API endpoints of a merge, a comment and GraphQL: <host> <path>.
_endpoints() {
    printf '%s\n' "api.github.com /repos/o/r/pulls/7/merge" \
        "api.github.com /repos/o/r/issues/7/comments" \
        "api.github.com /repos/o/r/issues/comments/9" \
        "api.github.com /graphql" \
        "ghe.example.com /api/v3/repos/o/r/pulls/7/merge" \
        "ghe.example.com /api/v3/repos/o/r/issues/7/comments" \
        "ghe.example.com /api/graphql"
}

@test "matrix: hook_api_endpoint_urls counts every host x path spelling of an API write URL" {
    local _h _p _hf _pf _u _MISS=''
    while read -r _h _p; do
        for _hf in "${_HOST_FORMS[@]}"; do
            for _pf in "${_PATH_FORMS[@]}"; do
                _u="$(_url "${_hf}" "${_h}" "$(_path_form "${_pf}" "${_p}")")"
                [[ "$(hook_api_endpoint_urls "curl -X PUT '${_u}'" | wc -l)" -eq 1 ]] \
                    || _MISS+="host=${_hf} path=${_pf}: ${_u}"$'\n'
            done
        done
    done < <(_endpoints)
    _report
}

@test "matrix: a direct API write through curl / wget / http is blocked for every host spelling" {
    local _h _p _hf _cl _u _b _MISS=''
    while read -r _h _p; do
        for _hf in "${_HOST_FORMS[@]}"; do
            _u="$(_url "${_hf}" "${_h}" "${_p}")"
            for _cl in curl wget http; do
                # A write: a write method on REST, a mutation body on GraphQL.
                case "${_cl}:${_p}" in
                    curl:*graphql) _b="curl -d '{\"query\":\"mutation{x}\"}' ${_u}" ;;
                    wget:*graphql) _b="wget --post-data='{\"query\":\"mutation{x}\"}' ${_u}" ;;
                    http:*graphql) _b="http POST ${_u} query='mutation{x}'" ;;
                    curl:*) _b="curl -X PUT ${_u}" ;;
                    wget:*) _b="wget --post-data=x ${_u}" ;;
                    http:*) _b="http POST ${_u}" ;;
                esac
                _expect 2 "client=${_cl} host=${_hf} endpoint=${_p}" "${_b}"
            done
        done
    done < <(_endpoints)
    _report
    run _calls
    assert_output ""
}

@test "matrix: API reads that are no merge / comment / graphql URL pass for every host spelling" {
    local _hf _u _MISS=''
    for _hf in "${_HOST_FORMS[@]}"; do
        for _u in "$(_url "${_hf}" api.github.com /repos/o/r/pulls/7)" \
            "$(_url "${_hf}" api.github.com /repos/o/r/commits)" \
            "$(_url "${_hf}" ghe.example.com /api/v3/repos/o/r/pulls)"; do
            _expect 0 "host=${_hf}" "curl -s ${_u}"
        done
    done
    _report
    run hook_api_endpoint_urls "see repos/o/r/pulls/7/merge and api docs at https://docs.github.com/rest"
    assert_output ""
}

@test "inline code without gh, script files and plain API reads pass" {
    local _c
    for _c in "python3 -c 'print(1)'" \
        "node -e 'console.log(1)'" \
        "perl -e 'print qq(pr merge\n)'" \
        "python3 tool.py --verbose" \
        "awk '{ print \$1 }' file" \
        "curl -s https://api.github.com/repos/o/r/pulls/7"; do
        _check "${_c}"
        assert_success
        assert_output ""
    done
    run _calls
    assert_output ""
}

@test "a checked gh api call with a full api.github.com URL is not blocked twice" {
    _check "gh api -X GET https://api.github.com/repos/o/r/issues/7/comments"
    assert_success
    assert_output ""
    _labels bug
    _check "gh api -X PUT https://api.github.com/repos/o/r/pulls/7/merge"
    assert_success
    assert_output ""
}

# --- round 12: no in-band sentinel ------------------------------------------------

@test "matrix: a control byte in a gh command classifies like the same command without it" {
    local _b _c _t _cmd _base _want _got _MISS=''
    local -a _tmpl=("gh pr comment 7 --body '[claude] a@b'" "gh pr comment 7 --body 'a@b'" \
        "gh pr comment 7 --body \"[claude] a@b\"" "gh pr view a@b" "gh pr comment 7 --body x@y")
    for _t in "${_tmpl[@]}"; do
        _base="${_t//@/}"
        _check "${_base}"
        _want="${status}"
        for _b in $(seq 1 31) 127; do
            printf -v _c '%b' "\\0$(printf '%03o' "${_b}")"
            # Unquoted, 0x09 / 0x0a are shell syntax, not a byte of a word.
            [[ "${_t}" == *" a@b" || "${_t}" == *" x@y" ]] && [[ "${_b}" -eq 9 || "${_b}" -eq 10 ]] && continue
            _cmd="${_t//@/${_c}}"
            _check "${_cmd}"
            _got="${status}"
            [[ "${_got}" == "${_want}" ]] \
                || _MISS+="byte=$(printf '0x%02x' "${_b}") template=${_t}: status ${_got}, want ${_want}"$'\n'
        done
    done
    _report
}

# --- everything else is untouched ----------------------------------------------

@test "unrelated commands pass silently and never call gh" {
    local _c
    for _c in "git status" \
        "gh pr view 7 -R ycpss91255/worktool" \
        "gh pr comment 7 --body '[claude] looks good'" \
        "echo hi" \
        "git commit -m 'docs: explain the milestone gate'" \
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
