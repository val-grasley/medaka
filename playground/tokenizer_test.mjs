#!/usr/bin/env node
// tokenizer_test.mjs — unit tests for medaka_tokenizer.js (the CM6 StreamParser
// body).  Drives the tokenizer exactly as StreamLanguage does — a fresh
// StringStream per line, `stream.start = stream.pos` before each token, state
// carried across lines — and asserts the emitted (text, class) token stream.
//
// StringStream is imported from the vendored CM6 bundle (no import-map needed in
// node: a direct relative import resolves it).
//
// Usage: node tokenizer_test.mjs   (node v24 — v20 is fine for this pure test)

import { StringStream } from './vendor/codemirror/codemirror.js';
import { startState, token } from './medaka_tokenizer.js';

// Tokenize a whole (possibly multi-line) source into [{text, type}], skipping
// whitespace/null tokens.  Mirrors StreamLanguage's per-line driver.
function tokenize(src) {
  const state = startState();
  const out = [];
  for (const line of src.split('\n')) {
    const stream = new StringStream(line, 2, 2);
    if (line.length === 0) continue;              // StreamLanguage: blankLine
    let guard = 0;
    while (!stream.eol()) {
      stream.start = stream.pos;
      const type = token(stream, state);
      if (stream.pos === stream.start) stream.next();   // ensure progress
      const text = line.slice(stream.start, stream.pos);
      if (type) out.push({ text, type });
      if (++guard > 10000) throw new Error('tokenizer did not terminate on: ' + line);
    }
  }
  return out;
}

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { console.log('  PASS: ' + name); pass++; }
  else { console.error('  FAIL: ' + name + (detail ? '\n        ' + detail : '')); fail++; }
}

// Does the token stream contain a {text,type} pair?
function has(toks, text, type) {
  return toks.some((t) => t.text === text && t.type === type);
}
function typeOf(toks, text) {
  const t = toks.find((x) => x.text === text);
  return t ? t.type : '(absent)';
}

console.log('\n=== Medaka tokenizer unit tests ===\n');

// 1. keywords vs TUpper ctor vs TIdent
{
  const t = tokenize('let match data impl foo Bar baz');
  check('keyword: let', has(t, 'let', 'keyword'));
  check('keyword: match', has(t, 'match', 'keyword'));
  check('keyword: data', has(t, 'data', 'keyword'));
  check('keyword: impl', has(t, 'impl', 'keyword'));
  check('lower ident → variableName (foo)', typeOf(t, 'foo') === 'variableName', 'got ' + typeOf(t, 'foo'));
  check('Upper ident → typeName (Bar)', typeOf(t, 'Bar') === 'typeName', 'got ' + typeOf(t, 'Bar'));
  check('lower ident → variableName (baz)', typeOf(t, 'baz') === 'variableName');
}

// 2. True/False are TUpper bool, NOT keyword
{
  const t = tokenize('x = True\ny = False');
  check('True → bool (not keyword)', typeOf(t, 'True') === 'bool', 'got ' + typeOf(t, 'True'));
  check('False → bool (not keyword)', typeOf(t, 'False') === 'bool', 'got ' + typeOf(t, 'False'));
}

// 3. nested block comment {- {- -} -}
{
  const t = tokenize('a {- outer {- inner -} still -} b');
  check('code before comment: a', typeOf(t, 'a') === 'variableName');
  check('code after nested comment: b', typeOf(t, 'b') === 'variableName',
    'got ' + typeOf(t, 'b') + ' — full: ' + JSON.stringify(t));
  const comments = t.filter((x) => x.type === 'comment');
  check('comment body classified as comment', comments.length > 0);
}

// 3b. multi-line block comment stays comment across lines
{
  const t = tokenize('foo {- line one\nstill comment -} bar');
  check('multiline block comment: foo before', typeOf(t, 'foo') === 'variableName');
  check('multiline block comment: bar after', typeOf(t, 'bar') === 'variableName',
    'got ' + typeOf(t, 'bar'));
}

// 4. line comment
{
  const t = tokenize('x = 1 -- trailing comment');
  check('line comment classified', t.some((x) => x.type === 'comment' && x.text.includes('trailing')));
}

// 5. string with interpolation  "a \{x} b"
{
  const t = tokenize('s = "a \\{x} b"');
  check('string literal quote', has(t, '"', 'string'));
  check('interp opener \\{ → interpolation', has(t, '\\{', 'interpolation'),
    'toks: ' + JSON.stringify(t));
  check('interp code x → variableName', typeOf(t, 'x') === 'variableName');
  check('interp closer } → interpolation', has(t, '}', 'interpolation'));
  // "b " after the interp is string again
  check('string resumes after interp', t.filter((x) => x.type === 'string').length >= 2);
}

// 6. triple string
{
  const t = tokenize('s = """triple"""');
  const strs = t.filter((x) => x.type === 'string');
  check('triple string opener """', strs.some((x) => x.text === '"""'), 'toks: ' + JSON.stringify(t));
  check('triple string body', strs.some((x) => x.text.includes('triple')));
}

// 6b. multi-line triple string
{
  const t = tokenize('s = """line1\nline2"""\nafter = 1');
  check('triple spans lines: after is code', typeOf(t, 'after') === 'variableName',
    'got ' + typeOf(t, 'after'));
}

// 7. numeric literals: hex / bin / oct / decimal / float
{
  const t = tokenize('a = 0xFF\nb = 0b1010\nc = 0o777\nd = 42\ne = 3.14');
  check('hex 0xFF → number', typeOf(t, '0xFF') === 'number', 'got ' + typeOf(t, '0xFF'));
  check('bin 0b1010 → number', typeOf(t, '0b1010') === 'number', 'got ' + typeOf(t, '0b1010'));
  check('oct 0o777 → number', typeOf(t, '0o777') === 'number', 'got ' + typeOf(t, '0o777'));
  check('decimal 42 → number', typeOf(t, '42') === 'number');
  check('float 3.14 → number', typeOf(t, '3.14') === 'number', 'got ' + typeOf(t, '3.14'));
}

// 8. an operator run
{
  const t = tokenize('r = a ++ b |> f >> g == h && i');
  for (const op of ['++', '|>', '>>', '==', '&&']) {
    check('operator ' + op, typeOf(t, op) === 'operator', 'got ' + typeOf(t, op));
  }
}

// 9. backtick infix
{
  const t = tokenize('z = a `mod` b');
  check('backtick infix `mod`', typeOf(t, '`mod`') === 'operator', 'toks: ' + JSON.stringify(t));
}

// 10. char literal
{
  const t = tokenize("c = 'a'");
  check("char literal 'a'", typeOf(t, "'a'") === 'character', 'got ' + typeOf(t, "'a'"));
}

console.log('\n=== ' + pass + ' pass / ' + fail + ' fail ===\n');
process.exit(fail > 0 ? 1 : 0);
