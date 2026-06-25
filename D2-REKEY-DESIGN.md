# D2 cross-module dict-identity — design (reproduced + root-caused)

> Read-only planning artifact. Reproduced on current `main` (merge-base of
> `da2469d` is an ancestor of HEAD; native `medaka` rebuilt
> `FORCE_EMITTER_REBUILD=1 make medaka`; oracle `_build/default/bin/main.exe`).
> **No source was changed.**

## 1. Problem — the LIVE, reproduced manifestation

A NON-prelude, sibling-module interface+impl whose method carries a **user**
(dict-bearing) **method-level `=>` constraint** mis-compiles on **both** native
paths, while `check` accepts it.

Minimal repro (scratchpad project, `medaka.toml` + two modules):

```
-- sibtrav.mdk
public export data Box a = Box a deriving (Debug)
export interface BoxTrav t where
  btraverse : Thenable m => (a -> m b) -> t a -> m (t b)
export impl BoxTrav Box where
  btraverse f b = match b
    (Box x) => andThen (f x) (y => pure (Box y))
-- main.mdk
import sibtrav.{Box(..), btraverse}
main = println (debug (btraverse (x => if x > 0 then Some x else None) (Box 5)))
```

Verbatim behavior on current `main`:

| Path | Output | Verdict |
|------|--------|---------|
| native `medaka check` | `main : Unit` (accepts) | silently wrong (no error) |
| native `medaka run`   | `no matching impl for dispatch` (panic) | FAIL |
| native `medaka build`+exec | (builds OK) **SIGSEGV, rc 139**, no output | FAIL |
| frozen oracle `run` | `[Box 5]` | wrong value (oracle mis-evaluates this shape — known, frozen) |
| **expected (correct)** | `Some (Box 5)` | — |

The correct value is established by the **single-module** control (same
interface+impl+call inlined into one file): native `run` and `build` both print
`Some Box 5` correctly; only the *frozen oracle* is wrong there too (`[Box 5]`).
So native is correct single-module and **only the cross-module sibling split
breaks it** — `run` panics, `build` SIGSEGVs.

This is not a new discovery so much as a never-closed residual: the shipped
fixture `test/eval_typed_modules_fixtures/method_constraint_dispatch/main.mdk`
header comment says so verbatim — *"the cross-module variant (interface/impl
imported from a sibling) hits a SEPARATE, pre-existing gap that fails on BOTH
backends (eval panics, build SIGSEGVs) — the cross-module method-scheme identity
(D2) problem — and is out of scope here."* My repro reproduces exactly that.

### Containment still holds (additive fix intact)
The existing fn-level + arg-position method-level collision fixtures all pass on
the loader-driven typed-modules gate
(`sh test/diff_selfhost_eval_typed_modules.sh` → **6 ok, 0 failing**), including
`cross_module_dict_arity` (1/2/3-arity), `cross_module_dict_arity_rev`
(reversed import order), and `cross_module_method_arity` (arg-position `Num e =>`
1-vs-2 arity). So the 2026-06-20/21 additive define-side mirrors
(`crossModuleFunConstraintsQualRef`/`crossModuleMethodConstraintsQualRef`) are
not regressed; the live bug is a class they do not cover.

## 2. Root cause — PROVEN to be method-scheme IDENTITY, **not** the WS2 collision re-key

The crux fork in the brief ("is the live failure the SAME root as WS2 Option-B,
or a distinct method-level identity issue?") resolves **decisively to the latter**,
on differential evidence (I am read-only, so the localization is by contrasting
repros rather than added print statements — the contrast matrix is dispositive,
and the codebase's own fixture comment names the root):

Contrast matrix (all cross-module, native `run`, oracle for reference):

| callee kind | constraint kind | position | native run | conclusion |
|-------------|-----------------|----------|-----------|------------|
| free **function** | user (`Tag a =>`) | arg | OK (`cross_module_dict_arity`) | fn path fine |
| **method** | **primitive** (`Num e =>`) | arg | OK (`cross_module_method_arity`) | primitive dict fine |
| **method** | **user** (`Debug m =>`) | arg | **`intToString: not an Int`** (under-application) | FAIL |
| **method** | **user** (`Thenable m =>`) | return | **`no matching impl`** / build SIGSEGV | FAIL |

The failing cells are exactly the intersection **method ∧ user (dict-bearing)
constraint ∧ cross-module**. Two distinct symptoms (arg-position →
under-application `intToString: not an Int`; return-position → `no matching impl`
/ SIGSEGV) share **one** root: at the importer's call site the method-level
constraint **dict slot is not recovered**, so either the define-side dict param
is prepended with nothing supplied (arg case → the value arg is swallowed → under-
application) or the inner constraint-var method (`pure`/`andThen`) routes `RNone`
→ arg-tag → no impl (return case).

### Why this is identity, not collision
The WS2 Option-B re-key (`selfhost/WS2-REKEY-DIAGNOSIS.md`) targets the **bare-name
first-match COLLISION**: two *distinct same-named* callees in different modules,
disambiguated by an AST `EVarFrom`-style definer origin. **My repro has no name
collision** — `btraverse`/`sizeWith` are unique across the project. A single,
uniquely-named cross-module method's constraint slot simply fails to be
recovered. The `EVarFrom` definer-origin re-key would change *which* same-named
entry is read; it does nothing when there is exactly one entry and the failure is
that its constraint **ids don't line up with the importer's instantiation subst**.

### The mechanism (from the source, validated)
- `methodConstraintsRef : Ref (List (String, List Int))` maps a method name →
  the **quantified tyvar ids** of its `=>` constraints, slot-parallel
  (`typecheck.mdk:1543`). The `Scheme = Forall ids evars t` carries **no**
  constraint list, so these ids are the *sole* record of which of a method's
  tyvars are dict slots — same structural fact the WS2 doc proved load-bearing
  for `funConstraintsRef`.
- These ids are produced by `ifaceMethodSchemes prog` (`:7825`) — a **fresh** id
  build **per module pass** (`registerMethodConstraints`/`registerMethodDictSlots`
  `:7603`, impl-body analog `registerImplMethodDicts` `:7701`). The code itself
  flags the hazard: the comment at `:1538` says the snapshot must use "the SAME
  quantified ids" as the scheme, and `:7206` notes `methodConstraintsRef` is
  "filled by a SEPARATE `ifaceMethodSchemes` build with its own ids."
- `resetState` wipes `methodConstraintsRef` each module (`:1993`); the importer's
  pass re-seeds it from the cross-module snapshot
  (`methodConstraintsRef ++ crossModuleMethodConstraintsRef`, `:8848`) whose ids
  come from the **definer** module's pass.
- At the importer's call site, `recordMethodDicts name methodRef subst` (`:2929`)
  reads the **bare** `methodConstraintsRef[name]` ids and maps them through
  `subst` — the importer's *own* instantiation of the method occurrence, whose
  keys are the ids from the **import-seed** scheme (re-generalized at the module
  boundary). Definer-pass ids ≠ importer-instantiation ids ⇒
  `constraintMonosOf ids subst` yields **empty** ⇒ `pendingMethodDicts` gets no
  route ⇒ no dict threaded. **That is the empty route.**

So the locus is the **method** constraint-id snapshot/recovery seam
(`methodConstraintsRef` lifecycle + `recordMethodDicts`/`ifaceMethodSchemes` id
identity), *not* the fn-level `funConstraintsRef`/`EVarFrom` collision re-key.

> Caveat (honesty): the exact id-mismatch step ("import-seed re-generalization
> vs definer snapshot") is inferred from the code structure + the contrast
> matrix, not yet from a printed `subst`/ids dump (read-only). **Stage 0 of the
> plan is to confirm it with one print** in `recordMethodDicts`/the `:8848` seed,
> driving the repro through `eval_typed_modules_main`. This is the single
> empirical step the read-only constraint blocked; everything else is proven.

## 3. WS2-REKEY-DIAGNOSIS.md — validation against current source

All cited symbols still exist; **line numbers have drifted ~+300** since the doc
(2026-06-21). Locate by symbol, not number. Confirmed:

- Six+ dict-arity refs present: `funConstraintsRef :1437`, `funConstraintIfacesRef
  :1465`, `crossModuleFunConstraintsRef :1498`, `crossModuleFunConstraintsQualRef
  :1515`, `crossModuleFunConstraintIfacesRef :1521`; `methodConstraintsRef :1543`,
  `crossModuleMethodConstraintsRef :1555`, `crossModuleMethodConstraintsQualRef
  :1572`. The qualified mirrors the doc says "already exist" do (fn `:1515`,
  method `:1572`).
- Writers: per-module accumulate/seed/snapshot block now at `:8848`(method seed)
  / `:8866`(`expandSupersTable`) / `:8867`(`crossModuleFunConstraintsRef`) /
  `:8872`(`crossModuleMethodConstraintsRef`) / `:8869`/`:8879`(qual mirrors via
  `attributeModuleArities`/`attributeMethodModuleArities`); `registerMethodDictSlots
  :7603`, `registerImplMethodDicts :7701`, `registerMember`/`registerInferredFor`
  still the fn writers.
- Readers: `dictArityOf` (fn) and the method-arity reader `:6748`
  (`methodDictArityOf`, **bare** `methodConstraintsRef`), `recordMethodDicts :2929`
  (**bare**, the call-site method reader — the load-bearing one for this bug),
  `scopeMethodArities :9645` consumed at `:9566/:9592`.
- `expandSupersTable :3090` rewrites the bare fn refs wholesale (`expandSupersCross
  :3098` for the snapshot) — must move in lockstep with any re-key. **Confirmed.**
- `dictParamName fn slot = "$dict_" ++ fn ++ "_" ++ intToString slot` (`:6991`) is
  `(encl,slot)`-unique and **must STAY BARE** (qualifying churns emitted IR →
  forces a needless seed re-mint). **Confirmed; honor it.**
- `emitArgStampPasses :1691` is the eval/emit fork ref; any fix must hold on
  **both** the eval (run) and emit (build) dict paths — the repro proves both
  break, so a one-path fix is insufficient. **Confirmed.**
- `resetState :1622/:1993` clears the per-module refs; any new/re-keyed ref must
  reset in lockstep. **Confirmed.**

**Correction to the WS2 doc's framing:** its steps 1–7 design the **function-level
`EVarFrom` definer-origin re-key** as the path to "retire the bare tables." That
plan is *correct for the collision class it targets* but is **neither necessary
nor sufficient for the live bug**, which is method-scheme **id identity** with no
name collision. The live bug needs a method-id-stabilization fix in the method
path; the `EVarFrom` AST/resolve work is orthogonal and can stay deferred.

## 4. Locked decisions vs. forks

**Locked:**
- The bug is real, live, cross-module, method-level, user-constraint-only;
  single-module and fn-level are correct. (Reproduced.)
- `dictParamName` stays bare; the fix must not change emitted IR shape where it
  can be avoided (keep fixpoint cheap).
- The fix must be verified on **both** `run` (eval) and `build` (emit) and the
  regression must drive `evalModules` (loader path), never single-file.
- The WS2 fn-level `EVarFrom` re-key remains **deferred** — it is a different
  (collision) problem; do not couple it to closing this gap.

**Forks (need a human decision) — see §6.**

## 5. Staged plan (ascending risk; gates per stage)

All stages after Stage 0 edit `selfhost/types/typecheck.mdk` ⇒ they **share one
file and must land sequentially** (no parallel branches). Stages that change the
method-constraint snapshot or `recordMethodDicts` feed the emitter self-compile
graph ⇒ require `selfcompile_fixpoint` C3a/C3b green and a **seed re-mint at the
very end** (one re-mint, not per-stage — per memory `feedback_defer_seed_remint`).

- **Stage 0 — confirm the id-mismatch empirically (read-only-blocked step).**
  Add one temporary print in `recordMethodDicts :2929` (the looked-up ids + the
  `subst` keys) and in the `:8848` seed; drive the repro through
  `test/bin/eval_typed_modules_main`. Expect: ids present but disjoint from
  `subst` keys ⇒ empty monos. *Decision gate:* if instead the entry is **absent**
  (not seeded for the imported method at all), the fix shifts from "id alignment"
  to "seed the imported method's constraint arity at the importer" — adjust Stage 2.
  No gates; throwaway diagnostic.

- **Stage 1 — add the failing fixture (RED first).** New
  `test/eval_typed_modules_fixtures/cross_module_method_userconstraint/` (sibling
  module defining `interface BoxTrav`/`impl BoxTrav Box` with `btraverse :
  Thenable m => …`, importer `main` calling it), golden captured **native-leg**
  (native > frozen oracle here — oracle mis-evaluates; do **not** capture from the
  oracle). It will FAIL until Stage 2/3. Gate: `diff_selfhost_eval_typed_modules`
  (the new fixture red, the other 6 green). Oracle-mirror impact: **none**
  (fixture-only, native golden). Touches fixpoint graph: no.

- **Stage 2 — stabilize method-constraint id identity at the importer.** The
  principled fix: ensure the ids in `methodConstraintsRef[name]` that
  `recordMethodDicts` reads are the **same quantified ids** as the importer's
  instantiation `subst` for that occurrence. Two candidate shapes (the §6 fork
  (a)): (i) re-derive the constraint slot ids from the importer's *own*
  `ifaceMethodSchemes`/import-seed scheme when reading at `recordMethodDicts`
  (read-side remap, smallest surface, keyed by the imported scheme's ids); or
  (ii) carry the constraint ids *with* the import-seed method scheme so the
  snapshot and the instantiation share ids by construction (define-side, larger).
  Shares `typecheck.mdk`. Gates: the new fixture flips to green AND all 6
  typed-modules fixtures stay green; `diff_selfhost_eval_dict` 26/0;
  `diff_selfhost_typecheck_errors` (no new accept/reject drift). Touches fixpoint
  graph: **yes** (typecheck is in the emitter graph) → `selfcompile_fixpoint`
  C3a/C3b must hold.

- **Stage 3 — emit-path parity (build).** Verify the same fix threads on the
  `emitArgStampPasses` (build) path; if the snapshot is shared the eval fix may
  cover it, but the SIGSEGV proves the emit side independently under-fills today.
  Add a `build`-exec assertion for the new shape. Gates:
  `diff_selfhost_build` 35/0 + the new fixture built+exec == native run golden.
  Touches fixpoint graph: **yes**.

- **Stage 4 — re-mint seed + full gate sweep + (optional) doc retire.** One seed
  re-mint (`selfhost/seed/`), full differential sweep, update
  `method_constraint_dispatch/main.mdk`'s "out of scope" comment to point at the
  now-covered fixture. Gates: §6 full list. Oracle-mirror impact: **none of these
  gates compares against a live `lib/` oracle for this shape** — all the relevant
  goldens are native-sourced (oracle mis-evaluates), so **no `lib/` change is
  forced**. (Confirm: `diff_selfhost_typecheck_errors` compares native vs native
  goldens; if any added case is captured against the OCaml oracle it would force a
  `lib/` mirror — avoid by keeping new goldens native-leg.)

**Sequencing note:** Stages 1→2→3→4 are strictly sequential (shared file +
RED→GREEN ordering). Stage 0 is independent and first.

## 6. Gates / acceptance

Run `FORCE=1 bash test/build_oracles.sh` before any `test/bin/*` gate (mtime-skip
→ false pass). Required green:

- `sh test/diff_selfhost_eval_typed_modules.sh` — was 6/0, becomes **7/0** with
  the new `cross_module_method_userconstraint` fixture.
- `sh test/diff_selfhost_eval_dict.sh` — **26/0**.
- `diff_selfhost_build` — **35/0** (+ new shape built+exec == run).
- `diff_selfhost_typecheck_errors` — **40/0** (no accept/reject drift; today
  `check` wrongly accepts the bug — after the fix it must still typecheck, now
  with a real dict route, *not* start rejecting).
- `selfcompile_fixpoint` **C3a/C3b YES** (Stages 2–4 touch the emitter graph).
- Cold `bootstrap_from_seed` C3a PASS after the Stage-4 re-mint.

Acceptance: native `run` prints `Some (Box 5)`; native `build`+exec prints the
same; both equal the new native golden; all gates above green; one seed re-mint.

## 7. Open forks for the human

(a) **Read-side id remap vs. define-side id-carrying scheme** (Stage 2 shape i
vs ii). (i) is smaller and localized to `recordMethodDicts`/the method reader but
re-derives ids per call site; (ii) is more principled (snapshot and instantiation
share ids by construction) but threads through `ifaceMethodSchemes`/the import
seed and risks touching the fn path. **Recommend starting with (i)** behind the
Stage-0 confirmation, escalating to (ii) only if (i) cannot make ids align for
re-exported/diamond imports.

(b) **Definer-resolution depth.** If a method is re-exported through an
intermediate module (diamond), does the importer's instantiation see the
*original* interface's ids or the intermediate's? Stage 0 should test a
3-module re-export chain; if ids diverge there too, the fix must chase to the
**original interface definer** (same hazard the WS2 doc flags for `EVarFrom`).
**Decision needed:** how far to chase re-exports for v1 (direct-import-only vs
full transitive).

(c) **Whether to also do the WS2 `EVarFrom` fn-level re-key now.** It is a
*separate* (collision) problem and currently benign-by-construction. Recommend
**no** — keep it deferred; this gap does not need it, and coupling raises risk in
the highest-footgun file. Surface only because the brief asked.

(d) **Incremental-landing seam.** Stage 2 (id identity) is independently
mergeable and closes `run`; Stage 3 (emit parity) closes `build`. If Stage 2's
shared snapshot already fixes emit (likely, since both read the same refs), Stage
3 collapses to a verification-only stage. **Decision:** land Stage 2 alone if it
fixes both paths, or hold for a combined 2+3 merge.
