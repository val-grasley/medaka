# tree-sitter-medaka

Tree-sitter grammar for the [Medaka](https://github.com/val/medaka) programming language.

Provides syntax highlighting for `.mdk` files in editors that support tree-sitter:
Neovim (nvim-treesitter), Helix, Zed, and VS Code (via extensions).

## Building

```sh
npm install
npx tree-sitter generate   # produces src/parser.c
```

The generated `src/parser.c` is committed so users without the CLI can still
build the native binding.

## Testing

```sh
npx tree-sitter test                          # run corpus tests
npx tree-sitter parse ../tests/stdlib/list.mdk  # check for ERROR nodes
npx tree-sitter highlight ../tests/stdlib/list.mdk  # preview highlight captures
```

A successful parse prints the CST with no `(ERROR)` nodes. The highlight command
annotates each token with its capture name (`@keyword`, `@type.constructor`, etc.).

## Editor setup

### Neovim (nvim-treesitter)

Add to your config:

```lua
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
parser_config.medaka = {
  install_info = {
    url = "path/to/tree-sitter-medaka",  -- or a GitHub URL
    files = { "src/parser.c", "src/scanner.c" },
  },
  filetype = "medaka",
}
vim.filetype.add({ extension = { mdk = "medaka" } })
```

Then run `:TSInstall medaka`.

### Helix

Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "medaka"
scope = "source.medaka"
file-types = ["mdk"]
roots = []
comment-token = "--"

[language.grammar]
source = { path = "path/to/tree-sitter-medaka" }
```

### Zed

Create a language extension following the [Zed extension docs](https://zed.dev/docs/extensions/languages).
Point `grammar.repository` at this directory and set `file_types = ["mdk"]`.

## Language overview

Medaka is an indentation-sensitive functional language. Blocks are delimited by
indentation rather than braces, similar to Python and Haskell. The grammar
handles `INDENT`/`DEDENT`/`NEWLINE` via an external scanner (`src/scanner.c`).

Key syntax:
- `f x y = body` — function definition
- `f : Int -> Int` — type signature
- `data Option a = Some a | None` — algebraic data type
- `x => x + 1` — lambda (fat arrow)
- `->` — type arrow only
- `match x ...` — pattern matching (indented arms)
- `do ...` — monadic do-notation (indented stmts)
- `<IO>`, `<Mut>` — effect annotations in types
- `--` — line comments
