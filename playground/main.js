// main.js — playground page glue.
// Wires: Run button → POST /compile → Worker → console pane.
// Also: WasmGC feature-detect, diagnostics pane, timeout/kill.

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
let activeWorker = null;
let killTimer    = null;

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

function killWorker(reason) {
  if (activeWorker) { activeWorker.terminate(); activeWorker = null; }
  if (killTimer)    { clearTimeout(killTimer); killTimer = null; }
  if (reason) appendTo(stderrPane, '\n[' + reason + ']\n');
  runBtn.disabled = false;
  setStatus('killed', 'error');
}

// ── Diagnostics renderer ──────────────────────────────────────────────────────
function renderDiagnostics(files) {
  // files = [{file, diagnostics: [{message, range:{start:{line,character}}, severity}]}]
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

// ── Run ───────────────────────────────────────────────────────────────────────
runBtn.addEventListener('click', async () => {
  // Kill any prior run.
  if (activeWorker) killWorker('superseded');

  clearOutput();
  runBtn.disabled = true;
  setStatus('compiling…');

  const source = editor.value;

  let resp;
  try {
    resp = await fetch('/compile', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ source }),
    });
  } catch (e) {
    setStatus('network error: ' + e.message, 'error');
    runBtn.disabled = false;
    return;
  }

  // Error response: JSON with { errors: [...] }
  if (!resp.ok || resp.headers.get('content-type') === 'application/json') {
    let body;
    try { body = await resp.json(); } catch { body = {}; }
    if (body.errors) {
      renderDiagnostics(body.errors);
      setStatus('compile error', 'error');
    } else {
      problemPane.textContent = 'server error: ' + resp.status;
      setStatus('error', 'error');
    }
    runBtn.disabled = false;
    return;
  }

  // Success: wasm bytes
  let wasmBuf;
  try {
    wasmBuf = await resp.arrayBuffer();
  } catch (e) {
    setStatus('failed to read wasm: ' + e.message, 'error');
    runBtn.disabled = false;
    return;
  }

  setStatus('running…');

  // Fresh worker per run — lets us terminate it cleanly.
  const worker = new Worker('worker.js');
  activeWorker = worker;

  killTimer = setTimeout(() => killWorker('killed: time limit'), RUN_TIMEOUT_MS);

  worker.onmessage = (e) => {
    const { type, text, message } = e.data;
    if (type === 'stdout') appendTo(stdoutPane, text);
    else if (type === 'stderr') appendTo(stderrPane, text);
    else if (type === 'error') {
      appendTo(stderrPane, '\n[' + message + ']\n');
      clearTimeout(killTimer); killTimer = null;
      activeWorker = null;
      runBtn.disabled = false;
      setStatus('runtime error', 'error');
    } else if (type === 'done') {
      clearTimeout(killTimer); killTimer = null;
      activeWorker = null;
      runBtn.disabled = false;
      setStatus('done', 'ok');
    }
  };

  worker.onerror = (e) => {
    appendTo(stderrPane, '\n[worker error: ' + e.message + ']\n');
    clearTimeout(killTimer); killTimer = null;
    activeWorker = null;
    runBtn.disabled = false;
    setStatus('worker error', 'error');
  };

  worker.postMessage({ wasm: wasmBuf }, [wasmBuf]);
});
