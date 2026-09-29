---
name: feedback-no-personal-info-in-scripts
description: "Never hardcode the user's real account identifiers (email addresses, usernames) into scripts or comments, even as illustrative examples"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 59ac1285-fe98-42d4-8ab9-9044ea79a10c
---

Never write the user's actual personal account identifiers (Gmail addresses, other
account usernames, etc.) into script files or code comments -- not even as
"here's what this looks like in practice" illustrative examples. Treat them as
confidential, the same as secrets/passwords, even though the value itself isn't a
credential.

**Why:** while writing `tmux/mail-open.sh` (double-click mail pill -> open the
monitored Thunderbird account), the script LOGIC correctly read the account
dynamically from `config.sh` (`TMUX_POWERLINE_SEG_MAILCOUNT_GMAIL_USERNAME`), but the
header COMMENT listed the user's real email addresses as example context ("this one
has <account>@gmail.com, <account2>@gmail.com, ..." - real addresses redacted in this copy). The user caught this
immediately: "這個賬號不能存在腳本中應該是要自動找監控賬號, 這是個人資訊, 算是機密"
(this account must not exist in the script, it should auto-discover the monitored
account; this is personal info, treat it as confidential).

**How to apply:** when writing any script/doc that references the user's real
accounts, hosts, or identifiers discovered while debugging (e.g. reading
`~/.thunderbird/profiles.ini` or `prefs.js` to find an account), keep the SCRIPT
generic (read the value from config at runtime) and keep comments generic too
("the monitored account", "an account in the profile") -- never paste the actual
discovered value into a comment as illustration. This applies repo-wide, not just to
mail: same standard as never hardcoding secrets, apply it to any personally
identifying value uncovered during diagnostics.
