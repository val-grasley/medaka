# Medaka

A pragmatic, modern functional programming language. Sits at the intersection of
a cleaned-up OCaml, a practical Haskell, and a more functional, garbage-collected
Rust. See [language-design.md](./language-design.md) for the full design.

The compiler is rewritten in Medaka (`selfhost/`) and a
native **LLVM backend** compiles it — all seven pipeline stages are native-compiled
and byte-identical to the interpreter, and the compiler reproduces itself
byte-for-byte (the self-compile fixpoint). See [PLAN.md](./PLAN.md) and
[selfhost/BOOTSTRAP.md](./selfhost/BOOTSTRAP.md). **As of the 2026-06-12 milestone
flip the native `medaka` is CANONICAL** (the one users invoke, built OCaml-free from
a checked-in IR seed); the OCaml reference compiler (`lib/`+`bin/`) is kept **frozen**
as the differential oracle during the soak period (retirement ≠ removal).

## Status

Frontend, interpreter, and standard library complete; **self-hosting + native LLVM
codegen done** (the native compiler self-hosts to a reproducing fixpoint — PLAN.md).
**Native backend is canonical** (2026-06-12): all PRE-FLIP-GAPS soundness/capability
gaps closed; `make medaka` builds it OCaml-free. **Soak tail in progress (2026-06-22):**
gate re-rooting done (all correctness gates OCaml-free), the single-file/multi-module
driver collapse done, native dispatch gaps #55/#21 + the map Foldable false-positive
fixed, fuzzer ported to native, constructor-name collision (mis-filed as "mixed-ADT match")
fixed via universal ctor mangling, `argStampEnabled` eval-vs-emit dispatch unification
complete (eval now threads dicts; `evalDictLayerActive` retired). Next: confidence-gated
OCaml `lib/` removal (Stage 3 tail).

- **AST** — `lib/ast.ml`
- **Lexer** — `lib/lexer.mll` (indentation-sensitive, OCaml-style)
- **Parser** — `lib/parser.mly` (Menhir)
- **Printer** — `lib/printer.ml` (AST → parseable source)
- **Resolver** — `lib/resolve.ml` (every reference is bound; multi-module aware)
- **Type checker** — `lib/typecheck.ml` (Hindley-Milner with let-polymorphism,
  ADTs, records, type aliases, newtypes, pattern matching, interfaces with
  constraint checking and constraint syntax in signatures, effect tracking,
  exhaustiveness/usefulness)
- **Desugar** — `lib/desugar.ml` (`deriving` → impls, record field punning,
  do-block lowering)
- **Loader** — `lib/loader.ml` (multi-file dependency walk, cycle detection)
- **Evaluator** — `lib/eval.ml` (tree-walking interpreter with VMulti-based
  typeclass dispatch)
- **REPL** — `lib/repl.ml` (incremental parse/typecheck/eval with persistent env)
- **CLI** — `bin/main.ml` — `check`, `run`, `repl`, `lsp`, `fmt`, `doc`, `new`, and `check-policy` subcommands
- **Doc generator** — `lib/doc.ml` (comment→decl matcher, signature renderer, Markdown output)
- **Formatter** — `lib/fmt.ml` (comment-preserving pretty printer with `--check` / `--write` / `--stdout`)
- **Project config** — `lib/project_config.ml` (minimal `medaka.toml` reader; shared project-root walk-up between CLI and LSP)
- **Diagnostics** — `lib/diagnostics.ml` (accumulating error pipeline)
- **Language server** — `lib/lsp_server.ml` (stdio LSP server: diagnostics,
  formatting, document symbols, hover, go-to-definition, document
  highlight, completion, inlay hints)
- **Test suite** — parser, roundtrip, resolve, typecheck, eval, run,
  repl, loader, diagnostics, fmt, project_config, new_cmd, and doc suites
- **Self-hosted compiler** — `selfhost/*.mdk` (the whole pipeline rewritten in
  Medaka), validated byte-for-byte against the OCaml reference
- **Native LLVM backend** — `selfhost/llvm_emit.mdk` (Core IR → textual LLVM IR →
  `clang`), `runtime/medaka_rt.c` (C runtime + Boehm GC); `test/bootstrap_*.sh` +
  `test/selfcompile_*.sh` are the differential + self-compile gates

The standard library is developed in Medaka itself on top of the `extern`
primitives — see [STDLIB.md](./STDLIB.md). Self-hosting + native LLVM codegen are
done (the native compiler self-hosts to a reproducing fixpoint). See
[PLAN.md](./PLAN.md) for the roadmap (and
[PLAN-ARCHIVE.md](./PLAN-ARCHIVE.md) for the completed-phase history).

## Building

Medaka has **two** compilers (see [AGENTS.md](./AGENTS.md)):

- the **native, self-hosted `medaka`** — the **canonical** compiler (as of the
  2026-06-12 milestone flip), built **OCaml-free** from a checked-in LLVM IR seed;
- the **OCaml reference compiler** (`lib/`+`bin/`) — kept **frozen** as the
  differential oracle during the soak period (retirement ≠ removal).

**Build the native compiler (no OCaml — just clang + Boehm GC):**
```sh
make medaka          # WARM (./medaka_emitter present): 2-stage rebuild from
                     # current source, no seed.  COLD (fresh clone): bootstraps
                     # the emitter from selfhost/seed/emitter.ll.gz first, then
                     # compiles selfhost/driver/medaka_cli.mdk → ./medaka
./medaka run yourfile.mdk
```
The result is a self-contained ~1.9 MB native binary doing
check/fmt/new/build/run/test/repl/lsp with no OCaml at build *or* run time. For
fully OCaml-free user builds, `export MEDAKA_EMITTER=$(pwd)/medaka_emitter` so
`medaka build` uses the native emitter. (`make help` lists all targets.)

**Build the OCaml reference compiler (the frozen oracle):**
```sh
opam install dune menhir alcotest
dune build           # or: make reference
```

## Running tests

```sh
dune test
```

Or run individual suites directly (preferred — `dune test` can hang):

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

**Language server** (for editor integration — speaks LSP over stdio):
```sh
./_build/default/bin/main.exe lsp
```

**Scaffold a new project:**
```sh
./_build/default/bin/main.exe new myproj
cd myproj && ../_build/default/bin/main.exe run
```

This creates `myproj/` containing `medaka.toml`, `main.mdk`,
`.gitignore`, and `README.md`. The `medaka.toml` is a minimal
Cargo-style file:

```toml
[package]
name = "myproj"
version = "0.1.0"
entry = "main.mdk"
```

Its presence marks the project root: `medaka run` / `medaka check`
with no file argument resolves `entry` from `medaka.toml` in the cwd
(walking up), and `import` paths in any file under the project tree
are resolved relative to the root.

**Format source code:**
```sh
./_build/default/bin/main.exe fmt path/to/file.mdk        # rewrite in place
./_build/default/bin/main.exe fmt --check src/            # report-only, exit 1 if any
./_build/default/bin/main.exe fmt --stdout one_file.mdk   # print to stdout
```

The formatter parses, re-prints, and verifies the output reparses to
the same AST. Line comments (`--`) and block comments (`{- … -}`,
nesting) are preserved at their original positions.

**Generate Markdown documentation:**
```sh
./_build/default/bin/main.exe doc path/to/file.mdk
```

Outputs one `## name` section per public declaration with the
inferred type signature and any `--` doc comments immediately above
the declaration. Run inside a project (`medaka.toml`) and the file
argument may be omitted.

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
> :load stdlib/core.mdk
loaded stdlib/core.mdk — 12 bindings
> :browse
eq : a -> a -> Bool
debug : a -> String
...
> :quit
```

REPL meta-commands:

| Command | Alias | Description |
|---------|-------|-------------|
| `:quit` | `:q` | Exit the REPL |
| `:reset` | | Clear all session bindings |
| `:type <expr>` | `:t` | Print inferred type of an expression |
| `:load <path>` | | Load a `.mdk` file into the session |
| `:reload` | `:r` | Reload the last loaded file |
| `:browse` | `:env` | List all bindings currently in scope |

Multi-line definitions work naturally — keep typing indented lines and press
Enter on a blank line to commit:

```
> insert x t = match t
    Leaf => Node x Leaf Leaf
    Node v l r => if x < v
                    then Node v (insert x l) r
                    else Node v l (insert x r)
  
val insert : a -> BTree a -> BTree a
```

## Standard library

The stdlib lives in `stdlib/`. `stdlib/runtime.mdk` is the authoritative catalog
of extern primitives — their type signatures are embedded at build time and
available in all programs without an explicit import. See
[stdlib/README.md](stdlib/README.md) for conventions on adding new primitives.

`stdlib/core.mdk` is automatically prepended (as a "prelude") to every user
program at type-check and eval time, so its data types (`Option`, `Result`,
`Ordering`), interfaces (`Eq`, `Ord`, `Debug`, `Num`, `Mappable`, `Foldable`,
`Applicative`, `Thenable`, `Semigroup`, `Monoid`, …) and helpers (`identity`,
`flip`, `compose`, `filter`, …) are available without an explicit import.
The remaining stdlib modules (`list`, `string`, `array`, …) are written in
Medaka itself and developed interactively via the REPL. See
[STDLIB.md](STDLIB.md) for the module plan.

## Editor setup

### VS Code / Cursor

A language extension lives in `editors/vscode-medaka/`. It provides
syntax highlighting for `.mdk` files via a TextMate grammar, and connects
to the Medaka language server (`medaka lsp`) for live error diagnostics.

**Install (symlink, recommended for development):**
```sh
ln -s "$(pwd)/editors/vscode-medaka" ~/.vscode/extensions/medaka
# For Cursor:
ln -s "$(pwd)/editors/vscode-medaka" ~/.cursor/extensions/medaka
```

Restart VS Code / Cursor. Files ending in `.mdk` will be highlighted.

**Install as VSIX (one-time):**
```sh
cd editors/vscode-medaka
npm install -g @vscode/vsce
vsce package          # produces medaka-0.1.0.vsix
code --install-extension medaka-0.1.0.vsix
```

### Neovim (nvim-treesitter)

Add to your config:

```lua
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
parser_config.medaka = {
  install_info = {
    url = vim.fn.expand("~/medaka/tree-sitter-medaka"),
    files = { "src/parser.c", "src/scanner.c" },
  },
  filetype = "medaka",
}
vim.filetype.add({ extension = { mdk = "medaka" } })
```

Copy the highlights query:
```sh
mkdir -p ~/.config/nvim/after/queries/medaka
cp tree-sitter-medaka/queries/highlights.scm \
   ~/.config/nvim/after/queries/medaka/highlights.scm
```

Then run `:TSInstall medaka` inside Neovim.

### Helix

Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "medaka"
scope = "source.medaka"
file-types = ["mdk"]
roots = []
comment-token = "--"
indent = { tab-width = 2, unit = "  " }

[language.grammar]
source = { path = "~/medaka/tree-sitter-medaka" }
```

Copy the highlights query:
```sh
mkdir -p ~/.config/helix/runtime/queries/medaka
cp tree-sitter-medaka/queries/highlights.scm \
   ~/.config/helix/runtime/queries/medaka/highlights.scm
```

### Zed

Create a language extension following the [Zed extension docs](https://zed.dev/docs/extensions/languages).
Point `grammar.repository` at `tree-sitter-medaka/` and set `file_types = ["mdk"]`.

## Tree-sitter grammar

The tree-sitter grammar lives in `tree-sitter-medaka/`. To rebuild after grammar
changes:

```sh
cd tree-sitter-medaka
npm install
npx tree-sitter generate   # regenerates src/parser.c
npx tree-sitter test       # run corpus tests
```

## Layout

```
lib/
  ast.ml          AST type definitions
  builtins.ml     Compiler-side registry of operator → stdlib method names
  lexer.mll       Tokenizer with INDENT/DEDENT handling
  parser.mly      Menhir grammar
  printer.ml      AST → source (round-trip)
  resolve.ml      Name resolution (single-file and multi-module)
  typecheck.ml    Hindley-Milner + interfaces + effects + exhaustiveness
  exhaust.ml      Maranget's pattern-matrix algorithm
  desugar.ml      `deriving` expansion, record field puns, do-blocks
  loader.ml       Multi-file dependency walk + topological sort
  eval.ml         Tree-walking interpreter (VMulti dispatch for typeclasses)
  prelude.ml      Parses and caches `stdlib/core.mdk` for implicit prelude
  runtime.ml      Parses `stdlib/runtime.mdk` to derive primitive schemes
  repl.ml         REPL loop (`:load`, `:reload`, `:browse`, `:type`, …)
  diagnostics.ml  Accumulating parse/resolve/typecheck pipeline (no exit-on-error)
  lsp_server.ml   LSP server: stdio JSON-RPC, diagnostics + formatting,
                  document symbols, hover, definition, highlight,
                  completion, inlay hints
  doc.ml          `medaka doc` — doc-comment→Markdown extractor
  fmt.ml          `medaka fmt` — comment-preserving formatter
  new_cmd.ml      `medaka new` — project scaffolder
  project_config.ml  `medaka.toml` reader + project-root walk-up
bin/
  main.ml         CLI entry point (check / run / repl / lsp / fmt / doc / new)
  repl.ml         Interactive REPL loop shim
gen/
  embed.ml        Build-time helper: embeds runtime.mdk/core.mdk as an OCaml string
stdlib/
  runtime.mdk     Extern primitive catalog (embedded at build time)
  core.mdk        Core interfaces, instances, helpers (implicit prelude)
  list.mdk        List operations
  string.mdk      String operations
  array.mdk       Array operations
test/
  test_parser.ml      AST shape per construct
  test_roundtrip.ml   parse → print → parse stability
  test_resolve.ml     Resolution errors
  test_typecheck.ml   Inferred types, type errors, exhaustiveness warnings
  test_eval.ml        Interpreter correctness
  test_run.ml         End-to-end program runs
  test_repl.ml        REPL meta-commands and load atomicity
  test_loader.ml      Module loader and cross-file imports
  test_diagnostics.ml Diagnostics module — parse/resolve/typecheck → diagnostic list
  test_fmt.ml         Formatter: idempotency, round-trip, comment preservation
  test_project_config.ml  `medaka.toml` parsing + project-root walk-up
  test_new_cmd.ml     `medaka new` scaffolding
  test_doc.ml         `medaka doc` — comment matching, entry extraction, Markdown output
  test_lsp.ml         LSP request handlers (formatting, hover, definition,
                      highlight, completion, inlay hints, …)
  thorough/           Exhaustive edge-case suites: typecheck, eval,
                      cross-feature interactions, stdlib usage, recent
                      phase coverage (run via `dune build @thorough`)
dev/
  debug.ml            Ad-hoc parse-and-print probe
  tc_debug.ml         Ad-hoc type-check probe
  lsp_smoke.sh        End-to-end smoke driver for `medaka lsp` (not run by `dune test`)
tree-sitter-medaka/
  grammar.js          Tree-sitter grammar definition
  src/parser.c        Generated parser (committed)
  src/scanner.c       External scanner for INDENT/DEDENT/NEWLINE
  queries/
    highlights.scm    Syntax highlight queries
  test/corpus/        Corpus tests for the grammar
editors/
  vscode-medaka/      VS Code / Cursor extension
```
