#!/usr/bin/env bash
# courier: the only thing on the host that holds a GitHub write token.
#
# The agent (user agent) pushes branches named agent/<name> into a local bare repo. This
# script, run as user courier, forwards them to GitHub and opens a PR. It never merges, never
# force-pushes, never deletes, and never pushes a ref outside refs/heads/agent/.
#
# Changes to .github/, .claude/, CLAUDE.md, CLAUDE.local.md, AGENTS.md or .mcp.json are never
# pushed: GitHub runs a pushed branch's own workflows with the repo's secrets, and a free private
# repo cannot fence secrets into protected environments. Those become a patch in the outbox for
# the owner to apply by hand.
#
# Every per-branch failure is logged, notified and skipped, so one bad branch cannot stall the
# others. Anything that cannot be checked is refused, never pushed.
#
# Installed root-owned at /opt/courier/courier.sh. Any change to it is reviewed by the owner.
# The COURIER_* overrides exist for the local test harness; the systemd unit sets none of them.
set -euo pipefail

LOCAL=${COURIER_LOCAL:-/srv/agent-git/project.git}   # agent pushes here
# LOCAL is owned by courier (group agent, agent may add refs/objects only, not config or
# hooks), so the courier reads it as its owner and never needs safe.directory.
WORK=${COURIER_WORK:-/var/lib/courier/mirror}          # courier's own clone
OUTBOX=${COURIER_OUTBOX:-/srv/courier/outbox}              # writable by courier only
ETC=${COURIER_ETC:-/etc/courier}                       # token, ntfy/healthchecks config, STOP
STATE=${COURIER_STATE:-/var/lib/courier/state}         # last sha acted on, per branch
STATUS=${COURIER_STATUS:-/srv/courier-status}               # agent-readable PR status
PARKED=${COURIER_PARKED:-/var/lib/agent-loop/parked}     # loop PRs the loop has set aside
REPO=OWNER/REPO
REMOTE=${COURIER_REMOTE:-https://github.com/${REPO}.git}
PROTECTED='^(\.github(/|$)|\.mcp\.json$|\.gitmodules$)|(^|/)\.claude(/|$)|(^|/)CLAUDE(\.local)?\.md$|(^|/)AGENTS\.md$'
NAME_OK='^agent/[A-Za-z0-9][A-Za-z0-9._-]{0,80}$'

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
# The ntfy topic and Healthchecks URL are read by curl from root-owned config files (-K), never
# passed on the command line, where other users could read them from /proc.
notify() {
    [ -r "$ETC/ntfy.curl" ] || return 0
    printf '%s' "$1" | curl -fsS --max-time 10 -K "$ETC/ntfy.curl" --data-binary @- >/dev/null || true
}
refuse() { log "refused $1: $2"; notify "courier: refused $1: $2"; }
# Whole-run failures alert once per kind, not once a minute; a clean run clears them.
fatal() { log "$2"; if [ ! -e "$STATE/.fatal-$1" ]; then notify "courier: $2"; : > "$STATE/.fatal-$1"; fi; exit 1; }
# Network calls get a ceiling, so a hang cannot hold the lock and silently stall every later run.
net() { if command -v timeout >/dev/null; then timeout 60 "$@"; else "$@"; fi; }
# One state file per branch records the sha last acted on. An unchanged branch is skipped without
# an API call or an alert, so a stuck branch neither spams ntfy nor burns the GitHub rate limit.
done_with() { printf '%s\n' "$2" > "$STATE/${1#agent/}"; }
# git's own error text, with the token removed in case a remote ever echoes it back.
scrub() { local s=$1; [ -z "${GH_TOKEN:-}" ] || s=${s//"$GH_TOKEN"/[token]}; printf '%s' "$s"; }

if [ -e "$ETC/STOP" ]; then log "STOP present; doing nothing"; exit 0; fi

if ! gitleaks version >/dev/null 2>&1 || ! gitleaks git --help >/dev/null 2>&1; then
    mkdir -p "$STATE"; fatal gitleaks "gitleaks missing or too old for 'gitleaks git'; nothing will be pushed"
fi

mkdir -p "$STATE"
GH_TOKEN=$(cat "$ETC/token" 2>/dev/null) || fatal token "token file missing or unreadable"
export GH_TOKEN
# The token never appears in a command line (other users can read /proc/<pid>/cmdline). git
# gets it from this helper, which reads it from this process's own environment.
CRED=(-c credential.helper= -c 'credential.helper=!f() { echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f')

if [ ! -d "$WORK/.git" ]; then
    net git "${CRED[@]}" clone -q "$REMOTE" "$WORK" || fatal clone "initial clone failed"
fi
net git "${CRED[@]}" -C "$WORK" fetch -q --no-tags --prune origin '+refs/heads/main:refs/remotes/origin/main' ||
    fatal fetch "fetching main failed (token expired or GitHub unreachable?)"

# The agent has no GitHub credential, so it gets main from here: into its local repo only.
git -C "$WORK" push -q --force "$LOCAL" refs/remotes/origin/main:refs/heads/main ||
    fatal sync "could not copy main into the agent's local repo"

refs=$(git -C "$LOCAL" for-each-ref --format='%(refname:strip=2) %(objectname)' 'refs/heads/agent/') || {
    fatal local "cannot read the agent's local repo"; }
rm -f "$STATE"/.fatal-*

while read -r name sha <&3; do
    [ -n "$name" ] || continue
    if [ -e "$ETC/STOP" ]; then log "STOP present; stopping mid-run"; break; fi
    if ! [[ "$name" =~ $NAME_OK ]]; then log "refused $name: branch name not allowed"; continue; fi
    if [ "$(cat "$STATE/${name#agent/}" 2>/dev/null)" = "$sha" ]; then continue; fi

    # A PR the owner closed stays closed: never push to it again or open a new one for it.
    prs=$(net gh pr list --repo "$REPO" --head "$name" --state all --json number,state \
            --jq '.[] | "\(.number) \(.state)"') || { refuse "$name" "cannot list its PRs"; continue; }
    if [ -n "$prs" ] && ! grep -q ' OPEN$' <<<"$prs"; then
        log "skipped $name: its PR was closed or merged; not reopening"
        notify "courier: $name has new commits but its PR was closed or merged; not forwarded"
        done_with "$name" "$sha"; continue
    fi

    # One loop PR at a time: a new agent/loop-* branch waits while another loop PR is open and not
    # parked. Held, not refused: it is forwarded on the first run after that PR closes.
    if [ -z "$prs" ] && [[ "$name" == agent/loop-* ]]; then
        others=$(net gh pr list --repo "$REPO" --state open --json number,headRefName \
                  --jq '.[] | select(.headRefName | startswith("agent/loop-")) | .number') || {
            log "held $name: cannot list open loop PRs"; continue; }
        busy=""
        for n in $others; do grep -qx "$n" "$PARKED" 2>/dev/null || busy=$n; done
        if [ -n "$busy" ]; then
            log "held $name: loop PR #$busy is still open"
            since=$(cat "$STATE/.held-${name#agent/}" 2>/dev/null || { date +%s | tee "$STATE/.held-${name#agent/}"; })
            if (( $(date +%s) - since > 7200 )) && [ ! -e "$STATE/.held-${name#agent/}.told" ]; then
                notify "courier: $name has been held over 2 h behind loop PR #$busy"; : > "$STATE/.held-${name#agent/}.told"
            fi
            continue
        fi
        rm -f "$STATE/.held-${name#agent/}" "$STATE/.held-${name#agent/}.told"
    fi

    # --no-tags and the full ref name: an agent-pushed tag called origin/main must never stand in
    # for main, or the checked range would be empty and every check would pass.
    git -C "$WORK" fetch -q --no-tags "$LOCAL" "+refs/heads/${name}:refs/courier/${name}" || {
        refuse "$name" "fetch from local repo failed"; continue; }
    sha=$(git -C "$WORK" rev-parse "refs/courier/${name}")
    base=$(git -C "$WORK" merge-base refs/remotes/origin/main "refs/courier/${name}") || {
        refuse "$name" "no common history with main"; done_with "$name" "$sha"; continue; }

    # Linear history only: git log, format-patch and gitleaks do not reliably show what a merge
    # commit itself changes. The agent rebases instead.
    merges=$(git -C "$WORK" rev-list --min-parents=2 "${base}..refs/courier/${name}") || {
        refuse "$name" "rev-list failed"; continue; }
    if [ -n "$merges" ]; then refuse "$name" "contains merge commits (rebase onto main)"; done_with "$name" "$sha"; continue; fi

    # Every commit in the range, not just the tip. -z: paths are never quoted.
    # --no-renames: a rename reports the path it left, too. Captured into a variable, never piped
    # into grep -q: an early grep exit would kill git log and, under pipefail, read as "no match".
    paths=$(git -C "$WORK" log --no-renames --no-ext-diff --format= \
              --name-only -z "${base}..refs/courier/${name}" | tr '\0' '\n') || {
        refuse "$name" "could not list changed paths"; continue; }
    # Case-insensitive: macOS and Windows checkouts treat .Claude/ and claude.md as the real thing.
    if grep -Eiq "$PROTECTED" <<<"$paths"; then
        out="$OUTBOX/${name#agent/}-${sha:0:12}.patch"
        if [ ! -e "$out" ]; then
            if git -C "$WORK" format-patch --stdout "${base}..refs/courier/${name}" > "$out.tmp"; then
                mv -f "$out.tmp" "$out"
                log "outbox $name -> $out (touches protected paths; not pushed)"
                notify "courier: $name touches protected paths. Patch waiting: $out"
            else
                rm -f "$out.tmp"; refuse "$name" "format-patch failed"
            fi
        fi
        done_with "$name" "$sha"; continue
    fi

    if ! gitleaks git --no-banner --ignore-gitleaks-allow \
            --log-opts="${base}..refs/courier/${name}" "$WORK" >/dev/null 2>&1; then
        refuse "$name" "gitleaks found a possible secret (or failed)"; done_with "$name" "$sha"; continue
    fi

    # Explicit refspec, never a wildcard or mirror, never --force.
    # Only a genuine rejection is final; a timeout or a GitHub error is retried next run.
    if ! perr=$(net git "${CRED[@]}" -C "$WORK" push -q "$REMOTE" "refs/courier/${name}:refs/heads/${name}" 2>&1); then
        perr=$(scrub "$perr")
        if grep -q 'rejected' <<<"$perr"; then
            # The reason is on git's "! [...]" line and the remote's own "remote:" lines; the alert
            # carries them, because a refusal that does not say why cannot be acted on.
            why=$(grep -E '^ *! \[|^remote:' <<<"$perr" | tr -s ' \n' ' ' | sed -E 's/^ +| +$//g' | cut -c1-300) || why=""
            log "push of $name rejected: $perr"
            refuse "$name" "push rejected: ${why:-git gave no reason}"; done_with "$name" "$sha"
        else
            log "push of $name failed, will retry: $perr"
        fi
        continue
    fi
    log "pushed $name @ ${sha:0:12}"

    if [ -z "$prs" ]; then
        subject=$(git -C "$WORK" log -1 --format=%s "refs/courier/${name}")
        body=$(git -C "$WORK" log --format='- %s' "${base}..refs/courier/${name}")
        if net gh pr create --repo "$REPO" --base main --head "$name" --title "$subject" --body "$body" >/dev/null; then
            log "opened PR for $name"
        else
            refuse "$name" "gh pr create failed"; continue
        fi
    fi
    done_with "$name" "$sha"
done 3<<<"$refs"

# The agent has no GitHub access, so this file is how it sees its PRs: state, and the bot's last
# comment and review (which carry the verdict, the findings and whether test/test-db were green).
# The token has no Checks permission, so check results are not queried directly.
# Refreshed every run; a failed refresh leaves the old file.
if pr_status=$(net gh pr list --repo "$REPO" --state all --limit 100 \
        --json number,headRefName,state,isDraft,url,comments,reviews \
        --jq '[.[] | select(.headRefName | startswith("agent/")) | {number, branch: .headRefName, state, isDraft, url,
               last_comment: (((.comments | last) // {}).body // "" | .[0:4000]),
               last_review: (((.reviews | map(select(.body != "")) | last) // {}).body // "" | .[0:4000])}]'); then
    # Inline-only reviews. A review posted with inline comments and an empty body is dropped by the
    # non-empty filter above, so the loop saw no event and its fix pass no text: #331 sat on an
    # unread HIGH (2026-10-04). For each open loop PR, take the latest review by REST, which carries
    # its id, and when it has inline comments put them in last_review with its body.
    for n in $(printf '%s' "$pr_status" | python3 -c 'import json, sys
print(" ".join(str(p["number"]) for p in json.load(sys.stdin)
               if p["state"] == "OPEN" and p["branch"].startswith("agent/loop-")))'); do
        review=$(net gh api "repos/$REPO/pulls/$n/reviews" --jq 'last // empty') || continue
        [ -n "$review" ] || continue
        rid=$(printf '%s' "$review" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])') || continue
        inline=$(net gh api "repos/$REPO/pulls/$n/comments?per_page=100" --jq "[.[] | select(.pull_request_review_id == $rid) | \"\(.path):\(.line // .original_line): \(.body)\"] | join(\"\n\n\")") || continue
        [ -n "$inline" ] || continue
        merged=$(printf '%s' "$pr_status" | N="$n" R="$review" I="$inline" python3 -c 'import json, os, sys
prs = json.load(sys.stdin)
body = json.loads(os.environ["R"]).get("body") or ""
text = (body + "\n\n" if body else "") + "Inline review comments:\n" + os.environ["I"]
for p in prs:
    if p["number"] == int(os.environ["N"]):
        p["last_review"] = text[:4000]
print(json.dumps(prs))') && pr_status=$merged
    done
    printf '%s\n' "$pr_status" > "$STATUS/prs.json.tmp" && mv -f "$STATUS/prs.json.tmp" "$STATUS/prs.json" ||
        log "could not write $STATUS/prs.json"
else
    log "could not refresh PR status"
fi

# GitHub main and its recent merges, for the daily ops report (owner-approved amendment 2,
# 2026-10-05). The courier holds the only GitHub token, so the collector reads main's SHA and the
# day's merges from here and nothing else. written_at lets it tell a stalled courier from a current
# one. Written atomically; a failed lookup leaves the old file, whose written_at then goes stale.
if main_sha=$(net gh api "repos/$REPO/commits/main" --jq .sha) &&
   merged=$(net gh pr list --repo "$REPO" --state merged --base main \
       --search "merged:>=$(date -u -d '-48 hours' +%Y-%m-%dT%H:%M:%SZ)" --limit 100 \
       --json number,mergedAt,title,headRefName); then
    if printf '%s' "$merged" | SHA="$main_sha" python3 -c 'import json, os, sys
from datetime import datetime, timezone
print(json.dumps({"written_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                  "main_sha": os.environ["SHA"], "merged": json.load(sys.stdin)}))' \
        > "$STATUS/main.json.tmp"; then
        mv -f "$STATUS/main.json.tmp" "$STATUS/main.json"
    else
        log "could not write $STATUS/main.json"
    fi
else
    log "could not read main or its merges"
fi

if [ -r "$ETC/healthchecks.curl" ]; then curl -fsS --max-time 10 -K "$ETC/healthchecks.curl" >/dev/null || true; fi
