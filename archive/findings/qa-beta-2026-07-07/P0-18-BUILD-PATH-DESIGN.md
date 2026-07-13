# P0-18 build-path soundness hole — design & scoping

**Status: ✅ IMPLEMENTED + merged (`0b4a7882` Part A + `01ac360d` Part B, on local main `01ac360d`, 2026-07-09).**
Option 3 (thread mangle rename-info into the mark pass) + Fork-2 carry-in-route, mangler and
pipeline order untouched. `medaka build` of `size (Box 3)` now → **3** (was garbage); N-way →
3/30/4. Gates (Docker-verified): build repro 3/4 run==build, agreement **14/0**, `diff_compiler_build`
**60/0** (+`definer_shadow_dispatch`/`definer_shadow_nway` fixtures), `diff_compiler_llvm*`
**byte-identical** (194/44/15), construct-coverage 139/0, eval 23/0, full suite 76/0/1skip,
**fixpoint C3a/C3b YES — NO seed re-mint** (Fork 4 held: the 5 in-tree shadows now route
`EMethodAt`+`RLocal` but emit a byte-identical direct call). **Second bug found+fixed:**
`inferDefinerShadowApp` typed the head against the interface method scheme, losing the concrete
element type (Map `toList` → `List a` not `List (k,v)`) → downstream SIGSEGV; now types against the
standalone scheme via the mangled symbol. **Part B (user's Fork-3 override to generalize):** N-way
multi-impl and importer-shadow-on-a-live-impl receiver BOTH already work post-Part-A (no further
change). **Residual ✅ FIXED (`cfc4fa5a`, 2026-07-09):** the importer shadow on a **no-impl**
receiver now `check` ACCEPTs + `build`/`run` return the standalone (4). 4 path-scoped `typecheck.mdk`
changes: build routing (`definerShadowArgHead` also fires on the mark-pass-seeded `RLocal <sym>`
cross-module signal); check obligation (`recordImplObligation` skips shadows in `definerShadowNames`
∪ `standaloneValues` — the union preserves single-file definer coverage); importer detection
(`buildStandaloneShadows` recognizes a shadow whose interface is declared locally in the importer);
importer dispatch (`shadowKeyTableRef` includes the module's own impls so a live-impl receiver
dispatches). Emit-inert (no importer shadows in compiler/stdlib → fixpoint safe). Gate
`diff_compiler_check_cli_modules` 12/0. **P0-18 fully closed.**

---
_Original design-pass header (preserved):_ **DIAGNOSED (empirically confirmed on `medaka build`), NOT implemented.** This is a
decision-ready design doc. The run/check path was fixed by `953d9ea1` (`size (Box 3)` → **3**,
`size 3` → **4** on run/check; agreement gate 14/0). The `medaka build` (native emit) path still
emits a **wrong value** for `size (Box 3)` — a silent soundness hole. This doc confirms the filed
root cause airtight, maps every touchpoint, evaluates only **mangling-preserving** fixes (per the
hard user constraint), and lists the human decision-forks.

Fixture: `test/run_check_agreement_fixtures/p0_18_standalone_fn_shadows_iface_method.mdk`
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
Desired end state: `build` prints **3** for `size (Box 3)` and **4** for `size 3`, matching `run`.

---

## 1. Empirical confirmation (reproduced in-container, Linux `medaka`)

Exact current behaviour on this worktree (post-merge, base `953d9ea1` = BASE_OK):

| command | `size (Box 3)` | `size 3` |
|---|---|---|
| `medaka run`   | **3** (correct) | 4 |
| `medaka check` | exit 0 (accepts) | exit 0 |
| `medaka build` → run binary | **140736648777713** (garbage) | 4 (correct) |

`size (Box 3)` builds to a large garbage integer (a `Box` cell pointer fed through the standalone
`n + 1`, i.e. `ptr + 1`) and exits 0 — so the exit-code agreement gate is unaffected while the
program is silently miscompiled.

### Why emit skips dispatch — traced, filed root cause CONFIRMED

The emit-path driver order (`compiler/entries/entry_support.mdk`, `runEmitWith`, lines 131-140):
```
enableEmitArgStampPasses ()
(coreMangled, modulesMangled) = mangleUnits coreDecls modules        -- line 133  ← MANGLE FIRST
(coreD, modules2)            = elaborateModules … coreMangled …      -- line 134  ← MARK + TYPECHECK + ROUTE
… emitTail …                                                          -- line 140  ← EMIT reads routes
```
(`emitModulesWith`, lines 144-147, has the same `mangleUnits` → `elaborateModules` order.)
Marking is a **sub-phase inside `elaborateModules`** (`compiler/types/typecheck.mdk:11785-11809`):
the mark set is `markRpNames` (line 11803), built by `buildStandaloneShadowsGraph allDecls
(flatMap snd modules)`, and `prePassDictArg`/`prePassModulePairArg` rewrite matching occurrences
to `EMethodAt`. So on the emit path **mangling runs strictly before marking.**

The **decisive asymmetry** in the mangler (`compiler/backend/private_mangle.mdk`):
- `renameDecl` on a `DFunDef` renames the definition name (`renameDefName rm n`, line 578) → the
  standalone `size` def becomes `<mid>__size`.
- `renameScoped`'s `EVar` arm (line 651-655) renames the **call-site** `size` → `<mid>__size`.
- BUT `renameIfaceMethod` (line 626-634) and `renameImplMethod` (line 636-638) rename only the
  method **body/params**, never the method **NAME** — the interface method stays bare `size`.
  This is deliberate and load-bearing: the header comment (lines 42-43) states method names are
  never mangled because method dispatch is **by (bare) name across modules** (an impl in module A
  must match a call in module B). Mangling method names would break cross-module dispatch.

Post-mangle the three occurrences of `size` are: interface method `size` (bare), standalone def
`<mid>__size`, call site `<mid>__size`. Shadow detection
(`buildStandaloneShadowsGraph`/`buildDefinerShadows`, `typecheck.mdk:11347-11362`) intersects
**iface-method-names ∩ funDef-names**: `{"size"}` ∩ `{"<mid>__size", "main", …}` = **∅**. So the
call site is **not** in `markRpNames`, is **never** rewritten to `EMethodAt`, stays a plain
mangled `EVar "<mid>__size"`, and emits a direct `@mdk_<mid>__size` call to the standalone → the
`n + 1`-on-a-`Box` garbage.

**Filed root cause = CONFIRMED, with one added precision:** it is not merely that mangling produces
"a direct standalone reference before marking" — it is that mangling renames the standalone side of
the shadow but (correctly) leaves the interface side bare, so the **name-based shadow detector
inside the mark pass no longer sees a shadow at all.** The run path never mangles, so its detector
sees `size ∩ size = {size}`, marks the occurrence, and the `953d9ea1` machinery routes it.

### Throwaway probe (run, then reverted) — proves the route machinery already works under emit

I temporarily excluded iface-method-shadowing names from the mangle rename map in
`buildUnitRenameMap` (so the definer-shadow def **and** references survived to marking unmangled),
rebuilt in Docker, and measured:
```
build size (Box 3) => 3
build size 3       => 4
```
So the **emit-path route machinery added by `953d9ea1` is complete and correct** —
`inferDefinerShadowApp` records the actual argument mono into `pendingArgStamps` (gated on
`argDispatchOf name` being `Some`, i.e. the emit path), `resolveArgStamps` stamps `RKey<Box>`,
`emitMethod … (RKey Box)` finds the `Sizeable Box` impl and dispatches → 3; the `size 3` occurrence
routes `RLocal` → the standalone → 4. **The ONLY defect is that mangling prevents the occurrence
from ever reaching marking.** (Probe reverted; the committed deliverable is only this doc.)

This probe is exactly the **ruled-out** "exclude definer-shadows from mangling" approach — it
un-mangles the standalone *definition* too, which re-collides `map`/`hash_map` `toList`/`isEmpty`
(see §3). It is used here **only to confirm the diagnosis**, not as a candidate fix.

---

## 2. Touchpoint map (file:line)

Emit-path driver order:
- `compiler/entries/entry_support.mdk:131-140` `runEmitWith` — `enableEmitArgStampPasses` →
  `mangleUnits` (133) → `elaborateModules` (134) → `emitTail` (140). Also `emitModulesWith`
  145-147 (same order). **This is where a reorder would land.**

Mangler (`compiler/backend/private_mangle.mdk`):
- `mangleUnits` entry `117-124`; `mangleUnitU` `356-364` (builds the rename `OrdMap`, applies
  `renameDecl`).
- `buildUnitRenameMap` `372-377` + `localRenameEntry` `381-384` — the local-fn → `<mid>__<name>`
  map (would grow definer-shadow awareness / a def-vs-ref split here).
- `renameDecl` `574-592`: `DFunDef` name `578`; `DInterface`/`DImpl` `586-589`.
- `renameIfaceMethod` `626-634` / `renameImplMethod` `636-638` — **method NAME left bare** (the
  asymmetry); header note `42-43`.
- `renameScoped` `EVar` arm `651-655` — the call-site rewrite (would need to skip / carry route
  under Options 2/3).

Marker sub-phase + the run-path fix (`compiler/types/typecheck.mdk`):
- `elaborateModules` `11785-11809`; `markRpNames` `11803` via `buildStandaloneShadowsGraph`.
- `buildStandaloneShadowsGraph` `11358-11362`, `buildDefinerShadows` `11347-11351` — **name-based
  intersection that mangling defeats.**
- `checkModuleFullImpl` `11101-11114` sets `definerShadowNamesRef`/`standaloneValuesRef` (the
  run/single-file path; unmangled names, which is why run works).
- `inferDefinerShadowApp` `~4951-4999` + `definerShadowArgHead` `~4960-4967` — record ACTUAL arg
  mono; push `pendingArgStamps` when `argDispatchOf name` is `Some` (emit path).
- `recordArgStamp` `~1973` — respects `suppressArgStamp`.
- `resolveRLocalSite` `~6902-6919` — per-receiver `implExistsForHead`.
- `singleParamIfaceMethod` `~4927`, `methodDispatchIdxRef`/`argDispatchIdxRef` (`3436`/`3442`).

Lowering + emit consumption:
- `compiler/ir/core_ir_lower.mdk:144-145` `EMethodAt name r ir mr` → `CMethod name …`. **`name` is
  a single field**, carried verbatim into emit.
- `compiler/backend/llvm_emit.mdk:3413` `emitMethod … (RKey tag)` → `implFor e name tag` (dispatch,
  needs the **bare** method name to find the impl).
- `compiler/backend/llvm_emit.mdk:3435-3436` `emitMethod … RLocal` → `emitKnownFnSat e ("mdk_" ++
  name) …` (needs the **mangled** standalone symbol `<mid>__size`).
- `compiler/eval/eval.mdk:~1064` `evalMethodAt … RLocal` — the run-path analogue (works because run
  is unmangled).

**How the RUN path makes this work (the mirror target):** run/check never mangle, so the mark pass
sees the shadow, marks `EMethodAt "size"`, `inferDefinerShadowApp` records the real receiver `Box`,
and `resolveRLocalSite` routes per-receiver via `implExistsForHead` (`Box` has a `Sizeable` impl →
leave the route → dispatch; `Int` → no impl → `RLocal` → standalone). The emit path must reproduce
exactly this **without** un-mangling the standalone definitions.

**The representational tension** (the heart of the fix): a definer-shadow occurrence needs
**different names for its two possible routes** — `RKey` dispatch needs the **bare** `size`
(`implFor e "size" Box`), while `RLocal` needs the **mangled** `<mid>__size` (the standalone
symbol). `EMethodAt`/`CMethod` carry a single `name`. The route is known only after typecheck, so
whatever mechanism is chosen must let the resolved route pick the right name.

---

## 3. The 5 definer shadows in the tree + the symbol-collision constraint

Confirmed by grep. For each: does the receiver it's applied to have an impl of the shadowed
interface (→ would newly dispatch) or not (→ stays standalone/`RLocal`)?

| # | shadow | file | shadowed iface (method) | receiver applied to | impl of iface for that receiver? | route | mangled symbol needed? |
|---|---|---|---|---|---|---|---|
| 1 | `toList`  | `stdlib/map.mdk:336`      | `Foldable` (`toList`)  | `Map`    | **NO** `impl Foldable Map`    | `RLocal` | **yes** — collides with #3 |
| 2 | `isEmpty` | `stdlib/map.mdk:157`      | `Foldable` (`isEmpty`) | `Map`    | **NO**                        | `RLocal` | **yes** — collides with #4 |
| 3 | `toList`  | `stdlib/hash_map.mdk:220` | `Foldable` (`toList`)  | `HashMap`| **NO** `impl Foldable HashMap`| `RLocal` | **yes** — collides with #1 |
| 4 | `isEmpty` | `stdlib/hash_map.mdk:63`  | `Foldable` (`isEmpty`) | `HashMap`| **NO**                        | `RLocal` | **yes** — collides with #2 |
| 5 | `orElse`  | `compiler/frontend/parser.mdk:210` | `Alternative` (`orElse`) | `Parser` | **NO** `impl Alternative Parser` | `RLocal` | keeps its own symbol |

`grep` over `stdlib/*.mdk` + `compiler/frontend/parser.mdk` confirms there is **no**
`impl Foldable Map`, `impl Foldable HashMap`, or `impl Alternative Parser`. So **all 5 existing
shadows route `RLocal` (standalone) and must keep their current mangled symbols.** The
`map`/`hash_map` pair (#1/#3, #2/#4) is precisely why un-mangling is forbidden: both define a
private standalone `toList`/`isEmpty`; without mangling both emit `@mdk_toList` / `@mdk_isEmpty` →
duplicate-symbol link collision when both are linked (the compiler links `map`; anything linking
both collides). This is the hard constraint the fix must respect.

**Consequence for blast radius:** the p0-18 fixture is the ONLY known case where a definer-shadow
receiver HAS an impl (→ should newly dispatch). All 5 existing shadows must continue to emit a
**byte-identical** direct `@mdk_<mid>__name` call. A correct fix therefore perturbs emit output for
**no program in the current tree** except the new-dispatch case — so `diff_compiler_llvm*` /
`diff_compiler_build` / `selfcompile_fixpoint` should stay byte-identical (a strong safety signal;
if any of them churns, the fix is over-reaching).

---

## 4. Options analysis (mangling-preserving only)

### Option 1 — Global reorder: mark-before-mangle. **REJECT.**
Run `elaborateModules` first (unmangled), then a route-aware `mangleUnits`.
- **Fatal flaw:** `elaborateModules` flattens `coreDecls ++ flatMap snd modules` (`typecheck.mdk:11793`).
  Mangling exists *specifically* to disambiguate same-named private top-levels across modules
  **before** that flatten (header lines 6-11: native lexer `emit`/`emit`, CLI `isIdentChar`
  `String→Bool` vs `Char→Bool`). Reordering reintroduces exactly the collision bug mangling was
  built to fix — two `isIdentChar` schemes would collapse in the flattened typecheck.
- **Blast radius:** enormous — every scheme key, dict name, and impl key currently derived from
  mangled names would shift. **Fixpoint almost certainly churns.** Rejected.

### Option 2 — Partial defer: mangle the DEF, leave definer-shadow REFERENCES bare through marking.
Split the rename map so `renameDefName` still mangles the standalone definition (`<mid>__size`,
collision-safe) but `renameScoped` skips definer-shadow names, leaving call sites bare `size`.
Marking then sees `size`, routes exactly like the run path. A small **post-elaborate finalize**
(route-aware) rewrites each definer-shadow occurrence: `RKey` → dispatch (leave bare `size`),
`RLocal` → the module's mangled standalone `<mid>__size`.
- **How it closes the hole:** fully — the occurrence reaches marking and routes per-receiver;
  `RKey` dispatches (3), `RLocal` resolves to the mangled standalone (4).
- **Blast radius:** localized to definer-shadow names. Requires (a) a def-vs-ref rename split in
  `mangleUnitU`/`renameDecl`, and (b) the finalize + a way for `RLocal` emit to reach `<mid>__size`
  (the RLocal-name problem, §Fork 2). Risk: the def-vs-ref split touches the shared `rm` plumbing
  that every rename goes through — must not perturb non-shadow references. Medium risk.
- Fully closes the hole; no un-mangling of definitions → no collision.

### Option 3 — Thread the mangle rename-info into the mark pass (RECOMMENDED).
Keep the pipeline order and full mangling **unchanged** (the reference stays `<mid>__size`).
`mangleUnits` additionally returns the per-unit rename info (or just the set of
`(mangledName ↦ bareMethodName)` pairs it created for names that are iface methods).
`elaborateModules` threads that into `buildStandaloneShadowsGraph`/`buildDefinerShadows` so the mark
pass **recovers the shadow post-mangle** — it recognises `<mid>__size` (a funDef) as a shadow of the
bare iface method `size`. It then marks the occurrence `EMethodAt` with the **bare dispatch name**
`size` (so `implFor` finds the impl) while recording the **mangled standalone symbol** `<mid>__size`
for the `RLocal` fallback (§Fork 2).
- **How it closes the hole:** fully, and mirrors the run path most directly (marking + the
  `953d9ea1` route machinery do all the work; only *shadow recovery* is added).
- **Blast radius:** smallest — mangling is byte-for-byte unchanged; the pipeline order is unchanged;
  the only new behaviour is inside the mark pass and is gated to names the mangler flagged as
  iface-method shadows (the 5 existing + any new one). The 5 existing shadows become `EMethodAt` +
  `RLocal` instead of bare `EVar`; **the emitted call must be byte-identical** to today's direct
  call (verify — this is the one thing to gate hard). Low-to-medium risk.
- Fully closes the hole; definitions stay mangled → no collision.

**Options 2 and 3 both fully close the hole and both preserve mangling.** They differ only in
*where* the route-awareness is injected (defer references vs. thread the map to marking) and both
must solve the same RLocal-name sub-problem (§Fork 2). Option 1 is rejected.

---

## 5. Recommendation

**Adopt Option 3 (thread mangle rename-info into the mark pass), with the RLocal symbol carried in
the route (Fork 2 = carry-in-route).** Rationale: it leaves the universal mangler literally
untouched (satisfies the hard constraint with zero risk to the collision-avoidance that the whole
mangling scheme exists for), keeps the pipeline order (no fixpoint-scary reorder), and reduces the
fix to "let the mark pass see through the mangle, then reuse the already-proven `953d9ea1` route
machinery." The probe in §1 already proves that machinery produces the correct build values once the
occurrence is marked.

Staged, independently gate-able steps (ascending risk):

1. **Additive plumbing (no behaviour change).** Have `mangleUnits` also return the
   `(mangled ↦ bareIfaceMethod)` pairs it produced (empty unless a unit's funDef name is an iface
   method). Thread it as a new **optional/additive** argument into `elaborateModules`; default/empty
   preserves every existing caller byte-for-byte. **Gate:** full suite unchanged (no site consumes
   it yet).

2. **Shadow recovery in the mark pass.** Make `buildStandaloneShadowsGraph`/`buildDefinerShadows`
   consult that map so `<mid>__size` is recognised as a shadow of `size`; mark the occurrence
   `EMethodAt` with bare dispatch name `size`. **Gate:** the 5 existing shadows now mark as
   `EMethodAt`+`RLocal`; assert `diff_compiler_llvm*`/`diff_compiler_build`/fixpoint stay
   byte-identical (they route `RLocal` to the same standalone).

3. **RLocal mangled-symbol carry (Fork 2).** Ensure `emitMethod … RLocal` (llvm_emit.mdk:3435) and
   `evalMethodAt … RLocal` reach the mangled `<mid>__size` (via the route/companion ref stamped at
   resolve time). **Gate:** `size 3` build → 4; the 5 existing shadows unchanged.

4. **Turn on new dispatch.** With steps 1-3 the p0-18 occurrence routes `RKey<Box>` → dispatch.
   **Gate:** build `size (Box 3)` → 3; agreement gate 14/0; `selfcompile_fixpoint` C3a/C3b.

Keep every deferred seam **parameterized/additive** (the new `elaborateModules` argument defaults to
empty; the new route/ref field defaults to today's behaviour) so each step is a no-op until the next
lights it up.

---

## 6. ⭐ Forks needing a human decision

**Fork 1 — Where does route-awareness enter?** Option 3 (thread mangle-map to the mark pass) vs
Option 2 (defer definer-shadow reference mangling + finalize) vs Option 1 (global reorder).
*Recommendation: Option 3.* It touches the fewest load-bearing invariants (mangler and pipeline
order both unchanged) and most directly reuses the run-path machinery. Option 2 is a viable
fallback if threading a new argument through `elaborateModules` proves noisier than expected. Option
1 is rejected (reintroduces the cross-module private-symbol collision).

**Fork 2 — How does `RLocal` emit obtain the mangled standalone symbol `<mid>__size`?** The
occurrence marked for dispatch carries the **bare** `size`, but `RLocal` must call
`@mdk_<mid>__size`. Choices: (a) **carry the mangled symbol in the route/a companion ref**, stamped
at resolve time (typecheck has the module context) — *recommended*, fully local, no emit-side
guessing; (b) **un-mangle-at-emit** by prefix logic — rejected, `<mid>__name` is lossy after
`sanitizeId` and names may contain `__`; (c) **don't mangle the definer-shadow def** and give it a
unique symbol another way — rejected, that is the collision. *Recommendation: (a).*

**Fork 3 — Handle the theoretical N-way / importer-shadow-with-live-impl cases now?** Today every
one of the 5 shadows is applied only to a receiver with NO impl (§3), so only the new
definer-shadow-with-live-impl case (p0-18) needs fixing. An *importer* shadow (a different module's
standalone shadowing a method, `shadowStandaloneHead`/`inferShadowApp`) applied to a live-impl
receiver, or a multi-impl N-way receiver, does not occur in-tree. *Recommendation: fix only the
definer-shadow case now (mirror `953d9ea1`), leave importer/N-way as an explicit TODO with an xfail
fixture; do not speculatively generalize.*

**Fork 4 — Seed re-mint expectation.** `typecheck.mdk` and `private_mangle.mdk` are both in the
self-compile graph, so a seed re-mint is owed **only if the compiler's own emitted IR changes**. The
compiler has **no** definer-shadow-with-live-impl site (its 5 shadows are all no-impl `RLocal`), so
step 2's "mark as `EMethodAt`+`RLocal`" should emit a byte-identical call and the fixpoint should
hold against the committed seed with **no re-mint**. *Recommendation: expect no re-mint; treat any
`selfcompile_fixpoint` churn as a signal the fix is over-reaching (e.g. an existing shadow's emit
changed) and stop to investigate rather than blindly re-mint.*

---

## 7. Decisive gates the implementation will need

- **Build repro (primary):** `medaka build` of the fixture → `size (Box 3)` prints **3**; a
  `size 3` variant prints **4**. (Run in Docker; the in-container binary is Linux.)
- **`diff_compiler_llvm` / `diff_compiler_llvm_typed`** — emit goldens byte-identical (the 5
  existing shadows must not churn).
- **`diff_compiler_build`** — native build path byte-identical.
- **`diff_construct_coverage` + `test/build_construct_coverage.sh`** — construct coverage stays
  139/0.
- **`test/diff_compiler_run_check_agreement.sh`** — stays **14/0**.
- **`diff_compiler_eval*`** — eval/run path unaffected (it already works; must stay so).
- **`test/selfcompile_fixpoint.sh` C3a/C3b** — emitter self-compile fixpoint YES against the
  committed seed.
- **Seed re-mint:** expected **not** owed (§Fork 4); confirm via the fixpoint-against-committed-seed
  result. If it churns, investigate before re-minting.
- Run the whole suite via `scripts/docker-dev.sh gates` (self-caps `JOBS=4`/`INNER_JOBS=2`); repeat
  any newly-touched build-shelling gate several times (temp-collision flakes show ~1-in-N).

---

## Appendix — one-line summary for the orchestrator

`medaka build` miscompiles `size (Box 3)` because `mangleUnits` renames the standalone def + call
site to `<mid>__size` **before** marking while (correctly) leaving the interface method name bare
`size`, so the mark pass's name-based shadow detector finds no shadow, never marks the occurrence
`EMethodAt`, and emits a direct call to the standalone. The `953d9ea1` emit-path route machinery is
already complete (a throwaway probe that let the occurrence reach marking built `3`/`4` correctly).
Recommended fix: **thread the mangle rename-info into the mark pass so it recovers the shadow
post-mangle, marks with the bare dispatch name, and carries the mangled standalone symbol for the
`RLocal` fallback** — mangler and pipeline order untouched, minimal blast radius, no expected seed
re-mint. Two human forks are load-bearing: *where* route-awareness enters (recommend thread-to-mark)
and *how* `RLocal` emit reaches `<mid>__size` (recommend carry-in-route).
