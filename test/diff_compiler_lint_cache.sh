#!/bin/sh
# `medaka lint --cache` differential gate (#395).
#
# A cache without a gate is a silent-wrongness generator: every bug it can have
# looks like "lint said nothing and exited 0", which in this repo is
# indistinguishable from "lint passed". So this gate does not check that the
# cache is FAST — it checks that it is INVISIBLE. Every scenario asserts that a
# cached run's bytes equal what an uncached run would have printed.
#
# There is no golden file, deliberately: the oracle is the UNCACHED run of the
# same binary over the same tree, computed fresh each time. A golden could rot
# into agreement with a broken cache; this cannot.
#
#   1. equivalence           — cold == populate == warm, over a real corpus
#   2. edit invalidation     — edit a file; warm == cold on the edited tree
#   3. CROSS-FILE invalidation — the one that earns the gate (see below)
#   4. forged stale entry    — wrong hash is ignored, output still correct
#   5. rule-set change       — a foreign stamp invalidates every entry
#   6. concurrency           — parallel runs stay correct and leave no torn shard
#
# Scenarios 1-3 also assert the CACHE HIT COUNT, via the one thing a hit is
# observable through without adding CLI surface: a hit writes no shard, a miss
# rewrites one. So "N shards changed" == "N misses". That is what proves the
# cache is actually hitting rather than silently re-linting everything and
# passing scenario 1 trivially. Wall-clock is deliberately NOT asserted — timing
# gates are noisy and this suite runs on shared hosted runners.
#
# Hermetic: the corpus, the cwd and therefore the cache dir all live in one
# mktemp -d, so this gate never touches the repo's own .medaka/ and cannot race
# another gate.
#
# Usage:  sh test/diff_compiler_lint_cache.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"

[ -x "$MEDAKA" ] || { echo "build ./medaka first (missing $MEDAKA)"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/medaka_lint_cache_XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

pass=0
fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

# POSIX-clean diff of two files (no process substitution — run_gates.sh invokes
# gates with strict /bin/sh, which would SKIP this gate otherwise).
same() { diff "$1" "$2" >/dev/null 2>&1; }

CACHE="$WORK/.medaka/lint-cache"
# `medaka lint --cache` roots its cache at the project root, so run everything
# from $WORK. A medaka.toml makes that root explicit rather than relying on the
# no-manifest cwd fallback.
: > "$WORK/medaka.toml"
cd "$WORK" || exit 2

# Snapshot each shard's INODE — the miss counter. A hit leaves the shard
# untouched; a miss rewrites it, and every write goes through temp+rename, which
# always installs a NEW inode. So "inode changed" == "this file was re-linted".
#
# Inodes, not checksums: a miss re-lints the file and writes back the SAME bytes,
# so a content diff cannot tell a hit from a miss at all — it would report 0
# changes for a cache that never hit once, and scenario 1c (the assertion that
# the cache actually hits) would pass vacuously. Not mtime either: sub-second
# runs versus 1-second stat granularity, and `stat` needs a dual-platform dance
# (-c %Y / -f %m). `ls -i` is POSIX and exact.
shard_state() {
  if [ -d "$CACHE" ]; then
    for f in "$CACHE"/*.json; do
      [ -f "$f" ] || continue
      printf '%s %s\n' "$(basename "$f")" "$(ls -i "$f" | awk '{print $1}')"
    done | sort
  fi
}

# Shards rewritten between two snapshots = misses. `comm -13` = lines only in
# the NEW state, i.e. a shard that is new or has a new inode.
changed_shards() {
  comm -13 "$1" "$2" | wc -l | tr -d ' '
}

# ── the corpus ────────────────────────────────────────────────────────────────
# A REAL one: test/lint_fixtures carries ~24 files that trip most of the rule
# set (and exercise inline `-- lint-disable-*` directives, which the cache also
# round-trips). Copied in rather than linted in place so scenarios 2/3 can edit
# it. Copy only .mdk — the .expected goldens belong to the other lint gates.
mkdir -p "$WORK/corpus"
cp "$ROOT"/test/lint_fixtures/*.mdk "$WORK/corpus/" 2>/dev/null
n_fixtures="$(ls "$WORK"/corpus/*.mdk 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_fixtures" -ge 2 ] || { echo "corpus missing (test/lint_fixtures/*.mdk)"; exit 2; }

# Scenario 3's pair: two files sharing one structurally identical, non-trivial
# body (>= dupComplexityThreshold = 10 AST nodes), in DIFFERENT files, which is
# what rule-duplicate-body fires on.
dup_body() {
  cat <<EOF
-- $1
sharedShape : Int -> Int -> Int
sharedShape a b =
  if a > b then
    (a * 2) + (b * 3) - 1
  else
    (b * 2) + (a * 3) + 1
EOF
}
dup_body dupA > "$WORK/corpus/dup_a.mdk"
dup_body dupB > "$WORK/corpus/dup_b.mdk"

lint_plain()  { "$MEDAKA" lint corpus > "$1" 2>&1; printf '%s\n' "$?" >> "$1"; }
lint_cached() { "$MEDAKA" lint --cache corpus > "$1" 2>&1; printf '%s\n' "$?" >> "$1"; }

# ── 1. equivalence: cold == populate == warm ─────────────────────────────────
# Also the exit-code check: each helper appends the status to the captured
# output, so a cache that changed only the exit code still fails here.
rm -rf "$CACHE"
lint_plain "$WORK/cold.txt"
lint_cached "$WORK/populate.txt"
before="$WORK/s1.before"; after="$WORK/s1.after"
shard_state > "$before"
lint_cached "$WORK/warm.txt"
shard_state > "$after"

if same "$WORK/cold.txt" "$WORK/populate.txt"; then
  ok "1a populate run == uncached run"
else
  bad "1a populate run == uncached run" "$(diff "$WORK/cold.txt" "$WORK/populate.txt" | head -5)"
fi

if same "$WORK/cold.txt" "$WORK/warm.txt"; then
  ok "1b warm run == uncached run (byte-identical, incl. exit code)"
else
  bad "1b warm run == uncached run" "$(diff "$WORK/cold.txt" "$WORK/warm.txt" | head -5)"
fi

# THE HIT-COUNT ASSERTION: a fully-warm run must miss on NOTHING. Without this,
# a cache that never hits would sail through every equivalence check above.
n_changed="$(changed_shards "$before" "$after")"
if [ "$n_changed" -eq 0 ]; then
  ok "1c warm run hit every file (0 shards rewritten)"
else
  bad "1c warm run hit every file" "$n_changed shard(s) rewritten — the cache is missing, not hitting"
fi

# A shard per source file, or the cache is not covering the corpus.
n_shards="$(ls "$CACHE"/*.json 2>/dev/null | wc -l | tr -d ' ')"
n_srcs="$(ls "$WORK"/corpus/*.mdk 2>/dev/null | wc -l | tr -d ' ')"
if [ "$n_shards" -eq "$n_srcs" ]; then
  ok "1d one shard per source file ($n_shards)"
else
  bad "1d one shard per source file" "$n_shards shards for $n_srcs sources"
fi

# ── 2. edit invalidation ─────────────────────────────────────────────────────
# Append a finding-bearing decl to one cached file. The warm run must report it,
# and must re-lint ONLY that file.
cat >> "$WORK/corpus/bool_simplify.mdk" <<'EOF'

editedProbe : Bool -> Bool
editedProbe b = if b then True else False
EOF
before="$WORK/s2.before"; after="$WORK/s2.after"
shard_state > "$before"
lint_cached "$WORK/warm2.txt"
shard_state > "$after"
lint_plain "$WORK/cold2.txt"

if same "$WORK/cold2.txt" "$WORK/warm2.txt"; then
  ok "2a edited file: warm == uncached on the edited tree"
else
  bad "2a edited file: warm == uncached" "$(diff "$WORK/cold2.txt" "$WORK/warm2.txt" | head -5)"
fi

n_changed="$(changed_shards "$before" "$after")"
if [ "$n_changed" -eq 1 ]; then
  ok "2b edit re-linted exactly the edited file (1 shard rewritten)"
else
  bad "2b edit re-linted exactly the edited file" "$n_changed shards rewritten, expected 1"
fi

# ── 3. CROSS-FILE INVALIDATION — the scenario that earns this gate ───────────
# dup_a.mdk and dup_b.mdk share a body, so rule-duplicate-body reports BOTH.
# Now edit B so the bodies differ. A is UNCHANGED and therefore cache-HITS — yet
# A's finding must disappear, because it only ever existed on account of B.
#
# This is what fails if someone caches the cross-file rule's FINDINGS instead of
# its per-file INPUTS (the occurrence list). The findings-cache version of this
# code passes scenarios 1, 2, 4, 5 and 6 and fails only here.
# Keyed on OUR pair's function name, not on the rule name: test/lint_fixtures has
# its own duplicate-body pair (bind_chain_to_do.mdk <-> match_to_map.mdk) which
# stays reported throughout, so a bare `grep rule-duplicate-body` would match
# that and never fail.
dup_pair_reported() { grep -q "rule-duplicate-body.*sharedShape\|'sharedShape'.*rule-duplicate-body" "$1"; }

lint_cached "$WORK/warm3_pre.txt"
if dup_pair_reported "$WORK/warm3_pre.txt"; then
  ok "3a precondition: duplicate-body fires on the A/B pair"
else
  bad "3a precondition: duplicate-body fires on the A/B pair" "rule never fired — scenario 3 would be vacuous"
fi

# Break the duplication by changing B's body shape (not just its names).
cat > "$WORK/corpus/dup_b.mdk" <<'EOF'
-- dupB, no longer structurally identical to dupA
sharedShape : Int -> Int -> Int
sharedShape a b =
  match a > b
    True => (a * 7) - (b * 5) + (a - b) - 3
    False => (b * 11) + (a * 13) - (a + b) + 9
EOF
before="$WORK/s3.before"; after="$WORK/s3.after"
shard_state > "$before"
lint_cached "$WORK/warm3.txt"
shard_state > "$after"
lint_plain "$WORK/cold3.txt"

if same "$WORK/cold3.txt" "$WORK/warm3.txt"; then
  ok "3b cross-file: warm == uncached after breaking the duplication"
else
  bad "3b cross-file: warm == uncached after breaking the duplication" \
      "$(diff "$WORK/cold3.txt" "$WORK/warm3.txt" | head -8)"
fi

# The explicit statement of the bug, independent of the diff above: A's finding
# must be GONE even though A never changed.
if dup_pair_reported "$WORK/warm3.txt"; then
  bad "3c cross-file: A's stale finding retracted though A cache-HIT" \
      "duplicate-body still reported for sharedShape after the duplication was broken — cross-file FINDINGS are being cached"
else
  ok "3c cross-file: A's stale finding retracted though A cache-HIT"
fi

# ...and A really did hit: only B's shard may have been rewritten. If A had
# missed, 3c would pass for the wrong reason (it re-linted rather than joined).
n_changed="$(changed_shards "$before" "$after")"
if [ "$n_changed" -eq 1 ]; then
  ok "3d only the edited file re-linted — A hit and the join still retracted it"
else
  bad "3d only the edited file re-linted" "$n_changed shards rewritten, expected 1 (A must HIT for 3c to mean anything)"
fi

# ── 4. forged stale entry ────────────────────────────────────────────────────
# Corrupt the stored content hash of one shard. It must be ignored (a miss), not
# trusted, and the output must be unaffected.
lint_cached "$WORK/warm4_pre.txt"
victim="$(ls "$CACHE"/*.json 2>/dev/null | head -1)"
if [ -n "$victim" ]; then
  sed 's/"hash":"[^"]*"/"hash":"0.0.0"/' "$victim" > "$victim.tmp" && mv "$victim.tmp" "$victim"
  lint_cached "$WORK/warm4.txt"
  lint_plain "$WORK/cold4.txt"
  if same "$WORK/cold4.txt" "$WORK/warm4.txt"; then
    ok "4a forged hash ignored — output still correct"
  else
    bad "4a forged hash ignored" "$(diff "$WORK/cold4.txt" "$WORK/warm4.txt" | head -5)"
  fi
else
  bad "4a forged hash ignored" "no shard to forge"
fi

# Truncated / garbage shards must be misses too, never a crash or a wrong answer.
# A truncated shard is what a NON-atomic writer would leave behind mid-write, so
# this also pins the behaviour the temp+rename staging exists to make impossible.
printf '{"version":1,"stamp":"x","path":"corpus/clean.mdk","hash":' > "$victim"
printf 'not json at all' > "$CACHE/zzz_garbage-1.json"
lint_cached "$WORK/warm4b.txt"
lint_plain "$WORK/cold4b.txt"
if same "$WORK/cold4b.txt" "$WORK/warm4b.txt"; then
  ok "4b truncated/garbage shard ignored — output still correct"
else
  bad "4b truncated/garbage shard ignored" "$(diff "$WORK/cold4b.txt" "$WORK/warm4b.txt" | head -5)"
fi

# ── 5. rule-set change ───────────────────────────────────────────────────────
# 5a: a DIFFERENT BINARY must not reuse this binary's entries — the real
# mechanism, end to end, not a re-implementation of the hash. `medaka_variant` is
# ./medaka with trailing bytes appended: a different file (so a different stamp)
# that still executes identically, since ELF/Mach-O loaders ignore trailing
# garbage. That stands in for "someone edited a rule and rebuilt": same rule
# names, different compiler.
#
# This is the assertion that the whole `ruleSetStamp` design exists for. If it
# ever regresses to something that does not track the binary — a version string,
# a hand-bumped constant, a hash of rule NAMES — a changed rule would silently
# reuse the old rule's findings, and this fails.
rm -rf "$CACHE"
lint_cached "$WORK/warm5_pre.txt"
cp "$MEDAKA" "$WORK/medaka_variant"
printf '\n# not part of the ELF image; changes the file, not the behaviour\n' >> "$WORK/medaka_variant"
chmod +x "$WORK/medaka_variant"

before="$WORK/s5.before"; after="$WORK/s5.after"
shard_state > "$before"
MEDAKA_ROOT="$ROOT" "$WORK/medaka_variant" lint --cache corpus > "$WORK/warm5.txt" 2>&1
printf '%s\n' "$?" >> "$WORK/warm5.txt"
shard_state > "$after"
lint_plain "$WORK/cold5.txt"

if same "$WORK/cold5.txt" "$WORK/warm5.txt"; then
  ok "5a a different binary: output still correct"
else
  bad "5a a different binary: output still correct" "$(diff "$WORK/cold5.txt" "$WORK/warm5.txt" | head -5)"
fi

n_changed="$(changed_shards "$before" "$after")"
if [ "$n_changed" -eq "$n_srcs" ]; then
  ok "5b a different binary invalidated EVERY entry ($n_changed re-linted)"
else
  bad "5b a different binary invalidated every entry" \
      "$n_changed of $n_srcs re-linted — an entry survived a COMPILER CHANGE; the rule-set stamp is not tracking the binary"
fi

# 5c: and a forged/unknown stamp is a miss rather than a guess — the same check
# from the shard side, covering a cache written by any compiler we cannot
# identify.
for f in "$CACHE"/*.json; do
  sed 's/"stamp":"[^"]*"/"stamp":"stamp-from-another-compiler"/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
before="$WORK/s5c.before"; after="$WORK/s5c.after"
shard_state > "$before"
lint_cached "$WORK/warm5c.txt"
shard_state > "$after"

if same "$WORK/cold5.txt" "$WORK/warm5c.txt"; then
  ok "5c foreign rule-set stamp: output still correct"
else
  bad "5c foreign rule-set stamp: output still correct" "$(diff "$WORK/cold5.txt" "$WORK/warm5c.txt" | head -5)"
fi

n_changed="$(changed_shards "$before" "$after")"
if [ "$n_changed" -eq "$n_srcs" ]; then
  ok "5d foreign rule-set stamp invalidated EVERY entry ($n_changed re-linted)"
else
  bad "5d foreign rule-set stamp invalidated every entry" "$n_changed of $n_srcs re-linted — some entry survived a rule-set change"
fi

# ── 6. concurrency ───────────────────────────────────────────────────────────
# Four cold-start runs at once, all writing the same shards. Shards are staged in
# a per-process mktemp -d inside the cache dir and rename(2)'d into place, so a
# reader sees each shard whole or not at all. `medaka build` once shipped the
# opposite (scratch keyed on the output basename in shared /tmp) and produced a
# stable-looking WRONG binary in 19 of 20 runs — so this is checked, not assumed.
rm -rf "$CACHE"
i=1
while [ "$i" -le 4 ]; do
  ( "$MEDAKA" lint --cache corpus > "$WORK/conc_$i.txt" 2>&1; printf '%s\n' "$?" >> "$WORK/conc_$i.txt" ) &
  i=$((i+1))
done
wait

conc_ok=1
i=1
while [ "$i" -le 4 ]; do
  same "$WORK/cold5.txt" "$WORK/conc_$i.txt" || conc_ok=0
  i=$((i+1))
done
if [ "$conc_ok" -eq 1 ]; then
  ok "6a 4 concurrent cold runs all produced correct output"
else
  bad "6a 4 concurrent cold runs all produced correct output" "$(diff "$WORK/cold5.txt" "$WORK/conc_1.txt" | head -5)"
fi

# The cache they raced to write must still be usable and correct — a torn shard
# would either be a miss (safe) or, if the tear happened to parse, a wrong hit.
lint_cached "$WORK/warm6.txt"
if same "$WORK/cold5.txt" "$WORK/warm6.txt"; then
  ok "6b cache written under concurrency is correct on the next run"
else
  bad "6b cache written under concurrency is correct on the next run" "$(diff "$WORK/cold5.txt" "$WORK/warm6.txt" | head -5)"
fi

# No staging dirs left behind, and every shard is a shard.
leaked="$(ls -d "$CACHE"/.staging_* 2>/dev/null | wc -l | tr -d ' ')"
if [ "$leaked" -eq 0 ]; then
  ok "6c no staging dirs leaked"
else
  bad "6c no staging dirs leaked" "$leaked staging dir(s) left in $CACHE"
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
