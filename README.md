# Medaka

A pragmatic, modern functional programming language. Sits at the intersection of
a cleaned-up OCaml, a practical Haskell, and a more functional, garbage-collected
Rust. See [language-design.md](./language-design.md) for the full design.

The compiler is written in OCaml (Phase 1). Eventually we'll target LLVM and/or
self-host.

## Status

Frontend complete; backend not yet started.

- **AST** — `lib/ast.ml`
- **Lexer** — `lib/lexer.mll` (indentation-sensitive, OCaml-style)
- **Parser** — `lib/parser.mly` (Menhir)
- **Printer** — `lib/printer.ml` (AST → parseable source)
- **Resolver** — `lib/resolve.ml` (every reference is bound)
- **Type checker** — `lib/typecheck.ml` (Hindley-Milner with let-polymorphism,
  ADTs, records, pattern matching, interfaces with constraint checking,
  effect tracking, exhaustiveness/usefulness)
- **CLI** — `bin/main.ml` runs the full pipeline with Elm-style error output
- **Test suite** — 275 cases across `test/test_parser.ml`,
  `test/test_roundtrip.ml`, `test/test_resolve.ml`, `test/test_typecheck.ml`

Not yet: evaluation, REPL, codegen, stdlib. See [PLAN.md](./PLAN.md) for the
backend roadmap.

## Building

Requires OCaml 5.x, dune, menhir, alcotest.

```sh
opam install dune menhir alcotest
dune build
```

## Running tests

```sh
dune build
./_build/default/test/test_parser.exe     --compact
./_build/default/test/test_roundtrip.exe  --compact
./_build/default/test/test_resolve.exe    --compact
./_build/default/test/test_typecheck.exe  --compact
```

(Running via `dune test` is supported, but PLAN.md §2.2 documents an
environment-specific hang — run the binaries directly when in doubt.)

## Trying the compiler

```sh
dune build && ./_build/default/bin/main.exe path/to/file.mdk
```

Runs parse → resolve → type-check, printing Elm-style errors on failure or
`OK — N bindings` on success.

## Layout

```
lib/
  ast.ml          AST type definitions + pretty printer + ELoc helpers
  lexer.mll       Tokenizer with INDENT/DEDENT handling
  parser.mly      Menhir grammar
  printer.ml      AST → source (round-trip)
  resolve.ml      Name resolution
  typecheck.ml    Hindley-Milner + interfaces + effects + exhaustiveness
  exhaust.ml      Maranget's pattern-matrix algorithm
bin/
  main.ml         CLI entry point
test/
  test_parser.ml      AST shape per construct
  test_roundtrip.ml   parse → print → parse stability
  test_resolve.ml     Resolution errors
  test_typecheck.ml   Inferred types, type errors, exhaustiveness warnings
  debug.ml            Ad-hoc parse-and-print probe
  tc_debug.ml         Ad-hoc type-check probe
```
