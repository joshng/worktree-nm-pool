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

`worktree-nm-pool` keeps a single **global** pool of `node_modules` directories
keyed by lockfile hash (default `$XDG_CACHE_HOME/nmpool`). Provisioning a
worktree is an `os.rename` from the pool into the worktree — atomic and O(1)
when they share a volume. When a worktree is removed, its `node_modules` is
moved back into the pool for reuse. A **total-bytes budget** (default 25 GiB)
bounds disk use across *all* projects via LRU eviction. Because the lockfile
both pins the dependency tree and implies the package manager, its hash is the
correct cache identity — so two clones of a repo share pooled trees.

## The tool: `bin/nmpool`

Pure Python 3 **stdlib only** — it *creates* `node_modules`, so it must not
depend on `node_modules` or any pip package.

```bash
nmpool install   [--worktree PATH]   # provision: pool hit via mv, else frozen install
nmpool uninstall [--worktree PATH]   # return node_modules to the pool, then gc
nmpool gc                            # evict LRU beyond the byte budget + prune dirty
nmpool --help
```

- **Pool:** one global dir (default `$XDG_CACHE_HOME/nmpool`, else `~/.cache/nmpool`),
  outside every repo — so there is nothing to gitignore.
- **Identity:** `sha256(<lockfile bytes>).hexdigest()[:16]`.
- **Lockfile priority:** `bun.lock` → `bun.lockb` → `pnpm-lock.yaml` →
  `package-lock.json` → `yarn.lock`. The detected lockfile selects the install
  command (`bun install --frozen-lockfile`, `pnpm install --frozen-lockfile`,
  `npm ci`, `yarn install --immutable`).
- **Pool entry:** `node_modules_<hash>_<slug>_<bytes>` (`slug` =
  `secrets.token_hex(4)`; `bytes` = measured tree size, so `gc` reads sizes from
  names without re-walking). Each holds a `.nmpool-hash` sentinel.
- **No locks:** claiming from the pool is atomic `os.rename` + retry on the next
  candidate if another worktree raced and grabbed it. Cross-volume pools
  (`EXDEV`) fall back to a real install with a warning (set `NMPOOL_CACHE_DIR`
  to a path on the worktree's volume to enable pooling there).

`install` is idempotent — a real `node_modules` whose sentinel matches the
lockfile is a fast no-op (stat + one file read; no install runs). A lockfile
that drifts under an existing worktree is reconciled **in place** (the package
manager evolves the tree), not via the pool.

## Configuration

Resolved **env var → config file → default**, where the config file is
`$XDG_CONFIG_HOME/nmpool/config.json` (else `~/.config/nmpool/config.json`):

| Setting | Env var | Config key | Default |
|---|---|---|---|
| Pool location | `NMPOOL_CACHE_DIR` | `cacheDir` | `$XDG_CACHE_HOME/nmpool` |
| Total-bytes budget | `NMPOOL_MAX_BYTES` | `maxCacheBytes` | `26843545600` (25 GiB) |

```json
{ "cacheDir": "/mnt/fast/nmpool", "maxCacheBytes": 53687091200 }
```

## Plugin / hook auto-wiring

- `.claude-plugin/plugin.json` — manifest.
- `hooks/hooks.json` — registers **only** `WorktreeRemove`.
  - **`WorktreeRemove`** → `hooks/on-worktree-remove.sh`: a *side-effect* hook
    (no decision control). For git, Claude removes the worktree itself via
    `git worktree remove`; this hook just runs best-effort `nmpool uninstall`
    (reading `worktree_path` from the JSON stdin) to rescue `node_modules` into
    the pool first. Exit code is ignored.
  - **No `WorktreeCreate` hook — on purpose.** That event *replaces* git's
    native worktree creation entirely (it exists for non-git VCS like SVN) and
    disables `.worktreeinclude`. A git tool must not own creation, so nmpool
    lets Claude create worktrees natively. Provisioning on creation is therefore
    not auto-wired — run `nmpool install` (the skill prompts this), or rely on
    lazy-ensure.
- `skills/worktree-nm-pool/SKILL.md` — model-invoked guidance.

The remove hook resolves the tool via `${CLAUDE_PLUGIN_ROOT}/bin/nmpool`,
falling back to a path relative to the script's own location.

## Install

Globally, via the plugin marketplace (in a Claude Code session):

```
/plugin marketplace add joshng/worktree-nm-pool
/plugin install worktree-nm-pool@joshng
```

For local development (ephemeral, reads the working tree directly):

```bash
claude --plugin-dir /path/to/worktree-nm-pool
```

When the plugin is enabled its `bin/` is auto-added to the Bash tool's PATH, so
`nmpool` resolves directly.

## Test

```bash
test/smoke.sh    # exercises pool mechanics with a faked install (NMPOOL_FAKE_INSTALL=1)
```
