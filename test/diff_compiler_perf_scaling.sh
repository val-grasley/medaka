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

# `xref` samples the WASM arm at its OWN, SMALLER band — 2000/4000/8000 rather than
# the shape's 4000/8000/16000. This is a COST fix and it is the reason this gate is
# not the CI critical path; read the wasm-band note by KNOWN_TCEIL_xref_wasm_emit
# before changing it, because the ledger's ceiling is calibrated to THIS band and
# means nothing against another one.
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
TIME_STAGES="parse exhaust-guards desugar resolve mark typecheck fmt lint lower emit"

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
#   xref:emit — FOUND BY THIS GATE the moment it could see the backend at all
#     (2026-07-16, issue #359), and it is the SAME thesis as match:typecheck above,
#     one pipeline half later: the LLVM emitter is QUADRATIC in the number of
#     top-level declarations, and ALLOCATION IS BLIND TO IT.
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
KNOWN_SLOW_TIME="xref:emit xref:wasm-emit"
KNOWN_TCEIL_match_typecheck="4.6";    KNOWN_TFIXED_match_typecheck="2.60"
KNOWN_TCEIL_listlit_typecheck="4.8";  KNOWN_TFIXED_listlit_typecheck="2.60"
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
# ⚠️ THIS ROW IS MEASURED AT N=2000->4000->8000 (XREF_WASM_N), *NOT* at the shape's
# 4000->8000->16000 like every other xref row. It is the one stage that could not afford
# resolve's N — 42 s x K=5 = ~211 s of a required CI shard for one row. Read the
# XREF_WASM_N note and grade_wasm_row's xref arm before touching either number.
#
# Observed at THIS band: r2 3.51-3.79, r1 2.68-2.75 (min-of-5 gate batch: 2.75/3.51;
# min-of-3 and min-of-1 spot batches: 3.72/3.79).
#
# ⚠️ THE OLD BAND'S NUMBERS DO NOT TRANSFER, AND THE RESAMPLE IS CROSS-CHECKED BY THAT:
# the previous entry recorded r2 3.87-4.15 / r1 3.60-3.82 at 4000->8000->16000. Those are
# NOT this row's numbers and must not be compared to them — but they are not unrelated
# either, and the relation is the check. This band's r2 IS the old band's r1: both are the
# SAME 4000->8000 doubling of the SAME curve. Old r1 3.60-3.82 vs new r2 3.51-3.79 — they
# agree, which is what says the smaller band resampled the curve rather than lost it. (Had
# they disagreed, the resample would be measuring something else and this entry would be
# junk.) Sampling LOWER still, at 1000->2000->4000, DOES lose it: measured r1=1.93 r2=2.68,
# i.e. UNDER TFIXED — the ~0.215 s prelude constant dominates at small N and the gate would
# have fired PROMOTE and declared #349/#350/#352 fixed. That is why the band is 2000, not
# lower, and it is a measured floor, not a preference.
#
# Ceiling 5.6 RETAINED, not re-derived: it clears this band's top (3.79) by 1.48, the same
# headroom convention as xref:emit (1.45) and the modules:typecheck precedent (1.3). TFIXED
# 2.60 (the file-wide convention) sits 1.35 under this band's floor (3.51) — a tighter
# margin than the old band's 1.57, so if this row ever starts flapping PROMOTE on a loaded
# runner, that margin is the first suspect. It should not: per the band warning above, a
# BUSY box reads this row LOWER... which is the direction of TFIXED. Watch it.
KNOWN_TCEIL_xref_wasm_emit="5.6";     KNOWN_TFIXED_xref_wasm_emit="2.60"

is_known_time() {
  for k in $KNOWN_SLOW_TIME; do [ "$k" = "$1" ] && return 0; done
  return 1
}

fail=0
known=0
pass=0

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
# ceilings are calibrated per-band ("a scaling ratio is not a constant" — see the
# KNOWN_TCEIL_xref_wasm_emit note), and two workstreams once appeared to disagree about
# one curve purely because each quoted a ratio without its band. A row that states
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
SHAPES="bindings match listlit nesting xref comments"
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
    xref)     base_n="$XREF_N" ;;
    comments) base_n="$COMMENTS_N" ;;
    manydefs) base_n="$MANYDEFS_N" ;;
    *)        base_n="$N" ;;
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

  time_bad=0
  time_lines=""
  for st in $TIME_STAGES; do
    grade_time_stage "$shape" "$st" \
      "$(awk -v s="$st" '$1==s{print $2}' "$TF1")" \
      "$(awk -v s="$st" '$1==s{print $2}' "$TF2")" \
      "$(awk -v s="$st" '$1==s{print $2}' "$TF3")" \
      "$n1" "$n2" "$n3"
  done
  grade_wasm_row "$shape" "$n1" "$n2" "$n3"

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

printf -- '---------------------------------------------------------------------\n'
printf '%d ok, %d known-superlinear (ledgered), %d regressed (threshold %sx per doubling)\n' "$pass" "$known" "$fail" "$THRESH"

printf 'backend TIME arm (issue #359): %d native lower/emit stage-ratios graded\n' "$backend_graded"
# The wasm arm is NOT counted by backend_graded (see that counter's note: wasm-emit
# clears the floor on most shapes, so counting it would make the counter unfailable).
# Its coverage guarantee is the KNOWN_SLOW_TIME ledger instead — `xref:wasm-emit` is
# graded on every green run or the gate is red — so report it rather than leaving the
# arm unmentioned.
printf 'backend TIME arm (issue #359): wasm graded via the xref:wasm-emit ledger row\n'

# Never exit 0 having measured nothing.
[ $((pass + known + fail)) -gt 0 ] || { echo "FAIL: the gate measured no shapes at all"; exit 1; }

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
