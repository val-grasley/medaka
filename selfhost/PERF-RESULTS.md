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
