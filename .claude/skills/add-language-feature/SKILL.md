---
name: add-language-feature
description: Thread a new language construct (syntax/expression/declaration/pattern) through the full Medaka compiler pipeline — lexer, parser, AST, resolver, type checker, exhaustiveness, desugar, evaluator — plus grammar, LSP, and tests. Use when adding or extending Medaka language syntax or semantics.
---

# Add a language feature end-to-end

Medaka compiles through a linear pipeline of single-file stages (see
`AGENTS.md`). A new construct touches each stage in order. Work the list
top-to-bottom; not every feature needs every stage, but check each.

When you emit **Medaka** code in examples/tests, use multi-arg lambda form
`x y => body`, never curried `x => y => body`.

## Stage checklist

1. **Lex** — `lib/lexer.mll`. New keyword/operator/token? Add the rule. The
   lexer is indentation-sensitive (INDENT/DEDENT/NEWLINE); be careful with
   layout-significant tokens.
2. **Parse** — `lib/parser.mly` (Menhir). Add grammar productions. Rebuild
   surfaces shift/reduce conflicts — resolve them, don't ignore new ones. The
   conflict count is the acceptance gate for a grammar change: measure it before
   and after with `grep -c '^** Conflict' _build/default/lib/parser.conflicts`
   and keep it from rising. The audit comment block at the top of `parser.mly`
   explains each conflict, but **don't trust its stated count — re-measure**; it
   has gone stale. Note: a pattern-or-expression *binding position* (do-block
   `stmt`, list-comp `lc_qual` generator, `guard_qual` bind, lambda params)
   parses its LHS as an **expression** and converts via `expr_to_pat`, not as a
   `pat` (a `pat`-LHS reduce/reduce-conflicts with the bare-expression case).
   Adding pattern syntax usually means extending `expr_to_pat` — and the same
   change typically must be applied to *all* of those positions together.
3. **AST** — `lib/ast.ml`. Add node variants; carry source locations like
   neighboring nodes (LSP and `ParseError` depend on them). A new `expr`
   constructor must get an arm in every *exhaustive* match over `expr` or the
   build fails: `pp_expr` (`ast.ml`), `expr_prec` **and** `print_expr_raw`
   (`printer.ml`), `collect_expr` (`coverage.ml`), and `check_expr`
   (`resolve.ml`). `strip_locs_expr` (`ast.ml`) and `map_expr` (`desugar.ml`)
   have catch-alls, so a leaf node falls through them safely. Let the compiler's
   non-exhaustive warnings drive you to each site.
4. **Resolve** — `lib/resolve.ml`. Bind every new name/reference. Add an arm
   for the new node so nothing falls through unresolved.
5. **Typecheck** — `lib/typecheck.ml`. Infer/check types (HM + interfaces +
   effects). If the construct introduces match arms, update exhaustiveness
   feeding into `lib/exhaust.ml`. Per-node `infer`/`check_expr` arms are shared,
   but **whole-program orchestration lives in two near-identical entry points** —
   `check_program_impl` (single-file) and `typecheck_module` (multi-module use-
   decls), each with its own `process_letrec_group`/results/final-pass block. A
   change to group processing, constraint registration, or a post-HM pass usually
   must be mirrored in both; and when a typechecker probe "won't fire," confirm
   it's on the path your driver hits (`check_program` → `check_program_impl`)
   rather than assuming a stale build (compare exe vs `.cmx` mtime).
6. **Desugar** — `lib/desugar.ml`. If the feature is sugar, lower it to
   existing core nodes here rather than handling it in eval. Desugar runs
   **first** (before resolve/marker/typecheck), so a node lowered here can emit
   bare method `EVar`s (e.g. `andThen`/`pure`) that the marker then turns into
   `EMethodRef`/`EDictApp` — bind/return-position dispatch flows through the
   normal dictionary elaboration with no eval-time special-casing (Phase 99
   lowered `EDo` exactly this way). Three things bite when adding a pass:
   - **Two entry points.** `desugar_program` (the program pass — add your
     `map_decl rewrite` step to its pipeline, minding *order*, e.g. `?`-rewrite
     before do-lowering) **and** `desugar_expr` (standalone-expr pass used by the
     REPL — applies the rewrites individually). A new pass usually belongs in
     *both* or the REPL silently skips it.
   - **Lowering an *existing* surface node** (vs. adding a new one) means you also
     **delete its downstream `typecheck`/`eval` arms** — leave a loud guard
     (`assert false` / `fail (InternalError "X survived desugar")`) so a
     pipeline-ordering regression is caught instead of silently mis-evaluated.
   - **Errors from desugar.** Desugar is *upstream of* typecheck (and
     `typecheck.ml` already `open`s/refs `Desugar`, so desugar **cannot** depend
     on `Typecheck` — no `Typecheck.Type_error`). To report a user-facing error
     from a lowering, raise a `Desugar`-local exception and catch it at **every**
     driver's `Type_error` site: `bin/main.ml` (single + multi-module),
     `lib/diagnostics.ml` (single + multi), and the test harness `check` helpers.
     `Desugar.desugar_program` has ~12 call sites — grep them; the trusted ones
     (prelude, valid fixtures) never raise, but user-facing drivers must catch.
7. **Eval** — `lib/eval.ml`. Add evaluation for any node that survives
   desugaring.
8. **Printer/fmt** — `lib/printer.ml` (and `lib/fmt.ml`). Round-trip must hold:
   parse → print → parse yields the same AST. `test_roundtrip` enforces this.

## Nodes introduced by a pass, not the parser

Not every construct enters through the lexer/parser. A *transparent* node —
created by a pipeline pass and invisible to surface syntax — skips steps 1–2
entirely. Precedent: Phase 69's `EMethodRef` and 69.x's `EDictApp` are installed
by `lib/method_marker.ml` (after resolve, before typecheck) and consumed by
typecheck + eval; the parser, printer, and `fmt` never produce them. For such a
node: add the constructor (step 3) with its exhaustive-match arms, give it a
trivial/transparent `pp_expr`/`printer` arm (it isn't round-tripped), thread it
through typecheck + eval, and **add any new `lib/<name>.ml` pass to the
`(modules …)` stanza in `lib/dune`** (it is not auto-discovered — see AGENTS.md).
A pass that *changes a node's shape* (e.g. inserting parameters) runs after
typecheck and returns a new tree, so the driver must consume its return value;
a pass that only fills mutable refs can mutate in place and needs no rewiring.

## Surrounding surfaces

- **Tree-sitter** — `tree-sitter-medaka/grammar.js`. Mirror the syntax for
  editor highlighting and update `queries/highlights.scm` + corpus tests
  (`test/corpus/*.txt`). **`npx tree-sitter generate` fails locally** (CLI
  0.21.0 rejects the block-comment rule's `\{-[^]*?-\}` regex — reproduces at
  HEAD, unrelated to your edit), so you usually **cannot** regenerate the
  committed `src/parser.c` / `src/grammar.json` here. Hand-edit `grammar.js` +
  corpus, leave the generated artifacts at HEAD (consistent with each other),
  and let CI / a compatible tree-sitter regenerate — never commit a
  half-generated `grammar.json`. Note `tree-sitter-medaka/` lives in the **main**
  git repo (not a submodule), so `git stash`/`checkout` run from inside it act
  on the *whole* working tree — commit a WIP checkpoint before any risky git op.
- **LSP** — usually inherited via the pipeline, but check `lib/lsp_server.ml`
  if the feature affects hover/completion/symbols. For substantial LSP work use
  the `add-lsp-capability` skill.

## Verify

Run the suite for each stage you touched (from repo root):

```sh
./_build/default/test/test_parser.exe --compact
./_build/default/test/test_roundtrip.exe --compact
./_build/default/test/test_typecheck.exe --compact
./_build/default/test/test_eval.exe --compact
./_build/default/test/test_run.exe --compact
```

If the change is **cross-cutting** — a marker/elaboration pass, dispatch, or
anything threaded through the eval drivers — also run the driver-specific
suites: `test_loader` (multi-module), `test_repl` (incremental; seeds its own
prelude), and `test_doctest`. Each driver assembles the prelude + pipeline
slightly differently, so a change that's green in `test_run` can still break
one of them. Note `test_eval`'s default `run` helper is **untyped**
(`Eval.eval_program`, no marker/typecheck), so return-position dispatch (e.g.
`pure`) only resolves through its `run_typed` helper — use that for monadic /
return-position cases.

Then `dune build @thorough`. Add new cases to the matching `test/test_*.ml`
suites. While iterating, a scratch `.mdk` plus
`./_build/default/bin/main.exe check`/`run` is the fastest loop; for raw
AST/type dumps see the `debug-pipeline` skill.
