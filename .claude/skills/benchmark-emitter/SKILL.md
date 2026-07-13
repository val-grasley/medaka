---
name: benchmark-emitter
description: Benchmark or validate a change to the Medaka LLVM/WasmGC emitter (compiler/backend/*) without measuring the exact opposite of reality. Covers the two-rebuild rule for a single-generation emitter, why a shared medaka_emitter is not a baseline, and when a stale seed must be re-minted. Use before timing ANY codegen change, and when the self-compile fixpoint fails on a change that looks correct.
---

# Benchmarking / validating an EMITTER change

**Read this BEFORE you take a measurement.** Getting it wrong makes you measure the
exact opposite of reality. It cost an agent ~40 minutes and nearly produced a false
"structurally hard, abandoned" report on a change that turned out to be a **2.2× win**
(2026-07-13). That agent measured its own optimization as a 2.5× SLOWDOWN.

## The one idea

In a self-hosting compiler, a binary has **two independent properties**:

* its **behavior** comes from its **source**;
* its **speed** comes from **the emitter that compiled it**.

## ⚠️ You need TWO rebuilds, not one

After you change the emitter, ONE `FORCE_EMITTER_REBUILD=1 make medaka` gives you a
binary with your **new behavior** but compiled by the **old** emitter — i.e. old
machine code. Build a "before" and an "after" that way and **the two binaries are
crossed**: you are timing the old emitter's codegen on both, plus whatever your change
did to the *compile-time* work.

**Two rebuilds reach a single-generation emitter:** one to propagate the new behavior
*into* the emitter, a second so the emitter is itself compiled BY that emitter. Only
then are both arms true single-generation binaries and the comparison means anything.

## ⚠️ Never use the main checkout's `medaka_emitter` as a baseline

`/root/medaka/medaka_emitter` is a **shared mutable artifact**. Another agent rebuilt it
mid-session and silently invalidated every "before" number derived from it (learned the
same day). **Build your own baseline binary from your own base commit, in your own
worktree.**

## The same two-generation logic governs the SEED

### 1. `test/refresh_seed.sh` is ONE pass and is NOT idempotent after a codegen change. Run it TWICE.

Pass 1 mints the seed using the *old-generation* emitter, so the fixpoint still reports
`C3a: NO`. Pass 2 mints it using an emitter that was itself built from the new seed, and
it converges (`C3a: YES`; the seed also shrinks). Measured 2026-07-13.

### 2. A stale seed can make the fixpoint SEGFAULT on a change that is perfectly correct.

After the arg-tuple removal (−71% allocation, −23% emitted IR), the fixpoint died with
`E-FATAL-SIGNAL: fatal memory fault` at *step 2* — while `make medaka` succeeded, all 83
gates passed, and the compiler-source typecheck was clean. Nothing was wrong with the
merge.

The crash was in the **intermediate bootstrap generation**: new source compiled by the
*stale seed's fat pre-optimization codegen*, which blew the stack. The seed was stale by
exactly the change that fixes it.

**Re-mint before you go bug-hunting** — the symptom points at your diff, and the cause is
the seed.

(A `C3a WARN: … lagging seed` line on its own is NOT a broken seed and NOT something you
did — the seed is allowed to drift, and `seed-health` in CI warns rather than fails on
purpose. Re-mint at checkpoints, not reflexively.)

## The decisive gate

Any change to `compiler/backend/*` must pass the emitter self-compile fixpoint:

```sh
bash test/selfcompile_fixpoint.sh      # C3a/C3b — the decisive gate
```

`make preflight` forces this for you when your diff touches the backend. Finding out in
CI is too late; run it locally for a backend change (this is one of the few cases where a
heavy local run IS justified).

If both backends are in scope, `test/diff_compiler_tmc_parity.sh` checks that LLVM and
WasmGC apply TMC to the same functions (needs the wasm probes:
`sh test/wasm/build_wasm_oracle.sh`).

## Opt-level knobs are output-neutral

`EMITTER_OPT` / `ORACLE_OPT` / `CLI_OPT` / `WASM_ORACLE_OPT` / `GC_INITIAL_HEAP_SIZE` all
preserve **byte-identical emitted IR** — the text IR is produced *before* `clang` runs, so
an opt level can never change it. That is why `-O2` is fixpoint-safe. See
`compiler/PERF-SCOPE.md`.

## If you are hunting a slow stage rather than validating codegen

See the **perf-hunt** skill — profile allocation (deterministic) over wall-clock (noisy),
and use DWARF call graphs.
