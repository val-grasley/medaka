---
name: perf-hunt
description: Find and fix a performance problem in the Medaka compiler — especially an accidental O(n²). Profile per-stage time AND allocation, name the hot symbol with perf, confirm by stub-and-measure. Use when a stage is unexpectedly slow, when diff_compiler_perf_scaling.sh goes red, or when a compile takes longer than the sum of its profiled stages.
---

# Hunting a performance bug (usually an O(n²))

Six quadratics were found in the compiler on 2026-07-13 — `resolve`'s `contigGo`;
five sites in `typecheck`; `exhaust`'s `groupByName` (quadratic *twice over*); the
CLI's `userSchemeLines`. **Every single one was the same shape: a `List` scanned,
`elem`-checked, `lookup`-ed, or REBUILT once per element.**

Note `xs ++ [x]` inside a fold is O(n²) all by itself, since list append is O(n).
When you see that shape, you have probably already found it.

The gate that catches this class is `test/diff_compiler_perf_scaling.sh`: it feeds
inputs at N and 2N and checks the **allocation** growth ratio per doubling (linear
≈2.0×, quadratic ≈4.0×). It grades allocation, not wall-clock, because GC bytes are
deterministic — so the gate is machine-independent and noise-free, which no timing
gate can be on a shared runner.

## The workflow, in order

### 1. Profile per-stage time AND allocation

```sh
MEDAKA_PERF=1 test/bin/profile_main <runtime.mdk> <core.mdk> <target.mdk>
```

⚠️ **`test/bin/` is a BUILD ARTIFACT — it is not committed**, so a fresh
clone/worktree has no `profile_main`. Build just that one probe (never the bare
`FORCE=1 build_oracles.sh`, which builds all 54):

```sh
FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one profile_main
```

**Allocation is the reliable signal.** It is deterministic (no runner noise), and it
exposed every one of the six more sharply than wall-clock did. A stage whose
allocation ~4× across an input doubling is quadratic. Some stages are milliseconds at
these sizes, so their *timing* is pure noise while their *allocation ratio* is stark.

### 2. Name the hot symbol with `perf`

`perf` is NOT installed by default: `apt-get install linux-perf`.

⚠️ **USE DWARF CALL GRAPHS. Flat counts will mislead you.**

```sh
perf record --call-graph dwarf,16384 -- <cmd>
```

This works — the emitted LLVM carries CFI, so DWARF unwinding produces clean stacks.
(An earlier doc claimed call graphs were "unusable". That was WRONG — it referred to
frame-pointer unwinding — and it cost an agent a wrong turn.)

**Why flat counts mislead here, specifically:** they profile **TIME**, but the perf
gate grades **ALLOCATION** — and on this workload those point at *different
functions*. Flat counts named `rootIdOf` at 28%, which is pure CPU and allocates
nothing, so it was invisible to the gate.

The move that actually works is **allocation attribution**: pipe `perf script` through
a filter that attributes each `GC_malloc_kind` sample to its nearest `mdk_` frame.
That is what the gate measures, and it named the two guilty functions in one shot.

Corollary: if the profile looks flat and allocation-dominated (`GC_malloc_kind` ~11%,
everything else <2%), **you are looking at the wrong axis.** Get allocation
attribution, or fall back to a stage-timing probe.

### 3. Read the source to find *why* it is O(N), then stub-and-measure to confirm

### 4. ⚠️ `whenL False (expensiveCall …)` is NOT a stub

Medaka is **STRICT** — the argument still evaluates. This produced a false "hypothesis
disproved" on a *correct* hypothesis. There is no lazy escape hatch; to stub something
out, actually remove the call.

## ⚠️ An unprofiled stage is an unprofilable bug

`checkGuardExhaustiveness` is a standalone pass over the RAW, PRE-DESUGAR AST (it needs
the surface `EGuards` shape that desugar lowers away), so it is in **no stage table**
and was in **no profiler** — which is exactly why a quadratic hid in it, and why
`medaka check` was 2.3s slower than the sum of every profiled stage. It is now emitted
as `[perf] exhaust-guards`.

**If you add a pass, profile it.**

## If the change is in the emitter

A perf fix to `compiler/backend/*` changes the code the compiler *emits*, which means
benchmarking it correctly needs **two** rebuilds, not one — see the
**benchmark-emitter** skill BEFORE you take any measurement. Measuring this wrong makes
an optimization look like a regression; it has happened, and it cost ~40 minutes.

## Where the numbers live

`compiler/PERF-RESULTS.md` — measured perf log, reusable patterns, and every dead end.
`compiler/PERF-SCOPE.md` — ranked hot paths and scoping. Harness: `test/bench.sh`.
