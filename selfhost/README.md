# selfhost — Medaka-in-Medaka compiler (Stage 1)

The self-hosted Medaka compiler, ported one pipeline stage at a time from the
OCaml reference in `lib/` and validated against it via differential testing.
See the **North star → Stage 1** section of [`../PLAN.md`](../PLAN.md).

Runs **on the existing tree-walking interpreter** (`medaka run …`) — correctness
first; native codegen is Stage 2.

## House style

Idiomatic Medaka, not transliterated OCaml — the self-host port is also how we
*dogfood* the language, so we lean into its idioms rather than minimizing the
diff with `lib/`:
- **Multi-clause functions** with pattern-matching heads (incl. literal heads
  like `keywordOrIdent "let" = TLet`), not `match` on the sole argument. Reserve
  `match` for case analysis on a *computed/local* value.
- **Type signatures on every top-level function.**
- Higher-order functions (`map`, etc.) where they read clearly; treat
  idiom-friction (e.g. the Phase 134 `map` quirk) as a bug to fix, not avoid.
- Structural parallelism with the OCaml reference is kept **only** in the core
  scan/parse algorithms, where it buys byte-for-byte validation.

## Layout

| File | Role |
|------|------|
| `lexer.mdk` | Port of `lib/lexer.mll`. `Token` ADT + `tokenToString` (mirror the OCaml `token_to_string` byte-for-byte) + `tokenize`. Prelude + global externs only — no stdlib import, so `selfhost/` is the sole project root. |
| `lex_main.mdk` | Runnable entry: `medaka run selfhost/lex_main.mdk <src.mdk>` reads the file, tokenizes, prints one token per line in the canonical reference form. |
| `ast.mdk` | The self-host AST — a Medaka mirror of `lib/ast.ml`'s surface (pre-desugar) nodes; the target the parser builds. Constructor names match `ast.ml`. |
| `sexp.mdk` | `programToSexp` — a canonical structural S-expression dump of the AST, mirroring `dev/astdump.ml` byte-for-byte; the parser's validation format (the `tokenToString` analog). |
| `parse_main.mdk` | Runnable entry for the parser (scaffold: dumps a hand-built control AST until the parser exists). |
| `medaka.toml` | Project config (import root). |

The OCaml-side validation references live in `dev/`: `lextok.exe` (token-stream
dumper) and `astdump.exe` (canonical AST S-expression dumper).

## Validation

```sh
dune build --root .                       # build the reference binary
sh test/diff_selfhost_lexer.sh            # diff the Medaka lexer vs OCaml goldens
```

The harness runs the Medaka lexer over every fixture in `test/diff_fixtures/`
and diffs its token stream against that fixture's golden `=== TOKENS ===`
section (those goldens are emitted by the OCaml `Lexer.tokenize_string`). A
fixture flips from `FAIL` to `ok` as the corresponding lexer behavior is ported;
the stage is done when all pass.

## Status

- ✅ Scaffold + harness wiring (token ADT, canonical serializer, runnable entry,
  diff loop).
- ✅ Tokenizer ported: int/float/string/char literals (with char escapes
  `\n \t \r \0 \\ \'` + `\u{…}`, mirroring Phase 133) + hex/bin/oct literals,
  idents/keywords, operators/punctuation, line + nestable `{- … -}` block
  comments, **string interpolation**, the `@`/`AS_AT` adjacency rule, and the
  INDENT/DEDENT/NEWLINE layout algorithm (plus else-continuation filter and
  leading-operator continuation).
- ✅ **Validated two ways**, both byte-for-byte against the OCaml reference:
  - **15/15 curated fixtures** — `sh test/diff_selfhost_lexer.sh`.
  - **13/13 real `.mdk` files** (every stdlib module + this lexer lexing itself)
    — `sh test/diff_selfhost_lex_files.sh`, which diffs against
    `dev/lextok.exe` (the OCaml reference dumper). FLOAT literal *text* is
    normalized away (OCaml `%g` vs `floatToString`: `1.0` → `1` vs `1.`; the
    TFloat value is identical). One more serialization-only nuance, not hit by
    any real file: control bytes in STRING/CHAR render `\0` (`debugStringLit`)
    vs `\000` (`%S`) — same value, different debug escaping.
- ⏳ Deferred (no real file or fixture uses them): triple-quoted strings (with
  their `strip_indent` dedent) and nested interpolation.

### Parser (Stage 1, in progress)

- ✅ Scaffold: the `ast.mdk` core node type, the `sexp.mdk` structural dumper
  (validated byte-for-byte against `dev/astdump.exe` via `sh
  test/diff_selfhost_parse.sh`'s positive control), `parse_main.mdk`, and the
  OCaml reference dumper. Validation is in place *before* any parse logic, same
  as the lexer.
- ⏳ Next: the recursive-descent parser itself, over `List Token` from the
  lexer. The precedence ladder (`expr_annot → … → expr_app → expr_atom`, ~18
  levels) maps one function per level. Coverage (AST nodes + `sexp` cases) grows
  per slice: expressions → patterns → declarations → types. Stays prelude-only
  (`List`/`Array`/string externs) — `Map`/stdlib isn't needed until resolve.

## Self-host-surfaced compiler fix

**Phase 134 (fixed).** Porting the lexer surfaced a real bug: an `<IO>`-returning
**helper** called from a `match` arm produced no output (clean exit) while the
same logic **inlined** ran correctly. Root cause was *not* the eval driver but
cross-module dict-passing: a private, then-`Num`-constrained 8-arg `emit` in
`lexer.mdk` made `Eval.eval_modules` (which dict-passed the whole program
*jointly*, keying dict-arity by bare name) prepend spurious dict parameters to any
same-named function in another module. `lex_main.mdk`'s unconstrained `emit`
helper then got under-applied, returning a partial closure that was never run.
Fixed by scoping each module's dict-arity table to the references that can resolve
to its own definitions (own decls + transitive importers); the regression is
guarded by `test_loader` (which supplies a genuinely-constrained same-named
sibling). `lex_main.mdk` now uses the clean helper form. (The lexer's `emit` has
since gained a concrete `Int` signature, so it no longer collides on its own.)
