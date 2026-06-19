#!/usr/bin/env node
// WasmGC runner — instantiate a module, supply the host IO imports, capture what
// the module writes. `(start $__init)` runs the value-binding prologue + `main`
// during instantiation.
//
// Host-import ABI (WASMGC-DESIGN §6 / §10 fork e — byte-level custom shim, W6):
//   * env.mdk_write_byte (i32) — write ONE byte (0..255) to stdout.
// The module produces ALL its output bytes itself (real intToString / string
// codegen / the byte-write print runtime in selfhost/backend/wasm_preamble.mdk):
// the decimal-int / true|false / newline FORMATTING the W2 scaffold did here is
// gone — this runner only accumulates the raw bytes and UTF-8-decodes them.
// (The legacy env.mdk_write / mdk_write_int / mdk_write_bool imports are removed.)
const fs = require('fs');
const path = process.argv[2];
if (!path) { console.error('usage: run.js <module.wasm>'); process.exit(2); }
const bytes = fs.readFileSync(path);
const acc = [];
const imports = { env: {
  mdk_write_byte: (b) => { acc.push(b & 0xff); },
} };
WebAssembly.instantiate(bytes, imports)
  .then(() => { process.stdout.write(Buffer.from(acc).toString('utf8')); })
  .catch((e) => { console.error('instantiate failed:', e.message); process.exit(1); });
