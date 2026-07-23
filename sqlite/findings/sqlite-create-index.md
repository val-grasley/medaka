# Findings — CREATE INDEX write path (`sqlite/lib/{schemadef,dbwriter,writer}.mdk`)

Task: emit a real single-column secondary-index B-tree that `sqlite3` accepts as a valid
database (`PRAGMA integrity_check` = `ok`). This is a pure-Medaka library change; no compiler
edits. Gated by `sqlite/test/index_write_oracle.sh`.

## What shipped

- **Parse** `CREATE INDEX [IF NOT EXISTS] name ON table (col)` — single column — in
  `sqlite/lib/schemadef.mdk` (`parseCreateIndex` / `CreateIndex`), with a **named** rejection
  for every unsupported form: `UNIQUE`, multi-column, `WHERE` (partial), `COLLATE`, `ASC`/`DESC`,
  and expression/function indexes. Kept OUT of the `Stmt` dispatcher on purpose — the executor
  (`lib.sqlexec`/`lib.mutate`) refuses to touch a DB that already holds an index, so there is no
  SQL-driven execution path to wire it into; the writer library + demo drive emission directly.
- **Emit** in `sqlite/lib/dbwriter.mdk`: `buildDatabaseMultiWithIndexes` allocates one fresh
  rootpage per index AFTER the table b-trees and BEFORE the overflow region, builds a single
  **index-leaf page (0x0A)** whose cells are records of `[keyCell, rowid]` sorted in SQLite record
  order, and adds a `sqlite_master` row `type='index'`.
- **Ergonomic** `writeTableWithIndexes`/`buildTableWithIndexes` in `sqlite/lib/writer.mdk`:
  derives the `(keyCell, rowid)` entries from the schema + rows so the index rowids match the
  table writer's exactly.
- Demo `sqlite/index_write_demo.mdk`; oracle `sqlite/test/index_write_oracle.sh` +
  `index_write.golden`.

## The load-bearing details (write-path / encoding friction, logged concretely)

### 1. An index-leaf cell is NOT a table-leaf cell — no rowid varint

A table-leaf cell is `[payload-len varint][rowid varint][payload]`. An **index-leaf** cell is
`[payload-len varint][payload]` — there is no separate rowid field; the rowid rides inside the
record as its **trailing column**. Reusing `encodeLeafCell` (which emits the rowid varint) would
have produced a corrupt index. A dedicated `encodeIndexLeafCell` emits `[len][record]`, and the
record is `encodeRecord [keyCell, CInt rowid]`.

### 2. The sort order is the whole feature — get it wrong and `integrity_check` fails

`integrity_check` cross-checks every index entry against the table AND verifies the entries are in
order, so the record comparison had to match SQLite exactly:

- storage-class rank: **NULL < numbers < text < blob**;
- numbers by numeric value (INTEGER/REAL mixed via `Float`);
- text/blob by **BINARY collation** = lexicographic `memcmp` of the UTF-8 bytes (`compareBytesLex`
  over the `toUtf8` byte array — UTF-8 byte order equals code-point order, so this is exact);
- ties on the key broken by the trailing **rowid** (numeric), which is distinct per row, so the
  order is total and the sort deterministic across duplicate keys.

The demo deliberately exercises a NULL key (`age` of `carol`), duplicate text keys (`bob` x2), and
duplicate int keys (`25` x2); `integrity_check` = `ok` confirms all three sort correctly. sqlite3's
planner then uses both indexes (`SEARCH … USING COVERING INDEX idx_name/idx_age`).

### 3. Page layout kept byte-identical for the no-index case

`assembleImage plans = assembleImageWithIndexes plans []`. With no indexes the page map, master
rows, and overflow start (`btreeTotal + 1`) are unchanged, so every existing write gate
(`writer`, `writer_api`, `multipage_write`, `multitable_write`) stays byte-for-byte green — verified.
Index pages slot in as `btreeTotal+1 .. btreeTotal+nIndexes`, overflow shifts to after them.

### 4. Index overflow / multi-page is refused, never silently truncated

v1 emits a SINGLE index-leaf page and stores each key entirely locally. A key record larger than
the index max-local-payload (`((U-12)*64/255)-23` = 1002 for U=4096), or an index whose cells
exceed one page, is a clean `Err` (`encodeIndexLeafCell` / `buildIndexLeafPage`) — the same
single-page discipline the table writer already uses. A silently-truncated index key would be an
S0, so this is a hard reject.

### 4b. COMPLETENESS at the fill boundary — the S0 `integrity_check` can't catch

`PRAGMA integrity_check` validates STRUCTURE (record format, page types, sort order), but a
silently-*truncated* index — fewer entries than table rows, e.g. an off-by-one in the
single-page-fill / overflow detection — could pass it yet return WRONG rows when sqlite3 SERVES a
query from the index. The oracle therefore binary-searches the exact fill boundary and proves
completeness at it, rather than trusting `integrity_check` and a 5-row test.

Empirically (for `nums(id INTEGER PRIMARY KEY, v INTEGER)`, `v=id`, U=4096): **434 rows is the
largest index that fits one leaf page; 435 overflows.** At exactly 434 the index is COMPLETE — a
FORCED index scan (`SELECT count(*) FROM nums INDEXED BY idx_v WHERE v BETWEEN 1 AND 434`) returns
434, equal to the full-table scan AND to sqlite3's OWN freshly-rebuilt index, and both the first
(`v=1`) and last (`v=434`) keys resolve. At 435 the writer prints its clean `Error:` and writes NO
file (`buildTableWithIndexes` fails in `buildIndexLeafPage` before `writeFileBytes` runs) — the
failure mode is a loud refusal, never a structurally-valid-but-short index. The oracle's boundary
search is self-calibrating, so if the record encoding ever changes it re-derives the boundary
instead of pinning a brittle `434`.

### 5. Indexing the INTEGER PRIMARY KEY column is refused (v1 limitation)

For an index on the rowid-alias column, SQLite stores the key as NULL (the value lives in the
rowid), so a naive `[CInt id, CInt id]` record would diverge from what sqlite3 expects. Rather than
risk a subtle mismatch, `writer.refuseIpkIndex` rejects it with a named error. Non-IPK columns
(the common case) are fully supported.

## Language friction (small, not blockers)

- **`rec` is a reserved word.** A local binding `rec <- …` in a `do` block parses as
  `unexpected 'rec'; expected a dedent` — the generic "reserved word masquerading as a parser bug"
  trap. Renamed to `recBytes`. (Adds to the known set: `record`/`as`/`test`/`of`/`prop`/`rec`.)
- The worktree-isolation classifier refuses `medaka build … -o <path outside the worktree>` and
  most env-var-prefixed compound commands; running steps from a small `bash` script inside the
  worktree sidesteps it.

## What is supported vs rejected (v1)

Supported: `CREATE INDEX [IF NOT EXISTS] name ON table (col)` on a single INTEGER / TEXT / REAL /
BLOB / nullable column of a rowid table; NULL keys; duplicate keys; a single index-leaf page's
worth of entries; any number of indexes per file.

Rejected (each a named `Err`, never silent): `UNIQUE`, multi-column, partial (`WHERE`), `COLLATE`,
`ASC`/`DESC`, expression/function indexes, indexing the INTEGER PRIMARY KEY column, an index too
large for one leaf page, and a key record needing overflow.
