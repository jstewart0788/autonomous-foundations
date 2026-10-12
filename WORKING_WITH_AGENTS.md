# Working with agents

Practices for running AI agents on a real project, including agents that direct and review other
agents. Each one was learned by running a system unattended; `FOUNDATIONS.md` has the full design
and the incident behind each point.

## 1. Enforce with mechanisms, not instructions

- An instruction is a request. If a property matters, put it where the agent cannot edit it: a
  permission, a setting, a CI check, a script it does not own.
- Prove every control by breaking it on purpose and watching something go red.
- Give the agent no credential it does not need, and prove each denial from the agent's side.
- Agreement between agents is not a control. Three reviewers that agree still cannot be held
  responsible; the gate's authority comes from how it is built.

## 2. Keep sessions short and state on disk

- One fresh session per unit of work. No long-running session, no accumulated context, no drift.
- Everything a later session needs lives in files: a work item, the repository, the pull request.
  A new session should rebuild its picture in seconds from those alone.
- Start each session from state the previous one could not have prepared: a clean checkout at a
  known commit, an empty home directory.
- Drive sessions by events (a merge, a review), not a clock. The review of one unit is the trigger
  for the next.

## 3. Skills for procedures, a short file for rules

- Keep the project instruction file to about a hundred lines: what the work is, how it is tested,
  what needs a second review, and "make judgment calls yourself and record why".
- Put each repeated procedure in a skill the agent invokes by name: pick the next work, do one
  unit, record a defect, ship. A skill is loaded when needed and can be tested and versioned; a
  long prompt is paid for on every turn and quietly ignored.
- Every rule has to be something a fresh session can compute from files. "Take the oldest open
  item" needs a definition of oldest.
- Prefer deleting something to adding a rule about it.

## 4. Define the unit of work

- One file per deliverable or defect, with acceptance criteria that name the tests proving them.
- Tests first, in their own change, failing for the right reason. The implementation may only make
  them pass; it may not edit them.
- One unit in progress at a time. A second open change waits.
- Noticing is not doing. A defect seen mid-task is written down and left for the picker.
- Rank a defect by whether it can happen today before ranking by how bad it would be.
- Where importance is not a field, filing order is the priority. Know the picker's tie-break.

## 5. Agents managing agents

This section is for the agent in charge of other agents. What the human hands over and keeps is
in section 7; the principle is the same at both levels.

- Delegate the volume, keep the judgment. Searches, mechanical edits, independent units of work
  and second opinions go to sub-agents. Decisions, and work that depends on context built up over
  the task, stay with the agent in charge: a handoff loses detail in both directions.
- Brief every sub-agent like a peer: the goal, what is already ruled out, the files to read, a
  narrow scope. If you cannot write that brief, you do not understand the task yet.
- Give reviewers identical briefs that differ only in role. Never tell a reviewer what you hope to
  hear, and do not show the second reviewer the first one's verdict.
- A reviewer never runs the code under review, and its own instructions come from the trusted
  branch, not the change.
- Treat findings as candidates: confirm each against the code before acting. One dissent blocks.
- Parallel agents get separate working copies from the same commit and return a diff. Apply the
  diffs one at a time, then re-check the combination.
- Cap the rounds. Stop when findings stop being blocking; when each round finds a new route around
  the same design, change the design.

## 6. Verify by running the real thing

- A clean build and a passing suite are not validation. Exercise the changed behaviour.
- Test with what the real caller sends, including defaults it makes explicit. At least one test
  goes through the real entry point.
- A stub that returns pre-shaped output tests nothing. Feed the real format, at the real size.
- A suite the gate cannot run is a human step. Name who runs it and when.
- A fix is closed when evidence exists from after it shipped. Until then, say "pending".

## 7. Watch outcomes, and keep the human small

- Report what a job produced, not that it exited zero. A green run that produced nothing is an
  outage.
- Health must not read green while the system is stuck. Put the heartbeat after everything it
  vouches for.
- Alert the human about problems, never progress. One alert per incident, carrying the cause.
- The human keeps the stop switch, money, secrets and parked items, and gives up reviewing and
  merging. Write down every remaining human action.
- Before any paid step, show what each dollar buys and offer the cheaper plan that answers the
  same question. Run the reduced-size version first.
- A watchdog must ask whether the thing it watches is still alive, and a wait must be longer than
  the period of what it waits for.

## 8. Start small

- Over-engineering is the default failure. Ask for the smallest mechanism that enforces the
  property before adding a component.
- Research what already works before designing. The pattern here (a fresh run per unit, state on
  disk, limits in the harness, one unit in progress) was documented before it was rebuilt.
- Be honest about gaps. Keep a list of what the system does not yet cover.
