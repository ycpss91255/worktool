export const meta = {
  name: 'research-verify',
  description: 'Research one question with agy (gemini), verify every claim with a claude agent and codex in parallel, synthesize, and record ONE zh-TW comment on the issue; never substitutes another model when agy fails',
  whenToUse: 'Any fact-finding the maintainer wants researched (agy finds, claude and codex verify). Pass args {repo, repoDir, issue, question, context?, sources?, timeoutMin?}.',
  phases: [
    { title: 'Research', detail: 'agent: agy headless with a hard timeout, retry once; failure is returned, never substituted (structured)' },
    { title: 'Verify', detail: 'parallel: claude agent claim by claim (structured) + codex exec with the agy text on stdin (verbatim file)' },
    { title: 'Synthesize', detail: 'agent: verified facts / refuted claims / needs-experiment / recommendation / parameters (structured)' },
    { title: 'Record', detail: 'agent: ONE issue comment via --body-file: [claude] conclusion, verbatim [codex], agy original folded' },
  ],
}

// research-verify: agy researches, claude and codex verify, the issue keeps the record.
//
// Invoke (from any cwd) with:
//   Workflow({ scriptPath: "<repoDir>/.claude/workflows/research-verify.js", args: {
//     repo: "ycpss91255/worktool",     // required: owner/name for every gh call
//     repoDir: "/path/to/worktool",     // required: local checkout; scratch files go under .worktree/.scratch/
//     issue: 179,                      // required: the issue that receives the ONE result comment
//     question: "...",                 // required: the research question
//     context: "...",                  // optional: background agy and the verifiers should know
//     sources: ["/path/to/src"],       // optional: local primary material (e.g. pinned source) for the verifiers
//     timeoutMin: 15,                  // optional: agy --print-timeout in minutes (positive integer)
//   } })
//
// Result: { issue, status, codex, claims, comment, synthesis }.
// status: 'recorded' | 'agy-failed' | 'record-failed'. When agy fails twice the
// workflow stops before Verify: no other model's answer is dressed up as agy's.

const A = args || {}
for (const k of ['repo', 'repoDir', 'issue', 'question']) {
  if (!A[k]) throw new Error(`research-verify: args.${k} is required`)
}
if (!Number.isInteger(A.issue) || A.issue <= 0) throw new Error(`research-verify: args.issue must be a positive integer, got ${JSON.stringify(A.issue)}`)
const TMIN = A.timeoutMin === undefined ? 15 : A.timeoutMin
if (!Number.isInteger(TMIN) || TMIN <= 0) throw new Error(`research-verify: args.timeoutMin must be a positive integer, got ${JSON.stringify(A.timeoutMin)}`)
if (A.sources !== undefined && (!Array.isArray(A.sources) || A.sources.some(s => typeof s !== 'string' || !s))) throw new Error('research-verify: args.sources must be an array of non-empty path strings')
const REPO = A.repo
const REPO_DIR = A.repoDir
const SOURCES = A.sources || []
const CONTEXT = A.context || ''
const SCRATCH = `${REPO_DIR}/.worktree/.scratch/research-${A.issue}`   // .worktree/ is gitignored

const AGY_SCHEMA = { type: 'object', properties: { status: { type: 'string', enum: ['ok', 'failed'] }, attempts: { type: 'integer' }, detail: { type: 'string' } }, required: ['status', 'attempts', 'detail'] }
const CLAIMS_SCHEMA = { type: 'object', properties: { claims: { type: 'array', items: { type: 'object', properties: { claim: { type: 'string' }, verdict: { type: 'string', enum: ['supported', 'refuted', 'unverifiable'] }, basis: { type: 'string' } }, required: ['claim', 'verdict', 'basis'] } } }, required: ['claims'] }
const CODEX_SCHEMA = { type: 'object', properties: { status: { type: 'string', enum: ['ok', 'no-output'] }, detail: { type: 'string' } }, required: ['status', 'detail'] }
const LIST = { type: 'array', items: { type: 'string' } }
const SYNTH_SCHEMA = { type: 'object', properties: {
  verified: { ...LIST }, refuted: { ...LIST }, needsExperiment: { ...LIST },
  recommendation: { type: 'string' }, parameters: { ...LIST },
}, required: ['verified', 'refuted', 'needsExperiment', 'recommendation', 'parameters'] }
const RECORD_SCHEMA = { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] }

const SRC_NOTE = SOURCES.length ? `本機一手資料(可直接讀取,優先於記憶):\n${SOURCES.map(s => `- ${s}`).join('\n')}` : '沒有提供本機一手資料。'

const AGY_PROMPT = `請研究以下問題並以繁體中文回答。
問題:${A.question}
${CONTEXT ? `背景:${CONTEXT}\n` : ''}來源規則:只採一手來源(官方文件、原始碼、規格、release notes、維護者的 issue/PR);每一個主張獨立一行編號,行尾以方括號標出來源類型與 URL(例如 [官方文件 https://...]、[原始碼 <repo>@<tag>:<path>]);找不到一手來源的主張標 UNVERIFIED,不要猜。最後列出你沒能查到的點。`

const RESEARCH = `Run the agy research step for issue #${A.issue} (${REPO}). Never answer the question yourself and never substitute another model or your own knowledge: your only job is to run agy and report whether it produced output.
1. mkdir -p ${SCRATCH} && cd ${SCRATCH} && rm -f agy.md agy.err codex.md codex-raw.txt body.md claude.md
2. Write the text between the markers below, byte for byte, to ${SCRATCH}/agy-prompt.txt with the Write tool (do not edit it).
===BEGIN===
${AGY_PROMPT}
===END===
3. Run in the foreground (blocking): \`cd ${SCRATCH} && timeout ${TMIN * 60 + 60} agy --sandbox --dangerously-skip-permissions -p "$(cat agy-prompt.txt)" --print-timeout ${TMIN}m > agy.md 2> agy.err; echo "exit=$?"\`.
4. Success = exit 0 and agy.md is non-empty (\`[ -s agy.md ]\`). On an empty file, exit 124 (timeout) or any other failure: retry ONCE (same command, overwrite agy.md). Still failing -> return status "failed" with attempts = 2 and detail = the exit codes plus the last 20 lines of agy.err. Do not write anything into agy.md yourself.
5. Return status "ok", attempts (1 or 2), detail = "agy.md <N> bytes".`

const CLAIM_CHECK = `Verify, claim by claim, the research answer agy wrote to ${SCRATCH}/agy.md (read that file; do not edit it). Question: ${A.question}
${CONTEXT ? `Context: ${CONTEXT}\n` : ''}${SRC_NOTE}
For EVERY numbered claim (UNVERIFIED ones included) check it yourself against primary material: the local sources above first, then official docs / source code / release notes on the web. Verdict: "supported" (you found primary evidence), "refuted" (primary evidence says otherwise), "unverifiable" (no primary evidence either way). basis = the concrete evidence (file:line, URL + quote, command output), in zh-TW, short. Do not add new claims. Never write a "[codex]" line yourself.`

const CODEX_PROMPT = `你是 codex。stdin 是 agy(gemini)針對下列問題的研究回答。請逐條驗證 agy 的每一個主張:成立 / 不成立 / 無法確認,每條附依據(檔案:行號、URL、指令輸出)。不要新增主張;最後以「## 結論」列出你認為可信的部分與需要實測的點。以繁體中文回答。
問題:${A.question}
${CONTEXT ? `背景:${CONTEXT}\n` : ''}${SRC_NOTE}`

const CODEX_STEP = `Run ONE codex verification of agy's research (issue #${A.issue}, ${REPO}). Never write a "[codex]" line yourself and never edit codex's words; you only run codex and report whether it produced output.
1. cd ${SCRATCH}. Write the text between the markers, byte for byte, to ${SCRATCH}/codex-prompt.txt with the Write tool.
===BEGIN===
${CODEX_PROMPT}
===END===
2. Run in the foreground: \`cd ${SCRATCH} && cat agy.md | timeout 600 codex exec --skip-git-repo-check "$(cat codex-prompt.txt)" > codex-raw.txt 2>&1\`; then extract the answer = lines after the line that is exactly "codex", minus trailing "tokens used" lines: \`awk '/^codex$/{f=1;next} f' codex-raw.txt | sed '/^tokens used/,$d' > codex.md\`.
3. codex.md empty, or an auth/quota error -> retry once after 60 s. Still empty -> \`rm -f codex.md\` and return status "no-output" with detail = the last 20 lines of codex-raw.txt. Otherwise return status "ok", detail = "codex.md <N> bytes".`

const SYNTH = (claims, codexOk) => `Synthesize the research on issue #${A.issue}. Question: ${A.question}
Inputs: agy's answer in ${SCRATCH}/agy.md; ${codexOk ? `codex's claim-by-claim verification in ${SCRATCH}/codex.md;` : 'codex produced NO output this run (treat every claim as having only one verifier);'} the claude verifier's verdicts (JSON):
${JSON.stringify(claims)}
Rules: a claim is "verified" only when no verifier refutes it and at least one cites primary evidence; a claim any verifier refutes goes to "refuted" (say who refuted it and why); disagreement or "unverifiable" from both -> "needsExperiment" (say what to run). Each item is one zh-TW line with its evidence. recommendation = the approach you recommend in zh-TW; parameters = the values the maintainer must decide (one per line, with the options). Do not invent evidence; do not write a "[codex]" line.`

const bullets = (xs) => (xs && xs.length ? xs.map(x => `- ${x}`).join('\n') : '- (無)')
const VERDICT_ZH = { supported: '成立', refuted: '不成立', unverifiable: '無法確認' }

const renderClaude = (s, claims, attempts) => `[claude] 研究結論(research-verify:agy 查資料,claude 與 codex 驗證)

**問題**:${A.question}

### 驗證後成立的事實
${bullets(s.verified)}

### 被推翻的主張
${bullets(s.refuted)}

### 仍需實測
${bullets(s.needsExperiment)}

### 建議方案
${s.recommendation}

### 需要維護者拍板的參數
${bullets(s.parameters)}

### claude 逐條驗證
${bullets(claims.map(c => `${VERDICT_ZH[c.verdict] || c.verdict}:${c.claim} —— ${c.basis}`))}

agy 執行 ${attempts} 次(每次上限 ${TMIN} 分鐘;prompt 與原始輸出在 \`.worktree/.scratch/research-${A.issue}/\`)。`

const RECORD = (codexOk) => `Post the research result for issue #${A.issue} as ONE comment. Never write a "[codex]" line yourself: the codex part below is copied from codex.md by the shell, not retyped.
1. Write the text between the markers, byte for byte, to ${SCRATCH}/claude.md with the Write tool.
2. Build the body in the foreground: \`cd ${SCRATCH} && { cat claude.md; printf '\\n\\n'; ${codexOk ? "printf '[codex] 逐條驗證(原文)\\n\\n'; cat codex.md;" : "printf '[claude] codex 無輸出(配額/認證),本輪沒有 codex 驗證。\\n';"} printf '\\n\\n<details><summary>agy 原文</summary>\\n\\n'; cat agy.md; printf '\\n\\n</details>\\n'; } > body.md\`.
3. \`gh issue comment ${A.issue} --repo ${REPO} --body-file ${SCRATCH}/body.md\`; return url = the comment URL it prints (empty string if it failed).
===BEGIN===
`

phase('Research')
const res = await agent(RESEARCH, { label: `agy:#${A.issue}`, phase: 'Research', schema: AGY_SCHEMA, agentType: 'general-purpose' })
if (!res || res.status !== 'ok') return { issue: A.issue, status: 'agy-failed', codex: 'skipped', claims: 0, comment: '', synthesis: null, detail: (res && res.detail) || 'agy agent returned nothing' }
log(`#${A.issue}: agy ok after ${res.attempts} attempt(s): ${res.detail}`)

phase('Verify')
const [claude, codex] = await parallel([
  () => agent(CLAIM_CHECK, { label: `claude-verify:#${A.issue}`, phase: 'Verify', schema: CLAIMS_SCHEMA, agentType: 'general-purpose' }),
  () => agent(CODEX_STEP, { label: `codex-verify:#${A.issue}`, phase: 'Verify', schema: CODEX_SCHEMA, agentType: 'general-purpose' }),
])
const claims = (claude && claude.claims) || []
const codexOk = !!codex && codex.status === 'ok'
log(`#${A.issue}: claude checked ${claims.length} claim(s); codex ${codexOk ? 'ok' : 'no output'}`)

phase('Synthesize')
const synth = await agent(SYNTH(claims, codexOk), { label: `synthesize:#${A.issue}`, phase: 'Synthesize', schema: SYNTH_SCHEMA, agentType: 'general-purpose' })
const s = synth || { verified: [], refuted: [], needsExperiment: ['synthesize 失敗,請直接看下方 codex 與 agy 原文'], recommendation: '(無)', parameters: [] }

phase('Record')
const rec = await agent(`${RECORD(codexOk)}${renderClaude(s, claims, res.attempts)}\n===END===`, { label: `record:#${A.issue}`, phase: 'Record', schema: RECORD_SCHEMA, agentType: 'general-purpose' })
const url = (rec && rec.url) || ''
return { issue: A.issue, status: url ? 'recorded' : 'record-failed', codex: codexOk ? 'ok' : 'no-output', claims: claims.length, comment: url, synthesis: s }
