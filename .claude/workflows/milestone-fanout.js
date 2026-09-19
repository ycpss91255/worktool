// milestone-fanout: run pr-loop for several INDEPENDENT sub-issues at once.
//
//   Workflow({ scriptPath: "<repo>/.claude/workflows/milestone-fanout.js", args: {
//     repo: "ycpss91255/worktool",
//     parent: "#5",
//     codex: "on" | "off",
//     items: [
//       { issue: 149, branch: "m3/149-arm64-ci", name: "arm",   task: "..." },
//       { issue: 150, branch: "m3/150-bench",    name: "bench", task: "..." },
//     ]
//   } })
//
// Each item runs the whole pr-loop independently (pipeline, no barrier):
// whoever is green + codex-approved first is reported first. Only sub-issues
// with NO dependency on each other belong in one fan-out; stacked work goes
// through pr-loop one at a time. Merging stays with the main loop (one PR at
// a time, rebase on conflicts, merge commit, keep agent commits).

export const meta = {
  name: 'milestone-fanout',
  description: 'Fan out independent sub-issues, each through the pr-loop workflow (implement, CI, codex, fix); reports per-PR results; never merges',
  whenToUse: 'Start of a milestone wave when several sub-issues are independent. Pass args {repo, parent, codex?, items:[{issue,branch,name,task,gates?}]}.',
  phases: [{ title: 'Fan-out', detail: 'one pr-loop per item, in parallel' }],
}

const A = args || {}
if (!A.repo || !Array.isArray(A.items) || A.items.length === 0) throw new Error('milestone-fanout: args.repo and a non-empty args.items are required')
const SCRIPT = '/home/cyc/Desktop/worktool/.claude/workflows/pr-loop.js'

phase('Fan-out')
log(`${A.items.length} sub-issue(s): ${A.items.map(i => '#' + i.issue).join(', ')}`)
const results = await pipeline(A.items, async (item) => {
  try {
    return await workflow({ scriptPath: SCRIPT }, {
      repo: A.repo, parent: A.parent || '', codex: A.codex || 'on', maxRounds: A.maxRounds || 3,
      issue: item.issue, branch: item.branch, name: item.name, task: item.task, gates: item.gates,
    })
  } catch (e) {
    return { issue: item.issue, status: 'error', error: String(e && e.message || e) }
  }
})
const done = results.filter(Boolean)
log(`done: ${done.map(r => `#${r.issue} -> ${r.pr ? 'PR #' + r.pr : r.status} (${r.codex || r.error || ''})`).join('; ')}`)
return done
