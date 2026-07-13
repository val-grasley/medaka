---
name: debug-pipeline
description: Diagnose a Medaka parse, resolve, typecheck, or eval failure — isolate which pipeline stage is at fault using the entry probes and the diagnostics accumulator. Use when a .mdk program errors unexpectedly, a test fails opaquely, or you need to narrow down a compiler bug.
---

# Debug a pipeline failure

The goal is to find the *first* stage that misbehaves, then read its source.
Errors don't abort on first failure — they accumulate in
`compiler/driver/diagnostics.mdk`, so a later-stage message may be downstream of
an earlier real cause.

**The real execution order** (driven by `compiler/driver/medaka_cli.mdk`):

```
lexer → parser → desugar → resolve → marker → typecheck → eval
```

Two facts that decide *where a bug can possibly live* — get these wrong and you
will bisect in the wrong half of the compiler:

- **`desugar` runs FIRST**, before resolve/typecheck — not last. So the surface
  sugar nodes (`EGuards`, `EFunction`, `ESection`, string interpolation, `EDo`)
  are **already lowered to core** by the time resolve/typecheck/eval see the tree.
  A misbehaviour that needs the *sugar shape* to explain it is a `desugar.mdk` bug,
  and it cannot be downstream of typecheck.
- **`exhaust` is NOT a stage in the chain.** `compiler/frontend/exhaust.mdk` is
  called *from inside* `compiler/types/typecheck.mdk` — once per `EMatch`, with the
  scrutinee type known (`checkMatchExhaustive` / `checkMatchRedundant`,
  `typecheck.mdk:5841` / `:5862`). (The one exception is
  `checkGuardExhaustiveness` (`exhaust.mdk:835`), a standalone pass on the RAW
  pre-desugar AST.)
- **`marker` (`compiler/frontend/marker.mdk`) runs between resolve and typecheck**
  and is where interface-method `EVar`s become `EMethodRef`/`EDictApp`. It owns the
  most common bug class this skill exists for — **dispatch**.

## Isolate the stage

Build first: `make medaka`. The primary loop is a scratch `.mdk` file plus the
CLI, which reads real files and reports full accumulated diagnostics:

```sh
./medaka check scratch.mdk          # front end only (no eval)
./medaka check --json scratch.mdk   # ← REACH FOR THIS. One JSON object per diagnostic,
                                    #   carrying a STABLE `code` (T-* type · R-* resolve ·
                                    #   P-* parse · L-* lex · W-* warning), `kind`, a real
                                    #   `range`, `severity`, `message`, and — where the
                                    #   compiler can offer one — `help` + a machine-applicable
                                    #   `fix { range, replacement }`.
./medaka run   scratch.mdk          # full pipeline incl. eval
```

The `code` prefix tells you which stage owns the failure before you read a line of
source. Key off `code`, not the wording — it is the stable handle.

Reason about which stage owns the failure:

- **Parse** (`P-*` / `L-*`) — error with file/line/col (structured `ParseError` from
  `compiler/driver/loader.mdk`) → bug in `compiler/frontend/lexer.mdk` or
  `compiler/frontend/parser.mdk`.
- **Resolve/Typecheck** (`R-*` / `T-*` / `W-*`) — unbound name, type mismatch, or
  non-exhaustive-match warning → `compiler/frontend/resolve.mdk`,
  `compiler/types/typecheck.mdk`, `compiler/frontend/exhaust.mdk`. Errors are
  collected by `compiler/driver/diagnostics.mdk` (no exit-on-error), so a later
  message can be downstream of an earlier real cause — **fix the first one.**
- **Wrong value at runtime** — do NOT jump straight to `compiler/eval/eval.mdk`.
  See "Is it a run≠build miscompile?" below: there are **three** engines and eval is
  only one of them.

## Is it a run≠build miscompile?

Medaka has **three implementations of its own semantics** — the tree-walking
interpreter (`medaka run`), the LLVM backend (`medaka build`), and the WasmGC
backend. A "wrong value" bug may be in any of them, and the repo has a whole
category of bugs where `run` was right and `build` was wrong (or vice versa).

**First: does the bug survive the change of engine?**

```sh
sh test/diff_compiler_engines.sh   # eval == native == wasm on the same programs
                                   # known-divergence ledger: test/engine_divergence.txt
```

- Same wrong answer in all three → a **front-end / semantics** bug (desugar,
  resolve, marker, typecheck).
- `run` right, `build` wrong → an **emitter** bug
  (`compiler/backend/llvm_emit.mdk`, or the Core IR lowering in
  `compiler/ir/core_ir_lower.mdk`).
- ⚠️ **`medaka build` shells out to `./medaka_emitter`.** A fix you just made to
  the emitter is **not in the binary you just ran** unless you rebuild it:
  `FORCE_EMITTER_REBUILD=1 make medaka`. This trap has cost agents entire sessions.

## Entry probes — raw AST / type dumps

For internals the CLI doesn't print, use the entry probes in
`compiler/entries/`. These are standalone `.mdk` programs built into the
`./medaka` binary; run them with `./medaka run compiler/entries/<probe>.mdk`:

- `compiler/entries/parse_main.mdk` — dump the parsed AST for a file
- `compiler/entries/resolve_main.mdk` — dump resolved names
- `compiler/entries/typecheck_main.mdk` — dump inferred types
- `compiler/entries/eval_typed_main.mdk` — the **single-file** typed eval path
- `compiler/entries/eval_modules_main.mdk` — the **multi-module loader** path
- `compiler/entries/eval_main.mdk` — untyped single-file eval

These probes read the target file path as their argument — check each entry's
`main` for the exact invocation form.

## The signature bug shape: loader-only dispatch failures

**A dispatch bug that reproduces through the loader but is a green single-file run
is *usually* the eval driver, not dict-passing.** The loader's `evalModules` uses
per-module frames and a separate prelude/install order, so binding-order and
impl-install-order bugs surface *only* there.

**Run BOTH probes on the same input and diff:**

```sh
./medaka run compiler/entries/eval_modules_main.mdk   # loader path      (evalModules)
./medaka run compiler/entries/eval_typed_main.mdk     # single-file path
```

Identical input, but only the modules path errors ⇒ the eval driver
(`compiler/eval/eval.mdk`). One probe drives one path — you need both.

⚠️ **But VERIFY; this heuristic has a documented exception.** Phase 134 was
loader-only *and* dict-passing, and the two-probe comparison did **not** flag it —
both probes behaved identically. **"No divergence" does NOT exonerate
dict-passing.** The printer also renders `EDictApp`/`EMethodRef` transparently as
the bare name, so a dict-passed dump *looks* clean. When the comparison comes back
clean and the bug is still there, instrument eval's `EVar`/`EMethodRef`/`EDictApp`
arms and see how the name *actually* resolves. (See AGENTS.md Gotchas for the full
counterexample.)

Because single-file masks these, **the regression test must exercise the
multi-module path** (`test/diff_compiler_eval_modules.sh`), not a single-file
doctest.

## Build a minimal repro

Shrink the failing program to the smallest snippet that still reproduces. Once
fixed, add it as a regression fixture in the matching gate. Fixtures are
**per-stage** — `test/parse_fixtures/`, `test/llvm_fixtures/`,
`test/eval_modules_fixtures/`, `test/fmt_fixtures/`, `test/wasm/fixtures/`, … —
there is no generic `test/fixtures/`.

⚠️ **A fixture directory is a SHARED CORPUS.** Adding one silently enrols you in
gates you never named. Before you add a file, find every consumer and run them all:

```sh
grep -rl '<fixture_dir>' test/
```

e.g. `test/eval_modules_fixtures/` feeds **both** `diff_compiler_eval_modules.sh`
**and** `diff_compiler_core_ir_modules.sh`; `test/wasm/fixtures/` feeds **four**
consumers. Capture the golden with `CAPTURE=1` on the specific gate.

## Tips

- For LSP-surfaced errors, run `bash test/diff_compiler_lsp.sh` and
  `test/lsp_harness.sh`.
- For multi-module bugs, run `bash test/diff_compiler_check_modules.sh` and
  `bash test/diff_compiler_eval_modules.sh` to isolate the loader path.
- Before blaming the compiler, check `.claude/HANDOFF.md` — it lists known-red
  gates. A red gate is often already known and not your bug.
