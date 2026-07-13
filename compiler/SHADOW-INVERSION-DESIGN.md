# SHADOW-INVERSION-DESIGN — invert S2: a top-level standalone WINS over a same-named interface method

**Status:** OPEN — design, decision-ready; not implemented. Forks A (make it work, new
clause S9) and D (importers in scope) are DECIDED by the language owner. Its two
prerequisites are now met: S-1 (`RLocal` carries a dict channel) is MERGED, and P0-21
(per-module shadow-hood on the flat path, so a user shadow cannot leak into the prelude)
ships with this PR. **Do not implement the inversion before P0-21 lands** — under
"standalone wins" a leaked prelude occurrence stops mistyping and starts ROUTING, which
would silently miscompile the prelude itself.

Peer of `docs/spec/SHADOW-SEMANTICS.md`. Peer of `SHADOW-SEMANTICS.md`
(which this doc proposes to replace clause-for-clause). All cells below were
**re-observed on this branch** (merged `origin/main` @ `ccdeda9f`) with a `medaka`
built from that source (`FORCE_EMITTER_REBUILD=1 make medaka`), on `check` AND `run`
AND `build`→execute. No cell is taken from a design doc.

---

## 0. THE GATE: compiler/stdlib definer-shadow census — **ZERO change meaning**

**Result: the inversion is a semantic NO-OP for `compiler/` and `stdlib/`.** All five
in-tree definer shadows already route to the standalone today, because none of them is
ever applied to a receiver whose head tycon has an impl of the shadowed interface.

### 0.1 The shadow universe is exactly the prelude

The **only** interfaces in production source are the **22 in `stdlib/core.mdk`**. No
module in `compiler/`, no non-core module in `stdlib/`, and no module in `sqlite/`,
`mq/`, `byteparser/`, or `parsec/` declares an interface. So shadow-hood reduces to:

> `standalone-names ∩ { the 49 prelude method names }`

The 49: `abs add andThen ap append arbitrary bimap compare debug display div empty eq
filter filterMap fold foldMap foldRight fromEntries fromInt from_rep gt gte hash index
isEmpty length lt lte map mapFirst mapSecond max maxBound min minBound mul negate
noMatch orElse pure sequence setIndex shrink signum sub toList to_rep traverse`.

### 0.2 The complete census (whole tree, `test/` + `archive/` excluded)

| # | `file:line` | Standalone | Shadowed | Receiver head at every call site | Impl of shadowed iface at that head? | Route TODAY | Route under STANDALONE-WINS | Changes? |
|---|---|---|---|---|---|---|---|---|
| 1 | `compiler/frontend/parser.mdk:221` | `orElse : Parser a -> Parser a -> Parser a` | `Alternative.orElse` | `Parser` (all 33 uses) | **No** — `parser.mdk:78` declares only `impl Mappable Parser` | `RLocal` | `RLocal` | **NO** |
| 2 | `stdlib/map.mdk:158` | `isEmpty : Map k v -> Bool` | `Foldable.isEmpty` | `Map` | **No** — `map.mdk` has Index/Mappable/Eq/Ord/Debug/Display/Semigroup/FromEntries/Monoid, deliberately **no `Foldable`** | `RLocal` | `RLocal` | **NO** |
| 3 | `stdlib/map.mdk:347` | `toList : Map k v -> List (k, v)` | `Foldable.toList` | `Map` (`:436`, `:445`, `:454`, `:471`) | **No** | `RLocal` | `RLocal` | **NO** |
| 4 | `stdlib/hash_map.mdk:63` | `isEmpty : HashMap k v -> Bool` | `Foldable.isEmpty` | `HashMap` (`:64`) | **No** — `hash_map.mdk` has only Eq + Debug | `RLocal` | `RLocal` | **NO** |
| 5 | `stdlib/hash_map.mdk:220` | `toList : HashMap k v -> List (k, v)` | `Foldable.toList` | `HashMap` (`:221`) | **No** | `RLocal` | `RLocal` | **NO** |
| 6 | `tests/stdlib/list.mdk:1,5,13` | `map` / `filter` / `length` | Mappable/Filterable/Foldable | — | — | **never compiled** | — | **DORMANT** |

**Row 6 is dead legacy.** `tests/stdlib/` is not referenced by the `Makefile` or by any
gate; the file has no type signatures (`export map f xs = …`), which today's
`rule-missing-signature` lint would reject. Last touched at Phase 16. It would be three
definer shadows *if* anything compiled it. **Recommend deleting it** in Stage 1 — it is
a landmine that costs nothing to defuse.

### 0.3 Importer shadows: **ZERO**

Every `import` in `compiler/`, `stdlib/`, and `sqlite/` is **selective**, and none of
them imports a standalone whose name collides with a prelude method:

* `compiler/support/ordmap.mdk:8` — `import map.{Map(..), set, get, has, size, delete}` — does **not** import `isEmpty`/`toList`.
* `compiler/ir/dce.mdk:37` — `import hash_map.{HashMap, new, set, has, findWithDefault}` — same.
* `stdlib/json.mdk:36` — `import core.{Eq, Debug, Display, Option, Result, Thenable, map}` — `map` here is the **method**, not a standalone. Not a shadow.

The only three **bare** imports in the tree are `import array` (`stdlib/json.mdk:38`,
`sqlite/lib/recordenc.mdk:68`, `sqlite/lib/recordfmt.mdk:30`). `stdlib/array.mdk`
defines **no** standalone colliding with a prelude method — its `length`/`isEmpty`/
`toList`/`map`/`filter` all come from `impl Foldable Array` / `impl Mappable Array` /
`impl Filterable Array`. So `import array` brings in no shadow.

### 0.4 Corroboration (this is not just my reasoning)

The compiler's own source already asserts this conclusion, in two places:

* `compiler/types/typecheck.mdk:7273` — *"The existing definer shadows (map/hash_map `toList`/`isEmpty`, parser `orElse`) are each applied only to their own type, which has NO impl of the shadowed interface, so they still resolve RLocal."*
* `compiler/backend/llvm_emit.mdk:3555` — *"our OWN 5 definer shadows (map/hash_map `toList`/`isEmpty`, parser `orElse`)…"*

And the stdlib **depends** on the standalone winning today. `stdlib/map.mdk:454`:

```medaka
export impl Debug (Map k v) requires Debug k, Debug v where
  debug m = "fromList \{debug (toList m)}"
```

If `Foldable.toList` won here the element type would be `v`, not `(k, v)`, and the
gated doctest `debug (fromList [(1, 10)])` would print the wrong thing. It doesn't.

`stdlib/hash_map.mdk:210-213` is the smoking gun in the other direction — the author
**working around** today's S2:

> *"Named `entries`, not `toList`: `toList` is a `Foldable` method (returning `List v`), so an internal use of `toList` would be shadowed by the method and mistyped (`List v` vs the pairs `List (k, v)`). `toList` below is a thin exported alias, never used [internally]."*

Under standalone-wins that workaround becomes unnecessary. (Leave it; it is harmless.)

### 0.5 GATE VERDICT

> **GREEN. Zero of the five change meaning. The self-compile fixpoint is not at risk
> from the census.** The risk to the fixpoint lies entirely elsewhere — see §1.

---

## 1. 🛑 THE ACTUAL BLOCKER (not in the brief): the flat path leaks shadows into the PRELUDE

This is the finding that gates the project, and it is **not** what the brief expected.

### 1.1 Reproduced

```medaka
-- pmap2.mdk — `map` is DEFINED and NEVER USED.
map : Int -> Int
map n = n + 1

main = println "hello"
```

`medaka check pmap2.mdk` → **14 errors**, all located at `1:0` (the shadow's own
signature line), including:

```
pmap2.mdk:1:0: 'map' takes 1 argument(s) but is applied to 2.
pmap2.mdk:1:0: Type mismatch: Int vs a -> b -> c
pmap2.mdk:1:0: Type mismatch: Int vs List a -> List a
pmap2.mdk:1:0: Type mismatch: Int vs a -> Unit
```

Nothing in the user's file applies `map` to two arguments. **Those call sites are the
PRELUDE'S OWN BODIES** — `map2`, `map3`, `replaceWith`, `discard`, the `Filterable`
default. The user's standalone is being typed into the prelude.

### 1.2 It is single-file-only. The multi-module path is clean.

Same shadow, in a 3-module project:

```medaka
-- helper.mdk           -- other.mdk
export map : Int -> Int  export doubled : List Int
map n = n + 1            doubled = map (x => x * 2) [1, 2, 3]
export bump : Int
bump = map 1
```

→ `run` prints **`2 [2, 4, 6]`**. `helper`'s `bump = map 1` took the **standalone** (2),
`other`'s `map` took the **method** ([2,4,6]), and the prelude is untouched. **Per-module
shadow-hood (S1) genuinely holds on the multi-module path.**

### 1.3 Why

* **Multi-module:** `checkModuleFullImpl` (`typecheck.mdk:11199-11201`) seeds `definerShadowNamesRef` **per module**, and `core` is checked in **isolation**. Prelude bodies never see a user shadow.
* **Flat / single-file:** `checkProgramSeeded` (`typecheck.mdk:9314`) does
  `setRef definerShadowNamesRef (buildDefinerShadows prog prog)` where `prog = core ++ user`.
  The *set* is correct (core's methods live in `DImpl`, not `funDefs`, so only genuine
  user shadows are collected) — but the set is then applied to **every occurrence in the
  flattened program, core's included**. `definerShadowVarHead` (`:5243`) fires on any
  `EVar "map"` anywhere, so `inferDefinerShadowVarApp` → `groundShadowReceiver` forces
  the prelude's receiver to the user's declared domain.

Two ad-hoc patches contain the damage today, and both are stand-ins for the missing
module boundary:

1. **`methodShadowNamesRef` + `dropSchemesNamed`** (`:9307`, `:9334`, `:10867`) — keeps user schemes out of the env threaded into prelude impl/default/prop/test bodies. The source comment calls itself the *"FLAT-PATH SHADOW FIX"*.
2. **`definerReceiverIsDictVar`** (`:5276`) — an ungrounded receiver that is a dict-bound constraint var **dispatches**. The header of `test/run_check_agreement_fixtures/accept_constrained_receiver_shadow.mdk` states the stakes plainly:

   > *"The same bug, via the PRELUDE's own `neq : Eq a => a -> a -> Bool` (`neq x y = not (eq x y)`), made ANY program with a top-level `eq`/`compare` fail to compile."*

### 1.4 Why this is a BLOCKER for the inversion, not just a pre-existing wart

Today a leaked prelude occurrence with a **grounded, live-impl** receiver still
**dispatches** — so the leak is only a *typing* leak, and it only bites where the arities
differ (which is why `map` explodes and `eq`/`display` do not: `println 42` still prints
`42`; `elem 9 [1,2,3]` still returns `False`, both verified).

**Invert S2 and that same leaked occurrence ROUTES to the user's standalone.** The
prelude's `println` would call the user's `display`. `elem` would call the user's `eq`.
`map2` would call the user's `map`. That is a silent miscompile of the prelude, on the
single-file path — which is also the path `medaka test` doctests use.

> **STAGE 0 IS MANDATORY AND MUST LAND FIRST: make shadow-hood truly per-module on the
> flat path. A prelude occurrence is NEVER a shadow.**

---

## 2. S-1: not landed, and a HARD PREREQUISITE (brief's premise refuted; its thesis confirmed)

### 2.1 S-1 has **not** landed on `main`

```
$ git merge-base --is-ancestor ee0593bd origin/main   →  NO
$ grep -n RLocal compiler/frontend/ast.mdk            →  72:  | RLocal String
```

`ee0593bd` ("S-1: a CONSTRAINED standalone shadowing an interface method was silently
miscompiled") exists only on branch `worktree-agent-a491549792b032a64`. `main`'s
`ast.mdk:72` is still the nullary-payload `RLocal String`, **not** `RLocal String (List
Route)`. The brief's "the fix that JUST LANDED" is not true of `main`.

S-1's bug reproduces on `main` exactly as filed:

```medaka
interface Sz a where { size : a -> String }
impl Sz Box where { size (Box n) = "box" }
size : Num a => a -> a
size n = n + 1
main = println (debug (size 3))
```
`check`: **green** · `run`: `E-PANIC: intToString: not an Int` · `build`: prints
**`70002786729968`**, **exit 0**.

### 2.2 CONFIRMED — S-1 becomes *more* load-bearing. In fact it is a prerequisite.

Today `RLocal` is a **fallback**: it fires only when the receiver's head has **no** impl
of the shadowed interface. A constrained standalone shadow whose receiver *does* have an
impl therefore never takes `RLocal`, and never hits S-1's missing-dict bug.

Under standalone-wins, **`RLocal` is the route for every definer-shadow occurrence** —
live-impl receivers included. So every constrained standalone shadow now takes the
`RLocal` path, and every one of them hits S-1's bug.

> **Inverting S2 without S-1 converts today's `check`-green dispatch cells into
> garbage-pointer miscompiles.** S-1 must merge before the inversion. Not "should".

### 2.3 S1-RESIDUAL-A — **partially REFUTED on `main`**

S-1's residual note claims:

> *"an **unconstrained** shadow (`size : Int -> Int`) in value position segfaults identically, and that takes the `dicts == []` path — byte-identical to pre-S1 codegen."*

**That is false on `main`.** `test/shadow_fixtures/d4_definer_value_pos.mdk` is exactly
that program (`size : Int -> Int`, `map size [1, 2, 3]`). On `main`, with a binary built
from `main`:

```
run   → [2, 3, 4]
build → [2, 3, 4]    exit 0
```

What *does* segfault on `main` is the **constrained** value-position shadow
(`size : Num a => a -> a` + `map size [1,2,3]`):

```
build → GC Warning: Failed to expand heap by 183634873808 KiB
        runtime error [E-FATAL-SIGNAL]: fatal memory fault (segmentation fault)   exit 139
```

So on `main`, RESIDUAL-A is **the same missing-dict root as S-1**, manifesting in value
position — which is not an application, so S-1's app-site fix does not reach it. It is
**not** an independent `emitMethodValue`-arity bug.

> ⚠️ **Action for the owner, before S-1 merges:** either S-1 *introduced* an
> unconstrained-value-position segfault (a regression against `d4`, which is green on
> `main`), or its residual note mis-verified. Both are cheap to settle — run `d4` on the
> S-1 branch. Do not merge S-1 on the assumption that `d4` was already broken.

**Interaction with standalone-wins:** value position **already** denotes the standalone
(S4), so the inversion neither creates nor changes this cell. But it multiplies the
*exposure*: every shadow name in value position now takes the standalone-with-no-dict
path. → **Not subsumed. Not worsened in kind. Substantially worsened in exposure.**

### 2.4 S1-RESIDUAL-B — worse on `main` than filed; orthogonal under the recommended fork

Reproduced on `main` (importer shadow, constrained standalone, ungrounded literal
receiver):

```
check → green      run → E-PANIC: debugStringLit: not a String
build → 70066829922288   exit 0        ← a SILENT MISCOMPILE, not "build correct"
```

S-1's note says *"`build` and `wasm` are correct (4); `run` still under-applies"* — that
is true **of the S-1 branch**, where S-1's fix repairs `build`. On `main` `build` is
garbage. S-1 therefore *improves* this cell; the residual is the leftover `run` half.

* Under **Fork A (definer-only inversion — recommended)**: importer shadows keep S2 per-receiver → RESIDUAL-B is **untouched, orthogonal**. Fix it on its own schedule (`inferShadowApp` is missing the P0-20 `groundShadowReceiver` call that `inferDefinerShadowApp` has).
* Under **Fork B (total inversion)**: every importer shadow becomes `RLocal` → RESIDUAL-B's under-application becomes the **default path for every importer shadow**. **Catastrophic.** This is an independent argument for Fork A.

---

## 3. The new spec — S1–S9 under standalone-wins

Changed clauses are marked **[CHANGED]**. Everything else is carried over verbatim so
the two docs can be diffed.

* **S1 (shadow-hood). [CHANGED — tightened]** `N` is a **definer shadow** in module `M`
  iff `N` ∈ funDef-names(`M`) ∩ iface-method-names(visible interfaces), and `N` is not
  bound by a local pattern at the occurrence. **Shadow-hood is per-module, per-name, and
  the PRELUDE IS A MODULE**: a `core.mdk` occurrence of `N` is never a shadow of a user
  standalone, on *any* path (flat or multi-module). `N` is an **importer shadow** in `M`
  iff `N` is an *imported* standalone that names a visible interface method.

* **S2 (applied — THE INVERSION). [CHANGED]** A **definer** shadow `N` applied to any
  receiver denotes **the standalone, unconditionally** (`RLocal`). The impl universe is
  **not consulted**. The argument must type against the standalone's declared domain; a
  mismatch is a **located reject** at `check` (and at `run`/`build`, which typecheck
  first). *A visible impl of the shadowed interface at the receiver's head no longer
  overrides the standalone — this is the inversion.*

  An **importer** shadow keeps the old per-receiver rule: live impl at the receiver head
  → method dispatch (`RKey`); no impl → the standalone (`RLocal`). **[Fork 1 — see §6.]**

* **S3 (N-way). [CHANGED]** Vacuous for definer shadows: every occurrence is the
  standalone regardless of receiver. A receiver at a live-impl head is a **located
  reject**, not a dispatch. (Unchanged for importer shadows.)

* **S4 (value position).** Unchanged, and now *consistent with* S2 rather than an
  exception to it: a bare shadow name denotes the **standalone, always**. Under the old
  S2 this was the one place lexical shadowing already won; under the new S2 it is simply
  the general rule.

* **S5 (ungrounded receiver). [CHANGED — narrowed]** A definer shadow applied to a
  receiver that never grounds routes to the **standalone**, and the enclosing function
  **monomorphises to the standalone's declared domain**. **Carve-out (Fork 2):** a
  receiver that is a **dict-bound `=>` constraint variable of the enclosing function**
  **dispatches** — the written constraint is an explicit request for dispatch.
  (`definerReceiverIsDictVar`, `typecheck.mdk:5276`.) **[Fork 2 — see §6.]**

* **S6 (module-independence). [CHANGED]** For a **definer** shadow the impl query is
  *deleted*, so S6 is trivially satisfied: where the interface and impl live cannot
  change the outcome, because the outcome does not depend on them. For an **importer**
  shadow S6 stands as written.

* **S7 (path agreement).** Unchanged and still binding: `run`, `check` and `build` agree
  on every cell. **⚠️ Note what S7 costs you:** because it *guarantees* the three engines
  agree, no differential gate can ever see a shadow bug. The `eq` bug was invisible to
  every gate the project owns, **by construction**. The regression tests for this change
  must therefore assert on **printed values against a pinned expectation**
  (`run_check_agreement`'s `.out` pin, added in P0-20), never on cross-path agreement.

* **S8 (arity).** Unchanged in *intent*, but see §7 Stage 3: `singleParamIfaceMethod`
  gates the whole machinery on interface **type-param count**, so a multi-typaram
  interface (`interface Ix a i`) bypasses it entirely. Under standalone-wins that gap
  means a definer shadow of an `Index`/`IndexMut`/`FromEntries` method silently keeps
  the OLD semantics. That is now an **inconsistency**, not merely a gap.

* **S9 (dicts — from S-1, retained and promoted).** *"The shadowed interface decides
  WHICH function; the standalone's own constraints decide WHICH DICTS."* An `RLocal`
  route carries the standalone's own constraint slots (`RLocal String (List Route)`).
  Under standalone-wins this clause moves from a corner case to **the common path**.

### 3.1 Tie-break rationale (replaces the old one)

The old rationale — *"a live impl is the ground truth of intent"* — is exactly the
premise being rejected. The new one:

> **A name written at top level in a module is that module's name.** The prelude defines
> ~49 method names over every common type; a user cannot be expected to know them, and
> `medaka check` cannot tell them. Silently discarding a declared, signatured top-level
> function because a *prelude* impl exists for the argument's type is not a tie-break —
> it is erasure. The stdlib fallback pattern (`map.mdk`'s `toList` beating `Foldable`'s)
> is not a *special case* of the old rule; it is the **general case** of the new one.

---

## 4. Decision matrix — the new expected outcomes

Baseline column = **observed on this branch** (build from merged `main`). Delta column =
specified under standalone-wins, Fork A + Fork 2 carve-out.

| # | Cell | Fixture | run/build TODAY | **UNDER STANDALONE-WINS** | Delta |
|---|---|---|---|---|---|
| 3 | definer · no-impl recv | `d1_definer_noimpl` | `4` | `4` | — |
| 4 | definer · zero-impl iface | `d1b_definer_noimpl_zeroimpls` | `4` | `4` | — |
| 5 | definer · **live-impl recv** | `d2_definer_liveimpl` | `3`, `4` | **REJECT** `Type mismatch: Int vs Box` @ `size (Box 3)`; `size 3` → `4` | **FLIPS** |
| 6 | definer · **N-way** | `d3_definer_nway` | `3`, `30`, `4` | **REJECT** ×2 (`Box`, `Crate`); `size 3` → `4` | **FLIPS** |
| 7 | definer · **parametric-head impl** | `d6_definer_parametric_receiver` | `9`, `4` | **REJECT** @ the `P a` receiver; `4` | **FLIPS** |
| 8 | definer · two-param method | `d7_definer_multiparam_method` | `3`, `6` | **REJECT** @ `comb (Box 1) (Box 2)`; `comb 2 3` → `6` | **FLIPS** (needs Stage 3 — see S8) |
| 9 | definer · value pos · no-impl elems | `d4_definer_value_pos` | `[2, 3, 4]` | `[2, 3, 4]` | — |
| 10 | definer · value pos · live-impl elems | `d4b_definer_value_pos_liveimpl` | REJECT `Int vs Box` | REJECT `Int vs Box` | — |
| 11 | definer · ungrounded recv · wrapper at standalone domain | `d5_definer_poly_receiver` | `4` | `4` | — |
| 12 | definer · ungrounded recv · wrapper at live-impl type | `d5b_definer_poly_liveimpl_call` | REJECT | REJECT | — |
| 13 | definer · no-impl · domain mismatch | `d9_definer_reject` | REJECT `Int vs String` | REJECT | — |
| 14 | definer · **iface+impl IMPORTED** | `d8_definer_imported_impl/` | `3`, `4` (dispatches — P0-19 batch 2) | **REJECT** @ `size (Box 3)`; `4` | **FLIPS** (undoes P0-19 batch 2's row-14 fix) |
| 15–18 | **importer** · live/no-impl · local/third-module iface | `i1_…`, `i3_…` | `3` / `4` | **unchanged** | — |
| 19–20 | **importer** · prelude iface (`import map` shape) | `i4_importer_prelude_iface/` | `True,False,False,True` | **unchanged** | — |
| — | **definer** · dict-bound (`=>`) receiver | `accept_constrained_receiver_shadow` | `14` (dispatches) | `14` (Fork 2 carve-out) — **or REJECT under strict** | **FORK 2** |
| — | **NEW** · user `eq` vs prelude `Eq` (the bug) | *(new fixture)* | `False` ← **the standalone is ERASED** | **`True`** | **THE POINT** |
| — | **NEW** · prelude internals survive a user `display`/`eq`/`map` | *(new fixture)* | `42` / `False` / **14 spurious errors for `map`** | `42` / `False` / **clean** | **Stage 0** |

**Five fixtures flip: `d2`, `d3`, `d6`, `d7`, `d8`.** All five flip from *dispatch* to
*located REJECT*. All five are currently **ACCEPT** cells, so the flip is loud, not
silent. `d8`'s flip **reverts** the P0-19-batch-2 row-14 fix — that fix made a definer
shadow dispatch cross-module, which is precisely what the inversion abolishes. Say so in
the commit; do not let it look like a regression.

**Nothing that is a REJECT today becomes an ACCEPT.** The change is monotonically
*more* rejecting for definer shadows — which is what makes it safe.

---

## 5. How is the interface method still reachable? (Q5 + Q6) — **it mostly ISN'T, and that is a gap**

### 5.1 Other modules: fine. Verified.

Shadow-hood is per-module (`S1`), and I verified this empirically on the multi-module
path (§1.2): `helper.mdk`'s standalone `map` did **not** stop `other.mdk` from using
`Mappable.map`. Code that does not define a colliding standalone is unaffected. ✅

### 5.2 The prelude's own internals: fine **on the multi-module path**, BROKEN on the flat path.

Verified: with a user `display : Int -> String`, `println 42` still prints `42`; with a
user `eq`, `elem 9 [1,2,3]` still returns `False`. But a user `map` produces 14 spurious
errors from prelude bodies (§1.1). **Stage 0 closes this. It is not optional.** ✅ after Stage 0.

### 5.3 The SAME module: there is **no escape hatch**, except operators.

| Route | Works? | Evidence |
|---|---|---|
| **Operators** (`==`, `!=`, `<`, `+`, `++`, …) | **YES** | Verified: a module with `impl Eq Foo` *and* `eq : List Int -> List Int -> Bool` still evaluates `Foo 1 == Foo 2` → `False`, `Foo 1 == Foo 1` → `True`. Operators desugar to the method-call path and never touch the bare-`EVar` funDef intersection (matrix row 24 — "UNREACHABLE"). This covers `Eq`/`Ord`/`Num`/`Semigroup`. |
| **Module alias** — `import core as C` → `C.eq` | **NO** | `Unbound variable: C.eq` |
| **Member alias** — `import core.{eq as eqM}` → `eqM` | **NO** | `Unbound variable: eqM. Did you mean 'eq'` |
| **Interface-qualified** — `Eq.eq x y` | **NO** | no such syntax |

So under standalone-wins, a module that defines `toList`/`isEmpty`/`map`/`display`/
`debug`/`pure`/`traverse`/`fold`/… **loses the ability to call that method by name, for
every type, inside that module.** For the five in-tree shadows this costs nothing (none
of them needs the method). For a user it is a real cliff.

**Recommendation (Stage 4, follow-up, not a blocker):** make
`import core.{eq as eqM}` work. The member-alias machinery **already exists and is
gated** — `test/eval_modules_fixtures/import_alias/` aliases a *user* interface's method
(`import shapes.{area as areaOf}`) and its own header explains the subtlety ("a method is
global-by-name … so it is in NO module's export list"). The prelude is simply not
reachable as an importable module for aliasing. Extending it is a contained change to
`resolve.mdk`'s import handling, reusing tested machinery, and needs **no new syntax**.
Until then, the answer for a user is: **rename your function** — and the Stage 2 warning
(§8) tells them to.

### 5.4 Q6 — an `impl` in the SAME module as the standalone

The impl's method is still **installed and dispatched normally for every other module**,
and inside its own module it is reachable **via the operator** if the interface is
operator-backed (verified above). For a non-operator interface it is reachable only from
outside the module, or after §5.3's alias work lands.

**This is a genuine sharp edge of the decision and the owner should see it stated
plainly**, because it is the one thing "true lexical shadowing" costs that the old rule
did not.

---

## 6. DESIGN FORKS — needs a human decision

### FORK 1 — does the inversion apply to **importer** shadows too? **RECOMMEND: NO (definer-only).**

`SHADOW-SEMANTICS.md` §0/§1 defines shadow-hood over **both** kinds. The brief says "a
top-level standalone function must WIN" without distinguishing.

**If importer shadows also win**, `test/shadow_fixtures/i4_importer_prelude_iface/`
breaks — verified green today (`True False False True`):

```medaka
import prov.{Tok(..), isEmpty}     -- prov.isEmpty : Tok -> Bool
main =
  println (isEmpty (Tok 0))        -- True   ← standalone
  println (isEmpty [1, 2])         -- False  ← the prelude METHOD, on a List
```

Under total inversion, `isEmpty [1, 2]` calls `prov.isEmpty : Tok -> Bool` on a `List`
→ **REJECT**. That is the everyday `import map` / `import hash_map` pattern, and it
would break every consumer that imports one of those modules unselectively and then uses
a Foldable method on anything else. It would also make S1-RESIDUAL-B the default path for
every importer shadow (§2.4).

**Recommendation: DEFINER-ONLY.** It is also the principled reading of *lexical*
shadowing: a module's own top-level binding is an **inner** scope relative to the implicit
prelude and therefore shadows it; an `import` is a **sibling** scope and does not. This
preserves rows 15–20 exactly and fixes the bug that motivated the change.

### FORK 2 — dict-bound (`=>`) receiver in the shadowing module: dispatch or standalone? **RECOMMEND: DISPATCH (keep the carve-out).**

```medaka
sz : Int -> Int          -- the definer shadow
sz n = n + 1
twice : Sz a => a -> Int -- an explicit constraint
twice x = sz x + sz x    -- x is dict-bound.  Dispatch, or the standalone?
```

Today this **dispatches** (`accept_constrained_receiver_shadow` → `14`), via
`definerReceiverIsDictVar`. Strict lexical shadowing says **standalone** → `a := Int` →
`twice True` rejects.

**Recommend keeping the carve-out (dispatch).** The `Sz a =>` is a *written-down*, explicit
request for dispatch — the user has said, in the signature, "resolve this through the
interface". Removing it would make generic code unwritable in any module that shadows a
method name, with no escape hatch (§5.3). It is a deviation from a purist reading, so it
needs the owner's explicit blessing, and it must be spelled out in S5.

⚠️ **Do NOT decide this by deleting the carve-out and seeing what breaks** — until Stage 0
lands, that carve-out is also what stops the **prelude's own `neq x y = not (eq x y)`**
from monomorphising to a user's `eq`. Order matters: Stage 0 first, *then* Fork 2 is a
free choice.

### FORK 3 — should the collision warn, and how loudly? **RECOMMEND: WARN. See §8.**

### FORK 4 — `d8` / row 14 reverts a fix that shipped two days ago.

P0-19 batch 2 (`ebb8ee90`) *deliberately* made a definer shadow dispatch to a
cross-module impl (row 14: "now DISPATCHES cross-module (run+build print `3`,`4`,
matching d2)"). The inversion **undoes that**. This is correct — that fix implemented the
old S2 faithfully — but it is a visible reversal of recent, intentional work and the
owner should confirm they want it. **RECOMMEND: yes, revert it; it is the old rule.**

---

## 7. Should the collision warn? **YES — recommend `W-SHADOWS-METHOD`, severity=warning.**

Standalone-wins makes the outcome *correct*, but it does not make it *obvious*. A user
who names a function `map` and gets lexical shadowing has still done something they
almost certainly did not intend, and the failure mode moves from "silently wrong answer"
to "confusing rejection three modules away".

**Recommendation — one warning, at the definition, not at each use:**

```
W-SHADOWS-METHOD  (severity 2 / warning)

foo.mdk:1:0: warning: 'eq' shadows the interface method 'Eq.eq' from the prelude.
             Inside this module 'eq' now always means your function; 'Eq.eq' is
             reachable only through the '==' operator.
  help: rename this function (e.g. 'eqList') if you meant to use 'Eq.eq' here.
  |
1 | eq : List Int -> List Int -> Bool
  | ^
```

Rationale and fit:
* The `W-*` infrastructure exists and is idiomatic (`W-NONEXHAUSTIVE`,
  `W-UNREACHABLE-ARM`, `W-GUARD-INEXHAUSTIVE`, `W-MAIN-SHAPE`), carries `severity: 2` +
  a real `range` + `help` through `--json` (`compiler/DIAGNOSTIC-CODES-DESIGN.md`), and
  is surfaced by the LSP. Adding a code is a two-line change plus a taxonomy row.
* **One per definition** — not per occurrence. `parser.mdk` has 33 `orElse` uses.
* It must be a **warning, not an error**: the five in-tree shadows are all *deliberate*,
  and `map.mdk`'s `toList` is a documented, load-bearing design choice.
* **Suppressible** via the existing `-- lint-disable-…` directive family if it is
  implemented as a lint rule instead. **Recommend the typecheck warning** (it needs the
  interface-method universe, which the linter does not have), plus a
  `-- lint-disable`-style escape if the owner wants one.
* ⚠️ **The five in-tree shadows will fire it.** They need `-- lint-disable-next-line`-style
  suppression or the gate goes red on the compiler's own source. Budget for that in
  Stage 2.

---

## 8. Staged implementation plan — ascending risk, independently gated

Hot-file contention is called out per stage. `typecheck.mdk`, `eval.mdk`,
`llvm_emit.mdk`, `wasm_emit.mdk` all have other work landing.

| Stage | What | Files | Risk | Gates | Parallel? |
|---|---|---|---|---|---|
| **−1** | **Land S-1.** Hard prerequisite (§2.2). Verify `d4` on the S-1 branch first (§2.3) — settle whether S-1 regressed the unconstrained value-position cell. | *(S-1's branch)* | — | `run_check_agreement`, fixpoint | **BLOCKS ALL** |
| **0** | **Per-module shadow-hood on the flat path.** A prelude occurrence is never a shadow. Concretely: partition the flat `prog` into `core`-sourced and user-sourced decls, and gate `definerShadowVarHead` / `definerShadowArgHead` / `recordRLocalSite` on the occurrence's owning module — not just on the *name*. Once this holds, `methodShadowNamesRef`/`dropSchemesNamed` become redundant scaffolding (leave them; delete in a later cleanup). | `compiler/types/typecheck.mdk` (`:9295-9345` seeding, `:5243` `definerShadowVarHead`, `:4969` `definerShadowArgHead`, `:3456` `recordRLocalSite`) | **MEDIUM** — one hot file, but a pure *narrowing*: fewer occurrences are shadows. | NEW fixtures: user `map`/`display`/`eq` + prelude internals, on all 3 paths. `diff_compiler_check*`, `medaka test` (doctests use this path!), `typecheck_compiler_source`, fixpoint | **SERIAL** (must precede Stage 1) |
| **1** | **Delete `tests/stdlib/list.mdk`** (dormant `map`/`filter`/`length` shadows, §0.2 row 6). Zero-risk hygiene; unblocks nothing but removes a future landmine. | `tests/stdlib/list.mdk` | **NIL** | — | **PARALLEL with everything** |
| **2** | **`W-SHADOWS-METHOD` warning** (§7), + suppression on the 5 in-tree shadows. Ship this **before** the inversion so users get the warning on the *old* semantics too, and so the compiler's own suppressions are already in place when Stage 3 lands. | `compiler/types/typecheck.mdk` (emit), `compiler/DIAGNOSTIC-CODES-DESIGN.md`, `compiler/frontend/parser.mdk` + `stdlib/{map,hash_map}.mdk` (5 suppressions) | **LOW** | `diff_compiler_check*`, `check_json`, `error_quality`, LSP | **PARALLEL with Stage 0** (different code region; expect a trivial merge in typecheck.mdk) |
| **3** | **THE INVERSION.** In `resolveRLocalSite` (`typecheck.mdk:7265`) and `stampRLocalOrFallback` (`:7285`): drop the `implExistsForHead` query for **definer** shadows — unconditionally stamp `RLocal`. In `inferDefinerShadowVarApp` (`:5254`) and `inferDefinerShadowApp` (`:5029`): delete the dispatch arm (keep the Fork-2 dict-var arm). Importer paths (`inferShadowApp`, `shadowStandaloneHead`) **untouched** (Fork 1). Also lift the `singleParamIfaceMethod` gate (S8) so multi-typaram interfaces don't silently keep the old rule. | `compiler/types/typecheck.mdk` **only** — the routes (`RKey`/`RLocal`) and their consumers (`eval.mdk:1063`, `llvm_emit.mdk:3413/3435`, `wasm_emit.mdk:3076`, `core_ir_lower.mdk:144`) already handle both arms. **Neither emitter nor eval should need a line.** | **HIGH** — but *contained to one file*, and the change is a **deletion** (removing a query), which is the good kind. | `d2`/`d3`/`d6`/`d7`/`d8` re-blessed to REJECT; NEW `eq`-bug fixture; `run_check_agreement` (with `.out` value pins — §S7); `selfcompile_fixpoint` **C3a/C3b**; `typecheck_compiler_source`; `diff_compiler_engines` | **SERIAL** after Stage 0 |
| **4** | **Re-open the method** — make `import core.{eq as eqM}` resolve (§5.3). Removes the sharp edge. | `compiler/frontend/resolve.mdk` (import/alias handling) | **LOW-MED** | `eval_modules_fixtures/import_alias`, `diff_compiler_resolve*` | **PARALLEL** with Stage 3 |
| **5** | **Rewrite `SHADOW-SEMANTICS.md`** from §3/§4 of this doc; wire `test/shadow_fixtures/` into a real gate (it is *still* gated by nothing — §4 of the current spec). | `SHADOW-SEMANTICS.md`, `test/diff_compiler_run_check_agreement.sh` | **NIL** | — | after Stage 3 |

**Emitter/eval touch: expected ZERO.** Both `RKey` and `RLocal` arms already exist and are
exercised on every path (`llvm_emit.mdk:3413`/`:3435`, `wasm_emit.mdk:3076`,
`eval.mdk:1063-1066`). The inversion only changes **which arm typecheck stamps**. That is
why Stage 3, despite being the semantic change, touches one file — and it is the strongest
argument that this design is right.

### Sequencing summary

```
S-1 (branch)  ──►  Stage 0  ──►  Stage 3  ──►  Stage 5
                      │             ▲
   Stage 1 ───────────┼─────────────┤   (parallel, any time)
   Stage 2 ───────────┘             │
   Stage 4 ──────────────────────────   (parallel with 3)
```

### The one thing that will bite

**`selfcompile_fixpoint.sh` (C3a/C3b) is the decisive gate for Stage 3**, and the census
(§0) says it should pass unchanged — the compiler's own five shadows do not move. If it
*doesn't* pass, the cause is **Stage 0's** module boundary, not the inversion: the
compiler is built through the **multi-module** path (clean today), but the doctest and
single-file paths are not, and `medaka test` runs the stdlib's doctests through the flat
path. **Run `make test` (in-language suite) as well as the fixpoint on Stage 0.**
