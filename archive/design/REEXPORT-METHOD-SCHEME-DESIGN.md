# Re-export does not thread schemes into the importer's typecheck seed

**Status:** IMPLEMENTED — see `compiler/types/typecheck.mdk:12373`, `reexportSeed :
List Decl -> List (String, List (String, Scheme)) -> List (String, Scheme)`,
matching this doc's proposed mechanism; fixture
`test/eval_typed_modules_fixtures/cross_module_method_userconstraint_diamond/`
(named in this doc's Stage 0 plan) exists in the tree.

Status: DESIGN (read-only investigation, 2026-06-25). Base verified: `git
merge-base --is-ancestor 221af36 HEAD` → BASE_OK (D2 method-constraint fix
landed). No source edited.

## TL;DR

The reported gap — interface methods unbound through an `export import`
re-export — is **real but NOT method-specific**. It is a *general* gap: an
`export import` re-export threads names through **resolve** and the **loader**
export sets, but the **typecheck import seed** (`pubV`/`depEnv` in
`typecheck.mdk`) carries only names a module *defines*, never names it
*re-exports*. So **values, functions, AND methods** all go unbound one hop
downstream. The fix is a single, contained addition in `typecheck.mdk`
(thread re-exported schemes into `pubV`). Marking and D2 dict-dispatch already
work cross-module via the flat-union `accAll`/`implDecls`, so once the scheme
reaches the importer's seed the method dispatches correctly — verified by the
fact that a **direct** (2-module) method import works end-to-end today.

This is **orthogonal to the F1b loader module-identity item** (✅ since DONE 2026-06-25, `ac4b04a`;
that was about the same file double-loading under two import spellings; here each module
loads exactly once and the loader/resolve export sets are correct).

## Problem — reproduced verbatim (current `main`, native `./medaka` + frozen oracle)

Project layout (`medaka.toml` present), three modules:
- `leaf.mdk`: `public export data Box a = Box a` + `export interface Tagger t
  where tagOf : t a -> Int` + `export impl Tagger Box where tagOf b = 7`
- `mid.mdk`: `export import leaf.{tagOf, Tagger}`
- `main.mdk`: `import mid.{tagOf}` + `import leaf.{Box(..)}` + `main = println
  (tagOf (Box 5))`

| Case | native `check` | native `run` | native `build` | oracle `check`/`run` |
|------|----------------|--------------|----------------|----------------------|
| **Re-export method** (leaf→mid→main) | `TYPE ERROR: Unbound variable: tagOf` | `unbound method: tagOf` (exit 1) | `unbound method: tagOf` (exit 1) | `Unbound variable: tagOf` (exit 1) |
| **Direct method** (leaf→main) — CONTROL | `main : Unit` (ok) | `7` (ok) | n/a | (frozen; consistent) |
| **Re-export VALUE** (`shade`/`answer` via mid) | `TYPE ERROR: Unbound variable: shade` | type error | — | `Unbound variable: shade` |
| **Direct VALUE** — CONTROL | ok | `42` | — | ok |

Key observations:
1. The **direct** method import works fully (`run` → `7`). The **only**
   difference vs. the failing case is the extra `export import` hop.
2. **Value re-export fails identically** — even the existing resolve fixture
   `test/resolve_module_fixtures/reexport_chain` (`shade` re-exported via `mid`)
   fails at typecheck when actually run as a project. So the brief's premise
   that "value/type re-exports already work" does **not** hold at the typecheck
   layer; only resolve handles them.
3. Native and frozen oracle agree (both unbound), so this is a shared
   front-end gap, not a native regression.
4. The constrained-method variant (`btraverse : Thenable m => …`, the existing
   `cross_module_method_userconstraint` fixture) is the same shape and fails the
   same way through a re-export hop — independent of the D2 dict machinery.

Repro lives in the session scratchpad (`…/scratchpad/method3`, `…/chain`).

## Root cause — located by symbol (line numbers drift)

### Resolve is COMPLETE (not the gap)
`compiler/frontend/resolve.mdk` already computes a re-exporting module's full
export set from its `export import` paths: `pubUsePaths` (filters `DUse True
path`), `reexportNamesOf`, `reExpValues`/`ifaceValsOf` (pulls interface methods
of a re-exported interface), `reExpTypes`/`reExpCtors`/`reExpInterfaces`/
`reExpIfaceMethods`. That is why the re-export `check` error is a **TYPE
ERROR** (`Unbound variable`) at the inference stage, not a resolve/name error —
resolve let `tagOf` through.

### Typecheck seed is the gap
`compiler/types/typecheck.mdk`:
- `importSeed` (walks a module's `DUse` decls, picks imported names out of the
  named dependency's public schemes held in `depEnv`) is how an importer's
  environment gets dependency schemes. It is correct for *direct* imports.
- The dependency's public schemes are built in `checkModulesGo` /
  `checkModulesDiagsGo` / `checkModulesEntryFullGo` / `elabModulesGo` as:
  `pubV = pickSchemes (publicValNames prog) schemes`, then carried forward as
  `(mid, pubV) :: depEnv`.
- **`publicValNames`** collects ONLY names *defined* in `prog` — its arms are
  `DFunDef True` / `DTypeSig True` / `DExtern True` / `DInterface {pub=True}`.
  There is **no `DUse` arm**, so a re-export (`DUse True path`) is dropped by
  the catch-all. A re-export-only module (`mid`) therefore has an **empty
  `pubV`**, and the downstream importer's `importSeed` finds nothing for the
  re-exported name → `Unbound variable`.
- Even if `publicValNames` returned the name, `checkModuleFullImpl` returns
  `globalS ++ topSchemes` (this module's own globals + top-level schemes,
  **not** the seed). So `pickSchemes` over `schemes` could not recover an
  imported scheme anyway — the re-exported scheme must be pulled from
  `depEnv` (the *source* dep's `pubV`), not from `schemes`.

So the gap is precisely: **`pubV` has no notion of re-exports.** Resolve's
re-export machinery has no typecheck-seed counterpart.

### Why marking + D2 dispatch are NOT implicated
- `markWith` (`frontend/marker.mdk`) sets `methods = preludeMethods ++
  interfaceMethodNames prog2`; in the multi-module path `elabModuleStamp`
  stamps routes over `implDecls = accAll ++ prog` — a **flat union** of core +
  every earlier module + this module. So `leaf`'s interface + impl + the D2
  `crossModuleMethodConstraintsRef` records are in scope for `main` regardless
  of re-export. The direct-import success proves the marking/dispatch side is
  already complete cross-module.
- Therefore: once `tagOf`'s **scheme** (the *original* leaf scheme, by
  identity, since `depEnv` holds leaf's `pubV` computed when leaf was checked)
  reaches `main`'s seed, dispatch follows automatically and the D2
  diamond-safety claim (original-definer constraint ids) holds by construction.

## Recommended mechanism

Mirror resolve's re-export computation into the typecheck seed. Add a helper
(name e.g. `reexportSeed : List Decl -> depEnv -> List (String, Scheme)`) that
walks `DUse True path` decls (the `pubUsePaths` filter, already the resolve
convention) and, for each, resolves the imported member names against the
**source dependency's `pubV`** in `depEnv` — exactly the `importFormSchemes` /
`resolveMemberSchemes` logic `importSeed` already uses, but gated on the `pub`
flag and emitting *outgoing* (re-export) pairs rather than seeding the current
module. Then at each `pubV` construction site:

```
pubV = pickSchemes (publicValNames prog) schemes ++ reexportSeed prog depEnv
```

Properties:
- **Original-definer identity preserved** — schemes come from `depEnv` (the
  definer's `pubV`), never re-generalized, so D2 constraint-id alignment holds
  through the hop.
- **Transitivity is automatic** — `pubV` now accumulates re-exports and is
  carried forward as `depEnv`, so a second `export import` hop
  (`mid2 export import mid.{tagOf}`) re-resolves against `mid`'s already-enriched
  `pubV`. (Confirm with a 4-module chain fixture; see forks for the policy call
  on whether to *bound* depth.)
- **Reuses existing member-resolution** (bare key + `__<name>` mangled-suffix
  fallback in `resolveMemberSchemes`), so it works on both golden and emit
  paths.
- Methods need **no special case** — `leaf`'s `pubV` already contains the
  method scheme (`publicValNames` includes `DInterface` method names), so
  re-export threads the method scheme by the same code path as a value.

Distinguish (answer to design Q2): the name **is** present in the
intermediate's resolve export set, but **absent from its typecheck `pubV`** —
the fix is purely in typecheck seed plumbing, in **one** logical place
replicated across the four module-driver loops.

## Locked decisions
- Fix lives in `compiler/types/typecheck.mdk` only (front-end seed); no
  resolve/loader change needed (both already correct).
- Mechanism = mirror resolve's re-export set into `pubV`, pulling schemes from
  `depEnv` to preserve definer identity (NOT method-specific plumbing — one
  general `reexportSeed` covers value/fn/method).
- This is NOT F1b: each module loads once; loader/resolve export sets are
  correct. Orthogonal, no coordination required.

## Staged plan (ascending risk; each stage independently gated + mergeable)

All stages touch `typecheck.mdk` ⇒ **sequential** (no parallelizing). `typecheck.mdk`
**is in the emitter self-compile graph** ⇒ each stage that lands code must pass
fixpoint (selfcompile C3a/C3b); the **seed re-mint is deferred and batched at
the end** (and batches with the already-deferred D2 seed re-mint). Run
`FORCE=1 bash test/build_oracles.sh` before any `test/bin/*` gate.

**Stage 0 — fixtures + failing gate (no source change).**
Add `test/eval_typed_modules_fixtures/cross_module_method_userconstraint_diamond/`
(leaf defines `BoxTrav`/`btraverse` + `Box(..)`; mid `export import
leaf.{btraverse, BoxTrav}`; main `import mid.{btraverse}` + `import
leaf.{Box(..)}`), golden `main.eval.golden = "Some Box 5"`. Golden is
**native-sourced** (the frozen oracle CANNOT produce it — it fails the case),
which is the preferred direction. Also add a plain-value re-export fixture
under `test/resolve_module_fixtures`-style coverage if a value gate exists.
Gate: `diff_compiler_eval_typed_modules.sh` goes 7→8 fixtures and the new one
**FAILS** (proves the gap). Risk: none (test-only).

**Stage 1 — `reexportSeed` helper + wire into `checkModulesGo`.**
Implement the helper; append to `pubV` in `checkModulesGo`. This fixes the
`check`/typecheck path for one hop. Gates: `diff_compiler_check_cli_modules.sh`,
`diff_compiler_check_modules.sh`, `typecheck_errors` (no regressions — verify a
re-export does NOT now leak a *private* name; only `DUse True` is threaded).
Risk: low. Shares `typecheck.mdk` ⇒ after Stage 0.

**Stage 2 — wire into the eval/elab + diags + entry loops.**
Same one-line append in `checkModulesDiagsGo`, `checkModulesEntryFullGo`,
`elabModulesGo` (the run/build + project-diagnostics paths). After this the
new diamond fixture passes. Gates: `diff_compiler_eval_typed_modules.sh`
(now **8/0**), `diff_compiler_eval_modules.sh`, `eval_dict`. Risk: low–medium
(touches the run path; verify no double-seeding/ambiguity for a name both
defined and re-exported — `lookupAssoc` first-wins makes duplicates benign but
confirm the defined scheme wins where intended).

**Stage 3 — transitivity + build/native end-to-end.**
Add a 4-module chain fixture (two `export import` hops) and a `medaka build`
smoke. Gates: `build` diff suite, `diff_native_cli` (rebuild `./medaka` fresh
first — stale-binary footgun), and confirm constructor re-export's documented
"abstract downstream" quirk is unchanged (do NOT alter ctor re-export
semantics here). Risk: medium (confirms no interaction with mangled emit-path
keys).

**Stage 4 — fixpoint + batched seed re-mint.**
`FORCE_EMITTER_REBUILD=1 make medaka`; selfcompile fixpoint (C3a/C3b) must hold;
re-mint `compiler/seed/*` **once**, batched with the deferred D2 re-mint;
cold-bootstrap PASS. Gates: `selfcompile_fixpoint`, `bootstrap_from_seed`.
Risk: medium (seed currency); mechanical once Stages 1–3 are green.

## Gates / acceptance
- `diff_compiler_eval_typed_modules.sh` → **8/0** (new
  `cross_module_method_userconstraint_diamond` passes; existing 7 unchanged).
- `eval_dict`, `typecheck_errors` → no regressions (esp. no private-name leak
  via re-export; only `DUse True` threaded).
- `diff_compiler_check_cli_modules.sh` / `diff_compiler_check_modules.sh` →
  green (re-export `check` resolves).
- `build` diff suite + `diff_native_cli` (fresh `./medaka`) → green.
- `selfcompile_fixpoint` holds; seed re-minted (batched w/ D2); cold-bootstrap
  PASS.
- Always `FORCE=1 bash test/build_oracles.sh` before `test/bin/*` gates.

## Open forks (need a human decision)
1. **Re-export transitive depth.** The proposed mechanism makes chains of
   `export import` work to arbitrary depth automatically (pubV accumulates).
   Is unbounded transitive re-export the intended semantics, or should depth be
   bounded / one-hop only? (Resolve currently appears to allow chains —
   `reexport_chain` fixture — so unbounded matches resolve. Confirm.)
2. **Mirror value/type path vs. method-specific plumbing.** Recommendation is
   the *general* mirror (one `reexportSeed` for value/fn/method), because value
   re-export is ALSO broken and a method-only fix would leave that gap. Confirm
   you want the general fix (closes the value gap too) rather than scoping
   strictly to methods per the original brief framing.
3. **Value-re-export is currently broken — in scope?** This investigation found
   value/function re-export fails identically (not just methods). The general
   fix closes it for free. Confirm that widening from "method gap" to "re-export
   seed gap" is acceptable (it is the principled close-the-gap-generally move;
   net-smaller than two separate fixes).
4. **Constructor re-export "abstract downstream" quirk.** Out of scope here
   (documented design: `export import T(..)` yields an abstract type
   downstream). Confirm we leave ctor re-export semantics untouched — this
   design only threads *value/method schemes*.
5. **F1b interaction — confirmed orthogonal.** Stated as locked, but flagging
   for your sign-off: this fix does not touch loader module identity; if you
   expect re-export to interact with the cross-package double-load model,
   that's a separate (bigger) call.
