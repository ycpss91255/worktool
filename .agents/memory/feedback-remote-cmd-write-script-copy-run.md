---
name: feedback-remote-cmd-write-script-copy-run
description: "For non-trivial remote ops, write a script file, copy it to the remote /tmp, then run it there — do NOT inline in ssh '...'"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 59ac1285-fe98-42d4-8ab9-9044ea79a10c
---

When running any non-trivial command on a remote machine (the maintainer's
remote work box; its address and account live in the maintainer's ssh
config, never in this repo), do NOT inline it inside `ssh '...'`. The remote
login shell is **fish**, and nested quotes / parentheses in an inline SSH
string repeatedly break (`fish: Unknown command`, `syntax error near
unexpected token '('`, `Missing end to balance this for loop`).

**How to apply:** write the script to a local file → copy it to the remote's `/tmp`
(scp, or `ssh ... 'cat > /tmp/x.sh' < local`, or pipe a tar) → execute it there with an
explicit interpreter (`ssh ... bash /tmp/x.sh` or `ssh ... 'bash -ls' < local`). This
sidesteps all fish-parsing and quote-nesting problems.

**Why:** the user called this out after many rounds of inline-SSH quoting
breakage during a config sync. Authentication goes through the desktop's ssh
agent; no password or socket path is recorded here.
