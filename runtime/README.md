# `runtime/` — native C runtime for the LLVM backend

The C-ABI runtime that compiled Medaka links against. See
[`../selfhost/RUNTIME-DESIGN.md`](../selfhost/RUNTIME-DESIGN.md) for the full
extern-disposition strategy (all 71 primitives) and the value-representation +
calling-convention proposal (§8), and
[`../selfhost/STAGE2-DESIGN.md`](../selfhost/STAGE2-DESIGN.md) §2.4 for where this
fits in the backend plan.

## Status: de-risking spike only

> **`medaka_rt.c` is NOT the real runtime.** It is the minimal stub the Stage-2.4
> *de-risking spike* (`../selfhost/llvm_emit.mdk`) links against to prove the
> emit → `clang` → link → run → diff toolchain end-to-end for the simplest scalar
> subset. The real runtime (~54 leaf C functions per RUNTIME-DESIGN.md §5) is built
> slice-by-slice later, after the bytecode VM (§2.2) proves the same ABI against the
> tree-walker oracle.

What the stub provides today (4 functions):

| Symbol | Role |
|--------|------|
| `mdk_alloc(i64) -> ptr` | Heap allocation entry point. **Spike: malloc-and-leak** (GC deferred — the later step is `brew install bdw-gc` and routing this to `GC_malloc`). Every extern that *returns* a Medaka value must allocate through here so the GC swap is one function (RUNTIME-DESIGN.md §2a). |
| `mdk_print_int(i64)` | Print an `Int`. Matches the tree-walker oracle: `Eval.pp_value (VInt n)` + newline. |
| `mdk_print_bool(i64)` | Print a `Bool` (`true`/`false`). |
| `mdk_print_float(double)` | Print a `Float`, reproducing OCaml `string_of_float` byte-for-byte (`%.12g` + a trailing `.` when integral, e.g. `14.`). |

## Value representation (PROVISIONAL — see RUNTIME-DESIGN.md §8)

The spike uses a uniform 64-bit tagged word, **revisable in one place** (this file +
`../selfhost/llvm_emit.mdk`'s tag/box helpers) because the tag arithmetic is emitted
*into the LLVM IR*, not baked into the runtime:

- **`Int` / `Bool` / `Char`** — immediate, `(n << 1) | 1` (low bit 1). Lossless for
  Medaka's 63-bit `Int`.
- **`Float`** — boxed: the word is a pointer (low bit 0) to a 16-byte cell
  `{ i64 header, double }` allocated via `mdk_alloc`. This is the one slice-1 value
  that must hit the heap — the concrete evidence behind RUNTIME-DESIGN.md §8's
  "floats don't fit a tagged-int word".

These helpers take/return *native* C scalars (the emitter untags/unboxes first), so
the runtime stays a plain C-ABI leaf with no knowledge of the tag scheme beyond the
`TAG_FLOAT` header it writes.

## Building / running it

You don't invoke this directly — the equivalence gate does:

```sh
sh test/diff_selfhost_llvm.sh   # emit each fixture's .ll, clang it with medaka_rt.c, run, diff
```

Manual one-off:

```sh
medaka run selfhost/llvm_emit_main.mdk test/llvm_fixtures/int_arith.mdk > /tmp/x.ll
clang /tmp/x.ll runtime/medaka_rt.c -o /tmp/x && /tmp/x
```

`clang` (Apple clang ≥ 15 / any LLVM ≥ 15 with opaque pointers) compiles textual
LLVM IR directly — no `llc`/`opt` needed. The harmless `overriding the module target
triple` warning on stderr is expected (the emitted module carries no triple).
