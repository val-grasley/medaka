# AGENTS.md

Orientation for AI agents working on **Medaka**, a pragmatic functional
language implemented in OCaml. This file is a *router*: maps, gotchas, and
links. For prose and rationale, follow the links — don't assume detail that
isn't here.

The compiler is one OCaml library, `medaka_lib` (everything in `lib/`).
**There are no `.mli` files** — modules expose everything. Compilation is a
linear pipeline; each stage is one file.

## Pipeline — where each stage lives

**Execution order** (the drivers in `diagnostics.ml` / `bin/main.ml` run it this
way — *not* the order files happen to be listed):

```
lexer.mll → parser.mly → ast.ml → desugar.ml → resolve.ml → method_marker.ml
  → typecheck.ml (runs exhaust.ml internally) → eval.ml
```

Two non-obvious facts that bite when deciding *where* a check belongs:
- **`desugar.ml` runs first**, before resolve/typecheck. So surface-sugar nodes
  (`EGuards`, `EFunction`, `ESection`, list comprehensions, string interp) are
  **already lowered to core** by the time typecheck/exhaust/eval see the tree. A
  check that needs the sugar shape (e.g. guard *coverage* on `EGuards`) cannot
  live in typecheck/exhaust — it must run pre-desugar (see `Exhaust.
  check_guard_exhaustiveness`, a standalone pass on the raw AST).
- **`exhaust.ml` is not a standalone later stage** — `Exhaust.check_match` is
  *called from inside* `typecheck.ml` (once per `EMatch`, with the scrutinee type
  known). It only ever sees core patterns.

| Stage | File | Role |
|-------|------|------|
| Lex | `lib/lexer.mll` | Indentation-sensitive; emits INDENT/DEDENT/NEWLINE |
| Parse | `lib/parser.mly` | Menhir grammar |
| AST | `lib/ast.ml` | Node types + source locations |
| Desugar | `lib/desugar.ml` | Runs FIRST. Lowers surface sugar: `deriving`, record puns, list comprehensions, `EGuards`/`EFunction`/`ESection`/string-interp |
| Resolve | `lib/resolve.ml` | Name binding, single- and multi-module |
| Mark | `lib/method_marker.ml` | Phase 69: runs after desugar+resolve, before typecheck. Rewrites interface-method `EVar`→`EMethodRef` so typecheck can stamp the resolved impl key per call site and eval routes return-position/multi-param dispatch by it |
| Typecheck | `lib/typecheck.ml` | Hindley-Milner + interfaces + effects; invokes Exhaust per `EMatch` |
| Exhaust | `lib/exhaust.ml` | Maranget pattern-matrix algorithm; called *from* typecheck, not standalone |
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
| `lib/doctest.ml` | Extracts + runs doctests for `medaka test`. Reads the lexer comment side-channel: `-- > expr` then `-- result` lines (block comments `{- … > expr … -}` are expanded to the same line form). Typechecks the *whole file* once, then evals each example; a typecheck failure falls back to broken arg-tag dispatch — so a name collision with a core prelude standalone can make every example ERROR at once |
| `gen/embed.ml` | Build-time: embeds `runtime.mdk`/`core.mdk` into generated `lib/stdlib_content.ml` |
| `bin/main.ml` | CLI: `check` / `run` / `test` (doctests + prop tests) / `repl` / `lsp` / `fmt` / `new` |

`stdlib/`: `runtime.mdk` (extern primitive catalog, embedded), `core.mdk`
(implicit prelude — `Eq`/`Ord`/`Show`/`Num`/…), `list.mdk`/`string.mdk`/`array.mdk`
(written in Medaka).

## Build & test

```sh
dune build      # also regenerates lib/stdlib_content.ml from gen/embed.ml
```

**In a `.claude/worktrees/<name>` worktree, use `dune build --root .`** (and
the same `--root .` for `@thorough`). Plain `dune build` fails with `No rule
found for alias .../default`: the worktree lives physically inside the main
checkout, so dune walks up to the parent repo and treats the worktree as a
subdir. `--root .` pins the worktree as the project root. The built exes still
run from `./_build/default/...` as below.

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
- **In a worktree, build with `dune build --root .`.** When the working
  directory is under `.claude/worktrees/`, a plain `dune build` climbs to the
  parent checkout and fails with `No rule found for alias …/default`. Pass
  `--root .` to pin the build (and tests) to the worktree. Combine with the
  PATH fix above if the sandbox also stripped PATH.
- **In a worktree, edit the worktree's files — use the full worktree path.**
  The shell cwd resets to the main checkout root each call, so a relative
  `grep -n lib/foo.ml` runs there and prints `lib/foo.ml:NN`; Read/Edit that
  bare path and you've silently changed the **main checkout**, which the
  `--root .` build never sees (and which dirties `git status` in main). Always
  target `/…/.claude/worktrees/<name>/lib/foo.ml`. If you slip: `cp` the edited
  files into the worktree, then `git -C <main> checkout -- <files>` to restore
  main.
- **Medaka multi-arg lambdas are `x y => body`**, not curried
  `x => y => body`. Curried forms predating Phase 59.6 are legacy artifacts,
  not the current style — match the `x y => body` form in new code.
- **Errors accumulate.** Phases push into `diagnostics.ml` rather than raising
  on the first error; don't add early `exit`/`raise` paths.
- **`lib/dune` has an explicit `(modules …)` list.** A new `lib/<name>.ml` is
  *not* picked up automatically — add it to that stanza or the build fails with
  `Unbound module Medaka_lib.<Name>`.
- **The prelude (`core.mdk`) is embedded at build time** (`gen/embed.ml` →
  `lib/stdlib_content.ml`). After editing `core.mdk`/`runtime.mdk` you **must
  `dune build`** before `run`/cross-module tests reflect it — they read the
  *embedded* snapshot. Confusing split: `medaka test stdlib/core.mdk` reads the
  file directly (sees edits immediately), but a *different* file importing the
  prelude uses the stale embed until rebuild — symptom is an error citing an old
  `core.mdk` line number.
- **To run a whole program, `main` must be a zero-arg value** (`main = …`), not
  `main () = …`: `medaka run` evaluates top-level bindings and checks `main`
  exists but never *applies* it, so `main () = …` is a silent no-op (exit 0, no
  output). Use `main = println …` for scratch probes.
- **The prelude is marked + dict-passed in the typed pipeline (Phase 69.x-c).**
  `Method_marker.marked_prelude` is the prelude marked against its own interface
  methods + constrained fns; `Typecheck.check_program`/`typecheck_module` prepend
  *it* (filling its `EMethodRef`/`EDictApp` refs in place), and the typed eval
  drivers build `marked_prelude @ user`, `Dict_pass.run` it, and call
  `Eval.eval_program ~prelude:false`.  So elaboration (EMethodRef/EDictApp)
  reaches prelude methods like `pure`/`when`/`unless`.  **Untyped**
  `Eval.eval_program` (default `~prelude:true`, no marker/typecheck — e.g. quick
  eval tests) prepends the *raw* prelude and falls back to arg-tag "first impl
  wins" for return-position methods: `pure` needs types to dispatch, so route it
  through the typed pipeline (see `run_typed` in `test/test_eval.ml`).
- Development is organized by numbered **Phases**. Open/forward work is in
  `PLAN.md`; the completed Phases 1–97 (with implementation notes) are in
  `PLAN-ARCHIVE.md`. Commit messages and code comments reference phase numbers.

## Writing tests

alcotest-based. Tests are self-diagnosing: embed the source under test in the
assertion so failures are readable. Add cases to the suite matching the stage
you changed (e.g. parser change → `test/test_parser.ml`).

## Task playbooks (skills)

For recurring multi-file tasks, load the matching skill rather than
re-deriving the workflow. **Skills are planning inputs, not just
implementation aids** — at task triage (including during plan-mode
exploration, *before* writing the plan) match the task against this table and
load the matching skill. A roadmap/Phase task is the cue: confirm where the
fix lands, then load. (A `UserPromptSubmit` hook,
`.claude/hooks/skill-triage.py`, nudges this on PLAN.md/Phase prompts.)

- **add-language-feature** — thread a new construct through the whole pipeline.
- **add-primitive** — add/modify a stdlib `extern` primitive (native, in `eval.ml`).
- **extend-stdlib** — implement/extend a *pure-Medaka* stdlib function, impl,
  doctest, or prop in `stdlib/{core,list,string,array}.mdk` (per STDLIB.md). Not
  for externs — that's add-primitive. Normally user-reserved; load when asked.
- **debug-pipeline** — diagnose a parse/typecheck/eval failure.
- **add-lsp-capability** — add/extend an LSP feature.
- **harden-typechecker** — typechecker-*internal* correctness/diagnostics work
  (much of the Phase 62–72 arc): add a `type_error`, tighten constraint/
  coherence/unification logic, without breaking error accumulation or level
  bracketing. Note: not every typechecker-flavored Phase item lives *only* in
  the typechecker — and adding a `type_error` does NOT by itself make a task
  this skill. Cross-cutting work is **add-language-feature** instead:
  - Phase 69 dispatch / 69.x dictionary passing — touches resolve/typecheck/eval
    + a marker pass.
  - Phase 63 — `desugar.ml`-rooted (`deriving` for parametric types).
  - Phase 72 (done) — field-name reuse / receiver-directed resolution: added the
    `AmbiguousField` `type_error` but the bulk was a `field_owners` multimap
    threaded through *both* `resolve.ml` and `typecheck.ml`. Looked like harden;
    wasn't.
  - Phase 73 (TODO) — signature-driven parameter typing (bidirectional checking):
    pure inference work, yet a delicate cross-cutting change to the letrec-group
    path, so add-language-feature.
  Check where the fix actually lands before loading this skill.

## Doc index

| Doc | What's in it |
|-----|--------------|
| `README.md` | Full build/test/CLI usage, editor setup, layout |
| `language-design.md` | Language design & semantics |
| `PLAN.md` | Forward-looking roadmap (open phases) |
| `PLAN-ARCHIVE.md` | Completed Phases 1–97 + per-phase implementation notes |
| `STDLIB.md` | Stdlib module plan |
| `stdlib/README.md` | Conventions for adding extern primitives |
