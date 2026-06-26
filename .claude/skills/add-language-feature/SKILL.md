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

1. **Lex** — `compiler/frontend/lexer.mdk`. New keyword/operator/token? Add the
   rule. The lexer is indentation-sensitive (INDENT/DEDENT/NEWLINE); be careful
   with layout-significant tokens.
2. **Parse** — `compiler/frontend/parser.mdk` (hand-written recursive-descent,
   NOT Menhir). Add grammar productions. Note: a pattern-or-expression *binding
   position* (do-block `stmt`, list-comp `lc_qual` generator, `guard_qual` bind,
   lambda params) parses its LHS as an **expression** and converts via
   `exprToPat`, not as a `pat`. Adding pattern syntax usually means extending
   `exprToPat` — and the same change typically must be applied to *all* of those
   positions together.
   **Keyword-vs-module-name conflict:** if the new keyword might also appear as a
   module ID in `import test.{…}` paths (e.g., a stdlib module named `test`),
   the import-ident rule in the parser must explicitly accept the keyword token
   alongside `IDENT`/`UPPER`, otherwise `import keyword.{…}` becomes a parse
   error. Check whether the keyword name matches any stdlib module file.
3. **AST** — `compiler/frontend/ast.mdk`. Add node variants; carry source
   locations like neighboring nodes (LSP and parse errors depend on them). A new
   `Expr` constructor must get an arm in every exhaustive match over `Expr` in
   the pipeline: `compiler/frontend/printer.mdk`, `compiler/frontend/resolve.mdk`,
   `compiler/frontend/desugar.mdk`, `compiler/types/typecheck.mdk`,
   `compiler/eval/eval.mdk`, `compiler/tools/lsp.mdk`. Let the compiler's
   non-exhaustive warnings guide you.
   **New `Decl` variant**: several files delegate via a catch-all `mapDecl`
   arm; add an explicit arm to `mapDecl` in `compiler/frontend/desugar.mdk` that
   recurses into the new variant's sub-expressions — then files that use that
   delegation need no explicit arm. Files that do NOT delegate and always need
   explicit arms: `compiler/frontend/exhaust.mdk` (guard recursion),
   `compiler/tools/lsp.mdk` (symbols + `declDefines`). Let non-exhaustive
   warnings guide you.
4. **Resolve** — `compiler/frontend/resolve.mdk`. Bind every new name/reference.
   Add an arm for the new node so nothing falls through unresolved.
5. **Typecheck** — `compiler/types/typecheck.mdk`. Infer/check types (HM +
   interfaces + effects). If the construct introduces match arms, update
   exhaustiveness feeding into `compiler/frontend/exhaust.mdk`. Per-node
   `infer`/`checkExpr` arms are shared, but **whole-program orchestration lives
   in two near-identical entry points** — `checkProgramImpl` (single-file) and
   `typecheckModule` (multi-module imports), each with its own
   `processLetrecGroup`/results/final-pass block. A change to group processing,
   constraint registration, or a post-HM pass usually must be mirrored in both.
6. **Desugar** — `compiler/frontend/desugar.mdk`. If the feature is sugar, lower
   it to existing core nodes here rather than handling it in eval. Desugar runs
   **first** (before resolve/marker/typecheck), so a node lowered here can emit
   bare method `EVar`s (e.g. `andThen`/`pure`) that the marker then turns into
   `EMethodRef`/`EDictApp` — bind/return-position dispatch flows through the
   normal dictionary elaboration with no eval-time special-casing. Three things
   bite when adding a pass:
   - **Two entry points.** `desugarProgram` (the program pass) **and**
     `desugarExpr` (standalone-expr pass used by the REPL). A new pass usually
     belongs in *both* or the REPL silently skips it.
   - **Lowering an *existing* surface node** means you also **delete its
     downstream `typecheck`/`eval` arms** — leave a loud guard so a
     pipeline-ordering regression is caught instead of silently mis-evaluated.
   - **Errors from desugar.** Desugar is upstream of typecheck and cannot depend
     on `Typecheck`. To report a user-facing error from a lowering, use the
     diagnostics accumulator directly (see `compiler/driver/diagnostics.mdk`).
7. **Eval** — `compiler/eval/eval.mdk`. Add evaluation for any node that
   survives desugaring.
8. **Printer/fmt** — `compiler/tools/printer.mdk` and `compiler/tools/fmt.mdk`.
   Round-trip must hold: parse → print → parse yields the same AST.
   `test/diff_compiler_roundtrip.sh` enforces this.

## Nodes introduced by a pass, not the parser

Not every construct enters through the lexer/parser. A *transparent* node —
created by a pipeline pass and invisible to surface syntax — skips steps 1–2
entirely. Precedent: `EMethodRef` and `EDictApp` are installed by
`compiler/frontend/marker.mdk` (after resolve, before typecheck) and consumed
by typecheck + eval; the parser, printer, and fmt never produce them. For such
a node: add the constructor (step 3) with its exhaustive-match arms, give it a
trivial/transparent printer arm (it isn't round-tripped), thread it through
typecheck + eval. No modules list to update — the compiler is one Medaka
codebase with automatic imports.

## Surrounding surfaces

- **Tree-sitter** — `tree-sitter-medaka/grammar.js`. Mirror the syntax for
  editor highlighting and update `queries/highlights.scm` + corpus tests
  (`test/corpus/*.txt`). **`npx tree-sitter generate` fails locally** (CLI
  0.21.0 rejects the block-comment rule's regex — reproduces at HEAD, unrelated
  to your edit), so you usually **cannot** regenerate the committed
  `src/parser.c` / `src/grammar.json` here. Hand-edit `grammar.js` + corpus,
  leave the generated artifacts at HEAD, and let CI / a compatible tree-sitter
  regenerate — never commit a half-generated `grammar.json`.
- **LSP** — usually inherited via the pipeline, but check `compiler/tools/lsp.mdk`
  if the feature affects hover/completion/symbols. For substantial LSP work use
  the `add-lsp-capability` skill.

## Verify

Build first: `make medaka`. Then run the diff gates for each stage you touched:

```sh
bash test/diff_compiler_check.sh          # front-end + typecheck
bash test/diff_compiler_eval.sh           # eval
bash test/diff_compiler_roundtrip.sh      # printer round-trip
bash test/diff_compiler_check_modules.sh  # multi-module path
```

If the change is **cross-cutting** — a marker/elaboration pass, dispatch, or
anything threaded through the eval drivers — also run the multi-module and
loader-path gates. Each driver assembles the prelude + pipeline slightly
differently, so a change green in `diff_compiler_eval.sh` can still break one
of them.

For the full suite: `make test` or run the relevant `test/diff_compiler_*.sh`
gates. For raw AST/type dumps use the entry probes in `compiler/entries/` — e.g.
`compiler/entries/parse_main.mdk`, `compiler/entries/typecheck_main.mdk`,
`compiler/entries/eval_main.mdk` — built with `make medaka` and invocable via
`./medaka run compiler/entries/<probe>_main.mdk`.

While iterating, a scratch `.mdk` plus `./medaka check`/`run` is the fastest
loop; for deeper pipeline dumps see the `debug-pipeline` skill.
