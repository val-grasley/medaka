---
name: harden-typechecker
description: Typechecker-internal correctness and diagnostics work in lib/typecheck.ml — add or refine a type_error, tighten constraint/coherence/unification logic, or fix an over/under-generalization bug. Use for the PLAN.md Phase 62–72 hardening arc, or whenever the fix lives inside the type checker rather than threading new surface syntax.
---

# Harden the typechecker

Almost everything here happens in one file, `lib/typecheck.ml`. The work is
narrower than `add-language-feature` (no lexer/parser/AST changes): you are
making the checker *reject more*, *diagnose better*, or *generalize correctly*,
without disturbing the two invariants below.

Read the relevant PLAN.md phase first — each entry has a **Where.** section with
approximate line numbers and a **Done when.** acceptance test. Those line
numbers drift; confirm with `grep` before trusting them.

## Two invariants you must not break

- **Errors accumulate; phases don't exit on first failure.** They push into
  `lib/diagnostics.ml`. Inside `typecheck.ml` the idiom is `fail (SomeError …)`
  which raises `Type_error`, caught upstream and collected. Don't add early
  `exit`/`raise` paths, and don't short-circuit a later phase because an earlier
  one failed.
- **Level bracketing must be exception-safe.** Generalization uses Rémy levels:
  hand-balanced `enter_level ()` / `exit_level ()` pairs. A `fail` *between* them
  permanently increments `current_level` and corrupts generalization for
  everything after — and the REPL deliberately does **not** `reset_state` between
  inputs. If you add a code path that can `fail` mid-bracket, restore the level
  (a `finally`, or reset at the boundary). This is Phase 71's whole subject.

## Adding a `type_error`

The mechanical loop — four edits, all in `typecheck.ml` unless noted:

1. **Constructor** — add a variant to `type_error` (~the `TypeMismatch … | Other`
   block). Carry enough payload to render a useful message (names + the `mono`s
   involved).
2. **Pretty-printer** — add a case to `pp_error`. Use `pp_mono` for types,
   `pp_scheme` for schemes. Phrase the message as *what's wrong + how to fix*.
3. **Raise site** — `fail (YourError …)` from the phase that detects it.
   `current_loc` supplies the source location automatically *if* it's set;
   several registries (`impl_entry`, etc.) carry no loc, so the message must
   stand on its own.
4. **Test** — add to `test/test_typecheck.ml`. `assert_err src` expects any type
   error; `assert_type src name expected` asserts a successful inferred type.
   Put cases in the group matching the feature, or add a new named group to the
   suite list at the bottom. Tests embed the source inline so failures read
   cleanly.

## Where things live (grep these names, don't trust line numbers)

- **Unification / generalization** — `unify`, `normalize`, `generalize`,
  `instantiate`, `enter_level`/`exit_level`, `fresh_var`.
- **Interfaces & impls** — `register_interface`, `register_impl`, `impl_entry`,
  `iface_info`. Call-site constraint solving: `check_method_usages`,
  `check_constraint_obligations`, `mono_matches` (one-directional wildcard match:
  pattern may have TVars, concrete must be ground).
- **Coherence** — `check_coherence`, `impls_overlap` (bidirectional unification:
  two impls overlap iff their head-type lists unify under one substitution).
  **Seeded (prelude) impls** (`impl_seeded`) are excluded from coherence — user
  impls are *meant* to override them (Phase 45.9) and the same prelude impl can
  appear twice via multi-module imports. Any new global impl check must respect
  that exclusion or it will false-positive on the stdlib itself.
- **Data/record/alias registration** — `register_data`, `register_record`,
  `register_alias`, `expand_aliases`, `from_ast_type`.

## Verify

```sh
export PATH="$HOME/.opam/5.4.1/bin:$PATH"   # only if `dune` is not found
dune build
./_build/default/test/test_typecheck.exe --compact
```

The typechecker loads the real stdlib, so **also run the suites that exercise
it end-to-end** — a too-aggressive new rule that rejects valid stdlib code shows
up here, not in `test_typecheck`:

```sh
for t in eval run loader repl diagnostics; do
  ./_build/default/test/test_$t.exe --compact >/dev/null && echo "$t ok" || echo "$t FAIL"
done
dune build @thorough   # exhaustive edge-case suites
```

If a change rejects something the stdlib relies on, the prelude fails to load
and *many* suites break at once — that's the signal your rule is too broad
(usual culprit: not excluding seeded impls, or treating a legitimate
named/`default` impl as a conflict).

Distinguish that from **expected tightening**: making the checker reject more
will break old `test_typecheck` cases that were written under the looser rule
and are now genuinely unsound (e.g. a Phase 64 super-obligation rule fails
existing `impl Ord T`-without-`impl Eq T` tests). A handful of such failures —
each a `assert_type` program that *should* now error — is correct, not a
regression: update those tests to satisfy the new obligation (or flip them to
`assert_err`). The tell is the count and locus: a few related `test_typecheck`
cases = tightening; the prelude/many-suites collapse = too broad.

## Diagnosing before fixing

If you're not yet sure which stage or construct is at fault, use the
**debug-pipeline** skill and the `dev/tc_debug.ml` probe (edit its hardcoded
`src`, rebuild, run) to dump inferred types.
