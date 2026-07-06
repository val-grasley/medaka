// editor.js — CodeMirror 6 editor setup for the Medaka playground (Stage S1/S2).
// Imports CM6 through the `codemirror` bare specifier (resolved by index.html's
// import-map to the vendored single-ESM bundle), plus the Medaka language
// (highlighting) and the pure diagnostics mapping (squiggles).
//
// Exposes a tiny imperative API so main.js's textarea reads/writes become CM6
// state reads/writes with minimal churn:
//   createEditor(parent, doc, onDocChange, langService) -> view
//   getValue(view) -> string
//   setDiagnostics(view, files)   // files = check --json shape; squiggles
//   clearDiagnostics(view)
//
// langService (optional, Stage S3/S4) wires hover-types + autocomplete to the
// stateless wasm language queries.  Shape:
//   { hover(source, line, col)    -> Promise<LSP Hover | null>
//     complete(source, line, col) -> Promise<LSP CompletionItem[] | null> }
// line/col are 0-based (LSP convention).

import {
  EditorState, EditorView, keymap, lineNumbers, highlightActiveLine,
  highlightActiveLineGutter, drawSelection, rectangularSelection, crosshairCursor,
  highlightSpecialChars, bracketMatching, indentOnInput, foldGutter, indentUnit,
  defaultKeymap, history, historyKeymap, indentWithTab, closeBrackets,
  closeBracketsKeymap, setDiagnostics as cmSetDiagnostics, lintGutter,
  highlightSelectionMatches, searchKeymap, hoverTooltip, autocompletion,
  completionKeymap,
} from 'codemirror';
import { medaka } from './medaka_lang.js';
import { diagnosticsFromFiles } from './diagnostics_map.js';

const IS_IDENT = /[A-Za-z0-9_]/;

// Pull the plain `name : type` line out of the ```medaka\n…\n``` markdown the
// hover guest returns (fall back to the raw value).
function hoverText(hv) {
  const value = (hv && hv.contents && hv.contents.value) || '';
  const m = value.match(/```medaka\n([\s\S]*?)\n```/);
  return m ? m[1] : value;
}

// CM6 hover-tooltip source backed by the wasm `hover` query.  Async: returns a
// Promise<Tooltip|null> (CM6 supports async hover sources).
function medakaHoverTooltip(svc) {
  return hoverTooltip(async (view, pos) => {
    const src = view.state.doc.toString();
    const line = view.state.doc.lineAt(pos);
    // Only fire when the cursor is on an identifier char.
    if (pos >= src.length || !IS_IDENT.test(src[pos])) return null;
    const hv = await svc.hover(src, line.number - 1, pos - line.from);
    const text = hoverText(hv);
    if (!text) return null;
    // Widen the tooltip range to the whole identifier.
    let from = pos, to = pos;
    while (from > line.from && IS_IDENT.test(src[from - 1])) from--;
    while (to < line.to && IS_IDENT.test(src[to])) to++;
    return {
      pos: from, end: to, above: true,
      create() {
        const dom = document.createElement('div');
        dom.className = 'cm-mdk-hover';
        dom.textContent = text;
        return { dom };
      },
    };
  });
}

// CM6 autocomplete source backed by the wasm `complete` query.
function medakaCompletionSource(svc) {
  return async (context) => {
    const word = context.matchBefore(/[A-Za-z_][A-Za-z0-9_]*/);
    if ((!word || word.from === word.to) && !context.explicit) return null;
    const pos = context.pos;
    const line = context.state.doc.lineAt(pos);
    const items = await svc.complete(context.state.doc.toString(), line.number - 1, pos - line.from);
    if (!items || !items.length) return null;
    return {
      from: word ? word.from : pos,
      options: items.map((it) => ({ label: it.label, detail: it.detail, type: 'function' })),
    };
  };
}

// Dark editor chrome matching the playground palette (bg #0d1117 / #c9d1d9,
// accents #e2b96f / #58a6ff, borders #30363d).
const medakaTheme = EditorView.theme({
  '&': {
    color: '#c9d1d9',
    backgroundColor: '#0d1117',
    height: '100%',
    fontSize: '0.88rem',
  },
  '.cm-scroller': {
    fontFamily: "'SF Mono', 'Fira Code', 'Cascadia Code', 'Menlo', monospace",
    lineHeight: '1.55',
  },
  '&.cm-focused': { outline: 'none' },
  '.cm-content': { caretColor: '#58a6ff' },
  '&.cm-focused .cm-cursor': { borderLeftColor: '#58a6ff' },
  '.cm-gutters': {
    backgroundColor: '#0d1117',
    color: '#484f58',
    border: 'none',
    borderRight: '1px solid #21262d',
  },
  '.cm-activeLineGutter': { backgroundColor: '#161b22', color: '#8b949e' },
  '.cm-activeLine': { backgroundColor: 'rgba(56,66,80,0.18)' },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection': {
    backgroundColor: '#264f78',
  },
  '.cm-selectionMatch': { backgroundColor: 'rgba(88,166,255,0.20)' },
  '.cm-matchingBracket, &.cm-focused .cm-matchingBracket': {
    backgroundColor: 'rgba(226,185,111,0.25)',
    outline: '1px solid rgba(226,185,111,0.5)',
  },
  '.cm-lintRange-error': {
    backgroundImage:
      "url('data:image/svg+xml;utf8,<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"3\"><path d=\"m0 3 l2 -2 l1 0 l-2 2 l1 0 l2 -2 l1 0 l-2 2\" fill=\"none\" stroke=\"%23eb5757\"/></svg>')",
  },
  '.cm-lintRange-warning': {
    backgroundImage:
      "url('data:image/svg+xml;utf8,<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"3\"><path d=\"m0 3 l2 -2 l1 0 l-2 2 l1 0 l2 -2 l1 0 l-2 2\" fill=\"none\" stroke=\"%23ffb347\"/></svg>')",
  },
  '.cm-tooltip': {
    backgroundColor: '#161b22',
    border: '1px solid #30363d',
    color: '#c9d1d9',
  },
  '.cm-tooltip.cm-tooltip-lint .cm-diagnostic': { fontSize: '0.82rem' },
  '.cm-mdk-hover': {
    padding: '3px 8px',
    fontFamily: "'SF Mono', 'Fira Code', 'Cascadia Code', 'Menlo', monospace",
    fontSize: '0.82rem',
    color: '#e2b96f',
    whiteSpace: 'pre',
  },
  '.cm-tooltip.cm-tooltip-autocomplete > ul > li[aria-selected]': {
    backgroundColor: '#264f78',
    color: '#c9d1d9',
  },
  '.cm-completionDetail': { color: '#8b949e', fontStyle: 'normal' },
}, { dark: true });

export function createEditor(parent, doc, onDocChange, langService) {
  const listener = EditorView.updateListener.of((u) => {
    if (u.docChanged && typeof onDocChange === 'function') onDocChange();
  });

  // Language-service extensions (hover-types + autocomplete) are added only when
  // a langService is supplied; the editor works without one (S1/S2 unchanged).
  const langExtensions = langService ? [
    medakaHoverTooltip(langService),
    autocompletion({ override: [medakaCompletionSource(langService)], activateOnTyping: true }),
  ] : [];

  const state = EditorState.create({
    doc,
    extensions: [
      lineNumbers(),
      highlightActiveLineGutter(),
      highlightSpecialChars(),
      history(),
      foldGutter(),
      drawSelection(),
      indentUnit.of('  '),
      EditorState.tabSize.of(2),
      bracketMatching(),
      closeBrackets(),
      indentOnInput(),
      highlightActiveLine(),
      highlightSelectionMatches(),
      lintGutter(),
      ...langExtensions,
      medaka(),
      medakaTheme,
      keymap.of([
        indentWithTab,
        ...closeBracketsKeymap,
        ...completionKeymap,
        ...defaultKeymap,
        ...historyKeymap,
        ...searchKeymap,
      ]),
      listener,
    ],
  });

  return new EditorView({ state, parent });
}

export function getValue(view) {
  return view.state.doc.toString();
}

export function setValue(view, doc) {
  view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: doc } });
}

export function setDiagnostics(view, files) {
  const src = view.state.doc.toString();
  const diags = diagnosticsFromFiles(src, files);
  view.dispatch(cmSetDiagnostics(view.state, diags));
  return diags;
}

export function clearDiagnostics(view) {
  view.dispatch(cmSetDiagnostics(view.state, []));
}
