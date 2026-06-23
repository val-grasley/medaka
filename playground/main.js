// main.js — playground page glue (Stage 3: fully client-side, no server compile).
//
// Data flow (server-free after first page load):
//   page load : fetch once (cached) dist/playground.wasm, dist/runtime.mdk,
//               dist/core.mdk, vendor/wat2wasm/wat2wasm_bg.wasm
//   Run click : compiler-worker.js compiles source → { ok:false, diagnostics }
//               | { ok:true, wasm: ArrayBuffer }
//             : on success → worker.js runner receives the wasm bytes and posts
//               stdout/stderr/done/error back.
//
// The compiler-worker (type:'module') imports compile.mjs + wat2wasm.js — all the
// heavy work runs off the main thread.  The runner-worker (worker.js, classic) is
// unchanged; its 10 s kill-timer is preserved.

const RUN_TIMEOUT_MS = 10000; // 10 s wall-clock budget per run

// ── WasmGC feature detection ──────────────────────────────────────────────────
// Tiny GC module: (module (type $t (array (mut i32))) (func (result (ref $t))
//   (array.new_default $t (i32.const 0))) (export "f" (func 0)))
const GC_PROBE = new Uint8Array([
  0x00,0x61,0x73,0x6d, 0x01,0x00,0x00,0x00,
  0x01,0x09,0x02,0x5e,0x7f,0x01,0x60,0x00,0x01,0x64,0x00,
  0x03,0x02,0x01,0x01,
  0x07,0x05,0x01,0x01,0x66,0x00,0x00,
  0x0a,0x08,0x01,0x06,0x00,0x41,0x00,0xfb,0x07,0x00,0x0b,
]);

function hasWasmGC() {
  try { return WebAssembly.validate(GC_PROBE); } catch { return false; }
}

// ── DOM refs ──────────────────────────────────────────────────────────────────
const editor      = document.getElementById('editor');
const runBtn      = document.getElementById('run-btn');
const stdoutPane  = document.getElementById('stdout');
const stderrPane  = document.getElementById('stderr');
const problemPane = document.getElementById('problems');
const gcBanner    = document.getElementById('gc-banner');
const statusLine  = document.getElementById('status');

// ── Engine gate ───────────────────────────────────────────────────────────────
if (!hasWasmGC()) {
  gcBanner.style.display = 'block';
  runBtn.disabled = true;
}

// ── State ─────────────────────────────────────────────────────────────────────
let activeRunner   = null;  // current worker.js runner worker
let compileWorker  = null;  // persistent compiler-worker.js (reused across runs)
let killTimer      = null;
// Cached assets (fetched once, reused across all runs)
let cachedAssets   = null;  // { wasm: ArrayBuffer, runtime: string, core: string, wat2wasmBytes: ArrayBuffer }
let assetsLoading  = null;  // pending Promise<assets> (dedupe concurrent runs)

function clearOutput() {
  stdoutPane.textContent = '';
  stderrPane.textContent = '';
  problemPane.textContent = '';
  statusLine.textContent = '';
}

function appendTo(pane, text) {
  pane.textContent += text;
  pane.scrollTop = pane.scrollHeight;
}

function setStatus(msg, cls) {
  statusLine.textContent = msg;
  statusLine.className = 'status ' + (cls || '');
}

function killRunner(reason) {
  if (activeRunner) { activeRunner.terminate(); activeRunner = null; }
  if (killTimer)    { clearTimeout(killTimer); killTimer = null; }
  if (reason) appendTo(stderrPane, '\n[' + reason + ']\n');
  runBtn.disabled = false;
  setStatus('killed', 'error');
}

// ── Diagnostics renderer ──────────────────────────────────────────────────────
function renderDiagnostics(files) {
  // files = [{file, diagnostics:[{message,range:{start:{line,character}},severity}]}]
  const lines = [];
  for (const f of files) {
    for (const d of f.diagnostics) {
      const s = d.range && d.range.start;
      const loc = s ? (s.line + 1) + ':' + (s.character + 1) : '?';
      const sev = d.severity === 1 ? 'error' : 'warning';
      lines.push('[' + sev + '] ' + loc + '  ' + d.message);
    }
  }
  problemPane.textContent = lines.join('\n') || '(no diagnostics)';
}

// ── Asset loader ──────────────────────────────────────────────────────────────
// Fetches the four static assets once; subsequent calls reuse the cache.
// Throws on any network / non-ok response.
async function loadAssets() {
  if (cachedAssets) return cachedAssets;
  if (assetsLoading) return assetsLoading;

  assetsLoading = (async () => {
    const [wasmResp, runtimeResp, coreResp, wat2wasmResp] = await Promise.all([
      fetch('dist/playground.wasm'),
      fetch('dist/runtime.mdk'),
      fetch('dist/core.mdk'),
      fetch('vendor/wat2wasm/wat2wasm_bg.wasm'),
    ]);
    for (const [name, r] of [
      ['dist/playground.wasm', wasmResp],
      ['dist/runtime.mdk',     runtimeResp],
      ['dist/core.mdk',        coreResp],
      ['vendor/wat2wasm/wat2wasm_bg.wasm', wat2wasmResp],
    ]) {
      if (!r.ok) throw new Error('failed to fetch ' + name + ' (' + r.status + ')');
    }
    const [wasm, runtime, core, wat2wasmBytes] = await Promise.all([
      wasmResp.arrayBuffer(),
      runtimeResp.text(),
      coreResp.text(),
      wat2wasmResp.arrayBuffer(),
    ]);
    cachedAssets = { wasm, runtime, core, wat2wasmBytes };
    assetsLoading = null;
    return cachedAssets;
  })();

  return assetsLoading;
}

// ── Compiler worker ───────────────────────────────────────────────────────────
// Returns the persistent module-type compiler worker, creating it on first call.
function getCompilerWorker() {
  if (!compileWorker) {
    compileWorker = new Worker('compiler-worker.js', { type: 'module' });
    compileWorker.onerror = (e) => {
      // Surface worker-level errors (e.g. import failure) as a rejected promise
      // via the pending request's reject, if any.
      if (compileWorker._reject) {
        compileWorker._reject(new Error('compiler-worker error: ' + e.message));
      }
      // The worker may be broken; recreate on next run.
      compileWorker = null;
    };
  }
  return compileWorker;
}

// Send a compile request to the compiler worker and return a Promise<result>.
// The worker is reused between runs (playground.wasm stays instantiated).
// Assets are passed by ArrayBuffer reference (NOT transferred, so the cache stays valid).
function requestCompile(source, assets) {
  return new Promise((resolve, reject) => {
    const worker = getCompilerWorker();
    worker._resolve = resolve;
    worker._reject  = reject;
    worker.onmessage = (e) => { worker._resolve = null; worker._reject = null; resolve(e.data); };
    // Clone the ArrayBuffers (structured-clone, not transfer) so cachedAssets stays intact.
    worker.postMessage({ source, assets });
  });
}

// ── Run ───────────────────────────────────────────────────────────────────────
runBtn.addEventListener('click', async () => {
  // Kill any prior runner (compile-worker is persistent, leave it).
  if (activeRunner) killRunner('superseded');

  clearOutput();
  runBtn.disabled = true;
  setStatus('loading compiler…');

  // Fetch/cache assets (noop after first successful load).
  let assets;
  try {
    assets = await loadAssets();
  } catch (e) {
    setStatus('asset load failed: ' + e.message, 'error');
    runBtn.disabled = false;
    return;
  }

  setStatus('compiling…');

  const source = editor.value;

  let result;
  try {
    result = await requestCompile(source, assets);
  } catch (e) {
    setStatus('compiler error: ' + e.message, 'error');
    runBtn.disabled = false;
    return;
  }

  if (!result.ok) {
    // Diagnostics: type/parse error or internal assembler/compile error.
    if (result.diagnostics && result.diagnostics.files) {
      renderDiagnostics(result.diagnostics.files);
    } else {
      problemPane.textContent = 'compile failed (no diagnostics)';
    }
    setStatus('compile error', 'error');
    runBtn.disabled = false;
    return;
  }

  // result.ok = true: result.wasm is an ArrayBuffer of assembled user wasm.
  setStatus('running…');

  // Fresh runner per run — lets us terminate it cleanly within the 10 s budget.
  const runner = new Worker('worker.js');
  activeRunner = runner;

  killTimer = setTimeout(() => killRunner('killed: time limit'), RUN_TIMEOUT_MS);

  runner.onmessage = (e) => {
    const { type, text, message } = e.data;
    if (type === 'stdout') appendTo(stdoutPane, text);
    else if (type === 'stderr') appendTo(stderrPane, text);
    else if (type === 'error') {
      appendTo(stderrPane, '\n[' + message + ']\n');
      clearTimeout(killTimer); killTimer = null;
      activeRunner = null;
      runBtn.disabled = false;
      setStatus('runtime error', 'error');
    } else if (type === 'done') {
      clearTimeout(killTimer); killTimer = null;
      activeRunner = null;
      runBtn.disabled = false;
      setStatus('done', 'ok');
    }
  };

  runner.onerror = (e) => {
    appendTo(stderrPane, '\n[runner error: ' + e.message + ']\n');
    clearTimeout(killTimer); killTimer = null;
    activeRunner = null;
    runBtn.disabled = false;
    setStatus('runner error', 'error');
  };

  // Transfer the wasm ArrayBuffer to the runner (result.wasm came from the
  // compiler-worker already as a fresh ArrayBuffer via structured-clone on the
  // worker's postMessage, so it's transferable).
  runner.postMessage({ wasm: result.wasm }, [result.wasm]);
});
