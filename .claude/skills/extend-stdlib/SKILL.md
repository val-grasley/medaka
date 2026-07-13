---
name: extend-stdlib
description: Implement or extend a pure-Medaka stdlib function/instance in stdlib/{core,list,string,array}.mdk (function bodies, typeclass impls, doctests, props) — as opposed to native externs. Use when explicitly asked to add stdlib logic per docs/stdlib/STDLIB.md. For native primitives (externs) use add-primitive instead.
---

# Extend the Medaka stdlib (pure-Medaka modules)

Writing `.mdk` library code — list/string/array functions, typeclass impls,
doctests, props. The native-extern path is the separate **add-primitive** skill;
this skill is for code written *in Medaka* on top of the prelude + kernel.

**Division of labor:** the user normally hand-writes the stdlib on purpose (it
stress-tests the language). Only do this when **explicitly asked**. `docs/stdlib/STDLIB.md`
is the checklist/spec; keep its ✅/⏳/🟡/⛔ statuses current as you go.

## Conventions (match existing code)

- **Multi-arg lambdas: `x y => body`**, never curried. Tuple-pattern lambdas
  (`(x, _) => x`, even multi-arg `(a, _) (b, _) => …`) and expression type
  ascription (`([] : List Int)`) both work.
- **Prefer interfaces over datatype-specific code.** Before writing a
  List-specific `maximum`, ask if it generalizes to `(Foldable t, …) => t a`
  in `core` (the prelude → globally in scope). This session moved
  `maximum`/`minimum`/`notElem` to generic and deleted the array/list copies.
- **Readability:** function guards (on indented continuation lines), as-patterns
  (`xs@(x::rest)`, no spaces around `@`), `\{interpolation}`, `flat`/`flatMap`.
- **Perf:** tail-recursive accumulators for long-list traversal (`reverse`); the
  user prioritizes runtime perf over purity (imperative/array internals are fine
  behind a conventional API).
- Effect-polymorphism: thread `<e>` on signatures whose function argument is
  applied, e.g. `takeWhile : (a -> <e> Bool) -> List a -> <e> List a`.

## Language sharp edges that will bite

- **`public export` is for `data` declarations only** (it exposes constructors to
  importers alongside the type). Plain functions/values use plain `export`.
  (The `record` keyword has been **removed** — `data X = { … }` replaces it.)
- An expr RHS can't wrap onto a second indented line (keep it one line).
- A multi-statement lambda body (match inside a fold callback) doesn't work
  inside parentheses — INDENT/DEDENT tokens are suppressed in balanced brackets.
  Use a named helper function or function-style multi-clause definitions instead.

**The following were bugs in early Medaka but are now fixed (Phase 91/121):**
- Guards fall through correctly to the next clause (no longer need `| otherwise`
  on every guarded clause — a standalone `| n <= 0 = []` clause is fine).
- Inline guards on one line (`f n _ | n <= 0 = []`) now parse.
- Point-free impl method bodies now work (eta-expansion was needed pre-Phase 121).

Do NOT follow the old advice in stale comments/docs that says otherwise.

## Build & test loop

1. Edit the `.mdk` file (full **worktree** path).
2. `make medaka` — **required after `core.mdk` edits** (prelude is loaded at
   startup; imports use the on-disk snapshot, so the rebuild is needed for the
   new compiler to pick up the change).
3. `./medaka test stdlib/<mod>.mdk` — runs doctests + props.
   Doctest form: `-- > expr` then `-- result` (or inside a `{- … -}` docstring).
   Probes: `main = println …` (a zero-arg value, NOT `main () = …`).

## Doctest harness traps (all-or-nothing)

**There is no `Show` interface in Medaka.** The rendering interface is **`Debug`**
(`stdlib/core.mdk:264`), method **`debug`**; `Display` (`core.mdk:380`, method
`display`) is the human-facing sibling.

`medaka test` typechecks the WHOLE file (prelude + decls + every synthetic
example) as one program. The harness synthesizes one binding per example —
`__dt_N__ = debug (<your example expr>)` (`compiler/tools/doctest.mdk:250`, name
from `synthName`, `:243`). If ONE example fails to typecheck, **every** example
falls back to broken dispatch and ERRORs with `intToString: expected Int`. To find
the culprit fast: strip the `import` line, append `dN = debug (<example>)` per
example, run `./medaka check` — it names the failing decl.

- A doctest's **result type needs a `Debug` impl reachable in that file's context**
  (core prelude + that file's decls + its imports). The `Debug` impls for `Int`,
  `Float`, `Bool`, `Char`, `String`, `Unit`, `Ordering`, `List`, `Array`, `Option`,
  `Result` and 2–5-tuples are **all in `stdlib/core.mdk`**, so they are always
  reachable. The ones that are NOT: `Map` (`map.mdk`), `Set` (`set.mdk`), `HashMap`
  /`HashSet`, `MutArray`, `Json`, `Toml` — an example whose result is one of those
  needs that module imported in the file under test, or it will not resolve.
- **`core.mdk` `prop`s are prepended to every downstream file's test context**, so
  a core prop that fails to resolve breaks *every* downstream module's test run,
  not just core's. Keep core props narrow and concretely typed; if a generic
  (`Foldable`-constrained) prop leaves its container type ambiguous, pin it with an
  ascription (`([1,2,3] : List Int)`) rather than relying on defaulting.

## Verify

`main` is PROTECTED — branch, then land via PR. Before committing:

```sh
medaka fmt --write stdlib/<mod>.mdk   # the pre-commit hook REJECTS unformatted .mdk
medaka lint stdlib/<mod>.mdk          # the hook is a MAX RATCHET: any new finding fails
```

Then:

```sh
./medaka test stdlib/core.mdk   # and list/string/array
make preflight                  # derives the gate set from your diff
bash test/diff_compiler_check.sh
bash test/diff_compiler_eval.sh
```

Two blast-radius warnings:

- **A `stdlib/core.mdk` change is one of the few cases where a FULL local run is
  justified** — it is the implicit prelude, so it is used everywhere.
- **The compiler may import stdlib modules.** If your change perturbs emitted IR,
  it forces a **seed re-mint + fixpoint re-validation**
  (`bash test/selfcompile_fixpoint.sh`). That is a feature, not a surprise — but
  budget for it.

See memories `project_medaka_eval_harness_gotchas`,
`project_stdlib_doctest_gotchas`, `project_mdk_layout_continuation`,
`feedback_stdlib_perf_over_purity`.
