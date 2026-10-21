# Foundations of an Autonomous Development System

A blueprint for an AI coding agent that works a real codebase continuously, merges its own reviewed changes and deploys them, with no human in the loop. It is distilled from building one end to end on a production host in late 2026, and from running it unattended. Nothing here is specific to that project. Where a concrete tool is named, it is what was used and proved, not the only option.

**Start a new project from here.** Read Parts 1 and 2. Then copy `kit/` (the host-side scripts and units), build the repo-side pieces listed in `kit/README.md`, and follow the rebuild roadmap phase by phase. Last updated 2026-10-07.

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
                                              (optional §10: the test and review
                                               jobs run on your own runner
                                               machines; merge and deploy never do)
                                     │
                                     └── the review/merge is the next event
            Alerts: liveness pings + push notifications to the human's phone
            Reports page: daily report + 5-min health snapshot + alert history,
                          written by root jobs the agent can't touch
```

### The nine components, and one optional one

Build the nine in this order. Each one is useless or dangerous without the ones before it. The tenth, running CI on your own machines, saves money and is not required: the system is complete without it.

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
  - a PR the owner closed stays closed;
  - commits that land after a PR **merged** are not dropped: they go out as a follow-up branch (`<branch>-late`) through every check, with their own PR, and the follow-up branch is written to the local repo so the agent can keep working on it;
  - **a branch whose tree equals its base is dropped, not forwarded.** A merged head with nothing after it, or commits that change no file, would open a PR that lists no files. The gate cannot classify that, and the loop waits on it until the stall timer. Compare the two trees, not the commit lists, so commits that cancel out are caught too;
  - a refusal says why: a rejected push carries the code host's own reason (git's `! [...]` line and any `remote:` lines, token scrubbed) in the alert, and the full output in the log;
  - **the code host's own faults are retried, not refused.** A server error on a push comes back from git as `! [remote rejected] … (Internal Server Error)`. Only a rejection whose reason is not a server fault is final; the rest are tried again on the next run without an alert.
- Test it with a harness that runs the real script against a fake code host, plus one mutant per rule. Feed it the error text the code host really sent, saved from the incident, and include a branch that only changes which runner a CI job uses: it must end in the outbox (§10).
- **Keep the harness in the repo next to the script.** In the reference system it first lived in a scratch directory, outside version control. It is now in `kit/tests/`, with a script that breaks the courier one rule at a time and fails unless the harness notices.
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
- **What interrupts current work:** only a new finding that can happen in production as it is configured today, and that is critical, on the money path, wrong data on a live read path, a live secret, or a red liveness check.
  - Every finding states its reach: `live` (names the production entry point and the setting, checked by CI against the real configuration) or `dormant` (names the one switch that closes every route to it).
  - A dormant finding is real and waits its turn. CI refuses a change that turns its switch on while it is open.
  - A defect in a check that keeps a switch off is live, because the check runs today.
- **The picker shares time.** Critical findings go first. After two interrupts in a row it tries roadmap and queued work before a third. Ordinary open findings and legacy findings get one slice in four, skipping anything blocked. Define "closed" and "oldest" so a fresh pass computes them from files alone.
- **Noticing is not doing.** A defect noticed during a slice is filed and left for the picker; it is never specced in the same PR. One finding per missing check, not one per argument or call site. A defect caused by a fix from the last week reopens that fix's finding.
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
  - idle nudge: with no open PR, run a pass after N hours. This is also the only thing that notices work filed by anyone other than the loop, so its length is the longest an operator-filed item can wait (lesson 60).
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
- **Watch the pipeline after the merge, not just the merge.** Three things read as "fine" from the PR list and are not:
  - a CI job that was **refused a start** (an exhausted CI budget refuses jobs; it doesn't queue them);
  - a change to main with **no completed deploy** some minutes later;
  - a job **waiting for a runner** longer than a set time.

  One alert per incident for each, cleared when the condition clears, and the marker written only when the alert was actually sent, so a failed send is retried.
- **Watch what a job produced, not whether it exited 0.** A scan ran green every day and confirmed nothing for days, because an upstream data feed had stopped returning one field. Report on outputs (rows written, signals produced, last successful fetch per feed), and give each external feed its own check.
- **Match severity to how soon someone must act.** A credential expiring in two days is a warning; red is for one day or less. A rule that pages on any failed run that day pages for a failure that was already retried and fixed: judge a day by its **last finished run**.
- **One named alert may be urgent.** Everything stays below "urgent" except the few conditions the human has said should wake them. Give the drain a narrow rule for those (right queue, written by root, naming that one check) and test that nothing else can reach that priority.
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
- **Those refusals are judgements, not fixed rules.** The same command can run one day and be refused the next, and saying "yes" in the conversation does not unlock it. When the human is remote and cannot paste a command, the answer is a single narrow allow rule for that one command, added on the human's explicit instruction and never on the session's own initiative. The limits that matter (a spending cap, a kill switch) must live in the tool being run, so the rule only skips the prompt.

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

#### 10. Optional: CI on your own machines

**Not required.** Everything above works on the code host's metered runners. This is about money: in the reference system the test and review jobs used about 1,700 billed minutes a day, and when the account's spending limit ran out every job was refused, so nothing was reviewed, merged or deployed until a human raised it. Two small rented machines run the same jobs for a fixed monthly price, and jobs on your own runners are not billed. Do this once the bill or the budget ceiling is the thing in your way, not before.

- **What moves and what never does.** Test jobs and the review jobs move. **Deploy stays hosted** (it holds every production secret) and **merge stays hosted** (it holds the only write token and runs for seconds). Pin every job's machine in one test, as a whole table, with a second assertion that deploy and merge are hosted. Then moving a job is a deliberate edit and pointing deploy at your own machine is a red test.
- **Two machines, neither the production host, neither on its private network.**
  - A **test machine** runs pull-request code. It holds no credential between jobs.
  - A **gate machine** runs the review jobs and holds the one code-host credential used to register runners. It refuses every inbound connection from the test machine.
- **A slot is one unprivileged user, one rootless container daemon and one systemd unit,** with a private `/tmp`. There is no rootful container daemon and nobody is in its group. The unit's life is one job:
  1. root wipes the slot, then waits for a single-use runner config in a root-only directory;
  2. root builds the slot's home afresh and hands the config over;
  3. the slot's user starts its daemon and one runner, which takes exactly one job and exits;
  4. root wipes the slot again.
- **The wipe covers the uid and its subordinate id range.** A rootless container daemon stores layers and container files under the subordinate range, not the user's uid. Kill every process and delete every file owned by either, on every writable filesystem, and remove the daemon's data directory by path.
- **Single-use runner configs only.** No runner registration persists. The gate machine asks the code host for one config per slot and delivers it: locally into the drop directory, or to the test machine over SSH with a key whose **only** permitted command there receives a config. Port forwarding, a shell and any other command are refused, and the test machine cannot open a connection back.
- **Nothing secret on a command line.** Slots on one machine can read each other's process arguments (hiding them breaks the runner, below). The registration token and the runner configs travel on stdin, in files and in the environment.
- **A per-minute monitor on the gate machine** keeps a runner registered per slot, removes registrations that never came online, raises the three pipeline alerts from §7 plus disk and "a newer runner has been released", and pings liveness only when every label has a runner online. If the gate machine dies, the missing ping is the alarm.
- **Prove it with two probes before moving any job.**
  - A **job-side probe** runs on every slot of a machine at the same time. It fails if the job is root, can use sudo or cron, can see a container socket other than its own, can read the other slot's home, temp files or process environments, or cannot reach its own container on localhost. The second slot waits for the first to be wiped and checks its own files and container survived.
  - A **root-side probe** fails if any process or file owned by a slot's ids exists anywhere while the slot is idle. Plant a file and a process under a subordinate id and watch it fail.
- **Time the real jobs before moving them,** side by side, on the commit a hosted run just tested, and compare the counts (passed, skipped, assertions), not just green. Identical counts are the evidence that nothing was silently skipped.
- **Order:** build and probe both machines on a throwaway branch, move the test jobs, watch a day, then move the review jobs. Going back is one commit.

**What it cost in the reference system, so you can decide:** under twenty dollars a month for both machines, against a metered bill that had passed ten dollars a day; test jobs about 1.5 times slower per job on cheap shared cores; one job of each kind at a time, so a busy hour queues.

**What bit, all found by running it:**
- A rootless daemon with no per-user service manager picks a cgroup driver that has no slice to use, and every container fails to start. Start it with the plain cgroupfs driver.
- Hiding other users' processes from a slot (`ProtectProc=invisible`) hides PID 1 too, and the runner reads `/proc/1/cgroup` to set up service containers. That is why nothing secret may be an argument.
- The hosted image is an undeclared dependency. Tests shelled out to a linter and a database client that the hosted image happens to carry; on a bare machine they failed. List the tools, install them, and have the probe check for each.
- The registration token could not read what the monitor was first written against. It had the two permissions the design fixed and no more, so "what is main's head?" answered 403. Read the change from what the token can read (a succeeded merge job, a deploy run created for main) rather than widen the token.
- Runs for main queue behind each other, so the deploy of an older merge can start after a newer merge. Judge "was this change deployed" by the run **created for it**, never by which deploy started later.
- A pull request can change which runner a job uses, because the workflow file comes from the PR head and a label is not a boundary. The control is the courier refusing every change to CI config (§2).
- Once a monitor hands a slot its next runner within seconds, a slot is never idle, so the root-side probe needs the monitor stopped first.
- **A security update must not reboot a machine under a running job.** A killed test job fails its PR or stalls a deploy, and nothing re-runs it. Let the updater install but not reboot. At a fixed time a root script checks for a pending reboot and drains first: no slot is handed a new runner, idle slots are stopped, running jobs finish, then it reboots. It can't be starved, because nothing new starts during a drain and every job has a time limit; cap the wait anyway. A job that arrives meanwhile waits in the code host's queue.
- The monitor has to allow for that drain, or every planned reboot pages the human: a draining machine's labels are not an outage for a bounded time, and "the other machine did not answer" is reported after minutes of silence, not after one miss.
- The code host refuses to delete a runner registration it still thinks is in a session, for about a minute after a listener is stopped. A refused delete must be logged and skipped, not allowed to end the cycle before replacements are issued.

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
| 9 (optional) | CI on your own machines (§10), only if the metered bill or its ceiling is in the way | Both probes green on real jobs, and the root-side probe red against planted leftovers. The real test jobs green side by side with counts identical to a hosted run of the same commit. From the test machine, the gate machine's SSH port times out. The monitor's alerts replayed over real past records fire on the known incidents and nowhere else. |

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
28. **CI spend caps stop deploys silently.** When the code host's Actions budget ran out, merges kept landing and nothing deployed. Watch deploy lag, not just merges. Moving the heavy jobs to your own machines (§10) removes most of the bill; it does not remove the need for the alert, because deploy and merge stay metered.
29. **One-off scripts that rewrite config are landmines.** Delete them, or quarantine them, once their job is done.
30. **An alert must carry the cause, not a guess at it.** The courier labelled every rejected push "non-fast-forward" because it matched only the word `rejected`. A fix branch that had never existed on the code host was reported that way, the real reason was never recorded, and a refusal is final for that commit, so the fix stalled with nothing to act on. Pass the tool's own error text through; a label is a claim and needs the same evidence as any other.
31. **A merge can land while the author is still working.** The gate merges the head it reviewed; an agent that keeps polishing pushes a commit seconds later, and a courier that refuses a merged PR drops it. Holding the branch until the pass ends looked like the fix and was wrong: the agent iterates with the reviewer inside one pass, so it would have waited for a PR that never appears. Read how a pass actually runs before adding a hold. What works is to forward late commits as a follow-up PR, and to tell "merged" apart from "closed by the owner", which still stays closed.

### Process and people

32. **Over-engineering is the default failure.** Every design got simpler under a simplifier with veto power, which pushed for one fixed unit name, no protocol markers, and a set-difference instead of hashes. Ask "what's the smallest mechanism that enforces this?" before adding a component.
33. **Research the field before designing.** The proven pattern (a fresh headless run per unit, state on disk, harness-enforced caps, work in progress limited to one) was already documented. Designing from scratch cost rounds.
34. **Independent reviewers need identical, fixed briefs.** The orchestrator shouldn't frame what it hopes to hear. Give every reviewer the same brief with only the role differing, a failure scenario required for anything blocking, and the previous round's findings listed so fixes get checked.
35. **Validate by driving the real thing.** Every serious defect was found by running it: the safe.directory refusal, the private `/tmp` hiding a marker, a stale status file, a counter file colliding with a directory name. None of them showed up by reading the code.
36. **Say who does what, precisely.** An assistant session isn't an operator. Escalation goes to the human's phone. One-time human actions (a merge that removes their key, a browser login, provisioning a secret) are named and batched.
37. **When the human says "don't ask me", build the thing that makes asking unnecessary.** Decisions move to the agents with a recorded rationale. The human keeps the stop switch, spending money and parked items.
38. **A code host reports its own failures in the same words as a refusal.** A push that hit the host's server error came back as "remote rejected", and a courier that treated the word as final marked the branch handled and never forwarded it. The work sat for two hours with one alert that read like a policy decision. Classify by the reason, retry the host's faults, and test with the real error text.

### From the first weeks unattended

39. **A green run that produced nothing is an outage.** A daily scan exited 0 and confirmed nothing for days: a vendor's free tier had stopped returning one calendar field, and every candidate was refused as "cannot be checked". The job, its liveness ping and the report were all green. Alert on what a job produced.
40. **Take public facts from whoever publishes them, and check their shape.** The missing field was a public calendar. It now comes from the publishers' own pages and feeds, with a check on the shape of what was parsed (the expected number of entries per year, no gap longer than the known maximum). A page redesign then fails loudly instead of yielding a short list. Plan for the day the source hasn't published next year yet, and decide beforehand how loud that should be.
41. **A constraint that exists only in the production database is tested only in production.** The in-memory test database had no check constraints, so a row the real database rejects passed every test and failed on the first live run. Put anything that touches a constraint in the CI job with the real database engine.
42. **A check that runs only after the merge fails where nobody is looking.** A bookkeeping job that runs on main, and doesn't block deploy, was red for hours after a PR left a pinned count one short. Either run its strict arm on the PR, or alert on it. A red run nobody is told about is decoration.
43. **Find out what a credential can read before building on an endpoint.** The monitor's first version asked for the head commit with a token that could not read commits. It was caught only by calling each endpoint with the real token and reading the status codes. A test now fails if the script calls anything outside what the token is scoped to.
44. **Tie an effect to the cause it was for.** "A deploy started after the merge" is not "the merge was deployed" when runs queue. The same mistake, in another form, is judging a day by any failed run rather than its last one.
45. **Replay a new alert over real history before trusting it.** Each rule was run against the code host's actual records at moments before, during and after two real incidents, and swept across a normal period. That found the rule above, and it is what turns a threshold from a guess into a measurement.
46. **Two writers that both allocate identifiers will collide.** The operator and the loop each picked "the next free number" for a work file and twice chose the same one. Allocate from one place, or make the collision a failed check rather than a silent overwrite.
47. **A new probe's failures are a mix of its own bugs and real ones.** The isolation probe's first red was its own (a file search that exits non-zero on a denied directory, with no message). The next two were real: containers that could not start, and a setting that broke service containers. Give the probe a trap that names the failing line, and read each failure before deciding which kind it is.
48. **A fixture has to be the size of the real thing.** The monitor's tests fed it API answers of a few dozen bytes. The real answers are hundreds of kilobytes; the script passed one as a command argument, and the operating system refused once it grew past the per-argument limit. Every cycle then died after doing its first job and before sending its heartbeat. Twenty-nine mutants had all gone red, because mutation testing shows the tests notice the code changing and says nothing about inputs they never supply. Ask what the real payload looks like before writing the fake.
49. **Give every remote call a test in which it fails.** No test ever made a fetch fail, so a path where a failed fetch read as "nothing found" shipped, and the heartbeat was still sent for a minute in which nothing had been checked. In a shell, a command substitution does not inherit exit-on-error: say `|| return 1` at each fallible step and call the function as a plain assignment.
50. **The silence alarm earns its keep.** The monitor pings liveness only after every check has run. When it crashed, nothing in it could have alerted; the missing ping did, within its grace period. Put the heartbeat last, behind everything it vouches for.
51. **Your own maintenance is the most common cause of a page.** A planned one-minute reboot paged the human, who had to ask what it was. Before taking down anything a monitor watches, say so and name the alert that may fire; better, make a planned outage of that length not fire it.
52. **Clear out what you created, and look before you do.** Throwaway branches held the only copy of a workflow the rebuild procedure depends on. It was found by reading what each branch contained that the main branch did not, immediately before deleting it.
53. **Ask whether the defect can happen, before asking how bad it would be.** The interrupt rule said "on the money path" and nothing about whether the path could run. With the product's risky actions switched off behind three gates, the agent spent four days fixing defects in code that could not execute: of 32 findings, 5 were reachable, 14 sat behind a switch that was off, 10 needed an input nothing could produce, and 3 were its own fixes from hours earlier. None was invented; the ranking was wrong.
54. **An agent that files its own work will chain it.** Each fix PR also specced the defect found beside it, flagged urgent, so the picker always had an interrupt and the roadmap never got a turn. One missing validation block became five findings, an argument at a time. Separate noticing from doing, bound each run to one outcome, and cap self-raised urgency.
55. **A healthy report can hide a stopped roadmap.** Merges, jobs and data were all green while the in-flight version stood still for a week on steps only an operator could run. Report roadmap movement as its own check: no merge on the in-flight version that day, or no new high in finished items for several reports, is red and pages. Use a high-water mark so reopening and re-closing work cannot reset it.
56. **Every picking rule needs a mechanism a fresh pass can compute.** A first draft of the rules above had a cap that could not be evaluated (sixteen files shared one closing date), a queue a blocked item could jam, and a "reopen" with no stated status. Each read fine and none worked. Walk the procedure through concrete states before shipping it.
57. **A pull request that conflicts makes no noise.** The code host runs no checks on it, so a loop that waits for a check or a review waits for nothing until its stall timer fires; hours go by. It happens whenever two authors claim the next work number. Have the courier record whether each PR is mergeable; when the loop's open PR conflicts, set it aside at once and tell the next pass to rebuild its work on a new branch, saying explicitly that the work is not dropped (a pass told only that a branch was "set aside" silently abandoned a finding). And do not file work by hand while the loop is mid-pass.
58. **Operator steps need an owner and a trigger.** Work that ends in "run this against production" was assigned to an operator session that nobody was assigned to start. Record owed operator steps where the report can list them.

### From the first operator-run jobs

59. **A pull request with nothing in it stalls everything behind it.** The courier forwarded commits that landed after a merge even when they changed no file. The empty PR could not be classified, got no review, and held the one-PR-at-a-time slot until the stall timer parked it, twice in a day, for hours each time. Anything that opens work automatically must first check there is work in it.
60. **A loop that wakes on its own events is deaf to everyone else's.** Four defects filed by the operator merged and sat for hours, because a merge of someone else's PR is not an event and the idle nudge had just fired. If other authors can add to the queue, either wake on the queue changing or accept the idle period as the response time, and say which.
61. **Where importance is not a field, order is the priority.** The urgent defect did not meet the interrupt rule, so the picker would have taken it last, by number. It went first only because it was given the lowest number. Know the picker's tie-break before filing several items at once, and file in the order you want them done.
62. **The operator's pull requests need the same watching as the agent's.** Two operator PRs sat red for hours on a rule the loop had added the day before. Nothing alerted, because every status file and alert was scoped to the loop's branches. A red check on any open PR is worth one line in the report.
63. **A test the gate cannot run is not a gate; it is an operator step.** One suite needs a data set only the operator's machine holds, so CI skips it. The loop fixed the defect it covers without being able to run it, and left its expected-failure marker in place. Name who runs every skipped suite and when, and treat "green" from a skip as no information.
64. **An expected-failure marker hides whatever fails first.** A marker that accepts an assertion error also accepts the test's own precondition failing, so a vacuous fixture reads the same as the defect. Make preconditions a hard failure of a different kind, and run the test once with the marker off to see the real error.
65. **Test with what the real caller sends, including the defaults it makes explicit.** The production launcher always passed a settings object, filled with default values. Every test passed none. The two paths diverged only when the object was present, so the suite was green and the first real run crashed after most of its cost was spent. Build at least one test through the real entry point.
66. **Buy the cheap run first.** A reduced-size run of a paid job found that crash for about a tenth of the full price, and gave measured phase times to size the real cap from. It also showed that fixing only the visible symptom would have turned a crash into a wrong answer, which no amount of reading had.
67. **A watchdog must ask whether the thing it watches is still alive.** The kill switch for paid jobs ended its watch on a result, a stall or the spending cap. A job that crashed produced none of those, so the watchdog reported "ok", kept counting money from the clock, and held the only run slot for two more hours. Ask the platform for the job's state on every tick; an unreadable state changes nothing.
68. **A wait must be longer than the period of what it waits for.** The launcher gave the watchdog one minute to confirm and then cancelled; the watchdog ticked every five. A launch worked only when it happened to start just before a tick. Derive the wait from the period, in code, so changing one changes the other.
69. **A spend estimate built from wall-clock time is not the bill.** The watchdog multiplied elapsed time by a deliberately high rate, which is right for a cap and wrong as a record: it showed four times the real cost of a job that had already stopped. Keep the conservative figure for the limit and reconcile against the billed line before quoting a cost.
70. **A cache keyed on its inputs serves old answers after the rules change.** A stored intermediate result was keyed on the job's parameters and data, not on the code that computed it, so a run under rewritten rules would have loaded results the old rules produced. Put the identity of the producing code in the key, and list every module that shapes the output, not just the obvious ones.
71. **A failed run's name is used up.** A retry under the same name was refused by the guard that stops two runs mixing their checkpoints, after paying for the start-up. That guard was right. Give every attempt a fresh name, or decide deliberately to clear the old state.
72. **Check that the data exists before scoping work that needs it.** A roadmap item assumed fifteen years of an event history; production held five months, and the job that could backfill it covered a fraction of the names. One read-only count answered it in a minute, after the code had been built.
73. **The agent executes the roadmap's words; the human should see the bill first.** "Record a result for each of five variants" became five full-price runs, when one proved the machinery and reduced runs exercised the rest for a quarter of the cost. Before the first paid step, put the plan to the human as what each dollar buys, and offer the cheaper plan that answers the same questions.
74. **A fix needs evidence from after it shipped.** Two of the fixes above were confirmed within a day by the next real run: the launch armed first time, and the watchdog named the crash and released the slot in one tick. Until then they were closed "pending runtime evidence", which is the honest status for anything that only production can exercise.
75. **Every tool the validation step needs must be root-installed on the fixed PATH.** The pass PATH holds only root-owned directories, which is right. The runbook then told each pass to install the package manager into its own home, which is never on that PATH, so no pass could run the tests. Passes reported the tool unreachable and merged on CI alone for two weeks, skipping the proof that a new test goes red first, and nothing alerted, because a pass that cannot run tests still ends "ok". Install every such tool root-owned and pinned, prove it from a pass-shaped shell (the agent user, the fixed PATH, an empty home, a fresh clone), and grep pass logs for "command not found".
76. **Inventory every model session against the account that pays for it.** The loop ran on the subscription; the reviewer in CI ran on the metered API key with the CLI's default, largest model, about nine hundred runs a month at several minutes each. The bill surfaced it, not any alert. List every place a model is invoked, the credential it holds and the model it defaults to; put every agent session on the subscription token; set a spend cap on the metered account so the next mistake is bounded.
77. **Keep the record of a reviewer that gave up.** When the second reviewer began failing in seconds, the workflow had kept only its final text, and the runner wiped its home after every job, so nothing said which call was refused. Five of six second reviews died this way before the cause could be read. Save the harness's own record of the run beside the verdict: turn count, duration, and every refused tool call with its arguments. The first run that kept them named the cause.
78. **The text a refusal hands the model decides whether it recovers.** The reviewer ran in the mode that refuses anything outside its allow list instead of prompting, which is right unattended. That mode's refusal text told the model to stop and explain, and it did, after one refused call. The ordinary mode refuses the same calls headless, because no prompt can be shown, but names the reason, and the model reissued an allowed shape. Measured: seven write attempts refused under each mode, nothing written, and the real prompt went from refusals in two of three runs to none. Before choosing a sandbox mode, read what it tells the model on a refusal, not only what it refuses.
79. **Telling the model which command shapes are allowed did not stop it composing others.** A rewritten prompt listed the exact one-per-call shapes and the known refusal triggers. The next run still opened with a chain beginning with a directory change, which the harness cannot resolve statically once a read-deny rule exists. The prompt change cost a day; the mode change above fixed it in one run. Where a harness and an instruction disagree, change the harness.
80. **A gate fix is reviewed by the gate it fixes, and a re-run never picks up the fix.** The gate's workflow and its second-review prompt are read from the default branch on purpose, so a PR cannot supply its own reviewer. That means the PR repairing the reviewer must pass the broken one, and a re-run of an existing gate run reuses the default-branch commit it started from, so merging the fix changes nothing for PRs already in flight. Fire a fresh gate event for each of them, and budget for the repair PR to need the operator's hand if the broken reviewer cannot pass it.
81. **A parked PR that later conflicts is stranded, and a merge race can create that conflict.** Two approved PRs merged seconds apart; the loser was refused, retried as designed, and by then conflicted with the winner, which no retry fixes. The loop's rebuild path for conflicting PRs skipped it because an earlier stall had parked it. Let the rebuild path consider parked PRs too, or unpark on a review event, and treat "refused for a moved base" followed by a conflict as a rebuild, not a retry.

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
- [ ] A refused CI start, a change to main with no deploy, and a job stuck waiting for a runner each alert a phone.
- [ ] Every job reports what it produced, and each external data feed has its own check.
- [ ] If CI runs on your own machines (§10): both probes pass, deploy and merge are pinned to hosted runners by a test, no secret appears in any process's arguments, and a machine reboots only when idle.
- [ ] Every remote call a monitor makes has a test in which it fails, and its fixtures are as large as the real answers.
- [ ] Every suite CI skips has a named runner and a trigger, and at least one test goes through the real entry point with the arguments it really sends.
- [ ] Every paid job has a watchdog that checks the job is still running, a wait longer than the watchdog's period, a reduced-size run before the full one, and a cost reconciled against the bill.
- [ ] Work filed by someone other than the loop has a known longest wait, and a red check on anyone's open PR is reported.

## Part 5 — Known gaps (be honest about them)

- **Shared process with a credential:** until the credential lives in its own process, any code the gate lets through on one review can reach it. Two-key review lowers the risk; it doesn't remove it.
- **Two keys from the same model:** they're two independent reads, not two independent minds. Prefer different prompts, and different models where possible.
- **Branch naming by prompt:** a pass that ignores its branch prefix creates an untracked PR. It's still reviewed, and bounded by the daily cap.
- **Egress:** a pass can reach the internet, so a hijacked pass could exfiltrate its token. Consider an egress allowlist.
- **Usage visibility:** a headless token may not be able to read the subscription's usage percentage. The human reads it with `/usage` while signed into the agent account.
- **Version the host scripts.** In the reference system, `loop.sh`, `pass.sh` and `courier.sh` lived only on the host, so a disk loss would have erased them. Keep them in the project repo with an installer from day one.
- **Own runners (§10), if you use them:** two slots on one machine share `/dev/shm` and can read each other's process arguments; one job of each kind runs at a time, so throughput is bounded by the slowest job; the alert thresholds were set from one day of traffic and should be re-measured after a busy week; the drain-before-reboot path has only been exercised with idle slots.
- **A conflicting pull request leaves an open PR behind** (lesson 57): the loop rebuilds the work on a new branch, but nothing closes the old PR. The parking alert asks the human to.
- **A `live` label can be wrong.** The entry point a finding names is free text; only the setting is checked. The interrupt cap bounds the damage.
- **The loop does not wake for work it did not file** (lesson 60). In the reference system an operator-filed item waits up to one idle period; nothing shortens that yet.
- **Operator pull requests are unwatched** (lesson 62): status files and alerts cover only the loop's branches.
- **Transient retries are silent.** A push that keeps hitting a code-host fault is retried every minute with no alert. Add a count and alert past a limit.
- **The usage-limit pause had not yet been exercised live** in the reference system when this was written. Check its first real occurrence in the loop's log.
