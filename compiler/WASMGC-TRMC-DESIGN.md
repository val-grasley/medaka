# WASMGC-TRMC-DESIGN.md — scoping the general fix for the WasmGC runtime stack overflow (layer-5)

**Status:** IMPLEMENTED — Stages 0–2 COMPLETE, layer-5 CLOSED (2026-06-22); TMC-parity
with the LLVM backend shipped 2026-07-13. This is the model example in this doc family of
self-documenting a header/body lag (see its own note below) — used as the template for
fixing the same pattern elsewhere in this doc set.

> **Status: IMPLEMENTED — Stages 0–2 COMPLETE, layer-5 CLOSED (2026-06-22).** See §11 "AS BUILT" for the implementation log. This doc was originally a design/scoping pass; the implementation was added in §11 without updating this header. No source edited in the initial design pass.
>
> **TMC-parity update (2026-07-13):** the Stage-3 dispatch-graph DETECTION was
> lifted out of `wasm_emit.mdk` into the shared `backend/trmc_analysis.mdk`
> (hook-parameterized `detectDispatchGroups`), and the **LLVM backend now emits
> (b′) groups too** (single-define inlining — `TRMC-DESIGN.md` §Phase 3), so both
> backends TMC the SAME functions by construction.  The wasm-only
> `wTrmcUniformCtor` gate was retired (mixed leaf-ctor sets emit via a
> `$__tmc_dctor` link dispatch; singleton sets byte-identical to before), which
> also made the v5 stage-1-claims predicate backend-identical.  Both emitters
> write `;; tmc:` / `; tmc:` census markers; `test/diff_compiler_tmc_parity.sh`
> gates the per-function TMC sets equal.
> Companion to `TRMC-DESIGN.md` (the LLVM-backend TRMC), `WASM-SELFHOST-ROADMAP.md`
> (the layer log — this is **layer-5**), `WASMGC-DESIGN.md` (value rep). The next agent
> implements; this doc only scopes the fix and surfaces the human-decision forks.

## 0. The problem, restated precisely

Running the self-hosted front-end (`compiler/entries/check_main.mdk`) on the full
`core.mdk` prelude, compiled to WasmGC and run under Node, throws
**`RangeError: Maximum call stack size exceeded`** in the lexer's token-list build
(`scan → scanAt → scanLower/emit/…`; also `support_char__isLower` on `core.mdk`).
This is **genuine stack growth from tail-recursion-modulo-cons** (the spine of the
token list stays live to EOF), not a mis-lowered construct (the lexer is otherwise
byte-correct — layer-4 closed the last miscompile). Native never hits it because the
C stack is far deeper than V8's; **a browser cannot raise V8's stack limit** (no
`--stack-size`), so the only real fix is a **codegen transform that makes the spine
iterative**.

The decisive question this pass answers: **does porting the LLVM backend's existing
TRMC (`TRMC-DESIGN.md`) fix it?** The answer hinges on the lexer's exact recursion
shape — Q1 below.

---

## 1. Q1 — the EXACT recursion shape of the lexer overflow (the make-or-break answer)

**Verdict: tail-recursion-modulo-cons where the cons sits in a DISPATCH CALLEE, and
the self-call target is a SINGLE fixed function (`scan`) — NOT classic self-recursion
(TRMC Phase-1/2's shape), and NOT mutual-recursion-into-many-targets (which TRMC
excludes). It is a *third* shape the existing TRMC does not handle as-is.**

### 1.1 The actual clause bodies (`compiler/frontend/lexer.mdk`)

`scan` is a pure dispatcher — it never builds a cons itself; it tail-calls `scanAt`:

```
-- lexer.mdk:336-339
scan src len pos depth id
  | pos >= len = []
  | otherwise = scanAt src len pos depth id (at src pos)
```

`scanAt` classifies the current char and fans out to a per-kind scanner — again, no
cons of its own, just a dispatch tail-call:

```
-- lexer.mdk:341-358
scanAt src len pos depth id c
  | isSpace c = scan src len (pos + 1) depth id
  | isNL c || isCR c = handleNewline src len pos depth id
  | ... isDigit c = scanNumber src len pos depth id
  | isLower c || c == '_' = scanLower src len pos depth id
  | isUpper c = scanUpper src len pos depth id
  | ... | otherwise = scanOp src len pos depth id c
```

The **cons that builds the spine lives in the per-kind leaf scanners**, and in EVERY
one of them the tail is `:: scan src len <newpos> …` — the recursive edge always
targets the single function `scan`:

```
-- lexer.mdk:382-385  scanLower
scanLower src len pos depth id =
  let e = identEnd src len (pos + 1)
  RTok (identToken src pos e) pos e :: scan src len e depth id

-- lexer.mdk:721-723  emit  (the operator/punctuation leaf, reached scanOp→singleOp→emit)
emit src len pos depth id tok length ddelta =
  RTok tok pos (pos + length) :: scan src len (pos + length) (depth + ddelta) id

-- lexer.mdk:471  numFinish (int leaf)
  | otherwise = RTok (TInt (parseIntFrom src pos e1 0)) pos e1 :: scan src len e1 depth id

-- lexer.mdk:485  scanStr (string char leaf)
  | otherwise = scanStr src len (p + 1) depth id (acc ++ charToStr (at src p))
  -- ^ NOTE scanStr/scanTriple/scanInterpCont are SELF-recursive accumulator loops
  --   (shape (c)) bounded by ONE literal's length; the SPINE cons is at lexer.mdk:482
  --   `RTok (TString acc) … :: scan …` — again targeting `scan`.
```

`identEnd`/`digitsEnd`/`charClose`/`btClose`/`skipLineComment`/`skipBlockComment` are
**self-recursive tail loops that return an Int** (a scan position) — they do NOT build
the spine and are NOT the overflow (pure tail recursion; WasmGC `return_call` already
makes them O(1) — see §1.3). The overflow is the **token spine** only.

The `support_char__isLower` mention in the error is incidental: it's the leaf predicate
`scanAt` calls per char; it appears in the stack trace because it's the deepest frame
at the moment V8 trips, not because it recurses.

### 1.2 Classification against TRMC's taxonomy

| Shape | Definition | TRMC Phase-1/2 covers? | Is this the lexer? |
|---|---|---|---|
| (a) self-recursive TMC | `f … = x :: f rest` — cons-tail call to `f` itself, *within `f`* | **YES** (`TRMC-DESIGN.md` Phase 1) | **No** — the cons is in `scanLower`/`emit`/…, whose tail calls `scan`, not themselves |
| (b) mutual recursion into a SET | `f`'s tail is `x :: g …`, `g`'s tail is `… :: h …`, … cycling back, several distinct cons-bearers | **NO** ("mutual recursion — out of scope") | **No** — there is only ONE cons-bearing edge target, `scan` |
| (b′) **dispatch-into-single-target TMC** | a fixed dispatcher `scan`; each per-token leaf does `x :: scan rest`; the live frame is the *leaf*, the self-call target is the single `scan` | not contemplated by `TRMC-DESIGN.md` | **YES — this is the lexer** |
| (c) accumulator / non-cons tail | `f acc rest = f (g acc) rest` | n/a (already O(1) via `return_call`) | only the *intra-literal* loops (`scanStr`, `identEnd`) |

The lexer is shape **(b′)**. It is *structurally* mutual recursion (`scan`↔`scanAt`↔
leaf), so the LLVM TRMC's `mentionsSelfMethod`/`refersTo self` self-detection — which
keys on a SINGLE self function — does not fire across the call boundary. **But it is
far more tractable than general (b)**: the recursion is a star, not a cycle of peers —
every spine cons calls back into the one function `scan`. That single-target property
is what makes a fix feasible (§2).

### 1.3 Why `return_call` (already emitted) does NOT save it

`emitRefTail` (`wasm_emit.mdk:3493`) already emits `return_call`/`return_call_ref` at
syntactic tail positions, and `scan`/`scanAt`'s **dispatch** tail-calls (`= scanAt …`,
`= scanLower …`) DO become `return_call` — so the dispatch fan-out is already O(1).
The problem is the **cons**: `RTok t … :: scan …`. In `emitRefTail` a tail-position
`CBinPrim "::"` has **no dedicated arm** — it falls through to
`other => emitRefExpr prog env 0 other ++ ["return"]` (`wasm_emit.mdk:3511`). So the
cons is emitted as an ordinary value: `scan …` is evaluated **as an argument to
`struct.new $C_Cons`**, which is NOT a tail position — the `scanLower` frame stays
live holding the half-built cell. That live frame, once per token, is the overflow.
This is exactly the LLVM `f (x::xs) = g x :: f xs` problem (`TRMC-DESIGN.md` §Problem),
only the live frame is a callee of the dispatcher rather than `scan` itself.

---

## 2. Q2 — options, given it is shape (b′)

Porting the LLVM TRMC **verbatim does not fix it** (its self-detection is single-function
and the cons-bearer is a *different* function from the recursion target). Three options:

### Option (i) — extend TRMC to "dispatch-into-single-target" (b′)  ⭐ RECOMMENDED

**Insight:** (b′) reduces to self-recursive TMC after a *single* mechanical
transformation — **inline the dispatcher**. The family `{scan, scanAt, scanLower,
scanUpper, scanOp, singleOp, emit, numFinish, scanNumber, scanStr-spine, …}` is a set
of functions whose only inter-function tail edges form a *tree rooted at `scan`*, and
whose only cons-tail edges all call `scan`. Treat the whole family as **one logical
loop with `scan`'s parameters as the loop state**: a cons leaf does
`struct.set` the new cell into the parent's tail field, recompute `(pos,depth,id)`,
`br` back to the `scan` loop head — never returning up the dispatch tree.

Concretely this is a WasmGC **destination-passing loop keyed on a *group* of mutually
tail-calling functions that all bottom out in cons-`scan`**, rather than on one
self-recursive function. The eligibility analysis generalizes from "self-call to `f`"
to "tail-call that (transitively, through self-free dispatch-only callees) reaches a
cons-`scan` or a `scan` tail-call." This is bigger than the LLVM Phase-1 self-only
analysis but **much smaller than general mutual recursion** because the target is
single and the dispatchers (`scan`/`scanAt`/`singleOp`) are cons-free pure routers.

- **Effort:** MEDIUM. New analysis: identify a "TMC group" = a strongly-tail-connected
  set with one cons target. New emit: a `scan`-rooted loop whose body is the inlined
  dispatch tree, each leaf either (cons → `struct.set` child + recompute state + `br`)
  or (base `[]` → store Nil + `br exit`). Reuses the LLVM destination-passing *technique*
  (§3) but the *grouping* is new.
- **Risk:** MEDIUM. The route-fragile part is proving the dispatch callees are cons-free
  and tail-only (so inlining them into the loop is sound). The accumulator sub-loops
  (`scanStr`, `identEnd`) must be left as ordinary `return_call` loops (they return a
  value/position, not a spine) — the analysis must NOT fold them into the group.
- **Where it lands:** `wasm_emit.mdk` only (emitter-only, OUT of the self-host graph →
  no fixpoint, no seed re-mint, no canonical-source edit). **This is the decisive
  advantage** over Option (ii).

### Option (ii) — restructure `frontend/lexer.mdk` to accumulator form

Rewrite `scan` to thread an explicit accumulator and emit tokens with an O(1)-stack
loop (e.g. `scan … acc = scanAt … (tok : acc)` then `reverse` at EOF, or a difference
list). This makes the recursion shape (c), which `return_call` already handles.

- **Effort:** MEDIUM (touches ~30 leaf scanners — every `:: scan …` site).
- **Risk:** HIGH on the *process* axis, not the code axis:
  - `frontend/lexer.mdk` is **IN-GRAPH** (`all_modules_entry.mdk:9` imports it; the
    native `medaka` front-end uses it). So a change here **must survive fixpoint
    (C3a/C3b) + force a seed re-mint** and affects the **native build**.
  - It must stay **byte-identical token output**: the lexer gates
    (`test/bootstrap_lex.sh`, `diff_compiler_lexer.sh`) compare against **frozen
    goldens** captured while OCaml was trusted — a `reverse`-at-EOF or difference-list
    rewrite must reproduce them exactly (a subtle reordering/`reverse` bug here breaks
    every downstream parse/typecheck gate). `lib/lexer.ml` does **not** need a lockstep
    edit (the gate is golden-based, not a live `lib/` diff — see Q-note §6), but the
    goldens are the contract.
  - It "fixes" only the lexer; the same shape recurs in other passes (Q4) and each
    would need its own canonical rewrite. **Net: edits canonical code + re-mints seed
    to fix a backend-only runtime limit — the wrong layer.**

### Option (iii) — WasmGC-side non-TRMC stack mitigation

E.g. trampoline the token build, or a CPS/explicit-stack-on-heap transform in the
emitter. **Rejected as primary:** strictly more emitter machinery than (i), with worse
constant factors, and (i) already keeps the fix emitter-only. Keep as a fallback only
if (i)'s grouping analysis balloons.

### Recommendation

**Option (i)** — extend the (already-portable, see Q5) TRMC analysis to the
dispatch-into-single-target group and build a WasmGC destination-passing loop emit. It
is the principled general fix (it generalizes the existing mechanism rather than
special-casing the lexer), it is **emitter-only** (no fixpoint/seed/canonical-source
cost — the entire reason the WasmGC workstream has moved fast), and it directly
addresses the *class* (Q4) not just the lexer. Hold Option (ii) as the escape hatch if
the grouping analysis proves intractable for a specific pass.

---

## 3. Q3 — WasmGC value-rep constraint: are the cons / ADT recursive fields `mut`?

**Finding: NO — they are currently IMMUTABLE. TRMC destination-passing REQUIRES them
`mut`. This is a required, low-blast-radius change.**

The cons cell and per-ctor structs are declared without `mut` on their fields:

```
-- wasm_emit.mdk:1629-1630  (the List rep)
"    (type $T_List (sub (struct (field i32))))",
"    (type $C_Cons (sub $T_List (struct (field i32) (field (ref eq)) (field (ref eq)))))"
--                                        ^tag        ^head (immutable)  ^tail (immutable)

-- wasm_emit.mdk:1642-1643, 1657-1668, 1683-1695  (synthetic + per-datatype ctor structs)
"    (type $" ++ cs ++ " (sub $" ++ root ++ " (struct (field i32)" ++ fields ++ ")))"
--   `fields` are emitted as plain `(field (ref eq))`, no mut
```

(`wasm_preamble.mdk` confirms the same: every `$C_Cons` use is `struct.get`/`struct.new`,
never `struct.set`; only `$refbox` (`field (mut (ref eq))`) and `$arr`
(`array (mut (ref eq))`) and `$str.$bytes` are mutable today.)

**What TRMC needs:** destination-passing writes the child cell into the *parent's tail
field AFTER the parent is created* (`struct.set $C_Cons 2 parent child`). That requires
the tail field (and, for general Axis-A ctors, the recursive field) to be `(mut (ref eq))`.

**Blast radius of making `$C_Cons` tail (field 2) `mut`:**
- **Small and well-precedented.** `$refbox`/`$arr` are already mutable; making one more
  field mutable is a one-line type-section change (and the per-ctor `emitCtorStruct`
  needs the recursive field emitted as `(field (mut (ref eq)))` — index-targeted, since
  only the TRMC-destination field needs it).
- **Nothing depends on immutability.** Medaka lists are functional, but the WasmGC
  encoding never relied on field immutability for correctness — equality/hash/match all
  use `struct.get`. WasmGC subtyping: a `mut` field is *invariant* (an immutable field is
  covariant), so widening `$C_Cons.tail` to `mut` could in principle break a place that
  relied on covariant subtyping of `$C_Cons` — **but `$C_Cons`'s tail is `(ref eq)`, the
  top type, so there is no covariant-narrowing site to break.** Verdict: safe.
- **Gate impact:** none expected on `diff_wasm*` (output unchanged — `mut` only *permits*
  `struct.set`; existing code keeps using `struct.new`/`struct.get`). `wasm-tools validate`
  must still pass (the assemble/validate gate). **Recommendation: declare the cons tail
  field (and the general TRMC-destination ctor field) `mut` from the start of the work**,
  exactly as `TRMC-DESIGN.md` §"Backend portability" instructs ("Bake it into the
  cons/ADT struct types from the start").

---

## 4. Q4 — breadth: is layer-5 one site or many? (census result)

The lexer is **not** a one-off, **but the breadth splits into two distinct sub-classes
with different fixes** — a key finding (census over `parser.mdk`/`resolve.mdk`/
`typecheck.mdk`/`exhaust.mdk`/`support/*`):

### 4.1 Class A — list-spine recursion (O(input)-LONG, TRMC-fixable)

Self-recursive or dispatch tail-modulo-cons over lists whose **length is O(program
size)**. These overflow on large input and are exactly what Stages 1–2 fix:

| Pass | Site (`file:line`) | Shape | Depth |
|---|---|---|---|
| Lexer | token spine — `scanLower`/`emit`/`numFinish`/… `:: scan …` (lexer.mdk:385/471/485/723) | **(b′)** dispatch-into-`scan` | O(#tokens) — **overflows now** |
| Parser | `manyGo` (parser.mdk:222) `chainl1Rest` (272) `choice` (215) postfix/dot chains (559) | **(a)** self-TMC (monadic, accumulator+reverse) | O(#tokens) |
| Resolve | `singleFileImportErrors` (resolve.mdk:990), `filterContains` (1031), `ownersOf` (130) | **(a)** self-TMC | O(#decls / #names) |
| Typecheck | `processSCCs` (typecheck.mdk:7838), `checkImplObligationsGo` (7173), `checkCallObligationsGo` (7027), `namesToSet` (7686) | **(a)** self-TMC (some over OrdMap, O(log n) inserts) | O(#decls / #obligations) |
| Exhaust | `parseDigitsGo` (exhaust.mdk:92) | **(a)** self-TMC | O(#digits) — bounded, no risk |
| Support | `reverseGo`/`contains`/`listLen`/`dedupGo`/`intersperseStr` (util.mdk:28/12/17/82/63), `omInsert`/`omLookup` (ordmap.mdk:76/84) | **(a)** self-TMC; OrdMap O(log n) tree | O(list len) / O(log n) |

**Verdict A:** parser, resolve-list, typecheck-obligation, exhaust, and support
recursions are **self-recursive (Stage-1 self-TMC covers them)**; the lexer is the lone
**(b′) dispatch case (Stage-2)**. The general analysis (Option (i)) covers both in one
mechanism. The lexer is just the FIRST O(input)-long spine to overflow (#tokens > #decls,
so it trips V8 first); the parser/typecheck list spines are the next to surface on a
large program and the same fix retires them.

### 4.2 Class B — AST TREE recursion (O(nesting-DEPTH), NOT TRMC-fixable)

A separate, **non-cons-tail tree-walk** class that **no form of TRMC addresses** (the
recursion is `walk f ++ walk x` — two child calls per node, not a cons-tail):

| Pass | Site | Shape | Depth |
|---|---|---|---|
| Resolve | `checkExpr` (resolve.mdk:237–305), `checkPat` (191), `patBindings` (137) | **(d)** tree walk, non-tail | O(expr/pattern **nesting depth**) |
| Typecheck | `infer` (the HM core), `allEVars` (typecheck.mdk:7596), `buildAdj`/`depsOf` (7681) | **(d)** tree walk, non-tail (multiple recursive calls per arm) | O(expr **nesting depth**) — **deepest tree risk** |

**Verdict B:** these are bounded by **AST nesting depth, not input length** — a real
program nests O(10–30) deep, so the **near-term overflow risk is LOW** (the lexer/Class-A
spines, O(#tokens), trip V8 long before a 30-deep `infer` does). But a pathologically
nested input (`a (b (c (d …)))` ×100s, deeply chained `let … let …`) WOULD overflow
`infer`/`checkExpr`, and **TRMC cannot help** — the fix there is a *different* transform
(accumulate errors via a Ref/callback in `checkExpr`; trampoline / explicit-heap-stack
`infer`, or cap desugar nesting depth). **This is out of scope for the layer-5 TRMC work**
and should be tracked as a separate, lower-priority item (a post-self-host hardening
concern), NOT mixed into the TRMC staging.

### 4.3 Consequence for the plan

- **Layer-5 + its class (Class A) IS the TRMC work** — fix the lexer (b′) now, and the
  same mechanism retires the parser/typecheck list spines as they surface. Stage by pass
  (lexer first — current blocker, cleanest (b′)).
- **Class B (tree walks) is a separate workstream** — flag it, do NOT let it bound or
  block the TRMC fix. It will not overflow on realistic input until well after the
  Class-A spines are fixed, and it needs a non-TRMC remedy.

---

## 5. Q5 — is the existing TRMC analysis liftable/backend-agnostic?

**Finding: YES for the analysis; the EMIT is LLVM-specific (as designed).** This is
explicitly stated in `TRMC-DESIGN.md` §"Backend portability" and confirmed by the
function inventory:

- **Backend-agnostic (liftable):** `trmcEligible`, `isConsTail`/`isCtorTail`,
  `ctorTailFieldsOk`, `allSelfFreeF`, the `SelfRef = SelfByVar | SelfByMethod` self-walk
  + `mentionsSelfMethod`, the match-arm tail descent (`trmcBodyOk`/`trmcArmsOk`). These
  are **pure structural analysis over `CExpr`/`CApp`/`CBinPrim`/`CMethod`** — no LLVM
  dependency. `TRMC-DESIGN.md` §"Reusable" says exactly this and notes the lift is "a
  mechanical move; not worth factoring now with no second consumer." **WasmGC is now
  that second consumer** → lift them into a shared module (landed as
  `compiler/backend/trmc_analysis.mdk`) consumed by both `llvm_emit.mdk` and
  `wasm_emit.mdk`. Caveat: a couple of helpers thread an `Emit`-typed handle for
  `isCtor`/`ctorArity` (ctor-arity lookup) — that lookup is itself backend-neutral
  (`Prog`/ctor tables), so the lift parameterizes it rather than coupling to LLVM.
- **Backend-specific (rebuild for WasmGC):** `emitTrmcCtor`/`emitTrmcFn`/
  `emitTrmcLoopBody` — `alloca` dest pointer, `@mdk_alloc`, `getelementptr`, raw `store`.
  WasmGC peer: hold the parent cell `(ref $C_Cons)` in a local, `struct.set` the child
  into the parent's (now-`mut`) tail field, loop with `parent := child`, `br` to the
  loop head. **Same algorithm**, ~the size of `emitTrmcCtor`, no `return_call` involved
  inside the loop (the loop is a `br`-based local loop, not a tail call).

**For (b′) specifically (the lexer):** the *self-only* analysis is liftable as-is but
must be **generalized** to the dispatch-group (Option (i)) — the lift is the prerequisite
and the platform for that generalization; do the lift first (it also benefits LLVM:
the LLVM backend has the same (b′) blind spot, it just never overflows the deep C stack).

---

## 6. Q-note — does `lib/` parity matter for any source change here?

Only relevant if Option (ii) (lexer source restructure) is chosen. **`lib/lexer.ml`
does NOT need a lockstep edit:** the compiler lexer gates (`bootstrap_lex.sh`,
`diff_compiler_lexer.sh`) diff against **committed goldens** captured while OCaml was
trusted (now-frozen, OCaml-free) — not a live `lib/lexer.ml` diff. The contract a
lexer-source change must honor is **byte-identical token output to the goldens**, plus
**fixpoint C3a/C3b + seed re-mint** (it's in-graph). Option (i) (emitter-only) avoids
all of this — no `lib/`, no goldens-as-risk, no fixpoint, no seed.

---

## 7. Recommended staged plan (ascending risk, each independently gateable)

Mirrors `TRMC-DESIGN.md`'s Phase-1 → Phase-2-A → B-dispatch → B-match staging.

**Stage 0 — make the destination field `mut` + lift the analysis (prep, no behavior change).**
- Declare `$C_Cons` tail (field 2) and the general TRMC-destination ctor field
  `(field (mut (ref eq)))` in `wasm_emit.mdk`'s type section (`recGroupLines` /
  `emitCtorStruct`). Gate: `assemble_check_main.sh` still VALIDATE_OK; `diff_wasm*`
  unchanged (output identical).
- Lift `trmcEligible`/`isCtorTail`/`SelfRef`/`mentionsSelfMethod`/match-descent out of
  `llvm_emit.mdk` into a shared module; re-point LLVM at it. Gate: full
  `diff_compiler_*` + `selfcompile_fixpoint` C3a/C3b YES (LLVM behavior byte-identical —
  pure code move). **This is the only in-graph touch if it relocates a module the
  compiler graph imports — confirm the shared module is imported only by the emitters,
  or accept a fixpoint+seed pass for the move.**

**Stage 1 — WasmGC self-recursive TMC (Axis-A peer).** Build `emitWasmTrmcCtor` +
wire it into the WasmGC fn-emit path for the *self-only* shape (a). Add a tail-position
`CBinPrim "::"` / single-ctor-last-field arm to `emitRefTail`. Gate: a new
`test/wasm/*` deep-list stack fixture (a hand-rolled `myMap`/`upto` over 2M, run under
Node) — **RangeError before, prints the length after**. This fixes the (a)-shaped
typecheck/resolve decl-walk spines (Q4) for free.

**Stage 2 — WasmGC dispatch-into-single-target TMC (the lexer, shape (b′)) ⭐ the layer-5 fix.**
Generalize the lifted analysis to identify a "TMC group" (a tail-connected set rooted
at one cons-target like `scan`, with cons-free dispatch routers), and emit a single
`scan`-rooted destination-passing loop with the dispatch tree inlined as the loop body.
Leave intra-literal accumulator loops (`scanStr`, `identEnd`) as ordinary loops. Gate:
**`check_main` runs to completion under Node on the full `core.mdk` prelude** (the
layer-5 close) + a synthetic dispatch-TMC fixture.

**Stage 3 — sweep the remaining passes.** Apply Stages 1–2's mechanism to the parser /
exhaust spine sites the Q4 census flags as still-overflowing; one gateable fixture per
pass. Endpoint: the whole self-host front-end runs to completion under Node — the
"self-host-of-the-front-end demo" (`WASM-SELFHOST-ROADMAP.md` layer-12+).

---

## 8. Design forks — need a human decision

| # | Fork | Recommendation | Tradeoff |
|---|---|---|---|
| **A** | **(i) extend TRMC to dispatch-TMC (emitter-only) vs (ii) restructure `lexer.mdk` (in-graph) vs (iii) WasmGC stack mitigation** | **(i)** | (i) is emitter-only (no fixpoint/seed/canonical edit), general (covers (a)+(b′), benefits LLVM too), but needs a new *grouping* analysis. (ii) is a localized rewrite but edits canonical in-graph code, forces a seed re-mint, risks the frozen lexer goldens, and only fixes the lexer (parser/typecheck recur). (iii) is more emitter machinery than (i) with worse constants. |
| **B** | **Make the WasmGC recursive struct fields `mut` from the start?** | **YES** | Required by destination-passing; blast radius is one type-section line + index-targeted ctor field; `$refbox`/`$arr` precedent; tail field is `(ref eq)` (top) so no covariant-subtyping break; output-gates unaffected. The only "cost" is `mut` fields are invariant under WasmGC subtyping — verified harmless here. Declining means Option (i)/(ii) can't use destination-passing at all. |
| **C** | **Lift the shared TRMC analysis module — is it imported by the compiler graph (in-graph → fixpoint+seed) or only by the emitters (out-of-graph)?** | **Keep it imported ONLY by the emitters** (`llvm_emit.mdk` + `wasm_emit.mdk`) so the lift stays emitter-only. | If the natural home pulls it into a module the compiler graph imports, the code-move itself triggers a fixpoint+seed pass. Confirm the import boundary before lifting; prefer a `backend/`-scoped module. |
| **D** | **Mirror any source change in `lib/`?** | **NO** (and avoid the situation by choosing (i)). | Lexer gates are golden-based, not live-`lib/` diffs; `lib/lexer.ml` needs no lockstep edit even under (ii). Only the goldens + fixpoint/seed are the contract — and (i) avoids even those. |
| **E** | **Stage by pass (lexer-first) vs one big TRMC-group pass?** | **Stage by pass** (lexer = Stage 2, the current blocker), per `TRMC-DESIGN.md`'s incremental precedent. | Each stage is independently gateable (a deep-list/-source fixture), so a regression localizes; a monolithic change risks an un-bisectable fixpoint/validate failure. |
| **F** | **Class B (AST tree-walk overflow in `infer`/`checkExpr`, Q4.2) — fix now or defer?** | **Defer to a separate workstream.** | TRMC cannot fix tree recursion; it needs a different transform (Ref/callback accumulation, trampoline, or desugar nesting cap). It overflows only on pathological nesting depth (O(100s)), well after the Class-A spines — so it does not block layer-5. Folding it into the TRMC work would conflate two unrelated remedies. |

---

## 9. The gate that proves the fix (analogue of `diff_native_stack.sh`)

The LLVM TRMC is gated by `test/diff_native_stack.sh` (deep-list fixtures, SIGSEGV-before
/ correct-after). The WasmGC peer:

1. **A WasmGC deep-list stack fixture** under `test/wasm/fixtures/` (peer of
   `test/stack_fixtures/`): e.g. `myMap (x => x+1) [1..=2_000_000] |> length` and a
   dispatch-TMC analogue. Run it through the existing `test/wasm/diff_wasm.sh` harness
   (emit WAT → `wasm-tools parse`+`validate` → run under Node ≥22 via `run.js` →
   diff stdout vs the `./medaka build` native oracle). **RangeError before the fix
   (the run.js child throws `Maximum call stack size exceeded`); prints `2000000`,
   exit 0, == oracle after.** Extend `diff_wasm.sh`'s corpus (it already auto-`nvm use
   24`, asserts Node ≥22, and stdout-diffs).

2. **The layer-5 acceptance gate: `check_main` runs to completion under Node on the
   full prelude.** Build on `test/wasm/assemble_check_main.sh` (which today asserts
   ASSEMBLE_OK + VALIDATE_OK) — add a *run* stage: emit `check_main` to WAT, instantiate
   under Node with the vfs host shim (`run.js`), feed `runtime.mdk`/`core.mdk` + a small
   input module, and assert it produces the typecheck-schemes output **without
   RangeError**, diffed against the native `check_main` oracle (`WASM-SELFHOST-ROADMAP.md`
   layer-12 "diff schemes vs native"). This is the decisive layer-5 close.

3. **Regression:** full `test/wasm/{diff_wasm,diff_wasm_typed,diff_wasm_modules,
   assemble_check_main}.sh` stay green (130/6/13 + VALIDATE_OK). If Stage 0's analysis
   lift touches an in-graph import, also `selfcompile_fixpoint` C3a/C3b YES + reseed.

---

## 10. One-paragraph verdict

The lexer overflow (layer-5) is **tail-recursion-modulo-cons in disguise**: each
per-token leaf scanner does `RTok … :: scan …`, so the cons-bearing frame
(`scanLower`/`emit`/…) stays live to EOF while the recursion target is the single
dispatcher `scan`. That is neither the LLVM TRMC's self-recursive shape nor general
mutual recursion — it is a **dispatch-into-single-target** shape (b′). **Porting the
existing TRMC verbatim does NOT fix it**, but the existing TRMC *analysis* is
backend-agnostic and liftable (Q5), the destination-passing *technique* maps cleanly to
WasmGC `struct.set` (Q3 — once the cons tail field is made `mut`, currently it is not),
and the (b′) generalization (inline the cons-free dispatchers, treat the family as one
`scan`-rooted destination-passing loop) is medium-effort and — crucially —
**emitter-only** (no fixpoint, no seed, no canonical-source edit), unlike restructuring
the in-graph `lexer.mdk`. Recommended: lift the analysis + make the fields `mut`
(Stage 0), build WasmGC self-TMC (Stage 1, also fixes the (a)-shaped typecheck spines),
then the dispatch-TMC group emit (Stage 2 = the layer-5 fix), gated by a WasmGC
deep-list fixture and `check_main`-runs-under-Node. **One honest caveat (Q4.2):** a
*separate*, non-TRMC class of overflow exists in the AST tree-walkers (`infer`,
`checkExpr`) — bounded by nesting depth, not input length, so low-risk on real programs
and out of scope for this TRMC work; track it as its own hardening item.

---

## 11. AS BUILT (2026-06-22) — Stages 0–2 COMPLETE, layer-5 CLOSED

Implemented per §7, emitter-only except Stage 0's analysis lift. The self-hosted lexer
now runs to completion on WasmGC under Node.

- **Stage 0 (`8c69296`; seed re-minted `6bbcde8`, bootstrap_from_seed C3a PASS).** Made the
  `$C_Cons` tail field + all `emitCtorStruct` payload fields `(field (mut (ref eq)))`
  (output-neutral). Lifted the analysis (`trmcEligible`/`isCtorTail`/`SelfRef`/
  `mentionsSelfMethod`/`selfFree`/match-descent + helpers) out of `llvm_emit.mdk` into
  `compiler/backend/trmc_analysis.mdk` (503 lines), re-pointed `llvm_emit.mdk`. The
  `Emit`-coupled ctor lookups were de-coupled by parameterizing `(ic : String -> <Mut> Bool)`/
  `(ar : String -> <Mut> Int)`. Pure code-move → `selfcompile_fixpoint` C3a/C3b YES; all LLVM
  differentials unchanged. **The ONE in-graph change of the whole arc.**
- **Stage 1 (`8737d11`, emitter-only).** WasmGC self-recursive (shape a) destination-passing TMC
  in `wasm_emit.mdk`: `wasmTrmcTry`/`emitWasmTrmcFn`/`emitWasmTrmcCtor`/`emitWasmTrmcLeaf` +
  `wTrmcCtxRef`. Loop scaffold with `$__tmc_head`/`$__tmc_dest`/`$__tmc_first` + arg-recompute
  temps; cons leaf `struct.new`s the cell, `struct.set`s into the parent's `mut` recursive slot,
  advances dest, recomputes args, `br $tmcloop` — no recursive `call`. Scope `SelfByVar` only;
  requires a uniform cons/ctor across leaves (`wTrmcUniformCtor`). Gate
  `test/wasm/fixtures/w_trmc_deep_cons.mdk` (2M `upto`): overflow → `2000000`, 0 loop calls;
  `diff_wasm` 131.
- **Stage 2 (`2688edb`, emitter-only).** The novel **dispatch-into-single-target (b′)** TMC — no
  LLVM precedent. `detectDispatchGroups` (pure, in `wasm_emit.mdk`) grows a TMC group rooted at one
  cons-target `scan`: routers cons-free + tail-call into the group, leaves cons-then-tail-call the
  root. On the real lexer the group is **49 members**. The root `scan` becomes a reset wrapper
  (zeroes 3 module globals `$g_tmc_head`/`$g_tmc_dest`/`$g_tmc_first`, `return_call $scan__disploop`);
  every spine cons leaf → build cell + link into `$g_tmc_dest` + advance + `return_call
  $scan__disploop` (the `return_call` IS the loop; no param-recompute slots needed). New
  `wDispCtxRef` live-context mechanism. **Bug found+fixed in bring-up:** the dispatch context must
  carry the ROOT's arity (5), not the emitting member's (`scanAt` is arity-6) — else a bare root
  call mis-redirects to the reset wrapper and drops the first token (`progFnArity prog root`).
  Gates `test/wasm/fixtures/w_trmc_dispatch.mdk` + `DISP-ASSERT` (0 recursive `call $scan` in any
  group body), `diff_wasm` 132. **Verified on the binary:** `check_main` lexes `runtime.mdk`+
  `core.mdk` fully under Node — flat `floatTok→layoutWithOffsets→tokenize→parse→runCheck` trace,
  no `scan`-recursion tower.

**Layer-6 (next, NOT TRMC):** `check_main` now traps a single-frame `unreachable` in
`frontend_lexer__floatTok` (`isDeferredFloatExternW`) on a `core.mdk` float literal — the
pre-existing W8b `stringToFloat` deferred-extern holdout. Port a pure-WAT/host-import
`stringToFloat`, then re-measure (Stage-3 (a)-spines or the §4.2 Class-B tree-walk may surface).

## 12. AS BUILT (2026-07-05) — Stage 3: GENERAL dispatch-GRAPH TMC (the layout family + class)

Emitter-only (`wasm_emit.mdk`; `trmc_analysis.mdk` untouched; NO LLVM seed re-mint —
`selfcompile_fixpoint` C3a/C3b YES unchanged). Generalizes Stage-2's
single-cons-target (b′) analysis to the full dispatch-graph shape BROWSER-STACK-DIAGNOSIS
§7 scoped, closing the browser Web Worker overflow (lexer offside-rule `layout` family,
~2400 frames on the prelude) AND the whole spine-cons class (`string.intersperse`, the
emit-path domino, + 11 more families picked up compiler-wide).

- **(a) Pattern-matched roots.** The `wTrmcAllPVarParams` root gate is REMOVED (it was a
  Stage-1 br-loop constraint; the b′ member emit already routes through the ordinary
  clause-chain dispatcher, which handles ctor patterns). `layout ((RNewline …)::rest)`
  roots fine.
- **(b) Member-targeted, multi-cell spine conses.** One shared classifier
  (`wDispSpineParts`: peel `h1 :: … :: f <sat>`, `f` any group member) is used by
  detection, validation, AND the leaf emit, so all three agree per leaf.
  `emitWDispSpineCons` links N cells in source order (the per-cell first/dest protocol
  chains naturally), then `return_call`s the bottom callee — `$root__disploop` for the
  root (never the reset wrapper), the member fn itself otherwise.
- **(c) Root selection in a strongly-connected family = EXTERNAL ENTRY, proven not
  guessed.** A candidate root R (pre-gate: R is some peeled cons's bottom target) grows
  its tail-closure; the group is accepted ONLY if (v4) NO bind or impl body outside the
  group references any member other than R — so R's reset wrapper is provably the sole
  entry. For layout, `flushCloseGo` etc. all fail v4 (they'd have `layout` as an
  externally-referenced non-root member); `layout` (entered by `layoutWithOffsets`)
  uniquely passes. Greedy in bind order + disjointness (v7) ⇒ deterministic.
- **Per-group dest globals.** Each root gets its own `$g_tmc_{head,dest,first}_<root>`
  triple, so a member's helper calling ANOTHER group's root mid-spine (e.g. a lexer
  helper reaching `join`→`intersperse`) builds that group's spine in that group's
  globals and returns it closed — no cross-group clobber, no cross-group veto needed.
  (Stage-2's single shared triple would have forced rejecting `scan` vs `intersperse`.)
- **Soundness validation (v2–v7), incl. the new v3:** every group-fn reference in a
  member body must sit on a sanctioned tail edge; all OTHER referenced heads (if-conds,
  let-RHSs, block prefixes, guards, scrutinees, cons heads, tail-call args, bases) are
  collected and expanded transitively through the top-level call graph (cap 256; past
  the cap ⇒ reject) and must not reach the group — this is what makes same-group
  mid-spine re-entry impossible rather than merely unobserved. `allCallHeads` gained
  the previously-missing CExpr arms (record/variant update, ranges, slices, let-group
  bind bodies, match/decision GUARDS) so references cannot hide. v5 keeps
  Stage-1-claimable singletons on Stage-1 (local dest, no globals); group membership
  now takes precedence over Stage-1 at emit (a Stage-1-emitted member inside a group
  would return its own spine instead of closing the group dest).
- **Residuals (documented, safe-by-rejection):** (1) a family whose external entry is
  never itself a cons-bottom target is not rooted (none known; layout/scan/intersperse
  entries all are); (2) dynamic dispatch (`CMethod`/`CDict`) out of member bodies is
  not traced by the closure scan (same level as Stage-2; none of the detected families
  dispatch into themselves); (3) helper closures past 256 fns reject the group.
- **Verified:** wasm gates byte-identical to the fd7612b0 baseline (diff_wasm 152 ok /
  2 pre-existing let-else FAILs also present pristine; typed 8/0; modules 28/0; sqlite
  6 ok / 3 pre-existing duplicate-`$mdk_wctor_Some` FAILs also present pristine);
  run_gates 72/1/1 (the 1 = pre-existing missing `main_not_value.json.out` golden).
  Playground WAT census: `layout`/`layoutPairs`/`scan`/`intersperse` + 11 more families
  all `__disploop`'d; every recursive edge `return_call` (remaining plain calls are O(1)
  leaf predicates). Node single-attempt (Liftoff, no retry): hello.mdk compiles CLEAN
  down to `--stack-size=200` (main trapped at ~1000 KB with 2369 frames; browser worker
  budget ~512 KB). Playwright system-Chrome e2e: 7/7 consecutive full passes (run →
  stdout, squiggles, hover, autocomplete).
