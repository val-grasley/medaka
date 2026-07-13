# PERF-RUNTIME.md — general compiled-program performance

**Status:** IMPLEMENTED — 11 fixpoint-gated native-codegen wins (float unboxing,
constant-cell hoisting) landed and are live in the emitter today. Well-maintained: the
2026-07-12 banner below already self-corrects the machine/flags staleness (Mac M5 →
Linux box migration) in place. Its "Remaining levers" section is genuine open forward
work, not stale content.

Performance of **native-compiled Medaka programs** (the `medaka build` → LLVM IR →
clang path), as distinct from compiler self-compile speed (that is
`compiler/PERF-RESULTS.md`). Started 2026-06-17 (overnight session 3).

All numbers: Apple M5, macOS 26.5, Apple clang 21, quiet machine, `/usr/bin/time -l`,
min-of-3, production build flags (`-O2 -Wl,-stack_size,0x20000000`, GC
`free_space_divisor=1`). Build via the native `./medaka` with
`MEDAKA_EMITTER=./medaka_emitter` (the OCaml `medaka build` path is dead — its
interpreter can no longer parse the compiler emitter source).

> ⚠️ **STALE MACHINE + STALE FLAGS (2026-07-12).** Two things moved out from under the
> numbers above. (1) Primary dev is now a **dedicated x86_64 Linux box** (Debian 13,
> 12-core EPYC 9645 / 32 GB, Debian clang 19), not the M5 Mac — the numbers are **not
> comparable** across the move; re-baseline on the current box before calling anything a
> regression. (2) `-Wl,-stack_size` is **gone** — it was Mach-O-only, and the compiler now
> gets its stack from a 256 MB GC-aware worker pthread in `runtime/medaka_rt.c`, so the
> build flags are `-O2 -pthread -lm` on both platforms. Use `/usr/bin/time -v` on Linux.

## Real-world validation (2026-06-18)

Beyond the micro-benches, a realistic mixed-float kernel — `taylor.mdk`: exp(x) via a
12-term Taylor series summed over 1M x-values (12M float iterations; let-bound terms,
a float accumulator, `fromInt` division) — measured **0.20s (main baseline) → 0.02s
(~10×)** with all 10 wins; the hot worker loop (`term__fw`) is now **allocation-free**
(0 `mdk_alloc`). Progression: 0.12s through Win 8 (fusion/let-unbox/atomic), 0.07s with
Win 9 (CBlock worker unboxed the accumulator), 0.02s with Win 10 (`fromInt`→`sitofp`
removed the last per-iter box). Takeaway: both dense pure-float kernels AND realistic
let-block numeric loops now reach ~10× when the hot loop becomes alloc-free.

## TL;DR (overnight session 3, 2026-06-17/18)

**11 fixpoint-gated native-codegen wins.** Two themes: (a) **float unboxing** — floats
were heap-boxed on every op (~18× tax); fusion + let-unboxing + atomic cells +
worker-wrapper + `fromInt`→`sitofp` + a general float-ABI (`$fw` for float helper fns)
take **floatsum 0.38→0.03 (~12×)**, **mandel 0.18→0.03 (6×)**, realistic `taylor`
**0.20→0.02 (~10×)**, **fhelp (float helper in a loop) 0.21→0.02**. (b) **constant-cell hoisting** — dict witnesses,
string/list/tuple/record literals that are compile-time constants were heap-allocated
at every evaluation; hoisting them to `internal constant` module globals takes
**dispatch 0.16→~0.03 (~5–8×)** and eliminates the per-eval alloc for constant
strings/lists/tuples/records. Every win is on an isolated branch (8-branch stack),
output-gated (`diff_compiler_*` byte-identical to the interpreter oracle) and
`selfcompile_fixpoint` C3a/C3b YES. Also corrected a stale doc claim: clang `-O2` of
the emitter is ~3.3s and a full rebuild ~8s (not the ~127s in PERF-RESULTS), so the
build-caching lever is moot.

**SOUNDNESS (overnight session, 2026-06-18) — 8 native-codegen fixes closing two whole
bug families, all compiled==interp, every `diff_compiler_*` gate + `selfcompile_fixpoint`
C3a/C3b green, zero perf regression:**
- *arith-on-type-lost-floats — FULLY CLOSED* (Float arith whose static LTy was lost →
  integer arith on boxed-float pointers → garbage): one-operand-Float (Win 12, `748bf5d`),
  closure float-capture `map (x=>x*scale)` (`03c432e`), tuple/record-destructure
  `(a,b)=>a+b` (`60522ef`), closure-call-result `f 1.0+f 2.0` (`e344efc`), record
  float-field-access `v.dx+v.dy` (`7ea85d2`), returned-from-fn closures
  `let f=mkAdd 100.0; f 1.0+f 2.0` (`2a3beeb`).
- *closure-application — CLOSED*: over-application `(g 7) 9` (`b4c1c44`),
  under-application/PAP `let h=g 7; h 9` (`2eacc61`).
- 6 regression fixtures (`closure_apply_arity` in llvm_fixtures; `tuple_float_arith`,
  `closure_ret_float`, `float_field_arith`, `returned_float_closure` in
  llvm_fixtures_typed). A post-fix soundness sweep over ADTs/comprehensions/
  nested-records/arrays/folds found NO further codegen divergences.
- Other recorded pre-existing item (NOT a codegen divergence): "unbound constrained fn"
  on some imported stdlib constrained fns (typecheck-side).

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
`runtime/medaka_rt.c:548` `mdk_box_float`; emitter `compiler/backend/llvm_emit.mdk:1822`
(`emitArith` LTFloat), `:1859` (`emitCmp` LTFloat).

## Value representation (reference)

- **Int / Char / Bool**: immediate, `(n<<1)|1` (Bool: 1=false, 3=true). No alloc.
- **Float**: heap-boxed `{i64 tag=2, double}`, 16B. **Every float op allocates.**
- **Cons / ADT / tuple / record / closure**: heap cell `{i64 header, fields…}`.
- **Nullary ctors (Nil/None/…)**: immediate `(tag<<1)|1`. No alloc (no win there).
- **TRMC**: DONE comprehensively (`compiler/TRMC-DESIGN.md`) — cons/ctor builders,
  dispatched impls (`map`), match-arm descent (`filter`/`filterMap`), stack-safe to
  2M+. Not an available lever; only deferred seams F1(b)/F2(b) (no real targets).

## Levers (ranked)

**11 wins banked** (all fixpoint-gated, on a 9-branch stack
`…→float-worker-block→fromint-fuse→float-helper-abi`):

1. **Float-expression fusion** — ✅ Win 1. mandel 6×.
2. **Let-bound float unboxing** (`LTFloatU`) — ✅ Win 2. mandel_let 2.3×.
3. **Atomic float cells** — ✅ Win 3. floatsum ~16%.
4. **Worker-wrapper float-param unboxing** (CIf/guard + 2-arm match) — ✅ Win 4. floatsum ≈12× cumul.
5. **Constant dict-witness hoisting** — ✅ Win 5. dispatch ~5–8× (≈ monomorphic).
6. **Constant string-literal cells** — ✅ Win 6. strlit ~elim.
7. **Constant list-literal cells** — ✅ Win 7. listlit alloc elim.
8. **Constant tuple/record cells** — ✅ Win 8. tuplit alloc elim.
9. **Worker-wrapper CBlock (let-block) bodies** — ✅ Win 9. taylor 0.12→0.07.
10. **`fromInt`/`intToFloat`→`sitofp` fusion** — ✅ Win 10. taylor 0.07→0.02 (cumul ~10×; hot loop alloc-free).
11. **General float-ABI (`$fw` for float helper fns)** — ✅ Win 11. fhelp 0.21→0.02; non-recursive
    float helpers called in float context use a double-ABI `$fw` (no box). Incidentally fixes the
    top-level-float-fn case of the arith-type-lost bug (reroute yields a double).

Constant-cell hoisting covers every safe cell type; float boxing comprehensively
addressed across CIf/match/let-block accumulators, int→float conversion, AND helper-fn
call boundaries.

**Remaining (structural / risky — not done):**
- **Monomorphization** — mostly captured by Win 5 for constant dicts; would still help
  RDict-forwarded dicts inside polymorphic fns + polymorphic-`fold` float unboxing. Big. Design (C).
- **GC allocation density** — bintrees ~50% GC_malloc, listsum/cons churn, the emitter's
  `++`/`mdk_string_append` result allocs (segment-emit was a session-2 dead-end). Structural.
- **arith-on-type-lost-floats fix** — **FULLY CLOSED 2026-06-18** (7 fixes; see TL;DR
  and bug log below). ~~PARTIALLY DONE: both-operands-type-lost REMAINING~~ — all forms
  closed (Win 12 + 6 soundness commits). Design B (field/component-type threading) was not
  needed; the `LTNum` / closure-capture / returned-from-fn fixes covered all real cases.
  (verified done 2026-06-22)

## Wins banked

### Win 1 — float-expression fusion (2026-06-17, `compiler/backend/llvm_emit.mdk`)

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
`diff_compiler_llvm` **180/0**; `selfcompile_fixpoint` **C3a YES / C3b YES** (the
emitter's own float sites changed deterministically → reproduces byte-for-byte).
Seed goes stale (emitter graph changed); not re-minted (fixpoint-verified per policy).

### Win 2 — let-bound float unboxing (2026-06-17, `compiler/backend/llvm_emit.mdk`)

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

**Gates:** clean-stress + mandel_let == `medaka run` oracle; `diff_compiler_llvm`
**180/0**; `selfcompile_fixpoint` **C3a/C3b YES**.

### Win 5 — constant dict-witness hoisting (2026-06-18, `perf/dict-const`)

A dict witness whose head tag + every requirement word are compile-time constants
(a one-level `RKey k []` → `[hashName k]`, or a nested RKey with constant reqs) was
heap-allocated by `emitDictCell` at **every call-site invocation** — e.g. a tight
`gmax : Ord a => …` loop allocated an 8-byte dict cell 50M times just to pass the
(constant, often unused) Ord dict. Now `dictWordOfRoute` routes constant dicts to
`emitConstDictCell`, which emits the cell ONCE as an `internal constant` module global
(deduped by initializer content) and passes `ptrtoint (ptr @g to i64)`. Layout is
byte-identical to the heap cell, so every consumer (RKey dispatch `loadField`,
nested-dict store, call arg) reads it unchanged. GC-safe: globals hold int tags +
ptrtoint-of-other-static-globals, no heap pointers.

**Numbers:** dispatch bench (polymorphic `Ord` 50M loop) **0.16s → 0.03s (~5×)**; the
loop's per-iteration `mdk_alloc` is gone, one shared `@mdk_dc_*` global remains. Broad:
every constant dict at a concrete→polymorphic call boundary (idiomatic — concrete code
calling generic stdlib) across all programs. The self-compile barely changes (the
emitter mostly forwards dicts via RDict params, not RKey constants) so no self-emit
regression (~3.0→3.3s, noise).

**Gates:** `diff_compiler_llvm` **180/0**, `diff_compiler_eval_dict` **25/0**,
`selfcompile_fixpoint` **C3a/C3b YES**, `diff_compiler_build` **25/0**,
`diff_native_cli` 58/3 (the 3 are pre-existing check/lsp, not emit).

**Follow-on:** RDict-forwarded dicts inside polymorphic fns stay heap-allocated (their
witness is a runtime param). Monomorphization (design C) would turn those into
constants too. The `lookupAssoc` dedup is linear; distinct-dict count is tiny so it's
fine, but an SMap/OrdMap would harden it if a program has many distinct dicts.

### Win 6 — constant string-literal cells hoisted to globals (2026-06-18, `perf/str-const`)

A `"…"` literal emitted a private byte-array global + a runtime `@mdk_str_lit` call
that allocated a fresh string cell (`{tag,byte_len,cp_count,bytes,NUL}`) at EVERY
evaluation — a string literal in a loop allocated per iteration. The cell is a
compile-time constant (cp_count is computable at emit time = `arrayLength
(stringToChars s)`), so `emitLit (LString …)` now emits the WHOLE cell as a
`private unnamed_addr constant { i64, i64, i64, [n+1 x i8] }` global and returns
`ptrtoint (ptr @g to i64)` — no runtime call, no allocation. Same global count as
before (one per literal occurrence), so no IR bloat; byte-identical cell layout, so
every string consumer (eq/append/print/slice) reads it unchanged.

**Numbers:** strlit (a `stringLength "hello world"` 10M loop) **0.07s → ~0** (the
per-iteration string alloc is gone). Broad: every string literal across all programs.
Self-emit unchanged (~3.1s — the emitter's string churn is dominated by `++`/
`mdk_string_append` result allocs, not literal cells).

**Gates:** `diff_compiler_llvm` **180/0**, `selfcompile_fixpoint` **C3a/C3b YES**
(the emitter is full of string literals — it self-compiles with cell-literals and
reproduces byte-for-byte), `diff_compiler_build` **25/0**, `diff_compiler_eval_run`
**28/0**. Correctness: concat/==/length literals == interpreter.

### Win 7 — constant list-literal cells hoisted to globals (2026-06-18, `perf/list-const`)

A list literal `[10,20,30]` allocated N cons cells at every evaluation (3 cons/iter in
a loop). When every element emits to a compile-time constant, `emitList` now builds the
cons spine as a chain of `internal constant` globals (each cell `[CONS, elem, tail-ptr]`,
base = Nil immediate) via `emitConstList` — no per-eval allocation. Restricted to
**lists** (where `==` is structural, verified — so sharing/dedup is value-safe);
**user-ADT cells are NOT hoisted** (their `==` is pointer-ish / already broken in the
compiled backend — out of scope). The non-constant path (`emitRtList` from pre-emitted
element words) is IR-identical to the original recursive `emitList`.

**Numbers:** listlit (`length [10,20,30]` 10M loop) 0.46s → **0.34s** (the 30M cons
allocs gone; residual is `length`'s O(n) traversal). Bigger for construct-only literals.
Also hoists constant **string** lists (str-const elements are constant ptrtoints).

**Gates:** `diff_compiler_llvm` **180/0**, `selfcompile_fixpoint` **C3a/C3b YES**,
`diff_compiler_eval_run` **28/0**, `diff_compiler_eval_list` **2/0**. Correctness:
`[1,2,3]==[1,2,3]` True, `map (*2) [10,20,30]` == interpreter.

### Win 8 — constant tuple/record cells hoisted to globals (2026-06-18, `perf/compound-const`)

Same constant-cell hoisting for tuple and record literals: `emitTuple`/`emitRecordCreate`,
when all field words are constant, emit the cell as an `internal constant` global
(via `emitConstDictCell`) instead of a per-eval `mdk_alloc`. Restricted to tuples +
records (both verified structural `==`, like lists — sharing is value-safe);
**user-ADT cells stay heap-allocated** (their `==` is pointer-ish / already broken).
Same byte-identical layout → field access / `==` / update read it unchanged.

**Numbers:** tuplit (`fst (10,20)` 10M loop) alloc/iter 1→0. Narrower than lists/strings
(constant tuples/records in hot loops are less common) but the same proven safe pattern;
composes (a constant tuple of constant strings/lists fully hoists).

**Gates:** `diff_compiler_llvm` **180/0**, `selfcompile_fixpoint` **C3a/C3b YES**,
`diff_compiler_eval_run` **28/0**. Correctness: tuple `==`/destructure, record access
== interpreter.

### Win 9 — worker-wrapper covers CBlock (let-block) bodies (2026-06-18, `perf/float-worker-block`)

Win 4's worker-wrapper handled CIf/value/2-arm-match bodies but NOT `let`-block bodies
— so the idiomatic float accumulator `f acc … = … let a = …; let b = …; f (acc+t) …`
(a CBlock) stayed ineligible and boxed its accumulator per iteration. Extended
`floatWorkerOk`/`emitFnBodyD` with a CBlock arm (`floatWorkerBlockOk`/`emitFnBodyDBlock`):
eligible iff every leading `CSLet` binds a plain var with a self-free RHS and the final
stmt is a worker-eligible CSExpr (the tail); the worker emits the lets (float RHS →
unboxed `LTFloatU`, reusing Win 2) then the tail in double-return mode. Any other stmt
(assign / let-else / non-PVar / non-CSExpr final) falls back.

**Numbers:** `taylor` (realistic 12-term Taylor exp, `term` has a let-block body) 0.12s →
**0.07s** — cumulative vs baseline **0.20→0.07 (~2.9×)**. CBlock-with-lets-before-the-
recursive-call is the common realistic float-accumulator shape, so this materially widens
worker-wrapper coverage.

**Gates:** `diff_compiler_llvm` **180/0**, `selfcompile_fixpoint` **C3a/C3b YES**; worker
sweep (w1–w8) + small-N == interpreter.

### Win 10 — `fromInt`/`intToFloat` → `sitofp` fusion (2026-06-18, `perf/fromint-fuse`)

`fromInt x` (@ Float) and `intToFloat x` are int→float conversions, but in float
context they were emitted as the extern/impl call (`sitofp` + **box**), then fusion
unboxed the result — a box-then-unbox per evaluation. `emitFloatLeaf` now recognizes
a `fromInt`/`intToFloat` call (head-name match, arity 1) and emits `sitofp i64 … to
double` directly — no box. Safe: only fires inside a statically-Float `emitFloatD`
context (so `fromInt` is the Float instance = `intToFloat` = `sitofp`); false-negative
falls back to the boxing leaf. `fromInt` is idiomatic in numeric code (converting loop
counters / sizes to float), so this removes a common per-iteration box.

**Numbers:** `taylor` 0.07s → **0.02s** — `term__fw` now has **ZERO `mdk_alloc`** (the
hot loop is allocation-free). Cumulative vs baseline **0.20→0.02 (~10×)**. Correctness:
`fromInt 7 + 0.5` = 7.5, `fromInt 3 * fromInt 4` = 12.0, `fold (+fromInt) …` == interp.

**Gates:** `diff_compiler_llvm` **180/0**, `selfcompile_fixpoint` **C3a/C3b YES**,
`diff_compiler_eval_run` **28/0**.

## Dead-ends

(none yet)

### Win 4 — worker-wrapper float-param unboxing (2026-06-18, `perf/float-param-unbox`)

floatsum's accumulator is a *param* boxed at each self-call (i64 ABI) then unboxed
next iteration; clang TCO-loops the call, so the box was the only cost. Emit a
WORKER `@mdk_<name>__fw(double acc, …)` carrying float params as native `double`
(self-calls `musttail` back into it with unboxed args → NO box per iteration) + a
WRAPPER `@mdk_<name>(i64 …)` (original ABI) that unboxes float params, calls the
worker, boxes the result. External callers + eta/dispatch hit the unchanged wrapper.

Scope (conservative, safe fallback): single-clause, all-PVar, non-dict, ≥1 `Float`
param, `Float` return, self-recursive, body is CIf/value, OR a desugarable 2-arm
`match scrut { lit => A ; _ => B }` (handled via `decisionToIf` → CIf, so the
idiomatic `match`-style floatsum.mdk also qualifies). Any other shape (constructor
patterns, >2 arms, guards, `let`-bodies with self) falls back to normal codegen.
Reuses the Win-2 `LTFloatU` machinery for the worker's double params.

**Numbers:** `floatsum` (match-style 50M) **0.16s → 0.03s (~5×)**; cumulative across
the session **0.38s → 0.03s (~12×)**, at the intsum 0.02s zero-alloc floor. Worker
body has **zero `mdk_alloc`** (accumulator stays a `double`; base case `ret double
%arg0`). Correct: small-N (1500.0) == interpreter.

**Gates:** `diff_compiler_llvm` **180/0**; `selfcompile_fixpoint` **C3a/C3b YES**
(+ typed/modules/build/stack — see commit). The emitter has no float-accumulator guard
fns of its own, so its IR is unchanged → fixpoint holds trivially.

**Follow-on:** the desugar covers 2-arm literal matches; a true CDecision-double
descent (multi-arm matches, `let`-bodied accumulators) via a `floatWorkerCtxRef`
mirror of `trmcCtxRef` would generalize further. Bounded; same technique.

### Win 3 — atomic float cells (2026-06-17, `llvm_emit.mdk` + `llvm_preamble.mdk`)

A boxed float is `{i64 tag=2, double}` — **pointer-free**. `boxFloat` emitted
`@mdk_alloc` (conservatively scanned); switched to `@mdk_alloc_atomic`
(`GC_malloc_atomic`, already in the runtime + now `declare`d in the preamble) so
Boehm never scans float payloads during mark. Sound (no Medaka pointer in the cell;
no false retention from float bit patterns). Runtime-/codegen-only; output identical.

**Numbers:** floatsum 0.19s → **0.16s** (~16%, min-of-5) — bigger than the ~3% the
analogous string-atomic change gave (session 2), because floatsum marks 50M transient
float cells. mandel/mandel_let unchanged (few floats live at mark time). Same applies
to no other cell: strings are already atomic; cons/ADT/tuple/closure carry pointers.

**Gates:** `diff_compiler_llvm` **180/0**; `selfcompile_fixpoint` **C3a/C3b YES**.

## Bugs / language gaps observed

- **SOUNDNESS SWEEP 2026-06-18 (post-fixes) — codegen verified CLEAN for common
  patterns.** After the six arith-typelost / closure-application fixes, a broad
  compiled-vs-interp sweep found NO further codegen divergences across: ADT float
  payloads (`Pt a b => a*a+b*b`), float list comprehensions, NESTED record float
  access (`o.inner.v + o.inner.v`), fn-returned float TUPLES (`let (a,b)=mk 3.0;
  a+b`), Option Float, `sum`/`fold`/fold-product over floats, float-array `get`+arith.
  All apparent failures were test-author errors identical in BOTH backends (not
  divergences): array fns need `import array.*` (wildcard) not `import array`, and
  mutating array `set` requires the caller's effect row to include `<Mut>`
  (`main : <IO, Mut> Unit`) — the effect checker correctly rejects undeclared `<Mut>`.
  Remaining known type-lost-float residual: closure RETURNED-from-a-fn then arith'd
  (rare; needs fnRetTy "returns-float-closure" propagation).


- **PRE-EXISTING — "unbound constrained fn" on imported constrained stdlib fns.**
  `medaka build`/`run` of a user program importing `list`/`map`/`set` and calling a
  constrained fn like `sort : Ord a => …` or `insert` panics
  (`typecheck.mdk:2284 "unbound constrained fn: sort"`). `sum`/`map` (also constrained)
  work, and prelude `max` works — so it's specific to some imported constrained fns
  (likely the recent multi-module import-scoping/mangling area; see memory
  `project_multimodule_check_import_scoping_collision`). Typecheck-side, pre-existing,
  unrelated to the perf work (which is emitter-only). Blocks demoing Win 5 on stdlib
  containers, but not its validity (user-defined `gmax` shows the 5×; eval_dict 25/0).
  — **APPEARS FIXED 2026-06-22**: `medaka build` with `import list.* ; sort [3,1,2]`
  builds and runs correctly (3); no panic. Likely resolved by 2026-06-17 multi-module
  check import-scoping collision fix (commit cfa2b1d / import-scope checkModulesEntryFullGo).

- **PRE-EXISTING SOUNDNESS BUG — arith on type-lost floats miscompiles.** `a + b`
  (and `- * /`) where `a`/`b` are `Float` but their static LTy was lost — bound via
  **tuple/record destructure** (`match p { (a,b) => a + b }`) or **closure capture**
  (`loadCaptures` binds captures as `LTInt`) — compiles to **integer** arithmetic on
  boxed-float *pointers* → garbage (e.g. `3.75e+255`). The native interpreter is
  correct (dynamic). `emitCmp` already routes the ambiguous-LTy case through the
  runtime discriminator `@mdk_value_cmp_raw`; **`emitArith` has no such fallback**
  (`emitArithW`'s `_ =>` branch assumes `LTInt` ⇒ immediate int).
  **PARTIALLY FIXED:** (a) Win 12 — one-operand-statically-Float arith now uses the
  float path. (b) 2026-06-18, commit 03c432e — **closure float CAPTURES fixed**:
  `loadCaptures` now threads the enclosing emit env (env param added to the 5
  `*Define` emitters) and binds a captured float `LTFloat` via the new `capTypeOf`
  (boxed-float convention; everything else stays `LTInt` → zero non-float change).
  This fixed the COMMON `map (x => x * scale)` idiom (captured float). (c) 2026-06-18,
  commit 60522ef — **tuple/record-destructured float arith fixed** (TYPED emit path):
  pattern-bound vars (`(a,b) => a + b`, `let (a,b)=p; …`) carry no declared type, so
  `paramUseTy` defaulted them to LTInt; now an arith operand whose sibling doesn't pin
  a concrete Int/Float is typed **LTNum** (runtime tag-dispatched @mdk_num_*, correct
  for int AND float). `binOperandTy`/`concreteNumTy` + block-continuation threading
  (`CBlock rest` into bindPattern). ZERO perf regression (only pattern-bound vars; int
  literals still pin the inline fast path). Typed gate `tuple_float_arith.mdk` 38/0.
  **STILL OPEN (tiny residual):** closure-call-RESULT arith where the closure is
  RETURNED FROM A FUNCTION (`let f = mkAdd 100.0; f 1.0 + f 2.0`) — the direct
  let-bound form (`let f = (x => x + base); f 1.0 + f 2.0`) is FIXED 2026-06-18
  (commit e344efc): a closure whose body evidently returns Float (`bodyFloatRet`,
  conservative) records LTFloat in `closureRetTyRef`, and `indirectRetTy` types the
  saturated call result LTFloat. The returned-from-fn case misses (f's reg is the
  call-result reg, not the lambda alloc reg) → needs ret-ty propagation through
  fnRetTy. Typed gate `closure_ret_float.mdk` 39/0. **The returned-from-fn form is
  ALSO FIXED** (2026-06-18, commit 2a3beeb): `collectFloatClosureFns` marks top-level
  fns returning a float closure; a saturated call records its result word in
  closureRetTyRef. `returned_float_closure.mdk` 41/0. The arith-on-type-lost-floats
  family is now FULLY CLOSED (7 fixes).

- **FIXED 2026-06-18 (branch perf/float-field-access, commit 7ea85d2) — record FLOAT
  field-ACCESS arith.** `v.dx + v.dy` / `v.dx*v.dx + v.dy*v.dy` over Float record
  fields did INTEGER arith on the boxed-float field words → garbage: emitFieldAccess
  returns LTInt and emitArith only checked staticIsFloat on the LEFT operand. Fix:
  emitArith routes to emitFloatArith when EITHER operand `isFloatFieldAccess`; the LTy
  of emitFieldAccess is UNCHANGED (localized to arith routing → no slice-7-dispatch
  blast radius). LESSON: an earlier attempt "broke slice-7" — real culprit was a
  DUPLICATE `nthStr` (grep before adding a helper). Typed gate `float_field_arith.mdk`
  40/0; zero perf regression.

- **FIXED 2026-06-18 (branch perf/closure-overapp) — over/partial-application of a
  LET-BOUND multi-level lambda.** `let g=(x => (y => x + y)); (g 7) 9` and
  `let h = g 7; h 9` miscompiled (garbage/empty): `flattenApp` collapses `(g 7) 9` to
  `g[7,9]` and the old `emitIndirect` passed BOTH args to g's arity-1 lifted code.
  Fix: a reg-keyed compile-time arity table (`closureArityRef`, recorded by
  `emitClosureAllocA`) makes `emitIndirect` arity-aware — OVER-app saturates then
  `emitApplyExtra`s the surplus; UNDER-app builds an indirect partial-application
  closure (`emitPapClosureIndirect`/`emitPapDefineIndirect`); saturated is the raw
  call. Verified compiled==interp (over, 3-level, partial-by-1, partial-by-2);
  diff_compiler_llvm 181/0 (+ fixture `closure_apply_arity.mdk`), full suite green,
  fixpoint C3a/C3b YES. Residual (rare, no regression): a closure reached through a
  table MISS (captured into another closure, then over-applied) — general cure is
  arity-in-cell at runtime, deferred.

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

**CORRECTION (measured this session, M5 + clang 21):** `clang -O2` of the 12MB
emitter IR is **~3.3s**, and a **full native compiler rebuild (emit+clang emitter +
emit+clang CLI) is ~8s** — NOT the ~127s in `PERF-RESULTS.md` Entry 1 (stale: older
machine/clang, or measured differently). Build latency is therefore a **non-issue**,
and the user-suggested **caching / separate-compilation lever is MOOT** — there is no
large clang cost to cache or split. `-O1` ≈ `-O2` runtime (self-emit 2.22s vs 2.17s)
at slightly lower compile (2.5s vs 3.3s); not worth changing the default.

| stage (self-compile graph, ~12MB IR) | time |
|---|---|
| `check` (parse+resolve+typecheck) | 1.7s |
| emit (native emitter → 317k-line IR) | ~3s |
| clang `-O2` of the IR | **~3.3s** (was mis-recorded as ~127s) |
| **full `build_native_medaka.sh` rebuild** | **~8s** |

The real performance opportunity is RUNTIME (compiled-program speed), not build
latency — see the float wins above and the remaining runtime levers below.

## Branch certification (perf/arith-typelost-fix — all 11 wins + Win-12 fix, 2026-06-18)

The full stack (11 perf wins + the Win-12 soundness fix) re-certified together on the
top branch — all green: `selfcompile_fixpoint` C3a/C3b YES; `diff_compiler_llvm` 180/0,
`_typed` 37/0, `_modules` 13/0; `diff_compiler_build` 25/0; `diff_compiler_eval_run`
28/0, `_dict` 25/0, `_list` 2/0, `_typed` 3/0; `diff_compiler_core_ir_run` 28/0;
`diff_native_stack` 7/0. Adopt-everything branch: **`perf/arith-typelost-fix`**; each
win also isolated on its own branch for cherry-picking. Final bench: floatsum 0.03,
mandel 0.03, dispatch 0.03, taylor 0.01, fhelp 0.02, strlit ~0; comp/shadow now correct.

## Branch certification (perf/fromint-fuse — all 10 wins stacked, 2026-06-18)

The full 10-win stack re-certified together on the top branch — all green:
`selfcompile_fixpoint` C3a/C3b YES; `diff_compiler_llvm` 180/0, `_typed` 37/0,
`_modules` 13/0; `diff_compiler_build` 25/0; `diff_compiler_eval_run` 28/0, `_dict`
25/0, `_list` 2/0, `_typed` 3/0; `diff_native_stack` 7/0. (`diff_native_cli` 58/3 —
the 3 are pre-existing `check`/`lsp`, not emit.) Adopt-everything branch:
`perf/fromint-fuse`; each win also isolated on its own branch for cherry-picking.

## Branch certification (perf/float-unbox, 2026-06-17)

All EMIT-path gates byte-identical / green after both float wins:

| gate | result |
|---|---|
| `selfcompile_fixpoint` | C3a YES / C3b YES |
| `diff_compiler_llvm` | 180 / 0 |
| `diff_compiler_llvm_modules` | 13 / 0 |
| `diff_compiler_llvm_typed` | 37 / 0 |
| `diff_compiler_build` | 25 / 0 |
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
**Blocker found (2026-06-18):** record/tuple field TYPES are NOT available at emit time
— the emitter's `recFields` table (`collectRecords`) captures field NAMES only, and
Core IR `CRecord`/destructure nodes carry no types (erased after typecheck). So the
proper fix (give a destructured/field-accessed float the `LTFloat` it deserves) needs
field types threaded through Core IR lowering into a new `recFieldType` table — a
lowering+emit change, not a localized emit patch. The `LTNum`/`LTUnknown` routing above
is the emit-side half; the type-source threading is the prerequisite.

### C. Monomorphization (the meta-lever — user-suggested)
**Measured this session: dict-passing/dispatch overhead is ~4×** — a polymorphic
`gmax : Ord a => a -> a -> a` in a 50M loop is 0.16s vs a monomorphic `imax : Int ->
Int -> Int` at 0.04s. The polymorphic define is `@mdk_disp__gmax(i64 %dict, i64, i64)`
and `a <= b` dispatches through `%dict` at runtime. This is broad — every constrained
function (stdlib `Eq`/`Ord`/`Num`/`Foldable`, the compiler's own generics, user code)
pays it.

Specialize polymorphic functions per concrete type instantiation: at a call site where
all type args are concrete (the dict-pass already resolves WHICH impl — an `RKey` like
`Int`/`Ord`), emit a specialized copy `@mdk_<fn>$<Type>(…)` with the dict param removed
and dict-method calls bound to the concrete impl (so `<=` inlines / calls
`@mdk_impl_Int_*` directly), and rewrite the call site to it (no dict arg). Subsumes
float unboxing GENERALLY (a `fold (+) 0.0 floats` gets an unboxed-`double` accumulator —
which the worker-wrapper cannot reach), devirtualizes dispatch (the ~4× above), and
enables instance-level DCE (AGENTS.md "Why compiler stays stdlib-free").

Scope/risk: touches `dict_pass.mdk` (collect concrete (fn × dict) pairs at call sites)
+ emit (emit specialized bodies; rewrite call sites) — the route-fragile dispatch
machinery. Stage it: start with fully-concrete-primitive dicts on top-level constrained
fns (e.g. `Ord`/`Num`), gated by `selfcompile_fixpoint` + `diff_compiler_llvm`/`_dict`.
Largest ceiling; a real multi-stage project (not a single-session change).

### D. Separate compilation (the BUILD-latency caching lever) — ❌ MOOT
**Measured this session: a full native compiler rebuild is ~8s (clang ~3.3s).** The
~127s clang figure in PERF-RESULTS that motivated this lever is stale/wrong. There is
no large clang cost to cache or split, so separate compilation / build caching has
~nothing to gain. Build latency is not a performance problem; runtime is the target.
