---
name: feedback-remote-cmd-write-script-copy-run
description: "For non-trivial remote ops, write a script file, copy it to the remote /tmp, then run it there — do NOT inline in ssh '...'"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 59ac1285-fe98-42d4-8ab9-9044ea79a10c
---

When running any non-trivial command on the remote work box (`yunchien@192.168.10.10`,
host `C01013263-ubuntu`), do NOT inline it inside `ssh '...'`. The remote login shell is
**fish**, and nested quotes / parentheses in an inline SSH string repeatedly break
(`fish: Unknown command`, `syntax error near unexpected token '('`, `Missing end to
balance this for loop`).

**How to apply:** write the script to a local file → copy it to the remote's `/tmp`
(scp, or `ssh ... 'cat > /tmp/x.sh' < local`, or pipe a tar) → execute it there with an
explicit interpreter (`ssh ... bash /tmp/x.sh` or `ssh ... 'bash -ls' < local`). This
sidesteps all fish-parsing and quote-nesting problems.

**Why:** the user called this out after many rounds of inline-SSH quoting breakage during
the tmux config sync. See [[reference-tmux-statusbar-config]] for the sync procedure and
[[feedback-tmux-statusbar-md-sync]] for the md-sync rule. SSH now uses the gnome-keyring
agent (`export SSH_AUTH_SOCK=/run/user/1000/keyring/ssh`) with an askpass fallback
(its password is not recorded in this repo copy) in the session scratchpad.
