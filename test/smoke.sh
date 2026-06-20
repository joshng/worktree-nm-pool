#!/usr/bin/env bash
# Self-contained smoke test for nmpool pool mechanics.
# Fakes the install step (NMPOOL_FAKE_INSTALL=1) so no multi-GB install runs.
# Points the global pool at a temp dir (NMPOOL_CACHE_DIR) on the test's volume.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NMPOOL="$HERE/../bin/nmpool"
export NMPOOL_FAKE_INSTALL=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Global pool lives in the temp tree (same volume as the test repo).
export NMPOOL_CACHE_DIR="$TMP/cache"
POOL="$TMP/cache"
# Keep config-file lookups inside the sandbox so the dev's real config can't
# leak in; individual cases override XDG_CONFIG_HOME when testing the file.
export XDG_CONFIG_HOME="$TMP/xdg-empty"

pass=0
fail=0
check() {  # check <desc> <condition-result(0/1)>
  if [ "$2" -eq 0 ]; then
    echo "  ok: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1"
    fail=$((fail + 1))
  fi
}

nm() { python3 "$NMPOOL" "$@"; }

# ---------------------------------------------------------------------------
# Set up a fake repo (main worktree) with a package-lock.json.
# ---------------------------------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo '{"name":"x"}' > "$REPO/package.json"
echo '{"lockfileVersion":3,"v":1}' > "$REPO/package-lock.json"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

HASH="$(python3 -c "import hashlib; print(hashlib.sha256(open('$REPO/package-lock.json','rb').read()).hexdigest()[:16])")"
echo "lockfile hash = $HASH"

echo "== case 1: install miss creates node_modules + sentinel =="
out1="$(nm install --worktree "$REPO")"
echo "    -> $out1"
[ -d "$REPO/node_modules" ] && [ ! -L "$REPO/node_modules" ]; check "real node_modules dir exists" $?
[ "$(cat "$REPO/node_modules/.nmpool-hash")" = "$HASH" ]; check "sentinel matches hash" $?
echo "$out1" | grep -q "pool miss"; check "reported pool miss" $?

echo "== case 2: install again is a no-op (no install) =="
out2="$(nm install --worktree "$REPO")"
echo "    -> $out2"
echo "$out2" | grep -q "no-op"; check "reported no-op" $?

echo "== case 3: uninstall moves it to pool as node_modules_<hash>_<slug>_<bytes> =="
out3="$(nm uninstall --worktree "$REPO")"
echo "    -> $out3"
[ ! -e "$REPO/node_modules" ]; check "node_modules removed from worktree" $?
entry="$(ls -d "$POOL"/node_modules_"$HASH"_* 2>/dev/null | head -1 || true)"
[ -n "$entry" ]; check "pool entry created" $?
echo "$(basename "$entry")" | grep -Eq "^node_modules_${HASH}_[0-9a-f]{8}_[0-9]+$"; check "pool entry name carries size suffix" $?

echo "== case 4: install again is a POOL HIT via mv (no install ran) =="
out4="$(nm install --worktree "$REPO")"
echo "    -> $out4"
echo "$out4" | grep -q "pool hit"; check "reported pool hit" $?
[ -z "$(ls -d "$POOL"/node_modules_"$HASH"_* 2>/dev/null || true)" ]; check "pool entry consumed by mv" $?
[ -d "$REPO/node_modules" ] && [ ! -L "$REPO/node_modules" ]; check "real node_modules back in worktree" $?

echo "== case 5: a symlinked node_modules is replaced =="
nm uninstall --worktree "$REPO" >/dev/null   # park it in the pool
rm -rf "$TMP/fake-store"; mkdir -p "$TMP/fake-store"
ln -s "$TMP/fake-store" "$REPO/node_modules"
[ -L "$REPO/node_modules" ]; check "precondition: node_modules is a symlink" $?
out5="$(nm install --worktree "$REPO")"
echo "    -> $out5"
[ ! -L "$REPO/node_modules" ] && [ -d "$REPO/node_modules" ]; check "symlink replaced with real dir" $?

echo "== case 6: changed lockfile (new hash) => miss, not a stale hit =="
nm uninstall --worktree "$REPO" >/dev/null   # park current hash's dir in pool
echo '{"lockfileVersion":3,"v":2}' > "$REPO/package-lock.json"
HASH2="$(python3 -c "import hashlib; print(hashlib.sha256(open('$REPO/package-lock.json','rb').read()).hexdigest()[:16])")"
[ "$HASH2" != "$HASH" ]; check "new lockfile yields new hash" $?
out6="$(nm install --worktree "$REPO")"
echo "    -> $out6"
echo "$out6" | grep -q "pool miss"; check "changed lockfile => pool miss (no stale hit)" $?
[ "$(cat "$REPO/node_modules/.nmpool-hash")" = "$HASH2" ]; check "sentinel matches new hash" $?

echo "== case 7: byte budget evicts oldest until total <= NMPOOL_MAX_BYTES =="
rm -rf "$POOL"; mkdir -p "$POOL"
# Seed 5 entries of 10 bytes each (size encoded in name), increasing mtime.
for i in $(seq 1 5); do
  d="$POOL/node_modules_${HASH2}_seed000${i}_10"
  mkdir -p "$d"
  echo "$HASH2" > "$d/.nmpool-hash"
  touch -t "202001010${i}00" "$d" 2>/dev/null || touch "$d"
done
export NMPOOL_MAX_BYTES=25
out7="$(nm gc)"
unset NMPOOL_MAX_BYTES
echo "    -> $out7"
remaining="$(ls -d "$POOL"/node_modules_* 2>/dev/null | wc -l | tr -d ' ')"
echo "    entries after gc: $remaining"
[ "$remaining" -eq 2 ]; check "pool trimmed to 2 entries (2*10=20 <= 25)" $?
[ -d "$POOL/node_modules_${HASH2}_seed0005_10" ] && [ -d "$POOL/node_modules_${HASH2}_seed0004_10" ]; check "kept the two newest (LRU)" $?
[ ! -e "$POOL/node_modules_${HASH2}_seed0001_10" ]; check "evicted the oldest" $?

echo "== case 8: gc prunes dirty (no-sentinel) entries regardless of budget =="
dirty="$POOL/node_modules_${HASH2}_dirtyaaa_10"
mkdir -p "$dirty"   # no .nmpool-hash
nm gc >/dev/null
[ ! -e "$dirty" ]; check "dirty entry pruned by gc" $?

echo "== case 9: config-file maxCacheBytes governs eviction (no env override) =="
rm -rf "$POOL"; mkdir -p "$POOL"
mkdir -p "$TMP/xdg/nmpool"
echo '{"maxCacheBytes":25}' > "$TMP/xdg/nmpool/config.json"
for i in $(seq 1 5); do
  d="$POOL/node_modules_${HASH2}_cfg000${i}_10"
  mkdir -p "$d"; echo "$HASH2" > "$d/.nmpool-hash"
  touch -t "202001010${i}00" "$d" 2>/dev/null || touch "$d"
done
XDG_CONFIG_HOME="$TMP/xdg" nm gc >/dev/null
remaining9="$(ls -d "$POOL"/node_modules_* 2>/dev/null | wc -l | tr -d ' ')"
echo "    entries after gc: $remaining9"
[ "$remaining9" -eq 2 ]; check "config-file budget trimmed to 2 entries" $?

echo "== case 10: config-file cacheDir selects the pool location =="
ALTPOOL="$TMP/altcache"
mkdir -p "$TMP/xdg2/nmpool"
python3 -c "import json; open('$TMP/xdg2/nmpool/config.json','w').write(json.dumps({'cacheDir':'$ALTPOOL'}))"
echo '{"lockfileVersion":3,"v":3}' > "$REPO/package-lock.json"
rm -rf "$REPO/node_modules"
HASH3="$(python3 -c "import hashlib; print(hashlib.sha256(open('$REPO/package-lock.json','rb').read()).hexdigest()[:16])")"
( unset NMPOOL_CACHE_DIR; XDG_CONFIG_HOME="$TMP/xdg2" python3 "$NMPOOL" install --worktree "$REPO" >/dev/null
  unset NMPOOL_CACHE_DIR; XDG_CONFIG_HOME="$TMP/xdg2" python3 "$NMPOOL" uninstall --worktree "$REPO" >/dev/null )
entry10="$(ls -d "$ALTPOOL"/node_modules_"$HASH3"_* 2>/dev/null | head -1 || true)"
[ -n "$entry10" ]; check "pool entry created under config cacheDir" $?

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
