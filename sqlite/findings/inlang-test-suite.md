# SQLite dogfood — findings: in-language `test`/`prop` suite

Task: add real `test "…"` / `prop "…"` suites for the sqlite library and wire them
into CI. New files: `sqlite/test/{dbfix,expr_test,query_test,roundtrip_test}.mdk`
+ `sqlite/test/inlang_test_oracle.sh` (auto-enrolled by the `sqlite` shard glob
`'sqlite/test/*oracle'`). No lib/compiler edits.

All findings are ergonomics/tooling friction — no compiler bugs, no wrong answers.
The library was a pleasure to test: every value I harvested matched what the
existing sqlite3 differential oracles already assert.

## F1 — `test.mdk` has no `Ok`/`Result`-aware assertion helper

- **Category:** ergonomics
- **Severity:** annoyance
- **Repro:** every query test reads `expectEqual (q "SELECT …") (Ok [[CText "Alice"]])`.
- **Expected:** an `expectOk : (Eq a, Debug a) => Result e a -> a -> Expectation`
  (assert `Ok x` and compare `x`), so a passing test needn't spell the `Ok`
  wrapper and a build/parse `Err` reports *its message* rather than an opaque
  "expected Ok […] but got Err …".
- **Actual:** I wrap every expected value in `Ok [...]`. Works, but a failing
  query surfaces the whole `Err "…"` inside a Debug diff instead of as the error.
- **Workaround:** wrap in `Ok`; for the invariant tests I hand-wrote a
  `match … Err e => fail e` shim.
- **Notes:** pure stdlib addition to `stdlib/test.mdk` (`expectOk`, maybe
  `expectErr`). Would remove boilerplate from essentially every DB-backed test.
- **Tracked in #431.**

## F2 — no `Arbitrary` for domain types; every prop hand-builds values

- **Category:** ergonomics
- **Severity:** annoyance
- **Repro:** the record round-trip prop must synthesise cells from a generated
  scalar: `prop "…" (xs : List Int) = let cells = map CInt xs; …`.
- **Expected:** being able to write `prop "…" (cells : List Cell) = …` — i.e. an
  `Arbitrary Cell` (and it composing to `List Cell`).
- **Actual:** `prop` only generates the built-in `Arbitrary` types (`Int`,
  `String`, `List Int`, `Bool`, `Float`), so a domain round-trip can only be
  exercised through a scalar the generator already knows.
- **Workaround:** build representative `List Cell`s from generated `Int`/`String`.
  Adequate, but it under-exercises `CBlob`/`CFloat`/mixed-width rows.
- **Notes:** there is no user-facing way to register an `Arbitrary` instance for
  a library type today (checked `stdlib/test.mdk`); a prop can only draw the
  compiler's built-in generators. A user-definable `Arbitrary` would make
  codec/parser round-trips (the highest-value dogfood here) far stronger.
- **Tracked in #425.**

## F3 — a function's *domain* can't be expressed to the generator

- **Category:** ergonomics
- **Severity:** annoyance
- **Repro:** `sqVarint`/`sqVarintBytes` are defined only for `0 ≤ v < 2^56`; the
  prop had to mask the draw: `let v = bitAnd n 72057594037927935`.
- **Expected:** a way to say "draw from this range" (a ranged/bounded generator).
- **Actual:** I fold the raw `Int` draw into the valid domain by hand, which also
  quietly narrows what the prop tests.
- **Notes:** minor and probably inherent to the current `prop` design; noting it
  because two of my four props needed a manual domain fold.

## F4 — cross-file `rule-duplicate-body` fires on a shared data literal

- **Category:** tooling
- **Severity:** annoyance
- **Repro:** `dbfix.mdk`'s `specs : List (String, String, Option Int, …)` table
  list is structurally identical to the `specs` in four demo probes, so
  `medaka lint sqlite` flags it cross-file and the max-ratchet pre-commit hook
  would reject the commit.
- **Expected:** a fixture table literal shared by *intent* across independent
  demo/test files shouldn't need suppression — a data literal is not a
  duplicated *function body* in the sense the rule targets.
- **Actual:** had to add `-- lint-disable-file rule-duplicate-body` (the same
  escape hatch every demo probe already uses for exactly this reason — see the
  `lint-disable-file` header in `inmem_join_probe.mdk` et al).
- **Notes:** the rule is structural and can't tell "coincidentally identical
  fixture data" from "copy-pasted logic". Not blocking, but every file in this
  directory now carries the same disable, which suggests the rule over-fires on
  data-heavy fixture modules.

## F5 — `queryString` vs `queryStringDistinct` is a runtime, not a type, distinction

- **Category:** surprising-semantics (mild)
- **Severity:** annoyance
- **Repro:** `queryString db "SELECT DISTINCT …" tCells` returns
  `Err "SELECT DISTINCT needs queryStringDistinct …"` at runtime.
- **Expected:** picking the wrong entry point for a `DISTINCT` query is caught by
  the type system, not by a stringly-typed `Err`.
- **Actual:** the `Eq a` cost of dedup means the two entry points differ only in
  a constraint, so the mismatch shows up as a `Result` error string. Sensible
  given the design (documented in `sqlstmt.mdk`), just a small trap for a caller
  who doesn't know the query is `DISTINCT` ahead of time.
- **Workaround:** the fixture exposes both `q` and `qd`; tests use the right one.

## F6 — prelude lacks `length`/`reverse`/`sort`; invariant tests hand-roll them

- **Category:** ergonomics
- **Severity:** annoyance
- **Repro:** the ORDER-BY / DISTINCT invariant tests needed `len`,
  `nonDecreasing`, and a `hasNoDups` helper.
- **Actual:** `all`/`any`/`elem` are in the prelude but `length`/`reverse`/`sort`
  live in `stdlib/list`; I hand-rolled tiny recursive helpers to avoid importing
  a whole module into a test file for one function.
- **Notes:** deliberate stdlib boundary, not a bug — noted only because writing
  list-shaped *invariants* (sorted? permutation? no-dups?) is a natural thing to
  want in property tests and currently costs a few lines of boilerplate each.

---

## Doctests judged "abusive" (behavioral assertions posing as docs) — follow-up only, NOT touched

Per scope I did not edit any lib doctest. Candidates a future pass could migrate
to `test "…"`/`prop "…"` decls (they assert behavior a newcomer would never write
as *documentation*):

- **`sqlite/test/rowtype_doctest.mdk`** — the whole file is a doctest-hosted test
  suite (its own header calls it a "Doctest suite for the typed-result layer").
  It exists only to carry ~15 behavioral assertions as `>` examples on throwaway
  `showI`/`showB`/`showP2` wrappers. These are unit tests wearing a doctest
  costume; they belong as `test "…"` decls (my new `expr_test`/`query_test` cover
  the query side but not these pure RowType-combinator error paths).
- **`sqlite/lib/recordfmt.mdk`** `parseRecord` doctests that feed hand-computed raw
  byte arrays (`arrayFromList [4, 0, 23, 1, 67, 97, …]`) and assert the decoded
  string. Nobody reads a literal SQLite record header as documentation — these
  are regression assertions and would read better as `test`/`prop`.
- **`sqlite/lib/varint.mdk`** the `roundTrip N` doctests (bottom of file) are
  genuinely a property (`decode∘encode = id`) enumerated at hand-picked points —
  now also covered generatively by `roundtrip_test.mdk`'s varint prop; the
  doctests could stay as illustrative examples or fold into the prop.

None of these are bugs; they're testing-hygiene debt. Flagging for the
orchestrator; leaving the files untouched.
