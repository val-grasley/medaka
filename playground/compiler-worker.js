// compiler-worker.js — Module Web Worker: compiles Medaka source to wasm bytes.
//
// This runs in a Worker context (type:'module') so it can import ES modules.
// It uses compile.mjs (the environment-agnostic seam) + vendor/wat2wasm/wat2wasm.js
// (the browser WAT assembler) — no network calls after initial asset load.
//
// Protocol:
//   Receives: { source: string, assets: { wasm: ArrayBuffer, runtime: string, core: string,
//                                          wat2wasmBytes: ArrayBuffer } }
//   Posts:    { ok: false, diagnostics }          — type/parse error; diagnostics = check --json shape
//           | { ok: true,  wasm: ArrayBuffer, diagnostics? } — assembled user wasm (transferable);
//             diagnostics present only when the clean compile still had WARNINGS
//             (e.g. W-NONEXHAUSTIVE) — the program still runs, but main.js should
//             also surface the warnings in the console.
//           | { ok: false, diagnostics: <synthErr> } — on unexpected compile/assemble error
//
// Keeps all heavy work (playground.wasm instantiation + WAT assembly) off the
// main thread so the UI stays responsive.  The main thread hands the result wasm
// bytes to the existing worker.js runner (which has its own 10s kill-timer).

import { compile } from './compile.mjs';
import initWat2Wasm, { wat2wasm } from './vendor/wat2wasm/wat2wasm.js';

// Track whether wat2wasm has been initialized (it's idempotent but we skip the
// redundant await on subsequent calls).
let wat2wasmReady = false;

self.onmessage = async function(e) {
  const { source, assets } = e.data;
  const { wasm: wasmBuffer, runtime, core, wat2wasmBytes, extra } = assets;

  // Initialize the WAT assembler on first use (pass bytes directly to avoid a
  // fetch; uses the single-object form to suppress the deprecation warning).
  if (!wat2wasmReady) {
    try {
      await initWat2Wasm({ module_or_path: new Uint8Array(wat2wasmBytes) });
      wat2wasmReady = true;
    } catch (err) {
      self.postMessage({ ok: false, diagnostics: synthErr('wat2wasm init failed: ' + (err && err.message || String(err))) });
      return;
    }
  }

  // Step 1: compile source to WAT (or collect diagnostics) via playground.wasm.
  let compileResult;
  try {
    compileResult = await compile(source, {
      wasm: new Uint8Array(wasmBuffer),
      stdlib: { runtime, core, extra },
    });
  } catch (err) {
    self.postMessage({ ok: false, diagnostics: synthErr('compile error: ' + (err && err.message || String(err))) });
    return;
  }

  if (!compileResult.ok) {
    // Type/parse error — forward diagnostics to main thread.
    self.postMessage({ ok: false, diagnostics: compileResult.diagnostics });
    return;
  }

  // Step 2: assemble the WAT string to wasm bytes.
  let userWasmBytes;
  try {
    userWasmBytes = wat2wasm(compileResult.wat);
  } catch (err) {
    // wat2wasm throws a human-readable error string on invalid WAT.
    const msg = (typeof err === 'string') ? err : (err && err.message || String(err));
    self.postMessage({ ok: false, diagnostics: synthErr('assembler error: ' + msg) });
    return;
  }

  // Transfer the ArrayBuffer (zero-copy) to the main thread.  Forward warnings
  // (if any) so the run path can also surface them, even though the program runs.
  const buf = userWasmBytes.buffer;
  self.postMessage({ ok: true, wasm: buf, diagnostics: compileResult.diagnostics }, [buf]);
};

function synthErr(message) {
  return {
    files: [{
      file: './main.mdk',
      diagnostics: [{
        message,
        range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } },
        severity: 1,
        source: 'medaka',
      }],
    }],
  };
}
