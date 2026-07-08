# P0-18 standalone-fn-shadows-interface-method — dispatch miscompile (DEFERRED, DO FIRST next session)

**Status (2026-07-08):** diagnosed, NOT fixed. The user chose **Option A (the principled
per-receiver fix)** and asked that it be **the first thing tackled next session**. This doc is
the complete diagnosis + plan so the next agent starts from the map, not a treasure hunt.

It is the **last failing fixture** in the run≡check agreement gate
(`test/diff_compiler_run_check_agreement.sh` → 12 pass / **1 fail** =
`p0_18_standalone_fn_shadows_iface_method`). Every other fixture is green. When this lands and
`.expected` stays `ACCEPT`, the gate goes 13/0 and Theme 1 (run≠check) is fully closed.

## Repro (fixture `test/run_check_agreement_fixtures/p0_18_standalone_fn_shadows_iface_method.mdk`)
```
interface Sizeable a where
  size : a -> Int
data Box = Box Int
impl Sizeable Box where
  size (Box n) = n
size : Int -> Int
size n = n + 1
main = println (size (Box 3))
```
`size` is BOTH an interface method AND a standalone `size : Int -> Int` (a "definer shadow",
documented per memory `project_phase112_standalone_vs_method`: bare name = standalone + no-impl
method **per receiver**). Desired: `size (Box 3)` → dispatch to the `Sizeable Box` method → **3**;
`size 3` → standalone → **4**. `.expected` = ACCEPT (valid program).

**Current behavior (verified on pristine binary):** `check` accepts (exit 0); `run` →
`E-PANIC: unknown op '+'` (it runs the STANDALONE `n + 1` on a `Box`); `build` → garbage
`2193518577`. `size 3` → 4 correctly. So receiver-directed dispatch picks the standalone for a
`Box` argument instead of the method.

## Root cause — stage at fault: TYPECHECK (`compiler/types/typecheck.mdk`)
The standalone's parameter type **leaks onto the method occurrence's receiver tyvar**, so the
route is stamped `RLocal` (= the standalone) instead of the method. Chain (evidence from pipeline
instrumentation, by the diagnosing agent):
1. `size (Box 3)` is marked `EMethodAt "size"`, typed in `inferMethodAt` (`typecheck.mdk:3369`)
   against the correctly-generalized method scheme `∀a. a -> Int` (`quant=1, mono=a -> Int`).
2. Right after `inferApp`, the receiver tyvar is correctly `Box` (`postFt = Box -> Int`).
3. But by route-stamping time the receiver mono is **re-pinned to the standalone's domain** —
   proven by a controlled swap: standalone `size : Int -> Int` → recorded receiver mono `Int`;
   `size : Bool -> Int` → `Bool`. It always equals the standalone's param type, never `Box`.
   No arg-mismatch error is raised → **also a soundness hole** (a `Box` silently accepted against
   an `Int`-domain function).
4. `recordRLocalSite` (`typecheck.mdk:3405`) records that leaked mono; `resolveRLocalSite`
   (`typecheck.mdk:6839`) computes `headTyconMono = Int`, `implExistsForHead keyTable "size"
   "Int" = False` → `stampRLocalOrFallback False` (`typecheck.mdk:6854`) → route **`RLocal`**.
5. `RLocal` = standalone: eval `evalMethodAt … RLocal` (`eval.mdk:1064`) runs `n + 1` on a `Box`
   → `unknown op '+'`. Emit `emitMethod … RLocal` (`llvm_emit.mdk:3435`) → direct `mdk_size` call
   → garbage. **Both run and build wrong via the same upstream cause** (leaked mono → RLocal).
6. `check` accepts because the definer-shadow path (`typecheck.mdk:4620-4628`) types shadow
   occurrences permissively and **skips the impl obligation**, so the mismatch never surfaces.

**Falsified hypothesis:** the Facet-2 unconditional `RLocal` for definer shadows
(`typecheck.mdk:6846`) is NOT the cause — removing it did not fix it (the leaked `Int` mono
already yields `RLocal` via the ordinary `implExistsForHead` branch).

## Option A — the plan (what the user approved)
Fix the receiver-type leak so the marked occurrence keeps the ACTUAL argument type (`Box`), then
route per-receiver: `Box` has a `Sizeable` impl → method; `Int` (no impl) → standalone. Almost
certainly also remove the Facet-2 unconditional `RLocal` (`typecheck.mdk:6846`). End state:
`size (Box 3)` → 3 on run AND build; `size 3` → 4; `.expected` stays ACCEPT; gate 13/0.

## ⚠️ Blast radius — the reason this is careful, non-local work
An Explore sweep found the **only 5 definer shadows in the tree**: `map.mdk` `toList`/`isEmpty`,
`hash_map.mdk` `toList`/`isEmpty`, `parser.mdk` `orElse`. Each is applied ONLY to its own concrete
type (`Map`/`HashMap`/`Parser`), none of which has an impl of the shadowed interface — so they
legitimately want `RLocal` and work today. **The fix must not regress them, nor the heavily-used
normal method-dispatch path.** Decisive gates: `diff_compiler_eval*`, `diff_compiler_llvm*`,
`diff_compiler_build`, `diff_construct_coverage`, the agreement gate → 13/0, and
`selfcompile_fixpoint` C3a/C3b. Likely a seed re-mint is owed (typecheck.mdk is in the
self-compile graph, but only if emitted IR changes — verify via fixpoint-against-committed-seed).

Alternatives considered + rejected by the user: **B** (make check REJECT `size (Box 3)` — contained,
closes the soundness hole, but flips `.expected` to REJECT and drops the per-receiver feature);
**C** (defer/xfail). User chose **A**.

Key file:lines: `typecheck.mdk` {3369 inferMethodAt, 3405 recordRLocalSite, 4620-4628 definer-shadow
typing, 6839 resolveRLocalSite, 6846 Facet-2 RLocal, 6854 stampRLocalOrFallback}, `eval.mdk:1064`
evalMethodAt, `llvm_emit.mdk:3435` emitMethod.
