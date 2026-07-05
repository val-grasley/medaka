// diagnostics_map.js — pure line/col ↔ absolute-offset mapping that converts the
// compiler's `medaka check --json` diagnostics (line/character ranges) into
// CodeMirror 6 `Diagnostic[]` (absolute `from`/`to` offsets).  No CodeMirror
// imports, so it is unit-testable in node and reused verbatim by editor.js
// (offsets computed from `view.state.doc.toString()` match CM's own indexing).

// Offsets of each line's first character (index 0 = line 0).
export function lineStarts(src) {
  const starts = [0];
  for (let i = 0; i < src.length; i++) if (src.charCodeAt(i) === 10) starts.push(i + 1);
  return starts;
}

// (0-based line, 0-based character) → absolute offset, clamped to the line's end
// (excluding its trailing newline) and to the document bounds.
export function lcToOffset(src, starts, line, character) {
  const n = starts.length;
  const li = Math.min(Math.max(line | 0, 0), n - 1);
  const base = starts[li];
  const lineEnd = (li + 1 < n) ? starts[li + 1] - 1 : src.length;
  const off = base + Math.max(character | 0, 0);
  return Math.min(off, lineEnd);
}

// Convert the `{files:[{diagnostics:[{message,range,severity,source}]}]}` object
// into CM6 Diagnostic[] against the given source text.
export function diagnosticsFromFiles(src, files) {
  const starts = lineStarts(src);
  const out = [];
  for (const f of files || []) {
    for (const d of f.diagnostics || []) {
      const r = d.range || {};
      const s = r.start || { line: 0, character: 0 };
      const e = r.end || s;
      let from = lcToOffset(src, starts, s.line, s.character);
      let to = lcToOffset(src, starts, e.line, e.character);
      if (to < from) to = from;
      if (to === from) to = Math.min(from + 1, src.length);   // ensure a visible span
      out.push({
        from,
        to,
        severity: d.severity === 2 ? 'warning' : 'error',
        message: d.message || '',
        source: d.source || 'medaka',
      });
    }
  }
  // CM6 requires diagnostics sorted by `from`.
  out.sort((a, b) => a.from - b.from || a.to - b.to);
  return out;
}
