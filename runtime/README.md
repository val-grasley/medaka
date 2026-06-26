# `runtime/` — native C runtime for the LLVM backend

The C-ABI runtime that compiled Medaka links against. See
[`../compiler/RUNTIME-DESIGN.md`](../compiler/RUNTIME-DESIGN.md) for the full
extern-disposition strategy (all 71 primitives) and the value-representation +
calling-convention proposal (§8), and
[`../compiler/STAGE2-DESIGN.md`](../compiler/STAGE2-DESIGN.md) §2.4 for where this
fits in the backend plan.

## Status: canonical LLVM runtime (verified done 2026-06-22)

> **`medaka_rt.c` IS the real runtime.** The de-risking spike this document originally
> described (slices 1–5a) grew into the full ~1039-line runtime backing the canonical
> native `medaka` binary. All extern primitives are implemented, Boehm GC is wired
> (`GC_malloc`/`GC_malloc_atomic` — not malloc-and-leak), strings are full UTF-8
> with cached codepoint counts, and IO/file/stdio/hash/sort/RNG/time externs all land
> here. The "build slice-by-slice later" plan is done. See
> [`../compiler/BOOTSTRAP.md`](../compiler/BOOTSTRAP.md) for the completion log.

What the file provides (functions grouped by role — see source for the full list):

| Group | Functions |
|-------|-----------|
| Allocation | `mdk_alloc`, `mdk_alloc_atomic` |
| Print (value types) | `mdk_print_int`, `mdk_print_bool`, `mdk_print_float`, `mdk_print_char`, `mdk_print_str`, `mdk_print_unit`, `mdk_print_num` |
| Strings | `mdk_putstr`, `mdk_putstrln`, `mdk_eputstr`, `mdk_eputstrln`, `mdk_flushstdout`, plus full UTF-8 codec, `stringConcat`, `stringIndexOf`, Unicode classify/fold |
| Arrays | `mdk_array_blit`, `mdk_array_fill`, sort, get, set, copy, length |
| IO / process | `readLine`, `readFile`, `writeFile`, `appendFile`, `fileExists`, `listDir`, `args`, `getEnv`, `exit`, `allocBytes`, `wallTimeSec` |
| Hash / RNG | `hashInt`, `hashString`, `hashChar`, `hashBool`, `hashFloat`, `randomInt`, `randomBool`, `randomFloat`, `randomChar`, `setSeed` |

GC is the **Boehm conservative collector** (`GC_init` at startup, `GC_malloc` for all
heap objects, `GC_malloc_atomic` for pointer-free string cells). Immediates (`Int`,
`Bool`, `Char`) are odd tagged words (low bit 1); Boehm never scans them as pointers.

## Value representation (LOCKED — see RUNTIME-DESIGN.md §8)

The runtime uses a uniform 64-bit tagged word, with tag arithmetic emitted
*into the LLVM IR* (not baked into the runtime):

- **`Int` / `Bool` / `Char`** — immediate, `(n << 1) | 1` (low bit 1). Lossless for
  Medaka's 63-bit `Int`.
- **`Float`** — boxed: the word is a pointer (low bit 0) to a 16-byte cell
  `{ i64 header, double }` allocated via `mdk_alloc`. This is the one slice-1 value
  that must hit the heap — the concrete evidence behind RUNTIME-DESIGN.md §8's
  "floats don't fit a tagged-int word".
- **ADT (slice 3)** — boxed: the word is a pointer (low bit 0) to a cell
  `{ i64 tag, field0, field1… }` (one 8-byte word each), allocated via `mdk_alloc`.
  The tag is the constructor name hashed to an i64 (computed in the emitter, so the
  stored tag and a `match`'s compared tag are the same constant by construction —
  no runtime hash). Same boxed-pointer discipline as `Float`, extended to N fields.
- **Closure (slice 4)** — boxed: the word is a pointer to a cell
  `{ i64 header, i64 code_ptr, capt0, capt1… }` (RUNTIME-DESIGN.md §8.5), the same
  cell shape as an ADT (header + fields), so it shares the `mdk_alloc` path. A
  higher-order call loads `code_ptr` and `call`s it passing the closure word as the
  leading argument; the runtime itself stays oblivious (no closure-specific symbol).
- **Record (slice 5a)** — boxed: same cell shape as ADT, with `header = hashName(record-type-name)` and one field per record attribute in declaration order.
- **Tuple (slice 5a)** — boxed: same cell shape with `header = hashName("$tuple")`.
- **Ref (slice 5a)** — boxed: 1-field cell `{ i64 header, i64 stored_value }` with `header = hashName("$ref")`. `.value` loads field 0; `set_ref` stores into field 0. Boehm GC handles tracing; no explicit write barrier needed with the conservative collector.

These helpers take/return *native* C scalars (the emitter untags/unboxes first), so
the runtime stays a plain C-ABI leaf with no knowledge of the tag scheme beyond the
`TAG_FLOAT` header it writes.

## Building / running it

You don't invoke this directly — the equivalence gate does:

```sh
sh test/diff_compiler_llvm.sh   # emit each fixture's .ll, clang it with medaka_rt.c, run, diff
```

Manual one-off:

```sh
medaka run compiler/entries/llvm_emit_main.mdk test/llvm_fixtures/int_arith.mdk > /tmp/x.ll
clang /tmp/x.ll runtime/medaka_rt.c -o /tmp/x && /tmp/x
```

`clang` (Apple clang ≥ 15 / any LLVM ≥ 15 with opaque pointers) compiles textual
LLVM IR directly — no `llc`/`opt` needed. The harmless `overriding the module target
triple` warning on stderr is expected (the emitted module carries no triple).
