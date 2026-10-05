# Kit

These are working templates for the host side of the system: the driver loop, the per-pass runner, the courier, and the conduct, config and systemd units around them. They are the scripts behind components 1, 2 and 6 in `FOUNDATIONS.md`, taken from a system that has run unattended in production.

**They are templates, not a package.** The names in them (users `agent`, `courier` and `alerter`; paths under `/opt`, `/etc`, `/var/lib` and `/srv`; `OWNER/REPO`) are placeholders. Change them for your project before installing. Don't add a config layer: each project gets its own copy.

## Files, and where they go

| File | Installs to (root-owned) | Role |
|---|---|---|
| `loop.sh` | `/opt/agent-loop/loop.sh` | The driver: waits for events on loop PRs, runs one isolated pass per event, and enforces every cap and outcome (FOUNDATIONS §6) |
| `pass.sh` | `/opt/agent-loop/pass.sh` | One pass, as the agent user in a transient unit: a fresh clone at the exact main SHA, an empty home, hooks off, then `claude -p` |
| `courier.sh` | `/opt/courier/courier.sh` | The only holder of the code-host token: forwards `agent/*` branches, opens PRs, and writes the status files the loop and any reporting read (FOUNDATIONS §2) |
| `etc/conduct.md` | `/etc/agent/conduct.md` | Rules appended to every pass's system prompt. Root-owned, so a pass can't change it |
| `etc/loop.conf` | `/etc/agent/loop.conf` | Knobs the loop re-reads every cycle: `DAILY_PASSES`, `WEEKLY_COST` |
| `etc/pass.gitconfig` | `/etc/agent/pass.gitconfig` | The pass's only git config: `safe.directory` for the bare repo, hooks off |
| `etc/firewall.nft` | `/etc/agent/firewall.nft` | Rejects the agent user's connections to the database port on every address |
| `units/agent-loop.service` | `/etc/systemd/system/` | The loop as root, with a fixed system PATH |
| `units/agent-firewall.service` | `/etc/systemd/system/` | Applies the firewall at boot |
| `units/courier.{service,timer}` | `/etc/systemd/system/` | The courier as its own user, every minute, under `flock` |

## Secrets each component needs (never in these files)

Create these on the host, root-owned and mode 0600 unless noted:
- **`/etc/agent/loop-token.env`**: `CLAUDE_CODE_OAUTH_TOKEN=…`, a 1-year token from `claude setup-token` on the dedicated agent account. FOUNDATIONS §9 covers installing it without it leaving the host.
- **`/etc/agent/hc-loop.url`**: the loop's liveness ping URL.
- **`/etc/courier/token`**: the code-host token, readable by the courier user only.
- **`/etc/courier/ntfy.curl` and `healthchecks.curl`**: curl config files (`url = "…"`), so the topic and ping URL never appear on a command line.

## Values to change

- **Users:** `agent`, `courier` and `alerter`.
- **Paths:** `/opt/agent-loop`, `/opt/courier`, `/etc/agent`, `/etc/courier`, `/var/lib/agent-loop`, `/var/lib/courier`, the bare repo `/srv/agent-git/project.git`, `/srv/courier-status`, `/srv/courier/outbox`, and the alert queue path in the loop unit's `ReadWritePaths`.
- **`REPO=OWNER/REPO` in `courier.sh`**, and its `PROTECTED` pattern if the project keeps agent config elsewhere.
- **`firewall.nft`:** the database port (5432) and anything else the agent must not reach.
- **`pass.sh`:** the model and turn limit (`PASS_MODEL`, `PASS_MAX_TURNS`).
- **`conduct.md`:** the project-specific rules.

## Not included: build these in the project repo

They're versioned and tested with the code they guard. FOUNDATIONS describes each one:
- **Review gate (§3):** the CI workflow with two independent reviewers, verdict extraction from the tool's JSON, and a merge pinned to the reviewed SHA.
- **Tier classifier and path list (§3),** read from the base commit, with a test example for every rule.
- **Agent instructions and skills (§5):** the project instruction file, the `next`, `slice`, `finding` and `ship` skills, and `.claude/settings.json` (attribution set to `""`).
- **Alert queue and deterministic push-notification drain (§7),** with delivery history.
- **Remote Control session units,** if the owner wants a live session on the host.
- **The Reports page (§7):** daily report collector, health snapshot, optional AI summary, and the read-only page.
- **A project runbook** for the host: where each piece lives, its knobs, and its operating procedures.
