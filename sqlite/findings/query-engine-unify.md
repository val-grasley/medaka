# Findings — unifying the `Select` / `AggQuery` query engines

Task: fold `lib/aggregate.mdk`'s `AggQuery` into `lib/select.mdk`'s `Select`, giving one
query ADT and one executor running SQL's real evaluation order (FROM → JOIN → WHERE →
GROUP BY → HAVING → project → DISTINCT → ORDER BY → LIMIT/OFFSET), with a real `EAgg`
node replacing the fake-column-name pun.

The refactor leaned on exactly the areas the brief predicted: record update syntax,
`Option`/`Result` plumbing, typeclass-constrained functions, higher-order compilation of
expressions to closures, and sorting with derived comparators. Two of the findings below
(**F1**, **F2**) are `check`/`run`/`build` disagreements — the highest-value class — and
**F2 is a silent miscompile**.

---

## F1 — `deriving (Eq)` on a type with an `Array` field: `check` ✓, `run` ✓, `build` ✗

- **Category:** compiler-bug
- **Severity:** workaround-required
- **Repro:**
  ```medaka
  data L = LBlob (Array Int) deriving (Eq)

  main : <IO> Unit
  main = println (LBlob (arrayFromList [1, 2]) == LBlob (arrayFromList [1, 2]))
  ```
- **Expected:** a `check`-time error. Medaka has no `Eq (Array a)` impl, and it says so
  perfectly when you compare arrays *directly*:
  ```
  arr2.mdk:2:54: No impl of Eq for Array Int
    |
  2 | main = println (arrayFromList [1, 2] == arrayFromList [1, 2])
    |                                                       ^
  ```
  So the checker already knows. `deriving` just never asks.
- **Actual:** `medaka check` passes silently. `medaka run` prints `True`. `medaka build`
  dies **inside the emitter** (no binary is produced):
  ```
  error: emitter failed compiling arr1.mdk
  runtime error [E-PANIC]: no impl of method 'eq' for type 'Array' (slice 6)
  ```
  Three tools, three answers. The `deriving` pass does not verify that each field type
  actually has an impl of the derived class, and the interpreter's arg-tag fallback
  "finds" *something* for `Array`, so `run` disagrees with `build`.
- **Workaround:** hand-write the impl. `lib/select.mdk`'s `Literal` has an `LBlob (Array Int)`
  arm, so it gets an explicit `impl Eq Literal` comparing blobs element-wise. `deriving (Eq)`
  is fine on `SqlExpr`/`CmpOp`/`ArithOp`/`AggFn` — I verified that deriving works on a
  *recursive* ADT carrying `Option` and a hand-written-`Eq` field type; **`Array` is the
  only thing that breaks it.**
- **Notes:** the `deriving` expansion in `frontend/desugar.mdk` presumably emits `eq` calls on
  field types without adding the corresponding constraint/impl check.

### F1a — `medaka lint` actively recommends the miscompile

- **Category:** tooling
- **Severity:** annoyance (but it points you at a broken build)
- **Actual:** with the hand-written impl from F1 in place, `medaka lint` says:
  ```
  sqlite/lib/select.mdk:52:1: [rule-hand-rolled-derivable] hand-written `impl Eq` for 'Literal' — use `deriving (Eq)`
  ```
  Taking that advice produces a program that **cannot be built** (F1). The rule is blind to
  whether the field types have an `Eq` impl at all.
- **Workaround:** `-- lint-disable-next-line rule-hand-rolled-derivable`, with a comment
  explaining that the rule is wrong here. (The pre-commit hook gates all rules, so this
  can't just be ignored.)

---

## F2 — Cross-module record field-name collision + record *update* → wrong slot written in `build`. **SILENT.**

- **Category:** compiler-bug
- **Severity:** blocker (worked around by renaming every field)
- **Repro** — two files, `lib/a.mdk` and `main.mdk`:
  ```medaka
  -- lib/a.mdk : `groupBy` is the SECOND field here (slot 1)
  public export data Sel = Sel { tag : String, groupBy : List Int }

  export mkSel : Sel
  mkSel = Sel { tag = "sel", groupBy = [7] }
  ```
  ```medaka
  -- main.mdk : `groupBy` is the FIRST field here (slot 0) — same NAME, different SLOT
  import lib.a.{Sel, mkSel}

  data Agg = Agg { groupBy : List Int, n : Int }

  withGroupBy : List Int -> Agg -> Agg
  withGroupBy cols q = { q | groupBy = cols }        -- the record UPDATE is the trigger

  main : <IO> Unit
  main =
    let a = withGroupBy [3] (Agg { groupBy = [], n = 1 })
    println "\{debug mkSel.groupBy} \{debug a.groupBy}"
  ```
- **Expected:** `[7] [3]`.
- **Actual:** `medaka check` passes. `medaka run` prints `[7] [3]` — correct. The **native
  build prints `[7] []`** — the update wrote the *other* record's slot, and because the two
  field types happened to be compatible, **nothing crashed and the program silently returned
  the wrong answer.**

  When the colliding field types are *incompatible* (e.g. `List String` vs `List SqlExpr`),
  the corruption instead surfaces later as an unlocated crash:
  ```
  runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match
  ```
- **All four conditions are required** — I removed each in turn and the bug disappears:
  1. the two record types are in **different modules** (both in one file: fine);
  2. they **share a field name**;
  3. that field sits at a **different positional index** in the two records (same index: fine
     — which is why the pre-existing `from` collision, slot 0 in both, never bit);
  4. the code performs a record **update** `{ r | f = v }` on it (construction, field access
     and record *patterns* are all fine — only update miscompiles).
- **Workaround:** eliminate the overlap. `AggQuery`'s fields are now `aqFrom` / `aqWhere` /
  `aqGroupCols` / `aqAggs` / `aqHaving`, because unification put `Select` (which has `from`,
  `where_`, `groupBy`, `having`) into the same module scope. Every exported *function* keeps
  its name, type and behaviour; only the internal field labels moved.
- **Notes:** looks like the field→slot resolution for the update path keys on the bare field
  name and picks the wrong owner when two record types in scope both declare it. Field
  *access* and *patterns* evidently resolve via the receiver's type; update does not. Related
  in spirit to the "flat frame keyed by bare name is last-write-wins" family in AGENTS.md,
  and to the Phase 72 `field_owners` work.
- **This cost the most time in the session by far.** It presents as "my brand-new engine has a
  bug", it only appears in the built binary, and the crash message names nothing (see F3).

---

## F3 — Runtime errors carry no source location at all

- **Category:** error-message
- **Severity:** workaround-required (bisect by hand)
- **Repro:** any of the F2 / F1 programs above, built natively.
- **Actual:**
  ```
  runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match
  runtime error [E-PANIC]: intToString: not an Int
  ```
  No file. No line. No function name. No scrutinee value. Nothing.
- **Expected:** at minimum the function and the source span of the `match` that fell through;
  ideally the value that matched no arm.
- **Workaround:** manual bisection. To find F2 I had to shrink a 6-query demo down to a
  3-line probe by hand, rebuilding ~15 times. A single "non-exhaustive match in `toSelect`
  at select.mdk:NNN, scrutinee = …" would have made it a two-minute fix.
- **Notes:** `check`-time diagnostics in this language are genuinely excellent (located,
  caret, suggested fix). Runtime errors are the exact opposite, and they're where the
  hard bugs live.

---

## F4 — Multi-module `run` throws away the type error and panics instead

- **Category:** compiler-bug / error-message
- **Severity:** workaround-required
- **Repro:** `main.mdk` importing `lib/b.mdk`, where `Lit` has no `Debug` impl:
  ```medaka
  -- lib/b.mdk
  public export data Lit = LInt Int | LText String
  ```
  ```medaka
  -- main.mdk
  import lib.b.{Lit, LInt}

  main : <IO> Unit
  main = println (debug (LInt 1))
  ```
- **Expected:** `run` refuses, printing the type error — which is exactly what it does for the
  **single-file** version of the same program:
  ```
  dbg.mdk:4:16: No impl of Debug for Lit; add 'deriving Debug' to the 'Lit' type, or write an 'impl Debug Lit'.
    |
  4 | main = println (debug [LInt 1, LText "x"])
    |                 ^
  ```
- **Actual:** in the **multi-module** path `run` does not report it. It executes the ill-typed
  program and dies with an unrelated message:
  ```
  runtime error [E-PANIC]: intToString: not an Int
  ```
  `medaka check` on the same file reports the real error correctly, and `build` fails with a
  third message (`no impl of method 'debug' for type 'Lit'`). So: **check ✓ (right message),
  run ✗ (wrong message), build ✗ (third message)**, for one program.
  (Exit codes are all `1`, so scripts and CI are not misled — only humans are.)
- **Workaround:** always `medaka check` before believing `medaka run`.
- **Notes:** smells like the loader/eval-driver vs single-file split documented in AGENTS.md —
  the multi-module eval driver isn't gating on `hadTypeErrors()`. This one sent me chasing a
  phantom bug in my own library for a while, because `intToString: not an Int` looks like
  data corruption, not a missing impl.

---

## F5 — Omitting `where` on an `impl` block: error points at the wrong line and never says `where`

- **Category:** error-message
- **Severity:** annoyance
- **Repro:**
  ```medaka
  data Lit = LInt Int | LText String

  impl Eq Lit                      -- line 3: the `where` is missing HERE
    eq (LInt a) (LInt b) = a == b  -- line 4
    eq _ _ = False
  ```
- **Expected:** an error on line 3 saying `impl` blocks need `where`.
- **Actual:** the error lands on the *first method's* `=`, and never mentions the keyword:
  ```
  arr3.mdk:6:23: unexpected `=`
    |
  6 |   eq (LInt a) (LInt b) = a == b
  ```
- **Workaround:** add `where`. (Obvious once you look at `stdlib/core.mdk`; not obvious from
  the message.)

---

## F6 — A multi-line list literal cannot be a `match` scrutinee

- **Category:** ergonomics / error-message
- **Severity:** annoyance
- **Repro:**
  ```medaka
  f : List Int -> Result String Int
  f xs = Ok (length xs)

  main : <IO> Unit
  main = match f [
      1,
      2,
    ]
    Err e => println e
    Ok n => println n
  ```
- **Expected:** parses. Block-exprs inside brackets are supported (per PLAN's layout work), and
  a multi-line list literal is fine everywhere else — including as a normal function argument.
- **Actual:**
  ```
  layout.mdk:5:15: unexpected `[`; expected an indent
    |
  5 | main = match f [
    |               ^
  ```
  The message ("expected an indent") describes the layout machinery's internal state rather
  than anything the author can act on.
- **Workaround:** hoist the list to a top-level binding and match on that. `inmem_join_probe.mdk`
  already does this (`specs : List (...)`), which is how I knew the workaround — i.e. someone
  hit this before me.

---

## F7 — Same diagnostic, different column under `run` vs `build`

- **Category:** error-message
- **Severity:** annoyance
- **Repro:** `import array.{toList}` (there is no `toList` in `stdlib/array.mdk`).
- **Actual:**
  ```
  run:   arr3.mdk:1:14: Module 'array' has no exported name 'toList'
  build: arr3.mdk:1:0:  Module 'array' has no exported name 'toList'
  ```
  `run` points at the name inside the import list (col 14); `build` points at column 0. Same
  error, same file, two locations. Minor, but it means you can't trust a column number to be
  stable across tools.

---

## Not findings (checked, works correctly)

Recording these because each was a *suspect* during debugging and each turned out to be fine —
worth knowing they're solid:

- **`deriving (Eq)` on a recursive ADT** carrying `Option`, nested constructors, and a field
  type with a hand-written `Eq`: works under `check`, `run` and `build`. Only `Array` (F1)
  breaks it.
- **`debug` on a type with no `Debug` impl**: correctly rejected at check time with a located,
  actionable message — including at *nested* positions (`Result String (String, List Lit)`).
  The constraint propagates properly through type constructors.
- **Destructuring lambda params** (`((k, rows) => …)`, `filter ((kk, _) => …)`) including `_`
  inside the tuple pattern: all fine.
- **Passing a multi-clause top-level function as a first-class value** (`Ok sumCells`,
  `map aggExpr aggs`) and **constructors point-free** (`map ECol gcols`): all fine. I suspected
  both while hunting F2; both are innocent.
- **Higher-order compilation of expressions to closures** (`List Cell -> Cell` accessors built
  in a `Result` monad and stored in lists) — the core technique of this engine — works exactly
  as you'd hope, and `sortBy` with a closure-derived comparator is stable, which the grouped
  ORDER BY relies on for deterministic tiebreaks.

---

## Design note — is the `Eq a` / DISTINCT split a language limitation?

The brief asked. **It is a real consequence of the type system, not an arbitrary choice, and I
kept it.**

`query : Db -> Select -> RowType a -> Result String (List a)` must stay unconstrained: it is
the general entry point and callers decode into arbitrary types. DISTINCT, however, dedups on
the **decoded** values (not the raw cells — two different cell rows can decode to the same
value), so it fundamentally needs `Eq a`. Medaka has no way to express "this constraint is
only required when the `distinct` flag is set" — that would need something like an
existential/conditional constraint, or dictionary-on-demand. So the honest encoding is two
entry points, which is what `query` / `queryDistinct` already were and still are.

The unification actually made this *cleaner*: `runPipeline` now does all the shared work in
cell-land (unconstrained) and the two entry points differ only in their last three lines —
`query` slices then decodes; `queryDistinct` decodes, `nub`s, then slices. Worth noting that
`nub` is O(n²), which is fine at dogfood scale but is the one place the constraint costs
something real.

An alternative worth considering if this ever matters: carry an `Option (a -> a -> Bool)`
equality witness inside `RowType a` (the same "closure carries the type information" trick
`RowType` already uses to work around the lack of GADTs). That would let plain `query` execute
DISTINCT with no constraint at all. It's a genuine design option, not a workaround — but it's
a bigger change than this task, so I left the split alone.
