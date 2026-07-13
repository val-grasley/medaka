# PRE-FLIP-GAPS.md — outstanding native-compiler items to close before the canonicalization milestone flip

**Status:** IMPLEMENTED — all 9 items closed `0836d1e`, 2026-06-12; milestone flip done
(native `medaka` is canonical). The "How to verify any item" / "Standard gates" sections
below are STALE and point at a dead OCaml oracle binary (`./_build/default/bin/main.exe`,
removed 2026-06-26) and a dead `dune build` instruction — struck in place below
(2026-07-13 doc pass). To verify a fix today: reproduce the repro fixture on the current
native `medaka`, and run the equivalent `test/diff_compiler_*.sh` gate (native output vs
captured goldens, not a live OCaml comparison).

**Status: ✅ ALL 9 ITEMS CLOSED (2026-06-12).** The punch-list gate on the milestone flip
(make native `medaka` canonical, retire OCaml) is **clear**. Each item was reproduced on
current main, diagnosed empirically (the audit's root-cause hypotheses were wrong on
several — see notes), fixed, and verified native==interp with the full differential suite +
`selfcompile_fixpoint` C3a/C3b. Seed re-minted at this checkpoint (`0836d1e`);
`bootstrap_from_seed` PASS (native compiler built OCaml-free, seed byte-identical).

| Gap | What | Commit | Notes |
|-----|------|--------|-------|
| G1 | typecheck-gate build/run/check (both drivers) | `1ca4fb7` | driver-level; OCaml `check` already gated |
| G2 | typechecker reject non-Num arithmetic | `3104031` | hooked existing `checkImplObligations`; `++` kept separate; gated on `numIfaceRegistered` |
| G3 | `Num a =>` arithmetic at Float | `8752c60` | **NOT #11's class** — `emitArith` picked int IR from static LTy; fixed via runtime `@mdk_num_*` tag-dispatch + `LTNum` |
| G4 | user-ADT `requires` instance dict | `f5c658b` | **broader than documented** — base-case `Box Int` crashed + `Box(Box Int)` silently wrong; 2 causes (abstract-operand RDict route + #21 full-table threading); covers C7-native/D4 (element dicts threaded by value) |
| G5 | refutable pattern-guards | `78ebb10` | `emitRefutMatch` arm |
| G6 | range patterns in match | `78ebb10` | tagged-word range compare matches `eval.mdk` |
| G7 | method-level dicts into default bodies | `4fb1160` | general fix; **also closes Ord/`max`/`min` default-method family**; foldMap List+String share one define |
| G8 | compiler parser false-rejects | `2bc48a1` | indented `let…in` body + negative range bounds |
| G9 | Float `sum`/`product` (targeted) | `fa0bbe9` | `fromInt` point-ful seed + native arith-section `LTNum`; full Num-poly literals DEFERRED post-flip |

**Deferred (post-flip, not flip gates):**
- **Full Num-polymorphic integer literals** (`litType (LInt) → Num a` + defaulting, both compilers) — the larger version of G9; G9 closed the practical Float-numeric gap via `fromInt` seeds instead.
- **Unconstrained-fn `fromInt`/operator-section RNone** (surfaced during G9): a return-position `fromInt`/section in a fn with NO `Num a =>` sig still hits the arg-tag gap, and auto-printing a polymorphic-`a` indirect-call result mistypes print. Narrow, non-soundness; dodged by the `Num a =>` sig on stdlib `sum`/`product`.

> **META that held all session (kept as a record):** the gap docs (EMITTER-GAPS / COVERAGE /
> TYPECHECK-AUDIT / DISPATCH-GAPS-SCOPE) were **stale** — root causes mispredicted repeatedly
> (G3 ≠ #11, G4 broader than documented, G7 bigger than "add a route"). DIAGNOSE-FIRST paid off
> every time. The per-gap sections below are the ORIGINAL audit hypotheses (historical; several
> were wrong — see the result table above for what each actually was).

## How to verify any item (HISTORICAL — see the STRUCK note above for the current method)
- ~~Oracle (reference): `./_build/default/bin/main.exe run <f>` and `… check <f>`.~~ Dead —
  OCaml removed 2026-06-26; use `./medaka run <f>` / `./medaka check <f>` and compare
  against a captured golden instead.
- Native build path: `./medaka build <f> -o <o> && <o>`.
- Selfhost typecheck path: `… run compiler/entries/check_main.mdk stdlib/runtime.mdk stdlib/core.mdk <f>`.
- Stdlib-method / typed cases: the typed emit path (`compiler/entries/llvm_emit_typed_main.mdk` + runtime + core).
- Native CLI: `compiler/driver/medaka_cli.mdk` (the canonical target) uses the **self-hosted**
  parser/typecheck/emit for every subcommand — its behavior is what users hit post-flip.

## Standard gates for any fix (HISTORICAL — `dune build` is dead; see AGENTS.md's `make preflight`)
~~`dune build --root .` clean~~ · the item's repro (interp == native, before→after) ·
`diff_compiler_llvm`/`_modules`/`_typed` (172/9/37) + `diff_compiler_build` byte-identical ·
**`selfcompile_fixpoint` C3a/C3b YES (MANDATORY for emitter changes)** · `diff_native_cli` 54 ·
emitter/typecheck-graph changes **leave the seed STALE** (orchestrator re-mints at the
checkpoint; do NOT re-mint per-fix).

---

## TIER 1 — SOUNDNESS BLOCKERS (native gives a wrong/crashing answer for a VALID program, or accepts an INVALID one). MUST close before flip.

### G1 — `build`/`run`/`check` do not gate on typecheck — ✅ CLOSED 2026-06-12 (`1ca4fb7`)
**Repro:** `main = println (1 + "x")` → `medaka build` **emits + runs, prints garbage**
(`2156693489`); both `check` and `build` **exit 0** while a type error exists.
**Root (audit):** the native CLI drivers (`compiler/medaka_cli.mdk` `runBuildCmd`/`runRunCmd`/
`runCheckCmd`; `compiler/build_cmd.mdk`) route-stamp via `elaborateModules` but **never
surface accumulated `typeErrors`** — `build` emits regardless; `check` reports in-band but
exit 0. (The OCaml `bin/main.ml` check ALSO exits 0 — confirm whether to fix both or just
the canonical native driver.)
**Fix:** make `build` and `run` run the compiler typechecker to a **hard error before
emit/eval** (abort + non-zero exit on any `typeError`); make `check` **exit non-zero** when
diagnostics exist (CI `$?` parity). Driver-level, not deep typecheck.
**Note:** G1 alone does NOT subsume G2 — G2 is the typechecker itself being wrong.

### G2 — typechecker FALSE-ACCEPTS non-Num arithmetic — ✅ CLOSED 2026-06-12 (`3104031`)
**Repro:** compiler `check` **accepts** `"a" - "b"` / `True - False` / `"a" * "b"`; OCaml
rejects (`No impl of Num for String`).
**Root (audit):** the compiler arithmetic operators (`-`,`*`,…) don't record the `Num`
obligation — analogous to the Gap-G fix that made `==`/`<` carry `Eq`/`Ord`. The
operator→method desugar/typecheck must thread the `Num` constraint so a non-Num receiver
is rejected. **`harden-typechecker` skill.** `compiler/typecheck.mdk` (+ mirror the
operator-constraint logic; check `builtins`/the binop typing path).

### G3 — `Num a =>` arithmetic at Float — ✅ CLOSED 2026-06-12 (`8752c60`)
**Repro:** `double : Num a => a -> a ; double x = x + x ; double 2.5` → interp `5.`, native
**`-4.86e-63`** (garbage). `x * x` at Float → **SIGSEGV 139**. Both fine at **Int**;
concrete `Float -> Float` fine.
**Root (audit, hypothesis):** Gap C4 — arg-tag dispatch of the **dict-passed `+`/`*` on a
primitive Float receiver** (primitives carry no runtime cell tag for arg-tag dispatch).
**This is the same class as the max/min-over-primitive-Ord gap (closed this session as #11,
`fdcc95b`)** — route the concrete primitive impl from the monomorphic caller / thread the
Num dict to a primitive-typed dispatch. Diagnose against #11's fix as the precedent.
`compiler/llvm_emit.mdk` + dispatch/`typecheck.mdk`. Route-fragile, Opus + oversight.

### G4 — user-ADT `requires` instance dict — ✅ CLOSED 2026-06-12 (`f5c658b`; broader than documented)
**Repro:** `data Box a = Box a ; impl Eq (Box a) requires Eq a where eq (Box x)(Box y)=x==y`
over `Box [1,2,3]` (poly field instantiated at `List`) → native crashes; oracle `True`.
`Box (List a)` fixed-field and `Box (Box Int)` WORK; the poly-field-over-List two-level case
does not.
**Root (audit):** `implRequiresRoutesRec` stamps a **flat `RKey "List" []`** when the inner
element stays abstract (`RNone`) → null inner dict. **Same machinery as #13 (`5ddfbf5`,
which closed Map-impl + #21 one-level via `argImplRequiresRoutesRec`)** — extend the nested
`requires`-route propagation one level deeper. Diagnose against #13's fix. `compiler/typecheck.mdk`.
**Siblings (doc-confirmed, `build` not directly exercised in the audit — VERIFY first):**
- **C7-native:** the native backend keys impls by head tycon only → `Def (Pair Int Bool)` vs
  `(Pair Bool Int)` mis-dispatch in `build`. `compiler/TYPECHECK-AUDIT.md` §C7.
- **D4:** `RHeadKey` route absent in compiler — non-ground headed dict-apps degrade to
  arg-tag/RNone; latent regression risk when the OCaml oracle retires.

---

## TIER 2 — CAPABILITY GAPS (a VALID construct can't build, but fails LOUD). Close before flip (user wants all closed).

### G5 — refutable pattern-guards — ✅ CLOSED 2026-06-12
**Repro:** `match … x if Just y <- e => …` → native clean-panicked `refutable pattern guard …
not yet lowered`; oracle ran it. (Irrefutable `x <- e` guards + match-arm `if` guards WORK
— CTGuard closed.) **Fix:** `compiler/llvm_emit.mdk` new `emitRefutMatch` (refutable pattern
test + `br failL` on mismatch, binds vars + falls through on match); `emitGuardChain`'s
`CGBind` arm routes through it; `allGuardsEmittable` now accepts all `CGBind`. Native `f (Box w
<- x)`→`w`, fallthrough on mismatch→next clause; irrefutable + `if` guards preserved. Fixpoint
C3a/C3b hold. Fixture `test/llvm_fixtures/guard_refut_ctor.mdk`.

### G6 — range patterns in `match` — ✅ CLOSED 2026-06-12
**Repro:** `match n { 1..9 => "digit" ; _ => "big" }` / `'a'..='z'` → parse + typecheck OK,
then **emitter panicked** `compiler/llvm_emit.mdk:~494 unsupported pattern … PRng`. **Fix:**
`PRng` canonicalizes to PWild in the matrix (`patNeedsGuard`), so the tree routes to a CTGuard;
`emitGuardedArm` now re-matches the arm pattern via `emitRefutMatch`, whose `PRng` case emits
`lo <= n && (incl ? n <= hi : n < hi)` on the tagged words (`n*2+1` monotonic → tagged compare
== untagged; Int + Char). Matches `eval.mdk`'s inIntRange/inCharRange boundaries exactly
(verified incl/excl/negative/char on the binary). Fixpoint C3a/C3b hold. Fixtures
`test/llvm_fixtures/rng_pat_int_{excl,incl,neg}.mdk` + `rng_pat_char.mdk`.

### G7 — `foldMap`/`empty` + Ord-default family — ✅ CLOSED 2026-06-12 (`4fb1160`)
**Repro:** `foldMap (x => [x, x]) [1,2,3]` → native clean-panics; oracle `[1,1,2,2,3,3]`. A
common stdlib shape (Foldable default-method dispatch where the Monoid `empty` seed has no
concrete tag → RNone). Same default-method-dispatch family as the closed gaps; diagnose its
route. `compiler/typecheck.mdk` + emit.

---

## TIER 3 — NARROW (parser false-rejects + a known limit). Close for completeness.

### G8 — compiler parser false-rejects — ✅ CLOSED 2026-06-12 (`2bc48a1`)
- **Indented multi-line `let … in` clause body:** `f x =⏎  let go n = … in go x` →
  `parser.mdk:2704 parse error`; single-line `f x = let … in …` parses. (PLAN "Known parser
  gaps" / OBS2 / T2.)
- **Negative range-pattern bound** `-1..1` in a match → rejected (`intBoundFor` only matches
  `TInt`, not `MINUS INT`). Non-negative ranges parse.
`compiler/parser.mdk`. UX footguns; the bootstrap corpus avoids both.

### G9 — Float `sum`/`product` (targeted) — ✅ CLOSED 2026-06-12 (`fa0bbe9`); full literals deferred
**Repro:** `sum [1.0, 2.0, 3.0]` / Float-literal computations → **both** oracle and compiler
reject (`Int vs Float`): the compiler typechecker monomorphizes int literals to `Int`
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
  A8/A9/A11 are NOT compiler-only (both parsers behave identically). Header already admits lag.
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
