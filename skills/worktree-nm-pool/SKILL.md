---
name: worktree-nm-pool
description: Set up or save a git worktree's node_modules via a cache. Use BEFORE running `git worktree add` or `git worktree remove` in a bun/npm/pnpm/yarn project
---

# worktree-nm-pool

## Invariant (non-negotiable)

- **NEVER symlink `node_modules` or run bun/npm/pnpm/yarn install in a worktree** — run `nmpool install`.
- **NEVER `git worktree remove` before running `nmpool uninstall`** — it discards the pooled `node_modules`, forcing a full reinstall next time.

## Workflow

```bash
# After adding a worktree:
nmpool install --worktree /path/to/worktree     # or omit --worktree when CWD is inside it

# Before removing a worktree — run FIRST, then remove:
nmpool uninstall --worktree /path/to/worktree
git worktree remove /path/to/worktree
```

- `install` provisions a real `node_modules` — a cache hit is an instant move; a
  miss runs the lockfile's frozen install once. Idempotent: a no-op when
  `node_modules` already matches the lockfile.
- `uninstall` returns the dir to the cache for the next worktree to reuse.

## Invoking nmpool

When this plugin is enabled, `nmpool` is on the Bash tool's PATH — call it
directly. Otherwise run it by path: `python3 <plugin-root>/bin/nmpool ...`.
`nmpool --help` documents the rest.

## Automatic wiring (partial)

*If* this plugin's hooks are active, claude-managed worktree **removal** runs
`nmpool uninstall` for you automatically (best-effort side-effect). There is no
create hook — provisioning is **not** automatic, so still run `nmpool install`
yourself after a worktree is created (it's idempotent — a safe no-op if already
provisioned).
