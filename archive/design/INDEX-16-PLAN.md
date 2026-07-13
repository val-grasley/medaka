# INDEX-16-PLAN.md — concrete staged implementation plan for the Index arc, Phase #16

**Status:** IMPLEMENTED — `c9478073`, 2026-07-12. Shipped exactly as staged below:
`stdlib/core.mdk:894` (`export interface Index c k v where`) and `:901`
(`IndexMut`), `TLBracketTight` in `compiler/frontend/lexer.mdk`, and
`bracketIndexTail`/`postfixTail` in `compiler/frontend/parser.mdk` all match this
plan verbatim. See PLAN.md's Open Issues Index. Residual value: the R0
post-order-desugar trap and two-pass fix (§ below) are a reusable technique for the
still-open #17 bare-slice `a[i..j]` follow-on.

**Companion to `INDEX-DESIGN.md`** (the decision-ready design + LOCKED forks). This doc is the
*implementation* plan: seam resolved, stages, exact touchpoints. Produced by a read-only Plan pass
on base `07bf5371` (all claims probe-verified on the built binary). Forks F0–F9 are LOCKED in
INDEX-DESIGN.md §7 / the HANDOFF — treat as fixed constraints.

> ⚠️ **Two INDEX-DESIGN.md claims are STALE (disproved here):**
> - **List indexing is NOT interpreter-only.** It lowers natively via `emitListIndex` →
>   `@mdk_list_index` (`compiler/backend/llvm_emit.mdk:8419`, `runtime/medaka_rt.c:459`,
>   `compiler/backend/llvm_preamble.mdk:45`) and traps a coded `E-INDEX-OOB` on `build`. The
>   "List build-path gap" comment at `compiler/types/typecheck.mdk:3157-3159` and INDEX-DESIGN §2
>   gap (1) are obsolete. **#16 inherits a working native List path — no native List gap.**
> - Wasm List/String index has no `emitRefExpr` arm (`CListIndex`/`CStringIndex` are LLVM/interp
>   only) — but **F2a retires those Core-IR nodes**, so wasm List/String indexing now flows through
>   the pure-Medaka impls (recursion / `stringToChars`), closing the old wasm gap **for free**.

---

## Seam resolution — the coded `E-INDEX-OOB` mechanism

**Problem.** `E-INDEX-OOB` is emitted ONLY from the built-in index path on every backend, never from
a Medaka-callable primitive (interp `runtimePanic "E-INDEX-OOB"` `eval.mdk:1088,1098`; native
`@mdk_oob` `medaka_rt.c:198`; wasm `wasmTrap "E-INDEX-OOB"` `wasm_emit.mdk:6941`). The only
Medaka-callable abort, `panic : String -> a` (`stdlib/runtime.mdk:57`), is hard-wired to `E-PANIC`.
So a pure-Medaka `index` impl body can't raise a coded `E-INDEX-OOB` today (probe P4 reproduced this:
`panic "…"` → `E-PANIC`, wrong code). This is the deferred "B4 stdlib coded-OOB seam"
(`RUNTIME-TRAP-UNIFY-DESIGN.md` §6 B4).

**Chosen: Option A — one coded-OOB abort extern `indexError : String -> a`**, modelled on `panic`,
reusing the already-declared `@mdk_oob` (native) and existing `wasmTrap` (wasm) → **no new C fn, no
new LLVM preamble decl, no new wasm host-import**:

| Backend | Wiring | File:line |
|---|---|---|
| Declare | `extern indexError : String -> a` | `stdlib/runtime.mdk` (beside `panic` `:57`) |
| Interp | prim `("indexError", prim1 (\s -> runtimePanic "E-INDEX-OOB" (unString s)))` → coded **+located** | `compiler/eval/eval.mdk` prim table (~`:1891`), reuse `runtimePanic` `:1669` |
| Native | add `"indexError"` to `isAbortExtern`; map to `@mdk_oob()` in `emitAbortExtern` (ignores msg → existing `runtime error [E-INDEX-OOB]: index out of bounds`) | `compiler/backend/llvm_emit.mdk:1562-1571` |
| Wasm | `emitLeafExternRef … "indexError" [msg] = wasmTrap "E-INDEX-OOB" "index out of bounds"` (mirror the `"panic"` arm) + add `"indexError"` to the arity-1 leaf-extern catalogs (`:963/:1008`) | `compiler/backend/wasm_emit.mdk:4919` |

Rejected: **(B)** keep `emitArrayIndex` as an inline monomorphic Array fast-path — contradicts F2a,
forces a hybrid built-in/method path, still needs a coded primitive for List/Map/String anyway (perf
tradeoff noted as R1). **(C)** an `Int`-carrying `indexOOB : Int -> a` — Map's key isn't `Int`, so a
`String` message serves all containers with one extern (Map passes `"key not found"`).

---

## 16a — coded-OOB primitive + `Index`/`IndexMut` interfaces + impls  (ADDITIVE; Sonnet)

Purely additive: adds the extern + interfaces + five impls; gated via **explicit `index …` /
`setIndex …` calls** (NOT the sugar — that's 16b/16c). Changes no existing lowering → low risk.

### Interfaces — in `stdlib/core.mdk` (beside `FromEntries` `:888`)
```medaka
export interface Index c k v where
  index : c -> k -> v
export interface IndexMut c k v requires Index c k v where
  setIndex : c -> k -> v -> <Mut> c
```
(F7 `IndexMut requires Index`; F9 `<Mut>`, consistent with `setRef : Ref a -> a -> <Mut> Unit`.)

### Impls (plain `impl`, NEVER `default impl` — §6 caveat). Heads non-overlapping on `c`.
Impls touching internal-only primitives (`arrayGetUnsafe`/`arraySetUnsafe`/`stringToChars`) MUST
live in stdlib (the internal-extern guard rejects them in user code):

| Impl | Home | Body sketch |
|---|---|---|
| `Index (Array a) Int a` | `stdlib/array.mdk` | `index arr i = if i < 0 \|\| i >= arrayLength arr then indexError "index \{intToString i} out of bounds" else arrayGetUnsafe i arr` |
| `IndexMut (Array a) Int a` | `stdlib/array.mdk` | bounds-check then `let _ = arraySetUnsafe i v arr in arr` (in-place, `<Mut>`; F3) |
| `Index (MutArray a) Int a` | `stdlib/mut_array.mdk` | mirror over MutArray rep (`mutArrayGet`/`mutArrayLen`) |
| `IndexMut (MutArray a) Int a` | `stdlib/mut_array.mdk` | mirror, in-place |
| `Index (List a) Int a` | `stdlib/core.mdk` or `stdlib/list.mdk` | `match xs { [] => indexError "index out of bounds"; (h::t) => if i <= 0 then h else index t (i-1) }` — **O(n), DOCUMENT (F4)** |
| `Index String Int Char` | `stdlib/string.mdk` | `let cs = stringToChars s in` bounds-check `else arrayGetUnsafe i cs` (codepoint → `Char`) |
| `Index (Map k v) k v requires Ord k` | `stdlib/map.mdk` | `match Map.get k m { Some v => v; None => indexError "key not found" }` — returns `v` not Option (locked); OOB=key-not-found. **Arg order:** `Map.get k m` (`map.mdk:167`) vs `index m k`. `requires Ord k` on a multi-param Map impl proven by `FromEntries (Map k v) (k,v) requires Ord k` (`map.mdk:474`). |

**No `IndexMut` for List/String/Map** (F3/F5). `Array`/`List`/`String`/`Char` are prelude builtins
→ no new imports; Map impl already lives in `map.mdk`.

### Primitive additions: exactly the seam table (runtime.mdk decl + eval prim + llvm arm + wasm arm).
No `medaka_rt.c` / `llvm_preamble.mdk` change (reuses `@mdk_oob`).

### 16a gates (explicit method calls, run AND build; new `test/` fixtures, diff_compiler style)
- success: `index [|10,20,30|] 1`→`20`; `index [10,20,30] 1`→`20`; `index "hello" 1`→`e`; `index m "k"`→value; `setIndex [|0,0|] 0 9` then read →`9`.
- OOB on **both paths** → nonzero + `E-INDEX-OOB` on stderr: `index [|1,2,3|] 5`; `index [1,2,3] 9`; `index "hi" 9`; `index m "absent"`.
- a fixture proving `indexError` from a user `.mdk` (via impls) yields `E-INDEX-OOB` not `E-PANIC` on all three backends (the P4 regression, fixed).

---

## 16b — desugar flip (F2a) + retire native `EIndex` path  (Opus)

### ⚠️ R0 — the post-order hazard (THE #1 trap). `mapExpr f e = f (mapKids f e)` is **post-order**
(`desugar.mdk:57`). So for `a[i] := v` (= `EBinOp ":=" (EIndex a i _) v _`), the EIndex **LHS child is
rewritten first** — into `index a i` — BEFORE the parent `:=` node is visited, so a single
`rewriteSugar (EBinOp ":=" (EIndex …) …)` arm **never matches**. The INDEX-DESIGN §4 "arm before the
`:=` arm" ordering is INSUFFICIENT.

**Fix — two passes** (`desugar.mdk:815`, currently `|> mapProg rewriteSugar`):
```
|> mapProg rewriteAssignIndex   -- NEW pass 1, runs FIRST (discriminates := LHS while EIndex intact)
|> mapProg rewriteSugar         -- existing pass 2
```
```medaka
rewriteAssignIndex (EBinOp ":=" lhs v _) = matchSetIndex (stripLoc lhs) v lhs
rewriteAssignIndex e = e
--   (EIndex a i _) => EApp (callBin "setIndex" a i) v   -- a[i] := v   (F2)
--   _              => EBinOp ":=" lhs v RNone           -- leave plain := for pass 2 → setRef

rewriteSugar (EIndex a i _)          = callBin "index" a i      -- a[i] → index a i  (NEW)
rewriteSugar (EBinOp ":=" lhs rhs _) = callBin "setRef" lhs rhs -- existing (desugar.mdk:197)
```
`stripLoc`/ELoc-peel is MANDATORY (parser wraps LHS via `located`, `parser.mdk:344`; peel helper
`parser.mdk:467`). Nested `a[j][i] := v` works: pass 1 → `setIndex (a[j]) i v` (inner `EIndex a j`
intact); pass 2 → `index a j`. `a.[i]` produces the same `EIndex` node (`parser.mdk:646`) → one code
path with 16c's `a[i]`.

### What becomes dead (INDEX only — **`ESlice` STAYS, F8**)
typecheck `inferIndex`/`indexKind`/`inferIndexElem`/`indexElemAs`/`infer (EIndex)`
(`typecheck.mdk:3112,3149-3173`); eval `eval (EIndex)`/`evalIndex`/`evalIndexInt`/`listNthAt`/
`stringIndexCp` (`eval.mdk:1029,1081-1085,162`); Core-IR `CIndex`/`CStringIndex`/`CListIndex` +
lower/eval/sexp/rewriteRP; LLVM `emitArrayIndex`/`emitStringIndex`/`emitListIndex` + `CIndex`
dispatch; wasm `emitIndexRef` + its `emitRefExpr` arm.
**Retire in two tiers:** (i) MUST flip desugar + delete the `infer (EIndex)`/`eval (EIndex)` arms so
nodes are provably unreachable; (ii) the `CIndex*` Core-IR + backend emitters MAY be left unreachable
to shrink the diff — **UNLESS `medaka lint`'s dead-code rule flags them** (run lint after the flip;
if flagged, delete in-PR → R6). `inferSlice`/`evalSlice`/`emitArraySlice…`/`CSlice*`/printer slice arm
all STAY.

### DECISIVE 16b gate
Every existing `.[i]` program identical observable behavior run vs build across interp/llvm/build/wasm:
success (`arr.[i]`, `xs.[i]` List, `s.[i]` String print today's values); OOB still nonzero +
`E-INDEX-OOB` both paths. Run the `diff_compiler_*` differential suite (llvm/eval/build/wasm) green +
**fixpoint C3a/C3b** (`desugar.mdk`/`typecheck.mdk`/`eval.mdk` are in the seed graph).

---

## 16c — bare `a[i]` grammar  (Sonnet; escalate to Opus only on parser-backtracking regressions)

### Lexer (F1) — `TLBracketTight`
New token beside `TLBracket` (`lexer.mdk:123`; add `tokenToString`/`describeToken` arms). In
`singleOp … '['` (`:935`) route through a `bracketTok` mirroring `atToken`/`minusTok` (`:966-980`),
keep the `emit … 1 1` depth delta:
```medaka
bracketTok src pos
  | pos > 0 && isExprEnd (at src (pos-1)) = TLBracketTight   -- alnum/'_'/')'/']'/'"'
  | otherwise = TLBracket
```
`a[i]`/`xs[0]`/`f(x)[i]`/`a[i][j]` → tight; `a [i]` (spaced), leading `[1,2,3]`, `x =[1]` → `TLBracket`
= list literal. (`[|…|]` array-literal open is a distinct token, unaffected.)

### Parser — one branch in `postfixTail` (`parser.mdk:618`)
```medaka
postfixTail e = orElse (bracketIndexTail e) (orElse (dotTail e) (pure e))
-- bracketIndexTail: fires only on peeked TLBracketTight, delegates to indexOrSlice e (:634)
```
postfix sits above app in the ladder (`:328`) → `a[i]` binds tighter than an app arg; chaining falls
out of the loop. Spaced `a [i]` stays application-to-list in `parseApp` (`:677`). `a[i, j]` multi-key
OUT (F6) — keep the comma a parse error. `a[i] := v` → `EBinOp ":=" (EIndex …) v _` → 16b's
`rewriteAssignIndex` → `setIndex`. **Bare slice `a[i..j]` DEFERRED (F8, #17)** — gate the tight branch
to reject `..` with a clean "bare slice not yet supported" error (avoid shipping unbounds-checked bare
slice).

### Printer / fmt (`printer.mdk`)
`printExprRaw (EIndex e i _)` (`:674`): `text ".["` → `text "["` (canonical output bare; `.[i]` still
accepted on input). **Leave `ESlice`** as `.[lo..hi]` (`:721`, #17). fmt round-trips via printer →
**recapture printer/fmt goldens** for fixtures containing `.[i]` (now emit `a[i]`).

### 16c gates
parse: `a[i]`, `a[i][j]`, `a[i].field`, `f(x)[i]`, `a[i] := v`; disambiguation pair `a[i]` vs `a [i]`
(different ASTs); `x =[1]` still a list literal. run+build across containers incl. OOB. printer
round-trip `a.[i]`→`a[i]`→same AST.

---

## Risk register + residuals
- **R0** post-order desugar → two-pass required (above). #1 trap.
- **R1** perf: retiring inlined `emitArrayIndex` adds a dict/call per `index`; hot Array indexing
  (`byteparser.mdk` `input.[pos]`) may regress. Acceptable for #16; recover later via monomorphization
  or a specialized fast-path. Flag, don't fix.
- **R2** bootstrap: `byteparser.mdk`/`string.mdk` use `.[i]` → reroute to `index`; impl resolvable
  (base modules); impl bodies use `arrayGetUnsafe`/recursion NOT `.[i]` → no desugar regress. Compiler
  source uses `.[i]` only in string literals. **Re-verify fixpoint C3a/C3b after 16b.**
- **R3** interp OOB loc now points at the `indexError` call in the impl (stdlib loc), not the user
  `a[i]` site — matches pre-existing `Array.set` behavior; code correct. User-located OOB needs
  Core-IR-loc (separate large project). Inherit.
- **R4** wasm List/String: F2a routes through pure-Medaka impls → closes old wasm gap for free. Add a
  wasm build fixture for `[1,2,3][1]` / `"hi"[0]`.
- **R5** Map message: native/wasm drop `indexError`'s message → Map OOB prints generic "index out of
  bounds" not "key not found" (code correct). Cosmetic; out of scope.
- **R6** dead-code lint may flag retired defs → delete in-PR if so.
- **Re-mint (orchestrator, at checkpoint):** `desugar/typecheck/eval/lexer/parser/printer` + backend
  emitters are in the seed graph. `stdlib/*` + `medaka_rt.c` are NOT. Batch 16a's eval+backend arms
  with 16b's in-graph edits into as few re-mints as feasible.

## Model rec: 16a Sonnet · 16b Opus · 16c Sonnet (Opus if parser regressions surface).
