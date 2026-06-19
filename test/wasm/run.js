#!/usr/bin/env node
// Slice W1 runner: instantiate a WasmGC module, supply the host IO import,
// capture what the module writes. `(start)` runs $main during instantiation.
const fs = require('fs');
const path = process.argv[2];
if (!path) { console.error('usage: run.js <module.wasm>'); process.exit(2); }
const bytes = fs.readFileSync(path);
let out = '';
const imports = { env: { mdk_write: (n) => { out += String(n); } } };
WebAssembly.instantiate(bytes, imports)
  .then(() => { process.stdout.write(out); })
  .catch((e) => { console.error('instantiate failed:', e.message); process.exit(1); });
