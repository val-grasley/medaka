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
//               → inline CM6 squiggles (setDiagnostics) + console problem lines.
//   Run click : compiler-worker.js compiles source → { ok:false, diagnostics }
//               | { ok:true, wasm, diagnostics? } — diagnostics present only when
//                 the clean compile still had WARNINGS (e.g. W-NONEXHAUSTIVE); shown
//                 as squiggles + console problem lines, then the program still runs
//                 via worker.js (stdout/stderr/done).
//
// Layout (2026-07 redesign): a single centered "quiet column" — slim header,
// dismissible funnel strip, toolbar (examples / share / run), editor, and one
// unified console pane (stdout + stderr + problems all render there; inline
// squiggles/gutter markers stay in the editor via editor.js).

import { createEditor, getValue, setValue, setDiagnostics as setSquiggles } from './editor.js';
import { hover as compileHover, complete as compileComplete } from './compile.mjs';

const RUN_TIMEOUT_MS = 10000; // 10 s wall-clock budget per run
const ANALYZE_DEBOUNCE_MS = 300;
const FUNNEL_DISMISS_KEY = 'medaka-playground-funnel-dismissed';

// ── Embedded examples ─────────────────────────────────────────────────────────
const EXAMPLES = {
  hello: `-- Medaka playground — edit me and hit Run!

main =
  println (sum [1, 2, 3, 4, 5])
  println (map (x => x * 2) [1, 2, 3, 4, 5])
  println "hello from Medaka!"
`,
  shapes: `-- A tiny shape calculator
data Shape
  = Circle Float
  | Rect Float Float

area : Shape -> Float
area (Circle r) = 3.14159 * r * r
area (Rect w h) = w * h

main =
  let shapes = [Circle 1.0, Rect 3.0 4.0]
  println "areas: \\{map area shapes}"
`,
  pipeline: `-- Recursion + a map/filter/fold pipeline
fib : Int -> Int
fib 0 = 0
fib 1 = 1
fib n = fib (n - 1) + fib (n - 2)

main =
  let fibs = map fib [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
  let evens = filter (x => x % 2 == 0) fibs
  let total = fold (acc x => acc + x) 0 fibs
  println "fibs: \\{fibs}"
  println "even fibs: \\{evens}"
  println "sum: \\{total}"
`,
};

const DEFAULT_PROGRAM = EXAMPLES.shapes;

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
const editorEl      = document.getElementById('editor');
const runBtn        = document.getElementById('run-btn');
const shareBtn       = document.getElementById('share-btn');
const exampleSelect  = document.getElementById('example-select');
const consolePane    = document.getElementById('console');
const gcBanner       = document.getElementById('gc-banner');
const statusLine     = document.getElementById('status');
const funnelStrip    = document.getElementById('funnel-strip');
const funnelDismiss  = document.getElementById('funnel-dismiss');

// ── Funnel strip dismissal (persists via localStorage) ────────────────────────
try {
  if (localStorage.getItem(FUNNEL_DISMISS_KEY) === '1') {
    funnelStrip.classList.add('hidden');
  }
} catch { /* localStorage unavailable — leave the strip showing */ }

funnelDismiss.addEventListener('click', () => {
  funnelStrip.classList.add('hidden');
  try { localStorage.setItem(FUNNEL_DISMISS_KEY, '1'); } catch { /* best-effort */ }
});

// ── Permalink (Share) — encode the program into the URL hash ─────────────────
function encodeProgram(src) {
  const bytes = new TextEncoder().encode(src);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function decodeProgram(b64url) {
  const b64 = b64url.replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64.length % 4 === 0 ? '' : '='.repeat(4 - (b64.length % 4));
  const bin = atob(b64 + pad);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder('utf-8').decode(bytes);
}

function programFromHash() {
  const h = window.location.hash;
  const m = h.match(/^#code=(.+)$/);
  if (!m) return null;
  try { return decodeProgram(m[1]); } catch { return null; }
}

const initialProgram = programFromHash() || DEFAULT_PROGRAM;

// ── Language-service (hover + completion) — runs on the MAIN THREAD ───────────
// Unlike analyze (in the language worker), hover/completion run here: a full
// single-file typecheck recurses thousands of frames deep in the compiler's lexer
// and overflows a Web Worker's small stack; the main thread's larger stack fits
// it (compile.mjs also retries a first-call Liftoff overflow against the tiered-up
// module).  They're on-demand + infrequent, so the brief main-thread cost is fine.
// A single stable Uint8Array over the cached wasm bytes lets compile.mjs cache the
// compiled Module (so the retry runs against tiered-up, small-frame code).
let mainThreadWasm = null;

async function langAssets() {
  const a = await loadAssets();
  if (!mainThreadWasm) mainThreadWasm = new Uint8Array(a.wasm);
  return { wasm: mainThreadWasm, stdlib: { runtime: a.runtime, core: a.core, extra: a.extra } };
}

// Warm the main-thread compiler module once (a throwaway hover) so V8 tiers it up
// (TurboFan, small frames) before the user's first real hover/completion — which
// otherwise pays the slow first-call Liftoff-overflow-then-retry cost inline.
let langWarmed = false;
async function warmLangService() {
  if (langWarmed) return;
  langWarmed = true;
  try {
    const { wasm, stdlib } = await langAssets();
    await compileHover('main = 0\n', 0, 7, { wasm, stdlib });
  } catch { /* warmup is best-effort */ }
}

// Passed to the CM6 editor; each returns a Promise the hover/complete providers await.
const langService = {
  hover: async (source, line, col) => {
    try { const { wasm, stdlib } = await langAssets(); return await compileHover(source, line, col, { wasm, stdlib }); }
    catch { return null; }
  },
  complete: async (source, line, col) => {
    try { const { wasm, stdlib } = await langAssets(); return await compileComplete(source, line, col, { wasm, stdlib }); }
    catch { return null; }
  },
};

// ── Editor ────────────────────────────────────────────────────────────────────
const view = createEditor(editorEl, initialProgram, onEditorChange, langService);
// Expose the view + language service for browser debugging / automated e2e tests
// (harmless).  __mdkLang lets the e2e assert hover/completion data deterministically,
// independent of CM6's timing-finicky synthetic-mouse hover trigger.
window.__mdkView = view;
window.__mdkLang = langService;

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

// Latest diagnostics (kept so the console can re-render problems alongside
// fresh run output without losing them).
let lastDiagnosticFiles = [];

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function clearConsole() {
  consolePane.innerHTML = '';
}

function appendConsole(cls, text) {
  const span = document.createElement('span');
  span.className = cls;
  span.textContent = text;
  consolePane.appendChild(span);
  consolePane.scrollTop = consolePane.scrollHeight;
}

function setStatus(msg, cls) {
  statusLine.textContent = msg;
  statusLine.className = 'b-status ' + (cls || '');
}

function killRunner(reason) {
  if (activeRunner) { activeRunner.terminate(); activeRunner = null; }
  if (killTimer)    { clearTimeout(killTimer); killTimer = null; }
  if (reason) appendConsole('con-stderr', '\n[' + reason + ']\n');
  runBtn.disabled = false;
  setStatus('killed', 'error');
}

// ── Diagnostics renderer (console problem lines) ──────────────────────────────
function renderProblems() {
  const files = lastDiagnosticFiles || [];
  let count = 0;
  for (const f of files) {
    for (const d of f.diagnostics) {
      count++;
      const s = d.range && d.range.start;
      const loc = s ? (s.line + 1) + ':' + (s.character + 1) : '?';
      const sev = d.severity === 2 ? 'warning' : 'error';
      appendConsole('con-problem', '[' + sev + '] ' + loc + '  ' + d.message);
    }
  }
  return count;
}

// Apply a diagnostics object to BOTH the console problems list and inline
// editor squiggles.  Does NOT touch stdout/stderr already in the console —
// callers clear the console first if they want a clean slate.
function applyDiagnostics(files) {
  lastDiagnosticFiles = files || [];
  setSquiggles(view, files || []);
}

// Pure / wasm-safe stdlib modules bundled into the vfs so `import <mod>` works
// in the browser.  EXCLUDED (native-only externs that trap/LinkError on wasm):
// math, fs, net, time, io, test.  Keep in sync with EXTRA_MODULES in
// build_playground_wasm.sh (these are fetched from dist/<id>.mdk).
const EXTRA_MODULES = [
  'array', 'async', 'base64', 'bytebuilder', 'byteparser', 'hash_map',
  'hash_set', 'hex', 'json', 'list', 'map', 'mut_array', 'nonempty',
  'option', 'path', 'result', 'set', 'string', 'toml', 'validation',
];

// ── Asset loader ──────────────────────────────────────────────────────────────
async function loadAssets() {
  if (cachedAssets) return cachedAssets;
  if (assetsLoading) return assetsLoading;

  assetsLoading = (async () => {
    const coreResps = await Promise.all([
      fetch('dist/playground.wasm'),
      fetch('dist/runtime.mdk'),
      fetch('dist/core.mdk'),
      fetch('vendor/wat2wasm/wat2wasm_bg.wasm'),
    ]);
    const [wasmResp, runtimeResp, coreResp, wat2wasmResp] = coreResps;
    const extraResps = await Promise.all(
      EXTRA_MODULES.map((m) => fetch('dist/' + m + '.mdk')));
    for (const [name, r] of [
      ['dist/playground.wasm', wasmResp],
      ['dist/runtime.mdk',     runtimeResp],
      ['dist/core.mdk',        coreResp],
      ['vendor/wat2wasm/wat2wasm_bg.wasm', wat2wasmResp],
      ...EXTRA_MODULES.map((m, i) => ['dist/' + m + '.mdk', extraResps[i]]),
    ]) {
      if (!r.ok) throw new Error('failed to fetch ' + name + ' (' + r.status + ')');
    }
    const [wasm, runtime, core, wat2wasmBytes] = await Promise.all([
      wasmResp.arrayBuffer(),
      runtimeResp.text(),
      coreResp.text(),
      wat2wasmResp.arrayBuffer(),
    ]);
    const extraTexts = await Promise.all(extraResps.map((r) => r.text()));
    const extra = {};
    EXTRA_MODULES.forEach((m, i) => { extra[m] = extraTexts[i]; });
    cachedAssets = { wasm, runtime, core, wat2wasmBytes, extra };
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
    assets: { wasm: assets.wasm, runtime: assets.runtime, core: assets.core, extra: assets.extra },
  });
  // Kick an initial analyze once the worker signals ready.
  scheduleAnalyze();
  // Warm the main-thread hover/completion module in the background.
  warmLangService();
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
async function runProgram() {
  if (runBtn.disabled) return;
  if (activeRunner) killRunner('superseded');

  clearConsole();
  runBtn.disabled = true;
  setStatus('loading compiler…');

  const startedAt = performance.now();

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
      const n = renderProblems();
      if (n === 0) appendConsole('con-problem', 'compile failed (no diagnostics)');
    } else {
      appendConsole('con-problem', 'compile failed (no diagnostics)');
    }
    setStatus('compile error', 'error');
    runBtn.disabled = false;
    return;
  }

  // Clean compile — but there may still be WARNINGS (e.g. W-NONEXHAUSTIVE): they
  // don't block emit (matching native `medaka check`), so show them as squiggles
  // + console problem lines, then still run the program.
  const warnFiles = (result.diagnostics && result.diagnostics.files) || [];
  applyDiagnostics(warnFiles);
  renderProblems();
  setStatus('running…');

  const runner = new Worker('worker.js');
  activeRunner = runner;

  killTimer = setTimeout(() => killRunner('killed: time limit'), RUN_TIMEOUT_MS);

  runner.onmessage = (e) => {
    const { type, text, message } = e.data;
    if (type === 'stdout') appendConsole('con-stdout', text);
    else if (type === 'stderr') appendConsole('con-stderr', text);
    else if (type === 'error') {
      appendConsole('con-stderr', '\n[' + message + ']\n');
      clearTimeout(killTimer); killTimer = null;
      activeRunner = null;
      runBtn.disabled = false;
      setStatus('runtime error', 'error');
    } else if (type === 'done') {
      clearTimeout(killTimer); killTimer = null;
      activeRunner = null;
      runBtn.disabled = false;
      const ms = Math.round(performance.now() - startedAt);
      setStatus('✓ no problems · ran in ' + ms + ' ms', 'ok');
      appendConsole('con-meta', '✓ compiled & ran in ' + ms + ' ms · WasmGC, fully in your browser');
    }
  };

  runner.onerror = (e) => {
    appendConsole('con-stderr', '\n[runner error: ' + e.message + ']\n');
    clearTimeout(killTimer); killTimer = null;
    activeRunner = null;
    runBtn.disabled = false;
    setStatus('runner error', 'error');
  };

  runner.postMessage({ wasm: result.wasm }, [result.wasm]);
}

runBtn.addEventListener('click', runProgram);

// Cmd/Ctrl+Enter runs the program from anywhere on the page (including while
// focused in the CM6 editor — editor.js's keymap does not intercept it, so it
// bubbles here).
window.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
    e.preventDefault();
    runProgram();
  }
});

// ── Examples picker ───────────────────────────────────────────────────────────
exampleSelect.addEventListener('change', () => {
  const src = EXAMPLES[exampleSelect.value];
  if (!src) return;
  const label = document.getElementById('example-label');
  if (label) label.textContent = exampleSelect.value;
  setValue(view, src);
  clearConsole();
  setStatus('');
  scheduleAnalyze();
});

// ── Share (permalink) ─────────────────────────────────────────────────────────
shareBtn.addEventListener('click', async () => {
  const src = getValue(view);
  const hash = '#code=' + encodeProgram(src);
  const url = window.location.origin + window.location.pathname + hash;
  window.history.replaceState(null, '', hash);
  try {
    await navigator.clipboard.writeText(url);
    const prevText = shareBtn.textContent;
    shareBtn.textContent = 'copied!';
    setTimeout(() => { shareBtn.textContent = prevText; }, 1500);
  } catch {
    // Clipboard API unavailable (e.g. insecure context) — the URL is still in
    // the address bar via replaceState above.
    const prevText = shareBtn.textContent;
    shareBtn.textContent = 'copy failed';
    setTimeout(() => { shareBtn.textContent = prevText; }, 1500);
  }
});

// ── Boot the live language service (only if the engine can run) ───────────────
if (gcOk) initLanguageService();
