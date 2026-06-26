# Making `sequence` a default method of `Traversable t`

> **AS-BUILT (2026-06-26, `main` = `f333125`): IMPLEMENTED, Fork 1 UNIVERSAL.** `fillImplDefaults`
> landed in `selfhost/frontend/desugar.mdk` (+ `lib/desugar.ml` mirror); `sequence` is a real
> `Traversable` default. Literal universal (no Ord/Foldable exclusion) required two emitter/typecheck
> dict-threading fixes the design's "universal just works" premise missed: encl-aware
> `registerImplRequires` routing (`typecheck.mdk`) and eta-expanding eta-short defaults INCLUDING
> leading dict params (`llvm_emit.mdk gatherGroup`). Also fixed a pre-existing parametric `Ord` bug
> (`max [1,2] [1,3]`). Gap 3 (§9) confirmed DODGED (stays open). The §7 native-only acceptance is
> realized and stronger than anticipated: the OCaml oracle can no longer typecheck the prelude at all
> (`identity` unbound in the `sequence` default body) — see PLAN.md top status + HANDOFF.

Status: DESIGN (decision-ready). Native-only target (the frozen OCaml oracle
cannot express the working end state — see §7). Read-only design pass; all
experiments below were run and reverted, tree left clean.

## 1. Problem statement

`stdlib/core.mdk` (interface at lines 760–792) declares `Traversable t` with two
methods, `traverse` and `sequence`. Every impl repeats the identical body:

```
sequence ta = traverse identity ta
```

(List @778, Option @784, `default` Result @792). The goal is to make `sequence`
a **default method** of the interface so the three impls drop that line.

The clean forms have historically failed. Three distinct gaps sit under this
residual; all three were re-verified empirically in this pass (reproduce-before-
trust), not taken on faith.

### Gap 1 — user-file generic free-fn build SIGSEGV: CLOSED
Closed by `066b9ea` (`selfhost/backend/llvm_emit.mdk`): `emitDispatchChain` now
sources a dispatched impl-method's method-level `=>` constraint dict (e.g.
`traverse`'s `Thenable m`) from the caller's ambient dict arg instead of an
out-of-bounds load from the runtime dispatch-dict cell. (Confirmed in base:
`git merge-base --is-ancestor 066b9ea HEAD` → BASE_OK.)

### Gap 2 — default-method form (THE TARGET): broken on the dispatch/eval path
Default methods install as a **single untagged fallback**, never specialized
per impl:
- lowering: `selfhost/ir/core_ir_lower.mdk:783-785` `lowerDefault` emits ONE
  `CImplEntry mname (CImplDefault pats body)` per interface default (no per-impl
  tag); `lowerDeclImpl` (@766-770) maps an impl's *explicit* methods to tagged
  `CImplTagged` entries but an interface's defaults to that single untagged entry.
- eval: `selfhost/eval/eval.mdk:1549-1551` `defaultEntry` installs the default
  body as an untagged `VClosure` fallback.
- typecheck: `inferDefaultMethod`/`inferDefaultMethodBody`
  (`selfhost/types/typecheck.mdk:7313-7358`) infer the default body once,
  generically, with `methodDictArityOf` covering only the method-level
  constraint (`Thenable m`) — **no receiver (`t`) dict slot**.

So a default `sequence ta = traverse identity ta` calls the SIBLING method
`traverse` on the GENERIC receiver `t`. With no receiver dict to forward,
`traverse` is stamped RNone → arg-tag dispatch → `no matching impl` at run.

### Gap 3 — generic prelude free-fn build: OPEN (reproduced below)
Making `sequence` a prelude FREE FUNCTION with the explicit signature
`sequence : (Traversable t, Thenable m) => t (m a) -> <e> m (t a)` passes all
core doctests and RUNS correctly, but `medaka build` of a caller FAILS with:
`arg-tag dispatch on impl type that owns no constructors (slice 7: primitive
receiver carries no cell tag)`. A USER-FILE free fn with the SAME signature
builds fine — only the GENERICALLY-EMITTED prelude copy hits slice-7.

## 2. The crux — why Ord defaults work but `sequence`'s default doesn't

Both are "single untagged fallback" defaults (same `defaultEntry` machinery),
yet Ord's work and `sequence`'s does not. The difference is **what the default
body dispatches on**:

- **Ord `lt`/`gt`/`min`/`max` (`core.mdk:146-163`) SELF-dispatch on their own
  concrete argument.** `lt x y = match compare x y …` — at the call `lt Red Blue`
  the argument `x = Red` is a CONCRETE value carrying a cell tag, so the sibling
  call `compare x y` resolves by arg-tag to the `Ord Color` impl. No receiver
  dict needed.
- **`sequence`'s default SIBLING-dispatches `traverse` on the receiver `t`.** The
  receiver of `traverse` inside the body is the structurally-generic `t (m a)`;
  the value flowing in is the same `ta`, but `traverse` needs the `Traversable t`
  receiver dict to pick List-vs-Option-vs-Result, and the untagged fallback
  carries no such dict (`methodDictArityOf sequence` = 1 = only `Thenable m`).
  → `traverse` stamped RNone → arg-tag → panic.

**Empirically confirmed (Experiment 3):** `Ord Color` defining ONLY `compare`,
then calling `lt`/`max` (defaults), works on BOTH run and build:
```
=== RUN ===            === EXEC (built) ===
True                   True
False                  False
Blue                   Blue
```
The hypothesis in the brief is CORRECT: self-dispatch-on-concrete-arg defaults
work; sibling-dispatch-on-generic-receiver defaults do not.

## 3. Experiment results (real outputs)

Binary rebuilt fresh each time (`dune build --root .` + `FORCE_EMITTER_REBUILD=1
make medaka`) to avoid the stale-binary footgun.

### Experiment 2 — existence proof: shipped per-impl `sequence` builds AND runs
Unmodified tree, caller `main = println (debug (sequence [Some 1, Some 2, Some 3])) …`:
```
=== RUN ===            === BUILD ===              === EXEC (built) ===
Some [1, 2, 3]         built … -> seqcaller.out   Some [1, 2, 3]
None                                              None
Ok [1, 2, 3]                                      Ok [1, 2, 3]
```
A concrete-receiver `sequence` copy builds and runs correctly TODAY. This is the
existence proof underpinning Fork 1.

### Experiment 1 — gap 3 reproduced
`sequence` rewritten as a prelude free fn (removed from interface + 3 impls,
added `sequence : (Traversable t, Thenable m) => … ; sequence ta = traverse
identity ta` to the prelude); rebuilt:
```
=== core doctests ===  9 props passed, 0 failed  (and 38 doctests OK)
=== RUN caller ===     Some [1, 2, 3] / None / Ok [1, 2, 3]      (correct)
=== BUILD caller ===   error: emitter failed compiling seqcaller.mdk
                       arg-tag dispatch on impl type that owns no constructors
                       (slice 7: primitive receiver carries no cell tag)
```
Then reverted (`git checkout -- stdlib/core.mdk`), rebuilt. Contrast confirmed:
a USER-FILE free fn `mySequence` with the same signature BUILDS and runs
(`Some [1,2,3]` / `Ok [1,2,3]`). So gap 3 is specific to the
**generically-emitted prelude copy**, not signed free-fns in general. (This
corrects the prior diagnosis's wrong sub-claim that signed free-fns fail on
native — they don't.)

### Experiment 3 — Ord-default contrast: see §2 (works on run AND build).

## 4. Fork 1 — default-method SPECIALIZATION (synthesize per-impl copies)

Mechanism: during elaboration, for each `DImpl` that does NOT explicitly define a
method the interface supplies a default for, synthesize a concrete-receiver
`ImplMethod` clause from the default body into that impl — exactly the
hand-written per-impl form (`sequence ta = traverse identity ta` with `t`
concretely `List`/`Option`/`Result e`). Downstream (typecheck dict-pass →
`core_ir_lower` → eval/emit) then sees a normal explicit, tagged impl method,
byte-identical to today's shipped form.

Touchpoints:
- **Injection stage — `selfhost/frontend/desugar.mdk`** (runs FIRST, before
  resolve/mark/typecheck, sees the whole decl list). Add a pass `fillImplDefaults
  : List Decl -> List Decl`: collect `(ifaceName, [defaults])` from every
  `DInterface`, then for each `DImpl { iface, methods, … }` append a synthesized
  `ImplMethod mname pats body` for each interface default whose `mname` is absent
  from `methods`. desugar already manipulates `IfaceMethod`/`MethodDefault`
  shapes here (`mergedDefault`/`mergeTwo` @699-708), so the machinery is local.
- **`stdlib/core.mdk`**: move `sequence` to a real default — add
  `sequence ta = traverse identity ta` to the interface body (@762 area) and
  DELETE the three per-impl `sequence ta = …` lines (@778/@784/@792). Update the
  @763-769 comment.

Does Fork 1 build? **YES — de-risked by Experiment 2.** The synthesized clause is
the same node as the per-impl form that builds and runs today; Fork 1 mechanizes
producing it instead of hand-writing it. It also **sidesteps gap 3** entirely:
every specialized copy has a concrete receiver, so slice-7 (primitive/generic
receiver carrying no cell tag) is never reached — the same reason the
hand-written per-impl form builds.

Visibility limitation (document): a desugar pass runs per-module and only sees
defaults from interfaces in the SAME module. For the Traversable goal the
interface + all three impls are co-located in `core.mdk`, so this is sufficient.
To generalize to USER impls of PRELUDE interfaces, the fill must run where the
prelude interface is visible alongside the user impl — the driver assembles
`markedPrelude ++ user` before the joint dict-pass (`selfhost/frontend/marker.mdk`
`markProgram`/`markerForWithPrelude` @92/@466-479; driver in
`selfhost/driver/`), so a whole-program variant of the pass would live there.
Recommend shipping the same-module desugar pass first (covers the goal) and
noting the whole-program lift as a follow-up.

Blast radius: one new desugar pass + a `core.mdk` edit. No typecheck/eval/emit
ABI change. Low risk (the produced node already works end-to-end).

Risk: synthesizing for EVERY missing default across ALL interfaces changes
behavior for any interface whose defaults currently rely on the untagged
fallback (e.g. Ord). Mitigate by either (a) scoping the synthesis to interfaces
that need it, or preferably (b) synthesizing universally but verifying the full
gate (Ord defaults still resolve — they will, since a tagged specialized copy is
strictly more specific than the untagged fallback and `coalesceImpls` orders
most-specific first). Option (b) is cleaner and closes the whole class.

## 5. Fork 2 — thread a RECEIVER DICT into default bodies

Mechanism: extend the default-method ABI so the untagged fallback also carries
the receiver `t` dict; register it active in
`inferDefaultMethod`/`inferDefaultMethodBody`
(`selfhost/types/typecheck.mdk:7313-7358`) so the in-body sibling call
`traverse` stamps RDict off it; supply it at the dispatch site in eval
(`eval.mdk` `defaultEntry`/dispatch) and emit (`llvm_emit.mdk`).

Touchpoints: `typecheck.mdk` (ABI + `methodDictArityOf` + active-dict
registration) + `core_ir_lower.mdk` (`lowerDefault` arity) + `eval.mdk`
(`defaultEntry` + dispatch supplies the receiver dict) + `llvm_emit.mdk`
(`emitDispatchChain`). 4 compiler files, an ABI change.

Gap 3: Fork 2 likely STILL HITS gap 3 — the default body stays generic, so the
emit path for the generic copy must additionally do what gap 3's fix requires.
So Fork 2 does NOT come for free; it needs a gap-3 fix too.

Blast radius: large (cross-cutting ABI). Higher risk. Benefit: GENERAL — fixes
every sibling-dispatching default for all interfaces, present and future, and
keeps `sequence` a single generic body.

## 6. Recommendation

**Adopt Fork 1 (default-method specialization), same-module desugar pass.**

Rationale:
1. It is **empirically de-risked**: the end-state node already builds and runs
   today (Experiment 2). Fork 2 is not de-risked and still needs a gap-3 fix.
2. It **dodges gap 3** for this goal — no slice-7, no emitter ABI change.
3. Smallest blast radius (one desugar pass + a `core.mdk` edit) vs Fork 2's
   4-file ABI change.
4. It generalizes cleanly later (lift the same pass to whole-program in the
   driver) without committing to the heavier ABI now.

Fork 2 is the right answer ONLY if a future requirement demands keeping
sibling-dispatching defaults as single generic bodies (no per-impl code-size
duplication) — then it must be paired with a gap-3 fix. Not needed for this task.

## 7. Design forks needing a human decision

**DECIDED (2026-06-26, user):** Fork 1 (specialization), **UNIVERSAL** scope (synthesize
for all missing interface defaults, close the whole class), native-only accepted, gap 3
deferred as a separate backlog item. The original fork list is retained below for the record.


- **Scope: targeted (Fork 1) vs general (Fork 2).** Do we want only "default
  methods that sibling-dispatch on the receiver get specialized per impl"
  (Fork 1, recommended), or the general "default bodies carry a receiver dict"
  capability (Fork 2, more invasive, still needs gap 3)? Recommend Fork 1 now.
- **Fork 1 synthesis breadth.** Synthesize specialized copies for ALL missing
  interface defaults universally (closes the whole class, must re-verify Ord et
  al. on the gate) vs scope narrowly to Traversable. Recommend universal +
  full-gate verification.
- **Native-only acceptance.** The end state (a specialized-per-impl Traversable
  default) cannot be mirrored on the frozen OCaml oracle. Accept native-only, as
  with prior soak-tail items; no oracle parity expected for this shape.
- **Gap 3 disposition.** Fork 1 leaves gap 3 OPEN (see §8). Decide whether to
  schedule the independent gap-3 fix now or defer it as a separate backlog item.

## 8. Staged implementation plan (ascending risk; each stage independently gated)

Stage 0 — Pin baseline. Confirm `066b9ea` in base (done: BASE_OK) and the
shipped per-impl `sequence` builds+runs (done: Experiment 2). No edits.

Stage 1 — desugar fill pass (compiler change, lowest behavioral risk).
- File: `selfhost/frontend/desugar.mdk` — add `fillImplDefaults` and wire it into
  the desugar pipeline (before resolve). No `core.mdk` edit yet, so the synthesized
  copies are byte-identical no-ops over today's explicit methods (the impls
  already define `sequence`) — pure refactor.
- Gate: emitter/compiler-graph change ⇒ `FORCE_EMITTER_REBUILD=1 make medaka` +
  **self-compile fixpoint** must hold (`test/selfcompile_*.sh`); re-mint the seed
  (`selfhost/seed/`) at the checkpoint, not per-iteration (per "defer seed
  re-mints"). Plus `diff_selfhost_*` green and core/list doctests pass.

Stage 2 — move `sequence` to a real default (`core.mdk` edit).
- File: `stdlib/core.mdk` — add the interface default body, delete the 3 per-impl
  lines, update the comment. Rebuild (`dune build --root .` +
  `FORCE_EMITTER_REBUILD=1 make medaka`).
- Decisive gate: **run == build on the 3 probes** —
  `sequence [Some 1, Some 2, Some 3]` → `Some [1,2,3]`,
  `[Some 1, None, Some 3]` → `None`, `[Ok 1, Ok 2, Ok 3]` → `Ok [1,2,3]` — under
  BOTH `medaka run` and the `medaka build`-ed binary. Plus `medaka test
  stdlib/core.mdk` (38 doctests + 9 props) and `stdlib/list.mdk`.
- Goldens that ripple (a `core.mdk` edit ripples the frontend goldens): recapture
  desugar / mark / lextok / sexp goldens for core, plus any `diff_selfhost_*`
  corpus that embeds core. (Per memory: editing core.mdk ripples
  desugar/mark/lextok/sexp goldens, not just `test`.) Use the project's
  `capture_goldens` flow; watch the documented blank-golden footgun.

Stage 3 — class-wide verification (if synthesis is universal).
- Confirm Ord (`lt`/`max` on a user type defining only `compare`), and any other
  default-bearing interface, still resolve on run AND build (Experiment 3 shape).
- Gate: `@thorough` + the eval/typecheck/loader suites; fixpoint still holds.

Stage 4 — checkpoint: re-mint seed, final fixpoint, commit (on request only).

## 9. Does gap 3 need an independent fix?

Under Fork 1, **no** — Fork 1 dodges gap 3 by specializing to concrete receivers,
so the goal ships without touching it. But gap 3 stays OPEN as a separate item:
a TRULY GENERIC prelude free function with a `(Traversable t, Thenable m) =>`
signature still fails `medaka build` with the slice-7 error (Experiment 1). If a
future stdlib helper needs to be a generic prelude free fn over a typeclass with
a primitive/generic receiver, gap 3 must be fixed in the emitter
(`selfhost/backend/llvm_emit.mdk` slice-7 dispatch path) independently. Track it
as its own backlog entry, not a blocker for this task.
