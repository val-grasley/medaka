---
name: extend-stdlib
description: Implement or extend a pure-Medaka stdlib function/instance in stdlib/{core,list,string,array}.mdk (function bodies, typeclass impls, doctests, props) — as opposed to native externs. Use when explicitly asked to add stdlib logic per STDLIB.md. For native primitives (externs) use add-primitive instead.
---

# Extend the Medaka stdlib (pure-Medaka modules)

Writing `.mdk` library code — list/string/array functions, typeclass impls,
doctests, props. The native-extern path is the separate **add-primitive** skill;
this skill is for code written *in Medaka* on top of the prelude + kernel.

**Division of labor:** the user normally hand-writes the stdlib on purpose (it
stress-tests the language). Only do this when **explicitly asked**. See the
`project-stdlib-division-of-labor` memory. STDLIB.md is the checklist/spec; keep
its ✅/⏳/🟡/⛔ statuses current as you go.

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

- **Guards do NOT fall through to the next equation** (panics `Non-exhaustive
  guards`). Each guarded clause must be self-exhaustive (end with `| otherwise`).
  Put an `n <= 0` guard *inside* the relevant pattern clause, not as a separate
  bare-pattern clause.
- **No inline guards:** `f n _ | n <= 0 = []` is a parse error; guards go on
  indented lines under the clause head.
- **Point-free defs of dispatched methods fail at eval** (`applied non-function:
  <dispatch/N>`). Eta-expand: `maximum xs = fold step None xs`, not
  `maximum = fold step None`.
- An expr RHS can't wrap onto a second indented line (keep it one line).

## Build & test loop

1. Edit the `.mdk` file (full **worktree** path).
2. `dune build --root .` — **required after `core.mdk` edits** (prelude is
   embedded; `run`/imports use the embedded snapshot).
3. `./_build/default/bin/main.exe test stdlib/<mod>.mdk` — runs doctests + props.
   Doctest form: `-- > expr` then `-- result` (or inside a `{- … -}` docstring).
   Probes: `main = println …` (a zero-arg value, NOT `main () = …`).

## Doctest harness traps (all-or-nothing)

`medaka test` typechecks the WHOLE file (prelude + decls + every synthetic
`__dt_N__ = show (example)`) as one program. If ONE example fails to typecheck,
**every** example falls back to broken dispatch and ERRORs with
`intToString: expected Int`. To find the culprit fast: strip the `import` line,
append `dN = show (<example>)` per example, run `medaka check` — it names the
failing decl.

- A doctest's **result type needs a `Show` impl reachable in that file's context**
  (core prelude + that file's decls). `Show Char`/`Show String` live in
  `string.mdk`, NOT core — so a core/list/array doctest returning a `Char`/
  `String` (or `show` of an array, which returns a `String`) fails. Use an
  `Int`/`Bool` example, or `show (...) == "literal"` (Bool needs only core).
- **`core.mdk` `prop`s are prepended to every downstream file's test context.**
  Keep core props to Foldable-*only* fns (`any`/`all`/`length`/`fold`): a prop
  calling generic `elem`/`maximum` (Foldable + `Eq`/`Ord`) mis-defaults to
  `Array` once `default impl Foldable Array` is loaded → `Array vs List`.

## Verify

```sh
./_build/default/bin/main.exe test stdlib/core.mdk   # and list/string/array
./_build/default/test/test_doctest.exe --compact
./_build/default/test/test_typecheck.exe --compact
dune build @thorough --root .
```

See memories `project_medaka_eval_harness_gotchas`,
`project_stdlib_doctest_gotchas`, `project_mdk_layout_continuation`.
