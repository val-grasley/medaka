# SQL arithmetic TEXT→numeric coercion + the implicit `rowid` column

Two SQLite-semantics behaviours added to `sqlite/lib/select.mdk`, each verified
DIFFERENTIALLY against the real `sqlite3` CLI in `sqlite/test/sql_oracle.sh`
(byte-for-byte) and under the interpreter in
`sqlite/test/arith_rowid_test.mdk`.

## Feature 1 — arithmetic coerces a TEXT/BLOB operand to a number

`evalArith` used to yield `NULL` for any non-numeric operand. SQLite instead
applies numeric affinity to an arithmetic operand: it takes the **longest
leading numeric prefix**, using `0` when there is none. NULL still propagates
(the null check runs *before* coercion, so `NULL + '5' = NULL`, not `5`).

The exact prefix grammar (`coerceNumericCell` / `coerceTextNumeric`), all
derived by probing `sqlite3`:

- optional leading ASCII whitespace (`' ' \t \n \v \f \r`) — `'  5' + 2 = 7`
- optional sign — `'+7' + 0 = 7`, `'-0' + 0 = 0`
- integer digits and/or a `.` with fractional digits — `'.5'`, `'5.'`, `'3.5'`
- an optional `e`/`E` exponent, **only consumed when ≥1 exponent digit follows**
  — `'5e' + 0 = 5` and `'5e+' + 0 = 5` (the `e` is *not* part of the number),
  but `'3.5e2' + 0 = 350.0`
- trailing junk is ignored — `'5abc' + 2 = 7`, `' 5 6' + 0 = 5`, `'1.2.3' + 0 = 1.2`
- no numeric prefix ⇒ `0` — `'abc'`, `''`, `'  '`, and `'0x10' + 2 = 2` (hex is
  **not** recognised; only the leading `0` is read)
- `'inf'`/`'nan'` ⇒ `0` (SQLite agrees — its affinity `atof` rejects those spellings)

Result **type**: a prefix carrying a `.` or a valid exponent is REAL (`CFloat`),
otherwise INTEGER (`CInt`). Blobs coerce via their byte-string
(`x'31' + 0 = 1`). The coercion is applied by `compileOperand`'s `EArith` arm,
so it also covers `UPDATE ... SET x = <text> + n` (via `lib.mutate`).

### Deliberately UNMATCHED edges (documented, never a wrong-looking answer)

- **Integer magnitude in `(2^62, 2^63)`.** Medaka's `Int` is 63-bit
  (`intMaxBound = 2^62 - 1`); SQLite's is 64-bit. A text integer that fits int64
  but not Medaka's `Int` (e.g. `'9223372036854775807'`) overflows and falls back
  to `CFloat` here, where SQLite keeps it an integer. Smaller magnitudes, and the
  overflow-past-int64 case (`'99999999999999999999' → 1.0e+20`, real in both), agree.
- **Giant-integer float FORMATTING.** `'99999999999999999999' + 0` denotes the
  same double in both engines but prints `1e+20` (Medaka shortest-round-trip,
  issue #57) vs `1.0e+20` (sqlite3 `%g`). Same class as the existing avg-float
  cases — kept OUT of the byte-diff corpus for that reason (it is a value-equal,
  format-only difference, exactly like the oracle's FLOAT ROUND-TRIP section).

## Feature 2 — the implicit `rowid` column (aliases `_rowid_` / `oid`)

The column resolver (`mkLookup` for the single-table path; `colOrRowid`, shared
by `lookupBare`/`lookupQualified`, for the aliased/join path) now resolves
`rowid` / `_rowid_` / `oid` (case-insensitively) to the **INTEGER PRIMARY KEY
column** when the table has one. That column's cell already holds the rowid value
(`rowCellsWithIpk` / `substituteIpk` in `lib.sqlite`), so no new value plumbing is
needed — the alias just points at the IPK slot.

- `columnIndex` is tried FIRST, so a real user column literally named `rowid`/
  `oid` **shadows** the alias — matching SQLite (verified: `orders(oid INTEGER
  PRIMARY KEY, …)` resolves `oid` to the real column, and a `hasrowid(rowid TEXT,
  …)` table returns the real `rowid` text column).
- `SELECT *` never shows rowid (it is not a stored column; it aliases the IPK).
- Works in the SELECT list, WHERE, ORDER BY, qualified (`o.rowid`), and across a
  JOIN (`users.rowid`, `orders.rowid`).

### Deliberately UNMATCHED edge (out of scope)

- **rowid on a table with NO `INTEGER PRIMARY KEY`.** SQLite still exposes a
  hidden rowid there; this engine does not, so `SELECT rowid FROM <non-ipk-table>`
  is a **clean** `error: ... unknown column: rowid` (never a wrong answer). The
  reason it is deferred: the resolver hands back an *index into the row's stored
  cell list*, and a non-IPK table's rowid is not in that list. Materialising it
  would mean appending a synthetic cell to every source row — which the `SELECT *`
  path (`pairRows [] rows = map (r => (r, r)) rows`) would then emit as a phantom
  column — so it needs the executor to separate a "rowid channel" from the visible
  cells, a change beyond `select.mdk`'s resolver seam. Every table in the oracle
  corpus (and the overwhelmingly common real-world case) has an IPK, so the
  supported path covers the required behaviour.
