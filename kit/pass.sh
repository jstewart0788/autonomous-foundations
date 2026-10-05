#!/bin/bash
# One pass of the agent loop, run as agent inside its own transient systemd unit.
# Usage: pass.sh <main-sha> <prompt-file>
#
# Everything the pass could change to influence a later pass lives in $HOME, a directory the loop
# creates empty for this pass and deletes afterwards: the clone, git config and hooks, Claude's
# config, memory, settings and skills, shell dotfiles. The rules come from the repo at the exact
# main SHA the courier fetched from GitHub, plus the root-owned conduct file.
# Root-owned at /opt/agent-loop/pass.sh. PASS_* overrides exist for test.sh.
set -euo pipefail

sha=$1; prompt_file=$2
ORIGIN=${PASS_ORIGIN:-/srv/agent-git/project.git}
CONDUCT=${PASS_CONDUCT:-/etc/agent/conduct.md}
CLAUDE=${PASS_CLAUDE:-/opt/claude/bin/claude}
MODEL=${PASS_MODEL:-opus}
MAX_TURNS=${PASS_MAX_TURNS:-400}

# Git reads no config a pass could have written: its "global" config is a root-owned file that
# grants safe.directory for the courier-owned bare repo (only a global or system file can) and
# turns hooks off. Every clone is new, so hooks or config a pass sets die with it.
export GIT_CONFIG_GLOBAL=${PASS_GITCONFIG:-/etc/agent/pass.gitconfig} GIT_CONFIG_NOSYSTEM=1
git clone -q --no-checkout -c core.hooksPath=/dev/null "$ORIGIN" "$HOME/clone"
cd "$HOME/clone"
git -c core.hooksPath=/dev/null checkout -q --detach "$sha"
git -c core.hooksPath=/dev/null checkout -q -B main
git config core.hooksPath /dev/null
git config user.name agent
git config user.email agent@localhost
if [ "$(git rev-parse HEAD)" != "$sha" ] || [ -n "$(git status --porcelain)" ]; then
    echo "clone is not clean at $sha" >&2; exit 3
fi

export CLAUDE_CONFIG_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"hasCompletedOnboarding": true}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"

# The conduct rules go in as a system prompt read straight from the root-owned file: with
# --setting-sources project, a user-level CLAUDE.md would not be loaded at all.
exec "$CLAUDE" -p "$(cat "$prompt_file")" --model "$MODEL" --append-system-prompt-file "$CONDUCT" \
    --permission-mode bypassPermissions --setting-sources project --strict-mcp-config \
    --max-turns "$MAX_TURNS" --output-format json
