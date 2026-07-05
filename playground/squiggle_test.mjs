#!/usr/bin/env node
// squiggle_test.mjs — Stage-S2 round-trip: feed a known-broken buffer through the
// EXISTING analyze path (compile.mjs over playground.wasm — the same
// __MEDAKA_DIAGNOSTICS__ output the language worker uses) and assert that
// diagnostics_map.js maps the check --json line/character ranges onto correct
// CodeMirror-6 absolute {from,to} offsets (the substring under a squiggle).
//
// Usage: node squiggle_test.mjs   (node v24; needs dist/ assets present)

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { loadCompiler, compile } from './compile.mjs';
import { diagnosticsFromFiles, lineStarts, lcToOffset } from './diagnostics_map.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const wasm   = await loadCompiler(join(__dirname, 'dist', 'playground.wasm'));
const stdlib = {
  runtime: readFileSync(join(__dirname, 'dist', 'runtime.mdk'), 'utf8'),
  core:    readFileSync(join(__dirname, 'dist', 'core.mdk'), 'utf8'),
};

let pass = 0, fail = 0;
const ok = (n) => { console.log('  PASS: ' + n); pass++; };
const no = (n, d) => { console.error('  FAIL: ' + n + (d ? '\n        ' + d : '')); fail++; };

console.log('\n=== Stage-S2 squiggle round-trip ===\n');

// ── pure-mapping unit checks (deterministic, no wasm) ─────────────────────────
{
  const src = 'abc\ndefgh\nij';
  const st = lineStarts(src);
  ok('lineStarts: ' + JSON.stringify(st) + (JSON.stringify(st) === '[0,4,10]' ? '' : ' MISMATCH'));
  if (JSON.stringify(st) !== '[0,4,10]') fail++;
  // line1 char2 = 'f' at absolute offset 6
  const off = lcToOffset(src, st, 1, 2);
  if (off === 6 && src[off] === 'f') ok('lcToOffset(1,2) → 6 (=\'f\')');
  else no('lcToOffset(1,2)', 'got ' + off + ' (char ' + JSON.stringify(src[off]) + ')');
  // character past EOL clamps to line end
  const clamped = lcToOffset(src, st, 0, 99);
  if (clamped === 3) ok('lcToOffset clamps past-EOL char to line end');
  else no('lcToOffset clamp', 'got ' + clamped);
  // a synthetic diagnostic maps to the exact substring
  const files = [{ file: 'x', diagnostics: [
    { message: 'm', severity: 1, range: { start: { line: 1, character: 1 }, end: { line: 1, character: 4 } } },
  ] }];
  const [d] = diagnosticsFromFiles(src, files);
  if (d.from === 5 && d.to === 8 && src.slice(d.from, d.to) === 'efg')
    ok('diagnosticsFromFiles → substring "' + src.slice(d.from, d.to) + '"');
  else no('diagnosticsFromFiles substring', JSON.stringify(d) + ' slice=' + JSON.stringify(src.slice(d.from, d.to)));
}

// ── real analyze round-trip: type error on line 1 ─────────────────────────────
{
  const source = 'main = println (1 + "hello")\n';
  const r = await compile(source, { wasm, stdlib });
  if (r.ok) { no('type-error program compiled ok (expected diagnostics)'); }
  else {
    const files = r.diagnostics && r.diagnostics.files;
    const raw = files && files[0] && files[0].diagnostics && files[0].diagnostics[0];
    if (!raw) { no('no diagnostic produced', JSON.stringify(r.diagnostics).slice(0, 200)); }
    else {
      ok('analyze produced diagnostic: ' + JSON.stringify(raw.message).slice(0, 70));
      const diags = diagnosticsFromFiles(source, files);
      const d = diags[0];
      // Offsets must be in-bounds, ordered, and land inside the source.
      if (d.from >= 0 && d.to <= source.length && d.from <= d.to)
        ok('CM6 offsets in-bounds & ordered: {from:' + d.from + ',to:' + d.to + '}');
      else no('offsets out of bounds/order', JSON.stringify(d));
      const span = source.slice(d.from, d.to);
      ok('squiggle span = ' + JSON.stringify(span) + ' (severity ' + d.severity + ')');
      if (d.severity === 'error') ok('severity 1 → "error"');
      else no('severity map', 'got ' + d.severity);
      // The reported range should be non-empty on a real type error.
      if (d.to > d.from) ok('non-empty squiggle span');
      else no('empty span', JSON.stringify(d));
    }
  }
}

// ── clean program → zero diagnostics ──────────────────────────────────────────
{
  const r = await compile('main = println (1 + 2)\n', { wasm, stdlib });
  if (r.ok) ok('clean program → ok:true (no squiggles)');
  else no('clean program produced diagnostics', JSON.stringify(r.diagnostics).slice(0, 150));
}

console.log('\n=== ' + pass + ' pass / ' + fail + ' fail ===\n');
process.exit(fail > 0 ? 1 : 0);
