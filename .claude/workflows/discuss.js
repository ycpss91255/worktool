export const meta = {
  name: 'discuss',
  description: 'Independent Claude and codex answers before asking the maintainer',
  whenToUse: 'Pass {repo, repoDir, issue, question, context?, premises?, references?}.',
  phases: [
    { title: 'Answer', detail: 'Independent answers' },
    { title: 'Compare', detail: 'Compare evidence and conclusions' },
  ],
}

const A = args || {}
for (const k of ['repo', 'repoDir', 'question']) {
  if (typeof A[k] !== 'string' || !A[k].trim() || /[\u0000-\u001f\u007f`]/.test(A[k])) throw new Error(`discuss: invalid args.${k}`)
}
if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(A.repo)) throw new Error('discuss: invalid args.repo')
if (!A.repoDir.startsWith('/')) throw new Error('discuss: invalid args.repoDir')
if (!Number.isInteger(A.issue) || A.issue < 1) throw new Error('discuss: invalid args.issue')
for (const k of ['context', 'premises', 'references']) {
  if (A[k] !== undefined && typeof A[k] !== 'string') throw new Error(`discuss: invalid args.${k}`)
}
const REPO = A.repo
const REPO_DIR = A.repoDir
const WT = REPO_DIR
const SCRATCH = `${REPO_DIR}/../worktree/.scratch/discuss-${A.issue}`
const GATES = 'just test lint and only the touched specs with just test <tier> <spec>'
const LOCAL_TEST_RULES = `In the TDD loop run only the slice's spec with just test <tier> <spec> [--filter]; before pushing run lint and only the touched specs. Never run just test changed or a whole tier locally; CI runs every tier.`
const CODEX_TIMEOUT_SECONDS = 14400
const CODEX_WAIT_SECONDS = 540
const sq = s => `'${String(s).replace(/'/g, `'\\''`)}'`
const PUSH_HISTORY_RULES = `Never rewrite pushed commits: no rebase, amend, reset, or force push of pushed history. The only exception is the commit-email remedy from #234: rewrite pushed commits only to fix a non-noreply author, then push with --force-with-lease. Only add new commits; sync with main by merging.`
const COMMON_GUARDRAILS = `
Repo: ${REPO_DIR} (branch main is protected: ci-passed required, merge only via PR). Work ONLY inside ${REPO_DIR}; never touch another checkout or worktree. Rules: one issue = one PR, one thing; TDD (tests FIRST, show RED then GREEN in your report); tests run ONLY in Docker via the just interface (${GATES}) - never bats on the host, never install anything on the host. ${LOCAL_TEST_RULES} ${PUSH_HISTORY_RULES} Commits/code/comments English; issue/PR/docs zh-TW; NO emoji; no new "# shellcheck disable"; functions < 50 lines; every user action goes through just (thin forwarder recipe; the SCRIPT owns --help/validation, parses the whole command line before serving help, "unknown option '<x>' (see --help)" exit 2 - copy script/box/assemble.sh + script/box/justfile.box). All gh calls pass --repo ${REPO}. Gates run BLOCKING in the foreground (no Monitor/background). Never merge a PR.`
const GUARDRAILS = `${COMMON_GUARDRAILS} Commit with a GitHub noreply author and committer. Add no attribution or session trailer lines. Never write a "[codex]" line yourself.`
const SCRATCH_ONLY = `Read only: never change the checkout. Intermediate files go ONLY under ${JSON.stringify(SCRATCH)}. Do not publish comments; the Record phase owns publication.`
const ANSWER = { type: 'object', properties: {
  answer: { type: 'string' }, reasons: { type: 'array', items: { type: 'string' } },
  risks: { type: 'array', items: { type: 'string' } }, error: { type: 'string' },
}, required: ['answer', 'reasons', 'risks'] }
const brief = n => `Question: ${A.question}\nContext: ${A.context || ''}\nApproved premises: ${A.premises || ''}\nRelated issues / ADRs: ${A.references || ''}\nRound ${n}. Independently answer; cite every judgment with issue URLs or repo-relative file:line evidence. Read CONTEXT.md and doc/contract.md. Do not invent evidence. ${SCRATCH_ONLY}`
const CODEX_DETACHED_RUN = (out, rc) => `Create ${SCRATCH}, write the brief below verbatim to <暫存檔>, and remove any stale ${rc}. Start codex detached with setsid nohup and this command; keep the codex exec command shape unchanged:
setsid nohup bash -c 'timeout ${CODEX_TIMEOUT_SECONDS} codex exec --skip-git-repo-check -C ${WT} -o ${out} "$(cat <暫存檔>)" < /dev/null; rc=$?; printf "%s\\n" "$rc" > ${rc}' > ${out}.log 2>&1 &
Do not use run_in_background or Monitor. Wait in repeated bounded foreground calls, each below ten minutes:
timeout ${CODEX_WAIT_SECONDS} bash -c 'until [ -s ${rc} ]; do sleep 30; done'
An exit 124 from a wait call only means to run that same wait call again. Once ${rc} exists, inspect its value. Then list test containers mounting the worktree with \`docker ps --filter volume=${WT} --format '{{.ID}}'\` and stop every returned container with \`docker stop\` before continuing. If the codex rc is non-zero, including timeout rc 124, report failure and include the last 80 lines from \`tail -n 80 ${out}\`; never treat it as success.`

const ask = (name, n, prior) => {
  const out = `${SCRATCH}/codex-r${n}.md`
  const context = `${brief(n)}${prior ? `\nPrevious independent answers and disagreements: ${JSON.stringify(prior)}\nRespond to the evidence; do not concede merely to agree.` : ''}`
  const prompt = name === 'claude' ? context : `Run codex; never answer for it. ${CODEX_DETACHED_RUN(out, `${out}.rc`)}\nBrief to copy verbatim:\n${context}\nRead the output and return answer/reasons/risks; error on failure or empty output. Never retype codex into a file.`
  return agent(`${GUARDRAILS}\n${prompt}`, { label: `${name}:r${n}`, phase: 'Answer', schema: ANSWER, agentType: 'general-purpose' })
}
const VERDICT = { type: 'object', properties: {
  status: { type: 'string', enum: ['agreed', 'derived', 'diverged'] }, conclusion: { type: 'string' },
  basis: { type: 'array', items: { type: 'string' } }, disagreements: { type: 'array', items: { type: 'string' } },
  question: { type: 'string' },
}, required: ['status', 'conclusion', 'basis', 'disagreements', 'question'] }
const validAnswer = x => x && !x.error && typeof x.answer === 'string' && x.answer.trim() && Array.isArray(x.reasons) && x.reasons.length && x.reasons.every(r => typeof r === 'string' && r.trim()) && Array.isArray(x.risks)
const validVerdict = x => x && ['agreed', 'derived', 'diverged'].includes(x.status) && typeof x.conclusion === 'string' && x.conclusion.trim() && Array.isArray(x.basis) && x.basis.length && x.basis.every(b => typeof b === 'string' && b.trim()) && Array.isArray(x.disagreements) && typeof x.question === 'string'
let prior = null
let result
for (let n = 1; n <= 3; n++) {
  const [claude, codex] = await parallel([() => ask('claude', n, prior), () => ask('codex', n, prior)])
  if (!validAnswer(claude) || !validAnswer(codex)) return { issue: A.issue, status: 'answer-failed', rounds: n }
  const verdict = await agent(`${GUARDRAILS}\nCompare independently obtained answers. Never invent evidence or select a side on disagreement.\nClaude: ${JSON.stringify(claude)}\nCodex: ${JSON.stringify(codex)}\nUse agreed only for matching conclusions; derived only when cited invariants, decided issues or precedents entail the conclusion. Otherwise diverged. basis must cite each judgment (issue URL or file:line). Return exactly one maintainer question for divergence. ${SCRATCH_ONLY}`, { label: `compare:r${n}`, phase: 'Compare', schema: VERDICT })
  if (!validVerdict(verdict)) return { issue: A.issue, status: 'compare-failed', rounds: n }
  result = { issue: A.issue, ...verdict, claude, codex, rounds: n }
  if (verdict.status !== 'diverged') break
  prior = { claude, codex, disagreements: verdict.disagreements }
}
return result
