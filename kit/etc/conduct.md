# PROJECT agent on this host (user agent)

This file is root-owned; you cannot change it. It governs this box only. The owner's workstation rules do not apply here.

## How your work reaches GitHub
- You have no GitHub credential and no database access. Do not look for either.
- Push work as `git push origin HEAD:refs/heads/agent/<name>` (one level, letters, digits, `.`, `_`, `-`). `origin` is a local repo; a courier forwards `agent/*` branches to GitHub within a minute and opens a ready PR. It never force-pushes: to redo a branch, push a new name.
- Keep history linear (rebase on `origin/main`); branches containing merge commits are refused.
- Changes to `.github/`, `.claude/`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json` or `.gitmodules` are never pushed. They become a patch for the owner. Put them on their own branch; do not mix them with other work.
- Branches containing anything gitleaks flags are refused. Never commit secrets or data files.
- The CI bot reviews and merges. Tier 1 merges on its review; Tier 2 (money path, migrations, config, workflows, test infrastructure, deliverable specs) merges only when an independent second review also approves. The owner does not merge or approve work: make judgment calls yourself and record why. A closed PR stays closed; do not resubmit rejected work under a new name.

## What to work on
- One deliverable slice at a time. A finding interrupts only if newly opened or reopened and CRITICAL, on the money path or a live-execution control, wrong data on a live read path, a live secret, or a red liveness check.
- Spec first: a deliverable's acceptance criteria and tests land in their own PR before the implementation.

## How to work
- Tests execute behaviour. Never assert on source or doc text; never write tests of tests.
- No finding IDs or history in code comments; comment only a non-obvious constraint. History goes in commit messages.
- A doc has one current State section, overwritten on update. No dated status blocks, no per-finding plan docs. Docs must not grow faster than code.
- A review finding blocks only with evidence and a concrete failure scenario. Loops stop when a round has no blocking finding.
- No AI attribution in commits, PRs or code.
- If you are told to stop, or `/etc/courier/STOP` exists, stop.

## Compact Instructions
After compaction, keep: the current work item and its acceptance criteria, decisions made and why, files changed, commands run and results, open questions, and the next step. Drop dead ends. Then re-read the in-progress item and run `git status`.
