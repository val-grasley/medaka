# PARSE-ERROR-LOCATION-DESIGN

Scope: make Medaka's parse errors **located (caret) with a real explanation**, to
the bar its typecheck errors already hit. Audit finding #2 — parse errors are the
worst part of the compiler for beginners. READ-ONLY design doc; no source touched.

Verified on the built native binary at HEAD (`git merge-base --is-ancestor
421ddb22 HEAD` = BASE_OK). Every claim below reproduced on the tree.

---

## 1. Root cause of the `1:0` collapse

There are **two independent defects** — one in the parser (bad *location*), one in
the driver (no *caret*). They compound.

### 1a. Location: silent-backtracking combinators discard the failure position

The parser monad is `PR a = POk a Int | PErr String Int` (`parser.mdk:63`), where
the `Int` is the current token index. Error-producing primitives set a real
message + position:

- `failP msg` → `PErr msg pos` (`:100`)
- `advanceR TEof pos` → `PErr "unexpected end of input" pos` (`:178`)
- `expectGo` → `failP "unexpected token"` (`:193`); `identNameFor` → `"expected identifier"` (`:202`)

But the two backtracking combinators **throw the `PErr` away**:

```
orElseR pa pb toks pos = match runP pa toks pos     -- parser.mdk:208
  POk x q  => POk x q
  PErr _ _ => runP pb toks pos                        -- msg + pos DISCARDED

manyGo p toks pos acc = match runP p toks pos          -- parser.mdk:221
  POk x pos2 => manyStep ...
  PErr _ _   => POk (reverseL acc) pos                 -- resets to element-START pos
```

`parseProgram = do skipNoise; many declThenNoise` (`:2992`). When the first
top-level decl fails to parse, `many` catches the `PErr` and returns
`POk [] pos` where `pos` is the position at which that decl *started* (≈ token 0
after the leading `skipNoise`). The top boundary then does:

```
resultDeclsResult ... (POk ds pos)                     -- parser.mdk:3450
  | peekTok toks pos == TEof = Ok ds
  | otherwise = Err (mkLocated ... "Parse error" pos)  -- generic msg, pos ≈ 0
```

So the reported error is the **generic string `"Parse error"` at the start of the
un-parseable declaration** — token 0 → line 1, col 0. That is the `1:0`.

The deep failure — e.g. `advanceR`'s "unexpected end of input", or a `failP
"unexpected token"` fired 15 tokens in — never survives the `orElse`/`many`
unwinding back to the top. Message and position are both lost.

**Why a few cases DO get a real column (e.g. `println (1 + 2` → `1:15`).** When
the failing construct sits inside a *nested* `many` (application-argument list),
that inner `many` cleanly stops, leaving the offending token as **leftover**, and
its position rides up as the outer `POk`'s `pos`. `main = println` parses as a
complete decl (body = `println`); the un-openable `(1 + 2` atom is left over at
col 15, so `resultDeclsResult` reports `"Parse error"` there. It is incidental —
still the generic message, still no caret, and it lands on a *plausible* token
rather than the true stuck point. The `1:0` cases are the ones where the failure
unwinds all the way to the decl head with nothing consumed.

`locateOffset`/`offsetAt` (`:3429`–`:3441`) correctly special-case EOF/past-end so
end-of-input errors pin to `srcLen` rather than the synthetic-token bogus 0 — that
machinery is fine. The problem is strictly *which token index* reaches it.

### 1b. Caret: the CLI text path hand-rolls the header, bypassing the caret renderer

Even with a good message/column, `medaka check` (text) never prints a caret. The
parse-error arm formats the header by hand and returns:

```
Ok tsrc => match parseResult tsrc                      -- medaka_cli.mdk:222
  Err e =>
    let loc = "\{target}:\{parseErrorLine e}:\{parseErrorCol e}"
    let _ = ePutStrLn "\{loc}: \{parseErrorMessage e}"  -- NO caret, NO snippet
    exit 1
```

Contrast the typecheck arm three functions down, which renders through the
caret-aware `ppDiagCliSrc tsrc target` (`medaka_cli.mdk:286`), and the
module-load arm (`:263`). `ppDiagCliSrc` (`diagnostics.mdk:220`) already produces
the exact caret block errors want:

```
file:L:C: message
  |
N | <source line>
  |    ^
```

### 1c. run / build / fmt are worse — no location at all

`medaka run|build|fmt` on a parse error print a bare `parse error` with **no
file, line, or message**. They go through the *panicking* boundary
`resultDecls _ (PErr _ _) = panic "parse error"` (`parser.mdk:3365`), not the
non-panicking `parseResult`. Only `check` (text + `--json`) routes through
`parseResult` today.

### Reproduced matrix (native binary, HEAD)

| Input | `check` today | True issue |
|---|---|---|
| `if true { x } else { y }` | `1:0: Parse error` | `{` after `if …` (wants `then`) |
| `for x in [1,2,3]:` | `1:0: Parse error` | no `for`; foreign syntax |
| `def f(x):` | `1:0: Parse error` | no `def`; foreign syntax |
| `function f(x){}` | `1:0: Parse error` | `{` body; foreign syntax |
| `main = { x` (unclosed) | `1:0: Parse error` | `{` not an expr opener |
| `/* block */` | `1:0: Parse error` | C comment; Medaka is `{- -}` |
| `main =` (empty body) | `1:0: Parse error` | unexpected end of input |
| `println (1 + 2` | `1:15: Parse error` | unclosed `(` — *incidentally* located |
| any of the above via `run`/`build`/`fmt` | `parse error` | not even located |

`--json` mirrors `check`: `{"code":"P-PARSE","message":"Parse error","range":{...line0,char0}}`.

---

## 2. Mechanism design

The good news: **the ParseError→Diag machinery already exists and is wired for the
JSON + LSP paths.** `parseErrCode` (`diagnostics.mdk:155`), `parseErrHelpFix`
(`:178`), `parseErrLoc` (`:433`) build a full `Diag` (code/kind/help/fix/Loc), and
`wrappedRead` (`:417`) already does exactly this for the LSP. The `check --json`
path (`medaka_cli.mdk:345`+) builds the same. The **text CLI path just doesn't
call any of it.**

So the work splits cleanly along the two defects:

### Fix 1b/1c (render) — cheap, no parser change

Route every CLI-text parse-error arm through `ppDiagCliSrc`, building the `Diag`
from the existing helpers (all already imported into `medaka_cli.mdk`, lines
80/91/92). Replace the hand-rolled `check` arm (`medaka_cli.mdk:222-226`) with:

```
Err e =>
  let ploc = Loc target (parseErrorLine e) (parseErrorCol e) (parseErrorLine e) (parseErrorCol e + 1)
  let (h, fx) = parseErrHelpFix (parseErrorMessage e) ploc
  let diag = Diag SevError (parseErrCode (parseErrorMessage e)) (parseErrorMessage e) (Some ploc) h fx
  let _ = ePutStrLn (ppDiagCliSrc tsrc target diag)
  exit 1
```

and give `run`/`build`/`fmt` a `parseResult` pre-check (before their panicking
`parse`) that renders the same way. This is **~15 lines, error-path only, zero
parser change, no re-mint.** It immediately delivers the caret + snippet + code +
any existing hint/fix for *every* parse error, and lifts run/build/fmt from bare
`parse error` to a located diagnostic.

Note: `ppDiagCliSrc` reads the source line via `nthLine` and needs the `Loc` line
to be 1-based (it is — `parseErrorLine` is 1-based) and col 0-based (it is). No
`ParseError` widening needed for this fix.

### Fix 1a (location) — the real work, two options

To stop the `1:0` collapse for *arbitrary* errors we must recover the **furthest
failure position** (and ideally its message) across the backtracking. Two designs:

**Option A — out-of-band high-water-mark Ref (recommended for Stage 3).**
Matches the idiom the parser *already uses*: `located` and the fmt position
side-channel thread state through module `Ref`s (`locSrcRef`, `locOffsRef`,
`parser.mdk:128-137`) without changing the `Parser` type. Add:

```
furthestRef : Ref (Int, String)          -- (maxFailPos, msg)
```

Reset it in the parse entry point; have the error primitives *record-if-further*:
in `failP`, in `advanceR`'s EOF arm, and in the handful of inline `PErr` sites,
do `if pos >= furthestRef.value.fst then setRef furthestRef (pos, msg)`. Because
`orElse`/`many` never touch the Ref, the deepest failure **survives backtracking**.
At the top, when `resultDeclsResult` would emit the generic `"Parse error"`,
consult `furthestRef` for the real deepest position + message instead.

- Pro: no change to `PR`/`Parser` *data*; combinators untouched; parsed-AST byte-identical.
- Con: `failP` currently is a pure `Array Token -> Int -> PR a`; a `setRef` write
  makes it `<Mut>`, which propagates the `<Mut>` effect through the `Parser`
  function type (`data Parser a = Parser (Array Token -> Int -> <Mut> PR a)`) and
  every combinator's signature. This is mechanical but broad, and — critically —
  **it changes the parser's emitted IR on the happy path too** (new effect
  plumbing), so it is a fixpoint-affecting change requiring re-validation and a
  likely **seed re-mint** (see §5). Reads of a `Ref` (`.value`) are already used
  effect-free in the parser; only the *writes* pull in `<Mut>`.

**Option B — widen `PR` to carry the high-water error.**
`POk a Int (Option (Int,String))` / thread a "furthest seen" through `mapPR`,
`apPR`, `bindPR`, `orElseR`, `manyGo`. Keeps everything pure (no `<Mut>`), but
touches every combinator and every `POk`/`PErr` construction — more surface than
A, and also fixpoint-affecting. Not recommended over A.

**Message enrichment.** Once the furthest position is recovered, the message is
whatever primitive fired there — already `"unexpected end of input"` /
`"expected identifier"` etc. To reach *"unexpected `{`"* / *"expected `then`,
found `{`"*, enrich the choke points: `advance`/`expectTok` can name the token
they saw (the token is in hand at `peekTok toks pos`) and, for `expectTok`, the
token they *wanted*. A small `tokenName : Token -> String` renders `TLBrace` as
`` `{` ``, `TThen` as `` `then` ``, etc. This is additive to the primitives and
does not require the furthest-failure machinery to be useful (it improves whatever
message reaches the top).

---

## 3. Explanation quality — the pre-scan hint chain covers the beginner cases *now*

`parseResult` already runs a chain of **pre-grammar token scans** that produce
located, beginner-grade messages for known foreign-syntax mistakes
(`parser.mdk:3585-3599`): `/=`→`!=`, inline-`let`-missing-`in`, Haskell
`case … of`, Haskell `::` type sig, plus `TLexError` (unterminated string/comment,
`\`-lambda, `$`). Each is a pure scan returning `Err (mkLocated … msg idx)` with a
**real token index** — so it *already* dodges the `1:0` collapse for its cases,
and each has a `parseErrCode` (`L-*`/`P-HS-*`) and some a machine `fix`.

**The audit's named beginner cases are exactly this pattern and slot straight in:**

| Case | Discriminator scan | Message |
|---|---|---|
| `{ … }` block/braces | `TLBrace` at an expression position (after `=`,`if…`,`then`,`else`,`(`) | ``unexpected `{` — Medaka has no brace blocks; use indentation`` |
| `for x in e:` | `TIdent "for"` … `TColon` at line end | `Medaka has no 'for'; use recursion or 'List.map/forEach'` |
| `def f(x):` | `TIdent "def"` at decl head | `Medaka has no 'def'; define a function as 'f x = …'` |
| `function f(x){}` | `TFunction`/`TIdent` followed by `(params){` | (folds into the brace hint) |
| trailing `;` | `TSemi` (if lexed) at statement end | `Medaka has no statement semicolons; newline-separate` |
| `/* … */` | `/` `*` adjacency (Medaka block comments are `{- … -}`) | ``unexpected '/*' — block comments are `{- … -}` `` |

These are **low-risk** exactly like the existing hints: they run *before* the
grammar and fire only on token shapes that are *never* valid Medaka, so no
valid-parse path is touched. They give real location + caret (via Fix 1b) +
explanation for the precise cases beginners hit most — *without* needing the
furthest-failure machinery at all.

The residual `"Parse error"` (arbitrary syntax slips outside the enumerated set)
still needs Fix 1a to escape `1:0`; but the caret (Fix 1b) applies to it too, and
"unexpected `<token>`" message enrichment (§2) makes even the generic case
readable.

---

## 4. Staged plan (ascending risk, each independently gatable)

**Stage 1 — caret + code on ALL parse errors (LOW risk, no parser change, no re-mint).**
Route the `check`-text arm through `ppDiagCliSrc` + the existing `Diag` builders;
add a `parseResult` pre-check to run/build/fmt so they stop printing bare
`parse error`. Pure driver change (`medaka_cli.mdk`), error-path only. Immediately
fixes "no caret" everywhere and every existing good message/column (e.g. the
`/=`, `case…of`, `::` hints) now renders with a snippet + caret. Gate: recapture
parse-error goldens across the ~5 affected gates (§5).

**Stage 2 — foreign-syntax pre-scan hints (LOW risk, no monad change).**
Add braces / `for` / `def` / `function` / `/* */` / trailing-`;` scanners to the
`parseResult` chain (mirrors the 5 hints already there). Delivers the audit's
named cases with real location + explanation + caret (Stage 1 renders them).
Purely additive; only fires on always-invalid token shapes. Gate: new fixtures in
`test/parse_error_fixtures/` + `test/error_quality_fixtures/parse/`.

**Stage 3 — general furthest-failure location + "unexpected `<token>`" (MEDIUM risk).**
Add the high-water-mark Ref (Option A) so *arbitrary* parse errors report the
deepest real token position instead of `1:0`/incidental, and enrich `advance`/
`expectTok` to name the unexpected (and expected) token. This is the general fix
but touches the `Parser` type's effect signature → fixpoint re-validation + likely
seed re-mint, and must be proven byte-identical on all valid parses. Do last;
optional if Stages 1+2 already cover the beginner surface well enough.

Recommended lock: **commit to Stages 1+2** (they deliver every audit-named case at
low risk and no re-mint), treat **Stage 3 as a follow-up** gated on whether the
residual generic `"Parse error"` rate still matters after 1+2.

---

## 5. Design forks — need a human decision

1. **How far to invest.** Stages 1+2 (caret everywhere + foreign-syntax hints)
   cover *every case the audit names* at low risk / no re-mint. Stage 3 (general
   furthest-failure + expected-set messages) is a larger, fixpoint-affecting
   change for the *residual* arbitrary-slip case. **Recommendation: lock 1+2 now,
   decide 3 after seeing 1+2 in practice.** Do you want the full expected-set
   parser rework in this preview, or is "beautiful on the common mistakes,
   located+caret on the rest" the 0.1.0 bar?

2. **Widen `ParseError`?** Not needed for Stages 1+2 — `ParseError Int Int String`
   already carries line/col/msg, and the `Diag`/help/fix are recovered from the
   message string at the boundary (existing design). Stage 3's furthest-failure is
   best done via the out-of-band Ref (Option A), which *also* leaves `ParseError`
   unchanged. **Recommendation: do not widen `ParseError`.**

3. **Golden-churn blast radius.** ~**28 golden/fixture files** reference a
   parse-error string, spread across ~5-6 gates: `parse_error_fixtures/` (6 →
   `diff_compiler_parse_errors.sh`), `error_quality_fixtures/parse/` (5) +
   `error_quality_fixtures/` (2), `check_json_fixtures/` (2 →
   `diff_compiler_check_json.sh`), `native_fixtures/` (3 → `diff_native_cli.sh`),
   `lsp_fixtures/` (1), `wasm/` (1). Stage 1 moves the *text* renderings (now
   caret blocks) and Stage 2 adds new fixtures; recapture via
   `bash test/capture_goldens.sh` (or per-gate `CAPTURE=1`). Manageable, bounded,
   mechanical. **No re-mint for Stages 1+2** — they are strictly error-path driver
   + pre-scan changes; the emitted parser IR on valid input is unchanged.
   **Fixpoint reasoning:** `parser.mdk` is in the self-compile graph, so *any*
   change to it re-enters the fixpoint — but Stages 1+2 add only new pre-scan
   *functions* (dead on valid input) and touch the driver, so the emitter's output
   on the compiler's own (valid) source is byte-identical → fixpoint holds, no
   re-mint. **Stage 3 changes the `Parser` type's effect signature** → emitted IR
   for the parser changes on all paths → **fixpoint must re-validate and a seed
   re-mint is expected.** Confirm this is acceptable before scheduling Stage 3.

---

## 6. Risk register

- **Valid-parse paths must stay byte-identical.** Stages 1+2 only touch the
  *error* path (driver render + pre-grammar scans that fire on always-invalid
  tokens). The happy path — `parse`/`resultDecls` and the grammar productions —
  is not edited. Verify with the full `run_gates.sh` suite (valid-input goldens
  unchanged) + `selfcompile_fixpoint.sh`.
- **Pre-scan false positives (Stage 2).** A discriminator that fires on a *valid*
  token shape would reject good programs. The existing hints show the discipline
  required (e.g. the `::`-sig scan is gated to depth-0 decl-head only, because
  `::` is cons everywhere else — `parser.mdk:3545-3574`). Each new scanner needs
  the same "never-valid-Medaka" proof + a valid-input fixture that must *not*
  trip it. Braces are the sharpest edge: `{` is used in **record literals /
  updates** (`{ r | f = v }`) — the brace hint must only fire where `{` cannot
  legally open (statement/decl-body position after `=`/`then`/`else`), never at an
  expression position where a record is valid. Get this discriminator wrong and
  valid record code regresses.
- **Stage 3 effect-threading.** Making `failP` write a Ref pulls `<Mut>` through
  the `Parser` type — broad signature churn, and the fixpoint/re-mint cost above.
  Guard with the fixpoint gate; if the churn is unacceptable, fall back to Option
  B (pure `PR`-widening) or defer Stage 3 entirely.
- **`ppDiagCliSrc` needs the source text.** The `check` arm has `tsrc` in scope;
  the run/build/fmt arms must read the file's source before rendering (they
  already have it or read it for parsing). Low risk, just plumbing.
- **Route fragility.** The parser is central; keep every change on the error path
  and lean on the existing pre-scan idiom rather than restructuring the monad for
  Stages 1+2.
