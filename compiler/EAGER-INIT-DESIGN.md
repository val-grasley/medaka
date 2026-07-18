# EAGER-INIT-DESIGN — closing the shared eager-global init-order hole (#553, S0)

**Status:** COMPLETE — the shared eager-init hole (#553) and the decided lazy-nullary invariant (#561) are both **CLOSED**. #553 Stage A (`eagerVars` structural completeness) + Stage B (the SCC-condensed reachability closure) shipped, closing the call-hidden divergences on both backends; #561 then made top-level nullary globals genuinely LAZY — native (PR-A, #659) and wasm (PR-B, #661) — with the eager fast-path preserving the byte-identical hot path, and a cycle-shape regression corpus (PR-C, #662). eval == native == wasm on cycles and dispatch-reaching globals. See §10 for the terminal (#561) design. Residual perf refinement: #660 (F2). Design pass 2026-07-17; #561 arc closed 2026-07-18.
**Spec law:** `docs/spec/WASM-SEMANTICS.md` **WP10** (now RESOLVED — both backends lazy) + its §4 row.

---

## 0. Headline — the framing in the issue is INCOMPLETE, and I can prove it

#553, WP10, and the `emitter:shared-eager-init` ledger row all state the remedy as:

> *"The real fix: a **call-graph eager-reachability closure** — for each eager binding, follow
> calls transitively and union the eager vars of every reachable callee."*

**That fix does not fix two of the four instances I reproduced, because they involve NO CALL.**
`eagerVars` is not merely *call-blind*; it is **structurally incomplete on its own AST**. It
drops subterms it is looking directly at. A closure over the call graph would leave those live.

This reframes #553 from *"one expensive graph algorithm"* into **two independent defects with
opposite cost profiles**:

| | class | fix | perf risk | can land |
|---|---|---|---|---|
| **A** | `eagerVars` misses subterms of the node it is ON | ~2 lines, add the missing recursions | **ZERO** | immediately, alone |
| **B** | `eagerVars` does not follow calls / dispatch | reachability closure | **real — this is the design fork** | after A, independently gated |

**Class A is a strictly-silent S0 that nobody has filed, and it is nearly free to fix.**
Shipping A first is the single highest value/risk move available here.

---

## 1. The problem, confirmed EMPIRICALLY (all rows re-run by me, this worktree, unpiped)

Every row below is my own run against the shipped `./medaka` with
`MEDAKA_EMITTER=…/medaka_emitter`. None is recited from the issue.

### 1.1 The filed repro — REPRODUCES (class B, call-hidden)

```medaka
mkVal _ = base
cell = mkVal ()      -- only eager var is `mkVal`, a FUNCTION => NO EDGE
base = 42
main = println cell
```
| engine | result |
|---|---|
| `run` (eval) | `42` ✅ |
| native `build` + exec | **`0`, exit 0, no diagnostic** ❌ |
| control (`base` first) | `42` / `42` ✅ |

Confirmed. Declaration order is the only variable. **The issue is real and still open.**

### 1.2 ⚠️ NEW — `CStringSlice` drops `lo`/`hi` (class A). REPRODUCES. **NO CALL INVOLVED.**

The issue lists this as an unproven "adjacent lead". **It reproduces, silently:**

```medaka
src = "hello"
cell = src.[lo..3]   -- `lo` is read DIRECTLY. eagerVars descends `src` ONLY.
lo = 1
main = println cell
```
| engine | result |
|---|---|
| eval | `el` ✅ |
| **native** | **`hel`** — `lo` read as 0 ⇒ slice `0..3`. **exit 0, no diagnostic** ❌ |
| control (`lo` first) | `el` / `el` ✅ |

The `hi` position fails the same way (`src.[1..hi]`, `hi = 3`): eval `el`, native **`""`** (empty
— `hi` reads 0 ⇒ slice `1..0`), exit 0.

**The decisive control — this isolates the cause to ONE LINE.** `CListSlice` *does* descend
`lo`/`hi` (`emit_support.mdk:60-63`); `CStringSlice` does not (`:59`). Same program shape:

```medaka
srcl = [10,20,30,40]
celll = srcl.[lo2..3]
lo2 = 1
main = println celll
```
→ eval `[20, 30]`, native `[20, 30]` ✅ **GREEN.**

**Same shape, one arm descends and is correct, the neighbouring arm does not and is wrong.**
That is a controlled experiment, not an inference. The cause is `emit_support.mdk:59`.

### 1.3 ⚠️ NEW — `eagerVarsArms` drops the GUARD list entirely (class A). REPRODUCES. **Nobody has ever named this one.**

Not in the issue, not in WP10, not in any lead. I found it by diffing `eagerVars`'s arms against
the `CExpr`/`CArm` declarations in `compiler/ir/core_ir.mdk`.

`CArm Pat (List CGuard) CExpr` (`core_ir.mdk:138`) and `CGuard = CGBool CExpr | CGBind Pat CExpr`
(`:140`) — **both guard forms carry a `CExpr`**. `eagerVars` pattern-matches
`eagerVarsArms b ((CArm pat _ body)::rest)` (`emit_support.mdk:75`) — **the `_` is the guard
list, discarded.**

```medaka
cell = match 1
  n if n < lim => "under"
  _ => "over"
lim = 42
main = println cell
```
| engine | result |
|---|---|
| eval | `under` ✅ |
| **native** | **`over`** — `lim` read as 0 ⇒ `1 < 0` false. **exit 0, no diagnostic** ❌ |
| control (`lim` first) | `under` / `under` ✅ |

**A wrong branch taken, silently.** Same S0 class as 1.1, no call involved, and it is a
one-token fix.

### 1.4 The `CMethod`/`CDict` catch-all lead — REPRODUCES, but it is class **B**, not A

```medaka
interface Mk a where
  mk : a -> Int
impl Mk Bool where
  mk _ = base
cell = mk True
base = 42
main = println cell
```
→ eval `42`, **native `0`, exit 0** ❌

**But the issue's diagnosis of *why* is wrong, and the distinction is load-bearing.** The issue
says the catch-all `eagerVars _ _ = []` (`:67`) means *"`CMethod`/`CDict` contribute no edges"*,
implying a missed subterm. **Grep-proven false:** `CMethod String Route (List Route) (List Route)`
and `CDict String (List Route)` (`core_ir.mdk:131-132`), and `Route` (`frontend/ast.mdk:80-86`) is
`RNone | RKey String (List Route) | RDict String | RDictFwd String | RLocal String (List Route) |
RScalar String` — **`Route` carries no `CExpr`.** There is no subterm to descend. The catch-all
is not dropping anything structural here.

The real hazard is that a `CMethod` is an **edge to an impl body** that the sort cannot see —
i.e. **class B reached through DISPATCH rather than a direct `CVar` call.** This matters
enormously for the design: **a closure that follows only `CVar`-named callees does not fix
1.4 either.** It must resolve dispatch routes to impl bodies.

### 1.5 Catch-all audit — what it actually swallows (complete, by construction)

I enumerated every `CExpr` constructor in `core_ir.mdk:55-132` against every `eagerVars` arm:

- **Matched:** `CLit CVar CApp CLam CLet CLetGroup CMatch CDecision CIf CBinPrim CUnOp CTuple
  CList CRecord CFieldAccess CRecordUpdate CVariantUpdate CArray CRangeList CRangeArray CIndex
  CSlice CStringIndex CStringSlice CListIndex CListSlice CBlock`
- **Reaches `eagerVars _ _ = []` (`:67`):** **`CMethod`, `CDict` only** — and neither holds a
  `CExpr`. ⇒ **the catch-all is currently harmless.** It is still a latent hazard (it defaults new
  constructors to *"no dependencies"*, the unsafe direction) — see §6 fork F4.
- `CStmt` = `CSExpr | CSLet | CSAssign` (`core_ir.mdk:191-194`) — **all three matched**
  (`:85-89`); the `eagerVarsStmts b (_::rest)` catch-all (`:90`) is **dead code**.
- `CDecision` not descending its `CTree` is **SAFE**: `CTree` (`core_ir.mdk:155-166`) is
  `CTFail | CTLeaf Int | CTGuard Int CTree | CTSwitch (List CTBranch) CTree | CTDrop CTree` —
  arm **indices**, no `CExpr`. Guards live on the `CArm`, which is why §1.3 is the live bug.

**⇒ Class A is exactly two holes: `CStringSlice`'s `lo`/`hi` (`:59`), and `CArm`'s guards (`:75`).**
Both reproduce silently. Neither is fixed by any closure.

### 1.6 Three-engine truth

I did not re-run the wasm arm (it needs a toolchain run outside my read-only budget). WP10 §4
records it as *"dereferencing a null pointer"* at instantiate. **eval is the only correct engine
in every instance above** — which §5.1 explains is not a coincidence.

---

## 2. Every touchpoint, grep-proven

`grep -rn 'eagerVars' compiler/ --include=*.mdk` (scoped to `compiler/`, `.mdk` only):

| file | symbol | role |
|---|---|---|
| `compiler/backend/emit_support.mdk` | **`eagerVars : List String -> CExpr -> List String`** (`:28`) | **THE shared primitive.** Both holes live here (`:59`, `:75`) |
| `compiler/backend/emit_support.mdk` | `eagerVarsList` `eagerVarsArms` `eagerVarsFields` `eagerVarsStmts` `eagerVarsBinds` | its mutual-recursion group |
| `compiler/backend/llvm_emit.mdk` | `bindFreeVars` (`:8496`) → `orderedValBinds` (sig `:8449`, body `:8452`) | **native** sort, fed by `eagerVars [] body` |
| `compiler/backend/wasm_emit.mdk` | `bindEagerVars` (`:2503`) → `topoSortValBinds` (`:2458`) | **wasm** sort, fed by the same |
| `compiler/backend/wasm_emit.mdk` | `eagerVars` in the import list (`:237`) | import site |
| `compiler/backend/llvm_emit.mdk` | `eagerVars` in the import list (`:241`) | import site |
| `compiler/types/typecheck.mdk` | `:1897-1910` | the #552 point-fix's explanatory comment (prose only) |

⚠️ **Line-number drift, checked rather than assumed.** The issue/prompt cite `orderedValBinds`
at `:8452` — **that one is correct** (it is the body line; the signature is `:8449`). But
`bindFreeVars` is cited at `:8499` and is **actually `:8496`**, and `emitTopGlobals … 
orderedValBinds …` is cited at `:9882` and is **actually `:9879`** — both drifted by 3.
**Every symbol still resolves; two of three line numbers do not.** Cite the symbol.

**Call sites of the two sorts** (these are the eager-init entry points):
- native: `emitTopGlobals e (orderedValBinds (valBinds groups))` — `llvm_emit.mdk:9879` (single site)
- wasm: `topoSortValBinds (filterList isValBind groups)` — `wasm_emit.mdk:1893` **and** `:2512`
  (**two** call sites — **both** must get the same edges; native has only one)

**The two sorts are DELIBERATE cross-file duplicates.** Both carry
`-- lint-disable-next-line rule-duplicate-body` with the comment *"Intentional cross-file
duplicate of the same helper in wasm_emit.mdk; not consolidating (tiny helper /
divergent-by-design backend pair)"*. `topoValGo`/`topoValVisit`/`topoValVisitDeps` are duplicated
**verbatim** in both files, differing only in `intersectStr (dedupS …)` (native) vs
`filterList (n => contains n names) (dedupKeep …)` (wasm), and `findBind` vs `findBindByName`.

⇒ **Any fix that lives in the SORT must be written twice, and can drift.** Any fix that lives in
`eagerVars` is written once and lands on both backends simultaneously. **This is the argument
for §3's placement decision.**

---

## 3. ⚠️ PERF — and a finding the issue does not contain: THE BASELINE IS ALREADY THE 14th QUADRATIC

`compiler/AGENTS.md`'s ONE RULE: *"A `List` is not a set, and it is not a map."* and its explicit
antipattern list: `contains x xs`, `lookupAssoc k pairs`, **`xs ++ [x]` inside a fold — "O(n²) BY
ITSELF: `++` is O(left)"**.

**The EXISTING `topoValVisit` — in BOTH backends, today, before anyone adds a closure — is all
three at once:**

```medaka
topoValVisit all names b done acc visiting
  | contains (bindName b) done     = (done, acc)   -- (1) List as a SET
  | contains (bindName b) visiting = (done, acc)   -- (1) List as a SET
  | otherwise =
    let deps = intersectStr (dedupS (bindFreeVars b)) names   -- (2) List as a SET, per binding
    let (done2, acc2) = topoValVisitDeps all names deps done acc (bindName b :: visiting)
    (bindName b :: done2, acc2 ++ [b])              -- (3) `xs ++ [x]` IN A FOLD
```
plus `findBind : String -> List CBind -> Option CBind` — **a linear scan of ALL binds, per
dependency edge** = (4) **List as a MAP**, the single most-cited shape in `AGENTS.md`.

**So the topo sort is already O(n²)** in the number of value globals, with `n` ≈ **583**
candidate top-level nullary binds across `compiler/` + `stdlib/`
(`grep -rhn '^[a-z][a-zA-Z0-9_]* = ' compiler/ stdlib/ --include=*.mdk | wc -l` → 583; an
upper bound — the post-DCE `filterList isValBind` set is smaller). n² ≈ 3·10⁵ `contains` steps
— **currently tolerable, which is exactly why nobody has noticed.**

### 3.1 Why this is the whole perf story

**A closure MULTIPLIES this baseline by the size of the CALL graph.** The value-global set is
~hundreds; the *function* set is **thousands** — `AGENTS.md` records that a **9-line program emits
272 functions, 271 of them prelude**. A naive closure — per eager binding, DFS the call graph with
a `List` for `seen` — is:

> O(n_valbinds × V_functions × E) with a `List` doing set duty = **the textbook 14th quadratic,
> and in practice worse than quadratic.**

**This is the danger the issue is right about.** The fix is not "be careful"; it is **structural**:

### 3.2 The mechanism that avoids it — memoize ONCE over the call graph, not per binding

```
eagerReach(f)  =  eagerVars(f.body)  ∪  ⋃ { eagerReach(g) | g ∈ callees(f) }
```
This is a **least fixpoint over the call graph** — computable **once per program**, not once per
eager binding, and consumed by both sorts as a lookup:

1. Build `callees : OrdMap String (List String)` — one pass over all `CBind`s.
2. **Condense with `tarjanSCCs`** — cycles collapse to a node; `eagerReach` is constant within an
   SCC (every member reaches every other), so mutual recursion is *handled by construction*, not
   by a visited-guard hack. **This answers the issue's "cycle handling" requirement outright.**
3. Fold the SCC DAG in **reverse topological order** — each SCC's set is its members' `eagerVars`
   unioned with its successors' already-computed sets. **Single pass, no re-visiting, no bound
   needed** — the DAG order *is* the bound.
4. Both sorts read `omLookup name reachMap`.

**Complexity: O((V + E) · log V)** with `OrdMap` unions, computed **once**. Not per-binding.
**Termination is structural** (a DAG fold), so there is no "add a depth bound and hope".

### 3.3 ⚠️ THE PRIMITIVES ALREADY EXIST — and the `import map` cost is ALREADY PAID

The issue frames the set/map as a cost to be weighed (*"+34 KB binary, +4.8% self-compile,
because DCE keeps every `DImpl`/`DInterface` whole"*). **Grep-proven: that cost does not apply
to this change.**

- `compiler/support/ordmap.mdk` — `omEmpty omInsert omLookup omHasKey omDelete omKeys omFromNames
  omFromPairs omMapValues omSize`. It is the thing that `import map.{Map(..), …}` (`ordmap.mdk:8`).
- **`compiler/backend/llvm_emit.mdk:196` and `compiler/backend/wasm_emit.mdk:194` ALREADY
  `import support.ordmap`.** ⇒ `map`'s `DImpl`/`DInterface` decls are **already retained** in
  `medaka` and `medaka_emitter`. Adding `ordmap` to `emit_support.mdk` (which today imports only
  `ir.core_ir`, `frontend.ast`, `backend.trmc_analysis`, `support.util`) **retains no new
  declaration** and therefore **costs 0 KB and 0%**. The 34 KB was paid long ago.
- **`compiler/support/scc.mdk` ALREADY EXISTS**: `tarjanSCCs : List String -> OrdMap (List String)
  -> List (List String)` (`:34`) — Tarjan's SCC, *"extracted from types/typecheck.mdk (PR1 of
  #158). Self-contained: it references only String/Int/Bool/List and the OrdMap wrappers"*. It
  imports only `support.ordmap` + `support.util`. Its only current consumer is
  `processTopGroups` in `typecheck.mdk` — so **it is already linked into every binary**, and a
  new `backend → support.scc` edge adds nothing.

**⇒ The exact data structures the correct design needs are already in the tree, already paid for,
already self-compiling.** There is no "do we take the map dependency" trade-off here. **The
cheap-looking `List` version is not even cheaper — it is just wrong.** This is the single most
important perf fact in this document.

### 3.4 ⚠️ WHAT GATE ACTUALLY CATCHES A REGRESSION HERE — the perf gate does NOT

`test/diff_compiler_perf_scaling.sh` grades **allocation** (and, since #110/#116, **time per
stage**). Per `AGENTS.md`'s SECOND RULE and the `rootIdOf`/#115 history — a **58× fix that hid
under a green gate for months** — **allocation is blind to a pure scan by construction.**

**Do not claim the perf gate covers this.** Concretely:

- ❌ **Allocation grading is blind.** `contains`/`findBind` allocate nothing. (The one exception:
  `acc2 ++ [b]` *does* allocate — so the existing sort's quadratic is *partially* visible. A
  closure's `seen`-list scan would not be.)
- ⚠️ **Time-per-stage grading is the only arm with a chance** — and `eagerVars` runs inside the
  **emit** stage. **Whether `diff_compiler_perf_scaling.sh` grades an `emit` stage separately, or
  folds it into a coarser bucket, DETERMINES whether this is gated at all. I did not verify this,
  and it must be verified before anyone relies on it.** Per `AGENTS.md`: *"Grade PER-STAGE, never
  a sum. Dilution can only push a ratio down toward 1.0."* A closure's cost diluted into a
  whole-`build` number is exactly the dilution that hid #115.
- ✅ **What WILL catch it — a DIRECT SCALING ASSERTION, not a general gate.** The honest answer is
  that no existing gate covers this, so the fix must **bring its own**: a synthetic fixture with a
  **deep call chain** (`f0 = f1 (); f1 _ = f2 () …` × 2ⁿ) plus a **wide mutual-recursion SCC**,
  compiled at n and 2n, asserting the **emit-stage time ratio stays ≈2.0** with
  `GC_INITIAL_HEAP_SIZE=2147483648` pinned and **min-of-k** (both per `AGENTS.md`'s measurement
  traps). The SCC arm is the one that goes red if someone replaces the Tarjan condensation with a
  visited-list.
- ✅ **Correctness regression is well-gated already** — `test/diff_compiler_engines.sh` (346
  fixtures × 3 engines) + the self-draining ledger. See §7.
- ⚠️ **`AGENTS.md`: "If you add a gate, ask where it is skipped."** A new perf assertion must be
  enrolled in a CI shard (`diff_compiler_ci_shard_coverage.sh` catches non-enrolment) and **must
  print `checked N` with `N == 0` a FAILURE**. Do not add it to `gates (engines)` (~5.8 min, the
  critical path).

---

## 4. RECOMMENDED MECHANISM

> **Split #553 in two. Land the structural-completeness fix (A) NOW — it is ~2 lines, zero perf
> risk, and closes two silent S0s. Then land the reachability closure (B) as an SCC-condensed,
> memoized-once fixpoint in `emit_support.mdk` beside `eagerVars`, using the `ordmap` + `scc`
> primitives that already exist and are already paid for.**

### 4.1 Stage A — structural completeness of `eagerVars` (no closure, no graph, no perf risk)

Two edits in `compiler/backend/emit_support.mdk`, both *adding* recursion into subterms
`eagerVars` is already standing on:

1. **`:59`** — `CStringSlice` must descend `lo`/`hi`, exactly as `CListSlice` (`:60-63`) and
   `CSlice` (`:64-66`) already do. **The correct code is literally the neighbouring arm.**
2. **`:75`** — `eagerVarsArms` must descend the `List CGuard` it currently discards (`CGBool e` →
   `eagerVars b e`; `CGBind pat e` → `eagerVars b e`, and its `patVars` scope into the *following*
   guards and the body — mirroring `eagerVarsStmts`'s existing `CSLet` threading at `:86-87`).

**Perf: nil.** No new traversal *reachability* — the same single walk visits strictly more nodes
of the same tree. It is O(size of the binding's own body), unchanged in shape.
**Risk: nil-to-low.** These edits can only ADD edges. An added edge can only (a) fix an ordering,
or (b) create a **false cycle** — and per both sorts' doc comments, a cycle falls back to source
order = **today's behaviour**. So Stage A is **monotonically no worse**, with one caveat in fork
**F3** below.
**Correctness gate: already exists** (§7) — `diff_compiler_engines.sh` + two new fixtures.

### 4.2 Stage B — the eager-reachability closure

**Placement: `emit_support.mdk`, beside `eagerVars`. Not in either sort, not in Core IR.** Reasons,
each grep-backed:

- **Not in the sorts** — `topoValGo`/`topoValVisit`/`topoValVisitDeps` are **verbatim duplicates
  across the two backends**, marked `lint-disable-next-line rule-duplicate-body` as
  *intentional*. Putting the closure there means **writing the hardest algorithm in this design
  TWICE and maintaining it against drift.** *"A one-backend fix is a half fix"* — and a parity
  gate **cannot see** a bug where both backends are equally wrong (this bug's entire history).
  Placement in the shared primitive makes the one-fix-both-backends property **structural**.
- **Not in Core IR** — Core IR is deliberately `Ty`-free and immutable
  (`core_ir.mdk:202-211`: *"the IR stays Ty-free"*). Eager-init order is a **backend physical-
  encoding** concern (that is precisely why WP10 is a *physical-encoding law*), not an IR
  property. Eval — the correct engine — needs none of it (§5.1).
- **In `emit_support.mdk`** — both backends already import `eagerVars` from it
  (`llvm_emit.mdk:241`, `wasm_emit.mdk:237`); adding one more export to the same import list is
  the smallest possible seam.

**Shape** (`eagerVars` keeps its exact signature — additive, non-breaking):

```
-- new, in emit_support.mdk:
eagerReachMap : List CBind -> OrdMap (List String)     -- built ONCE per program
bindEagerReach : OrdMap (List String) -> CBind -> List String   -- the sorts' new edge source
```
Both `bindFreeVars` (native) and `bindEagerVars` (wasm) become one-line delegations to
`bindEagerReach`, with the map threaded from the sort's entry. **`eagerVars` itself is
unchanged** — the closure *consumes* it. That keeps Stage A independently revertable.

**Algorithm: §3.2** — build `callees` map → `tarjanSCCs` condense → reverse-topological fold →
`OrdMap` memo. **O((V+E)·log V), once.** Cycles handled *by construction*; no depth bound needed.

**⚠️ Stage B must follow DISPATCH edges, not just `CVar` callees** — else §1.4 stays live. This
is the part of Stage B I am least able to cost from a read-only pass, and it is fork **F2**.

---

## 5. REJECTED ALTERNATIVES — each with the concrete thing that kills it

### 5.1 Make top-level nullary bindings LAZY / thunked — **REJECTED for 0.1.0, but it is the DECIDED ENDPOINT, and this changes how you should read Stage B**

⚠️ **This is not a fresh idea to be weighed — it is already decided repo doctrine, and the prompt
was right to flag it as "may already be half-true". It is more than half-true:**

- **`.claude/ORCHESTRATING.md:885`** — *"**Decided invariants — do not relitigate** (see memory):
  retirement ≠ removal; **lazy top-level nullary canonical**; no catchable panics."*
- **`compiler/WASMGC-DESIGN.md:249-252`** — *"Thunks (**lazy top-level nullary, see MEMORY 'Lazy
  top-level nullary canonical'**) = a 0-capture closure forced on first reference; represent
  identically to closures with a forced/value cache field."*

**⇒ The canonical semantics of a top-level nullary binding is LAZY. Eval implements it. Both
backends implement an EAGER approximation of it, and the topo sort is the workaround that makes
the approximation *usually* indistinguishable.** *That* is why **eval is the only correct engine
in all four of my repros** — it is not luck and it is not a coincidence, it is the one engine
running the decided semantics. **#553 is the gap between the decided invariant and the shipped
approximation.**

**Why it still loses for 0.1.0:** thunking every value global means a forced/value-cache check on
**every global read** — `WASMGC-DESIGN.md` scopes it as *WasmGC-roadmap* work, unimplemented on
**both** backends. It is a codegen-representation change to the hottest possible path, gated by
the fixpoint, in an S0 hotfix. **Cost: weeks + a self-compile perf risk. Benefit over Stage A+B:
it makes init order un-observable rather than merely correctly-ordered.**

**But it reframes Stage B honestly:** Stage B is **a better workaround for a known-approximate
encoding**, not the terminal answer. That is fine — it is the right 0.1.0 move — but the design
doc should say so, and WP10's *"the general fix (#553, an eager-reachability closure that follows
calls)"* should **not** be read as "and then the law is satisfied forever". **Fork F1.**

### 5.2 Emit a DIAGNOSTIC on an unresolved eager forward-ref / cycle instead of silently reading zero — **NOT REJECTED. RECOMMENDED AS A COMPANION TO B, and it is the highest-value-per-line item in this document.**

The prompt lists this as an alternative to kill. **I decline to kill it, and I think that is the
most important judgement in this pass.**

**It is not an alternative to the closure — it is the BACKSTOP that makes the closure's residual
failure mode loud instead of a plausible wrong answer.** Today's behaviour after *any* miss —
Stage A's, Stage B's, or the next one — is *"print 0 and exit 0"*. **Every instance in §1 is a
plausible wrong answer with no diagnostic. That is the worst possible failure class**, and it is
the actual reason #553 is S0 rather than S1: not that the order is wrong, but that **being wrong
is silent**.

The information is **already there**: both sorts already **detect** the condition — `topoValVisit`
has `| contains (bindName b) visiting = (done, acc)` — a **back-edge**, i.e. a genuine eager
cycle — and **silently falls back to source order**. `llvm_emit.mdk:1412` even says out loud:
*"eager same-init forward ref: orderedValBinds topologically sorts eager…"*, and per WP10 the
native comment continues *"a surviving eager forward ref is a genuine value cycle … and the cell
still holds 0"*. **The compiler KNOWS it is emitting a cell that will read zero, and says
nothing.**

**Cost: near-zero** — it is a diagnostic at a branch that already exists. **Why it is not
sufficient alone:** it converts S0-silent into S1-loud but **rejects programs the closure would
accept** (every §1 repro is a *legal* program the sort merely failed to order). ⇒ **Ship it
*with* B, where it fires only on a genuine cycle B cannot break.** **Fork F5** — because a
false-positive diagnostic on a legal program is a release-blocking regression, and the
back-edge-vs-unorderable distinction must be got right.

### 5.3 Naive call-graph closure with a `List` for `seen` (the "obvious fix") — **REJECTED**

**This is the proposal the next person will reach for, and it looks right until you try to break
it.** Concretely:

```medaka
closure b = go (bindFreeVars b) []          -- `seen : List String`
go [] seen = seen
go (x::rest) seen | contains x seen = go rest seen        -- List as a SET
                  | otherwise = go (calleesOf x ++ rest) (seen ++ [x])   -- `++` in a fold
```
**Two counterexamples that kill it:**

1. **Perf.** Per §3.1: O(n_valbinds × V × E) with `contains` doing set duty, over a **thousands-
   function** graph (271/272 functions in a 9-line program are prelude), **× 583 value globals**,
   **× 346 fixtures** in `diff_compiler_engines` — which `AGENTS.md` names as **CI's critical
   path**. And per §3.4 the **allocation gate cannot see it**. This is `AGENTS.md`'s ONE RULE and
   its THIRTEEN precedents, verbatim.
2. **Correctness — the `visiting`-guard trap.** The compiler is *"full of mutual recursion"*. A
   `seen`-list guard makes `eagerReach` **depend on visit order**: entering an SCC at `f` vs at
   `g` yields **different** sets, because the back-edge is cut in a different place. **The
   memoized result is then wrong AND non-deterministic w.r.t. traversal order** — which
   **breaks C3b** (the emitter reproducing its own IR byte-for-byte), the repo's decisive
   determinism gate. **The SCC condensation is not a perf optimization — it is what makes the
   fixpoint WELL-DEFINED.** A `seen`-list closure is not a slow correct algorithm; it is a fast
   incorrect one.

### 5.4 Runtime zero-init detection — **REJECTED**

Poison every value global and trap on read-before-init. **Kills it:** (a) `0` is a *legal* `Int` —
there is no spare bit for a poison value on the **unboxed** arm, which is **exactly the silent S0
arm** (§1.1 prints `0`; a `42`-vs-`0` distinction is invisible at the word level). It would fix
only the boxed/null arm, which is **already loud**. (b) A per-read check on every global read is
the §5.1 thunk cost with none of the §5.1 benefit. (c) Runtime-only ⇒ **cannot** fire in the
playground's instantiate-time trap window.

### 5.5 Just re-add the missing edge per site, as PR #552 did — **REJECTED as a strategy**

#552 was the right *hotfix* and its own comment says it does not close the class. **Kills it:**
it is not a fix, it is a **coding convention enforced by nothing** — *"correctness depends on
nobody ever moving a global read behind a call"*, and **a comment is not a gate**. My §1.2/§1.3
are two instances that were live the whole time under this strategy.

### 5.6 Fix only the wasm backend — **REJECTED, and the issue's own history is the argument**

The original #553 body asserted *"Native is unaffected"*. **False**, corrected in-issue, and my
§1.1–§1.4 are native. A wasm-only fix leaves the **silent** arm — the worse one — live.

---

## 6. DESIGN FORKS — needs a human decision

I am not resolving these. Each is a genuine language/scope decision, not a coding choice.

### F1 — Is Stage B the answer, or an admitted workaround with a scheduled end?
**`lazy top-level nullary canonical` is a DECIDED, do-not-relitigate invariant
(`.claude/ORCHESTRATING.md:885`), and eval already implements it — which is why eval is the only
correct engine.** Stage B makes the *eager approximation* correct; it does not make the backends
implement the decided semantics. **Decide and write down which:**
- **(a)** Stage B is the answer; eager+topo-sort is hereby the *canonical backend encoding* and
  the "lazy nullary" invariant is an **eval-level** semantic only ⇒ **then WP10 and the invariant
  list must be amended to say so**, because as written they conflict.
- **(b)** Stage B is an explicit workaround; thunks (`WASMGC-DESIGN.md:249-252`) remain the
  endpoint and get an issue ⇒ **then WP10's *"the general fix (#553…)"* wording is wrong** and
  should say *"the general MITIGATION"*.

**This is a language-design question about what a top-level nullary binding MEANS, and there are
two published repo documents that currently answer it differently from the shipped backends. It
is not mine to settle.**

### F2 — Must Stage B follow DISPATCH edges? (scope-determining)
**§1.4 reproduces**: `cell = mk True` where `mk`'s impl reads a later global → native `0`, silent.
A closure over `CVar`-named callees **does not fix it**; the head is a `CMethod` carrying `Route`s
(`core_ir.mdk:131`), not a callee name. Following it means resolving `RKey`/`RDict`/`RImpl`
routes to impl bodies **inside the emitter**, and `AGENTS.md` warns *"typeclass dispatch is
OUTLINED, not inlined at the site"*. Options:
- **(a)** Follow dispatch routes ⇒ correct, materially larger, needs the impl table in the closure.
- **(b)** Follow direct calls only, and **conservatively treat any `CMethod`/`CDict` in an eager
  binding as depending on EVERY value global** — sound (over-approximates), cheap, but **risks
  forging false cycles ⇒ source-order fallback ⇒ silently back to today's bug.** Needs measuring
  against the real compiler graph before it can be trusted.
- **(c)** Defer 1.4, ledger it as a known-open row. **Leaves a silent S0 live.**

### F3 — What is the blast radius of Stage A's NEW edges on the SELF-COMPILE? (must be measured, not reasoned)
Stage A adds edges the sort has never seen. On the compiler's own graph an added edge can forge a
**false cycle** ⇒ source-order fallback ⇒ *"leaving the eager ref null again — which is exactly
why a naive free-vars sort did NOT fix `parse ""`"* (`wasm_emit.mdk:2453`, the
`topoSortValBinds` doc comment). **That comment is a receipt that this class of change has
already bitten this repo once.** The parser combinator ladder is the stated hazard.
⇒ **Stage A must be validated by the fixpoint + `diff_compiler_engines` + a playground/wasm
instantiate check, not waved through as "it's two lines".** ⚠️ **I could not run these
(read-only). This is the one place where my "zero risk" claim is a REASONED claim, not a measured
one — treat it as unverified.**

### F4 — Should `eagerVars`'s catch-all become exhaustive?
`eagerVars _ _ = []` (`:67`) is **harmless today** (§1.5: only `CMethod`/`CDict` reach it, neither
holds a `CExpr`). But it is *"an allowlist defaulting to 'no dependencies' — the unsafe
direction"*: **the next `CExpr` constructor anyone adds silently gets no edges, and this exact
S0 returns.** §1.2 and §1.3 are what that costs. Options: **(a)** enumerate `CMethod`/`CDict`
explicitly and delete the catch-all ⇒ a new constructor becomes a **compile error**
(exhaustiveness), which is the safe direction; **(b)** keep it. **The `eagerVarsStmts` catch-all
(`:90`) is provably dead** (all 3 `CStmt` arms matched) and can go either way.
**Recommendation: (a).** This is the cheapest permanent guard against the *class*, and it costs
one exhaustiveness check. But it is a deliberate choice to trade a wildcard for a build break.

### F5 — Ship the cycle diagnostic (§5.2)? And is a genuine eager cycle an ERROR?
The back-edge branch already exists and already knows. **Should an unbreakable eager value cycle
be a compile ERROR (loud, may reject a legal-today program) or a WARNING (loud, compatible)?**
Both sorts' comments claim genuine value cycles *"none arise in practice"* — **if true, an error
costs nothing and closes the silent class permanently. If false, it is a release-blocking
false positive.** ⚠️ **That "none arise in practice" claim is UNVERIFIED and is exactly the kind
of comment this issue's history shows to be wrong** (*"native is unaffected"* was also a
confidently-stated comment). **Measure it before choosing.**

### F6 — Where does the LAW live? The native spec is SILENT. (a spec finding)
**`grep -rn 'eager' compiler/STAGE2-DESIGN.md compiler/RUNTIME-DESIGN.md compiler/EMITTER-GAPS.md
docs/spec/*.md` returns hits ONLY in `docs/spec/WASM-SEMANTICS.md` — ZERO in any native
document.** WP10 is thorough and *does* state the native arm — but it lives in a file called
**WASM-SEMANTICS**, under a law-code (`WP*`) meaning *wasm physical encoding*, while describing a
**backend-shared, native-inclusive** invariant.

⇒ **A native implementer reading `STAGE2-DESIGN.md` / `RUNTIME-DESIGN.md` / `EMITTER-GAPS.md`
would never learn this law exists.** That is precisely how *"native is unaffected"* got written
into the issue and survived unchallenged. **The law is correct and in the wrong home.** Decide:
promote WP10 to a backend-shared spec (or add a native-side law that cross-references it).
**I flag this as a finding, per the prompt's instruction to ask whether a spec already answers
the question: one DID, and its filename is why nobody read it.**

---

## 7. STAGING PLAN — seams, gating, and what is parameterized for later

### PR-1 — Stage A: `eagerVars` structural completeness (**land first, alone**)
- **Change:** `emit_support.mdk` `:59` (`CStringSlice` → descend `lo`/`hi`) and `:75`
  (`eagerVarsArms` → descend guards). Optionally F4(a).
- **Fixtures (new, mirroring the existing pair's shape exactly):**
  - **AS BUILT (Stage A):** `test/llvm_fixtures/eager_global_guard.mdk` (§1.3) — the
    guard-chain control, still live.
  - **AS BUILT (Stage A), since REMOVED by #670:** the `eager_global_string_slice` /
    `eager_global_list_slice` typed fixtures gated Stage A's `CStringSlice`/`CListSlice`
    bounds-descent (the *typed* corpus, since `llvm_fixtures/`'s probe is prelude-free and
    cannot do `CStringSlice`). #670 made slice a `Slice` prelude method whose impls call
    `stringSlice`/`arrayGetUnsafe`, so those Core IR nodes are unreachable and the fixtures
    were retired — dead-code removal tracked in #700.
  - **Precedent to copy verbatim:** `test/llvm_fixtures/eager_global_call_hidden.mdk` +
    `eager_global_call_ordered.mdk`, ledgered `emitter:shared-eager-init` at
    `test/engine_divergence.txt:121`. **The category already exists** (added 2026-07-16 for #553)
    — this is the taxonomy work #543/#552 already paid for, and **PR-1 does not need a new
    category.**
  - ⚠️ **Land the fixtures RED-first (ledgered) in the same PR, then drain them** — the existing
    row's `DRAINS when #553 lands` self-drain mechanism (*"simulating the fix yields `PROMOTE
    llvm/eager_global_call_hidden`, exit 1"*) is what proves the fixture can go green. Per
    `AGENTS.md`: **"HAVE YOU SEEN IT FAIL?"**
- **Gates:** `diff_compiler_engines.sh` (required; **a changed `known (ledgered)` count must be
  EXPLAINED**), `selfcompile_fixpoint.sh` C3a/C3b, plus **F3's measured blast-radius check**.
- **Independently valuable and independently revertable.** Closes two silent S0s alone.

### PR-2 — the cycle/forward-ref DIAGNOSTIC (§5.2), if F5 says yes
- Fires at the **existing** back-edge branch in both sorts. **Small, and it converts every
  residual miss — including ones we have not found — from a plausible wrong answer into a named
  failure.** Independently gated by a fixture asserting the diagnostic's `file:line`.
- **Seam:** deliberately BEFORE PR-3, so that if the closure has a residual hole, it is **loud**.

### PR-3 — Stage B: the SCC-condensed reachability closure
- `emit_support.mdk` gains `eagerReachMap` / `bindEagerReach`; `bindFreeVars` (native) and
  `bindEagerVars` (wasm) delegate. `import support.ordmap` + `support.scc` into `emit_support`.
- **Ships with its OWN scaling assertion** (§3.4): deep-chain + wide-SCC fixture, emit-stage time
  ratio ≈2.0, `GC_INITIAL_HEAP_SIZE=2147483648` pinned, min-of-k, enrolled in a shard that is
  **not** `gates (engines)`, printing `checked N` with `N == 0` = FAILURE.
- **Drains `test/engine_divergence.txt:121`** (`llvm/eager_global_call_hidden` → PROMOTE).
- ⚠️ **Emitter measurement discipline is MANDATORY here** — `benchmark-emitter` skill:
  `FORCE_EMITTER_REBUILD=1 make medaka`, the two-rebuild rule. *"An agent measured its own 2.2×
  win as a 2.5× SLOWDOWN"* by skipping this.

### PR-4 — dispatch edges (F2(a)), **parameterized so it is ADDITIVE**
**The seam that keeps this a later patch and not a rewrite:** `eagerReachMap : List CBind ->
OrdMap (List String)` builds its `callees : OrdMap String (List String)` adjacency in **one
separable step**. Dispatch support is *"add the `CMethod`/`CDict` → impl-body edges to `callees`
before condensing"* — **the SCC fold, the memo, the sorts, and the gates are untouched.** If F2
picks (c) (defer), PR-3 ledgers §1.4 as a known-open row and PR-4 drains it. **Nothing about
PR-3's structure changes.**

### Explicitly OUT of scope (⇒ F1(b) issue): thunked/lazy globals (§5.1).

### Spec work (F6), ships with PR-1
WP10's §1 body and §4 row currently state the remedy as *"an eager-reachability closure that
follows calls"*. **§1.2/§1.3 prove that is INCOMPLETE — those instances involve no call and no
closure fixes them.** WP10 must be amended to state the law as **"edges must cover every eager
subterm AND every eager callee"**, or it will keep pointing the next reader at only half of #553.

---

## 8. Confidence and what I did NOT verify

- ✅ **Measured by me, unpiped:** §1.1, §1.2 (+`hi` + `CListSlice` control), §1.3, §1.4, and every
  `_ordered` control. Four silent-wrong-answer instances, two of them previously unknown.
- ✅ **Grep-proven:** every symbol, file, and import claim in §2/§3.3/§5.1/§6-F6.
- ❌ **NOT verified:** the **wasm** arm of §1.2/§1.3/§1.4 (I ran native + eval only). The
  **allocation/time-stage granularity** of `diff_compiler_perf_scaling.sh` (§3.4) — **verify
  before relying on it.** **F3's blast radius** — my "Stage A is zero-risk" is reasoned, not
  measured. Any *absolute* perf number for Stage B (nothing was built).
- ⚠️ `n ≈ 583` (§3) is a **source-level grep upper bound**, not a post-DCE count.

---

## 9. ⚠️ LATE FINDING (probed after §1-§8 were written) — this SETTLES F5 and re-grades F1

I ran the F5 experiment (§6-F5 called it "cheap and not run"). **It inverts two of this
document's conclusions. Read this section before acting on §5.2 or §6-F1/F5.**

### 9.1 A FIFTH divergence — a recursive nullary value: eval ERRORS, native prints a number

```medaka
x = x + 1
main = println x
```
| engine | result |
|---|---|
| `run` (eval) | **`runtime error [E-CYCLIC-VALUE]: x refers to itself during initialization (non-productive cyclic value)`, exit 1** ✅ |
| **native `build`** | **`1`, exit 0** ❌ — reads the zero cell, computes `0+1`, prints it |

### 9.2 The `llvm_emit.mdk` comment defending the silent zero is CHECKABLY FALSE

`llvm_emit.mdk:1413-1416` says the surviving-forward-ref zero is fine because:

> *"a surviving eager forward ref is a genuine value cycle (none arise in practice) and the cell
> still holds 0 — **but that is exactly the interpreter's recursive-value semantics, not an
> emit-time error.**"*

**The interpreter's recursive-value semantics is `E-CYCLIC-VALUE`, exit 1 — not `0`.** The
comment asserts parity with eval and **eval does the opposite**. This is the *"native is
unaffected"* pattern again, verbatim: **a confidently-stated source comment, never checked, used
to justify the unsafe direction.** It should be deleted with the fix, and it is the reason the
silent zero has gone undefended-but-unchallenged for so long.

Also note *"(none arise in practice)"* — my 2-line program is a counterexample to the parenthetical.

### 9.3 ⇒ F5 IS NOT A LANGUAGE-DESIGN DECISION. It is PARITY RESTORATION.

§6-F5 asked *"should a genuine eager cycle be an ERROR or a WARNING?"* — **that framing is
obsolete.** The language has **already decided**: eval, the canonical engine, raises a **named,
coded diagnostic that already exists in the tree** — `E-CYCLIC-VALUE`
(`compiler/eval/eval.mdk:562`, raised by `blackholeCell` `:559-563`, via `forceCell`/`forceMemo`
`:545`/`:550`). **Nothing needs inventing. The backends simply do not implement it.**
⇒ **Ship §5.2 as an ERROR with the existing `E-CYCLIC-VALUE` code.** The only residual question
is the small one: does the backends' *unorderable* case coincide exactly with eval's
*black-holed* case? (F5', below.)

### 9.4 ⇒ F1 is re-graded: "lazy top-level nullary canonical" is NOT aspirational — EVAL SHIPS IT

§5.1 read `.claude/ORCHESTRATING.md:885` + `WASMGC-DESIGN.md:249-252` as a *decided but
unimplemented* invariant. **It is implemented, today, in eval.** `eval.mdk:539-542`, in source:

> *"P0-2(b): black-hole a lazy cell while it is being forced so a non-productive self-reference
> (`xs = 1 :: xs`; **top-level nullary bindings are LAZY** and `::` is STRICT, so forcing `xs`
> re-forces `xs`) is caught as a clean coded E-CYCLIC-VALUE instead of self-forcing to a
> stack-overflow crash."*

The full machinery is present and named: `VThunk`, `forceCell` (`:545`), `forceMemo` (`:550` —
*"read a cell, forcing + memoising a deferred thunk on first access"*), `blackholeCell` (`:559`).

**⇒ The correct statement of #553, which no document currently makes:**

> **Top-level nullary bindings are LAZY. That is the language, it is decided doctrine, and the
> reference engine implements it with thunks + memoization + black-holing. BOTH BACKENDS
> IMPLEMENT A DIFFERENT LANGUAGE — eager initialization — and `orderedValBinds` /
> `topoSortValBinds` are a static approximation of laziness that is UNSOUND in exactly the cases
> where the dependency is not syntactically visible.**

This is why **eval is the only correct engine in all five instances** — §1.1, §1.2, §1.3, §1.4,
§9.1. Not luck, not a coincidence: **it is the only engine running the specified semantics.**

**F1 therefore is not "which design do we prefer" but "how long do we ship a backend that
implements a different language than the spec and the reference engine?"** Stage A + Stage B
narrow the gap; **only thunks (§5.1) close it.** The honest answer for 0.1.0 is still **A + B +
the diagnostic** — but it must be recorded as **a known, bounded deviation with an owner**, not
as "#553 fixed".

### 9.5 New/updated forks from this section

- **F5′ (replaces F5).** Not *whether* to error, but: does the sorts' **unorderable/back-edge**
  set coincide with eval's **black-holed** set? Where they differ, the backends either reject a
  program eval accepts (regression) or accept one eval rejects (residual divergence). **Someone
  must compare the two conditions.** The `E-CYCLIC-VALUE` code, message text, and precedent all
  already exist — **reuse them; do not mint a new code.**
- **F1′.** Record the eager-vs-lazy deviation explicitly. **`WASMGC-DESIGN.md:249-252` already
  scopes the thunk representation** (*"a 0-capture closure forced on first reference; represent
  identically to closures with a forced/value cache field"*) — so the endpoint is designed, only
  unbuilt. Wants an issue and a milestone, not a relitigation.
- **F6 gains a second receipt.** The native spec being silent (§6-F6) is not a filing nit: **two
  false native-side claims** — *"native is unaffected"* (issue body) and *"that is exactly the
  interpreter's recursive-value semantics"* (`llvm_emit.mdk:1414`) — **both survived because
  there is no native document stating this law.** The doc gap has now demonstrably produced two
  wrong beliefs, one of which took down the playground.

### 9.6 Staging impact

- **PR-2 (the diagnostic) is now cheaper and better-founded than PR-3** — the code exists, eval is
  the oracle, and a fixture is `run` vs `build` on `x = x + 1`. **Consider landing it with PR-1.**
- **New fixture, NOT YET BUILT** (Stage B / divergence #5, `x = x + 1`) — an
  `eager_global_self_cycle` fixture (§9.1), name proposed not created —
  ledgerable **today** under the existing `emitter:shared-eager-init` category
  (`test/engine_divergence.txt:121`), no new taxonomy needed. It pins a divergence that is
  currently **completely ungated**.

---

## 10. #561 — LAZINESS (the terminal fix)

**Status: PR-A (native) SHIPPED (#659), PR-B (wasm) SHIPPED (#661) — #561 CLOSED.** Both backends
now classify LAZY value globals identically and raise the coded `E-CYCLIC-VALUE` on the same
cycles, matching eval. §5.1 rejected laziness for 0.1.0 on a *cost* argument (a forced/value-cache
check on every global read). #561 keeps that concern honest with a **fast-path**: only the value
globals that have **no static init order** go lazy; every other value global stays on the
byte-identical eager prologue. This section records the mechanism, the SAFE/LAZY predicate, the
native + wasm encodings, and the PR staging. **PR-C (regression corpus — this change)** adds
cycle-shape fixtures (mutual cycle, dispatch-hidden cycle) to the `diff_compiler_engines.sh`
corpus so a regression to eager init on either backend flips a gate red; see §10.5 and §10.6.

### 10.1 The 3-state cell — a faithful transliteration of eval

eval implements the DECIDED lazy-nullary semantics (`compiler/eval/eval.mdk`): `forceMemo`
(`:550`) black-holes a cell (`blackholeCell` `:559`) while running its thunk, memoises the value,
and a re-entrant force raises `E-CYCLIC-VALUE`. The native backend mirrors this **exactly** with a
3-state flag per LAZY global:

- value cell stays a uniform i64: `@mdk_g_x = global i64 0` (globals are NOT boxed — `0` is a
  legal Int, so the state cannot ride the value word);
- **separate** state flag `@mdk_gs_x = global i8 0` — `0` UNFORCED / `1` FORCING / `2` FORCED;
- `define i64 @mdk_force_x()` switches on the flag:
  - `2` FORCED → return the memoised `@mdk_g_x`;
  - `1` FORCING → re-entered mid-init ⇒ `call void @mdk_cyclic_value(ptr @.gname.x)` (the
    black-hole; `@mdk_cyclic_value` is a new emitter-emitted runtime primitive in
    `runtime/medaka_rt.c`, beside `mdk_slice_oob` — flush stdout, print
    `runtime error [E-CYCLIC-VALUE]: <name> refers to itself during initialization …`, exit 1);
  - `0` UNFORCED → set FORCING, emit the rhs body via the ordinary `emitExpr`, store the value,
    set FORCED, return.
- a read of a LAZY global lowers to `call i64 @mdk_force_x()` instead of `load i64, @mdk_g_x`
  (the split is at `lookupVarG`, `compiler/backend/llvm_emit.mdk`); a read of a SAFE global inside
  a force body is a plain `load` (the SAFE dep is already eager-initialised — see 10.2).

### 10.2 The SAFE/LAZY fast-path predicate (`emit_support.lazyGlobalNames`)

Reusing the #553 Stage-B machinery (`eagerCalleesMap` + `tarjanSCCs`), a value global is **LAZY**
iff, over the eager `CVar`/`CDict` call graph, it reaches EITHER:

- an interface-method **DISPATCH** (`CMethod`) in eager position (`eagerHasMethod`) — the resolved
  impl body can read an arbitrary later global the sort cannot see (repro #4); OR
- a value **CYCLE** — a nontrivial SCC, or a self-loop `x = x + 1` (repro #5) — which has no eager
  order at all.

The taint is a least fixpoint over the SCC-condensed graph, folded in the reverse-topological
order tarjanSCCs emits (callees before callers) — the same shape and the same cycle-safety as
`foldReachSCCs`. **Everything else is SAFE and stays byte-identical eager.**

**Why it is conservative-and-sound.** A wrongly-SAFE global is a silent miscompile (the #553 bug
class), so any doubt resolves to LAZY. The taint is **downward-closed over reads**: if SAFE `a`
eagerly read LAZY `l`, then `a` reaches `l`'s taint and would itself be LAZY — contradiction. So a
SAFE global's entire eager reach is SAFE, which is exactly what lets the eager prologue (over the
SAFE globals only, in the unchanged topo order) run to completion **without ever calling a force
function**, and be byte-identical whenever the LAZY set is empty.

### 10.3 ⚠️ Measured reality — the fast path is NOT free on the compiler

The compiler's parser is written in point-free **`do`-block** style, and a `do` desugars to an
eager `andThen` (`>>=`) — a `CMethod`. So **167 of the compiler's own value globals classify LAZY**
(`parseExpr`, `skipNewlines`, `identNameP`, … the whole combinator ladder). They are all
*false positives* in the sense that their resolved impl (`@mdk_impl_Parser_andThen`) reads no later
global — but the conservative predicate cannot know that without resolving dispatch to impl bodies
(the deferred F2 work). Consequences, all measured on this change:

- **Correctness: intact.** Self-compile fixpoint **C3a YES / C3b YES**; the lazy-ified compiler
  reproduces its own IR byte-for-byte and compiles every fixture correctly.
- **Emitted IR: +~1.1%** (the force fns + state-flag decls).
- **Self-compile emit wall-time: ~+3–5%** (min-of-k, interleaved: BASE 11.77 s vs WIP 12.16 s
  emitting the CLI). Modest, and ~negligible against the clang-bound full `make medaka`. NOT a
  perf S1, but NOT "flat" either — the fast-path premise "the compiler's globals are statically
  orderable" is **false** because of pervasive monadic dispatch.
- **The clean way to restore the fast path is F2** (Stage B following `CMethod` → resolved-impl
  edges): a `CMethod` whose impl reaches no value global would then add no taint, dropping the LAZY
  set to genuine cycles only (≈0 compiler globals). That is a strictly additive follow-up — the
  3-state mechanism, the encoding, and the gates are untouched.

### 10.4 Split-emit (#118) correctness

In `MEDAKA_EMIT_HALF` split mode the PROGRAM half owns `@mdk_program_main` and defines every
`@mdk_g_*`; the PRELUDE half only declares them. Force functions follow the same rule: **defined in
the program/whole half** (with the init logic), **declared** in the prelude half (`declare i64
@mdk_force_x()`), and `@mdk_gs_x` is `external` in the prelude half / defined in the program half —
symmetric with `@mdk_g_x`. The lazy set is installed (even empty) at **every** `emitProgram` entry,
so a prior program's classification can never leak across a same-process re-emit (the
`installKnownFnMap` discipline; the native analogue of the reset-path stale-memo hazard).

### 10.5 Staging

- **PR-A SHIPPED (#659): NATIVE.** 3-state lazy globals + fast-path; drains the native arm of
  `llvm/eager_global_self_cycle` (`na:ne…` → `na:eq…`) and adds
  `llvmT/eager_global_dispatch_hidden` (repro #4, native 0 → 42).
- **PR-B SHIPPED (#661): WASM.** The same mechanism on `wasm_emit.mdk` (WasmGC has a native
  forced/value-cache field per `WASMGC-DESIGN.md:249-252`). Fully drains the two ledger rows —
  both `llvm/eager_global_self_cycle` and `llvmT/eager_global_dispatch_hidden` now show `nw=eq`
  with native and wasm agreeing (both raise the coded `E-CYCLIC-VALUE` / print the same value).
- **PR-C SHIPPED (this change): regression corpus.** Rather than a bespoke parity-gate script,
  landed as fixtures in the EXISTING `diff_compiler_engines.sh` three-engine differential (which
  already runs `eval == native == wasm` on the shared `llvm_fixtures`/`llvm_fixtures_typed`
  corpora — see test header §"Three tiers"): a MUTUAL-cycle fixture
  (`llvm/eager_global_mutual_cycle`, the two-node sibling to the self-cycle repro) and a
  DISPATCH-HIDDEN-cycle fixture (`llvmT/eager_global_dispatch_hidden_cycle`, a CMethod-routed
  self-reference — the cyclic sibling to the ordering-only `eager_global_dispatch_hidden`). Both
  ledgered `eval:intended-abort` in `test/engine_divergence.txt` for the same structural reason as
  the original self-cycle row (the eval-arm classifier records ANY interpreter `E-*` as `na`, so
  `en`/`ew` stay `na` while `nw=eq`) — that is the gate's permanent, by-design signature for an
  `E-CYCLIC-VALUE` fixture, not a residual gap. §10.6 records the scalar-mode reachability
  question this staging note left open.

### 10.6 Scalar-mode wasm emit: N/A for lazy globals (verified, not just waved off)

PR-B wired the 3-state force mechanism (§10.1's transliteration) into `wasm_emit.mdk`'s **ref**
emit path only — `emitScalarInit`/`emitScalarProgram` (the OTHER wasm output shape, used when a
program needs none of ref-mode's uniform `(ref eq)` representation) has no knowledge of
`lazyGlobalNames`, no `$force_<name>` functions, and still eagerly initializes every value global
in topo order, exactly as it did before #561. A conformance reviewer flagged this during PR-B
review: is a LAZY global that reaches scalar mode a live gap?

**No — verified unreachable, not just argued.** Mode selection is a single boolean,
`useRef = useClos || programUsesAdt … || isNonEmptyList impls || useStrRef.value || …`
(`compiler/backend/wasm_emit.mdk:905`, computed once per program before either emit path
runs) — `emitScalarProgram` only ever runs when `useRef` is `False`. Walk what makes a global
LAZY at all (§10.2 — reaches a `CMethod` in eager position, OR sits in a value cycle):

- **Dispatch-reaching LAZY.** A `CMethod` occurrence requires an `interface`/`impl` pair to exist
  in the elaborated program, i.e. `impls` is non-empty — `isNonEmptyList impls` alone forces
  `useRef = True`. Structurally cannot reach scalar mode.
- **Cyclic LAZY.** A cycle with no operation on it at all (`x = x`) does not typecheck at the
  program's top level (`Ambiguous instance for Display` — nothing pins the auto-print type), so it
  never reaches emit. Every genuine cyclic fixture in this corpus (`eager_global_self_cycle`,
  `eager_global_mutual_cycle`, and the dispatch-hidden cycle) closes over some typeclass-dispatched
  operation (`+`, `mk`) to typecheck at all, which pulls in the operation's `impl` (`Num Int`, or
  the fixture's own `interface`/`impl`) — same `isNonEmptyList impls ⇒ useRef` argument applies.

**Empirically confirmed, not just derived**: both new PR-C fixtures (§10.5) were built through
the shipping CLI (`medaka build --target wasm --allow-internal`) and both raise `E-CYCLIC-VALUE`
via the `$force_<name>` black-hole (2026-07-18, this worktree) — the only path that could ever
produce that output, since `emitScalarInit` has no such call at all. So: **no lazy global reaches
`emitScalarInit`/`emitScalarProgram` via `medaka build --target wasm`, today or by any change that
keeps the LAZY predicate as-is** — the concern is closed by construction, not by absence of a
counterexample. A fixture that would *regress* this is not addable without inventing a way to make
a global LAZY without any `impl` in the program, which the LAZY predicate (§10.2) does not permit;
if that predicate ever changes to admit a non-dispatch, non-typeclass cycle source, this section's
reasoning (and the need for a scalar-mode force path) should be re-checked.
