---
name: harden-typechecker
description: Typechecker-internal correctness and diagnostics work in compiler/types/typecheck.mdk — add or refine a type error, tighten constraint/coherence/unification logic, or fix an over/under-generalization bug. Use for the PLAN-ARCHIVE.md Phase 62–72 hardening arc, or whenever the fix lives inside the type checker rather than threading new surface syntax.
---

# Harden the typechecker

Almost everything here happens in one file, `compiler/types/typecheck.mdk`. The
work is narrower than `add-language-feature` (no lexer/parser/AST changes): you
are making the checker *reject more*, *diagnose better*, or *generalize
correctly*, without disturbing the two invariants below.

Read the relevant PLAN-ARCHIVE.md phase first — each entry has a **Where.**
section with approximate locations and a **Done when.** acceptance test. Those
locations drift; **confirm every name with `grep` before trusting it.** (An
earlier version of this skill carried ~19 symbol names that had not existed since
the OCaml compiler was deleted. Verify, don't assume — including the names below,
which carry line numbers as of 2026-07-13.)

## Two invariants you must not break

- **Errors accumulate; phases don't exit on first failure.** They push into
  `compiler/driver/diagnostics.mdk`. Inside `typecheck.mdk` errors are plain
  `String` messages pushed via the `pushTypeError*` family (see below) — there is
  no `TypeError` ADT and no `fail`/`raise` path. Don't add early exit/panic paths,
  and don't short-circuit a later phase because an earlier one failed.
- **Level bracketing must be exception-safe.** Generalization uses Rémy levels:
  hand-balanced `enterLevel ()` (`typecheck.mdk:854`) / `exitLevel ()` (`:857`)
  pairs around `currentLevel` (`:745`). A non-local exit *between* them permanently
  increments the level. The whole-program entry points call `resetState` (`:2189`)
  on entry, so a leak is wiped before the next run; and within a single run the
  leak is *relative* — `processSCC` (`:10799`) brackets against whatever base it
  starts at and generalizes against that same base, so a uniform leak does not by
  itself break generalization. Still: if you add a path that can exit mid-bracket,
  restore the level at the boundary.

## Can't-happen vs. recoverable: `panic` vs. `pushTypeError`

A genuinely impossible invariant violation uses `panic "context"`
(e.g. `panic "unify: tuple arity mismatch"`). Native `panic` is **unrecoverable by
design** (see the `no-catchable-panics-isolation` decision) — reserve it for true
impossibilities, and **don't `panic` on anything a user program can actually
reach.** A *recoverable* condition a real program can trigger — notably a
cross-module lookup that can miss — must `pushTypeError` a clear user-facing
message rather than panic. **Exception:** a *rendering* path must never panic —
`ppMono` (`:2603`) returns the placeholder `"_"` for a post-normalize `Link`
rather than crashing, because it runs while formatting an error message.

## Generalization is value-restricted (Phase 66)

`let`/`do`-`let` bindings are only generalized when their RHS is a **syntactic
value**. The gate is `isNonexpansive` (`:2424`) — literal / var / lambda; tuple or
list-literal of values; `ELoc`/`EAnnot` transparent — *everything else, including
all applications, is expansive*. Generalization goes through
`genRestricted isValue t` (`:2494`), not bare `generalize` (`:2398`), at every
binding site.

The non-obvious rule if you touch any of this: **a non-generalized binding must
have its free vars *lowered* to `currentLevel`, not merely wrapped in a
monotype.** Otherwise the vars sit at a deeper level and an *enclosing* `let`'s
`generalize` picks them up — reopening the unsoundness one scope out.
`genRestricted` does this via `lowerToCurrent` (`:2470`); the non-`PVar` pattern
path gets it for free because `unify` (`:2305`) lowers through `occursAdjust`
(`:2277`). Note `Ref` is a *constructor* (`extern Ref : a -> Ref a`), so — like
SML/OCaml's `ref` — constructor applications are deliberately expansive.

## Adding a type error

**Every new diagnostic needs a stable code.** `pushTypeError` takes the code as
its *first* argument. Before you write the message:

- register the new code in **`compiler/DIAGNOSTIC-CODES-DESIGN.md`** (typechecker
  codes are the `T-*` family), and
- write the message against **`compiler/ERROR-QUALITY.md`** (the rubric: located,
  names the rule, actionable fix, carries a code).

The real API (`compiler/types/typecheck.mdk`):

```
pushTypeError          : String -> String -> <Mut> Unit                                   -- :1991
pushTypeErrorOnce      : String -> String -> <Mut> Unit                                   -- :2005  (dedups)
pushTypeErrorOnceAt    : String -> Option Loc -> String -> <Mut> Unit                     -- :2018
pushTypeErrorHelpFixAt : String -> Option Loc -> String -> String -> Option (Loc, String) -> <Mut> Unit  -- :2055
```

Real call sites read `pushTypeError "T-EFFECT-LEAK" (effectLeakMsg bound escaping)`
(`:923`) and `pushTypeError "T-CONFLICTING-IMPL" msg` (`:7752`).

- **`pushTypeError` does NOT dedup** — it plain-conses. `pushTypeErrorOnce` is the
  deduping variant.
- **`pushTypeError` captures `currentLoc` (`:2075`) itself.** That is correct
  *during* the `infer` walk, but **stale in post-HM passes** — by then it points at
  the last expression inferred. If your error fires from a deferred/post-HM pass,
  capture the loc at *record* time into the obligation tuple (that is why
  `pendingCallObligations` (`:1530`) and `pendingImplObligations` (`:1368`) both
  carry an `Option Loc`) and raise with `pushTypeErrorOnceAt` / `pushTypeErrorHelpFixAt`.
- Use `pushTypeErrorHelpFixAt` when you can offer a machine-applicable fix — it is
  what surfaces `help` + `fix` in `medaka check --json`.

The mechanical loop:

1. **Message builder** — write (or reuse) a `…Msg : … -> String` helper that formats
   the message from the names + `Mono`s involved. Real examples: `effectLeakMsg`
   (`:925`), `effectParamMsg` (`:930`), `ambiguousImplMsg` (`:8594`). Grep for an
   existing `Msg` builder near the error family you're adding and mirror it.
   **When a message names two or more types**, render them through one shared
   naming context — `ppMonosShared : List Mono -> <Mut> String` (`:10147`) — not
   separate `ppMono` calls, or two distinct tyvars can both print as `a`.
   (`ppMono` (`:2603`) / `ppScheme` (`:2565`) render a single type/scheme.)
2. **Raise site** — `pushTypeError "T-YOUR-CODE" (yourMsg …)` from the phase that
   detects it.
3. **Test** — add a fixture to `test/diff_compiler_check.sh`'s corpus.
   **Watch for prelude name collisions:** a fixture that reuses a stdlib interface
   name (e.g. `Monoid`) may pass on a *duplicate-interface* error rather than the
   error you intend — use a fresh name so the test exercises what it claims.
4. **Check the JSON shape** — `./medaka check --json scratch.mdk` and confirm your
   `code`, `range`, `severity`, and (if any) `help`/`fix` come out right.

> A structured error ADT (to replace the string messages) is a *parked* future
> refactor — see PLAN.md. Until then, string + per-error builder is the idiom; do
> **not** introduce a `TypeError` ADT as part of an unrelated change.

## Where things live

All in `compiler/types/typecheck.mdk`. Line numbers are as of 2026-07-13 — grep
the name, not the number.

| Area | Real names |
|---|---|
| Unification / generalization | `unify` (:2305), `normalize` (:2261), `generalize` (:2398), `instantiate` (:2518), `freshVar` (:754), `enterLevel`/`exitLevel` (:854/:857), `currentLevel` (:745), `resetState` (:2189) |
| Value restriction | `isNonexpansive` (:2424), `genRestricted` (:2494), `lowerToCurrent` (:2470), `occursAdjust` (:2277) |
| Errors / rendering | `pushTypeError` (:1991), `pushTypeErrorOnce` (:2005), `pushTypeErrorOnceAt` (:2018), `pushTypeErrorHelpFixAt` (:2055), `currentLoc` (:2075), `ppMono` (:2603), `ppScheme` (:2565), `ppMonosShared` (:10147) |
| Group inference (letrec/SCC) | `processSCCs` (:10751) → `processSCC` (:10799) → `sccSchemes` (:11089), `isLetrecGroup` (:10867) |
| Constraint obligations | `recordCallObligations` (:3561), `recordImplObligation` (:4635), `recordSchemeCallObligations` (:4615); state in `pendingCallObligations` (:1530), `pendingImplObligations` (:1368), `schemeObligationsRef` (:1555). `monoConcrete` (:4719) is the is-it-ground test. |
| Interfaces / supers | `methodIfaceParamsRef` (:1193), `userIfaceNamesRef` (:1509), `lookupQualIfaces` (:3505), `expandSupersTable` (:3620), `ifaceSelfAndSupers` (:5105), `directSupers` (:5114) |
| Impls | `ImplEntry` (the impl-table row), `findImplEntry` (:8507) |
| Coherence | `checkCoherence` (:7750) → `cohCollectImpls` (:8061) → `cohFirstConflict` (:7713) → `cohOverlap` (:7604) (bidirectional unification: two impls overlap iff their head-type lists unify under one substitution). **Prelude/seeded impls are excluded by construction** — `checkCoherence` is only ever handed *user* decls (`coherenceUserDecls`, :8093), because user impls are *meant* to override seeded ones. Any new global impl check must be fed the same list or it will false-positive on the stdlib itself. |
| Data / record / alias registration | `registerData` (:6004), `registerVariants` (:6044), `registerRecordInfoKeyed` (:6016), `aliasTableRef` (:1101), `buildAliasGraphEntry` (:2761), `rejectCyclicAliases` (:2806), `fromAstType` (:2886) |

**`fromAstType` gotcha.** Its signature is
`fromAstType : List (String, Mono) -> Ty -> <Mut> Mono` (`:2886`) — the tvar table
is an **ordinary first positional argument** (`tvs`). (Medaka has **no labeled
arguments**.) Call it with a fresh `[]` and the same source name `a` in two separate
calls becomes two unrelated TVars. When two `Ty` values must share variables (impl
head ↔ `requires`, signature ↔ its constraints), **thread one `tvs` list through
both calls.**

## Two whole-program entry points — mirror both

Per-node `infer`/`check` arms are shared, and both paths funnel group inference
through `processSCCs`/`processSCC`. But the *orchestration* — registration order,
coherence, and the final passes — is duplicated in two near-identical blocks:

- single-file: `checkProgramDiags` (`:11565`), plus `checkProgramSchemes` (`:9259`)
- multi-module: `checkModuleFullDiags` (`:12417`), driven by `checkModulesDiags`
  (`:12480`) / `checkModules` (`:12395`); `elaborateModules` (`:12610`) for the
  elaborated tree

Both run `checkCoherence` / `checkInterfaceCycles` / `checkPhantomMethods` /
`checkSuperImpls`. **A new whole-program pass added to one and not the other is
silently absent from half the compiler** — and only the multi-module path is what
`medaka check` on a real project uses.

## Writing tests: a parameter's type is a free var during body inference

A type signature does **not** pre-ground a function's parameter types before the
body is inferred. `processSCC` infers the body with each param as a fresh TVar and
unifies against the declared type *afterwards*. So a body expression that branches
on the *concrete* type of a parameter sees a free var, not the annotated type. To
exercise a type-directed branch, ground the value at the expression itself
(`[1,2,3].[1..2]`, `"abc".[0..1]`), not via a parameter annotation.

## Verify

`main` is protected — work on a branch and land via PR. Before you push:

```sh
medaka fmt --write compiler/types/typecheck.mdk   # pre-commit hook REJECTS unformatted .mdk
medaka lint compiler/types/typecheck.mdk          # hook is a max ratchet: any new finding fails
make preflight                                    # derives the gate set from your diff
```

Then the gates that matter for this file specifically:

```sh
bash test/typecheck_compiler_source.sh     # ← DO NOT SKIP. The build does NOT gate on type
                                           #   errors: an ill-typed compiler passes all 83 gates.
                                           #   This is what the required `soundness` CI check runs.
bash test/diff_compiler_check.sh           # typecheck gate (fixtures)
bash test/diff_compiler_check_modules.sh   # multi-module typecheck
bash test/diff_compiler_check_batch.sh
bash test/diff_compiler_eval.sh            # the typechecker loads the real stdlib — a
                                           #   too-broad new rule that rejects valid stdlib
                                           #   code breaks many gates at once
```

If a change rejects something the stdlib relies on, the prelude fails to load and
many gates break at once — that's the signal your rule is too broad. The usual
culprit is feeding a new global impl check the *seeded* impls instead of
`coherenceUserDecls`.

**The compiler's own source is in the snapshot corpus**, so a change to
`typecheck.mdk` moves its own golden — bless it (by naming the path) in the same
commit, or `main` goes red.

## Diagnosing before fixing

If you're not yet sure which stage or construct is at fault, use the
**debug-pipeline** skill. For raw type dumps, run the typecheck probe entry
(`compiler/entries/typecheck_main.mdk`) — check its `main` for the exact
invocation form. For structured output, `./medaka check --json scratch.mdk`.
