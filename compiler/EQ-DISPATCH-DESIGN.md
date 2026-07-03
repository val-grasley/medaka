# `==`/`!=` → `Eq` Dispatch (Option A) — Design + Blast-Radius Census

**Status:** DESIGN + CENSUS (no fix shipped). 2026-07-03.
**Base:** ancestor `9fddb349` (BASE_OK) — the live missing-constraint check.
**Files under study:** `compiler/types/typecheck.mdk`, `compiler/eval/eval.mdk`,
`compiler/backend/llvm_emit.mdk`, `compiler/backend/wasm_emit.mdk`,
`stdlib/core.mdk`.

## The approved change (Option A — full dispatch)

Today `==`/`!=` are a **builtin structural compare that bypasses the `Eq`
interface entirely** (`core.mdk:48`: "`==` on primitives is a builtin and does
*not* dispatch through this interface"). Consequences: a custom/derived `Eq`
impl is **silently ignored** by `==`, and `==` on functions is silently
accepted. Option A makes `==`/`!=`:

1. **constraint-generating** — `x == y` emits an `Eq a` obligation on the
   operand type (typecheck), exactly like `+` emits `Num a`; and
2. **dict-routed for polymorphic operands** — a poly `==` goes through the `Eq`
   dict (honoring custom impls), while **concrete Int/String/… keep a static
   fast path** — mirroring the existing poly-Num/Ord machinery
   (`mdk_num_*`/`numPolyLocalsRef` in llvm_emit, `$mdk_value_eq`/`$mdk_value_cmp`
   + `numPolyLocalsRef` in wasm_emit).

---

## 1. How `==`/`!=` flow TODAY

### Token → AST
`==`/`!=` are distinct tokens (`TEqEq`/`TNeq`, `parser.mdk:446-447`) that both
parse to the **same generic** node `EBinOp String Expr Expr (Ref Route)`
(`ast.mdk:143`) — `EBinOp "==" …` / `EBinOp "!=" …`, carrying a dict-route ref.
Not lowered at parse time.

### Typecheck — **NO constraint today**
- `typecheck.mdk:3090` — `infer … (EBinOp op l r dref) = inferBinopE …`.
- `typecheck.mdk:3952-3958` — `inferBinopE` infers `lt`/`rt`, calls
  `recordBinopSite`/`recordArithSite` (dict-route stashing), then
  `inferBinop op lt rt`.
- `typecheck.mdk:4003-4004` — `inferBinop "==" lt rt = compareOp lt rt`
  (and `"!="`).
- `typecheck.mdk:4097-4100` — the whole typing:
  ```
  compareOp lt rt = let _ = unify lt rt ; TCon "Bool"
  ```
  Operands unified, result `Bool`, **and NO obligation recorded**. So `==` types
  as `a -> a -> Bool` with an *empty* constraint context.

**Note (verified):** `<`/`>`/`<=`/`>=` share `compareOp` too (`4005-4008`) and
likewise generate **no `Ord` constraint** today. So `<` is *not* the precedent —
only `+`→`Num` is (§2).

`recordBinopSite` (`3967-3970`) *does* stash a **dict-routing** site
(`pendingBinopSites`) via `binopMethod "==" = Some "eq"` (`3988`) — but that only
drives later dict *rewriting*, it is not a constraint/obligation.

### `!=` relationship — shares the `eq` seam
`!=` is a separate token but maps to the same method: `binopMethod "!=" = Some
"eq"` (`3989`). In the typecheck dict-rewrite it becomes `not (eq l r)`:
`binopMethodApp` (`typecheck.mdk:7339-7344`) builds `EApp (EApp (EMethodAt "eq" …)
l) r` and wraps it in `EVar "not"` when `op == "!="`. Eval has the native
fallback `evalArith "!=" a b = VBool (not (valueEq a b))` (`eval.mdk:1367`).
**So `!=` already desugars to `not (== )` at the dict layer** — it does not need
an independent Eq seam.

### Eval — monolithic builtin structural walk (no dict)
- `eval.mdk:1366-1367` — `evalArith "==" a b = VBool (valueEq a b)` /
  `"!=" … not (valueEq a b)`.
- `eval.mdk:499-512` — `valueEq` is a shape-by-shape structural compare:
  `VInt/VFloat/VString/VChar/VBool/VUnit/VTuple/VList/VArray/VCon/VRecord/VRef`,
  with `valueEq _ _ = False` catch-all. Constructors compare by **name string +
  recursive arg list** (`Red == Green` → names differ → `False`). **Functions**
  (`VClosure`/`VPrim`) hit the catch-all → always `False`, never an error.
  **No `Eq` dictionary is consulted anywhere.**

### LLVM emit — already a runtime helper `@mdk_value_eq`
- `llvm_emit.mdk:2691-2702` — `emitValueEq`: `==` → `call i64 @mdk_value_eq`;
  `!=` → same then `xor i64 r, 2` (flips the tagged Bool 3↔1).
- `llvm_emit.mdk:2614-2649` — `emitCmp`/`emitCmpW` route to `emitValueEq` when an
  operand LTy is `LTUnknown`, or `LTInt` + `isEqOp`. Strings → `@mdk_string_eq`
  (`emitStrCmp`, `2727-2738`). `intPred "=="/"!="` (`7794-7795`) exist for the
  residual raw-`icmp` path but concrete Int `==` still goes through
  `@mdk_value_eq` (note at `2666-2668`).
  **So `==` is *already* a runtime structural helper, not inline `icmp` — it just
  never consults a dict.**

### WASM emit — runtime helpers `$mdk_value_eq` / `$mdk_value_eq_num`
- `wasm_emit.mdk:4163-4172` — `emitValueCmpRef`: `==` → `call $mdk_value_eq`;
  `!=` → same then `i31.get_u; i32.eqz; ref.i31`.
- `wasm_emit.mdk:4178-4193` — `emitValueCmpNumRef` (num-only, string-free
  programs) → `$mdk_value_eq_num`.
- Pure-int fast path is inline `wasmBinOp64` `i64.eq`/`i64.ne` (`4138`,
  `7164-7165`). Ordering uses `$mdk_value_cmp`/`_num`.

---

## 2. The dispatch design — mirror the poly-Num precedent

### 2.1 Typecheck: make `==`/`!=` generate `Eq a` (the census engine)
Mirror `numArithOp`/`recordNumObligation` exactly. Prototype (used verbatim for
the census below):

```
inferBinop "==" lt rt = eqCompareOp lt rt
inferBinop "!=" lt rt = eqCompareOp lt rt

eqCompareOp lt rt =
  let _ = unify lt rt
  let _ = recordEqObligation lt
  TCon "Bool"

recordEqObligation lt
  | eqIfaceRegistered () = setRef pendingImplObligations
      (("Eq", ["a"], TyVar "a", lt, currentLoc.value)::pendingImplObligations.value)
  | otherwise = ()

eqIfaceRegistered _ = anyList eqEntry methodIfaceParamsRef.value
eqEntry (_, (iface, _, _)) = iface == "Eq"
```

This reuses the entire existing obligation pipeline:
- `pendingImplObligations` → `checkImplObligations`: a concrete non-`Eq` head
  with no impl → **`No impl of Eq for <T>`**; a still-polymorphic head **defers**
  to the caller (an `Eq a =>` site), exactly the Num behaviour.
- The **live missing-constraint check** (`missingConstraintMsg`,
  `typecheck.mdk:9494`; raised in `reportUncovered`, `9458-9466`) then flags any
  **signed** binding whose body induces `Eq a` on a quantified var absent from
  its declared context → **`Could not deduce 'Eq a' from the signature of 'f'`**.
  This is precisely the census worklist.
- Gating on `eqIfaceRegistered` keeps the no-prelude bare-HM oracle
  (tc_probe/typecheck_main) byte-identical (no `Eq` class without core loaded) —
  same rationale as `numIfaceRegistered`.

**`!=` needs no separate obligation** — it shares `eqCompareOp` and already
lowers to `not (eq …)` at the dict layer (`7339-7344`).

### 2.2 Eval: dict-dispatch polymorphic `==`, keep structural for concrete
The dict machinery **already exists and is already used by `!=`/`==`**:
`binopMethodApp` (`7339-7344`) rewrites the binop to `eq`/`not(eq …)` via
`EMethodAt "eq"`, and `recordBinopSite` stamps the route ref. So the eval-side
change is small: where the route ref resolved to a **dict** (polymorphic
operand), route through the `Eq` dict's `eq` (honoring custom impls); where it is
`RNone`/concrete, fall through to the builtin `valueEq` fast path
(`eval.mdk:499`). The value-restriction, marker (`EMethodRef`), and dict-passing
plumbing that make `eq`/`compare` dispatch already carry `==` — this is the same
seam poly-Num/Ord `<`/`+` ride.

### 2.3 LLVM: split static-fast vs dict, mirroring `LTNum`
The precedent: arithmetic branches on the operand **`LTy`**. `emitArithW`
(`2575-2606`) routes `LTFloat`→static float, **`LTNum`** (`626`, "polymorphic
`Num a` operand")→`@mdk_num_add` runtime helper, else static Int. `LTNum` is
seeded by `binOperandTy` (`7688-7692`): `isNumPolyParam … && usedArith = LTNum`.

Mirror for Eq: introduce an **"Eq-polymorphic operand" signal** (an `LTEq`-style
seed, or reuse the poly-var detection `binOperandTy` already computes) and, in
`emitCmpW`/`emitValueEq` (`2634-2702`), insert a **dict-dispatch branch before the
`@mdk_value_eq` fallback**: poly operand → call the threaded `Eq` dict's `eq`;
concrete Int/String/unknown-structural → keep today's `@mdk_value_eq`/
`@mdk_string_eq`. Because `==` *already* funnels through `@mdk_value_eq`, this is
an **insertion of one branch**, not a rewrite of the equality path.

### 2.4 WASM: add an `isPolyEqOperand` arm, mirroring `isPolyNumBinop`
The precedent: `emitBinRef` (`4100-4139`) decides static-float → string-capable
`$mdk_value_eq` → **`isPolyNumBinop`→`$mdk_value_eq_num`** → inline `i64.eq`. The
poly signal is `numPolyLocalsRef` (`576-577`, seeded by `numPolyParamNames`
`3406-3420`); `isPolyNumOperand (CVar x _) = contains x numPolyLocalsRef.value`
(`4144-4149`) — **only a bare `CVar` bound to a poly param routes to the runtime
helper**. Mirror: seed an Eq-poly-locals set the same way (params whose declared
type is a type var used in an `==`/`!=`) and add an `isPolyEqOperand` arm in
`emitBinRef` that routes to the dict `eq`; concrete operands keep
`emitValueCmpRef`/`_num`/inline `i64.eq`. Gate the helper emission like
`useValueCmpRef`.

**Reused machinery, by name:** `pendingImplObligations`/`checkImplObligations`,
`missingConstraintMsg`/`reportUncovered`, `binopMethod`/`binopMethodApp`/
`recordBinopSite`/`EMethodAt "eq"`, `LTNum`/`binOperandTy`/`emitArithW`(pattern),
`numPolyLocalsRef`/`isPolyNumBinop`/`emitBinRef`(pattern), `@mdk_value_eq`/
`$mdk_value_eq`.

---

## 3. THE CENSUS — **0 + 0 + 0 newly-failing sites**

**Method.** PROTOTYPED §2.1 (`==`/`!=` push an `Eq` obligation), rebuilt
`./medaka`, then ran `MEDAKA_ROOT=$PWD ./medaka check <module>` over **every**
`.mdk` in `compiler/ + stdlib/ + sqlite/` **as its own entry** (so each module's
own signed members are re-inferred and censused). Collected the two diagnostics
the change produces. Then `git checkout -- typecheck.mdk` (prototype reverted —
**confirmed**: `grep -c eqCompareOp` = 0).

Validation the tool actually fires (calibrated on the live binary):
- `f : a -> a -> Bool ; f x y = x == y` → `Could not deduce 'Eq a' from the
  signature of 'f'` ✅ (case a).
- `export badEq : a -> a -> Bool ; badEq x y = x == y` (module-as-entry) → fires
  ✅ — confirms the loader/`processSCC` path is exercised.
- `data Color=… ; f = Red == Green` (no deriving) → `No impl of Eq for Color` ✅
  (case b); adding inline `deriving (Eq)` → passes ✅.
- `f : Int -> Bool ; f x = x == 3` → passes (concrete, static path) ✅.
- `f : a -> a -> Bool ; f x y = x < y` → **still passes** ✅ (`<` untouched,
  out of scope).

**Result over the whole tree:**

```
MODULES CHECKED = 186 (compiler + stdlib + sqlite, each as entry)
LOAD FAILURES   = 0  (only sqlite_test_select_typeerror.mdk — a deliberate
                      type-error fixture; runtime.mdk's "panic" is an extern in
                      the scheme dump, not an error) → full coverage
(a) "Could not deduce 'Eq …'"  = 0   signatures need Eq threaded
(b) "No impl of Eq for <T>"    = 0   ADTs need `deriving Eq`
(c) == on functions/effmonads  = 0   (would surface as No impl of Eq for <fn>)
```

**Interpretation.** The in-tree corpus **already** satisfies Eq-dispatch
soundness. Every *signed* function that compares polymorphic values with `==`
already declares `Eq a` (e.g. `elem : (Foldable t, Eq a) => …`, `core.mdk:1005`),
and every ADT compared with `==` already has an `Eq` impl (21 `deriving (Eq)`
sites across compiler+stdlib; ADTs like tokens are otherwise compared by
pattern-matching, not bare `==`). *Unsigned* poly-`==` helpers do not error at
def-site — their inferred `Eq` is auto-promoted (`registerInferredConstraints`),
exactly as for existing `eq` calls. **The fixup is a day, not a week.**

> Coverage caveat (honest, same as the sibling design): module-as-entry censuses
> that module's *own* signed members; imports are seeded as schemes. Because
> **every** module ran as an entry, every signed member was censused once. Do not
> use `check_modules_main` to census — it is a scheme-dump that swallows
> diagnostics.

---

## 4. Perf check — hot `==` stays concrete

The compiler's hot `==` sites are all **concrete** → they keep the static fast
path (no new dict):
- `contains : String -> List String -> Bool` (`util.mdk:13-15`) — String.
- `lookupAssoc : String -> List (String,b) -> …` key compare (`util.mdk:36`) —
  String.
- lexer/parser char/string scanning `c == '\n'`, `stringSlice … == pre`
  (`util.mdk:64,78,123-127,169,175`) — Char/String.

Census (a)=0 means **no signed polymorphic `==`** anywhere in the compiler, so no
hot inner loop newly pays a dict. Concrete Int/String `==` continue through
`@mdk_value_eq`/`@mdk_string_eq` (LLVM) and `i64.eq`/`$mdk_value_eq` (wasm),
unchanged. **No perf regression flagged.**

---

## 5. Structural-fallback decision

Today `Red == Green` with **no** `deriving Eq` works via the builtin structural
`valueEq`. Under Option A it needs an `Eq` impl (`deriving (Eq)` or hand-written)
— the operand grounds to `Color`, generating `Eq Color`, and with no impl the
site is rejected `No impl of Eq for Color`.

**Migration cost in-tree = 0** (census b = 0; the 21 existing `deriving (Eq)`
sites already cover every in-tree ADT `==`). This *is* a breaking change for
**out-of-tree user code** that leaned on the structural builtin — such code must
add `deriving Eq`. That is the intended semantic tightening (align `==` with the
interface), and it is exactly the diagnostic `No impl of Eq for <T>` guides the
user to. **Recommend: accept the tightening; it costs nothing in-repo and the
error message is self-explanatory.**

---

## 6. Staged implementation plan (each stage independently gated)

| # | Stage | Where | Gate | Re-mint? |
|---|-------|-------|------|----------|
| 1 | **Constraint-gen** — `==`/`!=` push `Eq` obligation (§2.1) | `typecheck.mdk` (`eqCompareOp`/`recordEqObligation`) | `diff_compiler_check*`, error-quality fixtures; census stays 0 | **No** (typecheck-only, IR unchanged) |
| 2 | **Eval dispatch** — route poly `==` through the `Eq` dict; keep `valueEq` for concrete (§2.2) | `eval.mdk` + existing `binopMethodApp` seam | `diff_compiler_eval*`, `eval_modules` (custom-`Eq` fixture: derived impl now honored) | **No** (eval is not the emitter) |
| 3 | **LLVM emit** — insert dict branch before `@mdk_value_eq` (§2.3) | `llvm_emit.mdk` (`emitCmpW`/`emitValueEq`, `LTEq`-style seed) | `diff_compiler_llvm*`, `selfcompile_fixpoint` C3a/C3b, run==build custom-Eq fixture | **YES — at this checkpoint** (emitted IR changes) |
| 4 | **WASM emit** — `isPolyEqOperand` arm in `emitBinRef` (§2.4) | `wasm_emit.mdk` | `test/wasm/diff_wasm*`, wasm custom-Eq fixture | No new re-mint (wasm seed is separate; native seed already re-minted at 3) |
| 5 | **Self-compile fixup** — add `Eq a =>` / `deriving Eq` to any newly-flagged compiler site, driven by the missing-constraint check | across `compiler/*` | full gate suite green; census 0 | (folded into 3's re-mint) |

**Re-mint point:** exactly **one** native seed re-mint, at **stage 3** (first
emitter change). Stages 1–2 are typecheck/eval-only and fixpoint-safe. Stage 5 is
empty in-tree (census 0) — it exists only if a future compiler edit introduces a
poly `==`.

**Ordering rationale:** land 1 first (pure reject, verify 0 census holds on the
binary), then 2 (behavioral: custom impls honored under `run`), then 3+4
(backends: `run==build` and `native==wasm` for a custom-Eq fixture), each with
its own gate. This matches the poly-Num/Ord roll-in that already shipped.

---

## 7. Design forks (recommendations)

1. **`!=` desugar vs independent dispatch.** *Recommend: keep desugar to
   `not (eq a b)`* — it already exists (`binopMethodApp`, `7339-7344`;
   `evalArith`, `1367`; `xor`/`i32.eqz` in both emitters). An independent `neq`
   method would let an impl make `!=` disagree with `==` (unsound) and duplicate
   the fast paths. `core.mdk`'s `neq` already documents "standalone so impls
   cannot make it disagree" (`54-55`).

2. **AST-level Int==Int fast path vs always-through-Eq-with-fast-impl.**
   *Recommend: keep the AST/emit-level static fast path* (the poly-Num model) —
   concrete Int/String `==` compiles to `@mdk_value_eq`/`i64.eq` with no dict, and
   only genuinely-polymorphic operands route to the dict. Forcing everything
   through a dict `eq` would regress every hot concrete `==` (see §4). The
   split is exactly what `LTNum`/`numPolyLocalsRef` already do for `+`/`<`.

3. **Scope of `deriving Eq` auto-add.** *Recommend: do NOT auto-derive* — require
   explicit `deriving (Eq)` (census b=0, so no in-tree churn; explicit is
   consistent with how Ord/Debug already work). The `No impl of Eq for <T>`
   diagnostic already points the user at the fix. Optionally emit a
   `help: add 'deriving (Eq)' to <T>` hint (cheap; mirrors the constraint
   auto-suggest fork in the sibling design).

4. **Also make `<`/`>`/`<=`/`>=` generate `Ord`?** Out of scope for this task
   (the approved change is `==`/`Eq`). But note the **symmetry**: `compareOp`
   currently gives `<` no `Ord` constraint either, so the same builtin-bypass
   critique applies. *Recommend: file a sibling `Ord`-dispatch follow-up* using
   this exact design (the machinery — `LTNum`-style seed, `pendingImplObligations`
   — is already Ord-aware via `mdk_num_cmp`/`$mdk_value_cmp`). Do it separately so
   each has its own census (the Ord census may differ from Eq's).

5. **Reject vs warn for the missing-constraint / no-impl sites.** *Recommend:
   REJECT* (matches the live check and `checkEffectEscape`). Census is 0 → nothing
   in-tree breaks; a `--warn` phase-in is unnecessary.

---

## Size estimate

**S–M.** Census is **0/0/0** — no signature threading, no `deriving` additions,
no latent-bug fixups needed in-tree. The work is: 1 typecheck helper (~15 lines,
prototyped), 1 eval branch, 1 LLVM branch, 1 wasm arm — each a direct mirror of
shipped poly-Num/Ord machinery — plus custom-`Eq` fixtures and **one** seed
re-mint at stage 3. The only genuinely new design is the emitter poly-Eq operand
seed (§2.3/2.4), and even that is a transcription of `LTNum`/`numPolyLocalsRef`.
Call it **S** for typecheck+eval (stages 1–2, no re-mint) and **M** including
both backends + fixpoint (stages 3–4).

---

## Appendix — key line citations

| What | File:line |
|------|-----------|
| `EBinOp String Expr Expr (Ref Route)` | `ast.mdk:143` |
| `TEqEq`/`TNeq` parse to `EBinOp "=="/"!="` | `parser.mdk:446-447` |
| `inferBinop "=="/"!=" = compareOp` | `typecheck.mdk:4003-4004` |
| `compareOp` (no constraint — the seam to change) | `typecheck.mdk:4097-4100` |
| `binopMethod "=="/"!=" = Some "eq"` | `typecheck.mdk:3988-3989` |
| `numArithOp`/`recordNumObligation` (the precedent to mirror) | `typecheck.mdk:4038-4058` |
| `binopMethodApp` (`!=` → `not(eq)`; `EMethodAt "eq"`) | `typecheck.mdk:7339-7344` |
| `missingConstraintMsg` / `reportUncovered` (census engine) | `typecheck.mdk:9494`, `9458-9466` |
| `evalArith "=="/"!="` → `valueEq` | `eval.mdk:1366-1367` |
| `valueEq` structural walk (no dict) | `eval.mdk:499-512` |
| `emitValueEq` (`@mdk_value_eq`) | `llvm_emit.mdk:2691-2702` |
| `emitCmpW` routing | `llvm_emit.mdk:2614-2649` |
| `LTNum` + `emitArithW` dispatch (precedent) | `llvm_emit.mdk:626, 2575-2606` |
| `binOperandTy` seeds `LTNum` | `llvm_emit.mdk:7688-7692` |
| `emitValueCmpRef` (`$mdk_value_eq`) | `wasm_emit.mdk:4163-4172` |
| `emitBinRef` static/dict branch | `wasm_emit.mdk:4100-4139` |
| `numPolyLocalsRef` / `isPolyNumOperand` (precedent) | `wasm_emit.mdk:576-577, 4144-4149` |
| `Eq` interface + builtin-bypass note + `neq` | `core.mdk:47-55` |
