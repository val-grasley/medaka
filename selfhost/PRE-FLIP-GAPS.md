# PRE-FLIP-GAPS.md — outstanding native-compiler items to close before the canonicalization milestone flip

**Status: the milestone flip (make native `medaka` canonical, retire OCaml) is GATED on
this punch list.** Produced by a 3-agent verified gap audit (2026-06-11), each item
**reproduced on current main** (`a6a95ce`-era). TRMC + all prior dispatch gaps are done;
these are the residual soundness + capability gaps the flip must not ship with.

> **CRITICAL META (held all session):** the gap docs (EMITTER-GAPS / COVERAGE /
> TYPECHECK-AUDIT / DISPATCH-GAPS-SCOPE) are **stale** — every gap mispredicted on
> contact this week (already-closed items marked open; documented root causes wrong 5×).
> **DIAGNOSE-FIRST: reproduce each item on current main before trusting any root-cause
> claim here or in the source docs.** The fix locations below are audit hypotheses, not
> verified roots.

## How to verify any item
- Oracle (reference): `./_build/default/bin/main.exe run <f>` and `… check <f>`.
- Native build path: `./_build/default/bin/main.exe build <f> -o <o> && <o>`.
- Selfhost typecheck path: `… run selfhost/check_main.mdk stdlib/runtime.mdk stdlib/core.mdk <f>`.
- Stdlib-method / typed cases: the typed emit path (`selfhost/llvm_emit_typed_main.mdk` + runtime + core).
- Native CLI: `selfhost/medaka_cli.mdk` (the canonical target) uses the **self-hosted**
  parser/typecheck/emit for every subcommand — its behavior is what users hit post-flip.

## Standard gates for any fix
`dune build --root .` clean · the item's repro (interp == native, before→after) ·
`diff_selfhost_llvm`/`_modules`/`_typed` (172/9/37) + `diff_selfhost_build` byte-identical ·
**`selfcompile_fixpoint` C3a/C3b YES (MANDATORY for emitter changes)** · `diff_native_cli` 54 ·
emitter/typecheck-graph changes **leave the seed STALE** (orchestrator re-mints at the
checkpoint; do NOT re-mint per-fix).

---

## TIER 1 — SOUNDNESS BLOCKERS (native gives a wrong/crashing answer for a VALID program, or accepts an INVALID one). MUST close before flip.

### G1 — `build`/`run`/`check` do not gate on typecheck  *(the keystone; silent miscompile)*
**Repro:** `main = println (1 + "x")` → `medaka build` **emits + runs, prints garbage**
(`2156693489`); both `check` and `build` **exit 0** while a type error exists.
**Root (audit):** the native CLI drivers (`selfhost/medaka_cli.mdk` `runBuildCmd`/`runRunCmd`/
`runCheckCmd`; `selfhost/build_cmd.mdk`) route-stamp via `elaborateModules` but **never
surface accumulated `typeErrors`** — `build` emits regardless; `check` reports in-band but
exit 0. (The OCaml `bin/main.ml` check ALSO exits 0 — confirm whether to fix both or just
the canonical native driver.)
**Fix:** make `build` and `run` run the selfhost typechecker to a **hard error before
emit/eval** (abort + non-zero exit on any `typeError`); make `check` **exit non-zero** when
diagnostics exist (CI `$?` parity). Driver-level, not deep typecheck.
**Note:** G1 alone does NOT subsume G2 — G2 is the typechecker itself being wrong.

### G2 — typechecker FALSE-ACCEPTS non-Num arithmetic (D3)
**Repro:** selfhost `check` **accepts** `"a" - "b"` / `True - False` / `"a" * "b"`; OCaml
rejects (`No impl of Num for String`).
**Root (audit):** the selfhost arithmetic operators (`-`,`*`,…) don't record the `Num`
obligation — analogous to the Gap-G fix that made `==`/`<` carry `Eq`/`Ord`. The
operator→method desugar/typecheck must thread the `Num` constraint so a non-Num receiver
is rejected. **`harden-typechecker` skill.** `selfhost/typecheck.mdk` (+ mirror the
operator-constraint logic; check `builtins`/the binop typing path).

### G3 — `Num a =>` arithmetic at Float — SILENT miscompile  *(scariest — wrong float, no crash)*
**Repro:** `double : Num a => a -> a ; double x = x + x ; double 2.5` → interp `5.`, native
**`-4.86e-63`** (garbage). `x * x` at Float → **SIGSEGV 139**. Both fine at **Int**;
concrete `Float -> Float` fine.
**Root (audit, hypothesis):** Gap C4 — arg-tag dispatch of the **dict-passed `+`/`*` on a
primitive Float receiver** (primitives carry no runtime cell tag for arg-tag dispatch).
**This is the same class as the max/min-over-primitive-Ord gap (closed this session as #11,
`fdcc95b`)** — route the concrete primitive impl from the monomorphic caller / thread the
Num dict to a primitive-typed dispatch. Diagnose against #11's fix as the precedent.
`selfhost/llvm_emit.mdk` + dispatch/`typecheck.mdk`. Route-fragile, Opus + oversight.

### G4 — two-level nested instance dict — SIGSEGV
**Repro:** `data Box a = Box a ; impl Eq (Box a) requires Eq a where eq (Box x)(Box y)=x==y`
over `Box [1,2,3]` (poly field instantiated at `List`) → native crashes; oracle `True`.
`Box (List a)` fixed-field and `Box (Box Int)` WORK; the poly-field-over-List two-level case
does not.
**Root (audit):** `implRequiresRoutesRec` stamps a **flat `RKey "List" []`** when the inner
element stays abstract (`RNone`) → null inner dict. **Same machinery as #13 (`5ddfbf5`,
which closed Map-impl + #21 one-level via `argImplRequiresRoutesRec`)** — extend the nested
`requires`-route propagation one level deeper. Diagnose against #13's fix. `selfhost/typecheck.mdk`.
**Siblings (doc-confirmed, `build` not directly exercised in the audit — VERIFY first):**
- **C7-native:** the native backend keys impls by head tycon only → `Def (Pair Int Bool)` vs
  `(Pair Bool Int)` mis-dispatch in `build`. `selfhost/TYPECHECK-AUDIT.md` §C7.
- **D4:** `RHeadKey` route absent in selfhost — non-ground headed dict-apps degrade to
  arg-tag/RNone; latent regression risk when the OCaml oracle retires.

---

## TIER 2 — CAPABILITY GAPS (a VALID construct can't build, but fails LOUD). Close before flip (user wants all closed).

### G5 — refutable pattern-guards
**Repro:** `match … x if Just y <- e => …` → native clean-panics `refutable pattern guard …
not yet lowered`; oracle runs it. (Irrefutable `x <- e` guards + match-arm `if` guards WORK
— CTGuard closed.) `selfhost/llvm_emit.mdk` `emitGuardedArm`/`emitGuardChain` — add the
refutable `CGBind` case (test + branch to next clause on match-failure). See AGENTS.md
gotcha + `test/llvm_fixtures/guard_match_*`.

### G6 — range patterns in `match`
**Repro:** `match n { 1..9 => "digit" ; _ => "big" }` / `'a'..='z'` → parse + typecheck OK,
then **emitter panic** `selfhost/llvm_emit.mdk:~494 unsupported pattern … PRng`. `bindPattern`
PRng + synthesized range-comparison guard (per `CONSTRUCT-COVERAGE.md` A2/A3 prose). Emit-only.

### G7 — `foldMap` / `empty` (RNone Monoid-default seed)
**Repro:** `foldMap (x => [x, x]) [1,2,3]` → native clean-panics; oracle `[1,1,2,2,3,3]`. A
common stdlib shape (Foldable default-method dispatch where the Monoid `empty` seed has no
concrete tag → RNone). Same default-method-dispatch family as the closed gaps; diagnose its
route. `selfhost/typecheck.mdk` + emit.

---

## TIER 3 — NARROW (parser false-rejects + a known limit). Close for completeness.

### G8 — selfhost parser false-rejects (vs OCaml accepts)
- **Indented multi-line `let … in` clause body:** `f x =⏎  let go n = … in go x` →
  `parser.mdk:2704 parse error`; single-line `f x = let … in …` parses. (PLAN "Known parser
  gaps" / OBS2 / T2.)
- **Negative range-pattern bound** `-1..1` in a match → rejected (`intBoundFor` only matches
  `TInt`, not `MINUS INT`). Non-negative ranges parse.
`selfhost/parser.mdk`. UX footguns; the bootstrap corpus avoids both.

### G9 — Float-literal arithmetic (KNOWN LIMIT, not a divergence)
**Repro:** `sum [1.0, 2.0, 3.0]` / Float-literal computations → **both** oracle and selfhost
reject (`Int vs Float`): the selfhost typechecker monomorphizes int literals to `Int`
(`litType (LInt _) = TCon "Int"`), so a Float-literal list doesn't typecheck. **Consistent
across both** (not a soundness divergence) but a real language limitation: no Float `sum`.
Closing it = Num-polymorphic numeric literals (a deeper typecheck change). **Larger; consider
deferring or scoping separately** — confirm with the user whether in-scope for the flip.

---

## Recommended execution order
1. **G1** (driver typecheck-gate) — keystone; closes the build-no-TC silent-miscompile class
   and gives every other typecheck-caught error a hard exit. Driver-level.
2. **G3** (Num/Float silent miscompile) — scariest; diagnose against #11's primitive-Ord fix.
3. **G2** (D3 non-Num false-accept) — typechecker hole; `harden-typechecker`.
4. **G4** (two-level dict) + verify C7-native/D4 — diagnose against #13's nested-requires fix.
5. **G5/G6/G7** (loud capability gaps) — emit-mostly, independent.
6. **G8** (parser) + decide **G9** (Float literals — likely defer/scope separately).

Each is independently landable + gated; run them as separate diagnose-first agents (route-
fragile ones Opus + oversight), verify empirically, merge to local main, batch a seed re-mint
at the checkpoint.

## Stale-doc reconciliations to apply while closing out (already fixed — don't re-investigate)
- `EMITTER-GAPS.md` TOTAL row: "2 residual max/min" → **0** (closed this session).
- `CONSTRUCT-COVERAGE.md`: Gap C1 (tuple debug), F1 (generic Display param), G (derived-Ord
  `<` native), C2 (well-typed poly debug), C4-at-Int — all **pass** now; Gap Group A rows
  A8/A9/A11 are NOT selfhost-only (both parsers behave identically). Header already admits lag.
- Error-path audit: **all 6 BLOCKERs + 7 MAJORs closed** (B5 + R2 marked "in flight" in PLAN
  are CLOSED; E10 eager-vs-lazy resolved-by-decision). The error-path retirement-gate is clear.
- `TYPECHECK-AUDIT.md`: L1 closed (mooted by mangling `332ef41`). Remaining tail = C7-native,
  D3 (=G2), D4 (the soundness items above).
- `DISPATCH-GAPS-SCOPE.md`: #50/#54/#55/#21-one-level all CLOSED (verified).

## After this punch list — the flip itself (separate, see PLAN.md gated-milestone + memory)
Make native `medaka` the default build; **re-root the differential gates on a hybrid oracle**
as `lib/` freezes (the biggest design piece — the gates currently use the OCaml `eval_probe`
oracle); doc sweep. Then the confidence-gated `lib/` removal after a soak period
([[retirement-is-not-removal]]). The Stage-4 tooling tail (coverage/bench port, #28
test-completeness, #61 args-slicing) and import-rename (#8) are separate, lower-priority.
