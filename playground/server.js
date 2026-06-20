#!/usr/bin/env node
// server.js — local dev stub for the Medaka playground.
// Zero npm deps: Node stdlib only (http, fs, path, child_process, os).
//
// Serves static playground/ files.
// POST /compile {source} →
//   1. medaka check --json → if errors, respond { errors: [files array] }
//   2. medaka build --target wasm → respond wasm bytes (application/wasm)
//      or { errors: [{ file: '<build>', diagnostics: [{message, ...}] }] } on failure.
//
// Env:
//   PORT                 — listen port (default 8080)
//   MEDAKA_ROOT          — repo root (default: parent of this file's directory)
//   MEDAKA_EMITTER       — path to native emitter binary (default: $REPO/medaka_emitter)
//   MEDAKA_WASM_EMITTER  — path to wasm emitter binary  (default: $REPO/test/bin/wasm_emit_modules_main)
//
// Stage 2 dev stub: single-request-at-a-time, no sandboxing, no resource limits.
// See PLAYGROUND-DESIGN.md §6 Stage 3/4 for the hardened server + sandboxing.

'use strict';

const http = require('http');
const fs   = require('fs');
const path = require('path');
const os   = require('os');
const { execFileSync } = require('child_process');

// ── Configuration ─────────────────────────────────────────────────────────────
const PORT       = parseInt(process.env.PORT || '8080', 10);
const REPO_ROOT  = process.env.MEDAKA_ROOT
  || path.resolve(__dirname, '..');  // playground/ sits inside repo root

const MEDAKA     = path.join(REPO_ROOT, 'medaka');
const EMITTER    = process.env.MEDAKA_EMITTER
  || path.join(REPO_ROOT, 'medaka_emitter');
const WASM_EMI   = process.env.MEDAKA_WASM_EMITTER
  || path.join(REPO_ROOT, 'test', 'bin', 'wasm_emit_modules_main');
const PLAYGROUND = __dirname;

// ── Prerequisite probes ───────────────────────────────────────────────────────
function probe(bin, label) {
  if (!fs.existsSync(bin)) {
    console.error('MISSING: ' + label + ' not found at ' + bin);
    return false;
  }
  try { fs.accessSync(bin, fs.constants.X_OK); } catch {
    console.error('NOT EXECUTABLE: ' + bin);
    return false;
  }
  return true;
}

function probeCommand(cmd) {
  try {
    execFileSync(cmd, ['--version'], { stdio: 'pipe', timeout: 5000 });
    return true;
  } catch { return false; }
}

let prereqsOk = true;
if (!probe(MEDAKA,   'medaka binary'))         prereqsOk = false;
if (!probe(EMITTER,  'medaka_emitter'))        prereqsOk = false;
if (!probe(WASM_EMI, 'wasm_emit_modules_main')) prereqsOk = false;
if (!probeCommand('wasm-tools')) {
  console.error('MISSING: wasm-tools not found on PATH');
  prereqsOk = false;
}

if (!prereqsOk) {
  console.error('');
  console.error('Setup:');
  console.error('  make medaka                          # builds medaka + medaka_emitter');
  console.error('  sh test/wasm/build_wasm_oracle.sh   # builds test/bin/wasm_emit_modules_main');
  console.error('  (ensure wasm-tools is on PATH)');
  process.exit(1);
}

// ── Compile env ───────────────────────────────────────────────────────────────
const compileEnv = Object.assign({}, process.env, {
  MEDAKA_EMITTER:      EMITTER,
  MEDAKA_WASM_EMITTER: WASM_EMI,
});

// ── MIME map ──────────────────────────────────────────────────────────────────
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.ico':  'image/x-icon',
};

// ── Helpers ───────────────────────────────────────────────────────────────────
function jsonResponse(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'Access-Control-Allow-Origin': '*',
  });
  res.end(body);
}

function errorDiag(message, file) {
  return [{
    file: file || '<build>',
    diagnostics: [{
      message,
      range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } },
      severity: 1,
      source: 'medaka',
    }],
  }];
}

// Run medaka check --json; return { ok: bool, files: [...] }
function runCheck(srcPath) {
  try {
    execFileSync(MEDAKA, ['check', '--json', srcPath], {
      env: compileEnv,
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 30000,
    });
    // exit 0 = clean
    return { ok: true, files: [] };
  } catch (e) {
    // exit non-zero; JSON on stderr (or stdout depending on version)
    const raw = (e.stderr ? e.stderr.toString() : '') || (e.stdout ? e.stdout.toString() : '');
    try {
      const parsed = JSON.parse(raw.trim());
      // Shape: { files: [{file, diagnostics:[...]}] }
      const files = parsed.files || [];
      const hasErrors = files.some(f => f.diagnostics && f.diagnostics.length > 0);
      if (hasErrors) return { ok: false, files };
      // If JSON parsed but no diagnostics — treat as check failure with raw message
      return { ok: false, files: errorDiag(raw || 'check failed', srcPath) };
    } catch {
      return { ok: false, files: errorDiag(raw || 'check failed', srcPath) };
    }
  }
}

// Run medaka build --target wasm; return { ok: bool, wasmPath?, error? }
function runBuild(srcPath, outPath) {
  try {
    execFileSync(MEDAKA, ['build', '--target', 'wasm', srcPath, '-o', outPath], {
      env: compileEnv,
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 60000,
    });
    return { ok: true, wasmPath: outPath };
  } catch (e) {
    const stderr = e.stderr ? e.stderr.toString() : '';
    const stdout = e.stdout ? e.stdout.toString() : '';
    const msg = (stderr || stdout || 'build failed').trim();
    return { ok: false, error: msg };
  }
}

// ── POST /compile handler ─────────────────────────────────────────────────────
function handleCompile(req, res) {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    let source;
    try {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      source = body.source;
      if (typeof source !== 'string') throw new Error('source must be a string');
    } catch (e) {
      return jsonResponse(res, 400, { errors: errorDiag('bad request: ' + e.message) });
    }

    // Per-request temp dir — isolated scratch space.
    const tmpDir  = fs.mkdtempSync(path.join(os.tmpdir(), 'medaka-playground-'));
    const srcPath = path.join(tmpDir, 'main.mdk');
    const outPath = path.join(tmpDir, 'main.wasm');

    function cleanup() {
      try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
    }

    try {
      fs.writeFileSync(srcPath, source, 'utf8');

      // Stage 1: typecheck
      const check = runCheck(srcPath);
      if (!check.ok) {
        cleanup();
        return jsonResponse(res, 200, { errors: check.files });
      }

      // Stage 2: compile to wasm
      const build = runBuild(srcPath, outPath);
      if (!build.ok) {
        cleanup();
        return jsonResponse(res, 200, { errors: errorDiag(build.error, srcPath) });
      }

      // Read wasm bytes and respond
      const wasmBytes = fs.readFileSync(outPath);
      cleanup();

      res.writeHead(200, {
        'Content-Type': 'application/wasm',
        'Content-Length': wasmBytes.length,
        'Access-Control-Allow-Origin': '*',
      });
      res.end(wasmBytes);
    } catch (e) {
      cleanup();
      console.error('compile handler error:', e);
      return jsonResponse(res, 500, { errors: errorDiag('internal error: ' + e.message) });
    }
  });
  req.on('error', (e) => {
    console.error('request error:', e);
    jsonResponse(res, 500, { errors: errorDiag('request error') });
  });
}

// ── Static file handler ───────────────────────────────────────────────────────
function handleStatic(req, res) {
  // Only serve files inside playground/
  const urlPath = req.url === '/' ? '/index.html' : req.url;
  // Strip query string
  const cleanPath = urlPath.split('?')[0];
  // Resolve canonically: join first, then resolve to collapse any '..' segments.
  const filePath = path.resolve(path.join(PLAYGROUND, cleanPath));

  // Security: prevent path traversal outside playground/
  if (!filePath.startsWith(PLAYGROUND + path.sep) && filePath !== PLAYGROUND) {
    res.writeHead(403, { 'Content-Type': 'text/plain' }); res.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not found: ' + cleanPath);
      return;
    }
    const ext = path.extname(filePath);
    res.writeHead(200, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Content-Length': data.length,
    });
    res.end(data);
  });
}

// ── HTTP server ───────────────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    res.end();
    return;
  }

  if (req.method === 'POST' && req.url === '/compile') {
    handleCompile(req, res);
  } else if (req.method === 'GET') {
    handleStatic(req, res);
  } else {
    res.writeHead(405); res.end('Method Not Allowed');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('Medaka playground stub running at http://localhost:' + PORT);
  console.log('  MEDAKA:       ' + MEDAKA);
  console.log('  EMITTER:      ' + EMITTER);
  console.log('  WASM_EMITTER: ' + WASM_EMI);
  console.log('  Serving:      ' + PLAYGROUND);
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.error('Port ' + PORT + ' in use — set PORT=<other> to use a different port.');
  } else {
    console.error('Server error:', e);
  }
  process.exit(1);
});
