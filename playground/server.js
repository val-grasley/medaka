#!/usr/bin/env node
// server.js — static dev server for the Medaka playground.
// Zero npm deps: Node stdlib only (http, fs, path).
//
// Serves the playground/ directory as static files.  No backend compilation —
// the Medaka compiler runs fully client-side as a WasmGC module (dist/playground.wasm).
// See playground/compiler-worker.js and playground/compile.mjs for the client-side flow.
//
// Before starting, build the dist assets (once, gitignored):
//   bash playground/build_playground_wasm.sh
//
// Env:
//   PORT  — listen port (default 8080)

'use strict';

const http = require('http');
const fs   = require('fs');
const path = require('path');

// ── Configuration ─────────────────────────────────────────────────────────��───
const PORT       = parseInt(process.env.PORT || '8080', 10);
const PLAYGROUND = __dirname;

// ── MIME map ──────────────────────────────────────────────────────────────────
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.mjs':  'text/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.mdk':  'text/plain; charset=utf-8',
  '.ico':  'image/x-icon',
};

// ── Static file handler ───────────────────────────────────────────────────────
function handleStatic(req, res) {
  const urlPath = req.url === '/' ? '/index.html' : req.url;
  // Strip query string.
  const cleanPath = urlPath.split('?')[0];
  // Resolve canonically: join first, then resolve to collapse any '..' segments.
  const filePath = path.resolve(path.join(PLAYGROUND, cleanPath));

  // Security: prevent path traversal outside playground/.
  if (!filePath.startsWith(PLAYGROUND + path.sep) && filePath !== PLAYGROUND) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('Forbidden');
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
  if (req.method === 'GET' || req.method === 'HEAD') {
    handleStatic(req, res);
  } else {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    res.end('Method Not Allowed');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('Medaka playground (static) at http://localhost:' + PORT);
  console.log('  Serving: ' + PLAYGROUND);
  console.log('  dist/playground.wasm must be pre-built: bash playground/build_playground_wasm.sh');
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.error('Port ' + PORT + ' in use — set PORT=<other> to use a different port.');
  } else {
    console.error('Server error:', e);
  }
  process.exit(1);
});
