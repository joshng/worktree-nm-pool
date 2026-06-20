# worktree-nm-pool

A standalone, project-agnostic Claude Code plugin that **pools git-worktree
`node_modules` directories**. Each worktree gets a *real* `node_modules`
directory (not a symlink) without re-installing 1–2 GB per worktree.

## Why

Next.js / Turbopack reject a `node_modules` that resolves outside the project
root, so the common "symlink to a shared store" trick fails in a worktree with
a root-resolution error. The worktree needs a real directory. But running a
full `npm ci` / `bun install` for every throwaway worktree is slow and wastes
gigabytes.

`worktree-nm-pool` keeps a pool of `node_modules` directories keyed by lockfile
hash at `<repo-main-root>/.node_modules_cache/`. Provisioning a worktree is an
`os.rename` from the pool into the worktree — atomic and O(1) when they share a
volume (which all worktrees of a repo do). When a worktree is removed, its
`node_modules` is moved back into the pool for reuse. An LRU cap (12 entries)
bounds disk use. Because the lockfile both pins the dependency tree and implies
the package manager, its hash is the correct cache identity.

## The tool: `bin/nmpool`

Pure Python 3 **stdlib only** — it *creates* `node_modules`, so it must not
depend on `node_modules` or any pip package.

```bash
nmpool install   [--worktree PATH]   # provision: pool hit via mv, else frozen install
nmpool uninstall [--worktree PATH]   # return node_modules to the pool, then gc
nmpool gc        [--worktree PATH]   # enforce LRU cap (12) + prune dirty entries
nmpool --help
```

- **Pool root:** `dirname(git rev-parse --git-common-dir)` + `/.node_modules_cache/`
  (the primary worktree's root, shared by all worktrees of the repo).
- **Identity:** `sha256(<lockfile bytes>).hexdigest()[:16]`.
- **Lockfile priority:** `bun.lock` → `bun.lockb` → `pnpm-lock.yaml` →
  `package-lock.json` → `yarn.lock`. The detected lockfile selects the install
  command (`bun install --frozen-lockfile`, `pnpm install --frozen-lockfile`,
  `npm ci`, `yarn install --immutable`).
- **Pool entry:** `node_modules_<hash>_<slug>` (`slug` = `secrets.token_hex(4)`),
  so multiple worktrees can share a hash. Each holds a `.nmpool-hash` sentinel.
- **No locks:** claiming from the pool is atomic `os.rename` + retry on the next
  candidate if another worktree raced and grabbed it. Cross-volume pools
  (`EXDEV`) fall back to a real install with a warning.

`install` is idempotent — a real `node_modules` whose sentinel matches the
lockfile is a fast no-op (stat + one file read; no install runs).

The tool ignores the pool via git's per-clone `<git-common-dir>/info/exclude`
(idempotently) rather than the tracked `.gitignore` — so no project-tracked
file is touched, and the single write covers every worktree of the repo.

## Plugin / hook auto-wiring

- `.claude-plugin/plugin.json` — manifest.
- `hooks/hooks.json` — registers `WorktreeCreate` and `WorktreeRemove` (neither
  event takes a matcher).
  - **`WorktreeCreate`** → `hooks/on-worktree-create.sh`: best-effort
    `nmpool install`, then **echoes the worktree path and exits 0**. This is
    required — `WorktreeCreate` blocks creation on *any* non-zero exit, so the
    hook never fails the build just because deps didn't install; lazy-ensure
    backfills later.
  - **`WorktreeRemove`** → `hooks/on-worktree-remove.sh`: best-effort
    `nmpool uninstall` (post-event; exit code ignored).
- `skills/worktree-nm-pool/SKILL.md` — model-invoked guidance.

Hook scripts resolve the tool via `${CLAUDE_PLUGIN_ROOT}/bin/nmpool`, falling
back to a path relative to the script's own location.

## Install (local dev)

```bash
claude --plugin-dir /path/to/worktree-nm-pool
```

Add `bin/` to your PATH (the plugin's `bin/` is auto-added to the Bash tool's
PATH while enabled) to call `nmpool` directly.

## Test

```bash
test/smoke.sh    # exercises pool mechanics with a faked install (NMPOOL_FAKE_INSTALL=1)
```
