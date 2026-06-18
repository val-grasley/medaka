# PERF-RUNTIME.md — general compiled-program performance

Performance of **native-compiled Medaka programs** (the `medaka build` → LLVM IR →
clang path), as distinct from compiler self-compile speed (that is
`selfhost/PERF-RESULTS.md`). Started 2026-06-17 (overnight session 3).

All numbers: Apple M5, macOS 26.5, Apple clang 21, quiet machine, `/usr/bin/time -l`,
min-of-3, production build flags (`-O2 -Wl,-stack_size,0x20000000`, GC
`free_space_divisor=1`). Build via the native `./medaka` with
`MEDAKA_EMITTER=./medaka_emitter` (the OCaml `medaka build` path is dead — its
interpreter can no longer parse the selfhost emitter source).

## Benchmark suite (`test/bench_fixtures/`)

Self-contained (no stdlib import) so they build via `medaka build` and isolate one
construct each.

| bench | construct | notes |
|---|---|---|
| `fib.mdk` | int tree recursion, **no alloc** | raw codegen / call overhead |
| `intsum.mdk` | int tail-loop, **no alloc** | control for floatsum |
| `floatsum.mdk` | float tail-accumulator | **isolates float boxing** (1 box/iter) |
| `mandel.mdk` | dense float compute (Mandelbrot) | ~11 float boxes/inner-iter |
| `bintrees.mdk` | ADT Node churn | GC mark/collect path |

## Baseline (2026-06-17, commit `2a54937` + benches, BEFORE any perf change)

| bench | min wall | RSS | observation |
|---|---|---|---|
| fib 38 | 0.09s | 2MB | codegen already tight (matches prior -O2 finding) |
| intsum 50M | 0.02s | 2MB | zero-alloc loop floor |
| floatsum 50M | 0.38s | 3MB | **18× slower than intsum — pure float-boxing tax** |
| mandel 300² | 0.18s | 3MB | dense float, boxing-bound |
| bintrees d15×200 | 0.09s | 7MB | ADT alloc + GC |

**Float boxing confirmed dominant for float code:** `floatsum` triggers **2916 GC
collections** (50M × 16B float cells ≈ 800MB churned); the only difference from the
zero-collection `intsum` is the box. Every `+ - * / %` and comparison on `Float`
currently: unbox operands (load), op, **box result** (`mdk_alloc(16)` + 2 stores).
`runtime/medaka_rt.c:548` `mdk_box_float`; emitter `selfhost/backend/llvm_emit.mdk:1822`
(`emitArith` LTFloat), `:1859` (`emitCmp` LTFloat).

## Value representation (reference)

- **Int / Char / Bool**: immediate, `(n<<1)|1` (Bool: 1=false, 3=true). No alloc.
- **Float**: heap-boxed `{i64 tag=2, double}`, 16B. **Every float op allocates.**
- **Cons / ADT / tuple / record / closure**: heap cell `{i64 header, fields…}`.
- **Nullary ctors (Nil/None/…)**: immediate `(tag<<1)|1`. No alloc (no win there).
- **TRMC**: DONE comprehensively (`selfhost/TRMC-DESIGN.md`) — cons/ctor builders,
  dispatched impls (`map`), match-arm descent (`filter`/`filterMap`), stack-safe to
  2M+. Not an available lever; only deferred seams F1(b)/F2(b) (no real targets).

## Levers (ranked)

1. **Float-expression fusion** — ✅ DONE (Win 1). mandel 6×.
2. **Let-bound float unboxing** — ✅ DONE (Win 2). mandel_let 2.3×.
3. **Worker-wrapper float-param unboxing** — remaining; floatsum-class. See
   "Remaining levers — concrete designs (A)".
4. **Monomorphization** (user-suggested) — remaining; the meta-lever. Design (C).
5. **Separate compilation** (user-suggested caching) — remaining; build latency. Design (D).
6. **arith-on-type-lost-floats fix** — remaining; correctness. Design (B).
7. **GC allocation density** — structural; fewer transient cells (bintrees ~50% GC_malloc).

## Wins banked

### Win 1 — float-expression fusion (2026-06-17, `selfhost/backend/llvm_emit.mdk`)

Compute a maximal statically-Float arith subtree in unboxed `double` SSA registers,
box ONCE at the boundary; a float comparison boxes ZERO times (operands go straight
to `fcmp`). Before, `emitArith`/`emitCmp` boxed every intermediate node AND boxed
float literals inline, round-tripping each result through a heap cell even when the
parent immediately re-consumed it.

Implementation: `staticIsFloat` (pure, conservative — no false positives vs the
emitted LTy, so it can only lose the optimization, never miscompile) routes the
float path to `emitFloatArith`/`emitFloatCmp`, which call `emitFloatD` — a
double-returning emitter that recurses through arith nodes (`fadd`/… on doubles),
emits float literals as inline `double` constants, and unboxes a non-arith leaf
once. The boxing fallback (`emitArithW`/`emitCmpW`) is the original code, still
reached for float values the static check misses (e.g. a float-returning call on the
left). Bit-identical results: box/unbox is a pure memory round-trip of the same
double; LLVM `fadd`/`fmul`/`fcmp` are the same ops the runtime helpers ran.

**Numbers (min-of-3, production flags):**

| bench | before | after | speedup |
|---|---|---|---|
| mandel 300² | 0.18s | **0.03s** | **6×** |
| floatsum 50M | 0.38s | **0.19s** | **2×** (literal `1.5` no longer boxes/iter) |
| fib / intsum / bintrees | — | unchanged | no float, no impact |

mandel emitted IR: float boxes in the hot `escape` loop collapse; whole-program
`alloc(i64 16)` = 36, with 21 fused float ops + 7 zero-box `fcmp`. floatsum still
boxes 1×/iter (single-op accumulator, no fusion depth) — addressed by the
loop-carried-unboxing lever (next).

**Gates (all green):** 24/24 float `llvm_fixtures` match their `.eval.golden`;
`diff_selfhost_llvm` **180/0**; `selfcompile_fixpoint` **C3a YES / C3b YES** (the
emitter's own float sites changed deterministically → reproduces byte-for-byte).
Seed goes stale (emitter graph changed); not re-minted (fixpoint-verified per policy).

### Win 2 — let-bound float unboxing (2026-06-17, `selfhost/backend/llvm_emit.mdk`)

Keep a `let`-bound float value **unboxed** in the emit env (`LTFloatU` — the register
holds a native `double`, not an i64 word), so float arith/compare on it reads the
double directly instead of unbox-from-a-just-created-box. Box lazily, only on escape.

The win over Win 1 (fusion): fusion eliminates intermediate boxes *within one
arith tree*, but a `let zr2 = zr*zr` boxed `zr2` at the binding and every reader
re-unboxed. Real numeric code is written with lets (`let zr2 = …; let zi2 = …; zr2 -
zi2 + cr`), so each binding cost a box. `mandel_let` (let-style mandel): 5 boxes in
the hot `escape` loop → **2**.

Mechanism (safe-by-centralization):
- `emitLet`/`emitBlock` CSLet: if the bound RHS is `staticIsFloat`, emit it as a
  `double` (`emitFloatD`) and bind `(reg, LTFloatU)`.
- **Escape coercion is centralized in `lookupVarG`** (the sole `Mut` var-read path):
  reading an `LTFloatU` var boxes it back to `(i64, LTFloat)`. So every ordinary use
  (tuple/record field, argument, return, non-float op) gets a proper boxed word —
  `emitExpr`'s "returns i64" invariant is preserved.
- `capWords` (closure captures) was the one *pure* `lookupVar` reader → rerouted
  through `lookupVarG`, so a captured float-let is boxed into the closure slot
  (closure ABI is uniform i64). No capture analysis needed.
- Only `emitFloatLeaf` consumes an `LTFloatU` reg raw (the fast path, via
  `floatVarReg`). `typeOf` normalizes `LTFloatU → LTFloat` (insurance).

**Numbers (min-of-3):** `mandel_let` 0.07s → **0.03s** (2.3×, now == inline mandel).
floatsum unchanged (its float is a *param* across a tail-call, not a let — needs
worker-wrapper unboxing, see levers). Correctness: `mandel_let`, a capture/tuple/
arith escape stress, and clean-stress all == interpreter oracle.

**Gates:** clean-stress + mandel_let == `medaka run` oracle; `diff_selfhost_llvm`
**180/0**; `selfcompile_fixpoint` **C3a/C3b YES**.

## Dead-ends

(none yet)

## Bugs / language gaps observed

- **PRE-EXISTING SOUNDNESS BUG — arith on type-lost floats miscompiles.** `a + b`
  (and `- * /`) where `a`/`b` are `Float` but their static LTy was lost — bound via
  **tuple/record destructure** (`match p { (a,b) => a + b }`) or **closure capture**
  (`loadCaptures` binds captures as `LTInt`) — compiles to **integer** arithmetic on
  boxed-float *pointers* → garbage (e.g. `3.75e+255`). The native interpreter is
  correct (dynamic). `emitCmp` already routes the ambiguous-LTy case through the
  runtime discriminator `@mdk_value_cmp_raw`; **`emitArith` has no such fallback**
  (`emitArithW`'s `_ =>` branch assumes `LTInt` ⇒ immediate int). Independent of the
  float-unboxing work (that branch is unchanged). Fix: route the ambiguous
  `LTInt`/`LTUnknown` arith case through a tag-dispatched `@mdk_num_*` (handles
  immediate-int AND float-box), mirroring the `emitCmp` precedent — at a small cost
  to genuine int arith unless provenance distinguishes "definitely immediate". Needs
  a fixture (`arith` over a tuple-destructured/captured float) + full gates. Recorded;
  not fixed tonight (esoteric, non-blocking, risks the int fast-path).

- `then`/`else` may not start a continuation line (layout) — forces inline
  if-then-else in float fixtures. Known, pre-existing; recorded in memory
  (`project_mdk_layout_continuation`). Not blocking.
- The native `medaka_emitter` binary, invoked DIRECTLY (not via `medaka build`),
  prints a trailing `()` (Unit) glued to the last IR line on stdout → the raw dump
  is not valid LLVM IR (`strip with sed '$ s/()$//'`). `medaka build` handles it, so
  not blocking; minor. Likely a Unit-main print on the emitter entry.

## Broad-suite baseline (2026-06-17, post-fusion)

| bench | time | RSS | GC colls | bottleneck |
|---|---|---|---|---|
| listops 2M (map/filter/fold) | 0.12s | 229MB | 7 | cons-cell density (3 live 2M lists) |
| closures 10M | 0.04s | 3MB | 292 | per-iter closure allocation |
| strbuild 20k `++` | 0.03s | 4MB | — | string append churn |
| bintrees d15×200 | 0.09s | 7MB | 101 | ADT Node alloc (~50% `GC_malloc`, sampled) |

These remaining levers are all **structural/large**: deforestation (listops cons
density), escape-analysis/inlining (closures), bump/generational GC or
stack-allocation (bintrees ~50% `GC_malloc`). No cheap safe win in the profile.

## Compile-time breakdown & the caching question (2026-06-17)

For the heavy compiler workload (self-compile graph, ~10MB IR):

| stage | time |
|---|---|
| `check` (parse+resolve+typecheck) | 1.7s |
| emit (native emitter → 317k-line IR) | 3.0s |
| **clang `-O2` of the IR** | **~127s** (PERF-RESULTS Entry 1; `-O0` ≈ few s) |

**clang `-O2` dominates build latency ~20–25× over the entire Medaka frontend+emit.**
So the user-suggested *caching* lever, for BUILD latency, points at **separate
compilation** (emit per-module IR → cache each module's `.o`, link; re-clang only
changed modules), NOT frontend caching. Frontend caching helps the `check`/LSP loop
(1.7s) but is small next to clang. Both are sizable architectural changes; separate
compilation is the higher-value compiler-perf lever and is recorded for a supervised
session (it changes emit linkage + the build driver).

## Branch certification (perf/float-unbox, 2026-06-17)

All EMIT-path gates byte-identical / green after both float wins:

| gate | result |
|---|---|
| `selfcompile_fixpoint` | C3a YES / C3b YES |
| `diff_selfhost_llvm` | 180 / 0 |
| `diff_selfhost_llvm_modules` | 13 / 0 |
| `diff_selfhost_llvm_typed` | 37 / 0 |
| `diff_selfhost_build` | 25 / 0 |
| `diff_native_stack` (TRMC) | 7 / 0 |
| `diff_native_cli` | 58 / 3 |

The 3 `native_cli` failures are `check/effect_param`, `check/effect_param_hole`
(no golden), and `lsp/session` — all `check`/`lsp` path, which the emit-only change
cannot touch (pre-existing; effect_param ties to the recent Async/effect-row commits,
lsp/session is a documented flake). Every gate that exercises codegen is green.

## Final measured numbers (min-of-3, native, production flags)

| bench | baseline | after fusion+let-unbox | speedup |
|---|---|---|---|
| mandel (inline float) | 0.18s | **0.03s** | **6×** |
| mandel_let (let-style float) | 0.07s | **0.03s** | **2.3×** |
| floatsum (param accumulator) | 0.38s | **0.19s** | 2× (literal box removed) |
| fib / intsum / bintrees / closures / strbuild | — | unchanged | no float |

## Remaining levers — concrete designs (for a supervised session)

### A. Worker-wrapper unboxing for float PARAMS (floatsum-class, ~5–10×)
floatsum's remaining cost is the accumulator boxed at the self-call (i64 ABI), then
unboxed next iteration; clang already TCO-loops it, so killing the box ≈ intsum speed.
Design: for a top-level non-dict self-recursive fn with ≥1 `LTFloat` param, emit a
WORKER `@f$fw(double …, i64 …)` (float params `double`) + a WRAPPER `@f(i64…)` that
unboxes float params and calls the worker. Bind worker float-params `LTFloatU` (reuse
the Win-2 escape machinery) and reroute self-calls to `@f$fw` passing float args via
`emitFloatD`. **Why deferred:** the self-call is emitted in TWO places —
`emitFnBody` (the `musttail`/CIf-guarded path) AND inside `emitDecision` (a `match`-bodied
fn like floatsum emits its self-call as a value inside the decision tree, NOT musttail).
Both must learn the worker reroute (a threaded `workerCtxRef`, mirror of `trmcCtxRef`),
plus signature/wrapper emission. Multi-path, route-fragile — supervised + fixpoint-gated.
Note: most float reductions go through polymorphic `fold` (won't benefit) — see C.

### B. The arith-on-type-lost-floats soundness fix (correctness)
See bug log above. Fix: bind tuple-destructure / closure-capture vars `LTUnknown`
(not `LTInt`) and add an `LTUnknown` arm to `emitArith` routing through `@mdk_num_*`
(tag-dispatch, correct for int-immediate AND float-box), mirroring `emitCmp`'s
runtime-discriminator. Keeps genuine `LTInt` arith inline-fast. Broad (LTUnknown is
handled in many emit sites) → needs a fixture (arith over a destructured/captured
float) + full gates. Correctness > perf; do supervised.

### C. Monomorphization (the meta-lever — user-suggested)
Specialize polymorphic functions per concrete type instantiation. Subsumes float
unboxing GENERALLY (a `fold (+) 0.0 floats` gets an unboxed-`double` accumulator —
which A cannot reach), devirtualizes dict-passing (turns runtime dict lookups into
direct calls), and enables instance-level DCE (the deferred backend item — see
AGENTS.md "Why selfhost stays stdlib-free"). Largest ceiling, largest effort/risk;
touches typecheck (collect instantiations) + emit (emit specialized copies) +
dispatch. Stage it: start with monomorphizing `Num`-instantiated functions to unbox
float/int, measured against `fold`-over-floats and dict-heavy benches.

### D. Separate compilation (the BUILD-latency caching lever — user-suggested)
clang `-O2` of the monolithic ~10MB IR dominates build latency (~127s, ~20-25× the
Medaka frontend+emit). Emit per-MODULE `.ll` (with cross-module `declare`s), clang
each to `.o` CACHED by module-IR hash, link the `.o`s. Incremental rebuild (one
module changed) → re-clang only that module + link ≈ seconds instead of ~127s.
Requires emitter restructure (per-module emission + linkage/init-order) + build-driver
rewrite (`selfhost/build_cmd.mdk`). A cheaper interim: cache the whole binary by
full-IR hash (helps only no-op rebuilds / repeated gate runs; fixpoint- & gate-safe
since it changes neither emitted IR nor program output).
