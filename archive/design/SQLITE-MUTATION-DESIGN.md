# SQLite Mutation (UPDATE / DELETE) — Design & Feasibility

**Status:** IMPLEMENTED — `a0fb00d`, 2026-06-30. See the AS-BUILT section at the
end of this file; `sqlite/lib/mutate.mdk` implements INSERT/UPDATE/DELETE via
read-transform-rewrite exactly as designed.

Status: **DESIGN / SCOPING** (2026-06-30). No library code written. This doc
records an empirical feasibility study of adding row mutation (UPDATE / DELETE)
to the pure-Medaka SQLite library under `sqlite/`, and proposes a v1.

The candidate approach is **read-transform-rewrite**: read every row of every
table via the read path (`lib/sqlite.mdk`), apply the DELETE filter / UPDATE map
to the target table, and rewrite the WHOLE `.db` from scratch via the write path
(`lib/dbwriter.mdk` `buildDatabaseMulti`). This sidesteps in-place b-tree page
mutation (freelist / page splits / merges) entirely.

`SQLITE-WRITE-DESIGN.md:162` already lists `UPDATE`/`DELETE` as **Deferred**.
This doc is that deferred item, scoped against what the read+write paths
actually round-trip today.

---

## 1. Empirical findings (probes run on the built native `medaka`)

All probes built real `.sqlite` files with the `sqlite3` CLI, read them back
with the Medaka reader, rewrote them with `buildDatabaseMulti` reusing the
**original stored CREATE SQL + `pkColumnIndex`**, and diffed against the source
with `sqlite3` (rows, rowids, `typeof`, `PRAGMA integrity_check`). Probe files
were temporary and have been deleted; the tree is clean.

### 1a. Round-trip fidelity — what an identity read→rewrite preserves

| Property | Result |
|---|---|
| Row count, per table | ✅ preserved |
| Column **values** | ✅ preserved |
| Column **types** (`typeof`) — INTEGER / TEXT / NULL / **REAL** / **BLOB** | ✅ preserved (REAL stays `real`, NULL `null`, blob bytes `x'deadbeef'` identical) |
| Multiple tables in one file | ✅ preserved (3 tables: IPK / non-IPK / REAL) |
| Stored **CREATE TABLE** text | ✅ **byte-identical** — because we reuse the *original* `schemaSql`, not regenerated text (key decision; see §3) |
| Large table → **multi-page interior b-tree** (600 rows, 5 pages) | ✅ round-trips identical, `integrity_check = ok` |
| **`PRAGMA integrity_check`** on the rewrite | ✅ `ok` in every case |
| **IPK-table rowids** (e.g. ids 1, 5, 9 — non-contiguous) | ✅ **preserved** |
| **non-IPK rowids with a gap** (kv rowids 1, **3**, **4** after a delete) | ❌ **RENUMBERED to 1, 2, 3** — the gap is lost |
| **Secondary indexes** (`CREATE INDEX`) | ❌ **silently DROPPED**, and `integrity_check` still returns `ok` |

The renumber, verbatim (source kv had rowids `1,3,4`; rewrite produced `1,2,3`):

```
## kv
< 3|three|3      (SRC)
< 4|four|4
---
> 2|three|3      (DST, rewritten)
> 3|four|4
```

### 1b. The rowid mechanism — the key unknown, resolved

The writer assigns rowids in `dbwriter.mdk`:

```
rowidFor : Option Int -> Int -> List Cell -> Result String Int
rowidFor None     autoRowid _     = Ok autoRowid          -- non-IPK: auto 1..N
rowidFor (Some p) _         cells = <the CInt value at column p>   -- IPK: the key
```

and `encodeRows` threads `autoRowid + 1` per row (`dbwriter.mdk:328-365`).

Consequences:

- **IPK tables are rowid-faithful for free.** The rowid *is* the IPK column
  value. The reader hands it back via `rowCellsWithIpk` (substitutes the rowid
  into the IPK column position), and the writer reads it back out of that
  column. Surviving rows after a DELETE keep their identity. ✅
- **Non-IPK tables are NOT rowid-faithful.** `rowidFor None` **ignores any input
  rowid** and assigns `autoRowid` = 1..N. There is currently **no way to supply
  an explicit rowid**. A DELETE on a non-IPK table inherently produces gaps, and
  the rewrite renumbers the survivors. This is the single hard blocker to a
  fully faithful v1, and it lives entirely in the **library** (no compiler
  change).

### 1c. WHERE reuse — confirmed

The existing typed-query path (`lib/select.mdk` `query`) already does exactly
what mutation needs:

```
entry  <- findTable db tbl                       -- lib/sqlite.mdk
lookup  = columnIndex (schemaSql entry)          -- name -> Option Int  (exported)
pred   <- compilePred lookup whereExpr           -- List Cell -> Bool   (exported)
(pkIdx, rows) <- scanTableRowsIpk db tbl
kept    = filter (r => pred (rowCellsWithIpk pkIdx r)) rows
```

Crucially the predicate runs over **`rowCellsWithIpk`** (IPK substituted), so a
`WHERE id = 5` on an IPK table compares against the real rowid, not the stored
`CNull`. Every piece is already `export`ed: `compilePred`, `columnIndex`,
`findTable`, `schemaSql`, `scanTableRowsIpk`, `rowCellsWithIpk`, `pkColumnIndex`,
and `buildDatabaseMulti`. DELETE = keep `not (pred cells)`; UPDATE = map a SET
over `pred`-matching `cells`.

### 1d. What a `.db` must NOT contain for a safe read-rewrite

Inherited limits from the read+write paths (`SQLITE-DESIGN.md`,
`SQLITE-WRITE-DESIGN.md:160-162`). A mutation that rewrites the whole file
inherits **all** of them:

| Shape | Read path | Write path | Mutation must |
|---|---|---|---|
| WAL mode (read ver 2) | clean `Err` | — | inherit reader `Err` ✅ |
| Overflow payload (row/cell > ~one page) | `Err "overflow payload not supported"` | `Err "row too large…"` | inherit `Err` ✅ |
| `sqlite_master` > 1 leaf page (≳ tens of tables) | ok to read | `Err "sqlite_master overflow…"` | inherit writer `Err` ✅ |
| Multi-**interior** trees (≳ tens of thousands of rows) | ok | `Err` (one interior page only) | inherit writer `Err` ✅ |
| **Secondary indexes** (`type='index'`) | read but ignored | **not written** | ⚠️ **NEW hazard — must detect + refuse**, see below |
| WITHOUT ROWID tables | out of scope | out of scope | should `Err` (not yet detected) |
| AUTOINCREMENT (`sqlite_sequence` table) | reads as a normal table | would be rewritten as a normal table | acceptable but loses the high-water mark; note |

**The index hazard is the dangerous one** because `integrity_check` does NOT
catch it: dropping an index leaves an internally-consistent database, so the
strongest existing gate stays green while the rewrite silently discards every
index. Mutation v1 **must** scan `readSchema` for any `schemaType == "index"`
on the target file and return a clean `Err` (e.g.
`"cannot mutate: table has indexes (would be dropped); not supported in v1"`)
rather than relying on `integrity_check`.

### 1e. Compiler soak note

No compiler run≠build bug surfaced. The only friction was a correct type error
(`Function 'main' declared with <IO> but also performs <Mut>`) — `buildDatabaseMulti`
carries `<Mut>`, so callers need `<IO, Mut, FileRead, FileWrite>`. That is
expected effect-row behavior, not a bug. Both probes compiled and ran
identically built (`medaka build`) — no run-vs-build divergence observed.

---

## 2. Recommended approach

**Read-transform-rewrite — validated.** The probes confirm it produces
`integrity_check`-clean, value-and-type-faithful, schema-text-identical
databases, including multi-table and multi-page b-trees. In-place b-tree
mutation (freelist management, page split/merge) is correctly deferred — it is
the genuinely hard part and buys nothing for a tool that already rewrites whole
files elsewhere.

**Two honest caveats that must drive the scope decision:**

1. **Rowid faithfulness is split by table kind.** IPK tables: faithful for free.
   Non-IPK tables: **renumbered** unless the writer is extended to accept
   explicit rowids (a small, pure-library change — §5 stage 3). Until then, v1
   on a non-IPK table *renumbers surviving rows' rowids*. That is acceptable
   only for tables with no external rowid references; it is **wrong** for any
   schema that joins on / stores an implicit rowid.

2. **Indexes are dropped.** Must be refused with a clean `Err` (not silently
   rewritten), because `integrity_check` won't flag it.

---

## 3. Proposed API

New module `sqlite/lib/mutate.mdk`, built entirely on exported read/write
symbols (no edits to existing modules for stages 1–2):

```medaka
-- Reuse lib.select's SqlExpr/Expr for WHERE. A SET assignment is a column
-- name plus a literal value (v1: literals only — see fork (c)).
public export data Assign = Assign String Literal     -- column := literal

-- DELETE rows matching `where_` from `table`, rewriting `path` in place.
export
delete : String -> String -> Expr Bool
       -> <FileRead, FileWrite, Mut> Result String Int     -- Ok = #rows deleted

-- UPDATE rows matching `where_`, applying every `Assign`, rewriting `path`.
export
update : String -> String -> List Assign -> Expr Bool
       -> <FileRead, FileWrite, Mut> Result String Int     -- Ok = #rows updated
```

Internal pipeline (shared by both):

```
db      <- openDb path
schema  <- readSchema db
_       <- refuseIfIndexed schema            -- §1d index hazard → clean Err
specs   <- for each table entry:
             (pkIdx, rows) <- scanTableRowsIpk db name
             cells          = map (rowCellsWithIpk pkIdx) rows
             cells'         = if name == target
                              then transform cells        -- delete: filter; update: map
                              else cells                  -- untouched tables pass through verbatim
             (name, schemaSql entry, pkIdx, cells')
img     <- buildDatabaseMulti specs
writeFileBytes path img
```

- **Multi-table handling:** every table is read and rewritten; only the target
  table's rows are transformed. Untouched tables pass through their original
  cells + original `schemaSql` + original `pkColumnIndex`, so they are
  byte-faithful (proven in §1a) — except their non-IPK rowids renumber if they
  already had gaps (a pre-existing condition, not introduced by the mutation,
  but still a v1 caveat — see fork (d)).
- **WHERE:** `Expr Bool` from `lib.select` → `unExpr` → `compilePred (columnIndex
  (schemaSql entry))`. Predicate evaluated over `rowCellsWithIpk` cells, so IPK
  and ordinary columns both work.
- **SET (`Assign`):** resolve the column index via `columnIndex`; replace that
  cell with the literal (mapped `Literal -> Cell`). Reject an assignment to the
  IPK column in v1 (changing a rowid is a delete+insert; out of scope) → clean
  `Err`.
- Atomic-ish write: `buildDatabaseMulti` builds the whole image in memory, then
  one `writeFileBytes`. (No journal/WAL — matches the existing writer's
  truncate-write contract; a crash mid-write can corrupt, already documented.)

---

## 4. Scope forks — need a human decision

- **(a) read-rewrite-all vs in-place.** Recommend **read-rewrite-all** for v1
  (validated; in-place is a much larger b-tree project). Confirm.
- **(b) single-table vs multi-table mutation.** The rewrite touches all tables
  regardless; "single-table mutation" just means one `target` per call. Recommend
  **one target table per `delete`/`update` call** (simplest, matches SQL). Confirm.
- **(c) UPDATE SET = literals only vs expressions.** Recommend **literals only**
  in v1 (`Assign String Literal`). Column-to-column / arithmetic SET (`x = x+1`)
  needs an evaluator over cells — a clean later extension. Confirm literals-only.
- **(d) rowid-faithful vs renumber.** The decision point. Options:
  - **(d1)** v1 **renumbers** non-IPK rowids; document loudly; restrict honest
    use to IPK tables + non-IPK tables without external rowid refs. *No writer
    change.* Ship faster.
  - **(d2)** Do the **writer change** (§5 stage 3) so non-IPK mutations preserve
    rowids. Pure-library, ~localized, but re-touches `dbwriter.mdk` +
    `writer.mdk`/`buildDatabaseMulti` signature. Recommended if non-IPK
    faithfulness matters at all. **My recommendation: (d2), staged after a
    working (d1) DELETE/UPDATE**, so each stage is independently verifiable.
- **(e) unsupported shapes → clean `Err`.** Recommend refusing (clean `Err`,
  never silent corruption) on: any `type='index'` entry (§1d, the must-fix),
  WITHOUT ROWID tables, WAL/overflow/multi-interior (inherited from read/write
  `Err`s), and a SET targeting the IPK column. Confirm the index refusal in
  particular (since `integrity_check` won't catch a silent drop).

---

## 5. Staged plan (each stage independently `sqlite3`-verifiable)

All stages are **pure-library** (new `sqlite/lib/mutate.mdk` + at most a writer
signature extension) — **no compiler change → no seed re-mint → no fixpoint
re-validation.** Verification is the `sqlite3`-CLI oracle pattern only.

| Stage | Work | Touches | Model |
|---|---|---|---|
| **0** | Index/unsupported-shape **refusal guard** (`refuseIfIndexed`, WITHOUT ROWID, IPK-SET) | new `mutate.mdk` | Sonnet |
| **1** | **DELETE** = read-all → filter target by `not (compilePred …)` → `buildDatabaseMulti` → write. IPK-faithful; non-IPK renumbers (caveat). | new `mutate.mdk` only (all deps exported) | Sonnet |
| **2** | **UPDATE** = same pipeline, map `Assign`s over matching rows (literals only, reject IPK-col SET). | `mutate.mdk` | Sonnet |
| **3** | *(if fork (d2))* **rowid-faithful writer**: extend `dbwriter` to accept explicit rowids per row (e.g. new spec variant `(name, sql, ipk, List (Int, List Cell))`, or `rowidFor` taking `Option explicitRowid`), then thread real rowids through `mutate`. Removes the non-IPK renumber. | `dbwriter.mdk` + `writer.mdk` + `mutate.mdk` | **Opus** (changes the byte-level rowid path; needs care that IPK path is unchanged and existing write oracles stay green) |
| **4** | *(optional)* expression SET (fork (c) = no) / multi-target — deferred. | — | Opus |

Stages 0-2 deliver a working, honestly-scoped DELETE/UPDATE. Stage 3 upgrades
non-IPK faithfulness. Sonnet is fine for 0-2 (composition over exported APIs);
Opus for stage 3 (byte-level writer change with a re-mint-free but
oracle-sensitive surface).

---

## 6. Verification strategy

Mirror the existing `sqlite/test/*_oracle.sh` pattern (e.g.
`multitable_write_oracle.sh`). Per mutation oracle:

1. **Seed** a db with `sqlite3` (`CREATE TABLE … INSERT …`), covering an IPK
   table and a non-IPK table.
2. **Mutate** with our library (build a small demo `.mdk` like the existing
   `*_demo.mdk`, e.g. `delete users WHERE age IS NULL`).
3. **Verify with `sqlite3`:**
   - `PRAGMA integrity_check` == `ok` (strongest structural gate).
   - `SELECT rowid,* FROM <t> ORDER BY rowid` matches the *expected post-mutation*
     state (computed by running the same DELETE/UPDATE in `sqlite3` on a copy).
   - For IPK tables, assert **rowids unchanged**; for non-IPK, assert against the
     documented v1 behavior (renumbered for d1; preserved for d2).
   - Reader self-round-trip gate (our `main.mdk` reader re-reads every table).
4. **Negative gates:** a db WITH an index → assert our library returns the clean
   `Err` (and does NOT write a silently-de-indexed file).

---

## Appendix — key source references

- `sqlite/lib/dbwriter.mdk:328-365` — `rowidFor` / `encodeRows` (the rowid
  auto-assign; the §5 stage-3 change site).
- `sqlite/lib/dbwriter.mdk:496` — `buildDatabaseMulti` (the rewrite entry; takes
  `List (name, createSql, ipkColIdx, rows)`).
- `sqlite/lib/sqlite.mdk:159` `scanTableRowsIpk`, `:177` `pkColumnIndex`,
  `:219` `columnIndex`, `:328` `rowCellsWithIpk`, `:98` `readSchema` — read-side
  reuse.
- `sqlite/lib/select.mdk:326` `compilePred`, `:447` `query` (the WHERE pipeline
  to mirror; `filterRows` runs the predicate over `rowCellsWithIpk`).
- `SQLITE-WRITE-DESIGN.md:160-162` — deferred list incl. UPDATE/DELETE and the
  inherited write limits.

---

## LOCKED SCOPE (orchestrator + user decision, 2026-06-30)

**v1 = full rowid-faithful UPDATE/DELETE via read-transform-rewrite.** Fork answers:
- (a) **read-rewrite-all** for v1 (in-place b-tree mutation deferred).
- (b) **one target table per call**.
- (c) **SET = literals only** (`Assign = Assign String Literal`); expressions deferred.
- (d) **rowid-FAITHFUL** (user chose full-faithful) — the byte-level `dbwriter` change to accept explicit rowids is IN scope, and lands FIRST as the foundation so DELETE/UPDATE are faithful from their first landing (no temporary renumbering behavior to later rework).
- (e) **refuse with a clean `Err`** any `.db` we can't faithfully rewrite: tables with a secondary **index** (silently dropped today + `integrity_check` still ok → the gate won't catch it), **WITHOUT ROWID** tables, and an UPDATE that SETs the **IPK column** (would move the rowid). Never silent corruption.

**Staged plan (reordered: writer-change first; all pure-library `sqlite/` → NO seed re-mint / fixpoint; gate = `sqlite3`-CLI oracles mirroring `sqlite/test/multitable_write_oracle.sh`):**
1. **Rowid-faithful writer** (`dbwriter.mdk` + `writer.mdk`) — extend the writer to accept an explicit rowid per row (`rowidFor`/`encodeRows` at `dbwriter.mdk:328-365` currently ignore input rowid for non-IPK → assign 1..N). Keep the IPK path byte-identical; all existing write oracles stay green. **Opus.** Gate: a round-trip oracle where a non-IPK db with a rowid GAP (e.g. 1,3,4) rewrites preserving the gap (today it collapses to 1,2,3), plus existing write oracles unchanged.
2. **DELETE** + the refusal guard (e) — new `sqlite/lib/mutate.mdk` `delete : path -> table -> Expr Bool -> Result Int` reusing `compilePred`/`rowCellsWithIpk`; read all tables, filter the target, rewrite faithfully. **Sonnet.** Gate: `sqlite3` oracle (seed db → delete → assert survivors + preserved rowids + `integrity_check` ok) + a NEGATIVE gate (indexed db → clean `Err`).
3. **UPDATE** — `update : path -> table -> List Assign -> Expr Bool -> Result Int` (map matching rows applying literal Assigns). **Sonnet.** Gate: `sqlite3` oracle.

Each stage independently `sqlite3`-verified + merged before the next. No compiler changes expected (pure-library); if a stage surfaces a compiler run≠build bug, STOP + report (soak win).

---

## AS-BUILT (shipped 2026-06-30, main `a0fb00d`)

All 3 stages landed as designed (full rowid-faithful, read-transform-rewrite), each `sqlite3`-CLI gated + merged; pure-library (no seed/fixpoint). No compiler bug surfaced.

- **Stage 1 — rowid-faithful writer (`d8cebbd`):** additive explicit-rowid path in `dbwriter.mdk`/`writer.mdk` — `writeTablesExplicit`/`buildDatabaseMultiExplicit`/`encodeRowsExplicit` over `List (Int, List Cell)`; IPK + auto paths byte-identical. Gate: a non-IPK rowid GAP (1,3,4) now survives a round-trip (was collapsing to 1,2,3). `rowid_roundtrip_oracle.sh`.
- **Stage 2 — DELETE + refusal guard (`a76ed3a`):** new `sqlite/lib/mutate.mdk` `delete : String -> String -> Expr Bool -> Result Int`. `refuseIfUnsupported` returns a clean `Err` for any secondary index (silently dropped + `integrity_check` still ok → the guard is the only protection) or WITHOUT-ROWID table. Reuses `select.compilePred` for WHERE; rewrites via the explicit-rowid writer preserving survivors' rowids. `delete_oracle.sh` + `delete_negative_oracle.sh`.
- **Stage 3 — UPDATE (`a0fb00d`):** `update : String -> String -> List Assign -> Expr Bool -> Result Int` (`Assign = Assign String Literal`, literals only). Maps matching rows; refuses SET on the IPK column (`"cannot UPDATE the INTEGER PRIMARY KEY column"`). All rowids preserved. `update_oracle.sh`.

**Residuals (deferred, inherited from the write path):** in-place mutation (current is read-rewrite-all); indexes (refused, not maintained); WITHOUT-ROWID; SET expressions (literals only); the write path's own limits (overflow pages, multi-interior trees, full balancing, durability/WAL).
