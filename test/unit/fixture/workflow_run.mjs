// test/unit/fixture/workflow_run.mjs - run ONE Workflow template under node
// with stand-in agent/parallel/phase/log, for test/unit/workflow_spec.bats.
//
// Usage:
//   node workflow_run.mjs <template.js> <args-json> <replies-json> [exec|exec-hooks]
//
// <replies-json> maps an agent label PREFIX to the value that agent returns
// (a missing prefix returns null, as a failed agent does). Without `exec`
// the agents only record their prompt. With `exec` each agent also plays
// the steps it is told to do, deterministically: it writes the
// ===BEGIN-<run>-<n>===/===END-<run>-<n>=== block to the path named by
// `to the path "<json string>" with the Write tool` (parents created, as
// the Write tool does), then runs every backtick span outside that block
// that starts with `cd `, `mkdir ` or `gh ` through `bash -c`, in order.
// A span holding a bare <placeholder> word (e.g. `gh run view <run-id> ...`)
// is a template the agent fills in, not a runnable step, so it is skipped;
// a quoted tag such as '<details>' is data and does not count.
// Fail closed: a Write target without a well-formed block, or the first
// step that exits non-zero, stops the agent and it returns null (a shell
// failure is a failed agent, never the canned reply).
// `exec-record` plays only Record agents against prepared model output files.
// `exec-stage-checks` plays only pr-loop stage-check agents; implementation
// and review remain canned so the checks can inspect real test repositories.
// `exec-job-results` executes generated start/wait calls against fake jobs,
// then reads the failed run and hands off to a canned repair on a failure marker.
// `exec-hooks` also runs both publication body hooks before each shell
// step, using the unchanged tool cwd rather than following shell `cd`.
// A top-level reply field equal to "<stdout>" becomes the trimmed stdout of
// the agent's last step (e.g. the URL `gh issue comment` printed).
// Prints ONE JSON object: { result, error, calls: [{label, role, phase, schema, prompt}],
// ran: [{cmd, rc}] }.

import { mkdirSync, readFileSync, writeFileSync, unlinkSync } from 'node:fs'
import { dirname } from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const [script, argsJson, repliesJson, mode] = process.argv.slice(2)
// Existing pr-loop scenarios model successful external gates/publication by
// default. Individual scenarios override either reply (including null).
const replies = {
  ...(process.env.WORKFLOW_JOB_REPLIES ? {
    'gates:': { state: 'green', detail: 'success' },
    'publish:Implement': { pr: 7, sha: 'abc' },
    'publish:Fix': { pr: 7, sha: 'def' },
    'adoption:': { posted: true },
  } : {}),
  ...JSON.parse(repliesJson),
}
const calls = []
const ran = []
const workflowCalls = []
const logs = []

// Check the body before each shell launch, as registered PreToolUse hooks do.
const checkHooks = (cmd) => {
  if (mode !== 'exec-hooks') return
  const input = JSON.stringify({ cwd: process.cwd(), tool_name: 'Bash', tool_input: { command: cmd } })
  for (const hook of ['enforce_no_local_paths', 'enforce_milestone_gate_approval']) {
    const path = fileURLToPath(new URL(`../../../.agents/hook/${hook}.sh`, import.meta.url))
    execFileSync('bash', [path], { input, stdio: ['pipe', 'pipe', 'pipe'] })
  }
}

const reply = (label) => {
  const k = Object.keys(replies).find(p => label.startsWith(p))
  if (k !== undefined && Array.isArray(replies[k])) return replies[k].shift() || null
  return k === undefined ? (label.startsWith('prepare:') ? { state: 'new' } : null) : replies[k]
}

// Play the prompt's steps; returns { ok, stdout } of the last step run.
const play = (prompt) => {
  const block = prompt.match(/===BEGIN-([0-9a-f]+-\d+)===\n([\s\S]*?)\n===END-\1===/)
  const outside = block ? prompt.replace(block[0], '') : prompt
  const target = outside.match(/to the path ("(?:[^"\\]|\\.)*") with the Write tool/)
  if (target && !block) return { ok: false, stdout: '' }
  if (block && target) {
    const path = JSON.parse(target[1])
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, block[2])
  }
  let stdout = ''
  for (const [, cmd] of outside.matchAll(/`((?:cd|mkdir|gh) [^`]*)`/g)) {
    if (/(^|\s)<[A-Za-z][A-Za-z0-9_-]*>(\s|$)/.test(cmd)) continue
    try {
      checkHooks(cmd)
      stdout = execFileSync('bash', ['-c', cmd], { stdio: ['ignore', 'pipe', 'ignore'] }).toString()
      ran.push({ cmd, rc: 0 })
    } catch (e) {
      ran.push({ cmd, rc: e.status })
      return { ok: false, stdout: '' }
    }
  }
  return { ok: true, stdout: stdout.trim() }
}

const withStdout = (value, stdout) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return value
  return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, v === '<stdout>' ? stdout : v]))
}

// Execute generated job calls against deterministic just/gh adapters. A
// successful failure handoff reads the failed run before the canned repair.
const playJobResults = (role, prompt) => {
  const steps = [...prompt.matchAll(/`([^`]+)`/g)].map(match => match[1])
  const start = steps.findIndex(cmd => cmd.includes('just job start') &&
    (!role.startsWith('ci:') || cmd.includes('--watch --fail-fast') !== (process.env.PL_JOB_KIND === 'local')))
  if (start < 0) throw new Error('fixture: missing job start')
  let stdout = ''
  for (const cmd of steps.slice(start, start + 2)) {
    for (let attempt = 0; attempt < 6; attempt += 1) {
      try {
        stdout = execFileSync('bash', ['-c', cmd], { stdio: ['ignore', 'pipe', 'pipe'] }).toString().trim()
        ran.push({ cmd, rc: 0, stdout })
        break
      } catch (e) {
        ran.push({ cmd, rc: e.status })
        if (e.status === 124 && cmd.includes('just job wait') && attempt < 5) continue
        return { state: 'red', sha: 'abc', detail: `job rc ${e.status}` }
      }
    }
  }
  if (stdout.includes('CI_CHECK_FAILED')) {
    const failedLog = steps.find(cmd => cmd.startsWith('gh run view ') && cmd.includes('--log-failed'))
    if (!failedLog) throw new Error('fixture: missing failed-log step')
    const cmd = failedLog.replace('<run-id>', '42')
    execFileSync('bash', ['-c', cmd], { stdio: ['ignore', 'pipe', 'pipe'] })
    ran.push({ cmd, rc: 0 })
    // The implementation itself stays canned, like the other workflow modes.
    return reply(`${role}repair`)
  }
  return reply(role)
}

// Model the Review agent and its Codex child at the publication seam.
const playHandoverReview = (prompt) => {
  const task = prompt.match(/BEGIN CODEX TASK\n([\s\S]*?)\nEND CODEX TASK/)
  const poster = task ? 'codex' : 'claude'
  const commandPrompt = task ? task[1] : prompt
  const args = JSON.parse(argsJson)
  const bodyPath = `${args.repoDir}/.agents/state/milestone-handover-${args.pr}-${'a'.repeat(40)}/codex.md`
  mkdirSync(dirname(bodyPath), { recursive: true })
  writeFileSync(bodyPath, `[codex]\n交出判定：可交出 head=${'a'.repeat(40)}\nBlocking items: none\n`)
  const command = commandPrompt.match(/gh pr comment \d+ --repo [\w./-]+ --body-file ([^\n`]+?)(?:\. Do|`|$)/m)
  if (!command) return null
  const cmd = command[0].replace(/\. Do$/, '').replace(/`$/, '')
    .replace(/<literal absolute codex.md path>/, bodyPath)
  const input = JSON.stringify({ cwd: process.cwd(), tool_name: 'Bash', tool_input: { command: cmd } })
  const hook = fileURLToPath(new URL('../../../.agents/hook/enforce_milestone_gate_approval.sh', import.meta.url))
  try {
    execFileSync('bash', [hook, poster], { input, stdio: ['pipe', 'pipe', 'pipe'] })
    const url = execFileSync('bash', ['-c', cmd], { stdio: ['ignore', 'pipe', 'pipe'] }).toString().trim()
    ran.push({ cmd, poster, rc: 0 })
    return { ...reply('review:'), url }
  } catch (e) {
    ran.push({ cmd, poster, rc: e.status })
    return null
  }
}

// Exercise handover filesystem commands with deterministic stage writers.
const playHandoverFiles = (role, prompt) => {
  if (role === 'scratch:' || role.startsWith('artifact-check:')) {
    const result = play(prompt)
    if (!result.ok) return null
    return role === 'scratch:' ? reply(role) : result.stdout
  }
  const args = JSON.parse(argsJson)
  const scratch = `${args.repoDir}/.agents/state/milestone-handover-${args.pr}-${'a'.repeat(40)}`
  const files = {
    'findings:': ['findings.md'], 'review:': ['codex.md', 'codex-result.json'],
    'independent-publish:': ['independent-codex-report.md', 'independent-claude-report.md', 'independent-verdict.md'],
    'machine:': ['machine.md'], 'evidence:': ['evidence.md', 'ready.md'],
  }[role]
  if (files) {
    mkdirSync(scratch, { recursive: true })
    if (role === 'machine:') mkdirSync(`${scratch}/machine`, { recursive: true })
    for (const file of files) writeFileSync(`${scratch}/${file}`, `${role} output\n`)
    const [stage, file, kind] = (process.env.HANDOVER_LOSS || '').split(':')
    if (role === `${stage}:`) {
      if (kind === 'missing') unlinkSync(`${scratch}/${file}`)
      else writeFileSync(`${scratch}/${file}`, '')
    }
  }
  return reply(role)
}

// Run workflow-owned snapshots against an isolated host-config fixture.
const playHandoverSnapshots = (role, prompt) => {
  if (role.startsWith('snapshot:')) {
    const result = play(prompt)
    ran[ran.length - 1] = { ...ran[ran.length - 1], role, snapshot: true, data: result.ok ? JSON.parse(result.stdout) : null }
    return result.ok ? result.stdout : { error: 'Snapshot command failed' }
  }
  if (role === 'independent-cleanup:' || role === 'independent-claude-cleanup:') {
    return prompt.includes('journal absence or emptiness alone')
      ? { restored: true, childrenStopped: true }
      : { restored: false, childrenStopped: true, error: 'Missing journal' }
  }
  return reply(role)
}

const agent = async (prompt, opts = {}) => {
  const label = opts.label || ''
  const role = label.replace(/^\S+ #[0-9]+ /, '')
  calls.push({ label, role, phase: opts.phase || null, schema: opts.schema || null, effort: opts.effort || null, prompt })
  if (mode === 'exec-job-results' && /^(ci|gates):/.test(role)) return playJobResults(role, prompt)
  if (mode === 'exec-handover-snapshots') return playHandoverSnapshots(role, prompt)
  if (mode === 'exec-handover-files') return playHandoverFiles(role, prompt)
  if (mode === 'exec-handover' && role === 'review:') return playHandoverReview(prompt)
  if (mode === 'exec-resume-push' && role.startsWith('ci:') && process.env.PL_ACTION === 'unpushed') {
    const wt = `${JSON.parse(argsJson).repoDir}/../worktree/n`
    execFileSync('git', ['-C', wt, 'commit', '-qm', 'fix: CI repair', '-m', 'Refs: #396', '--allow-empty'])
    return { ...reply(role), sha: execFileSync('git', ['-C', wt, 'rev-parse', 'HEAD']).toString().trim() }
  }
  if (mode === 'exec-stage-checks' && role.startsWith(process.env.PL_STAGE === 'Implement' ? 'implement:' : 'fix:')) {
    const wt = `${JSON.parse(argsJson).repoDir}/../worktree/n`
    if (process.env.PL_ACTION === 'dirty') writeFileSync(`${wt}/pending.txt`, 'pending')
    if (process.env.PL_ACTION === 'unpushed' || process.env.PL_ACTION === 'pushed' || process.env.PL_ACTION === 'diverged') {
      execFileSync('git', ['-C', wt, 'commit', '-qm', 'fix', '--allow-empty'])
    }
    if (process.env.PL_ACTION === 'diverged') {
      const remote = execFileSync('git', ['-C', wt, 'commit-tree', 'HEAD^{tree}', '-p', 'HEAD^', '-m', 'remote change']).toString().trim()
      execFileSync('git', ['-C', wt, 'push', '-q', 'origin', `${remote}:b`])
    }
    if (process.env.PL_ACTION === 'pushed') execFileSync('git', ['-C', wt, 'push', '-q', 'origin', 'b'])
  }
  if (role.startsWith('prepare:') && mode !== 'exec-resume') return reply(role)
  if (['exec-resume', 'exec-resume-push'].includes(mode) && !role.startsWith('prepare:') && !(mode === 'exec-resume-push' && /^(stage-check|push-check):/.test(role))) return reply(role)
  if (mode === 'exec-record' && !role.startsWith('record:')) return reply(role)
  if (!['exec', 'exec-hooks', 'exec-record', 'exec-resume', 'exec-resume-push'].includes(mode) && !(mode === 'exec-stage-checks' && (role.startsWith('stage-check:') || role.startsWith('push-check:')))) return reply(role)
  const { ok, stdout } = play(prompt)
  return ok ? withStdout(reply(role), stdout) : null
}
const parallel = async (fns) => Promise.all(fns.map(f => f()))
const workflow = async (options, workflowArgs) => {
  workflowCalls.push({ options, args: workflowArgs })
  return runWorkflow(options.scriptPath, workflowArgs)
}

const AsyncFunction = (async () => {}).constructor
// Match the Workflow harness while preserving explicit date inputs.
const NativeDate = Date
const forbidden = (api) => { throw new Error(`Workflow: ${api} is forbidden`) }
const WorkflowDate = new Proxy(NativeDate, {
  construct(target, inputs) {
    if (inputs.length === 0) forbidden('new Date()')
    return Reflect.construct(target, inputs)
  },
  apply() { return forbidden('new Date()') },
  get(target, key) {
    return key === 'now' ? () => forbidden('Date.now()') : Reflect.get(target, key)
  },
})
const WorkflowMath = Object.create(Math)
WorkflowMath.random = () => forbidden('Math.random()')
const runWorkflow = async (path, workflowArgs) => {
  const src = readFileSync(path, 'utf8').replace(/^export const meta/m, 'const meta')
  const body = new AsyncFunction('args', 'agent', 'parallel', 'workflow', 'phase', 'log', 'Date', 'Math', src)
  return body(workflowArgs, agent, parallel, workflow, () => {}, message => logs.push(message), WorkflowDate, WorkflowMath)
}

const out = { result: null, error: null, calls, workflowCalls, ran, logs }
try {
  out.result = await runWorkflow(script, JSON.parse(argsJson))
} catch (e) {
  out.error = e.message
}
process.stdout.write(`${JSON.stringify(out)}\n`)
