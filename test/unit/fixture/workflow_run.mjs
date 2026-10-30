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

import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, unlinkSync, rmSync, symlinkSync, renameSync, utimesSync } from 'node:fs'
import { dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'

const [script, argsJson, repliesJson, mode] = process.argv.slice(2)
// Existing pr-loop scenarios model successful external gates/publication by
// default. Individual scenarios override either reply (including null).
const replies = {
  ...(process.env.WORKFLOW_JOB_REPLIES ? {
    'red-record:': { evidence: JSON.stringify([{ source: 'body', body: '## RED\n```text\njust test unit test/unit/example_spec.bats\nnot ok 1 regression\n```' }]) },
    'gates:': { state: 'green', detail: 'success' },
    'publish:Implement': { pr: 7, sha: 'abc' },
    'publish:Fix': { pr: 7, sha: 'def' },
    'adoption:': { posted: true },
  } : {}),
  ...JSON.parse(repliesJson.startsWith('@') ? readFileSync(repliesJson.slice(1), 'utf8') : repliesJson),
}
const calls = []
const ran = []
const workflowCalls = []
const logs = []

let hookCalls = 0
let hookPath
// Test images ship busybox ps; give hooks a procps-shaped process table.
const hookEnv = (root) => {
  if (!hookPath) {
    hookPath = mkdtempSync(`${tmpdir()}/workflow-hook-bin-`)
    writeFileSync(`${hookPath}/ps`, "#!/bin/sh\nprintf '%s\\n' '1 0 Thu Oct 29 10:00:00 2026 init'\n", { mode: 0o755 })
  }
  return { ...process.env, PATH: `${hookPath}:${process.env.PATH}`, CLAUDE_PROJECT_DIR: root }
}
// Check the body before each shell launch, as registered Bash hooks do.
const checkHooks = (cmd) => {
  if (process.env.HANDOVER_REAL_HOOKS) {
    const root = fileURLToPath(new URL('../../../', import.meta.url)).replace(/\/$/, '')
    const settings = JSON.parse(readFileSync(`${root}/.claude/settings.json`))
    // Claude sends the session and tool-use identity on every hook event.
    const identity = { session_id: 'fixture-session', tool_use_id: `fixture-${++hookCalls}` }
    for (const event of ['PreToolUse', 'PostToolUse']) {
      const input = JSON.stringify({ cwd: root, hook_event_name: event, ...identity, tool_name: 'Bash', tool_input: { command: cmd } })
      for (const entry of (settings.hooks[event] ?? []).filter(entry => entry.matcher === 'Bash')) {
        for (const hook of entry.hooks) {
          const path = hook.command.replace('${CLAUDE_PROJECT_DIR}', root)
          execFileSync('bash', [path], { input, env: hookEnv(root), stdio: ['pipe', 'pipe', 'pipe'] })
        }
      }
    }
  }
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
const play = (prompt, beforeCommand = () => {}) => {
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
    if (/(^|\s)<[A-Za-z][A-Za-z0-9_-]*>(\s|$)/.test(cmd) || cmd.includes('__SOURCE__')) continue
    try {
      beforeCommand(cmd)
      checkHooks(cmd)
      stdout = execFileSync('bash', ['-c', cmd], { stdio: ['ignore', 'pipe', 'ignore'] }).toString()
      ran.push({ cmd, rc: 0 })
    } catch (e) {
      ran.push({ cmd, rc: e.status, stderr: e.stderr?.toString() })
      return { ok: false, stdout: e.stdout?.toString().trim() || '' }
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

// Model the deferred review publisher and its Codex child at the publication seam.
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
    return { ...reply('independent-publish:'), reviewUrl: url }
  } catch (e) {
    ran.push({ cmd, poster, rc: e.status })
    return null
  }
}

// Model an artifact writer transcribing data incorrectly or reporting a failure.
const artifactFault = (role, prompt, scratch) => {
  const [stage, file, kind] = (process.env.HANDOVER_WRITE_FAULT || '').split(':')
  if (role !== `artifact-write:${stage}`) return { prompt }
  if (kind === 'error') return { error: `${scratch}/${file}: simulated write failure` }
  return { prompt: prompt.replace(/===ARTIFACT DATA===\n([^\n]*)/, (span, data) => {
    const files = JSON.parse(data)
    const path = `${scratch}/${file}`
    if (files[path]) files[path] = files[path].replace(/ORIGINAL/g, 'MUTATION')
    return `===ARTIFACT DATA===\n${JSON.stringify(files)}`
  }) }
}

// Model Write plus the stage-owned protocol, then run its actual command.
const playOwnedArtifacts = (role, prompt, scratch) => {
  const files = {
    'review:': ['codex-prompt.md', 'codex-continue.md', 'codex.md'],
    'machine:': ['machine/record.md'],
    'independent-codex:': ['independent-prompt.md', 'independent-continue.md', 'independent-recovery/codex/journal.md'],
    'independent-claude:': ['independent-recovery/claude/journal.md'],
    'independent-cleanup:': ['independent-recovery/codex/cleanup.md'],
    'independent-claude-cleanup:': ['independent-recovery/claude/cleanup.md'],
    'independent-publish:': ['independent-verdict.md'],
  }[role]
  if (!files) return
  const template = prompt.match(/Artifact copy template: `([^`]+)`/)
  if (!template) throw new Error(`Missing file-only artifact protocol: ${role}`)
  const digestTemplate = prompt.match(/Artifact digest template: `([^`]+)`/)
  if (!digestTemplate) throw new Error(`Missing file-only digest protocol: ${role}`)
  const content = replies['findings:'].content
  const source = `${scratch}/../scratchpad/owned.txt`
  mkdirSync(dirname(source), { recursive: true })
  for (const file of files) {
    writeFileSync(source, content)
    const digestCmd = digestTemplate[1].replace('__SOURCE__', source)
    checkHooks(digestCmd)
    const expected = JSON.parse(execFileSync('bash', ['-c', digestCmd], { stdio: ['ignore', 'pipe', 'pipe'] }))
    if (expected.bytes !== Buffer.byteLength(content) || expected.sha256 !== createHash('sha256').update(content).digest('hex')) throw new Error(`Incorrect digest: ${file}`)
    ran.push({ cmd: digestCmd, rc: 0, role })
    const cmd = template[1].replace('__SOURCE__', source).replace('__DESTINATION__', `${scratch}/${file}`)
      .replace('__BYTES__', expected.bytes).replace('__SHA256__', expected.sha256)
    checkHooks(cmd)
    execFileSync('bash', ['-c', cmd], { stdio: ['ignore', 'pipe', 'pipe'] })
    ran.push({ cmd, rc: 0, role, artifact: file, byteExact: readFileSync(`${scratch}/${file}`).equals(Buffer.from(content)) })
  }
}

// Exercise handover filesystem commands with deterministic stage writers.
const playHandoverFiles = (role, prompt) => {
  const args = JSON.parse(argsJson)
  const scratch = `${args.repoDir}/.agents/state/milestone-handover-${args.pr}-${'a'.repeat(40)}`
  if (process.env.HANDOVER_OWNED_ARTIFACTS) playOwnedArtifacts(role, prompt, scratch)
  const [stage, lostFile, kind] = (process.env.HANDOVER_LOSS || '').split(':')
  const lossCheck = { findings: 'Review', machine: 'Evidence', evidence: 'Prepared' }[stage]
  if (role === `artifact-check:${lossCheck}`) {
    if (kind === 'missing') unlinkSync(`${scratch}/${lostFile}`)
    else writeFileSync(`${scratch}/${lostFile}`, '')
  }
  if (role === 'scratch:' || role.startsWith('artifact-check:') || role.startsWith('artifact-write:')) {
    const fault = artifactFault(role, prompt, scratch)
    if (fault.error) return { error: fault.error }
    const data = fault.prompt.match(/===ARTIFACT DATA===\n([^\n]*)\n===END ARTIFACT DATA===/)
    let instructions = fault.prompt
    if (data) {
      const scratchpad = `${args.repoDir}/scratchpad`
      mkdirSync(scratchpad, { recursive: true })
      for (const [path, content] of Object.entries(JSON.parse(data[1]))) {
        writeFileSync(`${scratchpad}/handover-${args.pr}-${'a'.repeat(40)}-${path.split('/').pop()}.txt`, content)
      }
      instructions = instructions.replace(data[0], '').replaceAll('__CLAUDE_SCRATCHPAD__', scratchpad)
    }
    const result = play(instructions)
    if (!result.ok) return result.stdout || null
    return role === 'scratch:' ? reply(role) : result.stdout
  }
  const files = {
    'review:': ['codex.md', 'codex-result.json'],
    'independent-publish:': ['independent-verdict.md'],
  }[role]
  if (files) {
    mkdirSync(scratch, { recursive: true })
    for (const file of files) writeFileSync(`${scratch}/${file}`, `${role} output\n`)
    if (role === `${stage}:` && stage === 'review') {
      if (kind === 'missing') unlinkSync(`${scratch}/${lostFile}`)
      else writeFileSync(`${scratch}/${lostFile}`, '')
    }
  }
  return reply(role)
}

const snapshotPath = prompt => JSON.parse(prompt.match(/to the path ("(?:[^"\\]|\\.)*") with the Write tool/)[1])
  .replace(/\.mjs$/, '.json')
const damaged = new Set()
// Model a comparison program altered after its verified copy.
const tamperComparison = (role, cmd) => {
  if (role !== process.env.HANDOVER_COMPARE_TAMPER || !cmd.includes(' sha256sum ')) return
  const program = cmd.match(/'([^']*\.cjs)'/)[1]
  writeFileSync(program, readFileSync(program, 'utf8') + '// tampered\n')
}
const damageSnapshot = (role, prompt, cmd) => {
  if (role !== process.env.HANDOVER_SNAPSHOT_DAMAGE || !/ sha256sum | node -e /.test(cmd) || damaged.has(role)) return
  damaged.add(role)
  const path = snapshotPath(prompt)
  const kind = process.env.HANDOVER_SNAPSHOT_DAMAGE_KIND
  if (kind === 'missing') { unlinkSync(path); return }
  if (kind === 'json') { writeFileSync(path, '{'); return }
  const data = JSON.parse(readFileSync(path, 'utf8'))
  if (kind === 'empty') data.snapshot = {}
  else data.snapshot[`${process.env.HOME}/.config/ghostty/config`].unexpected = 'invalid'
  writeFileSync(path, JSON.stringify(data))
}

// Run workflow-owned snapshots against an isolated host-config fixture.
const playHandoverSnapshots = (role, prompt) => {
  if (process.env.HANDOVER_UNRELATED_SIBLINGS && /^independent-(codex|claude):$/.test(role)) {
    for (const [parent, name] of [[process.env.HOME, '.claude.json'], [`${process.env.HOME}/.local/share`, 'recently-used.xbel']]) {
      writeFileSync(`${parent}/${name}.tmp`, role)
      renameSync(`${parent}/${name}.tmp`, `${parent}/${name}`)
      // Make the parent metadata change deterministic even on coarse filesystems.
      const time = new Date(role === 'independent-codex:' ? '2030-01-01' : '2031-01-01')
      utimesSync(parent, time, time)
    }
  }
  if (role === process.env.HANDOVER_MUTATE + ':') {
    writeFileSync(`${process.env.HOME}/.config/ghostty/config`, 'changed config\n')
  }
  if (role === process.env.HANDOVER_SNAPSHOT_FAILURE) {
    const ghostty = `${process.env.HOME}/.config/ghostty`
    if (process.env.HANDOVER_SNAPSHOT_FAILURE_KIND === 'sha256') {
      unlinkSync(`${ghostty}/config`)
      symlinkSync('/proc/self/mem', `${ghostty}/config`)
    } else {
      rmSync(ghostty, { recursive: true })
      writeFileSync(ghostty, 'not a directory\n')
    }
  }
  if (role.startsWith('snapshot:')) {
    const scratchpad = `${JSON.parse(argsJson).repoDir}/scratchpad`
    let steps = prompt.replaceAll('__CLAUDE_SCRATCHPAD__', scratchpad)
    // Model Write of each JSON-decoded program to its scratchpad .txt file.
    const data = steps.match(/===ARTIFACT DATA===\n([^\n]*)\n===END ARTIFACT DATA===/)
    if (data) {
      for (const [path, content] of Object.entries(JSON.parse(data[1]))) {
        mkdirSync(dirname(path), { recursive: true })
        writeFileSync(path, content)
      }
      steps = steps.replace(data[0], '')
    }
    const result = play(steps, cmd => { damageSnapshot(role, prompt, cmd); tamperComparison(role, cmd) })
    ran[ran.length - 1] = {
      ...ran[ran.length - 1], role, snapshot: true,
      data: result.ok ? JSON.parse(readFileSync(snapshotPath(prompt), 'utf8')) : null,
      comparison: result.stdout ? JSON.parse(result.stdout) : null,
    }
    if (result.ok && process.env.HANDOVER_RELAY_ERROR === role) {
      // The agent mis-copies either relayed snapshot content or one digest character.
      const relayed = JSON.parse(result.stdout)
      if (process.env.HANDOVER_RELAY_ERROR_KIND === 'digest') {
        const digest = relayed.digests.after
        relayed.digests.after = digest.slice(0, -1) + (digest.endsWith('0') ? '1' : '0')
      } else {
        relayed.snapshot = JSON.parse(readFileSync(snapshotPath(prompt), 'utf8')).snapshot
        relayed.snapshot[`${process.env.HOME}/.config/ghostty/config`].inode = '999999'
      }
      return relayed
    }
    return result.stdout || { error: 'Snapshot command failed' }
  }
  if (role === 'independent-cleanup:' || role === 'independent-claude-cleanup:') {
    return prompt.includes('journal absence or emptiness alone')
      ? { restored: false, childrenStopped: true }
      : { restored: false, childrenStopped: true, error: 'Missing journal' }
  }
  return reply(role)
}

const agent = async (prompt, opts = {}) => {
  const label = opts.label || ''
  const role = label.replace(/^\S+ #[0-9]+ /, '')
  calls.push({ label, role, phase: opts.phase || null, schema: opts.schema || null, effort: opts.effort || null, prompt })
  if (mode === 'exec-auto-body' && role.startsWith('auto-body:')) {
    const { ok, stdout } = play(prompt)
    return { ok, changed: stdout === 'changed' }
  }
  if (mode === 'exec-auto-body' && role.startsWith('auto-ci:') && process.env.AUTO_REAL_CI) {
    const { ok, stdout } = play(prompt)
    return ok ? JSON.parse(stdout) : { state: 'red', sha: '', detail: 'command failed' }
  }
  if (mode === 'exec-auto-body' && role.startsWith('auto-ci:')) return { state: process.env.AUTO_FINAL_RED ? 'red' : 'green', sha: 'abc', detail: 'success' }
  if (role.startsWith('auto-body:')) return { ok: true, changed: false }
  if (mode === 'exec-red-record' && role.startsWith('red-record:')) {
    const { ok, stdout } = play(prompt)
    if (ran.length) ran[ran.length - 1].stdout = stdout
    return ok ? withStdout(reply(role), stdout) : null
  }
  if (mode === 'exec-job-results' && /^(ci|gates):/.test(role)) return playJobResults(role, prompt)
  if (mode === 'exec-handover-snapshots') return playHandoverSnapshots(role, prompt)
  if (mode === 'exec-handover-files') return playHandoverFiles(role, prompt)
  if (mode === 'exec-handover' && role === 'independent-publish:') return playHandoverReview(prompt)
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
