---
name: feedback-folder-all-singular
description: Folder names are all-singular (doc/structure.md); only upstream-imposed and acronym exceptions
metadata:
  type: feedback
---

Folder naming in worktool is **all-singular**, zero judgment calls
(inherited from init_ubuntu, whose ADR-0021 set the rule; worktool records
it in doc/structure.md, 目錄結構):

- **Every repo-owned directory** → **singular**:
  `test/`, `script/`, `doc/`, `lib/`, `box/`, `tool/`, `dockerfile/`,
  `doc/agent/`, `doc/diagram/`, `.agents/hook/`, `.agents/script/`,
  `.agents/memory/`.
- **Acronyms** → preserve OSS convention: `doc/adr/` (not `adrs/`).
- **Upstream-imposed** → keep upstream's choice (fish `completions/` /
  `functions/`, `.agents/skills/` / `.claude/skills/` / `.claude/workflows/`
  Claude Code scan paths, `.github/workflows/`).
- **File names** are out of scope.

**Why:** init_ubuntu tried plural-for-collections (its ADR-0005) and
reverted (its ADR-0021): the per-directory "collection vs concept"
classification cost exceeded the industry-alignment benefit for a
single-maintainer repo. A zero-exception singular rule needs no judgment;
the only remaining questions are "upstream-imposed?" and "acronym?".

**How to apply:** Name every new directory singular. Only deviate when
an upstream tool mandates the name or the name is an acronym. Never
reintroduce a collection-vs-concept distinction. Where an upstream skill
template names a plural `docs` directory for ADRs or agent config,
worktool's paths are `doc/adr/` and `doc/agent/` (doc/agent/domain.md).

Related: [[feedback-unify-formats]] (one source of truth — the naming
rule lives in doc/structure.md; this memory just points at it).
