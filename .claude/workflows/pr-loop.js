export const meta = {
  name: 'pr-loop',
  description: 'Drive one issue through implementation, CI and independent review without merging.',
  whenToUse: 'Every worktool sub-issue. Pass args {repo, repoDir, issue, branch, name, task, base?, pr?, mode?, implementer?, gates?, codex?, maxRounds?, parent?}.',
  phases: [
    { title: 'Implement', detail: 'agent: worktree off origin/<base>, TDD RED->GREEN, Docker gates, push, open PR' },
    { title: 'Review', detail: 'light: a separate Claude agent reviews only the diff and applies required fixes' },
    { title: 'Publish', detail: 'light: lint and touched specs, push and open PR' },
    { title: 'Locate', detail: 'agent: resolve the PR number and head SHA from the branch (structured)' },
    { title: 'CI', detail: 'agent: gh pr checks --watch, fix and re-push if red (structured green/red)' },
    { title: 'Codex', detail: 'agent: full-context codex exec; posts [codex] + [claude] double-check (structured verdict)' },
    { title: 'Fix', detail: 'agent: address codex blocking items in the same worktree, independent commit, push' },
  ],
}

// pr-loop: one sub-issue -> one PR, driven to "CI green + codex 可合併".
//
// Invoke (from any cwd) with:
//   Workflow({ scriptPath: "<repoDir>/.claude/workflows/pr-loop.js", args: {
//     repo: "ycpss91255/worktool",     // required: owner/name for every gh call
//     repoDir: "/path/to/worktool",     // required: the local checkout the worktrees hang off
//     issue: 150,                      // required: the ONE sub-issue this PR closes
//     branch: "m3/150-bench",          // required: branch off origin/<base>
//     name: "bench",                   // required: worktree name under <repoDir>/../worktree/
//     task: "...",                     // required: what to build, acceptance criteria, files, tests
//     base: "main",                   // optional: target branch, including acceptance branches
//     gates: "just test lint, ...",    // optional replacement gates; default = lint + changed
//     codex: "on" | "off",             // optional: default "on"; "off" = quota paused
//     maxRounds: 3,                    // optional: number of Fix rounds allowed (0 = review once, never fix)
//     parent: "#5",                    // optional: "Part of" reference in the PR body
//   } })
//
// Result: { issue, pr, sha, ciState, codexVerdict, rounds, blockingLeft }.
// The workflow never merges: merge order and rebase conflicts stay with the
// main loop (one PR at a time, merge commit, keep agent commits).

const A = args || {}
for (const k of ['repo', 'repoDir', 'issue', 'branch', 'name', 'task']) {
  if (!A[k]) throw new Error(`pr-loop: args.${k} is required`)
}
if (A.pr !== undefined && (!Number.isInteger(A.pr) || A.pr <= 0)) throw new Error('pr-loop: args.pr must be a positive integer')
const MODE = A.mode === undefined ? 'full' : A.mode
if (MODE !== 'full' && MODE !== 'light') throw new Error(`pr-loop: args.mode must be "full" or "light", got ${JSON.stringify(A.mode)}`)
const codexArg = A.codex === undefined ? 'on' : A.codex
if (codexArg !== 'on' && codexArg !== 'off') throw new Error(`pr-loop: args.codex must be "on" or "off", got ${JSON.stringify(A.codex)}`)
const IMPLEMENTER = MODE === 'light' ? 'claude' : (A.implementer === undefined ? 'codex' : A.implementer)
if (IMPLEMENTER !== 'codex' && IMPLEMENTER !== 'claude') throw new Error(`pr-loop: args.implementer must be "codex" or "claude", got ${JSON.stringify(A.implementer)}`)
if (codexArg === 'off' && IMPLEMENTER === 'codex') throw new Error('pr-loop: args.codex "off" cannot use implementer "codex"; use implementer: "claude"')
const MAX = A.maxRounds === undefined ? 3 : A.maxRounds
if (!Number.isInteger(MAX) || MAX < 0) throw new Error(`pr-loop: args.maxRounds must be a non-negative integer, got ${JSON.stringify(A.maxRounds)}`)
const RUN_ID = `pr-loop #${A.issue}`
log(RUN_ID)
const BASE = A.base === undefined ? 'main' : A.base
const REPO = A.repo
const REPO_DIR = A.repoDir
const WORKTREE_ROOT = `${REPO_DIR}/../worktree`
const CODEX = codexArg === 'on'
const CHANGED_GATE = BASE === 'main' ? 'just test changed' : `just test changed --base origin/${BASE}`
const GATES = A.gates || (MODE === 'light' ? 'just test lint and only the touched specs with just test <tier> <spec>' : `just test lint, ${CHANGED_GATE}`)
const PARENT = A.parent || ''
const WT = `${WORKTREE_ROOT}/${A.name}`
const SCRATCH = `${WORKTREE_ROOT}/.scratch/${A.name}`
// POSIX single quoting: how a value reaches a shell command.
const sq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`
// A literal path, escaped for a sed -E s#...#...# pattern.
const ere = (s) => String(s).replace(/[\\^$.*+?()[\]{}|#]/g, '\\$&')
// The repo is public (#233): codex cites files through the local directory
// it ran in, so its answer passes this sed filter before it is posted. The
// scratch checkout (<scratch>/tree/, or any absolute prefix up to a /tree/
// checkout), the worktree and repoDir become repo-relative; the rest of the
// scratch dir becomes <scratch>/.
const RELPATHS = `sed -E ${sq([
  `s#${ere(SCRATCH)}/tree/##g`,
  's#(^|[^[:alnum:]_.~/-])/[^[:space:]]*/tree/#\\1#g',
  `s#${ere(WT)}/##g`,
  `s#${ere(SCRATCH)}/#<scratch>/#g`,
  `s#${ere(REPO_DIR)}/##g`,
].join(';'))}`
const IMPLEMENT_OUT = `${SCRATCH}/implement.md`
const CODEX_TIMEOUT_SECONDS = 14400
const CODEX_WAIT_SECONDS = 540

const LOCATE_SCHEMA = { type: 'object', properties: { pr: { type: 'integer' }, sha: { type: 'string' } }, required: ['pr', 'sha'] }
const CI_SCHEMA = { type: 'object', properties: { state: { type: 'string', enum: ['green', 'red'] }, sha: { type: 'string' }, detail: { type: 'string' } }, required: ['state', 'sha', 'detail'] }
const CODEX_SCHEMA = { type: 'object', properties: { verdict: { type: 'string', enum: ['mergeable', 'blocked', 'no-output'] }, blocking: { type: 'array', items: { type: 'string' } }, nonBlocking: { type: 'array', items: { type: 'string' } }, answer: { type: 'string' } }, required: ['verdict', 'blocking', 'nonBlocking', 'answer'] }

const LOCAL_TEST_RULES = A.gates
  ? `In the TDD loop run only the slice's spec with just test <tier> <spec> [--filter]; before pushing run ${GATES}. Never run a whole tier locally; CI runs every tier.`
  : MODE === 'light'
  ? `In the TDD loop run only the slice's spec with just test <tier> <spec> [--filter]; before pushing run lint and only the touched specs. Never run just test changed or a whole tier locally; CI runs every tier.`
  : `In the TDD loop run only the slice's spec with just test <tier> <spec> [--filter]; before pushing run just test lint and ${CHANGED_GATE}. Never run a whole tier locally; CI runs every tier.`
const PUSH_HISTORY_RULES = `Never rewrite pushed commits: no rebase, amend, reset, or force push of pushed history. The only exception is the commit-email remedy from #234: rewrite pushed commits only to fix a non-noreply author, then push with --force-with-lease. Only add new commits; sync with ${BASE} by merging.`
const COMMON_GUARDRAILS = `
Repo: ${REPO_DIR} (branch main is protected: ci-passed required, merge only via PR). Work ONLY inside ${WT}; never touch another checkout or worktree. Rules: one issue = one PR, one thing; TDD (tests FIRST, show RED then GREEN in your report); tests run ONLY in Docker via the just interface (${GATES}) - never bats on the host, never install anything on the host. ${LOCAL_TEST_RULES} ${PUSH_HISTORY_RULES} Commits/code/comments English; issue/PR/docs zh-TW; NO emoji; no new "# shellcheck disable"; functions < 50 lines; every user action goes through just (thin forwarder recipe; the SCRIPT owns --help/validation, parses the whole command line before serving help, "unknown option '<x>' (see --help)" exit 2 - copy script/box/assemble.sh + script/box/justfile.box). All gh calls pass --repo ${REPO}. Gates run BLOCKING in the foreground (no Monitor/background). Never merge a PR. End the final paragraph of every commit message with Refs: #${A.issue}. For multiple issues, use one Refs: #<issue> line per issue.`
const SKILL_LOAD = {
  claude: 'Before planning or editing, use the Skill tool to load the tdd skill first and follow it.',
  codex: 'Before planning or editing, read .agents/skills/tdd/SKILL.md first and follow it.',
}
const TDD_IMPLEMENT_RULES = `Treat the issue 驗收 section as the approved behaviour list; do not ask the maintainer to approve it again. Work in vertical slices: each behaviour one test+implementation commit, or an adjacent RED commit then GREEN commit. Never put a batch of tests in one commit.`
const TDD_REVIEW_RULES = `Check that the commit history is vertical slices and that tests verify behaviour through the public interface. Structure- or implementation-detail tests are blocking.`
const GUARDRAILS = `${COMMON_GUARDRAILS} Commit with a GitHub noreply author and committer. Add no attribution or session trailer lines. Never write a "[codex]" line yourself.`
const CODEX_RULES = `${COMMON_GUARDRAILS} Commit with a GitHub noreply author and committer. Add no attribution or session trailer lines. PR bodies and comments you create start with "[codex]".`
const RULES = GUARDRAILS

const IMPLEMENT_TASK = `TASK (issue #${A.issue}): ${A.task}
When all gates are green: git push -u origin ${A.branch}; open the PR: gh pr create --repo ${REPO} --base ${BASE} --head ${A.branch} --title "<zh-TW title ending with (#${A.issue})>" --body-file <file>; the zh-TW body has: "Closes #${A.issue}"${PARENT ? `, "Part of ${PARENT}"` : ''}, "## 這個 PR 只做一件事" (one line), "## commit" (list), "## 測試證據" (gate tails verbatim in text code blocks), ${CODEX ? '"codex:本 PR 開啟後由 workflow 跑複驗,結果附於留言"' : '"codex:暫停中(配額),待配額恢復後補複驗"'}`

const IMPLEMENT = `${RULES}
${SKILL_LOAD.claude}
${TDD_IMPLEMENT_RULES}
Setup: cd ${REPO_DIR} && git fetch origin && git worktree add -b ${A.branch} ${WT} origin/${BASE} && cd ${WT}. Work ONLY there.
${IMPLEMENT_TASK}. Do NOT merge. Leave the worktree in place (later phases reuse it). Report: PR URL, branch, commit SHAs, RED/GREEN evidence, gate tails.`

const CODEX_IMPLEMENT_BRIEF = `${CODEX_RULES}
${SKILL_LOAD.codex}
${TDD_IMPLEMENT_RULES}
${IMPLEMENT_TASK}. The PR body starts with "[codex]" and has no attribution footer. Do NOT merge. Leave the worktree in place (later phases reuse it). Report: PR URL, branch, commit SHAs, RED/GREEN evidence, gate tails.`

const CODEX_DETACHED_RUN = (out, rc) => `Create ${SCRATCH}, write the brief below verbatim to <暫存檔>, and remove any stale ${rc}. Start codex detached with setsid nohup and this command; keep the codex exec command shape unchanged:
setsid nohup bash -c 'timeout ${CODEX_TIMEOUT_SECONDS} codex exec --skip-git-repo-check -C ${WT} -o ${out} "$(cat <暫存檔>)" < /dev/null; rc=$?; printf "%s\\n" "$rc" > ${rc}' > ${out}.log 2>&1 &
Do not use run_in_background or Monitor. Wait in repeated bounded foreground calls, each below ten minutes:
timeout ${CODEX_WAIT_SECONDS} bash -c 'until [ -s ${rc} ]; do sleep 30; done'
An exit 124 from a wait call only means to run that same wait call again. Once ${rc} exists, inspect its value. Then list test containers mounting the worktree with \`docker ps --filter volume=${WT} --format '{{.ID}}'\` and stop every returned container with \`docker stop\` before continuing. If the codex rc is non-zero, including timeout rc 124, report failure and include the last 80 lines from \`tail -n 80 ${out}\`; never treat it as success.`

const CODEX_IMPLEMENT = `Your job is to run codex as the implementer, wait for it, and verify its result. Do not implement the task yourself.

${CODEX_RULES}

First run: cd ${REPO_DIR} && git fetch origin && git worktree add -b ${A.branch} ${WT} origin/${BASE}.
${CODEX_DETACHED_RUN(IMPLEMENT_OUT, `${SCRATCH}/implement.rc`)}
Do not add sandbox flags. After codex exits, verify with scripts that it changed only ${WT}, used the required noreply author and committer, added no attribution or session trailer lines, preserved vertical RED/GREEN slices, pushed ${A.branch}, and opened its PR. Report any failed check; do not repair it yourself.

brief:
${CODEX_IMPLEMENT_BRIEF}`

const LOCATE = `Resolve the open PR for branch ${A.branch} in ${REPO}: run \`gh pr list --repo ${REPO} --head ${A.branch} --base ${BASE} --state open --json number,headRefOid --jq '.[0]'\`. Return pr (integer) and sha (the headRefOid). If there is no such PR, return pr 0 and sha "".`

const CI_LOCAL_TEST_RULES = A.gates
  ? `Before pushing run ${GATES} blocking in the foreground. Never run a whole tier locally; CI runs every tier.`
  : 'Locally run only just test lint and changed unit specs with just test unit <spec...> [--filter REGEX]. Never run matrix, integration, system, system-real, acceptance or a whole unit tier locally; those tiers are verified by CI (ci-passed).'

const CI = (pr) => `Watch CI for PR #${pr} of ${REPO} against base ${BASE}. Before watching a resumed PR, verify its headRefName equals ${A.branch}, its state is OPEN and baseRefName equals ${BASE}; lookup failure or mismatch is red. In ${WT}, require a clean working tree on ${A.branch}; fetch origin, and if local HEAD is ahead of the remote branch, run ${GATES} blocking in the foreground, verify noreply author/committer and Refs: #${A.issue} on every unpublished commit, then push without rewriting history. If remote is ahead, sync by merging and run the same gates before pushing; divergence or any failed guard must be resolved safely or return red. Never watch a stale head. First run \`gh pr view ${pr} --repo ${REPO} --json baseRefName --jq .baseRefName\`; on lookup failure or base mismatch, return state "red" with the failure reason and do not judge CI green. Then run \`timeout 1800 gh pr checks ${pr} --repo ${REPO} --watch --fail-fast\` in the foreground. If every check passes, return state "green". If a check fails: read it (\`gh run view <run-id> --repo ${REPO} --log-failed\`), fix it in the existing worktree ${WT} (branch ${A.branch}) with TDD. ${CI_LOCAL_TEST_RULES} Continue and these rules (${RULES}), commit (independent commit, English), push, watch again (max 2 rounds); then return state "green" or "red". Always return sha = current head of the branch (\`git -C ${WT} rev-parse HEAD\`) and detail = the check list or the failure reason. Never merge.`

const CODEX_STEP = (pr, round, prior) => `Run ONE codex re-verification of PR #${pr} (${REPO}, issue #${A.issue}), round ${round}, against base ${BASE} (diff equivalent to git diff origin/${BASE}...HEAD). First run gh pr view ${pr} --repo ${REPO} --json baseRefName --jq .baseRefName and verify it is ${BASE}; lookup failure or mismatch is blocking. Rules: never write a [codex] line yourself - only paste codex's actual output; zh-TW; no emoji; gh with --repo ${REPO}. Work dir: mkdir -p ${SCRATCH} && cd ${SCRATCH}.
1. Context: \`gh pr view ${pr} --repo ${REPO} --json title,body --jq '"# " + .title + "\\n\\n" + .body' > ctx-r${round}.md\`; \`gh issue view ${A.issue} --repo ${REPO} --json title,body --jq '"# issue #${A.issue} " + .title + "\\n\\n" + .body' >> ctx-r${round}.md\`; \`gh pr diff ${pr} --repo ${REPO} > pr.diff\`; the issue's scope section, cut by the shell (never retyped), as ONE command whose exit status you check: \`gh issue view ${A.issue} --repo ${REPO} --json body --jq .body > issue-r${round}.md && tr -d '\\r' < issue-r${round}.md | awk '/^## 範圍/{f=1;print;next} f&&/^## /{exit} f' > scope-r${round}.md && { [ -s scope-r${round}.md ] || printf '%s\\n' 'issue 未定範圍:issue 本文沒有「## 範圍」段,依一般標準判定,並在非阻擋項註記「issue 未定範圍」。' > scope-r${round}.md; }\`. If it exits non-zero (gh failed: network, auth, API), retry once after 60 s; still non-zero -> never write the 未定範圍 note yourself and do not run codex: post a [claude] comment "讀取 issue #${A.issue} 失敗,本輪未完成" and return verdict "no-output", blocking ["讀取 issue #${A.issue} 失敗"], and an empty answer.
2. Prompt file: write the text below to draft-r${round}.txt with the line @@SCOPE@@ kept as is, then paste scope-r${round}.md into it verbatim: \`awk -v f=scope-r${round}.md '$0 == "@@SCOPE@@" { while ((getline l < f) > 0) print l; next } 1' draft-r${round}.txt > prompt-r${round}.txt\` (zh-TW): "你是 codex。stdin 前半是 PR 描述與對應 issue,後半是完整 diff(以 '=== DIFF ===' 分隔)。本 issue 的「## 範圍」段(擋 / 不擋 / 已知限制)逐字如下:\n@@SCOPE@@\n若上方是範圍段,只有落在上述範圍內的具體問題才可列為阻擋項(須指出 diff 位置與具體失敗情境);範圍外的寫法、延伸情境、假設性繞過與措辭一律列為非阻擋項。${prior ? `這是第 ${round} 輪:你上一輪的判定逐字如下,請逐項確認是否已修正:\n${prior}\n` : ''}${TDD_REVIEW_RULES} 請靜態逐項確認:(1) 只做一件事且對應 issue 的驗收標準;(2) TDD 證據(RED/GREEN);(3) 自足(不引用不存在的檔案/旗標/recipe);(4) 正確性與健壯性(邊界、錯誤處理、shell 引號、測試能否抓到回歸);(5) 文件與實作一致;(6) 新引入的問題。阻擋項列在「## 阻擋項」標題下、非阻擋項列在「## 非阻擋項」標題下,每項引用 diff 位置。最後一行只能是「可合併」或「不可合併:<原因>」。"
3. \`{ cat ctx-r${round}.md; printf '\\n=== DIFF ===\\n'; cat pr.diff; } | timeout 420 codex exec --skip-git-repo-check "$(cat prompt-r${round}.txt)" > out-r${round}.txt 2>&1\`; then extract the answer (lines after the line that is exactly "codex", minus trailing "tokens used" lines, local working-directory paths rewritten repo-relative) in the foreground: \`cd ${sq(SCRATCH)} && awk '/^codex$/{f=1;next} f' out-r${round}.txt | sed '/^tokens used/,$d' | ${RELPATHS} > answer-r${round}.md\`; answer = the content of answer-r${round}.md. Empty output or an auth/quota error -> retry once after 60 s; still empty -> post a [claude] comment "codex 無輸出(配額/認證),本輪未完成" and return verdict "no-output" with an empty answer.
4. Post ONE PR comment through a body file: "[codex] 第 ${round} 輪複驗" + the verbatim answer copied by the shell (\`cat answer-r${round}.md\`; never the raw out-r${round}.txt, never retyped), blank line, "[claude] double-check: <did the prompt have full context; does every item cite a diff location>", and "可重現:\`gh pr diff ${pr} --repo ${REPO} | codex exec --skip-git-repo-check \\"$(cat prompt-r${round}.txt)\\"\`".
5. Return: verdict = "mergeable" if the LAST line of the answer is exactly 可合併, "blocked" if it starts with 不可合併, otherwise "blocked" too (unparseable is not a pass); blocking = the items under 「## 阻擋項」 (one string each, short); nonBlocking = items under 「## 非阻擋項」; answer = the verbatim answer.`

const CLAUDE_REVIEW = (pr, round, prior) => `${GUARDRAILS}
Review PR #${pr} (${REPO}, issue #${A.issue}), round ${round} directly as Claude against base ${BASE} (git diff origin/${BASE}...HEAD). Verify the PR baseRefName is ${BASE}; lookup failure or mismatch is blocking. This is read-only: inspect the PR description, issue scope, complete diff, RED/GREEN evidence, and gate evidence. Only concrete in-scope failures may be blocking. Check one-issue scope, correctness, robustness, shell quoting, tests, and documentation. ${prior ? `Re-check every item from the prior verdict:\n${prior}` : ''}
${TDD_REVIEW_RULES}
Return the structured verdict without editing files, pushing, commenting, or merging.`

const FIX = (pr, round, blocking) => `${RULES}
${SKILL_LOAD.claude}
${TDD_IMPLEMENT_RULES}
Fix review round ${round} findings on PR #${pr} (${REPO}) in the existing worktree ${WT} (branch ${A.branch}; run \`git status\` first, then merge the remote branch if it moved). Blocking items to address (each one, TDD: add the failing test FIRST, show RED, then fix, GREEN):
${blocking.map((b, i) => `${i + 1}. ${b}`).join('\n')}
Run the gates (${GATES}) blocking in the foreground; commit ONE independent commit (English, "fix(...): ... (codex round ${round})"); push. Post a PR comment starting with "[claude] 採納第 ${round} 輪:" listing what changed per item. Do NOT merge. Return the commit SHA and a one-line-per-item summary.`

const CODEX_FIX_BRIEF = (pr, round, blocking) => `${CODEX_RULES}
${SKILL_LOAD.codex}
${TDD_IMPLEMENT_RULES}
Fix review round ${round} findings on PR #${pr} (${REPO}) in the existing worktree ${WT} (branch ${A.branch}; run \`git status\` first, then merge the remote branch if it moved). Blocking items to address (each one, TDD: add the failing test FIRST, show RED, then fix, GREEN):
${blocking.map((b, i) => `${i + 1}. ${b}`).join('\n')}
Run the gates (${GATES}) blocking in the foreground; commit ONE independent commit (English, "fix(...): ... (review round ${round})", with no attribution or session trailer lines); push. Post a PR comment starting with "[codex] 採納第 ${round} 輪:" listing what changed per item. Do NOT merge. Return the commit SHA and a one-line-per-item summary.`

const CODEX_FIX = (pr, round, blocking) => `Your job is to run codex as the implementer for a fix round, wait for it, and verify its result. Do not fix the task yourself.

${CODEX_RULES}

${CODEX_DETACHED_RUN(`${SCRATCH}/fix-r${round}.md`, `${SCRATCH}/fix-r${round}.rc`)}
Do not add sandbox flags. After codex exits, verify with scripts that it changed only ${WT}, used the required noreply author and committer, added no attribution or session trailer lines, preserved vertical RED/GREEN slices, pushed ${A.branch}, and updated PR #${pr}. Report any failed check; do not repair it yourself.

brief:
${CODEX_FIX_BRIEF(pr, round, blocking)}`

const NOCODEX = (pr) => `Post ONE comment on PR #${pr} (${REPO}) with exactly: "[claude] codex 暫停中(配額),待配額恢復後補複驗。" Then return "noted".`

const result = (extra) => ({ issue: A.issue, ...extra })

// Read fresh remote state rather than trusting an implementer's completion prose.
const checkStage = async (pr, stage, before = '') => {
  const script = `cd ${sq(WT)} && {
errors=''
status=$(git status --porcelain) || errors='git status failed; '
local_head=$(git rev-parse HEAD) || errors="$errors local HEAD lookup failed; "
remote_head=$(git ls-remote --exit-code origin ${sq(`refs/heads/${A.branch}`)}) || errors="$errors remote HEAD lookup failed; "
remote_head=$(printf '%s' "$remote_head" | cut -f1)
pr_head=$(gh pr view ${pr} --repo ${sq(REPO)} --json headRefOid --jq .headRefOid) || errors="$errors PR head lookup failed; "
jq -cn --arg status "$status" --arg localHead "$local_head" --arg remoteHead "$remote_head" --arg prHead "$pr_head" --arg errors "$errors" '{status:$status,localHead:$localHead,remoteHead:$remoteHead,prHead:$prHead,errors:$errors}'
}`
  const checked = await agent(`Run this script blocking in the foreground, without editing, committing or pushing: \`${script}\`.
Return its stdout verbatim in evidence, even when it contains errors. Do not infer success from the prior agent's report.`, {
    label: `${RUN_ID} stage-check:${stage}:#${pr}`,
    schema: { type: 'object', properties: { evidence: { type: 'string' } }, required: ['evidence'] },
    agentType: 'general-purpose',
  })
  let state
  try {
    state = JSON.parse(checked.evidence)
    if (!state || typeof state !== 'object' || Array.isArray(state)) throw new Error('invalid evidence')
  } catch { return { ok: false, detail: `${stage} check failed: no valid script evidence; git status and HEAD comparison unavailable` } }
  const valid = ['status', 'localHead', 'remoteHead', 'prHead', 'errors'].every(k => typeof state[k] === 'string')
  const ok = valid && !state.errors && !state.status && !!state.localHead &&
    state.localHead === state.remoteHead && state.localHead === state.prHead &&
    (!before || state.prHead !== before)
  return { ok, sha: state.prHead, detail: `${stage} check failed: ${state.errors || ''}git status: ${state.status || '(clean)'}; local HEAD: ${state.localHead}; remote HEAD: ${state.remoteHead}; PR head: ${state.prHead}; before: ${before || '(Implement)'}` }
}

// Probe the branch before choosing fresh implementation or resume.
const prepared = await agent(`${IMPLEMENTER === 'codex' ? CODEX_RULES : GUARDRAILS}
Run this script blocking in the foreground; return stdout verbatim in state. Only recreate the named worktree if absent; never alter another worktree, implement, push or rewrite history:
\`cd ${sq(REPO_DIR)} && {
if git show-ref --verify --quiet ${sq(`refs/heads/${A.branch}`)}; then
  if [ ! -e ${sq(WT)} ]; then
    registered=$(git worktree list --porcelain) || exit 1
    target=$(realpath -m ${sq(WT)}) || exit 1
    if printf '%s\\n' "$registered" | grep -Fxq "worktree $target"; then
      git worktree remove --force ${sq(WT)} >&2 || exit 1
    else
      rc=$?
      [ "$rc" -eq 1 ] || exit 1
    fi
    git worktree add ${sq(WT)} ${sq(A.branch)} >&2 || exit 1
  fi
  common=$(git rev-parse --path-format=absolute --git-common-dir) &&
  cd ${sq(WT)} &&
  [ "$(git rev-parse --path-format=absolute --git-common-dir)" = "$common" ] &&
  [ "$(git branch --show-current)" = ${sq(A.branch)} ] && printf resume
else
  rc=$?
  [ "$rc" -eq 1 ] && printf new
fi
}\``, { label: `${RUN_ID} prepare:${A.branch}`, phase: 'Locate', schema: { type: 'object', properties: { state: { type: 'string', enum: ['new', 'resume'] } }, required: ['state'] }, agentType: 'general-purpose' })
if (!prepared || !['new', 'resume'].includes(prepared.state)) return result({ pr: A.pr || 0, sha: '', ciState: 'none', codexVerdict: 'blocked', rounds: 0, blockingLeft: ['branch/worktree preparation failed'] })
const RESUME = prepared.state === 'resume'
if (A.pr && !RESUME) return result({ pr: A.pr, sha: '', ciState: 'none', codexVerdict: 'blocked', rounds: 0, blockingLeft: ['resume PR requires an existing branch'] })

// Light finishes editing and independent diff review before publishing.
if (MODE === 'light' && !RESUME) {
  phase('Implement')
  const edited = await agent(`${GUARDRAILS}
${SKILL_LOAD.claude}
${TDD_IMPLEMENT_RULES}
Act directly as Claude; do not invoke codex or delegate implementation.
Setup: cd ${REPO_DIR} && git fetch origin && git worktree add -b ${A.branch} ${WT} origin/${BASE} && cd ${WT}.
TASK (issue #${A.issue}): ${A.task}
For behaviour changes use TDD; mechanical edits without new behaviour need no new tests. Commit each completed slice with noreply author and committer and no attribution. Do not push or open a PR yet. Leave the worktree for independent review. Report commits and RED/GREEN evidence. Return status ready only after every slice is committed; otherwise failed. Always include reason: on failure name the step and explain why it failed; on success use an empty string.`, { label: `${RUN_ID} implement:#${A.issue}`, phase: 'Implement', schema: { type: 'object', properties: { status: { type: 'string', enum: ['ready', 'failed'] }, reason: { type: 'string' } }, required: ['status', 'reason'] }, agentType: 'general-purpose' })
  if (!edited || edited.status !== 'ready') return result({ pr: 0, sha: '', ciState: 'none', codexVerdict: 'skipped', rounds: 0, blockingLeft: [`light editing did not complete: ${(edited && edited.reason) || 'editor returned no failure reason'}`] })
  phase('Review')
  const reviewed = await agent(`${GUARDRAILS}
${SKILL_LOAD.claude}
${TDD_REVIEW_RULES}
You are a separate Claude reviewer, not the editor. Review only the complete diff in ${WT}: git diff origin/${BASE}...HEAD and any uncommitted diff. Do not run codex or a full-context review. Apply all required fixes in this worktree with TDD for behaviour changes; append independent commits without rewriting pushed history. Run ${GATES} blocking in the foreground after fixes. Do not push or open a PR. Return verdict mergeable only when every required fix is applied and gates pass; otherwise return blocked with concrete blocking items.`, { label: `${RUN_ID} review:#${A.issue}:light`, phase: 'Review', schema: CODEX_SCHEMA, agentType: 'general-purpose' })
  if (!reviewed || reviewed.verdict !== 'mergeable') return result({ pr: 0, sha: '', ciState: 'none', codexVerdict: 'skipped', rounds: 0, blockingLeft: (reviewed && reviewed.blocking && reviewed.blocking.length) ? reviewed.blocking : ['light diff review did not pass'] })
  phase('Publish')
  await agent(`${GUARDRAILS}
In ${WT}, run ${GATES} blocking in the foreground. Only when green, push with git push -u origin ${A.branch} and open one PR with gh pr create --repo ${REPO} --base ${BASE} --head ${A.branch} --title "<zh-TW title ending with (#${A.issue})>" --body-file <file>. Body: Closes #${A.issue}${PARENT ? `, Part of ${PARENT}` : ''}, ## 這個 PR 只做一件事, ## commit, ## 測試證據 with verbatim gate tails, and light:兩個不同 Claude 子代理已完成修改與 diff 審查,不跑 codex 複驗. Start the body with [claude]. No attribution footer. Never merge.`, { label: `${RUN_ID} publish:#${A.issue}`, phase: 'Publish', agentType: 'general-purpose' })
  phase('Locate')
  const loc = await agent(LOCATE, { label: `${RUN_ID} locate:${A.branch}`, phase: 'Locate', schema: LOCATE_SCHEMA, agentType: 'general-purpose' })
  if (!loc || !loc.pr) return result({ pr: 0, sha: '', ciState: 'none', codexVerdict: 'skipped', rounds: 0, blockingLeft: ['no PR was opened for the branch'] })
  const checked = await checkStage(loc.pr, 'Implement')
  if (!checked.ok) return result({ pr: loc.pr, sha: checked.sha || loc.sha, ciState: 'none', codexVerdict: 'skipped', rounds: 0, blockingLeft: [checked.detail] })
  phase('CI')
  const ci = await agent(CI(loc.pr), { label: `${RUN_ID} ci:#${loc.pr}`, phase: 'CI', schema: CI_SCHEMA, agentType: 'general-purpose' })
  return result({ pr: loc.pr, sha: (ci && ci.sha) || loc.sha, ciState: ci && ci.state === 'green' ? 'green' : 'red', codexVerdict: 'skipped', rounds: 0, blockingLeft: ci && ci.state === 'green' ? [] : [(ci && ci.detail) || 'CI did not go green'] })
}

if (!RESUME) {
  phase('Implement')
  await agent(IMPLEMENTER === 'codex' ? CODEX_IMPLEMENT : IMPLEMENT, { label: `${RUN_ID} implement:#${A.issue}`, phase: 'Implement', agentType: 'general-purpose' })
}

let resumedPR
if (RESUME && !A.pr) {
  phase('Publish')
  resumedPR = await agent(`${IMPLEMENTER === 'codex' ? CODEX_RULES : GUARDRAILS}
Resume the committed work in ${WT} on ${A.branch}; skip implementation. Require a clean worktree and inspect git log. Locate an existing open PR by branch and base ${BASE} first; reuse it rather than opening a duplicate. If none exists, require unpublished commits (compare origin/${A.branch}..HEAD, or origin/${BASE}..HEAD when the remote branch is absent). No unpublished commits or any lookup failure is blocking; return pr 0, sha "" without pushing.
Before publishing, run ${GATES} blocking in the foreground. Check every unpublished commit for noreply author/committer, Refs: #${A.issue}, and no attribution trailers. Only when green, git push -u origin ${A.branch}; then gh pr create --repo ${REPO} --base ${BASE} --head ${A.branch} --title "<zh-TW title ending with (#${A.issue})>" --body-file <file>.
Body starts with ${IMPLEMENTER === 'codex' ? '[codex]' : '[claude]'} and includes Closes #${A.issue}${PARENT ? `, Part of ${PARENT}` : ''}, ## 這個 PR 只做一件事, ## commit, ## 測試證據 with verbatim gate tails, and ${MODE === 'light' ? 'light:接續既有修改,不跑 codex 複驗' : CODEX ? 'codex:本 PR 開啟後由 workflow 跑複驗,結果附於留言' : 'codex:暫停中(配額),待配額恢復後補複驗'}. Return the PR number and head SHA using structured gh output. Do not merge.`, { label: `${RUN_ID} publish:#${A.issue}:resume`, phase: 'Publish', schema: LOCATE_SCHEMA, agentType: 'general-purpose' })
}
phase('Locate')
const loc = RESUME ? (A.pr ? { pr: A.pr, sha: '' } : resumedPR) : await agent(LOCATE, { label: `${RUN_ID} locate:${A.branch}`, phase: 'Locate', schema: LOCATE_SCHEMA, agentType: 'general-purpose' })
if (!loc || !loc.pr) return result({ pr: 0, sha: '', ciState: 'none', codexVerdict: 'none', rounds: 0, blockingLeft: ['no PR was opened for the branch'] })
const pr = loc.pr
let sha = loc.sha
const implemented = RESUME && A.pr ? { ok: true, sha } : await checkStage(pr, 'Implement')
if (!implemented.ok) return result({ pr, sha: implemented.sha || sha, ciState: 'none', codexVerdict: 'blocked', rounds: 0, blockingLeft: [implemented.detail] })
sha = implemented.sha
log(`#${A.issue}: PR #${pr} at ${sha.slice(0, 7)}`)

phase('CI')
let ci = await agent(CI(pr), { label: `${RUN_ID} ci:#${pr}`, phase: 'CI', schema: CI_SCHEMA, agentType: 'general-purpose' })
if (!ci || ci.state !== 'green') return result({ pr, sha: (ci && ci.sha) || sha, ciState: 'red', codexVerdict: 'skipped', rounds: 0, blockingLeft: [(ci && ci.detail) || 'CI did not go green'] })
sha = ci.sha || sha
if (RESUME) {
  const checked = await checkStage(pr, 'Resume')
  if (!checked.ok) return result({ pr, sha: checked.sha || sha, ciState: 'green', codexVerdict: 'blocked', rounds: 0, blockingLeft: [checked.detail] })
  sha = checked.sha
}

if (MODE === 'light') return result({ pr, sha, ciState: 'green', codexVerdict: 'skipped', rounds: 0, blockingLeft: [] })

if (!CODEX) {
  await agent(NOCODEX(pr), { label: `${RUN_ID} nocodex:#${pr}`, phase: 'Codex', agentType: 'general-purpose' })
  return result({ pr, sha, ciState: 'green', codexVerdict: 'off', rounds: 0, blockingLeft: [] })
}

let fixes = 0, verdict = 'blocked', blocking = [], prior = ''
for (;;) {
  const reviewByClaude = IMPLEMENTER === 'codex'
  const c = await agent(reviewByClaude ? CLAUDE_REVIEW(pr, fixes + 1, prior) : CODEX_STEP(pr, fixes + 1, prior), { label: `${RUN_ID} review:#${pr}:r${fixes + 1}`, phase: 'Codex', schema: CODEX_SCHEMA, agentType: 'general-purpose' })
  if (!c) { verdict = 'no-output'; blocking = ['codex agent returned nothing']; break }
  verdict = c.verdict
  blocking = c.blocking || []
  if (verdict === 'mergeable') break
  if (verdict === 'no-output') { blocking = blocking.length ? blocking : ['codex returned no output; re-run when the quota is back']; break }
  if (fixes >= MAX) break
  fixes += 1
  prior = c.answer
  const fixBrief = IMPLEMENTER === 'codex'
    ? CODEX_FIX(pr, fixes, blocking.length ? blocking : ['see the review answer above'])
    : FIX(pr, fixes, blocking.length ? blocking : ['see the codex answer above'])
  await agent(fixBrief, { label: `${RUN_ID} fix:#${pr}:r${fixes}`, phase: 'Fix', agentType: 'general-purpose' })
  const checked = await checkStage(pr, 'Fix', sha)
  if (!checked.ok) return result({ pr, sha: checked.sha || sha, ciState: 'green', codexVerdict: 'blocked', rounds: fixes, blockingLeft: [checked.detail].concat(blocking) })
  ci = await agent(CI(pr), { label: `${RUN_ID} ci:#${pr}:r${fixes}`, phase: 'CI', schema: CI_SCHEMA, agentType: 'general-purpose' })
  if (!ci || ci.state !== 'green') return result({ pr, sha: (ci && ci.sha) || sha, ciState: 'red', codexVerdict: 'blocked', rounds: fixes, blockingLeft: [(ci && ci.detail) || 'CI red after fix round'].concat(blocking) })
  sha = ci.sha || sha
}
return result({ pr, sha, ciState: 'green', codexVerdict: verdict, rounds: fixes, blockingLeft: verdict === 'mergeable' ? [] : blocking })

// args 範例（可直接貼進 Workflow 的 args）
// {
//   "repo": "ycpss91255/worktool",
//   "repoDir": "/path/to/worktool",
//   "issue": 283,
//   "branch": "chore/283-implementer",
//   "name": "impl283",
//   "task": "依 issue #283 的範圍與驗收實作。",
//   "implementer": "codex",
//   "gates": "just test lint, just test changed",
//   "maxRounds": 3
// }
