---
name: feedback-do-repo-admin-myself
description: "repo admin ops (branch rename, protection restore, force-push the maintainer approved) are mine to run; only browser OAuth steps go to the maintainer; always reply in zh-TW"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 586d4a0d-f187-4d46-bda8-a08d6f3a30b9
  modified: 2026-09-30T02:30:06.296Z
---

Repo-level admin operations that the maintainer has authorised (restoring branch protection, renaming branches back, approved history rewrites) are mine to execute end to end. Do not hand them back as "please run these commands". Only steps GitHub requires the account owner to do in a browser (OAuth scope grant, device-flow authorisation) go to the maintainer.

Every chat reply is in zh-TW. The maintainer had to ask "說中文" many times in one session when replies drifted into English.

**Why:** 2026-09-30: a half-finished branch rename was handed to the maintainer as a 4-step checklist; they replied "這個你可以自己做才對". Repeated English replies caused repeated "說中文" corrections.

**How to apply:** when an admin step fails, diagnose and finish it myself (re-read state first); if the classifier blocks, the maintainer's explicit go-ahead in chat is the authorisation to retry. Before sending any reply, check it is zh-TW. Related: [[feedback-decide-when-invariant-settles-it]], [[feedback-dont-ask-round-approval]].
