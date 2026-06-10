#!/usr/bin/env bash
# fuzz_diff.sh — differential fuzzer driver for the Medaka compiler (Stage-0/1 MVP).
#
# Generates well-typed Medaka programs with dev/fuzz_gen.exe and checks them two
# ways:
#   Tier-A (oracle + invariants): run each program through the OCaml oracle
#     (`main.exe run <file>`).  The generator emits oracle-independent invariants
#     inline as `println ("INV " ++ debug <bool>)` lines that MUST be `INV True`
#     (Eq reflexive/symmetric, (a==b)==(eq a b), (a<b)==(lt a b), Ord
#     totality/antisymmetry/transitivity, arithmetic identities a+0/a*1/(a+b)-b).
#     Any `INV False`, or a nonzero oracle exit (a generator well-typedness hole),
#     is a finding.
#   Tier-B (oracle vs selfhost tree-walker): run the SAME program through the
#     selfhost dict-passing tree-walker
#       main.exe run selfhost/eval_dict_main.mdk runtime.mdk core.mdk <file>
#     and diff stdout against the oracle.  Any difference is a finding.
#
# BATCHING: the selfhost path pays a ~480ms runtime+core parse tax PER PROCESS.
# We amortize it by generating each seed as a --batch of K independent blocks
# (sharing a fresh-name counter so names never collide) in ONE file, so one
# selfhost process covers K programs' worth of checks.
#
# Findings are classified against test/fuzz_allowlist.txt (documented-open gaps).
# Unmatched findings are dumped to test/fuzz_failures/seed_N.mdk with both outputs.
#
# Usage: test/fuzz_diff.sh [START_SEED] [COUNT] [TIER] [BATCH]
#   defaults: START_SEED=1 COUNT=200 TIER=2 BATCH=12
#
# Run from the repo root (or worktree root); paths are resolved relative to it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

GEN="$ROOT/_build/default/dev/fuzz_gen.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost/eval_dict_main.mdk"
ALLOWLIST="$ROOT/test/fuzz_allowlist.txt"
FAILDIR="$ROOT/test/fuzz_failures"

START="${1:-1}"
COUNT="${2:-200}"
TIER="${3:-2}"
BATCH="${4:-12}"

for f in "$GEN" "$MAIN"; do
  [ -x "$f" ] || { echo "missing $f — run: dune build --root ."; exit 2; }
done
mkdir -p "$FAILDIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/prog.mdk"; ORA="$TMP/ora.txt"; SH="$TMP/sh.txt"

# allowlist match: returns 0 if the source file OR the given text matches any
# documented-gap pattern.
allowlisted() {
  local srcfile="$1" extra="$2"
  [ -f "$ALLOWLIST" ] || return 1
  grep -vE '^\s*(#|$)' "$ALLOWLIST" | while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if grep -Eq "$pat" "$srcfile" 2>/dev/null || printf '%s' "$extra" | grep -Eq "$pat" 2>/dev/null; then
      echo MATCH; break
    fi
  done | grep -q MATCH
}

dump_failure() {
  local seed="$1" kind="$2"
  local out="$FAILDIR/seed_${seed}.mdk"
  {
    echo "-- FUZZ FAILURE  seed=$seed  tier=$TIER  batch=$BATCH  kind=$kind"
    echo "-- reproduce: $GEN --seed $seed --tier $TIER --batch $BATCH"
    echo "-- ============================== SOURCE =============================="
  } > "$out"
  cat "$SRC" >> "$out"
  {
    echo "-- ============================== ORACLE OUT =========================="
    sed 's/^/-- /' "$ORA"
    echo "-- ============================== SELFHOST OUT ========================"
    if [ -s "$SH" ]; then sed 's/^/-- /' "$SH"; else echo "-- (not run — failed at Tier-A)"; fi
  } >> "$out"
  echo "  -> dumped $out"
}

tierA=0; tierB=0; known=0; ran=0
end=$((START + COUNT - 1))
echo "fuzz_diff: seeds $START..$end  tier=$TIER  batch=$BATCH"

for seed in $(seq "$START" "$end"); do
  ran=$((ran + 1))
  : > "$SH"   # reset selfhost output so a stale prior run can't leak into a dump
  "$GEN" --seed "$seed" --tier "$TIER" --batch "$BATCH" > "$SRC" 2>/dev/null

  # ----- Tier-A: oracle run + invariant check -----
  if ! "$MAIN" run "$SRC" > "$ORA" 2>&1; then
    # nonzero oracle exit = generator emitted an ill-typed/erroring program
    if allowlisted "$SRC" "$(cat "$ORA")"; then
      known=$((known + 1))
    else
      echo "[Tier-A] seed $seed: oracle rejected/errored:"; head -2 "$ORA" | sed 's/^/    /'
      tierA=$((tierA + 1)); dump_failure "$seed" "oracle-error"
    fi
    continue
  fi
  if grep -q "INV False" "$ORA"; then
    echo "[Tier-A] seed $seed: INVARIANT VIOLATION (INV False)"
    tierA=$((tierA + 1)); dump_failure "$seed" "invariant-violation"
    continue
  fi

  # ----- Tier-B: oracle vs selfhost tree-walker -----
  "$MAIN" run "$SELFHOST" "$RUNTIME" "$CORE" "$SRC" > "$SH" 2>&1
  if ! diff -q "$ORA" "$SH" >/dev/null 2>&1; then
    if allowlisted "$SRC" "$(cat "$SH")"; then
      known=$((known + 1))
    else
      echo "[Tier-B] seed $seed: ORACLE != SELFHOST"
      diff "$ORA" "$SH" | head -6 | sed 's/^/    /'
      tierB=$((tierB + 1)); dump_failure "$seed" "tierB-divergence"
    fi
  fi
done

echo "------------------------------------------------------------"
echo "ran=$ran  TierA_findings=$tierA  TierB_findings=$tierB  known_gap=$known"
if [ $((tierA + tierB)) -eq 0 ]; then
  echo "RESULT: clean (no new divergences/invariant violations)"
  exit 0
else
  echo "RESULT: $((tierA + tierB)) NEW finding(s) — see $FAILDIR/"
  exit 1
fi
