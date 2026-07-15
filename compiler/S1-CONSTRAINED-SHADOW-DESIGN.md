# S-1 — a CONSTRAINED definer-shadow standalone is miscompiled

**Status:** IMPLEMENTED — `ee0593bd`, 2026-07-14. The fix ships in the same PR as this
design (`RLocal String (List Route)`; new `SHADOW-SEMANTICS.md` clause S9). One residual
remains OPEN — `S1-RESIDUAL-B` (imported constrained shadow on an *ungrounded* receiver;
`inferShadowApp` lacks the P0-20 `groundShadowReceiver` call its definer peer has), tracked
in `SHADOW-SEMANTICS.md` §6. `S1-RESIDUAL-A` (value position) appears CLOSED by this change
and is pending confirmation. Diagnosed empirically on `main` (`d23de250`), traced through
the source, not taken from the filing. **Peer docs:** `SHADOW-SEMANTICS.md` (the S1–S8
conformance spec + decision matrix), `SHADOW-INVERSION-DESIGN.md` (the S2 inversion, for
which this fix is a hard prerequisite), `.claude/workstreams/COMPILER-SOUNDNESS.md`.

---

## 0. Verdict on the filed root cause

> *Filed:* "This is the `RLocal`-vs-dict-passing seam: `RLocal` carries no dictionary, so the
> call reaches a dict-passed standalone *without its dict word* and gets a partial application
> back, which is then printed as a value."

**The filed root cause is RIGHT about the seam and the symptom, and WRONG about the
mechanism — in the one way that changes the fix.**

Verified against the emitted LLVM IR (below): the standalone *is* dict-passed (2 params), the
call site *does* supply 1 word, and a PAP *is* built and printed. That half is exactly right.

But `RLocal` does not *drop* a dict it was handed. **No dict is ever computed for this
occurrence at all.** The occurrence never becomes an `EDictAt` node, because the prePass that
decides "is this a dict-application?" is a **first-match guard chain** in which the
shadow/method arms are tested *before* the constrained-fn arm — so a name that is BOTH a
constrained standalone AND an interface-method name is consumed by the shadow arm and the dict
arm never fires. The definition still gets its dict *parameter* (a different pass, keyed on the
same name set), so **the def's arity and the call's arity disagree by exactly one word**.

Consequences for the fix, all of which the filing's framing would have missed:

1. The fix is **not** "stop dropping the dict in the backends" — there is nothing there to
   drop. It is "compute the dict for this occurrence, and give the route somewhere to put it."
2. The obvious-looking repair — **reorder the guard chain so the dict arm wins** — is
   **WRONG and must be explicitly forbidden**: `EDictAt` carries no route and cannot dispatch,
   so it would break S2 (`size (Box 3)` → the impl), which **works today** (row G below).
3. The fix also closes a **second, independent hole in the same arm**: the standalone's own
   constraints are never recorded as **call obligations**, so `size "hi"` (⇒ `Num String`,
   no impl) is **silently accepted by `check`**. Both the accept and the reject direction fall
   out of the same change.
4. **`Num` is not special** and **a literal receiver is not special** — so **S-1 is NOT a
   sibling of the P0-20 literal-receiver bug**, despite both involving `Num` + a constraint.
   P0-20 was "one decision, derived twice, over a value that changed in between." S-1 is a
   different shape: **two decisions that need the same node, and only one of them gets it.**

---

## 1. Empirical reproduction — the truth table

All rows on `main` @ `d23de250`, native binary + `medaka_emitter` from `main`. `main = …` form.
Every row probed on **all three paths**. `size 3` must be `4` in every broken row.

| # | shadow? | constraint on standalone | signature? | impl at receiver head? | `check` | `run` | `build` |
|---|---|---|---|---|---|---|---|
| A | yes (`Sz.size`) | `Num a =>` | yes | no (`impl Sz Box`, recv `Int`) | ACCEPT | E-PANIC `intToString: not an Int` | **`69915433383920`** |
| B | **no** | `Num a =>` | yes | — | ACCEPT | `4` | `4` ✅ |
| C | yes | `Num a =>` | yes | **no impls at all** | ACCEPT | E-PANIC | **`69938033698800`** |
| D | yes | **none** (`Int -> Int`) | yes | no | ACCEPT | `4` | `4` ✅ |
| E | **no** (`sizeX` iface) | `Num a =>` | yes | — | ACCEPT | `4` | `4` ✅ |
| F | yes | **`Dbl a =>`** (user iface) | yes | no | ACCEPT | E-PANIC | **`70079326785520`** |
| G | yes | `Num a =>` | yes | **YES** (`size (Box 3)`) | ACCEPT | `IMPL` | `IMPL` ✅ |
| H | yes | inferred `Num a =>` | **no sig** | no | ACCEPT | E-PANIC | **`70066234193904`** |
| I | yes | `Num a =>` | yes | no; receiver a **grounded local** (`k : Int`) | ACCEPT | E-PANIC | **`69969701119984`** |
| J | yes | `Num a =>` | yes | no; receiver **annotated** `(3 : Int)` | ACCEPT | E-PANIC | **`70316243941360`** |
| K | yes | `Num a =>` | yes | no; **value position** (`map size [1,2,3]`) | ACCEPT | E-PANIC | **GC OOM** (`Failed to expand heap by 92027528408 KiB`) |
| L | yes (**return-pos** method) | `Num a =>` | yes | no | ACCEPT | E-PANIC | **`69974316113904`** |
| M | yes | `Num a =>` (2-ary standalone) | yes | no | ACCEPT | E-PANIC | **`69994602108896`** |
| N2 | yes (**PRELUDE** `Eq.eq`) | `Num a =>` | yes | no | ACCEPT | E-PANIC | **`69991762833392`** |
| N3 | yes | `Num a =>` | yes | **both receivers in one program** | ACCEPT | E-PANIC | **`IMPL` then garbage** |
| P | yes | `Num a =>` | yes | no; **`size "hi"`** — should REJECT | **ACCEPT** ❌ | E-PANIC | (prints nothing) |
| Q | yes | `Num a =>` | yes | no; **nested constrained caller** | ACCEPT | E-PANIC | **`70095976615904`** |
| R | **importer** shadow (`import prov.{size}`) | `Num a =>` | yes | no | ACCEPT | E-PANIC | **`69858274072560`** |

### What is actually load-bearing

| ingredient | load-bearing? | evidence |
|---|---|---|
| **the shadow** (name collides with a visible interface-method name) | **YES** | B, E are green; only name-collision rows break |
| **a constraint on the standalone** | **YES** | D (same program, unconstrained standalone) is green |
| a **declared signature** | **NO** | H (unsignatured, *inferred* `Num a =>`) is equally broken. *The filing's "not a missing signature" is right but for the wrong reason: an unsignatured standalone that **infers** a constraint breaks too.* |
| **`Num` specifically** | **NO** | F (`Dbl a =>`, a user interface) is equally broken |
| an **impl at the receiver head** | **NO — inverted** | G **works** (it dispatches). The bug is **only** on the *standalone* (`RLocal`) arm. N3 shows both arms in one program: the `Box` receiver prints `IMPL`, the `Int` receiver prints garbage. |
| a **literal** receiver | **NO** | I (grounded local) and J (annotated) break identically ⇒ **not a P0-20 sibling** |
| **definer** vs **importer** shadow | **NO — both** | R (imported constrained standalone) breaks identically |
| the **prelude** vs a user interface | **NO — both** | N2 (`eq : Num a => a -> a` shadowing prelude `Eq.eq`) breaks |

**Minimal ingredient set: `{ shadow, constrained standalone (declared OR inferred), the
occurrence routes to the standalone }`.** Nothing else.

**Blast radius is larger than filed.** N2 means: *any* user program that defines a
`=>`-constrained top-level function whose name collides with **any prelude interface method**
(`eq`, `map`, `append`, `size`, `show`, …) is silently miscompiled. No user-defined interface
is required.

---

## 2. The real root cause

### 2.1 Ground truth from the emitted IR

Row C (`interface Sz a where size : a -> String` + `size : Num a => a -> a` + `size 3`),
LLVM IR straight from `medaka_emitter`:

```llvm
; the standalone — dict-passed, TWO params (arg0 = the Num dict, arg1 = n)
define i64 @mdk_C_noimpl__size(i64 %arg0, i64 %arg1) { … }

; main — builds a PARTIAL APPLICATION, and puts the Int 3 in the DICT slot
define i32 @mdk_program_main(i32 %argc, ptr %argv) {
  %t0 = call i64 @mdk_impl_Int_fromInt(i64 7)          ; the Int 3 (tagged 3*2+1)
  %t6 = call ptr @mdk_alloc(i64 24)
  store i64 1, ptr %t6                                  ; PAP: 1 word captured
  store i64 ptrtoint (ptr @mdk_pap_mdk_C_noimpl__size_1 …), ptr %t7
  store i64 %t0, ptr %t8                                ; ← captures the INT as the DICT
  %t11 = call i64 @mdk_core__println(… i64 %t9)         ; prints the PAP pointer
}
```

The control (row B, same standalone, **no shadow**) is the correct call:

```llvm
%t2 = call i64 @mdk_B_noshadow__size(i64 ptrtoint (ptr @mdk_dc_1 to i64), i64 %t0)
;                                    ^^^^^^^^^^^^ the dict word
```

So: **def arity 2, call arity 1.** The emitter is *correct* — an under-applied known call
becomes a PAP. The malformed call arrives from upstream.

### 2.2 Where the dict is lost — a first-match guard chain

Both halves of dict-passing are keyed off the same name set, computed together at
`compiler/types/typecheck.mdk:12658-12661`:

```
:12658  let markRpNames = dedup (rpNames ++ methodConstraintNames allDecls
                                 ++ buildStandaloneShadowsGraph allDecls …)   -- the SHADOW set
:12659  let core2    = prePassDictArg markRpNames dictNames argNames mangledShadowMapRef.value coreDecls
:12660  let modules2 = map (prePassModulePairArg markRpNames dictNames argNames …) modules
```

`dictNames` (:12649-12655) = the `=>`-constrained fn set. `markRpNames` = the shadow set.
For a constrained shadow, **`size` is in BOTH**. The prePass has **one arm per set, and they
are exclusive**. All three flavours of the prePass put the shadow/method arms *first*:

```
compiler/types/typecheck.mdk:6818-6821   rewriteRPDict
  | contains n rpNames   = EMethodAt …          ← shadow / return-pos method
  | contains n dictNames = EDictAt n (Ref [])   ← the DICT arm, never reached

compiler/types/typecheck.mdk:6861-6865   rewriteRPDictArg
  | contains n rpNames   = EMethodAt …
  | contains n argNames  = EMethodAt …          ← arg-position method
  | contains n dictNames = EDictAt n (Ref [])   ← never reached

compiler/types/typecheck.mdk:6943-6951   rewriteArgScoped  (the scope-aware emit path)
  | not (contains n bound) && isSome (lookupAssoc n sm) =
      … Some bare => EMethodAt bare (Ref (RLocal n)) (Ref []) (Ref [])   ← the P0-18 mangled-shadow arm
  | contains n rp && not (contains n bound) = EMethodAt …
  | contains n an && not (contains n bound) = EMethodAt …
  | contains n dn && not (contains n bound) = EDictAt n (Ref [])         ← never reached
```

**⇒ the occurrence becomes `EMethodAt`, never `EDictAt`. No dict is ever computed for it.**

The *other* half fires anyway, from the same `dictNames`:

```
compiler/types/typecheck.mdk:8869-8871   dictPassDecl
  dictPassDecl names _ (DFunDef pub n pats body)
    | contains n names = DFunDef pub n (dictParams n (dictArityOf n) ++ pats) body
```

⇒ **the definition gets the leading dict param; the call site does not supply it.**

The failure mode is *already documented in the tree* — the doc comment two lines above the
`dictNames` construction (`:12650-12654`), written for the import-aliasing fix, describes it
exactly:

> "…the call is never marked, receives no dict arguments, and silently **UNDER-APPLIES**:
> `check` stays green and `run` dies downstream with a type-confused value."

The shadow marking re-opened that same hole for a different reason.

### 2.3 Why the backends can't recover — and why the three arms differ

By the time the tree reaches lowering (`compiler/ir/core_ir_lower.mdk:136` `EMethodAt → CMethod`),
the node is a method occurrence with a route and **no dict channel filled**. All three consumers
of the `RLocal` route treat it as "call the standalone with exactly the args present":

| backend | site | behaviour on the malformed call |
|---|---|---|
| eval | `compiler/eval/eval.mdk:1076-1077` `evalMethodAt env name (RLocal sym) _ _ = lookupEnv env …` | returns the 2-ary closure; the enclosing `EApp` applies 1 arg ⇒ **PAP value** ⇒ `println` ⇒ `E-PANIC intToString: not an Int` |
| LLVM | `compiler/backend/llvm_emit.mdk:3534-3541` `emitMethod … (RLocal sym) … = emitKnownFnSat e ("mdk_"++target) argOps (fnArity e target) …` | `emitKnownFnSat` sees 1 arg < arity 2 ⇒ **builds a PAP** ⇒ **silently prints a heap pointer** |
| WasmGC | `compiler/backend/wasm_emit.mdk:3038-3041` `emitMethodRef … (RLocal sym) … = argInstrs ++ ["call $" ++ gname target]` | raw `call` with 1 operand to a 2-param func ⇒ **wasm validation failure** |

The invariant they encode is stated as *design* in two places, and **both are now wrong**:

- `compiler/frontend/ast.mdk:49-53`: *"RLocal = NOT a method dispatch … eval ignores VMulti
  dispatch and evaluates the bound name as the plain standalone (**no narrowing, no dicts**)."*
- `compiler/eval/eval.mdk:893`: `dictOfRoute _ (RLocal _) = VDict "" []  -- C5: RLocal never carries a dict`
- `SHADOW-SEMANTICS.md` §3, eval row: *"`dictOfRoute:874` RLocal carries no dict"*.

**⚠️ MAJOR FINDING — the implementation does not contradict the spec; the spec *codifies the
bug*.** "RLocal carries no dict" is asserted as an invariant in the AST doc-comment, in eval,
and in the SHADOW-SEMANTICS per-stage keying table. The fix **breaks that invariant on
purpose**, and all three must be edited in the same PR — otherwise the next agent reads
`ast.mdk:53` and "restores" it.

### 2.4 The second hole in the same arm: `check` over-accepts (the REJECT direction)

The standalone's constraints are never turned into **call obligations** either. Two sites:

- **emit/run path**, `compiler/types/typecheck.mdk:5319-5323` `definerShadowHeadType`:
  ```
  definerShadowHeadType env sym f = match lookupVar env sym
    Some s => instantiate s        -- plain instantiate: no obligations recorded
  ```
  Contrast the ordinary `EVar` path, `:4593`, which calls `instantiateVarTracked` (`:4604`) and
  records `pendingCallObligations` from `schemeObligationsRef`.
- **check path**, `compiler/types/typecheck.mdk:5301-5309` `inferDefinerStandaloneVarApp`:
  `standaloneShadowScheme name` yields a bare `Mono` with the constraint **stripped**, then
  `unify smono (TFun xt eff r)`. `Num String` is never asked.

⇒ row **P** (`size "hi"`): `check` **ACCEPTS**. This is a *reject*-direction soundness hole
living in the same arm, and it is fixed by the same change (§4.2 records the obligations).

### 2.5 Secondary (cosmetic, but it misled me for ten minutes)

`check` prints the **interface method's** scheme with the **standalone's** constraint:

```
$ ./medaka check A_filed.mdk
size : Num b => a -> String     ← the METHOD, wearing the STANDALONE's `Num` (note `b` is unbound!)
size : Num a => a -> a          ← the standalone
```

Cause: `compiler/types/typecheck.mdk:2599-2601`
```
ppSchemeNamed n s = ppSchemeCon (fromOption [] (lookupAssocS2 n schemeObligationsRef.value)) s
```
a **bare-name** lookup in a name-keyed obligation table, first-match. The method and the
standalone share the name. **Display-only** (`schemeLines` + LSP hover) — it is not the cause
of S-1 — but it is a real (separate) bug: the LSP will hover a wrong constraint, and the
`check --types` output is lying. Filed as a separate stage (§5, stage 5).

---

## 3. WasmGC: **YES, the backend has it too** — and it fails *loudly*, not silently

```
$ ./medaka build --target wasm C_noimpl.mdk -o C_noimpl.wasm
error: wasm-tools validate rejected …
error: func 325 failed to validate
Caused by:
    0: type mismatch: expected (ref eq) but nothing on stack (at offset 0x2b1e4)
```
(control `B_noshadow.mdk` builds clean.)

"nothing on stack" **is the missing dict word.** WasmGC is typed, so the same malformed Core IR
that LLVM turns into a silent PAP is rejected outright by `wasm-tools validate`.

This is the *strongest* confirmation that the defect is **upstream of both backends**: two
independently-written emitters, given the same 1-arg call to a 2-param function, produce two
different wrong answers. **Any fix that lands only in `llvm_emit.mdk` is wrong.** The wasm
`RLocal` arm (`wasm_emit.mdk:3038`) needs the peer change, and so do `wasm_emit.mdk:6458`
(`freeVarsRoute`) and `llvm_emit.mdk:3586` (`methValDictNames`) — see §4.4.

---

## 4. The fix

### 4.0 What NOT to do (say this to the implementation agent first)

> **Do not reorder the prePass guard chain so the `dictNames`/`EDictAt` arm wins.**
> `EDictAt` has no route ref and cannot dispatch. Row **G** (`size (Box 3)` → `IMPL`) and row
> **N3** (both arms in one program) prove the *dispatch* arm works today and must keep working.
> A shadow occurrence is genuinely **undecided at mark time** — the method/standalone choice is
> per-receiver and post-inference. `EMethodAt` is the node that can be either; the bug is that
> its **`RLocal` arm has no dict channel**. Give it one.

### 4.1 Representation — the dicts travel *in the route*

`compiler/frontend/ast.mdk:72`

```
  | RLocal String              -- today
  | RLocal String (List Route) -- proposed: the standalone's constraint dicts, slot-ordered
```

Exactly mirrors `RKey String (List Route)` (`ast.mdk:70`), which already carries a parametric
impl's element dicts the same way. The route is a **value**, stamped once by a **single
writer**, read out immutably by `lower` into `CMethod`. Nothing re-derives it. This is the
"make the decision travel with the node" shape the workstream asks for — and it is why the
alternative (§6, Fork B) is rejected.

### 4.2 Typecheck — compute the dicts on the arm that chose the standalone

Both shadow-app entry points already *know* which arm they took:

- **definer**, `compiler/types/typecheck.mdk:4977-5058` `inferDefinerShadowApp` — has
  `dispatches` (`:5000`) and `isDictVar` (`:4996`), and already forces the route to follow the
  arm via P0-20's `forceLocal` (`:5042`).
- **importer**, `compiler/types/typecheck.mdk:4927-4946` `inferShadowApp`.
- **check path (un-marked `EVar` head)**, `:5259-5278` `inferDefinerShadowVarApp` →
  `:5301-5315` `inferDefinerStandaloneVarApp`.

In the **standalone arm** of each (`not dispatches && not isDictVar`):

1. `let dictKey = if sym == "" then name else sym` — **the P0-20 sym-awareness lesson**: on the
   mangled emit path the standalone is `<mid>__size`, so a bare-name lookup is *silently inert*
   there and would flip build to the un-dicted call while run/check dicted correctly — the same
   bug, mirrored. (`shadowDomainFor:5185` exists for precisely this reason; copy its shape.)
2. Instantiate the standalone's scheme **tracked**: replace `definerShadowHeadType`'s
   `instantiate s` (`:5321`) with an `instantiateTracked`-returning variant so the
   `(Int, Mono)` subst is available.
3. Map the standalone's constraint ids through that subst **exactly as
   `inferDictAtFound` (`:3518-3545`) already does** — including `expandSupersPairs`
   (`:3536`, WS-1b super expansion; the def's dict params are sized from the *expanded* table,
   so the call must be too). Yields `(monos, ifaces)`.
4. `recordCallObligations ifaces monos` (`:3561`) — **this is what closes row P.**
5. Stash `(monos, ifaces)` on the pending-site record (§4.3).

`funConstraintsRef` is empty on the plain `check` path (`:1549`), so on **check** step 3 must
read the always-on `schemeObligationsRef` (`:1554`) via the `instantiateVarTracked` shape
(`:4604`) instead. Check never stamps routes, so it needs **only** step 4.

### 4.3 Route stamping — ordering-immune, single writer

**⚠️ The landmine.** In `elabModuleStamp` (`compiler/types/typecheck.mdk:13045-13048`):

```
:13045  resolveArgStamps  …
:13046  resolveRLocalSites (buildKeyTable implDecls) pendingRLocalSites.value   ← RLocal stamped HERE
:13047  realizeRecDictApps …
:13048  resolveDictApps implDecls stampImplTable pendingDictApps.value          ← dicts resolved HERE
```

**`resolveRLocalSites` runs BEFORE `resolveDictApps`.** So a design that pushes the standalone's
dicts through `pushDictApp`/`pendingDictApps` and then reads them at stamp time would read
**`[]`** — and reproduce the bug with more code. Do not do that, and do not "fix" it by
reordering these two lines (a global reorder of a post-inference resolver is a large blast
radius for no gain).

**Instead, resolve the routes inside the stamp.** `resolveDictApps`'s inner resolver is already
a **pure function** of the (union-find-solved) monos:

```
compiler/types/typecheck.mdk:8518-8523  resolveDictApps prog implTable ((routesRef, monos, ifaces)::rest) =
                                          setRef routesRef (routesOfMonosTop prog implTable monos ifaces)
compiler/types/typecheck.mdk:8536-8549  routesOfMonosTop / routeOfMonoTop   ← reuse this
```

So:

- `pendingRLocalSites : Ref (List (String, Ref Route, Mono, String, Bool))` (`:1341`)
  → **add two fields**: `(…, List Mono, List String)`.
- `resolveRLocalSites` (`:7242`) gains `prog` + `implTable` params (it already receives
  `keyTable`; both call sites are `:13046` and the flat path — **grep: `resolveRLocalSites` has
  exactly ONE call site today**, `:13046`).
- `stampRLocalOrFallback` (`:7278-7280`) becomes:
  ```
  stampRLocalOrFallback False tagRef sym monos ifaces =
    setRef tagRef (RLocal sym (routesOfMonosTop prog implTable monos ifaces))
  ```
  Empty `monos` ⇒ `[]` ⇒ `RLocal sym []` ⇒ **byte-identical to today**.

`activeDictVars` is still bound at `:13046` (it is what `resolveArgStamp:1936` reads one line
earlier), so an `RDict` slot (row **Q**: a constrained caller forwarding its own dict) resolves
correctly. **Ordering-immune, single writer, no global reorder.**

### 4.4 Backends — three arms, each delegating to the *existing, tested* dict-app path

Every RLocal arm already **receives** everything it needs; guard on `dicts == []` so the empty
case is provably byte-identical (the compiler's own 5 definer shadows are all **unconstrained**
— verified: `stdlib/map.mdk` `toList`/`isEmpty`, `stdlib/hash_map.mdk` `toList`/`isEmpty`,
`compiler/frontend/parser.mdk:221` `orElse : Parser a -> Parser a -> Parser a` — so they take
the empty path and **the self-compile fixpoint cannot move**).

| file:line | today | proposed |
|---|---|---|
| `compiler/eval/eval.mdk:1076` | `evalMethodAt env name (RLocal sym) _ _ = lookupEnv env target` | `… (RLocal sym dicts) …` → `applyDicts env (lookupEnv env target) dicts` — **the literal body of the `EDictAt` arm at `:1019`**. `applyDicts env v [] == v` ⇒ empty case unchanged. |
| `compiler/backend/llvm_emit.mdk:3534` | `emitKnownFnSat e ("mdk_"++target) argOps (fnArity e target) (fnRetTy e target)` | `if isEmpty dicts then <today, verbatim> else emitDictApp e env target dicts argOps` — `emitDictApp` (`:4313-4330`) already handles under-application via `defArityOf`/`emitPapClosure`. |
| `compiler/backend/wasm_emit.mdk:3038` | `argInstrs ++ ["call $" ++ gname target]` | `if isEmpty dicts then <today> else emitDictRef prog env d target dicts args` (`:3176-3182`). |
| `compiler/eval/eval.mdk:893` | `dictOfRoute _ (RLocal _) = VDict "" []` | pattern-widen to `(RLocal _ _)`; **update the `-- C5: RLocal never carries a dict` comment — it is now false.** |
| `compiler/eval/eval.mdk:863`, `:921` | `routeTag _ (RLocal _)`, `methodAtNarrow _ v (RLocal _)` | pattern-widen only. |
| **`compiler/backend/llvm_emit.mdk:3586`** `methValDictNames` | `methValDictNames _ = []` (RLocal captures nothing) | **must recurse into RLocal's dicts** — an `RDict "$dict_f_0"` inside a *value-position* shadow is a **captured local**. Row **Q** is the fixture. |
| **`compiler/backend/wasm_emit.mdk:6458`** `freeVarsRoute` | `freeVarsRoute _ (RLocal _) = []` | same — the peer. The comment there explicitly says "RLocal … carry NO captured local"; **that becomes false.** |
| `compiler/ir/core_ir_sexp.mdk:43-44` `routeSexp` | `RLocal "" → "RLocal"`; `RLocal s → node "RLocal" [s]` | keep both forms for **empty dicts** (goldens: `diff_compiler_core_ir_sexp.sh` must not move); emit a 2-field node only when dicts are non-empty. |
| `compiler/frontend/marker.mdk:315-318` `routeExtraRefs` | `RLocal s → [s]` | pattern-widen. RLocal's dict routes name **dict params (locals)** and **impl heads**, never new *global* refs, so **no DCE change is needed** — but assert it (a `RKey` dict slot's impl fn must already be a DCE root, as it is for `RKey` today). |
| `compiler/ir/core_ir_lower.mdk:136` | `EMethodAt → CMethod name routeRef.value …` | **unchanged** — it copies the whole `Route` by value. This is the point: the dicts ride the route and lowering is already correct. |

### 4.5 Why this shape, in one sentence

The `EMethodAt` node has to answer *two* questions — "dispatch or standalone?" (the route) and
"which dicts?" — and today the route can only answer the first. Making the route
`RLocal sym dicts` makes **the same value answer both, stamped by the same writer, at the same
instant**, so they cannot disagree.

---

## 5. Staged implementation plan

Ordered by ascending risk. Each stage is independently gated and mergeable.

| # | Stage | Files touched | Parallel? | Size | Gate |
|---|---|---|---|---|---|
| **0** | **Fixtures first (RED).** Land the failing fixtures so every later stage is measured. `test/run_check_agreement_fixtures/`: `s1_constrained_shadow_standalone` (**ACCEPT**, `.out` = `4`), `s1_constrained_shadow_domain_mismatch` (**REJECT** — row P), `s1_constrained_shadow_dispatch` (**ACCEPT**, `.out` = `IMPL` — the row-G *control*, must never regress), `s1_constrained_shadow_nested_dict` (**ACCEPT** — row Q, the `RDict`-capture case), `s1_constrained_shadow_value_pos` (**ACCEPT** — row K), `s1_constrained_shadow_importer/` (row R). Plus `test/shadow_fixtures/d10_definer_constrained.mdk`. | `test/**` only | **YES** — parallel with everything | S | agreement gate goes RED with a known count |
| **1** | **`check` REJECT direction alone** (§4.2 step 4 only). Record the standalone's call obligations at `inferDefinerStandaloneVarApp:5301` and `definerShadowHeadType:5319`. **No route work, no backend work.** Closes row **P**. | `compiler/types/typecheck.mdk` | serial w/ 2,3 | S–M | `diff_compiler_check*.sh`, `typecheck_golden_batch`, agreement gate (`…_domain_mismatch` turns green) |
| **2** | **The route carries dicts** (§4.1 + §4.3): `ast.mdk` `RLocal String (List Route)`; widen every pattern; `pendingRLocalSites` +2 fields; `stampRLocalOrFallback` calls `routesOfMonosTop`. **Behaviour-neutral** — everything still stamps `RLocal sym []`. | `compiler/frontend/ast.mdk`, `compiler/types/typecheck.mdk`, `compiler/frontend/marker.mdk`, `compiler/ir/core_ir_sexp.mdk`, `compiler/eval/eval.mdk`, `compiler/backend/{llvm,wasm}_emit.mdk` (pattern-widen only) | **serial** — touches every Route consumer | M | **fixpoint C3a/C3b**, `diff_compiler_core_ir_sexp.sh` (goldens MUST be byte-identical), full `run_gates` |
| **3** | **Fill the dicts** (§4.2 steps 1–3, 5) in `inferDefinerShadowApp:4977` + `inferShadowApp:4927`. Routes now stamp `RLocal sym [RKey "Int" []]` etc. | `compiler/types/typecheck.mdk` | serial after 2 | M | agreement gate; rows A/C/F/H/I/J/L/M/N2/R turn green **only after stage 4** |
| **4a** | **eval RLocal arm** → `applyDicts` (`eval.mdk:1076`) | `compiler/eval/eval.mdk` | **parallel with 4b, 4c** | S | `medaka run` on every fixture; `diff_compiler_eval*.sh` |
| **4b** | **LLVM RLocal arm** → `emitDictApp` + `methValDictNames` capture (`llvm_emit.mdk:3534`, `:3586`) | `compiler/backend/llvm_emit.mdk` | **parallel with 4a, 4c** | S | `diff_compiler_build.sh`, agreement gate **value** column, **fixpoint** |
| **4c** | **WasmGC RLocal arm** → `emitDictRef` + `freeVarsRoute` capture (`wasm_emit.mdk:3038`, `:6458`) | `compiler/backend/wasm_emit.mdk` | **parallel with 4a, 4b** | S | `test/build_wasm_cmd.sh` + `wasm-tools validate` on the fixtures |
| **5** | **Docs + the cosmetic scheme leak.** `ast.mdk:49-60` and `eval.mdk:893` comments ("no dicts") **must** be rewritten; `SHADOW-SEMANTICS.md` §3 eval row + a new clause **S9** + a new matrix row 26; fix `ppSchemeNamed:2599` to key the obligation lookup by the *binding's* identity, not the bare name. | `compiler/frontend/ast.mdk`, `compiler/eval/eval.mdk`, `SHADOW-SEMANTICS.md`, `compiler/types/typecheck.mdk` | parallel after 4 | S–M | `diff_compiler_check.sh` **goldens will move** (the `Num b =>` line disappears) — bless deliberately |

**Serial spine: 1 → 2 → 3 → {4a‖4b‖4c} → 5.** Stage 0 is parallel to all of it. Stages 4a/4b/4c
are three different files and can be three agents. **Rebuild note for any agent touching stages
2–4:** `FORCE_EMITTER_REBUILD=1 make medaka` — stages 2/3/4b change code the *emitter itself*
compiles, and without the force flag `medaka build` shells out to a stale `medaka_emitter` and
you will debug a ghost.

---

## 6. DESIGN FORKS — needs a human decision

### Fork A — **the spec codifies the bug.** (SEMANTICS · must be answered)

I grepped `SHADOW-SEMANTICS.md` first, as instructed. Findings:

- **There is no clause for a *constrained* standalone.** S2 answers *"method or standalone?"*.
  It is silent on *"and if the standalone is itself `C a => …`, where does its dict come from?"*
  Rows 1–25 of the matrix vary the receiver's **shape** and **provenance**, never the
  standalone's **constrained-ness**. **This is a genuine spec gap, not a contradiction.**
- **But §3's per-stage keying table, `ast.mdk:49-60`, and `eval.mdk:893` all assert
  "RLocal carries no dict" as an INVARIANT.** The spec therefore *documents the bug as the
  design.* Anyone reading the spec to fix S-1 will conclude the code is correct.

**Proposed clause S9 (needs sign-off):**
> **S9 (constrained standalone).** When S2/S4/S5 resolve a shadow occurrence to **the
> standalone**, and that standalone is `C a => …`, the occurrence is an **ordinary constrained
> call**: `C` is solved at the receiver's type and the dict is supplied at the call, exactly as
> at a non-shadow call site. `RLocal` therefore **does** carry dicts. A `C` with no impl at the
> receiver's type is a **located reject** at `check` (`Num String` for `size "hi"`), never a
> runtime panic. Orthogonal to S2: the *shadowed* interface decides **which function**; the
> standalone's *own* constraints decide **which dicts**. They are different interfaces.

**Decision needed:** accept S9 as written? The alternative — *"a constrained standalone may not
shadow an interface method; reject at declaration"* — is defensible (it makes the whole seam
disappear) but it **breaks N2** (`eq : Num a => a -> a` alongside the prelude's `Eq.eq`), i.e.
it makes an entire class of ordinary user programs illegal for a compiler-internal reason. I do
not recommend it, but it is a real option and it is dramatically cheaper.

### Fork B — representation: **`RLocal String (List Route)`** vs **reuse `EMethodAt`'s `implRef`**

`EMethodAt` already has a `Ref (List Route)` (`ast.mdk:244`, the impl-dicts ref) that the
`RLocal` arm **receives and ignores** in all three backends. Filling *that* would need **no AST
change, no sexp change, no marker change** — much less churn.

**I recommend against it, and I have a concrete reason, not a stylistic one.**
`inferDefinerShadowApp:5043-5045` pushes a `pendingArgStamps` entry **unconditionally**
(regardless of which arm it took), and `resolveArgStamp:1946-1949` then does
`setRef tagRef (RKey …)` **and `setRef implRef (…)`** — *before* `resolveRLocalSites:13046`
overwrites the *tag* back to `RLocal`. So on a standalone-arm occurrence **`implRef` can
already hold the dispatch arm's impl dicts.** Reusing it would be **one Ref carrying two
meanings, with a live stale writer** — precisely the shape that produced the refutable-guard
miscompile the workstream cites. The route has exactly one writer for the RLocal arm; use it.

**Decision needed:** accept the AST change (my recommendation), or take the cheaper `implRef`
route with an explicit clear-on-stamp?

### Fork C — is `size 3` **`4`**, or should it default differently?

I assumed the answer is **`4`** (no `impl Sz Int` ⇒ S2 standalone ⇒ `Num Int` ⇒ `3 + 1`), which
matches the unconstrained control (`p0_20_shadow_literal_noimpl_standalone.out` = `4`) and
row B. **I believe this is uncontroversial** but it is the value pinned into the `.out` file, so
it is worth one line of confirmation.

### Fork D — scope: does this stage also fix the **importer** shadow?

Row **R** proves the importer shadow (`inferShadowApp:4927`) has the identical bug. It is the
same fix in a second function. **Recommend: in scope** (it is ~20 extra lines and the fixture is
already written). The alternative is to file it as S-1b and ship the definer half first.

### Fork E — the `singleTyparamIfaceMethod` gate (S-3)

Every entry point to this machinery is gated on `singleParamIfaceMethod` (`:4969`, `:5241`),
which — per the workstream — **counts interface TYPE PARAMS, not method params**, and its name
says the opposite. The S-1 fix **inherits that gate**: a constrained shadow of a multi-typaram
interface will not be fixed by this work. **Recommend: out of scope, but rename the predicate
`singleTyparamIfaceMethod` in stage 5** so the next reader is not misled (it already misled one
agent, per the workstream).

---

## 7. The gates that will prove the fix

**Owner gate:** `test/diff_compiler_run_check_agreement.sh` — it now compares the **value**
(`run` stdout == built-binary stdout, plus an optional `.out` pin), which is the only reason
this class of bug is visible at all. **Both directions are owed:**

| fixture | `.expected` | `.out` | proves |
|---|---|---|---|
| `s1_constrained_shadow_standalone` | ACCEPT | `4` | the headline bug (row A/C) |
| `s1_constrained_shadow_domain_mismatch` | **REJECT** | — | the reject direction (row P) — `size "hi"` ⇒ located `Num String` |
| `s1_constrained_shadow_dispatch` | ACCEPT | `IMPL` | **the control** — row G still dispatches (this is what a guard-chain reorder would break) |
| `s1_constrained_shadow_nested_dict` | ACCEPT | — | row Q — an **`RDict`** slot forwarded from a constrained caller; the closure-capture case for `methValDictNames`/`freeVarsRoute` |
| `s1_constrained_shadow_value_pos` | ACCEPT | — | row K (S4 value position, currently a **GC OOM**) |
| `s1_constrained_shadow_user_iface` | ACCEPT | — | row F — `Num` is not special |
| `s1_constrained_shadow_no_sig` | ACCEPT | `4` | row H — an **inferred** constraint |
| `s1_constrained_shadow_importer/` | ACCEPT | `4` | row R — the importer half |

**Also required:**
- **`test/build_wasm_cmd.sh` + `wasm-tools validate`** on the same corpus. **This is
  non-negotiable** — §3 shows wasm is broken *differently*, and this repo has shipped a fix that
  landed in the LLVM emitter and never reached the wasm one. Assert `validate` passes **and**
  the wasm output value matches `run`.
- **Self-compile fixpoint C3a/C3b** — stage 2 touches `Route`, which the compiler's own 5
  definer shadows flow through. They are all unconstrained, so the `dicts == []` fast path must
  make them **byte-identical**. If the fixpoint moves, the guard is wrong.
- **`test/diff_compiler_snapshot_core_ir.sh`** — `routeSexp` goldens must not move for empty dicts.
- `test/shadow_fixtures/` gets `d10_definer_constrained.mdk` (matrix **row 26**).
- **`SHADOW-SEMANTICS.md` matrix row 26 + clause S9 + the §3 eval row correction** — the spec is
  currently *wrong*, and leaving it wrong is how this bug comes back.

---

## 8. What I verified vs. what I inferred

**Verified by running / reading:**
- the 18-row truth table (§1) — every row on all three paths on `main`
- the PAP + the 2-param callee, read out of the emitter's LLVM IR (§2.1)
- the guard chains at `:6818-6821`, `:6861-6865`, `:6943-6951`, and `dictPassDecl:8869` (§2.2)
- `resolveRLocalSites` at `:13046` running **before** `resolveDictApps` at `:13048` (§4.3)
- `resolveArgStamp:1949` writing `implRef` on the same occurrence (Fork B)
- the WasmGC validation failure (§3)
- `ppSchemeNamed:2599`'s bare-name lookup (§2.5)
- the compiler's own 5 definer shadows are all unconstrained

**Inferred (not executed):**
- that `routesOfMonosTop` is safe to call from inside `resolveRLocalSites` — it is a pure
  function of solved monos, and `activeDictVars` is bound at that point (`resolveArgStamp` one
  line earlier reads it), but I did not build an instrumented compiler to prove it.
- the exact size of the `check`-path obligation fix (`schemeObligationsRef` vs
  `funConstraintsRef` on the un-elaborated path).
- that no DCE change is needed for RLocal's dict routes.
