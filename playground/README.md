# Medaka Playground

An install-free web playground for [Medaka](../README.md): edit source, hit Run,
see output. The Medaka compiler runs **entirely in the browser** as a WasmGC module —
no server is involved in compilation. User programs compile to WasmGC and run in a
sandboxed Web Worker.

## Architecture

```
Browser
┌──────────────────────────────────────────────────────────────────┐
│  editor (textarea)                                                │
│                                                                   │
│  Run ──► compiler-worker.js (module Worker)                       │
│            │  compile.mjs: compile(source, {wasm, stdlib})        │
│            │    playground.wasm  (Medaka compiler, WasmGC)        │
│            │    + runtime.mdk + core.mdk (fed via in-memory vfs)  │
│            │                                                       │
│            ├─► ok=false  → diagnostics pane (line/col JSON)       │
│            │                                                       │
│            └─► ok=true, wat  → vendor/wat2wasm (Rust blob)        │
│                  wat2wasm_bg.wasm assembles WAT → binary bytes     │
│                      │                                             │
│                      └─► worker.js (runner Worker)                 │
│                            WebAssembly.instantiate(bytes, glue)   │
│                            mdk_write_byte → stdout pane           │
│                            10 s wall-clock kill-timer             │
└──────────────────────────────────────────────────────────────────┘
```

Data flow: `source → compile.mjs (playground.wasm) → diagnostics | WAT → wat2wasm → bytes → worker.js runs`

### Key files

| File | Role |
|------|------|
| `compiler/entries/playground_main.mdk` | Combined compiler entry: runs the front-end once; outputs `__MEDAKA_DIAGNOSTICS__` + JSON (check errors) or `__MEDAKA_WAT__` + WAT (clean) |
| `playground/compile.mjs` | Env-agnostic compile seam: `compile(source,{wasm,stdlib})` → `{ok:true,wat}` or `{ok:false,diagnostics}` |
| `playground/compiler-worker.js` | Module Worker: runs compile + wat2wasm assembly off the UI thread |
| `playground/worker.js` | Runner Worker: instantiates the assembled user wasm with host-import glue + 10 s kill-timer |
| `playground/main.js` | Page glue: fetches 4 static assets once, orchestrates compiler-worker → runner worker, renders output |
| `playground/server.js` | Static file server only — no `/compile` endpoint, no medaka subprocess at runtime |
| `playground/vendor/wat2wasm/` | Committed browser WAT→wasm assembler: Rust `wat` crate v1.252.0 wrapped with wasm-bindgen (~708 KB `_bg.wasm`) |
| `playground/dist/` | Gitignored build artifacts (`playground.wasm`, `runtime.mdk`, `core.mdk`) |

## Build steps

### One-time: rebuild the wat2wasm assembler blob (requires Rust + wasm-pack)

The `vendor/wat2wasm/` directory is **already committed** — you only need to
re-run this if regenerating the blob (e.g. after a `wat` crate version bump):

```sh
bash playground/build_assembler.sh
```

This requires a Rust toolchain and `wasm-pack`. The output is committed, so
most contributors never need to run this.

### Build the playground compiler wasm

Produces `playground/dist/playground.wasm` (~2.6 MB) and copies
`stdlib/runtime.mdk` + `stdlib/core.mdk` into `playground/dist/`:

```sh
bash playground/build_playground_wasm.sh
```

Prerequisites (checked and run automatically by the script):
- `make medaka` — native compiler + `medaka_emitter` binary
- `bash test/wasm/build_wasm_oracle.sh` — wasm emitter binary (`test/bin/wasm_emit_modules_main`)
- `wasm-tools` on PATH (`wasm-tools --version`)

### (Optional) Package a deployable site folder

```sh
bash playground/build_site.sh
```

Assembles `playground/site/` with exactly the files a static CDN needs (runs
`build_playground_wasm.sh` first if `dist/playground.wasm` is missing). Prints
the folder size and a one-line deploy note. `playground/site/` is gitignored.

## Running locally

```sh
node playground/server.js
```

Open **http://localhost:8080** in a WasmGC-capable browser (see browser support
below). Default port is 8080; override with `PORT=<n>`.

The server is a zero-dependency static file server. No compilation happens
server-side — everything runs in the browser.

## Browser support

WasmGC (finalized encoding, Wasm GC MVP) is Baseline since December 2024:

| Browser | Min version | Notes |
|---------|-------------|-------|
| Chrome | ≥ 119 | |
| Firefox | ≥ 120 | |
| Safari | ≥ 18.2 | macOS Sequoia 15.2 / iOS 18.2 |
| iOS / iPadOS | ≥ 18.2 | **All iOS browsers are WebKit** — iOS < 18.2 has NO WasmGC |
| Node | ≥ 22 | Build/test harness only; not required at runtime |

The page feature-detects WasmGC and shows a banner if the browser doesn't support
it. iOS < 18.2 is a shrinking tail.

## Deploying

The playground is a **pure static site** — no compile server, no container, no
backend of any kind at runtime. Upload `playground/site/` (built by
`build_site.sh`) to any static CDN: GitHub Pages, Cloudflare Pages, Netlify, etc.

See `PLAYGROUND-DESIGN.md` §6.1 for the hosting rationale and the superseded
container-based plan.
