#!/bin/sh
# diff_compiler_perf_scaling.sh — the O(n²) detector.
#
# PROBLEM: agents keep introducing quadratic algorithms into the compiler. Three
# have been found and fixed in a single night (resolve's contigGo, five sites in
# typecheck, and a third in the check driver). Nothing was watching.
#
# WHY THIS IS NOT A WALL-CLOCK GATE
# ---------------------------------
# The obvious design — "fail if the build takes >N seconds" — is WRONG here, and
# would have been worse than nothing:
#
#   * CI runs on SHARED HOSTED RUNNERS that vary 2-3x run to run. A wall-clock
#     threshold is either too loose to catch anything real, or it flaps constantly
#     and gets ignored. A gate people ignore is a gate that does not exist.
#   * A constant-factor slowdown and an ALGORITHMIC blowup are different bugs. Only
#     the second gets catastrophically worse as the codebase grows, and it is the
#     one actually being introduced.
#
# WHAT THIS MEASURES INSTEAD: **SCALING**.
#
# Feed the same operation inputs of size N, 2N, 4N and check the GROWTH RATIO per
# doubling. Runner speed CANCELS OUT of a ratio:
#
#     linear      O(n)        -> ~2.0x per doubling
#     n log n                 -> ~2.1x
#     QUADRATIC   O(n^2)      -> ~4.0x     <-- what we are hunting
#
# PRIMARY METRIC IS ALLOCATION, but it is NOT the only one (issue #110).
#
# GC-allocated bytes are DETERMINISTIC — they do not depend on runner speed, cache
# state, or load at all. So an allocation-ratio gate is simultaneously
# machine-independent AND noise-free, which no timing gate can be. It stays the
# PRIMARY verdict, unchanged.
#
# But allocation is BLIND to a real bug class: a pure O(n^2) TRAVERSAL — scan a
# List / linear-search a scope once per lookup — costs TIME quadratically while
# allocating almost NOTHING extra per scan. The resolve quadratic fixed in #78
# (P-1) was exactly this: time ratios 2.63x/3.56x (quadratic) against allocation
# ratios of only 2.09x/2.11x ("ok"). An allocation-only gate could not have caught
# it, and (separately) the `bindings` fixture never even exercised the buggy path
# — every body referenced only its own local `x`, so `lookupValue`'s short-circuit
# `||` chain never fell through to scan `env.values`. See the `xref` shape below.
#
# So TIME is now ALSO graded — PER STAGE, as a self-normalizing RATIO, never an
# absolute wall-clock ceiling (a hosted runner is too noisy for that). Four rules
# make a ratio-based time gate trustworthy; all four are load-bearing:
#
#   1. PER-STAGE, NEVER A SUM. An earlier draft of this gate summed several
#      stages' times and graded the sum. That is strictly worse than useless: a
#      sum can only BLUR signals together. It read 2.7-2.9x on a CORRECT
#      compiler purely because it was adding a small stage's artifact (below)
#      into resolve's clean signal. Grading each stage separately gives each a
#      clean ratio AND names which stage regressed.
#
#   2. PIN THE HEAP: GC_INITIAL_HEAP_SIZE=2147483648 on every timing run.
#      Wall-clock carries a GC HEAP-RESIZE STEP that allocation does not. Left
#      unpinned, `exhaust-guards` reads 3.25x and `desugar` 2.72x ON A CORRECT
#      COMPILER at the sizes we sample — and then COLLAPSES back to ~2.07x /
#      ~2.16x one doubling later. A real quadratic HOLDS near 4.0x; a step does
#      not. Pinning the heap removes it (exhaust-guards 3.25 -> 2.17). An
#      unpinned time gate is a FALSE-RED GENERATOR. (Per AGENTS.md this knob
#      cannot change emitted IR, so it is safe. It is applied to the TIMING runs
#      ONLY — the allocation runs stay unpinned and their numbers are unmoved,
#      because allocation is the primary verdict and must not shift.)
#
#   3. MIN-OF-K (K>=5) per measurement. Runner noise is ONE-SIDED — a scheduling
#      stall can only make a run SLOWER, never spuriously faster — so the minimum
#      over K samples converges on the true cost FROM ABOVE (same principle as
#      PERF-RESULTS.md's "min-of-10, quiet machine").
#
#   4. A PER-STAGE FLOOR (TIME_FLOOR, 200ms). A stage whose absolute time at the
#      LARGEST N is under the floor is too small to time reliably; its ratio is
#      computed out of noise and MUST NOT gate. Such a stage is SKIPPED — and the
#      skip is PRINTED, with the measured time, so it can never be read as a
#      pass. This is what disqualifies desugar/exhaust-guards/mark (10-70ms):
#      they are exactly where the borderline readings came from.
#
# Fail only on a SUSTAINED signal: BOTH doublings (r1 AND r2) over threshold.
#
# The timing verdict can ONLY make a shape FAIL that allocation called "ok" — it
# is an added detector, not a replacement. It never overrides or downgrades an
# allocation failure.
#
# MEASURED MARGIN (this box, 3 independent batches, pinned, min-of-5), the
# `xref` shape's gated stages on a CORRECT compiler:
#     parse      r <= 2.01      resolve  r <= 2.34      typecheck  r <= 2.14
# and on a compiler with the pre-#78 (quadratic) resolve restored:
#     resolve    r1=3.56 r2=3.89
# Against the 3.0 threshold that is ~22% headroom below and ~19% above.
#
# Usage:  sh test/diff_compiler_perf_scaling.sh
#         PERF_N=250 sh test/diff_compiler_perf_scaling.sh   # base size
# Exit:   0 all shapes scale sub-quadratically; 1 a shape regressed; 2 opt-in skip.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$ROOT/test/bin/profile_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$PROFILE" ] || {
  echo "build oracles first: sh test/build_oracles.sh --build-one profile_main (missing $PROFILE)"
  exit 2
}

# FAIL threshold, per doubling.
#   linear 2.0 | n log n ~2.1 | n^1.5 = 2.83 | QUADRATIC 4.0
# 3.0 comfortably admits n log n (plus slack) and comfortably catches n^2. It also
# catches n^1.58 and worse. Deliberately NOT tighter: a gate that fires on noise is
# a gate that gets disabled.
THRESH="${PERF_THRESH:-3.0}"
N="${PERF_N:-250}"

# `xref` samples at a LARGER N than the other four shapes. This is FORCED, not a
# preference: the stage we must be able to see (`resolve`) only reaches 0.29s at
# N=16000. At a 2000/4000/8000 range its largest-N time is 0.137s — UNDER the
# 200ms floor — so the floor would (correctly) refuse to grade it and the gate
# could not see the very bug it exists to catch. The alternative, lowering the
# floor to 100ms, weakens the one guard that keeps a ratio from being computed
# out of noise. So: raise N, keep the floor honest.
XREF_N="${PERF_XREF_N:-4000}"

# min-of-K sample count for the TIME signal. K>=5 required (see file header);
# allocation needs no such thing — it is deterministic, one run suffices.
PERF_K="${PERF_K:-5}"

# A stage whose absolute time at the LARGEST N is below this is too small to
# time-gate — its ratio would be noise. It is SKIPPED, loudly. See rule 4.
TIME_FLOOR="${PERF_TIME_FLOOR:-0.2}"

# Pin the GC heap for TIMING runs only — see rule 2. Without this the gate emits
# false reds from a heap-resize step on a perfectly correct compiler.
TIME_HEAP="${PERF_TIME_HEAP:-2147483648}"

# ── KNOWN SUPERLINEAR (a ledger, NOT a skip-list) ────────────────────────────
#
# A shape listed here is ALREADY superlinear — a real, filed bug. It is recorded
# rather than skipped, following the same model as diff_compiler_engines.sh's
# ledger, CAPABILITY-EXCEPTIONS.txt, and rustc's tests/crashes. Each entry asserts
# the CURRENT, WRONG behavior, so that:
#
#   (a) the bug cannot get any worse silently — a listed shape still FAILS if it
#       exceeds its recorded ceiling; and
#   (b) an ACCIDENTAL FIX is DETECTED — if a listed shape drops back to linear, this
#       gate FAILS and demands promotion.
#
# (b) is the whole point and is why this is not a skip-list. A skip-list cannot
# notice when a bug is fixed, so it ROTS — which is precisely how test/ported/ died
# (nothing ran it for months) and how diff_compiler_lint_multi sat "skipped" while
# also failing. Do not "simplify" this into a skip.
#
# (Currently EMPTY — every shape scales sub-quadratically. Long may it last.)
#
# HISTORY — entries that were fixed and promoted OUT of this ledger:
#
#   match — exhaustiveness checking (compiler/frontend/exhaust.mdk + the
#           `check_match` driver in compiler/types/typecheck.mdk) over an
#           N-constructor data decl with an N-arm match. Filed as T17, ratio
#           CLIMBING with N (2.48x -> 2.75x -> 3.10x per doubling; 274 MB net
#           allocation at N=1000). FIXED 2026-07-13: it was FOUR quadratics
#           stacked, all of the same "re-scan the whole thing once per element"
#           shape — `usefulCovered` called `specializeCon` (a full matrix scan)
#           once per signature constructor, `allCovered` did an O(#ctors x #rows)
#           list-membership scan, the constructor oracle's four tables were assoc
#           LISTS so every arity/type lookup was O(#ctors), and the redundant-arm
#           fold re-ran the whole Maranget recursion against every preceding arm.
#           Now: rows are bucketed by head constructor in ONE pass, the oracle is
#           an OrdMap, and the redundancy fold skips arms that provably cannot be
#           unreachable. 3.10x -> 2.18x; 274 MB -> 118 MB at N=1000.
KNOWN_SUPERLINEAR=""

is_known() {
  for k in $KNOWN_SUPERLINEAR; do [ "$k" = "$1" ] && return 0; done
  return 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── The shapes ───────────────────────────────────────────────────────────────
# Each stresses a DIFFERENT structure, because O(n^2) hides in specific ones and a
# single generator would miss whole classes. (A quadratic in exhaustiveness checking
# is invisible to a program with no `match`.)
#
#   bindings — symbol table, scope threading, letrec grouping, generalization.
#              THIS IS WHERE ALL THREE QUADRATICS FOUND SO FAR LIVED. But see the
#              WARNING below — this shape's bodies do not actually reference each
#              other, so it does NOT exercise cross-reference name lookup.
#   match    — exhaustiveness (Maranget's pattern-matrix algorithm is a classic
#              O(n^2) risk) and constructor tables.
#   listlit  — parser/lexer recursion and Core-IR lowering over a wide literal.
#   nesting  — deep recursion in the tree-walking passes.
#   xref     — CROSS-REFERENCING top-level bindings (each fN's body calls
#              f(N-1)). `bindings` above generates N functions whose bodies
#              reference only their own local parameter `x` — `lookupValue` is a
#              short-circuiting `||` chain that hits the local on element 1 and
#              NEVER scans `env.values`, so a bug in that scan is invisible to
#              it. Real code cross-references constantly; this shape is what
#              actually walks the scope chain, which is where #78's resolve
#              quadratic lived. Graded on TIME (see file header), not
#              allocation — the #78 bug was a pure scan, near-zero extra alloc.
gen_bindings() {
  n=$1; f=$2; : > "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf 'f%s : Int -> Int\nf%s x = x + %s\n' "$i" "$i" "$i"
    i=$((i+1))
  done >> "$f"
}

gen_match() {
  n=$1; f=$2; : > "$f"
  # one data decl with N constructors, and one match with N arms over it
  printf 'data T%s =\n' "$n" >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    if [ "$i" -eq 0 ]; then printf '  C%s\n' "$i"; else printf '  | C%s\n' "$i"; fi
    i=$((i+1))
  done >> "$f"
  printf 'toInt : T%s -> Int\ntoInt v = match v\n' "$n" >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  C%s => %s\n' "$i" "$i"; i=$((i+1)); done >> "$f"
}

gen_listlit() {
  n=$1; f=$2; : > "$f"
  printf 'xs : List Int\nxs = [' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    [ "$i" -gt 0 ] && printf ', '
    printf '%s' "$i"
    i=$((i+1))
  done >> "$f"
  printf ']\n' >> "$f"
}

gen_nesting() {
  n=$1; f=$2; : > "$f"
  # N-deep let nesting: stresses recursion depth in every tree-walking pass
  printf 'deep : Int\ndeep =\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  let v%s = %s\n' "$i" "$i" >> "$f"; i=$((i+1)); done
  printf '  v0\n' >> "$f"
}

gen_xref() {
  n=$1; f=$2; : > "$f"
  # N top-level functions, each REFERENCING the previous one (f0 is the base
  # case). This is the shape #78's resolve quadratic actually needed: every
  # `fN x = f(N-1) x + N` forces `lookupValue` to fall through the local-scope
  # check and walk the top-level env for `f(N-1)` — the scan `bindings` above
  # never triggers.
  printf 'f0 : Int -> Int\nf0 x = x + 1\n' >> "$f"
  i=1; while [ "$i" -lt "$n" ]; do
    prev=$((i - 1))
    printf 'f%s : Int -> Int\nf%s x = f%s x + %s\n' "$i" "$i" "$prev" "$i"
    i=$((i+1))
  done >> "$f"
}

# ── Measure ──────────────────────────────────────────────────────────────────
# Returns TOTAL allocated MB for one fixture. Allocation is deterministic, so ONE
# run suffices — no min-of-K needed, and no noise to average away.
alloc_of() {
  MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1 \
    | awk '/^\[perf\] total/ { gsub(/MB/,"",$4); print $4; exit }'
}

# ⚠️ THE BASELINE MUST BE SUBTRACTED, OR THIS GATE IS BLIND.
#
# Every run pays a FIXED cost that has nothing to do with N: parsing and checking
# runtime.mdk + core.mdk allocates ~80 MB before the fixture is even looked at. At
# N=250 that constant DOMINATES, and the measured ratios come out at 1.2-1.5x —
# i.e. SUBLINEAR — which reads as "fine" while a genuine quadratic hides inside it.
#
# This is the same trap as the wall-clock measurement: raw `medaka check` ratios
# read 1.56 / 2.52 / 3.63, but with the 0.43s startup subtracted they read
# 1.86 / 2.95 / 3.88 — and only THEN is the quadratic unmistakable.
#
# So: measure an EMPTY fixture, subtract that constant, and compute the ratio on
# what the input actually costs. A gate that cannot see the bug it was built for is
# worse than no gate, because it certifies the bug as absent.
BASE_FIX="$WORK/_baseline.mdk"
printf 'main = println 1\n' > "$BASE_FIX"
BASE_ALLOC="$(alloc_of "$BASE_FIX")"
case "$BASE_ALLOC" in
  ''|*[!0-9.]*) echo "FAIL: could not measure the baseline allocation (harness bug)"; exit 1 ;;
esac
# ── TIME grading, PER STAGE (issue #110) ─────────────────────────────────────
#
# One profile_main run emits a `[perf] <stage> <time>s <alloc>MB` line per stage,
# so ONE run yields every stage's time. stage_times_min runs the profiler K times
# with the heap PINNED and keeps, per stage, the MINIMUM observed time.
#
# Output: one "<stage> <min-seconds>" line per stage, on stdout.
stage_times_min() {
  fixture="$1"; k="$2"
  i=0
  while [ "$i" -lt "$k" ]; do
    GC_INITIAL_HEAP_SIZE="$TIME_HEAP" MEDAKA_PERF=1 \
      "$PROFILE" "$RUNTIME" "$CORE" "$fixture" 2>&1 \
      | awk '/^\[perf\] / { t = $3; gsub(/s$/, "", t); printf "%s %s\n", $2, t }'
    i=$((i+1))
  done | awk '
      { if (!($1 in m) || $2 + 0 < m[$1] + 0) m[$1] = $2 }
      END { for (st in m) printf "%s %s\n", st, m[st] }
    '
}

# Stages to grade. `parse-prelude` is the FIXED one-time cost of runtime+core and
# does not scale with N, so grading it is meaningless; `total` is a sum and rule 1
# says never grade a sum.
TIME_STAGES="parse exhaust-guards desugar resolve mark typecheck"

# ── KNOWN SLOW (TIME) — a ledger, NOT a skip-list ────────────────────────────
#
# Same contract as KNOWN_SUPERLINEAR above, for the TIME signal: each entry
# records a REAL, CURRENTLY-UNFIXED superlinearity, so that it cannot get worse
# silently AND an accidental fix is detected and must be promoted out.
#
#   match:typecheck / listlit:typecheck — FOUND BY THIS GATE, the moment it could
#     see time at all (2026-07-14). Typecheck is superquadratic in the size of a
#     SINGLE declaration, and ALLOCATION IS BLIND TO IT — which is the entire
#     thesis of issue #110, demonstrated on a live bug:
#
#         match, typecheck stage      TIME              ALLOC
#           N=250                     0.024s            7.2 MB
#           N=500                     0.072s  (3.05x)   9.6 MB  (1.33x)
#           N=1000                    0.234s  (3.28x)  14.6 MB  (1.52x)
#           N=2000                    1.059s  (4.52x)  25.0 MB  (1.72x)
#           N=4000                    6.950s  (6.56x)  46.8 MB  (1.87x)
#
#     The ratio CLIMBS past 4.0 — it is worse than quadratic at these sizes — so
#     it is not a heap-resize step (a step collapses one doubling later; this does
#     not). A 4000-arm match spends SEVEN SECONDS in typecheck.
#
#     It is NOT about the number of declarations: `xref` has 16000 of them and
#     typechecks linearly (2.03x / 2.10x). It is about the size of ONE decl —
#     `listlit` is a single wide list literal containing NO `match` at all, and
#     blows up identically (2.75 -> 3.55 -> 3.93 -> 5.86). So the two entries are
#     very likely ONE root cause in HM inference / constraint solving over a large
#     expression, not two.
#
#     NOTE the T17 entry in KNOWN_SUPERLINEAR's history above says the `match`
#     quadratic was "FIXED 2026-07-13 ... 3.10x -> 2.18x". That was the ALLOCATION
#     ratio. The time-side blowup survived it untouched, and nothing in CI could
#     see it. That is exactly the blind spot this change closes.
#
# Ceilings gate r2. They are set with real headroom over the observed spread
# (match r2 3.23-3.36, listlit r2 3.39-3.55 across 3 batches) because a ratio at
# these small absolute times is the least stable number this gate computes.
KNOWN_SLOW_TIME="match:typecheck listlit:typecheck"
KNOWN_TCEIL_match_typecheck="4.6";    KNOWN_TFIXED_match_typecheck="2.60"
KNOWN_TCEIL_listlit_typecheck="4.8";  KNOWN_TFIXED_listlit_typecheck="2.60"

is_known_time() {
  for k in $KNOWN_SLOW_TIME; do [ "$k" = "$1" ] && return 0; done
  return 1
}

fail=0
known=0
pass=0

printf '%-10s %8s %10s %10s %10s  %6s %6s  %s\n' \
  shape N 'net-N' 'net-2N' 'net-4N' 'r1' 'r2' verdict
printf -- '-------------------------------------------------------------------------------\n'

# ⚠️ MEASURE THREE SIZES, NOT TWO — a single doubling is not enough.
#
# This gate originally sampled N and 2N and gated on that one ratio. It would have
# MISSED the very bug it later found. At N=250 the (then-quadratic) `match` shape read
# 2.76x — UNDER the 3.0 threshold — and would have passed. It was only caught because
# someone hand-probed three doublings and saw the ratio CLIMB:
#
#     N=125->250  2.48x        N=250->500  2.75x        N=500->1000  3.10x
#
# THE SIGNAL FOR A QUADRATIC IS THE RATIO CLIMBING, not any single ratio. At small N a
# quadratic is still diluted by linear terms and constant factors; a single sample near
# the noise floor cannot distinguish n^1.4 from n^2.
#
# So: sample N, 2N, 4N. Gate on **r2** (the 2N->4N doubling) — it is the least
# contaminated by the constant term. Also flag a CLIMBING trend (r2 meaningfully above
# r1) even when r2 is still under the ceiling, because that is a quadratic caught early,
# while it is small.
for shape in bindings match listlit nesting xref; do
  case "$shape" in
    xref) base_n="$XREF_N" ;;
    *)    base_n="$N" ;;
  esac
  n1="$base_n"; n2=$((base_n * 2)); n3=$((base_n * 4))
  f1="$WORK/${shape}_$n1.mdk"; f2="$WORK/${shape}_$n2.mdk"; f3="$WORK/${shape}_$n3.mdk"
  "gen_$shape" "$n1" "$f1"
  "gen_$shape" "$n2" "$f2"
  "gen_$shape" "$n3" "$f3"

  a1="$(alloc_of "$f1")"; a2="$(alloc_of "$f2")"; a3="$(alloc_of "$f3")"

  # A shape that produces no measurement is a HARNESS failure, not a pass. Never
  # let "I could not measure it" read as "it is fine" — that is the silent-green
  # bug class this whole suite was hardened against.
  case "$a1$a2$a3" in
    *[!0-9.]*|"") echo "FAIL $shape: profiler produced no allocation figure (harness bug)"; fail=$((fail+1)); continue ;;
  esac

  # ── TIME verdict: PER STAGE, heap-pinned, min-of-K, floor-guarded ──────────
  # Computed BEFORE the allocation branch below so it can promote an allocation
  # "ok" to a failure — never the reverse.
  #
  # These are written to files rather than shell vars because there is one line
  # per stage per size and sh has no arrays.
  TF1="$WORK/${shape}_t1"; TF2="$WORK/${shape}_t2"; TF3="$WORK/${shape}_t3"
  stage_times_min "$f1" "$PERF_K" | sort > "$TF1"
  stage_times_min "$f2" "$PERF_K" | sort > "$TF2"
  stage_times_min "$f3" "$PERF_K" | sort > "$TF3"

  time_bad=0
  time_lines=""
  for st in $TIME_STAGES; do
    s1="$(awk -v s="$st" '$1==s{print $2}' "$TF1")"
    s2="$(awk -v s="$st" '$1==s{print $2}' "$TF2")"
    s3="$(awk -v s="$st" '$1==s{print $2}' "$TF3")"
    # A stage the profiler never emitted is a HARNESS bug, not a pass.
    if [ -z "$s1" ] || [ -z "$s2" ] || [ -z "$s3" ]; then
      time_lines="${time_lines}           time ${st}: NO MEASUREMENT from the profiler (harness bug)
"
      fail=$((fail+1))
      continue
    fi

    # RULE 4 — the per-stage floor. Under it, the ratio is noise: SKIP, loudly.
    below="$(awk -v v="$s3" -v f="$TIME_FLOOR" 'BEGIN{print (v + 0 < f + 0) ? 1 : 0}')"
    if [ "$below" = "1" ]; then
      ms3="$(awk -v v="$s3" 'BEGIN{printf "%.0f", v*1000}')"
      msf="$(awk -v f="$TIME_FLOOR" 'BEGIN{printf "%.0f", f*1000}')"
      time_lines="${time_lines}           time ${st}: SKIP — too small to time-gate: ${ms3} ms at N=${n3} < ${msf} ms floor
"
      continue
    fi

    tr1="$(awk -v a="$s1" -v b="$s2" 'BEGIN{printf "%.2f", b/a}')"
    tr2="$(awk -v a="$s2" -v b="$s3" 'BEGIN{printf "%.2f", b/a}')"
    # SUSTAINED signal only: both doublings over threshold.
    bad="$(awk -v r1="$tr1" -v r2="$tr2" -v th="$THRESH" 'BEGIN{print (r1 > th && r2 > th) ? 1 : 0}')"

    if is_known_time "${shape}:${st}"; then
      lk="$(printf '%s_%s' "$shape" "$st" | tr -c 'a-zA-Z0-9_' '_')"
      eval "tceil=\${KNOWN_TCEIL_$lk}"
      eval "tfixed=\${KNOWN_TFIXED_$lk}"
      tworse="$(awk -v r="$tr2" -v c="$tceil" 'BEGIN{print (r > c) ? 1 : 0}')"
      tbetter="$(awk -v r="$tr2" -v f="$tfixed" 'BEGIN{print (r < f) ? 1 : 0}')"
      if [ "$tworse" = "1" ]; then
        fail=$((fail+1))
        time_lines="${time_lines}           time ${st}: ** KNOWN-SLOW, AND GOT WORSE ** r1=${tr1} r2=${tr2} (ceiling ${tceil})
"
      elif [ "$tbetter" = "1" ]; then
        fail=$((fail+1))
        time_lines="${time_lines}           time ${st}: ** PROMOTE: now scales LINEARLY ** r2=${tr2} (< ${tfixed})
           Remove \"${shape}:${st}\" from KNOWN_SLOW_TIME — the bug is FIXED.
"
      else
        known=$((known+1))
        time_lines="${time_lines}           time ${st}: known-slow (TIME) r1=${tr1} r2=${tr2} — ledgered, alloc is blind to it
"
      fi
    elif [ "$bad" = "1" ]; then
      time_bad=1
      time_lines="${time_lines}           time ${st}: ** SUPERLINEAR (TIME) ** ${s1}s -> ${s2}s -> ${s3}s  r1=${tr1} r2=${tr2} (> ${THRESH}x)
"
    else
      time_lines="${time_lines}           time ${st}: ok  r1=${tr1} r2=${tr2}  (min-of-${PERF_K}, heap pinned)
"
    fi
  done

  # Subtract the fixed prelude cost — see the BASELINE note above. Without this the
  # gate is blind.
  verdict="$(awk -v a1="$a1" -v a2="$a2" -v a3="$a3" -v b="$BASE_ALLOC" -v th="$THRESH" 'BEGIN {
    d1 = a1 - b; d2 = a2 - b; d3 = a3 - b
    # If the input costs less than the noise floor, N is too small to say anything.
    # Report that honestly instead of certifying it as "ok".
    if (d1 < 1.0) { printf "0 0 TOOSMALL"; exit }
    r1 = d2 / d1
    r2 = d3 / d2
    # Gate on r2 (least constant-factor contamination). Also catch a CLIMBING ratio
    # even below the ceiling — that is a quadratic showing itself early.
    climbing = (r2 > r1 * 1.15 && r2 > 2.45)
    printf "%.2f %.2f %s", r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok")
  }')"
  r1="$(echo "$verdict" | cut -d' ' -f1)"
  ratio="$(echo "$verdict" | cut -d' ' -f2)"
  word="$(echo "$verdict" | cut -d' ' -f3)"

  d1="$(awk -v a="$a1" -v b="$BASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
  d2="$(awk -v a="$a2" -v b="$BASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
  d3="$(awk -v a="$a3" -v b="$BASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"

  if [ "$word" = "TOOSMALL" ]; then
    # NOT a pass. An unmeasurable shape is a harness problem, and silently counting
    # it as fine is exactly how a suite starts lying about what it covers.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** N TOO SMALL — raise PERF_N **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "-" "-"

  elif is_known "$shape"; then
    # A KNOWN-superlinear shape. Two ways this must still fail:
    eval "ceil=\${KNOWN_CEIL_$shape}"
    eval "fixed=\${KNOWN_FIXED_$shape}"
    worse="$(awk -v r="$ratio" -v c="$ceil" 'BEGIN{print (r > c) ? "1" : "0"}')"
    better="$(awk -v r="$ratio" -v f="$fixed" 'BEGIN{print (r < f) ? "1" : "0"}')"
    if [ "$worse" = "1" ]; then
      fail=$((fail+1))
      printf '%-10s %8s %9s MB %9s MB %8s  ** KNOWN-BAD, AND GOT WORSE (ceiling %s) **\n' \
        "$shape" "$n1" "$d1" "$d2" "$ratio" "$ceil"
    elif [ "$better" = "1" ]; then
      # ACCIDENTAL FIX. Fail loudly and demand promotion — an un-promoted entry
      # silently degrades into a skip, and then it rots.
      fail=$((fail+1))
      printf '%-10s %8s %9s MB %9s MB %8s  ** PROMOTE: now scales LINEARLY **\n' \
        "$shape" "$n1" "$d1" "$d2" "$ratio"
      printf '           The underlying bug is FIXED. Remove "%s" from KNOWN_SUPERLINEAR in %s\n' \
        "$shape" "$(basename "$0")"
    else
      known=$((known+1))
      printf '%-10s %8s %9s MB %9s MB %8s  known-superlinear (T17; ceiling %s)\n' \
        "$shape" "$n1" "$d1" "$d2" "$ratio" "$ceil"
    fi

  elif [ "$word" = "QUADRATIC" ]; then
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (ALLOC) **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '%s' "$time_lines"

  elif [ "$time_bad" = "1" ]; then
    # Allocation alone said "ok" — this is the blind spot #110 exists to close. A
    # pure O(n^2) scan (the resolve bug in #78) allocates almost nothing extra per
    # element, so allocation cannot see it; TIME can, and just did.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (TIME) **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '           alloc looked fine (r1=%s r2=%s) — the regression is in TIME:\n' "$r1" "$ratio"
    printf '%s' "$time_lines"

  else
    pass=$((pass+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ok\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '%s' "$time_lines"
  fi
done

printf -- '---------------------------------------------------------------------\n'
printf '%d ok, %d known-superlinear (ledgered), %d regressed (threshold %sx per doubling)\n' "$pass" "$known" "$fail" "$THRESH"

# Never exit 0 having measured nothing.
[ $((pass + known + fail)) -gt 0 ] || { echo "FAIL: the gate measured no shapes at all"; exit 1; }

if [ "$fail" -gt 0 ]; then
  cat <<EOF

A shape grew faster than ${THRESH}x per doubling of input size, in ALLOCATION or
in per-stage TIME. That is the signature of a SUPERLINEAR (probably QUADRATIC)
algorithm.

If the failure says SUPERLINEAR (TIME) while allocation reads "ok", that is not a
contradiction — it is the point. A pure O(n^2) TRAVERSAL (scan a list / linear-search
a scope once per lookup) costs time quadratically while allocating nothing extra, so
allocation cannot see it. Both signals are real; neither subsumes the other.

  linear      ~2.0x      n log n  ~2.1x      QUADRATIC  ~4.0x

The pattern found every time so far: a List being scanned / elem-checked /
lookup-ed / rebuilt ONCE PER ELEMENT. Note that \`xs ++ [x]\` inside a fold is
O(n^2) all by itself (list append is O(n)).

To localize it:
  MEDAKA_PERF=1 test/bin/profile_main stdlib/runtime.mdk stdlib/core.mdk <fixture>
gives per-STAGE time and allocation. Then \`perf\` (apt-get install linux-perf) to
name the hot symbol -- but note call graphs are unusable in these binaries (tail
calls, no frame pointers); use FLAT symbol counts only.

WARNING: \`whenL False (expensiveCall ...)\` is NOT a stub -- Medaka is strict, so
the argument still evaluates. To stub something out, actually remove the call.
EOF
  exit 1
fi
exit 0
