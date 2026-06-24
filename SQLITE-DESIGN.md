# SQLite Read-Path Library — Design

**Status:** design document (2026-06-23). Authored as a capstone dogfood project for
the Medaka language. Foundation externs landed `1b25c9b`; read-path slices in progress.

---

## Goal & scope (locked decisions)

Build a **pure-Medaka, read-path SQLite library** — no C FFI, no external bindings.
The goal is to read a real `.sqlite` file, parse the B-tree, walk the schema, and
evaluate a `SELECT … WHERE` query returning typed Medaka values.

**Locked:**

- **Pure Medaka reimplementation.** Not FFI bindings.
- **Synchronous.** SQLite is inherently sync. A network SQL-server-in-front (async
  capstone) is a separate, future project — out of scope.
- **Read path first.** INSERT, WAL journal, rollback journal, write transactions:
  all deferred to a later phase. This doc covers Phase 1 (read) and designs Phase 2
  (query ADT) and Phase 3 (deriving).
- **In-memory.** No seek/random-access IO in v1: slurp the entire (small/medium) DB
  into one `Array Int` via `readFileBytes` and index in memory. This limits file size
  to available RAM; acceptable for the dogfood use case. A windowed/mmap path is a
  later optimisation.
- **Differential oracle:** the real `sqlite3` CLI. Generate a known `.db` with
  `sqlite3`, read it with the Medaka lib, diff row output — mirrors the project's
  reproduce-and-compare discipline.

**Out of scope (this doc):**
WAL mode reads (mode > 1 in file header), encrypted databases, without-rowid tables,
BLOB storage overflow chains > one page (document limit), the write path.

---

## Phasing

| Phase | What ships |
|-------|-----------|
| **0** | Foundation externs: `readFileBytes` + bitwise ops — **LANDED** `1b25c9b`, fixpoint C3a/C3b YES |
| **1** | ByteParser module + header parser + B-tree page/cell walker + record decoder + `sqlite_master` schema read + simple `SELECT … WHERE` executor + `RowType` marshalling |
| **2** | Typed query ADT (`Select`/`SqlExpr`/`Expr a` phantom) + `render` + injection-safe param binding |
| **3** | *(Optional)* `deriving RowType` for records |

---

## The foundation (Phase 0) — LANDED `1b25c9b`, fixpoint YES

**Status:** `readFileBytes` and all six bitwise externs are in the native runtime
and stdlib; the fixpoint self-compile confirms the change propagated correctly
(C3a/C3b PASS). Residual: `readFileBytes` is **not** available in the native
interpreter (`medaka run`) — the native interpreter has no file-IO surface. The
SQLite lib must be compiled with `medaka build` to exercise any code path that
reads a file; `medaka run` suffices only for pure unit tests and doctests.

### readFileBytes

```
-- extern (landed in 1b25c9b):
readFileBytes : String -> <FileRead> Result String (Array Int)
```

The return element type is `Int` (Medaka's 63-bit integer). Each byte is stored as
a non-negative value in `0..255`. This is the **only safe binary IO primitive** —
`readFile : String -> <FileRead> String` decodes bytes as UTF-8, which corrupts any
byte ≥ 0x80 (replaced by U+FFFD). All SQLite file access goes through `readFileBytes`.

### Bitwise externs

```
-- externs (landed in 1b25c9b):
bitAnd     : Int -> Int -> Int
bitOr      : Int -> Int -> Int
bitXor     : Int -> Int -> Int
shiftLeft  : Int -> Int -> Int   -- shiftLeft value bits
shiftRight : Int -> Int -> Int   -- arithmetic right shift
bitNot     : Int -> Int
```

These are needed for varint decoding, multi-byte integer assembly, and page type
extraction.

### The 63-bit limitation

Medaka's `Int` is 63 bits (OCaml/native tagged representation; max value `2^62 - 1`).
SQLite's 9-byte varint can encode values up to `2^63 - 1`. Values above `2^62 - 1`
are unrepresentable. In practice:

- **No real SQLite database has rowids or integer values exceeding `2^62`** —
  the row limit is far smaller. This is a theoretical edge case.
- Detection: if the 9th byte of a varint is ≥ 0x80 after accumulation, the value
  would overflow; report `Err "varint exceeds 63-bit Int"`.
- Document the limit; do not attempt bignum arithmetic.

---

## The SQLite on-disk format

Source: [SQLite File Format Specification](https://www.sqlite.org/fileformat2.html).

### 1. Database header (first 100 bytes of page 1)

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | 16 | Magic string | `"SQLite format 3\000"` (with NUL terminator) |
| 16 | 2 | Page size | Big-endian uint16; value `1` means 65536 |
| 18 | 1 | File format write version | 1=legacy journal, 2=WAL |
| 19 | 1 | File format read version | 1=legacy, 2=WAL |
| 20 | 1 | Reserved space per page | Usually 0; space at end of each page reserved for extensions |
| 21 | 1 | Max embedded payload fraction | Must be 64 |
| 22 | 1 | Min embedded payload fraction | Must be 32 |
| 23 | 1 | Leaf payload fraction | Must be 32 |
| 24 | 4 | File change counter | Big-endian uint32 |
| 28 | 4 | Database page count | Big-endian uint32 (0 = use file size) |
| 32 | 4 | First trunk page of freelist | Big-endian uint32 (0 = none) |
| 36 | 4 | Total freelist pages | Big-endian uint32 |
| 40 | 4 | Schema cookie | Big-endian uint32; incremented on schema change |
| 44 | 4 | Schema format number | 1, 2, 3, or 4 |
| 48 | 4 | Default page cache size | Big-endian uint32 |
| 52 | 4 | Largest root B-tree page (for auto-vacuum) | 0 if not auto-vacuum |
| 56 | 4 | Text encoding | 1=UTF-8, 2=UTF-16LE, 3=UTF-16BE |
| 60 | 4 | User version | Application-defined; read-only concern |
| 64 | 4 | Incremental vacuum mode | 0=full vacuum, nonzero=incremental |
| 68 | 4 | Application ID | Application-defined 4-byte code |
| 72 | 20 | Reserved | Must be zero |
| 92 | 4 | Version-valid-for number | Page count source |
| 96 | 4 | SQLite version number | e.g. 3041000 for 3.41.0 |

**Fields we actually parse:** magic (0–15, validate), page size (16–17), read
version (19, reject WAL≠1 in Phase 1), reserved-per-page (20, add to header sizes),
text encoding (56, validate = 1 for UTF-8 or error), page count (28–31).

```
data DbHeader = DbHeader
  { pageSize    : Int    -- 512..65536, must be power of 2
  , pageCount   : Int    -- total pages in file
  , encoding    : Int    -- 1=UTF-8 (only supported value)
  , reserved    : Int    -- bytes reserved at end of each page (usually 0)
  , schemaCookie : Int
  , readVersion : Int    -- 1=ok, 2=WAL (error in Phase 1)
  }
```

### 2. B-tree page layout

Every page is exactly `pageSize` bytes. Pages are 1-indexed; page 1 is the root of
`sqlite_master`/`sqlite_schema` and also contains the 100-byte database header at
its start (so the B-tree page header for page 1 begins at byte offset 100, not 0).

**Page types** (first byte of the B-tree page header):

| Value | Meaning |
|-------|---------|
| `0x02` | Index interior page |
| `0x05` | Table interior page |
| `0x0A` | Index leaf page |
| `0x0D` | **Table leaf page** (primary target for Phase 1) |

**B-tree page header:**

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | Page type flag (see above) |
| 1 | 2 | Byte offset of first freeblock (0 = none) |
| 3 | 2 | Number of cells on this page |
| 5 | 2 | Start of cell content area (0 means 65536) |
| 7 | 1 | Fragmented free bytes in cell content area |
| 8 | 4 | Right-most pointer (interior pages only) |

Leaf page header = 8 bytes. Interior page header = 12 bytes.

**Cell pointer array:** immediately follows the page header. Contains `numCells`
big-endian uint16 values; each is a byte offset from the start of the page to the
cell content. To read cell `i`: look up `cellPointers[i]` and seek to that byte
offset within the page.

### 3. Cell formats

#### Table-leaf cell (page type `0x0D`)

```
[payload-length : varint] [rowid : varint] [payload : bytes]
```

- `payload-length`: total bytes of payload (the record), including any overflow.
  In Phase 1, we only support payloads that fit on one page (no overflow chains).
- `rowid`: the 64-bit signed rowid (INTEGER PRIMARY KEY). Non-negative in practice.
- `payload`: the record (see §4).

Overflow detection: if `payload-length > usablePageSize - 35` the payload spans
overflow pages. In Phase 1, return `Err "overflow payload not supported"`.

#### Table-interior cell (page type `0x05`)

```
[left-child-page : 4-byte big-endian int] [integer-key : varint]
```

These cells split the key space; `left-child-page` is the page number of the
subtree for keys ≤ `integer-key`. The right-most child is in the page header's
right-most pointer field.

#### Index cells (pages `0x02`, `0x0A`)

Out of scope for Phase 1 (we don't walk indexes to answer queries; we do full table
scans).

### 4. Record format

A record (payload) encodes a row. Format:

```
[header-length : varint] [serial-type-1 : varint] ... [serial-type-N : varint]
[value-1 : bytes] ... [value-N : bytes]
```

- `header-length` includes itself. So body starts at `record_start + header-length`.
- The serial types determine the column types AND their sizes. Serial types:

| Serial type | Meaning | Size (bytes) |
|-------------|---------|--------------|
| 0 | NULL | 0 |
| 1 | 8-bit signed int | 1 |
| 2 | 16-bit big-endian signed int | 2 |
| 3 | 24-bit big-endian signed int | 3 |
| 4 | 32-bit big-endian signed int | 4 |
| 5 | 48-bit big-endian signed int | 6 |
| 6 | 64-bit big-endian signed int | 8 |
| 7 | IEEE 754-2008 64-bit float (big-endian) | 8 |
| 8 | Integer 0 (no bytes in body) | 0 |
| 9 | Integer 1 (no bytes in body) | 0 |
| 10, 11 | Reserved / internal | — |
| ≥ 12 (even) | BLOB of `(N-12)/2` bytes | `(N-12)/2` |
| ≥ 13 (odd) | TEXT of `(N-13)/2` bytes (encoding per header) | `(N-13)/2` |

```
data SerialType
  = STNull
  | STInt8 | STInt16 | STInt24 | STInt32 | STInt48 | STInt64
  | STFloat
  | STIntZero | STIntOne
  | STBlob Int   -- byte length
  | STText Int   -- byte length (UTF-8 in practice)
```

### 5. Varint encoding

SQLite's variable-length integer format (Huffman-like, big-endian):

- 1 to 9 bytes.
- Bytes 1–8: the high bit is a **continuation flag** (1 = more bytes follow).
  The low 7 bits are payload.
- Byte 9 (if reached): all 8 bits are payload (no continuation; the spec forces a
  9th byte if the value needs it, carrying 8 data bits instead of 7).
- The value is the big-endian concatenation of payload bits.
- Signed interpretation: treat the assembled value as a signed two's-complement
  integer. For rowids this is signed; for record header lengths it is unsigned
  (positive by construction).

```
-- Decode a varint starting at byte offset `pos` in `bytes`.
-- Returns (value, bytesConsumed).
readVarint : Array Int -> Int -> Result String (Int, Int)
```

A 63-bit-cap check: if after 8 bytes the accumulator is non-zero and byte 9's high
4 bits would push the value past `2^62 - 1`, return `Err "varint exceeds 63-bit Int"`.
In practice this never happens with real databases.

### 6. sqlite_master / sqlite_schema

The root page (page 1) is the root of the `sqlite_master` table B-tree (in older
databases) or `sqlite_schema` (same thing, renamed in SQLite 3.33.0). It has this
fixed schema:

```sql
CREATE TABLE sqlite_master(
  type     text,
  name     text,
  tbl_name text,
  rootpage integer,
  sql      text
);
```

Columns in record order (0-indexed): type, name, tbl_name, rootpage, sql.

To find a user table named `"foo"`: scan all rows of `sqlite_master` where
`type = "table"` and `name = "foo"`, then `rootpage` is the 1-indexed page number
of that table's B-tree root.

The `sql` column holds the original `CREATE TABLE` SQL — we parse it lightly in
Phase 1 to extract column names and order (needed for `RowType` column matching).

---

## ByteParser plan

### Motivation

The existing `parsec/lib/parser.mdk` is hard-wired to `Array Char`:

```
data Parser a = Parser (Array Char -> Int -> PResult a)
```

Binary parsing needs `Array Int` (bytes). We need a **structurally parallel**
`ByteParser` module — a near-transcription with `Char` replaced by `Int` everywhere,
plus byte-specific primitives.

Estimated size: ~120 lines. No algorithmic changes from `parser.mdk`.

### Location

`byteparser/byte_parser.mdk` inside the standalone `byteparser/` library project
(its own `medaka.toml`, mirroring `parsec/`). Imported by `sqlite/` as a
cross-project dependency.

### ByteParser API

```
-- Result type (identical shape to PResult):
data BResult a = BOk a Int | BErr String Int

-- The parser type:
data ByteParser a = ByteParser (Array Int -> Int -> BResult a)

-- Run the wrapped function:
runBP : ByteParser a -> Array Int -> Int -> BResult a
runBP (ByteParser f) input pos = f input pos
```

**Typeclass instances** (same structure as `parser.mdk`):

```
impl Mappable ByteParser where ...
impl Applicative ByteParser where ...
impl Thenable ByteParser where ...
impl Alternative ByteParser where ...   -- left-biased, full backtracking
```

**Primitive combinators:**

```
-- Fail unconditionally:
bFailWith : String -> ByteParser a

-- Consume one byte satisfying predicate:
bSatisfy : (Int -> Bool) -> ByteParser Int

-- Consume any byte:
anyByte : ByteParser Int

-- Consume exactly this byte value:
byte : Int -> ByteParser Int
byte b = bSatisfy (x => x == b)

-- End of input:
bEof : ByteParser Unit

-- Zero-or-more:
bMany : ByteParser a -> ByteParser (List a)

-- One-or-more:
bSome : ByteParser a -> ByteParser (List a)

-- Separated-by:
bSepBy  : ByteParser a -> ByteParser b -> ByteParser (List a)
bSepBy1 : ByteParser a -> ByteParser b -> ByteParser (List a)

-- Optional:
bOptional : ByteParser a -> ByteParser (Option a)

-- Between:
bBetween : ByteParser open -> ByteParser close -> ByteParser a -> ByteParser a

-- First success:
bChoice : List (ByteParser a) -> ByteParser a

-- Read exactly N bytes, returning them as a List Int:
takeBytes : Int -> ByteParser (List Int)

-- Read exactly N bytes into an Array Int slice (for efficiency):
takeSlice : Int -> ByteParser (Array Int)

-- Peek at current byte without consuming:
peek : ByteParser Int
```

**Binary-specific primitives** (no equivalent in `parser.mdk`):

```
-- Read a big-endian unsigned integer of exactly N bytes (N in 1..8):
beUint : Int -> ByteParser Int

-- Read a big-endian signed integer of exactly N bytes (N in 1..8):
beSint : Int -> ByteParser Int

-- Read a SQLite varint (1-9 bytes). Returns (value, bytesConsumed):
sqVarint : ByteParser Int

-- Read a 64-bit IEEE 754 float (big-endian) as a Medaka Float:
beFloat64 : ByteParser Float
```

**Entry point:**

```
runByteParser : ByteParser a -> Array Int -> Result String a
runByteParser p bytes = match runBP p bytes 0
  BOk a _ => Ok a
  BErr m pos => Err "\{m} at byte \{pos}"
```

**What changes from `parser.mdk`:**

| `parser.mdk` | `byte_parser.mdk` |
|---|---|
| `Array Char` | `Array Int` |
| `satisfy : (Char -> Bool) -> Parser Char` | `bSatisfy : (Int -> Bool) -> ByteParser Int` |
| `char : Char -> Parser Char` | `byte : Int -> ByteParser Int` |
| `anyChar` | `anyByte` |
| `digit`/`letter`/`space` helpers | `beUint`/`beSint`/`sqVarint`/`beFloat64` |
| `string : String -> Parser String` | (no equivalent; use `takeBytes` + compare) |
| `spaces` whitespace skipper | (no equivalent; bytes don't have "whitespace") |
| `runParser : Parser a -> String -> Result String a` | `runByteParser : ByteParser a -> Array Int -> Result String a` |

Note: `manyGo`'s progress guard (`pos2 == pos => stop`) carries over unchanged —
a `bMany` of a zero-consuming parser must still terminate.

---

## SQL query API

### Phase 1: RowType — the no-GADT model

Medaka lacks GADTs, so we cannot write `data Col a = IntCol : Col Int | TextCol :
Col String`. The standard Caqti-style workaround: represent a row type as a
**first-class value carrying its decoder closure**. The phantom type parameter `a`
in `RowType a` is purely for Medaka's type checker at call sites — it is never
pattern-matched on the descriptor itself.

```
-- A cell is one column value from a decoded record:
data Cell
  = CNull
  | CInt   Int
  | CFloat Float
  | CText  String
  | CBlob  (Array Int)

-- A row decoder: given a list of cells (one per column), produce a Result:
data RowType a = RowType
  { width  : Int                          -- expected number of columns
  , decode : List Cell -> Result String a -- decoder closure
  }
```

**Primitive descriptors** (each closes over its decoder; no pattern match):

```
-- Single-column decoders:
tInt    : RowType Int
tFloat  : RowType Float
tText   : RowType String
tBool   : RowType Bool     -- stored as 0/1 Int
tBlob   : RowType (Array Int)
tOption : RowType a -> RowType (Option a)   -- None if CNull, else decode inner

-- Tuple combinators (up to 4; extend by nesting):
t2 : RowType a -> RowType b -> RowType (a, b)
t3 : RowType a -> RowType b -> RowType c -> RowType (a, b, c)
t4 : RowType a -> RowType b -> RowType c -> RowType d -> RowType (a, b, c, d)

-- Escape hatch: supply a custom decoder:
tCustom : Int -> (List Cell -> Result String a) -> RowType a
```

Example usage:

```
data User = User { id : Int, name : String, age : Option Int }

userRow : RowType User
userRow = tCustom 3 (cells => match cells
  [CInt id, CText name, age_cell] =>
    let age = match age_cell
      CNull   => Ok None
      CInt n  => Ok (Some n)
      _       => Err "age: expected Int or NULL"
    age |> andThen (a => Ok (User { id, name, age = a }))
  _ => Err "userRow: wrong number of columns")
```

Or with `t3` and a map:

```
userRow : RowType User
userRow =
  map (id name age => User { id, name, age })
    (t3 tInt tText (tOption tInt))
```

> **FOOTGUN — the no-GADT wall.** The `RowType a` value **cannot** be
> pattern-matched to introspect `a` at runtime. Never write code that does
> `match rowType { tInt => ...; tText => ... }` — there is no such constructor to
> match. The decoder closure IS the type information. If you need to dispatch on the
> column type dynamically, work with `Cell` directly (it IS an ADT you can match).
> The phantom `a` on `RowType a` exists only so `query userRow ...` can return
> `Result String (List User)` without a cast. This is the design choice that dodges
> GADTs — document it loudly in the API.

### Phase 1: query execution

```
-- Open a DB (reads the file; pure once in memory):
data Db = Db
  { header : DbHeader
  , bytes  : Array Int   -- the full file contents
  }

openDb : String -> <FileRead> Result String Db

-- Execute a full-table scan with an optional WHERE predicate on cells:
-- (Phase 1: no index support, no JOIN, no ORDER BY)
scanTable : Db -> String -> (List Cell -> Bool) -> RowType a
          -> Result String (List a)

-- Convenience: fetch all rows:
fetchAll : Db -> String -> RowType a -> Result String (List a)
fetchAll db table rt = scanTable db table (_ => True) rt
```

### Phase 2: typed query ADT

Phase 2 adds an injection-safe, type-checked query layer. The design keeps the
result `RowType r` **explicit** — do NOT attempt to infer it from the column list
(that requires type-level column names, i.e. a GADT wall).

```
-- A literal value (for parameterized queries):
data Literal
  = LInt  Int
  | LText String
  | LFloat Float
  | LNull

-- A phantom-typed expression (only smart constructors build these):
data Expr a = Expr { sql : String }   -- contains ? placeholders; never user-constructed

-- Smart constructors:
colInt   : String -> Expr Int
colText  : String -> Expr String
colFloat : String -> Expr Float

litInt   : Int    -> Expr Int
litText  : String -> Expr String

eq   : Expr a -> Expr a -> Expr Bool          -- a must be Eq-able (but we don't enforce at type level)
lt   : Expr Int -> Expr Int -> Expr Bool
gt   : Expr Int -> Expr Int -> Expr Bool
and_ : Expr Bool -> Expr Bool -> Expr Bool
or_  : Expr Bool -> Expr Bool -> Expr Bool
not_ : Expr Bool -> Expr Bool
isNull  : Expr a -> Expr Bool
notNull : Expr a -> Expr Bool

-- A SELECT query (no JOIN, no subquery in Phase 2):
data Select = Select
  { from    : String          -- table name
  , where_  : Option (Expr Bool)
  , limit   : Option Int
  , offset  : Option Int
  }

-- Render to SQL + parameter list (injection-safe: user values become ?):
render : Select -> (String, List Literal)

-- Execute against an open Db:
query : Db -> Select -> RowType a -> <FileRead> Result String (List a)
```

**Example:**

```
let q = Select
  { from   = "users"
  , where_ = Some (and_ (gt (colInt "age") (litInt 18)) (notNull (colText "email")))
  , limit  = Some 100
  , offset = None
  }

match query db q (t2 tInt tText)
  Err e  => println "Error: \{e}"
  Ok rows => rows |> map (id name => println "\{id}: \{name}") |> sequence_
```

**Type safety guarantee:** `eq (colInt "age") (colText "name")` is a type error
(`Expr Int` vs `Expr String`). This is the phantom type doing its job. Column
values still pass through `Cell` at runtime and the arity check is still runtime —
the phantom buys column-type correctness, not column-set completeness.

**Graceful degradation:** We do NOT attempt:
- Full relational EDSL (column-set ⊆ FROM checked at compile time) — requires
  type-level string literals, unavailable in Medaka.
- HKD table records (`Table f = { id : f Int, name : f String }`) — requires
  higher-kinded type application; deferred.
- Inferring `RowType r` from the column list — requires GADTs.

### Phase 3 (optional): deriving RowType

If Medaka gains `deriving` for records, a future annotation:

```
data User = User { id : Int, name : String, age : Option Int }
  deriving RowType
```

would generate `userRow : RowType User` automatically, matching fields by name
against the table schema at query time. Out of scope for this design; noted as the
natural Phase 3 hook.

---

## Effects & capabilities

> **Verification against EFFECTS-SEMANTICS.md.** The claims below were checked
> against the spec (§2–§7). Corrections noted inline where the initial framing was
> imprecise.

### Level 0: automatic propagation

```
readFileBytes : String -> <FileRead> Result String (Array Int)
```

`<FileRead>` propagates to the caller via the `app` rule (§3): every function
that calls `readFileBytes` acquires `<FileRead>` in its inferred row. This
reaches `main` automatically; `medaka manifest` surfaces it. No design work needed
here — the extern declaration does the job.

**Correction to initial framing:** "write externs carry `<FileWrite>`" — confirmed
correct by the label catalog in EFFECTS-SEMANTICS.md §7 (`FileRead`, `FileWrite` are
security labels emitted to the manifest). Phase 1 has no write path, so
`<FileWrite>` does not appear.

### Level basic+: pure/impure boundary

Query **construction** is pure: building a `Select` ADT, composing `Expr` values,
calling `render` — none of these touch IO. Effect row = `⟨ ⟩` (the empty closed
row). Only **execution** (`openDb`, `query`, `scanTable`) carries `<FileRead>`.

```
-- Pure (no effect):
render  : Select -> (String, List Literal)
t2      : RowType a -> RowType b -> RowType (a, b)
colInt  : String -> Expr Int

-- Effectful:
openDb  : String -> <FileRead> Result String Db
query   : Db -> Select -> RowType a -> <FileRead> Result String (List a)
```

This pure/impure boundary is the useful signal: a function that only builds queries
and never runs them is statically certified IO-free.

### The capability wedge (value without new machinery)

A read-only connection exposes only `<FileRead>` operations. A hypothetical future
write connection would expose `<FileWrite>`. The effect rows make this visible in
the manifest and checkable by policy:

```
-- A query tool that only reads:
main : <FileRead> Unit
main = ...

-- A migration tool that also writes:
main : <FileRead, FileWrite> Unit
main = ...
```

This is the capability wedge: `medaka check-policy --allow FileRead` accepts the
first, rejects the second. This emerges naturally from the extern declarations —
no new language machinery is needed. It is a **showcase** for Medaka's capability
discipline.

### Ruled out: custom `<Db "path">` resource effect

**Rejected.** Initial framing suggested a custom `<Db "path">` effect where the
path parameter refines to the specific file being read. Per EFFECTS-SEMANTICS.md §4:

> `α(f ē) = ⊤`

A database path is typically a runtime value (a command-line argument, a config
read). Even if it were a string literal, the intraprocedural `α` degrades function
results to `⊤` at call boundaries (§4, "application result `f ē` → `⊤`"). So
`<Db "myapp.sqlite">` would in practice always degrade to `<Db ⊤>` — which conveys
essentially nothing beyond `<FileRead>` already conveys. The `Prefix` domain
WOULD support path-level precision (`<FileRead "/data/app/*.sqlite">`), but that
precision is on `FileRead` itself, not a custom `Db` label.

**Conclusion:** `<FileRead>` (with an optional path prefix parameter on the
`FileRead` label, if that domain is active) is the correct level of granularity.
A `<Db "path">` label is redundant and its precision degrades to ⊤ at runtime paths.

### Ruled out: transaction-as-an-effect

**Rejected.** A transaction scope is **control-flow context** — it tracks which
operations are grouped into an atomic batch. It is NOT a resource authority being
exercised. Per EFFECTS-SEMANTICS.md §7, security labels are host-granted authorities
(FileRead, FileWrite, Net, etc.); a transaction is an application-level protocol,
not a platform authority.

Model it as a **value-level `Txn` handle** (a future write-path concern):

```
-- Write-path future design (not Phase 1):
data Txn
beginTxn    : Db -> <FileWrite> Txn
commitTxn   : Txn -> <FileWrite> Result String Unit
rollbackTxn : Txn -> <FileWrite> Unit
```

The type system tracks that you need `<FileWrite>` to start or commit a transaction;
the transaction protocol itself is enforced by the Txn handle's API, not by the
effect row.

---

## The differential oracle

Use the `sqlite3` CLI to generate known test databases and verify the Medaka library
reads them identically.

### Workflow

```sh
# Generate a test database:
sqlite3 /tmp/test.db <<'EOF'
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
INSERT INTO users VALUES (1, 'Alice', 30);
INSERT INTO users VALUES (2, 'Bob', NULL);
INSERT INTO users VALUES (3, 'Carol', 25);
EOF

# Query with sqlite3 (the oracle):
sqlite3 /tmp/test.db "SELECT id, name, age FROM users ORDER BY id" > /tmp/oracle.txt

# Query with Medaka library (the candidate):
medaka run sqlite/test_main.mdk /tmp/test.db > /tmp/candidate.txt

# Diff:
diff /tmp/oracle.txt /tmp/candidate.txt
```

### Test corpus

| DB | Purpose |
|----|---------|
| `test/sqlite_fixtures/basic.db` | Single table, all scalar types (Int, Float, Text, NULL) |
| `test/sqlite_fixtures/multipage.db` | Table large enough to require multiple B-tree pages (interior nodes) |
| `test/sqlite_fixtures/unicode.db` | UTF-8 text with multi-byte characters |
| `test/sqlite_fixtures/types.db` | One row exercising all serial types (0–9, blob, text) |
| `test/sqlite_fixtures/multitable.db` | Multiple tables (sqlite_master schema walk) |

Generate these at test-suite setup time via `sqlite3` shell commands; do NOT
commit binary `.db` files (check in the SQL that generates them instead).

### Gate definition

Each slice's gate (see below) should pass the relevant fixtures.

---

## Milestone status (2026-06-23) — single-leaf-page read path LANDED

The core file-format reader is implemented and differentially verified against
the real `sqlite3` CLI. Project: `sqlite/` (imports `byteparser/` cross-project).

**What works** (byte-identical to `sqlite3` output):
- 100-byte header parse + validate (magic, page size, encoding, read version).
- Table-leaf page (0x0D) header + cell-pointer array.
- Table-leaf cell decode: payload-length varint, rowid varint, record.
- Record decode: header serial-type varints + body → typed `Cell`s
  (NULL / 8–64-bit signed ints / int-0 / int-1 / UTF-8 text / blob).
- `sqlite_master` schema read (type, name, tbl_name, rootpage, sql).
- Full single-leaf-page table scan with rowid substitution for the
  `INTEGER PRIMARY KEY` column (stored as NULL, value = rowid).
- UTF-8 text (multi-byte), multiple tables, multi-width / negative integers.

Verified: 31 doctests (header/record/cell decoders on literal bytes) +
`sqlite/test/oracle.sh` (generates a DB from `sqlite/test/basic.sql`, diffs the
Medaka reader vs `sqlite3` for schema + 3 tables — both match).

**Documented residual** (fork E / slice 6): a table whose root page is a B-tree
*interior* page (0x05 — e.g. >~100 rows) is rejected with a clean error
`"multi-page B-tree not supported (v1 single-leaf-page only): ..."`. Multi-page
interior-node traversal is the next slice. Float columns (serial 7) stay out of
scope (the `beFloat64` extern is still stubbed) — they yield a clean `Err`.

**Loader/language gotchas surfaced while building (real findings):**
1. `record` is a reserved keyword, so a module file `record.mdk` imported as
   `lib.record` fails to parse (the dotted-import segment collides with the
   keyword). The record module is named `recordfmt.mdk`. *(Candidate compiler
   fix: allow keyword-named path segments in import resolution.)*
2. Medaka's not-equal operator is `!=`, not `/=` — `/=` lexes as `/` then `=`
   and produces a misleading "Parse error" with no useful location.
3. A `let x = e` immediately followed by a multi-line `if/then/else` whose
   `else` branch contains multiple further `let`s hits a layout parse error;
   inlining the leading `let` avoided it.
The cross-project `[dependencies]` resolution from `0ad8ae9` works for the
SQLite use case, *including transitively* (sqlite module → byteparser dep) and
under the doctest runner.

## Staged slice plan

| # | Slice | Gate |
|---|-------|------|
| 0 | **Foundation externs** (`readFileBytes` + bitwise) — **DONE** `1b25c9b` | fixpoint C3a/C3b YES; `medaka build` reads `.sqlite` bytes; `medaka run` can't (no file IO in native interp) |
| 1 | **ByteParser module** (`byteparser/byte_parser.mdk`) | `medaka test byteparser/byte_parser.mdk` — doctests covering `byte`, `beUint 4`, `sqVarint`, `bMany` |
| 2 | **Header parser** (`sqlite/header.mdk`) | Parses the 100-byte header from `basic.db`; prints page size, page count, encoding; matches `sqlite3 "PRAGMA page_size"` etc. |
| 3 | **Page/cell parser** (`sqlite/btree.mdk`) | Walks all table-leaf cells of page 1 (`sqlite_master` B-tree) for `basic.db`; prints raw cell byte counts = expected row count |
| 4 | **Record decoder** (`sqlite/record.mdk`) | Decodes the `Cell` list from each raw record; round-trips all serial types in `types.db` |
| 5 | **sqlite_master schema reader** (`sqlite/schema.mdk`) | Reads all rows of `sqlite_master` from `basic.db`; prints `(type, name, rootpage)` tuples = oracle output |
| 6 | **B-tree walk (multi-page)** (`sqlite/btree.mdk` extended) | Walks interior + leaf pages recursively for `multipage.db`; total row count = `SELECT count(*) FROM ...` |
| 7 | **SELECT executor + full table scan** (`sqlite/query.mdk`) | `fetchAll db "users" (t3 tInt tText (tOption tInt))` output diff = oracle for `basic.db` |
| 8 | **RowType marshalling** (`sqlite/row_type.mdk`) | Custom `userRow : RowType User` round-trips; `tOption` handles NULL; all fixtures pass |
| 9 | **Phase 2 query ADT** (`sqlite/lib/select.mdk`) — ✅ DONE (`e9fd54e`) | `render` produces injection-safe `?`-parameterized SQL + ordered binds; `query` (ADT drives the scanner: WHERE-pushdown over raw cells + limit/offset, then `RowType` decode) matches `sqlite3` on 17 rows (`select_oracle.sh`); phantom `Expr a` type-safety proven by a should-fail `check` fixture. Forks resolved: a1 ADT-drives-executor (render secondary), b1 parameterized binds, d2 WHERE+limit/offset (ORDER BY = rowid), e1 `RowType`+predicate API kept alongside. Constructors named off prelude methods (`eGt`/`eEq`/…) per the method-shadow finding. |

---

## Design decisions (RESOLVED)

The five forks from the initial design draft are all resolved. Decisions recorded here;
rationale collapsed since they are no longer open questions.

### F — `tFloat` coerces `CInt → Float` (REAL affinity) ✅ DECIDED (2026-06-24, `72b4c58`)

**Decision:** the `tFloat : RowType Float` combinator accepts BOTH a `CFloat` cell and a
`CInt` cell (coercing the latter via `intToFloat`); only genuinely non-numeric cells
(`CNull`/`CText`/`CBlob`) error.

Rationale (a dogfood finding): SQLite stores a whole-number REAL value (e.g. `10.0` in a
`REAL` column) on disk as an *integer* serial type — a documented storage optimization,
transparently converted back to REAL on read. So the on-disk cell for such a row is `CInt`,
not `CFloat`. A strict (`CFloat`-only) `tFloat` would error on this common case; coercing
`CInt → Float` makes `tFloat` faithful to the column's REAL affinity. (The raw-cell layer
still reports the honest `CInt` — coercion is a typed-`RowType` concern only.) Float DECODE
itself (serial type 7, 8-byte IEEE) goes through `bytesToFloat64`/`beFloat64` → `CFloat`.

### A — ByteParser location: own `byteparser/` project ✅ DECIDED

**Decision:** ByteParser is its own library project under `byteparser/` with its own
`medaka.toml`, mirroring the layout of `parsec/`. It is NOT nested inside `sqlite/`.

Rationale: ByteParser is independently useful for any future binary format library
(msgpack, protobuf, PNG, etc.). A standalone project with its own toml gives it clean
import paths and makes `medaka test byteparser/` work. The `parsec/` precedent is clear.

### B — Project structure: `sqlite/` is a `medaka.toml` project ✅ DECIDED

**Decision:** `sqlite/` is a full `medaka.toml` project, mirroring `parsec/`. It
imports `byteparser/` as a cross-project dependency (see caveat below).

### C — Float decoding: `bytesToFloat64` is a new extern ✅ DECIDED

**Decision:** Add `bytesToFloat64 : Array Int -> Int -> Float` as a new extern,
sequenced at the record-decoder slice (slice 4).

Rationale: Medaka's `Int` is 63-bit (OCaml/native tagged). Reconstructing a 64-bit
IEEE double from 8 raw bytes in pure Medaka is impossible without losing the sign bit
or the 64th mantissa bit. The extern is one line in `eval.ml` (OCaml's
`Int64.float_of_bits`) + the native runtime counterpart. Same argument as
`readFileBytes`: a bits-to-float reinterpret is inherently a machine primitive.

### D — SQL text parsing: skip in Phase 1 (position-based) ✅ DECIDED

**Decision:** Do not parse the `CREATE TABLE` SQL text from `sqlite_master` in
Phase 1. `RowType` is position-based by design (the decoder closure receives a
`List Cell` in column order). Column names are optional metadata needed only for
Phase 2's `colInt "name"` smart constructors.

Phase 2 can add a light SQL parser (using `parsec`) to validate that
`colInt "age"` refers to an INTEGER column. That is a Phase 2 concern.

### E — Overflow pages: clean error in Phase 1, transparent walk in Phase 2 ✅ DECIDED

**Decision:** Phase 1 returns `Err "overflow payload not supported"` when a
table-leaf cell payload exceeds the usable per-page size. Phase 2 adds transparent
overflow-chain walking inside `btree.mdk`; the caller never needs to think about it.

---

## Portability / bytes-first API (v1 API-shape DECISION)

The core constructor is:

```
fromBytes : Array Int -> Result String Db
```

This is **pure** — no effects, no filesystem access. The full file-open convenience
is a thin wrapper:

```
openDb : String -> <FileRead> Result String Db
openDb path = readFileBytes path >>= fromBytes
```

**Rationale:** This design isolates the one impure call to a single thin combinator.
The rest of the library — `scanTable`, `fetchAll`, `query`, `render`, all `RowType`
combinators — is pure given a `Db`. This has three concrete payoffs:

1. **Testability without a filesystem.** Unit tests and doctests can feed a
   hand-crafted `Array Int` (the bytes of a known sqlite header, a synthetic record,
   etc.) directly to `fromBytes` without touching disk. Doctests in particular run
   under `medaka test` which uses the native interpreter — which does NOT have
   `readFileBytes`. The bytes-first API lets every parsing combinator be doctest-able.
2. **WasmGC port is additive.** A future browser-side SQLite needs only one new
   host seam: a `readFileBytes` equivalent on the wasm side (e.g. reading from an
   `ArrayBuffer`). The library itself is unchanged.
3. **Clean effects manifest.** A function that only calls `fromBytes` and `scanTable`
   has effect row `⟨⟩` — statically IO-free. Only callers that invoke `openDb`
   acquire `<FileRead>`.

**Phase 2 note:** A windowed / seek-based access path (for large databases) would
replace the whole-file slurp with a page-reader abstraction of the shape:

```
-- Read `len` bytes starting at byte offset `off`:
type PageReader = Int -> Int -> <FileRead> Result String (Array Int)
```

This is a Phase 2 concern. For Phase 1, `fromBytes` over a whole-file slurp is
correct and sufficient.

**Cross-project import caveat:** `sqlite/` imports `byteparser/` as a
cross-project dependency. This may surface a loader / `medaka.toml` cross-project
dependency gap — `parsec/`'s Finding-#3 fix (2026-06-23) closed the intra-project
walk-up, but cross-project dependency resolution has not been exercised. This is a
good forcing function to handle when wiring the import, not before.

---

## v2 fast-follows

These are NOT in scope for the v1 read path. Recorded here so the design has
natural next-steps when v1 ships.

### WasmGC port

The library is ~99% pure compute over `Array Int`; the only OS touchpoint is
`readFileBytes`. The bytes-first API makes the wasm port additive:

- Add `readFileBytes` to the wasm host-import surface (read from an `ArrayBuffer`).
- Add `bytesToFloat64` to the wasm host-import surface (pure on wasm via
  `f64.reinterpret_i64`; no host round-trip needed, but the extern surface is the
  same pattern).
- The rest of the library recompiles unchanged.

Payoff: a 3-way native / `medaka build` / wasm differential oracle. Also a
concrete capability-wedge demo: a browser-side SQLite with `<FileRead>` capability
visible in the manifest, enforceable by a wasm host policy.

### Async SQL server

A network SQL server in front of the sync SQLite lib is the real async forcing
function — SQLite itself is synchronous, so `<Net>` sockets + an async reactor
are needed to serve multiple clients. This is the motivating use case for `<Net>`
sockets and the async monad design (see `ASYNC-DESIGN.md`).

Both fast-follows are blocked on the v1 read-path being solid.

---

## References

- [SQLite File Format](https://www.sqlite.org/fileformat2.html) — the authoritative
  spec for all byte offsets, B-tree layouts, serial types, and varint encoding cited
  above.
- `parsec/lib/parser.mdk` — the char-level combinator library; ByteParser is a
  structural transcription of this.
- `EFFECTS-SEMANTICS.md` — the ground-truth effect-system spec; all effect claims
  in this document were checked against §2–§7.
- Caqti (OCaml) — the `RowType a` phantom-typed decoder model is inspired by
  Caqti's `Caqti_type.t` representation, adapted to Medaka's type system
  (no GADTs, no functors).
