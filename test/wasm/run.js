#!/usr/bin/env node
// WasmGC runner — instantiate a module, supply the host IO imports, capture what
// the module writes. `(start $__init)` runs the value-binding prologue + `main`
// during instantiation.
//
// Host-import ABI (WASMGC-DESIGN §6 / §10 fork e — custom shim, the W2 scaffold):
//   * env.mdk_write       (i32) — W1 toolchain proof: writes the int verbatim.
//   * env.mdk_write_int   (i32) — W2 auto-print of an Int  main: decimal + "\n".
//   * env.mdk_write_bool  (i32) — W2 auto-print of a Bool main: "true"/"false" + "\n".
// The decimal / true|false / newline FORMATTING lives here (a temporary W2
// scaffold): once the W6 string slice lands real (array i8) string codegen +
// intToString/Debug, the module will produce the bytes itself and this collapses
// to a byte-level `mdk_write`. The bytes here match the native-compiled oracle's
// pp_value exactly (decimal int, lowercase true/false, one trailing newline).
const fs = require('fs');
const path = process.argv[2];
if (!path) { console.error('usage: run.js <module.wasm>'); process.exit(2); }
const bytes = fs.readFileSync(path);
let out = '';
const imports = { env: {
  mdk_write: (n) => { out += String(n); },
  mdk_write_int: (n) => { out += String(n | 0) + '\n'; },
  mdk_write_bool: (n) => { out += (n ? 'true' : 'false') + '\n'; },
} };
WebAssembly.instantiate(bytes, imports)
  .then(() => { process.stdout.write(out); })
  .catch((e) => { console.error('instantiate failed:', e.message); process.exit(1); });
