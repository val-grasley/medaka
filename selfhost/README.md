# selfhost — Medaka-in-Medaka compiler (Stage 1)

The self-hosted Medaka compiler, ported one pipeline stage at a time from the
OCaml reference in `lib/` and validated against it via differential testing.
See the **North star → Stage 1** section of [`../PLAN.md`](../PLAN.md).

Runs **on the existing tree-walking interpreter** (`medaka run …`) — correctness
first; native codegen is Stage 2.

## Layout

| File | Role |
|------|------|
| `lexer.mdk` | Port of `lib/lexer.mll`. `Token` ADT + `tokenToString` (mirror the OCaml `token_to_string` byte-for-byte) + `tokenize`. Prelude + global externs only — no stdlib import, so `selfhost/` is the sole project root. |
| `lex_main.mdk` | Runnable entry: `medaka run selfhost/lex_main.mdk <src.mdk>` reads the file, tokenizes, prints one token per line in the canonical reference form. |
| `medaka.toml` | Project config (import root). |

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
- ✅ Tokenizer ported: int/float/string/char + hex/bin/oct literals,
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
    TFloat value is identical).
- ⏳ Deferred (no real file or fixture uses them): triple-quoted strings (with
  their `strip_indent` dedent) and nested interpolation.

## Known eval quirk (self-host-surfaced)

An `<IO>`-returning **helper** called from a `match` arm is not forced by the
eval driver — the action is returned but never run (clean exit, no output) —
whereas the same logic **inlined** runs correctly. `lex_main.mdk` is written
inline to dodge this. Worth reducing to a minimal repro and filing as a compiler
bug.
