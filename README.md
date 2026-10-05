# Autonomous foundations

A blueprint for an AI coding agent that works a codebase continuously, merges its own reviewed changes and deploys them, with no human in the loop. It is distilled from building and running one in production.

- **[FOUNDATIONS.md](FOUNDATIONS.md)** covers:
  - the nine components;
  - a phase-by-phase rebuild roadmap, each phase with an exit test;
  - lessons learned;
  - a checklist before going unattended;
  - known gaps.
- **[kit/](kit/)** holds working templates for the host side: the driver loop, the per-pass runner, the courier, and their conduct file, config and systemd units. Change the placeholder names before use.

The core idea: **an agent can't be trusted by instruction, only by mechanism.** Every property that matters is enforced by something the agent can't edit, and proven by breaking it on purpose.
