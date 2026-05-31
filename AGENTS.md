# AGENTS.md

Orientation for AI agents working on **Medaka**, a pragmatic functional
language implemented in OCaml. This file is a *router*: maps, gotchas, and
links. For prose and rationale, follow the links — don't assume detail that
isn't here.

The compiler is one OCaml library, `medaka_lib` (everything in `lib/`).
**There are no `.mli` files** — modules expose everything. Compilation is a
linear pipeline; each stage is one file.

## Pipeline — where each stage lives

```
lexer.mll  →  parser.mly  →  ast.ml  →  resolve.ml  →  typecheck.ml
  → exhaust.ml  →  desugar.ml  →  eval.ml
```

| Stage | File | Role |
|-------|------|------|
| Lex | `lib/lexer.mll` | Indentation-sensitive; emits INDENT/DEDENT/NEWLINE |
| Parse | `lib/parser.mly` | Menhir grammar |
| AST | `lib/ast.ml` | Node types + source locations |
| Resolve | `lib/resolve.ml` | Name binding, single- and multi-module |
| Mark | `lib/method_marker.ml` | Phase 69: runs after desugar+resolve, before typecheck. Rewrites interface-method `EVar`→`EMethodRef` so typecheck can stamp the resolved impl key per call site and eval routes return-position/multi-param dispatch by it |
| Typecheck | `lib/typecheck.ml` | Hindley-Milner + interfaces + effects + exhaustiveness |
| Exhaust | `lib/exhaust.ml` | Maranget pattern-matrix algorithm |
| Desugar | `lib/desugar.ml` | `deriving`, record puns, list comprehensions |
| Eval | `lib/eval.ml` | Tree-walking interpreter; VMulti typeclass dispatch |

Support files:

| File | Role |
|------|------|
| `lib/loader.ml` | Multi-file dependency walk, topo sort, cycle detection; structured `ParseError` (file/line/col) |
| `lib/prelude.ml` | Caches `stdlib/core.mdk` as the implicit prelude |
| `lib/runtime.ml` | Parses `stdlib/runtime.mdk` to derive primitive signatures |
| `lib/diagnostics.ml` | Accumulating error pipeline — phases collect errors, no exit-on-error |
| `lib/printer.ml` / `lib/fmt.ml` | AST→source round-trip / comment-preserving formatter |
| `lib/builtins.ml` | Operator → stdlib method-name registry |
| `lib/lsp_server.ml` | LSP over stdio: diagnostics, formatting, symbols, hover, definition, highlight, completion, inlay hints |
| `lib/project_config.ml` | `medaka.toml` reader + project-root walk-up |
| `gen/embed.ml` | Build-time: embeds `runtime.mdk`/`core.mdk` into generated `lib/stdlib_content.ml` |
| `bin/main.ml` | CLI: `check` / `run` / `repl` / `lsp` / `fmt` / `new` |

`stdlib/`: `runtime.mdk` (extern primitive catalog, embedded), `core.mdk`
(implicit prelude — `Eq`/`Ord`/`Show`/`Num`/…), `list.mdk`/`string.mdk`/`array.mdk`
(written in Medaka).

## Build & test

```sh
dune build      # also regenerates lib/stdlib_content.ml from gen/embed.ml
```

**In a git worktree** (path under `.claude/worktrees/`), plain `dune build`
fails with `No rule found for alias .../default` — dune walks up to the parent
checkout and treats the worktree as a subdir. Build/test with
`dune build --root .` to pin the worktree as the project root.

**Do NOT run `dune test` — it can hang.** Run individual suites instead:

```sh
./_build/default/test/test_<name>.exe --compact
```

Suites: `test_parser` `test_roundtrip` `test_resolve` `test_typecheck`
`test_eval` `test_run` `test_repl` `test_loader` `test_diagnostics` `test_fmt`
`test_project_config` `test_new_cmd` `test_doctest` `test_snapshot`
`test_coverage` `test_lsp`.

Exhaustive edge-case suites: `dune build @thorough`.

Dev probes (build to `_build/default/dev/`):

```sh
./_build/default/dev/debug.exe      # parse-and-print probe
./_build/default/dev/tc_debug.exe   # typecheck probe
```

## Gotchas

- **Environment is pre-set.** opam env vars (switch `5.4.1`, PATH) are already
  exported via `.claude/settings.local.json`. **Never** prefix commands with
  `eval $(opam env)` — it's redundant. *Exception:* a sandboxed shell sometimes
  strips PATH, so `dune` reports `command not found`. If that happens, prepend
  the switch bin inline — `export PATH="$HOME/.opam/5.4.1/bin:$PATH"` — rather
  than reaching for `eval $(opam env)`.
- **Medaka multi-arg lambdas are `x y => body`**, not curried
  `x => y => body`. Curried forms predating Phase 59.6 are legacy artifacts,
  not the current style — match the `x y => body` form in new code.
- **Errors accumulate.** Phases push into `diagnostics.ml` rather than raising
  on the first error; don't add early `exit`/`raise` paths.
- Development is organized by numbered **Phases** — see `PLAN.md`. Commit
  messages and code comments reference them.

## Writing tests

alcotest-based. Tests are self-diagnosing: embed the source under test in the
assertion so failures are readable. Add cases to the suite matching the stage
you changed (e.g. parser change → `test/test_parser.ml`).

## Task playbooks (skills)

For recurring multi-file tasks, load the matching skill rather than
re-deriving the workflow:

- **add-language-feature** — thread a new construct through the whole pipeline.
- **add-primitive** — add/modify a stdlib `extern` primitive.
- **debug-pipeline** — diagnose a parse/typecheck/eval failure.
- **add-lsp-capability** — add/extend an LSP feature.
- **harden-typechecker** — typechecker-*internal* correctness/diagnostics work
  (most of the Phase 62–72 arc): add a `type_error`, tighten constraint/
  coherence/unification logic, without breaking error accumulation or level
  bracketing. Note: cross-cutting dispatch work (Phase 69 done; 69.x dictionary
  passing touches resolve/typecheck/eval + a marker pass) is *not* this skill —
  treat it like **add-language-feature** (thread a node through the pipeline).

## Doc index

| Doc | What's in it |
|-----|--------------|
| `README.md` | Full build/test/CLI usage, editor setup, layout |
| `language-design.md` | Language design & semantics |
| `PLAN.md` | Phase roadmap |
| `STDLIB.md` | Stdlib module plan |
| `stdlib/README.md` | Conventions for adding extern primitives |
