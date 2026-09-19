// pr-loop: one sub-issue -> one PR, driven to "CI green + codex 可合併".
//
// Invoke (from any cwd) with:
//   Workflow({ scriptPath: "<repo>/.claude/workflows/pr-loop.js", args: {
//     repo: "ycpss91255/worktool",          // required
//     issue: 150,                           // required: the ONE sub-issue this PR closes
//     branch: "m3/150-bench",               // required: branch name off origin/main
//     name: "bench",                        // required: worktree name under .worktree/
//     task: "...what to build, acceptance criteria, files, tests...",  // required
//     gates: "just test lint, just test unit, just test integration, just test system, just test acceptance, just test system-real",
//     codex: "on" | "off",                  // default "on"; "off" = quota paused
//     maxRounds: 3,                         // codex fix rounds before giving up
//     parent: "#5"                          // "Part of" reference for the PR body
//   } })
//
// Phases: Implement -> CI -> Codex -> (Fix -> CI -> Codex)* -> result.
// The workflow never merges: merge order and rebase conflicts stay with the
// main loop (one PR at a time, merge commit, keep agent commits).

export const meta = {
  name: 'pr-loop',
  description: 'One sub-issue -> one PR: implement (TDD, own worktree), wait for CI, codex re-verify, fix and re-verify up to maxRounds; never merges',
  whenToUse: 'Every worktool sub-issue. Pass args {repo, issue, branch, name, task, gates?, codex?, maxRounds?, parent?}.',
  phases: [
    { title: 'Implement', detail: 'agent: worktree off origin/main, TDD RED->GREEN, Docker gates, push, open PR' },
    { title: 'CI', detail: 'agent: gh pr checks --watch, fix and re-push if red' },
    { title: 'Codex', detail: 'agent: full-context codex exec; posts [codex] + [claude] double-check' },
    { title: 'Fix', detail: 'agent: address codex blocking items in the same worktree, independent commit, push' },
  ],
}

const A = args || {}
for (const k of ['repo', 'issue', 'branch', 'name', 'task']) {
  if (!A[k]) throw new Error(`pr-loop: args.${k} is required`)
}
const REPO = A.repo
const GATES = A.gates || 'just test lint, just test unit, just test integration, just test system, just test acceptance, just test system-real'
const CODEX = (A.codex || 'on') === 'on'
const MAX = A.maxRounds || 3
const PARENT = A.parent || ''
const WT = `.worktree/${A.name}`
const SP = '/tmp/claude-1000/-home-cyc-Desktop-initialization/15320221-f6f9-442e-9faa-924d66c5db63/scratchpad'

const RULES = `
Repo: /home/cyc/Desktop/worktool (branch main is protected: ci-passed required, merge only via PR). Rules: one issue = one PR, one thing; TDD (tests FIRST, show RED then GREEN in your report); tests run ONLY in Docker via the just interface (${GATES}) - never bats on the host, never install anything on the host; commits/code/comments English; issue/PR/docs zh-TW; NO emoji; no new "# shellcheck disable"; functions < 50 lines; every user action goes through just (thin forwarder recipe; the SCRIPT owns --help/validation, parses the whole command line before serving help, "unknown option '<x>' (see --help)" exit 2 - copy script/box/assemble.sh + script/box/justfile.box). All gh calls pass --repo ${REPO}. Commit trailer lines: "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" and "Claude-Session: https://claude.ai/code/session_01NX5H2vuMTv4mBmjpPYoS3s". Never write a "[codex]" line yourself. Gates run BLOCKING in the foreground (no Monitor/background).`

const IMPLEMENT = `${RULES}
Setup: cd /home/cyc/Desktop/worktool && git fetch origin && git worktree add -b ${A.branch} ${WT} origin/main && cd ${WT}. Work ONLY there.
TASK (issue #${A.issue}): ${A.task}
When all gates are green: git push -u origin ${A.branch}; open the PR: gh pr create --repo ${REPO} --base main --head ${A.branch} --title "<zh-TW title ending with (#${A.issue})>" --body-file <file>; the zh-TW body has: "Closes #${A.issue}"${PARENT ? `, "Part of ${PARENT}"` : ''}, "## 這個 PR 只做一件事" (one line), "## commit" (list), "## 測試證據" (gate tails verbatim in text code blocks), ${CODEX ? '"codex:本 PR 開啟後由 workflow 跑複驗,結果附於留言"' : '"codex:暫停中(配額),待配額恢復後補複驗"'}, and ends with "Generated with [Claude Code](https://claude.com/claude-code)". Do NOT merge. Leave the worktree in place (later phases reuse it). Return ONLY: PR number, branch, commit SHAs, RED/GREEN evidence, gate tails.`

const CI = (pr) => `Watch CI for PR #${pr} of ${REPO}: run \`timeout 1800 gh pr checks ${pr} --repo ${REPO} --watch --fail-fast\` in the foreground. If every check passes, return "green" plus the check list. If a check fails: read it (\`gh run view <run-id> --repo ${REPO} --log-failed\`), fix it in the existing worktree /home/cyc/Desktop/worktool/${WT} (branch ${A.branch}) with TDD and the same rules (${RULES}), commit (independent commit, English), push, watch again (max 2 rounds), then return "green" or "red: <why>" with the check list. Never merge.`

const CODEX_STEP = (pr, round, prior) => `Run ONE codex re-verification of PR #${pr} (${REPO}, issue #${A.issue}), round ${round}. Rules: never write a [codex] line yourself - only paste codex's actual output; zh-TW; no emoji; gh with --repo ${REPO}.
1. Context files in ${SP}: \`gh pr view ${pr} --repo ${REPO} --json title,body --jq '"# " + .title + "\\n\\n" + .body' > pr${pr}-ctx.md\`; \`gh issue view ${A.issue} --repo ${REPO} --json title,body --jq '"# issue #${A.issue} " + .title + "\\n\\n" + .body' >> pr${pr}-ctx.md\`; \`gh pr diff ${pr} --repo ${REPO} > pr${pr}.diff\`.
2. Prompt file pr${pr}-codex-prompt-r${round}.txt (zh-TW): "你是 codex。stdin 前半是 PR 描述與對應 issue,後半是完整 diff(以 '=== DIFF ===' 分隔)。${prior ? `這是第 ${round} 輪:你上一輪的判定逐字如下,請逐項確認是否已修正:\n${prior}\n` : ''}請靜態逐項確認:(1) 只做一件事且對應 issue 的驗收標準;(2) TDD 證據(RED/GREEN);(3) 自足(不引用不存在的檔案/旗標/recipe);(4) 正確性與健壯性(邊界、錯誤處理、shell 引號、測試能否抓到回歸);(5) 文件與實作一致;(6) 新引入的問題。阻擋項與非阻擋項分開列,每項引用 diff 位置。最後一句只能是「可合併」或「不可合併:<原因>」。"
3. \`{ cat pr${pr}-ctx.md; printf '\\n=== DIFF ===\\n'; cat pr${pr}.diff; } | timeout 420 codex exec --skip-git-repo-check "$(cat pr${pr}-codex-prompt-r${round}.txt)" > pr${pr}-codex-r${round}.txt 2>&1\`; answer = lines after the line "codex" (awk '/^codex$/{f=1;next} f'), minus trailing "tokens used" lines. Empty/auth error -> retry once after 60 s; still empty -> post a [claude] note and return verdict "no-output".
4. Post ONE PR comment: "[codex] 第 ${round} 輪複驗" + verbatim answer, blank line, "[claude] double-check: <did the prompt have full context; does every item cite a diff location>", and "可重現:\`gh pr diff ${pr} --repo ${REPO} | codex exec --skip-git-repo-check \\"$(cat pr${pr}-codex-prompt-r${round}.txt)\\"\`".
5. Return JSON-like text: verdict (the final line), blocking (list), nonBlocking (list), answer (verbatim).`

const FIX = (pr, round, blocking) => `${RULES}
Fix codex round ${round} findings on PR #${pr} (${REPO}) in the existing worktree /home/cyc/Desktop/worktool/${WT} (branch ${A.branch}; run \`git status\` first, pull --rebase if the remote moved). Blocking items to address (each one, TDD: add the failing test FIRST, show RED, then fix, GREEN):
${blocking.map((b, i) => `${i + 1}. ${b}`).join('\n')}
Run the gates (${GATES}) blocking in the foreground; commit ONE independent commit (English, "fix(...): ... (codex round ${round})" + trailers); push. Post a PR comment starting with "[claude] 採納第 ${round} 輪:" listing what changed per item. Do NOT merge. Return the commit SHA and a one-line-per-item summary.`

const NOCODEX = (pr) => `Post ONE comment on PR #${pr} (${REPO}) with exactly: "[claude] codex 暫停中(配額),待配額恢復後補複驗;CI 綠即依自主政策合併。" Then return "noted".`

phase('Implement')
const impl = await agent(IMPLEMENT, { label: `implement:#${A.issue}`, phase: 'Implement', agentType: 'general-purpose' })
const prMatch = String(impl || '').match(/(?:PR|pull\/)\s*#?(\d{2,5})/i) || String(impl || '').match(/pull\/(\d+)/)
if (!prMatch) return { issue: A.issue, status: 'no-pr', implement: impl }
const pr = Number(prMatch[1])
log(`#${A.issue}: PR #${pr} opened`)

let rounds = 0, verdict = '', prior = '', lastBlocking = []
let ci = await agent(CI(pr), { label: `ci:#${pr}`, phase: 'CI', agentType: 'general-purpose' })
if (!CODEX) {
  await agent(NOCODEX(pr), { label: `nocodex:#${pr}`, phase: 'Codex', agentType: 'general-purpose' })
  return { issue: A.issue, pr, ci, codex: 'off', rounds: 0 }
}
while (rounds < MAX) {
  rounds += 1
  const c = await agent(CODEX_STEP(pr, rounds, prior), { label: `codex:#${pr}:r${rounds}`, phase: 'Codex', agentType: 'general-purpose' })
  const text = String(c || '')
  verdict = (text.match(/verdict[^\n]*:\s*([^\n]+)/i) || [, text.trim().split('\n').pop()])[1].trim()
  const ok = /可合併/.test(verdict) && !/不可合併/.test(verdict)
  if (ok || /no-output/.test(verdict)) break
  const bl = text.split('\n').filter(l => /^\s*[-*\d.)]+\s*/.test(l) && !/非阻擋/.test(l)).map(l => l.replace(/^\s*[-*\d.)]+\s*/, '')).slice(0, 8)
  lastBlocking = bl.length ? bl : [verdict]
  prior = text
  if (rounds >= MAX) break
  await agent(FIX(pr, rounds, lastBlocking), { label: `fix:#${pr}:r${rounds}`, phase: 'Fix', agentType: 'general-purpose' })
  ci = await agent(CI(pr), { label: `ci:#${pr}:r${rounds}`, phase: 'CI', agentType: 'general-purpose' })
}
return { issue: A.issue, pr, ci, codex: verdict, rounds, blockingLeft: /不可合併/.test(verdict) ? lastBlocking : [] }
