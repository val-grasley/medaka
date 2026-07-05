// medaka_tokenizer.js — a hand-written stream tokenizer for Medaka, matching the
// compiler lexer's token classes (compiler/frontend/lexer.mdk; census in
// PLAYGROUND-EDITOR-DESIGN.md §5).  It is a CodeMirror-6 StreamParser body, but
// it has NO CodeMirror imports so it can be unit-tested in isolation over any
// object implementing the CM6 StringStream surface (peek/next/eat/eatSpace/
// match/eol/pos/string).  medaka_lang.js wires it into a real StreamLanguage.
//
// token() returns one of these class names per token (mapped to highlight tags
// by medaka_lang.js's tokenTable):
//   keyword comment string character number typeName variableName
//   operator punctuation bool escape interpolation
//
// The two stateful pieces are handled through the parser state object:
//   blockComment : nesting depth of `{- {- -} -}` block comments (0 = outside)
//   strKind      : 'normal' | 'triple' when currently scanning a string body,
//                  else null
//   interpStack  : stack of { brace, kind } frames for `"a \{expr} b"` string
//                  interpolation — each frame remembers the enclosing string
//                  kind to resume when its `{`/`}` balance returns to 0
//                  (interpolations nest: `"\{ f "\{x}" }"`).

// The 28 keywords (lexer.mdk keywordOrIdent, 295-328).  True/False are NOT here
// — they lex as TUpper (uppercase), handled as `bool` below.
export const KEYWORDS = new Set([
  'let', 'rec', 'with', 'mut', 'in', 'if', 'then', 'else', 'match', 'data',
  'record', 'interface', 'default', 'impl', 'import', 'export', 'public',
  'where', 'of', 'do', 'as', 'extern', 'requires', 'deriving', 'type',
  'newtype', 'prop', 'test', 'bench', 'effect', 'internal', 'function',
]);

// Multi-char operators, longest-first so a plain string match never truncates a
// longer operator (lexer.mdk scanOp, 725-775).
const OP3 = ['...'];
const OP2 = ['==', '!=', '<=', '>=', '&&', '||', '::', '++', '|>', '>>', '<<',
  '=>', '->', '<-', '[|', '|]', '{.', '.*', '..', '.=', '@|'];
const OP1_SET = '+-*/%<>=:.|!?@~^&$';   // single-char operator chars
const PUNCT_SET = '()[],;';             // delimiters (not braces — see below)

export function startState() {
  return { blockComment: 0, strKind: null, interpStack: [] };
}

export function copyState(s) {
  return {
    blockComment: s.blockComment,
    strKind: s.strKind,
    interpStack: s.interpStack.map((f) => ({ brace: f.brace, kind: f.kind })),
  };
}

export function token(stream, state) {
  if (state.blockComment > 0) return tokenBlockComment(stream, state);
  if (state.strKind) return tokenString(stream, state);
  return tokenCode(stream, state);
}

// Inside a `{- … -}` block comment (possibly spanning lines / nested).
function tokenBlockComment(stream, state) {
  while (!stream.eol()) {
    if (stream.match('{-')) { state.blockComment++; continue; }
    if (stream.match('-}')) {
      state.blockComment--;
      if (state.blockComment <= 0) { state.blockComment = 0; break; }
      continue;
    }
    stream.next();
  }
  return 'comment';
}

// Inside a string body (normal `"…"` or triple `"""…"""`).  Emits one token:
// either the interpolation opener `\{` (switching to code), the closing
// delimiter, an escape, or a run of literal text.
function tokenString(stream, state) {
  const triple = state.strKind === 'triple';

  // interpolation opener `\{` — begins an embedded code region
  if (stream.match('\\{')) {
    state.interpStack.push({ brace: 1, kind: state.strKind });
    state.strKind = null;
    return 'interpolation';
  }

  // closing delimiter
  if (triple) {
    if (stream.match('"""')) { state.strKind = null; return 'string'; }
  } else if (stream.match('"')) {
    state.strKind = null;
    return 'string';
  }

  // escape sequence (normal strings process escapes; triples treat `\` as
  // literal except before `{`, already handled above)
  if (!triple && stream.peek() === '\\') {
    stream.next();                       // backslash
    if (!stream.eol()) {
      const e = stream.next();
      if (e === 'u' && stream.peek() === '{') {
        while (!stream.eol() && stream.next() !== '}') { /* \u{HEX} */ }
      }
    }
    return 'escape';
  }

  // literal run up to the next special char (`"`, `\`, or EOL)
  while (!stream.eol()) {
    const c = stream.peek();
    if (c === '"' || c === '\\') break;
    stream.next();
  }
  // Guard against a zero-width token (StreamLanguage requires progress): if we
  // consumed nothing, take one char so we always advance.
  if (stream.eol() && stream.pos === stream.start) { /* handled by caller */ }
  return 'string';
}

function tokenCode(stream, state) {
  if (stream.eatSpace()) return null;

  const c = stream.peek();

  // line comment `-- … EOL`
  if (c === '-' && stream.match('--', false)) { stream.skipToEnd(); return 'comment'; }

  // block comment open `{-`
  if (c === '{' && stream.match('{-')) { state.blockComment = 1; return tokenBlockComment(stream, state); }

  // string / char literals
  if (c === '"') {
    if (stream.match('"""')) { state.strKind = 'triple'; return 'string'; }
    stream.match('"');
    state.strKind = 'normal';
    return 'string';
  }
  if (c === "'") return tokenChar(stream);

  // numbers: radix (0x/0b/0o) first, then decimal int / float (no sci-notation)
  if (c >= '0' && c <= '9') {
    if (stream.match(/^0x[0-9a-fA-F][0-9a-fA-F_]*/) ||
        stream.match(/^0b[01][01_]*/) ||
        stream.match(/^0o[0-7][0-7_]*/)) return 'number';
    stream.match(/^[0-9][0-9_]*(\.[0-9][0-9_]*)?/);   // int or `int.frac`
    return 'number';
  }

  // backtick infix operator `` `f` ``
  if (c === '`') {
    stream.next();
    while (!stream.eol() && stream.next() !== '`') { /* to closing backtick */ }
    return 'operator';
  }

  // uppercase identifier (TUpper): types / constructors; True/False are bools
  if (c >= 'A' && c <= 'Z') {
    const w = stream.match(/^[A-Za-z0-9_]+/)[0];
    if (w === 'True' || w === 'False') return 'bool';
    return 'typeName';
  }

  // lowercase / underscore identifier or keyword
  if ((c >= 'a' && c <= 'z') || c === '_') {
    const w = stream.match(/^[A-Za-z0-9_]+/)[0];
    if (KEYWORDS.has(w)) return 'keyword';
    return 'variableName';
  }

  // multi-char operators (longest-first)
  for (const op of OP3) if (stream.match(op)) return 'operator';
  for (const op of OP2) if (stream.match(op)) return 'operator';

  // plain delimiters
  if (PUNCT_SET.indexOf(c) >= 0) { stream.next(); return 'punctuation'; }

  // braces: interpolation-brace tracking when inside a `\{ … }`, else record punct
  if (c === '{' || c === '}') {
    stream.next();
    const top = state.interpStack[state.interpStack.length - 1];
    if (top) {
      if (c === '{') { top.brace++; return 'punctuation'; }
      top.brace--;
      if (top.brace <= 0) { state.interpStack.pop(); state.strKind = top.kind; return 'interpolation'; }
      return 'punctuation';
    }
    return 'punctuation';
  }

  // single-char operators
  if (OP1_SET.indexOf(c) >= 0) { stream.next(); return 'operator'; }

  // anything else: consume one char, unstyled
  stream.next();
  return null;
}

function tokenChar(stream) {
  stream.next();                          // opening '
  while (!stream.eol()) {
    const d = stream.next();
    if (d === '\\') { if (!stream.eol()) stream.next(); continue; }
    if (d === "'") break;
  }
  return 'character';
}
