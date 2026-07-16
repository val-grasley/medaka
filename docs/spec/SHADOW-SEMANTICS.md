# Declaration-Shadowing Semantics (standalone fn ⇄ interface method)

**Status:** ENFORCED — the decision matrix is a GATE
(`test/diff_compiler_shadow_semantics.sh`): it runs every fixture in
`test/shadow_fixtures/` through `check` + `run` + `build`, asserting each cell's
verdict AND (per **S7**) that `run` and the built binary print the same pinned
value. Every cell is conformant except **S-3** (row 26, multi-typaram interface),
which is pinned as a KNOWN-BAD ledger row so it fails the day it is fixed. Until
this gate existed the corpus below **ran nowhere**, and the matrix's own Status
column had silently gone stale in the OK direction (see the note under §2).
**Scope:** a bare name `N` that is BOTH a top-level standalone function AND an
interface-method name (a "shadow"). Peer of `DICT-SEMANTICS.md` /
`LAYOUT-SEMANTICS.md`: clauses S1–S9, a gated decision matrix, and a per-stage
enforcement table. Where the binary disagrees with a clause, the matrix row says
**BUG** — the spec is the target, not a description of present behavior.

> ## ⚡ 2026-07-14 — **S2 IS INVERTED: A TOP-LEVEL STANDALONE WINS.**
>
> A standalone function defined in a module now **beats** a same-named interface
> method **inside that module**, unconditionally. **The impl universe is no longer
> consulted for a definer shadow.** This replaces the old S2 ("a live impl at the
> receiver's head dispatches; the standalone is only a no-impl fallback").
>
> **The bug that forced it** — and it is not a corner case:
>
> ```medaka
> eq : List Int -> List Int -> Bool
> eq a b = True
> main = println (debug (eq [1] [2]))    -- printed False. THE USER'S FUNCTION WAS IGNORED.
> ```
>
> `check` passed. `run` and `build` **agreed** — both wrong the same way — and
> `check --types` did not even report the user's signature. The function was not
> shadowed, it was **erased**, because `List` has a prelude `impl Eq List`. By **S1**
> shadow-hood is `standalones ∩ iface-method-names` *and the interface may be the
> prelude*, so **~45 of the most natural names in the language were landmines**:
> `map`, `filter`, `length`, `compare`, `eq`, `min`, `max`, `abs`, `empty`, `index`,
> `append`, `fold`, `toList`, `display`, `debug`, `pure`, `traverse`, …
>
> ⚠️ **And the compiler was obeying this spec.** The old S2 said dispatch; the
> compiler dispatched. **The SPEC was the bug** — which is why the fix is a spec
> change, and why **no differential gate could ever have caught it**: by **S7** the
> three engines agree on every shadow cell *by construction*, and they did.
>
> **The new tie-break.** *A name written at top level in a module is that module's
> name.* The prelude declares 49 method names over every common type; a user cannot
> be expected to know them and `check` could not tell them. Silently discarding a
> declared, signatured top-level function because a **prelude** impl exists for the
> argument's type is not a tie-break — it is erasure. The stdlib's own fallback
> pattern (`map.mdk`'s `toList` beating `Foldable.toList`) is not a special case of
> the old rule; it is the **general case** of the new one.
>
> **Two deliberate limits** (both decided by the language owner, both load-bearing):
> - **Definer-only.** An **imported** standalone does **not** shadow — an `import` is
>   a *sibling* scope, not an *inner* one. Total inversion would break the everyday
>   `import map` pattern (row 20: `isEmpty [1,2]` must still reach `Foldable.isEmpty`).
> - **The `=>` carve-out stays.** A call on a **dict-bound** (`Sz a =>`) receiver still
>   **dispatches**: writing the constraint is an explicit request for dispatch, and it
>   is the only way to reach the method by name inside a shadowing module (§1.1).
>
> **What moved:** five cells went ACCEPT → **located REJECT** (rows 5, 6, 7, 8, 14 —
> `d2`, `d3`, `d6`, `d7`, `d8`), each now `Type mismatch: Int vs <receiver>` at the
> call site on all three paths. **Nothing that rejected became an accept**, except
> `p0_20_shadow_literal_result_pinned`, whose reject existed *only* as a side effect
> of the method stealing the call. Row 14 (`d8`) **deliberately reverts** `ebb8ee90`
> (P0-19 batch 2), which had made a definer shadow dispatch cross-module — that fix
> faithfully implemented the OLD S2, and the inversion abolishes the rule it
> implemented. Design: `compiler/SHADOW-INVERSION-DESIGN.md`.

**Why this exists.** This one rule produced four bugs in four different stages
(P0-18 arc: typecheck routing `953d9ea1`, mangle/mark ordering `0b4a7882`,
scheme selection → SIGSEGV, cross-module registration `cfc4fa5a`) because each
stage made its own keying assumption about the same rule (§3 makes those keys
explicit). Fixtures: `test/shadow_fixtures/` (one per matrix cell), run by
`test/diff_compiler_shadow_semantics.sh` — see §4. History/context: memory
`project_phase112_standalone_vs_method`, `qa-beta-2026-07-07/P0-18-*.md`.

## 0. Terminology

- **Shadow**: bare name `N` naming both a standalone top-level fn and an
  interface method visible at the call site.
- **Definer shadow**: the standalone is defined in the *call site's own module*
  (in-tree: `stdlib/map.mdk` + `stdlib/hash_map.mdk` `toList`/`isEmpty`,
  `compiler/frontend/parser.mdk` `orElse` — all applied only to no-impl
  receivers, all route standalone).
- **Importer shadow**: the standalone is *imported* from another module (the
  everyday `import map` → `isEmpty m` pattern; the shadowed interface may live
  in the prelude, in the consuming module, or in a third module).
- **Routes** (`compiler/frontend/ast.mdk:69-72`): `RKey tag dicts` = dispatch to
  the impl whose head tycon is `tag`; `RLocal sym dicts` = NOT a dispatch, call
  the standalone (`sym` = the mangled standalone symbol on the build path, `""`
  on the un-mangled run/check path). **`dicts` is the standalone's OWN
  `=>`-constraint dicts** — see clause **S9**. It is `[]` for an unconstrained
  standalone, which is every one of the compiler's own definer shadows.
  ⚠️ Until 2026-07-13 this document, `ast.mdk` and `eval.mdk` all asserted
  *"RLocal carries no dict"* as a settled **invariant**. That invariant WAS the
  S-1 silent miscompile: it is now false by design. Do not restore it.

## 1. The resolution function (clauses S1–S8)

Given an occurrence of bare name `N`:

- **S1 (shadow-hood).** `N` is a shadow iff `N` ∈ funDef-names(visible
  standalones) ∩ iface-method-names(visible interfaces). `N` is a **definer
  shadow** in module `M` iff the standalone is defined **in `M`**; an **importer
  shadow** iff it is *imported* into `M`. The *interface* may live anywhere
  (local, imported, prelude). Shadow-hood is per-module, per-name — not
  per-occurrence — and **the PRELUDE IS A MODULE**: a `core.mdk` occurrence of `N`
  is never a shadow of a user standalone, on *any* path, flat or multi-module
  (P0-21; before it, a user's `map` leaked into the prelude's own bodies). A name
  bound by a **local pattern** at the occurrence is not a shadow there — lexical
  scope resolves it to the binder.

- **S2 (applied — THE INVERSION).** **[CHANGED 2026-07-14]**

  - A **definer** shadow `N` applied to any receiver denotes **the standalone,
    unconditionally** (`RLocal`). **The impl universe is NOT consulted.** The
    argument must type against the standalone's declared domain; a mismatch is a
    **located reject** at `check` (and at `run`/`build`, which typecheck first).
    *A visible impl of the shadowed interface at the receiver's head no longer
    overrides the standalone — **this is the inversion.*** (Carve-out: S5's
    dict-bound receiver.)

  - An **importer** shadow keeps the **old per-receiver rule**: if any impl of the
    shadowed interface for the receiver's head tycon `T` is visible (the impl
    universe is GLOBAL — local ∪ imported ∪ prelude; instances are coherent across
    modules, cf. `DICT-SEMANTICS.md`) → **method dispatch** (`RKey T`); else → the
    standalone (`RLocal`), with the same domain obligation. An `import` is a
    *sibling* scope, not an *inner* one, so it does not shadow.

- **S3 (N-way).** **[CHANGED]** **Vacuous for a definer shadow:** every occurrence
  is the standalone regardless of receiver, so no receiver selects an impl; a
  receiver at a live-impl head is a **located reject**, not a dispatch. The impls
  remain installed and still dispatch N-way — from any module that does not shadow
  the name, and, inside the shadowing module, through a written `=>` constraint
  (S5's carve-out). Unchanged for importer shadows. (Gated: `d3_definer_nway`,
  `definer_shadow_nway`.)

- **S4 (value position).** A shadow name NOT syntactically applied to its
  receiver (passed to a HOF, bound with `let`, sectioned) denotes the
  **standalone, always** (Phase 112: a method value has no receiver to dispatch
  on). Consequently value-position use over live-impl elements whose type
  mismatches the standalone's domain is a **located reject** — never a silent
  dispatch, never a runtime panic. *Unchanged, and now **consistent with** S2
  rather than an exception to it: under the old S2 this was the one place lexical
  shadowing already won; under the new S2 it is simply the general rule.*

- **S5 (ungrounded receiver).** **[CHANGED — narrowed]** A definer shadow applied
  to a receiver that never grounds (a polymorphic parameter) routes to the
  **standalone**, and the enclosing function **monomorphises to the standalone's
  declared domain** — it must NOT generalize over the shadow's receiver (a
  generalized wrapper later called at a live-impl type would run the standalone on
  a foreign value). Calling such a wrapper outside the standalone's domain is a
  located reject.

  **⭐ CARVE-OUT (the one dispatch a definer shadow still permits):** a receiver
  that is a **dict-bound `=>` constraint variable of the enclosing function**
  **DISPATCHES**. Writing `Sz a =>` is an explicit, written-down request to resolve
  through the interface, and — for a non-operator interface — it is the **only** way
  to name the method inside a shadowing module (§1.1). Removing it would make
  generic code unwritable in any module that shadows a method name.
  (`definerReceiverIsDictVar`; gated: `accept_constrained_receiver_shadow` → `14`,
  and `definer_shadow_nway`, which dispatches N-way through exactly this channel.)

- **S6 (module-independence).** **[CHANGED]** For a **definer** shadow the impl
  query is *deleted*, so S6 is **trivially satisfied**: where the interface and impl
  live cannot change the outcome, because the outcome no longer depends on them. An
  all-local live impl (`d2`) and an imported one (`d8`) now reject identically. For
  an **importer** shadow S6 stands as written: the impl query is
  location-independent, and where the standalone/interface/impl each live changes
  *detection bookkeeping*, never the outcome.

- **S7 (path agreement).** `run`, `check`, and `build` agree on every cell:
  `check` accepts iff `run` and the built binary produce the (identical)
  defined value. A shadow cell where they disagree is a conformance bug even if
  each path is individually defensible.

  > ⚠️ **Note what S7 COSTS you.** Because it *guarantees* the three engines agree,
  > **no differential gate can ever see a shadow bug** — the `eq [1] [2]` erasure was
  > invisible to every gate the project owns, **by construction**, and P0-20 even
  > "fixed" that cell by making all three paths agree on the *wrong* answer. Tests for
  > this rule must assert on **printed values against a pinned expectation**
  > (`run_check_agreement`'s `.out` pin; the shadow gate's `value` column), **never**
  > on cross-path agreement alone.

- **S8 (arity).** The per-receiver machinery in typecheck is gated to
  single-**typaram** interfaces (`singleParamIfaceMethod`), but the *specified*
  outcome for a multi-**param** *method* shadow is the same S2 rule keyed on the
  first parameter — and under the inversion that means the standalone wins there too
  (row 8 / `d7` now rejects its live-impl receiver). ⚠️ A multi-**TYPARAM**
  *interface* (`interface Ix a i`) still bypasses the machinery entirely and keeps
  the OLD semantics — that is the open **S-3** bug (row 26), and under the inversion
  it is now an **inconsistency**, not merely a gap.

### S9 — a CONSTRAINED standalone (added 2026-07-13; closes S-1)

When S2/S4/S5 resolve a shadow occurrence to **the standalone**, and that
standalone is itself `C a => …`, the occurrence is an **ordinary constrained
call**: `C` is solved at the receiver's type and the dictionary is supplied at
the call site, exactly as at a non-shadow call site. **`RLocal` therefore DOES
carry dicts** (`RLocal sym dicts`, mirroring `RKey tag dicts`).

> **The shadowed interface decides WHICH function; the standalone's own
> constraints decide WHICH DICTS. They are different interfaces.**

A `C` with no impl at the receiver's type is a **located reject at `check`**
(`No impl of Num for String` for `size "hi"`), never a runtime panic.

**Why this clause exists.** Both halves of dict-passing key off the same name
sets, and a constrained shadow is in **both**: the marking prePass is a
first-match guard chain whose *shadow* arm is tested **before** the *dict* arm
(`typecheck.mdk` `rewriteRPDict` / `rewriteRPDictArg` / `rewriteArgScoped`), so
the occurrence became `EMethodAt` and was **never marked as a dict application**
— while `dictPassDecl`, keyed on the same dict-name set, still gave the
**definition** its leading dict parameter. Def arity 2, call arity 1: the call
silently **under-applied**, the first real argument landed in the dict slot, and
`build` **exited 0 printing a raw heap pointer**.

**Do NOT "fix" this by reordering the guard chain so the dict arm wins.**
`EDictAt` carries no route and cannot dispatch — that would break matrix row 5
(`size (Box 3)` → the impl), which works. A shadow occurrence is genuinely
*undecided* at mark time; `EMethodAt` is the node that can be either. The fix is
to give its `RLocal` arm a dict channel.

**Tie-break rationale.** **[REPLACED 2026-07-14 — the old rationale is the premise
the inversion rejects; kept below, struck, because it is the argument you will
re-derive if you don't see why it fails.]**

> ~~*Per-receiver* (not lexical shadowing) because **a live impl is the ground truth
> of intent** — the user wrote a method for that exact type; unconditional lexical
> shadowing was the pre-`953d9ea1` behavior and mis-ran `size (Box 3)` on the
> standalone.~~

**Why that fails.** It silently assumes the impl is *the user's*. Almost always it
is the **PRELUDE's** — `impl Eq List`, `impl Mappable List`, `impl Foldable Option`
— and a user who writes `eq`, `map`, or `length` has expressed no intent about it
whatsoever. "The ground truth of intent" turned into "the prelude outranks you, and
we will not tell you." The `size (Box 3)` case that motivated the old rule is real
but is the *rare* one; it is now a **located reject**, which is the honest answer:
the module said `size` means `Int -> Int`, so a `Box` does not fit.

**The rule now.** *A name written at top level in a module is that module's name.*
A module's own top-level binding is an **inner** scope relative to the implicit
prelude and therefore **shadows** it; an `import` is a **sibling** scope and does
not. The stdlib's `map.mdk`-`toList`-beats-`Foldable.toList` pattern is not a
special case of the old rule — it is the **general case** of the new one.

*Standalone-in-value-position = standalone* (S4) still holds for the original
reason: dispatch needs a receiver at the call and a method value carries no
evidence (no dict is threaded at value position on the arg-tag path) — the
standalone is the only coherent denotation. Under the new S2 it is no longer an
exception; it is just the rule.

### 1.1 Reaching the interface method from INSIDE a shadowing module

Under the inversion, a module that defines `toList` / `map` / `eq` / `display` / …
**cannot call that method by its bare name, for any type, anywhere in that module.**
That is the deliberate cost of true lexical shadowing, and it is the one thing the
new rule takes away that the old one gave. What still works:

| Route | Works? | Notes |
|---|---|---|
| **Operators** (`==`, `!=`, `<`, `+`, `++`, …) | **YES** | They desugar through the method-call path and never touch the bare-name funDef intersection (row 24, UNREACHABLE). A module with `impl Eq Foo` *and* a standalone `eq` still evaluates `Foo 1 == Foo 2` correctly. Covers `Eq`/`Ord`/`Num`/`Semigroup`. |
| **A written `=>` constraint** (S5 carve-out) | **YES** | `sizeOf : Sizeable a => a -> Int ; sizeOf x = size x` dispatches — including N-way. For a non-operator interface this is the **only** in-module route. Gated by `definer_shadow_nway`. |
| **Any other module** | **YES** | Shadow-hood is per-module (S1). A module that does not define a colliding standalone is completely unaffected — including the prelude's own bodies (P0-21). |
| **Module alias** — `import core as C` → `C.eq` | **NO** | `Unbound variable: C.eq` |
| **Member alias** — `import core.{eq as eqM}` → `eqM` | **NO** | `Unbound variable: eqM. Did you mean 'eq'` |
| **Interface-qualified** — `Eq.eq x y` | **NO** | No such syntax. |

**Recommended follow-up (not a blocker):** make `import core.{eq as eqM}` resolve.
The member-alias machinery already exists and is gated
(`test/eval_modules_fixtures/import_alias/` aliases a *user* interface's method);
the prelude is simply not reachable as an importable module for aliasing. It is a
contained change to `resolve.mdk`'s import handling and needs **no new syntax**.
Until then the answer for a user is: **rename your function.**

## 2. Decision matrix (re-observed 2026-07-14, post-`eb92cdff`; now GATED)

Axes: shadow kind × receiver impl-status × topology × use form. "Outcome" is
the S1–S9-specified result; **Status** is what the binary actually does on all
three of run / build / check. Fixtures in `test/shadow_fixtures/`.

> ⚠️ **This column used to be STALE, and that is the reason the gate exists.**
> From 2026-07-10 to 2026-07-14 rows 10 / 12 / 13 / 14 read **BUG** while the
> binary was in fact conformant on all four — P0-19 and P0-20 had fixed them,
> and this table was never updated even though the §5 change-log a few
> paragraphs below *said so*. A spec that says BUG where the binary says OK
> sends the next agent down a wrong hypothesis; that is exactly what it did.
> Every Status below is now re-observed empirically **and enforced by
> `test/diff_compiler_shadow_semantics.sh`**, which drives every fixture
> through `check` + `run` + `build` and pins the value. This column can no
> longer drift without a gate going red.

| # | Cell (kind · receiver · topology · use) | Clause | Specified outcome | Fixture | run | build | check | Status |
|---|---|---|---|---|---|---|---|---|
| 1 | not a shadow — standalone only | S1 | ordinary call | — (whole tree) | — | — | — | BASELINE |
| 2 | not a shadow — method only | S1 | ordinary dispatch | — (construct-coverage gates) | — | — | — | BASELINE |
| 3 | definer · no-impl recv (impl exists for another type) · 1-file · applied | S2 | RLocal → 4 | `d1_definer_noimpl.mdk` | 4 | 4 | accept | **OK** |
| 4 | definer · no-impl recv (interface has ZERO impls) · 1-file · applied | S2 | RLocal → 4 | `d1b_definer_noimpl_zeroimpls.mdk` | 4 | 4 | accept | **OK** |
| 5 | definer · live-impl recv · 1-file · applied | S2 | **REJECT** `Int vs Box` @ `size (Box 3)`; `size 3` → 4 | `d2_definer_liveimpl.mdk` | reject | reject | reject | **OK** (**FLIPPED 2026-07-14** — was `3,4` (dispatch). The inversion: the module's own `size : Int -> Int` takes the call, so `Box` mistypes) |
| 6 | definer · N-way (2 impls + no-impl) · 1-file · applied | S3 | **REJECT** ×2 (`Box`, `Bar`); `size 3` → 4 | `d3_definer_nway.mdk` | reject | reject | reject | **OK** (**FLIPPED** — was `3,30,4`. S3 is now VACUOUS for a definer shadow: no receiver selects an impl. The impls still dispatch N-way through a `=>` dict — see `definer_shadow_nway`) |
| 7 | definer · live impl at PARAMETRIC head (`impl … (P a)`) · applied | S2 | **REJECT** `Int vs P Bool` @ the `P a` receiver; 4 | `d6_definer_parametric_receiver.mdk` | reject | reject | reject | **OK** (**FLIPPED** — was `9,4`. A parametric impl head is no more privileged than a concrete one) |
| 8 | definer · TWO-param method shadow · applied | S8 | **REJECT** `Int vs Box` @ `comb (Box 1) (Box 2)`; `comb 2 3` → 6 | `d7_definer_multiparam_method.mdk` | reject | reject | reject | **OK** (**FLIPPED** — was `3,6` via ordinary arg-dispatch. Multi-*param methods* now follow S2 like everything else; multi-*TYPARAM interfaces* still do NOT — row 26 / S-3) |
| 9 | definer · value position · no-impl elements · **method/standalone arity EQUAL** | S4 | standalone → [2, 3, 4] | `d4_definer_value_pos.mdk` | [2,3,4] | [2,3,4] | accept | **OK** — ⚠️ arity-EQUAL, so this row is **blind to S1-RESIDUAL-A (#410)**; rows 9a/9b/9c are the arity-DIFFERING cells |
| 9a | definer · value position · **method arity 2 / standalone arity 1** · annotated result | S4 | standalone → [2, 3, 4] | `d13_definer_value_pos_arity_differ.mdk` | [2,3,4] | [2,3,4] | accept | **OK** (**FIXED 2026-07-16 #410** — was `build` exit 0 printing PAP heap pointers as Ints, an S0 silent wrongness; see §6 S1-RESIDUAL-A (A)) |
| 9b | definer · value position · arity-differing · **ZERO impls** of the iface | S2+S4 | standalone → [2, 3, 4] | `d15_definer_value_pos_arity_differ_zeroimpls.mdk` | [2,3,4] | [2,3,4] | accept | **OK** (**FIXED 2026-07-16 #410** — proves the impl universe is irrelevant: shadow-hood + arity mismatch + value position suffice) |
| 9d | definer · value position · **method arity 1 / standalone arity 2** (opposite direction) · annotated | S4 | standalone → 3 | `d16_definer_value_pos_arity_differ_opposite.mdk` | 3 | 3 | accept | **OK** (**FIXED 2026-07-16 #410** — pins the other side of the route-derived arity) |
| 9c | definer · value position · arity-differing · **UNANNOTATED** result | S4 | standalone → [2, 3, 4] | `d14_definer_value_pos_arity_differ_unannot.mdk` | [2,3,4] | accept, **binary SEGFAULTs** | accept | ❌ **KNOWN-BAD (#410 (B), open)** — `println`'s `Display` requirement gets a NULL element dict (RNone route). NOT the emitter: the route is stamped in `types/typecheck.mdk`. Pinned `BUILD_CRASH` (self-draining) |
| 10 | definer · value position · LIVE-impl elements | S4 | located REJECT | `d4b_definer_value_pos_liveimpl.mdk` | reject `Int vs Box` | reject | reject | **OK** (fixed P0-19 batch 2 `ebb8ee90`; was a 3-way split) — ⚠️ also arity-EQUAL |
| 11 | definer · ungrounded recv · wrapper used at standalone domain | S5 | 4; wrapper : Int -> Int | `d5_definer_poly_receiver.mdk` | 4 | 4 | accept (but `useIt : a -> Int` — over-general, the row-12 hole) | **OK** (value), caveat on scheme |
| 12 | definer · ungrounded recv · wrapper CALLED at live-impl type | S5 | located REJECT | `d5b_definer_poly_liveimpl_call.mdk` | reject `Int vs Box` | reject | reject | **OK** (fixed P0-19 batch 1 `ef0874f3`; was a silent miscompile) |
| 13 | definer · no-impl recv · domain mismatch (`size "hi"`) | S2 | located REJECT | `d9_definer_reject.mdk` | reject `Int vs String` | reject | reject | **OK** (fixed P0-19 batch 1 `ef0874f3`; was check-over-accept → build garbage) |
| 14 | definer · live impl, interface+impl IMPORTED · applied | S6 | **REJECT** `Int vs Box` @ `size (Box 3)`; 4 | `d8_definer_imported_impl/` | reject | reject | reject | **OK** (**FLIPPED 2026-07-14 — DELIBERATELY REVERTS `ebb8ee90`** (P0-19 batch 2), which made this dispatch cross-module. That fix faithfully implemented the OLD S2; the inversion abolishes the rule it implemented. S6 now holds VACUOUSLY — the impl universe is never queried, so *where* the impl lives cannot matter. Rejects identically to the all-local `d2`, which is the point. Also re-pinned in `diff_compiler_check_cli_modules`'s `definer-shadow-xmod` leg) |
| 15 | importer · live impl · interface LOCAL to consumer | S2/S6 | RKey → 3 | `i1_importer_local_iface/` | 3 | 3 | accept | **OK** |
| 16 | importer · no-impl recv · interface LOCAL | S2/S6 | RLocal → 4 | `i1_importer_local_iface/` | 4 | 4 | accept | **OK** |
| 17 | importer · live impl · interface+impl in a THIRD module | S6 | RKey → 3 | `i3_importer_imported_iface/` | 3 | 3 | accept | **OK** |
| 18 | importer · no-impl recv · third-module interface | S6 | RLocal → 4 | `i3_importer_imported_iface/` | 4 | 4 | accept | **OK** |
| 19 | importer · no-impl own type · PRELUDE interface (the stdlib shape) | S2 | standalone → True/False | `i4_importer_prelude_iface/` | T,F | T,F | accept | **OK** |
| 20 | importer · LIVE prelude impl recv (`isEmpty [1,2]`) alongside the shadow | S2 | method → False/True | `i4_importer_prelude_iface/` | F,T | F,T | accept | **OK** |
| 21 | importer · value position | S4 | standalone | — | — | — | — | UNTESTED-NO-FIXTURE (expected ≡ row 9) |
| 22 | importer · N-way | S3 | per-receiver | — | — | — | — | UNTESTED-NO-FIXTURE (expected ≡ row 6) |
| 23 | return-position method shadow (no receiver param, e.g. `pure`-like) | S4 | value-position rule → standalone | — | — | — | — | UNTESTED-NO-FIXTURE |
| 24 | operator-named shadow (`==` etc.) | — | n/a — operator occurrences resolve through the desugared method-call path, not bare-`EVar` funDef intersection | — | — | — | — | UNREACHABLE |
| 25 | definer · **CONSTRAINED** standalone (`size : Num a => a -> a`) · no-impl recv | S9 | RLocal **carrying the standalone's dicts** → 4 | `d10_definer_constrained.mdk` | 4 | 4 | accept | **OK** (fixed 2026-07-13, S-1 / clause S9; was `check` green + `run` E-PANIC + `build` printing a raw heap pointer) |
| 26 | definer · method of a **multi-TYPARAM interface** (`interface Ix a i`) · applied | S8 (does not cover it) | dispatch 4; standalone 3 | `d11_definer_multityparam_iface.mdk` | **E-PANIC `unknown op '*'`** | 4,3 | accepts | **BUG** (**S-3**; `run` diverges from check+build — an S7 violation. Every entry point gates on `singleParamIfaceMethod`, which counts interface TYPE PARAMS, not method params, so this shadow bypasses the machinery entirely. `check`/`build` happen to be per-receiver CORRECT. Pinned KNOWN-BAD by the gate.) |
| 27 | definer · **UNGROUNDED (numeric-literal) receiver** whose grounded head HAS a live prelude impl | S2+S5 | standalone → 3, 30 | `d12_definer_ungrounded_literal.mdk` | 3,30 | 3,30 | accept | **OK** (the P0-20 cell, now INVERTED: `eq 1 2` = 3, was `False`. `groundShadowReceiver` grounds the literal to the standalone's domain BEFORE the S2 question, so check/run/build ask it about the same head) |
| 28 | **importer** · **UNGROUNDED (numeric-literal) receiver** · prelude iface + the Fork-1 control | S2+S5 | standalone → True, False; **method** → False, True | `i5_importer_ungrounded_literal/` | T,F,F,T | T,F,F,T | accept | **OK** (fixed 2026-07-14, **S1-RESIDUAL-B** — was `Type mismatch: Int literal vs Int Int` on ALL THREE paths, PRE-EXISTING, and invisible to the corpus because i1/i3/i4 all use GROUNDED receivers. The last two lines are the Fork-1 control: an importer shadow still dispatches on a live-impl head) |

**Tally: 21 OK · 1 BUG (row 26 / S-3) · 3 UNTESTED-NO-FIXTURE · 1 UNREACHABLE ·
2 baselines.** Rows 10/12/13/14 were BUG until P0-19; row 25 was BUG until S-1;
**row 28 was BUG until 2026-07-14 (S1-RESIDUAL-B) — and it was PRE-EXISTING, not
introduced by the inversion.** Row 26 is the only open cell, and it is a **loud**
divergence (`run` panics), not a silent wrong answer.

> ⭐ **Rows 27–28 exist because the corpus was blind to an entire AXIS.** Every
> importer fixture used a **grounded** receiver, so the gate graded **18/0 while
> row 28 was broken**. A numeric literal is `Num a => a` — **ungrounded** at
> inference time — so the routing decision is taken before the receiver has a head
> tycon, and the type is then resolved against a receiver that has *since changed*.
> **That is the P0-20 root cause, and it is the root cause of this entire arc.**
> When adding a shadow fixture, vary the receiver's **PROVENANCE** — literal /
> grounded / dict-bound — not just its type. **A gate that cannot express a cell
> cannot defend it.**

> **The 2026-07-14 inversion moved exactly five rows — 5, 6, 7, 8, 14 — all
> ACCEPT → located REJECT.** The change is **monotonically more rejecting** for
> definer shadows, which is what made it safe to land: it cannot turn a rejected
> program into a silently-miscompiled one. (One cell went the other way, outside
> this matrix: `run_check_agreement`'s `p0_20_shadow_literal_result_pinned` REJECT →
> ACCEPT — its reject existed *only* because the method was stealing the call and
> returning a `String` where the annotation said `Int`.)
>
> **Rows 15–20 (importer shadows) and row 26 did NOT move, and must not.** They are
> the Fork-1 boundary and the S-3 ledger row respectively. If either moves, the
> inversion has leaked out of definer scope — `test/diff_compiler_shadow_semantics.sh`
> is the tripwire, and during development it caught exactly that, twice.

**In-tree census (re-verified 2026-07-14, two independent methods).** The whole
tree contains **exactly five** definer shadows, and the inversion is a **semantic
no-op for all five** — none is ever applied to a receiver whose head has an impl of
the shadowed interface, so all five routed `RLocal` before and route `RLocal` now:
`compiler/frontend/parser.mdk:221` `orElse` (46 uses, all on `Parser`; there is no
`impl Alternative Parser`) · `stdlib/map.mdk:158` `isEmpty` + `:347` `toList` (all
on `Map`; there is deliberately no `impl Foldable Map`) · `stdlib/hash_map.mdk:63`
`isEmpty` + `:220` `toList` (all on `HashMap`; same). Every interface in production
source lives in `stdlib/core.mdk` (49 method names), so shadow-hood reduces to
`standalone-names ∩ those 49`. This is why `selfcompile_fixpoint` (C3a/C3b) and
`typecheck_compiler_source` stayed green through the inversion — the compiler does
not depend on the rule that changed. `hash_map.mdk:210`'s comment is a **workaround
for the old rule** ("an internal use of `toList` would be shadowed by the method and
mistyped") — the inversion retires the need for it.

## 3. Per-stage enforcement table (clause → site → keying assumption)

The four P0-18 bugs were each a *disagreement between two rows of this table*.
Line numbers at `cfc4fa5a`.

| Clause | Stage / site | What it enforces | **Keying assumption** |
|---|---|---|---|
| S1 detect (run/check, definer) | `compiler/types/typecheck.mdk:11451` `buildDefinerShadows`; single-file seed `:8979`; per-module seed `checkModuleFullImpl:11199-11201` → `definerShadowNamesRef`/`standaloneValuesRef` | this module's funDefs that name a method | **bare-name intersection**: funDefs(`prog`) × `allIfaceMethodNames(accData ++ implDecls ++ prog)` — sees imported *interfaces* only via `accData` (public decls); see row-14 BUG |
| S1 detect (run/check, importer) | `typecheck.mdk:11422` `buildStandaloneShadows` (seeded `:11191`) | imported standalones shadowing a method | imported funDef names minus local names, methods scanned across `implDecls ++ prog` (the `cfc4fa5a` fix: LOCAL interfaces included) |
| S1 detect (build path) | `typecheck.mdk:11475` `computeMangledShadowMap` + `unitMangledShadows:11480`, set once at `elaborateModules:11932` (`mangledShadowMapRef`); consumed by `buildDefinerShadows:11460` and `buildStandaloneShadowsGraph:11487-11497` | recover shadows AFTER mangling renamed the standalone | **forward-constructs `mangledName mid m`** per (module, method) and checks it against actual funDefs — exact, not prefix-stripping; empty map on the un-mangled path (inert) |
| S1 mark | `typecheck.mdk:11942` `markRpNames` (∪ `buildStandaloneShadowsGraph`) → `prePassDictArg`/`prePassModulePairArg:11943-11944` rewrite occurrences to `EMethodAt` | occurrences get a route ref | graph-wide name set over USER modules (core excluded) |
| (enabler of the S1 build split) | `compiler/backend/private_mangle.mdk`: `mangleUnits:117`, `buildUnitRenameMap:372`, `renameDecl` DFunDef `~578` + `renameScoped` EVar `~651` rename the standalone def + refs to `<mid>__N`; `renameIfaceMethod:626`/`renameImplMethod:636` leave the method **NAME bare** (header `:34-46`: dispatch is by bare name cross-module) | collision-free private symbols | **the asymmetry**: standalone side mangled, method side bare — which is exactly what defeated name-intersection detection (bug `0b4a7882`); driver order `compiler/entries/entry_support.mdk:133-134` (`runEmitWith`) and `:145-146` (`emitModulesWith`): mangle STRICTLY before mark |
| S2 type + record (definer) | app-head peel → `definerShadowArgHead` (gated `singleParamIfaceMethod`; fires on `definerShadowNamesRef` OR a mark-seeded `RLocal sym` — the cross-module emit signal) → `inferDefinerShadowApp` + `definerShadowHeadType`. The un-marked `check` path peels via `definerShadowVarHead` → `inferDefinerShadowVarApp`. **`definerReceiverDispatches` is the single decision point** | **[CHANGED — THE INVERSION]** a definer shadow types against the STANDALONE scheme, **always** (via the mangled sym on build — the scheme-selection SIGSEGV fix); `enforceStandaloneDomain` then imposes its declared domain, so a live-impl receiver is a located reject. The only dispatch arm left is S5's dict-bound receiver | ⚠️ **`definerShadowArgHead` fires for IMPORTER shadows too** — its `routeLocalSym != ""` arm is the cross-module emit signal, so `inferDefinerShadowApp` serves BOTH kinds on the mangled path. "Did we reach this function" is therefore **NOT** the same question as "is this a definer shadow": `definerReceiverDispatches` must re-ask it via `isDefinerShadow` (`definerShadowNamesRef` never holds an imported standalone) or the inversion leaks onto importers and breaks `import map` |
| S2 type + record (importer) | `typecheck.mdk:4950` `shadowStandaloneHead` → `inferShadowApp:4979`; standalone schemes stashed in `shadowStandaloneSchemesRef` (`checkModuleFullImpl:11210`, concrete-head pick); impl query table `shadowKeyTableRef` (`:11217`, includes LOCAL impls per `cfc4fa5a`) | live-impl head ⇒ ordinary app (dispatch); else instantiate the IMPORTED standalone scheme + stamp `RLocal` | standalone scheme = the seedVars entry whose first arrow domain has a **concrete head tycon** (never the poly method scheme) |
| S2 no-impl obligation skip | `typecheck.mdk:4670` `recordImplObligation`, skip arm `:4688` | a no-impl shadow receiver is a legitimate standalone fallback, not `No impl of …` | bare name ∈ `definerShadowNamesRef` ∪ `standaloneValuesRef` — skips the obligation for EVERY occurrence of the name, impl-having or not (this un-checks row 13: the domain mismatch is never re-imposed) |
| S2/S3/S5 route stamping | `recordRLocalSite` (gated on `standaloneValuesRef`, suppressed inside `inferDefinerShadowApp`); `resolveRLocalSites` / `resolveRLocalSite`: **`isDefinerShadow` ⇒ `RLocal sym` unconditionally**, else (importer) grounded head + `implExistsForHead` → leave route (dispatch) else `RLocal sym` (`stampRLocalOrFallback`); ungrounded → `RLocal` for definer shadows; build-path RKey via `pendingArgStamps` push → `resolveArgStamps` | **[CHANGED — THE INVERSION]** route by SHADOW KIND first, receiver second. `resolveArgStamps` runs BEFORE `resolveRLocalSites`, so the `RLocal` stamp wins | ⚠️ **`isDefinerShadow`, not a bare `definerShadowNamesRef` membership test.** That ref is populated for a multi-TYPARAM interface's method too, but every *typing* entry point is gated on `singleParamIfaceMethod` and leaves such an occurrence to ordinary dispatch (open bug S-3 / row 26). Forcing `RLocal` here without the same gate routes a site whose TYPE came from the dispatch path — **route and type disagreeing is precisely the P0-20 bug class.** The two gates must stay identical |
| route representation | `compiler/frontend/ast.mdk:69-72` (`RKey`/`RLocal String`); sexp `compiler/ir/core_ir_sexp.mdk:43-44` (`RLocal ""` serializes to the old nullary form) | ONE occurrence needs TWO names: bare `N` for dispatch, `<mid>__N` for the standalone | the mangled standalone symbol is **carried in the route**, stamped at resolve time (Fork-2 carry-in-route) |
| lowering | `compiler/ir/core_ir_lower.mdk:144` `EMethodAt name … → CMethod name …` | route + both names survive to the backends | `name` is the single bare field; the RLocal symbol rides the route |
| emit (LLVM) | `compiler/backend/llvm_emit.mdk:3413` `emitMethod … (RKey tag)` → `implFor e name tag`; `:3435` `… (RLocal sym)` → `emitKnownFnSat e ("mdk_" ++ sym)` | S2's two arms at codegen | RKey needs the **bare** method name; RLocal needs the **mangled** symbol |
| emit (WasmGC) | `compiler/backend/wasm_emit.mdk:3076` `emitMethodRef … (RLocal sym)` (peer arm, header `:3071`) | same split, second backend | same two-name split |
| eval | `compiler/eval/eval.mdk` `evalMethodAt … (RLocal sym dicts)` → standalone via env lookup, **then `applyDicts … dicts`** (S9); other routes → arg-tag/dict dispatch (`methodAtNarrow` treats RLocal as not-a-dispatch; `dictOfRoute (RLocal _ _)` is the no-op dict — RLocal's dicts are the call's leading dict ARGS, not a witness FOR the route) | S2 + S9 on the interpreter | run path is UN-mangled: `sym` is `""` and the bare name resolves to the standalone lexically |
| S9 dicts (typecheck) | `shadowStandaloneDicts` / `shadowStandaloneDictSlotsAt` (slot monos, expanded-supers, from the SIGNATURE's id space) → carried on `pendingRLocalSites` (an `RLocalSite` record) → resolved **inside** `resolveRLocalSites` via `routesOfMonosTop` | the standalone's own `=>` dicts, stamped by the SAME single writer as the route | ⚠️ resolve them **inside the stamp** — `resolveRLocalSites` runs BEFORE `resolveDictApps` in `elabModuleStamp`, so routing them through `pendingDictApps` reads `[]` and reproduces the bug with more code |
| S9 reject direction | `recordStandaloneSigObligations` → `pushCallObl` → `checkCallObligations` | `size "hi"` ⇒ located `No impl of Num for String` | ⚠️ obligations must come from the **signature**, not `schemeObligationsRef`: for a signatured binding those are **different id spaces** (generalization vs `sigToSchemeTvs`), so the id lookup silently finds nothing |

## 4. The gate (`test/diff_compiler_shadow_semantics.sh`)

**The matrix in §2 is enforced.** One gate owns the whole corpus
(`test/shadow_fixtures/`, 17 fixture units — 13 single-file `.mdk` plus the
`d8`/`i1`/`i3`/`i4` multi-module directories), and for each it drives all three
paths and asserts:

- the **verdict** — `check`, `run`, and `build` each ACCEPT or REJECT exactly as
  the cell specifies; and
- the **value** — for a cell all three accept, `run`'s stdout and the **built
  binary's** stdout must be byte-identical to each other *and* to a pinned
  expectation. This half is not optional: **S7** is a claim about values, and an
  exit-code-only gate cannot see the bug class this arc keeps producing (P0-20:
  `build` exits 0 while printing a wrong number; S-1: `build` exits 0 while
  printing a raw heap pointer). Both would have graded PASS.

Two properties that keep it from rotting:

- **A coverage self-audit.** The gate diffs the fixture directory's actual
  contents against its own table and FAILS if a fixture is ever added without
  being wired in — the orphan-corpus failure this gate was written to end.
- **KNOWN-BAD rows are a ledger, never a skip-list.** An open bug (today: row 26
  / **S-3**) is pinned to its *current, wrong* behavior, so it is asserted on
  every run and goes **red the day it is fixed** — which is the signal to correct
  the row. This is not theoretical: `d10` (row 25) was added as a KNOWN-BAD row
  pinning the S-1 miscompile, S-1 landed, and the gate went red on the next run.

CI: the `types` shard (`.github/workflows/ci.yml`); `diff_compiler_ci_shard_coverage`
enforces that it is in exactly one shard.

Still **UNTESTED-NO-FIXTURE** (rows 21–23): importer value-position, importer
N-way, and a return-position method shadow. Adding those three fixtures is the
next mechanical step — the gate picks them up automatically once a row is added
to its table (and its coverage audit will fail until one is).

## 5. Residuals — HISTORICAL (all four now CLOSED; kept for the repro + root cause)

> **All four cells in this section are FIXED** (P0-19 batches 1–2, 2026-07-10;
> see the update notes at the end of the section). They are kept because the
> repro and the root cause are the useful part — and because *this section
> saying "fixed" while §2's table still said BUG for the same four rows* is
> precisely the drift the §2 gate now prevents. Read §2's table for current
> status; it is the one that is enforced.

1. **Row 10 — value-position shadow over live-impl elements: three-way split.**
   `d4b`: `map size [Box 1, Box 2]` → check ACCEPTS, run E-PANICs (`unknown op
   '+'` — the standalone on a `Box`), build prints `[1, 2]` (dispatches to the
   impl!). Hypothesis: eval honors S4 (bare value = standalone) while the emit
   path's marked `EMethodAt` value-position occurrence falls into method
   arg-dispatch, and check types the occurrence permissively (obligation
   skipped) — three stages, three different S4 answers.
2. **Row 12 — generalization over the shadow receiver: silent miscompile.**
   `d5b`: `useIt x = size x; useIt (Box 3)` → check ACCEPTS (`useIt : a ->
   Int`), run E-PANICs, build prints a garbage integer (Box pointer + 1).
   Hypothesis: the ungrounded-receiver occurrence is typed against the
   polymorphic METHOD scheme, so the wrapper generalizes instead of
   monomorphising to the standalone's domain (S5), and the RLocal route then
   runs the standalone on any argument.
3. **Row 13 — no-impl + domain mismatch: check over-accepts, build garbage.**
   `d9`: `size "hi"` → check ACCEPTS, run E-PANICs, build prints garbage.
   Hypothesis: `recordImplObligation:4688` skips the impl obligation for every
   occurrence of a shadow name, and nothing re-imposes the standalone's domain
   on the check path — the S2 "must then type against the standalone" half is
   unenforced.
4. **Row 14 — definer shadow with imported interface+impl: no dispatch.**
   `d8`: local `size : Int -> Int`, `import prov.{Sizeable, Box(..)}`,
   `size (Box 3)` → all three paths reject `Type mismatch: Int vs Box`
   (consistent, loud — but S6 says dispatch to 3). Hypothesis: on the
   multi-module run/check path the occurrence is typed directly against the
   local standalone before any per-receiver machinery fires — the
   definer-shadow app path or its `shadowKeyTableRef` impl query doesn't span
   the imported impl universe for a LOCAL standalone.

Rows 12 and 13 are **silent build soundness holes** (check accepts, binary
prints garbage) — the same severity class as the original P0-18 build hole, and
strong candidates for the next fix batch, with rows 10/14 folded in as the
same "which stage owns S4/S6" decision.

> **✅ UPDATE (2026-07-10, `ef0874f3` — P0-19 batch 1):** rows **12 (d5b)** and **13
> (d9)** are FIXED — both now `check`/`run`/`build` REJECT with a located
> `Type mismatch` (`enforceStandaloneDomain` re-imposes the standalone's declared
> domain whenever a definer-shadow occurrence resolves to the standalone, on both
> the marked run/build path and a new un-marked `EVar` check path; gated by
> `shadowKeyTableRef` so live-impl receivers still dispatch). Regression fixtures
> `test/run_check_agreement_fixtures/p0_19_{poly_wrapper_shadow,noimpl_domain_mismatch}`
> (`.expected=REJECT`); agreement gate 22/0, fixpoint C3a/C3b YES. Bonus: row 11's
> over-general wrapper scheme (`useIt : a -> Int`) is fixed to `Int -> Int`.
>
> **✅ UPDATE 2026-07-10 (P0-19 batch 2, `ebb8ee90`, main `ebb8ee90`) — the last two
> cells CLOSED; all 4 BUG cells now conformant.** Row **10 (d4b)** value-position
> now REJECTs `Int vs Box` (d4 over-Int still accepts `[2,3,4]`): a new
> `shadowHeadCtxRef` flag distinguishes "shadow `EVar` as app head" (keeps the
> method scheme for dispatch) from "bare value position" (pinned to the standalone
> scheme via `maybeStandaloneValueMono`). Row **14 (d8)** now DISPATCHES cross-module
> (run+build print `3`,`4`, matching d2): `shadowKeyTableRef` seeded from the global
> `accData ++ implDecls ++ prog` (was missing the imported impl on the check path),
> and both definer-shadow app paths decide per-receiver — a receiver with a visible
> impl fetches the method scheme from `methodIfaceParamsRef`, else the standalone
> scheme. Fixtures `p0_19_value_pos_{shadow=REJECT,ok=ACCEPT}` + a d8 leg in
> `diff_compiler_check_cli_modules` (14/0); agreement 24/0, fixpoint C3a/C3b YES.

> **🐛 NEW CELL + ✅ FIX (2026-07-13, P0-20) — row 25: a LITERAL receiver.  The worst
> cell in the arc: `check` accepted, `run` panicked, and `build` SILENTLY PRINTED A WRONG
> NUMBER.** The matrix above varies the *shape* of the receiver (grounded / ungrounded /
> dict-bound) but never its *provenance*, and that is where the hole was:
>
> ```
> eq : Int -> Int -> Int      -- a definer shadow of the PRELUDE's `Eq` method
> eq a b = a + b
> main = println (eq 1 2)     -- check: Int · run: E-PANIC · build: prints 0
> ```
>
> A **numeric literal is `Num a => a`, i.e. UNGROUNDED at inference time**, so typecheck
> took the S5 (ungrounded ⇒ standalone) arm and typed the site against `eq : Int -> Int ->
> Int`. But typing it against the standalone *unifies `Int` into the receiver* — so by the
> time the POST-inference route resolver (`resolveRLocalSite`) ran, the receiver WAS
> grounded, to `Int`, which has `impl Eq Int`, and it left the site to **dispatch**. The
> TYPE came from one arm and the ROUTE from the other. `eq 1 2` evaluated to a `Bool` that
> `println` rendered with `Display Int`: `run` panicked (`intToString: not an Int`), and
> the native binary printed **`0`** with exit 0. (With a user interface whose method
> returns a `String` the binary printed a raw heap **pointer**; with `abs` it SEGFAULTED.)
> Only literal receivers were affected — `f k = eq k 1` (k : Int, grounded on arrival)
> dispatched consistently on all three paths, which is why the arc missed it.
>
> Per **S2 the answer is DISPATCH** (the receiver grounds to `Int`; `Eq Int` has an impl),
> so `eq 1 2` is now `False` on check == run == build, and the user's own `eq` is reachable
> only at a type with no `Eq` impl — exactly as `d2` already specified for `Box`.
>
> Fix (`compiler/types/typecheck.mdk`): `groundShadowReceiver` performs S5's
> monomorphisation to the standalone's declared domain **BEFORE** the dispatch decision, so
> typecheck asks the S2 impl question about the SAME head the route resolver will see; and
> `pendingRLocalSites` gained a `forceLocal` flag so **the route FOLLOWS THE ARM** typecheck
> actually took instead of being independently re-derived post-inference. The domain lookup
> is sym-aware (`shadowDomainFor`) — on the mangled emit path the standalone is
> `<mid>__eq`, so a bare-name sig lookup is silently inert there, which flips *build* to the
> standalone while check/run dispatch (the same bug, mirrored).
>
> Fixtures: `test/run_check_agreement_fixtures/p0_20_shadow_literal_{receiver,user_iface,
> result_pinned,noimpl_standalone}` — and that gate now also compares the **VALUE** (`run`
> stdout == the built binary's stdout, plus an optional `.out` pin). It graded exit codes
> only, so a build that exits 0 while printing a wrong number was invisible to it: **the
> gate that owns this bug class could not see this bug.** Agreement 42/0, run_gates 83/0/0,
> fixpoint C3a/C3b YES.
>
> **Residuals found while closing this (both pre-existing on `main`, both filed):**
> 1. ~~**A definer shadow whose standalone is CONSTRAINED (`size : Num a => a -> a`) is
>    miscompiled**~~ — **FIXED 2026-07-13 (S-1; see clause S9).** `check` accepted, `run`
>    panicked, and `build` **exited 0 printing a raw heap pointer**, even with no impl at
>    the receiver head. The filing's mechanism was *close but wrong in the way that changes
>    the fix*: the `RLocal` route did not **drop** a dict — **no dict was ever computed for
>    the occurrence**, because the marking prePass's shadow arm is tested before its dict
>    arm, so the call was never marked an `EDictAt` while the *definition* still got its
>    dict param. `RLocal` now carries the standalone's own dicts (S9).
> 2. **A multi-TYPARAM interface (`interface Ix a i`) bypasses the whole definer-shadow
>    machinery** (every entry point is gated on `singleParamIfaceMethod`, which counts
>    interface TYPE PARAMS, not method params). `check` and `build` agree, `run` panics.
>    S8 speaks to multi-*param methods*; it does not cover multi-*typaram interfaces*.

> **🐛 NEW CELL + ✅ FIX (2026-07-14, P0-21) — row 27: S1 ("shadow-hood is per-module")
> was NOT enforced on the single-file/flat path — a user's shadow LEAKED INTO THE
> PRELUDE.** Every cell in the matrix above varies the shadow's *use*; none of them asks
> **whose module the occurrence is in**. That is where the hole was:
>
> ```
> map : Int -> Int      -- defined, and NEVER USED
> map n = n + 1
> main = println "hello"
> ```
>
> **14 errors**, every one of them raised inside the PRELUDE's own bodies
> (`map2`/`map3`/`replaceWith`/`discard` in `stdlib/core.mdk` all call `map`), all reported
> against the user's file at a fabricated `1:0` — including `'map' takes 1 argument(s) but
> is applied to 2` for a call the user never wrote. This is also the source of the
> separately-filed fabricated-`1:0` diagnostics.
>
> Root cause: `checkProgramSeeded` was handed ONE flat program, `core ++ user`, computed
> `buildDefinerShadows prog prog`, and then applied that single name set to **every
> occurrence in the flattened program, core's included**. The multi-module path never had
> this — `checkModuleFullImpl` seeds the shadow set per module and checks `core` in
> isolation, which is why `helper.mdk`'s `map : Int -> Int` and `other.mdk`'s
> `map (x => x*2) [1,2,3]` have always both worked.
>
> Today the leak was "only" a TYPING leak — a leaked prelude occurrence with a live-impl
> receiver still dispatched, so `println 42` and `elem 9 [1,2,3]` were merely accompanied
> by spurious errors, not miscompiled. **That stops being true the moment S2 is inverted so
> a standalone WINS over a same-named method**: the same leaked occurrence would then ROUTE
> the prelude's `println` into the user's `display`. So this is Stage 0 of the inversion
> arc (`compiler/SHADOW-INVERSION-DESIGN.md`) and had to land first.
>
> Fix (`compiler/types/typecheck.mdk`): the flat path now knows **where the prelude ends**.
> Every driver that flattens the prelude into what it checks (`desugar coreP ++ desugared`)
> passes the two halves separately — `checkProgramSeededSplit seed coreProg userProg`
> (`checkToLinesWithRuntime` / `checkErrorsWithRuntime` / `checkProgramDiags` /
> `checkProgramSchemes{,WithRuntime}` each gained the parameter). With the boundary known,
> `definerShadowNamesRef` is scoped exactly as `checkModuleFullImpl` scopes it: it is the
> USER module's shadow set (`buildDefinerShadows prog userProg`) and is toggled **empty
> while a CORE-owned letrec group, or core's impl/default/prop/test bodies, is inferred**
> (`flatShadowScopingRef` / `flatCoreFnNamesRef` / `flatUserShadowNamesRef`,
> `scopeShadowsForGroup`). Every consumer of that ref — `definerShadowVarHead`,
> `definerShadowArgHead`, `maybeStandaloneValueMono`, `recordImplObligation`'s skip arm,
> `resolveRLocalSite` — becomes per-module for free. All three refs are cleared by
> `resetState` and set ONLY by a `checkProgramSeededSplit` with a non-empty prelude, so the
> multi-module path and every prelude-free probe path are byte-identical.
>
> The `=>`-constrained-receiver carve-out (`definerReceiverIsDictVar`) is UNCHANGED and
> still load-bearing — it is what keeps a *user's* constrained fn dispatching through its
> dict in a shadowing module (`accept_constrained_receiver_shadow`). It is no longer what
> saves the prelude's own `neq x y = not (eq x y)`; the prelude is now simply not in the
> shadow's scope.
>
> Fixtures: `test/run_check_agreement_fixtures/p0_21_prelude_shadow_scope` (ACCEPT — the
> repro, plus a *used* `map 3` → 4 alongside prelude `map2`/`discard`/`elem`/`length`) and
> `p0_21_prelude_shadow_scope_reject` (REJECT — `map "hi"`, proving the machinery is still
> live inside the user's own module and P0-19's row-13 hole stays closed). Agreement 46/0,
> run_gates 83/0/0, fixpoint C3a/C3b YES, `make test` green.
>
> **Residual (unchanged, pre-existing):** inside a module that DOES shadow, a
> multi-*param* method (`map : (a -> b) -> f a -> f b`) still peels only its FIRST argument
> as the receiver, so `map (x => x*2) [1,2,3]` in a file that also defines `map : Int ->
> Int` is rejected `Int vs a -> a`. This is the S8 residual, not S1: the already-correct
> multi-module path rejects the identical shape identically, so the two paths now AGREE.
---

## 6. S-1 residuals (open; grep `S1-RESIDUAL`)

Found while closing S-1 (2026-07-13). **Neither is a regression and neither is a silent
wrong answer** — both were already broken on `main`, and both now fail *loudly*. They are
the two shadow occurrences that do **not** flow through an application-head arm.

### S1-RESIDUAL-A — value-position shadow miscompiles at emit (NOT an S-1 bug) — ✅ **CONFIRMED REAL; emitter half FIXED 2026-07-16 (issue #410)**

`map size [1,2,3]` (a bare shadow occurrence passed to a HOF) miscompiles when the
**interface method's arity DIFFERS from the standalone's**. `run` is correct throughout.

⚠️ **This is NOT caused by the constraint, and NOT by S-1.** Verified: an **unconstrained**
shadow (`size : Int -> Int`) in value position fails *identically*, and that takes the
`dicts == []` path — byte-identical to pre-S1 codegen. So does a shape with **zero impls**
of the interface (`d15`): shadow-hood + arity mismatch + value position suffice. S-1's
design doc mis-attributed this row's `build` failure (it saw a GC OOM) to the missing dict.

> **THE 2026-07-14 "DOES NOT REPRODUCE" NOTE WAS WRONG — AND ITS OWN SUSPICION WAS THE
> ANSWER.** It observed that the stated mechanism "requires the method and standalone
> arities to **differ**, and in both shapes above they are both 1" — then filed the entry
> unreproducible anyway. It was right: **every fixture it tested (`d4`, `d4b`, `d10`) is
> arity-EQUAL**, and when the arities coincide the arity lie is invisible. The corpus could
> not express the bug, so the gate could not defend it — this spec's own lesson, paid twice.
> **A "does not reproduce" that names its own missing ingredient has disproved nothing — it
> has written the next repro.**

**Two bugs stack here. They must not be conflated:**

**(A) the arity lie — emitter — ✅ FIXED 2026-07-16.** The value-position lift built a
closure of `methodArityOf name` — the **interface method's** arity — for a body calling the
**standalone**. With the arities differing, a HOF applying the standalone's arity got a
**partial application** back instead of a value: `map size [1,2,3]` produced a list of PAP
heap pointers and `build` **printed them as Ints at exit 0 with no error**
(`[70290166652896, …]`) — an S0 *silent wrongness*, worse than the segfault this entry
originally described. Fixed by making the arity **route-derived**: `methValArity`
(`llvm_emit.mdk`) and `methodValArity` (`wasm_emit.mdk`) resolve an `RLocal` route's target
via `fnArity`/`progFnArity` **minus the route's dict count** (both are dict-INCLUSIVE — see
the `trmcTryFn` note in `llvm_emit.mdk`), and keep the old name-derived arity for every
non-RLocal route, so the self-compile fixpoint cannot move (C3a/C3b YES). Pinned by
`d13`/`d15`/`d16` (**both** arity directions: method>standalone and method<standalone).
Wasm carried the same lie via an arity helper taking **no Route**; pre-fix its
symptom was a hard assembly failure (`unknown func: failed to find name $mdk_w_…__size`),
**not** the `illegal cast` this entry guessed. Both backends fixed together.

**(B) the NULL element dict — NOT the emitter — ❌ STILL OPEN.** With (A) fixed, the
*unannotated* `println (map size [1,2,3])` still **segfaults** the built binary: `println`'s
`Display (List Int)` requirement is emitted with a **NULL element dict**
(`@mdk_dc_N = [2 x i64] [<List-display tag>, i64 0]`; the `0` is an **RNone** route), so
`display` dereferences NULL. The element **type** resolves correctly to `Int` (annotating
`List String` reports `Type mismatch: Int vs String` at the list literal), so this is not a
typing failure — it is the requirement **route** stamped without being resolved against the
inferred type. Annotating `let ys : List Int = map size [1,2,3]` makes the route resolve and
the program correct, which is what isolates (B) from (A). Routes are stamped in
`compiler/types/typecheck.mdk`, so **(B) is not an emitter fix**; it is plausibly the same
root as the `#412` structured-requires pre-bake. Ledgered by `d14` (`BUILD_CRASH` —
self-draining: it goes RED the day (B) is fixed).

*Fix location (A, done):* `compiler/backend/llvm_emit.mdk` `methValArity`;
`compiler/backend/wasm_emit.mdk` `methodValArity`.
*Fix location (B, open):* `compiler/types/typecheck.mdk` — requirement-route resolution.

### S1-RESIDUAL-B — importer shadow on an UNGROUNDED receiver — ✅ **CLOSED 2026-07-14**

**The filed diagnosis was right, and its own suggested fix was the fix.** But the residual
**understated the blast radius**, and that is the part worth remembering.

*As filed:* `import prov.{size}` where `prov.size : Num a => a -> a` shadows a local
interface method, called as `size 3` — "`build` and `wasm` are correct (4); `run` still
under-applies." Read that way it sounds like a **constrained**-standalone dict-threading
nit on one engine.

*What it actually was:* the root breaks an **unconstrained** standalone at **`check`**, on
**all three paths**, whenever the shadowed method is **higher-kinded** — which every
`Foldable`/`Mappable`/`Traversable` method is:

```medaka
-- prov.mdk:  export isEmpty : Int -> Bool   (isEmpty n = n == 0)
import prov.{isEmpty}
main = println (debug (isEmpty 0))    -- Type mismatch: Int literal vs Int Int
```

The **`Int Int`** is the tell. A numeric literal is `Num a => a`, i.e. **ungrounded** at
inference time, so `inferShadowApp`'s `headTyconMono tx` said `None`, it never reached its
*standalone* arm, and it fell to the ordinary-app arm — which types against the **method**
scheme the env rebound the name to. The prelude's `Foldable.isEmpty : t a -> Bool` is
higher-kinded, so unifying `t a` against the literal's tyvar solved `t := Int, a := Int`.
The user's imported `isEmpty : Int -> Bool` was **never consulted**.

**Cause (as filed):** `inferShadowApp` lacked the `groundShadowReceiver` call that P0-20 gave
its definer peer `inferDefinerShadowApp`. **Fix (as filed):** add it — ground the ungrounded
receiver to the *imported* standalone's declared domain (`importerShadowDomain`) **before**
asking the S2 impl question, so typecheck and the post-inference route resolver ask it about
the **same head**.

> ⚠️ **This is the P0-20 shape again, one arm over: ONE DECISION, DERIVED TWICE, AT TWO
> DIFFERENT TIMES, OVER A RECEIVER THAT CHANGED IN BETWEEN.** It is the recurring root cause
> of this entire arc. When you touch shadow routing, the question to ask is never "is the
> receiver the right *type*" but "**is the receiver GROUNDED YET, and will it still be the
> same thing when the route is stamped?**"

**Why no gate caught it, and the lesson.** Every importer fixture — `i1`, `i3`, `i4` — used a
**grounded** receiver (a `Box`, a `Tok`, a `List`). **Not one used a bare numeric literal**,
so the corpus was *structurally blind* to the cell and the gate graded **18/0 over a real
break**. Rows 27–28 (`d12`, `i5`) close it, and `i5` carries the Fork-1 control in the same
fixture. **A gate that cannot express a cell cannot defend it: vary the receiver's
PROVENANCE — literal / grounded / dict-bound — not just its type.**

*Fixed in:* `compiler/types/typecheck.mdk` `inferShadowApp` + `importerShadowDomain`.
Fork 1 is untouched: grounding only decides **which head** the per-receiver rule is applied
to; a grounded head with a live impl still dispatches (`isEmpty [1, 2]` → `Foldable.isEmpty`).
