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
# THIRD ARM: OP COUNT (issue #884). TIME's four rules above exist BECAUSE time is
# noisy. A deterministic per-stage OPERATION counter (List-scan steps in
# util.contains/util.lookupAssoc, threaded through profile_main's [perf] line as a
# tab-delimited 5th column) has NONE of that noise — so it needs no heap-pin, no
# min-of-K, and crucially no 200ms floor. Its unique payoff is the SMALL front-end
# stages: `mark` (and desugar/exhaust-guards) sit under the floor on EVERY shape, so
# the TIME arm grades them NOWHERE, while OP grades them from a single run — in fact
# from the SAME deterministic wasm-off run the alloc arm already makes each size, so it
# adds ZERO profiler invocations (see profile_run/ops_from). Same sustained-both-
# doublings rule; same promote-an-alloc-ok-to-fail-never-downgrade discipline (the
# SUPERLINEAR (OPS) branch sits after the alloc and time failures). See grade_op_stage,
# ops_from, OP_STAGES, the KNOWN_SLOW_OPS ledger, and the `marksweep` money-shot (an
# OP-ONLY shape — its TIME min-of-K arm is skipped).
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
# The MULTI-MODULE profiler (issue #153). The single-file PROFILE above cannot see
# the O(modules^2) family (checkModuleFullImpl / elabModuleStamp) because it never
# runs the multi-module driver — a gate must run where the bug lands. This one is
# profile_modules_main: loadProgram -> desugar -> markModules -> checkModules,
# emitting the SAME `[perf] <stage> <t>s <mb>MB` line protocol as PROFILE.
PROFILE_MODULES="$ROOT/test/bin/profile_modules_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

# Collect ALL missing oracles before failing — naming only the first costs a
# round-trip per oracle in a fresh worktree (#398 — this gate is the issue's own
# example: it needs BOTH profile_main and profile_modules_main).
_missing=""
[ -x "$PROFILE" ] || _missing="$_missing $PROFILE"
[ -x "$PROFILE_MODULES" ] || _missing="$_missing $PROFILE_MODULES"
if [ -n "$_missing" ]; then
  echo "build oracles first — missing:"
  for _m in $_missing; do
    echo "  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$_m")  (missing $_m)"
  done
  exit 2
fi

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
# ── QUICK (default, per-PR) vs DEEP (nightly) ────────────────────────────────
#
# PERF_DEEP=0 (default) drops the two shapes whose N band exists ONLY to lift a single
# slow-to-clear stage over the 200ms floor, and which together were ~80% of this gate:
#
#     xref @ 4000/8000/16000   sized for `resolve` (0.29 s at 16000)   ~376 s
#     manydefs @ 4000/8000/16000  sized for `lint` (0.62 s at 16000)   ~100 s
#
# QUICK still runs `xref`, at 2000/4000/8000 — it does NOT drop the shape, and that is
# the point of the split. The BACKEND rows survive: `emit` reads 2.74 s and `wasm-emit`
# 10.4 s at 8000, both far over the floor and both still ledgered and graded, so
# backend_graded stays 1 and #359's arm keeps running on every PR. Only `resolve` falls
# under the floor (~0.145 s at 8000) and SKIPs — loudly — so the #78 resolve detector is
# what DEEP is really for.
#
# ⚠️ WHY THIS SPLIT AND NOT "MOVE perf_scaling TO NIGHTLY": jobs run in parallel, so CI
# wall-clock is the SLOWEST shard. At 12 min this gate WAS `gates (types)` and was the
# critical path, 3x `gates (engines)` (3.7 min) — the shard the ci.yml header still
# names as the pole. Deleting the gate from PRs would fix the clock and cost all per-PR
# perf coverage; this keeps the arm that catches emitter quadratics where the bug lands
# and banishes only the two N=16000 bands, which no amount of restructuring can afford:
# at K=5 they are irreducible. (Measured: routing every stage to its own band still only
# reaches ~400 s. You cannot hold N=16000 at K=5 and get under 4 min.)
#
# DEEP is not optional coverage — nightly.yml runs it, and the skips print loudly rather
# than silently narrowing the gate. Run it locally with PERF_DEEP=1.
PERF_DEEP="${PERF_DEEP:-0}"

# xref's band follows the mode: DEEP keeps resolve's 4000 (-> 16000 at 4N), QUICK uses
# 2000 (-> 8000), which is also XREF_WASM_N — so in QUICK the wasm row rides the main
# pass and costs no extra invocation at all (see grade_wasm_row).
if [ "$PERF_DEEP" = "1" ]; then XREF_N="${PERF_XREF_N:-4000}"; else XREF_N="${PERF_XREF_N:-2000}"; fi

# `comments` samples at its own N so the `fmt` stage clears the 200ms TIME_FLOOR at
# the largest size (4N): at base 1000 → 4000, fmt is ~0.46s on a correct compiler,
# comfortably gradeable. Smaller and the floor would (correctly) refuse to grade
# it, blinding the gate to the formatter/comment quadratic it exists to catch.
COMMENTS_N="${PERF_COMMENTS_N:-1000}"

# `manydefs` samples at its own N for the same reason `xref` does: the stage it
# must be able to see (`lint`) only reaches ~0.62s at N=16000 (4N of 4000). At a
# 2000-base range its largest-N lint time is 0.28s — barely over the 200ms floor,
# so a faster runner could drop it UNDER and the floor would silently SKIP the one
# stage this shape exists to grade. Sized for ~3x floor headroom instead.
MANYDEFS_N="${PERF_MANYDEFS_N:-4000}"

# `manyifaces` / `widerecords` (issue #883) run at the DEFAULT N band (250/500/1000).
# Both are OP-ONLY (deterministic, no min-of-K), so the band is chosen for the OP arm,
# not a TIME floor: at 250/500/1000 `manyifaces` clears mark op r1>3 (3.07/3.54) with R=8
# co-scaling, and `widerecords` keeps resolve op1 (~2783) over OP_FLOOR while its counted
# stages all read `ok`. Knobs reserved for DEEP/tuning; defaults match the ledgered bands.
MANYIFACES_N="${PERF_MANYIFACES_N:-$N}"
WIDERECORDS_N="${PERF_WIDERECORDS_N:-$N}"

# `xref` samples the WASM arm at its OWN, SMALLER band — 2000/4000/8000 rather than
# the shape's 4000/8000/16000. This is a COST fix and it is the reason this gate is
# not the CI critical path. The band is deliberate — a ratio measured here does not
# transfer to another band (see the XREF_WASM_N note below and grade_wasm_row's xref
# arm before changing it).
#
# Why the band can move at all: xref's N is sized for `resolve`, the only stage that
# needs N=16000 to clear the 200ms floor. wasm_emit is ~10x llvm_emit and was being
# dragged to resolve's N — 42 s per run, x K=5 = ~211 s of one CI shard for ONE row.
# At 8000 it still reads ~10 s, 50x the floor, and still reads r2=3.82. The signal
# does not need N=16000; only `resolve` did.
XREF_WASM_N="${PERF_XREF_WASM_N:-2000}"

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
# CURRENT ENTRIES:
#
#   modules — the O(modules^2) family (issue #153), measured through the
#           multi-module driver (profile_modules_main -> checkModules). N import-
#           chained modules, K=8 impls each; the accumulated decl universe that
#           checkModuleFullImpl rescans per module and elabModuleStamp rebuilds via
#           buildKeyTable(accAll ++ prog) grows O(modules), rescanned per module =
#           O(modules^2). This is a REAL, UNFIXED quadratic filed as #154/#150 —
#           NOT a shape that should be green. It is ledgered (not shipped red)
#           BECAUSE those fixes have not landed: the ledger asserts the current bad
#           net-total-allocation ratio so the gate is green now, FAILS if the ratio
#           worsens (KNOWN_CEIL_modules), and FAILS demanding promotion the moment
#           #154/#150 drop it back to linear (KNOWN_FIXED_modules) — which is the
#           measurement those Phase-2 fixes were asked to turn green. The fixture
#           TYPECHECKS 0-DIAGNOSTIC (proven with `medaka check`) — see gen_modules;
#           a resolve-broken fixture would measure a DIFFERENT module-count-scaling
#           mechanism (per-module rebinding of unresolved names), not this one.
#           MEASURED (this box, deterministic net-total alloc, N=100/200/400, K=8):
#             net-N 286 MB -> net-2N 927 MB -> net-4N 3313 MB   r1=3.24 r2=3.57
#           and the typecheck stage in isolation (where the bug lives) r1=3.50
#           r2=3.78. The ratio CLIMBS toward the pure-quadratic 4.0 as N grows
#           (typecheck alloc 3.78 -> 3.91 at N=400/800), so it is a quadratic, not a
#           heap-resize step. TIME is separately ledgered in KNOWN_SLOW_TIME.
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
#   modules — MULTI-MODULE typecheck (issue #153/#154). The whole O(modules^2) family.
#           #154 PR-A eliminated registerAllData's per-module public-data re-registration
#           (the DOMINANT concat, ~11x coefficient cut; r2 ~4.0 -> ~2.27); PR-B made
#           argDispatchIndices/registerAllData incremental; PR-C (this) removed the LAST
#           quadratic — the `accAll ++ prog` / `accData ++ publicDataDecls` concats in
#           foldModules, which copied a GROWING left operand every iteration. The perf-gate
#           `checkModules` path reads NEITHER accumulator (checkBodyImpl binds accData as a
#           dead `Module _ _ _` field; cmCheckWorker ignores accAll), so PR-C threads them
#           UNCHANGED there via per-worker wantData/wantAll signals — O(N) total. MEASURED
#           net-alloc, FLAT and linear to N=1600 (r2 2.02 @ 100/200/400, 2.02 @ 200/400/800,
#           2.04 @ 400/800/1600; 91 -> 183 -> 370 -> 748 -> 1528 MB), and typecheck TIME
#           dropped under the 200ms floor. PROMOTED OUT 2026-07-16 — now a HARD linear gate.
# No currently-ledgered superlinear shapes: every entry has drained. is_known() below
# stays (a future regression can re-ledger a shape without re-adding the plumbing).
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
#   comments — the COMMENT side-channel + the FORMATTER. N functions each with a
#              leading + two trailing comments, so comment count scales with N.
#              The ONLY shape that exercises `fmt` (profile_main runs formatSource):
#              lexer.collectComments/posLineColFrom and fmt.formatProgram. Both
#              historical quadratics here were pure scans (offset→line rescanned
#              from 0 per comment; remaining-comment-tail rescanned per decl), so
#              like #78/#115 they are graded on TIME — allocation is blind to them.
#              See gen_comments and the fmt entry in TIME_STAGES.
#   manydefs — the LINTER's per-file tier. N signed tiny private defs + one export.
#              The other shapes are blind to it: `bindings` has no signatures (so
#              ruleMissingSignature's set stays empty) and its defs are too few to
#              separate the O(defs^2) term from the rule's heavy linear term. Both
#              of this rule's fixed quadratics were List-as-a-SET (dead-code's
#              assoc-list ref map + `contains`-over-visited; missing-signature's
#              `contains` over signed names) — the same shape as #78/#115 — and
#              BOTH are invisible to the alloc verdict (see the `lint` note in
#              TIME_STAGES), so this shape is graded on lint TIME.
#   manyifaces — CO-SCALED interfaces x call sites (issue #883). N interface decls
#              (methods pool ~N) AND N reference sites, growing TOGETHER, so mark's
#              `contains x methods` List-as-set reads O(N^2). OP-ONLY (mark is under the
#              TIME floor); ledgers manyifaces:mark (the target) + manyifaces:resolve (a
#              second, interface-count quadratic the shape surfaces). See gen_manyifaces.
#   widerecords — the RECORD shape (issue #883). One record type with N fields + N tiny
#              accessor/updater decls. Exercises resolve's ownersOf/lookupRecordByName —
#              but those are HAND-ROLLED (uncounted), so op reads LINEAR: an `ok` guard,
#              not an ownersOf detector (the real O(N^2) is TIME-only, N>=~4000). OP-ONLY.
#              See gen_widerecords.
#   modules  — MULTI-MODULE (issue #153). The five shapes above are single-file,
#              so they run only the single-file driver and are STRUCTURALLY BLIND
#              to the O(modules^2) family in checkModuleFullImpl / elabModuleStamp.
#              This shape runs the multi-module driver (profile_modules_main) over
#              N import-chained modules — see gen_modules and the dedicated block
#              after the single-file loop. It is a LEDGERED, currently-UNFIXED
#              quadratic (#154/#150); see KNOWN_SUPERLINEAR / KNOWN_SLOW_TIME.
gen_bindings() {
  n=$1; f=$2; : > "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf 'f%s : Int -> Int\nf%s x = x + %s\n' "$i" "$i" "$i"
    i=$((i+1))
  done >> "$f"
  # An `emit`-able program MUST have a `main` — emitProgram panics "no `main`
  # binding" without one, which aborted the WHOLE profiler (issue #359 wiring).
  # It matches the _baseline.mdk fixture, so it subtracts straight back out.
  printf 'main = println 1\n' >> "$f"
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
  # ⚠️ `main` CALLS `toInt`, and that is load-bearing — do not "simplify" it.
  #
  # This shape is the OPPOSITE of xref and the more dangerous one: its whole cost is
  # concentrated in a SINGLE decl (`toInt`, N arms over N ctors) rather than spread
  # across N decls. `main = println 1` roots nothing, so dceFilter prunes `toInt`
  # outright and the backend stages time an empty program — this shape read a
  # meaningless 22 ms at N=1000 and SKIPped, i.e. it silently graded NOTHING.
  # Rooting `toInt` puts that one big decl on the live path, where DCE cannot touch
  # it, which is exactly where a per-decl blowup in the emitter would show.
  printf 'main = println (toInt C0)\n' >> "$f"
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
  # An `emit`-able program MUST have a `main` — emitProgram panics "no `main`
  # binding" without one, which aborted the WHOLE profiler (issue #359 wiring).
  # It matches the _baseline.mdk fixture, so it subtracts straight back out.
  printf 'main = println 1\n' >> "$f"
}

gen_nesting() {
  n=$1; f=$2; : > "$f"
  # N-deep let nesting: stresses recursion depth in every tree-walking pass
  printf 'deep : Int\ndeep =\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  let v%s = %s\n' "$i" "$i" >> "$f"; i=$((i+1)); done
  printf '  v0\n' >> "$f"
  # An `emit`-able program MUST have a `main` — emitProgram panics "no `main`
  # binding" without one, which aborted the WHOLE profiler (issue #359 wiring).
  # It matches the _baseline.mdk fixture, so it subtracts straight back out.
  printf 'main = println 1\n' >> "$f"
}

gen_manydefs() {
  n=$1; f=$2; : > "$f"
  # N SIGNED, private, tiny top-level defs + one exported `main`. Two shapes in one:
  #   * many defs  -> the dead-code rule's ref-map/closure (reachableNames) and the
  #     exported/reachable membership tests scale with the DEF COUNT;
  #   * one signature per def -> ruleMissingSignature's signed-name set scales too.
  # Bodies are deliberately TINY: the rule's honest linear term (declToString +
  # identTokens per decl) is proportional to body size, so small bodies keep it from
  # diluting the O(defs^2) term. With real bodies the pre-fix ratio only reached
  # 3.05 (under the 3.0 gate) at 3200 defs; with tiny ones it hits 3.32/3.59 (alloc)
  # and 3.45/4.47 (time) — an unmistakable signal.
  printf 'export main : Int\nmain = p0 + p1\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf 'p%s : Int\np%s = %s\n' "$i" "$i" "$i"
    i=$((i+1))
  done >> "$f"
}

gen_comments() {
  n=$1; f=$2; : > "$f"
  # N functions, each carrying a LEADING comment line + a TRAILING comment on both
  # its signature and its body. This is the ONLY shape that populates the comment
  # side-channel, and the comment count scales with N — the input a formatter
  # quadratic needs. It exercises `fmt` (profile_main runs `formatSource`):
  #   * lexer.collectComments/rawToComments/posLineColFrom — offset→(line,col) for
  #     every comment (was rescanned from offset 0 per comment → O(comments×bytes));
  #   * fmt.formatProgram — the per-decl comment interleaving (was a full remaining-
  #     tail rescan per decl → O(decls×comments)).
  # BOTH are pure scans that allocate ~nothing, so this shape is graded on fmt TIME
  # (the alloc verdict is blind to it — the issue #110 class). Sized (COMMENTS_N)
  # so fmt time at 4N clears the 200ms floor; see the base_n case in the loop.
  i=0; while [ "$i" -lt "$n" ]; do
    printf -- '-- leading comment %s describing the function defined just below it\n' "$i"
    printf 'f%s : Int -> Int  -- trailing comment on the signature of f%s\n' "$i" "$i"
    printf 'f%s x = x + %s  -- trailing comment on the body of f%s\n' "$i" "$i" "$i"
    i=$((i+1))
  done >> "$f"
  # An `emit`-able program MUST have a `main` — emitProgram panics "no `main`
  # binding" without one, which aborted the WHOLE profiler (issue #359 wiring).
  # It matches the _baseline.mdk fixture, so it subtracts straight back out.
  printf 'main = println 1\n' >> "$f"
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
  # ⚠️ `main` CALLS THE HEAD OF THE CHAIN, and that is load-bearing — do not
  # "simplify" it to `println 1`.
  #
  # An emit-able program must have a `main` at all (emitProgram panics "no `main`
  # binding" without one). But a `main` that reaches NOTHING is worse than useless
  # here: profile_main runs `dceFilter` exactly as the real build driver does, whose
  # roots are `main` + impl/interface bodies. With `main = println 1` every f0..fN is
  # DEAD, gets pruned before lowering, and the backend stages would time the prelude
  # and nothing else -- a ratio describing a scenario no real build performs.
  #
  # f%s calls f%s-1, so calling the LAST one transitively retains the WHOLE chain
  # through DCE. This is what makes the `xref:emit` quadratic a claim about
  # `medaka build` rather than about an artifact of the harness.
  # NB: f$((n-1)), not $prev — $prev leaves the loop at n-2, which would strand the
  # last function as the one dead decl.
  printf 'main = println (f%s 0)\n' "$((n - 1))" >> "$f"
}

# gen_marksweep — THE MONEY-SHOT for the op arm (issue #884). It drives marker's
# `contains x methods` scan directly, against a METHOD POOL THAT GROWS WITH N.
#
# ONE interface with N methods => the marker's `methods` pool has size ~N (cheap: one
# decl with N signatures, not N interface decls, so parse/fmt/lint stay small). Then a
# CONSTANT number of value bindings, each a chain of references to a non-method
# top-level `base`, forces a full `contains _ methods` scan of that growing pool at
# each of a FIXED number of sites. Constant sites x O(N) pool = O(N) op work => LINEAR
# (op-ratio ~2.0, once the fixed prelude-marking op constant is out-scaled), which is
# exactly why it reads "ok" on a correct compiler.
#
# WHY IT IS THE MONEY-SHOT: `mark`'s absolute time is ~30-95 ms here — FAR under the
# 200ms TIME_FLOOR at every N — so the TIME arm would SKIP `mark` and provide ZERO
# coverage of it; the deterministic OP arm grades it (r2 ~1.8) from a single run. This
# shape is therefore run OP-ONLY (its TIME min-of-K arm is skipped in the loop — it
# would grade nothing but cost ~K runs per size), so its op grade rides the shared
# deterministic run. And because the pool GROWS with N, a marker quadratic (e.g. a
# regression making `contains` scan the tail redundantly) turns each scan into
# O(pool^2) => the op ratio jumps toward 4.0 and the OP arm FAILs on a stage the TIME
# arm structurally cannot grade at these sizes.
#
# Sites (S) and refs-per-site (R) are sized so S*R (~4000) out-scales the ~125k fixed
# prelude-marking op constant enough for a clean linear read, while keeping `mark` time
# well under the floor. R is FIXED (independent of N), so per-decl typecheck cost does
# NOT grow with N — this shape does not re-trigger the listlit:typecheck size-of-one-
# decl blowup; only the method POOL scales.
gen_marksweep() {
  n=$1; f=$2; : > "$f"
  s=40; r=100
  printf 'interface Pool a where\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  m%s : a -> Int\n' "$i"; i=$((i+1)); done >> "$f"
  printf 'base : Int\nbase = 1\n' >> "$f"
  k=0; while [ "$k" -lt "$s" ]; do
    printf 'h%s : Int\nh%s = base' "$k" "$k"
    j=1; while [ "$j" -lt "$r" ]; do printf ' + base'; j=$((j+1)); done
    printf '\n'
    k=$((k+1))
  done >> "$f"
  # `main` reaches only h0 -> base, so DCE prunes the rest — but mark/resolve/typecheck
  # run BEFORE DCE and see the whole file, which is all this shape needs (it is a
  # front-end shape; its backend stages are not graded and xref carries backend).
  printf 'main = println h0\n' >> "$f"
}

# gen_manyifaces — THE CO-SCALED MARK QUADRATIC (issue #883, §5 hole 8). It is the
# marksweep money-shot's QUADRATIC counterpart: where marksweep grows ONLY the method
# pool (fixed sites => LINEAR), this grows BOTH the pool AND the reference-site count
# together, so mark's `contains x methods` scan (marker.mdk markVar/markInfix — a
# List-as-set walked for EVERY var/op node, `methods` = every interface-method name)
# reads O(sites x pool) = O(N^2). This is the §5 "co-scale the two dimensions that
# multiply" rule: the N->2N doubling of a single axis sees only a linear slice of an
# O(a x b) blow-up (marksweep's fixed-site read is exactly that linear slice, on
# purpose — the two shapes are a matched pair).
#
#   N interface decls, each ONE method  => `methods` pool ~N (base names m0..m{N-1}).
#   N reference sites (h0..h{N-1}), each R=8 refs to the NON-method value `base`.
# `base` is not in `methods`, so each of the R*N `base` var nodes forces a FULL
# `contains base methods` scan of the O(N) pool => R*N * O(N) = O(N^2) counted ops.
# R is a small FIXED constant so it out-scales the ~125k fixed prelude-marking op
# constant enough for a clean read at the default N band (mark op r1=3.07 r2=3.54 at
# 250/500/1000 — climbing; ledgered `manyifaces:mark`). The `+` operator nodes hit
# markInfix's `contains op methods` too, but `+` IS a prelude method and `methods`
# prepends `preludeMethods`, so that scan stops in the O(1) prelude prefix — it does
# not add to the quadratic (only the non-method `base` refs do).
#
# GRADED OP-ONLY (like marksweep): these stages sit FAR under the 200ms TIME_FLOOR here
# (~40-200 ms), so the TIME arm grades them NOWHERE; the deterministic OP arm does. The
# shared run surfaces the SAME O(interfaces^2) interface-registration/duplicate-checking
# class (scanning the growing ifaceMethods/interfaces lists once per interface — #954)
# across several stages, most now fixed:
#   * mark — FIXED (#975); was `manyifaces:mark`.
#   * resolve — FIXED (#969, findDups -> OrdMap); was `manyifaces:resolve` (r1=3.68 r2=3.83).
#   * typecheck — ledgered `manyifaces:typecheck` (r1=3.27 r2=3.60). It read `ok` on main
#     (r1=2.65) only because the #907 stampBindingIds op-quadratic (typecheck's checkBodyImpl)
#     DILUTED it; fixing #907 removed that masking term and surfaced the true ratio, exactly
#     the "future source change lifting r1 over 3 forces a ledger decision" this note predicted.
# elaborate (op r1=2.71 r2=3.21) still CLIMBs but stays r1<3, so it reads `ok` and is NOT
# ledgered (WATCH: a future source change lifting r1 over 3 will correctly fail and force a
# ledger decision then, exactly as the comments:typecheck note warns).
gen_manyifaces() {
  n=$1; f=$2; : > "$f"
  r=8
  {
    i=0; while [ "$i" -lt "$n" ]; do
      printf 'interface P%s a where\n  m%s : a -> Int\n' "$i" "$i"
      i=$((i+1))
    done
    printf 'base : Int\nbase = 1\n'
    i=0; while [ "$i" -lt "$n" ]; do
      printf 'h%s : Int\nh%s = base' "$i" "$i"
      j=1; while [ "$j" -lt "$r" ]; do printf ' + base'; j=$((j+1)); done
      printf '\n'
      i=$((i+1))
    done
    # mark/resolve/typecheck run BEFORE DCE and see every decl; `main` reaches only
    # h0 (the rest are pruned before the backend, which this front-end shape does not
    # grade — xref carries backend).
    printf 'main = println h0\n'
  } >> "$f"
}

# gen_widerecords — THE WIDE-RECORD SHAPE (issue #883, §5 hole 9). The ONLY shape that
# declares a record: a data decl with N fields, plus N tiny accessor decls (`gI r =
# r.fI`) and N tiny updater decls (`uI r = { r | fI = I }`), each ONE field mention.
# In resolve every field mention routes through `ownersOf fname env.fieldOwners`
# (resolve.mdk) — a linear scan of the (field,owner) multimap, which is N long — so the
# 2N field mentions cost O(N^2). Tiny per-decl bodies (one field mention each) avoid the
# one-big-expression typecheck/emit blow-up a single N-wide `r.f0 + ... + r.fN` sum or
# an N-deep nested `{ ... | fN = N }` update would trigger (measured: the wide-expr cut
# spent 2 s in `emit` at N=500 alone).
#
# ⚠️ DISPROVEN OP PREMISE — THIS SHAPE READS LINEAR ON OP-COUNT, and that is a real
# #883 finding, not a defect. `ownersOf` (and its sibling `ownsAnyField`) are
# HAND-ROLLED recursive scans that call NEITHER util.contains NOR util.lookupAssoc, so
# the deterministic OP counter (which only instruments those two) is STRUCTURALLY BLIND
# to them — identical to `starimports`/`findExports`. resolve's counted op work here is
# only the O(1) `contains owner owners` over the tiny per-field owners result, so op
# reads a flat r~2.0 (LINEAR). So this is an `ok` LINEAR regression guard on the counted
# record-resolution paths, NOT an ownersOf quadratic detector.
#
# The REAL ownersOf O(N^2) is visible only on resolve TIME, and only at N>=~4000 (it is
# ~180 ms at N=2000, under the 200ms floor; the counted path is cheap so alloc is blind
# too). A DEEP-only resolve-TIME arm would catch it, but at that N typecheck/elaborate
# TIME are also superlinear (the #907/#882 decl-count classes, over the floor) and would
# need their own ledger rows — filed as a #880 follow-up rather than paid for in QUICK.
# GRADED OP-ONLY (cheap, deterministic). Because grade_op_stage SKIPs (never fails) a
# below-OP_FLOOR reading, the SHAPES loop carries a DEDICATED widerecords resolve-op1 <
# OP_FLOOR ⇒ fail guard (added per the #883 PR review — see the "widerecords silent-green
# guard" block after the OP arm) so a band retune that blinds this guard fails loudly
# instead of silent-passing "ok". (The generic loop does NOT self-guard this — only the
# rshape and this explicit check do.)
gen_widerecords() {
  n=$1; f=$2; : > "$f"
  {
    printf 'data R = R { '
    i=0; while [ "$i" -lt "$n" ]; do [ "$i" -gt 0 ] && printf ', '; printf 'f%s : Int' "$i"; i=$((i+1)); done
    printf ' }\n'
    printf 'mk : R\nmk = R { '
    i=0; while [ "$i" -lt "$n" ]; do [ "$i" -gt 0 ] && printf ', '; printf 'f%s = %s' "$i" "$i"; i=$((i+1)); done
    printf ' }\n'
    i=0; while [ "$i" -lt "$n" ]; do
      printf 'g%s : R -> Int\ng%s r = r.f%s\n' "$i" "$i" "$i"
      printf 'u%s : R -> R\nu%s r = { r | f%s = %s }\n' "$i" "$i" "$i" "$i"
      i=$((i+1))
    done
    # main roots only g0/u0/mk; resolve/typecheck (the graded stages) run pre-DCE over
    # every decl. The tiny reached set keeps the backend stages small.
    printf 'main = println (g0 (u0 mk))\n'
  } >> "$f"
}

# gen_modules — the ONLY multi-module generator (issue #153). Writes N separate
# .mdk files into DIR, chained by import (m0 <- m1 <- ... <- m{N-1} <- entry), each
# module defining K data types + K impls of a shared interface `Widget`,
# re-exporting `Widget(..)` and its method `wval` down the chain, and EXERCISING
# every one of its K impls in a local `useI` value. Unlike the five single-file
# shapes, this one is DIRECTORY-shaped: the modules block below feeds `entry.mdk` +
# DIR to profile_modules_main so loadProgram walks the whole chain and checkModules
# runs over the accumulated decl universe — which is exactly what the O(modules^2)
# family (checkModuleFullImpl's per-module rescan, elabModuleStamp's
# buildKeyTable(accAll ++ prog)) scales with.
#
# ⚠️ THE FIXTURE MUST RESOLVE CLEANLY, or the gate measures the WRONG quadratic.
# profile_modules_main drives markModules/checkModules, which do NOT run
# frontend.resolve and DISCARD its result — so a resolve-BROKEN fixture still prints
# growing MB, but that growth can be the compiler re-failing to bind the same
# unresolved names once per module (a different module-count-scaling mechanism),
# NOT the checkModuleFullImpl/elabModuleStamp rescan #154/#150 are about. An earlier
# cut of this generator was resolve-broken exactly this way (bare `import m.{Widget}`
# does not re-export; plain `export data` is VisAbstract so the constructor is not
# exported; the interface method `wval` was never imported). The three fixes below
# are load-bearing and each was reproduced with `medaka check`:
#   * `export import` — re-export Widget+wval down the chain (plain import does not).
#   * `public export data` — export the CONSTRUCTOR (plain `export data` is abstract).
#   * import `Widget(..), wval` — bring the interface's METHOD into scope to dispatch.
# The corrected fixture typechecks 0-diagnostic AND still exhibits O(modules^2) in
# typecheck (r2: net alloc 3.57, typecheck alloc 3.78, typecheck time 4.12 at
# N=100/200/400, K=8) — STRONGER than the broken one, confirming the quadratic is
# the real accumulated-universe rescan, not a binding-failure artifact.
#
# WHY K>1 and WHY IMPLS. A plain function chain (each module one `fN x = ...`)
# scales LINEARLY here (measured typecheck alloc 1.72x/1.84x/1.91x) — the
# accumulated universe those passes rescan is IMPL/interface/data decls, not plain
# bindings, so plain functions never populate it. K impls per module do, and K is a
# linear multiplier on the quadratic coefficient, so a modest constant K keeps the
# module COUNT (and thus the file count and the gate's wall time) small while the
# quadratic still dominates by N=100. "Constant decls per module, scale the module
# count" — issue #153's fix shape.
gen_modules() {
  n=$1; dir=$2; k=$3
  rm -rf "$dir"; mkdir -p "$dir"
  {
    printf 'export interface Widget a where\n  wval : a -> Int\n\n'
    j=0; while [ "$j" -lt "$k" ]; do
      printf 'public export data T0_%s = T0_%s\nexport impl Widget T0_%s where\n  wval _ = %s\n' "$j" "$j" "$j" "$j"
      j=$((j+1))
    done
    printf 'export use0 : Int\nuse0 = '
    j=0; while [ "$j" -lt "$k" ]; do [ "$j" -gt 0 ] && printf ' + '; printf 'wval T0_%s' "$j"; j=$((j+1)); done
    printf '\n'
  } > "$dir/m0.mdk"
  i=1
  while [ "$i" -lt "$n" ]; do
    prev=$((i - 1))
    {
      printf 'export import m%s.{Widget(..), wval}\n' "$prev"
      j=0; while [ "$j" -lt "$k" ]; do
        printf 'public export data T%s_%s = T%s_%s\nexport impl Widget T%s_%s where\n  wval _ = %s\n' \
          "$i" "$j" "$i" "$j" "$i" "$j" "$j"
        j=$((j+1))
      done
      printf 'export use%s : Int\nuse%s = ' "$i" "$i"
      j=0; while [ "$j" -lt "$k" ]; do [ "$j" -gt 0 ] && printf ' + '; printf 'wval T%s_%s' "$i" "$j"; j=$((j+1)); done
      printf '\n'
    } > "$dir/m$i.mdk"
    i=$((i+1))
  done
  top=$((n - 1))
  printf 'import m%s.{Widget(..), wval, T%s_0(..)}\nmain = println (wval T%s_0)\n' "$top" "$top" "$top" > "$dir/entry.mdk"
}

# gen_starimports — the STAR import fan-in (issue #881). N leaf modules, each
# exporting one value, and ONE entry module importing ALL of them and referencing
# every imported symbol (so no import is unused). This is the multi-module RESOLVE
# analogue of `xref`: production's resolveModulesErrorsG threads `known` and resolves
# each of the entry's N imports via findExports — a LINEAR scan of the N-long known
# list — so the entry alone is O(N^2) in findExports COMPARISONS.
#
# ⚠️ MEASURED FINDING (issue #881): on this shape resolve is EFFECTIVELY LINEAR on every
# arm this gate has. The findExports quadratic is real but (a) its per-step cost is a
# cheap `modId ==` string compare, DWARFED by the ~0.6 MB/module linear buildEnvMM
# allocation (net resolve alloc/time both read ~2.0x here), and (b) findExports is a
# HAND-ROLLED recursive scan that calls NEITHER util.contains NOR util.lookupAssoc, so
# the deterministic OP counter is STRUCTURALLY BLIND to it (per #884's design: an inline
# scan stays TIME-arm-only). The op-count this shape DOES read (5*N — isPubExp's four
# `contains` per resolved import) is linear. So this shape is a LINEAR regression guard
# on the counted import-membership path, NOT a quadratic detector; it reads `ok`. See
# the resolve-shapes block and the #881 note in KNOWN_SLOW_OPS.
gen_starimports() {
  n=$1; dir=$2
  rm -rf "$dir"; mkdir -p "$dir"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf 'export v%s : Int\nv%s = %s\n' "$i" "$i" "$i" > "$dir/m$i.mdk"
    i=$((i+1))
  done
  {
    i=0
    while [ "$i" -lt "$n" ]; do printf 'import m%s.{v%s}\n' "$i" "$i"; i=$((i+1)); done
    # Reference EVERY imported name so none is unused (a 0-diagnostic fixture — the
    # gen_modules trap: a resolve-broken fixture measures a different mechanism).
    printf 'main = println ('
    i=0
    while [ "$i" -lt "$n" ]; do [ "$i" -gt 0 ] && printf ' + '; printf 'v%s' "$i"; i=$((i+1)); done
    printf ')\n'
  } > "$dir/entry.mdk"
}

# gen_reexports — the N-deep `export import` RE-EXPORT fan-out (issue #881). m0 exports
# v0; each m_i does `export import m{i-1}.*` (re-exporting the whole accumulated set) AND
# exports its own v_i; the entry imports the top module's `.*` and references the shallow
# and deep ends. Unlike the star, THIS shape's resolve cost runs through buildExports /
# isPubExp `contains` checks over an export list that GROWS with depth, once per
# re-exported name per module — which the OP counter DOES see.
#
# ⚠️ MEASURED FINDING (issue #881): resolve here is SUPER-LINEAR — a real, currently
# unfixed cost. Op-count is ~CUBIC (r ~7.9/doubling ≈ 2^3) because the `.*` re-export
# re-checks the growing export set at each of a growing number of sites; net alloc and
# resolve TIME are ~QUADRATIC (~4x). It is LEDGERED on op-count (KNOWN_SLOW_OPS,
# self-draining) rather than shipped red. The fixture resolves 0-DIAGNOSTIC (proven with
# `medaka check`): `export import m.*` re-exports, and the entry's `import m.*` binds.
gen_reexports() {
  n=$1; dir=$2
  rm -rf "$dir"; mkdir -p "$dir"
  printf 'export v0 : Int\nv0 = 0\n' > "$dir/m0.mdk"
  i=1
  while [ "$i" -lt "$n" ]; do
    prev=$((i - 1))
    {
      printf 'export import m%s.*\n' "$prev"
      printf 'export v%s : Int\nv%s = %s\n' "$i" "$i" "$i"
    } > "$dir/m$i.mdk"
    i=$((i+1))
  done
  top=$((n - 1))
  printf 'import m%s.*\nmain = println (v0 + v%s)\n' "$top" "$top" > "$dir/entry.mdk"
}

# ── Measure ──────────────────────────────────────────────────────────────────
# ⚠️ THE ALLOCATION RUNS DO NOT RUN wasm-emit (env -u MEDAKA_PERF_WASM), and that is
# deliberate — it RESTORES this column to what it was calibrated on. #481 added the
# wasm stage to this driver, which silently folded wasm's ~242 MB prelude constant (and
# on rooted shapes its 519->1353 MB scaling term) into every `total` this column reads.
# It cost nothing to remove because ALLOC WAS ALREADY BLIND TO IT: #481's own finding
# was that this column reads a flat 2.02x "ok" for a wasm stage taking 38 SECONDS. So
# the wasm arm's coverage is, and always was, the TIME signal alone (grade_wasm_row) —
# excluding it here loses no signal, un-dilutes the numbers, and drops 3 wasm runs per
# shape. `env -u` because an empty-but-SET var reads as present (see stage_times_min).
#
# Returns TOTAL allocated MB for one fixture. Allocation is deterministic, so ONE
# run suffices — no min-of-K needed, and no noise to average away.
alloc_of() {
  env -u MEDAKA_PERF_WASM MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1 \
    | awk '/^\[perf\] total/ { gsub(/MB/,"",$4); print $4; exit }'
}

# Same, but through the MULTI-MODULE driver (issue #153). Args: <entry.mdk> <root>.
alloc_of_modules() {
  MEDAKA_PERF=1 "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$1" "$2" 2>&1 \
    | awk '/^\[perf\] total/ { gsub(/MB/,"",$4); print $4; exit }'
}

# ── ONE run, TWO deterministic arms (alloc + op) — the shared per-shape run ────
#
# The ALLOC and OP arms are BOTH deterministic and BOTH read the SAME wasm-off
# `MEDAKA_PERF=1` profiler run: allocation from the `total` line, op-counts from every
# stage line's tab-delimited 5th column (emitPhaseAO). So the loop runs the profiler
# ONCE per size, captures the full [perf] output, and derives both from it — the op
# arm costs ZERO extra invocations (it used to call a separate `stage_ops` run 3× per
# shape). `env -u MEDAKA_PERF_WASM` is identical to alloc_of's command, so the alloc
# numbers are byte-unchanged by this sharing.
#
# profile_run: emit the full [perf] output of one wasm-off run to stdout.
profile_run() {
  env -u MEDAKA_PERF_WASM MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1
}

# alloc_from: total allocated MB, from a saved profile_run output. Same awk as alloc_of.
alloc_from() {
  awk '/^\[perf\] total/ { gsub(/MB/,"",$4); print $4; exit }' "$1"
}

# ops_from: one "<stage> <opDelta>" line per stage, from a saved profile_run output.
# ⚠️ PARSE WITH awk -F'\t' AND READ FIELD 5. The profiler line is
#     [perf] <label>\t<t>s\t<MB>MB\t<ops>\t<opDelta>
# and the <ops> field (tab-field 4) is FREE-FORM with embedded spaces ("N decls"), so a
# whitespace split lands inside it and reads garbage. See support/timer.mdk:emitPhaseAO.
ops_from() {
  awk -F'\t' '/^\[perf\] / { split($1, a, " "); print a[2], $5 }' "$1"
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
# Arg 3 (`wasm`, 0/1) sets MEDAKA_PERF_WASM, which makes profile_main RUN the
# wasm-emit stage at all — it is opt-in there, not merely unprinted. At 0 the profiler
# emits no `wasm-emit` line and does no WAT rendering; the caller must not then ask for
# that row (grade_time_stage would correctly call the absence a harness bug).
#
# ⚠️ OFF MUST *UNSET* THE VAR, NOT SET IT EMPTY. `getEnv` is C `getenv` and an empty
# var is still SET, so `MEDAKA_PERF_WASM=` reads as present. Spelling `off` as
# `MEDAKA_PERF_WASM="$wenv"` with an empty $wenv therefore leaves the stage ON, this
# gate silently pays the ~277 s it exists to save, and NOTHING fails — the rows still
# print, the shard is just slow again. (Measured; timer.mdk's perfWasmEnabled now also
# reads empty as OFF, so this is belt-and-braces. Keep both: the two halves fail open
# independently.) `env -u` also strips an AMBIENT value from the caller's shell, which
# is what stops a developer's exported MEDAKA_PERF_WASM from quietly re-pricing CI.
stage_times_min() {
  fixture="$1"; k="$2"; wasm="${3:-0}"
  i=0
  while [ "$i" -lt "$k" ]; do
    if [ "$wasm" = "1" ]; then
      GC_INITIAL_HEAP_SIZE="$TIME_HEAP" MEDAKA_PERF=1 MEDAKA_PERF_WASM=1 \
        "$PROFILE" "$RUNTIME" "$CORE" "$fixture" 2>&1
    else
      env -u MEDAKA_PERF_WASM \
        GC_INITIAL_HEAP_SIZE="$TIME_HEAP" MEDAKA_PERF=1 \
        "$PROFILE" "$RUNTIME" "$CORE" "$fixture" 2>&1
    fi | awk '/^\[perf\] / { t = $3; gsub(/s$/, "", t); printf "%s %s\n", $2, t }'
    i=$((i+1))
  done | awk '
      { if (!($1 in m) || $2 + 0 < m[$1] + 0) m[$1] = $2 }
      END { for (st in m) printf "%s %s\n", st, m[st] }
    '
}

# Same, but through the MULTI-MODULE driver. Args: <entry.mdk> <root> <k>.
stage_times_min_modules() {
  entry="$1"; root="$2"; k="$3"
  i=0
  while [ "$i" -lt "$k" ]; do
    GC_INITIAL_HEAP_SIZE="$TIME_HEAP" MEDAKA_PERF=1 \
      "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$entry" "$root" 2>&1 \
      | awk '/^\[perf\] / { t = $3; gsub(/s$/, "", t); printf "%s %s\n", $2, t }'
    i=$((i+1))
  done | awk '
      { if (!($1 in m) || $2 + 0 < m[$1] + 0) m[$1] = $2 }
      END { for (st in m) printf "%s %s\n", st, m[st] }
    '
}

# ── OP-COUNT sampling (issue #884) ───────────────────────────────────────────
#
# The deterministic per-stage OPERATION counter (List-scan steps in util.contains /
# util.lookupAssoc, threaded through the profiler's emitPhaseAO 5th column). Unlike
# TIME this needs NO min-of-K, NO heap pin, and NO floor: GC-free integer counts are
# byte-for-byte reproducible, so ONE run yields the true per-stage op delta. That is
# the whole point — a deterministic signal grades the small stages (mark / desugar /
# exhaust-guards) that TIME physically cannot, because it is never contaminated by
# runner noise and so needs no 200ms floor to protect it.
#
# The per-stage op deltas are extracted (ops_from) from the SAME wasm-off run the ALLOC
# arm already makes each size — see the profile_run/alloc_from/ops_from block above.
# There is deliberately no separate op-sampling invocation: both arms are deterministic
# and share one run, so op-grading adds ZERO profiler invocations per shape.

# Stages to grade. `parse-prelude` is the FIXED one-time cost of runtime+core and
# does not scale with N, so grading it is meaningless; `total` is a sum and rule 1
# says never grade a sum.
#
# `fmt` is the comment-preserving format pass (profile_main runs `formatSource` on
# the target: collectComments + parseWithPositions + formatProgram). It is a pure
# scan — its two historical quadratics (lexer.posLineColFrom rescanned from offset
# 0 per comment; formatProgram rescanned the whole remaining comment tail per decl)
# allocated almost NOTHING, so allocation was blind to them and only the `comments`
# shape's TIME signal catches the class. On every OTHER shape fmt is under the
# 200ms floor and SKIPs (loud, harmless); the `comments` shape is sized so its fmt
# time clears the floor and is graded.
#
# `lint` is the PER-FILE lint tier (profile_main runs lintProgram over allRules on
# the raw AST). Graded on TIME, and the `manydefs` shape is sized so it clears the
# floor: its two historical quadratics were BOTH invisible to the alloc verdict —
# one (mergeRefs' assoc-list ref map) allocates quadratically but is only ~11% of
# `total`, so the total-alloc ratio DILUTES it to 2.24/2.53 ("ok") while the lint
# stage itself read 3.32/3.59; the other (missingSigPair's `contains` over the
# signed-name list) is a PURE SCAN that allocates nothing at all. Per-stage time is
# the only signal that sees both.
#
# `lower` and `emit` are the BACKEND arm (issue #359). Until 2026-07-16 this list
# stopped at typecheck, so the O(n^2) detector graded NOTHING downstream of the front
# end and every emitter quadratic was structurally invisible to it — the same blind
# spot that let a quadratic hide in `exhaust-guards`, one pipeline half later. The
# 2026-07-16 emitter audit (#349-#352) filed findings that sit entirely behind it, and
# most are PURE SCANS, so they need exactly this TIME arm: allocation cannot see them.
#
# ⚠️ THE BACKEND STAGES RUN BEHIND DCE, AND THAT DECIDES WHICH SHAPES CAN GRADE THEM.
# profile_main runs `dceFilter` before lowering, exactly as the real build driver does
# (llvm_emit_modules_main.mdk, half == 0). Its roots are `main` + impl/interface
# bodies, so a shape whose synthetic decls `main` never calls has them ALL pruned
# before the backend sees them: its `lower`/`emit` then time the prelude alone, come
# in far under TIME_FLOOR, and SKIP.
#
# That is CORRECT, not a malfunction — it is what `medaka build` does to those
# programs — and it is why only `xref` threads its decls into `main` (its chain makes
# one call retain all N). bindings/match/listlit/nesting/comments keep an unreachable
# `main = println 1`: they are FRONT-END shapes (DCE runs after typecheck, so parse/
# resolve/typecheck/fmt still see every decl and their rows are unaffected), and their
# backend stages were already under the floor even before DCE existed here.
#
# So do NOT read "lower/emit: SKIP" on those shapes as backend coverage. Backend
# coverage is `xref`, and the backend_graded counter below is what enforces that it
# did not silently become zero.
#
# ⚠️ These two stages carry a LARGE FIXED PRELUDE COST that the front-end stages do
# not: `lower`/`emit` run over `livePrelude ++ target`, so core.mdk is lowered and
# emitted on EVERY run (~13 MB / ~28 ms at N=1). The per-stage TIME arm does NOT
# subtract a baseline, so that constant DILUTES the ratio toward 1.0 — a quadratic in
# the target reads smaller here than it would in isolation. Read a `lower`/`emit`
# ratio as a LOWER BOUND on the true exponent: over-threshold is real, under-threshold
# is not proof of linearity.
#
# `wasm-emit` is the WASM ARM of the same issue (#359). `emit` above grades ONLY
# llvm_emit; wasm_emit is a separate ~10k-line backend and was equally unprofiled.
#
# ⚠️ ONE `emit` ROW CANNOT STAND IN FOR BOTH BACKENDS — this is measured, not assumed.
# #381 was a CUBIC in WasmGC ctor-switch emission (O(ctors x branches x table)) that did
# NOT reproduce on llvm_emit: `ctorOrdinal`'s whole-table scan is SHARED, but only wasm
# nested it inside a (slot, branch) loop. #401 fixed it (53x at N=400). The `match` shape
# is that exact shape and now reads r2=1.09 — the fix holds, and this row is what keeps
# it holding.
#
# ⚠️ THE PRELUDE CONSTANT IS FAR HEAVIER HERE THAN ON `emit`, and it changes how two
# rows must be read. wasm_emit renders the whole live prelude to WAT at ~0.215 s / ~240 MB
# no matter how small the target (llvm_emit: ~0.021 s / ~10 MB — 10x cheaper). Two
# consequences, both real:
#
#   * On the DEAD-`main` shapes (bindings/listlit/nesting/comments) DCE prunes the
#     synthetic decls, so this stage times THE PRELUDE AND NOTHING ELSE — but unlike
#     `lower`/`emit`, which fall under TIME_FLOOR and SKIP loudly, that constant is
#     ~0.215-0.25 s and generally CLEARS the 0.2 s floor. Those rows therefore print a
#     flat `ok r1≈1.0 r2≈1.0` (measured: 0.90/1.08, 1.09/1.21, 1.08/0.94). THAT "ok" IS
#     NOT BACKEND COVERAGE — it is the prelude constant being constant. Do not read it
#     as one, and do not let it satisfy backend_graded (see the counter below, which
#     deliberately excludes this stage).
#
#     ⚠️ THE CONSTANT IS NOT UNIVERSAL AND THE ROW COUNT IS LOAD-DEPENDENT — do not
#     build on either. `manydefs` SKIPs outright (156-174 ms): its `main = p0 + p1` is
#     `Int`-typed, not a `println`, so DCE keeps no Display/String prelude and there is
#     less WAT to render. `comments` sits ON the floor and flips: 220 ms (graded "ok")
#     on a loaded box, 198 ms (SKIP) on a quiet one. So "wasm-emit always clears the
#     floor" is FALSE, and so is any fixed count of rows it grades — both were asserted
#     by earlier drafts of this comment and both were falsified by the next full run.
#     Only ONE wasm row is guaranteed: `xref:wasm-emit`, and only because the ledger
#     forces it (a KNOWN_SLOW_TIME stage may not SKIP).
#   * On the ROOTED shapes (xref/match) the same constant DILUTES the ratio downward
#     harder than it does `emit`: at match N=1000 it is 79% of the reading. Under-
#     threshold here is even weaker evidence of linearity than it is for `emit`.
#
# ⚠️ `wasm-emit` IS NOT IN THIS LIST — it is graded by grade_wasm_row instead, on the
# shapes and the N band where it means something. It is NOT ungraded, and removing it
# from here does not weaken the deletion guard: grade_wasm_row routes through the same
# grade_time_stage, so a profiler that stops emitting the row still hard-fails with
# "NO MEASUREMENT". This list is "stages graded at the shape's own band"; wasm-emit is
# the one stage that is not, because it cannot afford resolve's N.
TIME_STAGES="parse exhaust-guards desugar resolve mark typecheck elaborate dce mangle fmt lint lower emit"

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
# modules:typecheck — the TIME side of the O(modules^2) family (issue #153), the
# axis allocation is weakest on for a scan-heavy quadratic. Measured through the
# multi-module driver (min-of-K, heap pinned, N=100/200/400, K=8) on the
# resolve-CLEAN fixture, typecheck at N=400 is ~4.5s (well over the 200ms floor),
# r1=3.89 r2=4.12 — the ratio EXCEEDS the pure-quadratic 4.0 in this pre-asymptotic
# regime (constant/linear terms already negligible), as match:typecheck did before
# #115 (it reached 6.56 at N=4000). Observed r2 spread 4.1-4.3 across runs; ceiling
# 5.6 gives listlit-precedent headroom over that band plus time noise, still
# catching a genuine worsening. Same
# self-draining contract as the alloc entry: promoted out when #154/#150 land (the
# fix drops typecheck under the 200ms floor at the largest N, tripping the "too FAST
# to time-gate" promotion branch).
# #154 PR-A/PR-B/PR-C drained modules:typecheck: PR-C removed the last foldModules-concat
# O(N^2) (see KNOWN_SUPERLINEAR note), and typecheck TIME fell UNDER the 200ms floor at the
# gate's N (190ms @ N=400) — the same "too fast to time-gate" outcome as match/listlit under
# #115 (match 6.0s->0.11s, listlit 5.3s->0.06s). PROMOTED OUT 2026-07-16; the modules block
# now SKIPS the typecheck TIME below the floor (unledgered rule-4 behavior) and hard-gates it
# as SUPERLINEAR if it ever climbs back over.
#   xref:emit — ✅ PROMOTED OUT 2026-07-17 (PR #554). The gate FOUND this quadratic
#     the moment it could see the backend (2026-07-16, issue #359) and has now
#     watched it DIE: r2=1.98 (< 2.60) — the emit stage scales LINEARLY. The row is
#     deleted from KNOWN_SLOW_TIME; the stage is hard-gated like any other, so if it
#     ever climbs back this gate fails on it rather than excusing it.
#
#     THE CAUSE, for the record — it is the thesis below, confirmed: the emitter was
#     QUADRATIC IN THE NUMBER OF TOP-LEVEL DECLARATIONS because the threaded `sigs`
#     table (size = |fns|, i.e. it GROWS with the program) was `lookupAssoc`-scanned
#     LINEARLY once per param-use site — O(decls x decls). #554 indexed it into an
#     `OrdMap`; emitted IR is byte-identical, so only the scan changed.
#
#     ⚠️ AND IT IS THE PROOF OF THIS GATE'S OWN TIME ARM: allocation read a clean,
#     flat, LINEAR 2.03x throughout and was BLIND to the whole bug — a pure scan
#     allocates nothing. Had this gate graded allocation only (as it did before
#     issue #359 added the TIME arm), this quadratic would still be here today, and
#     the emitter would still take TEN SECONDS to emit 16000 functions.
#
#     The historical measurement that caught it is kept below, deliberately: it is
#     what a real find looks like, and it is the calibration for the next one.
#
#         xref, emit stage            TIME              ALLOC (whole-run net)
#           N=4000                    0.643s            1528.8 MB
#           N=8000                    2.392s  (3.72x)   3099.5 MB  (2.03x)
#           N=16000                   9.917s  (4.15x)   6289.6 MB  (2.03x)
#
#     Allocation reads a clean, flat, LINEAR 2.04x/2.04x — "ok" — while emit takes
#     TEN SECONDS to emit 16000 functions. Heap pinned, min-of-5, quiet box (load
#     <4). It is NOT a GC heap-resize step: a step COLLAPSES one doubling later, and
#     this ratio CLIMBS (3.72 -> 4.15) to/past the pure-quadratic 4.0 with the heap
#     pinned at 2 GB. Observed r2 band across FOUR DCE-realistic quiet-box batches:
#     3.85 / 4.01 / 4.11 / 4.15 (r1 3.62-3.82). The ~4.0 reading is the stable one;
#     treat the band, not any single batch, as the measurement.
#
#     ⚠️ THESE ARE THE *DCE-REALISTIC* NUMBERS, and that distinction is the whole
#     reason to trust them. The first cut of this entry measured a fixture whose
#     `main = println 1` rooted NONE of the N functions — work `dceFilter` (which the
#     real build driver runs, and which profile_main now runs too) would have pruned
#     entirely. That ratio described a scenario no real build performs. With `main`
#     rooting the chain the quadratic SURVIVES DCE essentially unmoved (r2 3.96 ->
#     4.11/4.15), so this is now a claim about `medaka build`, not about the harness.
#
#     This is the EMPIRICAL CONFIRMATION of the 2026-07-16 emitter perf audit
#     (#349/#350/#352), which found the quadratics by reading the source. #349
#     (dedupS conses) allocates and should show on the alloc arm; #350/#352 are pure
#     scans over accumulated per-decl state, which is what a flat alloc ratio beside
#     a 3.96x time ratio looks like. Fix those and this entry PROMOTES OUT.
#
#     THE OTHER ROOTED SHAPE, AND WHY IT IS NOT LEDGERED (measured 2026-07-16):
#     `xref` spreads its cost over N decls; `match` concentrates it in ONE rooted
#     decl (`toInt`, N arms). Both are now DCE-reachable, so "pruned" and "survived"
#     are distinguishable outcomes rather than one ambiguous number. Rooted
#     `match:emit`, net of the ~0.028s prelude constant, on a quiet box (load 1.9):
#
#           N=1000   0.099s      N=2000  0.366s (3.71x)     N=4000  1.366s (3.73x)
#
#     So the native LLVM emitter is QUADRATIC on this shape too (~3.7x), NOT cubic.
#     Worth stating plainly because the ws:wasm workstream measured ~7.9-8.4x per
#     doubling (≈2^3, CUBIC) on the SAME shape through `wasm_emit_modules_main` (#381).
#     That was a wasm_emit finding; it did NOT reproduce on llvm_emit. Do not carry the
#     cubic claim across backends.
#
#     It is NOT in KNOWN_SLOW_TIME because at this gate's match sizes (250/500/1000)
#     emit peaks at 122 ms — under TIME_FLOOR, so it SKIPs and there is nothing to
#     ledger. Grading it would need its own base-N knob (~1000, where emit is 1.4s);
#     that is a deliberate follow-up, not an oversight — raising match's N also moves
#     its alloc rows and the T17 alloc ledger, which must be re-derived, not assumed.
#
#     UPDATE 2026-07-16 (#359 wasm arm) — THE WASM CUBIC ABOVE IS FIXED, AND NOW
#     MEASURED. #401 fixed #381 (53x at N=400), and the `match:wasm-emit` row now checks
#     that rather than trusting it: 0.245s / 0.250s / 0.272s at N=250/500/1000, r1=1.02
#     r2=1.09 on a quiet box (load 0.6); this gate's own min-of-5 runs read r2=1.05/1.06.
#     So the band is r2 1.05-1.09 — the cubic is gone, and this row stops it returning.
#     Read that with the prelude caveat: at N=1000 the ~0.215s wasm prelude constant is
#     79% of the reading, so it is a WEAK linearity claim but a STRONG not-cubic one,
#     which is exactly what #401 is about. Unlike `match:emit`, this row is gradeable at
#     the gate's existing match sizes (the constant carries it over the floor), so the
#     wasm cubic needs no new base-N knob to stay regressed.
#
#     ⚠️ 4.15x is a LOWER BOUND on the true exponent, not an estimate of it. Unlike
#     the front-end stages, `emit` pays a large FIXED prelude cost (core.mdk is
#     emitted on every run, ~0.03s/~13 MB) that the per-stage TIME arm does not
#     subtract, so the constant term DILUTES the measured ratio downward.
#
#   xref:wasm-emit — THE WASM PEER OF THE ROW ABOVE, AND A SEPARATE MEASUREMENT.
#
#     wasm_emit is quadratic in the top-level declaration count too, and it is NOT a
#     restatement of `xref:emit`: it is a different ~10k-line backend, measured
#     independently. Rooted `xref`, quiet box (load 0.5), heap pinned at 2 GB:
#
#         xref, wasm-emit stage       TIME              ALLOC (this stage's delta)
#           N=4000                    2.439s            519.2 MB
#           N=8000                    9.317s  (3.82x)   796.9 MB   (1.53x)
#           N=16000                  38.128s  (4.09x)  1352.9 MB   (1.70x)
#
#     ⚠️ STATE THE N BAND WITH THE RATIO — A SCALING RATIO IS NOT A CONSTANT. These are
#     r1/r2 at N=4000 -> 8000 -> 16000, the band this gate's XREF_N fixes. The ceiling
#     below is only meaningful against THAT band: the same curve sampled at a different
#     N reads a different number, and both readings are correct. (This is exactly how
#     the ws:emitter and ws:wasm workstreams reported 3.71/3.73 and 2.27/2.87 for one
#     curve and briefly appeared to disagree.)
#
#     OBSERVED r2 BAND, same N, FIVE batches: 3.87 / 3.88 / 3.92 / 4.09 / 4.15
#     (r1 3.60-3.82). 4.09 is the quiet-box (load 0.5, min-of-2) reading above; 3.88 and
#     3.87 are this gate's own min-of-5 runs (the 3.87 on the tree merged with #468,
#     which reworked wasm_emit — it did not move this row); 3.92/4.15 are min-of-1
#     falsification runs. Treat the BAND as the measurement, not any single batch — and
#     note the QUIETER box read HIGHER, so a busy CI runner biases this row toward
#     false-green, never toward false-red.
#
#     ALLOCATION IS BLIND HERE TOO, AND HARDER THAN IT IS FOR `emit`. Two ways to see
#     it, both from the run above:
#       * this stage's OWN alloc delta reads 1.53x / 1.70x — not merely "linear (ok)"
#         but SUBLINEAR, because the ~240 MB fixed wasm prelude dominates the numerator;
#       * the gate's WHOLE-RUN net alloc column — the only alloc signal it actually
#         grades — reads a flat 2.02x / 2.02x and prints `ok` for this very row.
#     So a gate reading only allocation would call a stage taking 38 SECONDS to emit
#     16000 functions its healthiest row on the board. That is the #110/#115 thesis on a
#     second backend: these are PURE SCANS, and only the TIME arm can see them.
#
#     Mechanism note: this tracks `xref:emit` closely (3.97/4.08 in the same batch), so
#     the likely shared cause is `ctorOrdinal`/#352-class whole-table scans over
#     accumulated per-decl state, which both backends inherit. It is ~3.7x SLOWER in
#     absolute terms than llvm_emit on identical input. Fix the shared scans and BOTH
#     entries PROMOTE OUT — independently, which is the point of ledgering them apart.
#
#     ⚠️ 4.09x is a LOWER BOUND on the true exponent (the ~0.215s prelude constant is
#     not subtracted), and it is a WEAKER bound than `emit`'s: wasm's constant is ~10x
#     llvm's, so it dilutes harder.
#
# manydefs:lint (TIME) — the per-file lint tier is mildly SUPERLINEAR in TIME on the
# `manydefs` shape (DEEP-only; QUICK skips manydefs, so this entry is inert per-PR).
# Measured on a QUIET box (min-of-5, GC heap pinned, load ~1.5) at N=4000->8000->16000:
# r1=2.82 r2=3.37 — r2 comfortably over the 3.0 threshold and strengthening (an
# under-LOAD DEEP run read 3.04/3.31, the same signal). It is REAL, not a flap: TIME is
# the only arm that sees it (lint's alloc dilutes to ~2.0; the `manydefs:typecheck` OP
# quadratic that used to be its SEPARATE op-arm sibling was fixed by #907). Pre-existing —
# unrelated to #883's shapes. Ledgered self-drainingly: ceiling 4.3
# clears the observed r2=3.37 by ~28% (op counts... n/a here, TIME, so this absorbs
# runner noise too — hence the wider margin), TFIXED 2.60 (file convention). Tracked in
# #956 (the TIME-arm fragility issue); self-drains when the lint cost is made linear.
# One entry per line so draining a single row is a conflict-free one-line deletion
# (see #880 follow-up; the vars are word-split by `for k in $VAR`, newlines are IFS).
KNOWN_SLOW_TIME="
manydefs:lint
"
KNOWN_TCEIL_match_typecheck="4.6";    KNOWN_TFIXED_match_typecheck="2.60"
KNOWN_TCEIL_listlit_typecheck="4.8";  KNOWN_TFIXED_listlit_typecheck="2.60"
# manydefs:lint (TIME) — see the block above KNOWN_SLOW_TIME. Ceiling 4.3 clears the
# quiet-box r2=3.37 by ~28% (TIME is noisy, so the margin is wider than an op-arm ceiling);
# TFIXED 2.60 (file convention) sits well under the observed band so a quiet runner cannot
# false-PROMOTE it. Promotes out (#956) when the lint per-file cost is made linear.
KNOWN_TCEIL_manydefs_lint="4.3";      KNOWN_TFIXED_manydefs_lint="2.60"
# ⚠️ THIS ROW IS MEASURED AT TWO DIFFERENT BANDS depending on PERF_DEEP, and the entry
# below has to hold for BOTH:
#     DEEP  (nightly)  xref @ 4000->8000->16000   observed r2 3.85-4.15  (r1 3.57-3.82)
#     QUICK (per-PR)   xref @ 2000->4000->8000    observed r2 3.64       (r1 3.05), min-of-5
# They are not in tension: QUICK's r2 IS DEEP's r1 — the same 4000->8000 doubling of the
# same curve — which is why one ceiling covers both, and is also the cross-check that the
# quick band resamples the curve rather than losing it. It holds on the numbers: QUICK's
# r2=3.64 against DEEP's r1=3.57 (same tree, same day). (Same relation as xref:wasm-emit;
# see its note.) Ceiling 5.6 clears DEEP's top (4.15) by 1.45 and QUICK's (3.64) by 1.54;
# TFIXED 2.60 sits 1.40 under QUICK's r2. If you re-derive either number, state WHICH
# BAND you measured — a bare ratio here is unfalsifiable.
#
# Observed r2 3.85-4.15 across four DCE-realistic batches (incl. the merged tree with
# the `lint` stage present, which does not perturb emit). Ceiling 5.6 matches the
# modules:typecheck precedent, whose observed band (4.1-4.3) is the same one, rather
# than the tighter match/listlit ceilings set on a ~3.3 band; it clears the top of
# this band by 1.45, comparable to that precedent's 1.3. TFIXED 2.60 (the
# file-wide convention): drop under it and #349/#350/#352 are fixed and this entry
# must be promoted out.
KNOWN_TCEIL_xref_emit="5.6";          KNOWN_TFIXED_xref_emit="2.60"

is_known_time() {
  for k in $KNOWN_SLOW_TIME; do [ "$k" = "$1" ] && return 0; done
  return 1
}

# ── OP-COUNT grading, PER STAGE (issue #884) ─────────────────────────────────
#
# The deterministic third arm. It grades the SAME per-stage ratio idea as TIME, but
# on the noise-free op counter, so it needs none of TIME's four crutches (min-of-K,
# heap pin, 200ms floor, larger N). Its unique coverage is the SMALL front-end stages
# whose absolute time never clears the 200ms floor on ANY shape — `mark` above all —
# so TIME grades NOTHING there while OP grades them from a single run.
#
# `desugar`/`exhaust-guards` are in the list for completeness: they currently do ZERO
# counted ops (they call neither util.contains nor util.lookupAssoc), so they always
# self-skip below OP_FLOOR — but the plumbing is here the day either starts scanning.
OP_STAGES="desugar resolve mark typecheck exhaust-guards elaborate dce mangle"

# TOOSMALL guard (mirrors the alloc arm's d1<1.0, NOT TIME's noise floor — op counts
# are deterministic, so this is an ABSOLUTE-count guard, not a noise guard). A stage
# whose smallest-N op delta is under this is doing too little counted work to yield a
# meaningful ratio (desugar/exhaust-guards = 0; a constant handful like marksweep's
# resolve = 64). Grades everything above it.
OP_FLOOR="${PERF_OP_FLOOR:-1000}"

# ── KNOWN SLOW (OPS) — a ledger, NOT a skip-list ─────────────────────────────
#
# Same self-draining contract as KNOWN_SLOW_TIME / KNOWN_SUPERLINEAR: each entry
# records a REAL, currently-superlinear per-stage OP ratio, so the gate is green now
# yet (a) FAILS if the ratio worsens past its ceiling and (b) FAILS demanding
# promotion the instant a fix drops it back to linear. Because op counts are
# DETERMINISTIC, these ratios are exact and reproducible — the ceilings carry only the
# modest headroom needed to absorb drift from unrelated compiler-source changes, not
# runner noise.
#
# ⚠️ #884's design proposed shipping this EMPTY. That premise did not survive first
# contact: the moment the op arm graded resolve+typecheck across the existing shapes
# it surfaced two real superlinear op-signals that the current TIME and ALLOC arms do
# NOT grade — which is precisely the coverage this metric was built to add. They are
# ledgered (not shipped red) because they are pre-existing and out of #884's wiring
# scope; each is a candidate follow-up for the #880 epic.
#
# CURRENT ENTRIES (measured on this box, deterministic single run):
#
#   match:resolve — resolve is O(N^2) in the CONSTRUCTOR count on the `match` shape (a
#         data decl with N ctors + an N-arm match). Its per-ctor membership scan
#         (util.contains / util.lookupAssoc over a table that grows with the ctor
#         universe) is walked once per ctor reference. TIME never grades resolve on
#         `match` (that shape's N is sized for typecheck, and resolve sits far under
#         the floor), and allocation is blind to a pure scan — so ONLY the op arm sees
#         it. MEASURED N=250/500/1000: 35644 -> 133769 -> 517519, r1=3.75 r2=3.87
#         (climbing toward the pure-quadratic 4.0).
#
#   xref:typecheck — FIXED (#907). Was typecheck's O(decls^2) assoc-list bookkeeping: the
#         binding-id stamp (stampBindingIds/lookupBindId, run in typecheck's checkBodyImpl)
#         scanned the O(decls) top-level frame once per EVar. Now an OrdMap (op r1/r2 ~1.95
#         at N=2000/4000/8000; TIME also promoted linear, r2=2.11). De-ledgered on both arms.
#
# NOT LEDGERED, but WATCH: `comments:typecheck` reads r1=2.62 r2=3.00 at N=1000/2000/4000
# — genuinely climbing, but r1 is under the 3.0 threshold so the sustained-both-doublings
# rule (below) correctly calls it "ok". It is deterministic, so it will not flap on this
# compiler; a future source change that pushes r1 over 3.0 will (correctly) fail and force
# a ledger decision then. Left un-ledgered on purpose: a ledger entry asserts a stage is
# ALREADY over-threshold, and this one is not.
#
#   reexports:resolve — MULTI-MODULE RESOLVE (issue #881), the whole point of adding a
#         `resolve` stage to profile_modules_main and the two multi-module shapes below.
#         Production's resolveModulesErrorsG threads `known` and, on an N-deep
#         `export import m.*` re-export chain, buildExports/isPubExp re-check an export
#         set that GROWS with depth at a growing number of sites — so the counted
#         (util.contains) op work is ~CUBIC. This was UNMEASURED until #881: the
#         multi-module driver ran load->desugar->mark->typecheck and DISCARDED resolve
#         entirely, so a whole production pass with a known-superlinear shape was off the
#         CI map. It is ledgered (not shipped red) because it is a PRE-EXISTING cost out
#         of #881's wiring scope — a candidate follow-up for the #880 epic. The fixture
#         resolves 0-DIAGNOSTIC (proven with `medaka check`; see gen_reexports). MEASURED
#         (this box, deterministic single run, N=50/100/200): 65025 -> 510050 -> 4040100,
#         r1=7.84 r2=7.92 (stable ~7.9 to N=400 — a clean 2^3 cubic, not a step). Net
#         alloc and resolve TIME are separately ~QUADRATIC (~4x) on this shape; op-count
#         is the arm graded (deterministic, one run, no floor). Promotes out the moment a
#         fix drops the op-ratio under OFIXED (linear). See the resolve-shapes block.
#         (The STAR dual, `starimports`, reads LINEAR on every arm — its findExports
#         quadratic is uncounted AND dwarfed by linear buildEnvMM alloc — so it is a
#         regression guard, NOT ledgered; see gen_starimports.)
#
#   xref:elaborate — FIXED (#907). The elaborate stage runs elaborateDict, which re-checks
#         the program via checkProgramSeeded -> checkBodyImpl -> stampBindingIds — so it hit
#         the SAME O(decls^2) binding-id-stamp quadratic as xref:typecheck (the earlier
#         "elaborateDict reference-walking dict-routing" attribution was wrong; the cost was
#         stampBindingIds). Indexing the top frame drained it: op r1/r2 ~1.9 at both the
#         QUICK (2000/4000/8000) and DEEP (4000/8000/16000) bands. De-ledgered.
#   manyifaces:mark — THE HEADLINE #883 FIND. mark's `contains x methods`
#         (marker.mdk markVar/markInfix — a List-as-set walked for EVERY var/op node,
#         `methods` = every interface-method name) is O(sites x pool). No shape stressed
#         it: `marksweep` (#884) grows only the pool with FIXED sites, so it reads LINEAR
#         on purpose; `modules` has ONE interface with ONE method. `manyifaces` co-scales
#         N interfaces AND N reference sites (§5's "co-scale the two multiplying
#         dimensions" rule), so the scan reads O(N^2). MEASURED (this box, deterministic
#         single run, R=8, N=250/500/1000): 818999 -> 2512749 -> 8900249, r1=3.07 r2=3.54.
#         TIME never grades mark (it is ~40-200 ms here, under the 200ms floor on EVERY
#         shape) and allocation is blind to a pure scan — so ONLY the op arm sees it.
#         Ledgered (not shipped red) because it is a PRE-EXISTING, currently-unfixed
#         quadratic surfaced by #883's shape, out of scope for the gate-only wiring — a
#         candidate #880 follow-up, filed as #953. Op-count is the arm graded (one run,
#         no floor); it self-drains — promote it out the moment `methods` becomes a set
#         (OrdSet) and the op-ratio drops under OFIXED (linear).
#
#   manyifaces:resolve — A SECOND, INDEPENDENT quadratic the same shape surfaces, and a
#         DIFFERENT mechanism from match:resolve (which is O(ctors^2)). Here resolve is
#         O(interfaces^2) INDEPENDENT of the reference-site count R (the op-count is
#         identical at R=4 and R=8) — the cost is interface-method registration /
#         duplicate-checking scanning the growing ifaceMethods/interfaces lists once per
#         interface (resolve.mdk; localize precisely — filed as #954). It is
#         invisible to TIME (resolve ~8-40 ms here, under the floor) and to allocation.
#         MEASURED N=250/500/1000: 37126 -> 136751 -> 523501, r1=3.68 r2=3.83 (climbing
#         toward the pure-quadratic 4.0). Ledgered self-drainingly; promotes out when the
#         interface-method scan is indexed. (typecheck r1=2.65 r2=3.09 and elaborate
#         r1=2.52 r2=2.99 also climb on this shape — the #907/#882 decl-count classes —
#         but stay r1<3 at this band, so the sustained-both-doublings rule reads them `ok`
#         and they are NOT ledgered; WATCH, per the comments:typecheck note.)
# One entry per line so draining a single row is a conflict-free one-line deletion
# (see #880 follow-up; the var is word-split by `for k in $VAR`, newlines are IFS).
KNOWN_SLOW_OPS="
reexports:resolve
manyifaces:typecheck
"
# manyifaces:typecheck — an O(interfaces^2) interface-registration quadratic in the typecheck
# stage (the interface-method scheme/constraint registration scanning the growing interface
# list once per interface — the #954 class, the typecheck-stage sibling of resolve's findDups
# which #969 fixed). It was ALREADY quadratic on main but DILUTED under the sustained-both-
# doublings rule (r1=2.65 r2=3.09, read `ok`) by the #907 stampBindingIds op-quadratic that
# ran in typecheck's checkBodyImpl. Fixing #907 removed that masking term — the absolute op
# count DROPPED while the underlying interface quadratic's true ratio surfaced (r1=3.27
# r2=3.60), exactly the "future source change lifting r1 over 3 forces a ledger decision" the
# gen_manyifaces note predicted. Ledgered here (not a regression: op count fell): ceiling 4.3
# clears the observed r2=3.60 by ~19% (the file's headroom convention); OFIXED 2.60 — drops
# under it when the typecheck-side interface-method scan is indexed.
KNOWN_OCEIL_manyifaces_typecheck="4.3"; KNOWN_OFIXED_manyifaces_typecheck="2.60"
# Ceiling 8.9 clears the observed r2 (7.92) by ~12%, the same headroom convention as the
# entries above (4.2 over 3.8); op counts are deterministic so this absorbs only drift
# from unrelated compiler-source changes, not runner noise. OFIXED 2.60 (file convention):
# drop under it and the re-export resolve quadratic is fixed and this entry must be promoted.
KNOWN_OCEIL_reexports_resolve="8.9";  KNOWN_OFIXED_reexports_resolve="2.60"

is_known_ops() {
  for k in $KNOWN_SLOW_OPS; do [ "$k" = "$1" ] && return 0; done
  return 1
}

fail=0
known=0
pass=0

# How many stage OP-ratios were actually graded. Mirrors backend_graded: "green" must
# never mean "graded nothing". If every OP_STAGES reading fell under OP_FLOOR (e.g. the
# profiler stopped emitting the 5th column, so every field-5 read was empty→0) this
# would be 0 and the arm would be silently dead. Asserted non-zero at the bottom.
ops_graded=0

# How many times a NATIVE backend stage (lower/emit) actually produced a graded ratio.
# "Green" must never mean "did not run": if these two always SKIP under the TIME_FLOOR
# the gate silently reverts to issue #359's blind spot — grading no backend stage at
# all — while still exiting 0. Asserted non-zero at the bottom of this file.
#
# ⚠️ `wasm-emit` IS DELIBERATELY NOT COUNTED HERE, and the reason is the whole point of
# the counter. Its ~0.215-0.25 s prelude constant clears the 0.2 s floor on most shapes
# (4-5 of 7, load-dependent) — including the dead-`main` ones where DCE has pruned
# everything and it is timing the prelude alone. Counting it would peg this counter at
# 5-6 on every run: it would never be zero again, so it could never fail, and the llvm
# arm's floor-skip regression (the ONLY thing it detects) would sail through behind wasm
# rows that measured nothing but the prelude. A guard that cannot fail is not a guard.
# (Measured: with wasm-emit excluded this counter still reads 1, the same as before this
# stage existed — so the llvm guard is provably undiluted.)
#
# The wasm arm does not need this counter, because it is guarded twice over and more
# tightly:
#   * a stage in TIME_STAGES that the profiler stops emitting at all is already a hard
#     FAIL ("NO MEASUREMENT from the profiler") in the loop below — that covers deletion;
#   * `xref:wasm-emit` is LEDGERED in KNOWN_SLOW_TIME, and a ledgered stage MAY NOT SKIP:
#     dropping under the floor fires PROMOTE and FAILS. So the one row that carries the
#     wasm arm's real coverage is provably graded on every green run, or the gate is red.
backend_graded=0

# Grade ONE stage's three timings. Args: shape st s1 s2 s3 n1 n2 n3.
#
# Extracted from the shape loop so the WASM row can be graded on a DIFFERENT N BAND
# from the rest of its shape (see grade_wasm_row). That is the whole reason this is a
# function: the band is an argument, not the ambient $n1/$n2/$n3, because
# `xref:wasm-emit` is measured at 2000/4000/8000 while `xref:resolve` needs
# 4000/8000/16000.
#
# ⚠️ THE BAND IS PRINTED WITH EVERY RATIO, and that is not decoration. The ledger's
# ceilings are calibrated per-band ("a scaling ratio is not a constant"), and two
# workstreams once appeared to disagree about one curve purely because each quoted a
# ratio without its band. A row that states
# r2=3.82 and not the N it came from is unfalsifiable.
#
# Mutates the caller's fail/known/backend_graded/time_bad/time_lines. Must be called
# directly, NEVER in a subshell or a pipe — the counters would vanish and every verdict
# would silently read zero.
grade_time_stage() {
  shape="$1"; st="$2"; s1="$3"; s2="$4"; s3="$5"; gn1="$6"; gn2="$7"; gn3="$8"
  band="N=${gn1}->${gn2}->${gn3}"

  # A stage the profiler never emitted is a HARNESS bug, not a pass.
  if [ -z "$s1" ] || [ -z "$s2" ] || [ -z "$s3" ]; then
    time_lines="${time_lines}           time ${st}: NO MEASUREMENT from the profiler (harness bug)
"
    fail=$((fail+1))
    return
  fi

  # RULE 4 — the per-stage floor. Under it, the ratio is noise: SKIP, loudly.
  #
  # ⚠️ BUT A LEDGERED STAGE MAY NOT SKIP. Dropping below the floor is not an
  # absence of signal for a KNOWN_SLOW_TIME entry — it IS the signal: the stage
  # got so fast it is no longer measurable, which is exactly what "fixed" looks
  # like. Skipping here would let a stale ledger entry rot behind a green gate,
  # and "a ledger that cannot notice the bug is fixed" is a skip-list — the very
  # thing this ratchet exists to not be. (Caught for real: #115's fix took
  # `match:typecheck` from 6.0 s to 75 ms, under the floor, and the first cut of
  # this gate reported "0 known-superlinear, 0 regressed" and exited 0.)
  below="$(awk -v v="$s3" -v f="$TIME_FLOOR" 'BEGIN{print (v + 0 < f + 0) ? 1 : 0}')"
  if [ "$below" = "1" ]; then
    ms3="$(awk -v v="$s3" 'BEGIN{printf "%.0f", v*1000}')"
    msf="$(awk -v f="$TIME_FLOOR" 'BEGIN{printf "%.0f", f*1000}')"
    if is_known_time "${shape}:${st}"; then
      fail=$((fail+1))
      time_lines="${time_lines}           time ${st}: ** PROMOTE: now too FAST to time-gate ** ${ms3} ms at N=${gn3} < ${msf} ms floor
           Remove \"${shape}:${st}\" from KNOWN_SLOW_TIME — the bug is FIXED.
"
      return
    fi
    time_lines="${time_lines}           time ${st}: SKIP — too small to time-gate: ${ms3} ms at N=${gn3} < ${msf} ms floor
"
    return
  fi

  # Past the floor: this stage gets a real ratio. Record that the backend arm ran.
  case "$st" in lower|emit) backend_graded=$((backend_graded+1)) ;; esac

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
      time_lines="${time_lines}           time ${st}: ** KNOWN-SLOW, AND GOT WORSE ** r1=${tr1} r2=${tr2} (ceiling ${tceil}, ${band})
"
    elif [ "$tbetter" = "1" ]; then
      fail=$((fail+1))
      time_lines="${time_lines}           time ${st}: ** PROMOTE: now scales LINEARLY ** r2=${tr2} (< ${tfixed}, ${band})
           Remove \"${shape}:${st}\" from KNOWN_SLOW_TIME — the bug is FIXED.
"
    else
      known=$((known+1))
      time_lines="${time_lines}           time ${st}: known-slow (TIME) r1=${tr1} r2=${tr2} ${band} — ledgered, alloc is blind to it
"
    fi
  elif [ "$bad" = "1" ]; then
    time_bad=1
    time_lines="${time_lines}           time ${st}: ** SUPERLINEAR (TIME) ** ${s1}s -> ${s2}s -> ${s3}s  r1=${tr1} r2=${tr2} (> ${THRESH}x, ${band})
"
  else
    time_lines="${time_lines}           time ${st}: ok  r1=${tr1} r2=${tr2} ${band} (min-of-${PERF_K}, heap pinned)
"
  fi
}

# Grade ONE stage's three OP-COUNT deltas (issue #884). Args: shape st o1 o2 o3 n1 n2 n3.
#
# Structurally MIRRORS grade_time_stage, with two deliberate differences that follow
# from the counter being deterministic:
#   * NO min-of-K / heap-pin — the caller passes a single run's numbers.
#   * NO 200ms noise floor — replaced by an ABSOLUTE-count TOOSMALL guard (OP_FLOOR),
#     the op analogue of the alloc arm's d1<1.0. A stage under it is doing too little
#     counted work to grade (not "too noisy to grade").
#
# Grades on the SAME sustained signal as TIME: both doublings over threshold. Sets the
# caller's fail/known/ops_graded/op_bad/op_lines. Must be called DIRECTLY, never in a
# subshell/pipe, or the counters vanish (same rule as grade_time_stage).
grade_op_stage() {
  shape="$1"; st="$2"; o1="$3"; o2="$4"; o3="$5"; gn1="$6"; gn2="$7"; gn3="$8"
  band="N=${gn1}->${gn2}->${gn3}"

  # A stage the profiler never emitted a 5th column for is a HARNESS bug, not a pass.
  if [ -z "$o1" ] || [ -z "$o2" ] || [ -z "$o3" ]; then
    op_lines="${op_lines}           ops  ${st}: NO MEASUREMENT from the profiler (harness bug — missing op column)
"
    fail=$((fail+1))
    return
  fi

  # TOOSMALL — too few counted ops to grade (deterministic, so this is about the WORK
  # being negligible, not the reading being noisy). desugar/exhaust-guards do zero;
  # a constant handful (marksweep's resolve = 64) also lands here.
  small="$(awk -v v="$o1" -v f="$OP_FLOOR" 'BEGIN{print (v + 0 < f + 0) ? 1 : 0}')"
  if [ "$small" = "1" ]; then
    op_lines="${op_lines}           ops  ${st}: SKIP — too few ops to grade: ${o3} at N=${gn3} (< ${OP_FLOOR})
"
    return
  fi

  # A stage past the floor is genuinely graded. Record it (green must not mean "graded
  # nothing" — see ops_graded).
  ops_graded=$((ops_graded+1))

  or1="$(awk -v a="$o1" -v b="$o2" 'BEGIN{printf "%.2f", b/a}')"
  or2="$(awk -v a="$o2" -v b="$o3" 'BEGIN{printf "%.2f", b/a}')"
  bad="$(awk -v r1="$or1" -v r2="$or2" -v th="$THRESH" 'BEGIN{print (r1 > th && r2 > th) ? 1 : 0}')"

  if is_known_ops "${shape}:${st}"; then
    lk="$(printf '%s_%s' "$shape" "$st" | tr -c 'a-zA-Z0-9_' '_')"
    eval "oceil=\${KNOWN_OCEIL_$lk}"
    eval "ofixed=\${KNOWN_OFIXED_$lk}"
    oworse="$(awk -v r="$or2" -v c="$oceil" 'BEGIN{print (r > c) ? 1 : 0}')"
    obetter="$(awk -v r="$or2" -v f="$ofixed" 'BEGIN{print (r < f) ? 1 : 0}')"
    if [ "$oworse" = "1" ]; then
      fail=$((fail+1))
      op_lines="${op_lines}           ops  ${st}: ** KNOWN-SLOW (OPS), AND GOT WORSE ** r1=${or1} r2=${or2} (ceiling ${oceil}, ${band})
"
    elif [ "$obetter" = "1" ]; then
      fail=$((fail+1))
      op_lines="${op_lines}           ops  ${st}: ** PROMOTE: now scales LINEARLY ** r2=${or2} (< ${ofixed}, ${band})
           Remove \"${shape}:${st}\" from KNOWN_SLOW_OPS — the op quadratic is FIXED.
"
    else
      known=$((known+1))
      op_lines="${op_lines}           ops  ${st}: known-slow (OPS) r1=${or1} r2=${or2} ${band} — ledgered; TIME+ALLOC are blind to it
"
    fi
  elif [ "$bad" = "1" ]; then
    op_bad=1
    op_lines="${op_lines}           ops  ${st}: ** SUPERLINEAR (OPS) ** ${o1} -> ${o2} -> ${o3}  r1=${or1} r2=${or2} (> ${THRESH}x, ${band})
"
  else
    op_lines="${op_lines}           ops  ${st}: ok  r1=${or1} r2=${or2} ${band} (deterministic, single run — no floor/min-of-K/heap-pin)
"
  fi
}

# Grade the `wasm-emit` row for the shapes where it MEANS something, and only those.
# Args: shape n1 n2 n3 (the shape's own band, for the shapes that ride the main pass).
#
# ⚠️ WHICH SHAPES, AND WHY IT IS NOT "ALL OF THEM": wasm_emit renders the whole live
# prelude to WAT at ~0.24 s / ~242 MB no matter how small the target. On the dead-`main`
# shapes (bindings/listlit/nesting/comments/manydefs) DCE prunes every synthetic decl, so
# the stage times THE PRELUDE AND NOTHING ELSE and prints a flat `ok r1≈1.0 r2≈1.0` —
# measured 1.09/1.01, 0.98/1.17, 1.01/0.96. THAT "ok" IS NOT BACKEND COVERAGE; it is a
# constant being constant, and it cost 27% of every run's wall and 38% of its allocation
# to learn nothing. Those shapes now never run the stage at all (MEDAKA_PERF_WASM unset).
#
# The two that carry real signal:
#   match — the #381 CUBIC's exact shape (ctor-switch emission). #401 fixed it 53x; this
#           row reading r2≈1.05-1.09 is what keeps the fix fixed. Rides the main pass:
#           its band IS the shape's band, and at N<=1000 the stage is ~0.3 s.
#   xref  — the ledgered quadratic, on its OWN SMALLER BAND. See below.
grade_wasm_row() {
  shape="$1"; n1="$2"; n2="$3"; n3="$4"
  case "$shape" in
    match)
      # Rode the main pass (main_wasm=1), so the rows are already in TF1/TF2/TF3.
      grade_time_stage "$shape" wasm-emit \
        "$(awk '$1=="wasm-emit"{print $2}' "$TF1")" \
        "$(awk '$1=="wasm-emit"{print $2}' "$TF2")" \
        "$(awk '$1=="wasm-emit"{print $2}' "$TF3")" \
        "$n1" "$n2" "$n3"
      ;;
    xref)
      # QUICK: the shape's band already IS the wasm band, so the row rode the main pass
      # (main_wasm=1) and there is nothing extra to run. This is why QUICK is cheap: the
      # dedicated pass below exists only to spare DEEP the N=16000 wasm sample.
      if [ "$XREF_N" = "$XREF_WASM_N" ]; then
        grade_time_stage "$shape" wasm-emit \
          "$(awk '$1=="wasm-emit"{print $2}' "$TF1")" \
          "$(awk '$1=="wasm-emit"{print $2}' "$TF2")" \
          "$(awk '$1=="wasm-emit"{print $2}' "$TF3")" \
          "$n1" "$n2" "$n3"
        return
      fi
      # DEEP: A DEDICATED PASS AT A SMALLER BAND — the single biggest cost lever here.
      #
      # xref's band is sized for `resolve`, which only clears the 200ms floor at
      # N=16000. wasm_emit is ~10x llvm_emit, so riding that band cost 42 s per run x
      # K=5 = ~211 s for ONE row, and made `gates (types)` the CI critical path at 12
      # min against engines' 3.7. At 2000/4000/8000 the same curve reads ~1.0/2.8/10.4 s
      # — the largest still 50x the floor — for ~14 s per round instead of ~55 s.
      #
      # ⚠️ THE LEDGER'S CEILING BELONGS TO THIS BAND. r2 here is the OLD band's r1 (both
      # are the 4000->8000 doubling), which is why the recorded band moved 3.87-4.15 ->
      # ~3.7-3.8 rather than collapsing: it is the same curve, resampled. Re-derive
      # KNOWN_TCEIL/TFIXED_xref_wasm_emit against THIS band if you move XREF_WASM_N, and
      # do not compare a number from here to one from the old band.
      wn1="$XREF_WASM_N"; wn2=$((wn1 * 2)); wn3=$((wn1 * 4))
      wf1="$WORK/${shape}_$wn1.mdk"; wf2="$WORK/${shape}_$wn2.mdk"; wf3="$WORK/${shape}_$wn3.mdk"
      # 4000/8000 already exist from the main pass (same generator, same deterministic
      # name); only the 2000 fixture is new. Regenerating is harmless, just wasted.
      [ -f "$wf1" ] || "gen_$shape" "$wn1" "$wf1"
      [ -f "$wf2" ] || "gen_$shape" "$wn2" "$wf2"
      [ -f "$wf3" ] || "gen_$shape" "$wn3" "$wf3"
      WW1="$WORK/${shape}_w1"; WW2="$WORK/${shape}_w2"; WW3="$WORK/${shape}_w3"
      stage_times_min "$wf1" "$PERF_K" 1 | sort > "$WW1"
      stage_times_min "$wf2" "$PERF_K" 1 | sort > "$WW2"
      stage_times_min "$wf3" "$PERF_K" 1 | sort > "$WW3"
      grade_time_stage "$shape" wasm-emit \
        "$(awk '$1=="wasm-emit"{print $2}' "$WW1")" \
        "$(awk '$1=="wasm-emit"{print $2}' "$WW2")" \
        "$(awk '$1=="wasm-emit"{print $2}' "$WW3")" \
        "$wn1" "$wn2" "$wn3"
      ;;
  esac
}

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
# `manydefs` is DEEP-only: its band exists solely to lift `lint` over the floor (0.62 s
# at 16000), and nothing else in the shape needs 16000. QUICK announces the omission
# rather than quietly running a smaller set — a gate that narrows its own scope in
# silence reads as full coverage, which is the failure this suite is built against.
# `marksweep` (issue #884) is the op arm's money-shot: it grades `mark`, which every
# other shape leaves under the 200ms TIME_FLOOR so the TIME arm never grades it. It runs
# at the default N and is OP-ONLY — its TIME min-of-K arm is skipped (it exists FOR the
# op arm, and `mark` is under the floor on every shape anyway), so per-PR it costs only
# the 3 shared deterministic runs. That every other shape's rows show `time mark: SKIP`
# is the standing proof that TIME grades `mark` nowhere.
# `manyifaces` / `widerecords` (issue #883) are OP-ONLY single-file shapes, run at the
# default N band. `manyifaces` co-scales N interfaces AND N reference sites to catch
# mark's `contains x methods` List-as-set quadratic (ledgered manyifaces:mark, and the
# independent manyifaces:resolve it surfaces); `widerecords` is the record shape — a
# LINEAR op regression guard (its ownersOf target is uncounted; see gen_widerecords).
SHAPES="bindings match listlit nesting xref comments marksweep manyifaces widerecords"
if [ "$PERF_DEEP" = "1" ]; then
  SHAPES="$SHAPES manydefs"
else
  echo "NOTE: QUICK mode (PERF_DEEP=0). Reduced scope, on purpose:"
  echo "  * manydefs SKIPPED entirely — the per-file lint tier's O(defs^2) detector."
  echo "  * xref at N=${XREF_N} (-> $((XREF_N * 4))) instead of 4000 (-> 16000):"
  echo "      emit + wasm-emit still graded and ledgered (both >> the floor at 4N);"
  echo "      resolve drops under the 200ms floor and SKIPs — the #78 detector."
  echo "  These run in nightly.yml. Locally: PERF_DEEP=1 sh test/diff_compiler_perf_scaling.sh"
fi

for shape in $SHAPES; do
  case "$shape" in
    xref)       base_n="$XREF_N" ;;
    comments)   base_n="$COMMENTS_N" ;;
    manydefs)   base_n="$MANYDEFS_N" ;;
    manyifaces) base_n="$MANYIFACES_N" ;;
    widerecords) base_n="$WIDERECORDS_N" ;;
    *)          base_n="$N" ;;
  esac
  n1="$base_n"; n2=$((base_n * 2)); n3=$((base_n * 4))
  f1="$WORK/${shape}_$n1.mdk"; f2="$WORK/${shape}_$n2.mdk"; f3="$WORK/${shape}_$n3.mdk"
  "gen_$shape" "$n1" "$f1"
  "gen_$shape" "$n2" "$f2"
  "gen_$shape" "$n3" "$f3"

  # ONE deterministic wasm-off run per size, saved whole — it feeds BOTH the alloc arm
  # (total line) and the op arm (per-stage 5th column). The op arm makes NO run of its
  # own (issue #884 cost fix); the command is identical to alloc_of's, so the alloc
  # numbers below are byte-unchanged by the sharing.
  R1="$WORK/${shape}_run1"; R2="$WORK/${shape}_run2"; R3="$WORK/${shape}_run3"
  profile_run "$f1" > "$R1"; profile_run "$f2" > "$R2"; profile_run "$f3" > "$R3"
  a1="$(alloc_from "$R1")"; a2="$(alloc_from "$R2")"; a3="$(alloc_from "$R3")"

  # A shape that produces no measurement is a HARNESS failure, not a pass. Never
  # let "I could not measure it" read as "it is fine" — that is the silent-green
  # bug class this whole suite was hardened against.
  case "$a1$a2$a3" in
    *[!0-9.]*|"") echo "FAIL $shape: profiler produced no allocation figure (harness bug)"; fail=$((fail+1)); continue ;;
  esac

  # ── TIME verdict: PER STAGE, heap-pinned, min-of-K, floor-guarded ──────────
  # Computed BEFORE the allocation branch below so it can promote an allocation
  # "ok" to a failure — never the reverse.
  time_bad=0
  time_lines=""
  # ⚠️ OP-ONLY shapes skip the TIME min-of-K arm (issue #884 cost fix). `marksweep`
  # (#884) and `manyifaces`/`widerecords` (#883) all grade a stage — `mark`/`resolve` —
  # that sits UNDER the 200ms floor at their bands, so the TIME arm would grade nothing
  # while paying ~K timing runs per size. Their op grading rides the 3 shared
  # deterministic runs above, so each costs 3 runs, not 3 + 3*K. Every OTHER shape still
  # runs the full TIME arm.
  case "$shape" in
    marksweep|manyifaces|widerecords)
    time_lines="           time: (OP-ONLY shape — TIME min-of-K arm skipped, #883/#884 cost fix. its graded stage is under the ${TIME_FLOOR}s floor at this band, so TIME grades it nowhere; the op arm below is its coverage.)
"
    ;;
    *)
    # These are written to files rather than shell vars because there is one line
    # per stage per size and sh has no arrays.
    TF1="$WORK/${shape}_t1"; TF2="$WORK/${shape}_t2"; TF3="$WORK/${shape}_t3"
    # `match` is the ONLY shape whose wasm row rides the main pass — its band is the
    # shape's band and the stage is ~0.3 s there. Every other shape runs the main pass
    # with wasm OFF: xref grades it on its own smaller band (grade_wasm_row), and the
    # rest do not grade it at all because on them it only ever times the prelude.
    # A shape's wasm row rides the main pass when its own band IS the wasm band —
    # `match` always (250/500/1000), and `xref` in QUICK, where XREF_N == XREF_WASM_N.
    # In DEEP, xref's band is resolve's, so its wasm row needs the separate smaller-band
    # pass instead (grade_wasm_row).
    case "$shape" in
      match) main_wasm=1 ;;
      xref)  [ "$XREF_N" = "$XREF_WASM_N" ] && main_wasm=1 || main_wasm=0 ;;
      *)     main_wasm=0 ;;
    esac
    stage_times_min "$f1" "$PERF_K" "$main_wasm" | sort > "$TF1"
    stage_times_min "$f2" "$PERF_K" "$main_wasm" | sort > "$TF2"
    stage_times_min "$f3" "$PERF_K" "$main_wasm" | sort > "$TF3"
    for st in $TIME_STAGES; do
      grade_time_stage "$shape" "$st" \
        "$(awk -v s="$st" '$1==s{print $2}' "$TF1")" \
        "$(awk -v s="$st" '$1==s{print $2}' "$TF2")" \
        "$(awk -v s="$st" '$1==s{print $2}' "$TF3")" \
        "$n1" "$n2" "$n3"
    done
    grade_wasm_row "$shape" "$n1" "$n2" "$n3"
    ;;
  esac

  # ── OP verdict: PER STAGE, deterministic — reads the op column of the shared runs
  # (issue #884). No min-of-K, no heap pin, no floor (the op counter is noise-free).
  # Computed alongside TIME so it, too, can only PROMOTE an allocation "ok" to a
  # failure, never downgrade one (the SUPERLINEAR (OPS) branch below sits after the
  # alloc and time failures).
  OF1="$WORK/${shape}_op1"; OF2="$WORK/${shape}_op2"; OF3="$WORK/${shape}_op3"
  ops_from "$R1" | sort > "$OF1"
  ops_from "$R2" | sort > "$OF2"
  ops_from "$R3" | sort > "$OF3"
  op_bad=0
  op_lines=""
  for st in $OP_STAGES; do
    grade_op_stage "$shape" "$st" \
      "$(awk -v s="$st" '$1==s{print $2}' "$OF1")" \
      "$(awk -v s="$st" '$1==s{print $2}' "$OF2")" \
      "$(awk -v s="$st" '$1==s{print $2}' "$OF3")" \
      "$n1" "$n2" "$n3"
  done

  # ── widerecords silent-green guard (#883 PR review) ──────────────────────────
  # widerecords is a `resolve` op regression-guard, and that reading is the ONLY thing
  # it grades (its ownersOf target is uncounted — see gen_widerecords). But
  # grade_op_stage treats a below-OP_FLOOR reading as a plain SKIP: it appends to
  # op_lines and returns WITHOUT setting op_bad — so the overall verdict falls through
  # to the ALLOC arm and prints "ok". The op arm can only PROMOTE an alloc-ok to a
  # fail, never the reverse. So if a band retune (PERF_WIDERECORDS_N) drops resolve op1
  # under OP_FLOOR (headroom is only ~2.8x: op1≈2783 vs 1000), the guard would silently
  # stop checking while the shape still reported "ok" — the exact silent-green the
  # rshape (starimports/reexports) loop already fails on. Mirror that TOOSMALL=fail here
  # so widerecords can NEVER silent-pass. Narrow: widerecords' resolve reading only.
  if [ "$shape" = "widerecords" ]; then
    wr_ro1="$(awk '$1=="resolve"{print $2}' "$OF1")"
    if [ "$(awk -v v="${wr_ro1:-0}" -v f="$OP_FLOOR" 'BEGIN{print (v+0 < f+0)?1:0}')" = "1" ]; then
      fail=$((fail+1))
      printf '%-10s %8s  ** N TOO SMALL — widerecords resolve-guard blind: resolve op1 %s < OP_FLOOR %s — raise PERF_WIDERECORDS_N **\n' \
        "$shape" "$n1" "${wr_ro1:-0}" "$OP_FLOOR"
      continue
    fi
  fi

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
    printf '%s' "$op_lines"

  elif [ "$time_bad" = "1" ]; then
    # Allocation alone said "ok" — this is the blind spot #110 exists to close. A
    # pure O(n^2) scan (the resolve bug in #78) allocates almost nothing extra per
    # element, so allocation cannot see it; TIME can, and just did.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (TIME) **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '           alloc looked fine (r1=%s r2=%s) — the regression is in TIME:\n' "$r1" "$ratio"
    printf '%s' "$time_lines"
    printf '%s' "$op_lines"

  elif [ "$op_bad" = "1" ]; then
    # Allocation AND time both said "ok" — the #884 blind spot. A stage under the
    # 200ms TIME_FLOOR on every shape (e.g. `mark`) is graded by NOTHING on time, and a
    # pure scan allocates nothing — so only the deterministic op arm sees this, and
    # just did. This branch sits AFTER the alloc/time failures so it can only PROMOTE
    # an "ok" to a FAIL, never downgrade one.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (OPS) **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '           alloc AND time looked fine — the regression is in OP COUNT (a pure scan TIME cannot floor-grade):\n'
    printf '%s' "$time_lines"
    printf '%s' "$op_lines"

  else
    pass=$((pass+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ok\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '%s' "$time_lines"
    printf '%s' "$op_lines"
  fi
done

# ── SHAPE: modules — the O(modules^2) family (issue #153) ─────────────────────
#
# This is the WHOLE POINT of #153: the five shapes above are single-file, so they
# run only the single-file driver and are STRUCTURALLY BLIND to the multi-module
# passes (checkModuleFullImpl, elabModuleStamp) where the module-count quadratics
# live. This shape runs the MULTI-MODULE driver (profile_modules_main:
# loadProgram -> markModules -> checkModules) over N import-chained modules so the
# accumulated-decl rescans actually execute. It is graded on BOTH net-total
# allocation (its own baseline, subtracted like the single-file shapes) AND, since
# the scan-heavy part is time-dominant, the per-stage `typecheck` TIME. It is a
# LEDGERED entry (KNOWN_SUPERLINEAR + KNOWN_SLOW_TIME): a real, currently-UNFIXED
# quadratic (#154/#150), recorded so the gate is green now yet self-drains the
# instant those fixes land. See both ledger blocks above for the contract.
MOD_N="${PERF_MOD_N:-100}"
MOD_K="${PERF_MOD_K:-8}"
mn1="$MOD_N"; mn2=$((MOD_N * 2)); mn3=$((MOD_N * 4))
md1="$WORK/modules_$mn1"; md2="$WORK/modules_$mn2"; md3="$WORK/modules_$mn3"
gen_modules "$mn1" "$md1" "$MOD_K"
gen_modules "$mn2" "$md2" "$MOD_K"
gen_modules "$mn3" "$md3" "$MOD_K"

# Own baseline: this driver's fixed prelude cost differs from the single-file one.
MBASE_DIR="$WORK/modules_base"; mkdir -p "$MBASE_DIR"
printf 'main = println 1\n' > "$MBASE_DIR/entry.mdk"
MBASE_ALLOC="$(alloc_of_modules "$MBASE_DIR/entry.mdk" "$MBASE_DIR")"

ma1="$(alloc_of_modules "$md1/entry.mdk" "$md1")"
ma2="$(alloc_of_modules "$md2/entry.mdk" "$md2")"
ma3="$(alloc_of_modules "$md3/entry.mdk" "$md3")"

# A shape that cannot be measured is a HARNESS failure, never a silent pass — same
# contract as the single-file loop.
case "$MBASE_ALLOC$ma1$ma2$ma3" in
  *[!0-9.]*|"")
    echo "FAIL modules: profiler produced no allocation figure (harness bug)"
    fail=$((fail+1)) ;;
  *)
    # typecheck-stage TIME, min-of-K, heap pinned (rule 2/3). The other stages
    # (load/mark/desugar) scale linearly and sit under the 200ms floor at these N,
    # so typecheck is the one time signal worth grading — and the one the ledger
    # names.
    mt1="$(stage_times_min_modules "$md1/entry.mdk" "$md1" "$PERF_K" | awk '$1=="typecheck"{print $2}')"
    mt2="$(stage_times_min_modules "$md2/entry.mdk" "$md2" "$PERF_K" | awk '$1=="typecheck"{print $2}')"
    mt3="$(stage_times_min_modules "$md3/entry.mdk" "$md3" "$PERF_K" | awk '$1=="typecheck"{print $2}')"

    mnet1="$(awk -v a="$ma1" -v b="$MBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    mnet2="$(awk -v a="$ma2" -v b="$MBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    mnet3="$(awk -v a="$ma3" -v b="$MBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"

    # ── ALLOC verdict: HARD LINEAR GATE (#154 PR-C promoted `modules` OUT of the ledger
    # 2026-07-16).  The foldModules-concat O(modules^2) is gone; net-alloc r2 is FLAT ~2.0
    # to N=1600.  Graded exactly like the single-file shapes: r2 > THRESH (or a CLIMBING
    # ratio) FAILS as SUPERLINEAR; a too-small measurement is a harness failure, never a
    # silent pass. ──
    averdict="$(awk -v n1="$mnet1" -v n2="$mnet2" -v n3="$mnet3" -v th="$THRESH" 'BEGIN {
      if (n1 + 0 < 1.0) { printf "0 0 TOOSMALL"; exit }
      r1 = n2 / n1; r2 = n3 / n2
      climbing = (r2 > r1 * 1.15 && r2 > 2.45)
      printf "%.2f %.2f %s", r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok")
    }')"
    mar1="$(echo "$averdict" | cut -d' ' -f1)"
    mar2="$(echo "$averdict" | cut -d' ' -f2)"
    aword="$(echo "$averdict" | cut -d' ' -f3)"
    if [ "$aword" = "TOOSMALL" ]; then
      fail=$((fail+1))
      printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** N TOO SMALL — raise PERF_MOD_N **\n' \
        "modules" "$mn1" "$mnet1" "$mnet2" "$mnet3" "-" "-"
    elif [ "$aword" = "QUADRATIC" ]; then
      fail=$((fail+1))
      printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (ALLOC) **\n' \
        "modules" "$mn1" "$mnet1" "$mnet2" "$mnet3" "$mar1" "$mar2"
    else
      pass=$((pass+1))
      printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ok\n' \
        "modules" "$mn1" "$mnet1" "$mnet2" "$mnet3" "$mar1" "$mar2"
    fi

    # ── TIME verdict: no longer ledgered (#154 PR-C).  typecheck TIME is now UNDER the
    # 200ms floor at the gate's N (the fix dropped it there), so it SKIPS loudly — the same
    # rule-4 floor behavior the single-file loop applies to an UN-ledgered stage.  If it
    # ever climbs back over the floor it is hard-gated: r2 > THRESH (or climbing) = SUPERLINEAR. ──
    if [ -z "$mt1" ] || [ -z "$mt2" ] || [ -z "$mt3" ]; then
      echo "           time typecheck: NO MEASUREMENT from the profiler (harness bug)"
      fail=$((fail+1))
    else
      below="$(awk -v v="$mt3" -v f="$TIME_FLOOR" 'BEGIN{print (v + 0 < f + 0) ? 1 : 0}')"
      if [ "$below" = "1" ]; then
        ms3="$(awk -v v="$mt3" 'BEGIN{printf "%.0f", v*1000}')"
        msf="$(awk -v f="$TIME_FLOOR" 'BEGIN{printf "%.0f", f*1000}')"
        printf '           time typecheck: SKIP — too small to time-gate: %s ms at N=%s < %s ms floor (linear since #154 PR-C)\n' "$ms3" "$mn3" "$msf"
      else
        mtr1="$(awk -v a="$mt1" -v b="$mt2" 'BEGIN{printf "%.2f", b/a}')"
        mtr2="$(awk -v a="$mt2" -v b="$mt3" 'BEGIN{printf "%.2f", b/a}')"
        tbad="$(awk -v r1="$mtr1" -v r2="$mtr2" -v th="$THRESH" 'BEGIN{print (r2 > th || (r2 > r1 * 1.15 && r2 > 2.45)) ? 1 : 0}')"
        if [ "$tbad" = "1" ]; then
          fail=$((fail+1))
          printf '           time typecheck: ** SUPERLINEAR (TIME) ** %ss -> %ss -> %ss  r1=%s r2=%s (> %sx)\n' \
            "$mt1" "$mt2" "$mt3" "$mtr1" "$mtr2" "$THRESH"
        else
          printf '           time typecheck: ok  %ss -> %ss -> %ss  r1=%s r2=%s (min-of-%s, heap pinned)\n' \
            "$mt1" "$mt2" "$mt3" "$mtr1" "$mtr2" "$PERF_K"
        fi
      fi
    fi ;;
esac

# ── SHAPES: starimports / reexports — multi-module RESOLVE (issue #881) ────────
#
# THE HOLE #881 CLOSES: until now the multi-module driver (profile_modules_main) ran
# load -> desugar -> mark -> typecheck and DISCARDED resolve — it did not even import
# it. So resolveModulesErrorsG (frontend.resolve), a whole PRODUCTION pass with a
# known-superlinear shape (it threads `known` and resolves each import via a linear
# findExports scan; a star or a re-export fan-out is O(modules^2) in ONE module), was
# entirely off the CI map. The single-file `xref` shape covers single-file resolve; the
# `modules` shape above runs the multi-module driver but only grades typecheck. This
# adds the resolve stage to that driver and two shapes that drive resolve specifically.
#
# GRADED ON OP-COUNT ONLY — deterministic, ONE run per size, no min-of-K / heap-pin /
# floor (the #884 arm). This is a deliberate CI-cost choice (the `gates (types)` shard is
# the critical path, and a multi-module run is heavier than a single-file one): op-count
# already gives the signal on `reexports` (a clean ~2^3 cubic), so paying K timing runs
# would buy nothing. `reexports:resolve` is LEDGERED (KNOWN_SLOW_OPS) as a pre-existing,
# currently-unfixed superlinearity; `starimports:resolve` reads LINEAR (its findExports
# quadratic is uncounted AND dwarfed by linear alloc — see gen_starimports) and is an
# `ok` regression guard on the counted import-membership path.
#
# ⚠️ ADDITIVE: the resolve stage discards its `List ResError` and does NOT transform the
# module list, so the `modules` block above (mark/typecheck) is byte-unchanged by it.
#
# Bands are SMALL (QUICK/per-PR): starimports needs op1 >= OP_FLOOR (its resolve op-count
# is 5*N, so N=250 -> 1250 clears the 1000 floor with headroom); reexports is cubic and
# clears the floor at N=50 already, so it stays there.
STAR_N="${PERF_STAR_N:-250}"
REEXP_N="${PERF_REEXP_N:-50}"

for rshape in starimports reexports; do
  case "$rshape" in
    starimports) rbase="$STAR_N" ;;
    reexports)   rbase="$REEXP_N" ;;
  esac
  rn1="$rbase"; rn2=$((rbase * 2)); rn3=$((rbase * 4))
  rd1="$WORK/${rshape}_$rn1"; rd2="$WORK/${rshape}_$rn2"; rd3="$WORK/${rshape}_$rn3"
  "gen_$rshape" "$rn1" "$rd1"
  "gen_$rshape" "$rn2" "$rd2"
  "gen_$rshape" "$rn3" "$rd3"

  # ONE deterministic run per size — the op arm needs no min-of-K, heap-pin, or floor.
  # profile_modules_main does not run wasm, so there is no MEDAKA_PERF_WASM to strip.
  RR1="$WORK/${rshape}_rr1"; RR2="$WORK/${rshape}_rr2"; RR3="$WORK/${rshape}_rr3"
  MEDAKA_PERF=1 "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$rd1/entry.mdk" "$rd1" > "$RR1" 2>&1
  MEDAKA_PERF=1 "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$rd2/entry.mdk" "$rd2" > "$RR2" 2>&1
  MEDAKA_PERF=1 "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$rd3/entry.mdk" "$rd3" > "$RR3" 2>&1
  ro1="$(awk -F'\t' '/^\[perf\] resolve/{print $5; exit}' "$RR1")"
  ro2="$(awk -F'\t' '/^\[perf\] resolve/{print $5; exit}' "$RR2")"
  ro3="$(awk -F'\t' '/^\[perf\] resolve/{print $5; exit}' "$RR3")"

  op_bad=0; op_lines=""
  # An UNMEASURABLE resolve shape is a harness problem, never a pass — mirror the alloc
  # arm's TOOSMALL=fail. grade_op_stage SKIPs a reading under OP_FLOOR WITHOUT setting
  # op_bad, so without this guard a non-ledgered shape (starimports) would fall through
  # to pass++ below and report "ok" having graded NOTHING — the silent-green this suite
  # forbids. The trigger is real: lowering a resolve shape's band below OP_FLOOR for
  # CI-cost reasons. Fail loudly instead, for both shapes (a ledgered shape that drops
  # under the floor is a "raise N or promote" signal, not a pass). (#881 review finding.)
  rsmall="$(awk -v v="$ro1" -v f="$OP_FLOOR" 'BEGIN{print (v+0 < f+0) ? 1 : 0}')"
  if [ "$rsmall" = "1" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  resolve-ops %s -> %s -> %s  ** N TOO SMALL (op1 < OP_FLOOR %s) — raise this shape band **\n' \
      "$rshape" "$rn1" "$ro1" "$ro2" "$ro3" "$OP_FLOOR"
    continue
  fi
  grade_op_stage "$rshape" resolve "$ro1" "$ro2" "$ro3" "$rn1" "$rn2" "$rn3"
  # grade_op_stage handles the KNOWN_SLOW_OPS ledger (known++/fail++) internally and sets
  # op_bad for a NON-ledgered superlinear reading. Count pass/fail for the rest.
  if [ "$op_bad" = "1" ]; then
    fail=$((fail+1))
  elif ! is_known_ops "${rshape}:resolve"; then
    pass=$((pass+1))
  fi
  printf '%-12s %8s  resolve-ops %s -> %s -> %s  (band N=%s->%s->%s)\n' \
    "$rshape" "$rn1" "$ro1" "$ro2" "$ro3" "$rn1" "$rn2" "$rn3"
  printf '%s' "$op_lines"
done

printf -- '---------------------------------------------------------------------\n'
printf '%d ok, %d known-superlinear (ledgered), %d regressed (threshold %sx per doubling)\n' "$pass" "$known" "$fail" "$THRESH"

printf 'backend TIME arm (issue #359): %d native lower/emit stage-ratios graded\n' "$backend_graded"
# The wasm arm is NOT counted by backend_graded (see that counter's note: wasm-emit
# clears the floor on most shapes, so counting it would make the counter unfailable).
# Its coverage guarantee is the KNOWN_SLOW_TIME ledger instead — `xref:wasm-emit` is
# graded on every green run or the gate is red — so report it rather than leaving the
# arm unmentioned.
printf 'backend TIME arm (issue #359): wasm graded via the xref:wasm-emit ledger row\n'
printf 'OP-COUNT arm (issue #884): %d per-stage op-ratios graded (deterministic, no floor)\n' "$ops_graded"

# Never exit 0 having measured nothing.
[ $((pass + known + fail)) -gt 0 ] || { echo "FAIL: the gate measured no shapes at all"; exit 1; }

# Never exit 0 having graded no OP stage — the #884 analogue of the backend guard. If
# every OP_STAGES reading fell under OP_FLOOR (or the profiler stopped emitting the 5th
# column, so every field-5 read was empty), the op arm is silently dead while the gate
# still exits 0. `mark` alone guarantees a non-zero count on the `marksweep` money-shot,
# so 0 means the arm broke, not that the shapes are clean.
if [ "$ops_graded" -eq 0 ]; then
  echo "FAIL: no stage was graded on OP COUNT — the #884 op arm is dead."
  echo "      Every OP_STAGES reading fell under OP_FLOOR (${OP_FLOOR}). Either the profiler"
  echo "      stopped emitting the tab-delimited op column (timer.mdk:emitPhaseAO /"
  echo "      opcount.mdk), setOpCounting is not being called, or the shapes shrank."
  exit 1
fi

# Never exit 0 having graded no BACKEND stage — that is precisely issue #359, and it
# would come back SILENTLY (every lower/emit dropping under TIME_FLOOR reads as a
# loud-but-harmless SKIP per stage, yet in aggregate it means the O(n^2) detector is
# once again blind to the entire second half of the pipeline). N==0 is a FAILURE.
if [ "$backend_graded" -eq 0 ]; then
  echo "FAIL: no backend stage (lower/emit) was graded on TIME — the #359 blind spot is back."
  echo "      Every lower/emit reading fell under the ${TIME_FLOOR}s TIME_FLOOR. Either the"
  echo "      profiler stopped emitting [perf] lower / [perf] emit, or the shapes shrank."
  echo "      Do NOT 'fix' this by lowering the floor: raise N until the stage is timeable."
  exit 1
fi

if [ "$fail" -gt 0 ]; then
  cat <<EOF

A shape grew faster than ${THRESH}x per doubling of input size, in ALLOCATION, in
per-stage TIME, or in per-stage OP COUNT. That is the signature of a SUPERLINEAR
(probably QUADRATIC) algorithm.

If the failure says SUPERLINEAR (TIME) or SUPERLINEAR (OPS) while allocation reads
"ok", that is not a contradiction — it is the point. A pure O(n^2) TRAVERSAL (scan a
list / linear-search a scope once per lookup) costs time and op-count quadratically
while allocating nothing extra, so allocation cannot see it. SUPERLINEAR (OPS) further
catches it on the SMALL stages (mark/desugar/exhaust-guards) whose absolute time never
clears the 200ms floor, where the TIME arm grades nothing at all. All three signals are
real; none subsumes the others.

  linear      ~2.0x      n log n  ~2.1x      QUADRATIC  ~4.0x

The pattern found every time so far: a List being scanned / elem-checked /
lookup-ed / rebuilt ONCE PER ELEMENT. Note that \`xs ++ [x]\` inside a fold is
O(n^2) all by itself (list append is O(n)).

To localize it:
  MEDAKA_PERF=1 test/bin/profile_main stdlib/runtime.mdk stdlib/core.mdk <fixture>
gives per-STAGE time and allocation. Then \`perf\` (apt-get install linux-perf) to
name the hot symbol. USE DWARF CALL GRAPHS -- \`perf record --call-graph dwarf,16384\`
-- the emitted LLVM carries CFI, so unwinding produces clean stacks. (This message
used to say call graphs were "unusable" and to use flat counts only. That was WRONG:
it described frame-pointer unwinding, and it cost an agent a wrong turn. Flat counts
are still the right axis for a NON-allocating quadratic -- a hot symbol that allocates
nothing is not a false positive, it is the bug class allocation profiling cannot see.)

WARNING: \`whenL False (expensiveCall ...)\` is NOT a stub -- Medaka is strict, so
the argument still evaluates. To stub something out, actually remove the call.
EOF
  exit 1
fi
exit 0
