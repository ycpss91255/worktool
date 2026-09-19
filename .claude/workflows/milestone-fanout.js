export const meta = {
  name: 'milestone-fanout',
  description: 'Fan out independent sub-issues, each through the pr-loop workflow (implement, CI, codex, fix); reports each PR as it finishes; never merges',
  whenToUse: 'Start of a milestone wave when several sub-issues are independent. Pass args {repo, repoDir, parent, codex?, maxRounds?, sessionUrl?, items:[{issue,branch,name,task,gates?}]}.',
  phases: [{ title: 'Fan-out', detail: 'one pr-loop per item, in parallel; each result logged the moment it lands' }],
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
//       { issue: 149, branch: "m3/149-arm64-ci", name: "arm",   task: "..." },
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
for (const it of A.items) {
  for (const k of ['issue', 'branch', 'name', 'task']) {
    if (!it[k]) throw new Error(`milestone-fanout: item ${JSON.stringify(it.issue || it)} lacks ${k}`)
  }
}
const REPO_DIR = A.repoDir
const SCRIPT = `${REPO_DIR}/.claude/workflows/pr-loop.js`

phase('Fan-out')
log(`${A.items.length} sub-issue(s): ${A.items.map(i => '#' + i.issue).join(', ')}`)
const results = await pipeline(A.items,
  async (item) => {
    try {
      return await workflow({ scriptPath: SCRIPT }, {
        repo: A.repo, repoDir: REPO_DIR, parent: A.parent || '', sessionUrl: A.sessionUrl, codex: A.codex === undefined ? 'on' : A.codex,
        maxRounds: A.maxRounds === undefined ? 3 : A.maxRounds,
        issue: item.issue, branch: item.branch, name: item.name, task: item.task, gates: item.gates,
      })
    } catch (e) {
      return { issue: item.issue, pr: 0, sha: '', ciState: 'error', codexVerdict: 'error', rounds: 0, blockingLeft: [String((e && e.message) || e)] }
    }
  },
  (r, item) => {
    const summary = r ? `PR #${r.pr} ci=${r.ciState} codex=${r.codexVerdict} rounds=${r.rounds}${r.blockingLeft && r.blockingLeft.length ? ' blocking=' + r.blockingLeft.length : ''}` : 'no result'
    log(`#${item.issue} done: ${summary}`)
    return r || { issue: item.issue, pr: 0, sha: '', ciState: 'error', codexVerdict: 'error', rounds: 0, blockingLeft: ['pr-loop returned nothing'] }
  })
return results.filter(Boolean)
