// editor.js — CodeMirror 6 editor setup for the Medaka playground (Stage S1/S2).
// Imports CM6 through the `codemirror` bare specifier (resolved by index.html's
// import-map to the vendored single-ESM bundle), plus the Medaka language
// (highlighting) and the pure diagnostics mapping (squiggles).
//
// Exposes a tiny imperative API so main.js's textarea reads/writes become CM6
// state reads/writes with minimal churn:
//   createEditor(parent, doc, onDocChange) -> view
//   getValue(view) -> string
//   setDiagnostics(view, files)   // files = check --json shape; squiggles
//   clearDiagnostics(view)

import {
  EditorState, EditorView, keymap, lineNumbers, highlightActiveLine,
  highlightActiveLineGutter, drawSelection, rectangularSelection, crosshairCursor,
  highlightSpecialChars, bracketMatching, indentOnInput, foldGutter, indentUnit,
  defaultKeymap, history, historyKeymap, indentWithTab, closeBrackets,
  closeBracketsKeymap, setDiagnostics as cmSetDiagnostics, lintGutter,
  highlightSelectionMatches, searchKeymap,
} from 'codemirror';
import { medaka } from './medaka_lang.js';
import { diagnosticsFromFiles } from './diagnostics_map.js';

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
}, { dark: true });

export function createEditor(parent, doc, onDocChange) {
  const listener = EditorView.updateListener.of((u) => {
    if (u.docChanged && typeof onDocChange === 'function') onDocChange();
  });

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
      medaka(),
      medakaTheme,
      keymap.of([
        indentWithTab,
        ...closeBracketsKeymap,
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

export function setDiagnostics(view, files) {
  const src = view.state.doc.toString();
  const diags = diagnosticsFromFiles(src, files);
  view.dispatch(cmSetDiagnostics(view.state, diags));
  return diags;
}

export function clearDiagnostics(view) {
  view.dispatch(cmSetDiagnostics(view.state, []));
}
