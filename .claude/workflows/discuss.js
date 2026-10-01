export const meta = {
  name: 'discuss',
  description: 'Independent Claude and codex answers before asking the maintainer',
  whenToUse: 'Pass {repo, repoDir, issue, question, context?, premises?, references?}.',
  phases: [
    { title: 'Answer', detail: 'Independent answers' },
    { title: 'Compare', detail: 'Compare evidence and conclusions' },
    { title: 'Record', detail: 'Shell copies codex into the issue comment' },
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
  notes: { type: 'array', items: { type: 'string' } },
  risks: { type: 'array', items: { type: 'string' } }, error: { type: 'string' },
}, required: ['answer', 'reasons', 'notes', 'risks'] }
const PFX = [[REPO_DIR, '.'], [SCRATCH, '<scratch>']].sort((a, b) => b[0].length - a[0].length)
const SCRUB_LIT = String.raw`function lit(s, a, r,  o, k, p, c) { o = ""; while (a != "" && (k = index(s, a)) > 0) { o = o substr(s, 1, k - 1); p = substr(o, length(o), 1); c = substr(s, k + length(a), 1); o = o (((p !~ "[A-Za-z0-9._/-]" || (length(o) > 2 && substr(o, length(o) - 2) == "://")) && c !~ "[A-Za-z0-9._-]") ? r : a); s = substr(s, k + length(a)) } return o s }`
const SCRUB_MASK = String.raw`function keep(o, t, s,  p) { p = substr(o, length(o), 1); return p ~ "[A-Za-z0-9._~/-]" || t == "/" || (p == "<" && t ~ "^/[A-Za-z][A-Za-z0-9]*$" && substr(s, 1, 1) == ">") } function url(o, t) { return substr(o, length(o), 1) == ":" && match(o, "[A-Za-z][A-Za-z0-9+.-]*:$") && substr(t, 1, 2) == "//" } function mask(s,  o, t, q) { o = ""; while (match(s, "/" PC "*")) { o = o substr(s, 1, RSTART - 1); t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); q = ""; if (keep(o, t, s)) { o = o t; continue } if (url(o, t)) { if (substr(t, 1, 3) != "///") { o = o t; continue } q = "//"; t = substr(t, 3) } o = o q "<path>" } return o s }`
const SCRUB_MAIN = String.raw`BEGIN { n = ENVIRON["RV_N"] + 0; h = ENVIRON["HOME"]; PC = "[^][:space:]\"()<>{},;|" sprintf("%c%c", 39, 96) "]" } { t = tolower($0); sub("^[[:space:]]+", "", t); sub("[[:space:]]+$", "", t); if (t ~ /^claude-session:/ || t ~ /generated with \[?claude code([^[:alnum:]]|$)/ || t ~ /^co-authored-by:/ || t ~ /^generated with/) next; for (i = 0; i < n; i++) $0 = lit($0, ENVIRON["RV_P" i], ENVIRON["RV_R" i]); if (length(h) > 1) $0 = lit($0, h, "~"); gsub("/tmp/claude[-][0-9]+[^[:space:]]*", "<tmp>"); gsub("/(home|Users)/[^/[:space:]]+", "~"); gsub("\\\\\\\\[A-Za-z0-9._$?-]" PC "*", "<path>"); gsub("[A-Za-z]:\\\\" PC "*", "<path>"); print mask($0) }`
const SCRUB = `${PFX.map(([p, r], i) => `RV_P${i}=${sq(p)} RV_R${i}=${sq(r)} `).join('')}RV_N=${PFX.length} awk '${SCRUB_LIT} ${SCRUB_MASK} ${SCRUB_MAIN}'`

const brief = n => `Question: ${A.question}\nContext: ${A.context || ''}\nApproved premises: ${A.premises || ''}\nRelated issues / ADRs: ${A.references || ''}\nRound ${n}. Independently answer. Put judgments in reasons with evidence; put explanations and execution records in notes (no citations required; not judgments and excluded from comparison). Cite every judgment with issue URLs, local issue/PR shorthand #N or repo-relative file:line evidence. Read CONTEXT.md and doc/contract.md. Do not invent evidence. ${SCRATCH_ONLY}`
const CODEX_DETACHED_RUN = (out, rc) => `Create ${SCRATCH}, write the brief below verbatim to <暫存檔>, and remove any stale ${rc} and ${out}. Start codex detached with setsid nohup and this command; keep the codex exec command shape unchanged:
setsid nohup bash -c 'timeout ${CODEX_TIMEOUT_SECONDS} codex exec --skip-git-repo-check -C ${WT} -o ${out} "$(cat <暫存檔>)" < /dev/null; rc=$?; printf "%s\\n" "$rc" > ${rc}' > ${out}.log 2>&1 &
Do not use run_in_background or Monitor. Wait in repeated bounded foreground calls, each below ten minutes:
timeout ${CODEX_WAIT_SECONDS} bash -c 'until [ -s ${rc} ]; do sleep 30; done'
An exit 124 from a wait call only means to run that same wait call again. Once ${rc} exists, inspect its value. Then list test containers mounting the worktree with \`docker ps --filter volume=${WT} --format '{{.ID}}'\` and stop every returned container with \`docker stop\` before continuing. If the codex rc is non-zero, including timeout rc 124, report failure and include the last 80 lines from \`tail -n 80 ${out}\`; never treat it as success.`

const ask = (name, n, prior) => {
  const out = `${SCRATCH}/codex-r${n}.md`
  const context = `${brief(n)}${prior ? `\nPrevious independent answers and disagreements: ${JSON.stringify(prior)}\nRespond to the evidence; do not concede merely to agree.` : ''}`
  const prompt = name === 'claude' ? context : `Run codex; never answer for it. ${CODEX_DETACHED_RUN(out, `${out}.rc`)}\nBrief to copy verbatim:\n${context}\nRead the output and return answer/reasons/notes/risks; put judgments in reasons with evidence and other content in notes; error on failure or empty output. Never retype codex into a file.`
  return agent(`${GUARDRAILS}\n${prompt}`, { label: `${name}:r${n}`, phase: 'Answer', schema: ANSWER, agentType: 'general-purpose' })
}
const VERDICT = { type: 'object', properties: {
  status: { type: 'string', enum: ['agreed', 'derived', 'diverged'] }, conclusion: { type: 'string' },
  basis: { type: 'array', items: { type: 'string' } }, disagreements: { type: 'array', items: { type: 'string' } },
  question: { type: 'string' },
}, required: ['status', 'conclusion', 'basis', 'disagreements', 'question'] }
const cited = b => typeof b === 'string' && /https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/issues\/[1-9][0-9]*|#[1-9][0-9]*\b|[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*:[1-9][0-9]*/.test(b)
const validAnswer = x => x && !x.error && typeof x.answer === 'string' && x.answer.trim() && Array.isArray(x.reasons) && x.reasons.length && x.reasons.every(cited) && Array.isArray(x.notes) && Array.isArray(x.risks)
const failedReasons = (agent, x) => Array.isArray(x?.reasons)
  ? x.reasons.flatMap((reason, i) => cited(reason) ? [] : [{ agent, reason_index: i + 1, reason }]) : []
const validVerdict = x => x && ['agreed', 'derived', 'diverged'].includes(x.status) && typeof x.conclusion === 'string' && x.conclusion.trim() && Array.isArray(x.basis) && x.basis.length && x.basis.every(cited) && Array.isArray(x.disagreements) && typeof x.question === 'string'
const nonce = await agent('Read a run nonce with `od -An -N8 -tx1 /dev/urandom | tr -d " \n"`; return nonce only.', { label: 'nonce:', phase: 'Answer', schema: { type: 'object', properties: { nonce: { type: 'string' } }, required: ['nonce'] } })
if (!nonce || !/^[0-9a-f]{16}$/.test(nonce.nonce)) return { issue: A.issue, status: 'setup-failed', rounds: 0 }
let prior = null
let result
for (let n = 1; n <= 3; n++) {
  const [claude, codex] = await parallel([() => ask('claude', n, prior), () => ask('codex', n, prior)])
  if (!validAnswer(claude) || !validAnswer(codex)) return {
    issue: A.issue, status: 'answer-failed', rounds: n,
    failed_reasons: [...failedReasons('claude', claude), ...failedReasons('codex', codex)],
  }
  const verdict = await agent(`${GUARDRAILS}\nCompare independently obtained answers. Never invent evidence or select a side on disagreement.\nClaude: ${JSON.stringify(claude)}\nCodex: ${JSON.stringify(codex)}\nUse agreed only for matching conclusions; derived only when cited invariants, decided issues or precedents entail the conclusion. Otherwise diverged. basis must cite each judgment (issue URL, local issue/PR shorthand #N or file:line). Return exactly one maintainer question for divergence. ${SCRATCH_ONLY}`, { label: `compare:r${n}`, phase: 'Compare', schema: VERDICT })
  if (!validVerdict(verdict)) return { issue: A.issue, status: 'compare-failed', rounds: n }
  result = { issue: A.issue, ...verdict, claude, codex, rounds: n }
  if (verdict.status !== 'diverged') break
  prior = { claude, codex, disagreements: verdict.disagreements }
}
if (result.status === 'diverged' && (!result.question.trim() || /[\r\n]/.test(result.question) || (result.question.match(/[?？]/g) || []).length > 1)) return { issue: A.issue, status: 'compare-failed', rounds: result.rounds }
result.ask_maintainer = result.status === 'diverged' ? [result.question] : []
const labels = { agreed: '一致（定案）', derived: '可由不變量／前例推出（自行定案）', diverged: '分歧（交維護者，一次一題）' }
const text = `[claude] ${labels[result.status]}\n\n${result.conclusion}\n\n## 依據\n${result.basis.map(b => `- ${b}`).join('\n')}\n\n## Claude 判斷與依據\n${result.claude.answer}\n${result.claude.reasons.map(b => `- ${b}`).join('\n')}\n\n${result.ask_maintainer.length ? `## 維護者問題\n${result.ask_maintainer[0]}\n` : ''}\n## 分歧\n${result.disagreements.map(b => `- ${b}`).join('\n')}\n`
let i = 0
let marker
 do { marker = `${nonce.nonce}-${++i}` } while (text.includes(`===END-${marker}===`) || text.includes(`===BEGIN-${marker}===`))
const out = `codex-r${result.rounds}.md`
const build = `cd ${sq(SCRATCH)} && rm -f body.md && [ -s ${sq(out)} ] && ${SCRUB} < conclusion-raw.md > conclusion.md && ${SCRUB} < ${sq(out)} > codex-clean.md && [ -s conclusion.md ] && [ -s codex-clean.md ] && { cat conclusion.md; printf '\n## codex 原文（shell 複製）\n\n'; sed 's/^/> /' codex-clean.md; } > body.md`
const publish = `gh issue comment ${A.issue} --repo ${sq(REPO)} --body-file ${sq(`${SCRATCH}/body.md`)}`
const recorded = await agent(`${GUARDRAILS}\n${SCRATCH_ONLY}\nRecord only: comments start with [claude]. Never retype codex text: shell copies the final output, not the structured summary.\nWrite the text between the markers byte for byte to the path ${JSON.stringify(`${SCRATCH}/conclusion-raw.md`)} with the Write tool.\n===BEGIN-${marker}===\n${text}\n===END-${marker}===\nRun the build in the foreground: \`${build}\`. Wait for successful completion; on failure stop without publishing. Only after the build succeeds, run this separate foreground command in a new tool call: \`${publish}\`. Never combine the two commands. Return the printed URL.`, { label: 'record:', phase: 'Record', schema: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] } })
const prefix = `https://github.com/${REPO}/issues/${A.issue}#issuecomment-`
if (!recorded || typeof recorded.url !== 'string' || !recorded.url.toLowerCase().startsWith(prefix.toLowerCase()) || !/^[0-9]+$/.test(recorded.url.slice(prefix.length))) return { ...result, status: 'record-failed', comment: '' }
return { ...result, comment: recorded.url }
