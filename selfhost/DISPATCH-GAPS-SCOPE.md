# DISPATCH-GAPS-SCOPE.md
## Scoping Audit — Four Parked Native-Backend Dispatch Gaps
**Date:** 2026-06-10  
**Status:** READ-ONLY audit — no source edits.  
**Gaps audited:** #54 (Map `toList` H-b1), #55 (sum/product two-constraint), #50 (parametric-Ord `max`/`min`), #21 (2-level multi-module route flattening).

---

## Context

These four gaps were explicitly parked on 2026-06-10 as NOT on the Phase-C CLI capstone critical path.  They are stdlib-completeness gaps: any user program that calls `toList` on a `Map`, uses `sum`/`product`, calls `max`/`min` through a generic `Ord a`, or has a two-level boxed ADT fails at `medaka build` while succeeding under `medaka run`.

The native backend pipeline: `typecheck.mdk` `elaborateModules` route-stamps → `selfhost/llvm_emit.mdk` → text LLVM IR → `clang` → native binary.

---

## Gap #50 — `max`/`min` over generic `Ord a` (RDict → default-body synthesis)

### Minimal repro

```
-- g50_rdict_max.mdk
callMax : Ord a => a -> a -> a
callMax = max

main =
  println (callMax 3 7)
```

**Interpreter (`medaka run`):** `7`  
**Native (`medaka build` → run):** outputs `2189658104` (garbage register; exit 0)

The `max` concrete-ADT case (e.g., `max Red Blue` on a derived `Ord Color`) works correctly via `emitDefaultRKey` / E19. The concrete-ADT max-call-in-poly-context also works (slice-7 `restampIface` handles it). The gap fires specifically when the dispatch route is `RDict` — the caller keeps `a` abstract, so the route at the `max` call site is `RDict $dict_callMax_0`, routing through `emitMethodDispatch`.

### Oracle / interpreter reference

`callMax 3 7` = `7`. `callMax "a" "z"` = `"z"`. Correct output for any `Ord a` element.

### Root-cause hypothesis

**`emitMethodDispatch` / `emitDefaultDispatchChain` path** (`llvm_emit.mdk:2271–2333`).

When the route is `RDict d`, `emitMethodDispatch` loads the dict head tag and calls `emitDispatchChain`. The `max`/`min` method has NO tagged impl entries (`implsOf e "max"` = `[]` — no type-specific `max` override exists). The code at line 2287–2290 handles this:

```
[] => match defaultFor e name
        Some entry => emitDefaultDispatchChain e dictPtr headTag (ifaceTags e (methodIfaceOf name)) name entry argOps slot endL
        None => emitDispatchChain e dictPtr headTag impls name argOps slot endL
```

`emitDefaultDispatchChain` (line 2317) synthesizes `@mdk_default_max_<tag>` via `ensureDefaultEmitted`. This calls `restampIface` to re-stamp inner same-interface `compare` calls to `RKey tag`. However, `max`'s body is:

```
max x y = match compare x y
  Lt => y
  _ => x
```

When `tag` is `"Int"` (a primitive), `@mdk_impl_Int_compare` exists. The restamped inner `compare` becomes `CMethod "compare" (RKey "Int" [])`, which `emitMethod` resolves via `implFor e "compare" "Int"` → `Some entry` → direct call to `@mdk_impl_Int_compare`. This should work.

**The actual failure** is upstream: the `callMax` call site routes `RDict $dict_callMax_0`, and `callMax = max` is a point-free binding (`max` applied to zero args). The dict parameter `$dict_callMax_0` is passed in but `callMax`'s body is lowered as a partially-applied closure with `max` unapplied — the dict word is read but `max`'s default synthesis requires the concrete tag from the dict. 

The specific failure: `max` is point-free (`callMax = max`), so at the call to `callMax 3 7`, the emitter calls `callMax(dict, 3, 7)` but `callMax`'s body emits `max` in RDict mode with `arity=0` (`methodArityOf "max"` after dict prepend). The dict word loads fine, but `emitDefaultDispatchChain` calls `ensureDefaultEmitted e fname tag name entry` with `argOps = [3, 7]` (the original args) but the default body's `arity = maxInt (methodArityOf "max") ...` = 2 and is called with 2 args — but the default define `@mdk_default_max_Int` receives `(argOps)` and those words are the VALUE args, so it should work.

**More precisely:** the garbaged output `2189658104` = an uninitialized register or an integer read from a stack slot. `callMax = max` desugars to a point-free binding that emits as a GLOBAL (E1b). The global `mdk_g_callMax` is initialized in `@main`'s prologue to the VALUE of `max` — but `max` is a method reference, not a concrete function. In the `@main` prologue, `emitVar "max"` looks up `max` in the emitter's method table and (pre-dict-passing) emits a partial closure or returns `0` as a fallback. The whole-program binding `callMax = max` is stored into the global as this `0` or stale address; `callMax 3 7` then dispatches through a null/stale pointer.

**Fix location:** `selfhost/llvm_emit.mdk` — the point-free global init path for a method name. `emitVar "max"` (and all interface method names used as first-class values) should NOT be emitted as a raw var lookup; they need an eta-expanded closure wrapping the RDict dispatch. The RDict path for `emitMethodDispatch` already exists; the issue is that `callMax = max` stores the method VALUE (at compile time, before any dict is known) rather than a closure that, at call time, takes `(dict, x, y)` and dispatches. Alternative fix: detect top-level point-free `=>` constrained bindings that are pure method aliases and emit them as forwarding wrappers directly.

**Cite lines:** `llvm_emit.mdk` `emitVar` (searches `lookupVarG` / `isKnownMethod`) — the fallback for a method name in value position. Related: `emitDefaultDispatchChain` at lines 2317–2333 (correct for non-point-free callers). `emitGroupBody` / the global init path for `E1b` globals at `emitTopGlobals`.

**Note:** `max`/`min` over a directly-applied concrete ADT (`max Red Blue`) works (E19 `emitDefaultRKey`). `max`/`min` in the standard `maximum`/`minimum` prelude helpers are pruned by DCE when not called. Only a point-free or explicit-`Ord a`-constraint calller hits this.

### Fix sketch

1. In `emitVar` / `emitTopGlobals`, detect a method name appearing in value-position (the E1b global init for a binding like `f = methodName`): emit an eta-expanded closure `@mdk_eta_<method>_N(clos, dict, x1..xN)` that applies the dispatch chain, similar to `emitDefaultDefine` / `emitUnicodeEtaClosure`. 
2. Alternatively, recognize `f = method` as a constrained-fn alias at the dict-pass layer and let dict-passing emit `callMax` as a plain wrapper that calls `max` via the dict — making the RDict chain correct at the call site.

**Blast radius:** emitter-only (`llvm_emit.mdk`). No `typecheck.mdk` / `ast.mdk` changes. Does NOT touch the primitive IR paths. Self-compile fixpoint: unaffected (the compiler itself has no point-free method-alias globals). Low risk.

**STOP risk:** LOW. The existing `emitDefaultDispatchChain` and `restampIface` machinery is correct; the only new code is in `emitVar` / global init for method-name values.

### Spawn-readiness verdict

**SAFE to spawn autonomously.** Emitter-only, well-isolated. No design decision needed. Recommend **Sonnet**.

---

## Gap #55 — `sum`/`product` two-constraint dict threading (#21 Cause-B residual)

### Minimal repro

```
-- g55_twocstr.mdk
sumOf : (Foldable t, Num a) => t a -> a
sumOf = fold (+) 0

main =
  println (sumOf [1, 2, 3])
```

**Interpreter:** `6`  
**Native:** SIGABRT (exit 133), no output.

Also reproduces by calling `sum [1, 2, 3]` directly from a program that causes `sum` to be dict-passed with BOTH constraints live.

```
-- g55_sum.mdk
main =
  println (sum [1, 2, 3])
```

**Interpreter:** `6`  
**Native:** SIGABRT (exit 133)

### Oracle / interpreter reference

`sum [1, 2, 3]` = `6`. `product [2, 3, 4]` = `24`.

### Root-cause hypothesis

`sum` and `product` in `stdlib/core.mdk` are:

```
sum     : (Foldable t, Num a) => t a -> a  =  fold (+) 0
product : (Foldable t, Num a) => t a -> a  =  fold (*) 1
```

Two constraints: `Foldable t` (the container) and `Num a` (the element). The dict-passing layer (`dictPass` / `elaborateModules`) must thread TWO dict params: `$dict_sum_0` (Foldable) and `$dict_sum_1` (Num). The native `@mdk_sum` function signature must be `(dict_fold, dict_num, xs)`.

The Cause-B residual tracked in PLAN means: the `elaborateModules` path (the multi-module native build path) does not correctly thread BOTH dict params for a two-constraint function. Likely one of:

1. `constraintMonosOf` at `typecheck.mdk:1887–1891` silently drops a constraint id that doesn't appear in the substitution (`None` arm returns nothing). If `sum`'s second constraint tyvar (`Num a`) doesn't have a live cell in the instantiation subst at the call site, its route is dropped → caller passes one dict instead of two → callee reads garbage for the second dict param → SIGABRT.

2. `resolveDictApps` / `routesOfMonos` routes `sum`'s two constraint monos but the second one (`Num a` where `a = Int`) picks `RKey "Int"` while `$dict_sum_1` expects an `Ord` or `Num` witness — the wrong-size dict cell SIGSEGV.

3. `funConstraintsRef["sum"]` maps only the first constraint tyvar id (the `Foldable t` one) because `seedDictAritiesFromSigs` / `constrainedSigNames` only registers ONE constraint per function, ignoring the second.

**Most probable:** point 3. `constrainedSigNames` (`typecheck.mdk`) was designed for single-constraint fns; two-constraint fns have two `=>` constraints in their scheme. The seed / arity machinery may only capture one. Cross-reference PLAN "Cause-B residual" — Cause B was the `implTable` gap (closed for one-level), and `sum`/`product` are the remaining Cause-B shape because their SECOND constraint dict is not passed.

**Check location:** `typecheck.mdk` `constrainedSigNames` (how multi-constraint fns register their dict params), `funConstraintsRef` population for `sum`/`product`, and `dictPassDecl` / `prependImplDictIfUser` for how leading dict params are prepended. Also `dictPass`'s `dictDef` arm for multi-constraint `=>`-fns.

**Note:** Single-constraint fns (`neq : Eq a => ...`, `elem : (Foldable t, Eq a) => ...`) work (D3b-2 done). The `elem` case has TWO constraints `(Foldable t, Eq a)` — so if `elem` works, there may be a `sum`/`product`-specific issue (they are point-free: `sum = fold (+) 0`, not `sum xs = ...`). Point-free two-constraint may hit the same point-free method-value-in-global issue as #50.

### Fix sketch

1. Verify `funConstraintsRef["sum"]` has two ids (Foldable + Num), not one. If one: fix `constrainedSigNames` or `registerConstraintRegs` to capture all `=>` constraint vars for multi-constraint fns.
2. If both ids are registered but one route resolves to `RNone`: add a fixture that explicitly passes both dicts and trace which route is missing.
3. Point-free two-constraint global: same eta-expansion fix as #50 may apply jointly.

**Blast radius:** `typecheck.mdk` `constrainedSigNames`/`registerConstraintRegs` + possibly `llvm_emit.mdk` global init. Does NOT touch the primitive IR. Self-compile fixpoint: unaffected (compiler doesn't call `sum`/`product`). Low risk provided the fix is additive and gated behind `argStampEnabled`.

**STOP risk:** MEDIUM. Multi-constraint fns share machinery with working single-constraint fns — a careless edit can break `elem`/`any`/`all`/`neq`. Needs regression fixtures for the working single-constraint cases.

**Cross-gap coupling:** Shares the point-free-global root cause with #50 if both are point-free method-value globals. Fixing #50 first may resolve #55 as a free side effect — investigate #50 before separately attacking #55.

### Spawn-readiness verdict

**SAFE to spawn**, but **recommend fixing #50 first** and re-checking if the gap persists. If #55 is solely the two-constraint case (and `elem` which has two constraints works), there may be a `sum`-specific point-free vs `elem`-specific direct-application difference. Recommend **Sonnet** with explicit instruction to check `elem [1,2,3] 2` natively first.

---

## Gap #54 — Map `toList` bare-name (H-b1, standalone shadows Foldable method)

### Minimal repro

```
-- g54_map_tolist.mdk
import map.{Map, toList, fromList}

main =
  let m = fromList [(1, "a"), (2, "b")] : Map Int String
  println (debug (toList m))
```

**Interpreter:** `[(1, "a"), (2, "b")]`  
**Native:** `panic: no impl of method 'toList' for type 'Map' (slice 6)` (compile-time emitter panic; exit non-zero)

The same panic occurs inside `map.mdk`'s own `eq`/`compare`/`debug`/`display` impl bodies (each calls standalone `toList` on a `Map` receiver). The emitter sees a method call `toList` routed as `RKey "Map"`, calls `implFor e "toList" "Map"` → `None` (no `impl Foldable (Map k v)` exists), then calls `emitDefaultRKey` → `defaultFor e "toList"` → `None` (no interface default) → `gapE "no impl of method 'toList' for type 'Map'"`.

### Oracle / interpreter reference

`toList (fromList [(1, "a"), (2, "b")])` = `[(1, "a"), (2, "b")]` (sorted by key). `debug` / `display` on a `Map` also use standalone `toList` internally and work on the interpreter.

### Root-cause: two-layer requirement

**Layer 1 (typecheck route-stamping):** The C5 / Phase-112 machinery (`resolveRLocalSites`, `typecheck.mdk:3306–3332`) is already present and CORRECT: when a method call `toList` is in a standalone-shadow context and the receiver grounds to `Map` (which has no `Foldable` impl), `stampRLocalOrFallback` sets the route to `RLocal`. This routes the emitter to `emitMethod … RLocal => emitKnownFnSat e ("mdk_" ++ name) argOps …` — a direct call to `@mdk_toList` (the standalone map function).

**However**, this only fires if:
- `standaloneValuesRef` contains `"toList"` for this module (populated by `buildStandaloneShadows` — requires `toList` to appear as a `funDef` in `implDecls` AND be an interface method name AND NOT be a local def)
- `pendingRLocalSites` has an entry for the `toList` occurrence — which requires `inferMethodAt` to have fired for that occurrence, which requires the IMPL BODY where the call lives to have been typechecked

**The `inferImplBodiesIfEnabled` gate:** impl body inference is gated ON only on the emit path (`implInferEnabled = True` set by `elaborateDict` / `elaborateModules`). The impl bodies of `map.mdk` (`eq`, `compare`, `debug`, `display`) that call `toList` ARE inferred when `implInferEnabled` is on. So `pendingRLocalSites` SHOULD receive the `toList` entries.

**Layer 2 (emitter direct call):** `emitKnownFnSat e "mdk_toList" argOps (fnArity e "mdk_toList") (fnRetTy e "mdk_toList")`. The emitter's `fnArity` table is populated from the program's `DFunDef` declarations seen during `emitDecl`. `map.mdk`'s `toList` is a multi-module import — its `DFunDef` appears in `allDecls` but IS it emitted into the current binary? In `medaka build` (the `llvm_emit_modules_main` path), all modules are flattened into one `CProgram` and emitted together. So `@mdk_toList` (the standalone map function) should be defined. `fnArity e "toList"` would return its arity (1). So the emitter call should work.

**The actual gap location:** The panic fires at the EMITTER (line 453 = `gapE`), meaning the route arriving at `emitMethod` is `RKey "Map"` (not `RLocal`). So `resolveRLocalSites` is NOT stamping `RLocal` correctly. The likely reason: `buildKeyTable implDecls` passed to `resolveRLocalSites` contains a `KeyEntry` for `Map` that lists `toList` as one of its methods — because `map.mdk` defines `toList` as a standalone AND the key table builder includes all top-level decl names as "methods" without distinguishing standalone vs impl-method. If `implExistsForHead keyTable "toList" "Map"` returns `True` (incorrectly, because the key table counts the standalone `DFunDef toList` as an impl), then `stampRLocalOrFallback True` resets to `RNone` (eval path) or leaves `RKey` intact (emit path) — and the emitter panics.

**Fix location:**
- `typecheck.mdk` `implExistsForHead` (line ~3294) — the `KeyEntry` should only list impl METHOD names, not standalone function names. Or
- `buildKeyTable` must only populate `KeyEntry.methods` from `DImpl` declarations, not from `DFunDef` top-level functions named `toList`.
- Verify by adding a `debug (implExistsForHead keyTable "toList" "Map")` print — if True, that's the bug.

**The two-layer explanation from the task brief:** Layer 1 = the route fix (RLocal stamp — already in code), Layer 2 = the `buildKeyTable` / `implExistsForHead` correctness fix so Layer 1 fires. Without both, either the route is wrong (Layer 1 missing) or it routes correctly but `implExistsForHead` mistakenly says an impl exists (Layer 2 missing, Layer 1 fires with wrong data).

**Cite lines:**
- `typecheck.mdk:3294–3298` `implExistsForHead`
- `typecheck.mdk:5490–5500` `buildStandaloneShadows`
- `typecheck.mdk:5847–5850` `elabModuleStamp` calling `resolveRLocalSites`
- `llvm_emit.mdk:2126–2132` `emitMethod RLocal` arm

### Fix sketch

1. Add a diagnostic: print `standaloneValuesRef.value` and `implExistsForHead keyTable "toList" "Map"` in a probe build.
2. Fix `buildKeyTable` to populate `KeyEntry.methods` only from `DImpl` method sets (not `DFunDef` declarations). `KeyEntry` is built from `DImpl` in oracle too — confirm the `selfhost` version excludes `DFunDef`.
3. Regression fixtures: a program using `map.toList` standalone (not via Foldable), AND a program using `toList (Some x)` (genuine Foldable method) — both must work after the fix.

**Blast radius:** `typecheck.mdk` `buildKeyTable` / `implExistsForHead` (one-liner fix if the diagnosis is correct). Emitter untouched. Self-compile fixpoint: unaffected (compiler never calls `toList` on a `Map`). Low risk.

**STOP risk:** LOW. The C5 RLocal machinery is already present and tested; this is a one-node fix in key-table construction.

### Spawn-readiness verdict

**SAFE to spawn autonomously.** Well-scoped: diagnose `implExistsForHead` + fix `buildKeyTable` + add fixtures. Recommend **Sonnet**.

---

## Gap #21 — 2-level multi-module route flattening (`Box (List (List Int))`)

### Minimal repro

```
-- g21_two_level.mdk
data Box a = Box (List (List a))

impl Eq (Box a) requires Eq a where
  eq (Box xs) (Box ys) = eq xs ys

main =
  let b1 = Box [[1, 2], [3, 4]]
  let b2 = Box [[1, 2], [3, 4]]
  println (b1 == b2)
```

**Interpreter:** `True`  
**Native:** SIGABRT (exit 133), no output.

One-level nesting works (closed by GAP 1 / `5913297`):

```
data Box a = Box (List a)
impl Eq (Box a) requires Eq a where ...
-- eq (Box [1,2]) (Box [1,2])  → True  (both paths)
```

Two-level (`Box (List (List a))`) SIGSEGVs natively.

### Oracle / interpreter reference

`b1 == b2` = `True`. Any depth of structural equality (`eq`) over nested `Box (List (List Int))` works on the interpreter.

### Root-cause hypothesis

**Route flattening in `elabModuleStamp`** (`typecheck.mdk:5836–5859`).

GAP 1 (`5913297`) closed the EMITTER dict-witness representation: `dictWordOfRoute (RKey tag reqs)` now boxes the witness as a heap cell `[head_tag | reqdict_0 | …]` so nested reqs can be stored. The emitter's `emitDispatchChain` and `emitMethod` correctly load nested dict fields.

The remaining gap is UPSTREAM: when `elabModuleStamp` calls `resolveSites stampImplTable (buildKeyTable implDecls) [] pendingSites.value`, the `stampImplTable` passed to `implDictRoutesFor` is built from `implDecls` for the CURRENT module. For the two-level case, `Box`'s element type is `List (List a)`. `implDictRoutesFor` calls `implReqRoutes` → `reqRoute` → `implRequiresRoutesRec implTable "List" (List (List a))`.

`implRequiresRoutesRec` (`typecheck.mdk:3796–3801`) finds the `Eq (List a) requires Eq a` entry in `implTable`, matches `headTy = TyApp (TyCon "List") (TyVar "a")` against `List (List a)` → subst `a := List a`. Then calls `implReqRoutes implTable subst [Require _ [TyVar "a"]]` → `reqRoute implTable subst [TyVar "a"]` → `fromAstType subst (TyVar "a")` = `List a` (the inner list mono). Then `headTyconMono (List a)` = `Some "List"`, and recurses: `implRequiresRoutesRec implTable "List" (List a)`.

Now `List a` where `a` is still a free type variable. `findImplEntry implTable "List" (List a)` finds `Eq (List a) requires Eq a` again. `matchTyMono (TyApp List TyVar "a") (List a)` → subst `a2 := a` (a fresh var or the original). Then `implReqRoutes` recurses into `Require _ [TyVar "a2"]` → `reqRoute` → `fromAstType subst2 (TyVar "a2")` = `a` (the element var). `headTyconMono a` = `None` (it's a TVar) → `RNone`.

**So the RETURN from `implRequiresRoutesRec "List" (List a)` is `[RNone]`** — the innermost element is a free type variable, not ground. This gives: `Box`'s requires → `[RKey "List" [RNone]]`. In the boxed-cell rep: `[hashName "List" | 0]` (the inner dict is 0 because `RNone` → `dictWordOfRoute RNone = "0"`). When the emitter calls `eq (List (List Int))` and tries to load the inner dict, it loads 0 (a null/zero pointer) → SIGSEGV.

**The core issue:** `elabModuleStamp` uses `buildImplTable implDecls` but this table only contains the CURRENT module's impl declarations (not the full recursive chain). For `Box`, when processing the user's entry module, `implDecls = accAll ++ prog` = everything accumulated. But when processing intermediate modules, only their own decls are present. More critically: at the `Box` call site, `implRequiresRoutesRec` terminates at `List a` because `a` is still abstract — the caller's concrete `Int` has not yet propagated.

**Difference from single-file (`elaborateDict`):** the single-file path runs all impl inference with a fully-populated impl table and the concrete call `b1 == b2` has grounded `a := Int` by the time the route is stamped. The multi-module path stamps routes MODULE BY MODULE, and `Box`'s `eq` impl body is inferred inside `map.mdk`'s (or here, the entry module's) typecheck pass. When `resolveSites` runs for the user module, `Box`'s impl body has been inferred and the call site `eq xs ys` has `xs : List (List a)` — still with `a` abstract, because the method body uses the impl's type variable. `headTyconMono (List a)` gives `"List"` but the inner `a` is abstract → `implRequiresRoutesRec` returns `[RNone]` for the innermost level.

**Fix location:**
- `typecheck.mdk` `implRequiresRoutesRec` / `reqRoute` — when the element remains abstract (`RNone` for the inner level), the route is under-nested. The fix needs to defer stamping or propagate the concrete element type down from the call site.
- OR: `elabModuleStamp` must propagate the concrete call-site type into the impl body's route resolution. This is the "Cause-B two-level" residual noted in `EMITTER-GAPS.md` §GAP-1 residual.
- The EMITTER-GAPS.md GAP-1 residual note states: "with a properly-nested route the emitter handles arbitrary depth (`[[[Int]]]` direct lists work)." This confirms the emitter is correct; the gap is the typecheck route-building in the multi-module path.

**Depth vs GAP 1:** For `List (List Int)` (no custom Box wrapping), the nested `[[1,2]] == [[1,2]]` works natively because `List`'s own `Eq` impl is in `core.mdk` (which `elabModuleStamp` sees as `accData`), and when the entry module calls `eq [[1,2]] [[1,2]]` directly, `resolveSites` stamps the route from the CONCRETE `List (List Int)` result type → `implRequiresRoutesRec "List" (List Int)` → subst `a := Int` → `RKey "Int" []`. The `Box` case fails because the impl body inference sees `List (List a)` with `a` abstract.

**Blast radius:** `typecheck.mdk` route-building for multi-level parametric impls. Potentially large: any two-level `requires`-chain is affected. The fix may require passing the concrete instantiation through into `implRequiresRoutesRec` or post-processing after call-site inference. Does NOT touch primitive IR. Self-compile fixpoint: unaffected (compiler has no two-level nested `Eq` requirements). Medium risk.

**STOP risk:** HIGH. This is the "Phase 134 shape" — a loader-only dispatch bug that appears simple but involves the interaction between per-module inference, abstract type variables, and recursive route building. The Phase 134 experience showed that "no divergence" between paths does NOT exonerate the fix. The fix needs a `test_loader`-style multi-module gate, not a doctest. Recommend human oversight before landing.

### Spawn-readiness verdict

**CAUTION — recommend human oversight before spawning.** The root cause analysis is sound (route flattening in multi-module path), but the fix location has uncertain blast radius. If spawning: use **Opus** (the complex route-threading required), explicit instruction to add a `test_loader`-style multi-module regression fixture (not a doctest), and verify `[[[Int]]]` lists still work after the fix. Gate: `test/bootstrap_eval.sh` and `test/diff_selfhost_llvm_modules.sh` must stay green.

---

## Cross-gap shared root causes

All four gaps share one structural property: **they only fail on the multi-module `elaborateModules` / `elabModuleStamp` path**; the single-file `elaborateDict` path handles them correctly or avoids them. This is the documented "Phases 96/103/121/125/134 loader-only" pattern.

Three gaps (#50, #54, #55) have a second shared cause: **point-free top-level function bindings** that reference interface methods as values. `callMax = max`, `sumOf = fold (+) 0`, and `toList` (standalone, not point-free but referenced as a method). The E1b global-init path emits these bindings before any dispatch information is available, potentially storing `0` or a stale closure pointer.

Gaps #50 and #55 may share a single root: both involve a point-free two-level function (`callMax = max`, `sumOf = fold (+) 0`) that is stored as a global, and fixing the global init for method-value globals may resolve both.

Gap #21 is distinct: it is a typecheck route-building failure (abstract element variable not propagated through `implRequiresRoutesRec`) rather than a global-init or key-table issue.

Gap #54 is distinct: it is a key-table correctness issue in `resolveRLocalSites` (`implExistsForHead` returning a false positive from standalone `DFunDef` entries in the key table).

---

## Summary table

| Gap | Repro | Interpreter | Native | Root-cause location | Blast radius | STOP risk | Recommend |
|-----|-------|-------------|--------|--------------------|----|------|-----------|
| #50 | `callMax : Ord a => a -> a -> a; callMax = max; main = println (callMax 3 7)` | `7` | `2189658104` (garbage, exit 0) | `llvm_emit.mdk` `emitVar` / `emitTopGlobals` — method name in value/global position | Emitter-only | LOW | Sonnet |
| #55 | `sumOf : (Foldable t, Num a) => t a -> a; sumOf = fold (+) 0; main = println (sumOf [1,2,3])` | `6` | SIGABRT (exit 133) | `typecheck.mdk` `constrainedSigNames`/`registerConstraintRegs` for multi-constraint fns; possibly same point-free global as #50 | typecheck.mdk + emitter (small) | MEDIUM | Sonnet (after #50) |
| #54 | `import map.{Map, toList, fromList}; main = println (debug (toList (fromList [(1,"a")])))` | `[(1, "a")]` | emitter panic `no impl of method 'toList' for type 'Map'` | `typecheck.mdk` `buildKeyTable`/`implExistsForHead` — standalone `DFunDef` mistaken for an impl-method in key table | typecheck.mdk (one-liner) | LOW | Sonnet |
| #21 | `data Box a = Box (List (List a)); impl Eq (Box a) requires Eq a where eq (Box xs)(Box ys) = eq xs ys; main = println (Box [[1,2]] == Box [[1,2]])` | `True` | SIGABRT (exit 133) | `typecheck.mdk` `implRequiresRoutesRec` — abstract element var not ground in multi-module path; two-level nested route resolves to `RKey "List" [RNone]` instead of `RKey "List" [RKey "Int" []]` | typecheck.mdk route-building (medium) | HIGH | Opus, human oversight |

---

## Gaps not reproduced

All four gaps were reproduced. None failed to trigger on the native path.

---

## Files relevant to each gap

| Gap | Key files |
|-----|-----------|
| #50, #55 | `selfhost/llvm_emit.mdk` (`emitVar`, `emitTopGlobals`, `emitMethodDispatch`, `emitDefaultDispatchChain`); `selfhost/typecheck.mdk` (`constrainedSigNames`, `registerConstraintRegs`, `funConstraintsRef`, `elabModuleStamp`) |
| #54 | `selfhost/typecheck.mdk` (`buildKeyTable`, `implExistsForHead`, `resolveRLocalSites`, `buildStandaloneShadows`, `elabModuleStamp`); `stdlib/map.mdk` (standalone `toList` at line 350; calls in `eq`/`compare`/`debug`/`display` impls lines 447–482) |
| #21 | `selfhost/typecheck.mdk` (`implRequiresRoutesRec` line 3796, `reqRoute` line 3784, `elabModuleStamp` line 5836, `resolveSites` line 3279); `selfhost/llvm_emit.mdk` (`dictWordOfRoute`, `emitDispatchChain`, `loadReqDicts`) |
