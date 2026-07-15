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
// W8b floatToString host seam: reproduce medaka_rt.c mdk_float_lexeme byte-for-byte
// (SHORTEST-ROUND-TRIP since issue #57). `toExponential()` (no arg) is JS's shortest
// half-even scientific form — it matches C's `%.*e` shortest-precision loop EXACTLY,
// including the 17-digit half-way tie (C printf and JS toExponential(16) diverge there
// — half-even vs half-up — but the no-arg shortest form agrees with C). We take only
// its digits + decimal exponent, then re-derive the layout with the SAME fixed
// threshold as C (scientific iff exp<-4 || exp>=12), lowercase 'e', 2-digit signed
// exponent, and the `.0` append rule. Kept byte-identical to playground/worker.js.
function fmt12g(d) {
  if (Number.isNaN(d)) return 'nan';
  if (d === Infinity) return 'inf';
  if (d === -Infinity) return '-inf';
  if (d === 0) return (1 / d === -Infinity) ? '-0.0' : '0.0';
  const neg = d < 0, ad = Math.abs(d);
  const m = ad.toExponential().match(/^(\d)(?:\.(\d+))?e([+-]\d+)$/);
  let digits = m[1] + (m[2] || '');     // shortest significant digits
  const exp = parseInt(m[3], 10);
  digits = digits.replace(/0+$/, '');   // trim (defensive)
  if (digits === '') digits = '0';
  const nd = digits.length;
  let out;
  if (exp < -4 || exp >= 12) {
    const mant = (nd === 1) ? digits : (digits[0] + '.' + digits.slice(1));
    const ea = Math.abs(exp).toString().padStart(2, '0');
    out = mant + 'e' + (exp < 0 ? '-' : '+') + ea;
  } else {
    const pointPos = exp + 1;
    if (pointPos <= 0) out = '0.' + '0'.repeat(-pointPos) + digits;
    else if (pointPos >= nd) out = digits + '0'.repeat(pointPos - nd);
    else out = digits.slice(0, pointPos) + '.' + digits.slice(pointPos);
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
  writeFile: (p, buf) => fs.writeFileSync(p, buf),   // throws on unwritable path
};
const argv = (process.env.MDK_ARGS ? process.env.MDK_ARGS.split(' ') : []);
let pathBuf = [];          // bytes the guest pushed for the current path/name
let resultBuf = Buffer.alloc(0);   // bytes of the most recent readFile/getEnv result
let writeBuf = [];         // stage-D: bytes the guest streamed for writeFileBytes
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
  // stage-D: byte-clean file WRITE seam (writeFileBytes).  The path arrives via the
  // existing mdk_path_push channel; bytes stream into writeBuf; commit does an
  // fs.writeFileSync (via the swappable vfs).  Ok -> 1; on error cache the message in
  // resultBuf (so the guest rebuilds an Err $str) and return 0.  Mirrors readFile.
  mdk_write_file_reset: () => { writeBuf = []; },
  mdk_write_file_push: (b) => { writeBuf.push(b & 0xff); },
  mdk_write_file_commit: () => {
    try { vfs.writeFile(takePath(), Buffer.from(writeBuf)); writeBuf = []; return 1; }
    catch (e) { resultBuf = Buffer.from(String(e.message || e), 'utf8'); writeBuf = []; return 0; }
  },
  mdk_exit: (code) => { process.stdout.write(Buffer.from(acc).toString('utf8')); process.exit(code | 0); },
} };
WebAssembly.instantiate(bytes, imports)
  .then(() => {
    process.stdout.write(Buffer.from(acc).toString('utf8'));
    if (eacc.length) process.stderr.write(Buffer.from(eacc).toString('utf8'));
  })
  .catch((e) => {
    // A Medaka runtime trap: the guest streamed a coded `runtime error [E-CODE]: …`
    // line to stderr (via mdk_write_err_byte) and any pre-trap stdout to stdout BEFORE
    // the `unreachable`. Flush BOTH (native + playground preserve partial stdout too),
    // then surface the captured coded stderr instead of the engine's generic message.
    if (acc.length) process.stdout.write(Buffer.from(acc).toString('utf8'));
    if (eacc.length) process.stderr.write(Buffer.from(eacc).toString('utf8'));
    else process.stderr.write('instantiate failed: ' + (e && e.message ? e.message : String(e)) + '\n');
    process.exit(1);
  });
