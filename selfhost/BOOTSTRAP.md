# BOOTSTRAP.md — Native self-compile slices

Status of the native (LLVM) self-compile bootstrap: take a REAL self-hosted
compiler subcommand, compile it natively (emit textual LLVM IR -> `clang` -> link
`runtime/medaka_rt.c` + libgc), and prove its output **byte-matches the
tree-walker interpreter** over real fixtures.

Unlike `test/diff_selfhost_llvm_modules.sh` (which forces an EMPTY core prelude),
the bootstrap pushes the REAL `stdlib/core.mdk` prelude through `emitProgram` —
the actual bootstrap gate.

## B1 — native LEXER (18/19; mangling DONE, one UNRELATED emitter blocker)

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

### Remaining blocker — flat-emit bare-name function collision  [RESOLVED]
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

**FIXED (module-qualified private-fn mangling).** `selfhost/private_mangle.mdk`
(`mangleUnits`) runs PER UNIT, BEFORE `elaborateModules` flattens the module
boundaries. It finds top-level function names defined in >1 unit (the
collisions), and for each unit renames ITS module-PRIVATE (`pub = False`)
colliding functions to a unique `<mid>__<name>` symbol (mid sanitized to
`[A-Za-z0-9_]`), rewriting every in-module reference SCOPE-AWARELY (a reference is
renamed only where the name is the free top-level name, never where a local
binder shadows it — mirrors typecheck.mdk's `rewriteArgScoped` binder threading).
Exported functions keep their bare name (cross-module-referenced). Private ⇒ not
importable ⇒ references are self-contained, so no cross-module fixup is needed.
Wired into BOTH flat-emit drivers (`llvm_bootstrap_lex_main.mdk` and
`llvm_emit_modules_main.mdk`); the golden/oracle drivers never call it, so every
golden/oracle dump and all 10 selfhost gates stay byte-identical. Result:
`lex_main.emit` -> `@mdk_lex_main__emit`, `lexer.emit` -> `@mdk_lexer__emit`; the
native lexer now produces the correct token stream.

Two harness/measurement fixes also landed:
- `test/bootstrap_lex.sh` appended `\n()` (newline-then-parens) to the oracle to
  account for the native Unit auto-print, but `lex_main.emit` renders via `joinNl`
  (NO trailing newline) + `putStr`, so the oracle ends at the last token with no
  newline and native concatenates `()` directly after it (`…EOF()\n`). The append
  is now exactly `()` (matching the comment's documented `()\n` intent after
  `$(self)` strips the trailing newline). The sibling `llvm_modules` harness keeps
  `\n()` because its oracle output IS newline-terminated.

### NEW sole blocker — `emitCmp` does not route String `==` to `@mdk_string_eq`
`triple_str.mdk` is the lone remaining failure (18/19). Root cause is UNRELATED to
mangling and lives in `selfhost/llvm_emit.mdk`'s `emitCmp` (≈ line 1407): for
`==`/`!=`/`<`/… it dispatches only on `LTFloat` vs an integer `_` fallback. The
`_` arm `untagInt`s both operands and emits `icmp eq i64` — so for **`LTStr`**
operands it compares the two heap POINTERS, i.e. pointer identity, NOT string
contents. `mdk_string_eq` is used by the pattern-match path (≈ line 3185) but NOT
by the `==` binop path. Effect: native `"" == ""` and even `"ab" == "ab"` are
False (distinct `mdk_str_lit` pointers). In the lexer this breaks
`firstNl … acc = acc == "" || …` (lexer.mdk:534): `acc == ""` is False natively, so
`leadingNl` never flips True, so `maybeStrip`/`stripIndent` skips the triple-string
dedent → `triple_str.mdk` token 10 emits the raw un-dedented content. None of
`stripIndent`/`maybeStrip`/`firstNl`/`at` are renamed by the mangling pass — this
is a pre-existing emitter bug. **Fix (separate slice, out of B1 mangling scope):**
add an `LTStr` arm to `emitCmp` that calls `@mdk_string_eq` (returns tagged Bool
`3`) and branches on `icmp eq i64 r, 3`, exactly as the pattern path already does.
