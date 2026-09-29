# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

Every `gh` call names its repo with `-R ycpss91255/worktool` (see AGENTS.md: never rely on the current directory's remote). Bodies go through a file (`--body-file <file>`), never an inline `--body "..."` or a heredoc; the `enforce_gh_body_file` hook denies the rest.

- **Create an issue**: `gh issue create -R ycpss91255/worktool --title "..." --body-file <file> --label <label>`.
- **Read an issue**: `gh issue view <number> -R ycpss91255/worktool --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh issue list -R ycpss91255/worktool --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> -R ycpss91255/worktool --body-file <file>`
- **Apply / remove labels**: `gh issue edit <number> -R ycpss91255/worktool --add-label "..."` / `--remove-label "..."`
- **Close**: comment first, then close: `gh issue comment <number> -R ycpss91255/worktool --body-file <file>`, then `gh issue close <number> -R ycpss91255/worktool`.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> -R ycpss91255/worktool --comments` and `gh pr diff <number> -R ycpss91255/worktool` for the diff.
- **List external PRs for triage**: `gh pr list -R ycpss91255/worktool --state open --json number,title,body,labels,author,authorAssociation,comments` then keep only `authorAssociation` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE` (drop `OWNER`/`MEMBER`/`COLLABORATOR`).
- **Comment / label / close**: `gh pr comment <number> -R ycpss91255/worktool --body-file <file>`, `gh pr edit <number> -R ycpss91255/worktool --add-label "..."` / `--remove-label "..."`, `gh pr close <number> -R ycpss91255/worktool`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either — resolve with `gh pr view 42 -R ycpss91255/worktool` and fall back to `gh issue view 42 -R ycpss91255/worktool`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue (with `-R ycpss91255/worktool`).

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> -R ycpss91255/worktool --comments`.
