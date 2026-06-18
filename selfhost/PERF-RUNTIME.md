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

## Levers (ranked, to be measured)

1. **Float-expression fusion** (IN PROGRESS) — compute maximal float-arith subtrees
   in unboxed `double` SSA, box once at boundary, zero boxes when consumed by a
   comparison. Contained emitter change, bit-identical output. Targets mandel/dense
   float. Will NOT help floatsum (single-op accumulator, already 1 box/iter).
2. **Loop-carried float unboxing** — carry a statically-Float musttail/loop
   accumulator param as native `double`, killing floatsum-style per-iter boxes.
   Deeper (touches the tail-loop param representation).
3. **Monomorphization** (user-suggested) — specialize polymorphic fns per type →
   unboxed floats generally, devirtualize dict-passing, enable instance-level DCE.
   Largest swing; would subsume much of 1/2 and the dict-passing overhead.
4. **GC allocation density** — structural; fewer transient cells everywhere.
5. **Compiler caching** (user-suggested, compiler-side) — incremental/cross-run
   caching of parse/typecheck. Measure where compile latency actually goes first.

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

## Dead-ends

(none yet)

## Bugs / language gaps observed

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
