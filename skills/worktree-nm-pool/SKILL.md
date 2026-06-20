---
name: worktree-nm-pool
description: Set up node_modules in a git worktree without re-installing 1-2 GB or hitting the Turbopack symlink error. Use when working with git worktrees, fixing a "node_modules is a symlink"/Next/Turbopack root error in a worktree, or setting up a worktree's dependencies.
---

# worktree-nm-pool

## Invariant (non-negotiable)

**NEVER symlink `node_modules` in a git worktree.** Run `nmpool install`.

Next.js / Turbopack reject a `node_modules` that resolves outside the project
root — a symlink to a shared store fails with a root-resolution error. The
worktree needs a *real* `node_modules` directory. `nmpool` gives you one
without paying the full install cost per worktree.

## Manual workflow (the load-bearing steps)

This is the whole workflow — run these yourself; nothing else is required.

```bash
# Right after creating a worktree:
nmpool install --worktree /path/to/worktree     # or omit --worktree inside it

# Right before removing a worktree:
nmpool uninstall --worktree /path/to/worktree
```

- `install` provisions a real `node_modules`: a **pool hit** moves a cached dir
  in via O(1) `os.rename`; a **miss** runs the lockfile's frozen install
  (`bun install --frozen-lockfile` / `pnpm install --frozen-lockfile` /
  `npm ci` / `yarn install --immutable`) and records a sentinel. It is
  idempotent — if `node_modules` already matches the lockfile it's a fast
  no-op (no install runs).
- `uninstall` returns the dir to the pool for the next worktree to reuse, then
  trims the pool to its LRU cap.
- `nmpool gc` enforces the cap / prunes dirty entries on demand.

Switched branches and the lockfile changed? Just re-run `nmpool install` — a
new lockfile hash is a miss, never a stale hit.

## Running `nmpool` standalone

`nmpool` is plain Python 3 (stdlib only) and works outside any hook. It lives
at `<plugin-root>/bin/nmpool`. To invoke it:

```bash
# Directly by path:
python3 /path/to/worktree-nm-pool/bin/nmpool install --worktree .

# Or put it on PATH once (recommended), then just `nmpool ...`:
ln -s /path/to/worktree-nm-pool/bin/nmpool /usr/local/bin/nmpool
```

(When this plugin is enabled in Claude Code, its `bin/` is on the Bash tool's
PATH automatically, so `nmpool` resolves with no symlink.)

`nmpool --help` documents everything.

## How the pool works

- **Pool:** `<repo-main-root>/.node_modules_cache/`, shared by every worktree
  of the repo (main root = `dirname(git rev-parse --git-common-dir)`).
- **Identity:** `sha256(lockfile)[:16]`. The lockfile pins the exact tree and
  implies the package manager. Priority: `bun.lock` > `bun.lockb` >
  `pnpm-lock.yaml` > `package-lock.json` > `yarn.lock`.
- **Move, don't copy:** provisioning is an `os.rename` (atomic, O(1)) between
  pool and worktree on the same volume. No locks — claiming is atomic-rename +
  retry on race.
- **Sentinel:** each `node_modules` holds `.nmpool-hash` = its hash, used to
  verify identity and detect dirty dirs.
- **LRU cap:** 12 pool entries; `uninstall`/`gc` evict the oldest beyond it.

## Optional: automatic wiring via hooks

This is pure enhancement — the manual steps above stand on their own. *If* this
plugin's hooks are active, worktree create/remove run `nmpool install` /
`nmpool uninstall` for you automatically (best-effort; creation is never
blocked if an install fails — you can always backfill by running
`nmpool install` yourself). No hook is a prerequisite for anything here.
