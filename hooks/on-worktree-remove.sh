#!/usr/bin/env bash
# WorktreeRemove hook — best-effort return node_modules to the pool.
# Post-event hook: exit code is ignored, so this is purely cleanup.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
NMPOOL="$PLUGIN_ROOT/bin/nmpool"

input="$(cat)"
worktree_path="$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worktree_path",""))' 2>/dev/null)"

if [ -n "$worktree_path" ]; then
  if ! python3 "$NMPOOL" uninstall --worktree "$worktree_path" 1>&2; then
    echo "worktree-nm-pool: uninstall failed for $worktree_path (ignored)" 1>&2
  fi
fi

exit 0
