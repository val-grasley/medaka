// compile.mjs — reusable, environment-agnostic seam between the WasmGC-compiled
// Medaka compiler (playground.wasm = the COMBINED diagnostics+emit entry,
// selfhost/entries/playground_main.mdk) and its callers (the Node dev driver now,
// the browser Web Worker in Stage 3).
//
// It instantiates playground.wasm with the host IO ABI (a port of test/wasm/run.js)
// over an IN-MEMORY vfs (stdlib runtime.mdk/core.mdk + the user source), runs the
// guest once, and demuxes the guest's stdout by its first-line marker:
//
//   __MEDAKA_WAT__\n<wat>            -> { ok: true,  wat }
//   __MEDAKA_DIAGNOSTICS__\n<json>   -> { ok: false, diagnostics }   (check --json shape)
//
// `diagnostics` is the parsed {"files":[{file,diagnostics:[...]}]} object, drop-in
// for playground/main.js's renderDiagnostics (it reads `.files`/`.errors`).
//
// API:
//   const wasm = await loadCompiler(wasmBytesOrPath);   // Node: path or bytes; browser: bytes
//   const r = await compile(source, { wasm, stdlib });
//     stdlib = { runtime: <runtime.mdk text>, core: <core.mdk text> }
//     r = { ok:true, wat:string } | { ok:false, diagnostics:{files:[...]} }
//
// The vfs/host-ABI is deliberately self-contained so the browser worker can import
// this module unchanged (pass wasm bytes + stdlib text; no node:fs needed there).

// Guest arg paths (also the vfs keys).  The guest requests these literal strings.
// The user entry + its sibling imports go through the loader, which resolves a
// module id to "<root>/<id>.mdk"; with root '.' that yields "./main.mdk", so we
// register the user file (and any extra stdlib siblings) under the "./"-prefixed
// keys the loader will request.  runtime.mdk/core.mdk are read directly via their
// arg paths (NOT through the loader), so they keep their bare names.
const RUNTIME_PATH = 'runtime.mdk';
const CORE_PATH = 'core.mdk';
const USER_ROOT = '.';
const USER_PATH = './main.mdk';
const USER_MODID = 'main';

// ── host ABI (ported from test/wasm/run.js / dev_compile_node.mjs) ──────────────
function fmt12g(d) {
  if (Number.isNaN(d)) return 'nan';
  if (d === Infinity) return 'inf';
  if (d === -Infinity) return '-inf';
  if (d === 0) return (1 / d === -Infinity) ? '-0.0' : '0.0';
  const neg = d < 0, ad = Math.abs(d);
  const m = ad.toExponential(11).match(/^(\d)\.(\d+)e([+-]\d+)$/);
  const digits = m[1] + m[2];
  const exp = parseInt(m[3], 10);
  let out;
  if (exp < -4 || exp >= 12) {
    let mant = digits.replace(/0+$/, '');
    if (mant.length > 1) mant = mant[0] + '.' + mant.slice(1);
    const ea = Math.abs(exp).toString().padStart(2, '0');
    out = mant + 'e' + (exp < 0 ? '-' : '+') + ea;
  } else {
    const pointPos = exp + 1;
    if (pointPos <= 0) out = '0.' + '0'.repeat(-pointPos) + digits;
    else if (pointPos >= digits.length) out = digits + '0'.repeat(pointPos - digits.length);
    else out = digits.slice(0, pointPos) + '.' + digits.slice(pointPos);
    if (out.indexOf('.') >= 0) out = out.replace(/0+$/, '').replace(/\.$/, '');
  }
  if (neg) out = '-' + out;
  if (!/[.eEni]/.test(out)) out = out + '.0';
  return out;
}

const enc = (s) => new TextEncoder().encode(s);
const dec = (a) => new TextDecoder('utf8').decode(new Uint8Array(a));

// Run the compiler guest once over an in-memory vfs.  `vfsMap` = Map<path, Uint8Array>.
// `argv` = string[].  Returns { out, err, exit } (out/err as strings).
function runGuest(wasmModuleOrBytes, vfsMap, argv) {
  return new Promise((resolve, reject) => {
    const acc = [];
    const eacc = [];
    let floatFmtBuf = [];
    let pathBuf = [];
    let resultBuf = new Uint8Array(0);
    const takePath = () => { const s = dec(pathBuf); pathBuf = []; return s; };
    let exited = false;
    const finish = (code) => {
      if (exited) return;
      exited = true;
      resolve({ out: dec(acc), err: dec(eacc), exit: code | 0 });
    };

    const imports = { env: {
      mdk_write_byte: (b) => { acc.push(b & 0xff); },
      mdk_write_err_byte: (b) => { eacc.push(b & 0xff); },
      mdk_float_fmt: (d) => { floatFmtBuf = Array.from(enc(fmt12g(d))); return floatFmtBuf.length; },
      mdk_float_fmt_byte: (i) => floatFmtBuf[i] & 0xff,
      mdk_str_to_float: () => { const s = dec(pathBuf); pathBuf = []; return Number(s); },
      mdk_path_reset: () => { pathBuf = []; },
      mdk_path_push: (b) => { pathBuf.push(b & 0xff); },
      mdk_read_file: () => {
        const p = takePath();
        if (vfsMap.has(p)) { resultBuf = vfsMap.get(p); return 1; }
        resultBuf = enc('ENOENT: ' + p); return 0;
      },
      mdk_file_exists: () => (vfsMap.has(takePath()) ? 1 : 0),
      mdk_get_env: () => { takePath(); resultBuf = new Uint8Array(0); return 0; },
      mdk_args_count: () => argv.length,
      mdk_arg_len: (i) => enc(argv[i]).length,
      mdk_arg_byte: (i, j) => enc(argv[i])[j] & 0xff,
      mdk_result_len: () => resultBuf.length,
      mdk_result_byte: (i) => resultBuf[i] & 0xff,
      mdk_exit: (code) => { finish(code); throw new ExitSignal(); },
    } };

    const bytes = (wasmModuleOrBytes instanceof Uint8Array || wasmModuleOrBytes instanceof ArrayBuffer)
      ? wasmModuleOrBytes : wasmModuleOrBytes;

    WebAssembly.instantiate(bytes, imports)
      .then(() => finish(0))
      .catch((e) => {
        if (e instanceof ExitSignal || exited) { finish(0); return; }
        reject(e);
      });
  });
}

// Thrown from mdk_exit to unwind the guest after a clean exit (mirrors run.js).
class ExitSignal extends Error {}

// loadCompiler: normalize the wasm to bytes.  In Node, accepts a path or bytes;
// in the browser pass bytes (or a Response via arrayBuffer first).
export async function loadCompiler(src) {
  if (typeof src === 'string') {
    // Node path. Dynamic import keeps this module browser-safe.
    const fs = await import('node:fs');
    return new Uint8Array(fs.readFileSync(src));
  }
  if (src instanceof ArrayBuffer) return new Uint8Array(src);
  return src; // assume Uint8Array
}

// compile: the seam Stage 3 imports.
//   source : user .mdk text
//   opts.wasm   : Uint8Array of playground.wasm (from loadCompiler)
//   opts.stdlib : { runtime: <runtime.mdk text>, core: <core.mdk text> }
// Returns { ok:true, wat } or { ok:false, diagnostics } (parsed check --json object).
// On an unexpected guest trap (should not happen for the supported program shapes),
// returns { ok:false, diagnostics: <synthetic single-file error> }.
export async function compile(source, opts = {}) {
  const { wasm, stdlib } = opts;
  if (!wasm) throw new Error('compile: opts.wasm (playground.wasm bytes) required');
  if (!stdlib || stdlib.runtime == null || stdlib.core == null)
    throw new Error('compile: opts.stdlib { runtime, core } required');

  const vfsMap = new Map();
  vfsMap.set(RUNTIME_PATH, enc(stdlib.runtime));
  vfsMap.set(CORE_PATH, enc(stdlib.core));
  vfsMap.set(USER_PATH, enc(source));
  // A prelude-only program resolves no sibling imports.  Extra stdlib modules
  // (list/map/...) a program imports go in opts.stdlib.extra as { '<id>': text }
  // (e.g. { 'list': '...' }), registered under the loader's "./<id>.mdk" key.
  if (stdlib.extra) for (const [id, text] of Object.entries(stdlib.extra)) {
    vfsMap.set(USER_ROOT + '/' + id + '.mdk', enc(text));
  }

  // argv = <runtime.mdk> <core.mdk> <entry.mdk> <root>.  The loader resolves the
  // entry's module id "main" against root "." → "./main.mdk" (a registered key).
  const argv = [RUNTIME_PATH, CORE_PATH, USER_PATH, USER_ROOT];

  let res;
  try {
    res = await runGuest(wasm, vfsMap, argv);
  } catch (e) {
    return { ok: false, diagnostics: synthErr('compiler trap: ' + (e && e.message || e)) };
  }

  const out = res.out;
  const nl = out.indexOf('\n');
  const marker = nl >= 0 ? out.slice(0, nl) : out;
  const payload = nl >= 0 ? out.slice(nl + 1) : '';

  if (marker === '__MEDAKA_WAT__') {
    return { ok: true, wat: payload };
  }
  if (marker === '__MEDAKA_DIAGNOSTICS__') {
    try {
      return { ok: false, diagnostics: JSON.parse(payload.trim()) };
    } catch (e) {
      return { ok: false, diagnostics: synthErr('bad diagnostics JSON: ' + payload.slice(0, 200)) };
    }
  }
  // No recognized marker — surface stderr/stdout as a synthetic diagnostic so the
  // caller never silently swallows a failure.
  return { ok: false, diagnostics: synthErr('unexpected compiler output: ' + (res.err || out).slice(0, 400)) };
}

function synthErr(message) {
  return { files: [{
    file: USER_PATH,
    diagnostics: [{
      message,
      range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } },
      severity: 1,
      source: 'medaka',
    }],
  }] };
}
