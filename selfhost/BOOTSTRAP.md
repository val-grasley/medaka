# BOOTSTRAP.md — Native self-compile slices

Status of the native (LLVM) self-compile bootstrap: take a REAL self-hosted
compiler subcommand, compile it natively (emit textual LLVM IR -> `clang` -> link
`runtime/medaka_rt.c` + libgc), and prove its output **byte-matches the
tree-walker interpreter** over real fixtures.

Unlike `test/diff_selfhost_llvm_modules.sh` (which forces an EMPTY core prelude),
the bootstrap pushes the REAL `stdlib/core.mdk` prelude through `emitProgram` —
the actual bootstrap gate.

## B1 — native LEXER (IN PROGRESS; one blocker)

**Goal:** natively compile `selfhost/lex_main.mdk` (reads a file, `tokenize`s,
prints the canonical token stream) and byte-diff against
`medaka run selfhost/lex_main.mdk <fixture>`.

**Harness:** `test/bootstrap_lex.sh` (models `diff_selfhost_llvm_modules.sh`;
real `core.mdk`; diffs over every `test/diff_fixtures/*.mdk`).
**Emit driver:** `selfhost/llvm_bootstrap_lex_main.mdk` — clone of
`llvm_emit_modules_main.mdk` that runs the REAL `emitProgram` but calls
`enableGapRecord ()` first, so the 8 UNREACHABLE dead-code gaps in `core.mdk`
(`max`/`min` in `maximum`/`minimum`, the `Arbitrary` impls) become harmless `"0"`
placeholders instead of aborting. The byte-diff is the safety net: a gap the
lexer actually REACHES would diverge a fixture and FAIL — a passing diff proves
every placeholder was dead code.

### Done in this slice
1. **Two real emitter bugs fixed** (both in `selfhost/llvm_emit.mdk`; all 10
   `diff_selfhost_*` gates stay byte-identical):
   - **`e` / Euler shadowing.** `emitVar` intercepted the bare name `"e"` (and
     `pi`/`intMaxBound`/…) as a math constant BEFORE checking the local env, so a
     local/parameter named `e` resolved to `2.718281828459045`. The lexer uses
     `e` as a parameter pervasively (`identToken … e`, `let e = identEnd …`), so
     `substr src pos e` was emitted with `e` = a float cell -> wild array index ->
     SIGSEGV in `@mdk_at`. Fix: a local of that name now shadows the constant
     (`isLocal` check first; reserved value keywords `True`/`False`/`otherwise`
     and constructors still bind ahead of the env, as they can't be rebound).
   - **Gap placeholders left blocks unterminated.** When gap-recording is ON, the
     decision-tree gap sites (`CTGuard`, the unit/heterogeneous switch heads) only
     recorded the gap and emitted no terminator, so the dead-code `Arbitrary` impls
     produced structurally-invalid LLVM (`alloca` then a dangling label) and clang
     rejected the whole module. Each now stores a `"0"` placeholder and branches to
     the decision-end block — valid IR for the (dead) function.
2. **`@main` argv wiring confirmed present.** `emitProgram`'s `@main` already has
   the C signature `(i32 %argc, ptr %argv)` and calls
   `@mdk_set_args(i32 %argc, ptr %argv)` before the body, so `args ()` returns the
   file path. No emitter change needed.
3. With the `e`-fix, `tokenize <fixture>` natively returns the **correct token
   count** (e.g. 83 for `if_else.mdk`, matching the interpreter), and a probe that
   inlines `lex_main`'s logic byte-matches the interpreter on `if_else.mdk`.

### Remaining blocker — flat-emit bare-name function collision
`lex_main.mdk` defines a private `emit : String -> <IO> Unit`, and `lexer.mdk`
defines an unrelated private `emit : … -> List RawTok` (the operator scanner
helper, heavily used by `scanOp`). The multi-module emit path flattens every
module's decls into ONE list (`coreD ++ concatMapList snd modules`) and mangles
function names by **bare name** (`@mdk_<name>`), with no module qualification.
So both `emit`s collapse to `@mdk_emit`: only one `define` survives, and
`@main`'s call `@mdk_emit(%path)` (1 arg) dispatches to the surviving 8-arg lexer
`emit` with garbage args -> the lexer prints nothing (just the `()` Unit
auto-print). The interpreter avoids this via per-module frames; the flat native
emit does not.

**Proof it's the sole blocker:** renaming `lex_main`'s `emit` -> `emitTok`
(test only, NOT committed — `lex_main.mdk` is out of scope) makes the native
lexer **byte-match the interpreter** on the fixtures. So the emitter +
gap-tolerance + argv wiring are all correct; the one missing piece is
**module-qualified function mangling** for the flat multi-module emit (rename
module-private same-named functions, rewriting same-module references — a private
function is only referenced within its own module, so the rewrite is
self-contained). That is a separate, sizable AST-rename pass and is the next
slice's work; it was kept out of B1 to avoid risking the 10 green gates.

**Repro:**
```
dune build --root .
sh test/bootstrap_lex.sh     # emit+clang succeed; 0/19 match (the emit collision)
```
