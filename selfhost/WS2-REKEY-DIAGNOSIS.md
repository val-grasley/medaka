# WS-2 full re-key — diagnosis & deferral (module-qualified dict-arity identity)

> **Follow-up (2026-06-21, `880e0fe`):** a bare-name cross-module scan prompted by this
> diagnosis found the **method-level twin** of D2 — `methodConstraintsRef` had the same
> collision with **no** qualified mirror (a genuine *unmitigated* silent soundness bug:
> `check` passes, `run` crashes, `build` prints garbage, `run`≠`build`). It is now CLOSED
> with the same proven additive pattern (`crossModuleMethodConstraintsQualRef` +
> `scopeMethodArities`), **no** AST/resolve change. The full re-key described below
> (retiring the bare tables entirely) remains deferred. See ../archive/DICT-CONFORMANCE-ROADMAP.md
> WS-2 UPDATE.

**Status: DEFERRED to a supervised landing.** The observable bug is already
closed; the remaining work is pure code-health with **zero observable payoff**,
and the only principled path (full AST-origin re-key) is a large change through
the highest-footgun area (the eval dict path) that this session could not land
with *provable* non-regression. Per the WS-2 framing, a clean stop with a precise
diagnosis is the intended outcome here. This session **did** land the requested
regression-coverage extension and proved full non-regression of the tree as it
stands.

## What was verified empirically (current `main`, unmodified canonical binary)

1. **The observable D2 collision is fully closed for every shape asked for.**
   Extended `test/eval_typed_modules_fixtures/cross_module_dict_arity/` with a
   third leaf `cleaf`/`cmid` carrying an **arity-3** constrained `wrap`
   (`(U a, V a, W a) => …`) alongside the existing arity-1 (`aleaf`, `Tag a`)
   and arity-2 (`bleaf`, `(P a, Q a)`) `wrap`s, and added a sibling fixture
   `cross_module_dict_arity_rev/` that imports the three legs in **reversed
   order**. On the unmodified binary:
   - `medaka run`  → `11 25 45` (3-way) / `45 25 11` (rev)
   - `medaka build` + exec → identical
   - the loader-driven typed-modules gate (`diff_selfhost_eval_typed_modules`,
     which drives `evalModules` over per-module frames — the loader path, not
     single-file) → both fixtures **ok**.

   So the define-side fix already in `main` (the module-attributed
   `crossModuleFunConstraintsQualRef` → `scopeArities`, commit e488cd9) handles
   1/2/3-arity collisions and import-order permutations correctly.

2. **Claim 2 from the second scoping pass is REFUTED — the bare
   `crossModuleFunConstraintsRef` is LOAD-BEARING at the call site, not a
   redundant seed.** Decisive experiment: replace the inference-time seed at
   `selfhost/types/typecheck.mdk:8136`
   (`set_ref funConstraintsRef crossModuleFunConstraintsRef.value`) with
   `set_ref funConstraintsRef []`, rebuild (`FORCE_EMITTER_REBUILD=1 make medaka`):
   the existing fixture then fails at runtime with **`intToString: not an Int`** —
   the cross-module constrained call `wrap 7` **under-applies** (the leading dict
   param swallows the `7` argument).

   Root structural reason: `Scheme = Forall ids evars t`
   (`selfhost/types/typecheck.mdk:2642`) carries **no constraint list**. The set
   of "which of a callee's quantified tyvar ids are constraint (dict) slots" lives
   **only** in `funConstraintsRef`. At a cross-module call site,
   `inferDictAt`/`inferDictAtFound` (`typecheck.mdk:2553`, `:2577`) recover the
   callee's mono via `lookupVar` (definer-correct, import-scoped) but must still
   read `funConstraintsRef[name]` for the constraint-slot ids; without them
   `anyIdPinned` is `False`, the site falls to the self-recursive `RecDictApp`
   branch, no `pendingDictApp` is recorded, yet `dictPass` still prepends the
   define-side dict param → under-application. The seed at `:8136` is the **sole**
   supplier of those ids for *cross-module* callees (per-module `resetState` at
   `:8131` wipes `funConstraintsRef`).

   => The bare table cannot simply be retired. Retiring it requires giving the
   call site **module-qualified callee identity** so it can read the
   already-existing `crossModuleFunConstraintsQualRef` (keyed `(mid,name)`) by the
   **definer** module rather than the bare first-match. That is exactly the
   AST-origin re-key (plan step 1).

## Why the bare table is nonetheless *benign by construction* today

Modules are typechecked in dependency order; each module's
`funConstraintsRef` is seeded with the accumulated cross-module table
(`:8136`) and its own entries are **prepended** during its pass. A module's
`lookupVar` env only contains the callees it actually imports, and import
resolution forbids importing two distinct same-named `wrap`s into one scope.
So the first-match the call site reads is the importing module's own callee —
correct arity — purely as a consequence of processing order + most-recent-prepend,
*not* because the table encodes module identity. The re-key would make that
identity explicit instead of emergent. Real, but zero observable behavior change.

## What a supervised landing needs (concrete, file:line)

The plan's cited precedent is weaker than assumed and adds risk:

- **`annotateProgram` / `EVarAt` is NOT a live precedent to mirror.** It lives in
  `selfhost/types/annotate.mdk` (not `resolve.mdk`), is **exported but unwired**
  (drivers never run it; eval's `EVarAt` arm is dormant — see `selfhost/README.md`
  line for `annotate.mdk`, `PERF-NOTES.md:150`), and is a **single-module
  lexical-addressing** pass (frame/slot `Addr`). It carries **no cross-module
  definer identity**. `resolve.mdk` does not currently compute a reference's
  definer module at all (`grep definerModule|ownerModule|importScope` → empty).

A correct landing therefore must:

1. **AST** (`selfhost/frontend/ast.mdk` ~`:184`, beside `EVarAt`): add a
   resolve-only node, e.g. `EVarFrom String String` (name + **definer** module
   id). Transparent: no `astdump`/sexp clause; `strip_locs`/`map_expr`-style
   catch-alls cover it.
2. **Resolve** (`selfhost/frontend/resolve.mdk`): a new post-resolve rewrite that
   tags each **cross-module** `EVar` with its **definer** module id — resolved
   **through re-exports/diamonds to the original definer**, not the importer
   (keying by importer silently re-breaks D2). This is the genuinely new,
   load-bearing logic resolve does not have today. Local refs keep bare `EVar`.
3. **Printer/fmt** (`selfhost/tools/*printer*`): render `EVarFrom n _` as bare `n`
   (like `EVarAt`/`EDictApp`) or `diff_selfhost_fmt` + round-trip break.
4. **Typecheck re-key** (`selfhost/types/typecheck.mdk`): re-key the six refs to
   `((String,String), …)` and update every reader/writer —
   - defs `:1118/1146/1179/1202/1224/1236`; qual mirror already exists `:1196`.
   - writers: `registerInferredFor :7973`, `registerMember :7647`, method
     `:7211`, `seedDictAritiesFromSigs :8991`, the `discoverPromotedModules`
     snapshot `:4131`, the per-module accumulate/seed block `:8136/8163/8170/8172`.
   - readers: `dictArityOf :6384`, the method-arity `:6160`, the enclosing-slot
     lookups `:4803` and `:6015`, `inferDictAtFound :2579/2580` — **this last is
     the new logic**: do a `(callee_module, name)` lookup via the EVarFrom origin
     instead of bare first-match.
   - `scopeArities :8869` already consumes the qual ref; keep its per-scope
     re-set (`dictPassModulesScoped :8838`) as an **identity lookup**, not deleted
     (it still provides import-scoping).
   - **`expandSupersTable :2676`** rewrites the bare refs wholesale — must be
     re-keyed in lockstep or super-slot expansion desyncs the call vs define side.
5. **`dictParamName` STAYS BARE** — `$dict_<fn>_<slot>` is body-local and
   `(encl,slot)`-unique; qualifying it would churn the emitted IR and force a seed
   re-mint for zero gain. Confirmed: leaving it bare is what keeps fixpoint safe.
6. **resetState discipline** (`:1622`): every re-keyed / new ref must reset in
   lockstep with the existing ones or state leaks across runs (fixpoint catches
   it, but localization is expensive).
7. **Highest risk — the eval/emit fork.** `funConstraintsRef` feeds **both** the
   eval (run) and emit (build) dict paths via `emitArgStampPasses`; the re-key
   must hold on **both**, and eval is where loader-only bugs hide. The regression
   test MUST drive `evalModules` (the new fixtures already do); single-file masks
   these.

Acceptance is unchanged: all 12 differential gates green (eval_dict 26/0, build
35/0, typecheck_errors 40/0, …) **plus** `selfcompile_fixpoint` C3a/C3b YES, with
`FORCE=1 build_oracles` before the mtime-skipping gates.

## What this session landed

- `cross_module_dict_arity/`: + `cleaf.mdk`/`cmid.mdk` (arity-3 leg), `main.mdk`
  now exercises all three legs, golden `11 25 45`.
- `cross_module_dict_arity_rev/`: reversed-import sibling, golden `45 25 11`.
- No `selfhost/` code change (the re-key is deferred).
- Non-regression proven: all 12 gates 0-failing, fixpoint C3a/C3b YES.
