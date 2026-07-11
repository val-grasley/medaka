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

// W12 IO host surface (readFile/fileExists/args/getEnv/exit) + layer-6 stringToFloat
// share a byte-channel: the guest pushes a path/name into `pathBuf` one byte at a time
// (mdk_path_reset/mdk_path_push), then calls the op that consumes it. None of the real
// IO ops (file/env/args/exit) are available inside the worker sandbox — those throw a
// CapabilityError with a friendly message instead of a cryptic LinkError/trap; the
// str_to_float / path plumbing itself is pure and IS implemented for real (mirrors
// test/wasm/run.js byte-for-byte).
let pathBuf = [];
const takePath = () => { const s = new TextDecoder('utf-8').decode(new Uint8Array(pathBuf)); pathBuf = []; return s; };

// Thrown by the IO-capability stubs below. Caught in the instantiate .catch handler
// and surfaced verbatim (no "instantiate failed:" prefix, no generic panic wording).
class CapabilityError extends Error {}
const capabilityStub = (name) => () => {
  throw new CapabilityError(
    `${name} is not available in the online playground — use \`medaka build\` locally for file/IO access.`
  );
};

const stdoutBuf = [];
const stderrBuf = [];
// B5: a persistent copy of ALL stderr bytes (stderrBuf is drained on each flush). On a
// runtime trap the guest streams a coded `runtime error [E-CODE]: …` line here before
// the `unreachable`; the catch handler surfaces THAT instead of a generic message.
let stderrAll = [];

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
  stderrAll = [];
  floatFmtBuf = [];

  const imports = { env: {
    mdk_write_byte: (b) => {
      stdoutBuf.push(b & 0xff);
      // Flush on newline for responsive streaming.
      if ((b & 0xff) === 10) flushStdout();
    },
    mdk_write_err_byte: (b) => {
      stderrBuf.push(b & 0xff);
      stderrAll.push(b & 0xff);
      if ((b & 0xff) === 10) flushStderr();
    },
    mdk_float_fmt: (d) => {
      floatFmtBuf = Array.from(new TextEncoder().encode(fmt12g(d)));
      return floatFmtBuf.length;
    },
    mdk_float_fmt_byte: (i) => floatFmtBuf[i] & 0xff,
    // layer-6 stringToFloat: real, pure — parse the pathBuf bytes as a float via
    // Number() (byte-identical to C strtod on the valid-decimal subset medaka uses).
    mdk_str_to_float: () => { const s = takePath(); return Number(s); },
    // path/name byte-channel plumbing itself is pure and shared by str_to_float and the
    // (stubbed) IO ops below — real either way.
    mdk_path_reset: () => { pathBuf = []; },
    mdk_path_push: (b) => { pathBuf.push(b & 0xff); },
    // IO group: no real filesystem/env/argv/process in a Web Worker sandbox — friendly
    // capability errors instead of a cryptic LinkError/trap. Each must still be a
    // callable so instantiation SUCCEEDS; the friendly error fires at call-time.
    mdk_read_file: capabilityStub('readFile'),
    mdk_file_exists: capabilityStub('fileExists'),
    mdk_get_env: capabilityStub('getEnv'),
    mdk_args_count: capabilityStub('args'),
    mdk_arg_len: capabilityStub('args'),
    mdk_arg_byte: capabilityStub('args'),
    mdk_result_len: capabilityStub('readFile/getEnv result'),
    mdk_result_byte: capabilityStub('readFile/getEnv result'),
    mdk_exit: capabilityStub('exit'),
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
      // B5: a Medaka runtime trap (div-zero / non-exhaustive / OOB / panic) streams a
      // coded `runtime error [E-CODE]: <message>` line to stderr BEFORE the `unreachable`.
      // Surface that captured text — not a generic "program panicked" — so the user sees
      // WHICH error and its code. Fall back to the generic message only for a genuine
      // instantiate failure (no coded stderr was produced).
      const coded = new TextDecoder('utf-8', { fatal: false })
        .decode(new Uint8Array(stderrAll)).trim();
      const engineMsg = err.message || String(err);
      const isPanic = /unreachable|trap|RuntimeError/i.test(engineMsg);
      self.postMessage({
        type: 'error',
        message: coded ? coded
          : err instanceof CapabilityError ? engineMsg
          : (isPanic ? 'program panicked' : 'instantiate failed: ' + engineMsg),
      });
    });
};
