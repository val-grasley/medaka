# Findings — SQL `SELECT` statement parser (`lib.sqlstmt`)

Stage 2 of the SQL front end: `parseSelect : String -> Result String Select`, aggregate-call
syntax in `lib.sqlparse`, `queryString` / `queryStringDistinct`, and the SQL-text differential
oracle (`sqlite/test/sql_oracle.sh`, 71 SQL strings diffed against the real `sqlite3` CLI).

The three known landmines (PAP-constructor miscompile, cross-module record-update slot,
`deriving (Eq)` over an `Array` field) were all avoided by construction and none produced a NEW
variant. What follows is new.

Headline: **F1 and F2 are `medaka run` / `medaka build` / `medaka test` disagreements** — the
class this workstream exists to find. F3 is a data-fidelity bug in the stdlib. F5 is the
mis-located-diagnostic class the brief asked to watch for.

---

## F1 — `medaka test` treats a Markdown `>` blockquote in a doc comment as a doctest, and dies unlocated

- **Category:** tooling / error-message
- **Severity:** workaround-required (it silently disabled a whole module's doctests)

The doctest extractor keys on the `-- >` prefix. A Markdown **blockquote** in a doc comment has
exactly that prefix, so its prose is compiled as a Medaka expression.

- **Repro:** any file with a `>` blockquote in a comment. This one was sitting in
  `sqlite/lib/rowtype.mdk` on `main`, unnoticed:

  ```medaka
  -- > FOOTGUN -- the no-GADT wall.  You must NEVER pattern-match a `RowType a`
  -- > value to recover its element type `a`.
  ```

  ```sh
  $ medaka test sqlite/lib/rowtype.mdk
  ```

- **Expected:** either the blockquote is treated as prose, or the failure names the file, the
  line, and the offending text.
- **Actual:**

  ```
  runtime error [E-PANIC]: parse error
  running doctests in sqlite/lib/rowtype.mdk
  ```

  No file, no line, no column, no offending source, and the two lines are printed in the wrong
  order (the panic precedes the banner). The **consequence** is worse than the message:
  `rowtype.mdk` has been in the tree for many stages and **not one of its doctests ever ran** —
  `medaka test` bailed on the blockquote before reaching them. A test file that silently runs
  zero tests is the worst possible failure mode.

- **Workaround:** rewrote the blockquote with a `-- !!` prefix. `rowtype.mdk` now runs its
  doctests (2/2).
- **Notes:** two separate bugs, worth fixing independently. (1) The extractor should require the
  doctest marker to be *unambiguous*, or at minimum skip a `-- >` line that does not parse as an
  expression instead of aborting the run. (2) A doctest that fails to PARSE must be reported like
  a doctest failure (`file:line: could not parse doctest expression: <text>`), not as a bare
  interpreter panic. This is `compiler/tools/doctest.mdk`.

---

## F2 — `exit` type-checks, works in `medaka build`, and panics under `medaka run`

- **Category:** compiler-bug (`run` ≠ `build`)
- **Severity:** workaround-required

`exit : Int -> <Panic> Unit` is declared in `stdlib/runtime.mdk`. The native backend implements
it. The **interpreter does not**, and reports it as if the name did not exist.

- **Repro:**

  ```medaka
  main : <IO, Panic> Unit
  main =
    let _ = println "hi"
    exit 3
  ```

  ```sh
  $ medaka check e.mdk
  main : Unit                       # exit 0

  $ medaka build e.mdk -o e && ./e
  hi                                # exit 3   ← correct

  $ medaka run e.mdk
  runtime error [E-PANIC]: unbound identifier: exit     # exit 1
  ```

- **Expected:** `medaka run` exits with status 3 after printing `hi`.
- **Actual:** it panics — and note it never printed `hi` either, so the failure is not even at the
  point of use.
- **Workaround:** the probe reports its verdict on the last line of stdout (`TOTAL: PASS` /
  `TOTAL: FAIL`) and `sql_oracle.sh` greps for it, so the probe stays runnable under both
  `medaka run` and a native build.
- **Notes:** two defects. (1) The eval-side extern table (`compiler/eval/eval.mdk`) has no `exit`
  arm; every `stdlib/runtime.mdk` extern ought to be either implemented in eval or rejected at
  *check* time, so that `check`-clean ⇒ `run`-clean. (2) The message is actively misleading —
  `exit` **is** bound (check resolved it and typed it); it is *unimplemented*. `unbound
  identifier` sends you hunting for a missing import. Something like `extern 'exit' is not
  implemented by the interpreter — build it natively` would have cost me zero minutes instead of
  ten.

---

## F3 — ✅ FIXED (issue #57) — `floatToString` now emits shortest-round-trip; a `Float` prints faithfully

- **Category:** missing-stdlib / surprising-semantics
- **Severity:** was workaround-required (a real interop/data-fidelity bug); **RESOLVED**.

- **Repro:**

  ```medaka
  main : <IO> Unit
  main =
    let _ = println (floatToString (1.0 / 3.0))
    let _ = println (floatToString 1.2345678901234567)
    println (floatToString 123456789012345.6)
  ```

- **Expected:** enough digits to round-trip an IEEE-754 double (the shortest round-tripping
  form). C's `%.15g` — what `sqlite3` uses — is SHORTER than round-trip, so it is *not* the
  baseline to match; it is itself lossy.
- **Before #57 (`%.12g`) vs after (shortest-round-trip):**

  | value | Medaka BEFORE (`%.12g`) | Medaka AFTER (#57) | `sqlite3` (C `%.15g`) |
  |---|---|---|---|
  | `1.0 / 3.0` | `0.333333333333` | `0.3333333333333333` | `0.333333333333333` |
  | `1.2345678901234567` | `1.23456789012` | `1.2345678901234567` | `1.23456789012346` |
  | `123456789012345.6` | `1.23456789012e+14` | `1.234567890123456e+14` | `123456789012346.0` |

  The AFTER column round-trips (`toFloat (floatToString x) == x`); the pre-#57 column and
  sqlite3's `%.15g` do not. Scientific notation still kicks in at the same threshold
  (exp < -4 or exp ≥ 12), now at full precision.

- **Fix:** `floatToString` renders shortest-round-trip digits (fewest that `strtod` reads back
  bit-identically). Shared C helper `mdk_float_lexeme` (`runtime/medaka_rt.c`) backs both the
  `floatToString` extern and the bare-Float auto-print; the two WasmGC JS host copies
  (`test/wasm/run.js`, `playground/worker.js`) mirror it byte-for-byte.
- **Oracle:** the `FLOAT ROUND-TRIP` section of `sql_oracle.sh` (formerly `FLOAT_PREFIX`) no
  longer asserts a text-prefix relationship — that inverted, since Medaka is now the longer,
  precise side and sqlite3's `%.15g` string does not itself round-trip. It now asserts the true
  invariant: Medaka's printed value, CAST back to `REAL` by sqlite3, equals the double the query
  computes.
- **Notes:** this mattered well beyond cosmetics for a library whose job is real `.sqlite` files
  — storage was always fine (`beFloat64` writes the true 8 bytes), but every text path (display,
  JSON, logs, a generated SQL literal) was lossy. Now faithful.

---

## F4 — the engine's identifier lookup is case-SENSITIVE; SQL's is not

- **Category:** surprising-semantics (library-level, not a compiler bug)
- **Severity:** annoyance — it is a clean `Err`, never a wrong answer

`SELECT COUNT(*) FROM ORDERS` parses fine (keywords and aggregate names are case-insensitive, as
they should be) and then dies in the engine: `error: table not found: ORDERS`. `sqlite3` folds
identifier case; `findTable` / `columnIndex` in `lib.sqlite` compare exactly.

- **Repro:** `sql_demo shop.db "SELECT COUNT(*) FROM ORDERS;"`
- **Workaround:** none needed for correctness — it errors cleanly rather than returning garbage,
  so it stays outside the diffed corpus. The oracle instead exercises mixed-case **keywords**
  against correctly-cased **identifiers**, which is the parser's actual contract.
- **Notes:** filed for the record, not fixed: it is engine scope (`findTable`/`columnIndex`), it
  would change the semantics of every existing query path, and doing it properly means ASCII-fold
  on lookup while preserving the stored name. A good standalone follow-up.

---

## F5 — a diagnostic in an IMPORTED module is printed with the ENTRY file's name

- **Category:** error-message (mis-located)
- **Severity:** workaround-required (it sent me to the wrong file)

The human-readable renderer takes the *line* from the module that actually has the error but
stamps the **entry file's path** on it. `--json` gets it right, which localizes the bug to the
text renderer.

- **Repro:** put a bad import in `sqlite/lib/sqlparse.mdk` (line 76), then check a file that
  imports it, transitively, several modules up:

  ```sh
  $ medaka check sqlite/sqlparse_probe.mdk
  sqlite/sqlparse_probe.mdk:76:2: Module 'parsec.lib.parser' has no exported name 'POk'
  ```

- **Expected:** `sqlite/lib/sqlparse.mdk:76:2: ...`
- **Actual:** the error is attributed to `sqlparse_probe.mdk` — a file whose line 76 is an
  innocent string in a list literal. I went looking there first. `--json` on the same input is
  correct:

  ```json
  {"file":"sqlite/lib/sqlparse.mdk",
   "diagnostics":[{"code":"R-PRIVATE-NAME",
                   "message":"Module 'parsec.lib.parser' has no exported name 'POk'",
                   "range":{"start":{"line":75,"character":2}}, ...}]}
  ```

- **Workaround:** use `medaka check --json` and read the `file` key whenever an error's line does
  not look like it could possibly be the cause.
- **Notes:** the diagnostic record clearly carries the right file (the JSON proves it); the
  pretty-printer is pairing each diagnostic with the *entry* path instead of its own. Almost
  certainly a one-line fix in the human renderer (`compiler/driver/diagnostics.mdk` or the
  `check` command's print loop). High value: a wrong file in an error message is worse than no
  file, because it is confidently wrong.

---

## F6 — `export data` does not export its constructors, and the error does not say so

- **Category:** error-message / ergonomics
- **Severity:** annoyance

`parsec/lib/parser.mdk` has `export data PResult a = POk a Int | PErr String Int`. Importing
`POk` fails. The distinction is `export` (opaque type) vs `public export` (type + constructors) —
which is a perfectly reasonable design, and it *is* in the docs.

What cost time is the message:

```
Module 'parsec.lib.parser' has no exported name 'POk'
```

"Has no exported name" reads as *"you misspelled it / it does not exist"*. It exists; the type is
just abstract. The compiler knows the difference — the code is even `R-PRIVATE-NAME`, which is
precisely the right diagnosis, and the *message text* then throws that away.

- **Expected:** `'POk' is a constructor of the abstract type 'PResult'; declare it 'public export
  data PResult' to export its constructors`.
- **Workaround:** I wanted a `notFollowedBy`-style zero-width lookahead and reached for the raw
  `Parser` constructor. It turned out I did not need it: seeing the `(` at all means the `column`
  arm is doomed, so *consuming* it costs nothing — failing one character deeper is exactly what
  makes the message outrank its siblings. Ordinary combinators sufficed
  (`sqlparse.mdk:column`/`notCall`).
- **Notes:** the `code` is already right; only the human string needs to catch up. Cheap fix,
  good payoff (this is a first-week-of-Medaka confusion).

---

## F7 — parsec's `orElse` takes a later branch's SUCCESS over an earlier branch's deeper FAILURE, and that silently discards good errors

- **Category:** ergonomics / library design (parsec, not the compiler)
- **Severity:** annoyance — but it is a *rejection-quality* trap, so it is on-topic

Documented in the previous stage as F5 ("a SUCCEEDING alternative discards the deeper failure
explored beneath it"). This stage hit it twice more, and both times the symptom was **a bad error
message on input that should be crisply rejected** — which is exactly the failure mode this
session is chartered to eliminate.

1. `sum(*)` — `aggCall` correctly fails deep inside the parens ("expected an expression"), but
   `column` then happily parses `sum` as a *column name*, succeeds, and its success outranks the
   good failure. The `*` becomes a multiplication operator and the parse dies far away with
   `unexpected character`.
2. `WHERE flag = TRUE` — `boolReject` fails with a precise "TRUE/FALSE literals are not
   supported", and `column` again succeeds by reading `TRUE` as a column name, discarding it.
   (And that one is a genuine booby trap, not just a bad message: over a table that *has* a column
   named `TRUE`, `flag = TRUE` would silently compare two columns.)

- **Fix applied (in the library, not parsec):** make the competing branch *unable* to succeed.
  `column` now refuses an identifier immediately followed by `(` (in SQL that is always a call,
  never a column), and `TRUE`/`FALSE` joined `reservedWords`. Both are in `lib.sqlparse`.
- **Notes:** the general shape is worth a parsec combinator. `notFollowedBy p` — succeed iff `p`
  fails, consuming nothing — is the standard tool and would have expressed both of these directly.
  Requires no compiler change; it does require `PResult`'s constructors (see F6), or a `peek`
  primitive exported alongside `satisfy`.

---

## F8 — a raw parsec failure out-ranks a labelled one on a position tie, so `label` silently does nothing

- **Category:** ergonomics (parsec)
- **Severity:** annoyance

`orElse` breaks a same-position tie to the LEFT. In `notExpr = orElse notPrefix cmpExpr`, an
input that is not an expression at all (`*`, `)`) fails *both* branches at the same position:
`notPrefix` because `NOT` does not match, `cmpExpr` because no atom does. So the **left** branch
wins — and the left branch is `keyword "NOT"`, whose failure is a raw `unexpected character`,
while the right branch is the one carrying the carefully-written `label "expected an
expression"`. The label was inert.

- **Repro (before the fix):** `parseSqlExpr "*"` → `Err "unexpected character at 0"`.
- **After:** `Err "expected an expression at 0"`.
- **Fix applied:** re-label the whole level — `notExpr = label "expected an expression" (orElse
  notPrefix cmpExpr)`. Legal because `label` only rewrites a *zero-consumption* failure, so a real
  error deeper inside either branch still outranks it.
- **Notes:** worth a line in parsec's docs. The rule "left-biased on ties" plus "labels only apply
  at zero consumption" combine into a non-obvious hazard: **the labelled branch must be the
  leftmost one, or the label must sit above the `orElse`.** Same root as F7 — the error-selection
  policy is subtle, and both traps show up as a bad message rather than a wrong parse, which is
  why they survive.

---

## Non-findings (checked, working)

- Aggregates thread through the whole pipeline cleanly — `EAgg` in the SELECT list, in HAVING,
  and in ORDER BY, including `sum(price * qty)` over an expression operand, and `count(*)` shared
  between the select list and `ORDER BY count(*) DESC` (deduped via the derived `Eq SqlExpr`).
- `deriving (Eq)` on `Select` — a record with `List Join`, `Option SqlExpr`, `List (SqlExpr,
  Bool)` fields — works in both the interpreter and the native build. (Only `Array` fields break
  it; no `Select` field is one.)
- `do`-notation over the user-defined `Parser` monad held up under a much bigger grammar with no
  new friction. The one structural constraint — a recursive parser reference must sit inside a
  `do`-continuation, not in argument position, or it is a non-productive cyclic value — was
  already known (previous stage, F3) and is still the only shape to watch.
- The committed-loop pattern (`optional HEAD` then MANDATORY tail: `afterKeyword`, `commaSep1`,
  `joinClauses`) composes well and is what makes `WHERE age >` blame column 31 instead of
  shrugging with "expected end of input".

---

## A bug this work FOUND in the existing engine (fixed here, not a language finding)

**`lib.select` evaluated SQL's three-valued logic as two-valued, and `NOT` over a NULL column
returned the WRONG ROWS.** `compilePred` collapsed UNKNOWN to FALSE at every node. That is
accidentally correct for AND/OR under a top-level WHERE — but not under a `NOT`:

```
age IS NULL
WHERE NOT age = 30
  SQL:  NOT (NULL = 30) = NOT UNKNOWN = UNKNOWN  ⇒ row DROPPED
  was:  not (False)     = True                   ⇒ row KEPT     ✗ wrong answer
```

`NOT (a AND b)` with an UNKNOWN sub-term was wrong the same way. Every earlier oracle built its
`Select` as an ADT by hand and none happened to put a `NOT` over a nullable column, so it had
never been exercised — **the SQL-string oracle caught it on its first run**, which is a fair
argument for the whole "same text, two engines" approach.

Fixed in `sqlite/lib/select.mdk`: a `Tri` (`TTrue`/`TFalse`/`TUnknown`) evaluator with the
standard truth tables, collapsed to `Bool` exactly once at the WHERE/ON/HAVING boundary ("keep the
row iff the predicate is definitively TRUE"). Eight `NOT`-over-NULL queries in the oracle corpus
now pin it against `sqlite3`.
