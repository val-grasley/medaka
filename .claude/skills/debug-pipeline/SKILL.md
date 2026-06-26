---
name: debug-pipeline
description: Diagnose a Medaka parse, resolve, typecheck, or eval failure — isolate which pipeline stage is at fault using the entry probes and the diagnostics accumulator. Use when a .mdk program errors unexpectedly, a test fails opaquely, or you need to narrow down a compiler bug.
---

# Debug a pipeline failure

Medaka's stages run in order (lex → parse → resolve → typecheck → exhaust →
desugar → eval). The goal is to find the *first* stage that misbehaves, then
read its source. Errors don't abort on first failure — they accumulate in
`compiler/driver/diagnostics.mdk`, so a later-stage message may be downstream
of an earlier real cause.

## Isolate the stage

Build first: `make medaka`. The primary loop is a scratch `.mdk` file plus the
CLI, which reads real files and reports full accumulated diagnostics:

```sh
./medaka check scratch.mdk   # front end only (no eval)
./medaka run   scratch.mdk   # full pipeline incl. eval
```

Reason about which stage owns the failure:

- **Parse** — error with file/line/col (structured `ParseError` from
  `compiler/driver/loader.mdk`) → bug in `compiler/frontend/lexer.mdk` or
  `compiler/frontend/parser.mdk`.
- **Resolve/Typecheck** — unbound name, type mismatch, or non-exhaustive-match
  warning → `compiler/frontend/resolve.mdk`, `compiler/types/typecheck.mdk`,
  `compiler/frontend/exhaust.mdk`. Errors are collected by
  `compiler/driver/diagnostics.mdk` (no exit-on-error), so a later message can
  be downstream of an earlier real cause — fix the first one.
- **Eval** — type-checks but produces the wrong value → `compiler/eval/eval.mdk`
  (or `compiler/frontend/desugar.mdk` if the construct is sugar).

## Entry probes — raw AST / type dumps

For internals the CLI doesn't print, use the entry probes in
`compiler/entries/`. These are standalone `.mdk` programs built into the
`./medaka` binary; run them with `./medaka run compiler/entries/<probe>.mdk`:

- `compiler/entries/parse_main.mdk` — dump the parsed AST for a file
- `compiler/entries/typecheck_main.mdk` — dump inferred types
- `compiler/entries/eval_main.mdk` — run a single file through eval
- `compiler/entries/eval_modules_main.mdk` — run through the multi-module loader
- `compiler/entries/resolve_main.mdk` — dump resolved names

These probes read the target file path as their argument — check each entry's
`main` for the exact invocation form.

**A dispatch bug that reproduces through the loader but is a green single-file
run is *usually* the eval driver, not dict-passing** — the loader's
`evalModules` uses per-module frames and a separate prelude/install order, so
binding-order and impl-install-order bugs surface *only* there. Use
`eval_modules_main.mdk` to drive both paths and compare. (See AGENTS.md
Gotchas for the full counterexample and the instrument-eval's-resolution-arms
technique when the heuristic fails.)

## Build a minimal repro

Shrink the failing program to the smallest snippet that still reproduces. Once
fixed, add it as a regression fixture in the matching `test/diff_compiler_*.sh`
gate (e.g. a new file under `test/fixtures/` and a `check` or `eval` run in the
relevant script).

## Tips

- For LSP-surfaced errors, run `bash test/diff_compiler_lsp.sh` and
  `test/lsp_harness.sh`.
- For multi-module bugs, run `bash test/diff_compiler_check_modules.sh` and
  `bash test/diff_compiler_eval_modules.sh` (if present) to isolate the loader
  path.
