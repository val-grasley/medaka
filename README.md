# Medaka

A pragmatic, modern functional programming language. Sits at the intersection of
a cleaned-up OCaml, a practical Haskell, and a more functional, garbage-collected
Rust. See [language-design.md](./language-design.md) for the full design.

The compiler is written in OCaml (Phase 1). Eventually we'll target LLVM and/or
self-host.

## Status

Frontend and interpreter complete; codegen not yet started.

- **AST** — `lib/ast.ml`
- **Lexer** — `lib/lexer.mll` (indentation-sensitive, OCaml-style)
- **Parser** — `lib/parser.mly` (Menhir)
- **Printer** — `lib/printer.ml` (AST → parseable source)
- **Resolver** — `lib/resolve.ml` (every reference is bound)
- **Type checker** — `lib/typecheck.ml` (Hindley-Milner with let-polymorphism,
  ADTs, records, pattern matching, interfaces with constraint checking,
  effect tracking, exhaustiveness/usefulness)
- **Evaluator** — `lib/eval.ml` (tree-walking interpreter)
- **REPL** — `bin/repl.ml` (incremental parse/typecheck/eval with persistent env)
- **CLI** — `bin/main.ml` — `check`, `run`, and `repl` subcommands
- **Test suite** — 354 cases across parser, roundtrip, resolve, typecheck,
  eval, and run suites

Not yet: codegen, stdlib. See [PLAN.md](./PLAN.md) for the roadmap.

## Building

Requires OCaml 5.x, dune, menhir, alcotest.

```sh
opam install dune menhir alcotest
dune build
```

## Running tests

```sh
dune test
```

Or run individual suites directly:

```sh
./_build/default/test/test_parser.exe    --compact
./_build/default/test/test_typecheck.exe --compact
./_build/default/test/test_eval.exe      --compact
./_build/default/test/test_run.exe       --compact
```

## Using the compiler

**Type-check a file:**
```sh
./_build/default/bin/main.exe check path/to/file.mdk
```

**Run a file** (requires a `main : <IO> Unit` binding):
```sh
./_build/default/bin/main.exe run path/to/file.mdk
```

**Interactive REPL:**
```sh
./_build/default/bin/main.exe repl
```

```
medaka repl  (:quit to exit, :reset to clear session)
> x = 42
val x : Int
> x + 1
43 : Int
> data Color = Red | Green | Blue
type Color
> Red
Red : Color
> :type [1, 2, 3]
List Int
> :quit
```

Multi-line definitions work naturally — keep typing indented lines and press
Enter on a blank line to commit:

```
> insert x t = match t
    Leaf => Node x Leaf Leaf
    Node v l r => if x < v
                    then Node v (insert x l) r
                    else Node v l (insert x r)
  
val insert : Int -> Tree Int -> Tree Int
```

## Layout

```
lib/
  ast.ml          AST type definitions
  lexer.mll       Tokenizer with INDENT/DEDENT handling
  parser.mly      Menhir grammar
  printer.ml      AST → source (round-trip)
  resolve.ml      Name resolution
  typecheck.ml    Hindley-Milner + interfaces + effects + exhaustiveness
  exhaust.ml      Maranget's pattern-matrix algorithm
  eval.ml         Tree-walking interpreter
bin/
  main.ml         CLI entry point (check / run / repl)
  repl.ml         Interactive REPL loop
test/
  test_parser.ml      AST shape per construct
  test_roundtrip.ml   parse → print → parse stability
  test_resolve.ml     Resolution errors
  test_typecheck.ml   Inferred types, type errors, exhaustiveness warnings
  test_eval.ml        Interpreter correctness
  test_run.ml         End-to-end program runs
dev/
  debug.ml            Ad-hoc parse-and-print probe
  tc_debug.ml         Ad-hoc type-check probe
```
