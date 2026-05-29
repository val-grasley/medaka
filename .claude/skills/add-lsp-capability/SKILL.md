---
name: add-lsp-capability
description: Add or extend a Language Server Protocol feature in lib/lsp_server.ml — advertise the capability, implement the request handler, and wire it into dispatch. Use when adding editor features like hover, completion, code actions, references, rename, or extending existing LSP behavior.
---

# Add an LSP capability

All LSP work lives in `lib/lsp_server.ml` (stdio JSON-RPC, built on the `lsp`
and `jsonrpc` opam libraries). Existing handlers cover diagnostics, formatting,
document symbols, hover, definition, highlight, completion, and inlay hints —
use the nearest one as a template.

When examples involve **Medaka** code, use `x y => body`, never curried form.

## Wiring (three places)

1. **Advertise the capability** — in `handle_initialize`, where
   `ServerCapabilities.create` is built (look for `~completionProvider`,
   `~hoverProvider`, …). Add the provider field for your feature so clients
   know it's supported.
2. **Implement the handler** — add a `handle_<feature>` function next to the
   existing ones (e.g. `handle_hover`, `handle_completion`,
   `handle_inlay_hint`). It receives the typed `*Params.t`, resolves the
   document, and returns the typed result option.
3. **Dispatch** — match the corresponding `Client_request.TextDocument*`
   constructor in `handle_request_unsafe` and call your handler.

## Get analysis results

- Documents are tracked in the `docs` hashtable; resolve by URI.
- Run the compiler front end through the **loader** (multi-file aware) the same
  way the existing handlers do — reuse the shared analysis helper rather than
  re-invoking stages directly.
- **Resilience:** mid-edit buffers often don't parse. The server keeps a
  `last_good_source` hashtable so features degrade gracefully instead of going
  blank on a transient parse error — fall back to last-good like neighboring
  handlers do.

## Verify

```sh
./_build/default/test/test_lsp.exe --compact
```

Add a handler test to `test/test_lsp.ml`. For an end-to-end stdio check, run
`dev/lsp_smoke.sh`. If your feature depends on new language syntax, see the
`add-language-feature` skill first.
