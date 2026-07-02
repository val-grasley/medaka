# Medaka

A pragmatic, modern functional programming language. Sits at the intersection of
a cleaned-up OCaml, a practical Haskell, and a more functional, garbage-collected
Rust. See [language-design.md](./language-design.md) for the full design.

The compiler is written in Medaka (`compiler/`) and a
native **LLVM backend** compiles it — all seven pipeline stages are native-compiled
and byte-identical to the interpreter, and the compiler reproduces itself
byte-for-byte (the self-compile fixpoint). See [PLAN.md](./PLAN.md) and
[compiler/BOOTSTRAP.md](./compiler/BOOTSTRAP.md). **As of 2026-06-26 the OCaml
reference compiler (`lib/`+`bin/`) is REMOVED** (tag `oracle-frozen` preserves
the last lib/-present commit); native is the sole compiler. **`make medaka`**
builds it OCaml-free from a checked-in IR seed.

## Status

Frontend, interpreter, and standard library complete; **self-hosting + native LLVM
codegen done** (the native compiler self-hosts to a reproducing fixpoint — PLAN.md).
**Native backend is canonical** (2026-06-12); **OCaml compiler removed** (2026-06-26,
tag `oracle-frozen`): `make medaka` builds the compiler OCaml-free. Native dispatch
gaps #55/#21 fixed; constructor-name collision fixed via universal ctor mangling;
`argStampEnabled` eval-vs-emit dispatch unification complete; `Traversable t` typeclass
shipped (2026-06-25); `sequence` default method landed (2026-06-26).

The compiler lives in `compiler/` (subfolders: `frontend/ types/ ir/ backend/ eval/
driver/ tools/ support/ entries/ seed/`):

- **Lexer** — `compiler/frontend/lexer.mdk` (indentation-sensitive)
- **Parser** — `compiler/frontend/parser.mdk` (recursive-descent)
- **AST** — `compiler/frontend/ast.mdk`
- **Desugar** — `compiler/frontend/desugar.mdk` (`deriving` → impls, record punning, do-blocks, default-method specialization)
- **Resolver** — `compiler/frontend/resolve.mdk` (every reference bound; multi-module aware)
- **Method marker** — `compiler/frontend/marker.mdk` (EVar → EMethodRef rewrite for dispatch)
- **Type checker** — `compiler/types/typecheck.mdk` (Hindley-Milner + interfaces + effects + exhaustiveness)
- **Exhaustiveness** — `compiler/frontend/exhaust.mdk` (Maranget pattern-matrix; called from typecheck)
- **Evaluator** — `compiler/eval/eval.mdk` (tree-walking interpreter with dict-passing typeclass dispatch)
- **Core IR / LLVM emit** — `compiler/ir/core_ir_lower.mdk` → `compiler/backend/llvm_emit.mdk` → `clang`
- **WasmGC backend** — `compiler/backend/wasm_emit.mdk` (2nd backend, browser playground)
- **Loader / CLI** — `compiler/driver/loader.mdk` + `compiler/driver/medaka_cli.mdk`
- **Tools** — `compiler/tools/` (fmt, printer, LSP, doctest, doc, repl, new_cmd, test_cmd, check)
- **Self-hosted compiler** — `compiler/*.mdk` (the whole pipeline), validated at a
  byte-for-byte self-compile fixpoint (`test/selfcompile_fixpoint.sh`)

The standard library is developed in Medaka itself on top of the `extern`
primitives — see [STDLIB.md](./STDLIB.md). Self-hosting + native LLVM codegen are
done (the native compiler self-hosts to a reproducing fixpoint). See
[PLAN.md](./PLAN.md) for the roadmap (and
[PLAN-ARCHIVE.md](./PLAN-ARCHIVE.md) for the completed-phase history).

## Building

**Build the native compiler (requires clang + Boehm GC — no OCaml):**
```sh
make medaka          # WARM (./medaka_emitter present): 2-stage rebuild from
                     # current source.  COLD (fresh clone): bootstraps
                     # the emitter from compiler/seed/emitter.ll.gz first.
./medaka run yourfile.mdk
```
The result is a self-contained ~1.9 MB native binary doing
check/fmt/new/build/run/test/repl/lsp. For fully OCaml-free user builds,
`export MEDAKA_EMITTER=$(pwd)/medaka_emitter` so `medaka build` uses the
native emitter. (`make help` lists all targets.)

## Running tests

```sh
sh test/run_gates.sh                # run the WHOLE diff_compiler_* suite in PARALLEL (~32s)
bash test/diff_compiler_*.sh        # differential gates: native output vs goldens (~67 suites)
bash test/selfcompile_fixpoint.sh   # emitter self-compile fixpoint
bash test/bootstrap_*.sh            # each pipeline stage == interpreter
FORCE=1 bash test/build_oracles.sh  # force-rebuild oracle goldens (parallel; always use FORCE=1)
```

The oracle build and gate suites parallelize across CPUs (cap with `JOBS=n`).
Perf-tuning env knobs (`EMITTER_OPT` / `ORACLE_OPT` / `CLI_OPT` /
`GC_INITIAL_HEAP_SIZE`) and the numbers are documented in `compiler/PERF-RESULTS.md`
and `AGENTS.md` (Build & test).

## Using the compiler

**Type-check a file:**
```sh
medaka check path/to/file.mdk
```

**Run a file** (requires a `main : <IO> Unit` binding):
```sh
medaka run path/to/file.mdk
```

**Interactive REPL:**
```sh
medaka repl
```

**Language server** (for editor integration — speaks LSP over stdio):
```sh
medaka lsp
```

**Scaffold a new project:**
```sh
medaka new myproj
cd myproj && medaka run
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
medaka fmt path/to/file.mdk        # rewrite in place
medaka fmt --check src/            # report-only, exit 1 if any
medaka fmt --stdout one_file.mdk   # print to stdout
```

The formatter parses, re-prints, and verifies the output reparses to
the same AST. Line comments (`--`) and block comments (`{- … -}`,
nesting) are preserved at their original positions.

**Generate Markdown documentation:**
```sh
medaka doc path/to/file.mdk
```

Outputs one `## name` section per public declaration with the
inferred type signature and any `--` doc comments immediately above
the declaration. Run inside a project (`medaka.toml`) and the file
argument may be omitted.

**Lint for style issues:**
```sh
medaka lint path/to/file.mdk       # lint one file
medaka lint src/                   # lint a directory (recursive)
medaka lint                        # lint the whole medaka.toml project
medaka lint --fix file.mdk         # apply safe autofixes in place
medaka lint --deny=rule-name f.mdk # treat a rule's findings as errors (exit 1)
medaka lint --disable=r1,r2 src/   # turn rules off (or --only=r1,r2)
```

A modular, rule-based linter for style issues that the formatter
deliberately won't auto-change (they alter a definition's *shape*, not
just layout). Per-file rules flag immediate `match`-on-a-bare-param
(→ multi-clause), hand-rolled `Eq`/`Ord`/`Debug` (→ `deriving`), and
re-implemented stdlib functions; a cross-file rule flags structurally
duplicated function bodies across modules. Rules are warnings by
default (exit 0); `--deny` promotes a rule to an error (exit 1). `--fix`
applies the safe autofixes (currently the match-on-param → multi-clause
rewrite). Adding a custom rule is one function plus one registry entry
in `compiler/tools/lint.mdk`.

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
of extern primitives — their type signatures are loaded at startup and available
in all programs without an explicit import. See
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
compiler/
  frontend/
    ast.mdk         AST type definitions
    lexer.mdk       Tokenizer with INDENT/DEDENT handling
    parser.mdk      Recursive-descent grammar
    desugar.mdk     `deriving` expansion, record puns, do-blocks, default methods
    resolve.mdk     Name resolution (single-file and multi-module)
    marker.mdk      EVar→EMethodRef rewrite for dispatch
    exhaust.mdk     Maranget's pattern-matrix exhaustiveness algorithm
  types/
    typecheck.mdk   Hindley-Milner + interfaces + effects + exhaustiveness
    annotate.mdk    Type annotation helpers
  ir/
    core_ir.mdk         Core IR type definitions
    core_ir_lower.mdk   AST → Core IR lowering
    core_ir_sexp.mdk    Core IR S-expr serializer
    dce.mdk             Dead code elimination
  backend/
    llvm_emit.mdk       Core IR → LLVM text IR → clang
    wasm_emit.mdk       Core IR → WasmGC text IR (2nd backend)
    private_mangle.mdk  Universal constructor name mangling
    trmc_analysis.mdk   Tail-recursion-modulo-cons analysis
  eval/
    eval.mdk        Tree-walking interpreter (dict-passing dispatch for typeclasses)
  driver/
    loader.mdk      Multi-file dependency walk + topological sort + medaka.toml walk-up
    diagnostics.mdk Accumulating parse/resolve/typecheck pipeline (no exit-on-error)
    build_cmd.mdk   `medaka build` — LLVM pipeline driver
    medaka_cli.mdk  CLI entry point (check / run / repl / lsp / fmt / doc / new / build)
  tools/
    printer.mdk     AST → source (round-trip)
    fmt.mdk         `medaka fmt` — comment-preserving formatter
    lsp.mdk         LSP server: stdio JSON-RPC, diagnostics + formatting,
                    document symbols, hover, definition, highlight,
                    completion, inlay hints
    doc.mdk         `medaka doc` — doc-comment→Markdown extractor
    doctest.mdk     `medaka test` — doctest extractor + runner
    test_cmd.mdk    `medaka test` — test command driver + prop tests
    repl.mdk        `medaka repl` — interactive REPL loop
    new_cmd.mdk     `medaka new` — project scaffolder
    check.mdk       `medaka check` — type-check entry
    check_policy.mdk  `medaka check-policy` — policy checker
  support/
    util.mdk        Generic helpers (compiler private mini-stdlib)
    ordmap.mdk      Ordered map (SMap/EMap)
    char.mdk        Character utilities
    path.mdk        Path utilities
    timer.mdk       Timing utilities
  entries/           Per-stage probe entry points
  seed/
    emitter.ll.gz   Gzipped LLVM IR seed for cold bootstrap
stdlib/
  runtime.mdk     Extern primitive catalog (loaded at startup)
  core.mdk        Core interfaces, instances, helpers (implicit prelude)
  list.mdk        List operations
  string.mdk      String operations
  array.mdk       Array operations
  byteparser.mdk  Generic binary parser-combinator library (big-endian decoders)
  bytebuilder.mdk Symmetric byte-output builder (emit*/buildArray)
runtime/
  medaka_rt.c     C runtime + Boehm GC
test/
  run_gates.sh         Parallel runner for the whole diff_compiler_* suite
  diff_compiler_*.sh   Differential golden-diff test gates (~67 suites)
  bootstrap_*.sh       Per-stage native==interpreter gates
  selfcompile_*.sh     Emitter self-compile fixpoint gates
  build_oracles.sh     Oracle golden capture / force-rebuild (parallel)
  capture_goldens.sh   Golden capture helper
  bench.sh             Performance benchmark harness
  *_fixtures/          Input fixture files for each gate
  *_goldens/           Golden output files for each gate
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
