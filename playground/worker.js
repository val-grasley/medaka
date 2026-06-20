// worker.js — Web Worker that instantiates a WasmGC module and posts back stdout/stderr.
// Receives: { wasm: ArrayBuffer }
// Posts:    { type: 'stdout'|'stderr'|'done'|'error', text?: string, message?: string }
//
// Host-import ABI — copied verbatim from test/wasm/run.js (byte-exact vs native oracle).

// fmt12g: reproduce C `%.12g` + the `.0` append rule byte-for-byte.
// `toExponential(11)` = 12 significant digits, correct round-half-to-even.
function fmt12g(d) {
  if (Number.isNaN(d)) return 'nan';
  if (d === Infinity) return 'inf';
  if (d === -Infinity) return '-inf';
  if (d === 0) return (1 / d === -Infinity) ? '-0.0' : '0.0';
  const neg = d < 0, ad = Math.abs(d);
  const m = ad.toExponential(11).match(/^(\d)\.(\d+)e([+-]\d+)$/);
  const digits = m[1] + m[2]; // 12 significant digits
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

// Incremental UTF-8 decoder — posts text chunks as they arrive.
// TextDecoder with stream:true handles multi-byte codepoints across boundaries.
const stdoutDecoder = new TextDecoder('utf-8', { fatal: false });
const stderrDecoder = new TextDecoder('utf-8', { fatal: false });

let floatFmtBuf = [];

const stdoutBuf = [];
const stderrBuf = [];

function flushStdout() {
  if (stdoutBuf.length === 0) return;
  const text = stdoutDecoder.decode(new Uint8Array(stdoutBuf), { stream: true });
  stdoutBuf.length = 0;
  if (text) self.postMessage({ type: 'stdout', text });
}

function flushStderr() {
  if (stderrBuf.length === 0) return;
  const text = stderrDecoder.decode(new Uint8Array(stderrBuf), { stream: true });
  stderrBuf.length = 0;
  if (text) self.postMessage({ type: 'stderr', text });
}

self.onmessage = function(e) {
  const { wasm } = e.data;

  stdoutBuf.length = 0;
  stderrBuf.length = 0;
  floatFmtBuf = [];

  const imports = { env: {
    mdk_write_byte: (b) => {
      stdoutBuf.push(b & 0xff);
      // Flush on newline for responsive streaming.
      if ((b & 0xff) === 10) flushStdout();
    },
    mdk_write_err_byte: (b) => {
      stderrBuf.push(b & 0xff);
      if ((b & 0xff) === 10) flushStderr();
    },
    mdk_float_fmt: (d) => {
      floatFmtBuf = Array.from(new TextEncoder().encode(fmt12g(d)));
      return floatFmtBuf.length;
    },
    mdk_float_fmt_byte: (i) => floatFmtBuf[i] & 0xff,
  } };

  // (start $__init) runs main during instantiate — no entry to call after.
  WebAssembly.instantiate(wasm, imports)
    .then(() => {
      flushStdout();
      flushStderr();
      // Final flush with stream:false to emit any incomplete multi-byte sequence.
      const tail = stdoutDecoder.decode(new Uint8Array(0), { stream: false });
      if (tail) self.postMessage({ type: 'stdout', text: tail });
      self.postMessage({ type: 'done' });
    })
    .catch((err) => {
      flushStdout();
      flushStderr();
      // Medaka panic/exit lowers to unreachable → trap; surface cleanly.
      const msg = err.message || String(err);
      const isPanic = /unreachable|trap|RuntimeError/i.test(msg);
      self.postMessage({
        type: 'error',
        message: isPanic ? 'program panicked' : 'instantiate failed: ' + msg,
      });
    });
};
