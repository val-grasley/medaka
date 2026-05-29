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
   surfaces shift/reduce conflicts — resolve them, don't ignore new ones.
3. **AST** — `lib/ast.ml`. Add node variants; carry source locations like
   neighboring nodes (LSP and `ParseError` depend on them).
4. **Resolve** — `lib/resolve.ml`. Bind every new name/reference. Add an arm
   for the new node so nothing falls through unresolved.
5. **Typecheck** — `lib/typecheck.ml`. Infer/check types (HM + interfaces +
   effects). If the construct introduces match arms, update exhaustiveness
   feeding into `lib/exhaust.ml`.
6. **Desugar** — `lib/desugar.ml`. If the feature is sugar, lower it to
   existing core nodes here rather than handling it in eval.
7. **Eval** — `lib/eval.ml`. Add evaluation for any node that survives
   desugaring.
8. **Printer/fmt** — `lib/printer.ml` (and `lib/fmt.ml`). Round-trip must hold:
   parse → print → parse yields the same AST. `test_roundtrip` enforces this.

## Surrounding surfaces

- **Tree-sitter** — `tree-sitter-medaka/grammar.js`. Mirror the syntax for
  editor highlighting; regenerate (`npx tree-sitter generate`) and update
  `queries/highlights.scm` + corpus tests. The generated `src/parser.c` is
  committed.
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

Then `dune build @thorough`. Add new cases to the matching `test/test_*.ml`
suites. While iterating, a scratch `.mdk` plus
`./_build/default/bin/main.exe check`/`run` is the fastest loop; for raw
AST/type dumps see the `debug-pipeline` skill.
