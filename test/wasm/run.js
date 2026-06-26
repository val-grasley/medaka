#!/usr/bin/env node
// WasmGC runner — instantiate a module, supply the host IO imports, capture what
// the module writes. `(start $__init)` runs the value-binding prologue + `main`
// during instantiation.
//
// Host-import ABI (WASMGC-DESIGN §6 / §10 fork e — byte-level custom shim, W6):
//   * env.mdk_write_byte (i32) — write ONE byte (0..255) to stdout.
// The module produces ALL its output bytes itself (real intToString / string
// codegen / the byte-write print runtime in compiler/backend/wasm_preamble.mdk):
// the decimal-int / true|false / newline FORMATTING the W2 scaffold did here is
// gone — this runner only accumulates the raw bytes and UTF-8-decodes them.
// (The legacy env.mdk_write / mdk_write_int / mdk_write_bool imports are removed.)
const fs = require('fs');
const path = process.argv[2];
if (!path) { console.error('usage: run.js <module.wasm>'); process.exit(2); }
const bytes = fs.readFileSync(path);
const acc = [];
const eacc = [];
// W8b floatToString host seam: reproduce C `%.12g` + the `.0` append rule byte-for-byte.
// `%.12g` is FIXED 12-significant-digit %g (NOT shortest-round-trip dtoa), so
// `toExponential(11)` (12 sig digits, correct round-half-to-even) drives it exactly:
// pick %e form when exp<-4 || exp>=12 else %f form, strip trailing zeros (and a bare
// trailing '.'), 2-digit signed exponent, then append ".0" when there is no
// `.`/`e`/`E`/`n`/`i` (matches medaka_rt.c mdk_float_to_string / mdk_print_float).
function fmt12g(d) {
  if (Number.isNaN(d)) return 'nan';
  if (d === Infinity) return 'inf';
  if (d === -Infinity) return '-inf';
  if (d === 0) return (1 / d === -Infinity) ? '-0.0' : '0.0';
  const neg = d < 0, ad = Math.abs(d);
  const m = ad.toExponential(11).match(/^(\d)\.(\d+)e([+-]\d+)$/);
  const digits = m[1] + m[2];           // 12 significant digits
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
  if (!/[.eEni]/.test(out)) out = out + '.0';   // the `.0` append rule
  return out;
}
let floatFmtBuf = [];   // the most-recently-formatted Float's UTF-8 bytes (ASCII)

// W12 IO host surface (readFile/fileExists/args/getEnv/exit).  GC refs ($str) cannot
// cross the wasm import boundary, so strings are marshaled through a byte-channel:
//   * the guest pushes a path/name into `pathBuf` one byte at a time (mdk_path_push);
//   * the host caches a result's bytes in `resultBuf`, exposing (length, byte-at-i);
//   * args are exposed as (count, per-index length, per-index byte).
//
// GENERIC SEAM: the file source sits behind a small `vfs` object so the browser
// playground can swap an in-memory map for the SAME import signatures (Node fs now,
// virtual-FS later).  `argv` is the configurable program-args source; default [].
const vfs = {
  readFile: (p) => fs.readFileSync(p),   // -> Buffer; throws on missing/unreadable
  exists: (p) => fs.existsSync(p),
};
const argv = (process.env.MDK_ARGS ? process.env.MDK_ARGS.split(' ') : []);
let pathBuf = [];          // bytes the guest pushed for the current path/name
let resultBuf = Buffer.alloc(0);   // bytes of the most recent readFile/getEnv result
const takePath = () => { const s = Buffer.from(pathBuf).toString('utf8'); pathBuf = []; return s; };

const imports = { env: {
  mdk_write_byte: (b) => { acc.push(b & 0xff); },
  // W8 stderr seam (ePutStr / ePutStrLn): the diff gate compares STDOUT only, so a
  // stderr-only fixture's stdout matches on both sides; we still surface these bytes
  // on process.stderr for parity with the native oracle's fd 2.
  mdk_write_err_byte: (b) => { eacc.push(b & 0xff); },
  // W8b floatToString: format the double, cache its bytes, return the byte length;
  // the module then reads each byte via mdk_float_fmt_byte to rebuild a $str.
  mdk_float_fmt: (d) => { floatFmtBuf = Array.from(Buffer.from(fmt12g(d), 'utf8')); return floatFmtBuf.length; },
  mdk_float_fmt_byte: (i) => floatFmtBuf[i] & 0xff,
  // layer-6 stringToFloat: read the bytes pushed into pathBuf, parse as a float via
  // Number() (byte-identical to C strtod on the valid-decimal subset medaka uses).
  // The guest calls mdk_path_reset+mdk_path_push to populate pathBuf, then this.
  mdk_str_to_float: () => { const s = Buffer.from(pathBuf).toString('utf8'); pathBuf = []; return Number(s); },
  // W12 IO host surface (byte-channel; backed by `vfs` / `argv` so the browser can swap).
  mdk_path_reset: () => { pathBuf = []; },
  mdk_path_push: (b) => { pathBuf.push(b & 0xff); },
  mdk_read_file: () => {
    try { resultBuf = vfs.readFile(takePath()); return 1; }
    catch (e) { resultBuf = Buffer.from(String(e.message || e), 'utf8'); return 0; }
  },
  mdk_file_exists: () => (vfs.exists(takePath()) ? 1 : 0),
  mdk_get_env: () => {
    const v = process.env[takePath()];
    if (v === undefined) { resultBuf = Buffer.alloc(0); return 0; }
    resultBuf = Buffer.from(v, 'utf8'); return 1;
  },
  mdk_args_count: () => argv.length,
  mdk_arg_len: (i) => Buffer.byteLength(argv[i], 'utf8'),
  mdk_arg_byte: (i, j) => Buffer.from(argv[i], 'utf8')[j] & 0xff,
  mdk_result_len: () => resultBuf.length,
  mdk_result_byte: (i) => resultBuf[i] & 0xff,
  mdk_exit: (code) => { process.stdout.write(Buffer.from(acc).toString('utf8')); process.exit(code | 0); },
} };
WebAssembly.instantiate(bytes, imports)
  .then(() => {
    process.stdout.write(Buffer.from(acc).toString('utf8'));
    if (eacc.length) process.stderr.write(Buffer.from(eacc).toString('utf8'));
  })
  .catch((e) => { console.error('instantiate failed:', e.message); process.exit(1); });
