# Workstream: PERF

**Owns:** quadratics and constant factors in the compiler.
**Touches:** `compiler/frontend/resolve.mdk`, `compiler/tools/check.mdk`, `compiler/types/`.

```sh
gh issue list --label "ws:perf" --state open
```

**Load the `perf-hunt` skill before you start.**

**The gate:** `test/diff_compiler_perf_scaling.sh` — it measures **ALLOCATION**, not wall-clock. GC
bytes are deterministic, so the gate is machine-independent *and* noise-free, which no timing gate can
be on a shared runner. Ratio per input doubling: linear ≈2.0×, n·log n ≈2.1×, **quadratic ≈4.0×**.

---

## The method that has now worked eleven times

**Every single quadratic found so far was the same shape: a `List` scanned, `elem`-checked, `lookup`-ed,
or REBUILT once per element.** Note `xs ++ [x]` inside a fold is O(n²) all by itself, since list append
is O(n).

1. **`MEDAKA_PERF=1 test/bin/profile_main <runtime> <core> <target>`** — per-stage time AND allocation.
   **Allocation is the reliable signal**: deterministic, no runner noise, and it exposed every one of
   them more sharply than wall-clock did.

2. **`perf record --call-graph dwarf,16384`** to NAME the hot symbol. **This works** — the emitted LLVM
   carries CFI. (An older doc claimed call graphs were unusable; that was wrong and cost an agent a
   wrong turn.)
   **But flat counts profile TIME while the gate grades ALLOCATION, and on this workload they point at
   different functions.** Pipe `perf script` through a filter that attributes each `GC_malloc_kind`
   sample to its nearest `mdk_` frame — allocation attribution is what the gate measures.

3. ⚠️ **`whenL False (expensiveCall …)` is NOT a stub.** Medaka is **STRICT** — the argument still
   evaluates. This produced a false *"hypothesis disproved"* on a **correct** hypothesis. To stub
   something out, actually remove the call.

---

## ⚠️ Benchmarking an EMITTER change needs TWO rebuilds

A binary's **behavior** comes from its **source**; its **speed** comes from **the emitter that compiled
it**. One `FORCE_EMITTER_REBUILD=1 make medaka` after an emitter change gives you new behavior in **old
machine code** — build a "before" and "after" that way and **the binaries are crossed**. An agent
measured its own **2.2× win as a 2.5× SLOWDOWN** and nearly abandoned it.

**Never use the main checkout's shared `./medaka_emitter` as a baseline** — it is a mutable artifact
another agent will rebuild under you.

Read the **`benchmark-emitter`** skill first. Every time.

---

## Know which problems are STRUCTURAL before you chase them

Two of the four ranked hot paths in `compiler/PERF-SCOPE.md` are **not fixable by tuning**, and an
agent who does not know that will burn a session:

- **GC allocation density** (`PERF-SCOPE.md:206`) — *"a structural property of the value
  representation"* (uniform heap boxing). `-O2` helps at the margin. The real payoff needs
  stack-allocation of short-lived values, or unboxed nullary constructors in hot paths.
- **Indirect closure calls are not inlineable** (`:242`) — *"STRUCTURAL, not -O2 fixable."* The real fix
  is compile-time specialization, or closure conversion with known targets.

`compiler/PERF-RESULTS.md` is the measured log **including every dead end** — read the dead ends. The
segment-emit attempt is recorded there as a failure, which means the doc's own "highest-value remaining
work" line above it is stale.

---

## ⚠️ Do NOT delegate hot monomorphic helpers to prelude Foldable methods

`elem` / `any` / `all` / `length` lose `||`/`&&` **short-circuiting** and become dict-passed
fold+closure. Doing this to `util.mdk`'s hottest helpers cost **+56% self-compile.** Keep hot inner-loop
helpers **monomorphic and short-circuiting**.

---

## Opt-level knobs preserve byte-identical IR

`EMITTER_OPT` (-O2), `ORACLE_OPT` (-O0), `CLI_OPT` (-O2), `WASM_ORACLE_OPT` (-O2 — **-O0 overflows the
deep-TCO fixtures**) and `GC_INITIAL_HEAP_SIZE` **all preserve byte-identical emitted IR**: the text IR
is produced *before* `clang` runs, so an opt level can never change it.
</content>
