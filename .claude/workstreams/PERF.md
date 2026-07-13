# Workstream: PERF

**Owns:** quadratics and constant factors in the compiler.
**Touches:** `compiler/frontend/resolve.mdk`, `compiler/tools/check.mdk`, `compiler/types/`.

**The gate:** `test/diff_compiler_perf_scaling.sh` — it measures **ALLOCATION**, not wall-clock.
GC bytes are deterministic, so the gate is machine-independent *and* noise-free, which no timing
gate can be on a shared runner. Ratio per input doubling: linear ≈2.0x, n·log n ≈2.1x,
**quadratic ≈4.0x**.

---

## P-1 · The 11th quadratic: `resolve`'s scopes are `List String` with a linear `contains`

The file's own comment (around resolve.mdk:172) admits it. **3.82x per doubling** — it is now
the top allocator in the compiler. Straightforward fix (a set), high value.

## P-2 · `medaka check` runs the front end 2–3x per invocation

A ~3x **constant factor**. Likely worth more than either quadratic already fixed — a constant
factor on every invocation beats an asymptotic win at sizes people actually compile.

---

## The method that has now worked eleven times

**Every single quadratic found so far was the same shape: a `List` scanned, `elem`-checked,
`lookup`-ed, or REBUILT once per element.** Note `xs ++ [x]` inside a fold is O(n²) all by
itself, since list append is O(n).

1. `MEDAKA_PERF=1 test/bin/profile_main <runtime> <core> <target>` — per-stage time AND
   allocation. **Allocation is the reliable signal**: deterministic, no runner noise, and it
   exposed every one of them more sharply than wall-clock did.
2. `perf record --call-graph dwarf,16384` to NAME the hot symbol. **This works** — the emitted
   LLVM carries CFI. (An older doc claimed call graphs were unusable; that was wrong and cost an
   agent a wrong turn.)
   **But flat counts profile TIME while the gate grades ALLOCATION, and on this workload they
   point at different functions.** Pipe `perf script` through a filter that attributes each
   `GC_malloc_kind` sample to its nearest `mdk_` frame — allocation attribution is what the gate
   measures.
3. **`whenL False (expensiveCall …)` is NOT a stub.** Medaka is STRICT — the argument still
   evaluates. This produced a false "hypothesis disproved" on a *correct* hypothesis. To stub
   something out, actually remove the call.

## ⚠️ Benchmarking an EMITTER change needs TWO rebuilds

A binary's **behavior** comes from its **source**; its **speed** comes from **the emitter that
compiled it**. One `FORCE_EMITTER_REBUILD=1 make medaka` after an emitter change gives you new
behavior in **old machine code** — build a "before" and "after" that way and **the binaries are
crossed**. An agent measured its own **2.2x win as a 2.5x SLOWDOWN** and nearly abandoned it.

**Never use the main checkout's shared `./medaka_emitter` as a baseline** — it is a mutable
artifact another agent will rebuild under you.
