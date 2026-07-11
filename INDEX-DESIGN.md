# INDEX-DESIGN.md — Indexing (`a[i]` / `a[i] := v`) design pass

**Status:** decision-ready design. Read-only pass — no compiler/stdlib source changed.
**Verified on the built binary** (`make medaka`, base `fdd388cd` ✓). Probes cited inline.

---

## TL;DR (read this first)

1. **Most of the mechanism already exists.** `EIndex`/`ESlice` are first-class AST nodes
   (`ast.mdk:176,179`) with surface syntax **`a.[i]`** (dot-bracket) and **`a.[lo..hi]`**.
   They typecheck (`inferIndex`, `typecheck.mdk:3170`), eval (`evalIndexInt`, `eval.mdk:1125`),
   and lower to LLVM + WasmGC. The coded runtime error **`E-INDEX-OOB` already exists in all
   three backends** (`eval.mdk:1127`, `medaka_rt.c:198`, `wasm_emit.mdk:6941`).
2. **But it is a *closed monomorphic union*, not a typeclass.** `inferIndex` hardcodes the key to
   `Int` and the container to exactly `{String→Char, List, Array}` (`typecheck.mdk:3181-3191`);
   `Map` is not indexable. The roadmap's `Index c k v` interface is what makes it *open/extensible*.
3. **Bare `a[i]` does NOT parse today** — it parses as application `a [i]` (apply `a` to the list
   literal `[i]`) and fails typecheck ("… is a value, not a function"). Adding the bare postfix
   `[expr]` grammar is the genuinely new surface work.
4. 🚨 **BLOCKING FORK (empirically confirmed):** the `Index c k v` shape — `index : c -> k -> v`,
   where `v` appears **only in return position** — mis-dispatches on the current binary. It keys
   dispatch on the return-only param instead of the container. **This must be fixed in the
   typechecker before `Index c k v` can work at all.** Details + minimal repro in §1.

---

## 1. The interface(s) — and the 3-param empirical verification (CRITICAL)

### Proposed interfaces

```medaka
-- read
interface Index c k v where
  index : c -> k -> v            -- a[i]  ==>  index a i ;  E-INDEX-OOB on out-of-range

-- write (name: see Fork F7)
interface IndexMut c k v requires Index c k v where
  setIndex : c -> k -> v -> <Mut> c   -- a[i] := v  ==>  setIndex a i v
```

`requires Index c k v` ties the write class to the read class so `setIndex` and `index` agree on
`(c,k,v)`. (Whether `setIndex` returns a fresh `c` or mutates in place — and whether it needs
`<Mut>` — is **Fork F3**.)

### Does this typechecker support a 3-param interface? — VERIFIED

**The representation: YES, fully N-ary.** `DInterface.typarams : List String` (`ast.mdk:323`),
`DImpl.tys : List Ty` (`ast.mdk:331`), `Constraint String (List Ty)` (`ast.mdk:38`). Resolve
never checks param count; coherence (`cohOverlap`, `typecheck.mdk:7194`) and impl-dict routing
(`implDictRoutesForFull`, `typecheck.mdk:7925`) zip lists of *any equal length*. The multi-param
path is gated `listLen paramMonos > 1` (`typecheck.mdk:7956`), **not** `== 2`. The only existing
multi-param interface is `FromEntries c e` (`core.mdk:888`, 2-param, dispatches on `c` in **return**
position; both impls are `default impl` at `map.mdk:474` / `set.mdk:388`).

**The dispatch behaviour: 3 params PARSE, RESOLVE, and TYPECHECK — but the `Index` shape
MIS-DISPATCHES.** This is the load-bearing result of the whole pass.

Probes (all on the built `medaka`):

| Probe | Interface / method | Result |
|---|---|---|
| A | `interface Index c k v` + `impl Index (List a) Int a` + `index xs 1` | ❌ `No impl of Index for Int` |
| B | `interface Lookup c k` · `lk : c -> k -> Int` (return **concrete**) · arg-dispatch on `c` | ✅ works (`105`) |
| C | `interface Tri c k v` · `tri : c -> k -> v -> Int` (all three params in **arg** position) | ✅ works (`5`) |
| D | `interface Get c v` · `get1 : c -> v` (`v` **return-only**) · `get1 (Box 42)` | ❌ `No impl of Get for Int` |
| D′ | Probe D but call site annotated: `(get1 (Box 42) : Int)` | ✅ works (`42`) |

**Conclusion — the trigger is NOT param count.** It is: *a typaram that appears **only in return
position** while the dispatch (head) typaram is in argument position.* That is exactly the
`Index c k v` / `index : c -> k -> v` shape (`v` return-only). Probe C proves 3 params are fine when
all appear in argument position; probe B proves 2-param arg-dispatch is fine; probe D reproduces the
bug with only 2 params. Probe D′ proves the value is *computed correctly* once `v` is grounded — so
the container impl selection itself is fine; the failure is that an **un-grounded return-only param
hijacks the impl-obligation key**.

**Where the bug is (localised, for the implementer):** the *classification* is correct — `Get.get1`
is classified arg-dispatch, not return-dispatch (`returnPosMethod`/`anyArgMentions`,
`typecheck.mdk:6440-6443`: `not (anyArgMentions [c] [c])` = `False`), and `argDispatchOfMethod`
(`typecheck.mdk:1762`) computes `Some 0` for it. So the fault is **downstream, in the
method-occurrence obligation path** — `inferMethodAt` → `recordImplObligation` /
`recordArgStamp` (`typecheck.mdk:3211-3230`): a return-only sibling param leaks into the resolved
obligation args, so `resolveArgStamps`/`noImplFoundMsg` (`typecheck.mdk:9499`) reports the
return-type mono (`[Int]`) as the receiver. The annotation workaround (D′) grounds `v` early and
sidesteps it — but annotating the element type at every `a[i]` is not viable, so **this is a real
blocker, not a papered-over one.** Fix effort ≈ a `harden-typechecker` slice (arg-stamp / obligation
mono selection); no representational change needed.

> This is **Fork F0** (below): fixing the return-only-param dispatch bug is a *precondition* for the
> whole feature. Recommendation: fix it first as its own PR (it also de-risks any future
> multi-param class), then build indexing on top.

---

## 2. The impls

Signatures (assuming F0 fixed; `index`/`setIndex` bodies elided):

| Container | `impl Index …` | `k` | `v` | Notes |
|---|---|---|---|---|
| Array | `impl Index (Array a) Int a` | `Int` | `a` | Element read; `E-INDEX-OOB` on range. Backs today's `arr.[i]`. |
| Map | `impl Index (Map k v) k v requires Ord k` | `k` | `v` | **Design choice:** `m[k]` returns the **value `v`** (OOB → `E-INDEX-OOB` "key not found"), *not* `Option v`. `Map.get` (Option-returning) stays the safe path. |
| List | `impl Index (List a) Int a` | `Int` | `a` | **O(n)** — see Fork F4. Works in the interpreter *today* (`listNthAt`, `eval.mdk:1129`). |
| String | `impl Index String Int Char` | `Int` | `Char` | Codepoint-indexed → **`Char`** (today's `stringIndexCp`, `eval.mdk:1136`). `k`/`v` fixed, no type var. |

`IndexMut` impls: `Array` (in-place, `<Mut>`), `Map` (functional insert → new `Map`), possibly
`MutArray`. `String`/`List` write is a Fork (F5) — likely **read-only** (no `setIndex`), since
immutable-String write and O(n) List write are both footguns.

### Bounds → `E-INDEX-OOB` across the three backends (already mapped)

- **Interpreter** — `runtimePanic "E-INDEX-OOB" msg` (`eval.mdk:1709`) reads `currentEvalLoc` and
  emits a **coded + located** `file:L:C: runtime error [E-INDEX-OOB]: …` (also a `--json` `Diag`).
  Call sites `eval.mdk:1127` (Array), `1136` (String).
- **LLVM** — `emitArrayIndex` (`llvm_emit.mdk:8241`) emits the two `icmp` + `call @mdk_oob()` +
  `unreachable`; `mdk_oob` (`medaka_rt.c:198`) prints `runtime error [E-INDEX-OOB]: index out of
  bounds` (coded, **not** located — Core IR carries no source loc).
- **WasmGC** — `emitIndexRef` (`wasm_emit.mdk:6941`) → `wasmTrap "E-INDEX-OOB" "index out of
  bounds"` (`wasm_emit.mdk:4321`), a unified byte-streaming coded trap.

**Adding a *new* coded error is well-trodden** (docs: `RUNTIME-TRAP-UNIFY-DESIGN.md`,
`RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md`). For indexing, `E-INDEX-OOB` **already exists** — the work
is to make the *generalized* impl paths (esp. Map "key not found", and List/String on the
**native/wasm build path**) route to it. Two pre-existing gaps to inherit or close:
(1) **List indexing is interpreter-only** — the native/wasm build path has never lowered it
(`typecheck.mdk:3179-3180` comment); a `List` impl that must work under `medaka build` needs that
gap closed. (2) **Slice is not bounds-checked in native/wasm** (`E-SLICE-OOB` is interpreter-only) —
out of scope unless slicing is pulled in (Fork F8).

---

## 3. The postfix `[expr]` grammar

### What exists

- Lexer: `[` → `TLBracket` (`lexer.mdk:935`), a bracket opener (depth +1). No "space-before" flag on
  tokens, **but** exact per-token `(start,end)` offsets are threaded through layout
  (`tokOffsetAt`/`tokEndOffsetAt`, `parser.mdk:141-150`), so byte-adjacency is recoverable.
- Parser precedence ladder (`parser.mdk:318`): `… mul → app → postfix → atom`. Postfix binds tighter
  than application, so a postfix chain is a single application head/arg.
- The postfix loop is `postfixTail` (`parser.mdk:609`): `orElse (dotTail e) (pure e)`. `dotTail`
  handles `.field` and — **already** — `.[i]`/`.[lo..hi]` via `dotFor e TLBracket = indexOrSlice e`
  (`parser.mdk:620`), producing `EIndex e lo (Ref "Array")` / `ESlice …` and re-entering
  `postfixTail`, so `a.[i].field`, `a.[i].[j]` etc. already chain.

### The bare `a[i]` production

Add **one branch** to `postfixTail` (`parser.mdk:609`) that consumes `TLBracket expr TRBracket`
directly (no `.`) and builds the same `EIndex`/`ESlice` node. Because postfix < application in the
ladder, this correctly makes `a[i]` bind tighter than an application argument, and chaining
(`a[i][j]`, `a[i].field`, `f(x)[i]`) falls out of the existing loop for free.

### 🚨 The disambiguation fork (F1): `a[i]` vs `a [i]`

`a[i]` (index) and `a [i]` (apply `a` to the one-element list literal `[i]`) are the **same token
stream** `<expr> TLBracket … TRBracket`. `a [i]` is currently *valid and meaningful* (verified:
`arr[1]` today → typecheck error "arr is a value, not a function", i.e. it *did* parse as
application). So the disambiguation must be **whitespace-sensitive**, matching two existing
precedents:

- **Lex-time** (mirrors `minusTok`/`atToken`, `lexer.mdk:966-980`, which already switch `-`→`TMinusTight`
  and `@`→`TAsAt` on adjacency): emit a `TLBracketTight` when `at src (pos-1)` is an
  expression-ending char (ident / `)` / `]` / `"`). The new `postfixTail` branch fires **only** on
  the tight variant; a spaced `[` stays a list literal in `parseApp`. **Recommended** — keeps the
  decision out of the parser's `orElse` backtracking, and is the established pattern.
- **Parse-time** (alternative): the `postfixTail` branch requires `tokOffsetAt <bracket> ==
  tokEndOffsetAt <prev>` (no intervening space), else fall through to application.

**Precedence / chaining** are settled by slotting into `postfixTail` (§3 above). `a[i, j]` (multi-key)
is **Fork F6**.

---

## 4. Desugaring + the `:=` interaction

### Read: `a[i]` → `index a i`

Two strategies (**Fork F2**):

- **(2a) Desugar to a method call** — as the roadmap states literally: add
  `rewriteSugar (EIndex a i _) = callBin "index" a i` in `desugar.mdk` (next to the `:=`→`setRef`
  arm at `desugar.mdk:199`; `callBin` at `desugar.mdk:165`). `a[i]` becomes an ordinary
  `Index`-constrained method call; typecheck/eval/backends need **no** new arms. **Recommended** —
  it's the extensible model the roadmap wants and reuses all method machinery.
  ⚠️ This *retires* the existing native `EIndex` path (`inferIndex`/`evalIndexInt`/`emitArrayIndex`)
  in favour of dispatch — a strategy change, and it inherits the F0 dispatch bug. It also means
  `a.[i]` (dot-bracket) should desugar the same way for consistency.
- **(2b) Keep `EIndex` node, generalize `inferIndex`** — leave `EIndex` first-class but replace the
  hardcoded container union in `inferIndex` (`typecheck.mdk:3189-3192`) with an `Index c k v`
  obligation, and make `evalIndex`/the backends dispatch. More surgery across every stage, but keeps
  the built-in Int-key/Char/Array fast paths as monomorphic specializations of the class.

Either way the F0 dispatch fix is required.

### Write: `a[i] := v` — distinguishing from Ref-write `x := v`

`:=` today: lexer `TColonEq` (`lexer.mdk:903`) → parser `parseAssign`/`assignTail`
(`parser.mdk:328-340`) builds `EBinOp ":=" lhs rhs (Ref RNone)`, right-associative, loosest
precedence → desugar `rewriteSugar (EBinOp ":=" lhs rhs _) = callBin "setRef" lhs rhs`
(`desugar.mdk:199`). There is **no dedicated assign node** (`EBinOp`, `ast.mdk:156`).

So `a[i] := v` **already parses** as `EBinOp ":=" (EIndex a i _) v _` (the LHS is a postfix chain,
which `parseAssign`→`parseLam`→…→`parsePostfix` produces). The desugar branch discriminates purely on
the **LHS shape**, added **before** the generic `:=` arm (match order matters):

```medaka
rewriteSugar (EBinOp ":=" (EIndex a i _) v _)      = EApp (callBin "setIndex" a i) v   -- a[i] := v
rewriteSugar (EBinOp ":=" (ESlice a lo hi _ _) v _) = …                                  -- (if slice-set in scope, F8)
rewriteSugar (EBinOp ":=" lhs rhs _)                = callBin "setRef" lhs rhs           -- existing x := v
```

Clean and local; no parser change needed for the write form beyond the bare-`[` postfix (§3) so
`a[i]` (no dot) reaches the LHS. `a.[i] := v` works with zero parser change.

**Fork F3 (functional-update vs in-place):** does `setIndex` mutate (`Array`/`MutArray`, `<Mut>`,
returns the same container) or return a fresh container (`Map`, immutable)? The interface signature
`setIndex : c -> k -> v -> <Mut> c` covers both, but the *semantics* differ per container and this
should be a conscious decision (see Forks). For `Array` today the natural answer is **in-place +
`<Mut>`** (matches the mutable-Array model); for `Map` it's **functional** (returns a new `Map`, and
`m[k] := v` would need `m` to be rebindable — awkward under immutable `let`, argues for `IndexMut`
being **Array/MutArray-only** initially).

---

## 5. Full touchpoint map

| Stage | File | Change |
|---|---|---|
| Lexer | `frontend/lexer.mdk` | (F1 lex-time) emit `TLBracketTight` when `[` is adjacent to an expr-ending char; else unchanged `TLBracket`. |
| Parser | `frontend/parser.mdk` | One branch in `postfixTail` (`:609`) for bare `[expr]` (fires on tight `[`) building `EIndex`/`ESlice`. No new node. Multi-key `a[i,j]` only if F6=yes. |
| AST | `frontend/ast.mdk` | **None** — `EIndex`/`ESlice` already exist (`:176,179`). (New nodes only if F6 multi-key chosen.) |
| Desugar | `frontend/desugar.mdk` | Add `EIndex → index a i` (F2a) and the `EBinOp ":=" (EIndex …) v → setIndex a i v` arm, before the generic `:=` arm (`:199`). |
| Resolve | `frontend/resolve.mdk` | **None** for syntax; new `interface Index`/`IndexMut` + impls resolve through the existing arity-agnostic path. |
| Typecheck | `types/typecheck.mdk` | 🚨 **F0 dispatch fix** (return-only-param). Then: either retire `inferIndex`'s hardcoded union (F2a) or generalize it to an `Index` obligation (F2b). New interfaces typecheck via existing multi-param machinery. |
| Exhaust | `frontend/exhaust.mdk` | **N/A** — indexing introduces no patterns. |
| Eval | `eval/eval.mdk` | (F2a) `index`/`setIndex` become ordinary dict-dispatched methods; the impl bodies call primitives. Existing `evalIndexInt` (`:1125`) becomes the `Array`/`List`/`String` impl bodies (or is retired). Map read = `Map.get`-then-`E-INDEX-OOB`. |
| LLVM | `backend/llvm_emit.mdk` | (F2a) index is a normal call — no bespoke lowering. Keep/relocate `emitArrayIndex` bounds check (`:8241`) as the Array impl's inlined body if kept monomorphic. **Close the List-index native gap** if a List impl must `build`. |
| WasmGC | `backend/wasm_emit.mdk` | Same as LLVM: `emitIndexRef` (`:6941`) becomes the Array impl body or a normal call. Same List-build gap. |
| Printer / fmt | `tools/printer.mdk`, `tools/fmt.mdk` | Render `EIndex`/`ESlice` as bare `a[i]` (currently they'd print `a.[i]`). Round-trip both spellings; pick one canonical form (recommend bare `a[i]`, keep `.[i]` accepted). |
| Lint / LSP | `tools/lint.mdk`, `tools/lsp.mdk` | LSP: hover/completion over `index`/`setIndex` fall out of method support. Optional lint: suggest `a[i]` over `Array.get`+unwrap. No mandatory change. |
| Docs / tests | `SYNTAX.md`, `test/parse_fixtures/*`, `test/diff_compiler_*` | New parse + eval + build fixtures for `a[i]` / `a[i] := v` across Array/Map/List/String; golden capture. |

---

## 6. Interaction with named/default-impl removal (#15)

The design assumes the **post-removal model: plain impls + most-specific-wins**, and relies on
**nothing** from `default`/named selection. Two concrete points:

- The `Index`/`IndexMut` impls (Array/Map/List/String) are **non-overlapping on the head type `c`**
  (`Array a` / `Map k v` / `List a` / `String`), so most-specific-wins resolves each unambiguously —
  no `default` needed.
- ⚠️ **Caveat to flag:** the *only existing* multi-param interface, `FromEntries`, is written as
  `default impl` (`map.mdk:474`, `set.mdk:388`). That is the closest precedent, and it will itself be
  touched by #15. The new `Index` impls should be **plain `impl`** from day one. Confirm #15 lands (or
  is compatible) before/with this so we don't add fresh `default impl`s that #15 must then unwind.

---

## 7. DESIGN FORKS — for Val's decision

Each fork lists options and my recommendation.

- **F0 — Fix the return-only-param dispatch bug (PRECONDITION, not optional).**
  `Index c k v` cannot dispatch on the current binary (§1, probes A/D). Options: (a) fix it in the
  typechecker's arg-stamp/obligation path first, as its own PR; (b) restructure the interface to
  avoid a return-only param (see F7-alt). **Recommend (a)** — the interface shape is forced by the
  semantics (`index` *must* return the element, so `v` is return-only), and fixing the dispatcher
  de-risks every future multi-param class. Estimate: a `harden-typechecker` slice.

- **F1 — Whitespace-sensitivity of `[`.** (a) lex-time `TLBracketTight` on adjacency; (b) parse-time
  offset check; (c) no space-sensitivity (breaks `a [listArg]`). **Recommend (a)** — matches the
  `-`/`@` precedents (`lexer.mdk:966-980`), keeps it out of parser backtracking. `a[i]` = index,
  `a [i]` = application-to-list stays meaningful.

- **F2 — Read lowering: desugar-to-`index` vs generalize-`EIndex`.** (2a) `desugar EIndex → index a i`
  (roadmap's literal spec, reuses all method machinery, retires the native `EIndex` path); (2b) keep
  `EIndex` node, replace `inferIndex`'s hardcoded union with an `Index` obligation (keeps monomorphic
  fast paths, more surgery). **Recommend 2a** for extensibility; both need F0.

- **F3 — Functional-update vs in-place write (per container).** (a) `IndexMut` is **in-place +
  `<Mut>`**, offered only for `Array`/`MutArray`; `Map` write is functional and *not* via `[]:=`;
  (b) `setIndex` returns a fresh `c` for all (immutable everywhere); (c) both, per-container.
  **Recommend (a)** — `a[i] := v` reads as mutation; immutable containers keep their existing
  functional `insert`/`set`. Revisit if a functional `m[k] := v` (rebind) is wanted.

- **F4 — Include a `List` impl (O(n))?** List `a[i]` is O(n) and a well-known footgun. (a) omit it;
  (b) include it. **Recommend (b) include** but document the O(n) cost — it *already works in the
  interpreter* (`listNthAt`), the surface is expected by users, and omitting it is a surprising gap.
  Rider: closing the **native/wasm List-index build gap** (`typecheck.mdk:3179`) is required for it to
  work under `medaka build`.

- **F5 — String write & List write.** (a) read-only (no `IndexMut String`/`List`); (b) provide them.
  **Recommend (a)** — immutable-String element write is semantically odd and O(n) List write is a
  footgun; keep writes to `Array`/`MutArray`.

- **F6 — Multi-key `a[i, j]`.** (a) out of scope (2-D via chaining `a[i][j]` only); (b) support
  `a[i,j]` as sugar (needs a new AST arg-list node + parser + a variadic `index`). **Recommend (a)** —
  chaining `a[i][j]` covers nested containers with zero new machinery; revisit if a true 2-D array
  type lands.

- **F7 — Interface names.** Read: **`Index`** (settled). Write sibling: `IndexMut` vs `SetIndex`.
  **Recommend `IndexMut`** — pairs with `Index`, signals mutation, familiar (Rust). *Alt worth
  noting:* a single 2-param class carrying both methods would still have `v` return-only in `index`,
  so it does **not** dodge F0.

- **F8 — Slicing `a[i..j]` in the bare grammar.** `a.[lo..hi]`/`a.[lo..=hi]` (`ESlice`) already exist
  dot-form. (a) also accept bare `a[i..j]`; (b) leave slicing dot-only for now. **Recommend (a)** for
  surface consistency (the `postfixTail` branch handles both), but note native/wasm slice is **not
  bounds-checked** today (`E-SLICE-OOB` interpreter-only) — closing that is a rider if bare slice
  ships.

- **F9 — Does `IndexMut` need `<Mut>`?** If F3=in-place, **yes** — `setIndex : c -> k -> v -> <Mut> c`
  carries the effect, consistent with `setRef : Ref a -> a -> <Mut> Unit` (`runtime.mdk:16`). If
  F3=functional, no effect needed. **Recommend `<Mut>`** (tracks the in-place write honestly).

---

## 8. Adjacent interface-generalization batch — shared machinery? (one paragraph, not designed here)

The batch `++`→`Semigroup`, ranges→`Enum`, unary `-`→`Num.negate` is **largely independent** of
indexing: those replace *built-in operators* with dispatch to **single-param** interfaces
(`Semigroup a`, `Enum a`, `Num a`) — none hits the multi-param/return-only-param dispatch bug (F0)
that dominates this design, and none needs the whitespace-sensitive `[` grammar. The **one shared
seam** is the desugar pattern: like `a[i] → index a i`, they lower a surface operator to a
constrained method call in `desugar.mdk` (`++`→`append`/`<>`, `[lo..hi]`→`enumFromTo`, `-x`→`negate`)
— so they exercise the same "desugar-to-method + typeclass obligation" plumbing, and a `Num`-style
dispatch fix would share code review with F0 only insofar as both are typeclass-dispatch. Verdict:
sequence F0 first (it unblocks any multi-param class), then indexing and the operator batch can
proceed in parallel; do **not** couple them.

---

## Appendix — key file:line references (verified)

- Interfaces/AST: `ast.mdk:323` (`DInterface.typarams`), `:331` (`DImpl.tys`), `:38` (`Constraint`),
  `:156` (`EBinOp`), `:176`/`:179` (`ESlice`/`EIndex`).
- Multi-param precedent: `core.mdk:888` (`FromEntries c e`), `map.mdk:474` / `set.mdk:388`
  (`default impl`).
- Dispatch machinery: `typecheck.mdk:1762` (`argDispatchOfMethod`), `:1774` (`dispatchTyparams`),
  `:6440` (`returnPosMethod`), `:3211-3230` (`inferMethodAt` obligation path), `:9499`
  (`noImplFoundMsg`).
- Existing index: `typecheck.mdk:3170` (`inferIndex`), `:3181` (`indexKind`), `:3189`
  (`inferIndexElem`); `eval.mdk:1121-1160` (`evalIndex`/`evalIndexInt`/`stringIndexCp`/`evalSlice`);
  `parser.mdk:609` (`postfixTail`), `:620` (`dotFor … TLBracket`), `:625` (`indexOrSlice`).
- `E-INDEX-OOB`: `eval.mdk:1127`/`1709` (`runtimePanic`), `medaka_rt.c:198` (`mdk_oob`),
  `wasm_emit.mdk:6941`/`4321` (`emitIndexRef`/`wasmTrap`).
- `:=`: `lexer.mdk:903` (`TColonEq`), `parser.mdk:328-340` (`parseAssign`), `desugar.mdk:199`
  (`→ setRef`); `runtime.mdk:15-16` (`Ref`/`setRef`), `eval.mdk:1064`/`1221` (`.value` read).
