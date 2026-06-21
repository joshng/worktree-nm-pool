---
name: worktree-nm-pool
description: Set up or save a git worktree's node_modules via a cache. Use BEFORE running `git worktree add` or `git worktree remove` in a bun/npm/pnpm/yarn project
---

# worktree-nm-pool

## Invariant (non-negotiable)

- **To PROVISION a worktree's `node_modules`** (set it up to match the lockfile): run `nmpool install` — never a from-scratch `bun/npm/pnpm/yarn install`, never a symlink.
- **To CHANGE dependencies** (`bun add`/`remove`, version bumps): use the package manager directly. `nmpool` only provisions the *existing* lockfile (frozen install), so it can't add deps and will report `no-op`. After the change, run `nmpool install` to re-stamp the cache.
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
