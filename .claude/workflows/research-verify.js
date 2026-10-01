export const meta = {
  name: 'research-verify',
  description: 'Research one question with agy (gemini), verify every cited source with codex, sample sources with a claude agent, synthesize, and record bounded zh-TW comments on the issue; never substitutes another model when agy fails',
  whenToUse: 'Any fact-finding the maintainer wants researched (agy finds, claude and codex verify). Pass args {repo, repoDir, issue, question, context?, sources?, timeoutMin?}.',
  phases: [
    { title: 'Research', detail: 'agent: draw the run nonce from /dev/urandom; agent: agy headless with a hard timeout, retry once; failure is returned, never substituted (structured)' },
    { title: 'Verify', detail: 'codex exec checks every cited source (verbatim file), then claude samples sources (structured)' },
    { title: 'Synthesize', detail: 'claude agent: verified facts / refuted claims / unresolved disagreements with both bases, no side chosen / needs-experiment / recommendation / parameters (structured)' },
    { title: 'Record', detail: 'agent: bounded issue comments via --body-file: conclusion first, then claim detail and verbatim model text; then repo-check: git status equals the pre-run capture' },
  ],
}

// research-verify: agy researches, claude and codex verify, the issue keeps the record.
//
// Invoke (from any cwd) with:
//   Workflow({ scriptPath: "<repoDir>/.claude/workflows/research-verify.js", args: {
//     repo: "ycpss91255/worktool",     // required: owner/name for every gh call
//     repoDir: "/path/to/worktool",     // required: local checkout; scratch files go under ../worktree/.scratch/
//     issue: 179,                      // required: the issue that receives the result comments
//     question: "...",                 // required: the research question
//     context: "...",                  // optional: background agy and the verifiers should know
//     sources: ["/path/to/src"],       // optional: local primary material (e.g. pinned source) for the verifiers
//     timeoutMin: 15,                  // optional: agy --print-timeout in minutes (positive integer)
//   } })
//
// Result: { issue, status, codex, claims, comment, synthesis }.
// status: 'recorded' | 'setup-failed' | 'sources-invalid' | 'agy-failed' |
// 'verify-failed' | 'synthesize-failed' | 'record-failed' | 'repo-dirty'. Every failure stops
// the run where it happens (fail closed): no valid run nonce stops before agy
// runs; a source that is not readable stops before agy runs;
// agy failing twice stops before Verify (no other model's answer is dressed up
// as agy's); a claude sample without claims or a codex without output stops
// before Synthesize (both verifiers are required); a missing or malformed
// synthesis stops before Record. Nothing is posted unless all of them held.
// Every shell step's exit status carries its success (agy exit 0 with a
// non-empty agy.md; a non-empty codex.md), so a failing tool fails the step.
// status 'recorded' needs the comment URL gh printed for this issue.
// No repo writes (#243): every prompt confines intermediate files to SCRATCH;
// Research captures `git status --porcelain --untracked-files=all` of repoDir
// before any write (into a shell variable, saved after the mkdir), and after
// Record a repo-check compares it again in both directions: a line that
// appeared or vanished, a git/grep error, or no answer is 'repo-dirty' with
// the lines in detail, even if the comment went out.
//
// Shell safety: repo must be owner/name; repoDir must be an absolute path
// without control characters or backticks. Every path or value that reaches a
// shell command is single-quoted with sq(), so spaces and metacharacters in
// repoDir are data, never syntax. A verbatim block is fenced by
// ===BEGIN-<run>-<n>=== / ===END-<run>-<n>===: <run> is a 16-hex nonce the
// first agent reads from /dev/urandom, so markers are unique per run (issue
// #225); n is distinct for every block of the run and chosen so neither
// marker occurs in the block or in repoDir: no content can close the block
// early. A Workflow may not call Math.random (it would break resume), but a
// resumed run replays the nonce agent's cached result, so it keeps its own
// markers while a new run with the same args draws new ones.

const A = args || {}
for (const k of ['repo', 'repoDir', 'issue', 'question']) {
  if (!A[k]) throw new Error(`research-verify: args.${k} is required`)
}
if (!Number.isInteger(A.issue) || A.issue <= 0) throw new Error(`research-verify: args.issue must be a positive integer, got ${JSON.stringify(A.issue)}`)
const TMIN = A.timeoutMin === undefined ? 15 : A.timeoutMin
if (!Number.isInteger(TMIN) || TMIN <= 0) throw new Error(`research-verify: args.timeoutMin must be a positive integer, got ${JSON.stringify(A.timeoutMin)}`)
if (typeof A.repo !== 'string' || !/^[A-Za-z0-9_.][A-Za-z0-9_.-]*\/[A-Za-z0-9_.][A-Za-z0-9_.-]*$/.test(A.repo)) throw new Error(`research-verify: args.repo must be owner/name, got ${JSON.stringify(A.repo)}`)
if (typeof A.repoDir !== 'string' || !A.repoDir.startsWith('/') || /[\u0000-\u001f\u007f`]/.test(A.repoDir)) throw new Error(`research-verify: args.repoDir must be an absolute path without control characters or backticks, got ${JSON.stringify(A.repoDir)}`)
// One fail-closed validator per free-form input; each error names its arg.
const bad = (k, why, v) => { throw new Error(`research-verify: args.${k} ${why}, got ${JSON.stringify(v)}`) }
const isText = (v) => typeof v === 'string' && v.trim() !== ''
const checkQuestion = (v) => (isText(v) ? v : bad('question', 'must be a non-blank string', v))
const checkContext = (v) => (v === undefined ? '' : isText(v) ? v : bad('context', 'must be a non-blank string when given', v))
// Paths are pure-checked here (no filesystem in a workflow); existence and
// readability are checked by the Research step's shell before agy runs.
const isAbsPath = (v) => typeof v === 'string' && v.startsWith('/') && !/[\u0000-\u001f\u007f`]/.test(v)
const checkSources = (v) => {
  if (v === undefined) return []
  if (!Array.isArray(v)) bad('sources', 'must be an array of absolute paths', v)
  v.forEach((p, i) => { if (!isAbsPath(p)) bad(`sources[${i}]`, 'must be an absolute path without control characters or backticks', p) })
  return v
}
const QUESTION = checkQuestion(A.question)
const REPO = A.repo
const REPO_DIR = A.repoDir
const WORKTREE_ROOT = `${REPO_DIR}/../worktree`
const SOURCES = checkSources(A.sources)
const CONTEXT = checkContext(A.context)
const SCRATCH = `${WORKTREE_ROOT}/.scratch/research-${A.issue}`
// POSIX single quoting: the only safe way a value reaches a shell command.
const sq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`
const CD = `cd ${sq(SCRATCH)}`
// A literal path, escaped for a sed -E s#...#...# pattern.
const ere = (s) => String(s).replace(/[\\^$.*+?()[\]{}|#]/g, '\\$&')
// The repo is public (#233): codex cites files through the local directory
// it ran in, so its answer passes this sed filter before it is posted. The
// scratch checkout (<scratch>/tree/, or any absolute prefix up to a /tree/
// checkout) and repoDir become repo-relative; the rest of the scratch dir
// becomes <scratch>/.
const RELPATHS = `sed -E ${sq([
  `s#${ere(SCRATCH)}/tree/##g`,
  's#(^|[^[:alnum:]_.~/-])/[^[:space:]]*/tree/#\\1#g',
  `s#${ere(SCRATCH)}/#<scratch>/#g`,
  `s#${ere(REPO_DIR)}/##g`,
].join(';'))}`
// Where an agent writes a verbatim block with the Write tool (JSON-quoted path).
const TO = (f) => `to the path ${JSON.stringify(`${SCRATCH}/${f}`)} with the Write tool`
// Appended to every phase prompt: the checkout is someone's working tree (#243).
const SCRATCH_ONLY = `\nFile rule: Intermediate files (notes, drafts, logs) go ONLY under ${JSON.stringify(`${SCRATCH}/`)} (or the system temp dir); never create, edit or delete any other path under ${JSON.stringify(REPO_DIR)}, tracked or untracked. Report findings in your answer, not in files.`
// Every tracked or untracked checkout change must show. Scratch is outside the
// checkout, so the run starts only when this complete status is clean.
const GIT_STATUS = `git -C ${sq(REPO_DIR)} status --porcelain --untracked-files=all -- .`
// Both directions (a line that appeared AND one that vanished), and grep's
// exit 2 (an unreadable capture) is a failure, never "no difference".
const GREP_DIFF = (a, b, f) => `{ grep -vxF -f ${a} ${b} > ${f}; [ $? -le 1 ]; }`
const REPO_DIFF = `${GIT_STATUS} > status-after.txt && ${GREP_DIFF('status-before.txt', 'status-after.txt', 'repo-added.txt')} && ${GREP_DIFF('status-after.txt', 'status-before.txt', 'repo-removed.txt')} && { sed 's/^/+ /' repo-added.txt; sed 's/^/- /' repo-removed.txt; } > repo-extra.txt || { echo 'repo-check failed: git status or grep error' > repo-extra.txt; false; }`
// Fence body verbatim with markers that occur neither in it nor in REPO_DIR.
// RUN (the run nonce) keeps markers apart across runs; n only grows during a
// run, so no two blocks of one run share a marker.
let RUN = ''
let lastFence = 0
const fence = (body) => {
  let n = lastFence + 1
  while ([body, REPO_DIR].some(t => t.includes(`===BEGIN-${RUN}-${n}===`) || t.includes(`===END-${RUN}-${n}===`))) n += 1
  lastFence = n
  return `===BEGIN-${RUN}-${n}===\n${body}\n===END-${RUN}-${n}===`
}
// Shell that prints codex's final answer, never its transcript (issue #223):
// the file codex writes itself with -o (--output-last-message); when it wrote
// none, the LAST "codex" block of the transcript, and only when a line that
// is exactly "tokens used" closes that block directly (codex prints it once
// the turn has completed; prose such as "tokens used by ..." is answer text,
// never the boundary). A run that stopped after commentary, inside a tool
// call or on an error has no such boundary, so it prints nothing and the
// Record fails closed on the empty codex.md. Commentary, tool logs and the
// answer echoed after "tokens used" all stay out.
const CODEX_ANSWER = (last, raw) => `if [ -s ${last} ]; then cat ${last}; else awk '/^codex$/{a="";b="";f=1;next} /^tokens used$/{if(f)a=b;f=0;next} /^(exec|thinking|user)$/{f=0} f{b=b $0 "\\n"} END{printf "%s", a}' ${raw}; fi`
// Shell filter that keeps local absolute paths out of the issue (issue #223):
// each source becomes its basename and repoDir becomes ".", longest first and
// only at path boundaries; then $HOME and any /home/<user> or /Users/<user>
// become "~" and a Claude session dir under /tmp becomes <tmp>. Last, deny
// by default: every other absolute path (/usr, /etc, /root, /workspace,
// /private/tmp, /var/folders, /mnt/c/Users, the path of a file:/// URI, one
// after a bare "word:" such as location:/root or host:/srv, C:\Users\...,
// a \\server\share UNC path) becomes <path>. Only "scheme://host" URLs, a
// lone "/" and HTML closing tags (</details>) stay. No quote or backtick in
// the program: it sits in one '...' span.
const PFX = [...SOURCES.map(s => s.replace(/\/+$/, '')).map(s => [s, s.split('/').pop()]), [REPO_DIR.replace(/\/+$/, ''), '.']]
  .filter(([p, r]) => p && r).sort((a, b) => b[0].length - a[0].length)
const SCRUB_LIT = String.raw`function lit(s, a, r,  o, k, p, c) { o = ""; while (a != "" && (k = index(s, a)) > 0) { o = o substr(s, 1, k - 1); p = substr(o, length(o), 1); c = substr(s, k + length(a), 1); o = o (((p !~ "[A-Za-z0-9._/-]" || (length(o) > 2 && substr(o, length(o) - 2) == "://")) && c !~ "[A-Za-z0-9._-]") ? r : a); s = substr(s, k + length(a)) } return o s }`
const SCRUB_MASK = String.raw`function keep(o, t, s,  p) { p = substr(o, length(o), 1); return p ~ "[A-Za-z0-9._~/-]" || t == "/" || (p == "<" && t ~ "^/[A-Za-z][A-Za-z0-9]*$" && substr(s, 1, 1) == ">") } function url(o, t) { return substr(o, length(o), 1) == ":" && match(o, "[A-Za-z][A-Za-z0-9+.-]*:$") && substr(t, 1, 2) == "//" } function mask(s,  o, t, q) { o = ""; while (match(s, "/" PC "*")) { o = o substr(s, 1, RSTART - 1); t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); q = ""; if (keep(o, t, s)) { o = o t; continue } if (url(o, t)) { if (substr(t, 1, 3) != "///") { o = o t; continue } q = "//"; t = substr(t, 3) } o = o q "<path>" } return o s }`
const SCRUB_MAIN = String.raw`BEGIN { n = ENVIRON["RV_N"] + 0; h = ENVIRON["HOME"]; PC = "[^][:space:]\"()<>{},;|" sprintf("%c%c", 39, 96) "]" } { t = tolower($0); sub("^[[:space:]]+", "", t); sub("[[:space:]]+$", "", t); if (t ~ /^claude-session:/ || t ~ /generated with \[?claude code([^[:alnum:]]|$)/ || t ~ /^co-authored-by:[[:space:]]*claude([^[:alnum:]]|$)/ || t ~ /^co-authored-by:.*@anthropic[.]com/) next; for (i = 0; i < n; i++) $0 = lit($0, ENVIRON["RV_P" i], ENVIRON["RV_R" i]); if (length(h) > 1) $0 = lit($0, h, "~"); gsub("/tmp/claude[-][0-9]+[^[:space:]]*", "<tmp>"); gsub("/(home|Users)/[^/[:space:]]+", "~"); gsub("\\\\\\\\[A-Za-z0-9._$?-]" PC "*", "<path>"); gsub("[A-Za-z]:\\\\" PC "*", "<path>"); print mask($0) }`
const SCRUB = `${PFX.map(([p, r], i) => `RV_P${i}=${sq(p)} RV_R${i}=${sq(r)} `).join('')}RV_N=${PFX.length} awk '${SCRUB_LIT} ${SCRUB_MASK} ${SCRUB_MAIN}'`

const NONCE_RE = /^[0-9a-f]{16}$/
const NONCE_SCHEMA = { type: 'object', properties: { nonce: { type: 'string', pattern: '^[0-9a-f]{16}$' } }, required: ['nonce'] }
const AGY_SCHEMA = { type: 'object', properties: { status: { type: 'string', enum: ['ok', 'failed', 'bad-source'] }, attempts: { type: 'integer' }, detail: { type: 'string' } }, required: ['status', 'attempts', 'detail'] }
const CLAIMS_SCHEMA = { type: 'object', properties: { claims: { type: 'array', minItems: 1, items: { type: 'object', properties: { claim: { type: 'string' }, verdict: { type: 'string', enum: ['supported', 'refuted', 'unverifiable'] }, basis: { type: 'string' } }, required: ['claim', 'verdict', 'basis'] } } }, required: ['claims'] }
const CODEX_SCHEMA = { type: 'object', properties: { status: { type: 'string', enum: ['ok', 'no-output'] }, detail: { type: 'string' } }, required: ['status', 'detail'] }
const LIST = { type: 'array', items: { type: 'string' } }
const DISAGREEMENT_SCHEMA = { type: 'object', properties: { claim: { type: 'string' }, codexBasis: { type: 'string' }, claudeBasis: { type: 'string' } }, required: ['claim', 'codexBasis', 'claudeBasis'], additionalProperties: false }
const SYNTH_SCHEMA = { type: 'object', properties: {
  verified: { ...LIST }, refuted: { ...LIST }, needsExperiment: { ...LIST },
  disagreements: { type: 'array', items: DISAGREEMENT_SCHEMA },
  recommendation: { type: 'string' }, parameters: { ...LIST },
}, required: ['verified', 'refuted', 'disagreements', 'needsExperiment', 'recommendation', 'parameters'] }
const RECORD_SCHEMA = { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] }
const REPO_CHECK_SCHEMA = { type: 'object', properties: { extra: { ...LIST } }, required: ['extra'] }

const SRC_NOTE = SOURCES.length ? `本機一手資料(可直接讀取,優先於記憶):\n${SOURCES.map(s => `- ${s}`).join('\n')}` : '沒有提供本機一手資料。'

// Every source must exist and be readable; the first one that is not fails the run.
const SRC_CHECK = SOURCES.length ? `cd / && for f in ${SOURCES.map(sq).join(' ')}; do [ -r "$f" ] || { echo "research-verify: args.sources: not readable: $f"; exit 3; }; done` : ''

const AGY_PROMPT = `請研究以下問題並以繁體中文回答。
問題:${QUESTION}
${CONTEXT ? `背景:${CONTEXT}\n` : ''}來源規則:只採一手來源(官方文件、原始碼、規格、release notes、維護者的 issue/PR);每一個主張獨立一行編號,行尾以方括號標出來源類型與 URL(例如 [官方文件 https://...]、[原始碼 <repo>@<tag>:<path>]);找不到一手來源的主張標 UNVERIFIED,不要猜。最後列出你沒能查到的點。
前例優先順序:先找 Ubuntu／Canonical 與 ROS 生態系，其他大型 repo 僅作補充。`

const NONCE = `Draw the run nonce for research-verify on issue #${A.issue}. Never make one up: run \`cd / && od -An -N8 -tx1 /dev/urandom | tr -d ' \\n'\` in the foreground and return nonce = its output exactly (16 lowercase hex digits).`

const RESEARCH = () => `Run the agy research step for issue #${A.issue} (${REPO}). Never answer the question yourself and never substitute another model or your own knowledge: your only job is to run agy and report whether it produced output.
${SRC_CHECK ? `0. Run \`${SRC_CHECK}\`. If it exits non-zero, stop here (do not run agy): return status "bad-source", attempts 0, detail = its output.\n` : ''}1. Run, as ONE command: \`cd ${sq(REPO_DIR)} && before=$(${GIT_STATUS}) && [ -z "$before" ] && mkdir -p ${sq(SCRATCH)} && ${CD} && rm -f agy.md agy.err agy-models.txt codex.md codex-last.md codex-raw.txt body.md body-raw.md body-tmp.md claude.md status-before.txt status-after.txt repo-added.txt repo-removed.txt repo-extra.txt && printf '%s' "$before" > status-before.txt\`. It requires a completely clean checkout BEFORE any write (mkdir, rm, a file) and only then saves the empty baseline.
2. Write the text between the markers below, byte for byte, ${TO('agy-prompt.txt')} (do not edit it).
${fence(AGY_PROMPT)}
3. Run in the foreground (blocking): \`${CD} && { model=$(${sq(`${REPO_DIR}/.agents/script/research/agy-model.sh`)} 2> agy.err) || exit 1; printf '%s\\n' "$model" >> agy-models.txt; timeout ${TMIN * 60 + 60} agy --sandbox --dangerously-skip-permissions -p "$(cat agy-prompt.txt)" --print-timeout ${TMIN}m --model "$model" > agy.md 2> agy.err; }; rc=$?; echo "exit=$rc"; [ "$rc" -eq 0 ] && [ -s agy.md ]\` (it exits non-zero unless agy succeeded).
4. If the resolver fails, stop immediately: return status "failed", attempts = the number of research calls made, detail = the last 20 lines of agy.err. Never run agy research or retry discovery on this failure. Every research attempt (including the retry) must run the literal resolver path in step 3 first. Success = exit 0 and agy.md is non-empty (\`[ -s agy.md ]\`). On an empty file, exit 124 (timeout) or any other failure: retry ONCE (same command, overwrite agy.md). Still failing -> return status "failed" with attempts = 2 and detail = the exit codes plus the last 20 lines of agy.err. Do not write anything into agy.md yourself.
5. Return status "ok", attempts (1 or 2), detail = "agy.md <N> bytes".${SCRATCH_ONLY}`

const CLAIM_CHECK = `Read codex's source-by-source verification in ${SCRATCH}/codex.md, then spot-check the research answer agy wrote to ${SCRATCH}/agy.md (read that file; do not edit it). Question: ${QUESTION}
${CONTEXT ? `Context: ${CONTEXT}\n` : ''}${SRC_NOTE}
Sample a subset of cited primary sources (at least one; a single-claim answer may require that one claim): prioritize disputed, UNVERIFIED and consequential claims. Open the sampled sources yourself, using local sources above first. Record which claims you sampled and why in basis; do not repeat codex's exhaustive check or conduct broad web research. Verdict: "supported" (you found primary evidence), "refuted" (primary evidence says otherwise), "unverifiable" (no primary evidence either way). basis = the concrete evidence (file:line, URL + quote, command output), in zh-TW, short. Do not add new claims. Never write a "[codex]" line yourself.${SCRATCH_ONLY}`

const CODEX_PROMPT = `你是 codex。stdin 是 agy(gemini)針對下列問題的研究回答。請逐條開啟每個主張所引用的一手來源(含 UNVERIFIED)，不要只憑記憶或搜尋摘要核對，也不要自行大量網路查找。每條記錄來源是否支持主張:成立 / 不成立 / 無法確認，附實際開啟的 URL 或檔案:行號、來源摘錄與核對依據；來源不可讀或無法判定時標「無法確認」，說明原因，不猜測。不要新增主張;最後以「## 結論」列出你認為可信的部分與需要實測的點。以繁體中文回答。
問題:${QUESTION}
${CONTEXT ? `背景:${CONTEXT}\n` : ''}${SRC_NOTE}`

const CODEX_STEP = () => `Run ONE codex verification of agy's research (issue #${A.issue}, ${REPO}). Never write a "[codex]" line yourself and never edit codex's words; you only run codex and report whether it produced output.
1. Write the text between the markers, byte for byte, ${TO('codex-prompt.txt')}.
${fence(CODEX_PROMPT)}
2. Run in the foreground: \`${CD} && rm -f codex-last.md && cat agy.md | timeout 600 codex exec --skip-git-repo-check -o codex-last.md "$(cat codex-prompt.txt)" > codex-raw.txt 2>&1\`; then extract codex's final answer only (never the transcript) and rewrite local working-directory paths repo-relative with exactly: \`${CD} && rm -f body.md && { ${CODEX_ANSWER('codex-last.md', 'codex-raw.txt')}; } | ${RELPATHS} > codex.md && [ -s codex.md ]\`.
3. codex.md empty, or an auth/quota error -> retry once after 60 s. Still empty -> return status "no-output" with detail = the last 20 lines of codex-raw.txt. Otherwise return status "ok", detail = "codex.md <N> bytes".${SCRATCH_ONLY}`

const SYNTH = (claims) => `Synthesize the research on issue #${A.issue}. Question: ${QUESTION}
Inputs: agy's answer in ${SCRATCH}/agy.md; codex's claim-by-claim verification in ${SCRATCH}/codex.md; the claude verifier's verdicts (JSON):
${JSON.stringify(claims)}
Rules: use agy's brief and cited sources, codex's exhaustive source checks and claude's source samples; do not conduct broad web research. A claim is "verified" only when primary evidence supports it and no unresolved contradiction remains; "refuted" requires decisive primary evidence against it. Any disagreement that the sources cannot resolve, or a claim the sources cannot determine (including both "unverifiable"), belongs ONLY in "disagreements": {claim, codexBasis, claudeBasis}, recording both sides' evidence or explicit lack of evidence. Never choose a side, count votes or favor a model; do not place these claims in verified or refuted, and do not assume either side in recommendation. needsExperiment = concrete checks that could resolve uncertainty, not a substitute for recording disagreements. Each list item is one zh-TW line with evidence. recommendation = an approach based only on established facts, preserving unresolved disagreements; parameters = values the maintainer must decide (one per line, with options). Do not invent evidence; do not write a "[codex]" or "[agy]" line; their words are copied from their files only.${SCRATCH_ONLY}`

const bullets = (xs) => (xs && xs.length ? xs.map(x => `- ${x}`).join('\n') : '- (無)')
const VERDICT_ZH = { supported: '成立', refuted: '不成立', unverifiable: '無法確認' }

const renderConclusion = (s, attempts) => `[claude] 研究結論(research-verify:agy 查資料,claude 與 codex 驗證)

**問題**:${QUESTION}

### 驗證後成立的事實
${bullets(s.verified)}

### 被推翻的主張
${bullets(s.refuted)}

### 分歧（不選邊）
${bullets(s.disagreements.map(d => `${d.claim}；codex 依據：${d.codexBasis}；claude 依據：${d.claudeBasis}`))}

### 仍需實測
${bullets(s.needsExperiment)}

### 建議方案
${s.recommendation}

### 需要維護者拍板的參數
${bullets(s.parameters)}

agy 執行 ${attempts} 次(每次上限 ${TMIN} 分鐘;prompt 與原始輸出在 \`../worktree/.scratch/research-${A.issue}/\`)。`

const renderClaims = (claims) => claims.map(c => `${VERDICT_ZH[c.verdict] || c.verdict}:${c.claim} —— ${c.basis}`).join('\n\n')
const COMMENT_LIMIT = 60000
const SPLIT_JS = String.raw`const fs=require("fs"),[out,run,limit,...files]=process.argv.slice(1),max=Number(limit);const read=f=>fs.readFileSync(f,"utf8").trim();const bytes=s=>Buffer.byteLength(s);const cut=(s,n)=>{const a=Array.from(s);let lo=0,hi=a.length;while(lo<hi){const mid=Math.ceil((lo+hi)/2);if(bytes(a.slice(0,mid).join(""))<=n)lo=mid;else hi=mid-1}return a.slice(0,lo).join("")};const quote=s=>s.split("\n").map(x=>"> "+x).join("\n");const sections=[{h:"[claude] claude 來源抽查",t:read(files[1])},{h:"[claude] codex 逐條驗證(原文)",t:quote(read(files[2]))},{h:"[claude] agy 原文",t:read(files[3])}];const rawConclusion=read(files[0]),conclusion=bytes(rawConclusion)>max-500?cut(rawConclusion,max-600)+"\n\n[內容過長，已截斷]":rawConclusion;const all=conclusion+"\n\n"+sections.map(x=>x.h+"\n\n"+x.t).join("\n\n");let parts=[];if(bytes(all)+200<=max)parts=[all];else{parts=[conclusion];for(const x of sections){let cur=x.h;for(const p of x.t.split(/\n\s*\n/)){const room=max-bytes(cur)-500;if(bytes(p)>room){if(cur!==x.h)parts.push(cur);parts.push(x.h+"\n\n"+cut(p,max-bytes(x.h)-600)+"\n\n[內容過長，已截斷]");cur=x.h}else if(bytes(cur+"\n\n"+p)>max-300){parts.push(cur);cur=x.h+"\n\n"+p}else cur+="\n\n"+p}if(cur!==x.h)parts.push(cur)}}const total=parts.length;parts.forEach((p,i)=>{const marker="<!-- research-verify:"+run+":comment:"+(i+1)+"/"+total+" -->",number=total>1?"\n\n第 "+(i+1)+"／"+total+" 則":"";fs.writeFileSync(out+"/body-"+(i+1)+".md",p+number+"\n"+marker+"\n")});fs.writeFileSync(out+"/body-count",String(total))`

const RECORD_SPLIT = (claudeText) => {
  const tick = String.fromCharCode(96)
  const build = `${CD} && rm -f body.md body-*.md body-count existing.json conclusion.md claims.md codex-clean.md agy-clean.md conclusion-raw.md claims-raw.md && [ -s claude.md ] && [ -s agy.md ] && [ -s codex.md ] && awk 'BEGIN{s=0} /^===CLAIMS-${RUN}===$/{s=1;next} {print > (s ? "claims-raw.md" : "conclusion-raw.md")}' claude.md && [ -s conclusion-raw.md ] && [ -s claims-raw.md ] && [ -s agy-models.txt ] && printf '\\nagy 實際使用模型:\\n' >> conclusion-raw.md && cat agy-models.txt >> conclusion-raw.md && ${SCRUB} < conclusion-raw.md > conclusion.md && ${SCRUB} < claims-raw.md > claims.md && ${SCRUB} < codex.md > codex-clean.md && ${SCRUB} < agy.md > agy-clean.md && [ -s conclusion.md ] && [ -s claims.md ] && [ -s codex-clean.md ] && [ -s agy-clean.md ] && [ "$(wc -l < conclusion-raw.md)" -eq "$(wc -l < conclusion.md)" ] && [ "$(wc -l < claims-raw.md)" -eq "$(wc -l < claims.md)" ] && [ "$(wc -l < codex.md)" -eq "$(wc -l < codex-clean.md)" ] && [ "$(wc -l < agy.md)" -eq "$(wc -l < agy-clean.md)" ] && node -e ${sq(SPLIT_JS)} ${sq(SCRATCH)} ${sq(RUN)} ${COMMENT_LIMIT} conclusion.md claims.md codex-clean.md agy-clean.md && [ -s body-count ]`
  const post = `${CD} && gh issue view ${A.issue} --repo ${sq(REPO)} --json comments > existing.json && count=$(cat body-count) && i=1 && url= && while [ "$i" -le "$count" ]; do body="body-$i.md"; marker=$(grep -m1 '<!-- research-verify:' "$body"); old=$(jq -r --arg marker "$marker" '.comments[] | select(.body | contains($marker)) | .url' existing.json | tail -n 1); if [ -n "$old" ]; then url=$old; else url=$(gh issue comment ${A.issue} --repo ${sq(REPO)} --body-file "$body") || exit $?; fi; i=$((i + 1)); done; printf '%s\\n' "$url"`
  return `Post the research result for issue #${A.issue} as bounded comments. Never write a "[codex]" line yourself: codex.md is copied by the shell, not retyped.
1. Write the text between the markers, byte for byte, ${TO('claude.md')}.
2. Build the bodies in the foreground: ${tick}${build}${tick}. The filters rewrite local absolute paths; a paragraph that cannot fit is truncated with a note.
3. Post in order and skip markers already present: ${tick}${post}${tick}; return url = the final comment URL (empty string if it failed).${SCRATCH_ONLY}
${fence(claudeText)}`
}

const REPO_CHECK = `Check that the research run on issue #${A.issue} left the checkout ${JSON.stringify(REPO_DIR)} as it found it. Change nothing; only run and report.
1. Run in the foreground: \`${CD} && ${REPO_DIFF}\`. repo-extra.txt gets "+ <line>" for each status line that appeared and "- <line>" for each that vanished (e.g. a deleted untracked file); if git or grep failed it holds a "repo-check failed" line instead.
2. Return extra = the lines of repo-extra.txt, verbatim, one array item per line (empty array only when the command succeeded and the file is empty). If the command failed, return extra = ["repo-check failed: <error>"]. Do not clean up or delete any path you find.${SCRATCH_ONLY}`

const agyOk = (r) => !!r && r.status === 'ok' && [1, 2].includes(r.attempts)
const claimOk = (c) => !!c && typeof c.claim === 'string' && ['supported', 'refuted', 'unverifiable'].includes(c.verdict) && typeof c.basis === 'string'
const isList = (x) => Array.isArray(x) && x.every(i => typeof i === 'string')
const disagreementOk = (d) => !!d && ['claim', 'codexBasis', 'claudeBasis'].every(k => isText(d[k])) && Object.keys(d).every(k => ['claim', 'codexBasis', 'claudeBasis'].includes(k))
const synthOk = (s) => !!s && ['verified', 'refuted', 'needsExperiment', 'parameters'].every(k => isList(s[k])) && Array.isArray(s.disagreements) && s.disagreements.every(disagreementOk) && typeof s.recommendation === 'string' && s.recommendation.trim() !== ''
// The Record step succeeded only if it returned a comment URL on THIS issue.
const COMMENT_URL = new RegExp(`^https://github\\.com/${REPO.replace(/\./g, '\\.')}/issues/${A.issue}#issuecomment-[0-9]+$`, 'i')
const checkCommentUrl = (v) => typeof v === 'string' && COMMENT_URL.test(v)
const stop = (status, codex, claims, detail, synthesis = null) => ({ issue: A.issue, status, codex, claims, comment: '', synthesis, detail })

phase('Research')
const nonce = await agent(NONCE, { label: `nonce:#${A.issue}`, phase: 'Research', schema: NONCE_SCHEMA, agentType: 'general-purpose' })
if (!nonce || typeof nonce.nonce !== 'string' || !NONCE_RE.test(nonce.nonce)) return { issue: A.issue, status: 'setup-failed', codex: 'skipped', claims: 0, comment: '', synthesis: null, detail: 'no valid run nonce' }
RUN = nonce.nonce
const res = await agent(RESEARCH(), { label: `agy:#${A.issue}`, phase: 'Research', schema: AGY_SCHEMA, agentType: 'general-purpose' })
if (res && res.status === 'bad-source') return stop('sources-invalid', 'skipped', 0, res.detail)
if (!agyOk(res)) return { issue: A.issue, status: 'agy-failed', codex: 'skipped', claims: 0, comment: '', synthesis: null, detail: (res && res.detail) || 'agy agent returned nothing' }
log(`#${A.issue}: agy ok after ${res.attempts} attempt(s): ${res.detail}`)

phase('Verify')
const codex = await agent(CODEX_STEP(), { label: `codex-verify:#${A.issue}`, phase: 'Verify', schema: CODEX_SCHEMA, agentType: 'general-purpose' })
if (!codex || codex.status !== 'ok') return stop('verify-failed', (codex && codex.status) || 'no-output', 0, (codex && codex.detail) || 'codex returned no output')
const claude = await agent(CLAIM_CHECK, { label: `claude-verify:#${A.issue}`, phase: 'Verify', schema: CLAIMS_SCHEMA, agentType: 'general-purpose' })
// Fail closed: codex must have output and claude must have sampled sources, or nothing is concluded.
const claims = (claude && Array.isArray(claude.claims) && claude.claims.every(claimOk)) ? claude.claims : []
const codexState = (codex && codex.status) || 'no-output'
log(`#${A.issue}: claude checked ${claims.length} claim(s); codex ${codexState}`)
if (!claims.length || codexState !== 'ok') return stop('verify-failed', codexState, claims.length, `claude claims: ${claims.length}; codex: ${codexState}${codex && codex.detail ? ` (${codex.detail})` : ''}`)

phase('Synthesize')
const s = await agent(SYNTH(claims), { label: `synthesize:#${A.issue}`, phase: 'Synthesize', schema: SYNTH_SCHEMA, agentType: 'general-purpose' })
if (!synthOk(s)) return stop('synthesize-failed', 'ok', claims.length, 'synthesis missing or malformed', s || null)

phase('Record')
const recordText = `${renderConclusion(s, res.attempts)}\n===CLAIMS-${RUN}===\n${renderClaims(claims)}`
const rec = await agent(RECORD_SPLIT(recordText), { label: `record:#${A.issue}`, phase: 'Record', schema: RECORD_SCHEMA, agentType: 'general-purpose' })
const url = rec ? rec.url : undefined
// Fail closed (#243): no answer counts as dirty; the extra lines are the detail.
const chk = await agent(REPO_CHECK, { label: `repo-check:#${A.issue}`, phase: 'Record', schema: REPO_CHECK_SCHEMA, agentType: 'general-purpose' })
const extra = (chk && isList(chk.extra)) ? chk.extra : ['repo-check returned no list']
const status = extra.length ? 'repo-dirty' : (checkCommentUrl(url) ? 'recorded' : 'record-failed')
return { issue: A.issue, status, codex: 'ok', claims: claims.length, comment: checkCommentUrl(url) ? url : '', synthesis: s, detail: extra.length ? `repoDir changed during the run: ${extra.join(' | ')}` : (checkCommentUrl(url) ? '' : `record URL is not a comment on ${REPO}#${A.issue}: ${JSON.stringify(url)}`) }

// args 範例（可直接貼進 Workflow 的 args）
// {
//   "repo": "ycpss91255/worktool",
//   "repoDir": "/path/to/worktool",
//   "issue": 220,
//   "question": "這個設計選項的一手資料與限制是什麼？",
//   "context": "只採用官方文件與鎖定版原始碼。",
//   "sources": ["/path/to/worktool/doc/design.md"],
//   "timeoutMin": 15
// }
