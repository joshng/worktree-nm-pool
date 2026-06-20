#!/usr/bin/env bash
# Self-contained smoke test for nmpool pool mechanics.
# Fakes the install step (NMPOOL_FAKE_INSTALL=1) so no multi-GB install runs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NMPOOL="$HERE/../bin/nmpool"
export NMPOOL_FAKE_INSTALL=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

POOL="$REPO/.node_modules_cache"
HASH="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open('$REPO/package-lock.json','rb').read()).hexdigest()[:16])")"
echo "lockfile hash = $HASH"

echo "== case 1: install miss creates node_modules + sentinel =="
out1="$(nm install --worktree "$REPO")"
echo "    -> $out1"
[ -d "$REPO/node_modules" ] && [ ! -L "$REPO/node_modules" ]; check "real node_modules dir exists" $?
[ "$(cat "$REPO/node_modules/.nmpool-hash")" = "$HASH" ]; check "sentinel matches hash" $?
echo "$out1" | grep -q "pool miss"; check "reported pool miss" $?

echo "== case 1b: pool ignored via .git/info/exclude, .gitignore untouched =="
grep -q '^\.node_modules_cache/$' "$REPO/.git/info/exclude"; check "pool dir listed in .git/info/exclude" $?
{ [ ! -f "$REPO/.gitignore" ] || ! grep -q "node_modules_cache" "$REPO/.gitignore"; }; check ".gitignore not modified" $?

echo "== case 2: install again is a no-op (no install) =="
out2="$(nm install --worktree "$REPO")"
echo "    -> $out2"
echo "$out2" | grep -q "no-op"; check "reported no-op" $?

echo "== case 3: uninstall moves it to pool as node_modules_<hash>_<slug> =="
out3="$(nm uninstall --worktree "$REPO")"
echo "    -> $out3"
[ ! -e "$REPO/node_modules" ]; check "node_modules removed from worktree" $?
entry="$(ls -d "$POOL"/node_modules_"$HASH"_* 2>/dev/null | head -1 || true)"
[ -n "$entry" ]; check "pool entry created" $?
echo "$(basename "$entry")" | grep -Eq "^node_modules_${HASH}_[0-9a-f]{8}$"; check "pool entry name format" $?

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

echo "== case 7: LRU evicts beyond 12 =="
# Seed 15 fake pool entries for HASH2 with increasing mtimes, then gc.
nm uninstall --worktree "$REPO" >/dev/null   # 1 entry now in pool
mkdir -p "$POOL"
for i in $(seq 1 14); do
  d="$POOL/node_modules_${HASH2}_seed$(printf '%04d' "$i")"
  mkdir -p "$d"
  echo "$HASH2" > "$d/.nmpool-hash"
  touch -t "20200101$(printf '%02d' $((i % 24)))00" "$d" 2>/dev/null || touch "$d"
done
total_before="$(ls -d "$POOL"/node_modules_* | wc -l | tr -d ' ')"
echo "    entries before gc: $total_before"
out7="$(nm gc --worktree "$REPO")"
echo "    -> $out7"
total_after="$(ls -d "$POOL"/node_modules_* | wc -l | tr -d ' ')"
echo "    entries after gc: $total_after"
[ "$total_after" -eq 12 ]; check "pool capped at 12 entries" $?

echo "== case 8: gc prunes dirty (no-sentinel) entries =="
dirty="$POOL/node_modules_${HASH2}_dirtyaaa"
mkdir -p "$dirty"   # no .nmpool-hash
nm gc --worktree "$REPO" >/dev/null
[ ! -e "$dirty" ]; check "dirty entry pruned by gc" $?

echo
echo "==== $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
