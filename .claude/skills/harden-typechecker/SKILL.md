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
  permanently increments `current_level`. **Nuance confirmed in Phase 71:** the
  whole-program entry points (`check_program`, `typecheck_module`) call
  `reset_state` on entry, so a leak there is wiped before the next run; and
  within a single run the leak is *relative* — each `process_letrec_group`
  brackets against whatever base it starts at and generalizes against that same
  base, so a uniform leak does **not** by itself break generalization (a test
  that "exercises a level leak" via two sequential definitions will *not*
  discriminate — don't write one). The real exposure is the **REPL**, which
  reuses typechecker state and (to preserve the TVar counter) does *not* call
  `reset_state`: a leak there violates the absolute "top-level names pre-bound at
  level 1" invariant (§2.9). Phase 71's fix: `check_repl_decl` resets
  `current_level := 0` at each input boundary. Still: if you add a path that can
  `fail` mid-bracket, prefer restoring the level (a `finally`, or reset at the
  boundary).

## Broken invariants are diagnostics, not crashes (Phase 71)

There is **no `assert false` left in `typecheck.ml`** — don't reintroduce one.
For a "can't happen" invariant violation, `fail (InternalError "context")`
(a `type_error` variant that renders as "Internal type-checker error: …"); it's
catchable and survives the REPL. **Exception:** a *rendering* path must never
raise — `pp_mono`'s post-`normalize` `Link` case returns the placeholder `"_"`
rather than failing, because it runs while formatting an error message. Also
guard `Hashtbl.find` that can miss across module boundaries (`env.interfaces`,
`env.records`): fall back to the matching user-facing error (`UnknownInterface`,
`UnknownRecord`) or degrade gracefully (e.g. `n_iface_params` returns 0 → skips
the usage) rather than letting a raw `Not_found` escape.

## Generalization is value-restricted (Phase 66)

`let`/`do`-`let` bindings are only generalized when their RHS is a **syntactic
value**. The gate is `is_nonexpansive` (literal / var / lambda; tuple or
list-literal of values; `ELoc`/`EAnnot` transparent — *everything else,
including all applications, is expansive*). Generalization goes through
`gen_restricted is_value t` (not bare `generalize`) at every binding site: `ELet`
`PVar`, `DoLet` in `EBlock`/`EDo`, per-binding in `ELetGroup`, and the top-level
non-letrec path in `process_letrec_group`.

The non-obvious rule if you touch any of this: **a non-generalized binding must
have its free vars *lowered* to `current_level`, not merely wrapped in
`monotype`.** Otherwise the vars sit at a deeper level and an *enclosing* `let`'s
`generalize` picks them up — reopening the unsoundness one scope out.
`gen_restricted` does this via `lower_to_current`; the non-`PVar` pattern path
gets it for free because `unify tp t1` lowers through `occurs_adjust`. Note
`Ref` is a *constructor* (`extern Ref : a -> Ref a`), so — like SML/OCaml's
`ref` — constructor applications are deliberately expansive; do not add a
"constructor application of values is a value" carve-out or `r = Ref []` becomes
polymorphic again.

## Adding a `type_error`

The mechanical loop — four edits, all in `typecheck.ml` unless noted:

1. **Constructor** — add a variant to `type_error` (~the `TypeMismatch … | Other`
   block). Carry enough payload to render a useful message (names + the `mono`s
   involved).
2. **Pretty-printer** — add a case to `pp_error`. Use `pp_mono` for a single
   type, `pp_scheme` for schemes. **When a message names two or more types**
   (a mismatch, or two impl-head arg lists), render them through one shared
   naming context — `pp_mono_pair a b` / `pp_monos args` / `pp_monos_pair a b`
   (Phase 70) — not separate `pp_mono` calls, or two distinct tyvars can both
   print as `a`. Phrase the message as *what's wrong + how to fix*.
3. **Raise site** — `fail (YourError …)` from the phase that detects it.
   `fail` reads the global `current_loc`, which is correct *during* the `infer`
   walk but **stale in post-HM passes** (`check_method_usages`,
   `check_constraint_obligations`) — by then it points at the last expression
   inferred. If your error fires from a deferred/post-HM pass, capture
   `!current_loc` into the accumulator tuple at record time and raise with
   `fail_at loc …` instead (Phase 62 did exactly this for the two constraint
   passes — follow that pattern). Some registries (`impl_entry`, etc.) still
   carry no loc, so when none is available the message must stand on its own.
4. **Test** — add to `test/test_typecheck.ml`. `assert_err src` expects any type
   error; `assert_type src name expected` asserts a successful inferred type;
   `assert_err_at ~line src` (Phase 62) asserts the error is reported at a
   specific call-site line and not in the prelude — use it for any
   location-sensitive diagnostic. Put cases in the group matching the feature,
   or add a new named group to the suite list at the bottom. Tests embed the
   source inline so failures read cleanly. **Watch for prelude name
   collisions:** an `assert_err` fixture that reuses a stdlib interface name
   (e.g. `Monoid`) may pass on a *duplicate-interface* error rather than the
   error you intend — use a fresh name so the test exercises what it claims.

## Where things live (grep these names, don't trust line numbers)

- **Unification / generalization** — `unify`, `normalize`, `generalize`,
  `instantiate`, `enter_level`/`exit_level`, `fresh_var`. Value restriction:
  `is_nonexpansive`, `gen_restricted`, `lower_to_current` (see section above).
- **Interfaces & impls** — `register_interface`, `register_impl`, `impl_entry`,
  `iface_info`. Call-site constraint solving is a *family* of post-HM passes that
  share `matching_impls` + the top-level `is_concrete` + `fail_at loc`:
  `check_method_usages`, `check_constraint_obligations`,
  `check_superinterface_obligations` (Phase 64), `check_entry_requires`
  (Phase 65, recurses for nested `requires`). `mono_matches` is the
  one-directional wildcard match (pattern may have TVars, concrete must be
  ground). Two payoffs to remember: (1) folding a new obligation check *into* the
  selection passes (rather than a new standalone pass) covers all the
  `typecheck_*` entry points at once — grep `check_method_usages` to confirm
  every entry point still calls the pair; (2) to *correlate* a TVar across two
  obligations (e.g. an impl's head `a` and its `requires Eq a`), build an
  id-keyed substitution with the `impls_overlap` idiom and apply it
  non-destructively — never `Link` a registry TVar, the `impl_entry` is shared
  across call sites.
- **Coherence** — `check_coherence`, `impls_overlap` (bidirectional unification:
  two impls overlap iff their head-type lists unify under one substitution).
  **Seeded (prelude) impls** (`impl_seeded`) are excluded from coherence — user
  impls are *meant* to override them (Phase 45.9) and the same prelude impl can
  appear twice via multi-module imports. Any new global impl check must respect
  that exclusion or it will false-positive on the stdlib itself.
- **Data/record/alias registration** — `register_data`, `register_record`,
  `register_alias`, `expand_aliases`, `from_ast_type`. **Gotcha:** plain
  `from_ast_type` mints a *fresh* TVar table per call, so the same source name
  `a` in two separate calls becomes two unrelated TVars. When two `ty` values
  must share variables (impl head ↔ `requires`, signature ↔ its constraints),
  thread one table: pass `~tbl` to `from_ast_type`, or follow
  `from_ast_type_with_constraints`, which already shares a `tbl` for exactly this
  reason.

## Writing tests: a parameter's type is a free var during body inference

A type signature does **not** pre-ground a function's parameter types before the
body is inferred. `process_letrec_group` infers the body with each param as a
fresh TVar and unifies the result against the declared type *afterwards*. So a
body expression that branches on the *concrete* type of a parameter (e.g.
`ESlice`'s "is the container Array/List/String?") sees a free var, not the
annotated type. Practical fallout for tests: `f : List Int -> List Int` /
`f xs = xs.[1..3]` does **not** type the slice as `List` — the container is
still a TVar at that point (so e.g. `ESlice` falls back to its Array default).
To exercise a type-directed branch, ground the value at the expression itself
(`[1,2,3].[1..2]`, `"abc".[0..1]`), not via a parameter annotation.

## Verify

```sh
export PATH="$HOME/.opam/5.4.1/bin:$PATH"   # only if `dune` is not found
dune build                                  # add --root . inside a .claude/worktrees/ checkout
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
