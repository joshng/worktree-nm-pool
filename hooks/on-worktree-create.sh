#!/usr/bin/env bash
# WorktreeCreate hook — best-effort provision node_modules from the pool.
#
# CONTRACT (WorktreeCreate): must echo the worktree path to stdout and exit 0.
# Any non-zero exit BLOCKS worktree creation. We must NEVER block creation just
# because deps didn't install — a later `nmpool install` (lazy-ensure) backfills.
set -u

# Resolve the plugin root robustly: prefer the env var Claude provides, else
# derive from this script's own location (hooks run in the project cwd).
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
NMPOOL="$PLUGIN_ROOT/bin/nmpool"

input="$(cat)"
worktree_path="$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worktree_path",""))' 2>/dev/null)"

if [ -n "$worktree_path" ]; then
  if ! python3 "$NMPOOL" install --worktree "$worktree_path" 1>&2; then
    echo "worktree-nm-pool: install failed for $worktree_path (non-blocking; lazy-ensure will backfill)" 1>&2
  fi
else
  echo "worktree-nm-pool: no worktree_path in hook input; skipping" 1>&2
fi

# REQUIRED: echo the path + exit 0 so creation is never blocked.
printf '%s\n' "$worktree_path"
exit 0
