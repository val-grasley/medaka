// worker.js — Web Worker that instantiates a WasmGC module and posts back stdout/stderr.
// Receives: { wasm: ArrayBuffer }
// Posts:    { type: 'stdout'|'stderr'|'done'|'error', text?: string, message?: string }
//
// Host-import ABI — copied verbatim from test/wasm/run.js (byte-exact vs native oracle).

// fmt12g: reproduce medaka_rt.c mdk_float_lexeme byte-for-byte (SHORTEST-ROUND-TRIP
// since issue #57). `toExponential()` (no arg) is JS's shortest half-even scientific
// form, matching C's `%.*e` shortest-precision loop exactly (incl. the 17-digit
// half-way tie). We take its digits + decimal exponent and re-derive the layout with
// the same fixed threshold as C (scientific iff exp<-4 || exp>=12). Kept byte-identical
// to test/wasm/run.js.
// --- BEGIN SHARED SHIM fmt12g --- (byte-identical in test/wasm/run.js and
// playground/worker.js — WASM-SEMANTICS WH3; enforced by test/diff_compiler_wasm_shim_parity.sh)
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
// --- END SHARED SHIM fmt12g ---

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
let strToFloatOk = 0;   // #370: latched by mdk_str_to_float, read by mdk_str_to_float_ok

// --- BEGIN SHARED SHIM mdkStrToFloat --- (byte-identical in test/wasm/run.js and
// playground/worker.js — WASM-SEMANTICS WH2/WH3; enforced by test/diff_compiler_wasm_shim_parity.sh)
// #370 stringToFloat host seam. The C runtime is the oracle (WH2): medaka_rt.c
// mdk_string_to_float is `strtod` + an endptr FULL-CONSUMPTION check + an empty-string
// reject. JS Number() is NOT strtod: Number("") === 0, Number("1.5 ") trims,
// Number("nan"/"inf") is NaN, and Number rejects C99 hex floats ("0x1p3" -> NaN).
// strtod skips LEADING whitespace only, accepts inf/infinity and nan/nan(chars)
// case-insensitively, and accepts hex floats. Because native requires full
// consumption, longest-match is unnecessary — the whole post-whitespace string must
// match the grammar, or the endptr check would reject it anyway.
// Returns { ok, value }; ok === 0 means None. Verified case-for-case against the
// native C oracle over a 621-case battery (test/llvm_fixtures/str_to_float_frontier.mdk).
function mdkStrToFloat(s) {
  if (s.length === 0) return { ok: 0, value: 0 };   // medaka_rt.c: bl == 0 -> None
  const b = s.replace(/^[ \t\n\v\f\r]+/, '');       // strtod skips leading isspace
  let m;
  if ((m = /^([+-]?)(?:inf|infinity)$/i.exec(b)))
    return { ok: 1, value: m[1] === '-' ? -Infinity : Infinity };
  if ((m = /^([+-]?)nan(?:\([0-9A-Za-z_]*\))?$/i.exec(b)))
    // strtod propagates the SIGN onto the NaN, and the sign bit is OBSERVABLE
    // through floatToBytes64 (native "-nan" -> byte0 0xff, not 0x7f). JS unary
    // minus is an IEEE negate, so it sets the bit; the f64 crosses the import
    // boundary uncanonicalised.
    return { ok: 1, value: m[1] === '-' ? -NaN : NaN };
  if ((m = /^([+-]?)0[xX](?:([0-9A-Fa-f]+)(?:\.([0-9A-Fa-f]*))?|\.([0-9A-Fa-f]+))(?:[pP]([+-]?[0-9]+))?$/.exec(b))) {
    const ip = m[2] !== undefined ? m[2] : '';
    const fp = m[2] !== undefined ? (m[3] || '') : m[4];
    const v = mdkHexFloat(ip, fp, m[5] ? parseInt(m[5], 10) : 0);
    return { ok: 1, value: m[1] === '-' ? -v : v };
  }
  if (/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.test(b))
    return { ok: 1, value: Number(b) };             // decimal: Number() is correctly rounded
  return { ok: 0, value: 0 };
}
// C99 hex float -> double, correctly rounded like strtod. The value is M * 2^e for an
// exact BigInt M, so rendering it as an EXACT decimal string (2^-k = 5^k / 10^k) and
// handing that to Number() gets round-to-nearest-even for free.
function mdkHexFloat(ip, fp, pexp) {
  const M = BigInt('0x' + (ip + fp || '0'));
  if (M === 0n) return 0;
  const e = pexp - 4 * fp.length, bits = M.toString(2).length;
  if (bits + e > 1100) return Infinity;             // clamp keeps the BigInt bounded
  if (bits + e < -1100) return 0;
  if (e >= 0) return Number((M << BigInt(e)).toString());
  const k = -e, num = (M * 5n ** BigInt(k)).toString().padStart(k + 1, '0');
  return Number(num.slice(0, num.length - k) + '.' + num.slice(num.length - k));
}
// --- END SHARED SHIM mdkStrToFloat ---

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
    // #101 libm math host seam (JS Math.*): the transcendentals + pow/atan2/hypot have
    // no WasmGC opcode, so the playground provides them here (real, pure).  The IEEE-exact
    // ops (sqrt/floor/ceil/trunc/round) + floatRem lower to wasm opcodes / WAT helpers and
    // never reach a host import.  Extra unused entries are harmless (imports are by name).
    mdk_cbrt: Math.cbrt, mdk_exp: Math.exp, mdk_log: Math.log,
    mdk_log2: Math.log2, mdk_log10: Math.log10,
    mdk_sin: Math.sin, mdk_cos: Math.cos, mdk_tan: Math.tan,
    mdk_asin: Math.asin, mdk_acos: Math.acos, mdk_atan: Math.atan,
    mdk_sinh: Math.sinh, mdk_cosh: Math.cosh, mdk_tanh: Math.tanh,
    mdk_pow: Math.pow, mdk_atan2: Math.atan2, mdk_hypot: Math.hypot,
    // layer-6 stringToFloat (#370): the guest calls mdk_path_reset+mdk_path_push to
    // populate pathBuf, then mdk_str_to_float (which parses AND latches the ok flag),
    // then mdk_str_to_float_ok. Two channels because Some(nan) is a LEGAL strtod
    // result, so NaN cannot double as the failure signal (that collapse was #370).
    mdk_str_to_float: () => { const r = mdkStrToFloat(takePath()); strToFloatOk = r.ok; return r.value; },
    mdk_str_to_float_ok: () => strToFloatOk,
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
