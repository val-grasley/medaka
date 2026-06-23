#!/usr/bin/env node
// client_flow_test.mjs — Node integration test for the Stage-3 client-side compile flow.
//
// Runs the EXACT logic compiler-worker.js will execute in the browser:
//   1. load playground.wasm via compile.mjs
//   2. call compile(source, {wasm, stdlib}) → { ok, wat | diagnostics }
//   3. assemble WAT → wasm bytes via wat2wasm.js
//   4. WebAssembly.validate the result
//   5. run via the worker.js host ABI → assert stdout
//
// Cases:
//   A. clean: `main = println (1+2)` → ok:true → validate → run → "3"
//   B. broken: `main = println (1 + "hello")` → ok:false → diagnostics non-empty
//
// Usage: node --experimental-vm-modules client_flow_test.mjs
// (--experimental-vm-modules is not required; regular ESM dynamic import is fine)
//
// Paths: reads dist/playground.wasm, dist/runtime.mdk, dist/core.mdk,
//        vendor/wat2wasm/wat2wasm_bg.wasm — all relative to playground/.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = dirname(__filename);

// ── imports ───────────────────────────────────────────────────────────────────
import { loadCompiler, compile } from './compile.mjs';
import initWat2Wasm, { wat2wasm } from './vendor/wat2wasm/wat2wasm.js';

// ── asset paths ───────────────────────────────────────────────────────────────
const PLAYGROUND_WASM  = join(__dirname, 'dist', 'playground.wasm');
const RUNTIME_MDK      = join(__dirname, 'dist', 'runtime.mdk');
const CORE_MDK         = join(__dirname, 'dist', 'core.mdk');
const WAT2WASM_BG_WASM = join(__dirname, 'vendor', 'wat2wasm', 'wat2wasm_bg.wasm');

// ── runner host ABI (mirrors worker.js compute-only subset) ──────────────────
// Runs an assembled user wasm, returning its stdout string.
function runWasm(bytes) {
  const acc = [];
  const enc = new TextEncoder();
  const dec = new TextDecoder('utf-8');
  class ExitSignal extends Error { constructor(c) { super(); this.code = c; } }

  const imports = { env: {
    mdk_write_byte: (b) => acc.push(b & 0xff),
    mdk_write_err_byte: () => {},
    mdk_float_fmt:       () => 0,
    mdk_float_fmt_byte:  () => 0,
    mdk_str_to_float:    () => 0,
    mdk_path_reset:      () => {},
    mdk_path_push:       () => {},
    mdk_read_file:       () => 0,
    mdk_file_exists:     () => 0,
    mdk_get_env:         () => 0,
    mdk_args_count:      () => 0,
    mdk_arg_len:         () => 0,
    mdk_arg_byte:        () => 0,
    mdk_result_len:      () => 0,
    mdk_result_byte:     () => 0,
    mdk_exit: (c) => { throw new ExitSignal(c); },
  } };

  return WebAssembly.instantiate(bytes, imports)
    .then(() => dec.decode(new Uint8Array(acc)))
    .catch((e) => {
      if (e instanceof ExitSignal) return dec.decode(new Uint8Array(acc));
      throw e;
    });
}

// ── test harness ──────────────────────────────────────────────────────────────
let pass = 0;
let fail = 0;

function ok(name) {
  console.log('  PASS: ' + name);
  pass++;
}

function fail_(name, detail) {
  console.error('  FAIL: ' + name + '\n        ' + detail);
  fail++;
}

// ── setup: load assets ────────────────────────────────────────────────────────
console.log('\n=== Stage-3 client flow integration test ===\n');

let wasmBytes, runtime, core, wat2wasmBytes;
try {
  wasmBytes     = readFileSync(PLAYGROUND_WASM);
  runtime       = readFileSync(RUNTIME_MDK,      'utf8');
  core          = readFileSync(CORE_MDK,          'utf8');
  wat2wasmBytes = readFileSync(WAT2WASM_BG_WASM);
} catch (e) {
  console.error('SETUP FAILED: ' + e.message);
  console.error('Run: bash playground/build_playground_wasm.sh');
  process.exit(2);
}

// Initialize wat2wasm assembler (single-object form, no deprecation warning).
const wat2wasmBuf = wat2wasmBytes.buffer.slice(
  wat2wasmBytes.byteOffset, wat2wasmBytes.byteOffset + wat2wasmBytes.byteLength
);
await initWat2Wasm({ module_or_path: wat2wasmBuf });

const wasm   = new Uint8Array(wasmBytes);
const stdlib = { runtime, core };

// ── Case A: clean program ─────────────────────────────────────────────────────
console.log('Case A: clean program (1+2)');
{
  const r = await compile('main = println (1+2)\n', { wasm, stdlib });
  if (!r.ok) {
    fail_('compile returned ok:false', JSON.stringify(r.diagnostics).slice(0, 200));
  } else {
    ok('compile → ok:true, WAT produced (' + r.wat.length + ' chars)');

    // Assemble WAT → wasm bytes.
    let assembled;
    try {
      assembled = wat2wasm(r.wat);
      ok('wat2wasm assembled (' + assembled.byteLength + ' bytes)');
    } catch (e) {
      fail_('wat2wasm threw', String(e).slice(0, 200));
      assembled = null;
    }

    if (assembled) {
      // Validate the assembled wasm.
      const valid = WebAssembly.validate(assembled);
      if (valid) ok('WebAssembly.validate = true');
      else       fail_('WebAssembly.validate', 'returned false');

      // Run it and check stdout.
      try {
        const stdout = (await runWasm(assembled)).trim();
        if (stdout === '3') ok('run output = "3"');
        else               fail_('run output mismatch', 'got ' + JSON.stringify(stdout) + ', want "3"');
      } catch (e) {
        fail_('run threw', e && e.message || String(e));
      }
    }
  }
}

// ── Case B: type-broken program ───────────────────────────────────────────────
console.log('\nCase B: type-broken program (1 + "hello")');
{
  const r = await compile('main = println (1 + "hello")\n', { wasm, stdlib });
  if (r.ok) {
    fail_('compile returned ok:true (expected ok:false)', '');
  } else {
    ok('compile → ok:false');
    const files = r.diagnostics && r.diagnostics.files;
    if (files && files.length > 0 && files[0].diagnostics && files[0].diagnostics.length > 0) {
      ok('diagnostics non-empty: ' + JSON.stringify(files[0].diagnostics[0].message).slice(0, 80));
    } else {
      fail_('diagnostics empty or malformed', JSON.stringify(r.diagnostics).slice(0, 200));
    }
  }
}

// ── Case C: parse-broken program ─────────────────────────────────────────────
console.log('\nCase C: parse-broken program');
{
  const r = await compile('main = println (1 +\n', { wasm, stdlib });
  if (r.ok) {
    fail_('compile returned ok:true (expected ok:false)', '');
  } else {
    ok('compile → ok:false (parse error)');
    const files = r.diagnostics && r.diagnostics.files;
    if (files && files.length > 0 && files[0].diagnostics && files[0].diagnostics.length > 0) {
      ok('diagnostics non-empty: ' + JSON.stringify(files[0].diagnostics[0].message).slice(0, 80));
    } else {
      fail_('diagnostics empty or malformed', JSON.stringify(r.diagnostics).slice(0, 200));
    }
  }
}

// ── Summary ───────────────────────────────────────────────────────────────────
console.log('\n=== ' + pass + ' pass / ' + fail + ' fail ===\n');
process.exit(fail > 0 ? 1 : 0);
