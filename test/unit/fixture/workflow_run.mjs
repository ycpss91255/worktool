// test/unit/fixture/workflow_run.mjs - run ONE Workflow template under node
// with stand-in agent/parallel/phase/log, for test/unit/workflow_spec.bats.
//
// Usage:
//   node workflow_run.mjs <template.js> <args-json> <replies-json> [exec]
//
// <replies-json> maps an agent label PREFIX to the value that agent returns
// (a missing prefix returns null, as a failed agent does). Without `exec`
// the agents only record their prompt. With `exec` each agent also plays
// the steps it is told to do, deterministically: it writes the
// ===BEGIN===/===END=== block to the path named by
// `to the path "<json string>" with the Write tool` (parents created, as
// the Write tool does), then runs every backtick span outside that block
// that starts with `cd `, `mkdir ` or `gh ` through `bash -c`, in order.
// Prints ONE JSON object: { result, error, calls: [{label, schema, prompt}],
// ran: [{cmd, rc}] }.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { execFileSync } from 'node:child_process'

const [script, argsJson, repliesJson, mode] = process.argv.slice(2)
const replies = JSON.parse(repliesJson)
const calls = []
const ran = []
const workflowCalls = []

const reply = (label) => {
  const k = Object.keys(replies).find(p => label.startsWith(p))
  return k === undefined ? null : replies[k]
}

const play = (prompt) => {
  const block = prompt.match(/===BEGIN===\n([\s\S]*?)\n===END===/)
  const outside = block ? prompt.replace(block[0], '') : prompt
  const target = outside.match(/to the path ("(?:[^"\\]|\\.)*") with the Write tool/)
  if (block && target) {
    const path = JSON.parse(target[1])
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, block[1])
  }
  for (const [, cmd] of outside.matchAll(/`((?:cd|mkdir|gh) [^`]*)`/g)) {
    try {
      execFileSync('bash', ['-c', cmd], { stdio: ['ignore', 'ignore', 'ignore'] })
      ran.push({ cmd, rc: 0 })
    } catch (e) {
      ran.push({ cmd, rc: e.status })
    }
  }
}

const agent = async (prompt, opts = {}) => {
  const label = opts.label || ''
  calls.push({ label, schema: opts.schema || null, prompt })
  if (mode === 'exec') play(prompt)
  return reply(label)
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
