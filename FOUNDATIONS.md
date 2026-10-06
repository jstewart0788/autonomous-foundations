# Foundations of an Autonomous Development System

A blueprint for an AI coding agent that works a real codebase continuously, merges its own reviewed changes and deploys them, with no human in the loop. It is distilled from building one end to end on a production host in late 2026, and from running it unattended. Nothing here is specific to that project. Where a concrete tool is named, it is what was used and proved, not the only option.

**Start a new project from here.** Read Parts 1 and 2. Then copy `kit/` (the host-side scripts and units), build the repo-side pieces listed in `kit/README.md`, and follow the rebuild roadmap phase by phase. Last updated 2026-10-05.

The system rests on one idea. **An agent cannot be trusted by instruction, only by mechanism.** Every property that matters has to be enforced by something the agent cannot edit, and proven by breaking it on purpose.

---

## Part 1 — The blueprint

### The shape

```
            ┌──────────────── the host (also runs production) ────────────────┐
            │                                                                   │
 event ──►  │  LOOP (root, fixed PATH)                                          │
 (PR merged,│   │  one fresh, isolated pass per event                           │
  reviewed) │   ▼                                                               │
            │  PASS (agent user, transient unit, empty home, clean clone at    │
            │        the exact main SHA, hard CPU/mem/time limits)              │
            │   │  git push agent/loop-*                                         │
            │   ▼                                                               │
            │  LOCAL BARE REPO ──► COURIER (own user, holds the only token)     │
            │                        │ secret scan, protected paths → outbox,   │
            │                        │ one-PR hold, never force-pushes          │
            │                        │ writes a PR-status file the agent reads  │
            └────────────────────────┼──────────────────────────────────────────┘
                                     ▼
                         CODE HOST (PRs) ──► REVIEW GATE (CI)
                                              review → classify tier (from base)
                                              → Tier 2: second independent review
                                              → merge → deploy
                                     │
                                     └── the review/merge is the next event
            Alerts: liveness pings + push notifications to the human's phone
            Reports page: daily report + 5-min health snapshot + alert history,
                          written by root jobs the agent can't touch
```

### The nine components

Build them in this order. Each one is useless or dangerous without the ones before it.

#### 1. Containment: the agent's identity

- A dedicated OS user for the agent, with no sudo, no container runtime, no database access and no production credentials.
- A firewall rule scoped to that user's UID that rejects the database port on every address. That covers loopback, the container network and any VPN.
- It has no credentials for the code host. It pushes only to a local bare repo.
- Prove each property from the agent's side: connection refused, file unreadable, push rejected. Also prove the legitimate path still works.

#### 2. The courier: the only thing holding a code-host credential

- A small root-owned script, run by its own user on a one-minute timer. It forwards `agent/*` branches to the code host and opens PRs.
- **Rules:**
  - an explicit refspec for every push, never wildcards or mirroring;
  - no force-pushes and no deletions;
  - merge commits refused, so history stays linear;
  - every commit in the range checked, not just the tip.
- **Protected paths:** changes to CI config, agent config and rule files (`.github/`, `.claude/`, `CLAUDE.md`, `AGENTS.md`, MCP config, `.gitmodules`) are never pushed. They become a patch in an outbox for a human. The code host runs a pushed branch's own workflows with repo secrets, so these paths are an escalation route.
- **Secret scan:** a secret scanner runs on the range, and if the scanner is missing, everything is refused.
- **One PR at a time:** it holds a new loop branch while another loop PR is open and not parked. The hold is checked against the live API and fails closed.
- **Status files:** it writes a PR-status file the agent can read: state, the bot's last comment and the latest review **including its inline comments**. A review posted only as inline comments has an empty body, so a status built from the body alone hid a HIGH finding for hours. It also writes a `main.json` (main's SHA and the last 48 h of merges, with `written_at`) for the reports, because the courier is the only process holding the token.
- **Plumbing:**
  - the token is passed to git through a credential helper, never on a command line, where `/proc` exposes it;
  - every network call has a timeout;
  - state files record the last SHA acted on for each branch, so a stuck branch isn't retried or alerted on every minute;
  - a closed PR stays closed;
  - a refusal says why: a rejected push carries the code host's own reason (git's `! [...]` line and any `remote:` lines, token scrubbed) in the alert, and the full output in the log.
- Test it with a harness that runs the real script against a fake code host, plus one mutant per rule.
- **Edit it live only atomically:** write `courier.sh.new`, check it with `bash -n`, then `mv` it into place, keeping a dated backup. A half-written script ran once from its timer and failed mid-file.

#### 3. The review gate: CI decides what merges

- An LLM reviewer runs in CI on every non-draft PR. It must be hardened:
  - It never executes PR code. Its tools are read-only git, grep and the code-host CLI, and write operations and output redirection are denied.
  - Its prompt and its scripts are loaded from the **base** commit, never the head.
  - It starts in bare/minimal mode, so the checkout's own agent config and hooks don't load.
  - The verdict is parsed from the tool's JSON result held in memory, not from a file. The review must contain exactly one summary marker and exactly one verdict line, as the last line. Anything else counts as HOLD.
  - The merge job has its own write token. The reviewer's token is read-only.
  - The merge is pinned to the reviewed SHA.
- **Tiers:** a classifier and a path list, both read at the base commit, sort the PR's files, including the old names of renamed files.
  - **Tier 1** is an **allowlist** of packages with no execution, auth or credential code. It merges on one review.
  - **Tier 2** is everything else. It merges only when a **second, independent reviewer** also approves. That reviewer has its own prompt, read strictly from base, and is told not to read the first review.
  - Pin every Tier 2 module in both module form and package form (`x.py` and `x/**`), because a new package shadows a module.
  - Make every rule pinned by a test example that drops to Tier 1 without it.
- **HOLD** is reserved for what no review can supply: a new secret, spending money, or a vendor-portal action.
- **Fallbacks:**
  - If the reviewer's own comment is refused, the workflow posts the review text itself, minus the verdict line.
  - The test-gate waiter judges each check by its **latest** run, so re-runs and reopened PRs don't read as failures.
  - The merge step retries when the branch moved under it (a race between two merges), instead of failing the PR.
- **The operator session never comments on PRs as the human.** The code-host CLI posts in the human's name. Put context in the PR description, which the author writes anyway.

#### 4. The work model: what the agent works on

- **Unit of work:** a slice. It ends in a merged PR that changes behaviour, or in a spec PR that a later implementation PR satisfies.
- **One file per finding or deliverable** (`docs/work/<id>.md`), with front matter: kind, status, severity, surface, blocked-by, acceptance criteria with test IDs, and closure evidence.
- **Spec first:**
  - Acceptance tests land first, marked `xfail(strict=True, raises=AssertionError)`, and must fail by assertion.
  - The implementation PR may only remove those markers.
  - A spec can't be edited to fit the fix.
  - Concurrency, database and integration criteria are proven in the CI job that has a real database.
- **What interrupts current work:** only a new finding that is critical, on the money path, wrong data on a live read path, a live secret, or a red liveness check.
- **Legacy findings** get one slice in four.
- **Link work to the roadmap mechanically.** Each item in a version's order of work carries a stable ID (`[id: v0.6-slug]`, never renumbered). Each work file names the item it serves in front matter (`roadmap: v0.6-slug`, or `legacy` or `none`), and a CI test fails any work file whose value is missing or doesn't resolve. That makes "how much of this version is left" a count, not a guess.
- **Closure evidence:** a merged SHA. For a recurring process, also a dated runtime datum. If the path is switched off in production, the status says so (`closed-pending-runtime-verification`) rather than overclaiming.

#### 5. Rules and skills: how the agent works

- **A project instruction file of about 100 lines:**
  - the work model and the tiers;
  - test rules: tests execute behaviour, never assert on text, and must go red against broken code first;
  - anti-bloat rules: one current state section per doc, no dated banners, no per-finding plan docs, docs never growing faster than code;
  - "make judgment calls yourself and record why";
  - compaction instructions.
- **Procedures as skills:** `next` (pick work), `slice` (do it spec-first), `finding` (record a defect) and `ship` (rebase before the first push only, run the tier check, push).
- **A root-owned conduct file,** passed to each pass as a system prompt. Don't rely on user-level memory, which may not load.
- **Anything that must hold goes in settings, not prose.** The conduct file said "no AI attribution" and every commit still carried a `Co-Authored-By` trailer. The setting that controls it, `.claude/settings.json` `attribution`, takes **strings**: `{"commit": "", "pr": ""}`. `false` is ignored and the default trailer comes back. Prove it with a throwaway repo and the pass's own flags before trusting it.

#### 6. The driver loop: event-driven, fresh context every time

- **Not a schedule, and not a long-running session.** A small root daemon waits for an event on the loop's own PRs: a merge, a close, or a new review or comment. On an event it runs **one fresh headless pass**.
- **Each pass runs isolated:**
  - in its own transient service unit, with memory, CPU, time, nice and OOM-priority limits, `ProtectHome`, `PrivateTmp` and `NoNewPrivileges`;
  - as the agent user;
  - from an **empty home** created for the pass and deleted after it;
  - with a fresh clone checked out at the exact main SHA from the courier's trusted mirror;
  - with git's global config pointed at a root-owned file (hooks off);
  - with a fresh config dir, no MCP servers and project settings only;
  - with a long-lived login token from a root-only environment file.

  Nothing a pass writes can influence a later pass except through a reviewed PR.
- **Events:** one line per PR (number, state, and a hash of comment plus review). Snapshot it **before** the pass. A pass runs only for a line that wasn't there before, so a PR leaving the status window is never an event.
- **At most one open loop PR.** While one is open, a pass may only fix what its review found. With none open, it runs `next`.
- **Caps and outcomes, all enforced in the loop, not the prompt:**
  - passes per day, read each cycle from a root-owned config file. Needed only while the agent shares a subscription with the human; with a dedicated one (§9), set it out of reach and let the usage limit govern;
  - pass wall-clock and turn limits;
  - review rounds per PR: park the PR after N pushed fixes (passes that push nothing don't count);
  - stall: park an open PR with no event for N hours;
  - failures: backoff retry that doesn't need an event, no success pings while failing, and a CRITICAL alert on the third in a row;
  - usage limit: detected only from a failed pass's error output, then pause and recheck until it resets. Claude Code 2.x words it `You've hit your session limit · resets 3pm (…)` (also weekly). There is no machine-readable reset time in `-p` output, so recheck every 15 minutes: a blocked attempt fails immediately at no cost. Alert at most once a day for it, never once per recheck;
  - in-flight marker: a pass killed along with the loop counts as a failure and its events are restored;
  - a stopped pass keeps its events;
  - idle nudge: with no open PR, run a pass after N hours.
- **One fixed unit name** for passes, so systemd itself refuses a second concurrent pass. The pass is bound to the loop service, and orphans are stopped at loop start.
- **STOP file,** checked before and during a pass.
- **The loop is the only scheduler.** With no cap and nothing to do, it idles and runs an idle nudge every N hours. It doesn't exit when the roadmap is done; the human stops it.

#### 7. Observability: the human hears about problems, not progress

- **Liveness pings** (Healthchecks or similar) for every unattended job: the courier, the loop, the alert drain, backups and the disk watcher. Cron jobs report their **exit code**, so a failure reads as failed, not just late.
- **Push notifications** (ntfy or similar) for:
  - outbox patches;
  - refused branches;
  - parked PRs;
  - hit caps;
  - usage limits;
  - branches held too long;
  - repeated failures.

  Cap alert priority below "urgent", so the phone's Do Not Disturb still works at night.
- **Replace any LLM-driven alert delivery** with a deterministic drain script. An alerting path must not depend on a model session staying alive.
- **Keep each pass's transcript.** It's the only record of what an unattended agent actually ran.
- **A Reports page the human actually reads**, built by the operator, never by the loop. The loop is what the report describes, and it has no access to host state.
  - **Daily report.** Written at 00:10 UTC for the complete previous day by a root collector. It uses a least-privilege, read-only database role (SELECT on named tables, password held as a SCRAM verifier via `LoadCredential`) and fixed queries.
    - Every fact is tri-state (ok, bad or unknown), and unknown reads red, never zero.
    - Status (GREEN, AMBER or RED), the tripped checks and "needs you" come from **rules with measured thresholds**, accepted only after a replay of 30 days of history reads RED on exactly the known incident days.
    - Sections: what shipped (merges grouped by work file, titles sanitised and labelled as agent-written), roadmap progress by count per version, loop activity, and prod facts.
    - A redactor and then gitleaks run before an atomic publish. Reports are kept 30 days, pruned by filename date.
  - **Health snapshot every 5 minutes**, from a separate unit and process: every unattended job's last result, the app's `/health`, the alert-directory allowlist, disk use, and the last 7 days of phone alerts. The alert drain appends each delivery attempt to a history file (best-effort, never blocking delivery), rotated by logrotate.
  - **The page is read-only and opens on the newest report.** It shows a "no report since" banner over 26 h and a "snapshot stopped" banner over 15 min, computed by the page itself.
  - **An optional AI summary must be mechanically constrained.**
    - Its input is fact IDs, enums and numbers only, each with a **code-written label**. No agent-written text reaches it: titles, errors and front matter are injection paths, so validate any agent-written field against a strict pattern first.
    - Every sentence cites fact IDs, and every red or needs-you fact must be cited.
    - **Any number in a sentence must equal a value of a fact it cites.** Supply totals as facts, so the model never does arithmetic.
    - One retry, then facts-only. It costs about $0.04–0.13 a day.

#### 8. The human's role, deliberately small

- **Keeps:** the stop switch, spending money, provisioning secrets and infrastructure, and deciding on parked items, which is what parking exists to surface.
- **Gives up:** reviewing and merging. The two-key gate does that. The one-time bootstraps are the exception: a gate that removes the human's key has to be merged by that human once.
- **Escalation goes to the human's phone,** never to a named assistant session. A personal session exists only while it's open.
- **One-time human actions are named and batched:** buying the agent's subscription, approving browser logins (§9), setting up domain email, creating vendor OAuth apps, and running any command the operator session is refused (below).
- **The operator session's own guardrails will refuse some edits:** for example, removing an alert or changing a live control script on the host. Don't route around that. Hand the human the exact command to run with `!`, written to be safe as pasted. `set -e` plus `diff` exits on the first difference, so don't put `diff` before the `mv` it was meant to preview.

#### 9. Accounts and credentials: the agent is a separate identity

Give the system its own accounts from the start, so its usage, credentials and failures never mix with the human's.
- **A mail address on the project's domain.** Receive-only forwarding is enough: Cloudflare Email Routing, with the address forwarding to the human's inbox, no mail server. Gmail hides a message that loops back to its own sender, so test from another address, or read the routing activity log.
- **A dedicated AI subscription on that address.** The usage limit then belongs to the agent, which is what lets the loop run uncapped (§6).
- **Every login on the host belongs to that account:** the interactive login (Remote Control, which is visible only from the same account) and the headless token. Delete any of the human's credentials left on the host.
- **Log the host in without moving secrets.**
  - Run `claude /login` and `claude setup-token` **on the host** in a detached tmux, read the link with `capture-pane -J`, and have the human approve it in a private browser window signed into the agent account.
  - Send the one-time code back with `send-keys -l`, then a separate `Enter`.
  - Pipe the issued token straight from the pane into a root-only setter that rejects anything not shaped like a token, keeps a backup and swaps the file atomically. It never reaches a terminal, a clipboard or a chat.
- **Verify the account after every login.** The link is approved as whichever account the browser is signed into. Read `oauthAccount.organizationUuid` in the host's `~/.claude.json`, and make one real call with the token, with an empty home directory so nothing else can authenticate it.

---

## Part 2 — The rebuild roadmap

Each phase has an exit test. Don't start the next phase until it passes.

| Phase | Build | Exit test (run it, don't infer it) |
|---|---|---|
| 0 | Inventory the host: what runs, as whom, with what credentials | A written list of every process and credential. Nothing still running as an admin user. |
| 1 | Containment: agent user, firewall, no credentials | From the agent user: DB refused on every address, secrets unreadable, the app still reachable. |
| 2 | Courier plus harness | Harness green against a fake host, one mutant per rule. A live probe: a protected-path push goes to the outbox, a secret is refused, nothing unexpected reaches the host. |
| 3 | Review gate hardening | A PR whose code rewrites the verdict file can't produce MERGE. A quoted MERGE before a real HOLD gives HOLD. The prompt is loaded from base. |
| 4 | Tier classifier, allowlist, one-key/two-key merge | Replay against real past PRs. Every rule deletion reds the tests. A live Tier 2 PR gets held or double-reviewed. |
| 5 | Work model, rules file, skills | The agent runs `next` and reports its pick with evidence, and one forced compaction reopens the work file. |
| 6 | Observability: pings, push, deterministic alert drain | A test alert reaches the phone through the same path the jobs use. Each check shows up. |
| 6b | Agent identity (§9): domain mail, dedicated subscription, host logins, token | Host `organizationUuid` is the agent account's. A real call made with only the token succeeds. No owner credential remains on the host. |
| 7 | Driver loop | Suite green, with every control killed by a mutant. Live smoke as root: isolation read back from the unit, STOP kills a running pass, and **a loop restart mid-pass leaves exactly one pass**. The usage-limit classifier passes against the vendor's **current** limit message (read it from the installed CLI), and a test shows the old classifier failing it. |
| 7b | Reports page (§7) | The replay reads RED on exactly the incident days. Each check is mutated red. The page is checked in a browser against real host output in every state: normal, no summary, stale and missing. |
| 8 | Hand-over | The interactive session stands down (nothing uncommitted), the loop's first pass picks correctly, and the first PR merges through the gate. |

---

## Part 3 — Lessons learned

Each lesson cost something real to learn.

### Trust and enforcement

1. **Instructions don't bind; mechanisms do.** "One PR at a time" was prompt text until the courier enforced it. "Don't touch CI config" was a rule until the courier refused to push it. If a property matters, put it where the agent can't edit it.
2. **Agent consensus isn't a control.** Three model reviewers agreeing is still three things that can't be held responsible. The gate's authority comes from its mechanism (base-loaded prompt, pinned SHA, separate merge token), not from the reviewers.
3. **Root must never execute anything the agent can write.** A root loop with the agent's `~/.local/bin` on `PATH` is a root shell for the agent within a minute. Use a fixed system PATH, root-owned binaries, and nothing root reads or deletes that the agent can symlink.
4. **"Clean" state isn't clean if the agent owns part of it.** Git hooks, `~/.gitconfig`, fetch refspecs, dotfiles, MCP config and memory all survive `checkout` and `clean`. The only clean state is a new one: a fresh home and a fresh clone each pass, pinned to a SHA from a source the agent can't write.
5. **Path-based trust can't express a scattered critical path.** Code able to act on a production credential turned up in modules nobody listed as sensitive. Tier 1 must be an allowlist, and even then, anything sharing a process with a credential can reach it. The durable fix is a **process boundary**: credentials and the actions that use them live in a separate service, and the app can only propose.
6. **An in-process import boundary is whack-a-mole.** Three review rounds each found another route: a factory, a re-export, a Tier 2 module that imports the thing. The round cap parked it, which was correct. The lesson was to change the architecture, not write a fourth test.

### Review and testing

7. **Tests must be proven load-bearing.** Every control got a mutant that removes it, and the suite had to go red. Several survived at first: a test passing for the wrong reason (a timeout killed a pass before STOP could), and fixture data where two orderings coincided.
8. **A stub that returns pre-shaped output tests nothing.** Waiter tests fed fixed strings in place of `gh --jq` output, so the jq expression that had the bug was never executed. Feed the real format and let the real code parse it.
9. **Spec-first only works if the spec can't be satisfied by a wrong fix.** Reviewers repeatedly found acceptance tests that a racy or in-memory fix would pass. Cross-process guarantees need cross-process tests (separate interpreters and a real database), and every test needs a positive control so "refuse everything" doesn't pass.
10. **A reviewer's findings have to reach the author.** A deny rule on `>` silently blocked every review mentioning a comparison. Detect "the reviewer couldn't post" and post for it.
11. **Stop reviewing when findings stop being blocking, not after N rounds,** but keep a runaway guard. Real defects justify a new round. A new route around a fundamentally leaky design justifies parking and escalating.

### Unattended operation

12. **Fresh context per unit of work beats a long session.** No compaction, no drift, no accumulated persona. State lives on disk (work files, git, PRs), and every pass rebuilds it in seconds.
13. **Event-driven beats scheduled, and the review is the next event.** A merged PR triggers the next unit. A new review triggers the fix. Snapshot events *before* the pass, or anything arriving mid-pass is lost forever.
14. **Measure what changed, not what disappeared.** A 30-item status window meant a newly opened PR pushed an old one out, which read as an event. Wake only on genuinely new lines.
15. **Anything killed must be accounted for.** An OOM kill, a restart or a STOP must count as a failure and restore the events that pass consumed. Otherwise a PR waits forever for an event that already happened.
16. **Transient units outlive their parent.** A `systemd-run` pass isn't in the loop's cgroup, so restarting the loop orphaned it and started a second pass. Use one fixed unit name, bind it to the loop, and stop orphans at start. Verify by restarting mid-pass.
17. **A health check that pings green while stuck is worse than none.** Don't ping success while failing. Treat a stale input (the courier status file) as a failure, and park PRs that stall.
18. **Usage limits must be read from errors, not prose,** and from the vendor's *current* wording. The agent's own summaries talk about vendor rate limits, so only a *failed* pass's error channel can signal the subscription limit. The handler, written against an older message, would have counted the new one as a failure, and it was caught only by reading the strings in the installed CLI.
19. **Dollar estimates don't translate to a subscription.** What runs out is a usage allowance. While it's shared with the human, cap passes per day in a file the loop re-reads each cycle. Once the agent has its own subscription, drop the cap and let the limit pause the loop.
20. **Credentials for headless runs should be separate.** A copy of the interactive login would race its refresh flow against the interactive session. Use a long-lived headless token, generate it on the host, pipe it into place without displaying it, and verify it with a real call. Copying a token by hand is error-prone, and pasting it anywhere exposes it.

21. **A control that has never fired is untested.** The usage-limit handler never ran in production, because the daily cap always fired first. Before removing a guard, exercise whatever takes its place.
22. **State goes stale while the system is paused.** The loop's "open PR" marker is rewritten only by a pass, so while the loop was stopped the report kept naming a PR that had merged hours earlier. Cross-check with the source of truth (the courier's status).
23. **systemd blanks `ExecMainExitTimestamp` while a unit runs.** A freshness probe read a minutely timer as "never ran" about one time in six. A unit caught mid-run that started on time is current.
24. **A report written before the day's data lands must not call it missing.** Check the last target already due instead, and say it's deferred. Never skip the check, or an ongoing outage reads green.
25. **Use the scheduler's own calendar, never a copied holiday list.** A hard-coded list was right for one year and wrong forever after.
26. **Keep the alarm independent of what it watches.** The health snapshot imported the same module as the daily report, so one broken import would have silenced both. Prove it with a subprocess test that breaks the import.
27. **Edit live scripts atomically.** A timer that fires during a slow edit runs half a file.
28. **CI spend caps stop deploys silently.** When the code host's Actions budget ran out, merges kept landing and nothing deployed. Watch deploy lag, not just merges.
29. **One-off scripts that rewrite config are landmines.** Delete them, or quarantine them, once their job is done.
30. **An alert must carry the cause, not a guess at it.** The courier labelled every rejected push "non-fast-forward" because it matched only the word `rejected`. A fix branch that had never existed on the code host was reported that way, the real reason was never recorded, and a refusal is final for that commit, so the fix stalled with nothing to act on. Pass the tool's own error text through; a label is a claim and needs the same evidence as any other.

### Process and people

31. **Over-engineering is the default failure.** Every design got simpler under a simplifier with veto power, which pushed for one fixed unit name, no protocol markers, and a set-difference instead of hashes. Ask "what's the smallest mechanism that enforces this?" before adding a component.
32. **Research the field before designing.** The proven pattern (a fresh headless run per unit, state on disk, harness-enforced caps, work in progress limited to one) was already documented. Designing from scratch cost rounds.
33. **Independent reviewers need identical, fixed briefs.** The orchestrator shouldn't frame what it hopes to hear. Give every reviewer the same brief with only the role differing, a failure scenario required for anything blocking, and the previous round's findings listed so fixes get checked.
34. **Validate by driving the real thing.** Every serious defect was found by running it: the safe.directory refusal, the private `/tmp` hiding a marker, a stale status file, a counter file colliding with a directory name. None of them showed up by reading the code.
35. **Say who does what, precisely.** An assistant session isn't an operator. Escalation goes to the human's phone. One-time human actions (a merge that removes their key, a browser login, provisioning a secret) are named and batched.
36. **When the human says "don't ask me", build the thing that makes asking unnecessary.** Decisions move to the agents with a recorded rationale. The human keeps the stop switch, spending money and parked items.

---

## Part 4 — Checklist before going unattended

- [ ] The agent has no credential it doesn't need. Each denial proven from its side.
- [ ] Every write path to production passes through a gate the agent can't edit.
- [ ] Every cap, limit and rule lives in the harness, and a mutant proves each one.
- [ ] Nothing root executes or deletes is agent-writable.
- [ ] Each unit of work starts from state the agent couldn't have prepared.
- [ ] A restart, OOM, reboot and STOP have each been done live, and each leaves the system consistent.
- [ ] Every unattended job pings liveness, reports failure distinctly, and alerts a phone.
- [ ] Health can't read green while the system is stuck.
- [ ] The human's remaining actions are written down, and none are needed for normal operation.
- [ ] Transcripts of every unattended run are kept.
- [ ] The agent runs on its own account and subscription, and no owner credential is on the host.
- [ ] The usage-limit handler matches the vendor's current message, and the loop resumes on its own after the reset.
- [ ] The human has a Reports page that says, without being asked, whether today was fine.
- [ ] Settings that must hold (attribution, hooks, permissions) are proven with a throwaway run, not trusted from prose.

## Part 5 — Known gaps (be honest about them)

- **Shared process with a credential:** until the credential lives in its own process, any code the gate lets through on one review can reach it. Two-key review lowers the risk; it doesn't remove it.
- **Two keys from the same model:** they're two independent reads, not two independent minds. Prefer different prompts, and different models where possible.
- **Branch naming by prompt:** a pass that ignores its branch prefix creates an untracked PR. It's still reviewed, and bounded by the daily cap.
- **Egress:** a pass can reach the internet, so a hijacked pass could exfiltrate its token. Consider an egress allowlist.
- **Usage visibility:** a headless token may not be able to read the subscription's usage percentage. The human reads it with `/usage` while signed into the agent account.
- **Version the host scripts.** In the reference system, `loop.sh`, `pass.sh` and `courier.sh` lived only on the host, so a disk loss would have erased them. Keep them in the project repo with an installer from day one.
- **The usage-limit pause had not yet been exercised live** in the reference system when this was written. Check its first real occurrence in the loop's log.
