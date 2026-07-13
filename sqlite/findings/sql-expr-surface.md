# Findings — SQL expression surface (`||`, LIKE, IN, BETWEEN, CASE, COALESCE, string fns)

Task: fill in the missing SQL expression surface in `sqlite/lib/select.mdk` +
`sqlite/lib/sqlparse.mdk`. Everything shipped (see the branch summary for the full
list); this file is the pain-point log. Two real findings, both in the "surprising
stdlib semantics" category — no new compiler bugs hit this session.

## F1 — `string.toUpper`/`toLower`/`trim`/`ltrim`/`rtrim` are Unicode-correct, which is
the WRONG behavior to reuse for SQLite's built-in `UPPER`/`LOWER`/`TRIM`/`LIKE`

- **Category:** missing-stdlib / surprising-semantics
- **Severity:** workaround-required (not a blocker — just cost an investigation
  session and a hand-rolled ASCII-only fold)
- **Repro:** verified against the real `sqlite3` CLI (3.46.1), not assumed:
  ```sh
  $ sqlite3 :memory: "SELECT upper('café'), lower('CAFÉ'), '['||trim(char(9)||'hi'||char(9))||']';"
  CAFé|cafÉ|[	hi	]
  ```
  SQLite's built-in `UPPER`/`LOWER` fold **only ASCII `a`-`z`/`A`-`Z`** — `é`/`É`
  pass through untouched (this is a genuine, documented SQLite quirk: full-Unicode
  case folding needs the ICU extension, which isn't loaded by default). Its 1-arg
  `TRIM`/`LTRIM`/`RTRIM` strip **only the space character `0x20`** — a tab (`char(9)`)
  survives, which a "trim whitespace" mental model would not predict. `LIKE`'s
  case-insensitivity is the same ASCII-only rule (`'ÄBC' LIKE 'äbc'` is `0`,
  `'ABC' LIKE 'abc'` is `1`).
- **Expected:** `string.toUpper "café"` and SQLite's `upper('café')` would agree
  (both "just fold case"), so `UPPER`/`LOWER`/`TRIM`/`LIKE` could delegate straight
  to `stdlib/string.mdk`.
- **Actual:** `stdlib/string.mdk`'s versions are explicitly documented as **full
  Unicode** ("`toUpper`/`toLower` here are the *String* versions (full Unicode, so
  `Straße` → `STRASSE`)" — see the module header). Reusing them would have silently
  produced answers that disagree with `sqlite3` on any non-ASCII input — exactly
  the "looks right, ships wrong" trap this workstream exists to catch. There is no
  ASCII-only variant on offer.
- **Workaround:** hand-rolled `asciiFold : (Char -> Char) -> String -> String` +
  `asciiUpperChar`/`asciiLowerChar` (fold only codepoints 65-90/97-122) and a
  space-only `spaceTrimLeft`/`spaceTrimRight` pair, all local to
  `sqlite/lib/select.mdk` (now `export`ed so `lib.sqlparse` can share the fold
  rather than re-implement it — see F2 below). ~35 lines total.
- **Notes:** I deliberately did **not** push these into `stdlib/string.mdk`. Full
  Unicode is the *correct* general-purpose default — SQLite's ASCII-only behavior
  is a legacy quirk specific to emulating it, not something most callers of a
  general string library want. Adding `asciiUpper`/`asciiLower`/`spaceTrim` to the
  stdlib on the strength of one SQL-compat need felt like the wrong generalization
  (a `string.mdk` reader would have no idea which of `toUpper`/`asciiUpper` to
  reach for, and "the ASCII one" is a footgun default). If a SECOND consumer shows
  up wanting C-locale-style ASCII case folding, that's the signal to promote this;
  one consumer isn't. Flagging per the task instructions all the same, since it's
  exactly the "expected a stdlib function, didn't exist" shape — I just concluded
  the right fix is local, not a stdlib PR. **No `stdlib/` files were touched.**

## F2 — Adding one ADT constructor means finding and touching every exhaustive
match over the type — the compiler catches it (good), but there's no shortcut

- **Category:** ergonomics
- **Severity:** annoyance
- **Repro:** `SqlExpr` (`sqlite/lib/select.mdk`) is a closed ADT consumed by
  pattern-exhaustive functions in TWO files. Adding 6 new constructors
  (`EConcat`/`ELike`/`EIn`/`ECase`/`ECoalesce`/`EFn`) meant adding a matching arm
  to **9** separate functions: `render`/`renderExpr` (`select.mdk`), `compileTri`,
  `compileOperand`, `aggsIn`, `rewriteInner` (the post-GROUP-BY rewrite), plus
  `renderSqlExpr`, `dumpExpr`, `hasAgg` in `sqlparse.mdk` — each a hand-written,
  independently-shaped traversal (some fold to `Bool`, some rebuild the tree, some
  project to `String`, one is 3-valued). None of them share a generic
  "visit every child" helper, so each new constructor is 9 small, mechanical, but
  easy-to-miss edits.
- **Expected:** some kind of derived generic traversal (a `Functor`/`Foldable`-over-
  the-recursive-positions instance, or a fold combinator) that the 9 call sites
  build on, so a new constructor is one new case in ONE place plus 9 call-site
  defaults rather than 9 independent hand-rolled matches.
- **Actual:** none of that exists (nor should it necessarily — ADT-per-file
  hand-rolled traversal is a defensible, simple design, and Medaka doesn't claim
  otherwise). The exhaustiveness checker is genuinely the saving grace here: every
  missing arm was a **compile error**, not a silent gap — I never had to guess
  which of the 9 functions I'd forgotten (the compiler told me, one at a time, via
  `check`). So this is pure ergonomics friction, not a correctness risk: the
  language already prevents the failure mode a generic-traversal mechanism would
  exist to prevent; it just doesn't save the typing.
- **Workaround:** none needed beyond doing the mechanical work; `medaka check` made
  it fast (each error pointed at the exact missing-arm function and constructor).
- **Notes:** Not filing this as a request for a specific feature — a generic
  traversal derivation is a real design commitment (visitor generation, GADTs-ish
  machinery) that may not be worth it for a language whose whole ADT story is
  "closed, hand-matched, exhaustiveness-checked." Logging it because the task
  explicitly asks for ergonomic friction, and this was the most repetitive stretch
  of the session by a wide margin (roughly a third of the diff is these 9×6
  mechanical arms).

## Non-findings (things that worked and are worth naming, since "nothing wrong"
deserves the same scrutiny as "something wrong")

- **`||` precedence.** SQLite's real operator table puts `||` ABOVE `* / %`
  (tighter — verified: `1+2 || 3+4` evaluates to `28` via `1 + (2||3) + 4` with
  implicit text→number coercion), not beside `+ -` as a naive reading of "additive
  vs. multiplicative" might suggest. This is a SQL-semantics fact, not a Medaka
  finding, but worth recording because the task brief itself stated the wrong
  tier and explicitly asked to verify — a good reminder that this whole workstream
  runs on "trust `sqlite3`, not the brief."
- **Native `build` vs the constructor-PAP landmine (F1 in `sql-parser-expr.md`).**
  Every new binary-operator token builder (`concatOp`) follows the SAME eta-expanded
  `(l r => EConcat l r)` pattern as the existing `arithTok`, and every fully-applied
  multi-arg constructor call (`EFn "LENGTH" [a]`, `ECase whens els`, `EIn x vs`, …)
  was checked to confirm it supplies ALL constructor args at the call site, never a
  partial one bound to a name. `medaka build` (native) matched `sqlite3` on every
  one of 120 differential query cases, including through the LIKE/IN/CASE/`||`
  paths that exercise these constructors most — no repeat of that miscompile.
- **The recursive-parser cyclic-value trap (F6/header note in `sql-parser-expr.md`).**
  Every new back-edge parser (`caseExpr`, `whenThen`, `elseClause`, `fnCall`) is
  written with `do`-notation, matching the existing `parens`/`notPrefix` pattern;
  none hit `E-CYCLIC-VALUE`. Traced through WHY precisely (which combinator
  argument positions are "strict now" vs. "deferred behind a lambda") before
  writing the code rather than after debugging a failure — worth the few minutes.
- **`sepBy1`/`chainl1` in `parsec` needed zero changes** — `IN (v1, v2, …)` and the
  whole comparison-suffix extension slotted into the existing committed-suffix-loop
  design (`cmpSuffixHead`/`cmpSuffixTail`) without new combinator plumbing.
- **`string.replaceAll`'s contract already matches SQLite's `replace(X,Y,Z)`
  exactly** (including "unchanged if `Y` is empty" and empty-`X`/empty-`Y`
  edge cases) — reused directly, no adaptation needed.
- **`string.slice`/`stringSlice`'s `[lo, hi)`-clamped-to-bounds contract** made
  `substr`'s fairly intricate (`Y`/`Z` zero/negative) formula a clean 6-line
  `clamp`-based implementation once derived — no OOB panics to guard against.
