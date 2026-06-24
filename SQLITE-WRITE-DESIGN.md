# SQLite WRITE path — design (v1)

Companion to `SQLITE-DESIGN.md` (the read path). The pure-Medaka `sqlite/` library
gains the ability to **generate** a real `.sqlite` file that `sqlite3` can query.
Scope locked 2026-06-24 (user-confirmed). Format map verified against a real
`sqlite3`-created DB.

## v1 scope (forks DECIDED)

- **(a) Build a fresh DB from scratch** — NOT mutate an existing file. We control the
  whole layout; no freelist/change-counter/existing-page bookkeeping; splits avoided by
  construction. This is the "generate a `.db`" use case.
- **(b) `CREATE TABLE` + multi-row `INSERT`.** No `UPDATE`/`DELETE` (need in-place
  mutation + free-space/splits — deferred).
- **(c) Single leaf page per table.** When a table's cells+pointers exceed one page
  (~`pageSize-8` ≈ 4080 B), the writer returns a clean `Err` ("multi-page not supported
  in v1") — it MUST detect overflow, never silently corrupt. The B-tree page
  **split/rebalance** core (interior pages, redistribution, balance_deeper, freelist) is
  the genuinely hard part and is deferred. A "valid-but-unbalanced multi-page" writer
  (chain leaves under one interior page; `integrity_check` accepts any structurally-valid
  tree) is the natural NEXT phase; full balancing is later.
- **(d) Non-durable, single-writer.** Build the whole file in memory, `writeFileBytes`
  truncate-write once. No rollback journal / WAL / fsync ordering. A crash mid-write can
  corrupt — acceptable for fresh-DB generation, NOT for concurrent/in-place mutation.
- **(e) Byte builder lives in `byteparser/lib/bytebuilder.mdk`** (the symmetric inverse of
  the parser; reusable; round-trip tests live with the decoders).
- **(f1) No floats in v1** — `CFloat` round-trip needs a `floatToBytes64` extern (another
  4-site + fixpoint + seed cycle). int/text/null/blob only; float = a later phase.
- **(f2) INTEGER PRIMARY KEY affinity is MANDATORY.** sqlite stores an IPK column as
  serial-0 NULL with the value in the cell's rowid varint. The encoder must mirror this
  from P2 (reuse `pkColumnIndex` in `sqlite.mdk`).
- **(f3) Page size hardcoded 4096** (sqlite modern default; what the read path handles).

## Foundation gaps

- **`writeFileBytes` does NOT exist.** `writeFile` is String-only (not byte-clean — same
  reason reads needed `readFileBytes`). Add `writeFileBytes : String -> Array Int ->
  <FileWrite> Result String Unit`, mirroring `readFileBytes` (commit `1b25c9b`) across the
  4 sites below. IN the emitter graph → fixpoint + seed re-mint + OCaml-oracle parity.
- **Byte builder gap is total** (`byteparser` is decode-only). No `arrayConcat`/`arrayAppend`
  extern. Build on `stdlib/mut_array.mdk` (`MutArray`, amortized-O(1) `push`, `toArray`).

## Byte-perfect format map (what an encoder must EMIT)

Verified vs a fresh `sqlite3` DB (`CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, age
INTEGER)` + rows; page size 4096).

### 100-byte file header (invert `header.mdk`)
- `0..15` magic `"SQLite format 3\0"`.
- `16` u16 page size = 4096 (`10 00`).
- `18` write ver = 1; `19` read ver = 1 (legacy rollback, not WAL).
- `20` reserved-per-page = 0; `21..23` payload fracs `40 20 20` (max64/min32/leaf32).
- `24` u32 **change counter** = 1 for a fresh DB.
- `28` u32 **page count** (total pages).
- `32` u32 freelist trunk = 0; `36` u32 freelist count = 0.
- `40` u32 schema cookie = 1; `44` u32 schema format = 4; `48` u32 default cache = 0.
- `52` u32 largest-root (autovacuum) = 0; `56` u32 text encoding = 1 (UTF-8).
- `60..91` user-version/inc-vacuum/app-id/reserved = 0.
- `92` u32 version-valid-for = change counter (1); `96` u32 sqlite version number =
  a valid constant (e.g. `3046000`; `integrity_check` ignores it).

### Table-leaf page (invert `btree.mdk`) — `pageSize` bytes, zero-filled
- **8-byte page header** at page offset 0 (**page 1's header starts at file offset 100**):
  `0` type `0x0D` (table leaf) · `1` u16 first-freeblock = 0 · `3` u16 **cell count N** ·
  `5` u16 **cell-content-area start** (lowest cell offset; 0 ⇒ 65536) · `7` frag-free = 0.
- **Cell-pointer array** right after the header: N × u16 page-relative cell offsets,
  **sorted by rowid ascending** (cells are packed back-to-front, pointers in key order).
- **Cell content area** grows DOWN from page end. Leaf cell =
  `[payload-len varint][rowid varint][record bytes]`.

### Record (invert `recordfmt.mdk`)
`[header-len varint][serial-type varint × cols][body]`. header-len counts itself.
Inverse of `serialOf`: NULL→0; int→smallest of {1,2,3,4,6} by magnitude (8/9 for literal
0/1); float→7 (deferred); text(len)→`2*len+13`; blob(len)→`2*len+12`. **IPK column →
serial 0 (NULL)**, value in the rowid.

### `sqlite_master` row (page 1 leaf) — one per table
5 cols `(type, name, tbl_name, rootpage, sql)`: `"table"`, name, name, the table's root
page number (int), the exact `CREATE TABLE …` text.

## Phased slice plan (each independently `sqlite3`-verifiable)

- **P0 — `writeFileBytes` extern. ✅ DONE (`a97e34b`, re-minted `29d7a9d`, cold-bootstrap PASS).**
  5 sites (the 4 below + `selfhost/backend/llvm_preamble.mdk` `declare`). Native build == oracle byte-identical.
  Original P0 detail: 4 sites (`stdlib/runtime.mdk` declare; `lib/eval.ml`
  VPrim oracle; `runtime/medaka_rt.c` `mdk_write_file_bytes` — untag `(arr[i+1]>>1)`, `"wb"`;
  `selfhost/backend/llvm_emit.mdk` register + `emitFileExtern` arm). Fixpoint + seed re-mint +
  oracle parity. Verify: write `[72,73]` → `xxd` shows `48 49`.
- **P1 — byte builder ✅ DONE (`75ccf95`).** `byteparser/lib/bytebuilder.mdk` — `emitU8/U16BE/U24BE/U32BE/Bytes/SqVarint/BeSint` + `buildArray`; 33/33 round-trip doctests vs the byteparser decoders. **Builder is backed by `Ref (List Int)`** (O(1) prepend + reverse-on-build), NOT `MutArray` as originally sketched: P1 surfaced a compiler finding — **`arrayBlit` is missing from the native interpreter's primitives table** (`selfhost/eval/eval.mdk`; present in `lib/eval.ml` + the build path), so `MutArray.push` panics `unbound identifier: arrayBlit` under native `run`/`test` (works under `build` + oracle — a run-vs-build gap). Fix = add an `arrayBlit` entry to `selfhost/eval/eval.mdk` (analogous to `arrayCopy` :1789). FIXED `ecd2eee` (added arrayBlit + arraySetUnsafe to the native interp primitives table). The Ref-List builder needs no MutArray so the write path is unblocked.
- **P1 — (original sketch)** byte builder `byteparser/lib/bytebuilder.mdk` (`MutArray Int`-backed):
  `emitU8/U16BE/U24BE/U32BE/Bytes/SqVarint/BeSint`, `buildArray`. Differentially test each
  `emit*` against its `byteparser` decoder (`emitSqVarint`↔`sqVarint`, `emitU32BE`↔`beUint 4`).
- **P2 — record encoder ✅ DONE (`c4b9731`).** `sqlite/lib/recordenc.mdk` `encodeRecord : List Cell -> Result String (Array Int)` (inverse of `parseRecord`; serial selection incl. 8/9; header-len self-counting; IPK-as-NULL; `CFloat`→`Err`). 7/7 round-trip doctests + the captured real bytes `[4,0,17,1,66,111,25]`. **Self-contained byte emission** (does NOT use `bytebuilder`) because P2 surfaced **F1** (loader): a dependency module's intra-package imports aren't rebased to the dep root, so `byteparser.lib.bytebuilder` (which imports its sibling `byteparser`) is unusable cross-package (`unknown module: lib.byteparser`). **F1 fix IN PROGRESS** (loader, user-chosen). Also surfaced **F2** (pre-existing, tracked): `medaka test` panics on a doctest returning a no-`Debug` type — convention workaround is `showCells`/`roundTripShow`.
- **P2 — (original sketch)** record encoder `sqlite/lib/recordenc.mdk`: `encodeRecord : List Cell -> Array Int`
  (inverse of `parseRecord`, incl. IPK-as-NULL). Verify by self round-trip through
  `parseRecord` + against captured real-DB record bytes.
- **P3 — single-leaf-page DB writer** `sqlite/lib/dbwriter.mdk`: header + page-1
  `sqlite_master` leaf + page-N table leaf; `writeFileBytes`. Verify: `PRAGMA
  integrity_check`=ok, `SELECT` matches, the Medaka reader re-reads the same rows.
- **P4 — `CREATE TABLE` + multi-row `INSERT` API** within one page (compute IPK/rowid;
  `Err` on overflow). Verify across schemas.

**Deferred:** floats (P5, needs `floatToBytes64` extern); page splits / multi-page;
`UPDATE`/`DELETE`; overflow pages; transactions/journal/WAL; concurrency/locking.

## Verification strategy (per slice, on the compiled binary)

1. `sqlite3 out.db "PRAGMA integrity_check;"` = `ok` (strongest single gate).
2. Round-trip OUT: `sqlite3 out.db "SELECT * … ORDER BY rowid;"` matches intended rows.
3. Round-trip SELF: open `out.db` with the existing `sqlite/` reader (`scanTableRowsIpk`),
   confirm it decodes the same rows — proves the writer is the exact inverse of the trusted
   reader; disagreement with (2) triangulates writer-vs-reader.
Goldens must strip absolute build paths (MEMORY footgun).

## Implementation pointers
- `readFileBytes` wiring (the P0 template): `stdlib/runtime.mdk:35`, `lib/eval.ml:1391`,
  `runtime/medaka_rt.c:714`, `selfhost/backend/llvm_emit.mdk:1692/1718` (commit `1b25c9b`).
- Readers to invert: `sqlite/lib/{header,btree,recordfmt}.mdk`; IPK locator
  `pkColumnIndex` in `sqlite/lib/sqlite.mdk`. Buffer: `stdlib/mut_array.mdk`.
