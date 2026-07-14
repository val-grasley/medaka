# P1 Standard Library — Design & Prioritization

**Status:** PARTIAL — most P1 tier items (§3) shipped 2026-07-01: `math`
(Module 16), `path` (Module 13), `fs` extend (Module 17), `hex`/`base64`
(Modules 14-15), `time` (Module 18), `net` (Module 19) — see STDLIB.md for each
module's ✅ entry. **Exception:** item #4 "`bytes` flesh-out" is itself
PARTIAL — little-endian `le*` variants landed in `stdlib/byteparser.mdk`
(`leUint`/`leSint`/`leFloat64`) and hex/base64 landed as their own modules, but
the standalone `stdlib/bytes.mdk` buffer/slice/concat ergonomic layer this item
specifically proposed was never built (path does not exist). §1's "current
surface" gap table below now describes most shipped items as still-missing;
treat it as historical. The P2 tier (§3, regex/csv/
timezone-datetime/http/bigint) remains genuinely open — none of those exist in
STDLIB.md.

Status (at design time): **design proposal** (2026-07-01). Read-only planning doc. Decides *what
the stdlib grows next* and *in what order*, with per-item implementation-cost
classification so bites can be handed to implementation agents cheapest-first.

Anchors from the maintainer (P1): (a) better **filesystem** support, (b) a
**math** module for real arithmetic, (c) **networking** primitives, (d) fleshing
out the **byte** library. This doc treats those as fixed P1 goals but produces a
comprehensive tiering, folds in cheap high-value wins the anchors don't name
(path, time, base64/hex), and sequences networking as its own late arc.

---

## 1. Current surface (P0 census)

P0 is a mature core. What exists today, from `STDLIB.md` + `stdlib/*.mdk` +
`grep '^extern' stdlib/runtime.mdk` (94 externs):

**Pure data / algorithms (capability-free core):**
- `core` (prelude, auto-imported): Eq/Ord/Debug/Semigroup/Monoid/Num/Bounded/
  Mappable/Applicative/Thenable/Foldable/Filterable; Option/Result/Ordering;
  functional combinators.
- `list`, `string` (UTF-8 codepoint), `array` (fixed), `mut_array` (growable
  vector), `map`/`set` (persistent weight-balanced trees), `hash_map`/`hash_set`
  (mutable), `json` (parser+serializer), `toml`.
- `byteparser` / `bytebuilder` — generic binary parser-combinators + symmetric
  builder. Big-endian only (`beUint`/`beSint`/`beFloat64`, `emit*`).

**Capability modules (effect-labeled):**
- `io` over externs: `readFile`/`writeFile`/`appendFile`/`readFileBytes`/
  `writeFileBytes` (`<FileRead>`/`<FileWrite>`), `fileExists`, `listDir`,
  `makeDir`, `canonicalizePath` (realpath), `args`/`getEnv` (`<Env>`),
  `runCommand` (`<Exec>`), stdin/stdout/stderr streams, `exit`/`panic`.
- `async` — value-level monad (cooperative), no `<Async>` effect.
- RNG: `randomInt/Bool/Float/Char`, `setSeed` (`<Rand>`).
- Time: **only** `wallTimeSec : Unit -> <Clock> Float` (gettimeofday).

**Numeric / codec externs:** `intToFloat`, `floatToInt`, `floatRem`,
`intBitsToFloat`, `bytesToFloat64`, `floatToBytes64`, `intToString`,
`floatToString`, `stringToFloat`, bit-ops (`bitAnd/Or/Xor/Not`,
`shiftLeft/Right`), `pi`, `e`, `intMin/MaxBound`, `charMin/MaxBound`, per-type
`hash*`. UTF-8 codecs: `stringToUtf8Bytes`/`stringFromUtf8Bytes`,
`charCode`/`charFromCode`.

### The gaps (what P1 targets)

| Area | Present | Missing |
|------|---------|---------|
| **Math** | `pi`, `e`, `floatRem`, bit-ops, `abs`/`signum` (via `Num`), bounds | **sqrt, cbrt, hypot, sin/cos/tan + inverse, exp, log/log2/log10, pow, floor, ceil, round, trunc, isNan/isInf, gcd/lcm** |
| **Filesystem** | read/write/append, listDir, makeDir, fileExists, realpath | **removeFile, rename, copy, stat/metadata (size/mtime/is-dir), mkdirAll, walkDir, tempFile/tempDir, removeDir** |
| **Path** | *none in stdlib* (`compiler/support/path.mdk` has dirname/basename/join/chopExt, compiler-private) | **a real `path` module: join, dirname, basename, extension/splitExt, normalize, isAbsolute, components, relative** |
| **Networking** | **none** — no socket externs at all | **TCP/UDP sockets, DNS resolve, (later) HTTP, TLS** |
| **Bytes** | byteparser/bytebuilder (big-endian), UTF-8 codecs | **little-endian variants, base64/hex codecs, a byte-buffer ergonomic layer** |
| **Time/date** | `wallTimeSec` | **monotonic clock, sleep, civil datetime (y/m/d/h/m/s), ISO-8601 fmt/parse, Duration/Instant** |
| **Text codecs** | — | **base64, hex, url-encode** (pure) |
| **Regex** | — | pattern matching (P2) |
| **CSV** | — | RFC-4180 read/write (P2) |

Two facts that lower P1 cost dramatically:

1. **`Net` is already a registered builtin effect label.** `resolve.mdk:214`
   and `typecheck.mdk:167` list `Net` alongside `FileRead`/`FileWrite` as a
   `PPrefix None` builtin. The networking *effect-type* groundwork is done —
   networking needs externs + C runtime + a wasm story, **not** new effect
   infrastructure.
2. **`compiler/support/path.mdk` is a working path library already** — it's
   just compiler-private. Promoting/generalizing it to a stdlib `path` module is
   near-pure string work.

---

## 2. Comparison to other languages

Category-by-category presence in five reference stdlibs. ✅ = in-core
(batteries-included), 3P = deferred to ecosystem, ➖ = absent/minimal.

| Category | Rust std | Go std | Python std | OCaml | Zig std | *Verdict: table stakes?* |
|---|---|---|---|---|---|---|
| **Math** (sqrt/trig/log/pow/floor…) | ✅ `std::f64` methods | ✅ `math` | ✅ `math`/`cmath` | ✅ `Float`/`stdlib` (`sqrt`,`sin`…) | ✅ `std.math` | **YES — universal** |
| **Filesystem** (rm/rename/stat/walk/temp) | ✅ `std::fs` | ✅ `os`/`io/fs`/`path/filepath` | ✅ `os`/`shutil`/`pathlib`/`tempfile` | ✅ `Sys`/`Unix` (+`Filename`) | ✅ `std.fs` | **YES** |
| **Path manipulation** | ✅ `std::path` | ✅ `path`/`path/filepath` | ✅ `os.path`/`pathlib` | ✅ `Filename` | ✅ `std.fs.path` | **YES** |
| **Networking** (TCP/UDP/DNS) | ✅ `std::net` (TCP/UDP/DNS; no async, no TLS/HTTP) | ✅ `net` + `net/http` (HTTP in-core!) | ✅ `socket`/`http`/`urllib` | 3P (Unix sockets in `Unix`; `lwt`/`async`/`cohttp` for real work) | ✅ `std.net` (sockets; HTTP/TLS present-ish, evolving) | **Sockets: yes. HTTP/TLS: split** |
| **Time/date** | ✅ `std::time` (Instant/Duration; no calendar — `chrono` 3P) | ✅ `time` (full calendar+tz) | ✅ `time`/`datetime`/`zoneinfo` | partial (`Unix.gettimeofday`; calendar 3P `ptime`) | ✅ `std.time` (Instant/Timer; calendar minimal) | **Monotonic+Duration: yes. Calendar: split** |
| **base64/hex** | 3P (`base64` crate; hex via fmt) | ✅ `encoding/base64`,`encoding/hex` | ✅ `base64`/`binascii` | 3P | ✅ `std.base64`, hex in `std.fmt` | **Mostly yes** |
| **Regex** | 3P (`regex` crate — canonical) | ✅ `regexp` | ✅ `re` | 3P (`re`/`str`) | ➖ (no general regex) | **Split — often 3P** |
| **CSV** | 3P (`csv` crate) | ✅ `encoding/csv` | ✅ `csv` | 3P | ➖ | **Split** |
| **Bytes/binary** (buffers, endianness) | ✅ `bytes`-ish via slices+`to_le_bytes`; `byteorder` 3P for streams | ✅ `bytes`/`encoding/binary` | ✅ `struct`/`bytes`/`io.BytesIO` | ✅ `Bytes`/`Buffer` | ✅ `std.mem` (endian), slices | **YES** |
| **Hashing/crypto** | 3P (`sha2`,`ring`) | ✅ `crypto/*` (sha,aes,tls) | ✅ `hashlib`/`hmac`/`ssl` | 3P (`digestif`) | ✅ `std.crypto` | **Split** |
| **Compression** | 3P (`flate2`) | ✅ `compress/*` | ✅ `zlib`/`gzip` | 3P | ✅ `std.compress` | **Split** |

**Table-stakes ranking (by how universally in-core — the strongest signal for
what P1 *must* ship):**
1. **Always in-core (5/5):** math, path, byte/binary buffers + endianness,
   filesystem, TCP/UDP + DNS, monotonic + wall clock. Non-negotiable — even the
   minimalist stdlibs (Rust, OCaml, Zig) include these. **→ all P1.**
2. **In-core in 4/5 (only Rust omits):** big-int + rational. Strongly expected of
   a *functional/pragmatic* language. **→ P2** (no concrete Medaka use case yet;
   promote if crypto/exact-math lands).
3. **The batteries-vs-ecosystem dividing line (3/5 — Go/Python/Zig ship, Rust/
   OCaml-core don't):** base64, hex, compression, crypto-hash. These are the
   *productivity differentiator*. **→ base64/hex are P1** (pure, ubiquitous);
   compression + crypto-hash are P3.
4. **Genuinely split / optional:** regex, CSV (in-core for Go/Python, absent in
   Rust/OCaml/Zig), URL-encoding, HTTP, TLS, calendar+timezones. Defensible to
   defer. **→ CSV/regex P2, HTTP/TLS/tz P3.**

**Design poles:** Go/Python are batteries-included (ship all 10 categories incl.
HTTP/TLS/tz/regex/crypto); Rust/OCaml are minimal-core (only primitives, rest to
crates.io/opam); Zig leans comprehensive at the *primitive* level (big-int,
crypto, compression) but ships **no regex, no CSV, no real datetime**.

**Consequence for Medaka:** there is **no package ecosystem yet**, so the
"minimal core + ecosystem" escape hatch Rust/OCaml rely on isn't available.
That argues for a **slightly-more-batteries** stance: pull the pure, ubiquitous
mid-tier items (base64/hex, a small civil datetime, later CSV) into core because
there is nowhere else for them to live — while still deferring the genuinely
heavy protocol/format engines (regex, TLS, HTTP framework, crypto, tzdata).

*(Citations: doc.rust-lang.org/std, pkg.go.dev/std, docs.python.org/3/library,
ocaml.org/manual + v2.ocaml.org/api, ziglang.org/documentation/master/std — see
§7 sources.)*

---

## 3. Prioritization (P1 / P2 / P3)

Cost legend for §3–4:
- **[pure]** — writeable in `stdlib/*.mdk` over existing externs. Cheapest.
- **[extern]** — needs new externs: +`runtime.mdk`, +`eval.mdk` primitive,
  +`medaka_rt.c`, +`llvm_emit.mdk` registration, +`wasm_emit.mdk` registration
  (5 touch-points; see §4 for the measured shape). Mechanical/templated when the
  extern is a leaf libm/libc call.
- **[effect]** — needs an effect label. `Net` already exists; `Clock` already
  exists. So no P1 item actually needs *new* effect infra.
- **[C+wasm]** — needs real C-runtime logic and a cross-backend story
  (the networking risk).

### P1 — do these first (in roughly this order)

| Item | What | Cost | Size | Rationale |
|---|---|---|---|---|
| **`math`** | libm float ops: `sqrt cbrt hypot exp log log2 log10 pow sin cos tan asin acos atan atan2 floor ceil round trunc`; pure: `isNan isInf isFinite degrees radians lerp gcd lcm` | **[extern]** for the ~20 libm leaves (each mechanical) + **[pure]** wrappers | ~20 externs + ~150 LOC Medaka | Universal table-stakes; blocks graphics/geometry/stats/sqlite-math; each extern is a copy-paste of the `floatRem` shape |
| **`path`** | `join dirname basename extension splitExt stem normalize isAbsolute components relative` | **[pure]** — promote+extend `compiler/support/path.mdk` | ~200 LOC Medaka | Cheapest P1 win; pure string; already 80% written; unblocks fs+build tooling |
| **`fs` extend** | `removeFile rename copyFile removeDir mkdirAll walkDir stat`(size/mtime/isDir/isFile) `tempDir tempFile` | **[extern]** for `unlink/rename/rmdir/stat` + **[pure]** for `copyFile`(read+write), `mkdirAll`/`walkDir`(recurse over `listDir`) | ~5 externs + ~150 LOC | Anchor (a); reuses existing `<FileRead>`/`<FileWrite>` labels; high everyday value |
| **`bytes` flesh-out** | little-endian `le*` in byteparser/bytebuilder; a `bytes` module with a byte-buffer ergonomic layer over `mut_array Int`; `slice/concat/toHex/fromHex` | **[pure]** (endianness = arithmetic over existing byte arrays) | ~250 LOC | Anchor (d); all pure; makes byteparser symmetric and usable for real formats |
| **`base64` / `hex`** | `base64.encode/decode`, `hex.encode/decode` over `Array Int`/`String` | **[pure]** | ~120 LOC | Not named by anchors but ubiquitous, trivially pure, and needed by fs/net/json-adjacent work |
| **`time` (basic)** | `monotonicSec`(new extern), `sleep`(extern); pure `Duration`/`Instant` types + arithmetic; civil calendar `Date`/`DateTime` (days↔y/m/d is pure), ISO-8601 format/parse (pure) | **[extern]** for 2 clock/sleep externs (reuse `<Clock>`) + **[pure]** calendar | 2 externs + ~300 LOC | `wallTimeSec` alone is too thin; monotonic clock + Duration is table-stakes in all 5 langs; calendar is pure and high-value. **Timezones deferred to P2.** |
| **`net` (staged, LAST in P1)** | TCP client+server, UDP; `connect/listen/accept/send/recv/close`, DNS `resolve` | **[extern]+[C+wasm]**, `<Net>` label already exists | ~10 externs + C runtime + ~200 LOC Medaka | Anchor (c). Real C-runtime work + no clean wasm story → its own arc; see §5. Do math/fs/bytes/time FIRST. |

### P2 — next wave

| Item | Cost | Why P2 |
|---|---|---|
| **`datetime` timezones** | [extern] (needs tz database access / `localtime_r`) | Genuinely hard (tzdata), and the pure civil calendar from P1 covers most needs |
| **`csv`** (RFC-4180 read/write) | [pure] over `string` | Pure and useful, but lower daily value than math/fs; Go/Python ship it, Rust/OCaml don't |
| **`regex`** | [pure] NFA engine, ~600+ LOC (or [extern] to a C lib) | High value but large; a pure Thompson-NFA engine is a real project; Rust/OCaml/Zig all defer it |
| **`http` client** | builds on `net` + `bytes` + TLS gap | Depends on P1 `net` landing first; needs TLS for https |
| **`bigint` / `rational`** | [pure] over arrays of limbs, or [extern] to GMP | Niche until a use case (crypto, exact math) appears |
| **`process` extend** | [extern] (spawn/pipe beyond `runCommand`) | `runCommand` covers the common case already |

### P3 — later / on-demand

| Item | Cost | Why P3 |
|---|---|---|
| **crypto** (sha256, hmac, aes) | [extern] or large [pure] | Needed for TLS/auth; heavy; only Go/Python/Zig ship in-core |
| **TLS** | [C+wasm], depends on crypto | Blocks https; large; even Rust/OCaml defer to ecosystem |
| **compression** (gzip/deflate) | [pure] large or [extern to zlib] | On-demand |
| **url / uri parsing** | [pure] | Small but only matters once http lands |
| **structured logging, argparse** | [pure] | Nice-to-have, not core |

---

## 4. Implementation-cost details (grounded in the pipeline)

### The extern touch-point count (measured)

I traced `floatRem` and `wallTimeSec` end-to-end. A **new leaf float/libc
extern** touches exactly these five places:

1. `stdlib/runtime.mdk` — the `extern` signature (effect annotation on the
   return type; pure math = none, clocks = `<Clock>`, sockets = `<Net>`).
2. `compiler/eval/eval.mdk` — a `pFoo` primitive + a `("foo", prim1 pFoo)` entry
   in the `primitives` list. **Note:** the interpreter primitive itself *calls
   the same extern name* (e.g. `pFloatRem (VFloat a) (VFloat b) = VFloat
   (floatRem a b)`), so eval.mdk — being compiled natively — links the C impl.
   A startup completeness assertion enforces runtime↔eval parity.
3. `runtime/medaka_rt.c` — the C function (e.g. `mdk_float_rem` → `fmod`). For
   libm this is a one-liner over `<math.h>`.
4. `compiler/backend/llvm_emit.mdk` — add the name to `isNumExtern`'s list and an
   `emitNumExtern` arm (the float externs share a single boxed-Float ABI, so new
   ones are near-copy-paste).
5. `compiler/backend/wasm_emit.mdk` — register in the float-extern / host-import
   tables (the `floatToString`/`intToFloat` group).

**Consequence for sequencing:** the ~20 `math` libm externs are individually
trivial and *identical in shape* — a Sonnet agent can template all of them in
one pass. The cross-cutting risk is only in step 4/5 registration lists, which
are pattern-matched name sets, not route-fragile dispatch.

⚠️ **Re-mint reminder:** any change to `compiler/backend/*` or files the compiler
compiles perturbs emitted IR → requires a seed re-mint + `selfcompile_fixpoint`
re-validation. Batch the math externs into **one** re-mint checkpoint rather than
per-extern (per the "defer seed re-mints" practice).

### Per-tier cost summary

- **[pure] items** (`path`, `base64`/`hex`, `bytes` endianness, `csv`, calendar
  math, `copyFile`/`walkDir`/`mkdirAll`): no re-mint needed unless the compiler
  imports them; new modules are import-by-bare-name, not auto-prelude, so they
  don't perturb the compiler build. **Cheapest, Sonnet-friendly, parallelizable.**
- **[extern] items** (math libm, fs `unlink`/`rename`/`stat`, clock/`sleep`):
  5-file mechanical change + one batched re-mint. Sonnet-appropriate per-extern;
  an Opus/human should own the re-mint + fixpoint gate.
- **[effect] items:** none needed new — `Net` and `Clock` already registered.
  (If a `<Net>` sub-refinement like `<Net host>` prefix-args were wanted later,
  that's a typecheck change, but plain `<Net>` is free.)
- **[C+wasm] items** (networking): see §5.

---

## 5. Networking — design, sequenced late

Networking is the one anchor with real cross-cutting cost. Design it now,
implement it **after** math/fs/bytes/time.

### Effect label
Use the **already-registered `<Net>` label** (`PPrefix None` in typecheck.mdk).
Every socket extern's return type carries `<Net>`. No compiler change needed for
v1. A future refinement could make it prefix-parameterized (`<Net "host:port">`)
for capability manifests, mirroring `<FileRead path>` — that's a typecheck-side
extension, not a blocker.

### Proposed externs (v1: blocking TCP/UDP, native)
```
extern tcpConnect  : String -> Int -> <Net> Result String Socket   -- host, port
extern tcpListen   : String -> Int -> <Net> Result String Listener -- bind addr, port
extern tcpAccept   : Listener -> <Net> Result String Socket
extern socketSend  : Socket -> Array Int -> <Net> Result String Int  -- bytes written
extern socketRecv  : Socket -> Int -> <Net> Result String (Array Int) -- up to N bytes
extern socketClose : Socket -> <Net> Result String Unit
extern udpBind     : String -> Int -> <Net> Result String Socket
extern udpSendTo   : Socket -> String -> Int -> Array Int -> <Net> Result String Int
extern udpRecvFrom : Socket -> Int -> <Net> Result String (Array Int, String, Int)
extern dnsResolve  : String -> <Net> Result String (List String)
```
`Socket`/`Listener` are opaque handles — represent as a boxed fd (`Int`) wrapped
in a nominal type so they can't be confused with ints. The `Array Int`/byte
payload reuses the P1 `bytes` layer; that's *why* bytes is sequenced before net.

### C-runtime sketch
Thin shims over POSIX `socket(2)`/`connect`/`bind`/`listen`/`accept`/`send`/
`recv`/`close` + `getaddrinfo` for DNS, in `runtime/medaka_rt.c`, returning the
`Result String _` convention (errno → `strerror` in the `Err`). Blocking v1;
non-blocking/`select`/epoll and async integration are a later refinement.
Per the runtime-language decision, these stay **C thin syscall shims** with the
logic in Medaka.

### The wasm problem (flag honestly)
**Raw sockets do not port to WasmGC.** The browser/edge wasm target has no
`socket(2)`. Options, none free:
- **Gate by capability/target.** Networking lives in a capability module absent
  on the wasm target (exactly the stratification STDLIB.md §"Capability
  stratification" already anticipates). `medaka build --target wasm` would reject
  a program importing `net`. Cleanest; honest; recommended for v1.
- **WASI sockets** (`wasi-sockets`) on a non-browser wasm runtime — partial, and
  only for WASI hosts, not browsers. Future.
- **Fetch-shim** (browser `fetch` for HTTP only) — would back a *future* `http`
  client on wasm but not raw TCP. Different API surface; don't conflate with the
  socket externs.

**Recommendation:** ship native sockets behind `<Net>`, mark `net` a
native-only capability module, and defer any wasm networking to a separate
`http`-over-fetch design. This keeps the fixpoint/self-host story clean (the
compiler never imports `net`).

### Top networking risks
1. **No wasm story for raw sockets** — must be a gated native-only module or it
   breaks the multi-target promise. (Mitigation: capability gating, above.)
2. **Blocking-only v1** interacts awkwardly with the cooperative `async` monad —
   real servers want non-blocking. Scope v1 as blocking; treat async I/O as a
   follow-on that needs `select`/epoll externs.
3. **Opaque-handle lifetime** — sockets are mutable-handle resources with no
   `finally`/RAII and no catchable panics (by design). Need a clear close
   discipline; leaked fds are the failure mode. Consider a `withSocket` bracket
   helper (pure-Medaka) as the blessed pattern.
4. **TLS/HTTPS gap** — v1 is plaintext only. Real-world use wants https, which
   pulls in TLS→crypto (P3). Don't let scope creep pull crypto into the net arc.
5. **Re-mint churn is *low* here** — net externs live in the runtime + eval +
   emit registration but the compiler never imports `net`, so the fixpoint is
   only touched by the emit-registration list edits (batch with math).

---

## 6. Recommended implementation sequence (first bites)

Ordered cheapest/highest-value first. Each is a discrete bite for an
implementation agent.

1. **`path` module** — promote `compiler/support/path.mdk` to `stdlib/path.mdk`,
   add `extension`/`splitExt`/`stem`/`normalize`/`isAbsolute`/`components`/
   `relative`; doctests. **[pure, no re-mint]. Sonnet.** (Mechanical string work,
   reference impl already exists.)
2. **`base64` + `hex` codecs** — `stdlib/base64.mdk`, `stdlib/hex.mdk` over
   `Array Int`/`String`; doctests + a round-trip prop. **[pure]. Sonnet.**
3. **`math` externs (batch)** — add all ~20 libm externs across the 5 files in
   one pass, then the pure Medaka wrappers (`degrees`/`radians`/`gcd`/`lcm`/
   `isNan`/`lerp`); doctests. **[extern, ONE re-mint]. Sonnet for the templated
   extern pass; Opus/human owns the seed re-mint + `selfcompile_fixpoint` gate.**
4. **`bytes` flesh-out** — little-endian `le*` in byteparser/bytebuilder + a
   `stdlib/bytes.mdk` buffer/slice/concat/toHex/fromHex layer over `mut_array`.
   **[pure]. Sonnet.** (Depends on #2 for hex.)
5. **`fs` extend** — externs `removeFile`/`rename`/`removeDir`/`stat` (batch with
   #3's re-mint if possible), then pure `copyFile`/`mkdirAll`/`walkDir`/`tempDir`
   in `stdlib/fs.mdk` (or extend `io.mdk`). **[extern + pure]. Opus** owns the
   extern batch (route/emit registration + stat's struct return); **Sonnet** can
   do the pure recursion helpers.
6. **`time` basic** — `monotonicSec` + `sleep` externs (reuse `<Clock>`), pure
   `Duration`/`Instant` + civil `Date`/`DateTime` + ISO-8601. **[extern + pure].
   Opus** for the 2 externs + calendar-algorithm correctness (leap years,
   days-from-civil); **Sonnet** for formatting.
7. **`net` v1 (its own arc)** — the §5 externs + C shims + `stdlib/net.mdk`
   (incl. `withSocket` bracket), gated native-only. **[C+wasm]. Opus/human** —
   this is the route-fragile, cross-backend, resource-lifetime bite; do it last
   and as a dedicated workstream, not folded into another PR.
8. **(P2 kickoff) `csv`** — RFC-4180 over `string`. **[pure]. Sonnet.** Good
   parallel filler while the net arc is in review.

**Parallelism note:** bites 1, 2, 4, 8 are pure and independent → can run
concurrently on Sonnet agents. Bites 3, 5, 6 share the extern/re-mint machinery →
serialize their re-mints (or batch 3+5 externs into one) under Opus supervision.
Bite 7 is standalone and last.

---

## 7. Sources

- Rust std — https://doc.rust-lang.org/std/ (`std::fs`, `std::path`, `std::net`,
  `std::time`, `f64` methods)
- Go std — https://pkg.go.dev/std (`math`, `os`, `path/filepath`, `net`,
  `net/http`, `time`, `encoding/{base64,hex,csv,binary}`, `regexp`, `crypto`,
  `compress`)
- Python std — https://docs.python.org/3/library/ (`math`, `os`, `shutil`,
  `pathlib`, `tempfile`, `socket`, `http`, `datetime`, `zoneinfo`, `base64`,
  `re`, `csv`, `struct`, `hashlib`, `zlib`)
- OCaml — https://ocaml.org/manual + https://v2.ocaml.org/api/ (`Stdlib`,
  `Filename`, `Sys`, `Unix`, `Bytes`, `Buffer`; ecosystem: `re`, `ptime`,
  `cohttp`, `digestif`)
- Zig std — https://ziglang.org/documentation/master/std/ (`std.math`, `std.fs`,
  `std.net`, `std.time`, `std.base64`, `std.mem`, `std.crypto`, `std.compress`)

*(The §2 matrix reflects these stdlibs' documented module indexes as of
2026-07. A background research pass cross-checked category presence against the
official docs above.)*
