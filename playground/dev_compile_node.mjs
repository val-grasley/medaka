#!/usr/bin/env node
// dev_compile_node.mjs — drive the WasmGC-compiled COMBINED Medaka compiler
// (playground.wasm = compiler/entries/playground_main.mdk self-compiled to wasm)
// entirely in Node, via the SHARED playground/compile.mjs seam (the same module the
// browser Stage-3 worker will import) and an IN-MEMORY vfs.  NO native binary, NO
// server.  This dogfoods compile.mjs: it does no host-ABI/vfs work itself.
//
// Usage:
//   node dev_compile_node.mjs <playground.wasm> <runtime.mdk> <core.mdk> <user.mdk>
//
// Output:
//   clean program  → the emitted WAT on stdout (exit 0);
//   broken program → the check --json diagnostics on stdout (exit 1).
import fs from 'node:fs';
import { loadCompiler, compile } from './compile.mjs';

const argv = process.argv.slice(2);
if (argv.length < 4) {
  console.error('usage: dev_compile_node.mjs <playground.wasm> <runtime.mdk> <core.mdk> <user.mdk>');
  process.exit(2);
}
const [wasmPath, runtimePath, corePath, userPath] = argv;

const wasm = await loadCompiler(wasmPath);
const stdlib = {
  runtime: fs.readFileSync(runtimePath, 'utf8'),
  core: fs.readFileSync(corePath, 'utf8'),
};
const source = fs.readFileSync(userPath, 'utf8');

const r = await compile(source, { wasm, stdlib });
if (r.ok) {
  process.stdout.write(r.wat);
  process.exit(0);
} else {
  process.stdout.write(JSON.stringify(r.diagnostics, null, 2) + '\n');
  process.exit(1);
}
