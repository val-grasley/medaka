# Workstream: TYPECHECK

**Owns:** the consolidation arc for `compiler/types/typecheck.mdk` — dict-elaboration dedupe, the
entailment engine, driver/entry-point unification, state discipline, and the file's scaling
liabilities.
**Touches:** `compiler/types/typecheck.mdk` (almost exclusively), `compiler/driver/diagnostics.mdk`,
`test/diff_compiler_perf_scaling.sh`.

```sh
gh issue list --label "ws:typecheck" --state open   # the backlog. #160 is the tracking issue + DAG.
```

**Load the `harden-typechecker` skill before you start.** It carries the API surface (the
`pushTypeError` family, level bracketing, the value restriction, the two-entry-point table, the
coherence prelude-exclusion rule). This file carries only what the consolidation arc adds on top.

---

## Why this workstream exists

The HM core (levels + path-compressed union-find + value restriction) is excellent — do not
"improve" it. The problem is the layers around it: at the 2026-06-14 `compiler/ARCH-REVIEW.md`
deep-dive the file was 6,916 lines / 49 module-level `Ref`s; at `db33eeab` (2026-07-15) it is
13,717 lines / 97 `Ref`s. The growth is **parallel near-copies** — two orchestration bodies, five
final-check tails, four fold-over-modules loops, six impl-resolution paths, four operator-obligation
seams, binop/unop twins — each pair kept in agreement by nothing but manual mirror discipline.
That is the repo's #1 recurring bug shape (P0-9, the 2026-06-14 imported-module bug, #59).

The target shape is **already specified**: `docs/spec/DICT-SEMANTICS.md` (§3: entailment is ONE
function; §7: the single-evaluator law) and `compiler/ARCH-REVIEW.md` (consolidate + unify; the
HM-core/dispatch **file split was evaluated and rejected** — dispatch state is read at `infer`
depth across a 25-arm walk; do not relitigate it). This workstream is convergence to those two
documents, in gate-verified steps.

## The duplicate-family map (grep anchors, not line numbers)

| Family | Members |
|---|---|
| Orchestration bodies | `checkProgramSeededSplit` ∥ `checkModuleFullImpl` (#80) |
| Final-check tails ×5 | `checkToLines` / `checkToLinesWithRuntime` / `checkErrorsWithRuntime` / `checkProgramDiags` / `checkModuleFullDiags` (#152) |
| Module fold loops ×4 | `checkModulesGo` / `checkModulesDiagsGo` / `checkModulesEntryFullGo` / `elabModulesGo` (#151) |
| Impl resolution ×6 | `resolveSite`, `resolveOpSite` (the #145-unified binop/unop resolver), `routeOfMono`/`routeOfMonoTop`/`routeOfMonoEncl`, `findImplEntry`, arg-position mirrors (#156) |
| Structural matchers ×4 | `cohOverlap`'s unifier, `cohSubsumes`, `tySubsumes`, `matchTyMono` (#156 stage 1) |
| Operator seams ×4 | `recordNumObligation`/`recordEqObligation`/`recordOrdObligation`/`recordSemigroupObligation` + guards + predicates (#146) |
| Binop/unop twins ×4 pairs | ✅ LANDED (#145): collapsed into one `isBinop`-flagged set — `resolveOpSites`/`resolveOpSite`/`opDictVarOf`/`stampOpRoute` |

---

## ⚠️ THE TRAPS — read before your first PR here

### 1. The bar is BYTE-IDENTICAL, and two gates are non-negotiable
Every consolidation PR must show byte-identical goldens for the gates its diff touches, **plus**
`test/selfcompile_fixpoint.sh` (C3a/C3b YES) **plus** `test/typecheck_compiler_source.sh`. The last
one is not optional and not redundant: **the build does not gate on type errors** — an ill-typed
compiler builds green through all 80+ gates. It is also the *only* thing that catches a stale
caller after a signature change. The ONE deliberate exception to byte-identical is #157
(`emitArgStampPasses` retirement), where golden churn is expected, designed in advance, and
blessed by named path.

### 2. ORDER IS SEMANTICS — the map-ification trap
The `List` scans you are replacing are not incidental: reverse-declaration-order scanning,
first-match lookup, and prepend-wins are **oracle-matching behavior**. They decide which coherence
conflict is reported first, which impl a collision site keys, and which cross-module arity wins.
An `OrdMap` rewrite that changes any of that will show up as golden drift in
`diff_compiler_typecheck_errors` / `diff_compiler_check*` — treat that drift as "I changed
semantics," never as "goldens need a refresh." Buckets must preserve the order the scan had.

### 3. The compiler's own source is in the snapshot corpus
Any edit to `typecheck.mdk` moves its own golden. **Bless it, by name, in the same commit** — or
`main` goes red and the next agent is forced to rubber-stamp your regression.

### 4. Mirror discipline is LIVE until the unification issues land
Until #151/#152/#80 merge, a change to one copy of a duplicated family is **silently absent** from
the others — and the miss is path-specific (LSP-only, emit-only), the hardest kind to notice.
Before pushing, grep every member of the family you touched (table above) and patch all of them.

### 5. Coherence must NEVER see seeded impls
`checkCoherence` runs over **user decls only** (`coherenceUserDecls`) — a user impl deliberately
overrides a seeded prelude impl. Feed the unified final-checks helper (#152) the seeded set and it
false-positives on the stdlib itself, breaking dozens of gates at once. Pass the decls explicitly;
no defaulting to the whole program.

### 6. Keep hot helpers monomorphic and short-circuiting
Do NOT "clean up" a hot scan by delegating to a prelude Foldable method — measured **+56%
self-compile** (`compiler/AGENTS.md`). The consolidated helpers in #145/#146 must stay
monomorphic `||`/`&&` loops or keyed lookups.

### 7. resetState survivors are load-bearing — clearing is not a cleanup
~37 Refs deliberately survive `resetState` (cross-module accumulators, per-module reseed tables,
driver mode flags). Clearing one "for hygiene" reproduces the Phase-134 dropped-dict mode. The
cross-module six get exactly ONE lifecycle owner via #143; everything else waits for #158's
two-record split (a per-run record vs a cross-run record — #158 mints the actual names; they do
not exist yet, so don't grep for them), where survive-vs-clear becomes type structure.
`typeErrorsSticky` stays OUTSIDE any bundle, permanently — it is sound *because* it lives outside
resets (ARCH-REVIEW hazard #1).

### 8. Effect rows are transparent in matching ON PURPOSE
Coherence, subsumption, and dispatch matching all ignore/strip `TEff` rows. That is the
single-meaning law (`docs/spec/EFFECTS-SEMANTICS.md` §8 — effects erase; they never participate in
dispatch), not an oversight. Do not "fix" it while unifying the matchers in #156.

### 9. Measurement discipline for the perf items
The scans this workstream removes are **pure traversals — they allocate nothing**, so the
allocation grade is physically blind to them; only per-stage TIME can see them (the #115 lesson).
Pin `GC_INITIAL_HEAP_SIZE`, take min-of-K, grade per stage — and remember `whenL False (…)` is NOT
a stub in a strict language; to stub a call, delete it. Full doctrine: `.claude/workstreams/PERF.md`
and the `perf-hunt` skill.

### 10. One compiler-source PR in flight; stage commits by path
Goldens are re-cut from source, never text-merged — two typecheck branches always fight over the
same golden files. And never `git add -A` (see `.claude/workstreams/HARNESS.md`).

---

## Sequencing

The DAG lives in **#160** (tracking). Shape: Phase 0 defects + the perf-scaling shapes (#143/#144/
#153) → Phase 1 mechanical dedupe + map-ification (#145–#150) → Phase 2 driver unification
(#151 → #152 → #80, then #154/#155) → Phase 3 entailment engine #156, then single-mode elaboration
#157 → Phase 4 state + diagnostics records (#158, #159). Phase boundaries are dependency edges,
not suggestions: #158 designed before #157 lands would be designed around a flag that is about to
vanish (ARCH-REVIEW made exactly this sequencing mistake once).

## Reading list

- `docs/spec/DICT-SEMANTICS.md` — the target semantics for #156/#157. §10 maps defect classes to clauses.
- `compiler/ARCH-REVIEW.md` — PASS 2 is the prior deep-dive; its file-split rejection and
  DispatchState design still govern #158.
- `compiler/TYPECHECK-AUDIT.md` — the 2026-06-09 oracle-diff audit; its executive-summary root
  pattern ("semantics keyed by incidental identity") is what #156 finally retires.
- `docs/spec/SHADOW-SEMANTICS.md` + `docs/spec/EFFECTS-SEMANTICS.md` — the other two behavior
  contracts this file implements; their gates are part of the byte-identical bar.
- `compiler/AGENTS.md` — the perf ground rules; `.claude/workstreams/PERF.md` — the measurement traps.
