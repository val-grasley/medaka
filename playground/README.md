# Medaka Playground

An install-free web playground for [Medaka](../README.md): edit source, hit Run, see output. The user program compiles to **WasmGC** and runs entirely in the browser sandbox — the server only compiles, never executes untrusted code.

## Prerequisites

1. **Build the compiler** (from repo root):
   ```sh
   make medaka
   ```
   This produces `./medaka` and `./medaka_emitter`.

2. **Build the wasm emitter** (still from repo root):
   ```sh
   sh test/wasm/build_wasm_oracle.sh
   ```
   This produces `./test/bin/wasm_emit_modules_main`.

3. **wasm-tools** must be on PATH (`wasm-tools --version`). Install from <https://github.com/bytecodealliance/wasm-tools> if needed.

## Running

```sh
node playground/server.js
```

Open **http://localhost:8080** in a current Chrome or Firefox (2024+). Safari and older browsers may not support the finalized WasmGC encoding — the page shows a banner if WasmGC is not detected.

Default port is 8080; override with `PORT=<n>`.

## How it works

```
Browser                                     Local stub (server.js)
┌─────────────────────────────┐             ┌──────────────────────────────┐
│  editor (textarea)           │             │  POST /compile {source}      │
│  Run → POST /compile ────────┼────────────▶│  1. medaka check --json      │
│                              │             │     → errors? → { errors }   │
│  ← wasm bytes or { errors } ◀─────────────┤  2. medaka build --target wasm│
│                              │             │     → read .wasm bytes       │
│  Worker.instantiate(wasm)    │             └──────────────────────────────┘
│  mdk_write_byte → console   │
│  10 s wall-clock timeout    │
└─────────────────────────────┘
```

- **`server.js`** — Node HTTP stub (zero npm deps). Serves static files from `playground/`; `POST /compile` runs `medaka check --json` then `medaka build --target wasm` in a temp dir, returning wasm bytes or structured error diagnostics.
- **`worker.js`** — Web Worker that instantiates the wasm module with the exact host-import ABI (`mdk_write_byte`, `mdk_write_err_byte`, `mdk_float_fmt`, `mdk_float_fmt_byte`) and posts decoded stdout/stderr back to the page.
- **`main.js`** — page glue: wires the Run button, streams console output, renders diagnostics, kills the worker on timeout.
- **`index.html`** — editor + console + problems pane, no external dependencies.

## Browser requirement

Requires **Node ≥22** server-side (for wasm validation in `wasm-tools`). The browser must support the **finalized WasmGC encoding** (Wasm GC MVP, finalized 2023): current Chrome (≥119) and Firefox (≥120) work; Safari support varies. The page feature-detects and shows a banner if absent.

## Limitations (Stage 2 dev stub)

This is a local development stub — see `PLAYGROUND-DESIGN.md` §6 for the full staging plan:

- **Single-request-at-a-time**: no concurrency. Compiles are serialized.
- **No sandboxing or resource limits** on the compiler subprocess. The user program runs sandboxed in the browser, but the compiler itself runs unrestricted.
- **Localhost only**: binds to `127.0.0.1`. Not suitable for public deployment.
- **Stage 3** replaces this stub with a Medaka-native server (blocking-sequential, HTTP-in-Medaka, BSD socket externs).
- **Stage 4** adds subprocess resource limits and richer demos.

## Verification

Quick smoke-test from the repo root (server already running on port 8080):

```sh
# Known-good program → wasm bytes
curl -s -X POST localhost:8080/compile \
  -H 'Content-Type: application/json' \
  -d '{"source":"main = println (sum [1,2,3,4])"}' \
  -o /tmp/out.wasm && wasm-tools validate --features=all /tmp/out.wasm && echo OK

# Type error → JSON diagnostics
curl -s -X POST localhost:8080/compile \
  -H 'Content-Type: application/json' \
  -d '{"source":"main = 1 + \"x\""}' | python3 -m json.tool
```
