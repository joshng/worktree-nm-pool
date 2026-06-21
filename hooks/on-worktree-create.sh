#!/usr/bin/env bash
# WorktreeCreate hook — OWNS worktree creation.
#
# This event "replaces default git behavior" (Claude Code docs): with the hook
# registered, Claude does NOT create the worktree itself — this script must.
#
# CONTRACT: create the worktree, print its absolute path to stdout, exit 0.
# Any non-zero exit BLOCKS creation, so we only fail when `git worktree add`
# itself fails. A failed `nmpool install` is non-blocking — lazy-ensure (a
# later `nmpool install`) backfills the node_modules.
set -u

# Resolve the plugin root robustly: prefer the env var Claude provides, else
# derive from this script's own location.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
NMPOOL="$PLUGIN_ROOT/bin/nmpool"

input="$(cat)"
field() {  # field <key>  — read a string field from the hook's JSON stdin
  printf '%s' "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null
}
worktree_path="$(field worktree_path)"
branch_name="$(field branch_name)"
base_path="$(field base_path)"

if [ -z "$worktree_path" ]; then
  echo "worktree-nm-pool: no worktree_path in hook input; cannot create worktree" 1>&2
  exit 1
fi
[ -n "$base_path" ] || base_path="$(pwd)"

# Create the worktree (git's chatter -> stderr so our stdout stays path-only).
mkdir -p "$(dirname "$worktree_path")" 2>/dev/null || true
if [ -n "$branch_name" ]; then
  if git -C "$base_path" show-ref --verify --quiet "refs/heads/$branch_name"; then
    git -C "$base_path" worktree add "$worktree_path" "$branch_name" 1>&2 || exit 1
  else
    git -C "$base_path" worktree add -b "$branch_name" "$worktree_path" 1>&2 || exit 1
  fi
else
  git -C "$base_path" worktree add "$worktree_path" 1>&2 || exit 1
fi

# Provision node_modules from the pool (best-effort; never blocks creation).
if ! python3 "$NMPOOL" install --worktree "$worktree_path" 1>&2; then
  echo "worktree-nm-pool: install failed for $worktree_path (non-blocking; lazy-ensure will backfill)" 1>&2
fi

# REQUIRED: print the path + exit 0 so creation succeeds.
printf '%s\n' "$worktree_path"
exit 0
