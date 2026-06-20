# Global cache + byte budget — design

## Problem

The pool currently lives **per-project** at `<repo-main-root>/.node_modules_cache/`
and is capped by a blind **count** (`POOL_CAP = 12`). Two issues:

1. A count is a poor disk proxy — 12 tiny projects vs 12 monorepos differ by
   orders of magnitude.
2. A per-project cap doesn't bound *total* disk: N projects × cap grows
   unbounded as projects are added. The real constraint is global.

## Decisions

### 1. Global pool location (configurable)

The pool moves out of every repo to a single **global** directory, default
`$XDG_CACHE_HOME/nmpool` (falls back to `~/.cache/nmpool`). This:

- bounds *total* disk with one budget,
- enables cross-clone reuse (two clones of a repo share a lockfile hash → share
  pooled trees),
- **deletes** the in-repo pool machinery: `repo_main_root`, `git_common_dir`,
  `pool_dir`, `ensure_ignored` (`info/exclude`), and the `POOL_DIRNAME` concept.
  The pool is outside every repo, so there is nothing to gitignore.

Resolution precedence (location): `NMPOOL_CACHE_DIR` env → config file
`cacheDir` → `$XDG_CACHE_HOME/nmpool`.

### 2. Byte budget (configurable), default 25 GiB

`POOL_CAP` (count) is replaced by a **total-bytes** budget. `gc` sums entry
sizes, sorts LRU (oldest mtime first), and evicts until the total is within
budget. Dirty/mismatched entries are still pruned regardless.

Resolution precedence (budget): `NMPOOL_MAX_BYTES` env → config file
`maxCacheBytes` → `25 * 1024**3`.

### 3. Config file

`$XDG_CONFIG_HOME/nmpool/config.json` (falls back to `~/.config/nmpool/config.json`),
a JSON object: `{ "cacheDir": "...", "maxCacheBytes": 12345 }`. Both fields
optional. Env vars override the file; the file overrides defaults. The tool runs
standalone, so config is read directly from these locations (no harness
injection assumed).

### 4. Size metadata in the entry name

A pool entry's directory name carries its measured byte size:

```
node_modules_<hash>_<slug>_<bytes>
```

- Computed **once** at return-to-pool time; pooled entries are inert, so the
  size stays accurate while pooled.
- Stored in the *name* (not a file inside `node_modules`) → no `node_modules`
  pollution, immune to anything a PM does to contents, atomic (travels with the
  `mv`), lock-free, and O(1) to read at `gc` time (no re-walking 100k-file
  trees).
- `split("_")` is unambiguous: hash/slug are hex, bytes are digits, so a valid
  new entry has exactly 5 parts; a legacy 4-part entry has no size and is walked
  once then renamed forward.

Size measurement reuses a same-hash entry's size when one exists (identical
lockfile ⇒ identical tree ⇒ identical size), else walks once
(`os.walk(followlinks=False)`, summing `lstat` sizes; symlinks counted as their
own tiny size, never followed).

Return is staged to detect cross-volume *before* the walk:
`mv nm → <name>_pending`; measure; `mv → <name>_<bytes>`. A crashed `_pending`
self-heals on the next `gc` (walked + renamed forward).

### 5. Cross-volume (EXDEV) handling

O(1) `mv` requires pool and worktree on one filesystem. With a global pool, a
project on another volume hits `EXDEV`. Handling:

- **install** claim: on `EXDEV`, warn (suggest `NMPOOL_CACHE_DIR` on the
  project's volume) and fall back to a normal frozen install.
- **uninstall** return: on `EXDEV`, warn and discard `node_modules` (cannot
  pool cross-volume).

Automatic per-volume/project-local fallback pools are a **future enhancement**,
deliberately deferred — the configurable `NMPOOL_CACHE_DIR` covers the common
single-other-volume case.

## Out of scope

- Plugin `userConfig` UI (env + config file are sufficient and keep the tool
  harness-independent).
- Multi-volume automatic pooling.
- Count-based cap (removed entirely).

## Test plan (TDD, via `test/smoke.sh`)

- Point `NMPOOL_CACHE_DIR` at a temp dir on the test's volume so the global pool
  is exercised; remove the obsolete `info/exclude` case.
- Pool entry name carries a `_<bytes>` suffix after `uninstall`.
- `NMPOOL_MAX_BYTES` (and config-file `maxCacheBytes`) govern eviction: seed
  entries with known sizes, set a small budget, assert total-after ≤ budget and
  oldest evicted first.
- Existing pool-hit / miss / idempotent / symlink / lockfile-drift cases still
  pass against the global pool.
