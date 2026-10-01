#!/usr/bin/env bats
# test/unit/agent_config_spec.bats - repo-level agent config (issue #189)
#
# WHAT THIS PROVES
#   Every agent setting lives in this repo and depends on no other checkout
#   and nothing at user level:
#   - the real files are under .agents/{hook,script,skills,memory}; .claude/
#     holds only relative symlinks to them, the committed settings.json and
#     the untouched workflows/
#   - settings.json registers exactly the carried hooks, each through
#     ${CLAUDE_PROJECT_DIR}/.claude/hook/<name>.sh, and every registered path
#     runs from that symlinked location (its lib resolves inside the repo)
#   - no file under .agents/ or .claude/ points at the initialization checkout
#   - memory entries are real files, all indexed by MEMORY.md
#   - the issue's skill list is carried (next to i-have-adhd, #191); the
#     watch state dir is gitignored
#   - the carried skills and memory are adapted to worktool: doc/agent and
#     doc/adr (never docs/), no interface this repo lacks (justfile.ci,
#     release-tag.sh, an auto-merge Monitor ...), no [[link]] to a missing
#     memory, no personal or machine-specific info (IPs, home paths)

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    SETTINGS="${REPO_ROOT}/.claude/settings.json"
    CODEX_HOOKS="${REPO_ROOT}/.codex/hooks.json"
}

# Print "<event>|<matcher>|<command>" for every registered hook command.
_registered() {
    jq -r '.hooks | to_entries[] | .key as $e | .value[]
        | (.matcher // "") as $m | .hooks[] | "\($e)|\($m)|\(.command)"' "${SETTINGS}"
}

# Print the hook script basename for one matcher in one registration file.
_registered_names() {
    local _settings="$1" _matcher="$2"
    jq -r --arg matcher "${_matcher}" '
        .hooks.PreToolUse[] | select(.matcher == $matcher) | .hooks[].command
        | capture("/(?<name>[^/]+[.]sh)(?:[\\\"]*)$").name' "${_settings}"
}

# --- layout ------------------------------------------------------------------

@test ".claude/{hook,script,skills,memory} are relative symlinks to ../.agents/*" {
    local _d
    for _d in hook script skills memory; do
        assert [ -L "${REPO_ROOT}/.claude/${_d}" ]
        assert_equal "$(readlink "${REPO_ROOT}/.claude/${_d}")" "../.agents/${_d}"
        assert [ -d "${REPO_ROOT}/.claude/${_d}/" ]
    done
}

@test ".claude/workflows stays a real directory with both templates" {
    assert [ ! -L "${REPO_ROOT}/.claude/workflows" ]
    assert [ -f "${REPO_ROOT}/.claude/workflows/pr-loop.js" ]
    assert [ -f "${REPO_ROOT}/.claude/workflows/milestone-fanout.js" ]
}

@test "the agent scripts are executable real files" {
    local _s
    for _s in watch-user-replies.sh wait-pr-ci.sh; do
        assert [ -f "${REPO_ROOT}/.agents/script/${_s}" ]
        assert [ ! -L "${REPO_ROOT}/.agents/script/${_s}" ]
        assert [ -x "${REPO_ROOT}/.agents/script/${_s}" ]
    done
}

@test "the watch state directory .agents/state/ is gitignored" {
    run grep -xF '.agents/state/' "${REPO_ROOT}/.gitignore"
    assert_success
}

# --- settings.json -----------------------------------------------------------

@test "settings.json disables Claude Code attribution for commits and PRs" {
    run jq -c '.attribution' "${SETTINGS}"
    assert_success
    assert_output '{"commit":"","pr":""}'
}

@test "AGENTS.md forbids attribution lines in commits, PR bodies and comments" {
    run grep -F 'commit 訊息、PR 說明與留言一律不加署名' "${REPO_ROOT}/AGENTS.md"
    assert_success
    assert_output --partial 'Co-Authored-By'
    assert_output --partial 'Claude-Session'
    assert_output --partial 'Generated with'
}

@test "settings.json registers exactly the carried hooks per event and matcher" {
    run _registered
    assert_success
    local _p="\${CLAUDE_PROJECT_DIR}/.claude/hook"
    assert_output "$(printf '%s\n' \
        "PreToolUse|Bash|${_p}/test-must-use-docker.sh" \
        "PreToolUse|Bash|${_p}/enforce_long_job_timeout.sh" \
        "PreToolUse|Bash|${_p}/check_main_fresh_before_worktree.sh" \
        "PreToolUse|Bash|${_p}/remind_main_sync.sh" \
        "PreToolUse|Bash|${_p}/enforce_gh_body_file.sh" \
        "PreToolUse|Bash|${_p}/enforce_no_local_paths.sh" \
        "PreToolUse|Bash|${_p}/enforce_milestone_gate_approval.sh" \
        "PreToolUse|Bash|${_p}/enforce_main_checkout_readonly.sh" \
        "PreToolUse|Bash|${_p}/enforce_codex_round_cap.sh" \
        "PreToolUse|Bash|${_p}/enforce_scope_on_guard_issues.sh" \
        "PreToolUse|Bash|${_p}/enforce_tdd_commit.sh" \
        "PreToolUse|Bash|${_p}/enforce_issue_milestone.sh" \
        "PreToolUse|Bash|${_p}/enforce_no_attribution.sh" \
        "PreToolUse|Edit|Write|MultiEdit|${_p}/enforce_shellcheck_disable_approval.sh" \
        "PreToolUse|Edit|Write|MultiEdit|NotebookEdit|${_p}/enforce_main_checkout_readonly.sh" \
        "PreToolUse|Workflow|Agent|${_p}/enforce_cpu_capacity.sh" \
        "WorktreeCreate||${_p}/worktree_create.sh" \
        "UserPromptSubmit||${_p}/remind_workflow_tdd.sh" \
        "UserPromptSubmit||${_p}/remind_no_emoji.sh" \
        "Stop||${_p}/enforce_reply_language.sh")"
}

@test "codex registers every Claude PreToolUse Bash hook" {
    run diff -u \
        <(_registered_names "${SETTINGS}" Bash) \
        <(_registered_names "${CODEX_HOOKS}" Bash)
    assert_success
}

@test "every Codex Bash hook resolves from the repo root and accepts the measured payload" {
    local _command _payload _repo
    _payload='{"session_id":"s","turn_id":"t","transcript_path":"/tmp/x.jsonl","cwd":"<dir>","hook_event_name":"PreToolUse","model":"m","permission_mode":"bypassPermissions","tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_use_id":"exec-1"}'
    _repo="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_repo}/test/unit"
    cp -R "${REPO_ROOT}/.agents" "${_repo}/.agents"
    cp -R "${REPO_ROOT}/lib" "${_repo}/lib"
    git init -q "${_repo}"

    while IFS= read -r _command; do
        run bash -c 'cd "$1" && printf "%s" "$2" | bash -c "$3"' _ \
            "${_repo}/test/unit" "${_payload}" "${_command}"
        assert_success "Codex hook command failed: ${_command}"
        assert_output ""
    done < <(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "${CODEX_HOOKS}")
}

@test "every hook in .agents/hook is registered (no orphan hook)" {
    local _f _name _count
    for _f in "${REPO_ROOT}"/.agents/hook/*.sh; do
        _name="$(basename -- "${_f}")"
        _count=0
        if grep -Fq "/.claude/hook/${_name}" "${SETTINGS}"; then
            _count=$((_count + 1))
        fi
        if grep -Fq "/.agents/hook/${_name}" "${CODEX_HOOKS}"; then
            _count=$((_count + 1))
        fi
        assert [ "${_count}" -gt 0 ]
    done
}

@test "every registered hook runs from its settings.json path and allows an empty payload" {
    local _line _cmd
    while IFS= read -r _line; do
        _cmd="${_line##*|}"
        _cmd="${_cmd//\$\{CLAUDE_PROJECT_DIR\}/${REPO_ROOT}}"
        assert [ -x "${_cmd}" ]
        run bash -c 'printf "%s" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"\"}}" | CLAUDE_PROJECT_DIR="$2" "$1"' \
            _ "${_cmd}" "${REPO_ROOT}"
        assert_success
        refute_output --partial "No such file"
    done < <(_registered)
}

# --- no dependency outside the repo -----------------------------------------

@test "nothing under .agents/ or .claude/ points at the initialization checkout" {
    run grep -rn 'Desktop/initialization' "${REPO_ROOT}/.agents" "${REPO_ROOT}/.claude/"
    assert_failure 1
    assert_output ""
}

@test "hooks and scripts source nothing outside the repo" {
    run grep -rnE '(^|[[:space:]])(source|\.)[[:space:]]+"?/' \
        "${REPO_ROOT}/.agents/hook" "${REPO_ROOT}/.agents/script"
    assert_failure 1
}

# --- memory -------------------------------------------------------------------

@test "memory entries are real files, not symlinks" {
    run find "${REPO_ROOT}/.agents/memory" -type l
    assert_success
    assert_output ""
}

@test "MEMORY.md indexes every memory entry and every indexed entry exists" {
    local _dir="${REPO_ROOT}/.agents/memory" _f _link _n=0
    for _f in "${_dir}"/*.md; do
        [[ "$(basename -- "${_f}")" == MEMORY.md ]] && continue
        _n=$((_n + 1))
        run grep -cF "]($(basename -- "${_f}"))" "${_dir}/MEMORY.md"
        assert_output "1"
    done
    # The files themselves are the count; only guard against a glob that
    # matched nothing, which would make the loop above pass vacuously.
    assert [ "${_n}" -gt 0 ]
    while IFS= read -r _link; do
        assert [ -f "${_dir}/${_link}" ]
    done < <(grep -oE '\]\([^)]+\.md\)' "${_dir}/MEMORY.md" | sed -E 's/^\]\((.*)\)$/\1/')
}

# --- skills -------------------------------------------------------------------

@test "the issue's engineering skills are carried next to i-have-adhd, each with a SKILL.md" {
    local _s
    for _s in i-have-adhd tdd triage to-issues to-prd grilling grill-me grill-with-docs \
        domain-modeling ubiquitous-language codebase-design design-an-interface \
        decision-mapping diagnosing-bugs improve-codebase-architecture implement \
        prototype qa research review wayfinder handoff setup-matt-pocock-skills \
        writing-for-agents wait-pr-ci; do
        assert [ -f "${REPO_ROOT}/.agents/skills/${_s}/SKILL.md" ]
    done
    run bash -c 'ls -1 "$1" | wc -l' _ "${REPO_ROOT}/.agents/skills"
    assert_output "25"
}

@test "the wait-pr-ci skill names only scripts this repo carries" {
    run grep -nE 'wait-pr-ci-batch|wait-tag-ci|rebase-pr' "${REPO_ROOT}/.agents/skills/wait-pr-ci/SKILL.md"
    assert_failure 1
    run grep -c '.claude/script/wait-pr-ci.sh' "${REPO_ROOT}/.agents/skills/wait-pr-ci/SKILL.md"
    refute_output "0"
}

# --- carried content is adapted to worktool (codex round 1 on #193) ----------

@test "skills and memory point at worktool's doc/agent and doc/adr, not docs/" {
    run grep -rnE '(^|[^A-Za-z0-9._/-])docs/' \
        "${REPO_ROOT}/.agents/skills" "${REPO_ROOT}/.agents/memory"
    assert_failure 1
    assert_output ""
}

@test "memory and skills name no interface this repo lacks" {
    run grep -rnE 'justfile\.ci|release-tag\.sh|auto-merge-on-green|ci\.sh --ci|enforce_gh_review_approval|gen-module-index|serial-land|INDEX\.md|kcov' \
        "${REPO_ROOT}/.agents/skills" "${REPO_ROOT}/.agents/memory"
    assert_failure 1
    assert_output ""
}

@test "memory never tells an agent to arm or queue an auto-merge" {
    run grep -rniE 'arm(s|ed|ing)? (the )?auto-merge|pr merge --auto|auto-merge\.$|\+ auto-merge' \
        "${REPO_ROOT}/.agents/memory"
    assert_failure 1
    assert_output ""
}

@test "every [[link]] in memory resolves to a memory entry" {
    local _dir="${REPO_ROOT}/.agents/memory" _link _missing=''
    while IFS= read -r _link; do
        [[ -f "${_dir}/${_link}.md" ]] || _missing+="${_link} "
    done < <(grep -rhoE '\[\[[^]]+\]\]' "${_dir}" | tr -d '[]' | sort -u)
    assert_equal "${_missing}" ""
}

@test "memory and skills carry no personal or machine-specific info" {
    run grep -rnE '([0-9]{1,3}\.){3}[0-9]{1,3}|/home/[A-Za-z]|/Users/[A-Za-z]|~/Desktop|/run/user/[0-9]|[A-Za-z0-9._%+-]+@gmail\.com|~/\.local/bin' \
        "${REPO_ROOT}/.agents/memory" "${REPO_ROOT}/.agents/skills"
    assert_failure 1
    assert_output ""
}

@test "issue-tracker docs list only gh commands the hooks accept, each with -R" {
    local _f _cmd _h _bad='' _bt=$'\x60'
    for _f in "${REPO_ROOT}/.agents/skills/setup-matt-pocock-skills/issue-tracker-github.md" \
        "${REPO_ROOT}/doc/agent/issue-tracker.md"; do
        while IFS= read -r _cmd; do
            [[ "${_cmd}" =~ ^gh\ (issue|pr)\  ]] || continue
            [[ "${_cmd}" == *"-R ycpss91255/worktool"* ]] || _bad+="no -R: ${_cmd}"$'\n'
            for _h in enforce_gh_body_file enforce_issue_milestone; do
                run bash -c 'jq -n --arg c "$1" "{tool_name:\"Bash\",tool_input:{command:\$c}}" | "$2"' \
                    _ "${_cmd}" "${REPO_ROOT}/.agents/hook/${_h}.sh"
                [[ "${status}" -eq 0 && -z "${output}" ]] || _bad+="${_h} denied: ${_cmd}"$'\n'
            done
        done < <(grep -E '^- ' "${_f}" | grep -oE "${_bt}gh [^${_bt}]+${_bt}" | tr -d "${_bt}")
    done
    assert_equal "${_bad}" ""
}

@test "the carried issue-tracker skill template names no heredoc body" {
    run grep -nE '^- .*(heredoc|--body ")' "${REPO_ROOT}/.agents/skills/setup-matt-pocock-skills/issue-tracker-github.md"
    assert_failure 1
    assert_output ""
}

@test "agent docs identify the contract as the sole skill layout exception with its review rationale" {
    local doc
    for doc in AGENTS.md doc/agent/domain.md; do
        run grep -E 'contract\.md.*唯一.*例外.*同一個 PR.*悄悄脫鉤' "${REPO_ROOT}/${doc}"
        assert_success
    done
}
