# PERF-CI-COVERAGE.md — a comprehensive design for catching quadratics in CI

**Status:** DESIGN — 2026-07-23, tracked in #880 (sub-issues #881–#887). A coverage-gap
analysis + build plan; nothing here is implemented yet.

**Goal:** catch every quadratic-or-worse regression *in CI*, before it reaches `main`.
**Scope:** the whole compiler pipeline, not just the front end the current gate favours.

Companion perf docs: `compiler/PERF-SCOPE.md` (ranked hot paths), `compiler/PERF-RESULTS.md`
(measured log incl. dead ends), and the deep-dive `.claude/workstreams/PERF.md`. This doc is
the *coverage map*: what the gates see, what they cannot, and how to close the gap.

---

## 0. Keep the principle the current gates already encode

`test/diff_compiler_perf_scaling.sh` is good, and this design extends its discipline rather
than replacing it. The load-bearing rules to preserve everywhere:

- **Deterministic metric ⇒ you may gate an absolute number. Noisy metric ⇒ ratio only** —
  self-normalizing, min-of-K (noise is one-sided), a per-stage floor, fail only on a
  *sustained* signal (both doublings). Wall-clock on a shared runner is never an absolute ceiling.
- **Allocation is primary** (deterministic, noise-free) **but blind to a pure scan.** Per-stage
  time is the secondary signal that sees a non-allocating O(n²). *Neither subsumes the other.*
- **Sample N, 2N, 4N and watch the ratio CLIMB** — a single doubling misses a quadratic still
  diluted by linear terms at small N.
- **Ledgers self-drain**: a known-superlinear entry must FAIL when accidentally fixed, so it
  can never rot into a skip-list.

The comprehensive set is just this discipline applied to everything currently invisible to it.

---

## 1. The coverage model: a bug is caught only at an intersection

A perf regression is caught **iff** some check simultaneously satisfies three axes:

```
  (a PASS that actually runs the bad code)
     × (an INPUT SHAPE that grows the offending dimension)
        × (a METRIC that can physically see the blow-up)
```

Every historical miss was a hole on one axis: #78 (metric — allocation could not see resolve's
scan), the O(modules²) family (pass — the single-file profiler never ran the multi-module
driver), and `gen_bindings`'s original form (shape — its bodies referenced no cross-symbol, so
the scan never fired). The audit below is organized by these three axes.

---

## 2. What is covered today

| | |
|---|---|
| **Gates that actually gate** | `test/diff_compiler_perf_scaling.sh` (alloc + per-stage time; front end + both backends + a multi-module *typecheck* arm), `test/diff_compiler_references_scaling.sh` (refindex op-count + a flat-query invariant), `test/diff_compiler_tmc_parity.sh` (LLVM vs Wasm TMC the same fns) |
| **Shapes** | bindings, match, listlit, nesting, xref, comments, manydefs, modules |
| **Graded stages** | parse, exhaust-guards, desugar, resolve, mark, typecheck, fmt, lint, lower, emit, wasm-emit |
| **Metrics** | GC allocation (deterministic), per-stage wall-time (min-of-K, heap-pinned), refindex op-count |
| **Wiring** | per-PR QUICK in `gates (types)`; nightly DEEP (`PERF_DEEP=1`) restores the N=16000 `xref`/`manydefs` bands; references-scaling in `tools`, tmc-parity in `backend` |
| **Reports but gates NOTHING** | `test/bench.sh` (unwired, macOS-only, prints RSS but never asserts) |

That is genuinely strong. The holes are specific.

---

## 3. The holes (verified first-hand), ranked

### PASS-axis holes — code that runs in production but no profiler measures

1. **⭐ Multi-module RESOLVE is entirely unmeasured — and structurally O(modules²).** (#881)
   `compiler/entries/profile_modules_main.mdk` runs load → desugar → mark → typecheck and
   **discards resolve**. Production runs `resolveModulesErrorsG` (`compiler/frontend/resolve.mdk`),
   which threads `known : List ModuleExports`, grows it `exp :: known`, and resolves every import
   via `findExports mid known` — a linear scan over a list that grows with the module count, plus
   `contains`-over-`expValues`. A star (one module importing N) or a re-export fan-out is O(N²) in
   one module — and *nothing in CI can see it*. The single biggest hole.

2. **DCE (`dceFilter`) is exercised but timed by nothing.** (#882 — ✅ CLOSED) `profile_main` now
   has its own `dce` stage (op arm reads 0 counted ops — no util.contains/lookupAssoc — so it
   self-skips the op floor and is graded on TIME/alloc). `compiler/ir/dce.mdk`.

3. **Elaboration is deliberately untimed.** (#882 — ✅ CLOSED) `profile_main` now has an
   `elaborate` stage over `elaborateDict` + the eight `install*` table-builders. It IS superlinear
   — but shape-specifically: `xref` (reference fan-in) reads op r1=3.31 r2=3.60 at N=4000→16000,
   while `manydefs` (decl count, no cross-refs) is linear — localizing the cost to
   `elaborateDict`'s reference-walk dict-routing, not the table-builds. Ledgered self-draining as
   `xref:elaborate` in `KNOWN_SLOW_OPS`; candidate #880 follow-up.

4. **`mangleUnits` is not exercised by either profiler at all.** (#882 — ✅ CLOSED) `profile_main`
   now has a `mangle` stage: it runs `mangleUnits` standalone over `(core, [("target", target)])`
   and DISCARDS the result (additive — `lower`/`emit` stay byte-unchanged). Reads LINEAR on every
   shape. `compiler/backend/private_mangle.mdk`.

5. **The multi-module path has no backend coverage.** (#881) `profile_modules_main` stops at
   typecheck — no `lower`/`emit`/`wasm-emit`. An O(modules²) in lowering or cross-module dict
   routing is unmeasured.

6. **The interpreter has zero perf coverage.** (#887) `compiler/eval/eval.mdk` (`medaka run`,
   doctests, repl) and `compiler/ir/core_ir_eval.mdk` (`cevalModules`) are covered for
   *correctness* only.

7. **The LSP request handlers have zero perf coverage.** (#887) `compiler/tools/lsp.mdk` — the
   GC-bound edit loop, the latency users feel most. (The refindex gate covers the *index builder*,
   not the handlers.)

### SHAPE-axis holes — passes that ARE measured, but no input grows the bad dimension (#883)

8. **Many distinct interfaces × many call sites.** `markVar`/`markInfix`
   (`compiler/frontend/marker.mdk`) do `contains x methods` for *every* var/op node, where
   `methods` is the flat list of *all* interface-method names — a textbook List-as-set quadratic.
   No shape touches it: `modules` has exactly one interface with one method, so its `methods` list
   is length ~1. Needs a shape that **co-scales** N interfaces *and* N call sites (see §5).

9. **Wide records.** No existing shape declares a record. In resolve, every field mention routes
   through `ownersOf fname (fieldOwners : List (String, String))` — a linear scan per field;
   record *update* pays it per updated field; `lookupRecordByName` is a prepend-list first-match.

10. **Nested / wide patterns.** `match` is N *flat* arms, bucketed to O(N log N). Nested patterns
    take the `usefulBranch`/`specializeCon` path (`compiler/frontend/exhaust.mdk`) that re-scans
    the matrix per constructor — the pre-optimization O(n²).

11. **Guards.** A guard-heavy group takes the `checkGroupCovered` branch that `match` never hits;
    `checkMatchRedundant` folds arms feeding all unguarded predecessors into `precMatrix`
    (O(arms²)).

*(Lower priority, distinct-but-low-risk: `deriving` fan-out, string-interpolation `++` chains,
N-statement `do` blocks. Parser op-chains are provably linear — `chainl1` is a tail left-fold.)*

### METRIC-axis holes — blow-ups no current metric can see

13. **No deterministic per-stage OP-COUNT.** (#884) Today a non-allocating scan is caught only by
    *time*, which is why the gate needs heap-pinning, min-of-K, a 200 ms floor, and larger N — and
    still cannot grade the small stages (`mark`, `desugar`, `exhaust-guards` skip under the floor
    on every shape). `test/diff_compiler_references_scaling.sh` proves the better way: a
    deterministic op-counter is noise-free like allocation *and* sees a pure scan. The highest-
    leverage addition (see §6), and it relates to the cardinality-observability work in #542.

14. **No IR-size / prelude-independence bound.** (#885) CI's real bottleneck is **clang**, and the
    "9-line program → 32,896 lines of IR (271/272 fns prelude)" bloat class is guarded only by
    `test/diff_compiler_dispatch_shape.sh` (a *shape* pin), not a *size* bound. IR line count is
    deterministic ⇒ gateable as an absolute ceiling + a linear-in-live-program-size assertion.

15. **No self-compile-time tripwire and no peak-RSS gate.** `test/selfcompile_fixpoint.sh` is
    byte-identical correctness only — never timed. `test/bench.sh` prints RSS but asserts nothing
    and isn't wired. Both are noisy ⇒ ratio/min-of-K with generous headroom, nightly only.

---

## 4. Pass-axis additions

**P1 — Measure multi-module resolve (+ backend).** (#881) Add a `resolve` stage to
`profile_modules_main` (run `resolveModulesErrorsG` and time it), and optionally `lower`/`emit` so
the multi-module backend is covered. Then add the shapes in §5.

**P2 — Time DCE, elaboration, and mangle.** (#882 — ✅ DONE) `profile_main` now emits `elaborate`,
`dce`, and `mangle` stages (the `mangleUnits` call is standalone + discarded, so `lower`/`emit` are
byte-unchanged), all enrolled in `TIME_STAGES` and `OP_STAGES`. Zero new profiler invocations — the
new stages ride the runs already happening. Surfaced one pre-existing superlinear (`xref:elaborate`,
op), ledgered self-draining. Also folded in the #914 cleanup (stale `emitPhaseA` comment/orphan).

**P3 — An eval scaling gate (nightly).** (#887) New profiler over `eval.mdk`/`cevalModules`, graded
on per-stage time (+ op-count). Shapes: deep tail recursion, a big-`match` interpreted hot loop,
list/map builders.

**P4 — An LSP latency gate (nightly).** (#887) Reuse the refindex op-count model: assert that
hover/completion/definition on a growing file stays **flat** (O(edited-region), not O(project)) —
the same flat-query invariant `references_scaling` already uses.

---

## 5. Shape-axis additions (new `gen_*` in the scaling gate, #883)

**The critical design rule for two-dimensional bugs:** a shape must **co-scale the two dimensions
that multiply**, or the N→2N method sees only a linear slice of an O(a×b) blow-up.

| new shape | grows | stresses |
|---|---|---|
| `manyifaces` | N interfaces **and** N call sites *together* | `mark`'s `contains x methods` |
| `widerecords` | N fields, accessed/updated N times | resolve `ownersOf`, `lookupRecordByName` |
| `starimports` | 1 module importing N (and N→1) | `findExports` over `List ModuleExports` (needs P1) |
| `reexports` | N-deep re-export fan-out | `reexportBindings`/`buildExports` (needs P1) |
| `nestpat` | one N-deep / N-wide pattern | `usefulBranch`/`specializeCon` rescan |
| `guards` | N guard clauses in one group | `checkGroupCovered`, `checkMatchRedundant` |

Every new shape obeys the existing corpus discipline: a real `main` that roots the decls through
DCE, and — for multi-module — a fixture that resolves 0-diagnostic (a resolve-broken fixture
measures a *different* quadratic).

---

## 6. Metric-axis additions (highest leverage first)

**M1 — Deterministic per-stage op-count.** (#884) The `[perf]` line format in
`compiler/support/timer.mdk` already reserves an `ops` column; wire a real per-stage operation
counter (List-scan steps, map get/set, `contains` calls) the way `refindex.riOps` already does,
and have the gate grade its ratio. Payoff: noise-free, sees non-allocating scans, **needs no floor
/ no min-of-K / no heap-pin**, and therefore **grades the small stages `mark`/`desugar`/
`exhaust-guards` that time physically cannot.** Recommend building this first — several shape
additions depend on it to be gradeable at small N.

**M2 — IR-size gate.** (#885) A deterministic gate asserting (a) a fixed tiny program emits under
a ceiling of IR lines, and (b) emitted IR lines scale ~linearly with *live* (post-DCE) program
size. Catches the clang-bound bloat class that the O(n²)-time gate structurally cannot.

**M3 — Self-compile time + peak-RSS tripwire (nightly, ratio-only).** Wrap a fixed workload in
min-of-K timing with generous headroom (e.g. fail on >1.5× a committed baseline), and assert peak
RSS the same way. Noisy ⇒ nightly, ratio/min-of-K, wide margins — never a per-PR absolute ceiling.

---

## 7. Wiring & cost

- **Per-PR (QUICK):** P1 (resolve — cheap and the biggest hole), P2, the six §5 shapes at small N,
  M1 (op-count is cheap — one run, no min-of-K), M2. All deterministic or op-count based, so they
  add little wall-clock. Keep them in `gates (types)` or spread to a shard with room (schedule by
  cost, not theme).
- **Nightly (DEEP):** P3 (eval), P4 (LSP), M3, the large-N bands, and the low-risk §5 shapes.
- Any new `test/diff_compiler_*.sh` must be **enrolled in a shard pattern** or it silently never
  runs (`test/diff_compiler_ci_shard_coverage.sh` enforces this) — and must print `checked N` with
  `N==0` a hard failure.

---

## 8. The meta-check: make coverage self-auditing so this map can't rot (#886)

The deepest fix isn't the fixtures — it's making *coverage itself* a derived, self-draining
property, in the same spirit as `test/diff_compiler_ci_shard_coverage.sh` and the perf ledgers:

- **A pass-coverage census.** Enumerate the pipeline stages the driver actually runs; assert every
  one is either graded by some perf shape **or** carries an explicit `-- perf: linear by inspection
  (<why>)` waiver. A new pass with neither FAILS the census — so the "a whole pass is unmeasured"
  hole (how the modules family and multi-module resolve happened) cannot recur silently.
- **A `backend_graded`-style non-zero assertion per axis.** The gate already refuses to exit 0
  having graded no backend stage. Generalize: refuse to exit 0 if the resolve arm, the eval arm, or
  the op-count arm graded nothing — each blind spot names itself.
- **Every new shape must be seen to fail.** Break the target pass on purpose and watch the gate
  name the `file:line`; a gate never observed red is indistinguishable from one that can't go red.

---

## 9. Priority order (what to build, in sequence)

1. **M1 (deterministic op-count, #884)** — unblocks small-stage grading and simplifies the rest.
2. **P1 (multi-module resolve, #881)** — the biggest single hole; a known-quadratic pass off the map.
3. **§5 shapes** `manyifaces`, `widerecords`, `starimports` (#883) — the concrete List-as-set
   quadratics with no shape today.
4. **P2 (DCE/elaborate/mangle timers, #882)** — cheap, closes three unmeasured passes.
5. **M2 (IR-size, #885)** — guards the clang-bound bottleneck the time gate can't see.
6. **§8 pass-coverage census (#886)** — makes the whole thing self-draining.
7. **Nightly:** P3/P4 (eval, LSP, #887), M3, remaining shapes.
