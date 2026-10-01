export const meta = {
  name: 'milestone-fanout',
  description: 'Fan out independent sub-issues, each through pr-loop, with at most two child workflows and test runs active; reports each PR as it finishes; never merges',
  whenToUse: 'Start of a milestone wave when several sub-issues are independent. Pass args {repo, repoDir, parent, implementer?, codex?, maxRounds?, items:[{issue,branch,name,task,gates?}]}.',
  phases: [{ title: 'Fan-out', detail: 'pr-loop items run in batches of at most two; each result is logged when its child workflow finishes' }],
}

// milestone-fanout: run pr-loop for several INDEPENDENT sub-issues at once.
//
//   Workflow({ scriptPath: "<repoDir>/.claude/workflows/milestone-fanout.js", args: {
//     repo: "ycpss91255/worktool",
//     parent: "#5",
//     codex: "on" | "off",
//     maxRounds: 3,
//     repoDir: "/path/to/worktool",   // required: local checkout
//     items: [
//       { issue: 149, branch: "m3/149-arm64-ci", name: "arm",   task: "...", gates: "just test lint, just test changed" },
//       { issue: 150, branch: "m3/150-bench",    name: "bench", task: "..." },
//     ]
//   } })
//
// Each item runs the whole pr-loop independently (pipeline, no barrier) and
// is logged as soon as its own loop ends. Only sub-issues with NO dependency
// on each other belong in one fan-out; stacked work goes through pr-loop one
// at a time. Merging stays with the main loop (one PR at a time, rebase on
// conflicts, merge commit, keep agent commits).

const A = args || {}
if (!A.repo || !A.repoDir || !Array.isArray(A.items) || A.items.length === 0) throw new Error('milestone-fanout: args.repo, args.repoDir and a non-empty args.items are required')
const IMPLEMENTER = A.implementer === undefined ? 'codex' : A.implementer
if (IMPLEMENTER !== 'codex' && IMPLEMENTER !== 'claude') throw new Error(`milestone-fanout: args.implementer must be "codex" or "claude", got ${JSON.stringify(A.implementer)}`)
for (const it of A.items) {
  for (const k of ['issue', 'branch', 'name', 'task']) {
    if (!it[k]) throw new Error(`milestone-fanout: item ${JSON.stringify(it.issue || it)} lacks ${k}`)
  }
}
const CONCURRENCY = A.concurrency === undefined ? 10 : A.concurrency
const REPO_DIR = A.repoDir
const SCRIPT = `${REPO_DIR}/.claude/workflows/pr-loop.js`

phase('Fan-out')
log(`${A.items.length} sub-issue(s): ${A.items.map(i => '#' + i.issue).join(', ')}`)
const runItem = async (item) => {
    let result
    try {
      result = await workflow({ scriptPath: SCRIPT }, {
        repo: A.repo, repoDir: REPO_DIR, parent: A.parent || '', codex: A.codex === undefined ? 'on' : A.codex,
        implementer: IMPLEMENTER, maxRounds: A.maxRounds === undefined ? 3 : A.maxRounds,
        issue: item.issue, branch: item.branch, name: item.name, task: item.task, gates: item.gates,
      })
    } catch (e) {
      result = { issue: item.issue, pr: 0, sha: '', ciState: 'error', codexVerdict: 'error', rounds: 0, blockingLeft: [String((e && e.message) || e)] }
    }
    const summary = result ? `PR #${result.pr} ci=${result.ciState} codex=${result.codexVerdict} rounds=${result.rounds}${result.blockingLeft && result.blockingLeft.length ? ' blocking=' + result.blockingLeft.length : ''}` : 'no result'
    log(`#${item.issue} done: ${summary}`)
    return result || { issue: item.issue, pr: 0, sha: '', ciState: 'error', codexVerdict: 'error', rounds: 0, blockingLeft: ['pr-loop returned nothing'] }
}
const results = []
for (let i = 0; i < A.items.length; i += CONCURRENCY) {
  const batch = A.items.slice(i, i + CONCURRENCY)
  const completed = await parallel(batch.map(item => () => runItem(item)))
  results.push(...completed)
}
return results.filter(Boolean)

// args 範例（可直接貼進 Workflow 的 args）
// {
//   "repo": "ycpss91255/worktool",
//   "repoDir": "/path/to/worktool",
//   "parent": "#280",
//   "implementer": "codex",
//   "maxRounds": 3,
//   "items": [
//     { "issue": 281, "branch": "feat/281-a", "name": "impl281", "task": "完成 issue #281。" },
//     { "issue": 282, "branch": "feat/282-b", "name": "impl282", "task": "完成 issue #282。" }
//   ]
// }
