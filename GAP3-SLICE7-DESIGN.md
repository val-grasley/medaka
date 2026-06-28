# Gap 3 — slice-7 arg-tag dispatch on a generic prelude free function

> **RE-DIAGNOSIS UPDATE (2026-06-28, current main).** This design (below) was
> written on stale commit `197e550` against the `debug (sequence …)` repro. On
> current main the manifestation has SHIFTED (post-#21/#22, which closed the
> constrained-value-as-HOF-arg path). The two repros in the picked-up brief
> (`pickEq eq x y = eq x y` build-reject; `app2 f = f 2 3; main = println (app2
> (==))` SIGTRAP) reduce to **TWO DISTINCT bugs, NEITHER of which is the
> arg-stamp prelude/user grounding asymmetry §2 describes:**
>
> 1. **FACE 1 (build-reject) = an EMITTER name-shadowing bug, now FIXED (E24).**
>    A HOF PARAMETER named like an interface method (`eq`/`compare`/…) applied in
>    the body (`eq x y`) was mis-routed by `llvm_emit.mdk`'s `emitApp` to
>    `emitMethodArgDispatch` (arg-tag over primitive Int/String impl groups →
>    `emitTagMatch []` slice-7) because it checked `isImplMethod` before
>    recognising the head as a local. This is the emitter-side analogue of the
>    front-end E15/E18 scope guards. Fix: an `isLocal env fname` guard at the top
>    of `emitApp`'s CVar arm. The GENUINE constrained-value-as-HOF-arg case (with
>    a NON-method param name, e.g. `pickEq f x y = f x y; pickEq (==) …`) already
>    BUILDS+runs correctly via E22/E23. See EMITTER-GAPS.md **E24**.
>
> 2. **FACE 2 (#23 SIGTRAP) = a TYPECHECK Num-defaulting bug, OPEN (deferred).**
>    A HOF generalized to `(Num a, Num b) =>` from internal literals, called with
>    a fn that makes the var `Num`+`Eq` and the result concrete (`app2 (==)`),
>    leaves the ambiguous Num var UNGROUNDED — its callee `CDict` Num-dict routes
>    resolve `RNone` → a NULL dict word → `inttoptr 0; load` SIGTRAP. Root cause:
>    `processSCC`'s Num-defaulting reads only `pendingImplObligations`, but the
>    callee's instantiated Num constraints flow through `pendingCallObligations` /
>    (for inferred-constraint promoted fns) `pendingDictApps`. Two targeted fix
>    attempts failed; a clean STOP. See EMITTER-GAPS.md **#23 / slice-7 SIGTRAP**
>    for the full verified diagnosis + next step.
>
> The `debug (sequence …)` repro below is a THIRD manifestation (a genuinely-
> generic prelude free fn over a typeclass); §6 F3's "no current caller, keep the
> per-impl specialization" disposition still stands for THAT case.

---

# Gap 3 — slice-7 arg-tag dispatch on a generic prelude free function

Status: DESIGN (decision-ready). Read-only diagnostic pass on `main`
(`197e550`, BASE_OK). All experiments below were run on a freshly-built
`./medaka` (`FORCE_EMITTER_REBUILD=1 make medaka`) and the tree was reverted
clean afterward (`git checkout -- stdlib/core.mdk`; repro files removed).

## 1. Reproduction result — CONFIRMED, but the filed framing is INCOMPLETE

Experiment 1 (rewrite `sequence` as a prelude free fn
`sequence : (Traversable t, Thenable m) => t (m a) -> <e> m (t a)` /
`sequence ta = traverse identity ta`, removed from the `Traversable` interface +
its synthesized per-impl defaults) reproduces the documented error on current
main:

```
=== RUN  seqcaller (println (debug (sequence [Some 1, Some 2, Some 3]))) ===
Some [1, 2, 3]   None   Ok [1, 2, 3]            (correct)
=== BUILD seqcaller (MEDAKA_EMITTER=./medaka_emitter) ===
error: emitter failed compiling seqcaller.mdk
arg-tag dispatch on impl type that owns no constructors
(slice 7: primitive receiver carries no cell tag)
```

CONTRAST (filed claim confirmed): the SAME signature+body as a USER-FILE free fn
`mySequence` BUILDS and runs (`Some [1,2,3]` / `Ok [1,2,3]`). So the gap is
specific to the generically-emitted prelude copy.

### NEW finding — the filed framing names the wrong site, and there are TWO gaps

The brief assumes slice-7 fires on the inner `traverse` (the generic receiver
`t`). It does NOT. Reduction experiments localize it precisely:

- `seq2`: `main = match sequence [Some 1,Some 2,Some 3] { Some xs => println
  (length xs); None => println 0 }` — NO `debug`. **This BUILDS** (no slice-7).
- `seq3`: route the result through a concretely-typed wrapper
  `f : Option (List Int) -> String; f r = debug r; main = println (f (sequence
  […]))`. **This BUILDS** (no slice-7).
- Only the form that applies a bare interface method (`debug`) DIRECTLY to the
  prelude `sequence` result hits slice-7.

So **slice-7 fires at the CALLER's `debug` site, not inside `sequence`/
`traverse`.** `debug : a -> String` is an argument-position interface method
whose impls include the PRIMITIVE types (Int/String/Char/Bool/Float). When its
discriminating-argument mono is left an unsolved type variable, its route stays
RNone, the emitter arg-tag-dispatches over ALL of `debug`'s impl groups, and the
primitive groups (Int/String/…) own no runtime constructor cell tag →
`emitTagMatch []` → the slice-7 gap.

**Second, deeper gap (the brief misses this):** even when slice-7 is dodged, the
generic prelude `sequence` is *independently mis-emitted at runtime*:
- `seq2` built binary prints `0` where `medaka run` prints `3` — WRONG ANSWER.
- `seq3` built binary SEGFAULTS (exit 139), while `medaka run` is correct.
So the inner generic-receiver `traverse` dispatch is ALSO broken in native
codegen for the generic prelude body — a separate emitter defect behind the
slice-7 one. Fixing slice-7 alone would NOT make a generic prelude `sequence`
build-correct.

## 2. Root-cause diagnosis on current main

### 2a. Why `debug` is left RNone (the slice-7 trigger)

Argument-position interface-method occurrences are marked `EMethodAt name (Ref
RNone) …` on the emit path (`compiler/types/typecheck.mdk:4987-4990`,
`rewriteRPDictArg`; `debug` is in the rp/arg name set). Their route is then
stamped from the *resolved discriminating-argument mono* in `resolveArgStamp`
(`compiler/types/typecheck.mdk:1840-1857`):

```
resolveArgStamp … am … = match activeDictVarOfEncl am encl
  Some dname => set_ref tagRef (RDict dname)          -- threaded element dict
  None => match headTyconMono am
    Some tag => … set_ref tagRef (RKey routeKey [])    -- concrete head → RKey
    None => ()                                         -- UNGROUNDED → stays RNone
```

For `debug (sequence […])` the discriminating arg mono `am` is the RESULT of the
prelude `sequence` application. With the prelude free-fn `sequence`, that result
mono is **not grounded to `Option (List Int)` by direct application alone** — it
remains an unsolved type variable at stamp time, so `headTyconMono am = None`,
the `None => ()` arm runs, and `debug`'s route stays RNone (typecheck.mdk:1857).

Empirical proof that this is exactly the mechanism: forcing the result concrete
via an explicit annotation (`seq3`'s `f : Option (List Int) -> String`) grounds
`am`, `headTyconMono` returns `Some "Option"`, debug stamps `RKey Option`, and
the build SUCCEEDS. Pattern-matching the result (`seq2`) avoids a `debug` site
entirely and also builds.

### 2b. Why the USER copy grounds but the PRELUDE copy does not

`mySequence` and prelude `sequence` carry an identical constrained signature, and
both are placed in the joint dict-name set for the modules build path
(`moduleDictNames`, typecheck.mdk:9917-9921 =
`preludeReturnPosDictNames ++ preludeArgPosDictNames ++ constrainedSigNames
(modules)`; `sequence` enters via `preludeArgPosDictNames`/`constrainedSigNames`
of the prelude, typecheck.mdk:4853-4890). The divergence is *where each is
inferred*: the USER `mySequence` is inferred inside the user module where its
result mono unifies against the concrete caller and the `debug` arg-stamp (queued
under the same enclosing `main`) reads a grounded `am`. The PRELUDE `sequence`
is a cross-context constrained symbol; at the user call site its higher-kinded
result `m (t a)` is reconstructed from the imported scheme and the
`Traversable t`/`Thenable m` obligations resolve via dict-passing, so the
RESULT-position tyvar feeding `debug` is not pinned to `Option (List Int)` at the
moment `resolveArgStamp` runs over `main`'s queued sites. The arg-stamp therefore
observes an ungrounded `am` for the prelude case only.

In short: the gap is an **arg-stamp grounding-vs-ordering asymmetry between
in-module and prelude-imported constrained functions**, surfacing on the FIRST
downstream argument-position interface method with primitive impl groups
(`debug`).

### 2c. The emitter slice-7 endpoint (where it actually panics)

`emitMethod … RNone => emitMethodArgDispatch e name argOps`
(`compiler/backend/llvm_emit.mdk:3021`) → with several impl groups →
`emitArgTagDispatch`/`emitArgDispatchChain` (llvm_emit.mdk:3479-3511) →
`emitTagMatch e tagReg (ctorsOfType e tag)`. For a primitive group tag
(`Int`/`String`/…) `ctorsOfType` returns `[]` (no entry in `ctorTypeTable`, and
`reservedCtorsOfType` only covers List/Option/Result/Ordering, llvm_emit.mdk:
1038-1051) → the `emitTagMatch _ _ [] => gapStr …` arm fires
(**llvm_emit.mdk:3515-3518**). This is exactly the "irreducible primitive
residual" that `compiler/ARGSTAMP-UNIFY-PLAN.md` predicts arg-tag cannot serve.

### 2d. The second (runtime) defect

The inner `traverse identity ta` on the generic receiver `t`: in the prelude
body, after dict-passing, `traverse`'s route does not thread the receiver
`Traversable t` dict correctly through native emit (the body either takes the
wrong arg-tag branch — `seq2` prints `0` — or loads a bad cell — `seq3`
segfaults). This is the generic-receiver analogue of the same RNone→arg-tag
problem, internal to the emitted `sequence`. It is NOT exercised by the per-impl
specialized form (each copy has a concrete receiver → RKey).

## 3. The fix design

Two independent defects; a generic prelude free fn over a typeclass needs BOTH:

**Fix A — ground the downstream arg-stamp (closes slice-7 on `debug`).** Make a
prelude-constrained-function application's RESULT mono resolve to its concrete
instantiation before `resolveArgStamp` runs over the enclosing function, OR make
`resolveArgStamp`'s `None` arm (typecheck.mdk:1857) defer/re-resolve after the
constrained-call obligations are discharged. Touchpoints: typecheck only
(`resolveArgStamp` + the queueing of arg-stamp sites relative to constrained-call
unification; `recordArgSiteFn`/`resolveArgStamps`, typecheck.mdk:1820-1857).
Marker/lower/emit unchanged. This is the minimal, targeted fix and is
emitter-graph-touching only through typecheck (which IS in the self-compile
graph).

**Fix B — dispatch the inner generic receiver through the threaded dict
(closes the runtime defect 2d).** Make the emitted `sequence` body route
`traverse` via the `Traversable t` dict witness threaded into `sequence` (an
RDict/RDictFwd, not RNone arg-tag). Touchpoints: the receiver-dict must be
registered active while inferring the prelude body so `traverse` stamps RDict
(`registerImplRequires`/`registerConstraintRegs`/`activeDictVarOfEncl`,
typecheck.mdk:1841), threaded by dict_pass, and consumed by
`emitMethod RDict => emitMethodDispatch` (llvm_emit.mdk:3019) instead of falling
to `emitMethodArgDispatch`. This is the same ABI work as Fork 2 of
TRAVERSABLE-DEFAULT-METHOD-DESIGN.md §5 and threads through
typecheck + dict_pass + core_ir_lower + llvm_emit.

**Emitter-only?** No. Fix A is typecheck-only; Fix B is cross-cutting
(typecheck + dict_pass + lower + emit). Neither is a pure llvm_emit.mdk change.
A pure-emitter "slice-7 → primitive-tag dispatch" patch (give `emitTagMatch` a
real primitive-tag test instead of gapping) would only paper over Fix A's symptom
and still leave defect 2d; not recommended as the primary fix.

## 4. Emitter-graph / fixpoint / seed relevance

`compiler/types/typecheck.mdk`, `compiler/frontend/marker.mdk`,
`compiler/ir/core_ir_lower.mdk` and `compiler/backend/llvm_emit.mdk` are ALL in
the self-compile graph. Any change to A or B therefore requires:
`FORCE_EMITTER_REBUILD=1 make medaka` → `test/selfcompile_fixpoint.sh`
(C3a/C3b) must hold → seed re-mint (`compiler/seed/`) at the checkpoint by the
orchestrator (per "defer seed re-mints"). The fix is NOT seed-free.

## 5. Risk / blast radius

- Fix A perturbs arg-position route stamping — the highest-traffic dispatch
  decision in the compiler (every `debug`/`display`/`eq`/`compare`/`fold` call
  site). Mis-timing the re-resolution could flip a currently-RKey site to RNone
  (new gaps) or vice-versa (wrong impl). Decisive gates: `selfcompile_fixpoint`,
  `diff_compiler_llvm` / `diff_compiler_llvm_typed` / `diff_compiler_build` /
  `diff_compiler_eval_dict`, plus `medaka test stdlib/core.mdk` (the documented
  `neq`/prop-shrinker canary for arg-position dict churn).
- Fix B is an ABI change to the dict-threading of generic receivers — larger
  blast radius; same gate set plus the eval-modules differential
  (`diff_compiler_eval_modules`).

## 6. DESIGN FORKS — need a human decision

- **F1. Fix the emitter slice-7 to handle primitive receivers vs. fix the
  typecheck arg-stamp so the site never reaches arg-tag.** Recommend the
  typecheck arg-stamp grounding (Fix A): the emitter arm is correctly a gap
  (arg-tag genuinely cannot dispatch a primitive cell), and ARGSTAMP-UNIFY-PLAN
  already designates this the irreducible residual — the right answer is to stop
  routing the site to arg-tag, not to emit a fake primitive-tag test.
- **F2. Minimal (Fix A only) vs. general (Fix A + Fix B).** Fix A alone makes
  `debug (sequence …)` BUILD, but the built `sequence` still returns wrong
  answers / segfaults (defect 2d). So Fix A alone is NOT shippable for a generic
  prelude free fn — it converts a clean compile-error into a silent
  miscompile, which is worse. Recommend: ship A+B together, or **ship neither
  and keep the per-impl specialization (Fork 1, already landed)**.
- **F3. Is Gap 3 worth fixing at all right now?** The shipped resolution
  (default-method specialization, TRAVERSABLE-DEFAULT-METHOD-DESIGN.md Fork 1)
  already delivers a working `sequence` with concrete receivers and dodges both
  defects. Gap 3 only bites a genuinely-generic prelude free fn over a typeclass
  with a generic/primitive receiver — no such stdlib helper exists today.
  Recommend: keep Gap 3 as a tracked backlog item (this doc), do NOT schedule
  A+B until a real need appears; the cost (two cross-cutting changes + seed
  re-mint + the arg-stamp blast radius) is unjustified for zero current callers.

## 7. Staging (if A+B is scheduled)

- Stage 1 (Fix A, typecheck-only, lowest cross-cut): re-ground/defer the
  arg-stamp for prelude-constrained-call results. Gate: full
  `diff_compiler_*` + `selfcompile_fixpoint` + `medaka test stdlib/core.mdk`.
  Acceptance: `debug (sequence …)` BUILDS. NOTE: stop here only if Stage 2 also
  lands in the same checkpoint — A-alone is a miscompile (F2).
- Stage 2 (Fix B, ABI): thread the `Traversable t` receiver dict into the
  generic prelude body so the inner `traverse` routes RDict. Gate: above +
  `diff_compiler_eval_modules` + run==build on the three `sequence` probes
  (`Some [1,2,3]` / `None` / `Ok [1,2,3]`).
- Stage 3 (checkpoint): re-mint seed, final fixpoint, commit.

## 8. One-line summary

Gap 3 is REAL and still slice-7 on current main, but it fires on the CALLER's
arg-position `debug` (ungrounded result mono → RNone → arg-tag over primitive
impl groups, `typecheck.mdk:1857` → `llvm_emit.mdk:3518`), not on the inner
`traverse`; and behind it the generic prelude `sequence` body is independently
mis-emitted at runtime (wrong answer / segfault). A real fix is cross-cutting
(typecheck arg-stamp grounding + generic-receiver dict-threading ABI), not
emitter-only, and needs a seed re-mint. Recommended disposition: keep the
shipped per-impl specialization and leave Gap 3 as a no-current-caller backlog
item.
