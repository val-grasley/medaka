# WASM-FLOAT-TYPING-DESIGN — the principled fix for W-SQLITE-4

**Status:** IMPLEMENTED — stage 1 `b5eb9606`, stage 2 `2d321af6`, 2026-06-30. Verified
live: `floatRetFnsRef`/`floatParamsRef`/`ctorFloatFieldsRef` all present in
`compiler/backend/wasm_emit.mdk` (7 source markers, matching this doc's own and
`SHARED-FLOAT-RESIDUAL-DESIGN.md`'s claims). Header below predates the fix.

Original header (predates the fix): **Status:** DESIGN (read-mostly scoping). No emitter/lib source changed. Bug =
`EMITTER-GAPS.md` §W-SQLITE-4: type-erased Float arithmetic on WasmGC miscompiles
as INTEGER arith → `mdk_unbox_int` (`i31.get_s`/`ref.cast (ref i31)`) on a boxed
`$float` → runtime **"illegal cast"** trap. This is the WasmGC analog of the native
LLVM "arith on type-lost floats" arc (memory `project_arith_on_typelost_floats_bug`,
7 fixes 2026-06-18), which `llvm_emit.mdk` solved by threading real `LTy`.

All results below reproduced on this worktree at BASE_OK (`d493676` ancestor of
HEAD), native build green, `bash test/wasm/diff_wasm.sh` = **141 ok, 0 failing**,
Node v24.17.0.

---

## 1. Empirical repro — blind-spot table

Oracle = the **native-compiled binary** (`medaka build <f> -o bin && ./bin`), which
applies the `pp_value` auto-print contract (same oracle `test/wasm/diff_wasm.sh`
uses). wasm = `medaka build --target wasm <f>` → `wasm-tools parse/validate` →
`node test/wasm/run.js`. Probes in scratchpad; each is a bare-value `main` (auto-print).

| # | case | probe body | native cbin | wasm | verdict |
|---|------|-----------|-------------|------|---------|
| a | Float **fn param** arith, no co-located literal | `f x = x + x` (`f : Float -> Float`); `main = f 2.5` | `5.0` | **TRAP** `instantiate failed: illegal cast` | wasm-only BUG |
| b | Float-returning fn **with a literal in every binop** | `g x = x * 2.0`; `main = (g 3.0) + 1.0` | `7.0` | `7.0` | WORKS (literal anchors detection) |
| c | **tuple-destructured** Floats | `addPair p = match p ((a,b) => a + b)` (`(Float,Float)->Float`); `main = addPair (1.5,2.5)` | `4.0` | **TRAP** illegal cast | wasm-only BUG |
| d | **record-field** Floats | `data R = R {u:Float,v:Float}`; `sumR r = r.u + r.v`; `main = sumR (R{u=1.5,v=2.5})` | `4.0` | **TRAP** illegal cast | wasm-only BUG |
| e | **ctor-payload** match-bound Float | `data Box = Box Float`; `unbox b = match b (Box f => f + f)`; `main = unbox (Box 4.5)` | `9.0` | **TRAP** illegal cast | wasm-only BUG |
| f | **fold accumulator**, sig'd wrapper | `sumF : List Float -> Float`; `sumF xs = fold (acc x => acc + x) 0.0 xs`; `main = sumF [1.0,2.0,3.0]` | `6.0` | **TRAP** illegal cast | wasm-only BUG (see §5) |
| g | fold accumulator, **bare value main** | `main = fold (acc x => acc + x) 0.0 [1.0,2.0,3.0]` | `2185922448` (native ALSO wrong — auto-print type-lost) | **TRAP** | SHARED residual |
| h | Int fold (control) | `main = fold (acc x => acc + x) 0 [1,2,3]` | `6` | `6` | WORKS |

**Loud, not silent-wrong.** For case (a) `wasm-tools validate --features=all` PASSES;
the failure is a *runtime* `ref.cast` trap at instantiation. So the fix turns
trapping/rejected-valid programs into working ones — it is **not a soundness patch**.
Int programs (h) are unaffected.

**Decisive WAT** (case a, `$b_bare__f`):
```wat
(func $b_bare__f (param $u____wparg0 (ref eq)) (result (ref eq))
  local.get $u____wparg0
  local.set $x
  local.get $x   call $mdk_unbox_int      ;; <- i31 cast on a $float box
  local.get $x   call $mdk_unbox_int
  i64.add
  call $mdk_box_int
  return)
```
Case (b) works because `g`'s body `x * 2.0` and the call site `(g 3.0) + 1.0` each
contain a Float **literal**, so `cexprIsFloat` returns True and `emitFloatBinRef`
fires (`struct.get $float 0` / `f64.mul` / `struct.new $float`).

---

## 2. Root-cause map

### The decision point
`emitBinRef` (`wasm_emit.mdk` ~3518) is the ONLY place arithmetic commits to a
representation, and it commits **statically**:
```
emitBinRef prog env d op l r =
  if isArithOrCmp op && (cexprIsFloat prog env l || cexprIsFloat prog env r)
    then emitFloatBinRef …            -- unbox $float, f64 op, rebox
  else if isCmpOp op && useStrRef.value
    then emitValueCmpRef …            -- runtime-shape-dispatched (handles Float too)
  else                                -- INT PATH: unbox_int, i64 op, box_int  <-- traps on $float
```
Note the asymmetry: **comparisons** in a string-using program route through the
runtime-shape-dispatched `$mdk_value_cmp`/`$mdk_value_eq`, which would handle a
`$float` operand at runtime. **Arithmetic has no such runtime fallback** — it must
decide statically, and when `cexprIsFloat` is False it emits `mdk_unbox_int` and
traps.

### `cexprIsFloat` (~3596) — a purely STRUCTURAL detector
Returns True only for: a Float **literal**; `pi`/`e` (unless shadowed by `env`); a
name in `floatLocalsRef.value`; a `CApp` whose head ∈ `["intToFloat","randomFloat"]`;
a nested arith binop with a Float operand; and let/block/if whose result is Float.
It has **no arm** for: a bare `CVar` param (unless in `floatLocalsRef`), a **user
fn returning Float** (`CApp` arm only knows the two externs), a **`CFieldAccess`**,
or a **`CMatch`/ctor-bound** variable.

### `floatLocalsRef` (~514) — the only non-literal Float source, and it's tiny
```
floatLocalsRef : Ref (List String)   -- CVars the structural detector can't otherwise see
```
Populated at **exactly one site**: `emitImplGroup` (~2971) sets it to the pattern
vars of an `impl … Float` method's clauses (so `impl Num Float`'s `add`/`negate`/…
params are known Float), and resets it to `[]` for every other impl and all
non-impl code. It does **not** cover ordinary user functions, fold lambdas, record
fields, or ctor payloads.

### Every site that trusts `cexprIsFloat` and misfires on a type-erased Float
| site | ~line | effect on miss |
|------|-------|----------------|
| `emitBinRef` arith/cmp dispatch | 3519 | Int path → `mdk_unbox_int` → **trap** (the bug) |
| `emitUnRef "-"` | 3626 | integer negate over an i64 box → wrong / trap |
| `refMainKind` `CBinPrim` | 2126 | auto-print picks Int kind → renders `$float` pointer as int (case g) |
| `refMainKind` `CUnOp "-"` | 2129 | same |

---

## 3. Native LLVM solution — what's portable

`llvm_emit.mdk` threads **real static type** everywhere: `emitExpr : … -> (String, LTy)`
— every emitted value carries its `LTy` (`LTFloat`/`LTInt`/…). Float sources are
seeded from:

- **Declared signatures** — `declSigOf name` (`declParamLTy`/`declRetLTy`, ~515/524)
  over `fieldNameToLTy` (~481: `"Float" → LTFloat`). Fed by
  `installDeclSigTypes (declSigTypeNames runtimeDecls ++ declSigTypeNames allDecls)`
  in `entries/llvm_emit_modules_main.mdk` (~96).
- **Constructor/record field types** — `ctorFieldTypeNamesOf con` (~472), fed by
  `installCtorFieldTypes (ctorFieldTypeNames allDecls)` (~95).
- **Tags** — `tagToLTy`, plus body-use inference (`inferSigs`/`paramUseTy`).

**Is the type info available to wasm upstream? YES, cheaply.**
`declSigTypeNames` and `ctorFieldTypeNames` are **exported from `core_ir_lower.mdk`**
(~1009 / ~964) and `entries/wasm_emit_modules_main.mdk` **already imports
`core_ir_lower`** (it uses `declSigTypeNames` in scope for other install hooks).
They read the **AST `Decl` list** (`DTypeSig`/`DExtern`/data decls) — the same
`allDecls` the LLVM modules entry passes.

**But `CProgram` does not carry them.** `emitProgram : CProgram -> String`, and
`CProgram = CProgram (List CBind) (ctorArities) (ctorTypes) (impls)` — no declared
signatures, no field types. So (exactly like LLVM) the tables must be **threaded in
via install hooks from the entries**, not recovered from the lowered `CProgram`.
The two scalar wasm entries (`wasm_emit_main`, `wasm_emit_typed_main`) currently
install **nothing** — they are bare `emitProgram (lowerProgramEmit (annotate (desugar
(parse …))))` pipelines — so the fix wires an install hook into all three entries
(the AST decls are transiently in scope in each before lowering).

---

## 4. Recommended fix + alternatives

### Recommended: MINIMAL — extend the existing structural mechanism with upstream tables

No change to the wasm value representation (stays `(ref eq)` + on-demand structural
detection). Add three small registries fed by the already-exported tables, and teach
`cexprIsFloat` + the body-emission seeding to consult them.

1. **New Refs** in `wasm_emit.mdk`, mirroring the LLVM registries:
   - `floatRetFnsRef : Ref (List String)` — user fns whose declared return head is
     `Float` (from `declSigTypeNames`, `retName == "Float"`).
   - `floatParamsRef : Ref (List (String, List Int))` — fn → indices of its `Float`
     params (from `declSigTypeNames` arg heads).
   - `ctorFloatFieldsRef : Ref (List (String, List Int))` — ctor/record → indices of
     `Float` fields (from `ctorFieldTypeNames`).
2. **Install hooks** `installWasmFloatSigs` / `installWasmCtorFloatFields`, called from
   **all three** entries (`wasm_emit_main`, `wasm_emit_typed_main`,
   `wasm_emit_modules_main`) — compute `declSigTypeNames`/`ctorFieldTypeNames` from the
   desugared AST decls before lowering (the modules entry already has `allDecls`).
3. **Generalize the `floatLocalsRef` seeding**: today only `impl … Float` params seed
   it. At each fn/clause body emission, additionally seed the fn's `Float`-typed
   param pattern-vars (from `floatParamsRef`). → fixes case **a**.
4. **`cexprIsFloat` `CApp` arm**: also True when the call head ∈ `floatRetFnsRef`
   (analog of native `declRetLTy`). → recognizes `cellNumF c`, `sumFloat`, etc.
5. **`cexprIsFloat` `CFieldAccess` arm**: True when the `(recName, label)` field type is
   `Float` (via `ctorFloatFieldsRef` + the ctorTypes already in `CProgram`). → case **d**.
6. **`CMatch`/`CDecision` ctor-binder seeding**: when an arm binds a payload var of a
   `Float` ctor field, add it to `floatLocalsRef` for that arm body. → case **e**.

**Coverage of MINIMAL:** cases **a, b(already), d, e** ✓; and crucially the *real*
`sumFloat` pattern `acc + cellNumF c` ✓ — because a binop needs only **one**
structurally-Float operand and `cellNumF : Cell -> Float` is now return-Float, so
the `faddF` workaround becomes removable (§5). **Misses:** case **c** (tuple element
types — a tuple param head isn't a scalar name in `declSigTypeNames`) and case **g**
(pure `acc + x`, both operands anonymous, no literal, no return-Float call).

### Alternative: FULLER — port LTy threading to wasm
Give `emitRefExpr` a threaded per-binder Float map (like LLVM's `(String, LTy)` env),
seeded from sigs/fields and propagated through `let`/`match`/lambda binders and
inferred from a fold seed's literal. Covers cases **c** and **g** too. Much larger
(touches the whole ref-mode emission spine) and almost certainly **unnecessary**:
the minimal fix already covers every *realistic* Float pattern (typed fns, records,
ctors, and any accumulation where one operand is a typed operation). Case **g**'s
pure `acc + x` is rare, and even **native** only prints garbage for its bare-value
form (auto-print type-lost) — it is a **shared** residual, not a wasm-specific gap.

**Recommendation: MINIMAL.** Rationale: the type info is available upstream at near-
zero cost (exported tables, already imported); the "one Float operand suffices"
property of binops makes the return-Float registry cover real accumulation loops; it
removes the `faddF` workaround; and it is strictly **additive** (Int stays the default,
so no existing fixture can regress). Defer FULLER (tuple + anonymous accumulator) to a
later item shared with native's residual.

---

## 5. Blast radius

**Unblocks on wasm:** any program that moves a `Float` through a **function
parameter, record field, or constructor payload** and does arithmetic on it without a
co-located literal — i.e. general Float math libraries, `SUM`/`AVG`-style reductions,
and future tandem SQL numeric features. Today every such program traps at instantiate.

**Removes the `faddF` workaround** (`sqlite/lib/aggregate.mdk` ~278):
```
faddF a b = (a + 0.0) + (b + 0.0)          -- current: seeds a Float literal per operand
sumFloat cells = fold (acc c => faddF acc (cellNumF c)) 0.0 cells
```
After Stage 2 (return-Float registry), this simplifies to the natural form
```
sumFloat cells = fold (acc c => acc + cellNumF c) 0.0 cells
```
because `cellNumF : Cell -> Float` makes the right operand structurally Float. This
simplification, gated green on **both** backends by `test/wasm/diff_sqlite.sh`, is the
regression proof.

**Correctness risk:** none of soundness. Today the affected programs TRAP loudly
(`validate` passes, runtime `illegal cast`); the fix converts trapping programs to
correct ones. The registries are additive and Int-defaulted, so no currently-green
program changes. Verified via WAT that the miss is a static Int commitment, not a
runtime shape mistake.

---

## 6. Staged plan (wasm-gated only — NO seed re-mint / NO LLVM fixpoint)

`wasm_emit.mdk` is **outside** the LLVM self-compile graph, so every stage is gated by
wasm harnesses alone: `bash test/wasm/diff_wasm.sh` (141/0 baseline + new fixtures)
and `bash test/wasm/diff_sqlite.sh` (both-backend tandem). No `emitter.ll` re-mint, no
`selfcompile_fixpoint`. Model new fixtures on `test/wasm/fixtures/w8b_float_arith.mdk`;
capture goldens with the gate's oracle (native-compiled binary).

| stage | model | work | gate | proves |
|-------|-------|------|------|--------|
| **0** | Sonnet | Add float-typing fixtures (cases a/d/e/f + control) to a **new** `test/wasm/fixtures` set; wire a `diff_wasm`-style gate (or extend `diff_wasm`). Initially these FAIL (document expected-trap) so later stages have a target. | new gate runs | pins the repro as a test |
| **1** | Opus | `floatParamsRef` + install hooks in all 3 entries + generalize `floatLocalsRef` seeding to sig'd Float params. | fixture **a** green; `diff_wasm` 141/0 | Float fn params |
| **2** | Opus | `floatRetFnsRef` + `cexprIsFloat` `CApp` arm. | fixture **f**-style + `sumFloat` pattern green | Float-returning fns; enables faddF removal |
| **3** | Sonnet | `ctorFloatFieldsRef` + `CFieldAccess` arm + `CMatch` ctor-binder seeding. | fixtures **d**, **e** green | records + ctor payloads |
| **4** | Sonnet | Remove `faddF`; simplify `sumFloat` to `acc + cellNumF c`. | `diff_sqlite` green BOTH backends | **regression proof** |
| **5** | Opus, DEFERRED | (optional) FULLER LTy threading for tuple (**c**) + anonymous accumulator (**g**). Only if a real program needs it. | new tuple fixture green | full native parity |

Each stage is independently committable and independently wasm-gated. Stage 4 depends
on Stage 2. Also update `emitUnRef` (~3626) and `refMainKind` (~2126/2129) to consult
the same registries (bundle into Stages 1–2) so unary-neg and auto-print of type-lost
Floats agree.

---

## 7. Design forks needing a human decision

1. **Minimal vs fuller scope.** Recommend **MINIMAL** now (covers all realistic
   patterns, low churn, additive), **FULLER deferred** (Stage 5, only if a tuple- or
   anonymous-accumulator program appears). Confirm?
2. **Remove the `faddF` workaround as part of this?** Recommend **YES** — it is the
   cleanest regression proof and the natural form is more readable. Requires Stage 2
   to land first (so `cellNumF`'s return-Float is registered). Confirm?
3. **Tuple + anonymous-accumulator parity (cases c, g).** Recommend **DEFER**. Note
   that native ALSO garbles case (g)'s bare-value auto-print (`2185922448` above), so
   this is a **shared** backend residual, not a wasm-only gap — arguably a separate
   dual-backend "typed lowering of anonymous accumulators" item. Include or defer?
4. **Wiring mechanism: install hooks (3 entries) vs extend `CProgram`.** Recommend
   **install hooks**, mirroring LLVM exactly (smallest change, keeps `CProgram`
   backend-agnostic). Downside: touches all three wasm entries. Alternative: add the
   sig/field-Float tables as fields on `CProgram` (one type change, no per-entry
   wiring, but a wider blast on the Core IR type). Preference?

---

## LOCKED SCOPE (orchestrator decision, 2026-06-30)

**MINIMAL fix** — all four forks per the design's recommendation:
1. Minimal (3 registries + new `cexprIsFloat` arms), NOT the fuller LTy port.
2. Remove the `faddF` lib workaround as the regression proof (after the return-Float stage).
3. **Defer** tuple-destructured + pure-anonymous-accumulator Float — native ALSO garbles the anonymous accumulator, so deferring keeps native/wasm at PARITY (not a new gap). Tracked as a shared residual.
4. **Install-hooks** (thread `declSigTypeNames` + `ctorFieldTypeNames` from the wasm entries, mirroring LLVM), NOT extending `CProgram`.

**Staged (all wasm-gated — `wasm_emit.mdk` is OUTSIDE the LLVM self-compile graph → NO seed re-mint / LLVM fixpoint; gates = `diff_wasm` 141/0 + new float-typing fixtures + `diff_sqlite`):**
- **Stage 1 (Opus)** — the core: install-hook plumbing (thread the upstream type tables from the ~3 wasm entries), the **float-return-fn** + **float-param** registries, and the `cexprIsFloat` `CApp`→return-Float + param arms. This enables the `sumFloat` pattern (`acc + cellNumF c`, `cellNumF : Cell -> Float`). Gate: the float-param + float-return probes run wasm==native. Incremental-landing OK (land params first + report if it's cleaner).
- **Stage 2 (Sonnet)** — record/ctor **field** Float: the field registry (from `ctorFieldTypeNames`) + `cexprIsFloat` `CFieldAccess` + `CMatch` ctor-binder arms. Gate: record-field + ctor-payload probes wasm==native.
- **Stage 3 (Sonnet)** — remove `faddF` from `sqlite/lib/aggregate.mdk` (restore the natural `acc + x`), confirm `diff_sqlite` (native==wasm) + `diff_wasm` green. The regression proof.
- **Deferred (S5, not scheduled):** fuller LTy threading for tuple-destructured + anonymous-accumulator Float — a shared native+wasm residual, low value.
