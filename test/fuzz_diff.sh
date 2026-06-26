#!/usr/bin/env bash
# fuzz_diff.sh — differential fuzzer driver for the Medaka compiler (Stage-0/1 MVP).
#
# Generates well-typed Medaka programs with the NATIVE compiler generator
# (test/bin/fuzz_gen_main, compiled from compiler/entries/fuzz_gen_main.mdk by
# test/build_oracles.sh — the OCaml-free port of the former OCaml dev generator, #36).
# The whole gate is now OCaml-free (the value oracle was already native, REROOT
# Phase 3).  The generator emits the SAME kind of program (type-directed,
# well-typed-by-construction; the random input source, not an oracle) and checks
# them two ways:
#   Tier-A (oracle + invariants): run each program through the native-interp ORACLE
#     (test/bin/eval_dict_main, the self-hosted dict-passing tree-walker compiled to
#     a standalone native binary by test/build_oracles.sh — REROOT-PLAN Phase 3).
#     The generator emits oracle-independent invariants
#     inline as `println ("INV " ++ debug <bool>)` lines that MUST be `INV True`
#     (Eq reflexive/symmetric, (a==b)==(eq a b), (a<b)==(lt a b), Ord
#     totality/antisymmetry/transitivity, arithmetic identities a+0/a*1/(a+b)-b).
#     Any `INV False`, or a nonzero oracle exit (a generator well-typedness hole),
#     is a finding.  (The former Tier-B — oracle vs compiler-on-the-OCaml-host — is
#     retired: post-reroot the oracle IS the native compiler tree-walker, so the
#     genuine cross-implementation check is Tier-C below, native-compiled vs
#     native-interp.)
#
# BATCHING: the native-interp path pays a ~480ms runtime+core parse tax PER PROCESS.
# We amortize it by generating each seed as a --batch of K independent blocks
# (sharing a fresh-name counter so names never collide) in ONE file, so one
# native-interp process covers K programs' worth of checks.
#
# Findings are classified against test/fuzz_allowlist.txt (documented-open gaps).
# Unmatched findings are dumped to test/fuzz_failures/seed_N.mdk with both outputs.
#
#   Tier-C (oracle vs NATIVE): OPT-IN (5th arg NATIVE=1).  Compile the SAME
#     program with `medaka build` (the native LLVM backend: self-hosted emitter
#     → LLVM IR → clang + runtime/medaka_rt.c + Boehm GC) into a native binary,
#     run it, and diff stdout against the oracle.  Native is the artifact being
#     made CANONICAL (PLAN.md Stage 3), so this is the highest-leverage tier — it
#     was previously UNFUZZED.  Native build is expensive (~2.8s per batched
#     program = emit-via-interpreter + clang), so Tier-C uses its own (smaller)
#     COUNT (the 6th arg, default 40) and reuses the batched program as ONE binary
#     (the batch's combined `main` builds + runs as a single executable, so the
#     ~480ms+clang fixed cost amortizes over all BATCH blocks just like Tier-B).
#     The native runtime auto-prints `main`'s Unit as a trailing "()" line, which
#     `medaka run` (oracle) does NOT — the harness strips one trailing "()" line
#     from native output before diffing.  Tier-C diffs each seed's native build
#     against that program's OWN oracle output.  (Tuples are NO LONGER suppressed:
#     `debug`/`==`/`compare` on a tuple receiver is native==oracle as of the
#     arity-distinguished tuple-head fix — former Gap C1/C5.  The generator never
#     emits `<`/`>` on a tuple, so the deferred parametric-default-`<` gap is unreached.)
#
# RE-BASELINE (native generator is the new baseline, NOT byte-identical to the old
# OCaml dev generator).  The fuzzer checks output INVARIANTS, never a fixed
# golden, so the generator only needs to emit valid, varied, DETERMINISTIC programs
# per seed.  Exact byte-parity with the retired OCaml generator is impractical and
# unnecessary: (1) the RNG DRAW differs (OCaml masked a raw next64() and took `rem
# n`; the native port draws via the shared SplitMix64 `randomInt 0 (n-1)` extern —
# same algorithm + seed, different consumption), and (2) the printer differs
# (compiler width-80 / string_of_float vs OCaml width-200 %g) — layout/float-digit
# only, never validity.  So a given seed still maps to ONE program (replayable), but
# a DIFFERENT program than the old OCaml seed.  See compiler/entries/fuzz_gen_main.mdk.
#
# Usage: test/fuzz_diff.sh [START_SEED] [COUNT] [TIER] [BATCH] [NATIVE] [NATIVE_COUNT]
#   defaults: START_SEED=1 COUNT=200 TIER=2 BATCH=12 NATIVE=0 NATIVE_COUNT=40
#
# Run from the repo root (or worktree root); paths are resolved relative to it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

GEN="$ROOT/test/bin/fuzz_gen_main"
# The native generator's `main : <…> Unit` ends with `putStr (programToString …)`,
# after which the native runtime auto-prints `main`'s Unit as a trailing "()" line.
# gen() writes the program to $1 and drops that one trailing "()" so the emitted
# .mdk parses (a bare top-level "()" is a parse error).  MEDAKA_ROOT lets the
# generator read stdlib (string.toInt, the printer's float/char helpers) from disk.
gen() {  # gen <outfile> <seed>
  MEDAKA_ROOT="$ROOT" "$GEN" --seed "$2" --tier "$TIER" --batch "$BATCH" 2>/dev/null \
    | sed -e '${/^()$/d;}' > "$1"
}
# Native-interp ORACLE (REROOT-PLAN.md Phase 3 / §2g): the self-hosted dict-passing
# tree-walker compiled to a standalone native binary (test/bin/eval_dict_main, built
# by test/build_oracles.sh) replaces the OCaml interpreter oracle.  Random inputs
# cannot be goldened, so the live native interpreter is the reference.
ORACLE="$ROOT/test/bin/eval_dict_main"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
ALLOWLIST="$ROOT/test/fuzz_allowlist.txt"
FAILDIR="$ROOT/test/fuzz_failures"

START="${1:-1}"
COUNT="${2:-200}"
TIER="${3:-2}"
BATCH="${4:-12}"
NATIVE="${5:-0}"
NATIVE_COUNT="${6:-40}"

[ -x "$GEN" ] || { echo "missing $GEN — the fuzz generator (native compiler entry) must be built: sh test/build_oracles.sh"; exit 2; }
[ -x "$ORACLE" ] || { echo "missing $ORACLE — run: sh test/build_oracles.sh"; exit 2; }
if [ "$NATIVE" = "1" ]; then
  [ -x "$MEDAKA" ] && [ -x "$EMITTER" ] || { echo "missing $MEDAKA / $EMITTER — run: make medaka"; exit 2; }
fi
mkdir -p "$FAILDIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/prog.mdk"; ORA="$TMP/ora.txt"
# Tier-C native scratch
NSRC="$TMP/nprog.mdk"; NORA="$TMP/nora.txt"; NAT="$TMP/nat.txt"
NATSTRIP="$TMP/nat_strip.txt"; NBIN="$TMP/nbin"; NERR="$TMP/nbuild.err"

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
  } >> "$out"
  echo "  -> dumped $out"
}

# Tier-C native-divergence dump.  Records the SOURCE, the oracle
# output, and the native build error OR native stdout, so a candidate new native
# gap is a self-contained repro.
dump_native() {
  local seed="$1" kind="$2"
  local out="$FAILDIR/native_seed_${seed}.mdk"
  {
    echo "-- NATIVE FUZZ FAILURE  seed=$seed  tier=$TIER  batch=$BATCH  kind=$kind"
    echo "-- reproduce: $GEN --seed $seed --tier $TIER --batch $BATCH > p.mdk"
    echo "--            ./medaka build p.mdk -o p && ./p   (vs  test/bin/eval_dict_main runtime core p.mdk)"
    echo "-- ============================== SOURCE ================="
  } > "$out"
  cat "$NSRC" >> "$out"
  {
    echo "-- ============================== ORACLE OUT =========================="
    sed 's/^/-- /' "$NORA"
    echo "-- ============================== NATIVE BUILD ERR ===================="
    if [ -s "$NERR" ]; then sed 's/^/-- /' "$NERR"; else echo "-- (build ok)"; fi
    echo "-- ============================== NATIVE OUT (stripped) =============== "
    if [ -f "$NATSTRIP" ]; then sed 's/^/-- /' "$NATSTRIP"; else echo "-- (did not run)"; fi
  } >> "$out"
  echo "  -> dumped $out"
}

tierA=0; known=0; ran=0
tierC=0; nat_known=0; nat_ran=0; nat_built=0
end=$((START + COUNT - 1))
echo "fuzz_diff: seeds $START..$end  tier=$TIER  batch=$BATCH  native=$NATIVE"

for seed in $(seq "$START" "$end"); do
  ran=$((ran + 1))
  gen "$SRC" "$seed"

  # The native generator itself can hit an open native-backend codegen gap on
  # certain programs (intermittent mixed nullary/payload ADT field corruption —
  # surfaces as a printer NULL-deref / empty output; most prevalent at TIER=1,
  # absent at the default TIER=2).  Empty output ⇒ generator crashed, NOT a
  # compiler-under-test finding: count as a known native gap and skip.  See
  # compiler/entries/fuzz_gen_main.mdk ("native-generator gap").
  if [ ! -s "$SRC" ]; then
    known=$((known + 1)); continue
  fi

  # ----- Tier-A: native-interp oracle run + invariant check -----
  if ! "$ORACLE" "$RUNTIME" "$CORE" "$SRC" > "$ORA" 2>&1; then
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
done

# ===================== Tier-C: oracle vs NATIVE (`medaka build`) =====================
# Opt-in (NATIVE=1).  Runs its OWN seed range (START..START+NATIVE_COUNT-1) because
# native build is ~2.8s/program — far heavier than Tier-A/B — so it gets a smaller
# default count.  Each seed is built, run, and its stripped stdout diffed against
# that program.s own oracle output.  (Tuples enabled: `debug`/`==`/`compare` on a
# tuple receiver is native==oracle since the arity-distinguished tuple-head fix.)
if [ "$NATIVE" = "1" ]; then
  nend=$((START + NATIVE_COUNT - 1))
  echo "------------------------------------------------------------"
  echo "Tier-C (native): seeds $START..$nend  (build ~2.8s each)"
  for seed in $(seq "$START" "$nend"); do
    nat_ran=$((nat_ran + 1))
    : > "$NERR"; rm -f "$NATSTRIP"
    gen "$NSRC" "$seed"
    # generator hit the open native gap (empty output) — known, skip (see Tier-A)
    if [ ! -s "$NSRC" ]; then nat_known=$((nat_known + 1)); continue; fi
    # oracle for THIS program — skip seeds the oracle itself rejects
    # (those are Tier-A's job on the normal program; here we only compare native
    # against a known-good oracle baseline).  The native-interp oracle auto-prints
    # a trailing "()" line, same as the native build below — strip it from both.
    if ! "$ORACLE" "$RUNTIME" "$CORE" "$NSRC" > "$NORA.raw" 2>&1; then
      continue
    fi
    sed -e '${/^()$/d;}' "$NORA.raw" > "$NORA"
    if grep -q "INV False" "$NORA"; then
      continue
    fi
    # native build (OCaml-free: ./medaka build via the native emitter)
    if ! MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$NSRC" -o "$NBIN" > /dev/null 2>"$NERR"; then
      if allowlisted "$NSRC" "$(cat "$NERR")"; then
        nat_known=$((nat_known + 1))
      else
        echo "[Tier-C] seed $seed: NATIVE BUILD FAILED (candidate new gap):"
        head -3 "$NERR" | sed 's/^/    /'
        tierC=$((tierC + 1)); dump_native "$seed" "native-build-fail"
      fi
      continue
    fi
    nat_built=$((nat_built + 1))
    # run native, strip one trailing "()" line (runtime Unit auto-print; oracle omits it)
    if ! "$NBIN" > "$NAT" 2>&1; then
      echo "[Tier-C] seed $seed: NATIVE RUN CRASHED (candidate new gap):"
      tail -3 "$NAT" | sed 's/^/    /'
      tierC=$((tierC + 1)); cp "$NAT" "$NATSTRIP"; dump_native "$seed" "native-run-crash"
      continue
    fi
    sed -e '${/^()$/d;}' "$NAT" > "$NATSTRIP"
    if ! diff -q "$NORA" "$NATSTRIP" >/dev/null 2>&1; then
      if allowlisted "$NSRC" "$(cat "$NATSTRIP")"; then
        nat_known=$((nat_known + 1))
      else
        echo "[Tier-C] seed $seed: ORACLE != NATIVE"
        diff "$NORA" "$NATSTRIP" | head -6 | sed 's/^/    /'
        tierC=$((tierC + 1)); dump_native "$seed" "native-divergence"
      fi
    fi
  done
fi

echo "------------------------------------------------------------"
echo "ran=$ran  TierA_findings=$tierA  known_gap=$known"
if [ "$NATIVE" = "1" ]; then
  echo "native: ran=$nat_ran  built=$nat_built  TierC_findings=$tierC  native_known_gap=$nat_known"
fi
if [ $((tierA + tierC)) -eq 0 ]; then
  echo "RESULT: clean (no new divergences/invariant violations)"
  exit 0
else
  echo "RESULT: $((tierA + tierC)) NEW finding(s) — see $FAILDIR/"
  exit 1
fi
