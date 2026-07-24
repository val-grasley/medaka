#!/bin/sh
# diff_compiler_eval_scaling.sh — the O(n^2) detector for the two INTERPRETERS
# (issue #887, epic #880, PERF-CI-COVERAGE.md §4 P3). NIGHTLY.
#
# THE HOLE THIS CLOSES
# --------------------
# The tree-walking interpreter (compiler/eval/eval.mdk — `medaka run`, doctests,
# repl) and the Core-IR interpreter (compiler/ir/core_ir_eval.mdk — `cevalModules`)
# were covered for CORRECTNESS only (diff_compiler_eval*.sh / _core_ir*.sh). No
# profiler ran them, so a quadratic in the tree-walker's env/frame handling or the
# Core-IR evaluator's dispatch/lowering would ship silently. This gate runs both
# over synthetic inputs of size N, 2N, 4N and grades the GROWTH RATIO — the same
# scaling discipline as diff_compiler_perf_scaling.sh, applied where nothing looked.
#
# WHY DETERMINISTIC METRICS ONLY (alloc + op), NOT WALL-TIME
# ---------------------------------------------------------
# diff_compiler_perf_scaling.sh grades allocation PLUS a heap-pinned min-of-K TIME
# arm. That TIME arm is deliberately ABSENT here, and the absence is measured, not
# lazy: the interpreters' wall-clock latency is SUPER-LINEAR IN RECURSION DEPTH on
# the CURRENT, CORRECT interpreter — a depth-N non-tail recursion that retains a
# growing live set (the `listbuild` shape below) reads a ~4.0x TIME ratio while its
# ALLOCATION ratio is a clean ~2.0x, and pinning the GC heap (which fixes the
# heap-resize step perf_scaling documents) does NOT remove it (measured 4.1x pinned).
# It is inherent to a non-TCO tree-walker under a conservative GC (the deep host
# stack is re-scanned per collection), so a wall-time gate here would be a PERMANENT
# FALSE-RED, the exact failure mode perf_scaling's rules 2-4 exist to prevent. So
# this gate follows diff_compiler_references_scaling.sh's precedent instead — grade
# the DETERMINISTIC, noise-free signals only:
#
#   ALLOCATION (primary)  GC-allocated bytes are deterministic and see a frame/env
#                         COPY quadratic (a tree-walker that copied the whole env per
#                         call would allocate O(n^2)). Baseline-subtracted per stage.
#   OP-COUNT   (secondary) util.contains/util.lookupAssoc scan steps (support/opcount.mdk,
#                         the emitPhaseAO 5th column). Noise-free like allocation but
#                         ALSO sees a pure O(n^2) SCAN that allocates nothing — the
#                         List-as-set class. This is how the Core-IR lowering quadratic
#                         the `bigmatch` shape once exercised (dedupHeads, #960 — now
#                         fixed) was caught; the ledger it seeded is now empty (below).
#
# Both are deterministic ⇒ ONE run per size suffices (no min-of-K, no heap-pin, no
# floor). A stage whose net op-delta is below OP_FLOOR is graded on ALLOCATION alone
# and its op arm SELF-SKIPS (loudly) — most eval/ceval stages add ~0 counted ops
# (their per-iteration env lookup is eval-internal, not util.contains/lookupAssoc),
# so the op arm is a targeted tripwire, not a universal one.
#
# THE SHAPES (each stresses a different interpreter structure)
# -----------------------------------------------------------
#   tailrec   — deep TAIL recursion. Stresses env/frame allocation and the value
#               representation over a long iteration. ALLOC linear (~2.0). Depth is
#               capped below eval.mdk's 25000-frame guard, so N tops out at 16000.
#   listbuild — a list BUILDER (non-tail `range`) + a fold. Stresses cons allocation
#               and list traversal. ALLOC linear (~2.0).
#   bigmatch  — a value classified by an N-arm `match` over an N-constructor data
#               type, driven a FIXED number of times. Both interpreters lower/interpret
#               it in ALLOC-linear time; the ALLOC arm is the live regression guard here.
#               The CORE-IR evaluator LOWERS it first (lowerGroups →
#               core_ir_lower.distinctConHeads → dedupHeads); that lowering WAS an
#               O(arms^2) List-as-set scan (dedupHeads), FIXED in #960, so its op-count
#               is now flat and its op arm self-skips (see KNOWN_SLOW_OPS below).
#   bigmatch_lits — the LITERAL sibling of bigmatch: N arms are distinct INTEGER
#               LITERALS (0..N-1) + a wildcard default, so the CORE-IR evaluator lowers
#               it through the LITERAL switch (buildLitSwitch → distinctLits/dedupLits
#               and specLitRow), NOT the constructor path. That lowering compared
#               literals with the derived `Eq Lit`, which ALLOCATES on every call
#               (verified by profiling: GC_malloc_kind ← mdk_alloc ← mdk_impl_Lit_eq
#               dominated a wide literal match's lowering). It ran once per
#               (row × distinct-literal): dedupLits' List-as-set dedup scan AND
#               specLitRow's per-branch matrix rescan were BOTH O(arms^2) — and,
#               unlike dedupHeads' counted `contains` (#960), used the UNcounted
#               `anyList`/raw `==`, so the quadratic was invisible to the OP arm yet
#               STARK in ALLOCATION (the compare allocates). #970 made it linear: an
#               OrdMap-set dedup (litKey-keyed) + an alloc-free `litEq` in specLitRow
#               (mirroring the constructor path's alloc-free `String ==`). The ALLOC
#               arm on `ceval` is the live guard: reverting either fix to the derived
#               allocating `==` reddens it (dedupLits alone worst-r≈3.1; specLitRow
#               alone ≈3.5; both ≈3.7 at N=3000/6000/12000). Op stays flat (uncounted).
#
# NON-ZERO-GRADED ASSERTION (PERF-CI-COVERAGE.md §8): the gate refuses to exit 0 if
# the ALLOC arm graded nothing — a blind spot must name itself, never pass silently.
# The OP arm additionally hard-fails on graded-nothing ONLY while a quadratic is
# LEDGERED (that entry MUST grade). With an empty ledger (post-#960) a healthy tree
# drives no counted scan above the floor, so the op arm grades nothing and says so
# (a NOTE) — a real op-scan quadratic above the floor still fails per-shape in grade().
#
# Usage:  sh test/diff_compiler_eval_scaling.sh
# Exit:   0 both interpreters scale as expected; 1 a shape regressed (or a ledgered
#         quadratic was FIXED and needs promotion); 2 opt-in skip (oracle missing).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$ROOT/test/bin/profile_eval_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$PROFILE" ] || {
  echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one profile_eval_main (missing $PROFILE)"
  exit 2
}

# FAIL threshold per doubling — same calibration as perf_scaling: linear 2.0,
# n log n ~2.1, quadratic 4.0. 3.0 admits n log n with slack and catches n^2.
THRESH="${EVAL_THRESH:-3.0}"

# A stage whose net op-delta (largest N) is below this is graded on ALLOCATION only;
# its op ratio would be computed out of a tiny constant and means nothing.
OP_FLOOR="${EVAL_OP_FLOOR:-1000}"

# ── The shapes' N bands ──────────────────────────────────────────────────────
# tailrec/listbuild scale the iteration/list dimension; bigmatch scales the match
# ARM (= constructor) count, so its N is smaller (parse + lower of N ctors).
TAILREC_N="${EVAL_TAILREC_N:-4000}"      # 4000/8000/16000  (16000 < eval's 25000 guard)
LISTBUILD_N="${EVAL_LISTBUILD_N:-4000}"  # 4000/8000/16000
BIGMATCH_N="${EVAL_BIGMATCH_N:-500}"     # 500/1000/2000
# bigmatch_lits scales the distinct-LITERAL arm count. N is larger than bigmatch's
# because the residual per-branch matrix rescan (specLitRow) is O(arms^2) in TIME
# (alloc-free, like the constructor path) — so the ALLOC signal of a regression only
# clears the linear base at these sizes: at 3000/6000/12000 reverting even the
# minority dedupLits fix alone lands worst-r≈3.1 (> the 3.0 FAIL line), with margin
# for the specLitRow/both reverts. Deterministic (alloc), so the margin is stable.
BIGMATCH_LITS_N="${EVAL_BIGMATCH_LITS_N:-3000}"  # 3000/6000/12000

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# ── KNOWN SUPERLINEAR (a self-draining LEDGER, NOT a skip-list) ───────────────
# Same model as perf_scaling's KNOWN_SUPERLINEAR / references_scaling's design: an
# entry asserts the CURRENT, WRONG behaviour of a KNOWN-unfixed op-scan quadratic so
# (a) it cannot get worse silently and (b) an ACCIDENTAL FIX is DETECTED and demands
# promotion. (b) is the whole point. The list is EMPTY right now — it self-drained:
#
#   ceval:bigmatch (op) was the sole entry — the CORE-IR match lowering's `dedupHeads`
#   (core_ir_lower.mdk) did `contains c seen` against a GROWING `seen` List, an O(arms^2)
#   List-as-set scan (measured 124750→499500→1999000, r≈4.0, pure n^2). FIXED in #960:
#   `dedupHeads` now tests membership through an OrdMap-backed set (O(log n), UNcounted),
#   so the net op-count collapsed to ~0 and the shape's op arm now self-skips below the
#   floor. #960 CLOSED; the entry was promoted out. The MECHANISM below stays live so the
#   NEXT op-scan quadratic can be ledgered the same way.
# A ledgered "<stage>:<shape>" entry is graded against a WINDOW [PROMOTE_BELOW, CEIL]
# on its worst doubling ratio: below PROMOTE_BELOW ⇒ FIXED, promote out (FAIL); above
# CEIL ⇒ worsened (FAIL); inside ⇒ ledgered-OK.
KNOWN_SLOW_OPS=""
# ratio window for a ledgered quadratic: it must stay quadratic (>= PROMOTE_BELOW) but
# not get worse than CEIL. 4.0 is pure-n^2; 3.0 would mean it dropped toward linear
# (fixed). Retained for the next op-scan quadratic (op-count is deterministic, so the
# CEIL headroom is belt-and-braces, not noise tolerance).
LEDGER_PROMOTE_BELOW="${EVAL_LEDGER_PROMOTE_BELOW:-3.0}"
LEDGER_CEIL="${EVAL_LEDGER_CEIL:-4.5}"

is_ledgered() {
  for k in $KNOWN_SLOW_OPS; do [ "$k" = "$1" ] && return 0; done
  return 1
}

# ── Generators ───────────────────────────────────────────────────────────────
gen_tailrec() {
  n=$1; f=$2
  # A tail-recursive countdown. eval.mdk has no TCO, so this recurses N frames deep
  # in the interpreter (native, 256MB worker stack) — N is kept under the 25000-frame
  # guard. Allocation is O(N) (one frame per step); a frame/env COPY regression is O(N^2).
  printf 'loop : Int -> Int -> Int\nloop n acc = match n\n  0 => acc\n  _ => loop (n - 1) (acc + 1)\nmain = println (loop %s 0)\n' "$n" > "$f"
}

gen_listbuild() {
  n=$1; f=$2
  # Build an N-element list via non-tail `range`, then fold it. Stresses cons
  # allocation + list traversal. ALLOC is O(N); the wall-TIME super-linearity noted
  # in the header lives here (retained growing live set) — which is exactly why this
  # gate does not grade time.
  {
    printf 'range : Int -> Int -> List Int\n'
    printf 'range lo hi = match lo < hi\n  False => []\n  True => lo :: range (lo + 1) hi\n'
    printf 'sum : List Int -> Int\n'
    printf 'sum xs = match xs\n  [] => 0\n  y :: ys => y + sum ys\n'
    printf 'main = println (sum (range 0 %s))\n' "$n"
  } > "$f"
}

gen_bigmatch() {
  n=$1; f=$2
  # data T with N NULLARY constructors; classify is an N-arm match hitting the LAST
  # arm (worst-case linear scan in the tree-walker), driven a FIXED number of times.
  # The tree-walker interprets the match directly (op FLAT); the Core-IR evaluator
  # LOWERS it via distinctConHeads/dedupHeads (the #960 O(arms^2) scan, now fixed —
  # op FLAT, ALLOC linear). The ALLOC arm is the live scaling guard for this shape.
  printf 'data T =\n' > "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    if [ "$i" -eq 0 ]; then printf '  C%s\n' "$i"; else printf '  | C%s\n' "$i"; fi
    i=$((i+1))
  done >> "$f"
  printf 'classify : T -> Int\nclassify v = match v\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  C%s => %s\n' "$i" "$i"; i=$((i+1)); done >> "$f"
  last=$((n - 1))
  printf 'drive : Int -> Int -> Int\n' >> "$f"
  printf 'drive k acc = match k\n  0 => acc\n  _ => drive (k - 1) (acc + classify C%s)\n' "$last" >> "$f"
  printf 'main = println (drive 400 0)\n' >> "$f"
}

gen_bigmatch_lits() {
  n=$1; f=$2
  # classify is an N-arm match over N distinct INTEGER LITERALS (0..N-1) + a wildcard
  # default (an Int literal match needs one for exhaustiveness), hitting the LAST
  # literal, driven a FIXED number of times. This drives the CORE-IR evaluator's
  # LITERAL switch lowering (buildLitSwitch → distinctLits/dedupLits + specLitRow) —
  # the derived-`Eq Lit`-allocates O(arms^2) that #970 fixed — NOT the constructor
  # path bigmatch exercises. The tree-walker interprets the match directly (op/alloc
  # ~flat in N); the ALLOC arm on `ceval` (which does the lowering) is the live guard.
  printf 'classify : Int -> Int\nclassify v = match v\n' > "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  %s => %s\n' "$i" "$i"; i=$((i+1)); done >> "$f"
  printf '  _ => 0\n' >> "$f"
  last=$((n - 1))
  printf 'drive : Int -> Int -> Int\n' >> "$f"
  printf 'drive k acc = match k\n  0 => acc\n  _ => drive (k - 1) (acc + classify %s)\n' "$last" >> "$f"
  printf 'main = println (drive 400 0)\n' >> "$f"
}

# ── Measure: run the profiler ONCE, print "<stage> <allocMB> <opDelta>" per stage ─
# The profiler line is  [perf] <label>\t<t>s\t<MB>MB\t<ops>\t<opDelta>  — parse with
# awk -F'\t' and read fields 3 (alloc) and 5 (op); the <ops> field 4 is free-form
# with spaces (see support/timer.mdk:emitPhaseAO). Deterministic ⇒ one run suffices.
measure() {
  MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1 \
    | awk -F'\t' '/^\[perf\] (eval|ceval)\t/ {
        split($1, a, " "); m = $3; gsub(/MB/, "", m); print a[2], m, $5 }'
}

# baseline (empty program): subtract each stage's fixed prelude-eval constant so the
# ALLOC ratio reflects what the INPUT costs, not the ~1 MB constant that dominates at
# small N (the same trap perf_scaling's BASE_ALLOC subtraction avoids).
BASE_FIX="$WORK/_baseline.mdk"
printf 'main = println 1\n' > "$BASE_FIX"
BASE_OUT="$(measure "$BASE_FIX")"
base_alloc() { printf '%s\n' "$BASE_OUT" | awk -v s="$1" '$1==s{print $2; exit}'; }
base_op()    { printf '%s\n' "$BASE_OUT" | awk -v s="$1" '$1==s{print $3; exit}'; }
BASE_EVAL_A="$(base_alloc eval)";  BASE_EVAL_O="$(base_op eval)"
BASE_CEVAL_A="$(base_alloc ceval)"; BASE_CEVAL_O="$(base_op ceval)"
case "$BASE_EVAL_A" in ''|*[!0-9.]*) echo "FAIL: could not measure baseline eval alloc (harness bug)"; exit 1 ;; esac
case "$BASE_CEVAL_A" in ''|*[!0-9.]*) echo "FAIL: could not measure baseline ceval alloc (harness bug)"; exit 1 ;; esac

echo "baseline: eval ${BASE_EVAL_A}MB / ${BASE_EVAL_O} ops   ceval ${BASE_CEVAL_A}MB / ${BASE_CEVAL_O} ops"
echo "threshold=$THRESH  op-floor=$OP_FLOOR"
echo

fail=0
alloc_graded=0
op_graded=0

# stage_field <full measure output> <stage> <field#>  (2=alloc, 3=op)
sf() { printf '%s\n' "$1" | awk -v s="$2" -v c="$3" '$1==s{print $c; exit}'; }

# grade one (shape, stage) across the three sizes.
#   $1 shape  $2 stage  $3 base-alloc  $4 base-op  $5 outN  $6 out2N  $7 out4N
grade() {
  shape="$1"; stage="$2"; bA="$3"; bO="$4"; oN="$5"; o2N="$6"; o4N="$7"
  aN="$(sf "$oN" "$stage" 2)";  a2N="$(sf "$o2N" "$stage" 2)";  a4N="$(sf "$o4N" "$stage" 2)"
  pN="$(sf "$oN" "$stage" 3)";  p2N="$(sf "$o2N" "$stage" 3)";  p4N="$(sf "$o4N" "$stage" 3)"

  # ── VALIDATE EACH PER-N MEASUREMENT — a missing figure is a LOUD FAIL, never a silent 0. ─
  # sf() returns "" if a `[perf] eval|ceval` line was ABSENT for a size (profiler crash /
  # OOM / a loaded-runner timeout — and note compiler/ir/core_ir_eval.mdk has NO
  # recursion-depth guard, unlike eval.mdk's 25000-frame limit, so a future N-bump or a
  # slow runner could crash `ceval` mid-run). Without this guard the empty string flows
  # into `"" - base` = 0 -> r1/r2 = 0 -> bad=0 -> the gate PASSES silently, and the
  # alloc_graded/op_graded counters do NOT save it (they are bumped only AFTER a valid
  # ratio is computed, below). Mirror of diff_compiler_perf_scaling.sh's per-N guard: a
  # concatenation is empty OR carries any non-[0-9.] char ⇒ some size did not measure.
  # Grade nothing for this stage — a partial ratio is worse than none.
  # ⚠️ CHECK EACH VALUE INDIVIDUALLY, NOT A CONCATENATION. An empty trailing/middle
  # figure VANISHES in "$aN$a2N$a4N" ("21.5"+"41.4"+"" = "21.541.4", still all-numeric),
  # so a concatenation guard sails right past exactly the missing-4N case this catches
  # (verified: it did, and the alloc arm then computed r2=-0.129 without failing). Loop.
  for _v in "$aN" "$a2N" "$a4N"; do
    case "$_v" in
      ''|*[!0-9.]*)
        echo "  FAIL: $shape:$stage produced a missing/garbled ALLOCATION measurement at some N (aN='$aN' a2N='$a2N' a4N='$a4N') — a [perf] line was absent (profiler crash / OOM / timeout). Refusing to grade a partial ratio."
        fail=1; return ;;
    esac
  done
  for _v in "$pN" "$p2N" "$p4N"; do
    case "$_v" in
      ''|*[!0-9.]*)
        echo "  FAIL: $shape:$stage produced a missing/garbled OP-COUNT measurement at some N (pN='$pN' p2N='$p2N' p4N='$p4N') — a [perf] line was absent (profiler crash / OOM / timeout). Refusing to grade a partial ratio."
        fail=1; return ;;
    esac
  done

  # ── ALLOCATION arm (primary) — baseline-subtracted net, sustained-both-doublings. ─
  read na n2 n4 r1 r2 <<EOF
$(awk -v a="$aN" -v b="$a2N" -v c="$a4N" -v base="$bA" 'BEGIN{
    na=a-base; n2=b-base; n4=c-base;
    r1=(na>0)?n2/na:0; r2=(n2>0)?n4/n2:0;
    printf "%.3f %.3f %.3f %.3f %.3f", na, n2, n4, r1, r2 }')
EOF
  printf '  %-9s %-5s ALLOC net MB %s -> %s -> %s   r1=%s r2=%s\n' "$shape" "$stage" "$na" "$n2" "$n4" "$r1" "$r2"
  alloc_graded=$((alloc_graded + 1))
  bad="$(awk -v r1="$r1" -v r2="$r2" -v t="$THRESH" 'BEGIN{ print (r1>=t && r2>=t) ? 1 : 0 }')"
  if [ "$bad" = "1" ]; then
    echo "  FAIL: $shape:$stage ALLOCATION is super-linear (r1=$r1 r2=$r2 >= $THRESH) — a frame/env/list quadratic in the interpreter."
    fail=1
  fi

  # ── OP-COUNT arm (secondary) — net delta; self-skip below floor; ledger otherwise. ─
  read qN q2 q4 s1 s2 <<EOF
$(awk -v a="$pN" -v b="$p2N" -v c="$p4N" -v base="$bO" 'BEGIN{
    qN=a-base; q2=b-base; q4=c-base;
    s1=(qN>0)?q2/qN:0; s2=(q2>0)?q4/q2:0;
    printf "%d %d %d %.3f %.3f", qN, q2, q4, s1, s2 }')
EOF
  below="$(awk -v q="$q4" -v f="$OP_FLOOR" 'BEGIN{ print (q < f) ? 1 : 0 }')"
  if [ "$below" = "1" ]; then
    printf '  %-9s %-5s OP   net %s ops at 4N < floor %s — op arm SKIPPED (graded on alloc only)\n' "$shape" "$stage" "$q4" "$OP_FLOOR"
    return
  fi
  printf '  %-9s %-5s OP   net ops %s -> %s -> %s   s1=%s s2=%s\n' "$shape" "$stage" "$qN" "$q2" "$q4" "$s1" "$s2"
  op_graded=$((op_graded + 1))
  if is_ledgered "$stage:$shape"; then
    # ledgered quadratic: must stay inside the [PROMOTE_BELOW, CEIL] window.
    worst="$(awk -v s1="$s1" -v s2="$s2" 'BEGIN{ print (s1>s2)?s1:s2 }')"
    if awk -v w="$worst" -v lo="$LEDGER_PROMOTE_BELOW" 'BEGIN{ exit !(w < lo) }'; then
      echo "  FAIL: LEDGER $stage:$shape dropped to ~linear (worst r=$worst < $LEDGER_PROMOTE_BELOW) — the ledgered op-scan quadratic was FIXED. PROMOTE it out of KNOWN_SLOW_OPS and close the tracking issue."
      fail=1
    elif awk -v w="$worst" -v hi="$LEDGER_CEIL" 'BEGIN{ exit !(w > hi) }'; then
      echo "  FAIL: LEDGER $stage:$shape WORSENED (worst r=$worst > $LEDGER_CEIL) — the known quadratic got worse."
      fail=1
    else
      echo "  ($stage:$shape is a LEDGERED, currently-unfixed O(arms^2) — worst r=$worst, inside [$LEDGER_PROMOTE_BELOW, $LEDGER_CEIL]. See KNOWN_SLOW_OPS.)"
    fi
  else
    bad="$(awk -v s1="$s1" -v s2="$s2" -v t="$THRESH" 'BEGIN{ print (s1>=t && s2>=t) ? 1 : 0 }')"
    if [ "$bad" = "1" ]; then
      echo "  FAIL: $shape:$stage OP-COUNT is super-linear (s1=$s1 s2=$s2 >= $THRESH) — a List-as-set scan (util.contains/lookupAssoc) in the interpreter."
      fail=1
    fi
  fi
}

run_shape() {
  shape="$1"; base="$2"
  n2=$((base * 2)); n4=$((base * 4))
  case "$shape" in
    tailrec)   gen_tailrec   "$base" "$WORK/a.mdk"; gen_tailrec   "$n2" "$WORK/b.mdk"; gen_tailrec   "$n4" "$WORK/c.mdk" ;;
    listbuild) gen_listbuild "$base" "$WORK/a.mdk"; gen_listbuild "$n2" "$WORK/b.mdk"; gen_listbuild "$n4" "$WORK/c.mdk" ;;
    bigmatch)  gen_bigmatch  "$base" "$WORK/a.mdk"; gen_bigmatch  "$n2" "$WORK/b.mdk"; gen_bigmatch  "$n4" "$WORK/c.mdk" ;;
    bigmatch_lits) gen_bigmatch_lits "$base" "$WORK/a.mdk"; gen_bigmatch_lits "$n2" "$WORK/b.mdk"; gen_bigmatch_lits "$n4" "$WORK/c.mdk" ;;
  esac
  echo "── $shape  (N=$base, $n2, $n4) ──"
  oN="$(measure "$WORK/a.mdk")"; o2N="$(measure "$WORK/b.mdk")"; o4N="$(measure "$WORK/c.mdk")"
  grade "$shape" eval  "$BASE_EVAL_A"  "$BASE_EVAL_O"  "$oN" "$o2N" "$o4N"
  grade "$shape" ceval "$BASE_CEVAL_A" "$BASE_CEVAL_O" "$oN" "$o2N" "$o4N"
  echo
}

run_shape tailrec       "$TAILREC_N"
run_shape listbuild     "$LISTBUILD_N"
run_shape bigmatch      "$BIGMATCH_N"
run_shape bigmatch_lits "$BIGMATCH_LITS_N"

# ── NON-ZERO-GRADED assertion (PERF-CI-COVERAGE.md §8) ───────────────────────
if [ "$alloc_graded" -eq 0 ]; then
  echo "FAIL: the ALLOCATION arm graded NOTHING — a blind spot must name itself, not pass silently."
  fail=1
fi
# The op arm hard-fails on graded-NOTHING ONLY when a quadratic is LEDGERED (that entry
# MUST grade, else its measurement broke). With an EMPTY ledger (the #960 dedupHeads scan
# is fixed) a healthy tree legitimately drives no counted util.contains/lookupAssoc scan
# above the floor at these sizes, so grading nothing is EXPECTED — a loud NOTE, not a fail.
# Any REAL op-scan quadratic above the floor still hard-fails per-shape in grade(); this
# guard governs only the graded-NOTHING meta-case.
if [ "$op_graded" -eq 0 ]; then
  if [ -n "$KNOWN_SLOW_OPS" ]; then
    echo "FAIL: the OP-COUNT arm graded NOTHING but [$KNOWN_SLOW_OPS] is LEDGERED — the ledgered quadratic's op measurement is broken (a ledgered entry MUST grade). The op tripwire is dead."
    fail=1
  else
    echo "NOTE: the OP-COUNT arm graded nothing (ledger empty; no counted scan above op-floor $OP_FLOOR at these sizes). The op tripwire is armed but idle — a NEW super-linear op scan would still fail per-shape."
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: both interpreters scale as expected (alloc linear; op ledger empty — no op-scan quadratic)."
  exit 0
fi
exit 1
