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
2. **Parse** — `compiler/frontend/parser.mdk` (hand-written recursive-descent).
   Add grammar productions. Note: a pattern-or-expression *binding position*
   (do-block statement, guard bind `Pat <- e`, lambda params) parses its LHS as an
   **expression** and converts via `exprToPat` (`compiler/frontend/parser.mdk:420`),
   not as a `pat`. Adding pattern syntax usually means extending `exprToPat` — and
   the same change typically must be applied to *all* of those positions together.
   **Keyword-vs-module-name conflict:** if the new keyword might also appear as a
   module ID in `import test.{…}` paths (e.g., a stdlib module named `test`),
   the import-ident rule in the parser must explicitly accept the keyword token
   alongside `IDENT`/`UPPER`, otherwise `import keyword.{…}` becomes a parse
   error. Check whether the keyword name matches any stdlib module file.
3. **AST** — `compiler/frontend/ast.mdk`. Add node variants; carry source
   locations like neighboring nodes (LSP and parse errors depend on them). A new
   `Expr` constructor must get an arm in every exhaustive match over `Expr` in
   the pipeline: `compiler/tools/printer.mdk`, `compiler/frontend/resolve.mdk`,
   `compiler/frontend/desugar.mdk`, `compiler/frontend/marker.mdk`,
   `compiler/types/typecheck.mdk`, `compiler/eval/eval.mdk`,
   `compiler/tools/lsp.mdk`, **and `compiler/ir/core_ir_lower.mdk`** (see step 8 —
   without it the construct runs but does not *build*). Let the compiler's
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
   exhaustiveness — `checkMatchExhaustive` / `checkMatchRedundant`
   (`compiler/types/typecheck.mdk:5841` / `:5862`) call *into*
   `compiler/frontend/exhaust.mdk` (`buildOracle` / `useful` / `usefulWitness`);
   exhaust is not a standalone stage. Per-node `infer`/`check` arms are shared, but
   **whole-program orchestration lives in two near-identical entry points** —
   `checkProgramDiags` (`:11565`, single-file) and `checkModuleFullDiags` (`:12417`,
   multi-module, driven by `checkModulesDiags` `:12480`). A change to registration,
   coherence, or a post-HM pass usually must be mirrored in both.
6. **Desugar** — `compiler/frontend/desugar.mdk`. If the feature is sugar, lower
   it to existing core nodes here rather than handling it in eval. Desugar runs
   **first** (before resolve/marker/typecheck), so a node lowered here can emit
   bare method `EVar`s (e.g. `andThen`/`pure`) that the marker then turns into
   `EMethodRef`/`EDictApp` — bind/return-position dispatch flows through the
   normal dictionary elaboration with no eval-time special-casing. Three things
   bite when adding a pass:
   - **One entry point.** `export desugar : List Decl -> List Decl`
     (`compiler/frontend/desugar.mdk:865`). The REPL calls the *same* one
     (`compiler/tools/repl.mdk:250`), so a pass added there is not silently
     skipped. Bottom-up traversal uses the shared combinators `mapExpr` (`:58`),
     `mapDecl` (`:137`), `mapProg` (`:158`).
   - **Lowering an *existing* surface node** means you also **delete its
     downstream `typecheck`/`eval` arms** — leave a loud guard so a
     pipeline-ordering regression is caught instead of silently mis-evaluated.
   - **Errors from desugar.** Desugar is upstream of typecheck and cannot depend
     on `Typecheck`. To report a user-facing error from a lowering, use the
     diagnostics accumulator directly (see `compiler/driver/diagnostics.mdk`).
7. **Eval** — `compiler/eval/eval.mdk`. Add evaluation for any node that
   survives desugaring. ⚠️ **This is where a construct ships half-done.** After
   this step `medaka run` works and `medaka build` does not. Keep going.
8. **Core IR + BOTH backends** — the step that gets skipped, and the most
   damaging one to skip. Lower the surviving node in
   `compiler/ir/core_ir_lower.mdk` (`export lower : Expr -> CExpr`, `:80`).
   **Prefer lowering to an *existing* `CExpr` shape.** If the feature genuinely
   needs a new `CExpr` constructor (`compiler/ir/core_ir.mdk:55`), every
   exhaustive match over `CExpr` needs an arm — `compiler/ir/core_ir_sexp.mdk`,
   `compiler/ir/core_ir_eval.mdk`, `compiler/backend/trmc_analysis.mdk`, and
   **both emitters**: `compiler/backend/llvm_emit.mdk` **and**
   `compiler/backend/wasm_emit.mdk`. The two backends are independent
   implementations of the same semantics; a node emitted by one and not the other
   is a divergence, not a gap.
9. **Printer/fmt** — `compiler/tools/printer.mdk` and `compiler/tools/fmt.mdk`.
   Round-trip must hold: parse → print → parse yields the same AST.
   `test/diff_compiler_printer.sh` enforces this; `test/diff_compiler_fmt.sh`
   covers the comment-preserving formatter.

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

`main` is PROTECTED — branch, then land via PR (nine required checks, zero
approvals). Build first: `make medaka`. Before committing:

```sh
medaka fmt --write <each changed .mdk>   # the pre-commit hook REJECTS unformatted .mdk
medaka lint <each changed .mdk>          # the hook is a MAX RATCHET: any new finding fails
make preflight                           # derives the gate set from your diff — the agent loop
```

Then the gates for the stages you touched:

```sh
bash test/diff_compiler_check.sh          # front-end + typecheck
bash test/diff_compiler_eval.sh           # eval
bash test/diff_compiler_printer.sh        # printer round-trip
bash test/diff_compiler_check_modules.sh  # multi-module path
```

Because a new construct threads through the compiler's *own* source, also run:

```sh
bash test/typecheck_compiler_source.sh   # the build does NOT gate on type errors —
                                         #   an ill-typed compiler passes all 83 gates.
                                         #   This is what the required `soundness` check runs.
bash test/selfcompile_fixpoint.sh        # decisive for anything touching compiler/backend/
sh   test/diff_compiler_engines.sh       # eval == native == wasm on the same programs.
                                         #   The gate that catches "step 8 was skipped".
```

If the change is **cross-cutting** — a marker/elaboration pass, dispatch, or
anything threaded through the eval drivers — also run the multi-module and
loader-path gates (`test/diff_compiler_eval_modules.sh`,
`test/diff_compiler_core_ir_modules.sh`). Each driver assembles the prelude +
pipeline slightly differently, so a change green in `diff_compiler_eval.sh` can
still break one of them.

Two things that will make `main` go red if you forget them:

- **The compiler's own sources are in the snapshot corpus**, so your source change
  **moves its own golden**. Re-capture and bless it (by NAMING the path) in the
  **same commit**.
- **A fixture directory is a shared corpus.** Adding a fixture enrolls you in gates
  you never named. Before touching one: `grep -rl '<fixture_dir>' test/`, then run
  every consumer.

Don't run the whole suite locally — CI does. For raw AST/type dumps use the entry
probes in `compiler/entries/` — e.g. `compiler/entries/parse_main.mdk`,
`compiler/entries/typecheck_main.mdk`, `compiler/entries/eval_main.mdk` — built with
`make medaka` and invocable via `./medaka run compiler/entries/<probe>.mdk`.

While iterating, a scratch `.mdk` plus `./medaka check`/`run` is the fastest
loop; for deeper pipeline dumps see the `debug-pipeline` skill.
