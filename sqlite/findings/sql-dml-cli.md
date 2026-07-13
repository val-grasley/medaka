# Findings — SQL DML statements + the SQL CLI

Task: `INSERT` / `UPDATE` / `DELETE` / `CREATE TABLE` parsing (`lib.sqlstmt`,
`lib.schemadef`), wiring them to the existing write engine (`lib.mutate`,
`lib.writer`), and turning `sqlite/main.mdk` into a real `sqlite3`-compatible CLI
(`lib.sqlexec`).  Gate: `sqlite/test/dml_oracle.sh`.

Known landmines from prior stages (partially-applied ctor miscompile, cross-module
record-field slot bug, `deriving (Eq)` over `Array`, `run` not gating on type errors,
point-free recursive parser back-edge) are NOT re-filed.  Only new things are here.

---

## F1 — A positive scientific-notation Float literal does not lex; the error blames a phantom variable

- **Category:** compiler-bug / error-message
- **Severity:** workaround-required
- **Repro:**
  ```medaka
  big : Float
  big = 9.0e15

  main : <IO> Unit
  main = println big
  ```
- **Expected:** `9.0e15` is a Float literal (`1e-05` already works — a NEGATIVE
  exponent lexes fine, so this reads as an oversight, not a design choice).
- **Actual:**
  ```
  f.mdk:2:13: Unbound variable: e15
  ```
  The lexer stops the number at `9.0` and hands `e15` to the parser as an
  identifier.  The diagnostic therefore blames a variable the programmer never
  wrote, at a column inside a numeric literal — nothing points at "exponent".
- **Workaround:** spell the number out (`9000000000000000.0`) — but see **F2**, which
  makes even that unsafe.  What I actually shipped is
  `intToFloat 9000000000000000` (an INT literal, converted at run time), which is
  the only spelling of a large Float constant that survives the whole toolchain.
- **Notes:** lexer (`compiler/frontend/lexer.mdk`) number scanner: it accepts
  `e-<digits>` but not `e<digits>` / `e+<digits>`.  Previously logged as OPEN in the
  project memory ("`1e12` scientific-notation rejected"); this is the same gap, now
  with the misleading-diagnostic half characterized.

---

## F2 — ⚠️ `medaka fmt --write` CORRUPTS a source file containing a large Float literal

- **Category:** tooling (formatter round-trip)
- **Severity:** blocker (it destroys source, and the pre-commit hook runs `fmt`)
- **Repro:**
  ```medaka
  -- f.mdk — parses, typechecks, runs, prints "9e+15"
  big : Float
  big = 9000000000000000.0

  main : <IO> Unit
  main = println big
  ```
  ```sh
  medaka run f.mdk        # -> 9e+15
  medaka fmt --write f.mdk
  cat f.mdk               # -> big = 9e+15
  medaka run f.mdk        # -> BROKEN
  ```
- **Expected:** `fmt` is a semantics-preserving, idempotent pretty-printer.  AGENTS.md
  states it outright: "`medaka fmt` is safe (0 corruptions / 0 non-idempotent
  repo-wide)".
- **Actual:** `fmt --write` rewrites the literal to `9e+15`, which the lexer **cannot
  read back** (F1).  The file is now broken:
  ```
  f.mdk:2:6: No impl of Num for (Float -> Float)
    |
  2 | big = 9e+15
  ```
  (The parse of `9e+15` is `9 e + 15` — an APPLICATION of `9` to `e`, plus 15.  Here
  it happens to type-error; the general shape is a silent misparse, which is why this
  is filed as a blocker rather than an annoyance.)
- **Root cause (high confidence):** the printer renders a Float literal with
  `floatToString`, which switches to scientific notation for large magnitudes —
  emitting a notation the lexer rejects.  The two halves of the round-trip disagree,
  so **fmt's printer must not use `floatToString`'s notation for literals** (or F1
  must be fixed, which closes this too).
- **Workaround:** never write a Float literal whose `floatToString` rendering uses an
  exponent.  I derive the constant from an Int (`intToFloat 9000000000000000`).
- **Notes:** `compiler/tools/printer.mdk` / `compiler/tools/fmt.mdk`, `ENumLit`/float
  literal arm.  Threshold is wherever `floatToString` flips to `%g`-style output.
  **This one is worth a regression fixture**: a float-literal round-trip property
  (`parse ∘ print == id`) over a corpus of magnitudes.

---

## F3 — `medaka test` panics on a parse error instead of reporting it

- **Category:** tooling / error-message
- **Severity:** workaround-required
- **Repro:**
  ```medaka
  -- pe.mdk
  f : Int -> Int
  f x =
    as <- 1
    x
  ```
- **Expected:** `medaka test` reports the parse error the way `medaka check` does.
  `check` on the same file is exemplary:
  ```
  pe.mdk:3:2: unexpected `as`; expected a dedent
    |
  3 |   as <- 1
    |   ^
  ```
- **Actual:**
  ```
  runtime error [E-PANIC]: parse error
  ```
  No file, no line, no column, no caret, no code — and an `E-PANIC` prefix, which
  reads like a COMPILER crash rather than a problem in my file.  I lost a cycle
  looking for a bug in the doctest machinery before thinking to re-run `check`.
- **Workaround:** always run `medaka check <file>` before `medaka test <file>`.
- **Notes:** `compiler/tools/test_cmd.mdk` / `compiler/tools/doctest.mdk` — the
  doctest driver evidently `panic`s on a `Result`/diagnostic instead of routing it
  through `compiler/driver/diagnostics.mdk`.  Related in spirit to the prior stage's
  "doctests silently disabled for months" finding: the `test` entry point does not
  surface front-end failures.

---

## F4 — Binding a non-monadic value with `<-` in a `Result` do-block reports a **container** error

- **Category:** error-message
- **Severity:** annoyance (but a very costly one — the message points at the wrong universe)
- **Repro:**
  ```medaka
  -- fileExists : String -> <FileRead "_"> Bool   (a BARE Bool, not a Result)
  f : String -> <FileRead> Result String Int
  f p = do
    e <- fileExists p
    Ok 1

  main : <IO, FileRead> Unit
  main = println (f "x")
  ```
- **Expected:** something like *"`<-` in a `Result` do-block expects a `Result`; the
  right-hand side is a `Bool`. Use `let e = fileExists p`."*
- **Actual:**
  ```
  fe.mdk:5:18: 'andThen' expects a container (like List or Array) here, but got Bool.
  Pass a List or Array, or convert the Bool to one first.
  ```
  The message is about **Lists and Arrays**.  I was in a `Result`-typed `do` block
  talking to the filesystem; nothing in the program mentions a container.  The advice
  ("convert the Bool to one first") is actively wrong — the fix is to not bind it at
  all.  The failing constraint is `Thenable Bool`, and the diagnostic has hard-coded
  one particular *reason* someone might want a `Thenable` (a Foldable/Traversable
  container) as if it were the only one.
- **Workaround:** thread the value in as a parameter:
  ```medaka
  createTableIn path ct = createWith path ct (fileExists path)
  ```
- **Notes:** the `Thenable`/`andThen` no-impl diagnostic in
  `compiler/types/typecheck.mdk`.  Suggested shape: name the interface that failed
  (`Thenable`), name the type that lacks it, and — when the do-block's other
  statements pin the monad — say which monad was expected.  Per
  `compiler/ERROR-QUALITY.md` this is a "names the rule / actionable fix" miss.

---

## F5 — `as` is a reserved keyword, and the parse error does not say so

- **Category:** error-message
- **Severity:** annoyance
- **Repro** (as actually hit — a `do`-block binder named `as`, the obvious name for a
  list of SQL `SET` assignments):
  ```medaka
  updateBranch : Parser Stmt
  updateBranch = do
    _ <- keyword "UPDATE"
    as <- commaSep1 setAssign     -- `as` is reserved
    pure (SUpdate as)
  ```
- **Expected:** *"`as` is a reserved keyword and cannot be used as a name."*
- **Actual:**
  ```
  sqlstmt.mdk:652:2: unexpected `as`; expected a dedent
    |
  652 |   as <- commaSep1 setAssign
    |   ^
  ```
  Reasonable *layout* wording, but it never says the word is RESERVED, so the natural
  conclusion is "my indentation is wrong" and you go and fix the wrong thing.  (`as`
  is not in `SYNTAX.md`'s keyword list, which is where I looked.)
- **Worse in the `let` form** — the caret moves to the WRONG TOKEN entirely:
  ```medaka
  f xs =
    let as = xs
    as
  ```
  ```
  as.mdk:3:2: unexpected `let`; expected a dedent
    |
  3 |   let as = xs
    |   ^
  ```
  The offending word is `as`; the diagnostic blames `let`.
- **Workaround:** renamed to `asgs`.
- **Notes:** parser (`compiler/frontend/parser.mdk`) — when the unexpected token is a
  keyword, say so, and point at the keyword rather than the construct it broke.
  Cheap, high-value: the same wording problem will hit every reserved word used as an
  identifier.

---

## F6 — No way to write raw bytes to stdout (`writeFileBytes` has no stdout twin)

- **Category:** missing-stdlib
- **Severity:** workaround-required
- **Repro:** the CLI must print a BLOB column the way `sqlite3` does — as its raw
  bytes.  Medaka `String` is UTF-8, so `stringFromChars` over the byte values
  re-encodes any byte ≥ 0x80 into two UTF-8 bytes; there is no `println`-of-bytes.
  `stdlib/runtime.mdk` has `writeFileBytes : String -> Array Int -> …` but nothing
  like `writeStdoutBytes : Array Int -> <IO> Unit`.
- **Expected:** a byte-oriented stdout primitive, symmetric with `writeFileBytes`.
- **Actual:** none.  Anything binary must go via a temp file.
- **Workaround:** the CLI renders a BLOB as the marker `<blob>` (the pre-existing
  `lib.recordfmt.cellToString` behaviour), and `dml_oracle.sh` gates blob STORAGE by
  asking `sqlite3` itself for `hex(col)` on both databases instead of diffing our
  stdout.  Documented in `sqlite/main.mdk`'s header as a known divergence.
- **Notes:** `stdlib/runtime.mdk` + `compiler/eval/eval.mdk` (a new extern — out of
  scope for a library agent).

---

## F7 — `concatMap` does not exist; `flatMap` is in `core` with a `Thenable` constraint

- **Category:** missing-stdlib / ergonomics
- **Severity:** annoyance
- **Repro:**
  ```medaka
  fails : List String
  fails = concatMap check corpus     -- Unbound variable: concatMap
  ```
- **Expected:** `list.mdk` exports `concatMap : (a -> List b) -> List a -> List b` — it
  is one of the most common list combinators after `map`/`filter`.
- **Actual:**
  ```
  cm.mdk:8:6: Unbound variable: concatMap
    |
  8 | out = concatMap ch corpus
    |       ^
  ```
  Note the contrast with the neighbouring `zip`, whose unbound-variable diagnostic DOES
  carry a fix (`Unbound variable: zip. (Did you forget to 'import list.{zip}'?)`).  For
  a name that exists nowhere the diagnostic is bare — correct, but it means "no
  suggestion" is indistinguishable from "you spelled it right and it just isn't there",
  which is exactly the moment you want the compiler to say *"no such function"*.
- **Workaround:** `flatMap` (in `core`,
  `Thenable m => (a -> <e> m b) -> m a -> <e> m b`), which works for `List` but is a
  dict-passed generic where a monomorphic list function would do.  It also is not a
  name you find by looking in `list.mdk`.
- **Notes:** `stdlib/list.mdk`.

---

## F8 — Ergonomics: a "pure transform" cannot be expressed as pure once one leaf needs an effect

- **Category:** ergonomics
- **Severity:** annoyance
- **Notes / no clean repro:** `lib.mutate`'s new shared engine takes the transform as
  a plain `String -> List (Int, List Cell) -> Result String (…)` — genuinely
  effect-free — while the surrounding `rewriteTable` is
  `<FileRead, FileWrite, Mut>`.  That worked, and the effect rows compose without
  fuss, which is the good news worth recording.  The friction is one level up:
  `buildDatabaseMultiExplicit` carries `<Mut>` purely because it builds an image with
  a mutable byte buffer inside, so EVERY function that merely *sequences* it —
  `rewriteImage`, `createImage`, `insertRows`' callers — must repeat `<Mut>` in its
  signature even though nothing observable mutates.  There is no way to say "this
  effect is internal and does not escape" (an effect-scoping / `runST`-style
  construct).  Roughly a dozen signatures in this library exist only to re-declare
  `<Mut>`.

---

# Library divergences found (NOT language findings) — for the orchestrator

These are bugs in `sqlite/lib/select.mdk`, which a **parallel agent owns this
session**, so I did not touch them.  Both are WRONG ANSWERS versus `sqlite3`, and both
are in the QUERY engine (they are reachable from a plain `SELECT` — they are not DML
bugs).  `dml_oracle.sh` routes around them and says so in its comments; they should be
fixed and the corpus tightened afterwards.

## D1 — arithmetic on a TEXT operand yields NULL; sqlite3 coerces the text to a number

`lib.select.evalArith` documents "a non-numeric (text/blob) operand … yields NULL".
That is not SQLite's rule: SQLite applies a numeric cast, and a non-numeric string
casts to **0**.

```sh
sqlite3 q.db "CREATE TABLE t(s TEXT, n INTEGER); INSERT INTO t VALUES('abc', 5);"
sqlite_cli q.db "SELECT s + 1, s * 2, n + s FROM t"    # Medaka : ||     (NULL,NULL,NULL)
sqlite3    q.db "SELECT s + 1, s * 2, n + s FROM t"    # sqlite3: 1|0|5
```
And for numeric-looking text (`s = '7'`): Medaka `NULL`, sqlite3 `8`.

This bit the DML oracle: `UPDATE t SET n = n + 1` over a column holding the text
`'abc'` (which sqlite3 legitimately stores in an INTEGER column) produced NULL in
Medaka and `1` in sqlite3 — the row then matched a later `WHERE n IS NULL` DELETE and
vanished.  **Fix location:** `evalArith` in `sqlite/lib/select.mdk` — add SQLite's
`CAST(… AS NUMERIC)` rule for text operands.

## D2 — the `rowid` pseudo-column is not addressable in a query

```sh
sqlite_cli q.db "SELECT rowid FROM t"   # error: compilePred: unknown column: rowid
sqlite3    q.db "SELECT rowid FROM t"   # 1
```
`SELECT rowid, …` and `ORDER BY rowid` are the idiomatic way to read a table in
storage order, and every row already carries its rowid through the read path
(`scanTableRowsIpk`).  **Fix location:** the column resolver used by
`compileOperand`/`compilePred` in `sqlite/lib/select.mdk` — map the name `rowid`
(and `_rowid_`, `oid`) to the row's rowid, or to the IPK column when one exists.

## D3 — (pre-existing, cosmetic) `columnIndex` / `findTable` are case-sensitive

Already logged as F4 in `findings/sql-parser-select.md`; re-noted only because the DML
path inherits it: `INSERT INTO USERS …` fails with `table not found` where sqlite3
folds identifier case.  It is a clean `Err`, never a wrong answer.  The one place it
would have been dangerous — `lib.sqlite.pkColumnIndex`'s case-SENSITIVE scan for the
literal `"INTEGER PRIMARY KEY"`, which silently returns `None` for a sqlite3-authored
`id integer primary key` and would make the writer store the rowid in the wrong place —
is now **cross-checked and refused** by `lib.mutate` (`ipkAgrees`), and the refusal is
gated in `dml_oracle.sh`.
