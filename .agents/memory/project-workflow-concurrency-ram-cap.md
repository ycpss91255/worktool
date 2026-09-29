---
name: project-workflow-concurrency-ram-cap
description: "RAM-crisis postmortem (2026-07-05): the 30GB hog was runaway tmux-powerline, NOT the Docker workflows; diagnose the actual process before blaming workflows"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

On 2026-07-05 (while running init_ubuntu workflows, worktool's predecessor)
the dev machine hit 35/38GB used + swapping, appearing to stall many
parallel workflows. I WRONGLY blamed the workflows' test runs and stopped
three of them. The real cause: FIVE runaway `tmux-powerline` processes, each
stuck ~49 min at ~6GB RSS = ~30GB. Killing those five PIDs dropped usage
from 34GB to 4GB instantly. The Docker workflows used real but MANAGEABLE
RAM; they were not the hog.

**Lessons:**
1. Before attributing high RAM to the workflows, READ the actual top processes'
   cmdline: `ps -eo pid,rss,etime,comm --sort=-rss | head` then
   `tr '\\0' ' ' < /proc/<PID>/cmdline`. A "bash" at 6GB is suspicious -- check
   what it is. Do not assume it is Docker.
2. RAM is NOT the binding limit, CPU is: a gate parallelizes internally to
   nproc, so N concurrent workflows spawn ~N*nproc busy processes. Running 4
   at once drove load average to ~65 on an 8-core box -- gates that take
   ~5min crawled to 25min+ (CPU-oversubscribed, NOT hung). Cap concurrent
   workflows at ~2. Distinguish hung (low CPU + long) from slow (high CPU +
   long) with `docker stats --no-stream` before intervening.
3. Failed/stopped workflows can orphan Docker containers. Remove them
   targeted by name or label (`docker ps -aq --filter name=<prefix> | xargs
   -r docker rm -f`), never with prune / global ops. worktool's gates run in
   one-shot `docker run --rm` containers (script/test/test.sh), so a clean
   exit leaves none; check after a killed run.

- NEVER run two agents/gates on the SAME worktree concurrently: they share the
  Docker `/source` bind mount, so two gate runs racing while git mutates the
  tree produce SPURIOUS failures (seen 2026-07-05: 3 overlapping agents on one
  worktree -> 8 bogus unit failures; GitHub's isolated CI was green). Each
  workflow item gets its own `.worktree/<name>`.

Related: [[project-workflow-long-implement-no-schema]], [[feedback-use-monitor-for-ci]].
