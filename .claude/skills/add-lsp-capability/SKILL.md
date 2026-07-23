---
name: add-lsp-capability
description: Add or extend a Language Server Protocol feature in compiler/tools/lsp.mdk — advertise the capability, implement the request handler, and wire it into dispatch. Use when adding editor features like hover, completion, code actions, references, rename, or extending existing LSP behavior.
---

# Add an LSP capability

All LSP work lives in `compiler/tools/lsp.mdk` (stdio JSON-RPC). Existing
handlers cover diagnostics, formatting, document symbols, hover, definition,
highlight, completion, and inlay hints — use the nearest one as a template.

When examples involve **Medaka** code, use `x y => body`, never curried form.

## Wiring (three places)

All three are in `compiler/tools/lsp.mdk`. Line numbers are as of 2026-07-13 —
grep the name, not the number.

1. **Advertise the capability** — `initializeResult` (`:1183`). It is a plain
   top-level **value**, not a function and not a record type:
   `initializeResult : Json`, built with `jObject`. Its `"capabilities"` object
   (`:1187`) already lists `textDocumentSync`, `documentFormattingProvider`,
   `documentSymbolProvider`, `definitionProvider`, `documentHighlightProvider`,
   `hoverProvider`, `completionProvider`, `inlayHintProvider`,
   `semanticTokensProvider`. Add your provider field there so clients know the
   feature exists.
2. **Implement the handler** — add a `handle<Feature>` function next to the
   existing ones. Real templates: `handleHover` (`:648`), `handleCompletion`
   (`:738`), `handleInlayHint` (`:825`) — all with the shape
   `String -> String -> Json -> Json -> Docs -> <IO, Mut> Unit`
   (`runtimeSrc`, `coreSrc`, the request id, the params `Json`, and the open-document
   table). They write the response themselves rather than returning a value.
3. **Dispatch** — `dispatch` (`:1471`),
   `dispatch : String -> String -> Json -> Docs -> <IO, Mut> Step`. It matches on
   `methodOf msg` (`:1464`) — add an arm for your request's method string and call
   your handler.

## Implementing `textDocument/references` (or `rename`)

Neither is wired yet, but the substrate already exists: `compiler/tools/refindex.mdk`
(driven standalone by `compiler/entries/refindex_main.mdk`) builds a whole-project
binder-keyed def/use index — shadow-aware, alias/re-export-collapsing — which is the
evident foundation for both requests. Read its header before building a references
handler from scratch.

## Get analysis results

- Open documents live in the `Docs` table (`data Docs`, `:118`), threaded through
  every handler as the `docs` parameter; read/write with `docsGet` (`:214`) /
  `docsPut` (`:123`). Resolve by URI.
- Run the compiler front end through the **loader** (multi-file aware) the same
  way the existing handlers do — reuse the shared analysis helper rather than
  re-invoking stages directly.
- **Resilience:** mid-edit buffers often don't parse. The server keeps a
  session-lived last-good-source cache — **`projectCache : Ref (List (String,
  String))`** (`:1231`), a module-level `Ref` mapping file path → last source that
  parsed, **not** a table type. Features degrade gracefully instead of going blank
  on a transient parse error; fall back to last-good like neighboring handlers do.

## Verify

`main` is PROTECTED — branch, then land via PR. Before committing:

```sh
medaka fmt --write compiler/tools/lsp.mdk   # the pre-commit hook REJECTS unformatted .mdk
medaka lint compiler/tools/lsp.mdk          # the hook is a MAX RATCHET: any new finding fails
make preflight
```

Then:

```sh
bash test/diff_compiler_lsp.sh
bash test/diff_compiler_lsp_b3.sh
bash test/diff_compiler_lsp_b4.sh
```

New LSP output almost always **moves an LSP golden**. Re-capture it (`CAPTURE=1`
on the specific gate) and bless it — by NAMING the path — in the **same commit**,
or `main` goes red.

For an end-to-end stdio check, use `test/lsp_harness.sh`. The harness drives
the **compiled** `medaka lsp` binary over JSON-RPC — run `make medaka` first.
If your feature depends on new language syntax, see the `add-language-feature`
skill first.
