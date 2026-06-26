---
name: harden-typechecker
description: Typechecker-internal correctness and diagnostics work in compiler/types/typecheck.mdk — add or refine a type_error, tighten constraint/coherence/unification logic, or fix an over/under-generalization bug. Use for the PLAN-ARCHIVE.md Phase 62–72 hardening arc, or whenever the fix lives inside the type checker rather than threading new surface syntax.
---

# Harden the typechecker

Almost everything here happens in one file, `compiler/types/typecheck.mdk`. The
work is narrower than `add-language-feature` (no lexer/parser/AST changes): you
are making the checker *reject more*, *diagnose better*, or *generalize
correctly*, without disturbing the two invariants below.

Read the relevant PLAN-ARCHIVE.md phase first — each entry has a **Where.**
section with approximate locations and a **Done when.** acceptance test. Those
locations drift; confirm with search before trusting them.

## Two invariants you must not break

- **Errors accumulate; phases don't exit on first failure.** They push into
  `compiler/driver/diagnostics.mdk`. Inside `typecheck.mdk` the idiom is
  `fail (SomeError …)` which raises a type error, caught upstream and collected.
  Don't add early exit/panic paths, and don't short-circuit a later phase
  because an earlier one failed.
- **Level bracketing must be exception-safe.** Generalization uses Rémy levels:
  hand-balanced `enterLevel ()` / `exitLevel ()` pairs. A `fail` *between* them
  permanently increments `currentLevel`. **Nuance confirmed in Phase 71:** the
  whole-program entry points (`checkProgram`, `typecheckModule`) call
  `resetState` on entry, so a leak there is wiped before the next run; and
  within a single run the leak is *relative* — each `processLetrecGroup`
  brackets against whatever base it starts at and generalizes against that same
  base, so a uniform leak does **not** by itself break generalization. The real
  exposure is the **REPL**, which reuses typechecker state: a leak there violates
  the absolute "top-level names pre-bound at level 1" invariant (§2.9). Phase
  71's fix: `checkReplDecl` resets `currentLevel := 0` at each input boundary.
  Still: if you add a path that can `fail` mid-bracket, prefer restoring the
  level (a finally, or reset at the boundary).

## Broken invariants are diagnostics, not crashes (Phase 71)

There is **no `assert false` left in `typecheck.mdk`** — don't reintroduce one.
For a "can't happen" invariant violation, `fail (InternalError "context")`
(a type_error variant that renders as "Internal type-checker error: …"); it's
catchable and survives the REPL. **Exception:** a *rendering* path must never
raise — `ppMono`'s post-normalize `Link` case returns the placeholder `"_"`
rather than failing, because it runs while formatting an error message. Also
guard lookups that can miss across module boundaries (`env.interfaces`,
`env.records`): fall back to the matching user-facing error (`UnknownInterface`,
`UnknownRecord`) or degrade gracefully rather than letting a raw not-found
escape.

## Generalization is value-restricted (Phase 66)

`let`/`do`-`let` bindings are only generalized when their RHS is a **syntactic
value**. The gate is `isNonexpansive` (literal / var / lambda; tuple or
list-literal of values; `ELoc`/`EAnnot` transparent — *everything else,
including all applications, is expansive*). Generalization goes through
`genRestricted isValue t` (not bare `generalize`) at every binding site: `ELet`
`PVar`, `DoLet` in `EBlock`/`EDo`, per-binding in `ELetGroup`, and the
top-level non-letrec path in `processLetrecGroup`.

The non-obvious rule if you touch any of this: **a non-generalized binding must
have its free vars *lowered* to `currentLevel`, not merely wrapped in
`monotype`.** Otherwise the vars sit at a deeper level and an *enclosing* `let`'s
`generalize` picks them up — reopening the unsoundness one scope out.
`genRestricted` does this via `lowerToCurrent`; the non-`PVar` pattern path
gets it for free because `unify tp t1` lowers through `occursAdjust`. Note
`Ref` is a *constructor* (`extern Ref : a -> Ref a`), so — like SML/OCaml's
`ref` — constructor applications are deliberately expansive.

## Adding a `type_error`

The mechanical loop — four edits, all in `compiler/types/typecheck.mdk` unless
noted:

1. **Constructor** — add a variant to the `TypeError` ADT. Carry enough payload
   to render a useful message (names + the `Mono`s involved).
2. **Pretty-printer** — add a case to `ppError`. Use `ppMono` for a single type,
   `ppScheme` for schemes. **When a message names two or more types** (a
   mismatch, or two impl-head arg lists), render them through one shared naming
   context — `ppMonoPair a b` / `ppMonos args` / `ppMonosPair a b` (Phase 70)
   — not separate `ppMono` calls, or two distinct tyvars can both print as `a`.
   Phrase the message as *what's wrong + how to fix*.
3. **Raise site** — `fail (YourError …)` from the phase that detects it.
   `fail` reads the global `currentLoc`, which is correct *during* the `infer`
   walk but **stale in post-HM passes** (`checkMethodUsages`,
   `checkConstraintObligations`) — by then it points at the last expression
   inferred. If your error fires from a deferred/post-HM pass, capture
   `!currentLoc` into the accumulator tuple at record time and raise with
   `failAt loc …` instead (Phase 62 did exactly this — follow that pattern).
4. **Test** — add a fixture to the typecheck golden gate or the
   `test/diff_compiler_check.sh` suite. Fixtures embed the source inline so
   failures read cleanly. **Watch for prelude name collisions:** a fixture that
   reuses a stdlib interface name (e.g. `Monoid`) may pass on a
   *duplicate-interface* error rather than the error you intend — use a fresh
   name so the test exercises what it claims.

## Where things live (grep these names, don't trust line numbers)

- **Unification / generalization** — `unify`, `normalize`, `generalize`,
  `instantiate`, `enterLevel`/`exitLevel`, `freshVar`. Value restriction:
  `isNonexpansive`, `genRestricted`, `lowerToCurrent`.
- **Interfaces & impls** — `registerInterface`, `registerImpl`, `implEntry`,
  `ifaceInfo`. Call-site constraint solving is a family of post-HM passes that
  share `matchingImpls` + `isConcrete` + `failAt loc`:
  `checkMethodUsages`, `checkConstraintObligations`,
  `checkSuperinterfaceObligations` (Phase 64), `checkEntryRequires`
  (Phase 65, recurses for nested `requires`). `monoMatches` is the
  one-directional wildcard match (pattern may have TVars, concrete must be
  ground). Fold a new obligation check *into* the selection passes (rather than
  a new standalone pass) to cover all `typecheck*` entry points at once.
- **Coherence** — `checkCoherence`, `implsOverlap` (bidirectional unification:
  two impls overlap iff their head-type lists unify under one substitution).
  **Seeded (prelude) impls** (`implSeeded`) are excluded from coherence — user
  impls are *meant* to override them (Phase 45.9). Any new global impl check
  must respect that exclusion or it will false-positive on the stdlib itself.
- **Data/record/alias registration** — `registerData`, `registerRecord`,
  `registerAlias`, `expandAliases`, `fromAstType`. **Gotcha:** plain
  `fromAstType` mints a *fresh* TVar table per call, so the same source name
  `a` in two separate calls becomes two unrelated TVars. When two `Ty` values
  must share variables (impl head ↔ `requires`, signature ↔ its constraints),
  thread one table: pass `~tbl` to `fromAstType`, or follow
  `fromAstTypeWithConstraints`, which already shares a `tbl` for exactly this
  reason.

## Writing tests: a parameter's type is a free var during body inference

A type signature does **not** pre-ground a function's parameter types before the
body is inferred. `processLetrecGroup` infers the body with each param as a
fresh TVar and unifies the result against the declared type *afterwards*. So a
body expression that branches on the *concrete* type of a parameter sees a free
var, not the annotated type. To exercise a type-directed branch, ground the
value at the expression itself (`[1,2,3].[1..2]`, `"abc".[0..1]`), not via a
parameter annotation.

## Verify

```sh
make medaka          # rebuild the native compiler
bash test/diff_compiler_check.sh          # typecheck gate (fixtures)
bash test/diff_compiler_check_modules.sh  # multi-module typecheck
```

The typechecker loads the real stdlib, so **also run the suites that exercise
it end-to-end** — a too-aggressive new rule that rejects valid stdlib code shows
up here:

```sh
bash test/diff_compiler_eval.sh
bash test/diff_compiler_check_batch.sh
```

If a change rejects something the stdlib relies on, the prelude fails to load
and many gates break at once — that's the signal your rule is too broad (usual
culprit: not excluding seeded impls, or treating a legitimate named/`default`
impl as a conflict).

## Diagnosing before fixing

If you're not yet sure which stage or construct is at fault, use the
**debug-pipeline** skill. For raw type dumps, run the typecheck probe entry:

```sh
./medaka run compiler/entries/typecheck_main.mdk -- scratch.mdk
```
