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

1. **Advertise the capability** — in `handleInitialize`, where
   `ServerCapabilities` is built (look for `completionProvider`,
   `hoverProvider`, …). Add the provider field for your feature so clients
   know it's supported.
2. **Implement the handler** — add a `handle<Feature>` function next to the
   existing ones (e.g. `handleHover`, `handleCompletion`,
   `handleInlayHint`). It receives the typed params, resolves the document,
   and returns the typed result option.
3. **Dispatch** — match the corresponding request method string in
   `handleRequestUnsafe` and call your handler.

## Get analysis results

- Documents are tracked in the `docs` table; resolve by URI.
- Run the compiler front end through the **loader** (multi-file aware) the same
  way the existing handlers do — reuse the shared analysis helper rather than
  re-invoking stages directly.
- **Resilience:** mid-edit buffers often don't parse. The server keeps a
  `lastGoodSource` table so features degrade gracefully instead of going blank
  on a transient parse error — fall back to last-good like neighboring handlers
  do.

## Verify

```sh
bash test/diff_compiler_lsp.sh
bash test/diff_compiler_lsp_b3.sh
bash test/diff_compiler_lsp_b4.sh
```

For an end-to-end stdio check, use `test/lsp_harness.sh`. The harness drives
the **compiled** `medaka lsp` binary over JSON-RPC — run `make medaka` first.
If your feature depends on new language syntax, see the `add-language-feature`
skill first.
