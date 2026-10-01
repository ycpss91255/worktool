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
// `exec-stage-checks` plays only pr-loop stage-check agents; implementation
// and review remain canned so the checks can inspect real test repositories.
// `exec-hooks` also runs both publication body hooks before each shell
// step, using the unchanged tool cwd rather than following shell `cd`.
// A top-level reply field equal to "<stdout>" becomes the trimmed stdout of
// the agent's last step (e.g. the URL `gh issue comment` printed).
// Prints ONE JSON object: { result, error, calls: [{label, schema, prompt}],
// ran: [{cmd, rc}] }.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const [script, argsJson, repliesJson, mode] = process.argv.slice(2)
const replies = JSON.parse(repliesJson)
const calls = []
const ran = []
const workflowCalls = []

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
  return k === undefined ? null : replies[k]
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

const agent = async (prompt, opts = {}) => {
  const label = opts.label || ''
  calls.push({ label, schema: opts.schema || null, prompt })
  if (mode === 'exec-stage-checks' && label.startsWith(process.env.PL_STAGE === 'Implement' ? 'implement:' : 'fix:')) {
    const wt = `${JSON.parse(argsJson).repoDir}/../worktree/n`
    if (process.env.PL_ACTION === 'dirty') writeFileSync(`${wt}/pending.txt`, 'pending')
    if (process.env.PL_ACTION === 'unpushed' || process.env.PL_ACTION === 'pushed') {
      execFileSync('git', ['-C', wt, 'commit', '-qm', 'fix', '--allow-empty'])
    }
    if (process.env.PL_ACTION === 'pushed') execFileSync('git', ['-C', wt, 'push', '-q', 'origin', 'b'])
  }
  if (!['exec', 'exec-hooks'].includes(mode) && !(mode === 'exec-stage-checks' && label.startsWith('stage-check:'))) return reply(label)
  const { ok, stdout } = play(prompt)
  return ok ? withStdout(reply(label), stdout) : null
}
const parallel = async (fns) => Promise.all(fns.map(f => f()))
const workflow = async (options, workflowArgs) => {
  workflowCalls.push({ options, args: workflowArgs })
  return runWorkflow(options.scriptPath, workflowArgs)
}

const AsyncFunction = (async () => {}).constructor
const runWorkflow = async (path, workflowArgs) => {
  const src = readFileSync(path, 'utf8').replace(/^export const meta/m, 'const meta')
  const body = new AsyncFunction('args', 'agent', 'parallel', 'workflow', 'phase', 'log', src)
  return body(workflowArgs, agent, parallel, workflow, () => {}, () => {})
}

const out = { result: null, error: null, calls, workflowCalls, ran }
try {
  out.result = await runWorkflow(script, JSON.parse(argsJson))
} catch (e) {
  out.error = e.message
}
process.stdout.write(`${JSON.stringify(out)}\n`)
