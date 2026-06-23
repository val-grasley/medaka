#!/usr/bin/env node
// dev_compile_node.mjs — run the WasmGC-compiled Medaka compiler (compiler.wasm =
// the modules emitter self-compiled to wasm) entirely in Node with an IN-MEMORY vfs.
//
// This is the playground proof-of-concept: NO native binary, NO disk reads for the
// stdlib — the browser will do exactly this with the same host ABI but a virtual FS.
//
// Usage:
//   node dev_compile_node.mjs <compiler.wasm> <runtime.mdk> <core.mdk> <user.mdk> [extra.mdk=path ...]
//
// It marshals args [runtime.mdk, core.mdk, user.mdk] to the guest, serves files from
// an in-memory map (keys = the paths the guest will request), and prints the WAT the
// compiler emits on stdout. stderr is surfaced to our stderr.
import fs from 'node:fs';

const argvFull = process.argv.slice(2);
if (argvFull.length < 4) {
  console.error('usage: dev_compile_node.mjs <compiler.wasm> <runtime.mdk> <core.mdk> <user.mdk> [root ...]');
  process.exit(2);
}
const [wasmPath, runtimePath, corePath, userPath, ...extraRoots] = argvFull;

// In-memory vfs: map the request path -> bytes.  The guest requests the literal
// path strings we pass as args, plus core.mdk's own internal imports resolved
// relative to roots.  We seed the three explicit files under their basenames AND
// any root-relative resolution the loader does.  Simplest faithful model: serve
// by the EXACT path string the guest pushes; we register each file under the
// path we hand it as an arg, and also probe disk as a fallback for stdlib imports
// the loader pulls (e.g. list.mdk, map.mdk) — but for a TRUE in-memory test we
// preload the whole stdlib + selfhost dirs the user program's roots can reach.
const vfsMap = new Map();
function reg(p, realPath) { vfsMap.set(p, fs.readFileSync(realPath)); }
reg(runtimePath, runtimePath);
reg(corePath, corePath);
reg(userPath, userPath);

// The loader resolves imports (e.g. `import list`) to <root>/list.mdk.  For the
// user program's root (= dirOf(userPath)) preload every .mdk sibling so a
// prelude-using program finds its imports purely in-memory.
import path from 'node:path';
const userRoot = path.dirname(userPath) || '.';
for (const f of fs.readdirSync(userRoot)) {
  if (f.endsWith('.mdk')) {
    const p = path.join(userRoot, f);
    if (!vfsMap.has(p)) vfsMap.set(p, fs.readFileSync(p));
  }
}
// Also preload stdlib/*.mdk under both "stdlib/x.mdk" and "x.mdk" keys, since
// dot-imports may resolve against the stdlib root or the cwd-relative path.
const stdlibDir = path.dirname(runtimePath);
for (const f of fs.readdirSync(stdlibDir)) {
  if (f.endsWith('.mdk')) {
    const full = path.join(stdlibDir, f);
    if (!vfsMap.has(full)) vfsMap.set(full, fs.readFileSync(full));
    if (!vfsMap.has(f)) vfsMap.set(f, fs.readFileSync(full));
  }
}

const vfs = {
  readFile: (p) => {
    if (vfsMap.has(p)) return vfsMap.get(p);
    // Fallback to disk for any path we did not preload (so we can SEE what the
    // guest asks for during bring-up).  A true browser vfs would throw here.
    if (process.env.VFS_STRICT) throw new Error('ENOENT (vfs strict): ' + p);
    try { return fs.readFileSync(p); } catch (e) { throw e; }
  },
  exists: (p) => vfsMap.has(p) || (!process.env.VFS_STRICT && fs.existsSync(p)),
};

const argv = [runtimePath, corePath, userPath, ...extraRoots];

// ── host ABI (copied from test/wasm/run.js, vfs/argv swapped to in-memory) ──────
const bytes = fs.readFileSync(wasmPath);
const acc = [];
const eacc = [];
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
let floatFmtBuf = [];
let pathBuf = [];
let resultBuf = Buffer.alloc(0);
const takePath = () => { const s = Buffer.from(pathBuf).toString('utf8'); pathBuf = []; return s; };

const imports = { env: {
  mdk_write_byte: (b) => { acc.push(b & 0xff); },
  mdk_write_err_byte: (b) => { eacc.push(b & 0xff); },
  mdk_float_fmt: (d) => { floatFmtBuf = Array.from(Buffer.from(fmt12g(d), 'utf8')); return floatFmtBuf.length; },
  mdk_float_fmt_byte: (i) => floatFmtBuf[i] & 0xff,
  mdk_str_to_float: () => { const s = Buffer.from(pathBuf).toString('utf8'); pathBuf = []; return Number(s); },
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
  mdk_exit: (code) => {
    process.stdout.write(Buffer.from(acc).toString('utf8'));
    if (eacc.length) process.stderr.write(Buffer.from(eacc).toString('utf8'));
    process.exit(code | 0);
  },
} };

WebAssembly.instantiate(bytes, imports)
  .then(() => {
    process.stdout.write(Buffer.from(acc).toString('utf8'));
    if (eacc.length) process.stderr.write(Buffer.from(eacc).toString('utf8'));
  })
  .catch((e) => { console.error('instantiate failed:', e.message); process.exit(1); });
