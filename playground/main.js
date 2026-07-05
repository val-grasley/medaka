// main.js — playground page glue (Stage 3 client-side compile + Stage S1/S2 editor).
//
// This is now an ES MODULE (index.html loads it with type="module") so it can
// import the CodeMirror-6 editor seam (editor.js → vendored `codemirror`).
//
// Data flow (server-free after first page load):
//   page load : create the CM6 editor; fetch once (cached) dist/playground.wasm,
//               dist/runtime.mdk, dist/core.mdk, vendor/wat2wasm/wat2wasm_bg.wasm;
//               init the language worker and run an initial analyze.
//   edit      : debounced analyze in language-worker.js → __MEDAKA_DIAGNOSTICS__
//               → inline CM6 squiggles (setDiagnostics) + problems-pane list.
//   Run click : compiler-worker.js compiles source → { ok:false, diagnostics }
//               | { ok:true, wasm } → worker.js runner posts stdout/stderr/done.

import { createEditor, getValue, setDiagnostics as setSquiggles } from './editor.js';

const RUN_TIMEOUT_MS = 10000; // 10 s wall-clock budget per run
const ANALYZE_DEBOUNCE_MS = 300;

const DEFAULT_PROGRAM = `-- Medaka playground — edit me and hit Run!

main =
  println (sum [1, 2, 3, 4, 5])
  println (map (x => x * 2) [1, 2, 3, 4, 5])
  println "hello from Medaka!"
`;

// ── WasmGC feature detection ──────────────────────────────────────────────────
const GC_PROBE = new Uint8Array([
  0x00,0x61,0x73,0x6d, 0x01,0x00,0x00,0x00,
  0x01,0x09,0x02,0x5e,0x7f,0x01,0x60,0x00,0x01,0x64,0x00,
  0x03,0x02,0x01,0x01,
  0x07,0x05,0x01,0x01,0x66,0x00,0x00,
  0x0a,0x09,0x01,0x07,0x00,0x41,0x00,0xfb,0x07,0x00,0x0b,
]);
function hasWasmGC() {
  try { return WebAssembly.validate(GC_PROBE); } catch { return false; }
}

// ── DOM refs ──────────────────────────────────────────────────────────────────
const editorEl    = document.getElementById('editor');
const runBtn       = document.getElementById('run-btn');
const stdoutPane   = document.getElementById('stdout');
const stderrPane   = document.getElementById('stderr');
const problemPane  = document.getElementById('problems');
const gcBanner     = document.getElementById('gc-banner');
const statusLine   = document.getElementById('status');

// ── Editor ────────────────────────────────────────────────────────────────────
const view = createEditor(editorEl, DEFAULT_PROGRAM, onEditorChange);
// Expose the view for browser debugging / automated end-to-end tests (harmless).
window.__mdkView = view;

// ── Engine gate ───────────────────────────────────────────────────────────────
const gcOk = hasWasmGC();
if (!gcOk) {
  gcBanner.style.display = 'block';
  runBtn.disabled = true;
}

// ── State ─────────────────────────────────────────────────────────────────────
let activeRunner   = null;  // current worker.js runner worker
let compileWorker  = null;  // persistent compiler-worker.js (reused across runs)
let killTimer      = null;
let cachedAssets   = null;  // { wasm, runtime, core, wat2wasmBytes }
let assetsLoading  = null;  // pending Promise<assets>

// Language service (live diagnostics)
let langWorker     = null;  // language-worker.js
let langReady      = false;
let analyzeSeq      = 0;    // monotonically increasing request id
let analyzeInFlight = false;
let pendingSource   = null; // latest un-analyzed source when a request is in flight
let debounceTimer   = null;

function clearOutput() {
  stdoutPane.textContent = '';
  stderrPane.textContent = '';
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

// ── Diagnostics renderer (problems pane list) ─────────────────────────────────
function renderDiagnostics(files) {
  const lines = [];
  for (const f of files) {
    for (const d of f.diagnostics) {
      const s = d.range && d.range.start;
      const loc = s ? (s.line + 1) + ':' + (s.character + 1) : '?';
      const sev = d.severity === 2 ? 'warning' : 'error';
      lines.push('[' + sev + '] ' + loc + '  ' + d.message);
    }
  }
  problemPane.textContent = lines.join('\n') || '(no diagnostics)';
}

// Apply a diagnostics object to BOTH the problems pane and inline squiggles.
function applyDiagnostics(files) {
  renderDiagnostics(files || []);
  setSquiggles(view, files || []);
}

// ── Asset loader ──────────────────────────────────────────────────────────────
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

// ── Language worker (live diagnostics) ────────────────────────────────────────
function getLanguageWorker() {
  if (!langWorker) {
    langWorker = new Worker('language-worker.js', { type: 'module' });
    langWorker.onmessage = (e) => {
      const m = e.data;
      if (m.type === 'ready') { langReady = true; return; }
      if (m.type === 'diagnostics') {
        // Ignore stale responses (only the newest analyzeSeq matters).
        if (m.id === analyzeSeq) applyDiagnostics(m.files);
        onAnalyzeDone();
      } else if (m.type === 'error') {
        onAnalyzeDone();
      }
    };
    langWorker.onerror = () => { langReady = false; langWorker = null; };
  }
  return langWorker;
}

// Initialize the language worker with the compiler assets (structured-clone the
// wasm bytes so cachedAssets stays intact for the run compiler-worker).
async function initLanguageService() {
  let assets;
  try { assets = await loadAssets(); }
  catch { return; }  // Run button surfaces asset errors; live diag stays quiet.
  const w = getLanguageWorker();
  w.postMessage({
    type: 'init',
    assets: { wasm: assets.wasm, runtime: assets.runtime, core: assets.core },
  });
  // Kick an initial analyze once the worker signals ready.
  scheduleAnalyze();
}

function onEditorChange() {
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(scheduleAnalyze, ANALYZE_DEBOUNCE_MS);
}

// Coalescing dispatcher: at most one analyze in flight; the latest source is
// queued and sent when the previous completes (natural cancellation).
function scheduleAnalyze() {
  if (!langReady) {
    // Worker not up yet — retry shortly (init posts 'ready').
    setTimeout(scheduleAnalyze, 120);
    return;
  }
  const source = getValue(view);
  if (analyzeInFlight) { pendingSource = source; return; }
  analyzeInFlight = true;
  analyzeSeq += 1;
  getLanguageWorker().postMessage({ type: 'analyze', id: analyzeSeq, source });
}

function onAnalyzeDone() {
  analyzeInFlight = false;
  if (pendingSource != null) {
    pendingSource = null;
    scheduleAnalyze();
  }
}

// ── Compiler worker (Run) ─────────────────────────────────────────────────────
function getCompilerWorker() {
  if (!compileWorker) {
    compileWorker = new Worker('compiler-worker.js', { type: 'module' });
    compileWorker.onerror = (e) => {
      if (compileWorker._reject) {
        compileWorker._reject(new Error('compiler-worker error: ' + e.message));
      }
      compileWorker = null;
    };
  }
  return compileWorker;
}

function requestCompile(source, assets) {
  return new Promise((resolve, reject) => {
    const worker = getCompilerWorker();
    worker._resolve = resolve;
    worker._reject  = reject;
    worker.onmessage = (e) => { worker._resolve = null; worker._reject = null; resolve(e.data); };
    worker.postMessage({ source, assets });
  });
}

// ── Run ───────────────────────────────────────────────────────────────────────
runBtn.addEventListener('click', async () => {
  if (activeRunner) killRunner('superseded');

  clearOutput();
  runBtn.disabled = true;
  setStatus('loading compiler…');

  let assets;
  try {
    assets = await loadAssets();
  } catch (e) {
    setStatus('asset load failed: ' + e.message, 'error');
    runBtn.disabled = false;
    return;
  }

  setStatus('compiling…');

  const source = getValue(view);

  let result;
  try {
    result = await requestCompile(source, assets);
  } catch (e) {
    setStatus('compiler error: ' + e.message, 'error');
    runBtn.disabled = false;
    return;
  }

  if (!result.ok) {
    if (result.diagnostics && result.diagnostics.files) {
      applyDiagnostics(result.diagnostics.files);
    } else {
      problemPane.textContent = 'compile failed (no diagnostics)';
    }
    setStatus('compile error', 'error');
    runBtn.disabled = false;
    return;
  }

  // Clean compile → clear any stale squiggles/problems.
  applyDiagnostics([]);
  setStatus('running…');

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

  runner.postMessage({ wasm: result.wasm }, [result.wasm]);
});

// ── Boot the live language service (only if the engine can run) ───────────────
if (gcOk) initLanguageService();
