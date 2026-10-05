#!/bin/bash
# agent loop. Starts one fresh, isolated agent pass per event on the loop's own PRs.
#
# A pass runs when something new happens to an `agent/loop-*` PR (a merge, a close, a new bot
# comment or review) as the courier's status file records it; otherwise the loop sleeps. At most
# one loop PR is open: while one is, a pass only fixes what its review found; when none is, a pass
# runs /next. The review a pass produces is the next event.
#
# Each pass is its own transient systemd unit, run as agent from an empty home directory that
# is deleted afterwards (pass.sh), so nothing a pass writes reaches a later pass except through a
# reviewed PR. The loop runs as root on a fixed system PATH and executes only root-owned files.
# Every cap below is enforced here, not in the prompt.
# Root-owned at /opt/agent-loop/loop.sh. LOOP_* overrides exist for test.sh only.
set -uo pipefail
export PATH=${LOOP_PATH:-/usr/sbin:/usr/bin:/sbin:/bin}   # never an agent-writable directory

STATUS=${LOOP_STATUS:-/srv/courier-status/prs.json}
MIRROR=${LOOP_MIRROR:-/var/lib/courier/mirror}
STOPFILES=${LOOP_STOPFILES:-/etc/agent/STOP-loop:/etc/courier/STOP}
HC=${LOOP_HC:-/etc/agent/hc-loop.url}
ALERT=${LOOP_ALERT:-/opt/alerter/enqueue.sh}
ORIGIN=${LOOP_ORIGIN:-/srv/agent-git/project.git}
STATE=${LOOP_STATE:-/var/lib/agent-loop}
RUNNER=${LOOP_RUNNER:-systemd}          # "direct" in test.sh: run pass.sh without systemd
PASS=${LOOP_PASS:-/opt/agent-loop/pass.sh}

POLL=${LOOP_POLL:-60}
PASS_TIMEOUT=${LOOP_PASS_TIMEOUT:-7200}
DAILY_PASSES=${LOOP_DAILY_PASSES:-32}
WEEKLY_COST=${LOOP_WEEKLY_COST:-150}    # estimated USD over 7 days (claude's total_cost_usd)
MAX_ROUNDS=${LOOP_MAX_ROUNDS:-3}        # pushed fixes on one PR before it is parked
STALL=${LOOP_STALL:-21600}              # an open PR with no event for this long is parked
IDLE_NUDGE=${LOOP_IDLE_NUDGE:-21600}    # no open PR and nothing for this long: run a pass
STALE=${LOOP_STALE:-600}                # status file older than this: the courier is down
BACKOFF=${LOOP_BACKOFF:-1800}           # first retry after a failed pass; doubles, capped at 4x
LIMIT_WAIT=${LOOP_LIMIT_WAIT:-900}     # recheck interval at a usage limit; a blocked attempt fails at once
KEEP_DAYS=${LOOP_KEEP_DAYS:-14}
FAIL_COST=${LOOP_FAIL_COST:-10}         # charged to the budget for a pass that left no cost figure
UNIT=agent-pass                           # ONE name: systemd itself refuses a second concurrent pass

LOGS=$STATE/logs; PASSES=$STATE/passes; PROMPTS=$STATE/prompts
# Caps can be tuned without a restart: a root-owned file of plain NAME=value lines, re-read every
# cycle. Only these two names are honoured, and only as integers.
CONF=${LOOP_CONF:-/etc/agent/loop.conf}
load_conf() {
    local k v
    [ -r "$CONF" ] || return 0
    while IFS='=' read -r k v; do
        [[ "$v" =~ ^[0-9]+$ ]] || continue
        case $k in DAILY_PASSES) DAILY_PASSES=$v ;; WEEKLY_COST) WEEKLY_COST=$v ;; esac
    done < "$CONF"
}

COMMON='You are one pass of the agent loop on this host. No human is watching and none will answer: make every judgment call yourself under CLAUDE.md and the skills, and record the reason in the PR body or the work file. You start on a clean clone of current main. /srv/courier-status/prs.json has the state of every agent PR. Name every branch you push agent/loop-<name>.'

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
stopped() { local f; IFS=: read -r -a _s <<< "$STOPFILES"; for f in "${_s[@]}"; do [ -e "$f" ] && return 0; done; return 1; }
hc() { [ -r "$HC" ] || return 0
       printf 'url = "%s%s"\n' "$(tr -d '[:space:]' < "$HC")" "$1" | curl -fsS --max-time 10 --retry 2 -K - -o /dev/null || true; }
alert() { if [ -x "$ALERT" ] && "$ALERT" "$1" "agent loop: $2" >/dev/null 2>&1; then return; fi; log "alert not queued: $2"; }
once() { [ "$(get "once-$1" x)" = "$2" ] && return 1; put "once-$1" "$2"; }   # once KEY VALUE
get() { cat "$STATE/$1" 2>/dev/null || echo "${2:-0}"; }
put() { printf '%s\n' "$2" > "$STATE/$1.tmp" && mv -f "$STATE/$1.tmp" "$STATE/$1"; }
healthy() { (( $(get failures) == 0 )) && hc ""; }

# The status file, reduced to loop PRs. `keys`: one line per PR with its state and a hash of the
# bot's last comment and review; an OPEN PR with no text yet is skipped. A pass runs only for a
# line that was not seen before, so a PR leaving the courier's window is never an event.
prs() {
    python3 - "$STATUS" "$1" "$STATE/parked" <<'EOF'
import hashlib, json, sys
what = sys.argv[2]
try:
    parked = set(open(sys.argv[3]).read().split())
except OSError:
    parked = set()
prs = [p for p in json.load(open(sys.argv[1])) if p["branch"].startswith("agent/loop-")]
for p in sorted(prs, key=lambda p: p["number"]):
    text = (p.get("last_comment") or "") + (p.get("last_review") or "")
    if what == "keys" and not (p["state"] == "OPEN" and not text):
        print(f'{p["number"]}:{p["state"]}:{hashlib.sha1(text.encode()).hexdigest()[:16]}')
    elif what == "open" and p["state"] == "OPEN" and str(p["number"]) not in parked:
        print(p["number"], p["branch"])
    elif what == "parked-branches" and p["state"] == "OPEN" and str(p["number"]) in parked:
        print(p["branch"])
EOF
}
ref() { git -c safe.directory="$ORIGIN" --git-dir="$ORIGIN" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || echo none; }
main_sha() { git -c safe.directory="$MIRROR" -C "$MIRROR" rev-parse --verify refs/remotes/origin/main; }
week_cost() { awk -v since=$(( $(date +%s) - 604800 )) '$1 >= since { s += $2 } END { printf "%d\n", s }' "$STATE/costs" 2>/dev/null || echo 0; }

# Stop any pass still running: one left behind by a loop that died or restarted, or on STOP.
stop_pass() { [ "$RUNNER" = systemd ] && systemctl stop "$UNIT" 2>/dev/null; return 0; }

park() {
    echo "$1" >> "$STATE/parked"; alert WARN "PR #$1 parked: $2; the loop moves on"; log "parked #$1: $2"
}

# Keep the pass's transcripts: the only record of what an unattended pass actually ran.
keep_transcript() {
    mkdir -p "$LOGS/$1"
    find "$2/.claude/projects" -name '*.jsonl' -type f -exec cp {} "$LOGS/$1/" \; 2>/dev/null
}

# Run one pass in its own unit. Prints: ok, fail, limit:<seconds>, stopped.
run_pass() {
    local id=$1 prompt=$2 sha=$3 home="$PASSES/$1" out="$LOGS/$1.json" err="$LOGS/$1.err" pid rc
    mkdir -p "$home" && chown agent:agent "$home" 2>/dev/null
    printf '%s' "$prompt" > "$PROMPTS/$id"
    if [ "$RUNNER" = systemd ]; then
        systemd-run --unit="$UNIT" --uid=agent --gid=agent --wait --collect --quiet \
            -p PartOf=agent-loop.service \
            -p RuntimeMaxSec="$PASS_TIMEOUT" -p MemoryMax=3G -p MemoryHigh=2560M -p MemorySwapMax=0 \
            -p CPUQuota=150% -p TasksMax=1024 -p Nice=19 -p IOWeight=10 -p OOMScoreAdjust=1000 \
            -p NoNewPrivileges=yes -p ProtectSystem=strict -p ProtectHome=yes -p PrivateTmp=yes \
            -p ReadWritePaths="$home $ORIGIN" -p EnvironmentFile=/etc/agent/loop-token.env \
            -p Environment="HOME=$home DISABLE_AUTOUPDATER=1 PATH=/opt/claude/bin:/usr/local/bin:/usr/bin:/bin" \
            -p StandardOutput="file:$out" -p StandardError="file:$err" \
            "$PASS" "$sha" "$PROMPTS/$id" &
    else
        ( HOME=$home "$PASS" "$sha" "$PROMPTS/$id" > "$out" 2> "$err" ) &
    fi
    pid=$!
    local tick=$(( POLL < 5 ? POLL : 5 )) waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if stopped; then
            if [ "$RUNNER" = systemd ]; then stop_pass; else pkill -TERM -P "$pid"; kill "$pid"; fi
            wait "$pid"; keep_transcript "$id" "$home"; rm -rf "$home"; echo stopped; return
        fi
        sleep "$tick"; waited=$(( waited + tick ))
        (( waited % POLL == 0 )) && healthy
    done
    wait "$pid"; rc=$?
    keep_transcript "$id" "$home"
    rm -rf "$home"
    python3 - "$out" "$err" "$rc" "$LIMIT_WAIT" "$STATE/costs" "$FAIL_COST" <<'EOF'
import json, re, sys, time
out, err, rc, default_wait, costs = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
try:
    r = json.load(open(out))
except Exception:
    r = {}
# A pass killed by its ceiling, OOM or STOP writes no result, and those are the expensive ones.
cost = r.get("total_cost_usd") if "total_cost_usd" in r else float(sys.argv[6])
with open(costs, "a") as f:
    f.write(f"{int(time.time())} {cost}\n")
if rc == 0 and r.get("type") == "result" and not r.get("is_error"):
    print("ok"); sys.exit()
# Only a pass that FAILED can have hit the usage limit, and only its error channels are read: the
# agent's own summary talks about vendor rate limits all the time.
errtext = open(err, errors="replace").read() + (r.get("result") or "" if r.get("is_error") else "")
# Claude Code 2.x words it "You've hit your session limit · resets 3pm (…)", with no epoch, so the
# wait falls back to LIMIT_WAIT and the loop simply rechecks until the reset has passed.
if r.get("api_error_status") == 429 or re.search(r"usage limit|limit reached|rate limit|you.ve (?:hit|reached) your", errtext, re.I):
    m = re.search(r"\|(\d{10})\b", errtext)
    wait = int(m.group(1)) - int(time.time()) if m else default_wait
    print(f"limit:{max(wait, min(default_wait, 300))}")
else:
    print("fail")
EOF
}

mkdir -p "$STATE" "$LOGS" "$PASSES" "$PROMPTS"; chmod 755 "$STATE"
log "loop starting"
stop_pass
# A pass that was running when the loop died (OOM, reboot, restart) failed: restore the events it
# consumed and count it, so its PR is not left waiting for an event that already happened.
if [ -f "$STATE/inflight" ]; then
    mv -f "$STATE/inflight" "$STATE/seen"; put failures $(( $(get failures) + 1 )); put retry_at 0
    log "previous pass did not finish; counted as a failure"
fi

while :; do
    load_conf
    find "$LOGS" "$PROMPTS" -mindepth 1 -mtime +"$KEEP_DAYS" -delete 2>/dev/null
    rm -rf "${PASSES:?}"/* 2>/dev/null   # a pass never runs here: run_pass has returned, and stop_pass ran at start

    if stopped; then stop_pass; healthy; sleep "$POLL"; continue; fi

    age=$(( $(date +%s) - $(stat -c %Y "$STATUS" 2>/dev/null || echo 0) ))
    if (( age > STALE )) || ! now=$(prs keys 2>/dev/null) || ! sha=$(main_sha 2>/dev/null); then
        log "courier status or mirror unreadable or stale (${age}s)"; hc "/fail"; sleep "$POLL"; continue
    fi
    open=$(prs open); pr=${open%% *}; branch=${open#* }; branch=${branch%%$'\n'*}
    [ "$pr" = "$(get stall_pr x)" ] || { put stall_pr "${pr:-none}"; put stall_since "$(date +%s)"; }

    failures=$(get failures)
    if (( failures > 0 )); then
        (( $(date +%s) < $(get retry_at) )) && { sleep "$POLL"; continue; }
        reason="retry after failure $failures"
    elif (( $(date +%s) < $(get limit_until) )); then
        healthy; sleep "$POLL"; continue
    elif [ ! -f "$STATE/seen" ]; then
        reason="first run"
    elif new=$(comm -13 <(sort "$STATE/seen") <(printf '%s\n' "$now" | sort)) && [ -n "$new" ]; then
        reason="event: $(echo "$new" | tr '\n' ' ')"; put stall_since "$(date +%s)"
    elif [ -n "$pr" ] && (( $(date +%s) - $(get stall_since) > STALL )); then
        park "$pr" "no review activity for $(( STALL / 3600 )) h"; continue
    elif [ -z "$pr" ] && (( $(date +%s) - $(get last_pass) > IDLE_NUDGE )); then
        reason="idle for $(( IDLE_NUDGE / 3600 )) h with no open PR"
    else
        healthy; sleep "$POLL"; continue
    fi

    today=$(date -u +%F)
    [ "$(get day x)" = "$today" ] || { put day "$today"; put passes_today 0; }
    if (( $(get passes_today) >= DAILY_PASSES )); then
        once cap "$today" && log "daily cap of $DAILY_PASSES passes reached; resuming tomorrow (UTC)"
        # The day's work is done: publish a partial ops report for it now. --no-block, and its result is
        # never read, so a reporter failure cannot touch this loop's failures or backoff.
        once partial-report "$today" && { systemctl start --no-block daily-report-partial.service || true; }
        healthy; sleep "$POLL"; continue
    fi
    if (( $(week_cost) >= WEEKLY_COST )); then
        once budget "$today" && alert WARN "7-day usage estimate reached \$$WEEKLY_COST; pausing until it drops"
        healthy; sleep "$POLL"; continue
    fi

    if [ -n "$pr" ]; then
        if (( $(get "rounds-$pr") >= MAX_ROUNDS )); then park "$pr" "$MAX_ROUNDS pushed fixes"; continue; fi
        prompt="$COMMON

Agent PR #$pr ($branch) is open. Read its last comment and last review in prs.json. If they report a HIGH or CRITICAL finding, fix it as new commits on $branch and push (never rebase a pushed branch). If there is nothing to fix, stop without starting any other work."
        mode="fix #$pr"
    else
        parked=$(prs parked-branches | tr '\n' ' ')
        prompt="$COMMON

No loop PR is open. Run /next and carry the pick as far as you can in this pass: spec, tests, code, /ship. Push at most one branch.${parked:+ These parked branches hold work that was set aside; do not redo it: $parked}"
        mode=next
    fi

    # Record the events BEFORE the pass (so anything during it is the next event), and mark the pass
    # in flight (so a pass killed with the loop is counted and its events restored).
    if [ -f "$STATE/seen" ]; then cp "$STATE/seen" "$STATE/inflight"; else : > "$STATE/inflight"; fi
    printf '%s\n' "$now" > "$STATE/seen"
    put passes_today $(( $(get passes_today) + 1 )); put last_pass "$(date +%s)"
    before=none; [ -n "$pr" ] && before=$(ref "$branch")
    id=$(date -u +%Y%m%dT%H%M%SZ)
    log "pass $id ($mode) starting at main ${sha:0:12}: $reason"
    outcome=$(run_pass "$id" "$prompt" "$sha")
    # A stopped pass did not handle its events: put them back for the pass after STOP clears.
    if [ "$outcome" = stopped ]; then mv -f "$STATE/inflight" "$STATE/seen"; else rm -f "$STATE/inflight"; fi
    log "pass $id ($mode) ended: $outcome"
    [ -n "$pr" ] && [ "$(ref "$branch")" != "$before" ] && put "rounds-$pr" $(( $(get "rounds-$pr") + 1 ))

    case $outcome in
        ok)      put failures 0; hc "" ;;
        stopped) ;;
        limit:*) secs=${outcome#limit:}; put limit_until $(( $(date +%s) + secs )); rm -f "$STATE/seen"
                 once limit "$(date -u +%F)" && alert WARN "usage limit hit; rechecking every $(( secs / 60 )) min until it resets" ;;
        *)       f=$(( $(get failures) + 1 )); put failures "$f"
                 put retry_at $(( $(date +%s) + BACKOFF * (f > 3 ? 4 : 1 << (f - 1)) )); hc "/fail"
                 (( f == 3 )) && alert CRITICAL "three failed passes in a row; retrying on backoff. Logs: $LOGS" ;;
    esac
done
