# SQLITE-WASM-DESIGN.md — scoping the WasmGC port of the Medaka SQLite library

Goal: get `sqlite/` (pure-Medaka, bytes-first, today native-only via LLVM)
compiling + running correctly under `medaka build --target wasm`, verified
against the native path, so future SQL features land on native + wasm in tandem.

This is a **scoping document** produced from an empirical census on the binary
(2026-06-30, worktree `bright-knitting-eich`, base `b55f95f`). It does NOT change
any emitter / extern / `sqlite/` source — that is the staged work below.

---

## 1. Empirical findings

### Environment / toolchain (all green before touching the lib)
- `wasm-tools` 1.252.0 on PATH.
- Default `node` is v20.11.1 (too old for WasmGC); **nvm `v24.17.0`** is what the
  wasm gates select (`test/wasm/diff_wasm.sh` does `nvm use 24`). Used v24 throughout.
- **`bash test/wasm/diff_wasm.sh` → 139 ok, 0 failing** (+ TCO/DISP/S1B IR-shape
  asserts all ok). The WasmGC toolchain works in this env; any sqlite failure is the
  lib/externs, not the toolchain.
- Native `make medaka` builds clean (clang + Boehm GC; no opam/dune).

### What `--target wasm` already does for the lib (positive findings)
The wasm build path (`build_cmd.mdk` `runBuildWasm` → `compiler/entries/wasm_emit_modules_main.mdk`
→ `wasm-tools parse`/`validate` → Node) **runs the full real front end**: loader
(multi-module), `elaborateModules` (real `core.mdk` prelude + dict-passing), Core IR
lower, DCE, then `wasm_emit`. Empirically the sqlite build **gets all the way through
loading + typecheck + lowering and into the emitter** — it only stops at the first
**missing extern** (see below). So:
- Multi-module resolution + cross-module dispatch + the real prelude **already work
  under `--target wasm`** for the sqlite graph.
- `sqlite/medaka.toml` has **no `[deps]`**; every import (`byteparser`, `bytebuilder`,
  `array`, `list`, `string`) resolves to **stdlib** (bare-name). The `byteparser/`
  *project* at repo root is a leftover demo, unused by the lib. So **cross-project
  dep resolution is not exercised** by sqlite — not a gap, but also unverified for
  wasm (flag, not blocker).
- `arrayGetUnsafe`'s internal-only restriction is **not** a build blocker: the build
  path goes through the emitter (no resolve internal-only check), and the native
  build of `query_demo` succeeds with **no `--allow-internal`**. (Note: the *census
  entry* `wasm_emit_gaps_main` runs `loadProgram`→resolve and so prints the
  internal-only diagnostics, but they don't block it.)

### Emitter-gap census result
**Zero pure-construct emitter gaps.** The WasmGC emitter is hardened (the W-series
drove a per-binding census 1428→0). The sqlite lib trips **no** unlowerable
Medaka construct — every blocker is a **missing extern**, not an emitter hole.

Caveat on method: each missing extern **hard-panics** in the emitter's ref-mode
(`wasm_emit gap — ref-mode: unbound variable '<name>'`) rather than routing through
the gap-tolerant `gapRecordEnabledW` census helpers, so the census **cannot
enumerate past the first missing extern** — it stops, it does not list all gaps in
one pass. I therefore enumerated externs by (a) walking the panic chain and (b)
statically diffing the lib's extern uses against the emitter's supported-extern
dispatch table. Three panics observed in sequence by removing each blocker:
1. `readFileBytes` — in `lib_sqlite.openDb`
2. `floatToBytes64` — in `lib_recordenc.cellBodyBytes`
3. `shiftLeft` — in `lib_varint.sqVarintStep`

### Extern table (the real blocker)

The emitter's **supported** extern set (string-lit dispatch arms in `wasm_emit.mdk`)
includes: `arrayLength/Copy/Make/MakeWith/Get­Unsafe/SetUnsafe/FromList`,
`stringToUtf8Bytes`, `stringFromUtf8Bytes`, `string*` (slice/compare/indexOf/case/
fromChars/toChars), `intToString/Float`, `floatToInt/String`, `stringToFloat`,
`hash*`, `random*`, `readFile`/`fileExists`/`getEnv`/`args`/`exit` (W12 string IO).

Externs the lib uses, vs wasm support (usage counts across `sqlite/` +
stdlib `byteparser`/`bytebuilder`/`array`):

| extern | uses | category | wasm impl? | what's needed |
|---|---|---|---|---|
| `bitAnd` | 30 | pure-compute | **NO** | `i64.and` (trivial) |
| `shiftLeft` | 10 | pure-compute | **NO** | `i64.shl` (trivial) |
| `shiftRight` | 8 | pure-compute | **NO** | `i64.shr_s` (trivial) |
| `arrayBlit` | 2 | pure-compute | **NO** | offset/len copy loop (or `array.copy`) |
| `arrayFill` | 1 | pure-compute | **NO** | fill loop |
| `floatToBytes64` | 2 | float reinterpret | **NO** | `i64.reinterpret_f64` + 8-byte extract (pure wasm) |
| `bytesToFloat64` | 2 | float reinterpret | **NO** | 8 bytes→`i64`→`f64.reinterpret_i64` (pure wasm) |
| `readFileBytes` | 3 | host I/O | **NO** | host import returning a **byte** array (≠ `readFile`'s String) |
| `writeFileBytes` | 9 | host I/O | **NO** | **new** host import + Node `fs.writeFileSync` |
| `arrayGetUnsafe` | (byteparser `.[]`) | array | **YES** ✓ | — |
| `stringToUtf8Bytes` / `stringFromUtf8Bytes` | (`string.toUtf8`/`fromUtf8`) | string | **YES** ✓ | — |
| `beUint`/`beSint`/`emitBeUint`/`sqVarint` | many | *Medaka fns* | n/a | built on the above; not externs |

Note: `beUint` itself is pure arithmetic (`acc*256 + byte`, no bitwise) — it's
`sqVarint`/`beSint` that pull `shiftLeft`/`shiftRight`/`bitAnd`. No
`bitOr`/`bitXor`/`bitNot` are used by the lib.

**Shape of the gap:** 5 of 7 missing externs are **pure-computational** (bitwise,
shift, blit, fill) — trivial inline wasm with no host involvement. 2 are **float
reinterpret** — pure wasm via `reinterpret`, moderate (byte (de)serialization of a
`f64`). Only 2 are genuine **host I/O** (`readFileBytes`, `writeFileBytes`).

### Minimal end-to-end proof — how far it got
- **Native oracle works.** An in-memory probe parsing an inline record byte array
  (`arrayFromList [4,0,23,1,67,97,114,111,108,25]` via `parseRecord`/`runByteParser`/
  `showCells`) builds + runs natively → `NULL|Carol|25`. (A second probe via
  `encodeRecord` also natively round-trips `42|hi|NULL`.)
- **Wasm build:** first blocker at `readFileBytes` for the file demos; for the
  file-I/O-free inline-array probe, the first blocker is `shiftLeft` (via `sqVarint`
  inside `parseRecord`). Verbatim:
  ```
  error: wasm emitter failed compiling <file>
  wasm_emit gap — ref-mode: unbound variable 'shiftLeft' [in lib_varint__sqVarintStep]
  ```
- **Conclusion:** the lib never reaches assemble/validate/run under wasm today; the
  *first hard blocker is the extern surface*, exactly as predicted. No emitter
  construct gap stands in the way — once the externs exist, the lib's Medaka should
  emit and run.

---

## 2. The file-I/O seam decision

The lib is **already bytes-first and cleanly seamed**. `readFileBytes`/`writeFileBytes`
are confined to the **edges**: `lib_sqlite.openDb` (read) and `lib_dbwriter.writeDatabase`
(write). Everything between — `byteparser`, `varint`, `recordfmt`/`recordenc`, `btree`,
`header`, `query`, `select`, `mutate`, `writer` — operates purely on `Array Int`. The
in-memory probe above proves the parse path runs with **zero** file I/O once the
compute externs exist.

**Recommendation — do both, in order:**
1. **Primary (v1): in-memory `Array Int`.** Expose the byte-array entrypoints the lib
   already has (`openDb` consuming bytes; `buildDatabase`/`writeDatabase`'s
   `Array Int` product) and drive them from a wasm `main` that holds an inline /
   host-fed byte array. This is the cleanest verification surface and needs **no new
   file externs** — only the pure-compute + float-reinterpret externs. The lib needs
   **no refactor** for this; the byte-source is already separable.
2. **Secondary: host file externs over Node fs.** `readFileBytes` maps naturally onto
   the existing `run.js` **byte-channel** (`mdk_path_push` + `resultBuf` +
   `mdk_result_len`/`mdk_result_byte`) that `readFile` already uses — it returns a
   `Buffer`; a bytes-returning variant just hands those bytes back as an `Array Int`
   instead of UTF-8-decoding to a `$str`. `writeFileBytes` needs a **new** host import
   (push path + push N bytes + `fs.writeFileSync`). In the browser these route to the
   `vfs` virtual-FS already stubbed in `run.js`.

No lib refactor is required for either; the byte-source/byte-parsing split already
exists. (If anything, a tiny convenience: ensure `openDb` has a public
`bytes -> Db` form that the file path also calls — verify it does.)

---

## 3. Recommended approach + staged plan

Each stage is independently verifiable. **COMPILER stages touch
`compiler/backend/wasm_emit.mdk`** (and possibly `test/wasm/run.js`); these are
validated by the **wasm gates** (`build_wasm_oracle.sh` + `diff_wasm.sh`), **not** the
LLVM fixpoint. **Confirmed:** `wasm_emit.mdk` is reached only through the
`wasm_emit_modules_main` entry graph; the LLVM self-compile fixpoint compiles
`llvm_bootstrap_lex_main` (emitter + front end + prelude), which does **not** include
`wasm_emit.mdk`. So **wasm-emitter changes need a wasm-oracle rebuild + `diff_wasm.sh`,
and do NOT need an LLVM seed re-mint.** (Still run `make medaka` so the shipped binary
can self-emit wasm; double-check the fixpoint stays green out of caution.)

| # | Stage | Touches | Verify | Model |
|---|---|---|---|---|
| 0 | **Pure-compute externs** — lower `bitAnd`/`shiftLeft`/`shiftRight`/`arrayBlit`/`arrayFill` in `wasm_emit` (inline `i64.and`/`shl`/`shr_s`; copy/fill loops). Mirror existing `arrayCopy`/`arraySetUnsafe` arms. | COMPILER (`wasm_emit.mdk`) | add fixtures to `test/wasm/fixtures` exercising each; `diff_wasm.sh` green | **Sonnet** (mechanical, has 1:1 templates) |
| 1 | **Float-reinterpret externs** — `floatToBytes64` / `bytesToFloat64` via `i64.reinterpret_f64` / `f64.reinterpret_i64` + big-endian byte (de)assembly. Must match `medaka_rt.c` byte order exactly. | COMPILER (`wasm_emit.mdk`) | round-trip fixture; diff vs native oracle byte-for-byte | **Opus** (IEEE byte-order correctness; subtle) |
| 2 | **In-memory read proof** — wasm-build the inline-array `parseRecord` probe (and a `buildDatabase`→`Array Int`→`parseRecord` round-trip); run under Node ≥22; diff vs native. After stages 0–1 this should pass with no file externs. | proof only (a probe `.mdk`) | new `test/wasm/` oracle: build wasm + native from same src, diff stdout | **Sonnet** |
| 3 | **`readFileBytes` host extern** — bytes-returning variant over the existing `run.js` byte-channel + a `wasm_emit` W12-style extern arm. | COMPILER (`wasm_emit.mdk` + `run.js`) | wasm-build `query_demo`, run vs native on a real `.sqlite` | **Opus** (host-ABI seam) |
| 4 | **`writeFileBytes` host extern** — new host import (path + N bytes + `fs.writeFileSync`) + emitter arm. | COMPILER (`wasm_emit.mdk` + `run.js`) | wasm-build `writer_demo`/`multipage_write_demo`, diff the produced `.sqlite` bytes vs native | **Opus** |
| 5 | **Wasm-vs-native diff oracle** — a `test/wasm/diff_sqlite.sh` that builds each sqlite demo for BOTH targets from the same source and diffs outputs (in-memory probes need no fs; file demos use a temp `.sqlite`). Wire into the gate set. | harness (`test/wasm/`) | the oracle itself green across the demo corpus | **Sonnet** |
| 6 | **Cross-project dep under wasm (optional)** — if any future sqlite consumer uses `[deps]`, confirm `--target wasm` resolves it (sqlite-internal imports are stdlib, so untested today). | verify only | a 2-package fixture built `--target wasm` | **Sonnet** |

Sequence rationale: 0→1 unlock the **entire in-memory parse/encode path** (stage 2
proof) with zero host work; 3→4 add file edges; 5 makes it permanent and tandem-safe.

---

## 4. Design forks needing a human decision

a. **In-memory bytes vs Node-fs file externs for wasm.** Recommend **both, phased**
   (§2): in-memory `Array Int` is the v1 verification surface (stages 0–2, no host
   file I/O); `readFileBytes`/`writeFileBytes` host externs come after (stages 3–4)
   for demo parity. Decision: is the in-memory surface sufficient for v1 "done", with
   file externs as a follow-up — or must the file demos run under wasm to call it
   done?

b. **v1 scope: read-only first vs read+write.** Read path needs externs
   {bitAnd, shiftLeft, shiftRight, bytesToFloat64} + (for files) readFileBytes. Write
   path adds {floatToBytes64, arrayBlit, arrayFill, writeFileBytes}. Recommend
   **read-only in-memory first** (stages 0,1-partial,2), then write. Decision: split
   the milestone, or do the full read+write extern surface in one pass (it's only 9
   externs, 5 trivial)?

c. **How much may the lib be refactored vs kept byte-identical to native.**
   Recommendation: **keep `sqlite/` byte-identical to native** — no refactor needed;
   the byte-source/parse seam already exists, and all work lands in `wasm_emit.mdk` +
   `run.js`. Only possible lib touch: ensure a public `bytes -> Db` entry exists for
   in-memory use (likely already present). Decision: confirm "no lib changes" as a
   constraint?

d. **Verification harness shape.** Recommend a **shared wasm-vs-native diff oracle**
   (stage 5) mirroring `diff_wasm.sh`: same source → native binary AND wasm module →
   diff stdout (in-memory) or produced `.sqlite` (file). Decision: per-demo oracle
   scripts (like the existing `sqlite/test/*_oracle.sh`) extended with a wasm arm, or
   one new `test/wasm/diff_sqlite.sh`?

---

## 5. Tandem-development note (the stated goal)

To keep native + wasm in lockstep for **future SQL features**, the durable artifact is
**stage 5's shared oracle**: every sqlite demo/test is built for **both** targets from
the **one** source and its output diffed. Because the lib is bytes-first, most new
features can be exercised **in-memory** (inline `Array Int` → parse/encode → print),
which needs no host I/O and runs identically on both backends — so a new feature's
test is automatically a wasm test. Make the rule: **a new sqlite feature ships with an
in-memory fixture that the wasm-vs-native oracle runs**; file-backed demos additionally
diff the produced `.sqlite` bytes. Once the extern surface (stages 0–4) is closed, the
two backends differ only in the 7 externs above — all behind a stable seam — so feature
work touches neither emitter.
```
emitter delta to close the port:  5 trivial + 2 float-reinterpret + 2 host = 9 externs
construct/emitter gaps:           0
lib refactor:                     none required
```

---

## LOCKED SCOPE (orchestrator + user decision, 2026-06-30)

**v1 = full SQLite on WasmGC, all 9 externs (in-memory CRUD + node-fs host I/O), lib unchanged.** Fork answers:
- (a) **Include host I/O** — `readFileBytes`/`writeFileBytes` wasm host externs (node-fs) so the existing FILE-based demos/oracles run under wasm too (in addition to in-memory).
- (b) Full read+write extern surface (in-memory CRUD needs only the 7 non-host externs; host I/O adds file demos).
- (c) **No lib changes** — `sqlite/` stays byte-identical/target-agnostic; only externs differ. The lib is already cleanly bytes-first seamed (file externs only at `openDb`/`writeDatabase` edges).
- (d) **One shared `test/wasm/diff_sqlite.sh`** that builds a probe under BOTH native and wasm and diffs output — the tandem-development enabler (every future in-memory sqlite fixture becomes a wasm test automatically).

**Compiler impact:** all changes are wasm-backend — `compiler/backend/wasm_emit.mdk` (extern dispatch ~729-1013: add supported-extern entries + WAT lowering) and `test/wasm/run.js` (host-import Node impls for the I/O seam, alongside the existing `env.mdk_write_byte`). `wasm_emit.mdk` is OUTSIDE the LLVM self-compile graph → **NO seed re-mint / LLVM fixpoint**; gates = `test/wasm/diff_wasm.sh` (139/0 baseline) green + `assemble_check` validate + the new `diff_sqlite.sh` (wasm output == native). Node v24.17.0 via nvm (default v20 too old for WasmGC).

**Staged plan (sequential — A/B/D all edit `wasm_emit.mdk`):**
- **A — pure-compute externs** (`bitAnd`→`i64.and`, `shiftLeft`→`i64.shl`, `shiftRight`→`i64.shr_s`, `arrayBlit`/`arrayFill`→copy/fill loops) in `wasm_emit.mdk`. **Sonnet.** Gate: a wasm probe using them == native; `diff_wasm` still 139/0.
- **B — float-reinterpret externs** (`floatToBytes64` = `i64.reinterpret_f64`+BE bytes, `bytesToFloat64` = bytes→`f64.reinterpret_i64`) in `wasm_emit.mdk`. **Opus** (byte-order/IEEE care — must match the native/C impl exactly). Gate: float cell round-trip wasm == native. After B, all 7 non-host externs are in → full IN-MEMORY CRUD should work on wasm.
- **C — in-memory CRUD proof + shared oracle** `test/wasm/diff_sqlite.sh`: an in-memory sqlite probe (build db → read → mutate → read) run under both targets, diffed. **Sonnet.** This is the milestone that proves wasm CRUD == native + the tandem harness.
- **D — host I/O externs** `readFileBytes` (byte-channel exists in `run.js`) + `writeFileBytes` (new host import + Node `fs` write) in `wasm_emit.mdk` + `test/wasm/run.js`. **Opus.** Gate: a FILE-based sqlite demo runs under wasm == native; extend `diff_sqlite.sh` with a file arm.
- (Cross-project deps: MOOT — `sqlite/` has no `[deps]`, all imports are stdlib.)

---

## AS-BUILT (shipped 2026-06-30, main `3a633d7`)

WasmGC port COMPLETE — SQLite (in-memory + file, full CRUD) runs under `--target wasm` == native. All wasm-backend work (no seed re-mint / LLVM fixpoint); gated by `test/wasm/diff_wasm.sh` (141/0) + the new `test/wasm/diff_sqlite.sh` (2/0, in-memory + file arms). The lib is UNCHANGED (target-agnostic; only externs differ).

- **Stage A (`8cff4f3`):** 5 pure-compute externs → WAT (`bitAnd`→`i64.and`, `shiftLeft`→`i64.shl`, `shiftRight`→`i64.shr_u` LOGICAL, `arrayBlit`→`array.copy`, `arrayFill`→store loop). Wasm Int rep is UNTAGGED raw i64 → trivial.
- **Stage B (`b9d05c3`):** 2 float-reinterpret externs (`floatToBytes64`/`bytesToFloat64`, 8-byte big-endian IEEE-754 via `i64.reinterpret_f64`/`f64.reinterpret_i64`) matching `medaka_rt.c` byte-for-byte (incl. `-0.0` sign).
- **Stage C (`3d15756`):** in-memory CRUD proof + shared `diff_sqlite.sh` oracle. Closed 2 emitter gaps (W-SQLITE-1 eta-array, W-SQLITE-2 tuple-pattern freeVars — see EMITTER-GAPS.md).
- **Stage D (`3a633d7`):** host I/O externs `readFileBytes` (reuses the existing read byte-channel) + `writeFileBytes` (new `mdk_write_file_reset/push/commit` host imports → Node `fs.writeFileSync`), so file-based SQLite incl. `delete`/`update` runs under wasm. Closed 1 more emitter gap (W-SQLITE-3 maxIndexAt undercount).

**Tandem workflow now live:** add a probe to `diff_sqlite.sh`'s `CORPUS` → it builds under both native + wasm and diffs. Every future in-memory SQL feature gets a wasm test for free.
