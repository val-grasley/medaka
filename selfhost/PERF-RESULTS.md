# PERF-RESULTS.md — native-backend performance log

Running log of measured native-backend performance. Companion to
`selfhost/PERF-SCOPE.md` (the scoping/plan). Each entry: what changed, the
gate state, and the numbers (min-of-N, single-threaded, quiet machine).

## Machine / toolchain

| | |
|---|---|
| Chip | Apple M5 (10-core: 4 P + 6 E), 32 GB |
| OS | macOS 26.5 (25F71) |
| clang | Apple clang 21.0.0 (clang-2100.0.123.102) |
| Date | 2026-06-10 |

Method: `/usr/bin/time -l`, min-of-3 unless noted, cache pre-warmed, no parallel
CPU work during timing runs.

Workloads:
- **fib 38** (`test/bench_fixtures/fib.mdk`) — exponential tree recursion,
  pure Int, **no heap allocation** → isolates raw codegen, zero GC.
- **self-compile** — the native emitter binary emitting its OWN module graph
  (`runtime.mdk core.mdk llvm_emit_modules_main.mdk selfhost stdlib`),
  emits 10 119 834 bytes of text IR. The heaviest representative workload.

---

## Entry 1 — Baseline -O0 + flip to -O2 (2026-06-10)

**Change:** added `-O2` to the clang link step in both build drivers
(`lib/build_cmd.ml:233`, `selfhost/build_cmd.mdk:219`). Previously all 6 clang
invocations ran at implicit `-O0`.

**Gates (all green, both at -O2):**
- `test/selfcompile_fixpoint.sh` (emit driver) — C3a YES, C3b YES.
- `test/selfcompile_build_fixpoint.sh` (build driver) — C3a YES, C3b YES.
- `test/diff_selfhost_build.sh` — 9/9 programs byte-identical (OCaml vs selfhost
  build, GC correct under -O2; no `-fno-omit-frame-pointer` needed).
- `dune build --root .` clean.
- Emitter self-compile IR **byte-identical -O0 vs -O2** (`cmp -s` clean) and
  fib output identical → `-O2` is behavior-preserving, fixpoint-safe (text IR is
  pre-clang, as predicted in PERF-SCOPE §1c).

**Numbers (min-of-3 wall / max-RSS):**

| Workload | -O0 wall | -O0 RSS | -O2 wall | -O2 RSS | OCaml interp wall | interp RSS |
|---|---|---|---|---|---|---|
| fib 38 | 0.11 s | 2.31 MB | 0.10 s | 2.33 MB | n/a | n/a |
| self-compile | 12.04 s | ~770 MB | **9.78 s** | **162 MB** | 125.35 s | 1467 MB |

**Headline findings:**
- **Native vs OCaml interpreter (the retirement bar):** native -O0 is **10.4×**
  faster than the interpreter (12.04 s vs 125.35 s) and uses **1.9×** less memory;
  native -O2 widens it to **12.8×** faster and **9.1×** less memory. The
  performance bar for OCaml retirement is satisfied with comfortable margin.
- **-O2 self-compile:** ~18 % wall-clock improvement (12.04→9.78 s) and a
  **4.7× drop in peak RSS** (770→162 MB). The RSS collapse is the standout win —
  consistent with `mem2reg` promoting the 2 234 `alloca` slots out of the
  emitter's hot functions (PERF-SCOPE §3b#1), eliminating stack-spill pressure.
- **fib 38:** essentially flat (0.11→0.10 s). Expected — fib allocates nothing
  and the inner loop is already register-tight at -O0; there is no alloca/GC
  overhead for -O2 to remove. Confirms the self-compile win comes from
  alloca/spill elimination, not arithmetic.

**Cost / tradeoff:** clang `-O2` of the 10 MB emitter IR makes the *build* step
much slower (emitter native build ~127 s at -O2 vs a few s at -O0). This is a
one-time compile cost paid by `medaka build`; runtime + RSS improve. Acceptable
for the compiler binary; revisit if per-invocation build latency matters for
small user programs (could gate -O2 on input size).

**Next candidates (PERF-SCOPE §3b, not yet done):** TRMC for `x :: recurse`
list builders (PLAN #56); reduce GC allocation density on hot paths (4 201
`mdk_alloc` sites) — structural, beyond what -O2 reaches.

---

## Entry 2 — Boehm GC free-space-divisor tuning (2026-06-10)

**Change:** `runtime/medaka_rt.c` `mdk_gc_init` now calls
`GC_set_free_space_divisor(1)` after `GC_INIT()` (was the default, 3), unless
`GC_FREE_SPACE_DIVISOR` is set in the environment. A lower divisor lets the heap
grow further between collections → fewer collection cycles. This is a **runtime**
change only — it is NOT in the emitter module graph, so the seed and the
text-IR fixpoint are unaffected by construction.

Motivation: after Entry 1, the emitter self-compile was GC-bound — RSS had
dropped to 162 MB (lots of headroom) but wall-clock was still 9.78 s, dominated
by collection of the ~4 200 cells/run + every cons/closure. The default divisor
optimizes for low RSS at the cost of collection frequency; Medaka's short-lived
allocation-heavy workloads prefer the opposite trade.

**Gates (all green):** `dune build --root .` clean; `selfcompile_fixpoint.sh`
C3a/C3b YES; `diff_selfhost_build.sh` 9/9 byte-identical; self-compile emitted IR
byte-identical to Entry-1 output; listsum output unchanged.

**Numbers (min-of-3 self-compile, min-of-5 listsum; all -O2):**

| Workload | -O2 default GC | -O2 divisor=1 | Δ wall | RSS default→tuned |
|---|---|---|---|---|
| self-compile | 9.78 s | **6.25 s** | **−36 %** | 162 → 229 MB |
| listsum (20M cons) | 0.11 s | 0.11 s | flat | 3.1 → 3.7 MB |

**Cumulative vs the original -O0 / default-GC baseline:**

| Workload | original (-O0, div 3) | now (-O2, div 1) | speedup | RSS |
|---|---|---|---|---|
| self-compile | 12.04 s / 770 MB | **6.25 s / 229 MB** | **1.93×** | 3.4× less |
| vs OCaml interpreter | 125.35 s | 6.25 s | **20.1×** | 6.4× less |

**Findings:**
- GC collection frequency, not codegen, was the dominant self-compile cost after
  -O2. Trading ~67 MB of peak RSS for divisor=1 buys a 36 % wall-clock cut.
- The native compiler is now **~20× faster than the OCaml interpreter** at the
  representative self-compile workload — the perf bar for OCaml retirement is met
  with wide margin.
- listsum (pure cons churn, tiny live set) is unaffected — its GC cost was
  already negligible; the win is specific to workloads with a large transient
  working set like the emitter.
- divisor=1 is bounded: heap grows to ~2× the live set, so RSS stays well under
  the -O0 baseline. Env var `GC_FREE_SPACE_DIVISOR` overrides for memory-tight
  deployments.

**Next candidates:** TRMC (PLAN #56) for list-builder stack pressure; profile the
remaining 6.25 s self-compile to see whether it is now emit-logic-bound or still
alloc-bound (try divisor=2 as a memory/speed midpoint; measure GC_get_heap_size).

